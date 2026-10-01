import Foundation

public enum PythonLocator {
    static let versions = ["3.14", "3.13", "3.12", "3.11"]

    /// Asks about the versioned names too, because `python3` alone can be macOS's own 3.9. The
    /// loop prints nothing for a name that is missing, and the trailing `true` keeps one missing
    /// name from failing the whole command — `LoginShell.run` discards the output of a non-zero one.
    static let candidateQuery = "for c in python3 \(versions.map { "python\($0)" }.joined(separator: " ")); do command -v $c; done; true"

    /// Where Homebrew and python.org put interpreters. The shell answer is not enough on its own:
    /// `zsh -lic` reads zsh's rc files, so a user whose login shell is bash — or whose
    /// Homebrew `PATH` is only ever set for that other shell — hands us nothing.
    static let wellKnownPaths: [String] = {
        var paths = ["/opt/homebrew/bin", "/usr/local/bin"].flatMap { dir in
            ["\(dir)/python3"] + versions.map { "\(dir)/python\($0)" }
        }
        paths += versions.map { "/Library/Frameworks/Python.framework/Versions/\($0)/bin/python3" }
        paths.append("/usr/bin/python3")
        return paths
    }()

    /// Interpreters worth probing, best guess first. Only absolute paths survive: `command -v`
    /// prints a bare `python3` when the name is a shell function or alias, and `Process` searches
    /// no `PATH`, so such a name reaches the supervisor as a file that does not exist — which is
    /// how a machine running Aikido safe-chain (it wraps `python3` in a shell function) got
    /// "The file \u{201C}python3\u{201D} doesn\u{2019}t exist." on every restart. Login-shell rc
    /// files print banners onto the same stream, and those are dropped by the same rule.
    public static func candidates(shellOutput: String?) -> [URL] {
        let fromShell = (shellOutput ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") }
        var seen = Set<String>()
        return (fromShell + wellKnownPaths).filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
    }

    /// Runs the candidate itself, rather than its name through the login shell: the supervisor
    /// spawns this exact file with `Process`, so this is the only check that proves it can.
    public static func isSupported(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              fm.isExecutableFile(atPath: url.path) else { return false }
        guard let result = try? ProcessRunner.run(url, ["-c", "import sys; print(sys.version_info >= (3, 11))"], timeout: 10),
              result.status == 0 else { return false }
        return result.stdout.contains("True")
    }

    public static func find(runner: (String) -> String? = LoginShell.run, validate: (URL) -> Bool = isSupported) -> URL? {
        candidates(shellOutput: runner(candidateQuery)).first(where: validate)
    }
}
