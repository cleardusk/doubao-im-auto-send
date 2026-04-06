import Carbon
import Foundation

func printUsage() {
    let usageLines = [
        terminalSectionTitle("用法："),
        "  \(terminalCommand("doubao-im-auto-send [--right-ctrl|--left-ctrl|--right-option|--left-option] [--delay-ms 600] [--per-second-postdelay-ms 130] [--stable-ms 450] [--poll-ms 50] [--max-wait-ms 5000] [--min-hold-ms 250] [--log-file PATH] [--no-file-log] [--refine] [--refine-mode trim|correct] [--refine-model MODEL] [--refine-timeout-ms 6000] [--quiet]"))",
        "  \(terminalCommand("doubao-im-auto-send --check"))",
        "  \(terminalCommand("doubao-im-auto-send --refine-text \"这个事情大概就是这样这样\" [--refine-mode trim|correct] [--refine-model MODEL] [--refine-timeout-ms 6000]"))",
        "",
        terminalSectionTitle("行为："),
        "  1. 监听指定修饰键的长按与松开。",
        "  2. 仅在当前输入法为豆包输入法时生效。",
        "  3. 默认跳过常见编辑器类应用，如 VS Code、Cursor、Windsurf、JetBrains、Xcode、Sublime。",
        "  4. 松手后先满足释放侧下界，再等待文本稳定。",
        "  5. 若启用 `--refine`，会在自动发送前调用 MiniMax CN API 做文本 refine。",
        "  6. 如果前台应用、输入法、焦点输入框或用户输入发生变化，或按下 Esc，则取消自动发送。",
        "  7. `--max-wait-ms` 为可选兜底参数；默认关闭。",
        "  8. 默认同时写入终端和文件日志：\(Config.defaultLogFilePath)",
        "  9. `--quiet` 仅静默终端；`--no-file-log` 关闭文件日志。",
        " 10. 启用 refine 时需要 `MINIMAX_API_KEY`；`MINIMAX_API_HOST` 默认为 \(Config.defaultMiniMaxHost)。"
    ]
    print(usageLines.joined(separator: "\n"))
}

func printCheck(config: Config, accessibility: AccessibilityService) {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let inputSourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
        Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    } ?? "未知"
    let localizedName = TISGetInputSourceProperty(source, kTISPropertyLocalizedName).map {
        Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    } ?? "未知"
    let frontmost = accessibility.frontmostBundleID() ?? "未知"
    let denylistStatus = Config.defaultDeniedAppBundleIDPrefixes.contains { frontmost.hasPrefix($0) } ? "是" : "否"
    let miniMaxStatus = MiniMaxClient.environmentStatus()
    let hostStatus = miniMaxStatus.hostValidationError == nil ? miniMaxStatus.apiHost : "\(miniMaxStatus.apiHost)（无效）"
    let keyStatus = miniMaxStatus.apiKeyPresent ? "已设置" : "未设置"

    let checkLines = [
        terminalSectionTitle("当前环境："),
        "\(terminalLabel("当前输入法 ID:")) \(inputSourceID)",
        "\(terminalLabel("当前输入法名称:")) \(localizedName)",
        "\(terminalLabel("当前前台应用:")) \(frontmost)",
        "\(terminalLabel("命中默认 denylist:")) \(denylistStatus)",
        "\(terminalLabel("refine 已启用:")) \(config.refineEnabled ? "是" : "否")",
        "\(terminalLabel("refine 模式:")) \(config.refineMode.rawValue)",
        "\(terminalLabel("refine 模型:")) \(config.refineModel)",
        "\(terminalLabel("refine 超时:")) \(Int(config.refineTimeout * 1000))ms",
        "\(terminalLabel("MINIMAX_API_HOST:")) \(hostStatus)",
        "\(terminalLabel("MINIMAX_API_KEY:")) \(keyStatus)"
    ]
    print(checkLines.joined(separator: "\n"))
    if let hostValidationError = miniMaxStatus.hostValidationError {
        fputs("警告：\(hostValidationError)\n", stderr)
    }
}

func runRefineText(_ config: Config, logger: Logger) -> Int32 {
    guard let text = config.refineText else {
        logger.error("缺少 `--refine-text` 的文本内容。")
        return 1
    }

    do {
        let client = try MiniMaxClient(logger: logger)
        let result = try client.refineSync(
            text: text,
            mode: config.refineMode,
            model: config.refineModel,
            timeout: config.refineTimeout
        )
        print(result)
        return 0
    } catch {
        logger.error("refine 失败：\(error.localizedDescription)")
        return 1
    }
}

@main
struct DoubaoAutoSendCLI {
    static func main() {
        if CommandLine.arguments.contains("--help") {
            printUsage()
            exit(0)
        }

        let config = Config.fromArguments()
        let logger = Logger(terminalVerbose: config.terminalVerbose, fileLogURL: config.fileLogURL)
        let accessibility = AccessibilityService()

        if let startupError = logger.startupError {
            logger.error(startupError)
        }

        if CommandLine.arguments.contains("--check") {
            printCheck(config: config, accessibility: accessibility)
            exit(0)
        }

        if config.refineText != nil {
            exit(runRefineText(config, logger: logger))
        }

        let miniMaxClient: MiniMaxClient?
        if config.refineEnabled {
            do {
                miniMaxClient = try MiniMaxClient(logger: logger)
            } catch {
                logger.error(error.localizedDescription)
                exit(1)
            }
        } else {
            miniMaxClient = nil
        }

        AutoSendEngine(
            config: config,
            logger: logger,
            accessibility: accessibility,
            miniMaxClient: miniMaxClient
        ).run()
    }
}
