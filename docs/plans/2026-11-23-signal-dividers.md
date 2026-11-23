# Dividers between signals in the Operator section

## Goal

The Projects section has named dividers (Add Divider… in its "+" menu, then Rename…, Move Up/Down and Remove
Divider in the row's menu). The Operator section gets the same dividers between its signal headings, to group
signals under a label. A divider is a label only: it holds nothing, and it does not change signal priority, which
stays the order of `AppState.signals` (`MatchDecision`).

## Approach

Decided while planning: dividers go **between signals** (not a fixed rule between the two sections), and they
**don't affect priority**.

- **Storage.** `AppState.signals` stays exactly as it is, still the priority and still the only list the Operator
  and `MatchDecision` read. A new `AppState.signalDividers: [SignalDivider]` (`id`, `name`, `position` = how many
  live signals are drawn above it) is saved as its own `signalDividers` key and left out while empty, so existing
  workspaces are written byte-for-byte as before. An older build keeps the key through `PreservedFields`.
  On decode a position past `signals.count` is clamped to the end and a negative one to 0.
- **One drawn order.** `AppState` composes signals and dividers into a single drawn list (dividers with equal
  positions in array order) and splits an edited list back into the two arrays: signals in their new order, each
  divider's position recounted. Every change goes through that pair, so moves reuse the projects' rule
  (`move(id:_:)` in `Models.swift`): an item moves past its drawn neighbour, so a signal directly under a divider
  moves above it on one press **without changing priority**. Signal-past-signal stays a swap, as today.
- **Mutators** on `AppState`, beside the project ones: `append(signalDivider:)`, `renameSignalDivider`,
  `removeSignalDivider`, `canMove/move` for a signal divider, and `removeSignal(id:)`. `removeSignal` replaces the raw
  `signals.removeAll` in `AppController+Signals.swift:86` so the dividers below the removed signal keep their place.
  `canMove(signalId:)` now also counts a divider as a neighbour.
- **Projection.** `SignalSidebar` builds the Operator section's drawn entries: live signal sections with
  `DividerEntry`s between them, then removed signals' leftover headings last (as today). `signalSections` stays the
  list the arrow path, fold chips and selection read, so dividers stay off the arrow path and selection, like
  project dividers. The Operator's own row stays first, above any divider.
  `SidebarProjection.refresh()` returns early when its cached `Inputs` are equal, so `signalDividers` joins
  `Inputs`: otherwise adding, renaming or moving a divider with the signals unchanged would leave the sidebar stale
  (found in review).
- **A section of dividers alone.** Saved dividers count as something the Operator section shows, beside its row and
  signal headings (the `folds` condition in `refresh()`). Removing the last signal therefore leaves the section
  openable with its dividers, as the Projects section draws dividers without projects, so they can still be renamed
  or removed (found in review). Adding a divider still needs a live signal.
- **Row.** `DividerRow` is reused unchanged (`Views/DividerRow.swift`); only its wiring is new: a second
  `init(entry:controller:)`-style factory whose rename, move and remove reach the signal-divider mutators.
  No new tokens or visuals.
- **Adding.** The Operator heading's "+" menu gets **Add Divider…** after **New Signal…**, enabled when the
  workspace can change and at least one live signal exists (with none, the section has nothing to show it in).
  `SheetKind.newDivider` and `NameSheet.newDivider` carry which section they add to. **File ▸ Add Divider… (⌘D)**
  adds to the open section. Rename gets a signal-divider target whose subtitle reads "Changes the heading over the
  signals under it."
- **Out of scope:** dividers never reach the Operator's prompt, tools or digest (`SignalOperatorContractTests`
  goldens stay untouched); no drag; no divider in the folded section's chips.

## Files

- **modify** `app/Sources/AiTermCore/Models.swift`: `SignalDivider`; `signalDividers` with coding; the drawn-order
  compose/split; the mutators above; `canMove(signalId:)` past dividers.
- **modify** `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: reuse `DividerEntry` for the Operator section
  (or a thin twin if `SidebarDivider` can't carry it).
- **modify** `app/Sources/AiTerm/SignalSidebar.swift`: the Operator section's entries with dividers.
- **modify** `app/Sources/AiTerm/SidebarProjection.swift`: publish those entries beside `signalSections`.
- **modify** `app/Sources/AiTerm/Views/SidebarView.swift`: `operatorRows` draws entries; a divider is
  `.selectionDisabled()`.
- **modify** `app/Sources/AiTerm/Views/SidebarRows.swift`: the signal divider's `DividerRow` wiring.
- **modify** `app/Sources/AiTerm/Views/SidebarHeadings.swift`: Add Divider… in the Operator "+" menu.
- **modify** `app/Sources/AiTerm/AppController+Signals.swift`: add / rename / move / remove signal divider;
  `removeSignal` through the new mutator.
- **modify** `app/Sources/AiTerm/SheetKind.swift`, `SheetCoordinator.swift`, `Views/NameSheet.swift`: the section a
  new divider goes to; the signal-divider rename target.
- **modify** `app/Sources/AiTerm/AiTermApp.swift`: ⌘D adds to the open section.
- **modify** `app/Sources/AiTerm/Snapshots/SignalSidebarSnapshots.swift`: a `signals-divider` pose, two signals
  under a named divider.
- **tests** `app/Tests/AiTermCoreTests/ModelsTests.swift`, `StateStoreTests.swift`;
  `app/Tests/AiTermTests/SidebarProjectionTests.swift`, `AppControllerTests.swift`, `FileMenuTests.swift`,
  `SignalSidebarTests.swift`, `RowAccessibilityTests.swift` (if it covers divider labels).
- **modify** `app/Sources/AiTermUI/README.md`: the composition inventory's "New Signal… alone under the Operator"
  becomes New Signal… and Add Divider…, and `DividerRow` is named in both sections (found in review).
- **modify** `docs/operators.md` (headings order paragraph: dividers label, priority unchanged),
  `docs/keyboard.md` (⌘D adds to the open section; signal divider menu), `docs/design/ui-patterns.md`.
- **modify** `docs/design/design-system.html`, through the `design-system` skill: first a proposal on the
  Proposals tab drawing the Operator section with a divider between signal headings, before any Swift (the
  invariant in `AGENTS.md`; found in review); after implementation, the proposal removed and the Components prose
  on `DividerRow` updated to name both sections. Published from a later session: reviewed locally here, as agreed.

## Proof

- Test first, failing before the change:
  - `ModelsTests`: compose/split round trip; add, rename, remove; divider moves among signals and past another
    divider; a signal moving past a divider keeps `signals` order (priority) unchanged; removing a signal keeps the
    dividers below it in place; out-of-range positions clamp; `signalDividers` omitted when empty and round-trips.
  - `SidebarProjectionTests` / `SignalSidebarTests`: drawn order with dividers; `operatorPath` unchanged by
    dividers; removed headings after a trailing divider; move flags; after a first `refresh()`, adding, renaming and
    moving a divider alone re-derives the rows; with the last signal removed and no tasks left, the section still
    folds and opens on its dividers.
  - `AppControllerTests` / `FileMenuTests`: Add Divider… from the Operator menu trims the name; ⌘D adds to the
    open section; a locked workspace refuses.
  - Filtered runs: `scripts/test.sh swift -- --filter Models` (and the other suites above).
- Before the commit: plain `scripts/test.sh`, in the background.
- Visual: `AITERM_SNAPSHOT_HOSTED=1 scripts/snapshots.sh <dir>` before and after: the existing `signals-*` captures
  unchanged, the new `signals-divider` shows the named rule between two signal headings in the project divider's
  exact treatment.

## To-dos

- [x] Proposal: the Operator section with a divider drawn on the design page's Proposals tab (`design-system`
      skill); the user picks before any Swift.
- [x] Model: `SignalDivider`, saved key, drawn-order compose/split, mutators, `removeSignal`; `ModelsTests` and
      `StateStoreTests` green.
- [x] Projection and drawing: Operator entries with dividers, `DividerRow` wiring with Rename / Move / Remove;
      projection tests green.
- [x] Adding: Operator "+" Add Divider…, sheet section, rename target, ⌘D to the open section; controller and
      File-menu tests green.
- [x] Snapshot pose, before/after compared; docs updated; design page proposal removed, Components prose updated
      (reviewed locally and left unpublished, agreed 23 Nov: the live page is too large to read back from this
      session); plain `scripts/test.sh` green.
