import AppKit

/// Reads a hosted view through AppKit's accessibility tree, as VoiceOver does.
@MainActor enum AccessibilityTree {
    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    /// Enhanced UI is an application attribute, so scope it to one synchronous host check.
    /// Restore the process's previous value on every exit, including a thrown test failure.
    static func with<T>(_ body: () throws -> T) rethrows -> T {
        let app = NSApplication.shared
        let previous = app.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        return try body()
    }

    /// SwiftUI's virtual nodes expose accessibility methods without conforming to the
    /// full NSAccessibilityProtocol. Read their public ObjC methods or legacy attributes.
    static func value(_ attribute: NSAccessibility.Attribute, getter: String, of node: NSObject) -> Any? {
        let selector = NSSelectorFromString(getter)
        if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() { return value }
        return node.accessibilityAttributeValue(attribute)
    }

    static func elements(_ root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ node: NSObject, depth: Int) -> [NSObject] {
            guard depth < 32, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children = value(.children, getter: "accessibilityChildren", of: node) as? [NSObject] ?? []
            return [node] + children.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }

    /// Presses a node as VoiceOver does: SwiftUI's nodes answer the ObjC method, AppKit's the legacy action.
    static func press(_ node: NSObject) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if node.responds(to: selector) { _ = node.perform(selector) } else { node.accessibilityPerformAction(.press) }
    }

    static func role(of node: NSObject) -> String? { value(.role, getter: "accessibilityRole", of: node) as? String }
    static func label(of node: NSObject) -> String? { value(.description, getter: "accessibilityLabel", of: node) as? String }
    static func help(of node: NSObject) -> String? { value(.help, getter: "accessibilityHelp", of: node) as? String }
}
