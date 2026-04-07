import ApplicationServices
import Carbon
import Cocoa
import CoreGraphics
import Foundation

struct FocusedElementSnapshot {
    let bundleID: String?
    let element: AXUIElement
    let text: String?
}

private struct TerminalEditContext {
    let inputText: String
    let caretOffset: Int
}

private struct TerminalLineSegment {
    let lineRange: NSRange
    let segmentStart: Int
    let text: String
}

final class AccessibilityService {
    func currentInputSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func frontmostApplicationDescription() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "未知"
        }
        let name = app.localizedName ?? "未知"
        let bundleID = app.bundleIdentifier ?? "未知"
        return "\(name) (\(bundleID))"
    }

    func captureFocusedElementSnapshot() -> FocusedElementSnapshot? {
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
        return FocusedElementSnapshot(
            bundleID: app.bundleIdentifier,
            element: element,
            text: readText(from: element)
        )
    }

    func readText(from element: AXUIElement) -> String? {
        if isTerminalShellElement(element) {
            return sanitizedTerminalInputText(terminalEditContext(from: element)?.inputText ?? "")
        }

        let attributeNames = [kAXValueAttribute, kAXSelectedTextAttribute]
        for attribute in attributeNames {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            guard error == .success, let value else { continue }
            if let stringValue = extractString(from: value) {
                return stringValue
            }
        }
        return nil
    }

    func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    func usesTerminalRewrite(for element: AXUIElement) -> Bool {
        isTerminalShellElement(element)
    }

    func terminalReadFailureSummary(for element: AXUIElement) -> String {
        let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? "nil"
        let description = stringAttribute(kAXDescriptionAttribute as String, from: element) ?? "nil"

        var rawValue: CFTypeRef?
        let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &rawValue)
        let valueType = rawValue.map { String(describing: CFCopyTypeIDDescription(CFGetTypeID($0))) } ?? "nil"

        let selectedRange: String
        if let range = rangeAttribute(kAXSelectedTextRangeAttribute as String, from: element) {
            selectedRange = "\(range.location):\(range.length)"
        } else {
            selectedRange = "nil"
        }

        return "role=\(role), description=\(description), valueError=\(valueError.rawValue), valueType=\(valueType), selectedRange=\(selectedRange)"
    }

    func terminalRewriteFailureSummary(expectedText: String, for element: AXUIElement) -> String {
        let expectedPreview = terminalPreview(normalizeTerminalText(expectedText))
        guard let fullText = stringAttribute(kAXValueAttribute as String, from: element) else {
            return "expected=\(expectedPreview), selected=<nil>, tail=<nil>"
        }

        let bufferNSString = fullText.replacingOccurrences(of: "\0", with: "") as NSString
        let selectedPreview: String
        if let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute as String, from: element),
           let selectionContext = terminalEditContext(from: bufferNSString, selectedRange: selectedRange) {
            selectedPreview = terminalPreview(normalizeTerminalText(selectionContext.inputText))
        } else {
            selectedPreview = "<nil>"
        }

        let tailPreview: String
        if let tailContext = terminalEditContextFromBufferTail(bufferNSString) {
            tailPreview = terminalPreview(normalizeTerminalText(tailContext.inputText))
        } else {
            tailPreview = "<nil>"
        }

        return "expected=\(expectedPreview), selected=\(selectedPreview), tail=\(tailPreview)"
    }

    func writeText(_ text: String, to element: AXUIElement) -> Bool {
        if isTerminalShellElement(element) {
            return rewriteTerminalInput(text, in: element)
        }

        let setError = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        if setError == .success, readValueOnly(from: element) == text {
            return true
        }
        return false
    }

    func postEnter(
        enterKeyCode: CGKeyCode,
        for element: AXUIElement? = nil,
        expectedTextBeforeSend: String? = nil
    ) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let normalizedExpectedBeforeSend: String?
        if let element, isTerminalShellElement(element) {
            normalizedExpectedBeforeSend = sanitizedTerminalInputText(
                expectedTextBeforeSend ?? terminalEditContext(from: element)?.inputText ?? ""
            )
            Thread.sleep(forTimeInterval: 0.12)
        } else {
            normalizedExpectedBeforeSend = nil
        }

        guard postKeyPress(keyCode: enterKeyCode, source: source) else {
            return false
        }

        guard let element,
              isTerminalShellElement(element),
              let normalizedExpectedBeforeSend,
              !normalizedExpectedBeforeSend.isEmpty else {
            return true
        }

        if waitForTerminalSubmission(
            in: element,
            previousInput: normalizedExpectedBeforeSend
        ) {
            return true
        }

        Thread.sleep(forTimeInterval: 0.08)
        guard postKeyPress(keyCode: 76, source: source) else {
            return false
        }
        return waitForTerminalSubmission(
            in: element,
            previousInput: normalizedExpectedBeforeSend
        )
    }

    private func readValueOnly(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard error == .success, let value, let stringValue = value as? String else {
            return nil
        }
        return stringValue
    }

    private func rewriteTerminalInput(_ text: String, in element: AXUIElement) -> Bool {
        guard let context = terminalEditContext(from: element) else {
            return false
        }

        let normalizedTarget = normalizeTerminalText(text)
        if normalizeTerminalText(context.inputText) == normalizedTarget {
            return true
        }

        guard clearTerminalInput(in: element, initialContext: context) else {
            return false
        }

        Thread.sleep(forTimeInterval: 0.03)
        if pasteTerminalText(text, into: element) {
            return true
        }
        guard postUnicodeText(text) else {
            return false
        }
        return waitForTerminalRewrite(text, in: element)
    }

    private func waitForTerminalRewrite(_ expectedText: String, in element: AXUIElement) -> Bool {
        let timeout: TimeInterval = 0.5
        let pollInterval: TimeInterval = 0.02
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if terminalInputMatches(expectedText, in: element) {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline

        return terminalInputMatches(expectedText, in: element)
    }

    private func clearTerminalInput(
        in element: AXUIElement,
        initialContext: TerminalEditContext
    ) -> Bool {
        var context = initialContext
        let maxAttempts = 3

        for attempt in 0..<maxAttempts {
            let movesToEnd = max(0, context.inputText.count - context.caretOffset)
            guard pressKeyRepeated(keyCode: 124, count: movesToEnd, interKeyDelay: 0.003) else {
                return false
            }

            guard pressKeyRepeated(keyCode: 51, count: context.inputText.count, interKeyDelay: 0.003) else {
                return false
            }

            if waitForTerminalInputToClear(in: element) {
                return true
            }

            guard attempt < maxAttempts - 1 else {
                break
            }

            Thread.sleep(forTimeInterval: 0.03)
            guard let refreshedContext = terminalEditContext(from: element) else {
                return false
            }
            context = refreshedContext
        }

        return waitForTerminalInputToClear(in: element)
    }

    private func waitForTerminalInputToClear(in element: AXUIElement) -> Bool {
        let timeout: TimeInterval = 0.35
        let pollInterval: TimeInterval = 0.02
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if currentTerminalInputText(in: element).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline

        return currentTerminalInputText(in: element).isEmpty
    }

    private func waitForTerminalSubmission(in element: AXUIElement, previousInput: String) -> Bool {
        let timeout: TimeInterval = 0.8
        let pollInterval: TimeInterval = 0.03
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            let currentInput = sanitizedTerminalInputText(terminalEditContext(from: element)?.inputText ?? "")
            if currentInput.isEmpty || currentInput != previousInput {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline

        let finalInput = sanitizedTerminalInputText(terminalEditContext(from: element)?.inputText ?? "")
        return finalInput.isEmpty || finalInput != previousInput
    }

    private func terminalInputMatches(_ expectedText: String, in element: AXUIElement) -> Bool {
        let normalizedExpected = sanitizedTerminalInputText(expectedText)
        guard let fullText = stringAttribute(kAXValueAttribute as String, from: element) else {
            return false
        }

        let bufferNSString = fullText.replacingOccurrences(of: "\0", with: "") as NSString

        if let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute as String, from: element),
           let selectionContext = terminalEditContext(
               from: bufferNSString,
               selectedRange: selectedRange
           ),
           sanitizedTerminalInputText(selectionContext.inputText) == normalizedExpected {
            return true
        }

        if let tailContext = terminalEditContextFromBufferTail(bufferNSString),
           sanitizedTerminalInputText(tailContext.inputText) == normalizedExpected {
            return true
        }

        return false
    }

    private func currentTerminalInputText(in element: AXUIElement) -> String {
        sanitizedTerminalInputText(terminalEditContext(from: element)?.inputText ?? "")
    }

    private func normalizeTerminalText(_ text: String) -> String {
        trimmingTrailingLineBreaks(
            from: text
                .replacingOccurrences(of: "\0", with: "")
                .replacingOccurrences(of: "\r\n", with: "\n")
        )
    }

    private func sanitizedTerminalInputText(_ text: String) -> String {
        let normalized = normalizeTerminalText(text)
        guard !normalized.isEmpty else {
            return ""
        }

        var keptLines = normalized.components(separatedBy: "\n").filter { line in
            !shouldIgnoreTerminalInputLine(line)
        }

        while let first = keptLines.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keptLines.removeFirst()
        }

        while let last = keptLines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keptLines.removeLast()
        }

        return keptLines.joined(separator: "\n")
    }

    private func terminalPreview(_ text: String, limit: Int = 120) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count <= limit {
            return normalized
        }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return "\(normalized[..<endIndex])..."
    }

    private func terminalEditContext(from element: AXUIElement) -> TerminalEditContext? {
        guard isTerminalShellElement(element) else {
            return nil
        }

        guard let fullText = stringAttribute(kAXValueAttribute as String, from: element) else {
            return nil
        }

        let bufferNSString = fullText.replacingOccurrences(of: "\0", with: "") as NSString
        if let selectedRange = rangeAttribute(kAXSelectedTextRangeAttribute as String, from: element),
           let selectionContext = terminalEditContext(
               from: bufferNSString,
               selectedRange: selectedRange
           ) {
            return selectionContext
        }

        return terminalEditContextFromBufferTail(bufferNSString)
    }

    private func terminalEditContext(
        from bufferNSString: NSString,
        selectedRange: CFRange
    ) -> TerminalEditContext? {
        let lineRange = effectiveCurrentLineRange(
            in: bufferNSString,
            selectedRange: selectedRange
        )
        return terminalEditContext(
            from: bufferNSString,
            lineRange: lineRange,
            selectedRange: selectedRange
        )
    }

    private func terminalEditContext(
        from bufferNSString: NSString,
        lineRange: NSRange,
        selectedRange: CFRange?
    ) -> TerminalEditContext? {
        let segments = terminalLineSegments(
            in: bufferNSString,
            currentLineRange: lineRange,
            selectedRange: selectedRange
        )
        guard !segments.isEmpty else {
            return nil
        }

        let inputText = segments.map(\.text).joined()
        let caretOffset = terminalCaretOffset(
            selectedRange: selectedRange,
            inputText: inputText,
            segments: segments,
            buffer: bufferNSString
        )
        return TerminalEditContext(inputText: inputText, caretOffset: caretOffset)
    }

    private func terminalEditContextFromBufferTail(_ bufferNSString: NSString) -> TerminalEditContext? {
        let trailingTrimmed = trimmingTrailingLineBreaks(from: bufferNSString as String)
        let trimmedNSString = trailingTrimmed as NSString
        guard trimmedNSString.length > 0 else {
            return nil
        }

        let lastLineRange = lastNonAuxiliaryLineRange(in: trimmedNSString)
            ?? currentLineRange(
                in: trimmedNSString,
                selectedRange: CFRange(location: trimmedNSString.length, length: 0)
            )
        if let context = terminalEditContext(
            from: trimmedNSString,
            lineRange: lastLineRange,
            selectedRange: nil
        ) {
            return context
        }

        if let promptRange = lastPromptLineRange(in: trimmedNSString),
           let context = terminalEditContext(
               from: trimmedNSString,
               lineRange: promptRange,
               selectedRange: nil
           ) {
            return context
        }

        let lastLine = trimmedNSString.substring(with: lastLineRange)
        guard !lastLine.isEmpty else {
            return nil
        }
        return TerminalEditContext(inputText: lastLine, caretOffset: lastLine.count)
    }

    private func effectiveCurrentLineRange(in buffer: NSString, selectedRange: CFRange) -> NSRange {
        var lineRange = currentLineRange(in: buffer, selectedRange: selectedRange)
        while lineRange.length > 0 {
            let lineText = buffer.substring(with: lineRange)
            if !isTerminalAuxiliaryLine(lineText) {
                return lineRange
            }
            guard let previousLineRange = previousNonAuxiliaryLineRange(in: buffer, before: lineRange) else {
                return lineRange
            }
            lineRange = previousLineRange
        }
        return lineRange
    }

    private func currentLineRange(in buffer: NSString, selectedRange: CFRange) -> NSRange {
        let bufferLength = buffer.length
        let caretLocation = min(max(selectedRange.location, 0), bufferLength)

        let prefixRange = NSRange(location: 0, length: caretLocation)
        let previousNewlineRange = buffer.range(
            of: "\n",
            options: .backwards,
            range: prefixRange
        )
        let lineStart = previousNewlineRange.location == NSNotFound
            ? 0
            : previousNewlineRange.location + previousNewlineRange.length

        let suffixRange = NSRange(location: caretLocation, length: bufferLength - caretLocation)
        let nextNewlineRange = buffer.range(
            of: "\n",
            options: [],
            range: suffixRange
        )
        let lineEnd = nextNewlineRange.location == NSNotFound
            ? bufferLength
            : nextNewlineRange.location

        return NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
    }

    private func inputStartOffset(in lineNSString: NSString, lineText: String) -> Int? {
        let leadingPromptMarkers = ["$ ", "# ", "% ", "> ", "› ", "❯ ", "➜ "]
        for marker in leadingPromptMarkers where lineText.hasPrefix(marker) {
            let markerLength = (marker as NSString).length
            guard markerLength <= lineNSString.length else {
                return nil
            }
            return markerLength
        }

        let infixPromptMarkers = [" $ ", " # ", " % ", " > ", " › ", " ❯ ", " ➜ "]
        for marker in infixPromptMarkers {
            let markerRange = lineNSString.range(of: marker, options: .backwards)
            guard markerRange.location != NSNotFound else {
                continue
            }

            let inputStart = markerRange.location + markerRange.length
            guard inputStart <= lineNSString.length else {
                continue
            }
            return inputStart
        }

        return nil
    }

    private func lastPromptLineRange(in buffer: NSString) -> NSRange? {
        let leadingPromptMarkers = ["\n$ ", "\n# ", "\n% ", "\n> ", "\n› ", "\n❯ ", "\n➜ "]
        let fullRange = NSRange(location: 0, length: buffer.length)
        var bestRange: NSRange?

        for marker in leadingPromptMarkers {
            let markerRange = buffer.range(of: marker, options: .backwards, range: fullRange)
            guard markerRange.location != NSNotFound else {
                continue
            }

            let lineStart = markerRange.location + 1
            let lineRange = lineRangeStarting(at: lineStart, in: buffer)
            if bestRange == nil || lineStart > bestRange!.location {
                bestRange = lineRange
            }
        }

        let startOfBufferPromptMarkers = ["$ ", "# ", "% ", "> ", "› ", "❯ ", "➜ "]
        for marker in startOfBufferPromptMarkers {
            if buffer.hasPrefix(marker) {
                let lineRange = lineRangeStarting(at: 0, in: buffer)
                if bestRange == nil || 0 > bestRange!.location {
                    bestRange = lineRange
                }
                break
            }
        }

        return bestRange
    }

    private func terminalCaretOffset(
        selectedRange: CFRange?,
        inputText: String,
        segments: [TerminalLineSegment],
        buffer: NSString
    ) -> Int {
        guard let selectedRange, selectedRange.length == 0 else {
            return inputText.count
        }

        let caretLocation = selectedRange.location
        var prefixCount = 0

        for segment in segments {
            let segmentAbsoluteStart = segment.lineRange.location + segment.segmentStart
            let segmentAbsoluteEnd = segment.lineRange.location + segment.lineRange.length

            if caretLocation >= segmentAbsoluteEnd {
                prefixCount += segment.text.count
                continue
            }

            if caretLocation <= segmentAbsoluteStart {
                return prefixCount
            }

            let caretUTF16Offset = max(0, caretLocation - segmentAbsoluteStart)
            let lineText = buffer.substring(with: segment.lineRange) as NSString
            let prefix = lineText.substring(
                with: NSRange(location: segment.segmentStart, length: caretUTF16Offset)
            )
            return prefixCount + prefix.count
        }

        return inputText.count
    }

    private func terminalLineSegments(
        in buffer: NSString,
        currentLineRange: NSRange,
        selectedRange: CFRange?
    ) -> [TerminalLineSegment] {
        guard currentLineRange.length > 0 else {
            return []
        }

        var collectedLines: [(range: NSRange, text: String)] = [
            (currentLineRange, buffer.substring(with: currentLineRange))
        ]
        var searchRange = currentLineRange
        let maxLookbackLines = 12

        for _ in 0..<maxLookbackLines {
            let firstLine = collectedLines[0]
            let lineNSString = firstLine.text as NSString
            if let inputStart = inputStartOffset(in: lineNSString, lineText: firstLine.text) {
                return collectedLines.enumerated().compactMap { index, line in
                    let segmentStart = index == 0 ? inputStart : 0
                    let segmentEnd = lineSegmentEnd(
                        for: line.range,
                        lineText: line.text as NSString,
                        selectedRange: selectedRange,
                        isCurrentLine: index == collectedLines.count - 1
                    )
                    guard segmentStart <= segmentEnd else {
                        return TerminalLineSegment(
                            lineRange: line.range,
                            segmentStart: segmentStart,
                            text: ""
                        )
                    }
                    let segmentText = (line.text as NSString).substring(
                        with: NSRange(location: segmentStart, length: segmentEnd - segmentStart)
                    )
                    if shouldIgnoreTerminalInputLine(segmentText) {
                        return nil
                    }
                    return TerminalLineSegment(
                        lineRange: line.range,
                        segmentStart: segmentStart,
                        text: segmentText
                    )
                }
            }

            guard let previousLineRange = previousLineRange(in: buffer, before: searchRange) else {
                break
            }
            collectedLines.insert(
                (previousLineRange, buffer.substring(with: previousLineRange)),
                at: 0
            )
            searchRange = previousLineRange
        }

        return []
    }

    private func lineSegmentEnd(
        for lineRange: NSRange,
        lineText: NSString,
        selectedRange: CFRange?,
        isCurrentLine: Bool
    ) -> Int {
        guard isCurrentLine, let selectedRange, selectedRange.length == 0 else {
            return lineText.length
        }

        let relativeCaret = selectedRange.location - lineRange.location
        return min(max(relativeCaret, 0), lineText.length)
    }

    private func previousLineRange(in buffer: NSString, before lineRange: NSRange) -> NSRange? {
        guard lineRange.location > 0 else {
            return nil
        }

        let previousLineEnd = lineRange.location - 1
        let prefixRange = NSRange(location: 0, length: previousLineEnd)
        let previousNewlineRange = buffer.range(
            of: "\n",
            options: .backwards,
            range: prefixRange
        )
        let previousLineStart = previousNewlineRange.location == NSNotFound
            ? 0
            : previousNewlineRange.location + previousNewlineRange.length
        return NSRange(
            location: previousLineStart,
            length: max(0, previousLineEnd - previousLineStart)
        )
    }

    private func previousNonAuxiliaryLineRange(in buffer: NSString, before lineRange: NSRange) -> NSRange? {
        var candidate = previousLineRange(in: buffer, before: lineRange)
        while let current = candidate {
            let text = buffer.substring(with: current)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !isTerminalAuxiliaryLine(text) {
                return current
            }
            candidate = previousLineRange(in: buffer, before: current)
        }
        return nil
    }

    private func lastNonAuxiliaryLineRange(in buffer: NSString) -> NSRange? {
        var candidate = currentLineRange(
            in: buffer,
            selectedRange: CFRange(location: buffer.length, length: 0)
        )
        while candidate.length > 0 {
            let text = buffer.substring(with: candidate)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !isTerminalAuxiliaryLine(text) {
                return candidate
            }
            guard let previous = previousLineRange(in: buffer, before: candidate) else {
                return nil
            }
            candidate = previous
        }
        return nil
    }

    private func lineRangeStarting(at lineStart: Int, in buffer: NSString) -> NSRange {
        let clampedStart = min(max(lineStart, 0), buffer.length)
        let suffixRange = NSRange(location: clampedStart, length: buffer.length - clampedStart)
        let nextNewlineRange = buffer.range(
            of: "\n",
            options: [],
            range: suffixRange
        )
        let lineEnd = nextNewlineRange.location == NSNotFound
            ? buffer.length
            : nextNewlineRange.location
        return NSRange(location: clampedStart, length: max(0, lineEnd - clampedStart))
    }

    private func isTerminalAuxiliaryLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if looksLikeRuntimeLogLine(trimmed) {
            return true
        }

        let lowercase = trimmed.lowercased()
        let codexHintTokens = [
            "? for shortcuts",
            "tab to queue message",
            "queue message",
            "shift+tab",
            "enter to send",
            "esc to edit",
            "⏎ send",
            "shift+⏎ newline",
            "ctrl+t transcript",
            "ctrl+c quit"
        ]
        if codexHintTokens.contains(where: { lowercase.contains($0) }) {
            return true
        }

        if lowercase.contains("to get started, describe a task") {
            return true
        }

        let codexStartupCommandHints = [
            "/init - create an agents.md",
            "/status - show current session",
            "/approvals - choose what codex",
            "/model - choose what model"
        ]
        if codexStartupCommandHints.contains(where: { lowercase.contains($0) }) {
            return true
        }

        let separatorCount = trimmed.components(separatedBy: " · ").count - 1
        let codexStatusTokens = [
            "gpt-",
            "% left",
            "% used",
            "weekly ",
            "window",
            "xhigh",
            "fast",
            "~/",
            "feat/",
            "main ·"
        ]

        if separatorCount >= 3,
           codexStatusTokens.contains(where: { trimmed.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        return false
    }

    private func shouldIgnoreTerminalInputLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        return isTerminalAuxiliaryLine(trimmed) || isTerminalPlaceholderOnlyLine(trimmed)
    }

    private func isTerminalPlaceholderOnlyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if trimmed.caseInsensitiveCompare("Implement {feature}") == .orderedSame {
            return true
        }

        return false
    }

    private func looksLikeRuntimeLogLine(_ line: String) -> Bool {
        guard line.hasPrefix("[20"),
              let closingBracketIndex = line.firstIndex(of: "]") else {
            return false
        }

        let timestampPortion = line[line.index(after: line.startIndex)..<closingBracketIndex]
        return timestampPortion.contains("T")
    }

    private func isTerminalShellElement(_ element: AXUIElement) -> Bool {
        guard stringAttribute(kAXRoleAttribute as String, from: element) == (kAXTextAreaRole as String) else {
            return false
        }
        return stringAttribute(kAXDescriptionAttribute as String, from: element) == "shell"
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value, let stringValue = extractString(from: value) else {
            return nil
        }
        return stringValue
    }

    private func extractString(from value: CFTypeRef) -> String? {
        if let stringValue = value as? String {
            return stringValue
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private func rangeAttribute(_ attribute: String, from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }
        return decodeAXRangeValue(value)
    }

    private func decodeAXRangeValue(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange()
        AXValueGetValue(axValue, .cfRange, &range)
        return range
    }

    private func trimmingTrailingLineBreaks(from text: String) -> String {
        var trimmed = text
        while let last = trimmed.last, last.isNewline {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func pressKeyRepeated(
        keyCode: CGKeyCode,
        count: Int,
        interKeyDelay: TimeInterval = 0
    ) -> Bool {
        guard count >= 0 else {
            return false
        }

        if count == 0 {
            return true
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                return false
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if interKeyDelay > 0 {
                Thread.sleep(forTimeInterval: interKeyDelay)
            }
        }
        return true
    }

    private func postKeyPress(keyCode: CGKeyCode, source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func pasteTerminalText(_ text: String, into element: AXUIElement) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboardItems(from: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboardItems(snapshot, to: pasteboard)
            return false
        }
        guard pressModifiedKey(keyCode: 9, flags: .maskCommand) else {
            restorePasteboardItems(snapshot, to: pasteboard)
            return false
        }

        let matched = waitForTerminalRewrite(text, in: element)
        restorePasteboardItems(snapshot, to: pasteboard)
        return matched
    }

    private func pressModifiedKey(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func snapshotPasteboardItems(from pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else {
            return []
        }
        return items.map { item in
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot[type] = data
                }
            }
            return snapshot
        }
    }

    private func restorePasteboardItems(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else {
            return
        }

        let restoredItems = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

    private func postUnicodeText(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        let unicodeScalars = Array(text.utf16)
        keyDown.keyboardSetUnicodeString(
            stringLength: unicodeScalars.count,
            unicodeString: unicodeScalars
        )
        keyUp.keyboardSetUnicodeString(
            stringLength: unicodeScalars.count,
            unicodeString: unicodeScalars
        )
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
