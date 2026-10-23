import Foundation

/// The project's files and folders, for the prompt's `@` completions. A pick is written as an `@`
/// mention of its path from the project's root — the form Claude Code and PI attach a file by,
/// and a path any agent can open — which reads the same in the task's worktree, where the agent
/// runs.
public enum ProjectFiles {
    /// The key that opens the file list, at the start of a word.
    public static let trigger: Character = "@"
    /// How many entries a folder that is not a git checkout is read to, so a home directory
    /// picked as a project does not stall the sheet.
    static let walkLimit = 20_000

    /// Every file git tracks in `path`, and every folder that holds one. Tracked files only: they
    /// are what the task's new worktree has, and `.gitignore`d build output never is. A folder that
    /// is not a checkout is walked instead, hidden entries and `SkillCatalog.skipped` left out; one
    /// git could not answer for offers nothing.
    public static func list(in path: String, git: any GitRunning) -> FileIndex {
        // 128 is "not a git repository".
        let tracked = Log.git.attempt("Listing the files of \(path)") {
            try git.ask(["ls-files", "-z"], in: path, none: [128])
        }
        switch tracked {
        case .some(.some(let listing)): return FileIndex(paths: listing.split(separator: "\0").map(String.init), root: path)
        case .some(.none): return FileIndex(paths: walk(path), root: path)
        case .none: return .empty
        }
    }

    /// The files under `path`, relative to it, to `walkLimit` entries.
    static func walk(_ path: String) -> [String] {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = [], seen = 0
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in entries {
            seen += 1
            if seen > walkLimit { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if SkillCatalog.isSkipped(url.lastPathComponent) { entries.skipDescendants() }
                continue
            }
            let full = url.resolvingSymlinksInPath().path
            if full.hasPrefix(prefix) { out.append(String(full.dropFirst(prefix.count))) }
        }
        return out
    }

    /// Whether a query names a folder on disk rather than a path in the project: one above it
    /// (`../`), in the home folder (`~/`), or absolute.
    static func leavesProject(_ query: String) -> Bool {
        query.hasPrefix("../") || query.hasPrefix("~/") || query.hasPrefix("/")
    }

    /// What is in the folder a query that leaves the project names, read from disk on each
    /// keystroke — one folder, not a walk — and matched by the name typed after its last `/`: names
    /// that start with it, then those that hold it, folders first in each. A hidden entry shows once
    /// its dot is typed. A pick in the project is written from the project's root, the project
    /// itself as `./`, and anything else as its absolute path: the task's agent runs in a worktree
    /// under `.worktrees/`, where `../` would be somewhere else.
    static func outside(_ query: String, root: String, limit: Int,
                        resolve: (URL) -> URL = { $0.resolvingSymlinksInPath() }) -> [AgentCompletion] {
        guard !root.isEmpty, let slash = query.lastIndex(of: "/") else { return [] }
        let typed = query[query.index(after: slash)...].lowercased()
        let base = URL(fileURLWithPath: root, isDirectory: true)
        let folder = URL(fileURLWithPath: (String(query[...slash]) as NSString).expandingTildeInPath, relativeTo: base)
            .standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        let project = base.resolvingSymlinksInPath().path + "/", resolvedFolder = folder.resolvingSymlinksInPath()
        func written(_ url: URL, resolved: String, directory: Bool) -> String {
            let tail = directory ? "/" : "", path = resolved + (directory ? "/" : "")
            return !path.hasPrefix(project) ? url.path + tail : path == project ? "./" : String(path.dropFirst(project.count))
        }
        func completion(_ url: URL, directory: Bool) -> AgentCompletion {
            AgentCompletion(name: written(url, resolved: resolve(url).path, directory: directory),
                            kind: directory ? .folder : .file, detail: nil, source: .project)
        }
        let candidates = entries.compactMap { entry -> (url: URL, directory: Bool, prefixed: Bool, name: String, cached: AgentCompletion?)? in
            let name = entry.lastPathComponent, lowered = name.lowercased()
            guard typed.hasPrefix(".") || !name.hasPrefix("."), typed.isEmpty || lowered.contains(typed) else { return nil }
            let values = try? entry.resourceValues(forKeys: keys)
            // Enumeration canonicalizes /var to /private/var; keep the path the query named.
            let url = folder.appendingPathComponent(name)
            var directory = values?.isDirectory == true, cached: AgentCompletion?
            // Links need their target's kind and written name before ranking; ordinary entries
            // use the enumeration's metadata and resolve only once selected.
            if values?.isSymbolicLink == true {
                var targetIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &targetIsDirectory) else { return nil }
                directory = targetIsDirectory.boolValue
                cached = completion(url, directory: directory)
            }
            let sortName = cached?.name ?? written(url, resolved: resolvedFolder.appendingPathComponent(name).path, directory: directory)
            return (url, directory, lowered.hasPrefix(typed), sortName.lowercased(), cached)
        }.sorted { a, b in
            if a.prefixed != b.prefixed { return a.prefixed }
            if a.directory != b.directory { return a.directory }
            return a.name < b.name
        }
        var result: [AgentCompletion] = []
        for entry in candidates {
            if result.count == limit { break }
            if let cached = entry.cached { result.append(cached); continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.url.path, isDirectory: &isDirectory) else { continue }
            result.append(completion(entry.url, directory: isDirectory.boolValue))
        }
        return result
    }

    /// What a picked file or folder writes into the prompt: `@` and its path, whitespace
    /// backslash-escaped so the mention stays one word. A folder's name already ends in `/`.
    public static func mention(of item: AgentCompletion) -> String {
        String(trigger) + item.name.reduce(into: "") { out, c in
            if c.isWhitespace { out.append("\\") }
            out.append(c)
        }
    }
}

/// A project's files and folders, ready to be matched as the `@` query is typed: each path lowered
/// once, here, rather than on every keystroke.
public struct FileIndex: Sendable {
    struct Entry: Sendable { let item: AgentCompletion, path: String, leaf: String }
    let entries: [Entry]
    /// The project's folder, which a query leaving it (`../`) is read from.
    let root: String

    public static let empty = FileIndex(paths: [])

    /// Every path in `paths` and every folder above one, shallowest first, then folders before
    /// files, then by name — so an empty query offers the project's top level.
    public init(paths: [String], root: String = "") {
        self.root = root
        var folders = Set<String>()
        for path in paths {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                guard folders.insert(parts.joined(separator: "/") + "/").inserted else { break }
                parts = parts.dropLast()
            }
        }
        let items = folders.map { AgentCompletion(name: $0, kind: .folder, detail: nil, source: .project) }
            + paths.map { AgentCompletion(name: $0, kind: .file, detail: nil, source: .project) }
        entries = items.map { (item: $0, depth: $0.name.split(separator: "/").count) }.sorted { a, b in
            if a.depth != b.depth { return a.depth < b.depth }
            if a.item.kind != b.item.kind { return a.item.kind == .folder }
            return a.item.name < b.item.name
        }.map { pair in
            let item = pair.item
            let path = item.name.lowercased()
            let leaf = path.split(separator: "/").last.map(String.init) ?? path
            return Entry(item: item, path: path, leaf: leaf)
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Paths that start with the query first, then those whose own name does, then those that hold
    /// it anywhere; in the index's order within each. The folder the query already names is left
    /// out, so `@app/` lists what is in `app/` rather than `app/` itself. `./` is the project's
    /// root; a query that leaves the project (`../`, `~/`, `/`) lists that folder on disk instead.
    public func matches(_ query: String, limit: Int = SkillCatalog.matchLimit) -> [AgentCompletion] {
        if ProjectFiles.leavesProject(query) { return ProjectFiles.outside(query, root: root, limit: limit) }
        let q = (query.hasPrefix("./") ? String(query.dropFirst(2)) : query).lowercased()
        var prefixed: [AgentCompletion] = [], named: [AgentCompletion] = [], contained: [AgentCompletion] = []
        for entry in entries where !(entry.item.kind == .folder && entry.path == q) {
            if entry.path.hasPrefix(q) {
                prefixed.append(entry.item)
                if prefixed.count == limit { break }
            } else if named.count < limit, entry.leaf.hasPrefix(q) {
                named.append(entry.item)
            } else if contained.count < limit, entry.path.contains(q) {
                contained.append(entry.item)
            }
        }
        return Array((prefixed + named + contained).prefix(limit))
    }
}
