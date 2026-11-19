import Foundation

struct AssertionHolder: Equatable {
    let process: String
    let assertion: String
    let detail: String
}

/// 解析 `pmset -g assertions`，回答"现在到底谁在阻止睡眠"。
/// 这是本 App 的透明化功能：把 macOS 从不展示的动态断言层直接摆出来。
enum AssertionReader {
    private static let interesting: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventUserIdleDisplaySleep",
        "PreventSystemSleep",
        "NoDisplaySleepAssertion",
        "NoIdleSleepAssertion",
    ]

    private static let labels: [String: String] = [
        "PreventUserIdleSystemSleep": "防系统睡眠",
        "PreventSystemSleep": "防系统睡眠（强制）",
        "PreventUserIdleDisplaySleep": "防息屏",
        "NoDisplaySleepAssertion": "防息屏",
        "NoIdleSleepAssertion": "防系统睡眠",
    ]

    static func currentHolders() -> [AssertionHolder] {
        parse(ProcessRunner.run("/usr/bin/pmset", ["-g", "assertions"]).stdout)
    }

    /// CLI 调试用：每行 "进程<TAB>断言<TAB>描述"
    static func dumpLines() -> [String] {
        currentHolders().map { "\($0.process)\t\($0.assertion)\t\($0.detail)" }
    }

    static func parse(_ output: String) -> [AssertionHolder] {
        let pattern = #"pid\s+\d+\(([^)]*)\):\s+\[0x[0-9a-fA-F]+\]\s+\S+\s+(\w+)\s+named:\s+"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var result: [AssertionHolder] = []
        var inSection = false
        for line in output.components(separatedBy: "\n") {
            if line.contains("Listed by owning process:") {
                inSection = true
                continue
            }
            if line.contains("Kernel Assertions:") {
                break
            }
            guard inSection else { continue }
            guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  m.numberOfRanges == 4,
                  let pr = Range(m.range(at: 1), in: line),
                  let at = Range(m.range(at: 2), in: line),
                  let dt = Range(m.range(at: 3), in: line)
            else { continue }

            let assertion = String(line[at])
            guard interesting.contains(assertion) else { continue }
            result.append(AssertionHolder(process: String(line[pr]),
                                          assertion: assertion,
                                          detail: String(line[dt])))
        }
        return result
    }

    /// 生成菜单底部的中文摘要（去重、限量）。
    static func summarize(_ holders: [AssertionHolder]) -> String {
        guard !holders.isEmpty else { return "当前没有进程在阻止睡眠" }
        var seen = Set<String>()
        var lines: [String] = []
        for h in holders {
            let type = h.assertion == "NoIdleSleepAssertion" ? "PreventUserIdleSystemSleep"
                : h.assertion == "NoDisplaySleepAssertion" ? "PreventUserIdleDisplaySleep" : h.assertion
            let key = "\(h.process)|\(type)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            var label = labels[h.assertion] ?? h.assertion
            if h.process == "powerd" {
                label = "防系统睡眠（系统：亮屏期间不睡）"
            }
            if h.process == "ScreenMaintainer" {
                label += "（本 App）"
            }
            lines.append("· \(h.process) — \(label)")
            if lines.count >= 4 {
                lines.append("· …")
                break
            }
        }
        return lines.joined(separator: "\n")
    }
}
