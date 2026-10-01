/// Whether the running bundle is a release or a local build. `scripts/make-app.sh` stamps
/// `AiTermDevBuild` into every bundle it makes; `scripts/release.sh` builds with `AITERM_RELEASE=1`,
/// which leaves it out. A dev build draws DEV on its Dock icon and does not update itself.
public enum BuildChannel: Equatable, Sendable {
    case release, dev

    public static let infoKey = "AiTermDevBuild"

    /// `nil` (`swift run`, which has no Info.plist) reads as release: it has neither an icon to
    /// badge nor a feed to update from, so there is nothing for `.dev` to change.
    public init(infoDictionary: [String: Any]?) {
        self = infoDictionary?[Self.infoKey] as? Bool == true ? .dev : .release
    }
}
