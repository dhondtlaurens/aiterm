# The Operator row's title counts its workload instead of repeating its heading

## Goal

The Operator section's heading says **Operator** and the first row under it, `SignalOperatorRow`, says
**Operator** again. Every other row's title says something its heading does not. The row's title should say what
the Operator holds: **3 tasks · 2 signals**, **1 task · 1 signal**, or **No tasks**. The caption keeps the activity,
and at rest says **watching** alone, since the count moved up.

Picked on the design page's Proposals tab (19 Nov 2026): **C**, the workload as the title. The rejected options were
one line with the activity as the only text (A), "Chat" (B) and renaming the heading to "Signals" (D).

## Approach

`SignalOperatorRowValue` gains a `title`, built in `make` from the `tasks` and `signals` counts it already derives
from `state.operatorWorkTasks`. `SignalOperatorRow` draws `RowTitle(value.title)`; the title never decodes (only
`OperatorActivityCaption` morphs, as today).

Decided while planning:

- **Format:** `N task(s) · M signal(s)`, singular at one. Every workload task has a signal task
  (`operatorWorkTasks` filters on it), so a counted task always counts at least one signal; no special case.
- **No tasks:** the row can show with an empty workload (a question for you, its chat working or needing input, an
  app issue, a retiring session, live activity). The title then reads **No tasks**. `SignalOperatorRowValue.empty`
  carries it too.
- **Caption loses the duplicate count:** the resting line `watching N tasks in M signals` becomes `watching`; the
  changing line `starting fresh · N tasks carried over` becomes `starting fresh`. Every other line is unchanged.
- **VoiceOver:** the label becomes `Operator, <title>`, since the visible text no longer names the Operator; the
  value stays the line's tooltip.
- The heading (`Operator`, `Operator · paused`), its menus, the row's wash, mark, status mark and click are
  unchanged. No token changes.

## Files

- **modify** `app/Sources/AiTerm/SignalSidebar.swift`: `title` on `SignalOperatorRowValue`, computed in `make`;
  the resting and starting-fresh lines; `empty`'s line and title.
- **modify** `app/Sources/AiTerm/Views/Operators/SignalRows.swift`: draw `value.title` in tabular figures; the
  accessibility label.
- **modify** `app/Sources/AiTerm/Views/SidebarRows.swift`: `RowTitle` takes `tabular`, since the README asks for
  tabular figures where digits change (found in review).
- **modify** `app/Tests/AiTermTests/SignalSidebarTests.swift`: title cases (0 tasks, 1 task in 1 signal, several in
  several) and the new resting line.
- **modify** `app/Tests/AiTermTests/SignalSidebarPresentTests.swift`,
  `app/Tests/AiTermTests/Operators/SignalOperatorIssueTests.swift`: the resting line's expectation becomes
  `watching`.
- **check** `app/Tests/AiTermTests/RowAccessibilityTests.swift`: add the Operator row's label if the suite covers
  row labels; otherwise leave it.
- **modify** `docs/operators.md`: "Its title stays steady" becomes what the title says and that it does not decode.
- **modify** `docs/design/ui-patterns.md`: "The title stays “Operator”" (line 51) becomes the counted title.
- **modify** `docs/design/design-system.html`: delete the `#p-operator-title` proposal (restore the
  `no-proposals` line), rewrite the `#c-operator` passage that says the title stays "Operator", replace its native
  reference images with fresh `scripts/snapshots.sh` captures, then publish through the `design-system` skill.

`OperatorBadgeTests` use their own `OperatorLine` literals and do not depend on `make`; they stay.

## Proof

- Test first: the new title cases and the changed lines in `SignalSidebarTests`, failing before the change, through
  `scripts/test.sh swift -- --filter SignalSidebar` (and `--filter SignalOperatorIssue`).
- Before the commit: plain `scripts/test.sh`, in the background.
- Visual: `AITERM_SNAPSHOT_HOSTED=1 scripts/snapshots.sh <dir>` before and after (the `signals-*` captures are
  `hostedOnly` and skipped without it; native capture needs screen-recording permission). The Operator section's
  captures (`signals-acting`, `-questions`, `-paused`, `-idle`, `-fresh`, `-issue`) show the counted title and the
  shorter resting and starting-fresh captions, nothing else moved. The design page's references come from the
  after set.

## To-dos

- [x] Title and shorter lines on `SignalOperatorRowValue`, tests first; filtered suites green.
- [x] `SignalOperatorRow` draws the title and the new VoiceOver label; snapshots before and after compared.
- [x] `docs/operators.md` and `docs/design/ui-patterns.md` updated; design page synced (proposal removed, Components prose and images updated) and
      published; plain `scripts/test.sh` green.
