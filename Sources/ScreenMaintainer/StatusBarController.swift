import AppKit
import SwiftUI
import Combine

/// 基于 NSStatusItem + 原生 NSPopover + NSHostingController 的菜单栏弹出面板：
/// - 原生系统圆角磨砂玻璃窗口：无外围暗黑直角线框，居中对齐于菜单栏图标下方
/// - NSHostingController(.preferredContentSize) 原生驱动 NSPopover 尺寸，彻底消除手动翻转容器导致的组件错位
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: PowerStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<MenuPanel>

    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var lastIconKey: String = ""
    private var lastClosedAt: Date = .distantPast

    init(store: PowerStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.hostingController = NSHostingController(rootView: MenuPanel(store: store))

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
        hostingController.sizingOptions = [.preferredContentSize]

        popover.contentViewController = hostingController
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

        hostingController.view.layoutSubtreeIfNeeded()
        let fit = hostingController.view.fittingSize
        let size = NSSize(width: max(296, fit.width), height: max(120, fit.height))
        hostingController.preferredContentSize = size
        popover.contentSize = size

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.acceptsMouseMovedEvents = true
            popoverWindow.makeKey()
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        lastClosedAt = Date()
        store.stopHoldersAutoRefresh()
    }
}
