import AppKit
import AiTermCore

/// The two things a row can hand a folder to. VS Code is looked up once by bundle id, so the
/// badge and menu items can simply be absent when it is not installed.
enum ExternalApps {
    static let vscodeBundleId = "com.microsoft.VSCode"
    static let vscode: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscodeBundleId)

    static func openInVSCode(path: String) {
        guard let app = vscode else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.ui.failed("Opening \(path) in VS Code", error) }
        }
    }

    /// The folder itself, as a Finder window — what "Open in Finder" says, beside "Open in VS Code".
    static func openInFinder(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func open(link: String?) {
        guard let link, let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        NSWorkspace.shared.open(url)
    }
}
