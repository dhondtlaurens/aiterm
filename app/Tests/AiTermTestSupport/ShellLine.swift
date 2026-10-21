import Foundation

/// A command line run as a person's shell would run it once typed, without opening a terminal:
/// `shell -c script` in `folder`, with no rc files and `argument` as its `$1`.
public enum ShellLine {
    /// `printf` standing in for an agent's CLI: each argument it is handed, NUL-ended.
    public static let printing = ["/usr/bin/printf", "%s\\0"]

    /// What `printing` prints for `arguments`.
    public static func printed(_ arguments: [String]) -> Data { Data(arguments.map { $0 + "\0" }.joined().utf8) }

    /// What the line printed, and how its shell exited.
    public static func run(_ shell: String, _ script: String, argument: String? = nil, in folder: URL) throws -> (out: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = (shell.hasSuffix("zsh") ? ["-f"] : []) + ["-c", script] + (argument.map { ["_", $0] } ?? [])
        process.currentDirectoryURL = folder
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path, "LANG": "en_US.UTF-8"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }
}
