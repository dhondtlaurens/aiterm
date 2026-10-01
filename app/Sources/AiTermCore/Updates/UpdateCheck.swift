import Foundation

public enum UpdateCheckResult: Equatable, Sendable {
    case current(ReleaseVersion), available(Release), failed(UpdateError)
    /// The check was cancelled: nothing to tell anyone.
    case cancelled
}

public enum UpdateCheck {
    /// A release is offered only when it is newer: a build ahead of the newest release — a dev
    /// build — is told it is current rather than offered a downgrade.
    public static func run(source: any ReleaseSource, current: ReleaseVersion) async -> UpdateCheckResult {
        do {
            let release = try await source.latest()
            return release.version > current ? .available(release) : .current(current)
        } catch let error as UpdateError {
            return .failed(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.other(error.localizedDescription))
        }
    }
}
