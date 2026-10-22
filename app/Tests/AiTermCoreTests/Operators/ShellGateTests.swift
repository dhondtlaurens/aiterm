import Foundation
import Testing
@testable import AiTermCore

@Suite struct ShellGateTests {
    let directory = "/code/shop"
    let roots = ["/code/shop", "/runs/R"]

    func route(_ command: String, in directory: String? = nil, resolve: ((String) -> String)? = nil) -> ShellGate.Route {
        let directory = directory ?? self.directory
        guard let resolve else { return ShellGate.route(command, in: directory, roots: roots) }
        return ShellGate.route(command, in: directory, roots: roots, resolve: resolve)
    }

    @Test func readsRunAtOnce() {
        let reads = [
            "git status", "git -C /code/shop log --oneline -5", "glab mr view 412", "gh api repos/a/b/pulls",
            "npm outdated --workspaces", "npx npm-check-updates --workspaces --format group", "which node",
            "cat package.json", "git status | head -20", "git diff --stat 2>&1",
        ]
        for command in reads {
            #expect(route(command) == .read(rewrite: nil), "\(command)")
        }
    }

    @Test func theAllowedSubcommandsAreReads() {
        let reads = [
            "git log -p -3", "git show HEAD~1", "git rev-parse --abbrev-ref HEAD", "git merge-base main HEAD",
            "git branch", "git branch -a", "git branch -vv", "git branch --show-current", "git branch --contains abc123",
            "git worktree list", "git remote -v", "git remote get-url origin", "git ls-remote origin", "git fetch origin",
            "glab mr list", "glab mr diff 3", "glab ci status", "glab ci view", "glab api projects/1 -X GET",
            "gh pr checks 12", "gh run list", "gh api repos/a/b --method GET",
            "npm ls", "npm list --depth 0", "npm audit", "npm view react version", "npm config get registry",
            "npm config list", "npm -v", "npm --version", "npx ncu --workspaces",
            "node -v", "node --version", "command -v git", "type git", "pwd",
            "ls -la", "head -n 5 package.json", "tail -n 20 /runs/R/log", "wc -l package.json", "stat package.json",
            "file package.json", "grep -rn TODO src", "rg 'foo.*bar' src", "git status && git diff --stat",
            "git log >/dev/null", "git status 2>/dev/null; pwd", "git status || pwd",
        ]
        for command in reads {
            #expect(route(command) == .read(rewrite: nil), "\(command)")
        }
    }

    @Test func writesGoToTheOracle() {
        let writes = [
            "git status && rm -rf x", "cat a > b", "git diff --output=x", "git branch -D old",
            "git -c core.sshCommand=x fetch", "git fetch --upload-pack=evil", "echo $(whoami)", "echo `id`",
            "npx ncu -u", "npm install", "npm audit fix", "glab api -X POST projects/1/merge_requests",
            "glab api projects/1 -f a=b", "find . -delete", "sed -i s/a/b/ f", "git push", "cat 'unbalanced",
        ]
        for command in writes {
            #expect(route(command) == .oracle, "\(command)")
        }
    }

    @Test func shellSyntaxThatCouldHideAWriteGoesToTheOracle() {
        let hidden = [
            "", "   ", "git status &", "git status &&", "git status; ; pwd", "cat <(ls)", "cat package.json >(tee x)",
            "git status\nrm x", "cat package.json < /etc/hosts", "git log >out", "git log &> out", "git log >&2",
            "(git status)", "cat \"unbalanced", "cat $HOME/.npmrc", "cat \"$HOME/.npmrc\"", "cat \"$(id)\"", "cat a\\ b",
            "FOO=1 git status", "/bin/cat package.json", "git log | tee out", "git push --dry-run", "git remote add a b",
            "git remote set-url origin x", "git worktree add ../x", "git branch new", "git branch --list x -D",
            "git branch --contains", "git ls-remote --upload-pack=x origin", "git fetch --receive-pack=x",
            "git diff --ext-diff", "git show --output x", "git diff --no-index /etc/hosts a", "git -C",
            "git -C /code/shop -C /etc status", "git --git-dir=/etc status", "git -C /etc status",
            "glab mr merge 1", "glab mr close 1", "glab ci run", "glab api", "glab api projects/1 --method DELETE",
            "glab api projects/1 -XPOST", "gh api repos/a/b --input x", "gh api repos/a/b -F a=b",
            "gh api repos/a/b --raw-field a=b", "gh pr merge 1", "gh run rerun 1", "gh api repos/a/b -X PATCH",
            "npm run build", "npm publish", "npm audit --fix", "npm config set a b", "npm config get //r/:_authToken",
            "npm config", "npm", "npx", "npx cowsay hi", "npx ncu --upgrade", "npx ncu -ui", "npx ncu --doctor",
            "node script.js", "node -e 1", "command git status", "ls | xargs rm", "echo hi", "curl x", "make",
            "tail -f log", "tail -F log", "file -C", "wc --files0-from=/etc/hosts", "grep -f /etc/hosts a",
            "grep -if /etc/hosts a", "grep --file=/etc/hosts a", "grep -R x .", "rg --pre sh x", "rg --follow x",
            "rg -L x", "rg --files /etc", "env FOO=1 git status", "printenv HOME",
        ]
        for command in hidden {
            #expect(route(command) == .oracle, "\(command)")
        }
    }

    @Test func pathsStayInsideTheBroadcast() {
        for command in ["cat ../../.ssh/id_rsa", "cat ~/.npmrc", "cat /etc/hosts", "cat ~root/x", "ls /", "cat package.json /etc/hosts",
                        "head -n 3 /etc/hosts", "cat /code/shop/../../etc/hosts", "cat *", "ls src/*.ts", "cat {a,b}",
                        "grep -r x /etc", "rg x ../other", "cat /code/shopfront/x"] {
            #expect(route(command) == .oracle, "\(command)")
        }
        #expect(route("cat link", resolve: { $0 == "/code/shop/link" ? "/Users/x/.ssh/id_rsa" : $0 }) == .oracle)
        #expect(route("cat /code/shop/link", resolve: { $0 == "/code/shop/link" ? "/Users/x/.ssh/id_rsa" : $0 }) == .oracle)
    }

    @Test func pathsInsideARootAreReads() {
        for command in ["cat /code/shop/package.json", "cat /runs/R/notes.md", "ls /runs/R", "cat 'my file.txt'",
                        "cat -- -weird", "grep -n 'a.*b' /runs/R/log", "grep foo", "ls"] {
            #expect(route(command) == .read(rewrite: nil), "\(command)")
        }
        // A symlink that stays inside the roots is no escape.
        #expect(route("cat link", resolve: { $0 == "/code/shop/link" ? "/runs/R/real" : $0 }) == .read(rewrite: nil))
    }

    @Test func aCommandIsJudgedFromTheDirectoryItRunsIn() {
        #expect(route("cat package.json", in: "/runs/R/sub") == .read(rewrite: nil))
        #expect(route("cat package.json", in: "/home/me") == .oracle)
        #expect(route("ls", in: "/home/me") == .oracle)
        #expect(route("git status", in: "/home/me") == .oracle)
        #expect(route("grep -r foo", in: "/home/me") == .oracle)
        #expect(route("git -C /runs/R status", in: "/home/me") == .read(rewrite: nil))
        #expect(route("git -C sub status", in: "/code/shop") == .read(rewrite: nil))
        #expect(route("which node", in: "/home/me") == .read(rewrite: nil))
        #expect(ShellGate.route("cat package.json", in: "/code/shop", roots: []) == .oracle)
    }

    @Test func envIsMasked() throws {
        #expect(route("env") == .read(rewrite: ShellGate.maskedEnv))
        #expect(route("printenv") == .read(rewrite: ShellGate.maskedEnv))
        #expect(route("env 2>&1") == .read(rewrite: ShellGate.maskedEnv))
        // The rewrite replaces the whole command, so an env inside a longer one is not rewritten but judged.
        #expect(route("env | grep TOKEN") == .oracle)
        #expect(route("git status && env") == .oracle)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ShellGate.maskedEnv]
        process.environment = ["GITLAB_TOKEN": "abc", "PATH": "/bin", "my_Secret": "s", "aws_key_id": "k", "DB_PASSWORD": "p", "HOME": "/h"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        for expected in ["GITLAB_TOKEN=***", "PATH=/bin", "my_Secret=***", "aws_key_id=***", "DB_PASSWORD=***", "HOME=/h"] {
            #expect(lines.contains(expected), "\(expected) in \(lines)")
        }
        #expect(!lines.contains { $0.contains("abc") || $0.contains("=s") || $0.contains("=p") })
    }
}
