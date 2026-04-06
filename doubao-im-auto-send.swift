import Cocoa
import Carbon
import CoreGraphics
import Foundation
import ApplicationServices
import Darwin

struct Config {
    static let defaultLogFilePath = "~/Library/Logs/doubao-im-auto-send/runtime.log"

    let doubaoInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
    let enterKeyCode: CGKeyCode = 36
    let escapeKeyCode: CGKeyCode = 53
    let watchedModifier: WatchedModifier
    let minReleaseDelay: TimeInterval
    let optimizationDelayPerHeldSecond: TimeInterval
    let stableDuration: TimeInterval
    let pollInterval: TimeInterval
    let maxWaitAfterRelease: TimeInterval?
    let minHoldDuration: TimeInterval
    let terminalVerbose: Bool
    let fileLogURL: URL?

    static func fromArguments() -> Config {
        var watchedModifier: WatchedModifier = .leftOption
        var minReleaseDelay = 0.6
        var optimizationDelayPerHeldSecond = 0.13
        var stableDuration = 0.45
        var pollInterval = 0.05
        var maxWaitAfterRelease: TimeInterval?
        var minHoldDuration = 0.25
        var terminalVerbose = true
        var fileLogEnabled = true
        var fileLogPath: String?

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--left-ctrl":
                watchedModifier = .leftControl
            case "--right-ctrl":
                watchedModifier = .rightControl
            case "--left-option":
                watchedModifier = .leftOption
            case "--right-option":
                watchedModifier = .rightOption
            case "--delay-ms":
                if let value = iterator.next(), let milliseconds = Double(value) {
                    minReleaseDelay = milliseconds / 1000
                }
            case "--per-second-postdelay-ms":
                if let value = iterator.next(), let milliseconds = Double(value) {
                    optimizationDelayPerHeldSecond = milliseconds / 1000
                }
            case "--stable-ms":
                if let value = iterator.next(), let milliseconds = Double(value) {
                    stableDuration = milliseconds / 1000
                }
            case "--poll-ms":
                if let value = iterator.next(), let milliseconds = Double(value) {
                    pollInterval = milliseconds / 1000
                }
            case "--max-wait-ms":
                if let value = iterator.next(), let milliseconds = Double(value) {
                    maxWaitAfterRelease = milliseconds / 1000
                }
            case "--min-hold-ms":
                if let value = iterator.next(), let milliseconds = Double(value) {
                    minHoldDuration = milliseconds / 1000
                }
            case "--log-file":
                if let value = iterator.next() {
                    fileLogPath = value
                    fileLogEnabled = true
                }
            case "--no-file-log":
                fileLogEnabled = false
            case "--quiet":
                terminalVerbose = false
            default:
                break
            }
        }

        let fileLogURL: URL?
        if fileLogEnabled {
            let path = fileLogPath ?? defaultLogFilePath
            fileLogURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            fileLogURL = nil
        }

        return Config(
            watchedModifier: watchedModifier,
            minReleaseDelay: minReleaseDelay,
            optimizationDelayPerHeldSecond: optimizationDelayPerHeldSecond,
            stableDuration: stableDuration,
            pollInterval: pollInterval,
            maxWaitAfterRelease: maxWaitAfterRelease,
            minHoldDuration: minHoldDuration,
            terminalVerbose: terminalVerbose,
            fileLogURL: fileLogURL
        )
    }
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

enum WatchedModifier {
    case leftControl
    case rightControl
    case leftOption
    case rightOption

    var keyCode: CGKeyCode {
        switch self {
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftOption: return 58
        case .rightOption: return 61
        }
    }

    var eventFlag: CGEventFlags {
        switch self {
        case .leftControl, .rightControl:
            return .maskControl
        case .leftOption, .rightOption:
            return .maskAlternate
        }
    }

    var label: String {
        switch self {
        case .leftControl: return "左 Ctrl"
        case .rightControl: return "右 Ctrl"
        case .leftOption: return "左 Option"
        case .rightOption: return "右 Option"
        }
    }
}

final class State {
    var isModifierPressed = false
    var pressedAt: CFAbsoluteTime = 0
    var frontmostBundleAtRelease: String?
    var releaseStartedAt: CFAbsoluteTime = 0
    var focusedValueAtRelease: String?
    var lastObservedValue: String?
    var lastValueChangedAt: CFAbsoluteTime = 0
    var requiredReleaseDelay: TimeInterval = 0
    var pendingPoll: DispatchWorkItem?
}

final class DoubaoAutoSendHelper {
    private let config: Config
    private let state = State()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let fileLogger: FileLogger?
    private let fileLoggerError: String?
    private let stdoutColorEnabled = isatty(fileno(stdout)) == 1
    private let stderrColorEnabled = isatty(fileno(stderr)) == 1

    init(config: Config) {
        self.config = config
        if let fileLogURL = config.fileLogURL {
            do {
                fileLogger = try FileLogger(url: fileLogURL)
                fileLoggerError = nil
            } catch {
                fileLogger = nil
                fileLoggerError = "创建文件日志失败：\(error.localizedDescription)"
            }
        } else {
            fileLogger = nil
            fileLoggerError = nil
        }
    }

    func run() {
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let helper = Unmanaged<DoubaoAutoSendHelper>.fromOpaque(userInfo).takeUnretainedValue()
            helper.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            printError("创建事件监听失败。请检查“输入监控”和“辅助功能”权限。")
            exit(1)
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource else {
            printError("创建运行循环源失败。")
            exit(1)
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        if let fileLoggerError {
            printError(fileLoggerError)
        }

        let maxWaitLabel = config.maxWaitAfterRelease.map { "\(Int($0 * 1000))ms" } ?? "关闭"
        log("开始监听 \(config.watchedModifier.label)，最小等待=\(Int(config.minReleaseDelay * 1000))ms，稳定窗口=\(Int(config.stableDuration * 1000))ms，最大等待=\(maxWaitLabel)，按 Esc 可取消自动发送")
        log("当前输入法：\(currentInputSourceID() ?? "未知")")
        log("当前前台应用：\(frontmostApplicationDescription())")
        log("文件日志：\(config.fileLogURL?.path ?? "关闭")")
        RunLoop.current.run()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handleKeyDown(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            cancelPendingActions(reason: "发送前发生了新的鼠标输入")
        default:
            break
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == config.escapeKeyCode {
            cancelPendingActions(reason: "按下 Esc，取消自动发送")
            return
        }
        cancelPendingActions(reason: "发送前发生了新的键盘输入")
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == config.watchedModifier.keyCode else { return }

        let isPressed = event.flags.contains(config.watchedModifier.eventFlag)
        if isPressed && !state.isModifierPressed {
            state.isModifierPressed = true
            state.pressedAt = CFAbsoluteTimeGetCurrent()
            cancelPendingActions(reason: "再次按下\(config.watchedModifier.label)")
            log("\(config.watchedModifier.label) 已按下")
            return
        }

        if !isPressed && state.isModifierPressed {
            state.isModifierPressed = false
            scheduleStabilizedSend()
        }
    }

    private func scheduleStabilizedSend() {
        let heldFor = CFAbsoluteTimeGetCurrent() - state.pressedAt
        guard heldFor >= config.minHoldDuration else {
            log("跳过：按住时长过短（\(Int(heldFor * 1000))ms）")
            return
        }

        guard currentInputSourceID() == config.doubaoInputSourceID else {
            log("跳过：当前输入法不是豆包输入法")
            return
        }

        state.frontmostBundleAtRelease = frontmostBundleID()
        state.releaseStartedAt = CFAbsoluteTimeGetCurrent()
        state.focusedValueAtRelease = focusedTextValue()
        state.lastObservedValue = state.focusedValueAtRelease
        state.lastValueChangedAt = state.releaseStartedAt
        state.requiredReleaseDelay = computedRequiredReleaseDelay(heldFor: heldFor)
        log("松手时前台应用：\(frontmostApplicationDescription())")
        log("计算得到释放侧下界：\(Int(state.requiredReleaseDelay * 1000))ms")
        log("\(config.watchedModifier.label) 已松开，等待识别优化完成并观察文本稳定")
        scheduleNextPoll(after: config.pollInterval)
    }

    private func scheduleNextPoll(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.pollAndMaybeSend()
        }
        state.pendingPoll = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func pollAndMaybeSend() {
        state.pendingPoll = nil

        guard !state.isModifierPressed else {
            log("取消：发送前再次按下触发键")
            return
        }

        guard currentInputSourceID() == config.doubaoInputSourceID else {
            log("取消：发送前输入法发生变化")
            return
        }

        let currentFrontmostBundleID = frontmostBundleID()
        guard currentFrontmostBundleID == state.frontmostBundleAtRelease else {
            let previousBundle = state.frontmostBundleAtRelease ?? "未知"
            log("取消：发送前前台应用发生变化（松手时=\(previousBundle)，当前=\(frontmostApplicationDescription())）")
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - state.releaseStartedAt
        let currentValue = focusedTextValue()

        if currentValue != state.lastObservedValue {
            state.lastObservedValue = currentValue
            state.lastValueChangedAt = now
            log("观测到松手后的文本变化")
        }

        if let maxWaitAfterRelease = config.maxWaitAfterRelease, elapsed >= maxWaitAfterRelease {
            logSendBasis(forceByMaxWait: true)
            log("达到最大等待时间，发送 Enter")
            fireEnterSend()
            return
        }

        if elapsed < state.requiredReleaseDelay {
            scheduleNextPoll(after: config.pollInterval)
            return
        }

        let stableFor = now - state.lastValueChangedAt
        if stableFor >= config.stableDuration {
            logSendBasis()
            fireEnterSend()
            return
        }

        scheduleNextPoll(after: config.pollInterval)
    }

    private func fireEnterSend() {
        postEnter()
        log("已发送 Enter")
    }

    private func logSendBasis(forceByMaxWait: Bool = false) {
        let releaseBound = state.requiredReleaseDelay
        let stableBound = (state.lastValueChangedAt - state.releaseStartedAt) + config.stableDuration
        let tolerance = config.pollInterval

        let releaseBoundMs = Int(releaseBound * 1000)
        let stableBoundMs = Int(stableBound * 1000)

        if forceByMaxWait, let maxWaitAfterRelease = config.maxWaitAfterRelease {
            log("触发依据：最大等待兜底（释放侧=\(releaseBoundMs)ms，稳定性=\(stableBoundMs)ms，最大等待=\(Int(maxWaitAfterRelease * 1000))ms）")
            return
        }

        if abs(releaseBound - stableBound) <= tolerance {
            log("触发依据：释放侧下界与文本稳定性下界同时满足（释放侧=\(releaseBoundMs)ms，稳定性=\(stableBoundMs)ms）")
            return
        }

        if releaseBound > stableBound {
            log("触发依据：释放侧下界（释放侧=\(releaseBoundMs)ms，稳定性=\(stableBoundMs)ms）")
            return
        }

        log("触发依据：文本稳定性下界（释放侧=\(releaseBoundMs)ms，稳定性=\(stableBoundMs)ms）")
    }

    private func cancelPendingActions(reason: String) {
        guard let pendingPoll = state.pendingPoll else { return }
        pendingPoll.cancel()
        state.pendingPoll = nil
        log("取消待执行轮询：\(reason)")
    }

    private func currentInputSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    private func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func frontmostApplicationDescription() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "未知"
        }
        let name = app.localizedName ?? "未知"
        let bundleID = app.bundleIdentifier ?? "未知"
        return "\(name) (\(bundleID))"
    }

    private func focusedTextValue() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElement: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusedError == .success, let focusedElement else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        let attributeNames = [kAXValueAttribute, kAXSelectedTextAttribute]
        for attribute in attributeNames {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            guard error == .success, let value else { continue }

            if let stringValue = value as? String {
                return stringValue
            }
        }
        return nil
    }

    private func computedRequiredReleaseDelay(heldFor: TimeInterval) -> TimeInterval {
        let base = config.minReleaseDelay
        let optimizationComponent = heldFor * config.optimizationDelayPerHeldSecond
        let requiredDelay = optimizationComponent + base
        guard let maxWaitAfterRelease = config.maxWaitAfterRelease else {
            return requiredDelay
        }
        return min(maxWaitAfterRelease, requiredDelay)
    }

    private func postEnter() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log("创建 CGEventSource 失败")
            return
        }

        let down = CGEvent(keyboardEventSource: source, virtualKey: config.enterKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: config.enterKeyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func log(_ message: String) {
        let timestamp = timestampString()
        let plainLine = "[\(timestamp)] \(message)"
        fileLogger?.writeLine(plainLine)

        guard config.terminalVerbose else { return }
        let renderedTimestamp = color("[\(timestamp)]", code: "90", enabled: stdoutColorEnabled)
        let renderedMessage = colorizeLogMessage(message)
        print("\(renderedTimestamp) \(renderedMessage)")
        fflush(stdout)
    }

    private func printError(_ message: String) {
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
        if message.hasPrefix("已发送") {
            return color(message, code: "32", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("触发依据") {
            return color(message, code: "35", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("当前前台应用") || message.hasPrefix("松手时前台应用") {
            return color(message, code: "96", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("取消") || message.hasPrefix("跳过") || message.hasPrefix("达到最大等待时间") {
            return color(message, code: "33", enabled: stdoutColorEnabled)
        }
        if message.contains("失败") {
            return color(message, code: "31", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("观测到") {
            return color(message, code: "36", enabled: stdoutColorEnabled)
        }
        if message.hasPrefix("开始监听") || message.hasPrefix("当前输入法") || message.hasPrefix("计算得到") || message.contains("已按下") || message.contains("已松开") {
            return color(message, code: "34", enabled: stdoutColorEnabled)
        }
        return message
    }

    private func color(_ text: String, code: String, enabled: Bool) -> String {
        guard enabled else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }
}

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

func printUsage() {
    let usageLines = [
        terminalSectionTitle("用法："),
        "  \(terminalCommand("swift doubao-im-auto-send.swift [--right-ctrl|--left-ctrl|--right-option|--left-option] [--delay-ms 600] [--per-second-postdelay-ms 130] [--stable-ms 450] [--poll-ms 50] [--max-wait-ms 5000] [--min-hold-ms 250] [--log-file PATH] [--no-file-log] [--quiet]"))",
        "  \(terminalCommand("swift doubao-im-auto-send.swift --check"))",
        "",
        terminalSectionTitle("行为："),
        "  1. 监听指定修饰键的长按与松开。",
        "  2. 仅在当前输入法为豆包输入法时生效。",
        "  3. 松手后先满足释放侧下界，再等待文本稳定。",
        "  4. 如果前台应用、输入法或用户输入发生变化，或按下 Esc，则取消自动发送。",
        "  5. `--max-wait-ms` 为可选兜底参数；默认关闭。",
        "  6. 默认同时写入终端和文件日志：\(Config.defaultLogFilePath)",
        "  7. `--quiet` 仅静默终端；`--no-file-log` 关闭文件日志。",
        "  8. 条件满足后发送一个 Enter 键事件。"
    ]
    print(usageLines.joined(separator: "\n"))
}

if CommandLine.arguments.contains("--help") {
    printUsage()
    exit(0)
}

if CommandLine.arguments.contains("--check") {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let inputSourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
        Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    } ?? "未知"
    let localizedName = TISGetInputSourceProperty(source, kTISPropertyLocalizedName).map {
        Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    } ?? "未知"
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "未知"
    let checkLines = [
        terminalSectionTitle("当前环境："),
        "\(terminalLabel("当前输入法 ID:")) \(inputSourceID)",
        "\(terminalLabel("当前输入法名称:")) \(localizedName)",
        "\(terminalLabel("当前前台应用:")) \(frontmost)"
    ]
    print(checkLines.joined(separator: "\n"))
    exit(0)
}

DoubaoAutoSendHelper(config: Config.fromArguments()).run()
