import SwiftUI
import AiTermCore
import AiTermUI

/// One of the Interface tab's badge switches: what it turns off, and the badge it previews.
struct BadgeDetailSwitch: Identifiable, Sendable {
    let detail: WritableKeyPath<BadgeDetails, Bool> & Sendable
    let title: String
    let help: String
    let brand: Brand
    /// What the badge prints while its detail is on; the mark alone once it is off.
    let label: String?
    var diff: Badge.Diff?

    var id: String { title }

    /// In the order a task row draws them, the project header's key first because it sits above.
    static let all = [
        BadgeDetailSwitch(detail: \.jiraProject, title: "Jira project key", help: "On the project header",
                          brand: Palette.jira, label: "SHOP"),
        BadgeDetailSwitch(detail: \.jiraTicket, title: "Jira ticket key", help: "On each task linked to a ticket",
                          brand: Palette.jira, label: "SHOP-412"),
        BadgeDetailSwitch(detail: \.mergeRequest, title: "Merge request number",
                          help: "On each review of a merge or pull request", brand: Palette.gitlab, label: "!87"),
        BadgeDetailSwitch(detail: \.diff, title: "Lines changed",
                          help: "On the VS Code badge, once a task’s branch has moved from its base",
                          brand: Palette.vscode, label: nil, diff: Badge.Diff(added: 12, removed: 3)),
    ]
}

/// The Interface tab: the preferences that change what AiTerm's terminal windows look like, how
/// large the sidebar is drawn and its badges, then every key AiTerm answers to.
struct InterfaceSettingsPane: View {
    let matchItermBackground: Binding<Bool>
    let badgeDetails: Binding<BadgeDetails>
    let interfaceSize: Binding<InterfaceSize>
    /// The terminal-profile preview swatch's own size, beside the toggle description. One call
    /// site; no existing `Size` step is close enough to stand in without visibly shrinking it.
    private static let swatch: CGFloat = 42

    /// The keys sit a section's step below the preferences, since they are a list to read rather than
    /// something to set.
    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            VStack(alignment: .leading, spacing: Space.block) {
                backgroundToggle
                sizeGroup
                badgeGroup
            }
            KeyboardSettingsPane()
        }
    }

    private var backgroundToggle: some View {
        HStack(alignment: .top, spacing: Space.gap) {
            RoundedRectangle(cornerRadius: Radius.group).fill(Palette.surface)
                .frame(width: Self.swatch, height: Self.swatch)
                .overlay(RoundedRectangle(cornerRadius: Radius.group).strokeBorder(Palette.border, lineWidth: 1))
                .overlay(Text("#1E").font(Typography.monoChip).foregroundStyle(Palette.muted))
            VStack(alignment: .leading, spacing: Space.tight) {
                Text("Use dark terminal background")
                    .font(Typography.bodyEmphasis).foregroundStyle(Palette.text)
                HelpText("Applies to terminal windows opened by AiTerm, including existing ones. Your iTerm2 profiles stay unchanged.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(title: "Use dark terminal background", isOn: matchItermBackground)
        }
        .padding(Space.block).groupChrome()
    }

    /// The sidebar's size. The sheet itself keeps Apple's sizes, so the change shows in the sidebar
    /// behind it, as soon as it is picked; Cancel puts the old size back.
    private var sizeGroup: some View {
        SettingsGroup(title: "Sidebar size",
                      help: "Draws the sidebar’s text, rows and badges larger. View › Zoom In (⌘+), Zoom Out (⌘−) and Actual Size (⌘0) pick the same sizes.") {
            SegmentedControl(values: InterfaceSize.allCases, selection: interfaceSize) { size, on in
                Text(size.title).font(Typography.body).foregroundStyle(on ? Palette.text : Palette.muted)
            }
        }
    }

    /// A `Grid` rather than stacked rows so every title starts after the widest preview, `+12 −3`,
    /// without a measured column width.
    private var badgeGroup: some View {
        SettingsGroup(title: "Sidebar badges",
                      help: "Turn one off to show only its mark. Clicking it and its tooltip still work.") {
            Grid(alignment: .leading, horizontalSpacing: Space.gap, verticalSpacing: Space.gap) {
                ForEach(Array(BadgeDetailSwitch.all.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline() }
                    badgeRow(item)
                }
            }
        }
    }

    /// The preview is the sidebar's own `Badge`, following its switch before Save.
    private func badgeRow(_ item: BadgeDetailSwitch) -> some View {
        let on = badgeDetails[dynamicMember: item.detail]
        return GridRow(alignment: .top) {
            Badge(on.wrappedValue ? item.label : nil, icon: .brand(item.brand),
                  diff: on.wrappedValue ? item.diff : nil, style: .quiet)
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(item.title).font(Typography.bodyEmphasis).foregroundStyle(Palette.text)
                HelpText(item.help)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(title: item.title, isOn: on)
        }
    }
}
