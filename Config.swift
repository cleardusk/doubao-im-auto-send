import CoreGraphics
import Foundation

enum RefineMode: String {
    case trim
    case correct

    var systemPrompt: String {
        switch self {
        case .trim:
            return """
            你是中文语音转文字的后处理器。请将输入文本整理成更简洁、更自然、更适合直接发送的最终文本。删除口头禅、重复表达和车轱辘话，但必须保留原意，不得扩写，不得新增信息，不得改变事实。即使原文不完整，也只做最小必要整理，不要追问，不要解释。只输出最终文本，不要加引号，不要使用 Markdown。
            """
        case .correct:
            return """
            你是中文语音转文字的纠错器。请优先修正语音识别错误、错别字和明显不通顺的片段，但尽量保持原句结构、语气和信息完整，不要扩写，不要新增信息。即使原文不完整，也只做最小必要修正，不要追问，不要解释。只输出最终文本，不要加引号，不要使用 Markdown。
            """
        }
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

struct Config {
    static let defaultLogFilePath = "~/Library/Logs/doubao-im-auto-send/runtime.log"
    static let defaultMiniMaxHost = "https://api.minimaxi.com"
    static let defaultMiniMaxModel = "MiniMax-M2.5-highspeed"
    static let defaultDeniedAppBundleIDPrefixes = [
        "com.microsoft.VSCode",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "com.jetbrains.",
        "com.apple.dt.Xcode",
        "com.sublimetext.4"
    ]

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
    let deniedAppBundleIDPrefixes: [String]
    let refineEnabled: Bool
    let refineMode: RefineMode
    let refineModel: String
    let refineTimeout: TimeInterval
    let refineText: String?

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
        var refineEnabled = false
        var refineMode = RefineMode.trim
        var refineModel = defaultMiniMaxModel
        var refineTimeout = 6.0
        var refineText: String?

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
            case "--refine":
                refineEnabled = true
            case "--refine-mode":
                if let value = iterator.next(), let mode = RefineMode(rawValue: value) {
                    refineMode = mode
                }
            case "--refine-model":
                if let value = iterator.next(), !value.isEmpty {
                    refineModel = value
                }
            case "--refine-timeout-ms":
                if let value = iterator.next(), let milliseconds = Double(value), milliseconds > 0 {
                    refineTimeout = milliseconds / 1000
                }
            case "--refine-text":
                refineText = iterator.next()
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
            fileLogURL: fileLogURL,
            deniedAppBundleIDPrefixes: defaultDeniedAppBundleIDPrefixes,
            refineEnabled: refineEnabled,
            refineMode: refineMode,
            refineModel: refineModel,
            refineTimeout: refineTimeout,
            refineText: refineText
        )
    }
}
