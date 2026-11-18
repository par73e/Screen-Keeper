import Foundation
import IOKit

/// 「合盖不睡眠」= 系统级设置 `pmset -a disablesleep`。
///
/// 采用极简免密机制：
///   - 优先通过 `/etc/sudoers.d/screenmaintainer` 精确白名单免密执行 `pmset -a disablesleep 0/1`
///   - 首次开启若尚未配置白名单，在同一次管理员授权弹窗中顺带完成白名单安装与开启；之后开关及开盖自动关闭均免输密码
enum ClamshellMode {
    private static let pmsetPath = "/usr/bin/pmset"
    private static let sudoersPath = "/etc/sudoers.d/screenmaintainer"

    /// 读取当前合盖物理状态（AppleClamshellState）；true = 笔记本已合盖。
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool else {
            return false
        }
        return prop
    }

    /// 读取当前系统 SleepDisabled 标志（只读，无需授权）。
    static var isSleepDisabled: Bool {
        let out = ProcessRunner.run(pmsetPath, ["-g"]).stdout
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("SleepDisabled") else { continue }
            let parts = t.split(whereSeparator: \.isWhitespace)
            if let last = parts.last {
                return last == "1"
            }
        }
        return false
    }

    /// 检查当前用户是否已配置免密执行 `pmset -a disablesleep 0/1`。
    static var isPasswordlessConfigured: Bool {
        let canDisable = ProcessRunner.run("/usr/bin/sudo", ["-n", "-l", pmsetPath, "-a", "disablesleep", "0"]).exitCode == 0
        let canEnable = ProcessRunner.run("/usr/bin/sudo", ["-n", "-l", pmsetPath, "-a", "disablesleep", "1"]).exitCode == 0
        return canDisable && canEnable
    }

    /// 设置 disablesleep：优先免密 `sudo -n`；未配置时弹一次管理员框（开启时顺带安装免密白名单）。
    @discardableResult
    static func setEnabled(_ enable: Bool) -> String? {
        let value = enable ? 1 : 0
        let sudoResult = ProcessRunner.run("/usr/bin/sudo", ["-n", pmsetPath, "-a", "disablesleep", "\(value)"])
        if sudoResult.exitCode == 0 {
            return nil
        }

        if enable, let result = enableAndInstallPasswordless() {
            switch result {
            case .success:
                return nil
            case .failure(let message):
                return message
            }
        }

        let script = "do shell script \"\(pmsetPath) -a disablesleep \(value)\" with administrator privileges"
        let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script])
        if result.exitCode == 0 {
            return nil
        }
        let msg = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("(-128)") {
            return "已取消管理员授权"
        }
        return msg.isEmpty ? "设置失败（exit \(result.exitCode)）" : msg
    }

    private enum CombinedInstallResult {
        case success
        case failure(String)
    }

    /// 一次管理员授权同时完成：校验并安装 sudoers 白名单 + 开启 disablesleep 1。
    /// 若前置校验无法进行则返回 nil，交由常规单次弹窗路径处理。
    private static func enableAndInstallPasswordless() -> CombinedInstallResult? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return nil
        }

        let rule = "\(user) ALL=(root) NOPASSWD: \(pmsetPath) -a disablesleep 0, \(pmsetPath) -a disablesleep 1\n"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenmaintainer-sudoers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try rule.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        let check = ProcessRunner.run("/usr/sbin/visudo", ["-cf", tmpURL.path])
        guard check.exitCode == 0 else { return nil }

        let escapedTmp = tmpURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "/usr/sbin/visudo -cf '\(escapedTmp)' && /usr/bin/install -o root -g wheel -m 0440 '\(escapedTmp)' '\(sudoersPath)' && \(pmsetPath) -a disablesleep 1"
        let appleScriptCmd = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptCmd)\" with administrator privileges"
        let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script])
        if result.exitCode == 0 {
            return .success
        }
        let msg = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("(-128)") {
            return .failure("已取消管理员授权")
        }
        return .failure(msg.isEmpty ? "设置失败（exit \(result.exitCode)）" : msg)
    }

    /// 单独写入 `/etc/sudoers.d/screenmaintainer`，仅精确放行 `disablesleep 0/1`。
    static func installPasswordlessRule() -> String? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return "用户名格式不支持自动配置"
        }

        let rule = "\(user) ALL=(root) NOPASSWD: \(pmsetPath) -a disablesleep 0, \(pmsetPath) -a disablesleep 1\n"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenmaintainer-sudoers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try rule.write(to: tmpURL, atomically: true, encoding: .utf8)
        } catch {
            return "写入临时规则失败：\(error.localizedDescription)"
        }

        let check = ProcessRunner.run("/usr/sbin/visudo", ["-cf", tmpURL.path])
        guard check.exitCode == 0 else { return "sudoers 语法校验失败" }

        let escapedTmp = tmpURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "/usr/sbin/visudo -cf '\(escapedTmp)' && /usr/bin/install -o root -g wheel -m 0440 '\(escapedTmp)' '\(sudoersPath)'"
        let appleScriptCmd = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptCmd)\" with administrator privileges"
        let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script])
        if result.exitCode == 0 {
            return nil
        }
        let msg = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("(-128)") {
            return "已取消管理员授权"
        }
        return msg.isEmpty ? "配置免密失败（exit \(result.exitCode)）" : msg
    }

    /// 移除 `/etc/sudoers.d/screenmaintainer` 免密规则。
    static func removePasswordlessRule() -> String? {
        let script = "do shell script \"/bin/rm -f '\(sudoersPath)'\" with administrator privileges"
        let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script])
        if result.exitCode == 0 {
            return nil
        }
        let msg = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("(-128)") {
            return "已取消管理员授权"
        }
        return msg.isEmpty ? "移除免密失败（exit \(result.exitCode)）" : msg
    }
}
