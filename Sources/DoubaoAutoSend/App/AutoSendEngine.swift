import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation

private enum EnginePhase {
    case idle
    case polling
    case refining
    case applying
}

private final class SessionState {
    var phase: EnginePhase = .idle
    var isModifierPressed = false
    var pressedAt: CFAbsoluteTime = 0
    var frontmostBundleAtRelease: String?
    var releaseStartedAt: CFAbsoluteTime = 0
    var focusedValueAtRelease: String?
    var lastObservedValue: String?
    var lastValueChangedAt: CFAbsoluteTime = 0
    var requiredReleaseDelay: TimeInterval = 0
    var pendingPoll: DispatchWorkItem?
    var pendingRefineTask: RefineTask?
    var activeRequestID: UUID?
    var focusSnapshotAtRelease: FocusedElementSnapshot?
    var loggedPendingTerminalInput = false
    var loggedPendingRefineSettle = false
    var consoleLoggingSuppressed = false
}

private enum SyntheticAction {
    case directSend(snapshot: FocusedElementSnapshot?, expectedTextBeforeSend: String?)
    case rewriteThenSend(snapshot: FocusedElementSnapshot, refinedText: String)
}

private enum SyntheticActionOutcome {
    case directSend(sendSucceeded: Bool)
    case rewriteSuccess(length: Int, sendSucceeded: Bool)
    case rewriteFailure(summary: String?, sendSucceeded: Bool)
}

final class AutoSendEngine {
    private static let terminalInputGraceAfterRelease: TimeInterval = 2.0
    private static let refinePreflightExtraStableDuration: TimeInterval = 0.6
    private static let refineInputPreviewLimit = 120

    private let config: Config
    private let logger: Logger
    private let accessibility: AccessibilityService
    private let refineProvider: RefineProvider?
    private let syntheticActionQueue = DispatchQueue(label: "DoubaoAutoSend.synthetic-actions")
    private let state = SessionState()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        config: Config,
        logger: Logger,
        accessibility: AccessibilityService,
        refineProvider: RefineProvider?
    ) {
        self.config = config
        self.logger = logger
        self.accessibility = accessibility
        self.refineProvider = refineProvider
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

            let helper = Unmanaged<AutoSendEngine>.fromOpaque(userInfo).takeUnretainedValue()
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
            logger.error("创建事件监听失败。请检查“输入监控”和“辅助功能”权限。")
            exit(1)
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource else {
            logger.error("创建运行循环源失败。")
            exit(1)
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        let maxWaitLabel = config.maxWaitAfterRelease.map { "\(Int($0 * 1000))ms" } ?? "关闭"
        logger.log("开始监听 \(config.watchedModifier.label)，最小等待=\(Int(config.minReleaseDelay * 1000))ms，稳定窗口=\(Int(config.stableDuration * 1000))ms，最大等待=\(maxWaitLabel)，按 Esc 可取消自动发送")
        logger.log("当前输入法：\(accessibility.currentInputSourceID() ?? "未知")")
        logger.log("当前前台应用：\(accessibility.frontmostApplicationDescription())")
        logger.log("默认 denylist：常见编辑器类应用")
        logger.log("文件日志：\(config.fileLogURL?.path ?? "关闭")")
        if config.refineEnabled {
            let transportSummary: String
            switch config.refineProvider {
            case .codex:
                transportSummary = config.refineCodexTransport.rawValue
            case .minimax:
                transportSummary = config.refineMiniMaxTransport.rawValue
            }
            logger.log("refine：开启，provider=\(config.refineProvider.rawValue)，transport=\(transportSummary)，mode=\(config.refineMode.rawValue)，model=\(config.refineModel)，timeout=\(Int(config.refineTimeout * 1000))ms")
        } else {
            logger.log("refine：关闭")
        }
        RunLoop.current.run()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if state.phase == .applying {
            handleWhileApplying(type: type, event: event)
            return
        }

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

    private func handleWhileApplying(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == config.watchedModifier.keyCode else { return }
        let isPressed = event.flags.contains(config.watchedModifier.eventFlag)
        if isPressed {
            logger.log("跳过：上一轮仍在回写或发送收尾")
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
            logger.log("\(config.watchedModifier.label) 已按下")
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
            logger.log("跳过：按住时长过短（\(Int(heldFor * 1000))ms）")
            return
        }

        guard accessibility.currentInputSourceID() == config.doubaoInputSourceID else {
            logger.log("跳过：当前输入法不是豆包输入法")
            return
        }

        if let bundleID = accessibility.frontmostBundleID(), isDeniedApp(bundleID) {
            logger.log("跳过：当前前台应用在默认 denylist 中（\(accessibility.frontmostApplicationDescription())）")
            return
        }

        state.focusSnapshotAtRelease = accessibility.captureFocusedElementSnapshot()
        if let snapshot = state.focusSnapshotAtRelease,
           accessibility.usesTerminalRewrite(for: snapshot.element) {
            suppressConsoleLoggingForTerminal()
        }
        state.frontmostBundleAtRelease = state.focusSnapshotAtRelease?.bundleID ?? accessibility.frontmostBundleID()
        state.releaseStartedAt = CFAbsoluteTimeGetCurrent()
        state.focusedValueAtRelease = state.focusSnapshotAtRelease?.text
        state.lastObservedValue = state.focusedValueAtRelease
        state.lastValueChangedAt = state.releaseStartedAt
        state.requiredReleaseDelay = computedRequiredReleaseDelay(heldFor: heldFor)
        state.phase = .polling
        state.loggedPendingRefineSettle = false
        logger.log("松手时前台应用：\(accessibility.frontmostApplicationDescription())")
        logger.log("计算得到释放侧下界：\(Int(state.requiredReleaseDelay * 1000))ms")
        logger.log("\(config.watchedModifier.label) 已松开，等待识别优化完成并观察文本稳定")
        scheduleNextPoll(after: config.pollInterval)
    }

    private func scheduleNextPoll(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.pollAndMaybeSend()
        }
        state.pendingPoll = workItem
        state.phase = .polling
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func pollAndMaybeSend() {
        state.pendingPoll = nil

        guard !state.isModifierPressed else {
            logger.log("取消：发送前再次按下触发键")
            resetWorkflowState()
            return
        }

        guard accessibility.currentInputSourceID() == config.doubaoInputSourceID else {
            logger.log("取消：发送前输入法发生变化")
            resetWorkflowState()
            return
        }

        let currentFrontmostBundleID = accessibility.frontmostBundleID()
        guard currentFrontmostBundleID == state.frontmostBundleAtRelease else {
            let previousBundle = state.frontmostBundleAtRelease ?? "未知"
            logger.log("取消：发送前前台应用发生变化（松手时=\(previousBundle)，当前=\(accessibility.frontmostApplicationDescription())）")
            resetWorkflowState()
            return
        }

        let currentSnapshot = accessibility.captureFocusedElementSnapshot()
        if let originalSnapshot = state.focusSnapshotAtRelease {
            guard let currentSnapshot else {
                logger.log("取消：发送前焦点输入框不可用")
                resetWorkflowState()
                return
            }
            guard accessibility.isSameElement(originalSnapshot.element, currentSnapshot.element) else {
                logger.log("取消：发送前焦点输入框发生变化")
                resetWorkflowState()
                return
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - state.releaseStartedAt
        let currentValue = currentSnapshot?.text
        let isTerminalShell = currentSnapshot.map { accessibility.usesTerminalRewrite(for: $0.element) } ?? false

        if currentValue != state.lastObservedValue {
            state.lastObservedValue = currentValue
            state.lastValueChangedAt = now
            state.loggedPendingRefineSettle = false
            logger.log("观测到松手后的文本变化")
        }

        if let maxWaitAfterRelease = config.maxWaitAfterRelease, elapsed >= maxWaitAfterRelease {
            logSendBasis(forceByMaxWait: true)
            logger.log("达到最大等待时间，发送 Enter")
            beginSyntheticAction(.directSend(snapshot: currentSnapshot, expectedTextBeforeSend: currentValue))
            return
        }

        if elapsed < state.requiredReleaseDelay {
            scheduleNextPoll(after: config.pollInterval)
            return
        }

        let stableFor = now - state.lastValueChangedAt
        if stableFor >= config.stableDuration {
            let trimmedCurrentValue = currentValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isTerminalShell,
               trimmedCurrentValue.isEmpty,
               elapsed < state.requiredReleaseDelay + Self.terminalInputGraceAfterRelease {
                if !state.loggedPendingTerminalInput {
                    logger.log("等待：terminal 当前输入尚未可读，继续观察")
                    state.loggedPendingTerminalInput = true
                }
                scheduleNextPoll(after: config.pollInterval)
                return
            }

            if config.refineEnabled {
                let requiredStableForRefine = config.stableDuration + Self.refinePreflightExtraStableDuration
                if stableFor < requiredStableForRefine {
                    if !state.loggedPendingRefineSettle {
                        logger.log("等待：refine 前额外确认文本已稳定")
                        state.loggedPendingRefineSettle = true
                    }
                    scheduleNextPoll(after: config.pollInterval)
                    return
                }
            }

            state.loggedPendingRefineSettle = false
            logSendBasis()
            maybeStartRefineOrSend(
                stableText: currentValue,
                stableSnapshot: currentSnapshot
            )
            return
        }

        scheduleNextPoll(after: config.pollInterval)
    }

    private func maybeStartRefineOrSend(
        stableText: String?,
        stableSnapshot: FocusedElementSnapshot?
    ) {
        guard config.refineEnabled else {
            beginSyntheticAction(.directSend(
                snapshot: stableSnapshot ?? state.focusSnapshotAtRelease,
                expectedTextBeforeSend: stableText?.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            return
        }

        guard let refineProvider else {
            logger.log("跳过：refine 客户端不可用，回退原文发送")
            beginSyntheticAction(.directSend(snapshot: nil, expectedTextBeforeSend: nil))
            return
        }

        guard let sourceText = stableText?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceText.isEmpty else {
            let fallbackSnapshot = stableSnapshot ?? state.focusSnapshotAtRelease
            if let fallbackSnapshot,
               accessibility.usesTerminalRewrite(for: fallbackSnapshot.element) {
                logger.log("terminal 读取失败：\(accessibility.terminalReadFailureSummary(for: fallbackSnapshot.element))")
            }
            logger.log("跳过：当前输入框文本不可用，回退原文发送")
            beginSyntheticAction(.directSend(snapshot: fallbackSnapshot, expectedTextBeforeSend: nil))
            return
        }

        guard let focusSnapshot = stableSnapshot ?? state.focusSnapshotAtRelease else {
            logger.log("跳过：当前焦点输入框不可用，回退原文发送")
            beginSyntheticAction(.directSend(snapshot: nil, expectedTextBeforeSend: nil))
            return
        }

        startRefine(sourceText: sourceText, focusSnapshot: focusSnapshot, provider: refineProvider)
    }

    private func startRefine(sourceText: String, focusSnapshot: FocusedElementSnapshot, provider: RefineProvider) {
        let requestID = UUID()
        state.phase = .refining
        state.activeRequestID = requestID
        logger.log("开始 refine：provider=\(config.refineProvider.rawValue)，mode=\(config.refineMode.rawValue)，原文长度=\(sourceText.count)，model=\(config.refineModel)")
        logger.log("refine 输入预览：\(previewForLog(sourceText))")

        state.pendingRefineTask = provider.refine(
            text: sourceText,
            mode: config.refineMode,
            model: config.refineModel,
            timeout: config.refineTimeout
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleRefineResult(
                    result,
                    requestID: requestID,
                    sourceText: sourceText,
                    focusSnapshot: focusSnapshot
                )
            }
        }
    }

    private func handleRefineResult(
        _ result: Result<String, Error>,
        requestID: UUID,
        sourceText: String,
        focusSnapshot: FocusedElementSnapshot
    ) {
        guard state.activeRequestID == requestID else {
            logger.log("丢弃：收到过期 refine 响应")
            return
        }

        state.pendingRefineTask = nil

        guard !state.isModifierPressed else {
            logger.log("取消：refine 完成前再次按下触发键")
            resetWorkflowState()
            return
        }

        guard accessibility.currentInputSourceID() == config.doubaoInputSourceID else {
            logger.log("取消：refine 完成前输入法发生变化")
            resetWorkflowState()
            return
        }

        guard accessibility.frontmostBundleID() == state.frontmostBundleAtRelease else {
            logger.log("取消：refine 完成前前台应用发生变化")
            resetWorkflowState()
            return
        }

        guard let currentSnapshot = accessibility.captureFocusedElementSnapshot() else {
            logger.log("取消：refine 完成前焦点输入框不可用")
            resetWorkflowState()
            return
        }

        guard accessibility.isSameElement(focusSnapshot.element, currentSnapshot.element) else {
            logger.log("取消：refine 完成前焦点输入框发生变化")
            resetWorkflowState()
            return
        }

        let currentText = currentSnapshot.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentText != sourceText {
            logger.log("跳过：输入框文本在 refine 期间发生变化，回退当前文本发送")
            beginSyntheticAction(.directSend(snapshot: currentSnapshot, expectedTextBeforeSend: nil))
            return
        }

        switch result {
        case .success(let refinedText):
            logger.log("refine 输出预览：\(previewForLog(refinedText))")
            if refinedText == sourceText {
                logger.log("跳过：refine 未改变文本，直接发送")
                beginSyntheticAction(.directSend(snapshot: currentSnapshot, expectedTextBeforeSend: sourceText))
                return
            }

            if accessibility.usesTerminalRewrite(for: currentSnapshot.element) {
                logger.log("refine 回写：terminal rewrite 模式")
            }
            beginSyntheticAction(.rewriteThenSend(snapshot: currentSnapshot, refinedText: refinedText))
        case .failure(let error):
            logger.log("跳过：refine 失败（\(error.localizedDescription)），回退原文发送")
            beginSyntheticAction(.directSend(snapshot: currentSnapshot, expectedTextBeforeSend: nil))
        }
    }

    private func performEnterSend(
        snapshot: FocusedElementSnapshot? = nil,
        expectedTextBeforeSend: String? = nil
    ) -> Bool {
        accessibility.postEnter(
            enterKeyCode: config.enterKeyCode,
            for: snapshot?.element,
            expectedTextBeforeSend: expectedTextBeforeSend
        )
    }

    private func completeEnterSend(_ sendSucceeded: Bool) {
        resetWorkflowState()
        if sendSucceeded {
            logger.log("已确认发送 Enter")
        } else {
            logger.log("Enter 已触发，但未确认提交")
        }
    }

    private func beginSyntheticAction(_ action: SyntheticAction) {
        prepareForSyntheticActions()
        state.phase = .applying

        syntheticActionQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.executeSyntheticAction(action)
            DispatchQueue.main.async { [weak self] in
                self?.finishSyntheticAction(outcome)
            }
        }
    }

    private func executeSyntheticAction(_ action: SyntheticAction) -> SyntheticActionOutcome {
        switch action {
        case .directSend(let snapshot, let expectedTextBeforeSend):
            let sendSucceeded = performEnterSend(
                snapshot: snapshot,
                expectedTextBeforeSend: expectedTextBeforeSend
            )
            return .directSend(sendSucceeded: sendSucceeded)
        case .rewriteThenSend(let snapshot, let refinedText):
            if accessibility.writeText(refinedText, to: snapshot.element) {
                let sendSucceeded = performEnterSend(
                    snapshot: snapshot,
                    expectedTextBeforeSend: refinedText
                )
                return .rewriteSuccess(length: refinedText.count, sendSucceeded: sendSucceeded)
            }

            let summary: String?
            if accessibility.usesTerminalRewrite(for: snapshot.element) {
                summary = accessibility.terminalRewriteFailureSummary(
                    expectedText: refinedText,
                    for: snapshot.element
                )
            } else {
                summary = nil
            }
            let sendSucceeded = performEnterSend(snapshot: snapshot, expectedTextBeforeSend: nil)
            return .rewriteFailure(summary: summary, sendSucceeded: sendSucceeded)
        }
    }

    private func finishSyntheticAction(_ outcome: SyntheticActionOutcome) {
        switch outcome {
        case .directSend(let sendSucceeded):
            completeEnterSend(sendSucceeded)
        case .rewriteSuccess(let length, let sendSucceeded):
            logger.log("refine 回写成功，长度=\(length)")
            completeEnterSend(sendSucceeded)
        case .rewriteFailure(let summary, let sendSucceeded):
            if let summary {
                logger.log("refine 回写校验失败：\(summary)")
            }
            logger.log("跳过：refine 回写失败，回退原文发送")
            completeEnterSend(sendSucceeded)
        }
    }

    private func logSendBasis(forceByMaxWait: Bool = false) {
        let releaseBound = state.requiredReleaseDelay
        let stableBound = (state.lastValueChangedAt - state.releaseStartedAt) + config.stableDuration
        let tolerance = config.pollInterval

        let releaseBoundMs = Int(releaseBound * 1000)
        let stableBoundMs = Int(stableBound * 1000)

        if forceByMaxWait, let maxWaitAfterRelease = config.maxWaitAfterRelease {
            logger.log("触发依据：最大等待兜底（释放侧=\(releaseBoundMs)ms，稳定性=\(stableBoundMs)ms，最大等待=\(Int(maxWaitAfterRelease * 1000))ms）")
            return
        }

        if abs(releaseBound - stableBound) <= tolerance {
            logger.log("触发依据：释放侧下界与文本稳定性下界同时满足（释放侧=\(releaseBoundMs)ms，稳定性=\(stableBoundMs)ms）")
            return
        }

        if releaseBound > stableBound {
            logger.log("触发依据：释放侧下界（释放侧=\(releaseBoundMs)ms，稳定性=\(stableBoundMs)ms）")
            return
        }

        logger.log("触发依据：文本稳定性下界（释放侧=\(releaseBoundMs)ms，稳定性=\(stableBoundMs)ms）")
    }

    private func cancelPendingActions(reason: String) {
        guard state.phase != .idle || state.pendingPoll != nil || state.pendingRefineTask != nil else {
            return
        }

        state.pendingPoll?.cancel()
        state.pendingPoll = nil
        state.pendingRefineTask?.cancel()
        state.pendingRefineTask = nil
        resetWorkflowState()
        logger.log("取消待执行操作：\(reason)")
    }

    private func prepareForSyntheticActions() {
        state.pendingPoll?.cancel()
        state.pendingPoll = nil
        state.pendingRefineTask?.cancel()
        state.pendingRefineTask = nil
        state.activeRequestID = nil
    }

    private func resetWorkflowState() {
        restoreConsoleLoggingIfNeeded()
        state.pendingPoll = nil
        state.pendingRefineTask = nil
        state.activeRequestID = nil
        state.phase = .idle
        state.frontmostBundleAtRelease = nil
        state.releaseStartedAt = 0
        state.focusedValueAtRelease = nil
        state.lastObservedValue = nil
        state.lastValueChangedAt = 0
        state.requiredReleaseDelay = 0
        state.focusSnapshotAtRelease = nil
        state.loggedPendingTerminalInput = false
        state.loggedPendingRefineSettle = false
    }

    private func suppressConsoleLoggingForTerminal() {
        guard !state.consoleLoggingSuppressed else { return }
        logger.setConsoleOutputEnabled(false)
        state.consoleLoggingSuppressed = true
    }

    private func restoreConsoleLoggingIfNeeded() {
        guard state.consoleLoggingSuppressed else { return }
        logger.setConsoleOutputEnabled(true)
        state.consoleLoggingSuppressed = false
    }

    private func isDeniedApp(_ bundleID: String) -> Bool {
        config.deniedAppBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
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

    private func previewForLog(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count <= Self.refineInputPreviewLimit {
            return normalized
        }
        let endIndex = normalized.index(
            normalized.startIndex,
            offsetBy: Self.refineInputPreviewLimit
        )
        return "\(normalized[..<endIndex])..."
    }
}
