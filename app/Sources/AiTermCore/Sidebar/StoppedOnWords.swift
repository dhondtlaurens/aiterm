import Foundation

/// How a worker an API error stopped is said (`StoppedOn`): on its card's line and in `run_status`. Here, beside the
/// usage footer whose reset times it says the same way, rather than with the daemon's types.
public extension StoppedOn {
    /// What stopped it, as a few words after `blocked ·` on a card's line: `usage limit, resets 13:20`, `usage limit`,
    /// `billing error`, `sign-in failed`, or the API's own name for any other error. The reset in 24-hour local time,
    /// with the weekday across a date boundary, as the sidebar's usage footer says it.
    func detail(now: Date, calendar: Calendar = .current) -> String {
        if isLimit { return "usage limit" + (resetsAt.map { ", resets " + SidebarModel.fmtReset($0, now: now, calendar: calendar) } ?? "") }
        switch error {
        case "billing_error": return "billing error"
        case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error", "verification_required": return "sign-in failed"
        case "account_on_hold": return "account on hold"
        default: return "API error, " + error.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// What stopped it, as a sentence `run_status` and a card's tooltip say: whether Claude Code may carry on by itself.
    /// "stopped on its usage limit, resets 13:20; Claude Code may carry on by itself then".
    func reason(now: Date, calendar: Calendar = .current) -> String {
        if isLimit {
            guard let resetsAt else { return "stopped on its usage limit; Claude Code may carry on by itself once it resets" }
            return "stopped on its usage limit, resets \(SidebarModel.fmtReset(resetsAt, now: now, calendar: calendar)); Claude Code may carry on by itself then"
        }
        let what = switch detail(now: now, calendar: calendar) {
        case "billing error": "on a billing error"
        case "sign-in failed": "because its sign-in failed"
        case "account on hold": "because its account is on hold"
        default: error == "unknown" ? "on an API error" : "on an API error (\(error))"
        }
        return "stopped \(what); it won’t carry on by itself"
    }
}
