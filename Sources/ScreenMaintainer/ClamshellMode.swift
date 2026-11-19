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
    static var lidClosed: Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool else {
            return nil
        }
        return prop
    }

    /// nil 表示读取失败，调用方不能据此清除恢复记录。
    static var sleepDisabled: Bool? {
        let result = ProcessRunner.run(pmsetPath, ["-g"])
        guard result.exitCode == 0 else { return nil }
        return parseSleepDisabled(result.stdout)
    }

    static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.first == "SleepDisabled" else { continue }
            switch parts.last {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        // 未设置该键时，pmset 的有效设置中通常没有 SleepDisabled 一行。
        return output.contains("Currently in use:") ? false : nil
    }

    static var isPasswordlessConfigured: Bool {
        ["0", "1"].allSatisfy { value in
            ProcessRunner.run("/usr/bin/sudo", ["-n", "-k", "-l", pmsetPath, "-a", "disablesleep", value]).exitCode == 0
        }
    }

    static func setEnabled(_ enable: Bool, allowPrompt: Bool = true) -> String? {
        let value = enable ? "1" : "0"
        let result = ProcessRunner.run("/usr/bin/sudo", ["-n", "-k", pmsetPath, "-a", "disablesleep", value])
        if result.exitCode == 0 { return nil }
        guard allowPrompt else { return "需要管理员授权才能恢复系统睡眠" }
        if enable {
            return runAsAdministrator(passwordlessInstallCommand(enableSleepOverride: true), failure: "设置失败")
        }
        return runAsAdministrator("\(pmsetPath) -a disablesleep \(value)", failure: "设置失败")
    }

    static func installPasswordlessRule() -> String? {
        runAsAdministrator(passwordlessInstallCommand(enableSleepOverride: false), failure: "配置免密失败")
    }

    /// 在 sudoers 目录内创建仅管理员可访问的暂存目录，再原子移入已校验文件。
    /// 点号开头的路径不会被 sudoers 的 includedir 当作规则文件读取。
    private static func passwordlessInstallCommand(enableSleepOverride: Bool) -> String {
        // 数字 UID 精确匹配当前账户，不会被 sudoers 解释成用户名别名。
        let rule = "#\(getuid()) ALL=(root) NOPASSWD: \(pmsetPath) -a disablesleep 0, \(pmsetPath) -a disablesleep 1"
        let install = """
        set -eu
        umask 077
        stage=$(/usr/bin/mktemp -d /private/etc/sudoers.d/.screenmaintainer.XXXXXXXX)
        trap '/bin/unlink "$stage/rule" 2>/dev/null || :; /bin/rmdir "$stage"' EXIT
        /usr/bin/printf '%s\\n' '\(rule)' > "$stage/rule"
        /usr/sbin/chown root:wheel "$stage/rule"
        /bin/chmod 0440 "$stage/rule"
        /usr/sbin/visudo -cf "$stage/rule"
        [ ! -d '\(sudoersPath)' ]
        /bin/mv -fh "$stage/rule" '\(sudoersPath)'
        """
        return enableSleepOverride ? install + "\n\(pmsetPath) -a disablesleep 1" : install
    }

    static func removePasswordlessRule() -> String? {
        runAsAdministrator("if [ -e '\(sudoersPath)' ] || [ -L '\(sudoersPath)' ]; then /bin/unlink '\(sudoersPath)'; fi",
                           failure: "移除免密失败")
    }

    private static func runAsAdministrator(_ command: String, failure: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = ProcessRunner.run("/usr/bin/osascript", ["-e", script])
        if result.exitCode == 0 { return nil }
        let message = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("(-128)") { return "已取消管理员授权" }
        return message.isEmpty ? "\(failure)（exit \(result.exitCode)）" : message
    }
}
