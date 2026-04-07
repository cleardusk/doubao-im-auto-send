import Darwin
import Foundation

let terminalOutputColorEnabled = isatty(fileno(stdout)) == 1

func terminalColor(_ text: String, code: String) -> String {
    guard terminalOutputColorEnabled else { return text }
    return "\u{001B}[\(code)m\(text)\u{001B}[0m"
}

func terminalSectionTitle(_ text: String) -> String {
    terminalColor(text, code: "1;36")
}

func terminalCommand(_ text: String) -> String {
    terminalColor(text, code: "34")
}

func terminalLabel(_ text: String) -> String {
    terminalColor(text, code: "90")
}

final class FileLogger {
    private let handle: FileHandle

    init(url: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            let created = fileManager.createFile(atPath: url.path, contents: nil)
            guard created else {
                throw NSError(domain: "DoubaoAutoSend", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "无法创建日志文件：\(url.path)"
                ])
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func writeLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    deinit {
        try? handle.close()
    }
}

final class Logger {
    let startupError: String?
    private let terminalVerbose: Bool
    private let fileLogger: FileLogger?
    private let stdoutColorEnabled = isatty(fileno(stdout)) == 1
    private let stderrColorEnabled = isatty(fileno(stderr)) == 1
    private var consoleOutputEnabled = true

    init(terminalVerbose: Bool, fileLogURL: URL?) {
        self.terminalVerbose = terminalVerbose
        if let fileLogURL {
            do {
                fileLogger = try FileLogger(url: fileLogURL)
                startupError = nil
            } catch {
                fileLogger = nil
                startupError = "创建文件日志失败：\(error.localizedDescription)"
            }
        } else {
            fileLogger = nil
            startupError = nil
        }
    }

    func log(_ message: String) {
        let timestamp = timestampString()
        let plainLine = "[\(timestamp)] \(message)"
        fileLogger?.writeLine(plainLine)

        guard terminalVerbose else { return }
        guard consoleOutputEnabled || shouldPrintWhileConsoleSuppressed(message) else { return }
        let renderedTimestamp = color("[\(timestamp)]", code: "90", enabled: stdoutColorEnabled)
        let renderedMessage = colorizeLogMessage(message)
        print("\(renderedTimestamp) \(renderedMessage)")
        fflush(stdout)
    }

    func setConsoleOutputEnabled(_ enabled: Bool) {
        consoleOutputEnabled = enabled
    }

    func error(_ message: String) {
        let timestamp = timestampString()
        fileLogger?.writeLine("[\(timestamp)] 错误：\(message)")
        let renderedMessage = color(message, code: "31", enabled: stderrColorEnabled)
        fputs("\(renderedMessage)\n", stderr)
    }

    private func timestampString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.string(from: Date())
    }

    private func colorizeLogMessage(_ message: String) -> String {
        if message.hasPrefix("refine 输入预览：") {
            return colorizedPreviewMessage(
                message,
                prefix: "refine 输入预览：",
                contentCode: "93"
            )
        }
        if message.hasPrefix("refine 输出预览：") {
            return colorizedPreviewMessage(
                message,
                prefix: "refine 输出预览：",
                contentCode: "92"
            )
        }
        if message.hasPrefix("已发送")
            || message.hasPrefix("已确认发送 Enter")
            || message.hasPrefix("refine 回写成功")
            || message.hasPrefix("refine 前后相同") {
            return color(message, code: "32", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("触发依据") {
            return color(message, code: "35", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("refine 回写：") {
            return color(message, code: "95", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("当前前台应用") || message.hasPrefix("松手时前台应用") {
            return color(message, code: "96", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("等待：")
            || message.hasPrefix("取消")
            || message.hasPrefix("跳过")
            || message.hasPrefix("达到最大等待时间")
            || message.hasPrefix("丢弃") {
            return color(message, code: "33", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("Enter 已触发，但未确认提交")
            || message.contains("失败")
            || message.contains("无效") {
            return color(message, code: "31", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("观测到") || message.hasPrefix("开始 refine") || message.hasPrefix("refine 生成成功") {
            return color(message, code: "36", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("开始监听") || message.hasPrefix("当前输入法") || message.hasPrefix("计算得到") || message.contains("已按下") || message.contains("已松开") || message.hasPrefix("refine：") || message.hasPrefix("文件日志") {
            return color(message, code: "34", enabled: stdoutColorEnabled)
        }
        return message
    }

    private func color(_ text: String, code: String, enabled: Bool) -> String {
        guard enabled else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func colorizedPreviewMessage(_ message: String, prefix: String, contentCode: String) -> String {
        guard stdoutColorEnabled else { return message }
        let content = String(message.dropFirst(prefix.count))
        let renderedPrefix = color(prefix, code: "90", enabled: true)
        let renderedContent = color(content, code: contentCode, enabled: true)
        return "\(renderedPrefix)\(renderedContent)"
    }

    private func shouldPrintWhileConsoleSuppressed(_ message: String) -> Bool {
        let importantPrefixes = [
            "松手时前台应用：",
            "计算得到释放侧下界：",
            "观测到松手后的文本变化",
            "观测到未收录的 Codex 建议文案：",
            "等待：",
            "触发依据：",
            "开始 refine：",
            "refine 输入预览：",
            "refine 生成成功：",
            "refine 输出预览：",
            "refine 前后相同：",
            "refine 回写：",
            "refine 回写成功",
            "refine 回写校验失败：",
            "terminal 读取失败：",
            "已确认发送 Enter",
            "Enter 已触发，但未确认提交",
            "取消：",
            "取消待执行操作：",
            "跳过："
        ]
        if importantPrefixes.contains(where: { message.hasPrefix($0) }) {
            return true
        }

        return message.contains("已松开")
    }
}
