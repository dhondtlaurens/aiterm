import SwiftUI
import AiTermUI
import AppKit
import AiTermCore

/// What the completion popup is showing right now. The `NSTextView` drives it and the SwiftUI
/// overlay renders it, so the list, the highlighted row and the caret position stay in one place.
///
/// Observed per property, and a write of the value already there is no change: closing a closed
/// popup, which every caret move does, redraws nothing.
@MainActor
@Observable
final class PromptCompletions {
    /// Every command and skill the agent has; the popup draws only `visible`.
    @ObservationIgnored var all: [AgentCompletion] = []
    /// The project's files and folders, which `@` lists.
    @ObservationIgnored var files = FileIndex.empty
    var visible: [AgentCompletion] = []
    var index = 0
    /// Top-left of the popup, in the editor's own coordinates: under the caret's line, or above it
    /// when `opensAbove`.
    var anchor = CGPoint.zero
    /// Whether the popup hangs above the caret's line: there was no room for it below, inside what
    /// shows of the editor's surroundings (the scroll view it sits in, else its window), and more
    /// room above. Settings › Operator's Instructions, the last field of a scrolling sheet, is one.
    var opensAbove = false
    /// The editor's own width, so the popup can pull itself left instead of running past the
    /// field's right edge when the token starts near the end of a line.
    var fieldWidth: CGFloat = 0
    var isOpen: Bool { !visible.isEmpty }
    /// Set by the editor so the popup's rows can be clicked as well as typed through.
    @ObservationIgnored var accept: ((AgentCompletion) -> Void)?

    func close() { visible = []; index = 0 }
}

/// The first-prompt editor: a real `NSTextView`, which is what makes the completion popup possible
/// at all — SwiftUI's `TextEditor` exposes neither the caret's position nor the arrow keys.
///
/// Typing `/` at the start of a word opens the popup with the slash commands and skills that agent
/// actually has installed, and `@` with the project's files and folders. ↑/↓ move, ↩ accepts, ⎋
/// closes.
/// Files dropped or pasted from Finder — screenshots, PDFs, anything — go in as their paths.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    let agent: AgentKind
    /// Never read while updating the view: the text view never draws the popup, and reading it
    /// there would update the `NSTextView` on every caret move. `CompletionPopup` is its one reader.
    let completions: PromptCompletions
    /// Told when the text view takes the keyboard and when it gives it up, so the field around it
    /// can draw the focus ring.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Takes the keyboard as soon as the editor is in a window, so arriving on the prompt step
    /// puts the caret in the field without a click.
    var focusOnAppear = false

    /// Where the text sits inside the field's box: `Space.snug` in from the side, `Space.base` down
    /// from the top. `PromptStep` lays its placeholder on the same inset.
    static let textInset = CGSize(width: Space.snug, height: Space.base)
    /// The gap `NSTextContainer` leaves before a line's first glyph, past `textInset`. AppKit's own
    /// default, set explicitly so the placeholder can add the same amount rather than assume it.
    static let lineFragmentPadding: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, explicitly: the caret rectangle the popup is anchored to comes from
        // `NSLayoutManager`, and an NSTextView left to pick TextKit 2 has none.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CGFloat(0), height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = Self.lineFragmentPadding
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let textView = PromptTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.onFocusChange = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange($0) }
        textView.wantsFocus = focusOnAppear
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Typography.promptMono.nsFont
        textView.textColor = NSColor(Palette.text)
        textView.insertionPointColor = NSColor(Palette.accent)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.string = text
        Self.enable(textView, context.environment.isEnabled)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        completions.accept = { [weak coordinator = context.coordinator] item in coordinator?.accept(item) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
        }
        Self.enable(textView, context.environment.isEnabled)
    }

    /// `.disabled(…)` around the editor: no typing and no selecting, which also refuses it the keyboard.
    private static func enable(_ textView: NSTextView, _ enabled: Bool) {
        if textView.isEditable != enabled { textView.isEditable = enabled }
        if textView.isSelectable != enabled { textView.isSelectable = enabled }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var textView: NSTextView?
        init(_ parent: PromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) { refresh() }

        /// The keys the popup owns while it is open. Everything else, and every key when it is
        /// closed, goes to the text view as usual — ↩ still inserts a newline in a plain prompt.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let model = parent.completions
            switch DropdownKeys.handle(selector: selector, count: model.visible.count, index: model.index, open: model.isOpen) {
            case .moved(let index): model.index = index; return true
            case .accepted(let index): accept(model.visible[index]); return true
            case .closed: model.close(); return true
            case .unhandled: return false
            }
        }

        /// Replaces the typed token with the picked item as its agent runs it — `/bra` becomes
        /// `/brainstorming`, for Codex `/imag` becomes the skill mention `$imagegen`, and `@read`
        /// becomes `@README.md`. A folder is written without the space after it, and the popup
        /// stays open on what is inside it.
        func accept(_ item: AgentCompletion) {
            guard let textView, let trigger = currentTrigger() else { return }
            let text = textView.string
            let start = text.index(text.startIndex, offsetBy: trigger.range.lowerBound)
            let end = text.index(text.startIndex, offsetBy: trigger.range.upperBound)
            let range = NSRange(start..<end, in: text)
            let replacement = SkillCatalog.invocation(of: item, for: parent.agent) + (item.kind == .folder ? "" : " ")
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
            }
            parent.text = textView.string
            if item.kind == .folder { refresh() } else { parent.completions.close() }
        }

        private func currentTrigger() -> CompletionTrigger? {
            guard let textView else { return nil }
            let text = textView.string
            let utf16Caret = textView.selectedRange().location
            guard textView.selectedRange().length == 0,
                  let caretIndex = Range(NSRange(location: utf16Caret, length: 0), in: text)?.lowerBound else { return nil }
            let caret = text.distance(from: text.startIndex, to: caretIndex)
            return SkillCatalog.trigger(in: text, caret: caret)
        }

        func refresh() {
            let model = parent.completions
            guard let textView, let trigger = currentTrigger() else { model.close(); return }
            let matches = trigger.sigil == ProjectFiles.trigger ? model.files.matches(trigger.query)
                : SkillCatalog.matches(model.all, query: trigger.query)
            guard !matches.isEmpty else { model.close(); return }
            if model.visible != matches { model.visible = matches; model.index = 0 }
            let line = tokenLine(in: textView, tokenStart: trigger.range.lowerBound)
            let height = CompletionPopup.height(rows: matches.count)
            let above = CompletionPopup.opensAbove(line: textView.convert(line, to: nil), height: height, visible: visibleArea(of: textView))
            let scrolled = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
            // A hairline between the popup and the caret's line, so it never touches the text.
            let y = above ? line.minY - scrolled - Space.hairline - height : line.maxY - scrolled + Space.hairline
            if model.opensAbove != above { model.opensAbove = above }
            model.anchor = CGPoint(x: line.minX, y: y)
            model.fieldWidth = textView.enclosingScrollView?.bounds.width ?? textView.bounds.width
        }

        /// The line the token being typed starts on, in the text view's coordinates, so the popup
        /// hangs by the token rather than at a fixed spot.
        private func tokenLine(in textView: NSTextView, tokenStart: Int) -> CGRect {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return .zero }
            let text = textView.string
            let start = text.index(text.startIndex, offsetBy: min(tokenStart, text.count))
            let location = NSRange(start..<start, in: text).location
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            return rect
        }

        /// What shows around the editor, in window coordinates: the scroll view it sits in (a
        /// sheet's), else its window's content; nil outside a window.
        private func visibleArea(of textView: NSTextView) -> CGRect? {
            if let outer = textView.enclosingScrollView?.enclosingScrollView {
                return outer.contentView.convert(outer.contentView.bounds, to: nil)
            }
            guard let content = textView.window?.contentView else { return nil }
            return content.convert(content.bounds, to: nil)
        }

    }
}

/// A plain-text view that takes files as their paths, the way a drop into iTerm2 does, so the
/// agent gets something it can open. Rich text is off, so without this a dropped image would
/// either be refused or read in as its contents.
final class PromptTextView: NSTextView {
    /// What iTerm2 backslash-escapes in a dropped path, so the agent reads the same thing it would
    /// if the file were dropped into its own terminal.
    private static let special = Set(#"\'"()[]{}<>$&;|*?!#~`"#)

    /// Called with `true` when the view takes the keyboard and `false` when it gives it up.
    var onFocusChange: ((Bool) -> Void)?
    /// Whether to take the keyboard once, on joining a window. SwiftUI inserts the representable
    /// before it has one, so asking at `makeNSView` would find no window to ask. A disabled editor doesn't take it:
    /// `makeFirstResponder` doesn't ask whether a view accepts it.
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, isSelectable, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes.contains(.fileURL) ? super.acceptableDragTypes : super.acceptableDragTypes + [.fileURL]
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + super.readablePasteboardTypes.filter { $0 != .fileURL }
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        type == .fileURL ? .copy : super.dragOperation(for: dragInfo, type: type)
    }

    /// Both a drop and ⌘V land here, with the selection already at the drop point.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return super.readSelection(from: pboard, type: type) }
        let range = selectedRange()
        let before = range.location > 0 ? (string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)).first : nil
        insertText(Self.insertion(for: urls.map(\.path), after: before), replacementRange: range)
        return true
    }

    /// The paths, space-separated and escaped, with a space before them unless the caret already
    /// follows whitespace and one after so typing can carry on.
    static func insertion(for paths: [String], after previous: Character?) -> String {
        let escaped = paths.map { path in
            path.reduce(into: "") { out, c in
                if c.isWhitespace || special.contains(c) { out.append("\\") }
                out.append(c)
            }
        }
        let lead = previous.map { $0.isWhitespace ? "" : " " } ?? ""
        return lead + escaped.joined(separator: " ") + " "
    }
}

/// The popup itself: a `DropdownList` of the agent's own commands and skills, or of the project's
/// files and folders.
struct CompletionPopup: View {
    let completions: PromptCompletions
    let width: CGFloat
    /// The kind glyph's own size. Same size as `Typography.micro`, but that step is always
    /// semibold, and this plain SF Symbol glyph must draw at its regular weight, so it takes the
    /// number on its own rather than the token that carries it.
    private static let iconSize: CGFloat = 10
    /// The glyph's fixed slot, so "sparkles", "terminal", "doc" and "folder" — different intrinsic
    /// widths — line up the name text that follows them.
    private static let iconSlot: CGFloat = 12
    var body: some View {
        // The offset lives here, not at the call site: only this view reads the model, so an
        // anchor read anywhere else would be the one from when the sheet last rebuilt.
        // Never wider than the field it opens from, which a sheet's scroller can narrow.
        let width = completions.fieldWidth > 0 ? min(self.width, completions.fieldWidth) : self.width
        if completions.visible.isEmpty { EmptyView() } else {
            list.frame(width: width)
                .offset(x: Self.leading(anchorX: completions.anchor.x, width: width, fieldWidth: completions.fieldWidth),
                        y: completions.anchor.y)
        }
    }

    /// The popup's height for `rows` results: `DropdownList`'s rows inside its padding. The editor
    /// reads it to decide whether the popup fits below the caret's line.
    static func height(rows: Int) -> CGFloat { CGFloat(rows) * Size.menuRow + 2 * Space.tight }

    /// Above only when the popup does not fit below the caret's line and there is more room above
    /// it. `line` and `visible` are in window coordinates, whose y runs up; with no `visible` (no
    /// window yet) it hangs below.
    static func opensAbove(line: CGRect, height: CGFloat, visible: CGRect?) -> Bool {
        guard let visible else { return false }
        let below = line.minY - Space.hairline - visible.minY
        let above = visible.maxY - (line.maxY + Space.hairline)
        return below < height && above > below
    }

    /// The popup's x: under the token when it fits, otherwise pulled left until its right edge
    /// meets the field's, and never past the field's left edge.
    static func leading(anchorX: CGFloat, width: CGFloat, fieldWidth: CGFloat) -> CGFloat {
        max(0, min(anchorX, fieldWidth - width))
    }

    private var list: some View {
        DropdownList(items: completions.visible, index: Binding(get: { completions.index }, set: { completions.index = $0 }),
                     onPick: { completions.accept?($0) }) { Row(item: $0) }
    }

    /// One command, skill, file or folder, inked for the ground its row declares: white while
    /// highlighted, and a command's or skill's source, faint at rest, rises to the secondary ink
    /// there with the rest. A path names no source: every one is the project's.
    private struct Row: View {
        let item: AgentCompletion
        @Environment(\.surface) private var surface
        private var isPath: Bool { item.kind == .file || item.kind == .folder }

        var body: some View {
            HStack(spacing: Space.base) {
                Icon(.symbol(Self.symbol(for: item.kind)), size: CompletionPopup.iconSize,
                     tint: surface.secondaryInk)
                    .frame(width: CompletionPopup.iconSlot)
                // A long path keeps its file's name and loses the middle of its folders.
                Text(item.name).font(Typography.monoCode)
                    .foregroundStyle(surface.ink).lineLimit(1).truncationMode(isPath ? .middle : .tail)
                if let detail = item.detail {
                    Text(detail).font(Typography.help)
                        .foregroundStyle(surface.secondaryInk).lineLimit(1)
                }
                Spacer(minLength: Space.snug)
                if !isPath {
                    Text(item.source.label).font(Typography.help)
                        .foregroundStyle(surface.isOnAccent ? surface.secondaryInk : Palette.faint)
                }
            }
        }

        static func symbol(for kind: AgentCompletion.Kind) -> String {
            switch kind {
            case .skill: return "sparkles"
            case .command: return "terminal"
            case .file: return "doc"
            case .folder: return "folder"
            }
        }
    }
}


/// Discoverability hint for the prompt editor’s completion shortcuts. One key for every agent: a
/// Codex skill picked from `/` is written as its `$` mention.
struct CompletionHint: View {
    static let text = "Type / for commands and skills, @ for files and folders."
    var body: some View {
        HelpText(Self.text)
    }
}
