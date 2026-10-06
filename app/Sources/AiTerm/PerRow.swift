import Foundation
import Observation
import AiTermCore

/// A value for each sidebar row, which each row observes for itself alone. Observation tracks a
/// property, not a key in it: a row that read the selection, `removals[id]` or
/// `missingCheckouts.contains(id)` was redrawn by every write to the whole, so one arrow key re-ran
/// every row's body, and one removal every task row's. Here each row's value is a cell of its own,
/// and a write reaches only the cell whose value it changes — for an arrow key, the row it leaves
/// and the row it reaches.
///
/// The owner keeps its own collection as it was, for everything that reads it whole, and mirrors
/// each change into this one, which rows read instead.
///
/// A row's cell is made the first time it is read or given a value other than the default. It goes
/// once its row has left the workspace and holds the default again, at the workspace's next change;
/// the owner clears what it held for a gone row, so a cell outlives its row by a change at most.
@MainActor
final class PerRow<Value: Equatable> {
    private let defaultValue: Value
    private var cells: [UUID: RowCell<Value>] = [:]

    init(default value: Value, workspace: WorkspaceStore) {
        defaultValue = value
        // Its own hook rather than one of the controller's ordered ones: it drops only cells no row
        // reads, so where it runs among them changes nothing.
        workspace.onChange { [weak self, weak workspace] in
            if let self, let workspace { dropGone(from: workspace.state) }
        }
    }

    /// The row's value. Read in a view's body, it is that row's alone to observe.
    subscript(id: UUID) -> Value {
        get { cell(id).value }
        set {
            if let cell = cells[id] {
                if cell.value != newValue { cell.value = newValue }
            } else if newValue != defaultValue {
                cells[id] = RowCell(newValue)
            }
        }
    }

    private func cell(_ id: UUID) -> RowCell<Value> {
        if let cell = cells[id] { return cell }
        let cell = RowCell(defaultValue)
        cells[id] = cell
        return cell
    }

    private func dropGone(from state: AppState) {
        guard !cells.isEmpty else { return }
        let rows = Set(state.items.map(\.id) + state.tasks.map(\.id) + state.terminals.map(\.id))
        for (id, cell) in cells where !rows.contains(id) && cell.value == defaultValue {
            cells[id] = nil
        }
    }
}

/// One row's value, observed on its own.
@Observable
private final class RowCell<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
