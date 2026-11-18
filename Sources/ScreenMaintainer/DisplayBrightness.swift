import Foundation
import CoreGraphics

/// 控制 Mac 内置屏幕亮度（通过 macOS DisplayServices 私有框架）：
/// - 专用于合盖不睡眠期间自动压低功耗与发热（3 秒后降到 10%），并在开盖或关闭时自动平滑恢复。
enum DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool

    private static let symbols: (get: GetFn, set: SetFn, can: CanFn?)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let getPtr = dlsym(handle, "DisplayServicesGetBrightness"),
              let setPtr = dlsym(handle, "DisplayServicesSetBrightness") else {
            return nil
        }
        let getFn = unsafeBitCast(getPtr, to: GetFn.self)
        let setFn = unsafeBitCast(setPtr, to: SetFn.self)
        let canFn = dlsym(handle, "DisplayServicesCanChangeBrightness")
            .map { unsafeBitCast($0, to: CanFn.self) }
        return (getFn, setFn, canFn)
    }()

    private static var animationTimer: Timer?

    /// 查找内置屏幕 DisplayID（合盖/外接屏场景优先找内置屏，避免误调不支持硬件亮度的外接显示器）
    private static func builtinDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            let main = CGMainDisplayID()
            return CGDisplayIsBuiltin(main) != 0 ? main : nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return nil
        }
        if let builtin = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            return builtin
        }
        return nil
    }

    static func current() -> Float? {
        guard let syms = symbols, let id = builtinDisplayID() else { return nil }
        if let can = syms.can, !can(id) { return nil }
        var value: Float = -1
        guard syms.get(id, &value) == 0, value >= 0 else { return nil }
        return min(1, max(0, value))
    }

    static func set(_ value: Float) {
        cancelAnimation()
        applyImmediate(value)
    }

    static func cancelAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    /// 平滑过渡到目标亮度（必须在主线程调用）
    static func animate(to target: Float, duration: TimeInterval = 0.55) {
        cancelAnimation()
        let clampedTarget = min(1, max(0, target))
        guard let start = current() else {
            applyImmediate(clampedTarget)
            return
        }
        if abs(start - clampedTarget) < 0.01 {
            applyImmediate(clampedTarget)
            return
        }

        let steps = max(1, Int((duration / 0.025).rounded()))
        var step = 0
        let timer = Timer(timeInterval: 0.025, repeats: true) { t in
            step += 1
            let progress = min(1.0, Float(step) / Float(steps))
            // easeOutCubic 让亮度升降手感更接近系统调节
            let eased = 1 - pow(1 - progress, 3)
            let value = start + (clampedTarget - start) * eased
            applyImmediate(value)
            if step >= steps {
                t.invalidate()
                if animationTimer === t {
                    animationTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private static func applyImmediate(_ value: Float) {
        guard let syms = symbols, let id = builtinDisplayID() else { return }
        if let can = syms.can, !can(id) { return }
        _ = syms.set(id, min(1, max(0, value)))
    }
}
