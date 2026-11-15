import Foundation
import AiTermCore
import Darwin

/// Test-only host seam for real hook/shim processes. The shipped app never reads this variable
/// and is built by product, so this executable and its fixed host facts are not in the bundle.
@main struct Probe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--worker-guard" else { exit(2) }
        let words = Array(args.dropFirst())
        let input = ["hook", "push"].contains(words.first ?? "") ? FileHandle.standardInput.readDataToEndOfFile() : Data()
        let dependencies = WorkerGuardCLI.Dependencies(git: GitRunner(), fence: { _ in
            try await BackgroundWork.run {
                guard let path = ProcessInfo.processInfo.environment["AITERM_GUARD_PROBE_FACTS"] else {
                    throw WorkerGuard.GuardFailure("The test host did not provide protection facts.")
                }
                let facts = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                guard let branch = facts["defaultBranch"]?.stringValue, let protected = facts["protected"]?.boolValue else {
                    throw WorkerGuard.GuardFailure("Unreadable test host facts.")
                }
                return WorkerGuard.Fence(defaultBranch: branch, protection: protected ? .protected("test host") : .unprotected)
            }
        })
        let result = await WorkerGuardCLI.run(words, input: input, dependencies: dependencies)
        if !result.output.isEmpty { print(result.output) }
        if !result.error.isEmpty { try? FileHandle.standardError.write(contentsOf: Data((result.error + "\n").utf8)) }
        exit(result.status)
    }
}
