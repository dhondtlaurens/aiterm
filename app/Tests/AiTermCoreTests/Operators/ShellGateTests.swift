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
            "npm config list", "npm -v", "npm --version", "npx npm-check-updates --deep",
            "node -v", "node --version", "command -v git", "type git", "pwd",
            "ls -la", "ls -1t", "head -n 5 package.json", "head -5 package.json", "grep -n 'é' src", "git fetch origin main", "git fetch --prune --all",
            "git ls-remote --heads origin 'refs/heads/*'", "git status -s -b", "git diff --cached -U5", "git log HEAD~3..HEAD", "git show main~1:package.json", "git log --format=%H --since=2.weeks -n 5 main..HEAD",
            "gh api repos/a/b -i --paginate --jq '.[].number'", "gh pr view 12 --comments", "gh pr list --state open --limit 5 --json number",
            "gh run view 12 --log-failed", "glab mr list --author me", "glab ci status -b main", "tail -n 20 /runs/R/log", "wc -l package.json", "stat package.json",
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
            "npx npm-check-updates -u", "npm install", "npm audit fix", "glab api -X POST projects/1/merge_requests",
            "glab api projects/1 -f a=b", "find . -delete", "sed -i s/a/b/ f", "git push", "cat 'unbalanced",
        ]
        for command in writes {
            #expect(route(command) == .oracle, "\(command)")
        }
    }

    /// `ncu` is npm-check-updates' bin, but on the registry it is another package: where npm-check-updates isn't installed,
    /// npx would fetch that one and run it unasked. Only the full name is a read.
    @Test func npxNcuIsNoRead() {
        for command in ["npx ncu", "npx ncu --workspaces", "npx ncu --deep --format group"] {
            #expect(route(command) == .oracle, "\(command)")
        }
        #expect(route("npx npm-check-updates --workspaces") == .read(rewrite: nil))
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
            "npm config", "npm", "npx", "npx cowsay hi", "npx npm-check-updates --upgrade", "npx npm-check-updates -ui", "npx npm-check-updates --doctor",
            "node script.js", "node -e 1", "command git status", "ls | xargs rm", "echo hi", "curl x", "make",
            "tail -f log", "tail -F log", "file -C", "wc --files0-from=/etc/hosts", "grep -f /etc/hosts a",
            "grep -if /etc/hosts a", "grep --file=/etc/hosts a", "grep -R x .", "rg --pre sh x", "rg --follow x",
            "rg -L x", "rg --files /etc", "env FOO=1 git status", "printenv HOME",
        ]
        for command in hidden {
            #expect(route(command) == .oracle, "\(command)")
        }
    }

    @Test func theShellParsesBytesNotCharacters() {
        // A combining mark after a quote, a `;` or a `>` is one Character with it, but the shell still sees the metacharacter.
        for command in ["cat 'a'\u{301}; rm -rf x; echo '", "git log >\u{301}x", "git status ;\u{301} rm x", "cat 'a'\u{200D}| tee x",
                        "git status\u{0}", "git status\t&& rm x", "git status\u{7F}", "cat é", "git log --author=é", "git status\u{2028}",
                        "cat \"a\u{0}b\""] {
            #expect(route(command) == .oracle, "\(command.unicodeScalars.map(\.value))")
        }
    }

    @Test func unquotedBracesGlobsAndTildesGoToTheOracleWhereverTheyAre() {
        for command in ["git log {--output=/tmp/x,-1}", "npm audit {fix,}", "npx npm-check-updates {-u,}", "git status {-s,}", "git log --output=/tmp/x{,}",
                        "cat !x", "cat ~", "git log ~", "git log --author=~x", "git log -n ?", "npm ls [a]", "git branch {-D,} old", "git log *"] {
            #expect(route(command) == .oracle, "\(command)")
        }
        // Quoted, they are plain text.
        #expect(route("rg 'a{2}|b*' src") == .read(rewrite: nil))
    }

    @Test func anOptionThatIsNotNamedIsNeverARead() {
        for command in ["git fetch --upload-pa=touch origin", "git ls-remote --upload-pa=touch origin", "git fetch --receive-p=x origin",
                        "git fetch --exe=x", "git log --outp=/tmp/x", "git log --max-count=3", "git log --ext-diff", "git log --textconv",
                        "git diff --ext-di", "git diff --output-indicator-new=x", "git status --ignore-submodules", "git show --stat --output=x",
                        "git rev-parse --git-path x", "git merge-base --octopus a b", "git fetch --depth=1", "git fetch --prune -u",
                        "git ls-remote --exec=x origin", "git log -n --output=x", "git log -nx", "git diff -U",
                        "ls -L", "ls -LR", "ls --color", "ls -lL", "ls -R", "cat -v x", "head -f x", "tail -n5x f", "wc -L x", "stat -f %N x", "file -b -f x",
                        "grep --fil=/etc/hosts a", "grep --exclude-f=/etc/hosts a", "grep -e", "rg --fil=x a", "rg --pr=sh a", "rg -z a",
                        "npx npm-check-updates --upgrad", "npx npm-check-updates --format", "npx npm-check-updates --install always -u", "npm audit --fi", "npm audit signatures"] {
            #expect(route(command) == .oracle, "\(command)")
        }
    }

    @Test func aClusteredOrCutShortFlagCannotSendOrChangeAnything() {
        for command in ["gh api -iXPOST repos/a/b/issues", "gh api repos/a/b/issues -if title=x", "glab api projects/1 -iftitle=x",
                        "gh api repos/a/b -XGET", "gh api repos/a/b -X get", "gh api repos/a/b --method=POST", "gh api repos/a/b -i -X",
                        "gh api repos/a/b --hostname", "gh api", "gh api a b", "gh api repos/a/b --silent", "gh api repos/a/b -H x:y",
                        "gh pr view -w 1", "gh pr view 1 --web", "gh pr checks --watch 1", "gh pr checks 1 -w", "gh run view 1 -w",
                        "gh run view 1 --web", "gh pr list --web", "gh pr view 1 2", "gh pr diff 1 --color=always", "gh pr list --search x",
                        "glab mr view 1 -w", "glab mr view 1 --web", "glab ci status --live", "glab ci list -x", "glab mr list -ag"] {
            #expect(route(command) == .oracle, "\(command)")
        }
    }

    /// gh and glab send their token to the host they talk to: `-R` names a plain repository path, and `--hostname` or a
    /// path's host part one of the hosts the broadcast's projects are on. Anything else is the Oracle's.
    @Test func ghAndGlabReadOnlyFromTheBroadcastsHosts() {
        let hosts: Set<String> = ["gitlab.com", "github.com"]
        func route(_ command: String) -> ShellGate.Route { ShellGate.route(command, in: directory, roots: roots, hosts: hosts) }
        for command in ["glab mr view 3 -R team/shop", "glab mr list --repo team/shop -R gitlab.com/group/shop", "gh pr view 12 -R a/b",
                        "gh pr list --repo=a/b", "gh api repos/a/b --hostname github.com", "glab api projects/1 --hostname GitLab.com",
                        "glab ci status -R gitlab.com/group/sub/shop"] {
            #expect(route(command) == .read(rewrite: nil), "\(command)")
        }
        for command in ["glab api projects/1 --hostname other.host", "gh api repos/a/b --hostname=evil.example",
                        "glab mr view 3 -R https://other.host/a/b", "glab mr view 3 -R other.host/a/b", "gh pr view 1 -R evil.example/a/b",
                        "gh pr view 1 -R git@other.host:a/b", "gh pr view 1 -R user@a/b", "glab mr view 3 -R a", "glab mr view 3 -R a/../b",
                        "gh pr view 1 -R //a/b", "gh pr view 1 -R a/b/", "glab mr view 3 -R localhost:8080/a/b", "gh pr view 1 -R group/sub/shop",
                        "gh api repos/a/b --hostname github.com.evil.example", "gh api repos/a/b --hostname github.com:443"] {
            #expect(route(command) == .oracle, "\(command)")
        }
        // With no project on a host, no host is one to send to.
        #expect(ShellGate.route("gh api repos/a/b --hostname github.com", in: directory, roots: roots) == .oracle)
    }

    @Test func aFetchNamesARemoteAndPlainBranchesOnly() {
        for command in ["git fetch origin +main:feature", "git fetch origin main:feature", "git fetch origin :feature", "git fetch origin +main",
                        "git fetch ext::sh", "git fetch https://x/y.git", "git fetch /tmp/evil", "git fetch -- --upload-pack=x", "git fetch origin 'refs/*:refs/*'",
                        "git ls-remote ext::sh", "git ls-remote origin +x"] {
            #expect(route(command) == .oracle, "\(command)")
        }
    }

    @Test func npmTakesOnlyTheOptionsNamedForItsReads() {
        for command in ["npm ls --logs-dir=/tmp/x", "npm ls --logs-di=/tmp/x", "npm view react --cache=/tmp/c", "npm view react --cach=/tmp/c",
                        "npm outdated --cache /tmp/c", "npm list --prefix /tmp", "npm ls --global", "npm ls -g", "npm ls --depth=x", "npm ls --omit=all",
                        "npm ls --workspace=../x", "npm ls -w", "npm ls ../pkg", "npm ls /etc", "npm view", "npm view react --registry=http://x",
                        "npm config list --logs-dir=/tmp/x", "npm config list -L", "npm config get --logs-dir=/tmp/x", "npm config get",
                        "npm config get registry --cache=/tmp/c", "npm audit --audit-level=evil", "npm audit --cache=/tmp/c", "npm outdated --json --foo"] {
            #expect(route(command) == .oracle, "\(command)")
        }
        for command in ["npm ls", "npm ls react", "npm ls --all --json --long --parseable", "npm list --depth=0", "npm outdated --workspaces",
                        "npm outdated -w packages/a", "npm ls --workspace=a --omit=dev", "npm view react version", "npm view @scope/pkg@1.2 dist.tarball --json",
                        "npm config list --json", "npm config list -l", "npm config get registry", "npm audit --json --audit-level=high"] {
            #expect(route(command) == .read(rewrite: nil), "\(command)")
        }
    }

    @Test func zshExpansionsAtTheStartOfAWordGoToTheOracle() {
        for command in ["cat =ls", "=(ls)", "git status =cat", "git status | =cat", "cat (ls)", "cat package.json )", "diff =(ls) b", "git log -n =1",
                        "cat ''=ls", "cat \"\"=ls", "git diff ''=ls ''=cat", "cat ''\"\"=ls"] {
            #expect(route(command) == .oracle, "\(command)")
        }
        // Quoted, or inside a word, an equals sign is plain text.
        #expect(route("git log --author='=x' --format=%H") == .read(rewrite: nil))
        #expect(route("cat '=x'") == .read(rewrite: nil))
    }

    @Test func gitPathsAreHeldToTheRoots() {
        for command in ["git diff /etc/hosts /etc/passwd", "git diff -- /etc/hosts", "git diff ../a ../b", "git log /Users/x/.ssh", "git show /etc/hosts",
                        "git diff main -- ../../x", "git log -- /outside", "git -C /code/shop diff /etc/a /etc/b", "git status /etc", "git diff /code/shopfront/a /code/shopfront/b"] {
            #expect(route(command) == .oracle, "\(command)")
        }
        #expect(route("git diff link other", resolve: { $0 == "/code/shop/link" ? "/Users/x/a" : $0 }) == .oracle)
        for command in ["git diff /code/shop/a /code/shop/b", "git diff main..HEAD -- src/a.ts", "git log -- src", "git show HEAD:package.json", "git diff origin/main",
                        "git -C /runs/R diff a b", "git log /runs/R/x"] {
            #expect(route(command) == .read(rewrite: nil), "\(command)")
        }
    }

    @Test func aJqExpressionThatReadsTheEnvironmentGoesToTheOracle() {
        for command in ["gh api repos/a/b --jq env", "gh api repos/a/b --jq '$ENV.PATH'", "gh api repos/a/b -q '.x | env.HOME'", "gh api repos/a/b --jq=env",
                        "gh api repos/a/b -q 'ENV'", "glab api projects/1 --jq '[env]'", "gh pr view 1 --json number --jq env", "gh pr list --jq '$ENV'",
                        "gh run list -q '.[] | env'"] {
            #expect(route(command) == .oracle, "\(command)")
        }
        for command in ["gh api repos/a/b --jq '.[].environment'", "gh api repos/a/b -q '.[].number'", "gh pr list --json number --jq '.[] | .number'"] {
            #expect(route(command) == .read(rewrite: nil), "\(command)")
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
        process.environment = ["GITLAB_TOKEN": "abc", "PATH": "/bin", "my_Secret": "s", "aws_key_id": "k", "DB_PASSWORD": "p", "HOME": "/h",
                               "RSA_KEY": "-----BEGIN\nFOO=bar\nSECRET_X=1\n-----END", "NOTE": "line\nMORE=text"]
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
        // A multi-line value is masked whole: none of its lines is printed, whatever it looks like.
        #expect(lines.contains("RSA_KEY=***"))
        #expect(!lines.contains { $0.contains("BEGIN") || $0.contains("FOO=bar") || $0.contains("SECRET_X") || $0.contains("END") })
        // A variable that is not secret is printed as it is, lines and all.
        #expect(lines.contains("NOTE=line") && lines.contains("MORE=text"))
    }

    // MARK: Hard denials (spec §A.2)

    @Test func everyPushIsRefusedForFinishTask() {
        for command in ["git push", "git push origin feat/x", "git push --force-with-lease", "git -C /code/shop push", "git -c a=b push",
                        "git --no-pager push", "git --git-dir=/code/shop/.git push", "git --git-dir /code/shop/.git push origin",
                        "/usr/bin/git push", "cd /code/shop && git push", "git status; git push", "git status | git push",
                        "FOO=1 git push", "env GIT_TRACE=1 git push", "command git push", "nohup git push &", "timeout 10 git push",
                        "(git push)", "{ git push; }", "echo $(git push)", "echo \"$(git push)\"", "echo `git push`", "git pu\\sh",
                        "'git' 'push'", "sh -c 'git push'", "bash -lc \"git push origin\"", "zsh -c 'cd x && git push'", "eval git push",
                        "git status\ngit push", "git -c alias.p=push p", "git -c 'alias.p=!git push' p", "git push 2>&1 | tail -5",
                        "git 2>/dev/null push", "if true; then git push; fi"] {
            #expect(ShellGate.hardDenial(command) == ShellGate.pushDenial, "\(command)")
        }
        #expect(ShellGate.pushDenial.contains("finish_task"))
    }

    @Test func aWorkersChangesToACheckoutAreRefused() {
        let cases: [(String, String)] = [
            ("git commit -m x", "git commit"), ("git -C /code/shop commit -am x", "git commit"), ("git -c user.name=x commit", "git commit"),
            ("git reset --hard", "git reset --hard"), ("git reset --hard origin/main", "git reset --hard"),
            ("git -c core.x=y reset --hard HEAD~1", "git reset --hard"), ("git -C /code/shop reset -q --hard", "git reset --hard"),
            ("git checkout main", "git checkout"), ("git --no-pager checkout -- .", "git checkout"), ("git -C x checkout -b y", "git checkout"),
            ("git switch main", "git switch"), ("git -C /code/shop switch x", "git switch"), ("git -c a=b switch -c y", "git switch"),
            ("git clean -fdx", "git clean"), ("git -C /code/shop clean -fdx", "git clean"), ("git -C x clean -n", "git clean"),
            ("git --git-dir=/x/.git clean -f", "git clean"), ("git --work-tree /x clean -f", "git clean"),
        ]
        for (command, what) in cases {
            #expect(ShellGate.hardDenial(command) == ShellGate.workerDenial(what), "\(command)")
        }
        #expect(ShellGate.workerDenial("git clean").contains("message_task"))
    }

    @Test func mergesAndChangesToARequestOnTheHostAreRefused() {
        let cases: [(String, String)] = [
            ("gh pr merge 12", "gh pr merge"), ("gh pr merge --squash 12", "gh pr merge"), ("gh pr -R a/b merge 12", "gh pr merge"),
            ("gh pr close 12", "gh pr close"), ("gh pr edit 12 --title x", "gh pr edit"), ("gh pr review 12 --approve", "gh pr review"),
            ("gh pr ready 12", "gh pr ready"), ("gh pr reopen 12", "gh pr reopen"), ("gh pr comment 12 -b hi", "gh pr comment"),
            ("gh pr create --fill", "gh pr create"), ("glab mr merge 3", "glab mr merge"), ("glab mr accept 3", "glab mr accept"),
            ("glab mr close 3", "glab mr close"), ("glab mr approve 3", "glab mr approve"), ("glab mr update 3 --draft", "glab mr update"),
            ("glab mr note 3 -m hi", "glab mr note"), ("glab mr rebase 3", "glab mr rebase"), ("glab -R a/b mr merge 3", "glab mr merge"),
            ("/opt/homebrew/bin/glab mr merge 3", "glab mr merge"), ("cd /code/shop && glab mr approve", "glab mr approve"),
        ]
        for (command, what) in cases {
            #expect(ShellGate.hardDenial(command) == ShellGate.hostDenial(what), "\(command)")
        }
        #expect(ShellGate.hostDenial("gh pr merge").contains("finish_task"))
    }

    @Test func anAPICallThatIsNoGetIsRefused() {
        for command in ["gh api -X PUT repos/a/b/pulls/1/merge", "gh api repos/a/b/pulls/1/merge -XPUT", "gh api --method=PATCH repos/a/b/pulls/1",
                        "gh api --method POST repos/a/b/issues", "gh api -iXPOST repos/a/b/issues", "gh api repos/a/b/issues -f title=x",
                        "gh api repos/a/b/issues -F title=x", "gh api repos/a/b/issues --field title=x", "gh api repos/a/b --raw-field=a=b",
                        "gh api repos/a/b --input body.json", "gh api repos/a/b -iftitle=x", "gh api graphql -f query=x"] {
            #expect(ShellGate.hardDenial(command) == ShellGate.apiDenial("gh"), "\(command)")
        }
        for command in ["glab api -X PUT projects/1/merge_requests/3/merge", "glab api projects/1/merge_requests/3/merge --method PUT",
                        "glab api projects/1/merge_requests/3/notes -f body=x", "glab api projects/1 -XDELETE"] {
            #expect(ShellGate.hardDenial(command) == ShellGate.apiDenial("glab"), "\(command)")
        }
    }

    /// Claude's backstop names nothing the gate lets through: each `OperatorCommand.shellDenials` pattern, its wildcards
    /// filled, is a hard denial. A reset is the hard one: Claude's prefix match can't find `--hard` after `-C <dir>` or
    /// `-c k=v`, so those two patterns refuse every reset, where the gate sends a soft one to the Oracle
    /// (`readsAndOtherCommandsAreNoHardDenial`).
    @Test(arguments: OperatorCommand.shellDenials)
    func everyBackstopPatternIsAHardDenial(_ pattern: String) throws {
        let inner = try #require(pattern.wholeMatch(of: /Bash\((.+):\*\)/)?.1, "\(pattern) is no Bash(…:*) pattern")
        var command = String(inner.replacing("-C *", with: "-C /code/shop").replacing("-c *", with: "-c core.pager=cat")
            .replacing(" * ", with: " --no-pager "))
        if command.hasSuffix(" reset") { command += " --hard" }
        #expect(ShellGate.hardDenial(command) != nil, "\(command)")
    }

    @Test func readsAndOtherCommandsAreNoHardDenial() {
        for command in ["git status", "git log --grep push", "git log -- commit.ts", "git show HEAD:checkout.md", "git reset --soft HEAD~1",
                        "git reset HEAD file", "git fetch origin", "git branch --contains abc", "git diff main", "git stash list",
                        "echo git push", "grep -rn 'git push' .", "cat push.md", "npm run commit", "gh pr view 12", "gh pr list",
                        "gh pr checks 12", "gh pr diff 12", "glab mr view 3", "glab mr list", "glab mr diff 3", "glab ci status",
                        "gh api repos/a/b/pulls", "gh api repos/a/b/pulls -X GET -f state=open", "gh api repos/a/b --method get",
                        "glab api projects/1/merge_requests", "gh run rerun 1", "npm install", "rm -rf node_modules", "",
                        "git -C /code/shop log --oneline", "git -c core.pager=cat log", "git -c alias.st=status st"] {
            #expect(ShellGate.hardDenial(command) == nil, "\(command)")
        }
    }
}
