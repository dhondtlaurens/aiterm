import Foundation

/// A task's diff as `read_task` answers it (spec §9), small: each file's patch cut to `perFile` characters, the
/// patches together to `total`, and a lockfile never inlined, only said in a line (how much changed, and for
/// `package-lock.json` which packages moved version). A file the caps leave without its patch is still listed.
public struct DiffDigest: Equatable, Sendable {
    /// One file of the diff. `patch` is nil for a lockfile and for a file past the whole digest's cap; `summary` is
    /// set for those two.
    public struct File: Equatable, Sendable {
        public var path: String
        public var patch: String?
        public var summary: String?
        public var truncated: Bool
        public init(path: String, patch: String?, summary: String?, truncated: Bool) {
            self.path = path; self.patch = patch; self.summary = summary; self.truncated = truncated
        }
    }

    public var files: [File]
    /// Whether anything of the diff was left out: a patch cut short, or one not carried at all. A lockfile summarised
    /// is not: its summary is all it is read for.
    public var truncated: Bool

    /// The lockfiles that are summarised, matched on a path's last component.
    public static let lockfiles: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Package.resolved", "poetry.lock",
                                                "uv.lock", "Cargo.lock", "composer.lock", "Gemfile.lock"]
    /// The most files an answer lists; past it one entry says how many more.
    public static let listedFiles = 200
    /// The most lines of git's `--stat` an answer keeps: its last, so the summary line stays.
    public static let statLines = 220
    /// The most lines of the commit list and of the uncommitted edits an answer keeps.
    public static let commitLines = 100, uncommittedLines = 100

    /// What the whole answer aims to stay under, JSON escaping and the keys around its text included.
    static let answerBudget = 36_000
    /// What a listed file costs an answer beside its patch: its keys and path.
    static let fileOverhead = 120

    /// The patch budget (`build`'s `total`) for an answer whose other parts, `others` characters of stat, commits and
    /// uncommitted edits, leave this room for `files` listed files: never above 30 000, and never below 6 000, so
    /// the files that matter most still carry a patch.
    public static func patchBudget(others: Int, files: Int) -> Int {
        min(30_000, max(6_000, answerBudget - others - min(files, listedFiles) * fileOverhead))
    }

    /// `text`'s first `limit` lines, and whether it had more.
    public static func firstLines(_ text: String, _ limit: Int) -> (text: String, cut: Bool) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > limit ? (lines.prefix(limit).joined(separator: "\n"), true) : (text, false)
    }

    /// `text`'s last `limit` lines, and whether it had more.
    public static func lastLines(_ text: String, _ limit: Int) -> (text: String, cut: Bool) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > limit ? (lines.suffix(limit).joined(separator: "\n"), true) : (text, false)
    }

    /// The most package names a `package-lock.json` summary lists before saying how many more.
    static let versionNames = 30

    /// The digest of `diff`, a `git diff`'s output.
    public static func build(diff: String, perFile: Int = 6_000, total: Int = 30_000) -> DiffDigest {
        var files: [File] = [], budget = total
        for section in sections(of: diff) {
            let name = (section.path as NSString).lastPathComponent
            if lockfiles.contains(name) {
                files.append(File(path: section.path, patch: nil, summary: summary(of: section, name: name), truncated: false))
                continue
            }
            guard budget > 0 else {
                files.append(File(path: section.path, patch: nil, summary: counts(of: section) + ", patch left out", truncated: true))
                continue
            }
            let room = min(perFile, budget), cut = section.text.count > room
            let patch = cut ? String(section.text.prefix(room)) : section.text
            budget -= patch.count
            files.append(File(path: section.path, patch: patch, summary: nil, truncated: cut))
        }
        return DiffDigest(files: files, truncated: files.contains { $0.truncated })
    }

    /// One file's part of the diff: its `diff --git` header to the next one's.
    private struct Section {
        var path: String
        var text: String
        var lines: [Substring]
    }

    private static func sections(of diff: String) -> [Section] {
        var out: [Section] = [], current: [Substring] = []
        func flush() {
            while current.last?.isEmpty == true { current.removeLast() }
            guard let header = current.first else { return }
            let text = current.joined(separator: "\n") + "\n"
            out.append(Section(path: path(of: current, header: header), text: text, lines: current))
            current = []
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush() }
            if !current.isEmpty || line.hasPrefix("diff --git ") { current.append(line) }
        }
        flush()
        return out
    }

    /// The path a section is about: where a rename went, else the `b/` side of its header.
    private static func path(of lines: [Substring], header: Substring) -> String {
        if let renamed = lines.first(where: { $0.hasPrefix("rename to ") }) { return String(renamed.dropFirst("rename to ".count)) }
        let names = header.dropFirst("diff --git ".count)
        if let split = names.range(of: " b/", options: .backwards) { return String(names[split.upperBound...]) }
        return String(names)
    }

    /// The hunks' lines, without the header's `---` and `+++`.
    private static func hunkLines(of section: Section) -> ArraySlice<Substring> {
        guard let first = section.lines.firstIndex(where: { $0.hasPrefix("@@") }) else { return [] }
        return section.lines[first...]
    }

    private static func counts(of section: Section) -> String {
        var added = 0, removed = 0
        for line in hunkLines(of: section) {
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
        return "+\(added) \u{2212}\(removed) lines"
    }

    private static func summary(of section: Section, name: String) -> String {
        let counted = counts(of: section)
        guard name == "package-lock.json" else { return counted }
        let names = packagesWithNewVersions(in: section)
        guard !names.isEmpty else { return counted }
        let listed = names.prefix(versionNames).joined(separator: ", ")
        return counted + "; versions changed: " + listed + (names.count > versionNames ? " and \(names.count - versionNames) more" : "")
    }

    /// The packages of a `package-lock.json` diff whose `"version"` line changed: the `"node_modules/<name>"` block that
    /// line sits in, as far as the hunk's context shows it. A nested package is named by its own name.
    private static func packagesWithNewVersions(in section: Section) -> [String] {
        var names: [String] = [], current: String?
        for line in hunkLines(of: section) {
            if line.hasPrefix("@@") { current = nil; continue }
            let content = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("\"node_modules/"), content.hasSuffix("{"), let end = content.range(of: "\": ") {
                let path = content[content.index(content.startIndex, offsetBy: 1)..<end.lowerBound]
                current = path.components(separatedBy: "node_modules/").last
            } else if line.hasPrefix("+") || line.hasPrefix("-"), content.hasPrefix("\"version\":"), let name = current, !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }
}
