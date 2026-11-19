import Foundation
import IOKit.pwr_mgt

/// 断言绑定进程生命周期，退出或崩溃时由系统释放。
final class PowerAssertions {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    /// 切换失败时保留原有断言，避免界面和实际行为分离。
    func apply(_ mode: KeepAwakeMode) -> String? {
        if mode == .off {
            release(&displayAssertion)
            release(&systemAssertion)
            return nil
        }

        let needsDisplay = mode == .displayAwake
        let reason = needsDisplay
            ? "ScreenMaintainer: keep display and system awake"
            : "ScreenMaintainer: keep system awake for background agents/tasks (display may sleep)"
        let needsSystemAssertion = systemAssertion == 0
        if needsSystemAssertion {
            let status = create(kIOPMAssertionTypePreventUserIdleSystemSleep, reason, &systemAssertion)
            guard status == kIOReturnSuccess else { return "无法保持系统唤醒（\(status)）" }
        }
        if needsDisplay && displayAssertion == 0 {
            let status = create(kIOPMAssertionTypePreventUserIdleDisplaySleep, reason, &displayAssertion)
            guard status == kIOReturnSuccess else {
                if needsSystemAssertion { release(&systemAssertion) }
                return "无法保持屏幕常亮（\(status)）"
            }
        } else if !needsDisplay {
            release(&displayAssertion)
        }
        return nil
    }

    private func create(_ type: String, _ reason: String, _ assertion: inout IOPMAssertionID) -> IOReturn {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               reason as CFString, &id)
        if status == kIOReturnSuccess { assertion = id }
        return status
    }

    private func release(_ assertion: inout IOPMAssertionID) {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }
}
