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
    var visible: [AgentCompletion] = []
    var index = 0
    /// Top-left of the popup, in the editor's own coordinates.
    var anchor = CGPoint.zero
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
/// Typing `/` (and `$` for Codex, which answers to both) at the start of a word opens the popup with
/// the slash commands and skills that agent actually has installed. ↑/↓ move, ↩ accepts, ⎋ closes.
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
            guard model.isOpen else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                model.index = (model.index + 1) % model.visible.count; return true
            case #selector(NSResponder.moveUp(_:)):
                model.index = (model.index - 1 + model.visible.count) % model.visible.count; return true
            case #selector(NSResponder.insertNewline(_:)):
                accept(model.visible[min(model.index, model.visible.count - 1)]); return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.close(); return true
            default:
                return false
            }
        }

        /// Replaces the typed token with the picked item as its agent runs it — `/bra` becomes
        /// `/brainstorming`, and for Codex `/imag` becomes the skill mention `$imagegen`.
        func accept(_ item: AgentCompletion) {
            guard let textView, let trigger = currentTrigger() else { return }
            let text = textView.string
            let start = text.index(text.startIndex, offsetBy: trigger.range.lowerBound)
            let end = text.index(text.startIndex, offsetBy: trigger.range.upperBound)
            let range = NSRange(start..<end, in: text)
            let replacement = SkillCatalog.invocation(of: item, for: parent.agent) + " "
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
            }
            parent.text = textView.string
            parent.completions.close()
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
            let matches = SkillCatalog.matches(model.all, query: trigger.query)
            guard !matches.isEmpty else { model.close(); return }
            if model.visible != matches { model.visible = matches; model.index = 0 }
            model.anchor = caretAnchor(in: textView, tokenStart: trigger.range.lowerBound)
            model.fieldWidth = textView.enclosingScrollView?.bounds.width ?? textView.bounds.width
        }

        /// Bottom-left of the line the caret is on, in the scroll view's visible coordinates, so the
        /// popup hangs under the token being typed rather than at a fixed spot.
        private func caretAnchor(in textView: NSTextView, tokenStart: Int) -> CGPoint {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return .zero }
            let text = textView.string
            let start = text.index(text.startIndex, offsetBy: min(tokenStart, text.count))
            let location = NSRange(start..<start, in: text).location
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            let scrolled = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
            // A hairline below the caret's line, so the popup never touches the text above it.
            return CGPoint(x: rect.minX, y: rect.maxY - scrolled + Space.hairline)
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
    /// before it has one, so asking at `makeNSView` would find no window to ask.
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, let window else { return }
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

/// The popup itself: a menu-shaped list of the agent's own commands and skills.
struct CompletionPopup: View {
    let completions: PromptCompletions
    let width: CGFloat
    /// The kind glyph's own size. Same size as `Typography.micro`, but that step is always
    /// semibold, and this plain SF Symbol glyph must draw at its regular weight, so it takes the
    /// number on its own rather than the token that carries it.
    private static let iconSize: CGFloat = 10
    /// The glyph's fixed slot, so "sparkles" and "terminal" — different intrinsic widths — line up
    /// the name text that follows them.
    private static let iconSlot: CGFloat = 12
    var body: some View {
        // The offset lives here, not at the call site: only this view reads the model, so an
        // anchor read anywhere else would be the one from when the sheet last rebuilt.
        if completions.visible.isEmpty { EmptyView() } else {
            list.frame(width: width)
                .offset(x: Self.leading(anchorX: completions.anchor.x, width: width, fieldWidth: completions.fieldWidth),
                        y: completions.anchor.y)
        }
    }

    /// The popup's x: under the token when it fits, otherwise pulled left until its right edge
    /// meets the field's, and never past the field's left edge.
    static func leading(anchorX: CGFloat, width: CGFloat, fieldWidth: CGFloat) -> CGFloat {
        max(0, min(anchorX, fieldWidth - width))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completions.visible.enumerated()), id: \.element.id) { index, item in
                let on = index == completions.index
                let surface: Surface = on ? .accent : .sheet
                Button { completions.accept?(item) } label: {
                    HStack(spacing: Space.base) {
                        Icon(.symbol(item.kind == .skill ? "sparkles" : "terminal"), size: Self.iconSize,
                             tint: surface.secondaryInk)
                            .frame(width: Self.iconSlot)
                        Text(item.name).font(Typography.monoCode)
                            .foregroundStyle(surface.ink).lineLimit(1)
                        if let detail = item.detail {
                            Text(detail).font(Typography.help)
                                .foregroundStyle(surface.secondaryInk).lineLimit(1)
                        }
                        Spacer(minLength: Space.snug)
                        Text(item.source.label).font(Typography.help)
                            .foregroundStyle(on ? surface.secondaryInk : Palette.faint)
                    }
                    .padding(.horizontal, Space.base).frame(height: Size.menuRow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .menuRowHighlight(on)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { completions.index = index } }
            }
        }
        .padding(Space.tight)
        .menuChrome()
    }
}


/// Discoverability hint for the prompt editor’s completion shortcuts. One key for every agent: a
/// Codex skill picked from `/` is written as its `$` mention.
struct CompletionHint: View {
    static let text = "Type / for commands and skills."
    var body: some View {
        HelpText(Self.text)
    }
}
