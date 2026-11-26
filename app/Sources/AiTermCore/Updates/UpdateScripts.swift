import Foundation

/// Every update script, oldest first, and the workspace format this build reads and writes.
public enum UpdateScripts {
    /// The format of a workspace saved without a `version`: 1.5.0, the last release before
    /// workspaces carried one. A workspace from before 1.0 is not brought forward.
    public static let baseline = ReleaseVersion(major: 1, minor: 5, patch: 0)

    public static let all: [UpdateScript] = [.update2_0_0]

    /// The format this build saves: the newest script's version. It is not the bundle's version —
    /// minor and patch releases never change the format, and a development build says 0.1.0.
    public static var current: ReleaseVersion { all.last?.version ?? baseline }
}
