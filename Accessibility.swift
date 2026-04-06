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

    func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    func writeText(_ text: String, to element: AXUIElement) -> Bool {
        let setError = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        guard setError == .success else {
            return false
        }
        return readValueOnly(from: element) == text
    }

    func postEnter(enterKeyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        let down = CGEvent(keyboardEventSource: source, virtualKey: enterKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: enterKeyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }

    private func readValueOnly(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard error == .success, let value, let stringValue = value as? String else {
            return nil
        }
        return stringValue
    }
}
