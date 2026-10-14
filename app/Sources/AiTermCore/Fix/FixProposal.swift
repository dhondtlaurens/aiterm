import Foundation

/// The Look run's answer as the agent's JSON gives it: every field optional, so a wrong shape fails
/// validation with one sentence rather than decoding with a Swift error.
public struct FixLookAnswer: Decodable, Equatable, Sendable {
    public var outcome: String?, headline: String?, why: String?
    public var steps: [String]?, moves: [String]?, drops: [String]?
    public var verify: String?, reason: String?
    public init(outcome: String?, headline: String?, why: String?, steps: [String]?, moves: [String]?,
                drops: [String]?, verify: String?, reason: String?) {
        self.outcome = outcome; self.headline = headline; self.why = why; self.steps = steps
        self.moves = moves; self.drops = drops; self.verify = verify; self.reason = reason
    }
}

public struct FixApplyAnswer: Decodable, Equatable, Sendable {
    public var outcome: String?, summary: String?
    public init(outcome: String?, summary: String?) { self.outcome = outcome; self.summary = summary }
}

/// A plan the person can approve: checked against the request before it is ever shown.
public struct FixProposal: Equatable, Sendable {
    public var headline: String, why: String
    public var steps: [String]
    public var moves: [String]
    /// Local commits the plan deliberately leaves out — the force-push case. Landing refuses any
    /// other loss (`FixGuard.lostCommits`).
    public var drops: [String]
    public var verify: String?

    /// For the app's snapshots, which draw a proposal outside a test's `@testable` import.
    public init(headline: String, why: String, steps: [String], moves: [String], drops: [String], verify: String?) {
        self.headline = headline; self.why = why; self.steps = steps; self.moves = moves; self.drops = drops; self.verify = verify
    }
}

public enum FixLook: Equatable, Sendable {
    case fix(FixProposal)
    case none(String)

    static let headlineLimit = 90, whyLimit = 300, stepRange = 1...3
    /// Characters a `verify` command may not hold: anything that chains, substitutes, redirects or
    /// globs, and the `*` and `:` that Claude's `Bash(…)` permission rule gives a meaning of its own.
    static let shellOperators: [String] = [";", "&", "|", "`", "$(", "(", ")", ">", "<", "*", ":", "\n", "\r"]

    public init(validating answer: FixLookAnswer, request: FixRequest, localOnly: Set<String>,
                agent: FixerAgent) throws(FixRefusal) {
        let refuse = FixRefusal.unreadableAnswer(agent)
        switch answer.outcome {
        case "none":
            let reason = answer.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reason.isEmpty else { throw refuse }
            self = .none(reason)
        case "fix":
            guard let headline = answer.headline, !headline.isEmpty, headline.count <= Self.headlineLimit,
                  let why = answer.why, why.count <= Self.whyLimit,
                  let steps = answer.steps, Self.stepRange.contains(steps.count), steps.allSatisfy({ !$0.isEmpty }),
                  let moves = answer.moves, !moves.isEmpty, Set(moves).isSubset(of: [request.branch])
            else { throw refuse }
            let drops = answer.drops ?? []
            guard drops.allSatisfy({ drop in localOnly.contains { $0.hasPrefix(drop) && drop.count >= 7 } }) else { throw refuse }
            let verify = answer.verify?.trimmingCharacters(in: .whitespaces)
            if let verify, verify.isEmpty || Self.shellOperators.contains(where: { verify.contains($0) }) { throw refuse }
            let fullDrops = drops.map { drop in localOnly.first { $0.hasPrefix(drop) }! }
            self = .fix(FixProposal(headline: headline, why: why, steps: steps, moves: moves, drops: fullDrops,
                                    verify: verify))
        default:
            throw refuse
        }
    }
}

/// The Apply run's answer, once it says it applied.
public struct FixApplied: Equatable, Sendable {
    public var summary: String

    public init(validating answer: FixApplyAnswer, agent: FixerAgent) throws(FixRefusal) {
        switch answer.outcome {
        case "applied": summary = answer.summary ?? ""
        case "failed": throw .agentFailed(agent, summary: answer.summary ?? "no reason given")
        default: throw .unreadableAnswer(agent)
        }
    }
}
