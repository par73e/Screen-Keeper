import AppKit
import SwiftUI
import Combine

/// 基于 NSStatusItem + 原生 NSPopover 的菜单栏弹出面板：
/// - 原生系统圆角磨砂玻璃窗口：完全消除无边框 NSPanel 在 WindowServer 下的外围矩形黑线框
/// - 自动居中对齐：通过 `popover.show(relativeTo:of:preferredEdge: .minY)` 居中于菜单栏图标下方
/// - 顶部锚定零跳动：内部使用翻转容器 `TopAnchoredContainerView` + 无动画同步 `popover.contentSize`，展开/收起不跳动
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: PowerStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let contentController: NSViewController
    private let containerView: TopAnchoredContainerView
    private let hostingView: AutoSizingHostingView<MenuPanel>

    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var lastIconKey: String = ""
    private var lastClosedAt: Date = .distantPast

    init(store: PowerStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.contentController = NSViewController()
        self.containerView = TopAnchoredContainerView()
        self.hostingView = AutoSizingHostingView(rootView: MenuPanel(store: store))

        super.init()

        configureStatusButton()
        configurePopover()
        bindUpdates()
        updateStatusIcon()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    private func configurePopover() {
        containerView.translatesAutoresizingMaskIntoConstraints = true
        containerView.autoresizingMask = [.width, .height]

        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width]
        hostingView.onSizeChange = { [weak self] newSize in
            self?.handleContentSizeChange(newSize)
        }

        containerView.addSubview(hostingView)
        contentController.view = containerView

        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private func bindUpdates() {
        // 监听状态变化以刷新菜单栏图标水位与模式
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusIcon()
                }
            }
            .store(in: &cancellables)

        // 不清空 lastIconKey，避免 AppKit 重绘菜单栏图标快照触发 KVO 造成重绘死循环
        if let button = statusItem.button {
            appearanceObservation = button.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.updateStatusIcon()
                }
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let state = store.iconState
        let level = store.waterLevel
        let bucket = Int((min(1, max(0, level)) * 50).rounded())
        let key = "\(state.rawValue)-\(isDark)-\(bucket)"
        guard key != lastIconKey else { return }
        lastIconKey = key
        button.image = MenuBarIcon.image(for: state, dark: isDark, level: level)
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // 避免刚因点击菜单栏图标触发 transient 关闭后在同一点击周期内立即重开
        if Date().timeIntervalSince(lastClosedAt) < 0.15 {
            return
        }
        openPanel()
    }

    private func openPanel() {
        guard let button = statusItem.button else { return }

        store.refreshHolders()
        store.startHoldersAutoRefresh()

        hostingView.layoutSubtreeIfNeeded()
        let size = measuredSize()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerView.frame = NSRect(origin: .zero, size: size)
        hostingView.frame = NSRect(origin: .zero, size: size)
        popover.contentSize = size
        CATransaction.commit()

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.acceptsMouseMovedEvents = true
            popoverWindow.makeKey()
        }
    }

    private func measuredSize() -> NSSize {
        let fit = hostingView.fittingSize
        return NSSize(width: max(296, fit.width), height: max(120, fit.height))
    }

    private func handleContentSizeChange(_ newSize: NSSize) {
        guard popover.isShown else { return }
        let targetSize = NSSize(width: max(296, newSize.width), height: max(120, newSize.height))
        let current = popover.contentSize
        guard abs(current.width - targetSize.width) > 0.5 || abs(current.height - targetSize.height) > 0.5 else { return }

        let wasAnimated = popover.animates
        popover.animates = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerView.frame = NSRect(origin: .zero, size: targetSize)
        hostingView.frame = NSRect(origin: .zero, size: targetSize)
        popover.contentSize = targetSize
        CATransaction.commit()
        popover.animates = wasAnimated
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        lastClosedAt = Date()
        store.stopHoldersAutoRefresh()
    }
}

/// 顶部锚定容器（isFlipped = true 使 y=0 永远贴紧面板顶边，展开/收起时不产生居中跳动）。
private final class TopAnchoredContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// 监听 SwiftUI 内容固有尺寸变化（例如合盖二次确认展开/收起），同步面板高度。
private final class AutoSizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((NSSize) -> Void)?
    private var lastReportedSize: NSSize = .zero

    override func layout() {
        super.layout()
        let size = fittingSize
        if abs(size.width - lastReportedSize.width) > 0.5 || abs(size.height - lastReportedSize.height) > 0.5 {
            lastReportedSize = size
            frame = NSRect(origin: .zero, size: size)
            DispatchQueue.main.async { [weak self] in
                self?.onSizeChange?(size)
            }
        }
    }
}
