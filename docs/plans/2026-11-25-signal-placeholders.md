# Tab fills a Signal query's example

## Goal

The examples in the Signal sheet's query fields are often what the person wants. Tab in one of those
fields while it is empty writes its example in, so it no longer has to be retyped.

The approved fields, all drawn by `SignalTriggerStep.queryField`:

| Step | Field | Fills in |
|---|---|---|
| Start · An item · Jira | JQL | `assignee = currentUser() AND sprint in openSprints()` |
| Start · An item · GitLab | GitLab query | `reviewer:@me review-state:unreviewed draft:no` |
| Start · An item · GitHub | GitHub query | `is:open user-review-requested:@me` |
| Done · A query matches · Jira | JQL | `status = Done` |
| Done · A query matches · GitLab | GitLab query | `reviewer:@me review-state:approved` |
| Done · A query matches · GitHub | GitHub query | `-user-review-requested:@me` |
| Start · A schedule | Cron | `0 9 * * 1` |

Left out on purpose: Describe it and What done looks like (examples meant to be rephrased before
Write), Name and Prompt (their placeholders are instructions), and fields outside the Signal sheet.

## Approach

`PromptEditor` takes an optional text that Tab fills, nil by default. Its `doCommandBy` delegate
answers `insertTab:` first: when the text is empty (the same test `PromptPlaceholder` shows the
example on) and a fill is set, it inserts the fill through `shouldChangeText`/`didChangeText`, as
`accept` inserts a completion, so the binding, undo and the caret at its end behave like typing,
and the sheet's match preview or next runs follow as they do for typed text. Any other Tab (a field
with text, an editor without a fill) goes on to the popup keys and then the text view, as today.

`PromptStep` passes the fill through; `SignalTriggerStep.queryField` sets it to that field's
`queryPlaceholder`. Every other `PromptEditor` (task prompt, describe fields, Operator instructions)
keeps today's Tab. No visual change, so the design system and snapshots are untouched; no Signal
contract or golden changes.

Decided while grilling: the seven fields above; "tab in" means pressing Tab inside the empty field
(today it types a tab character); a non-empty field keeps its current Tab.

## Files

- modify `app/Sources/AiTerm/Views/PromptEditor.swift`: the optional Tab fill and its rule in
  `doCommandBy`.
- modify `app/Sources/AiTerm/Views/Steps/PromptStep.swift`: passes the fill to its editor.
- modify `app/Sources/AiTerm/Views/Operators/SignalTriggerStep.swift`: `queryField` fills with its
  example.
- modify `app/Tests/AiTermTests/PromptEditorTests.swift`: the Tab rule's tests.

## Proof

- `PromptEditorTests`, driving the real text view's delegate as the popup-key tests do:
  - an empty editor with a fill: Tab writes the fill to the binding, the caret ends after it, and
    undo empties the field again;
  - an editor with text: Tab is not taken, the text is unchanged;
  - an editor without a fill: Tab is not taken.
- A wiring test that the Signal sheet's Start JQL and Cron editors fill with their own examples.
- `scripts/test.sh` green; then `scripts/run-dev.sh`: a new signal, Tab in each empty query field
  (Start Jira, GitLab, GitHub, Done, Cron) fills its example and the match preview or next runs
  appear.

## To-dos

- [x] Tab fill rule in `PromptEditor`, nil by default, with its three tests
- [x] Signal query fields opt in through `PromptStep` and `SignalTriggerStep`, with the wiring test
- [ ] Gate green and the dev app check
