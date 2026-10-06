import Foundation

/// The four harnesses, side by side: what differs between them is read here, in one table.
extension Harness {
    static let claude = Harness(
        agent: .claude, executable: "claude", displayName: "Claude Code",
        installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
        fallbackEfforts: ModelCatalog.claudeEfforts, defaultEffort: "high",
        noModelsExplanation: "No models are available.",
        skillSigil: "/", hookEndpoint: "/hook/claude",
        bundledResource: .script("claude-statusline-shim.sh"),
        launchArguments: { model, reasoning in ["--model", model] + (reasoning.map { ["--effort", $0] } ?? []) },
        models: .files(sources: { ModelCatalog.claudeSources(home: $0) }, read: { ModelCatalog.claudeModels(home: $0) }),
        skillRoots: { home, project in
            // Claude Code, like Grok, keeps a `user-invocable: false` skill out of its `/` menu.
            let user = home.appendingPathComponent(".claude")
            var roots = [SkillRoot(.skills(hidingNonInvocable: true), user.appendingPathComponent("skills"), .user),
                         SkillRoot(.commands(), user.appendingPathComponent("commands"), .user),
                         SkillRoot(.plugins(hidingNonInvocable: true), user, .user)]
            if let project = project?.appendingPathComponent(".claude") {
                roots += [SkillRoot(.skills(hidingNonInvocable: true), project.appendingPathComponent("skills"), .project),
                          SkillRoot(.commands(), project.appendingPathComponent("commands"), .project)]
            }
            return roots
        },
        makeDriver: { home, port, shim in shim.map { ClaudeDriver(home: home, daemonPort: port, shimPath: $0) } })

    static let codex = Harness(
        agent: .codex, executable: "codex", displayName: "Codex",
        installCommand: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        fallbackEfforts: ModelCatalog.codexEfforts, defaultEffort: "medium",
        noModelsExplanation: "No models are available.",
        // Codex runs a skill as a `$` mention and keeps `/` for its commands, `/prompts:<name>`
        // among them.
        skillSigil: "$", hookEndpoint: "/hook/codex",
        bundledResource: nil,
        launchArguments: { model, reasoning in
            ["--dangerously-bypass-approvals-and-sandbox", "-m", model] + (reasoning.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [])
        },
        models: .files(sources: { ModelCatalog.codexSources(home: $0) }, read: { ModelCatalog.codexModels(home: $0) }),
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

    static let grok = Harness(
        agent: .grok, executable: "grok", displayName: "Grok Build",
        installCommand: "curl -fsSL https://x.ai/cli/install.sh | bash",
        fallbackEfforts: ["low", "medium", "high", "xhigh"], defaultEffort: "high",
        noModelsExplanation: "No Grok models — run grok once to sign in and fetch them.",
        skillSigil: "/", hookEndpoint: "/hook/grok",
        bundledResource: .script(GrokStatusLineConfig.shimName),
        launchArguments: { model, reasoning in ["-m", model] + (reasoning.map { ["--reasoning-effort", $0] } ?? []) },
        models: .files(sources: { GrokModelCatalog.sources(home: $0) }, read: { GrokModelCatalog.models(home: $0) }),
        skillRoots: { home, project in
            // Grok reads skills and flat commands from .grok, .agents and (Claude compatibility)
            // .claude, globally and in the project; only `commands/*.md` itself is a command
            // (08-skills.md). Its bundled skills come after the user's, which override them.
            let dots = [".grok", ".agents", ".claude"]
            func roots(in base: URL, _ source: AgentCompletion.Source) -> [SkillRoot] {
                dots.flatMap { dot in
                    [SkillRoot(.skills(hidingNonInvocable: true), base.appendingPathComponent("\(dot)/skills"), source),
                     SkillRoot(.commands(depth: 0), base.appendingPathComponent("\(dot)/commands"), source)]
                }
            }
            return roots(in: home, .user)
                + [SkillRoot(.skills(hidingNonInvocable: true), home.appendingPathComponent(".grok/bundled/skills"), .builtIn)]
                + (project.map { roots(in: $0, .project) } ?? [])
        },
        makeDriver: { home, port, shim in shim.map { GrokDriver(home: home, daemonPort: port, shimPath: $0) } })

    static let pi = Harness(
        agent: .pi, executable: "pi", displayName: "PI",
        installCommand: "curl -fsSL https://pi.dev/install.sh | sh",
        fallbackEfforts: PiModelCatalog.thinkingLevels, defaultEffort: "medium",
        noModelsExplanation: "No PI providers are signed in — run /login in PI.",
        skillSigil: "/", hookEndpoint: "/hook/pi",
        bundledResource: .source("pi-aiterm-status.ts"),
        launchArguments: { model, reasoning in ["--model", model] + (reasoning.map { ["--thinking", $0] } ?? []) },
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
