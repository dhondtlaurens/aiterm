import Foundation
import Testing

/// Core's folders depend on one another in one direction only. Core is one module, so the compiler
/// lets any file name any type; this reads the source instead. The files directly in
/// `Sources/AiTermCore` — the process, shell, HTTP and log plumbing, and the saved model
/// (`Models.swift`) — are the bottom and name no folder's types. The folders that wrap one tool or
/// service (Git, Daemon, Hooks, Jira, GitHub, GitLab) sit on that; Agents, Harnesses, Workspace,
/// Sidebar, Tasks and Updates on those; Interface and Geometry on top. A folder may name another's
/// types only if that one names none of its own, directly or round a loop: a loop is what would
/// stop Core being split into targets along its folders (ARCH-12).
///
/// A folder names a type when its code, comments and string literals left out, spells a name that
/// another folder declares at the top level of a file (a type, a typealias, a non-private global).
/// That is cheap and blind to members: a property one folder adds to another's type in an extension
/// is not seen — `LoginShellLocator`'s default names reach `AgentKind.harness`, which Harnesses
/// adds, and this does not count it.
struct CoreFoldersTests {
    /// What stands for the files directly in `Sources/AiTermCore`, which are in no folder.
    private static let root = "(root)"

    @Test func coreFoldersFormNoLoop() throws {
        let edges = try Self.edges(Self.sources())
        let loops = edges.keys.sorted().flatMap { from in
            edges[from, default: [:]].keys.sorted().compactMap { to -> String? in
                guard Self.reaches(from: to, to: from, edges) else { return nil }
                let names = edges[from]![to]!.sorted().prefix(4).joined(separator: ", ")
                return "\(from) → \(to) (\(names))"
            }
        }
        #expect(loops.isEmpty, """
            Core's folders depend on each other in a loop. Move the type to the folder it belongs to, \
            or move what names it up a folder: \(loops)
            """)
    }

    /// The scan itself, so one that quietly reads nothing cannot pass the check above.
    @Test func theScanSeesWhatFoldersName() throws {
        let edges = try Self.edges(Self.sources())
        #expect(edges["Workspace"]?["Git"]?.contains("Worktree@AppState+Workspace.swift") == true)
        #expect(edges["Tasks"]?["GitHub"] != nil, "MergeRequestSearch names GitHubClient")
        #expect(edges["Git"]?[Self.root] != nil, "Git names the model's Project and TaskItem")

        let code = Self.code(#"""
            /// Names `Worktree`.
            let a = "Worktree" + #"Repository"# /* Project */ + """
                TaskItem
                """
            let b = Harness.claude // Log
            """#)
        let names = Set(code.matches(of: /[A-Za-z_]\w*/).map { String($0.output) })
        #expect(names.isDisjoint(with: ["Worktree", "Repository", "Project", "TaskItem", "Log"]), "\(names)")
        #expect(names.isSuperset(of: ["a", "b", "Harness", "claude"]))
        #expect(code.components(separatedBy: "\n").count == 5, "a skipped comment or string lost its lines")
    }

    // MARK: - The scan

    /// Every Swift file in Core: the folder it is in, its path there, and its code.
    private static func sources() throws -> [(folder: String, file: String, code: String)] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AiTermCore")
        let enumerator = try #require(FileManager.default.enumerator(atPath: directory.path))
        let files = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files.contains("Models.swift") && files.count > 50, "the scan is not reading AiTermCore")
        return try files.map { file in
            let parts = file.split(separator: "/")
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            return (parts.count > 1 ? String(parts[0]) : root, String(parts.last!), code(source))
        }
    }

    /// For each folder, the folders whose types it names, each with the names as `Type@File.swift`.
    private static func edges(_ sources: [(folder: String, file: String, code: String)]) -> [String: [String: Set<String>]] {
        // A top-level declaration: attributes and modifiers, then what it declares and its name. A
        // private or fileprivate one is captured as `access`, since no other file can name it.
        let declaration = /(?:@[\w.]+(?:\([^)\n]*\))?\s+)*(?:(?:public|package|internal|final|nonisolated|indirect|open)\s+|(?<access>private|fileprivate)\s+)*(?:struct|class|enum|protocol|actor|typealias|func|let|var)\s+`?(?<name>[A-Za-z_]\w*)/
        var owners: [String: Set<String>] = [:]
        for source in sources {
            for line in source.code.split(separator: "\n") {
                guard let match = line.prefixMatch(of: declaration), match.output.access == nil else { continue }
                owners[String(match.output.name), default: []].insert(source.folder)
            }
        }
        var edges: [String: [String: Set<String>]] = [:]
        for source in sources {
            for name in Set(source.code.matches(of: /[A-Za-z_]\w*/).map { String($0.output) }) {
                // A name declared in this folder too is this folder's own.
                guard let folders = owners[name], !folders.contains(source.folder) else { continue }
                for folder in folders { edges[source.folder, default: [:]][folder, default: []].insert("\(name)@\(source.file)") }
            }
        }
        return edges
    }

    private static func reaches(from start: String, to goal: String, _ edges: [String: [String: Set<String>]]) -> Bool {
        var seen: Set<String> = [], queue = [start]
        while let next = queue.popLast() {
            if next == goal { return true }
            guard seen.insert(next).inserted else { continue }
            queue += edges[next, default: [:]].keys
        }
        return false
    }

    /// `source` with its comments and the text of its string literals — plain, raw (`#"…"#`) and
    /// multi-line — blanked, keeping their line breaks so a declaration still starts its line. An
    /// interpolation is blanked with its string: a type named only inside one is not seen.
    static func code(_ source: String) -> String {
        let chars = Array(source)
        var out = "", i = 0
        func starts(_ text: String, at index: Int) -> Bool {
            let text = Array(text)
            return index + text.count <= chars.count && Array(chars[index..<index + text.count]) == text
        }
        /// Skips `chars[i..<end]`, keeping only its line breaks.
        func skip(to end: Int) {
            out += String(repeating: "\n", count: chars[i..<min(end, chars.count)].filter { $0 == "\n" }.count)
            i = end
        }
        while i < chars.count {
            if starts("//", at: i) {
                var end = i
                while end < chars.count, chars[end] != "\n" { end += 1 }
                skip(to: end)
            } else if starts("/*", at: i) {
                var end = i, depth = 0
                repeat {
                    if starts("/*", at: end) { depth += 1; end += 2 } else if starts("*/", at: end) { depth -= 1; end += 2 } else { end += 1 }
                } while depth > 0 && end < chars.count
                out += " "
                skip(to: end)
            } else if chars[i] == "\"" || chars[i] == "#" {
                var hashes = 0
                while i + hashes < chars.count, chars[i + hashes] == "#" { hashes += 1 }
                guard i + hashes < chars.count, chars[i + hashes] == "\"" else { out.append(chars[i]); i += 1; continue }
                let quotes = starts("\"\"\"", at: i + hashes) ? 3 : 1
                let close = String(repeating: "\"", count: quotes) + String(repeating: "#", count: hashes)
                var end = i + hashes + quotes
                while end < chars.count, !starts(close, at: end) { end += hashes == 0 && chars[end] == "\\" ? 2 : 1 }
                out += "\"\""
                skip(to: end + close.count)
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}
