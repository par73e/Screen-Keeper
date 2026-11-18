import Foundation
import Combine
import AppKit
import ServiceManagement

enum KeepAwakeMode: String, CaseIterable {
    case off          // 关闭，恢复系统默认行为
    case systemAwake  // 防系统睡眠（屏幕可正常熄灭），Agent/后台任务不中断
    case displayAwake // 防息屏 + 防系统睡眠
}

/// 全部状态与业务逻辑。所有可变状态只在主线程访问；
/// 阻塞操作（pmset / osascript）一律丢到后台队列。
final class PowerStore: ObservableObject {
    static let shared = PowerStore()

    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let mode = "mode"
        static let deadline = "deadline"
        static let duration = "durationChoice"
        static let autoOffOnUnplug = "autoOffOnUnplug"
        static let restoreOnLaunch = "restoreOnLaunch"
        static let clamshellOn = "clamshellOn"
        static let clamshellWarningSeen = "clamshellWarningSeen"
        static let savedBrightnessBeforeClamshell = "savedBrightnessBeforeClamshell"
    }

    // MARK: - 发布状态

    @Published var mode: KeepAwakeMode = .off
    @Published var deadline: Date? = nil
    @Published var remainingText = ""
    /// 本次激活的总时长（水位动画的分母）
    @Published var activeDuration: TimeInterval = 0

    /// 自动关闭时长；0 = 不限（直到手动关闭）
    @Published var durationChoice: TimeInterval = 4 * 3600 {
        didSet {
            Self.defaults.set(durationChoice, forKey: Keys.duration)
            guard mode != .off else { return }
            if durationChoice > 0 {
                deadline = Date().addingTimeInterval(durationChoice)
                remainingText = Self.formatRemaining(durationChoice)
            } else {
                deadline = nil
                remainingText = ""
            }
            activeDuration = durationChoice
            persistMode()
        }
    }

    @Published var autoOffOnUnplug = true {
        didSet { Self.defaults.set(autoOffOnUnplug, forKey: Keys.autoOffOnUnplug) }
    }
    @Published var restoreOnLaunch = true {
        didSet { Self.defaults.set(restoreOnLaunch, forKey: Keys.restoreOnLaunch) }
    }

    @Published var onACPower = true
    @Published var powerSummary = "…"

    @Published var holders: [AssertionHolder] = []
    @Published var holdersSummaryText = "…"

    @Published var clamshellOn = false
    @Published var clamshellBusy = false
    @Published var clamshellError: String? = nil
    @Published var clamshellConfirmNeeded = false
    @Published var clamshellLeftover = false
    @Published var clamshellWarningSeen = false
    @Published var clamshellDimCountdown: Int? = nil
    @Published var clamshellPasswordless = false
    @Published var clamshellPasswordlessBusy = false
    @Published var loginItemEnabled = false

    private let assertions = PowerAssertions()
    private var tickTimer: Timer?
    private var tickCount = 0
    private var clamshellDimTimer: Timer?
    private var lidWasClosedDuringClamshell = false
    private var autoOpenLidRestoreTriggered = false
    private var savedBrightnessBeforeClamshell: Float? = nil

    var iconState: MenuBarIcon.State {
        if clamshellOn { return .clamshell }
        return mode == .off ? .off : .active
    }

    /// 水位（0...1）：剩余时间 / 本次激活总时长；不限时为 1（全亮）
    var waterLevel: Double {
        guard mode != .off else { return 0 }
        guard let dl = deadline, activeDuration > 0 else { return 1 }
        return min(1, max(0, dl.timeIntervalSinceNow / activeDuration))
    }

    // MARK: - 初始化

    private init() {
        let d = Self.defaults
        if let v = d.object(forKey: Keys.duration) as? TimeInterval { durationChoice = v }
        if let v = d.object(forKey: Keys.autoOffOnUnplug) as? Bool { autoOffOnUnplug = v }
        if let v = d.object(forKey: Keys.restoreOnLaunch) as? Bool { restoreOnLaunch = v }
        clamshellWarningSeen = d.bool(forKey: Keys.clamshellWarningSeen)
        if let saved = d.object(forKey: Keys.savedBrightnessBeforeClamshell) as? Double {
            savedBrightnessBeforeClamshell = Float(saved)
        }
        let clamshellIntent = d.bool(forKey: Keys.clamshellOn)

        if let cliMode = LaunchOptions.initialMode, cliMode != .off {
            // CLI 测试路径：不写 UserDefaults，不污染用户设置
            mode = cliMode
            let dur = LaunchOptions.seconds ?? durationChoice
            if dur > 0 {
                deadline = Date().addingTimeInterval(dur)
                remainingText = Self.formatRemaining(dur)
            }
            activeDuration = dur
            applyAssertions()
        } else if restoreOnLaunch,
                  let raw = d.string(forKey: Keys.mode),
                  let restored = KeepAwakeMode(rawValue: raw),
                  restored != .off {
            if let ts = d.object(forKey: Keys.deadline) as? Double {
                let dl = Date(timeIntervalSince1970: ts)
                if dl > Date() {
                    mode = restored
                    deadline = dl
                    remainingText = Self.formatRemaining(dl.timeIntervalSinceNow)
                    activeDuration = dl.timeIntervalSinceNow
                    applyAssertions()
                } else {
                    persistMode() // 定时在关机期间已过期 → 保持关闭
                }
            } else {
                mode = restored
                applyAssertions()
            }
        }

        loginItemEnabled = (SMAppService.mainApp.status == .enabled)

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t

        pollPowerSource()

        // 同步「合盖不睡眠」的系统真实状态与免密状态；若有异常退出残留且已配置免密，则静默还原
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var actual = ClamshellMode.isSleepDisabled
            let passwordless = ClamshellMode.isPasswordlessConfigured
            var leftover = actual && !clamshellIntent
            if leftover && passwordless {
                _ = ClamshellMode.setEnabled(false)
                actual = ClamshellMode.isSleepDisabled
                leftover = false
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.clamshellOn = actual
                self.clamshellPasswordless = passwordless
                self.clamshellLeftover = leftover
                if actual != clamshellIntent {
                    Self.defaults.set(actual, forKey: Keys.clamshellOn)
                }
                if actual {
                    self.lidWasClosedDuringClamshell = ClamshellMode.isLidClosed
                } else if self.savedBrightnessBeforeClamshell != nil {
                    self.restoreBrightnessAfterClamshell(animated: false)
                }
            }
        }
    }

    // MARK: - 模式切换

    func activate(_ newMode: KeepAwakeMode) {
        guard newMode != .off else { deactivate(); return }
        let wasOff = (mode == .off)
        mode = newMode
        if wasOff {
            if durationChoice > 0 {
                deadline = Date().addingTimeInterval(durationChoice)
                remainingText = Self.formatRemaining(durationChoice)
            } else {
                deadline = nil
                remainingText = ""
            }
            activeDuration = durationChoice
        }
        applyAssertions()
        persistMode()
        refreshHolders()
    }

    func deactivate() {
        mode = .off
        deadline = nil
        remainingText = ""
        activeDuration = 0
        applyAssertions()
        persistMode()
        refreshHolders()
    }

    private func applyAssertions() {
        assertions.releaseAll()
        switch mode {
        case .off:
            break
        case .systemAwake:
            assertions.preventSystemSleep(
                reason: "ScreenMaintainer: keep system awake for background agents/tasks (display may sleep)")
        case .displayAwake:
            assertions.preventDisplaySleep(
                reason: "ScreenMaintainer: keep display and system awake")
        }
    }

    private func persistMode() {
        Self.defaults.set(mode.rawValue, forKey: Keys.mode)
        if let dl = deadline {
            Self.defaults.set(dl.timeIntervalSince1970, forKey: Keys.deadline)
        } else {
            Self.defaults.removeObject(forKey: Keys.deadline)
        }
    }

    // MARK: - 定时 / 电源轮询

    private func tick() {
        if let dl = deadline {
            let remaining = dl.timeIntervalSinceNow
            if remaining <= 0 {
                deactivate()
            } else {
                remainingText = Self.formatRemaining(remaining)
            }
        }

        if clamshellOn {
            let lidClosed = ClamshellMode.isLidClosed
            if lidClosed {
                lidWasClosedDuringClamshell = true
            } else if lidWasClosedDuringClamshell && !autoOpenLidRestoreTriggered {
                // 检测到「合盖 -> 开盖」：立即自动抬回原亮度，并触发自动关闭合盖保持运行
                autoOpenLidRestoreTriggered = true
                lidWasClosedDuringClamshell = false
                cancelClamshellDimTimer()
                restoreBrightnessAfterClamshell(animated: true)
                if !clamshellBusy {
                    setClamshellEnabled(false)
                }
            }
        }

        tickCount += 1
        if tickCount % 10 == 0 {
            pollPowerSource()
        }
    }

    private func checkUnplug() {
        if autoOffOnUnplug && mode != .off && !onACPower {
            deactivate()
        }
    }

    func pollPowerSource() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = ProcessRunner.run("/usr/bin/pmset", ["-g", "batt"]).stdout
            let parsed = PowerStore.parseBattery(out)
            DispatchQueue.main.async {
                guard let self else { return }
                self.powerSummary = parsed.summary
                self.onACPower = parsed.onAC
                self.checkUnplug()
            }
        }
    }

    func refreshHolders() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = AssertionReader.currentHolders()
            let summary = AssertionReader.summarize(list)
            DispatchQueue.main.async {
                guard let self else { return }
                self.holders = list
                self.holdersSummaryText = summary
            }
        }
    }

    /// 面板打开期间每 15 秒刷新一次"谁在阻止睡眠"
    private var holdersRefreshTimer: Timer?

    func startHoldersAutoRefresh() {
        guard holdersRefreshTimer == nil else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshHolders()
        }
        RunLoop.main.add(t, forMode: .common)
        holdersRefreshTimer = t
    }

    func stopHoldersAutoRefresh() {
        holdersRefreshTimer?.invalidate()
        holdersRefreshTimer = nil
    }

    // MARK: - 合盖不睡眠（系统级 disablesleep，带护栏）

    func requestClamshellEnable() {
        clamshellConfirmNeeded = true
    }

    func confirmClamshellEnable() {
        clamshellConfirmNeeded = false
        clamshellWarningSeen = true
        Self.defaults.set(true, forKey: Keys.clamshellWarningSeen)
        setClamshellEnabled(true)
    }

    func cancelClamshellConfirm() {
        clamshellConfirmNeeded = false
    }

    func setClamshellPasswordless(_ enable: Bool) {
        guard !clamshellPasswordlessBusy else { return }
        clamshellPasswordlessBusy = true
        clamshellError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = enable
                ? ClamshellMode.installPasswordlessRule()
                : ClamshellMode.removePasswordlessRule()
            let actual = ClamshellMode.isPasswordlessConfigured
            DispatchQueue.main.async {
                guard let self else { return }
                self.clamshellPasswordlessBusy = false
                self.clamshellPasswordless = actual
                if let err {
                    self.clamshellError = err
                }
            }
        }
    }

    func setClamshellEnabled(_ enable: Bool) {
        guard !clamshellBusy else { return }
        clamshellBusy = true
        clamshellError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = ClamshellMode.setEnabled(enable)
            let actual = ClamshellMode.isSleepDisabled
            let passwordless = ClamshellMode.isPasswordlessConfigured
            DispatchQueue.main.async {
                guard let self else { return }
                self.clamshellBusy = false
                self.clamshellError = err
                self.clamshellOn = actual
                self.clamshellPasswordless = passwordless
                if actual {
                    self.clamshellLeftover = false
                    if enable && err == nil {
                        self.beginClamshellBrightnessAndLidTracking()
                    }
                } else {
                    self.cancelClamshellDimTimer()
                    self.lidWasClosedDuringClamshell = false
                    self.autoOpenLidRestoreTriggered = false
                    self.restoreBrightnessAfterClamshell(animated: true)
                }
                Self.defaults.set(actual, forKey: Keys.clamshellOn)
            }
        }
    }

    private func beginClamshellBrightnessAndLidTracking() {
        if savedBrightnessBeforeClamshell == nil, let current = DisplayBrightness.current() {
            savedBrightnessBeforeClamshell = current
            Self.defaults.set(Double(current), forKey: Keys.savedBrightnessBeforeClamshell)
        }
        lidWasClosedDuringClamshell = ClamshellMode.isLidClosed
        autoOpenLidRestoreTriggered = false
        startClamshellDimCountdown()
    }

    private func startClamshellDimCountdown() {
        cancelClamshellDimTimer()
        clamshellDimCountdown = 3
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard self.clamshellOn else {
                self.cancelClamshellDimTimer()
                return
            }
            let next = (self.clamshellDimCountdown ?? 1) - 1
            if next > 0 {
                self.clamshellDimCountdown = next
            } else {
                self.cancelClamshellDimTimer()
                let current = DisplayBrightness.current() ?? 1.0
                let target: Float = min(current, 0.10)
                DisplayBrightness.animate(to: target, duration: 0.45)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clamshellDimTimer = timer
    }

    private func cancelClamshellDimTimer() {
        clamshellDimTimer?.invalidate()
        clamshellDimTimer = nil
        clamshellDimCountdown = nil
    }

    private func restoreBrightnessAfterClamshell(animated: Bool) {
        guard let saved = savedBrightnessBeforeClamshell else { return }
        savedBrightnessBeforeClamshell = nil
        Self.defaults.removeObject(forKey: Keys.savedBrightnessBeforeClamshell)

        let target = max(saved, DisplayBrightness.current() ?? saved)
        if animated {
            DisplayBrightness.animate(to: target, duration: 0.55)
            // 开盖唤醒瞬间内置屏可能延迟 ~0.5s 才重新上电，二次兜底确保亮度确实抬起
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                guard let self, !self.clamshellOn || self.autoOpenLidRestoreTriggered else { return }
                if let cur = DisplayBrightness.current(), cur + 0.03 < target {
                    DisplayBrightness.animate(to: target, duration: 0.35)
                }
            }
        } else {
            DisplayBrightness.set(target)
        }
    }

    /// App 退出时调用：若「合盖不睡眠」处于开启状态，自动还原亮度与系统默认。
    /// 授权弹窗由 SecurityAgent（独立进程）渲染，因此可以在退出流程中同步等待。
    func handleAppTermination() {
        cancelClamshellDimTimer()
        if let saved = savedBrightnessBeforeClamshell {
            savedBrightnessBeforeClamshell = nil
            Self.defaults.removeObject(forKey: Keys.savedBrightnessBeforeClamshell)
            DisplayBrightness.set(max(saved, DisplayBrightness.current() ?? saved))
        }
        let intent = Self.defaults.bool(forKey: Keys.clamshellOn)
        Self.defaults.set(false, forKey: Keys.clamshellOn)
        if intent && ClamshellMode.isSleepDisabled {
            ClamshellMode.setEnabled(false)
        }
    }

    // MARK: - 登录项

    func setLoginItem(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 失败原因（未打包运行等）直接反映在 status 上
        }
        loginItemEnabled = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: - 工具

    static func formatRemaining(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        if total >= 3600 { return String(format: "%d小时%02d分", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return String(format: "%d分%02d秒", total / 60, total % 60) }
        return "\(total)秒"
    }

    static func parseBattery(_ out: String) -> (summary: String, onAC: Bool) {
        let onAC = out.contains("'AC Power'")
        var summary: String
        if out.contains("'Off Line'") {
            summary = "离线供电"
        } else {
            summary = onAC ? "已插电" : "电池供电"
        }
        if let r = out.range(of: "(\\d+)%", options: .regularExpression) {
            let pct = out[r].dropLast(1)
            summary = onAC ? "已插电 · \(pct)%" : "电池 \(pct)%"
        }
        return (summary, onAC)
    }
}
