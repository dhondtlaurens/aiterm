import Foundation

/// Claude's hooks are off and its Bash sandbox has no network.
private let claudeSettings = #"{"disableAllHooks":true,"sandbox":{"enabled":true,"allowUnsandboxedCommands":false,"network":{"allowedDomains":[]}}}"#
private let claudeSettingSources = ["--setting-sources", "user"]
private let claudeNoWeb = ["WebFetch", "WebSearch"]
private let readTools = ["Read", "Grep", "Glob"]
private let writeTools = ["Bash", "Edit", "Write", "NotebookEdit"]
/// Ignore user configuration so MCP servers cannot run outside the sandbox; auth still comes from `CODEX_HOME`.
private let codexQuiet = ["--ignore-user-config", "--disable", "hooks"]
/// PI has no sandbox: its tool set keeps it to reading, with extensions and MCP servers off.
private let piReadingTools = ["read", "grep", "find", "ls"]
private let piHeadlessOptions = ["--no-session", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--no-approve", "--offline"]
/// An answer file larger than this is not an answer.
private let answerLimit = 1_000_000

/// The three harnesses, side by side: what differs between them is read here, in one table.
extension Harness {
    static let claude = claude(config: ClaudeConfig())

    static func claude(config: ClaudeConfig) -> Harness { Harness(
        agent: .claude, executable: "claude", displayName: "Claude Code",
        installCommand: "curl -fsSL https://claude.ai/install.sh | bash",
        fallbackEfforts: ["low", "medium", "high"], defaultEffort: "high",
        noModelsExplanation: "No models are available.",
        skillSigil: "/", hookEndpoint: "/hook/claude",
        bundledResource: .script("claude-statusline-shim.sh"),
        launchArguments: { Harness.claude.modelArguments(model: $0, reasoning: $1) },
        modelArguments: { model, reasoning in
            ["--model", model] + (reasoning.map { ["--effort", $0] } ?? [])
        },
        readOnlyLaunchArguments: nil,
        readOnlyHeadless: { prompt, _, readable, _, model, reasoning in
            // The read tools are the whole tool set, with writes and web tools denied besides.
            ["-p", prompt, "--permission-mode", "dontAsk", "--tools", readTools.joined(separator: ","), "--allowedTools"]
                + readTools + ["--disallowedTools"] + writeTools + claudeNoWeb
                + ["--output-format", "json", "--strict-mcp-config", "--settings", claudeSettings]
                + claudeSettingSources + (readable.isEmpty ? [] : ["--add-dir"] + readable)
                + (model.isEmpty ? [] : Harness.claude.modelArguments(model: model, reasoning: reasoning))
        },
        readsAnswerFromFile: false,
        headlessAnswer: { stdout, _ in
            struct ClaudeResult: Decodable { var result: String? }
            return (try? JSONDecoder().decode(ClaudeResult.self, from: Data(stdout.utf8)))?.result
        },
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
        fallbackEfforts: ["minimal", "low", "medium", "high", "xhigh"], defaultEffort: "medium",
        noModelsExplanation: "No models are available.",
        // Codex runs a skill as a `$` mention and keeps `/` for its commands, `/prompts:<name>`
        // among them.
        skillSigil: "$", hookEndpoint: "/hook/codex",
        bundledResource: nil,
        launchArguments: { model, reasoning in
            ["--dangerously-bypass-approvals-and-sandbox"] + Harness.codex.modelArguments(model: model, reasoning: reasoning)
        },
        modelArguments: { model, reasoning in
            ["-m", model] + (reasoning.map { ["-c", "model_reasoning_effort=\($0)"] } ?? [])
        },
        readOnlyLaunchArguments: { model, reasoning in
            ["--sandbox", "read-only", "--ask-for-approval", "never"] + Harness.codex.modelArguments(model: model, reasoning: reasoning)
        },
        readOnlyHeadless: { prompt, folder, _, answerFile, model, reasoning in
            ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--json", "-C", folder, "-o", answerFile]
                + codexQuiet + (model.isEmpty ? [] : Harness.codex.modelArguments(model: model, reasoning: reasoning)) + [prompt]
        },
        readsAnswerFromFile: true,
        headlessAnswer: { _, answerFile in
            guard let answerFile, case .bytes(let data) = RegularFile.read(answerFile, limit: answerLimit) else { return nil }
            return String(decoding: data, as: UTF8.self)
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
        fallbackEfforts: ["off", "minimal", "low", "medium", "high", "xhigh", "max"], defaultEffort: "medium",
        noModelsExplanation: "No PI providers are signed in. Run /login in PI.",
        skillSigil: "/", hookEndpoint: "/hook/pi",
        bundledResource: .source("pi-aiterm-status.ts"),
        launchArguments: { Harness.pi.modelArguments(model: $0, reasoning: $1) },
        modelArguments: { model, reasoning in
            ["--model", model] + (reasoning.map { ["--thinking", $0] } ?? [])
        },
        readOnlyLaunchArguments: nil,
        readOnlyHeadless: { prompt, _, _, _, model, reasoning in
            let effort = reasoning.flatMap { Harness.pi.fallbackEfforts.contains($0) ? $0 : nil }
            // PI reads any path; `--` keeps a prompt starting with a dash the prompt.
            return ["-p"] + piHeadlessOptions + ["--tools", piReadingTools.joined(separator: ",")]
                + (model.isEmpty ? [] : Harness.pi.modelArguments(model: model, reasoning: effort)) + ["--", prompt]
        },
        readsAnswerFromFile: false,
        headlessAnswer: { stdout, _ in stdout },
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
