# 3c. Operator row identity and row flags

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 3b. Audit findings: WD F8, SB F6, OC F11 (the
Operator row's id); WD F9 (row flags).

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

WD F9 counted three "set plus a per-row mirror" pairs. After 3a only one is left: `CheckoutMonitor`'s
`missingCheckouts` with `missingRows` (3a deleted `WindowReconciler`'s `failed` with `failedRows`).
`RowFocus`'s `selection` with `selectedRows` is one optional value with a per-row mirror, not a set, so a
`RowFlags` would not make it one copy; it stays. This brief adds `RowFlags` for the one real pair.

## Why

The Operator row is one fixed row, but the code still carries the shape of the broadcast era, when each
broadcast had its own Operator row: `RowSelection.operation(UUID)` and Core `RowID.operation(UUID)` carry
a payload that is always `OperatorSession.rowID`, and `OperatorRow.id(of:)` XORs three bytes of that
constant so "the list id is never its broadcast's". So one row has two fixed UUIDs, `RowSelection.id` and
`RowID.id` disagree about which one it is, and every site spells `OperatorRow.id(of: OperatorSession.rowID)`
or matches `.operation(let id) where id == OperatorSession.rowID` with a dead fallback case. The end
state: the selection case and the row id are `.operatorChat` without a payload, the row's id is
`OperatorSession.rowID` everywhere, and `OperatorRow` is gone. Separately, `CheckoutMonitor` keeps the
missing checkouts twice (a set and a per-row mirror written in a `didSet`); a small `RowFlags` keeps them
once. No behaviour changes in this step.

## Today

All in `app/Sources/`, after 3b.

- `AiTermCore/Sidebar/OperatorRow.swift`: `OperatorRow.id(of:)`, the XOR. Every call passes
  `OperatorSession.rowID` (`AiTermCore/Operators/Signals/OperatorSession.swift`, a fixed UUID). Callers:
  `grep -rn "OperatorRow" app/Sources app/Tests` finds `SessionContexts.swift` (two: `prune(keeping:)` and
  `row(for:in:)`), `AiTerm/SignalSidebar.swift` (`SignalOperatorRowValue.id`), `AiTerm/PerRow.swift`
  (`dropGone`), `AiTerm/RowFocus.swift` (`RowSelection.id`, `row(id:)`, comments),
  `AiTerm/Views/Operators/SignalRows.swift` (`SignalOperatorRow.row`), a comment in
  `AiTerm/Views/SidebarView.swift` (`operatorRows`), and tests `SignalSidebarTests`,
  `SidebarRowRedrawTests`, `SessionContextsTests`.
- `RowSelection` in `AiTerm/RowFocus.swift`: `case project, signal, task, terminal, operation(UUID)`;
  `id` returns `OperatorRow.id(of: run)` for `.operation`; `init(_ row: RowID)` maps `.operation`.
- `RowID` in `AiTermCore/Sidebar/SidebarModel.swift` (about line 247): `case task, terminal,
  operation(UUID)`; its `id` returns the payload itself, so `RowID.operation(rowID).id` is not
  `RowSelection.operation(rowID).id`. Its doc says "by its broadcast's id".
- Sites that build or match the case (`grep -rn "\.operation(\|case \.operation" app/Sources app/Tests | grep -v "work\.\|TaskOperation\|HarnessDiagnostics"`):
  `AppController.swift` (`targetProject`, `activateSelection`, `choose`, `notifications.onOpen`),
  `AppController+Operators.swift` (`reveal`), `SidebarProjection.swift` (`operatorNeedingAttention`,
  `operatorPath`, `usageRow(for:)` with its `guard id == OperatorSession.rowID`), `RowFocus.swift`
  (`row(id:)`, `windowActivated`, `window(for:)` with `case .operation(let id) where id == OperatorSession.rowID`
  and a dead `case .operation: nil`), `RowWindows.swift` (the `RowSelection` to `WindowRow` mapping 3b
  added), `Views/Operators/SignalRows.swift` (the row's `activate`), and `SignalSidebarTests`.
  `HarnessDiagnostics`'s `.operation` is another enum; leave it.
- Neither id is saved: selection and list tags are runtime. `grep -rn "6AF39C02" app/Tests` finds no
  fixture holding it.
- `AiTerm/CheckoutMonitor.swift`: `missingCheckouts: Set<UUID>` (`@ObservationIgnored`) with a `didSet`
  that writes each changed id into `missingRows: PerRow<Bool>`; `isMissing(_:)` reads `missingRows`;
  `forget(task:)` removes one id; the scan's apply assigns the whole set (about line 226). Readers of the
  set: `CheckoutMonitor` itself (removal check about line 239) and tests (`CheckoutMonitorTests`,
  `CheckoutCleanupTests`, `AppControllerTests`). `SidebarRowRedrawTests` (about line 152) pins that one
  checkout going redraws only its row.
- `AiTerm/PerRow.swift`: `PerRow<Value>` with cells per row; its doc says the owner keeps its own
  collection and mirrors each change.

## Change

1. **One case, one id.** In `RowSelection`, replace `operation(UUID)` with `operatorChat`; its `id` is
   `OperatorSession.rowID`. In Core `RowID`, replace `operation(UUID)` with `operatorChat`, `id` also
   `OperatorSession.rowID`; rewrite its doc ("a task, a terminal, or the Operator's row"). `RowSelection.init(_ row: RowID)`
   maps `.operatorChat` to `.operatorChat`.
2. Rewrite every site from the grep above: `.operation(OperatorSession.rowID)` becomes `.operatorChat`;
   `case .operation(let id) where id == OperatorSession.rowID` becomes `case .operatorChat`; delete the
   dead `case .operation: nil` in `RowFocus.window(for:)`; delete the `guard id == OperatorSession.rowID`
   in `SidebarProjection.usageRow(for:)` (keep the `operatorSession` guard); `RowWindows`' mapping sends
   `.operatorChat` to `WindowRow.operatorChat`.
3. **Delete `OperatorRow.swift`.** Every `OperatorRow.id(of: OperatorSession.rowID)` becomes
   `OperatorSession.rowID`: `SessionContexts.prune(keeping:)` and `row(for:in:)`,
   `SignalOperatorRowValue.id`, `PerRow.dropGone`, `RowFocus.row(id:)`, `SignalOperatorRow.row`. Rewrite
   the comments that explain the derived id (`RowFocus.swift` top of file and `row(id:)`, `SidebarView.operatorRows`)
   and any that still say "broadcast" or "operation" for this row.
4. **`RowFlags`.** In `AiTerm/PerRow.swift`, add a small `@MainActor final class RowFlags`: a set of row
   ids that each row can observe on its own. It holds one `PerRow<Bool>` for the cells and the member set,
   and offers `contains(_ id:)` (observed per row, as `PerRow`'s subscript is), `members: Set<UUID>` (read
   whole, not observed), `set(_ ids: Set<UUID>)` (writes only the cells whose value changes), `insert(_:)`
   and `remove(_:)`. It is the one copy: nothing else stores the set.
5. **`CheckoutMonitor`** replaces `missingCheckouts` (with its `didSet`) and `missingRows` by one
   `missing: RowFlags`. `isMissing(_:)` reads `missing.contains`; `forget(task:)` calls `missing.remove`;
   the scan apply calls `missing.set(scan.missingCheckouts)`; the removal check reads `missing.members`.
   Keep a read-only `missingCheckouts` that returns `missing.members`, so callers and tests read the same
   name. Update `PerRow`'s doc sentence about owners mirroring their collection: `RowFlags` is that for a
   set.

## Keep

- `OperatorSession.rowID`'s value: it is the list tag, the context-fill key and the `PerRow` key from now
  on. Changing the constant is not needed and not wanted.
- `HarnessDiagnostics`' own `.operation` case.
- `RowFocus.selection` with `selectedRows`: one value and its per-row mirror, observed row by row so an
  arrow key redraws two rows. Not a set.
- `PerRow` itself and its drop rule for gone rows.
- `RowFocus.row(id:)` returning the Operator row unconditionally: 8e makes it honour whether the row is
  shown.

## Decisions already taken

- The Operator row's list id changes from the XOR value to `OperatorSession.rowID`. Nothing saved or drawn
  holds it, so pixels and the saved workspace are unchanged; the audit's advice to keep the XOR value no
  longer applies once nothing derives it.
- No other row uses `OperatorSession.rowID` as its id, so the list cannot hold two rows with one tag.
- `RowFlags` is not generic over a value type and gets no other user in this step.

## Tests

Delete: none.

Adjust (names only, same assertions): `SignalSidebarTests` (every `.operation(OperatorSession.rowID)` and
`OperatorRow.id(of:)`), `SidebarRowRedrawTests` (about line 128), `SessionContextsTests` (about line 73),
and any test the grep in step 2 lists after the rename.

Add `RowFlagsTests` (new file `app/Tests/AiTermTests/RowFlagsTests.swift`): `set` makes `members` exactly
the ids given; `contains` reads true only for members; `insert` and `remove` change one id; a `set` that
changes one id invalidates an observation of that id's `contains` and not of another id's (use
`withObservationTracking`, as `SidebarRowRedrawTests` does). `SidebarRowRedrawTests`' missing-checkout
redraw case is the survivor for the monitor's per-row redraw and must stay green.

## Proof

While iterating: `scripts/test.sh swift -- --filter "RowFlagsTests|SignalSidebarTests|SidebarRowRedrawTests|SessionContextsTests|CheckoutMonitorTests|CheckoutCleanupControllerTests|SidebarProjectionTests|ItermFocusControllerTests|RowWindowsControllerTests"`.
Then plain `scripts/test.sh` in the background.

Snapshots: `scripts/snapshots.sh build/refactor-3c`; every PNG equal to `build/refactor-before`.

## Done when

- `grep -rn "OperatorRow\b\|OperatorRow\.\|\.operation(" app/Sources app/Tests | grep -v "HarnessDiagnostics\|work\.\|TaskOperation\|onTask\|onTerminal\|onProject"`
  returns nothing, and `app/Sources/AiTermCore/Sidebar/OperatorRow.swift` is gone.
- `grep -rn "missingRows" app/Sources` returns nothing.
- Plain `scripts/test.sh` green; snapshots equal.

## Not in this step

- Deselecting a vanished Operator row, and a fold handing the selection to its heading: 8e.
- The iTerm2 banner: 3d. The window docs: 3e.
