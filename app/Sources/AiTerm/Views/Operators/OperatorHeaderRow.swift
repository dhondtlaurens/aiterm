import SwiftUI
import AiTermUI
import AiTermCore

/// `OPERATORS`, above `PROJECTS`, and the menu that makes a new operator: the one way to the first, so
/// it is drawn with no operator at all (spec §10.1).
struct OperatorsHeader: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack {
            SidebarHeading("Operators")
            Spacer()
            AddMenu(help: "New operator", enabled: controller.canChangeWorkspace) {
                OperatorMenuButtons(items: OperatorMenus.operatorsGroup) { _ in controller.presentNewOperator() }
            }
        }
        .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
    }
}

/// An operator: a project header's anatomy (spec §10.1) — the disclosure chevron, its mark where a
/// project's provider sits (`SymbolMark` `.paper` with `headphones` at `Size.chip`, centred in the
/// `Size.avatar` column), its name, folded its operations' counts, and a "+" for New Operation…. Its
/// menu: New Operation…, Edit Operator…, Duplicate, Move to Trash…. Not on the arrow path — it has no
/// window — and with no operation it has nothing to disclose, as an empty project.
struct OperatorHeaderRow: View {
    let section: OperatorSection
    let controller: AppController
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let persona = section.persona
        // An operator moved to the Trash keeps its header while its operations run, offering nothing
        // that needs its file.
        let enabled = controller.canChangeWorkspace && section.inLibrary
        HStack(spacing: scale(Space.base)) {
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: section.collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(section.isEmpty ? 0 : 1)
                SymbolMark(symbol: OperatorAvatar.symbol, size: scale(Size.chip), style: .paper)
                    .frame(width: scale(Size.avatar), height: scale(Size.avatar))
                HeaderTitle(text: persona.name)
                Spacer(minLength: scale(Space.tight))
                if section.collapsed {
                    StatusCountChips(counts: SidebarModel.operationStatusCounts(section.operations))
                }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { controller.toggleCollapsed(operator: persona.handle) },
                     including: section.isEmpty ? .subviews : .all)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Operator \(persona.name)")
            .accessibilityAddTraits(section.isEmpty ? [] : .isButton)
            AddMenu(help: "New operation", enabled: enabled) {
                OperatorMenuButtons(items: OperatorMenus.headerPlus) { controller.perform($0, on: persona) }
            }
        }
        .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: false))
        .contextMenu {
            OperatorMenuButtons(items: OperatorMenus.header, enabled: { _ in enabled }) { controller.perform($0, on: persona) }
        }
    }
}
