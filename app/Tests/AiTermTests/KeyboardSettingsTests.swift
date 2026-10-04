import AppKit
import Testing
@testable import AiTerm

@MainActor
@Suite(.serialized) struct KeyboardSettingsTests {
    /// Widest reach first: each group works only where the one before it does.
    @Test func theGroupsRunFromTheWidestReachToTheNarrowest() {
        #expect(KeyBindings.all.map(\.title) == ["Switching apps", "Anywhere in AiTerm", "Sidebar", "Sheets", "Lists and the prompt"])
        #expect(KeyBindings.all.flatMap(\.bindings).allSatisfy { !$0.keys.isEmpty })
    }

    /// The list is written by hand, so this keeps it honest against the menu bar: every key the
    /// app, File and View menus answer to is listed under "Anywhere in AiTerm", under the item's own
    /// title and with its own modifiers, and nothing else is. (Edit's keys are the text system's
    /// own, the same in every app, and are not listed.)
    @Test func theMenuBarsKeysAreTheOnesListed() throws {
        let saved = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = saved }
        AiTermApp(controller: AppController(preferences: .scratch())).buildMenu()
        let menus = try #require(NSApplication.shared.mainMenu).items.compactMap(\.submenu).filter { $0.title != "Edit" }
        let items = menus.flatMap(\.items).filter { !$0.isHidden && !$0.keyEquivalent.isEmpty }
        let menuRows = items.map { KeyBinding(action: $0.title, keys: Self.keys(of: $0)) }

        let listed = try #require(KeyBindings.all.first { $0.title == "Anywhere in AiTerm" })
        #expect(Set(listed.bindings.map(Row.init)) == Set(menuRows.map(Row.init)))
    }

    /// The File menu and the HIG's app-menu items are there, in order, with the keys the spec gives
    /// them.
    @Test func theFileAndAppMenusCarryTheirKeys() throws {
        let saved = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = saved }
        AiTermApp(controller: AppController(preferences: .scratch())).buildMenu()
        let menus = try #require(NSApplication.shared.mainMenu).items.compactMap(\.submenu)
        #expect(menus.map(\.title).contains("File"))
        #expect(!menus.map(\.title).contains("Window"), "no Window menu, so no ⌘M or ⌘W")
        let all = menus.flatMap(\.items)
        func item(_ title: String) throws -> NSMenuItem { try #require(all.first { $0.title == title }, "\(title)") }
        #expect(Self.keys(of: try item("Add Project…")) == ["⌘", "P"])
        #expect(Self.keys(of: try item("Add Divider…")) == ["⌘", "D"])
        #expect(Self.keys(of: try item("New Task…")) == ["⌘", "N"])
        #expect(Self.keys(of: try item("New Review…")) == ["⌘", "R"])
        #expect(Self.keys(of: try item("New Terminal…")) == ["⌘", "T"])
        let fileMenu = try #require(menus.first { $0.title == "File" })
        #expect(fileMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Add Project…", "Add Divider…", "New Task…", "New Review…", "New Terminal…",
        ])
        #expect(Self.keys(of: try item("Hide AiTerm")) == ["⌘", "H"])
        #expect(Self.keys(of: try item("Hide Others")) == ["⌥", "⌘", "H"])
        #expect(try item("Show All").keyEquivalent.isEmpty)
        #expect(try item("Check for Updates…").keyEquivalent.isEmpty)
        // Separators split it into four groups: About and updates, Settings, the Hide items, Quit.
        let appMenu = try #require(menus.first)
        #expect(appMenu.items.map { $0.isSeparatorItem ? "—" : $0.title } == [
            "About AiTerm", "Check for Updates…", "—", "Settings…", "—",
            "Hide AiTerm", "Hide Others", "Show All", "—", "Quit AiTerm",
        ])
    }

    /// View › Backpack Mode, ⌘B, after the views, checked while the mode is on.
    @Test func theViewMenuCarriesBackpackMode() throws {
        let saved = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = saved }
        let app = AiTermApp(controller: AppController(preferences: .scratch()))
        app.buildMenu()
        let view = try #require(NSApplication.shared.mainMenu?.items.compactMap(\.submenu).first { $0.title == "View" })
        let titles = view.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == ["Zoom In", "Zoom Out", "Actual Size", "—", "Focus View", "List View", "—", "Backpack Mode", "—"])
        let item = try #require(view.items.first { $0.title == "Backpack Mode" })
        #expect(Self.keys(of: item) == ["⌘", "B"])
        #expect(app.validateMenuItem(item), "never disabled: a press that cannot turn it on answers with a toast")
        #expect(item.state == .off)
    }

    /// A row as the menu check compares it: its title and its keys.
    private struct Row: Hashable {
        let action: String, keys: [String]
        init(_ binding: KeyBinding) { action = binding.action; keys = binding.keys }
    }

    /// A menu item's keys as the list prints them: its modifiers in the menu's order, ⌃⌥⇧⌘ — an
    /// upper-case letter implies ⇧ — then the key, upper case, with a true minus. Read from the mask,
    /// so a ⌥⌘ item cannot pass for a plain ⌘ one.
    private static func keys(of item: NSMenuItem) -> [String] {
        let mask = item.keyEquivalentModifierMask, key = item.keyEquivalent
        let shifted = mask.contains(.shift) || key != key.lowercased()
        let modifiers: [(Bool, String)] = [(mask.contains(.control), "⌃"), (mask.contains(.option), "⌥"),
                                           (shifted, "⇧"), (mask.contains(.command), "⌘")]
        return modifiers.filter(\.0).map(\.1) + [key == "-" ? "−" : key.uppercased()]
    }

    /// VoiceOver reads a row's keys in words: its own names for ⎋ or ⇥ are the glyphs' Unicode names.
    @Test func theKeysAreReadOutInWords() {
        #expect(KeyBinding(action: "Remove", keys: ["⌘", "⌫"]).spokenKeys == "Command Delete")
        #expect(KeyBinding(action: "Close", keys: ["⎋"]).spokenKeys == "Escape")
        #expect(KeyBinding(action: "Zoom out", keys: ["⌘", "−"]).spokenKeys == "Command minus")
        #expect(KeyBinding(action: "Switch", keys: ["⌘", "⇥"]).spokenKeys == "Command Tab")
        #expect(KeyBinding(action: "Settings", keys: ["⌘", ","]).spokenKeys == "Command ,")
        #expect(KeyBinding(action: "Fold", keys: ["←", "→"]).spokenKeys == "Left Arrow Right Arrow")
        #expect(KeyBinding(action: "Tabs", keys: ["⌘", "1–4"]).spokenKeys == "Command 1 to 4")
    }
}
