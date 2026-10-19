import SwiftUI
import AiTermUI
import AiTermCore

/// `OPERATORS`, above `PROJECTS`, and the menu that starts a broadcast: the one way to the first, so
/// it is drawn with no broadcast at all.
struct OperatorsHeader: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack {
            SidebarHeading("Operators")
            Spacer()
            AddMenu(help: "New operation", enabled: controller.canChangeWorkspace) {
                OperatorMenuButtons(items: OperatorMenus.operatorsGroup) { _ in controller.presentNewOperation() }
            }
        }
        .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
    }
}

/// The Operator: a project header's anatomy, the disclosure chevron, its mark where a project's
/// provider sits (`SymbolMark` `.paper` with `headphones` at `Size.chip`, centred in the `Size.avatar`
/// column), its name, folded its broadcasts' counts, and a "+" for New Operation…, which is also its
/// menu. Not on the arrow path, as it has no window. The plan's Task 14 replaces it.
struct OperatorHeaderRow: View {
    let section: OperatorSection
    let controller: AppController
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let enabled = controller.canChangeWorkspace
        HStack(spacing: scale(Space.base)) {
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: section.collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(section.isEmpty ? 0 : 1)
                SymbolMark(symbol: OperatorAvatar.symbol, size: scale(Size.chip), style: .paper)
                    .frame(width: scale(Size.avatar), height: scale(Size.avatar))
                HeaderTitle(text: section.name)
                Spacer(minLength: scale(Space.tight))
                if section.collapsed {
                    StatusCountChips(counts: SidebarModel.operationStatusCounts(section.operations))
                }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { controller.toggleCollapsed(operator: section.id) },
                     including: section.isEmpty ? .subviews : .all)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(section.name)
            .accessibilityAddTraits(section.isEmpty ? [] : .isButton)
            AddMenu(help: "New operation", enabled: enabled) {
                OperatorMenuButtons(items: OperatorMenus.headerPlus) { _ in controller.presentNewOperation() }
            }
        }
        .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: false))
        .contextMenu {
            OperatorMenuButtons(items: OperatorMenus.header, enabled: { _ in enabled }) { _ in controller.presentNewOperation() }
        }
    }
}
