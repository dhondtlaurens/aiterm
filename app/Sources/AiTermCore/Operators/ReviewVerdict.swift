import Foundation

extension ReviewVerdict {
    /// The visible review tab's final lines, copied by the Operator into `record_review`: `sha` filled in already, the
    /// commit the tab was opened on, so the verdict names the commit reviewed and not wherever the branch has moved.
    public static func block(sha: String) -> String {
        """
        End with this verdict block, replacing the placeholders. Set passed by the review prompt's criteria. \
        Counts are non-negative integers; summary is one line the Operator can copy into record_review with the sha as it stands.
        sha: \(sha)
        passed: <true or false>
        critical: <count>
        important: <count>
        minor: <count>
        summary: <one-line summary>
        """
    }
}

