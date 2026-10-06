import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct LoginShellTests {
    /// `command -v` answers first, then `whence -p`, each line `name<TAB>answer`.
    private func located(_ output: String, names: [String] = ["claude", "codex", "pi"],
                         isExecutable: @escaping (String) -> Bool = LoginShell.isExecutableFile) -> [String: String]? {
        LoginShell.locate(names, runner: { _ in output }, isExecutable: isExecutable)
    }

    @Test func aPathOnThePATHIsWhereTheCLIIs() {
        #expect(located("claude\t/bin/sh\nclaude\t/bin/sh\n") == ["claude": "/bin/sh"])
    }

    /// Claude's own installer can leave `alias claude=~/.claude/local/claude` and nothing on the
    /// `PATH`. The task window's shell runs the alias, so the CLI is where the alias points.
    @Test func anAliasIsItsFirstAbsoluteWord() {
        #expect(located("claude\talias claude=/bin/sh\nclaude\t\n") == ["claude": "/bin/sh"])
        #expect(located("codex\talias codex='nocorrect /bin/sh --flag'\ncodex\t\n") == ["codex": "/bin/sh"])
        #expect(located("pi\talias pi='\"/bin/sh\" '\\''x'\\'\npi\t\n") == ["pi": "/bin/sh"])
        let home = NSHomeDirectory()
        #expect(located("claude\talias claude='~/.claude/local/claude'\nclaude\t\n", isExecutable: { $0 == home + "/.claude/local/claude" })
                == ["claude": home + "/.claude/local/claude"])
    }

    /// A shell function — or an alias to a bare name — is not a file to run. What it wraps is
    /// usually the CLI on the `PATH`, which is what `whence -p` finds.
    @Test func aFunctionFallsBackToThePATH() {
        #expect(located("claude\tclaude\nclaude\t/bin/sh\n") == ["claude": "/bin/sh"])
        #expect(located("codex\talias codex='codex --yolo'\ncodex\t/bin/sh\n") == ["codex": "/bin/sh"])
        #expect(located("pi\tpi\npi\t\n") == [:])
    }

    /// rc-file banners share the stream; only an answer for a name asked about, naming an
    /// executable file, counts.
    @Test func noiseAndMissingFilesAreNotACLI() {
        #expect(located("Welcome to zsh\nclaude\t\nclaude\t\n") == [:])
        #expect(located("codex\t/definitely/not/here/codex\ncodex\t\n") == [:])
        #expect(located("codex\t/bin\ncodex\t\n") == [:], "a directory is not a CLI")
        #expect(located("sh\t/bin/sh\n") == [:], "a name not asked about")
    }

    @Test func aShellThatFailedLocatedNothing() {
        #expect(LoginShell.locate(["claude"], runner: { _ in nil }) == nil)
    }

    /// The query, in the zsh it is written for, with an alias and a function defined.
    @Test func theQueryAnswersInTheFormItIsReadIn() throws {
        let located = LoginShell.locate(["aliased", "sh", "missing"], runner: { query in
            let script = "alias aliased='nocorrect /bin/ls -la'; sh() { :; }; " + query
            let result = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-fc", script], timeout: 5)
            return result?.status == 0 ? result?.stdout : nil
        })
        #expect(located == ["aliased": "/bin/ls", "sh": "/bin/sh"])
    }

    /// Only names that are safe to put in a shell command unquoted are asked about.
    @Test func anUnsafeNameIsNeverAskedAbout() {
        var asked: [String] = []
        _ = LoginShell.locate(["claude", "x; rm -rf ~", ""], runner: { asked.append($0); return "" })
        #expect(asked == [LoginShell.locateQuery(["claude"])])
    }
}
