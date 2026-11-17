/// An actionable connection problem above the sidebar. The title names the problem, the
/// description says how to fix it, and help keeps the underlying reason available as a tooltip.
public struct ConnectionBanner: Equatable, Sendable {
    public let title: String
    public let description: String?
    public let help: String?
    public let opensIterm: Bool
    public let opensSettings: Bool

    public init(title: String, description: String? = nil, help: String? = nil,
                opensIterm: Bool = false, opensSettings: Bool = false) {
        self.title = title
        self.description = description
        self.help = help
        self.opensIterm = opensIterm
        self.opensSettings = opensSettings
    }
}
