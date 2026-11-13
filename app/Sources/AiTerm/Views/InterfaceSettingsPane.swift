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

    /// In the order a task row draws them, the project header's count first because it sits above.
    static let all = [
        BadgeDetailSwitch(detail: \.jiraProject, title: "Jira project count", help: "On the project header",
                          brand: Palette.jira, label: "2"),
        BadgeDetailSwitch(detail: \.jiraTicket, title: "Ticket key", help: "On each task or review linked to a ticket",
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
            // The colour the switch paints AiTerm's terminals: the sidebar's own ground.
            Color.clear.frame(width: Self.swatch, height: Self.swatch)
                .groupChrome(fill: Palette.sidebar)
                .overlay(Text("#17").font(Typography.monoChip).foregroundStyle(Palette.muted))
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
            SegmentedControl(values: InterfaceSize.allCases, selection: interfaceSize) { size, _ in
                Text(size.title).font(Typography.body)
            }
        }
    }

    /// A `Grid` rather than stacked rows so every title starts after the widest preview, `+12 −3`,
    /// without a measured column width. The brand colours come last: the one switch about the marks
    /// themselves, which every preview above it follows.
    private var badgeGroup: some View {
        SettingsGroup(title: "Sidebar badges",
                      help: "Turn a detail off to show only its mark. Clicking it and its tooltip still work.") {
            Grid(alignment: .leading, horizontalSpacing: Space.gap, verticalSpacing: Space.gap) {
                ForEach(BadgeDetailSwitch.all) { item in
                    let on = badgeDetails[dynamicMember: item.detail]
                    badgeRow(title: item.title, help: item.help, isOn: on) {
                        Badge(on.wrappedValue ? item.label : nil, icon: .brand(item.brand),
                              diff: on.wrappedValue ? item.diff : nil, style: .quiet, markInk: markInk)
                    }
                    Hairline()
                }
                badgeRow(title: "Brand colours", help: "Draws each mark in its own colours instead of the ink of its row",
                         isOn: badgeDetails.brandColours) {
                    Badge(icon: .brand(Palette.jira), style: .quiet, markInk: markInk)
                }
            }
        }
    }

    private var markInk: Badge.MarkInk { badgeDetails.wrappedValue.markInk }

    /// The preview is the sidebar's own `Badge`, following its switch before Save.
    private func badgeRow(title: String, help: String, isOn: Binding<Bool>, @ViewBuilder preview: () -> some View) -> some View {
        GridRow(alignment: .top) {
            preview()
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title).font(Typography.bodyEmphasis).foregroundStyle(Palette.text)
                HelpText(help)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsSwitch(title: title, isOn: isOn)
        }
    }
}

extension BadgeDetails {
    /// How the sidebar's badges ink their marks: with their words unless the brand colours are on.
    var markInk: Badge.MarkInk { brandColours ? .own : .label }
}
