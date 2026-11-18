import Foundation
import IOKit.pwr_mgt

/// 基于 IOKit 官方电源断言（power assertion）机制，与系统自带 `caffeinate` 同源。
///
/// 关键性质（本 App 的"失败安全"基石）：
/// 断言绑定进程生命周期 —— App 退出或崩溃时断言由系统自动释放，
/// 绝不会像修改 `pmset` 设置那样留下需要手动还原的残留。
final class PowerAssertions {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    /// 阻止系统闲置睡眠（屏幕仍可正常熄灭，后台任务继续跑）。
    func preventSystemSleep(reason: String) {
        guard systemAssertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if status == kIOReturnSuccess {
            systemAssertion = id
        }
    }

    /// 阻止息屏（同时持有系统断言：屏幕常亮自然意味着系统不睡）。
    func preventDisplaySleep(reason: String) {
        guard displayAssertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if status == kIOReturnSuccess {
            displayAssertion = id
        }
        preventSystemSleep(reason: reason)
    }

    func releaseAll() {
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
    }
}
