import AppKit

/// 手绘菜单栏图标：屏幕造型 + 水位隐喻。
/// - off：灰色屏幕（描边 + 淡填充），默认态
/// - active + 不限：屏幕中心全亮
/// - active + 倒计时：白色亮块像水位一样自顶向下退去（亮块高度 = 剩余时间比例）
/// - clamshell：合上的笔记本
/// 配色跟随系统深浅色外观，在液态玻璃菜单栏任意壁纸下清晰。
enum MenuBarIcon {
    enum State: String {
        case off
        case active     // 两个唤醒档共用同一水位外观
        case clamshell
    }

    private static var cache: [String: NSImage] = [:]
    // 比常规菜单栏图标略小一圈，融入用户的图标排布
    private static let size = NSSize(width: 20, height: 16)

    /// level: 0...1 水位（剩余比例），1 = 全亮。按 2% 量化缓存。
    static func image(for state: State, dark: Bool, level: Double = 1) -> NSImage {
        let bucket = Int((min(1, max(0, level)) * 50).rounded())
        let key = "\(state.rawValue)-\(dark)-\(bucket)"
        if let hit = cache[key] { return hit }
        let image = NSImage(size: size, flipped: false) { rect in
            switch state {
            case .off:       drawScreen(in: rect, level: nil, dark: dark)
            case .active:    drawScreen(in: rect, level: min(1, max(0, level)), dark: dark)
            case .clamshell: drawClosedLid(in: rect, dark: dark)
            }
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }

    private static func primary(dark: Bool) -> NSColor {
        dark ? NSColor.white : NSColor.black.withAlphaComponent(0.88)
    }

    private static func drawScreen(in rect: NSRect, level: Double?, dark: Bool) {
        let c = primary(dark: dark)
        let screen = NSRect(x: 1.5, y: 4.6, width: rect.width - 3, height: rect.height - 5.6)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: 2.4, yRadius: 2.4)
        let innerRect = screen.insetBy(dx: 1.4, dy: 1.4)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 1.4, yRadius: 1.4)

        // 支架
        let standColor = c.withAlphaComponent(0.75)
        let neck = NSBezierPath(roundedRect: NSRect(x: rect.midX - 1.2, y: 2.4, width: 2.4, height: 2.4),
                                xRadius: 0.6, yRadius: 0.6)
        let base = NSBezierPath(roundedRect: NSRect(x: rect.midX - 4.6, y: 1.0, width: 9.2, height: 1.7),
                                xRadius: 0.85, yRadius: 0.85)
        standColor.setFill()
        neck.fill()
        base.fill()

        if let level {
            // 激活：深色屏底 + 白色水位（底部锚定，顶边随剩余时间下降）
            NSColor(white: 0.12, alpha: 0.78).setFill()
            innerPath.fill()
            if level > 0.001 {
                NSGraphicsContext.current?.saveGraphicsState()
                innerPath.addClip()
                let water = NSRect(x: innerRect.minX,
                                   y: innerRect.minY,
                                   width: innerRect.width,
                                   height: innerRect.height * CGFloat(level))
                NSColor.white.setFill()
                NSBezierPath(rect: water).fill()
                NSGraphicsContext.current?.restoreGraphicsState()
            }
        } else {
            // 关闭：灰色屏幕
            c.withAlphaComponent(dark ? 0.35 : 0.32).setFill()
            innerPath.fill()
        }

        screenPath.lineWidth = 1.5
        c.setStroke()
        screenPath.stroke()
    }

    /// 合盖模式：合上的笔记本（横向薄板 + 中缝 + 顶部凹槽）
    private static func drawClosedLid(in rect: NSRect, dark: Bool) {
        let c = primary(dark: dark)
        let slab = NSRect(x: 1.5, y: rect.midY - 2.4, width: rect.width - 3, height: 4.8)
        let path = NSBezierPath(roundedRect: slab, xRadius: 2, yRadius: 2)
        c.withAlphaComponent(0.9).setFill()
        path.fill()

        let seam = NSRect(x: slab.minX + 1.2, y: rect.midY - 0.4, width: slab.width - 2.4, height: 0.8)
        (dark ? NSColor.black : NSColor.white).setFill()
        NSBezierPath(roundedRect: seam, xRadius: 0.4, yRadius: 0.4).fill()

        let groove = NSRect(x: rect.midX - 2.0, y: slab.maxY - 1.0, width: 4.0, height: 0.7)
        (dark ? NSColor.black : NSColor.white).withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: groove, xRadius: 0.35, yRadius: 0.35).fill()
    }
}
