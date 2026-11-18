import Foundation

enum ProcessRunner {
    struct Output {
        let stdout: String
        let exitCode: Int32
    }

    /// 同步运行一个短命令（pmset / osascript），返回 stdout+stderr 合并文本与退出码。
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Output(stdout: "", exitCode: -1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Output(stdout: text, exitCode: process.terminationStatus)
    }
}
