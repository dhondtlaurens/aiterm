import Foundation

/// One step that brings a saved workspace from the format before `version` into `version`'s. AiTerm
/// reads only its own format: a release that changes what it saves adds one of these to
/// `UpdateScripts.all`, versioned as that release at any level, and no decoder reads an older or a
/// newer shape. Each runs once per workspace, in order, so a person who skipped releases goes through
/// every step in between.
public struct UpdateScript: Sendable {
    /// The release whose format this step produces: major, minor or patch.
    public let version: ReleaseVersion
    /// What the step changes, for the log and the tests.
    public let summary: String
    public let run: @Sendable (inout UpdateContext) throws -> Void

    public init(version: ReleaseVersion, summary: String, run: @escaping @Sendable (inout UpdateContext) throws -> Void) {
        self.version = version; self.summary = summary; self.run = run
    }
}

/// What an update script may change: the workspace as it is saved, untyped, since the build's own
/// types read only its own format; and AiTerm's preferences and files. A step that changes anything
/// outside `state` does so idempotently: a crash after it runs the step again on the next launch.
public struct UpdateContext {
    public var state: JSONValue
    public let defaults: UserDefaults
    /// `~/Library/Application Support/AiTerm`, beside `state.json`.
    public let supportDirectory: URL
    /// The person's home folder, for the agent settings AiTerm writes into.
    public let home: URL

    public init(state: JSONValue, defaults: UserDefaults, supportDirectory: URL, home: URL) {
        self.state = state; self.defaults = defaults; self.supportDirectory = supportDirectory; self.home = home
    }
}

extension JSONValue {
    /// Runs `body` on the member `key` when this is an object that has it.
    public mutating func edit(_ key: String, _ body: (inout JSONValue) throws -> Void) rethrows {
        guard var member = self[key] else { return }
        try body(&member)
        self[key] = member
    }

    /// Runs `body` on each element when this is an array.
    public mutating func editEach(_ body: (inout JSONValue) throws -> Void) rethrows {
        guard case .array(var elements) = self else { return }
        for index in elements.indices { try body(&elements[index]) }
        self = .array(elements)
    }

    /// Sets the member `key` to `value` when this is an object without it.
    public mutating func fill(_ key: String, with value: JSONValue) {
        if case .object = self, self[key] == nil { self[key] = value }
    }
}
