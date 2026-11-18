import AppKit
import SwiftUI
import Combine

/// 基于 NSStatusItem + 无边框透明 NSPanel + NSGlassEffectView 的苹果控制中心式弹出面板：
/// - 居中展开：面板顶部中心对齐菜单栏图标中心（并在屏幕左右边缘自动做安全限位）
/// - 原生 NSGlassEffectView 外壳：直接折射屏幕壁纸与底层窗口，带真实圆角镜面边缘与实时景深
/// - 原地固定：无 NSPopover 箭头框，随内容展开（如合盖二次确认、阻止睡眠列表）保持顶部中心锚定、向下平滑伸展
@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private let store: PowerStore
    private let statusItem: NSStatusItem
    private let panel: FloatingGlassPanel
    private let glassView: NSGlassEffectView
    private let containerView: TopAnchoredContainerView
    private let hostingView: AutoSizingHostingView<MenuPanel>

    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var lastIconKey: String = ""
    private var lastClosedAt: Date = .distantPast
    private var anchoredTopCenter: NSPoint?

    init(store: PowerStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = FloatingGlassPanel()
        self.glassView = NSGlassEffectView()
        self.containerView = TopAnchoredContainerView()
        self.hostingView = AutoSizingHostingView(rootView: MenuPanel(store: store))

        super.init()

        configureStatusButton()
        configurePanel()
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

    private func configurePanel() {
        glassView.style = .regular
        glassView.cornerRadius = 18
        glassView.wantsLayer = true

        containerView.translatesAutoresizingMaskIntoConstraints = true
        containerView.autoresizingMask = [.width, .height]

        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width]
        hostingView.onSizeChange = { [weak self] newSize in
            self?.handleContentSizeChange(newSize)
        }

        containerView.addSubview(hostingView)
        glassView.contentView = containerView
        panel.contentView = glassView
        panel.delegate = self
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

        if let button = statusItem.button {
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.lastIconKey = ""
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
        if panel.isVisible {
            closePanel()
            return
        }
        // 避免刚因点击菜单栏图标触发 resignKey 关闭后在同一点击周期内立即重开
        if Date().timeIntervalSince(lastClosedAt) < 0.15 {
            return
        }
        openPanel()
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        store.refreshHolders()
        store.startHoldersAutoRefresh()

        // 先刷新一次宿主视图尺寸
        hostingView.layoutSubtreeIfNeeded()
        let contentSize = measuredSize()

        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 居中展开：面板水平中心对齐菜单栏图标中心（buttonScreenRect.midX），并在屏幕可视边界内留 8pt 安全边距
        let topY = buttonScreenRect.minY - 6
        let centerX = buttonScreenRect.midX
        anchoredTopCenter = NSPoint(x: centerX, y: topY)

        let frame = panelFrame(for: contentSize, anchor: NSPoint(x: centerX, y: topY), visibleFrame: visibleFrame)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        glassView.frame = NSRect(origin: .zero, size: frame.size)
        containerView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        CATransaction.commit()

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installMonitors()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        lastClosedAt = Date()
        removeMonitors()
        store.stopHoldersAutoRefresh()
        statusItem.button?.highlight(false)
        panel.orderOut(nil)
        anchoredTopCenter = nil
    }

    private func measuredSize() -> NSSize {
        let fit = hostingView.fittingSize
        return NSSize(width: max(296, fit.width), height: max(120, fit.height))
    }

    private func panelFrame(for size: NSSize, anchor: NSPoint, visibleFrame: NSRect) -> NSRect {
        let minX = visibleFrame.minX + 8
        let maxX = max(minX, visibleFrame.maxX - size.width - 8)
        let originX = max(minX, min(anchor.x - size.width / 2, maxX)).rounded()
        let originY = max(visibleFrame.minY + 8, anchor.y - size.height).rounded()
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    private func handleContentSizeChange(_ newSize: NSSize) {
        guard panel.isVisible, let anchor = anchoredTopCenter else { return }
        let width = max(296, newSize.width)
        let height = max(120, newSize.height)
        let current = panel.frame
        guard abs(current.width - width) > 0.5 || abs(current.height - height) > 0.5 else { return }

        let screen = panel.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetFrame = panelFrame(for: NSSize(width: width, height: height), anchor: anchor, visibleFrame: visibleFrame)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(targetFrame, display: true)
        glassView.frame = NSRect(origin: .zero, size: targetFrame.size)
        containerView.frame = NSRect(origin: .zero, size: targetFrame.size)
        hostingView.frame = NSRect(origin: .zero, size: targetFrame.size)
        panel.invalidateShadow()
        CATransaction.commit()
    }

    // MARK: - 关闭监听（点击面板外部 / Esc / 失焦）

    private func installMonitors() {
        removeMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePanel()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closePanel()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }
}

/// 无边框浮动玻璃面板：支持成为 key window（接收悬停与 Esc），但不强夺其他应用激活状态。
private final class FloatingGlassPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 296, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        acceptsMouseMovedEvents = true
        isFloatingPanel = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// 顶部锚定容器（isFlipped = true 使 y=0 永远贴紧面板顶边，展开/收起时不产生居中跳动）。
private final class TopAnchoredContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// 监听 SwiftUI 内容固有尺寸变化（例如合盖二次确认展开/收起），同步面板高度且保持顶部中心锚点不变。
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
