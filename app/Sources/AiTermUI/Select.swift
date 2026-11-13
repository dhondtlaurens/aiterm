import SwiftUI
import AppKit

/// A real `NSPopUpButton`. Its menu is a window of its own, so it opens *over* whatever is below it
/// instead of pushing the sheet around, and it fills the column it is given — which neither
/// SwiftUI's menu-style `Picker` nor `Menu` will do: both hug their widest title and centre
/// themselves in the space left over.
///
/// The button is borderless and sits in the same `fieldBox` as an `Input`, so a select and a field
/// side by side are one shape. AppKit still owns the menu, the keyboard and the click; the house
/// draws the chrome, the picked title and the chevrons. The title is the house's because a
/// borderless pop-up sets its own 5 pt in, short of an `Input`'s `Space.inset`, and takes no other
/// inset from its cell. So a disabled `Select` does not dim on its own: whoever disables it fades it
/// with `Opacity.disabled`, as the README asks of every disabled part.
public struct Select<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    var label: (Value) -> String
    var detail: (Value) -> String? = { _ in nil }
    var monospaced = false
    var isSelectable: (Value) -> Bool = { _ in true }

    public init(values: [Value], selection: Binding<Value>, label: @escaping (Value) -> String,
                detail: @escaping (Value) -> String? = { _ in nil }, monospaced: Bool = false,
                isSelectable: @escaping (Value) -> Bool = { _ in true }) {
        self.values = values
        self._selection = selection
        self.label = label
        self.detail = detail
        self.monospaced = monospaced
        self.isSelectable = isSelectable
    }

    public var body: some View {
        NativePopUp(titles: values.map(label), tooltips: values.map(detail), selectable: values.map(isSelectable),
                    selectedIndex: values.firstIndex(of: selection) ?? 0, monospaced: monospaced) { index in
            if values.indices.contains(index), isSelectable(values[index]) { selection = values[index] }
        }
        // SwiftUI pushes this environment value onto the button after `makeNSView`, so the `.large`
        // set there is not enough on its own: without it the button came back `.regular` and drew
        // a 24 pt bezel centred in the 28 pt slot, shorter than the `Input` beside it.
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .frame(height: Size.control)
        .overlay {
            // Drawn over the button, which keeps the click: the whole field opens the menu.
            HStack(spacing: 0) {
                Text(values.contains(selection) ? label(selection) : (values.first.map(label) ?? ""))
                    .font(monospaced ? Typography.monoCode : Typography.body).foregroundStyle(Palette.text)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(Typography.micro).foregroundStyle(Palette.muted)
                    .frame(width: Size.menuRow)
            }
            .padding(.leading, Space.inset)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .fieldBox()
    }
}

struct NativePopUp: NSViewRepresentable {
    let titles: [String]
    let tooltips: [String?]
    let selectable: [Bool]
    let selectedIndex: Int
    let monospaced: Bool
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        // No bezel, no arrows and no title of its own: `Select` draws those. The button shows an
        // empty item instead of the picked one, which stays picked in the menu.
        button.isBordered = false
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.arrowPosition = .noArrow
            cell.usesItemFromMenu = false
            cell.menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.menu?.autoenablesItems = false
        // `.large` *is* 28 pt, which is the height `sizeThatFits` hands back. At `.regular` AppKit
        // drew a ~21 pt bezel stretched into a 28 pt slot.
        button.controlSize = .large
        // Without these the button refuses to shrink below its widest title, and a long model name
        // would push the whole row wider than the sheet.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let font = (monospaced ? Typography.monoCode : Typography.body).nsFont
        if button.font != font { button.font = font }
        let tips = tooltips.map { $0?.isEmpty == false ? $0 : nil }
        if button.itemArray.map(\.title) != titles {
            // Built item by item, not with `addItem(withTitle:)`: that drops a title already in the
            // menu, and two models can share a label.
            button.removeAllItems()
            for (title, tip) in zip(titles, tips) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.toolTip = tip
                button.menu?.addItem(item)
            }
        } else {
            for (item, tip) in zip(button.itemArray, tips) where item.toolTip != tip { item.toolTip = tip }
        }
        for (item, enabled) in zip(button.itemArray, selectable) where item.isEnabled != enabled { item.isEnabled = enabled }
        if titles.indices.contains(selectedIndex), button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
        // SwiftUI pushes this onto a hosted control today; setting it keeps `.disabled(…)` around a
        // `Select` from depending on that.
        if button.isEnabled != context.environment.isEnabled { button.isEnabled = context.environment.isEnabled }
    }

    /// Take the width offered rather than the intrinsic one: this is what makes the popup fill its
    /// column instead of hugging its title. With none offered (`.fixedSize()`), the width its widest
    /// title needs inside the house chrome: the button's own is that of the empty item it shows.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? Self.naturalWidth(titles: titles, monospaced: monospaced), height: Size.control)
    }

    /// The leading inset, the widest title and the chevrons' slot.
    static func naturalWidth(titles: [String], monospaced: Bool) -> CGFloat {
        let font = (monospaced ? Typography.monoCode : Typography.body).nsFont
        let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return Space.inset + ceil(widest) + Size.menuRow
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }
        @objc func changed(_ sender: NSPopUpButton) {
            guard sender.isEnabled, sender.selectedItem?.isEnabled == true else { return }
            onSelect(sender.indexOfSelectedItem)
        }
    }
}
