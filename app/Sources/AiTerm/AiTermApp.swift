import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

@main
@MainActor
final class AiTermApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        Appearance.apply()
        do { try AiTermPaths.migrateSupportDirectory() }
        catch {
            app.setActivationPolicy(.regular)
            NSAlert(error: error).runModal()
            return
        }
        let delegate = AiTermApp(); app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    let controller: AppController
    private(set) lazy var updates = UpdateController.live(prompter: controller.prompter)

    override convenience init() {
        self.init(controller: .live())
    }
    init(controller: AppController) {
        self.controller = controller
        super.init()
    }
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Offscreen render-and-exit, for comparing the views against the design canvas.
        if Snapshots.runIfRequested() { NSApp.terminate(nil); return }
        #endif
        DevBuildIcon.apply()
        updates.finishPreviousUpdate()
        guard prepareWorkspace() else { NSApp.terminate(nil); return }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = controller.state.sidebarFrame
        let scale = controller.preferences.interfaceSize.scale
        let minimum = scale(Size.sidebarMinWidth)
        var initialFrame = saved ?? CGRect(x: screen.minX + 12, y: screen.minY, width: scale(Size.sidebarWidth), height: screen.height)
        // Upgrade frames persisted by versions that allowed the sidebar to shrink below its
        // content. Keeping the origin fixed avoids making the window jump sideways on launch.
        initialFrame.size.width = max(initialFrame.width, minimum)
        window = NSWindow(contentRect: initialFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "AiTerm"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.minSize = NSSize(width: minimum, height: 400)
        window.contentView = NSHostingView(rootView: SidebarView(controller: controller))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let tiling = controller.tiling
        tiling.sidebarWindow = window
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak tiling] _ in MainActor.assumeIsolated { tiling?.sidebarMoved() } }
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak tiling] _ in MainActor.assumeIsolated { tiling?.sidebarMoved() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak tiling] _ in MainActor.assumeIsolated { tiling?.sidebarMoved() } }
        buildMenu()
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.workspaceLoaded else { return .terminateNow }
        controller.tiling.finishPendingMove()
        // Changes wait a moment to be saved together; whatever is still waiting is saved now.
        if controller.workspace.flush() { return .terminateNow }
        let answer = controller.prompter.ask(AlertPrompt(
            message: "Workspace changes haven’t been saved",
            detail: "Quit without saving to discard changes since the last save, or cancel to keep working.",
            buttons: ["Cancel Quit", "Quit Without Saving"], escape: 0))
        if answer.button == 1 { return .terminateNow }
        window?.makeKeyAndOrderFront(nil)
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func prepareWorkspace() -> Bool {
        while true {
            do { try controller.loadWorkspace(); return true }
            catch {
                let answer = controller.prompter.ask(AlertPrompt(
                    message: "AiTerm couldn’t open your workspace",
                    detail: error.localizedDescription
                        + "\n\nRestoring a backup may omit recent changes. The original file will be preserved.",
                    buttons: ["Retry", "Restore Backup", "Reveal in Finder", "Quit"],
                    unavailable: controller.workspace.file.hasValidBackup ? [] : ["Restore Backup"], escape: 3))
                switch answer.button {
                case 0: continue
                case 1:
                    do { try controller.restoreWorkspace(); return true }
                    catch { controller.prompter.ask(AlertPrompt(message: error.localizedDescription)) }
                case 2:
                    NSWorkspace.shared.activateFileViewerSelecting([controller.workspace.file.url.deletingLastPathComponent()])
                default: return false
                }
            }
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        // The HIG's order: About and Check for Updates…, Settings…, the Hide items, Quit — each
        // group apart. Hide, Hide Others and Show All are NSApplication's own actions.
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About AiTerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AiTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit AiTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        // What the "+" menus create, in their order: the header's, then a project's. The three New
        // items act on the target project — the selected header's, or the selected row's. Each key
        // is plain ⌘ and the item's initial. No Window menu: the sidebar is the app's one window,
        // and ⌘W on a task would close it without a word (docs/keyboard.md).
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Project…", action: #selector(addProject), keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Add Divider…", action: #selector(addDivider), keyEquivalent: "d")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Task…", action: #selector(newTask), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Review…", action: #selector(newReview), keyEquivalent: "r")
        fileMenu.addItem(withTitle: "New Terminal…", action: #selector(newTerminal), keyEquivalent: "t")
        fileItem.submenu = fileMenu
        // The standard Edit menu: without it the app has no Cut/Copy/Paste/Undo key equivalents,
        // so the text fields in the New Task and Settings sheets could not be edited normally.
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        // Safari's names and keys. Only the sidebar zooms: sheets keep Apple's sizes.
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        // ⌘= is the unshifted key ⌘+ sits on; Safari answers to both.
        let zoomInAlias = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(zoomInAlias)
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        // ⌘F, though macOS reads it as Find: the sidebar has nothing to find, and a sheet's search
        // fields are covered by the item turning off while one is up.
        viewMenu.addItem(withTitle: "Focus View", action: #selector(showFocusView), keyEquivalent: "f")
        viewMenu.addItem(withTitle: "List View", action: #selector(showListView), keyEquivalent: "l")
        // AppKit appends Enter Full Screen to a menu titled View; this keeps it apart from the views.
        viewMenu.addItem(.separator())
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
    }

    @objc func openSettings() { controller.presentSettings() }
    @objc func newTask() { if let project = controller.targetProject { controller.presentNewTask(project: project) } }
    @objc func newReview() { if let project = controller.targetProject { controller.presentNewReview(project: project) } }
    @objc func newTerminal() { if let project = controller.targetProject { controller.presentNewTerminal(project: project) } }
    @objc func addProject() { controller.addProject() }
    @objc func addDivider() { controller.presentNewDivider() }
    @objc func zoomIn() { changeInterfaceSize(to: controller.preferences.interfaceSize.bigger) }
    @objc func zoomOut() { changeInterfaceSize(to: controller.preferences.interfaceSize.smaller) }
    @objc func actualSize() { changeInterfaceSize(to: .standard) }
    @objc func showFocusView() { controller.showFocusView() }
    @objc func showListView() { controller.showListView() }

    private func changeInterfaceSize(to size: InterfaceSize?) {
        if let size { controller.tiling.setInterfaceSize(size) }
    }
    @objc func checkForUpdates() { Task { await updates.checkForUpdates() } }
}

extension AiTermApp: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // A sheet does not scale, and Settings puts its opening size back on Cancel: zoom only the
        // bare sidebar.
        let zoomable = controller.sheet == nil
        switch item.action {
        case #selector(checkForUpdates): return !updates.isBusy
        case #selector(openSettings): return controller.canPresentSettings
        case #selector(newTask), #selector(newReview): return controller.canCreateTask
        case #selector(newTerminal): return controller.canCreateTerminal
        case #selector(addProject), #selector(addDivider): return controller.canUseFileMenu
        case #selector(zoomIn): return zoomable && controller.preferences.interfaceSize.bigger != nil
        case #selector(zoomOut): return zoomable && controller.preferences.interfaceSize.smaller != nil
        case #selector(actualSize): return zoomable && controller.preferences.interfaceSize != .standard
        case #selector(showFocusView): return controller.canShowFocusView
        case #selector(showListView): return controller.canShowListView
        default: return true
        }
    }
}
