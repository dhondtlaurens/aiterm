import Foundation
import Synchronization
import AiTermCore
import Darwin

/// A guard subprocess exits here before NSApplication, migration, live state or controllers exist.
enum WorkerGuardEntry {
    static func runIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--worker-guard" else { return false }
        let words = Array(arguments.dropFirst())
        let input = ["hook", "push"].contains(words.first ?? "") ? FileHandle.standardInput.readDataToEndOfFile() : Data()
        let box = Mutex<WorkerGuardCLI.Output?>(nil), done = DispatchSemaphore(value: 0)
        Task.detached {
            let realGit = ProcessInfo.processInfo.environment["AITERM_REAL_GIT"] ?? "/usr/bin/git"
            let dependencies = WorkerGuardCLI.Dependencies(git: GitRunner(git: realGit), fence: WorkerGuard.liveFence)
            let result = await WorkerGuardCLI.run(words, input: input, dependencies: dependencies)
            box.withLock { $0 = result }; done.signal()
        }
        done.wait()
        let result = box.withLock { $0! }
        if !result.output.isEmpty { print(result.output) }
        if !result.error.isEmpty { try? FileHandle.standardError.write(contentsOf: Data((result.error + "\n").utf8)) }
        exit(result.status)
    }
}
