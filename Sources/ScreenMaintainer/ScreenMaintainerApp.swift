import SwiftUI
import AppKit

/// 命令行调试入口：
///   --dump-assertions                 打印当前解析到的"阻止睡眠的进程"后退出
///   --activate <mode> [--seconds N]   以指定模式启动（systemAwake|displayAwake）
enum LaunchOptions {
    static let dumpAssertions = CommandLine.arguments.contains("--dump-assertions")

    static let initialMode: KeepAwakeMode? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--activate"),
              i + 1 < CommandLine.arguments.count else { return nil }
        return KeepAwakeMode(rawValue: CommandLine.arguments[i + 1])
    }()

    static let seconds: TimeInterval? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--seconds"),
              i + 1 < CommandLine.arguments.count,
              let v = Double(CommandLine.arguments[i + 1]) else { return nil }
        return v
    }()
}

@main
struct ScreenMaintainerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if LaunchOptions.dumpAssertions {
            for line in AssertionReader.dumpLines() { print(line) }
            exit(0)
        }
        // 调试：--dump-strip <dark|light> <out.png>
        // 用生产渲染代码输出整排图标：off / 全亮 / 66% / 33% / 合盖
        if let i = CommandLine.arguments.firstIndex(of: "--dump-strip"),
           i + 2 < CommandLine.arguments.count {
            let dark = CommandLine.arguments[i + 1] == "dark"
            let specs: [(MenuBarIcon.State, Double)] = [
                (.off, 0), (.active, 1), (.active, 0.66), (.active, 0.33), (.clamshell, 0),
            ]
            let scale: CGFloat = 5
            let itemW: CGFloat = 22 * scale
            let gap: CGFloat = 14
            let total = NSSize(width: itemW * CGFloat(specs.count) + gap * CGFloat(specs.count - 1),
                               height: 18 * scale)
            let strip = NSImage(size: total)
            strip.lockFocus()
            NSColor(white: dark ? 0.22 : 0.75, alpha: 1).setFill()  // 模拟菜单栏底色
            NSBezierPath(rect: NSRect(origin: .zero, size: total)).fill()
            for (idx, spec) in specs.enumerated() {
                let img = MenuBarIcon.image(for: spec.0, dark: dark, level: spec.1)
                let x = CGFloat(idx) * (itemW + gap)
                img.draw(in: NSRect(x: x, y: 0, width: itemW, height: total.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
            }
            strip.unlockFocus()
            if let tiff = strip.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
            }
            exit(0)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(store: PowerStore.shared)
    }

    func applicationWillTerminate(_ notification: Notification) {
        PowerStore.shared.handleAppTermination()
    }
}
