import Foundation
import AiTermCore

/// A project's origin and the code host it is on: the client `finish_task` and the review tools talk to, and whether
/// AiTerm can connect to it, which a draft MR or a merge needs: the Operator's tools refuse those ends without one, and
/// New Broadcast's Task step dims them.
struct CodeHostCheck: Sendable {
    /// Git failing to read the origin for a reason other than there being none, in git's own words.
    struct OriginUnreadable: Error { let reason: String }

    let git: any GitRunning
    /// The client for an origin's host, with the connections Settings saved (`OperatorPorts.publisher`).
    let publisher: @Sendable (RemoteInfo) throws -> any MergeRequestPublishing

    /// What stood between a project and its code host's client.
    enum Failure: Error {
        /// Git failed to read the origin.
        case unreadable(any Error)
        case noOrigin
        /// What Settings saved connects to no host the origin is on (`TaskFinisher.unavailable` says it).
        case unavailable(any Error)
    }

    /// The client for the project's origin, with the connections Settings saved: git reads the origin off the main
    /// actor. Every caller that talks to the host, or asks whether it could, reads it here.
    func host(of project: Project) async throws(Failure) -> any MergeRequestPublishing {
        let git = self.git, path = project.path
        let origin: String?
        do { origin = try await BackgroundWork.run({ try git.ask(["remote", "get-url", "origin"], in: path, none: [2]) }) }
        catch { throw .unreadable(error) }
        guard let origin else { throw .noOrigin }
        do { return try publisher(ProviderDetector.detect(remoteUrl: origin, repoPath: path)) }
        catch { throw .unavailable(error) }
    }

    /// Only an origin whose host AiTerm can connect to supports a remote publication end. Git saying there is no origin
    /// (exit 2), or no repository to have one (a folder that is none, or is gone), is no origin; any other failure of
    /// git's (a timeout, a config it can't read) is thrown with git's own words, not read as no origin.
    func connects(_ project: Project) async throws(OriginUnreadable) -> Bool {
        do {
            _ = try await host(of: project)
            return true
        } catch .unreadable(let error) {
            if let error = error as? GitError, Self.isNoRepository(error) { return false }
            if !FileManager.default.fileExists(atPath: project.path) { return false }
            throw OriginUnreadable(reason: (error as? GitError)?.reason ?? error.localizedDescription)
        } catch {
            return false
        }
    }

    /// Git's answer that the folder is no repository, or is gone: in its own words, which `GitRunner` keeps English.
    private static func isNoRepository(_ error: GitError) -> Bool {
        !error.timedOut && error.code == 128 && (error.stderr.contains("not a git repository") || error.stderr.contains("cannot change to"))
    }
}

extension OperatorPorts {
    /// The code-host rule over these ports' git and connections.
    var codeHost: CodeHostCheck { CodeHostCheck(git: git, publisher: publisher) }
}

extension ToolRefusal {
    /// What kept a tool from its project's code host, said as Settings would fix it.
    @MainActor init(_ failure: CodeHostCheck.Failure) {
        switch failure {
        case .unreadable(let error): self.init(GitError.displayReason(of: error))
        case .noOrigin: self.init(PublishRefusal.noOrigin.localizedDescription)
        case .unavailable(let error): self.init(TaskFinisher.unavailable(error))
        }
    }
}
