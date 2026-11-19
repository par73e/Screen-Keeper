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

    @Published private(set) var mode: KeepAwakeMode = .off
    @Published private(set) var assertionError: String?
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
    @Published private(set) var clamshellBusy = true
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
    private var ownsClamshellOverride = false
    private var clamshellEnabling = false
    private var clamshellDisabling = false
    private var clamshellDisableRequested = false
    private var terminationReply: ((Bool) -> Void)?
    private var brightnessRestorePending = false
    private var brightnessRestoreInFlight = false
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
        ownsClamshellOverride = d.bool(forKey: Keys.clamshellOn)
        brightnessRestorePending = savedBrightnessBeforeClamshell != nil

        if let cliMode = LaunchOptions.initialMode, cliMode != .off {
            startMode(cliMode, remaining: LaunchOptions.seconds ?? durationChoice)
        } else if restoreOnLaunch,
                  let raw = d.string(forKey: Keys.mode),
                  let restored = KeepAwakeMode(rawValue: raw),
                  restored != .off {
            if let ts = d.object(forKey: Keys.deadline) as? Double {
                let remaining = Date(timeIntervalSince1970: ts).timeIntervalSinceNow
                if remaining > 0 {
                    startMode(restored, remaining: remaining)
                    if mode == restored { deadline = Date(timeIntervalSince1970: ts) }
                } else {
                    persistMode()
                }
            } else {
                startMode(restored, remaining: 0)
            }
        }

        loginItemEnabled = (SMAppService.mainApp.status == .enabled)

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t

        pollPowerSource()

        reconcileClamshellOnLaunch()
    }

    // MARK: - 模式切换

    private func startMode(_ newMode: KeepAwakeMode, remaining: TimeInterval) {
        assertionError = assertions.apply(newMode)
        guard assertionError == nil else { return }
        mode = newMode
        if remaining > 0 {
            deadline = Date().addingTimeInterval(remaining)
            remainingText = Self.formatRemaining(remaining)
        }
        activeDuration = remaining
    }

    func activate(_ newMode: KeepAwakeMode) {
        guard newMode != .off else { deactivate(); return }
        guard terminationReply == nil else { return }
        if mode == .off {
            startMode(newMode, remaining: durationChoice)
        } else {
            assertionError = assertions.apply(newMode)
            if assertionError == nil { mode = newMode }
        }
        guard assertionError == nil else { return }
        persistMode()
        refreshHolders()
    }

    func deactivate() {
        assertionError = assertions.apply(.off)
        mode = .off
        deadline = nil
        remainingText = ""
        activeDuration = 0
        clamshellConfirmNeeded = false
        persistMode()
        refreshHolders()
        if clamshellEnabling || ownsClamshellOverride {
            setClamshellEnabled(false)
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

        if clamshellOn && ownsClamshellOverride && !clamshellLeftover,
           let lidClosed = ClamshellMode.lidClosed {
            if lidClosed {
                lidWasClosedDuringClamshell = true
            } else if lidWasClosedDuringClamshell {
                lidWasClosedDuringClamshell = false
                setClamshellEnabled(false)
            }
        }
        restoreBrightnessIfNeeded(animated: true)

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
        guard mode != .off else { return }
        clamshellConfirmNeeded = true
    }

    func confirmClamshellEnable() {
        clamshellConfirmNeeded = false
        guard mode != .off else { return }
        clamshellWarningSeen = true
        Self.defaults.set(true, forKey: Keys.clamshellWarningSeen)
        setClamshellEnabled(true)
    }

    func cancelClamshellConfirm() {
        clamshellConfirmNeeded = false
    }

    /// AppKit 在等待 terminateLater 时使用 modalPanel 模式，不会消费普通主队列回调。
    private static func deliverClamshellResult(_ callback: @escaping () -> Void) {
        let modes = [RunLoop.Mode.modalPanel.rawValue, RunLoop.Mode.common.rawValue]
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, modes as CFArray, callback)
        CFRunLoopWakeUp(mainRunLoop)
    }

    private func reconcileClamshellOnLaunch() {
        let needsRecovery = ownsClamshellOverride
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var actual = ClamshellMode.sleepDisabled
            var error: String?
            if needsRecovery && actual != false {
                error = ClamshellMode.setEnabled(false, allowPrompt: false)
                actual = ClamshellMode.sleepDisabled
            }
            let passwordless = ClamshellMode.isPasswordlessConfigured
            Self.deliverClamshellResult {
                guard let self else { return }
                self.clamshellPasswordless = passwordless
                self.updateClamshellRecovery(actual: actual, error: error)
                self.restoreBrightnessIfNeeded(animated: false)
                self.clamshellBusy = false
                self.continueClamshellCleanup()
            }
        }
    }

    func setClamshellPasswordless(_ enable: Bool) {
        guard !clamshellBusy, !clamshellPasswordlessBusy, terminationReply == nil else { return }
        clamshellPasswordlessBusy = true
        clamshellError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = enable
                ? ClamshellMode.installPasswordlessRule()
                : ClamshellMode.removePasswordlessRule()
            let actual = ClamshellMode.isPasswordlessConfigured
            Self.deliverClamshellResult {
                guard let self else { return }
                self.clamshellPasswordlessBusy = false
                self.clamshellPasswordless = actual
                self.clamshellError = error
                self.continueClamshellCleanup()
            }
        }
    }

    func setClamshellEnabled(_ enable: Bool) {
        if !enable {
            guard !clamshellDisabling else { return }
            clamshellDisableRequested = true
            continueClamshellCleanup()
            return
        }
        guard mode != .off, !clamshellBusy, !clamshellPasswordlessBusy, terminationReply == nil else { return }
        clamshellBusy = true
        clamshellEnabling = true
        clamshellError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let initial = ClamshellMode.sleepDisabled
            var actual = initial
            var error: String?
            if initial == false {
                // 授权尚未完成时也保留记录，覆盖命令成功后进程立即退出的情况。
                Self.defaults.set(true, forKey: Keys.clamshellOn)
                if Self.defaults.synchronize() {
                    error = ClamshellMode.setEnabled(true)
                    actual = ClamshellMode.sleepDisabled
                } else {
                    error = "无法保存睡眠恢复记录"
                }
            } else if initial == nil {
                error = "无法读取系统睡眠设置，请重试"
            }
            let passwordless = ClamshellMode.isPasswordlessConfigured
            Self.deliverClamshellResult {
                guard let self else { return }
                self.clamshellEnabling = false
                self.clamshellPasswordless = passwordless
                self.ownsClamshellOverride = Self.defaults.bool(forKey: Keys.clamshellOn)
                let canContinue = initial == false && actual == true && error == nil
                    && !self.clamshellDisableRequested && self.terminationReply == nil && self.mode != .off
                if canContinue {
                    self.clamshellOn = true
                    self.clamshellLeftover = false
                    self.beginClamshellBrightnessAndLidTracking()
                } else {
                    self.updateClamshellRecovery(actual: actual, error: error ?? (actual == false && initial == false
                        ? "系统未开启合盖不睡眠，请重试" : nil))
                    if initial == false && self.ownsClamshellOverride {
                        self.clamshellDisableRequested = true
                    } else if initial == true && !self.ownsClamshellOverride {
                        // 此次开启并未修改系统，撤销不影响其他应用的设置。
                        self.clamshellDisableRequested = false
                    }
                }
                self.clamshellBusy = false
                self.continueClamshellCleanup()
            }
        }
    }

    private func continueClamshellCleanup() {
        guard !clamshellBusy, !clamshellPasswordlessBusy else { return }
        if clamshellDisableRequested || (terminationReply != nil && ownsClamshellOverride) {
            clamshellDisableRequested = false
            if clamshellOn || ownsClamshellOverride {
                disableClamshell()
                return
            }
        }
        finishTermination(allow: true)
    }

    private func disableClamshell() {
        clamshellBusy = true
        clamshellDisabling = true
        clamshellError = nil
        lidWasClosedDuringClamshell = false
        cancelClamshellDimTimer()
        queueBrightnessRestore()
        restoreBrightnessIfNeeded(animated: terminationReply == nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var actual = ClamshellMode.sleepDisabled
            var error: String?
            if actual != false {
                error = ClamshellMode.setEnabled(false)
                actual = ClamshellMode.sleepDisabled
            }
            let passwordless = ClamshellMode.isPasswordlessConfigured
            Self.deliverClamshellResult {
                guard let self else { return }
                self.clamshellDisabling = false
                self.clamshellPasswordless = passwordless
                self.updateClamshellRecovery(actual: actual, error: error ?? (actual == true ? "系统仍禁止睡眠，请重试" : nil))
                self.clamshellBusy = false
                self.finishTermination(allow: actual == false || !self.ownsClamshellOverride)
            }
        }
    }

    /// 读取成功且系统确认恢复后，才删除本 App 的恢复记录。
    private func updateClamshellRecovery(actual: Bool?, error: String?) {
        if let actual { clamshellOn = actual }
        if actual == false {
            ownsClamshellOverride = false
            Self.defaults.removeObject(forKey: Keys.clamshellOn)
        }
        clamshellLeftover = clamshellOn || ownsClamshellOverride
        clamshellError = error ?? (actual == nil ? "无法确认系统睡眠状态，请重试恢复" : nil)
    }

    private func beginClamshellBrightnessAndLidTracking() {
        lidWasClosedDuringClamshell = ClamshellMode.lidClosed == true
        startClamshellDimCountdown()
    }

    private func startClamshellDimCountdown() {
        cancelClamshellDimTimer()
        clamshellDimCountdown = 3
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let next = (self.clamshellDimCountdown ?? 1) - 1
            if next > 0 {
                self.clamshellDimCountdown = next
                return
            }
            self.cancelClamshellDimTimer()
            guard !self.brightnessRestorePending, let current = DisplayBrightness.current(), current > 0.10 else { return }
            self.savedBrightnessBeforeClamshell = current
            Self.defaults.set(Double(current), forKey: Keys.savedBrightnessBeforeClamshell)
            guard Self.defaults.synchronize() else { return }
            DisplayBrightness.animate(to: 0.10, duration: 0.45)
        }
        RunLoop.main.add(timer, forMode: .common)
        clamshellDimTimer = timer
    }

    private func cancelClamshellDimTimer() {
        clamshellDimTimer?.invalidate()
        clamshellDimTimer = nil
        clamshellDimCountdown = nil
    }

    private func queueBrightnessRestore() {
        guard !brightnessRestorePending, savedBrightnessBeforeClamshell != nil else { return }
        DisplayBrightness.cancelAnimation()
        brightnessRestorePending = true
    }

    private func restoreBrightnessIfNeeded(animated: Bool) {
        guard brightnessRestorePending, !brightnessRestoreInFlight,
              let saved = savedBrightnessBeforeClamshell, let current = DisplayBrightness.current() else { return }
        let target = max(saved, current)
        brightnessRestoreInFlight = true
        let complete: (Bool) -> Void = { [weak self] applied in
            guard let self else { return }
            self.brightnessRestoreInFlight = false
            guard applied, let verified = DisplayBrightness.current(), verified + 0.02 >= saved else { return }
            self.brightnessRestorePending = false
            self.savedBrightnessBeforeClamshell = nil
            Self.defaults.removeObject(forKey: Keys.savedBrightnessBeforeClamshell)
        }
        if current >= saved {
            complete(true)
        } else if animated {
            DisplayBrightness.animate(to: target, duration: 0.55, completion: complete)
        } else {
            complete(DisplayBrightness.set(target))
        }
    }

    /// 返回 true 时由 AppKit 等待异步清理结果，确保在途的开启命令也有机会撤销。
    func prepareForTermination(reply: @escaping (Bool) -> Void) -> Bool {
        if terminationReply != nil { return true }
        cancelClamshellDimTimer()
        queueBrightnessRestore()
        if brightnessRestoreInFlight {
            DisplayBrightness.cancelAnimation()
            brightnessRestoreInFlight = false
        }
        restoreBrightnessIfNeeded(animated: false)
        guard clamshellBusy || clamshellPasswordlessBusy || ownsClamshellOverride else { return false }
        terminationReply = reply
        continueClamshellCleanup()
        return true
    }

    private func finishTermination(allow: Bool) {
        guard let reply = terminationReply else { return }
        terminationReply = nil
        reply(allow)
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
