import Foundation
import AiTermCore

/// Whether a project's origin is on a code host AiTerm can connect to, which a draft MR or a merge needs: the Operator's
/// tools refuse those ends without one, and New Broadcast's Task step dims them.
struct CodeHostCheck: Sendable {
    /// Git failing to read the origin for a reason other than there being none, in git's own words.
    struct OriginUnreadable: Error { let reason: String }

    let git: any GitRunning
    /// The client for an origin's host, with the connections Settings saved (`OperatorPorts.publisher`).
    let publisher: @Sendable (RemoteInfo) throws -> any MergeRequestPublishing

    /// Only an origin whose host AiTerm can connect to supports a remote publication end. Git saying there is no origin
    /// (exit 2), or no repository to have one (a folder that is none, or is gone), is no origin; any other failure of
    /// git's (a timeout, a config it can't read) is thrown with git's own words, not read as no origin.
    func connects(_ project: Project) async throws(OriginUnreadable) -> Bool {
        let git = self.git, path = project.path
        let origin: String?
        do { origin = try await BackgroundWork.run({ try git.ask(["remote", "get-url", "origin"], in: path, none: [2]) }) }
        catch let error as GitError where Self.isNoRepository(error) { return false }
        catch _ where !FileManager.default.fileExists(atPath: path) { return false }
        catch { throw OriginUnreadable(reason: (error as? GitError)?.reason ?? error.localizedDescription) }
        guard let origin else { return false }
        let remote = ProviderDetector.detect(remoteUrl: origin, repoPath: path)
        do { _ = try publisher(remote); return true } catch { return false }
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
