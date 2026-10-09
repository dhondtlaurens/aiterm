import SwiftUI
import AiTermUI

/// "Copy files listed in .worktreeinclude": the checkbox that ends New Task's and New Review's
/// first-step fields, above the destination line, when a new worktree would get what the project's
/// `.worktreeinclude` selects. Drawn as step 3's "Include Jira ticket details" is, ticked by
/// default, with no caption; its tooltip lists the files. The sheet leaves it out — not disabled —
/// when there are none to copy.
struct WorktreeIncludeToggle: View {
    let files: [String]
    @Binding var isOn: Bool

    /// How many files the tooltip names before it counts the rest.
    static let namedInHelp = 12

    var body: some View {
        Toggle("Copy files listed in .worktreeinclude", isOn: $isOn)
            .toggleStyle(.checkbox).font(Typography.body)
            .help(Self.help(files))
    }

    /// The tooltip: the files, one a line, the first `namedInHelp` of them, then how many more.
    static func help(_ files: [String]) -> String {
        let named = Array(files.prefix(namedInHelp)), more = files.count - named.count
        return (named + (more > 0 ? ["and \(more) more"] : [])).joined(separator: "\n")
    }
}
