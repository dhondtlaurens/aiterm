import Foundation

/// The service a release, a merge request or a pull request lives on, as copy names it. GitLab is
/// every host that is not github.com: it is the only other one AiTerm reads.
public enum CodeHost: String, Sendable, Equatable {
    case gitLab = "GitLab", gitHub = "GitHub"

    public var name: String { rawValue }

    /// Judged by the web URL a merge or pull request was stored with, so a saved review needs no
    /// field of its own to say where it came from.
    public init(webURL: String) {
        self = URL(string: webURL)?.host?.lowercased() == "github.com" ? .gitHub : .gitLab
    }

    /// How the host writes a request's number: GitLab `!87`, GitHub `#87`.
    public func reference(_ number: Int) -> String { (self == .gitHub ? "#" : "!") + String(number) }
}

/// A merge request (GitLab) or pull request (GitHub), as either host's client reads it.
public struct MergeRequest: Equatable, Sendable, Identifiable {
    public var iid: Int, title: String, sourceBranch: String, targetBranch: String
    public var author: String?, state: String, draft: Bool, url: String
    /// The source owner/project and branch when it lives in a fork rather than on origin,
    /// which is where a review checks out from. Both GitHub and GitLab report it.
    public var forkHead: String?
    public var id: Int { iid }
    public init(iid: Int, title: String, sourceBranch: String, targetBranch: String,
                author: String?, state: String, draft: Bool, url: String, forkHead: String? = nil) {
        self.iid = iid; self.title = title; self.sourceBranch = sourceBranch; self.targetBranch = targetBranch
        self.author = author; self.state = state; self.draft = draft; self.url = url; self.forkHead = forkHead
    }

    /// The lane a picked merge or pull request shows beside its title.
    public var lane: String { forkHead != nil ? "Fork" : draft ? "Draft" : state.capitalized }
    public var host: CodeHost { CodeHost(webURL: url) }
    /// `!87` for GitLab, `#87` for GitHub.
    public var reference: String { host.reference(iid) }
}

/// How many of a merge or pull request's review threads are resolved, of all of them: GitLab's
/// resolvable discussions, GitHub's review threads. A plain comment or a system note cannot be
/// resolved and is not one. A count, not a sentence: the app words it.
public struct ReviewThreads: Equatable, Sendable {
    public var resolved: Int, total: Int
    public init(resolved: Int, total: Int) { self.resolved = resolved; self.total = total }

    /// One flag per thread, true when it is resolved.
    public init(resolutions: [Bool]) {
        self.init(resolved: resolutions.filter { $0 }.count, total: resolutions.count)
    }
}

/// One review thread on a request, as the Review slice reads it (spec §5): GitLab's resolvable
/// discussion, GitHub's review thread. `id` is what a reply names; the last note is who spoke last
/// in it and what they said.
public struct ReviewThread: Equatable, Sendable {
    public var id: String, resolved: Bool, lastAuthor: String?, lastBody: String
    public init(id: String, resolved: Bool, lastAuthor: String?, lastBody: String) {
        self.id = id; self.resolved = resolved; self.lastAuthor = lastAuthor; self.lastBody = lastBody
    }
}

/// A list the host pages that AiTerm could not read to its end: a page past the cap, a page that failed, or an
/// entry that did not decode. What is decided on it (the merge floor, the review watcher) decides on nothing.
public struct IncompleteRead: Error, Equatable, LocalizedError {
    /// What was listed, as "review threads" or "reviews".
    public let what: String
    public init(_ what: String) { self.what = what }
    public var errorDescription: String? { "AiTerm couldn’t read every one of the \(what) on the host." }
}

/// Someone on a code host a request can be assigned to for review: the username the host knows them
/// by, and their display name when the host gives one.
public struct HostUser: Equatable, Sendable {
    public var username: String, name: String?
    public init(username: String, name: String?) { self.username = username; self.name = name }
}

/// What a code host says of merging a request now, in its own words.
public enum MergeReadiness: Equatable, Sendable {
    /// It would merge now, its pipelines green; `head` is the commit it would merge.
    case ready(head: String)
    /// Not yet: a pipeline running, the host still checking, an approval to come.
    case waiting(String)
    /// Not without someone acting: conflicts, a failed pipeline, a closed request, a refused merge.
    case blocked(String)
    /// Merged — by this call, or an earlier one whose answer was lost, or by someone on the host — as
    /// `commit`, with `head` the request's head commit that was merged ("" when the host did not say).
    /// `target` is the live target when the host supplies it; nil must not be inferred from saved state.
    case merged(commit: String, head: String, target: String? = nil)
}

public extension MergeReadiness {
    /// Why a draft is not ready, as both hosts say it: only once nothing else stops the request, so a draft blocked
    /// for this alone would merge once it is marked ready.
    static let draftReason = "it is a draft"
}

/// Whether a code host protects a branch. AiTerm never pushes to a protected branch (spec §3):
/// `TaskPublisher` asks before every push, and pushes nothing unless the answer is `.unprotected`.
public enum BranchProtection: Equatable, Sendable {
    case unprotected
    /// Protected, and why, in the host's terms: the rule or ruleset that covers it.
    case protected(String)

    /// `branch` against a host's branch-name pattern, case-sensitively as both hosts compare names.
    /// GitLab's `*` spans any characters, `/` too (`starCrossesSlash`); GitHub's patterns are fnmatch
    /// with FNM_PATHNAME, where `*` and `?` stop at `/` and `**` does not. `[…]` is a character class,
    /// `[!…]` its negation; everything else is literal.
    ///
    /// A pattern AiTerm cannot evaluate matches: a caller that only asks yes or no then treats the
    /// branch as covered. Callers that must tell "covered" from "cannot tell" use `evaluate`.
    public static func matches(_ pattern: String, _ branch: String, starCrossesSlash: Bool) -> Bool {
        (try? evaluate(pattern, branch, starCrossesSlash: starCrossesSlash)) ?? true
    }

    /// `matches`, throwing `ProtectionUnknown.unreadable` for a pattern that is no valid glob here
    /// (an empty or reversed character class, say) instead of guessing an answer.
    public static func evaluate(_ pattern: String, _ branch: String, starCrossesSlash: Bool) throws -> Bool {
        let one = starCrossesSlash ? "." : "[^/]"
        var regex = "(?s)\\A", rest = Substring(pattern)
        while let character = rest.first {
            rest = rest.dropFirst()
            switch character {
            case "*" where rest.first == "*":
                rest = rest.dropFirst()
                regex += ".*"
            case "*":
                regex += one + "*"
            case "?":
                regex += one
            case "[":
                guard let close = rest.firstIndex(of: "]") else { regex += "\\["; continue }
                var set = String(rest[..<close])
                if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                // ICU reads `[` and `&&` inside a class as set syntax; in a glob they are characters.
                for special in ["\\", "[", "&"] { set = set.replacingOccurrences(of: special, with: "\\" + special) }
                regex += "[" + set + "]"
                rest = rest[rest.index(after: close)...]
            default:
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        guard let expression = try? NSRegularExpression(pattern: regex + "\\z") else {
            throw ProtectionUnknown.unreadable("AiTerm cannot read the branch pattern \(pattern)")
        }
        return expression.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)) != nil
    }
}

/// Why a host's protection could not be established: the caller then pushes nothing (fail closed).
public enum ProtectionUnknown: Error, Equatable, LocalizedError {
    /// The host answered without the rules — GitHub's GraphQL with a null and an error beside it —
    /// or with one AiTerm cannot evaluate.
    case unreadable(String)
    /// More rules than AiTerm reads.
    case tooManyRules(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let what): return "\(what)."
        case .tooManyRules(let count): return "The host has more than \(count) branch protection rules, more than AiTerm reads."
        }
    }
}
