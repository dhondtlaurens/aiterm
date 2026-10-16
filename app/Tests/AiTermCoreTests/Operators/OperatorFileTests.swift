import Testing
import Foundation
@testable import AiTermCore

@Suite struct OperatorFileTests {
    /// The spec's own example (§4.0), comments and all.
    static let example = """
    ---
    name: Senior engineer
    handle: senior
    model: claude-opus-5-5
    effort: high
    secondOpinion:
      level: healthyDoubt     # noSelfDoubt | healthyDoubt | impostor (§4.4)
      agent: codex
      model: gpt-6-astra
      effort: medium
    autonomy: routine         # askFirst | routine | trusted | handsOff
    alwaysAsk:                # added to the fixed list (§4.2)
      - database migrations
    limits:
      retries: 2              # relaunches of a failed task
      runtimeMinutes: 90      # per task, counted while it works (not while it waits on you)
    ---
    ## Persona

    You are a senior frontend engineer on Nuxt and Storyblok projects. You keep changes small…

    ## Lessons

    - Ask before adding a field a ticket doesn't mention.
    """

    @Test func theSpecsExampleParses() throws {
        let p = try OperatorFile.parse(Self.example)
        #expect(p == OperatorPersona(
            name: "Senior engineer", handle: "senior", model: "claude-opus-5-5", effort: "high",
            secondOpinion: SecondOpinion(level: .healthyDoubt, agent: .codex, model: "gpt-6-astra", effort: "medium"),
            autonomy: .routine, alwaysAsk: ["database migrations"], limits: OperatorLimits(retries: 2, runtimeMinutes: 90),
            persona: "You are a senior frontend engineer on Nuxt and Storyblok projects. You keep changes small…",
            lessons: ["Ask before adding a field a ticket doesn't mention."]))
    }

    /// Whatever the sheet can hold comes back from its file as it was: quotes, colons, `#`, a
    /// model id zsh would glob, a multi-line persona with its own subheadings, several lessons.
    @Test(arguments: [
        OperatorPersona(name: "Ops: the \"careful\" one #1", handle: "ops-1", model: "claude-fable-5-1[1m]", effort: nil,
                        secondOpinion: SecondOpinion(level: .impostor, agent: .claude, model: "opus", effort: nil),
                        autonomy: .handsOff, alwaysAsk: ["anything: with a colon", "true", "  padded"],
                        limits: OperatorLimits(retries: 0, runtimeMinutes: 15),
                        persona: "Line one.\n\n### Style\n\n- keep it short\n- # not a comment",
                        lessons: ["First lesson.", "Second: with a colon.", "Third # with a hash."]),
        OperatorPersona(name: "Plain", handle: "plain", model: "opus", effort: "low",
                        secondOpinion: .standard, autonomy: .askFirst, persona: "", lessons: []),
    ])
    func renderThenParseGivesThePersonaBack(_ persona: OperatorPersona) throws {
        #expect(try OperatorFile.parse(OperatorFile.render(persona)) == persona)
    }

    @Test func renderWritesTheSpecsLayout() {
        let text = OperatorFile.render(try! OperatorFile.parse(Self.example))
        #expect(text.hasPrefix("---\nname: Senior engineer\nhandle: senior\nmodel: claude-opus-5-5\neffort: high\nsecondOpinion:\n  level: healthyDoubt"))
        #expect(text.contains("\n---\n## Persona\n\nYou are a senior"))
        #expect(text.hasSuffix("## Lessons\n\n- Ask before adding a field a ticket doesn't mention.\n"))
    }

    /// Decided: a key this build does not know is ignored, not preserved. The sheet writes the
    /// whole file from the persona, so the next save from AiTerm drops it.
    @Test func anUnknownKeyIsIgnoredAndNotWrittenBack() throws {
        let text = Self.example.replacingOccurrences(of: "autonomy: routine", with: "colour: teal\nautonomy: routine\nextras:\n  depth: 3")
        let p = try OperatorFile.parse(text)
        #expect(p == (try OperatorFile.parse(Self.example)))
        #expect(!OperatorFile.render(p).contains("colour") && !OperatorFile.render(p).contains("extras"))
    }

    /// A flow list reads like the block one, quoting and all; `[]` is none.
    @Test func aFlowListIsAList() throws {
        let head = "---\nname: n\nhandle: h\nmodel: m\n"
        let p = try OperatorFile.parse(head + "alwaysAsk: [database migrations, \"deploys, all of them\", 'it''s']  # why\n---\n")
        #expect(p.alwaysAsk == ["database migrations", "deploys, all of them", "it's"])
        #expect(try OperatorFile.parse(head + "alwaysAsk: []\n---\n").alwaysAsk.isEmpty)
        #expect(try OperatorFile.parse(head + "alwaysAsk: [ one ]\n---\n").alwaysAsk == ["one"])
        // A quoted "[…]" is a scalar, not a list.
        #expect(throws: OperatorFile.ParseError.invalidValue(key: "alwaysAsk", value: "[a]")) {
            try OperatorFile.parse(head + "alwaysAsk: \"[a]\"\n---\n")
        }
    }

    @Test func missingOptionalKeysTakeTheirDefaults() throws {
        let p = try OperatorFile.parse("---\nname: N\nhandle: n\nmodel: opus\n---\nBe brief.\n")
        #expect(p.effort == nil)
        #expect(p.secondOpinion == .standard)
        #expect(p.autonomy == .routine)
        #expect(p.alwaysAsk.isEmpty && p.lessons.isEmpty)
        #expect(p.limits == OperatorLimits())
        #expect(p.persona == "Be brief.")
    }

    /// Lessons kept by hand in other bullet styles and wrapped lines still read as lessons.
    @Test func lessonsAcceptStarsAndWrappedLines() throws {
        let p = try OperatorFile.parse("---\nname: N\nhandle: n\nmodel: opus\n---\n## Lessons\n\n* One\n- Two that\n  wraps\n\nstray text\n")
        #expect(p.lessons == ["One", "Two that wraps"])
        #expect(p.persona.isEmpty)
    }

    @Test func aWindowsLineEndedFileParses() throws {
        let p = try OperatorFile.parse(Self.example.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(p.handle == "senior" && p.lessons.count == 1)
    }

    @Test(arguments: [
        ("name: x\n---\n", OperatorFile.ParseError.missingFrontmatter),
        ("---\nname: x\n", .missingFrontmatter),
        ("---\nhandle: h\nmodel: m\n---\n", .missingKey("name")),
        ("---\nname: n\nhandle: h\n---\n", .missingKey("model")),
        ("---\nname: n\nhandle: h\nmodel: m\nautonomy: yolo\n---\n", .invalidValue(key: "autonomy", value: "yolo")),
        ("---\nname: n\nhandle: h\nmodel: m\nlimits:\n  retries: -1\n---\n", .invalidValue(key: "limits.retries", value: "-1")),
        ("---\nname: n\nhandle: h\nmodel: m\nsecondOpinion:\n  agent: gemini\n---\n", .invalidValue(key: "secondOpinion.agent", value: "gemini")),
        ("---\nname: n\nhandle: h\n  stray: 1\nmodel: m\n---\n", .unreadableLine(4, "  stray: 1")),
        ("---\nname n\n---\n", .unreadableLine(2, "name n")),
        // A known key of the wrong shape is refused, never read as its default.
        ("---\nname: n\nhandle: h\nmodel: m\nalwaysAsk: deploys\n---\n", .invalidValue(key: "alwaysAsk", value: "deploys")),
        ("---\nname: n\nhandle: h\nmodel: m\nalwaysAsk:\n  kind: deploys\n---\n", .invalidValue(key: "alwaysAsk", value: "a map")),
        ("---\nname: n\nhandle: h\nmodel: m\nalwaysAsk: [a, \"b]\n---\n", .unreadableLine(5, "alwaysAsk: [a, \"b]")),
        ("---\nname: n\nhandle: h\nmodel: m\nlimits: 5\n---\n", .invalidValue(key: "limits", value: "5")),
        ("---\nname: n\nhandle: h\nmodel: m\nlimits:\n  - 5\n---\n", .invalidValue(key: "limits", value: "[5]")),
        ("---\nname: n\nhandle: h\nmodel: m\nsecondOpinion: codex\n---\n", .invalidValue(key: "secondOpinion", value: "codex")),
        ("---\nname: n\nhandle: h\nmodel: m\nautonomy: [routine]\n---\n", .invalidValue(key: "autonomy", value: "[routine]")),
        ("---\nname: [n]\nhandle: h\nmodel: m\n---\n", .invalidValue(key: "name", value: "[n]")),
    ])
    func whatCannotBeReadIsSaid(_ text: String, _ error: OperatorFile.ParseError) {
        #expect(throws: error) { try OperatorFile.parse(text) }
    }
}
