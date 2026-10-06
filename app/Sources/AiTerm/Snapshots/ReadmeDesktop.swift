import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// The README's picture: the two windows and nothing behind them — the real `SidebarView` at
/// `Size.sidebarMinWidth`, and a drawn iTerm2 window `Snap.taskFrame`'s 12 pt to its right — on a
/// transparent ground with room left for their shadows. Everything here but the sidebar
/// approximates what macOS and iTerm2 draw, so its numbers are this view's own, not `Metrics` tokens.
struct ReadmeDesktop: View {
    let controller: AppController
    let tabTitle: String
    let tabs: Int

    /// Its own workspace — a home folder, then aiterm under Personal and acme under Work, two tasks
    /// each, one of them a review — so the fixture the regression set shares stays small. Hosted
    /// only: `ImageRenderer` never materialises a `List`.
    static var snapshot: Snapshot {
        Snapshot("readme-desktop.png", hostedOnly: true) {
            let (controller, selected) = workspace()
            return ReadmeDesktop(controller: controller, tabTitle: selected.branch, tabs: 2)
        }
    }

    /// The workspace the picture draws, and its selected task.
    private static func workspace() -> (AppController, TaskItem) {
        let here = FileManager.default.currentDirectoryPath
        let clock = Snapshots.clock
        let site = URL(string: "https://example.atlassian.net")!
        let ml = JiraProjectRef(id: "10001", key: "ML", name: "Machine Learning", siteURL: site)
        let web = JiraProjectRef(id: "10002", key: "WEB", name: "Website", siteURL: site)
        func project(_ name: String, _ provider: Provider, jira: [JiraProjectRef] = []) -> Project {
            Project(id: UUID(), name: name, path: here, provider: provider, remoteUrl: nil, addedAt: clock.now,
                    collapsed: false, jiraProjects: jira)
        }
        let models: [AgentKind: String] = [.claude: "opus", .codex: "gpt-5.6", .pi: "openai-codex/gpt-5.6-sol", .grok: "grok-4.7"]
        func task(_ project: Project, _ title: String, _ branch: String, _ agent: AgentKind, _ window: String,
                  jira: String? = nil, review: MergeRequestRef? = nil) -> TaskItem {
            TaskItem(id: UUID(), projectId: project.id, title: title, branch: branch, worktreePath: "/r/.worktrees/\(window)",
                     baseBranch: "main", jira: jira.map { JiraRef(key: $0, summary: title, url: "https://example/\($0)") },
                     kind: review == nil ? .task : .review, mr: review,
                     agent: agent, model: models[agent] ?? "", reasoning: "high", firstPrompt: nil, appendTicket: jira != nil,
                     createdAt: clock.now, windowId: window)
        }
        let home = project("laurensdhondt", .none)
        let aiterm = project("aiterm", .github)
        let acme = project("acme", .gitlab, jira: [ml, web])

        let refactor = task(aiterm, "Refactor the session tracker", "refactor/session-tracker", .claude, "a1")
        let orphan = task(aiterm, "Fix orphaned helper on restart", "fix/orphaned-helper", .grok, "a2")
        let quantize = task(acme, "Quantize the ranking model to int8", "feat/ml-412-int8-quantization", .pi, "m1", jira: "ML-412")
        let release = task(acme, "Release new marketing website", "release/marketing-website", .codex, "m2", jira: "WEB-221",
                           review: MergeRequestRef(iid: 87, title: "Release new marketing website", url: "https://example/!87"))
        let tasks = [refactor, orphan, quantize, release]

        let onDisk = WorkspaceScan(
            branchByCwd: Dictionary(uniqueKeysWithValues: tasks.map { ($0.worktreePath, $0.branch) } + [("/r", "main")]),
            projectBranch: Dictionary(uniqueKeysWithValues: [home, aiterm, acme].map { ($0.id, "main") }),
            missingCheckouts: [], removedTasks: [], remotes: [:],
            // The review has just been checked out, so it sits on its branch and draws no diff.
            diffByTask: [refactor.id: DiffStat(added: 212, removed: 148), orphan.id: DiffStat(added: 18, removed: 6),
                         quantize.id: DiffStat(added: 96, removed: 31)])
        let controller = Fixture.emptyController(scan: onDisk)
        controller.workspace.mutate { state in
            state.append(project: home)
            state.append(divider: SidebarDivider(id: UUID(), name: "Personal"))
            state.append(project: aiterm)
            state.append(divider: SidebarDivider(id: UUID(), name: "Work"))
            state.append(project: acme)
            state.tasks = tasks
        }
        controller.live.sessions = [
            // The selected task: Claude Code in front, its context the footer's `ctx` line.
            Fixture.session("r1", "a1", refactor.id, "claude", "working", 0, cwd: refactor.worktreePath, active: true, context: 38),
            Fixture.session("r2", "a1", refactor.id, "codex", "idle", 1, cwd: refactor.worktreePath),
            Fixture.session("r3", "a2", orphan.id, "grok", "done", 0, cwd: orphan.worktreePath, active: true),
            Fixture.session("r4", "m1", quantize.id, "pi", "working", 0, cwd: quantize.worktreePath, active: true),
            Fixture.session("r5", "m2", release.id, "codex", "needsInput", 0, cwd: release.worktreePath, active: true),
            Fixture.session("r6", "m2", release.id, "claude", "idle", 1, cwd: release.worktreePath),
        ].compactMap { $0 }
        controller.checkouts.seedSnapshotFixture(onDisk)
        controller.live.usage = Fixture.usage("""
            {"claude":{"fiveHour":{"usedPercent":42,"resetsAt":\(Fixture.soon)},"sevenDay":{"usedPercent":61,"resetsAt":\(Fixture.later)},"spend":null,"plan":"Max","updatedAt":\(Fixture.fresh)},
             "codex":{"fiveHour":null,"sevenDay":{"usedPercent":17,"resetsAt":\(Fixture.later)},"spend":null,"plan":"Pro","updatedAt":\(Fixture.fresh)}}
            """)
        controller.focus.browse(.task(refactor.id))
        controller.helper.itermConnection = .connected(version: "3.7.2")
        return (controller, refactor)
    }

    /// The windows' size, as they were on the 1512 × 982 pt desktop the picture used to sit on.
    static let windowHeight: CGFloat = 862, windowsWidth: CGFloat = 1300, gap: CGFloat = 12
    /// The transparent margin around the windows, the same on every side and wide enough that
    /// `DesktopWindow`'s shadow has faded out before the picture's edge.
    static let margin: CGFloat = 48
    /// The band a window's traffic lights sit in, and iTerm2's title bar.
    static let titleBar: CGFloat = 28

    var body: some View {
        let terminalWidth = Self.windowsWidth - Size.sidebarMinWidth - Self.gap
        HStack(alignment: .top, spacing: Self.gap) {
            DesktopWindow {
                // The list's own top inset already clears the traffic lights, as the real
                // window's transparent title bar leaves it.
                SidebarView(controller: controller)
            }
            .frame(width: Size.sidebarMinWidth, height: Self.windowHeight)
            DesktopWindow { ItermWindow(title: tabTitle, tabs: tabs) }
                .frame(width: terminalWidth, height: Self.windowHeight)
        }
        .padding(Self.margin)
    }
}

/// A window's frame: rounded, edged in a faint light line, its traffic lights over the content's
/// top band, and a soft shadow on whatever the picture is set on.
private struct DesktopWindow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 12, height: 12) }
                }
                .frame(height: ReadmeDesktop.titleBar)
                .padding(.leading, 12)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

/// The iTerm2 profile the picture draws: the default profile's Monokai colours, in MesloLGS NF,
/// with Interface → "Use dark terminal background" on, so the daemon paints AiTerm's tabs the
/// `#1E1E1E` it sets in `set_aiterm_background`. The profile's tab style is Minimal, so the title
/// bar and the tabs take that background too.
private enum Monokai {
    static let background = Color(hex: 0x1E1E1E), foreground = Color(hex: 0xFDFFF1)
    static let red = Color(hex: 0xF92672), green = Color(hex: 0xA6E22E), yellow = Color(hex: 0xE6DB74)
    static let magenta = Color(hex: 0xAE81FF), cyan = Color(hex: 0x66D9EF)
    /// The profile's bold colour: iTerm2 draws bold text in the default foreground in it.
    static let bold = cyan
    /// ANSI 8, bright black.
    static let brightBlack = Color(hex: 0x6E7066)
    /// Faint text: iTerm2 draws it at half opacity, which over `background` lands here.
    static let faint = Color(hex: 0x8E8E87)
    static let cursor = Color(hex: 0xC0C1B5)
    /// The Minimal tab bar's ground behind the tabs that are not in front, and the lines between them.
    static let tabBar = Color(hex: 0x171717), tabLine = Color(hex: 0x111111)

    static func font(_ weight: Font.Weight = .regular) -> Font {
        // Fall back to the system monospace so a machine without Meslo keeps the columns.
        NSFont(name: "MesloLGS NF", size: 12) == nil
            ? .system(size: 12, weight: weight, design: .monospaced)
            : .custom("MesloLGS NF", fixedSize: 12).weight(weight)
    }
}

/// iTerm2's window for the selected task: its title bar, one tab per session — each titled with
/// the task's branch, as `SidebarModel.sessionTitles` sets it — and Claude Code mid-turn in front.
private struct ItermWindow: View {
    let title: String
    let tabs: Int

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Monokai.foreground.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: ReadmeDesktop.titleBar)
                .background(Monokai.background)
            HStack(spacing: 0) {
                ForEach(0..<tabs, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text("×").opacity(0.6)
                        Text(title).lineLimit(1).frame(maxWidth: .infinity)
                        Text("⌘\(index + 1)").font(.system(size: 11)).opacity(0.6)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Monokai.foreground.opacity(index == 0 ? 0.9 : 0.5))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(index == 0 ? Monokai.background : .clear)
                    .overlay(alignment: .trailing) { Monokai.tabLine.frame(width: 1) }
                }
            }
            .frame(height: 26)
            .background(Monokai.tabBar)
            .overlay(alignment: .bottom) { Monokai.tabLine.frame(height: 1) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ClaudeTurn.lines.enumerated()), id: \.offset) { _, line in line }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Monokai.background)
        }
    }
}

/// Claude Code's transcript in the front tab, one 16 pt line at a time in the profile's 12 pt mono.
/// Claude Code runs its `dark-ansi` theme, so every colour is an ANSI slot of `Monokai`: Claude's
/// own accent is bright red, success bright green, the text bright white, the dim text faint,
/// the auto-accept mode bright magenta, and the user's prompt sits on bright black. Bold text takes
/// the profile's bold colour. A diff has no line washes: its gutter carries the red and green, the
/// removed code is faint, and the rest is highlighted in the profile's colours.
private enum ClaudeTurn {
    enum Ink { case text, dim, green, red, accent, bold, mode, keyword, type, function, link, boldLink }
    typealias Run = (String, Ink)

    static let lineHeight: CGFloat = 16

    static var lines: [AnyView] {
        [
            line(("✻", .accent), (" ", .text), ("Welcome to Claude Code", .bold), ("  · opus · ~/aiterm/.worktrees/session-tracker", .dim)),
            blank,
            prompt("> Refactor the session tracker into one owner: LiveSessions and CheckoutMonitor"),
            prompt("  each keep their own copy of the open tabs. Fold that into a SessionTracker."),
            blank,
            line(("⏺", .green), (" Both copies are rebuilt from the same workspace snapshot, so one owner can", .text)),
            line(("  feed the sidebar and the tab titles alike. Reading both first.", .text)),
            blank,
            tool("Read", "app/Sources/AiTerm/LiveSessions.swift"), result(("Read ", .text), ("214", .bold), (" lines", .text)), blank,
            tool("Read", "app/Sources/AiTerm/CheckoutMonitor.swift"), result(("Read ", .text), ("171", .bold), (" lines", .text)), blank,
            tool("Write", "app/Sources/AiTerm/SessionTracker.swift"),
            result(("Wrote ", .text), ("96", .bold), (" lines to ", .text), ("app/Sources/AiTerm/SessionTracker.swift", .boldLink)), blank,
            tool("Update", "app/Sources/AiTerm/CheckoutMonitor.swift"),
            result(("Added ", .text), ("1", .bold), (" line, removed ", .text), ("2", .bold), (" lines", .text)),
            diff(162, nil, "    /// The titles read the tabs as they are after the pass."),
            diff(163, nil, "    private func syncTitles(_ scan: WorkspaceScan) async {"),
            diff(164, "-", "        let sessions = live.sessions"),
            diff(165, "-", "        let titles = SidebarModel.sessionTitles(state: workspace(),"),
            diff(164, "+", "        let titles = tracker.titles(after: scan)"),
            diff(165, nil, "            await onTitles(titles, tracker.sessions)"),
            blank,
            tool("Bash", "scripts/test.sh", link: false),
            result(("Executed 412 tests, with 0 failures", .text)), blank,
            line(("✶ Moving tab titles onto the tracker…", .accent), (" (4m 02s · ↓ 6.2k tokens · esc to interrupt)", .dim)),
            blank,
            rule,
            AnyView(HStack(spacing: 0) {
                text([("> ", .dim)])
                Rectangle().fill(Monokai.cursor).frame(width: 7, height: 15)
            }.frame(height: lineHeight)),
            rule,
            line(("  ⏵⏵ accept edits on", .mode), (" (shift+tab to cycle)", .dim)),
        ]
    }

    static var blank: AnyView { AnyView(Color.clear.frame(height: lineHeight)) }
    static var rule: AnyView {
        AnyView(Monokai.brightBlack.frame(height: 1).frame(maxWidth: .infinity).frame(height: lineHeight))
    }
    /// A line of the user's prompt, on the theme's message background across the whole row.
    static func prompt(_ text: String) -> AnyView {
        AnyView(self.text([(text, .text)])
            .frame(maxWidth: .infinity, minHeight: lineHeight, maxHeight: lineHeight, alignment: .leading)
            .background(Monokai.brightBlack))
    }
    /// A tool call; a file argument is a link, which iTerm2 underlines dashed.
    static func tool(_ name: String, _ argument: String, link: Bool = true) -> AnyView {
        line(("⏺", .green), (" ", .text), (name, .bold), ("(", .text), (argument, link ? .link : .text), (")", .text))
    }
    static func result(_ runs: Run...) -> AnyView { line([("  ⎿  ", .text)] + runs) }
    /// A diff line: its number, then `-` or `+` for a removed or added line, then the code.
    static func diff(_ number: Int, _ sign: String?, _ code: String) -> AnyView {
        let mark: Ink = sign == "-" ? .red : sign == "+" ? .green : .dim
        return line([("    \(number) \(sign == "-" ? "−" : sign ?? " ")  ", mark)]
                    + (sign == "-" ? [(code, .dim)] : highlighted(code)))
    }
    /// Swift as the profile highlights it: keywords magenta, types cyan, a declared function yellow,
    /// comments faint, everything else the foreground.
    static func highlighted(_ code: String) -> [Run] {
        if code.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return [(code, .dim)] }
        let keywords: Set = ["private", "func", "let", "var", "await", "async", "return"]
        var runs: [Run] = [], word = "", previous = ""
        func flush() {
            guard !word.isEmpty else { return }
            let ink: Ink = keywords.contains(word) ? .keyword
                : previous == "func" ? .function
                : word.first!.isUppercase ? .type : .text
            runs.append((word, ink)); previous = word; word = ""
        }
        for character in code {
            if character.isLetter || character.isNumber || character == "_" && !word.isEmpty { word.append(character) }
            else { flush(); runs.append((String(character), .text)) }
        }
        flush()
        return runs
    }
    static func line(_ runs: Run...) -> AnyView { line(runs) }
    static func line(_ runs: [Run]) -> AnyView {
        AnyView(text(runs).frame(height: lineHeight, alignment: .leading))
    }

    static func text(_ runs: [Run]) -> Text {
        var string = AttributedString()
        for (chunk, ink) in runs {
            var run = AttributedString(chunk)
            switch ink {
            case .text: run.foregroundColor = Monokai.foreground
            case .dim: run.foregroundColor = Monokai.faint
            case .green: run.foregroundColor = Monokai.green
            case .red, .accent: run.foregroundColor = Monokai.red
            case .mode, .keyword: run.foregroundColor = Monokai.magenta
            case .type: run.foregroundColor = Monokai.cyan
            case .function: run.foregroundColor = Monokai.yellow
            case .link:
                run.foregroundColor = Monokai.foreground
                run.underlineStyle = Text.LineStyle(pattern: .dash)
            case .bold, .boldLink:
                run.foregroundColor = Monokai.bold
                run.font = Monokai.font(.bold)
                if ink == .boldLink { run.underlineStyle = Text.LineStyle(pattern: .dash) }
            }
            string += run
        }
        return Text(string).font(Monokai.font())
    }
}

private extension Color {
    init(hex: Int, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
#endif
