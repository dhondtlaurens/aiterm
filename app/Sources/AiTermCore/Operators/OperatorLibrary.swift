import Foundation

/// The operators on this Mac: one `<handle>.md` each (`OperatorFile`) in
/// `~/Library/Application Support/AiTerm/operators/`. The file is the operator — there is no
/// index to drift from it — so a file copied in by hand is an operator on the next load, and
/// Move to Trash really moves the file to the Trash, where it can be put back (spec §10).
///
/// Blocking file work, meant for `BackgroundWork` off the main actor.
public struct OperatorLibrary: Sendable {
    /// A file in the folder that is not an operator, and why, for the sidebar to say.
    public struct Unreadable: Equatable, Sendable {
        public var file: URL
        public var reason: String
        public init(file: URL, reason: String) { self.file = file; self.reason = reason }
    }

    public struct Loaded: Equatable, Sendable {
        /// By name as Finder sorts it, then by handle.
        public var operators: [OperatorPersona]
        public var unreadable: [Unreadable]
        public init(operators: [OperatorPersona] = [], unreadable: [Unreadable] = []) {
            self.operators = operators; self.unreadable = unreadable
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidHandle(String)
        case notFound(String)
        case alreadyExists(String)
        public var description: String {
            switch self {
            case .invalidHandle(let h): return "“\(h)” can't name an operator file."
            case .notFound(let h): return "There's no operator “\(h)”."
            case .alreadyExists(let h): return "There's already an operator file “\(h)”."
            }
        }
    }

    public let directory: URL
    /// Moves a file to the Trash and says where it went. `FileManager.trashItem` in the app; a
    /// test passes its own, so a run never fills the developer's Trash.
    let trasher: @Sendable (URL) throws -> URL?

    public init(directory: URL = OperatorLibrary.defaultDirectory(),
                trasher: @escaping @Sendable (URL) throws -> URL? = OperatorLibrary.moveToTrash) {
        self.directory = directory
        self.trasher = trasher
    }

    /// `operators/` in AiTerm's support folder; an operation's run folders are under it, in `runs/`.
    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        AiTermPaths.supportDirectory(home: home).appendingPathComponent("operators")
    }

    public static func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// A handle names a file and is typed in a sheet: lowercase letters, digits and inner dashes.
    public static func isValidHandle(_ handle: String) -> Bool {
        handle.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil && handle.count <= 64
    }

    public func url(for handle: String) -> URL { directory.appendingPathComponent(handle + ".md") }

    /// Every `*.md` directly in the folder. The file's name is the handle, whatever its frontmatter
    /// says: two files cannot share a name, so two operators cannot share a handle, even after a
    /// copy made by hand. A missing folder is an empty library.
    public func load() -> Loaded {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var operators: [OperatorPersona] = [], unreadable: [Unreadable] = []
        for name in names where name.hasSuffix(".md") && !name.hasPrefix(".") {
            let file = directory.appendingPathComponent(name)
            let handle = String(name.dropLast(3))
            do {
                guard Self.isValidHandle(handle) else { throw Failure.invalidHandle(handle) }
                let text = try String(contentsOf: file, encoding: .utf8)
                var persona = try OperatorFile.parse(text)
                persona.handle = handle
                operators.append(persona)
            } catch {
                unreadable.append(Unreadable(file: file, reason: Self.reason(error)))
            }
        }
        operators.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.handle < $1.handle : order == .orderedAscending
        }
        unreadable.sort { $0.file.lastPathComponent < $1.file.lastPathComponent }
        return Loaded(operators: operators, unreadable: unreadable)
    }

    private static func reason(_ error: any Error) -> String {
        switch error {
        case let e as OperatorFile.ParseError: return e.description
        case let e as Failure: return e.description
        default: return error.localizedDescription
        }
    }

    /// Writes `persona` to its file, atomically: a crash mid-save leaves the old file, never half
    /// of one. Creates the folder on the first save.
    public func save(_ persona: OperatorPersona) throws {
        guard Self.isValidHandle(persona.handle) else { throw Failure.invalidHandle(persona.handle) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(OperatorFile.render(persona).utf8).write(to: url(for: persona.handle), options: .atomic)
    }

    /// Writes a new operator's file and refuses, rather than replaces, one that is already there —
    /// whatever it holds, readable or not — so a name taken since the handle was chosen never costs
    /// another operator its persona and lessons. Written whole to a file of its own and then linked to
    /// its name, which the file system refuses if the name exists: no half-written operator, and no
    /// window between the check and the write.
    public func create(_ persona: OperatorPersona) throws {
        guard Self.isValidHandle(persona.handle) else { throw Failure.invalidHandle(persona.handle) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(persona.handle).\(UUID().uuidString).tmp")
        try Data(OperatorFile.render(persona).utf8).write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard link(staging.path, url(for: persona.handle).path) == 0 else {
            if errno == EEXIST { throw Failure.alreadyExists(persona.handle) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Moves the operator's file to the Trash and says where it went. Operations already running
    /// keep their snapshot (spec §10).
    @discardableResult
    public func trash(handle: String) throws -> URL? {
        let file = url(for: handle)
        guard Self.isValidHandle(handle), FileManager.default.fileExists(atPath: file.path) else { throw Failure.notFound(handle) }
        return try trasher(file)
    }

    /// A kept lesson, appended to the operator's file under `## Lessons` (spec §4.5). Read from
    /// the file, not from a snapshot, so an edit made since is kept.
    public func appendLesson(_ lesson: String, to handle: String) throws {
        let file = url(for: handle)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.notFound(handle) }
        var persona = try OperatorFile.parse(String(contentsOf: file, encoding: .utf8))
        persona.handle = handle
        let line = lesson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !persona.lessons.contains(line) else { return }
        persona.lessons.append(line)
        try save(persona)
    }

    /// The handle a new operator called `name` gets: its name in lowercase words joined by dashes,
    /// and `-2`, `-3`… past the ones taken. Compared without case, as the Mac's file system does.
    /// `excluding` is the operator being renamed, whose own handle is not in the way.
    public func uniqueHandle(for name: String, excluding: String? = nil) -> String {
        Self.handle(for: name, taken: takenHandles().subtracting([excluding?.lowercased()].compactMap { $0 }))
    }

    /// The names the folder's files hold, lowercased: every `*.md`, an operator or not, since a new
    /// operator's file must not land on one of them. What the operator sheet is told is taken.
    public func takenHandles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)).lowercased() })
    }

    /// `name` as a handle, free among `taken` (compared without case): the one rule `uniqueHandle` and
    /// the operator sheet both name a new operator's file by.
    public static func handle(for name: String, taken: Set<String>) -> String {
        let words = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let base = String(words.joined(separator: "-").prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = isValidHandle(base) ? base : "operator"
        let taken = Set(taken.map { $0.lowercased() })
        guard taken.contains(stem) else { return stem }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }
}
