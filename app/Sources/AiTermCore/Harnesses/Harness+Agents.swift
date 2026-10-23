import Foundation

/// The three harnesses, side by side: what differs between them is read here, in one table.
extension Harness {
    static let claude = claude(config: ClaudeConfig())

    static func claude(config: ClaudeConfig) -> Harness { Harness(
        agent: .claude, executable: "claude", displayName: "Claude Code",
        installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
        fallbackEfforts: ModelFiles.claudeEfforts, defaultEffort: "high",
        noModelsExplanation: "No models are available.",
        skillSigil: "/", hookEndpoint: "/hook/claude",
        bundledResource: .script("claude-statusline-shim.sh"),
        launchArguments: { Harness.claude.modelArguments(model: $0, reasoning: $1) },
        resumeArguments: { ["--resume", $0] },
        models: .files(sources: { ModelFiles.claudeSources(home: $0, claudeConfig: config) }, read: { ModelFiles.claudeModels(home: $0, claudeConfig: config) }),
        skillRoots: { home, project in
            // Claude Code keeps a `user-invocable: false` skill out of its `/` menu.
            let user = config.directory(home: home)
            var roots = [SkillRoot(.skills(hidingNonInvocable: true), user.appendingPathComponent("skills"), .user),
                         SkillRoot(.commands(), user.appendingPathComponent("commands"), .user),
                         SkillRoot(.plugins(hidingNonInvocable: true), user, .user)]
            if let project = project?.appendingPathComponent(".claude") {
                roots += [SkillRoot(.skills(hidingNonInvocable: true), project.appendingPathComponent("skills"), .project),
                          SkillRoot(.commands(), project.appendingPathComponent("commands"), .project)]
            }
            return roots
        },
        makeDriver: { home, port, shim in shim.map { ClaudeDriver(home: home, daemonPort: port, shimPath: $0, claudeConfig: config) } }) }

    static let codex: Harness = Harness(
        agent: .codex, executable: "codex", displayName: "Codex",
        installCommand: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        fallbackEfforts: ModelFiles.codexEfforts, defaultEffort: "medium",
        noModelsExplanation: "No models are available.",
        // Codex runs a skill as a `$` mention and keeps `/` for its commands, `/prompts:<name>`
        // among them.
        skillSigil: "$", hookEndpoint: "/hook/codex",
        bundledResource: nil,
        launchArguments: { model, reasoning in
            ["--dangerously-bypass-approvals-and-sandbox"] + Harness.codex.modelArguments(model: model, reasoning: reasoning)
        },
        resumeArguments: { ["resume", $0] },       // a subcommand: its options follow the id
        models: .files(sources: { ModelFiles.codexSources(home: $0) }, read: { ModelFiles.codexModels(home: $0) }),
        skillRoots: { home, project in
            // Codex follows the Agent Skills standard, `.agents/skills` in the home and the repo.
            // Its own home still holds the built-ins (`skills/.system`), what its skill installer
            // adds and its (deprecated) custom prompts, which it runs as `/prompts:<name>`; none of
            // those has a project-level twin.
            let user = home.appendingPathComponent(".codex")
            var roots = [SkillRoot(.skills(), user.appendingPathComponent("skills"), .user),
                         SkillRoot(.skills(), home.appendingPathComponent(".agents/skills"), .user),
                         SkillRoot(.commands(namespace: "prompts"), user.appendingPathComponent("prompts"), .user),
                         SkillRoot(.plugins(), user, .user)]
            if let project {
                roots.append(SkillRoot(.skills(), project.appendingPathComponent(".agents/skills"), .project))
            }
            return roots
        },
        makeDriver: { home, port, _ in CodexDriver(home: home, daemonPort: port) })

    static let pi: Harness = Harness(
        agent: .pi, executable: "pi", displayName: "PI",
        installCommand: "curl -fsSL https://pi.dev/install.sh | sh",
        fallbackEfforts: PiModelCatalog.thinkingLevels, defaultEffort: "medium",
        noModelsExplanation: "No PI providers are signed in. Run /login in PI.",
        skillSigil: "/", hookEndpoint: "/hook/pi",
        bundledResource: .source("pi-aiterm-status.ts"),
        launchArguments: { Harness.pi.modelArguments(model: $0, reasoning: $1) },
        resumeArguments: { ["--session", $0] },    // a session id or file
        models: .launch(sources: { PiModelCatalog.sources(home: $0) },
                        list: { try PiModelCatalog.discover(executable: $0, runner: $1) }),
        skillRoots: { home, project in
            // PI runs a skill as `/skill:<name>`.
            let user = home.appendingPathComponent(".pi/agent")
            var roots = [SkillRoot(.skills(namespace: "skill"), user.appendingPathComponent("skills"), .user),
                         SkillRoot(.skills(namespace: "skill"), home.appendingPathComponent(".agents/skills"), .user),
                         SkillRoot(.commands(), user.appendingPathComponent("prompts"), .user)]
            if let project {
                roots += [SkillRoot(.skills(namespace: "skill"), project.appendingPathComponent(".pi/skills"), .project),
                          SkillRoot(.skills(namespace: "skill"), project.appendingPathComponent(".agents/skills"), .project),
                          SkillRoot(.commands(), project.appendingPathComponent(".pi/prompts"), .project)]
            }
            return roots
        },
        makeDriver: { home, port, source in source.map { PiDriver(home: home, daemonPort: port, source: $0) } })
}
