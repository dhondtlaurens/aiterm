# Approved and merged on the merge-request badge

## Goal

The sidebar's merge-request badge says when a request is ready to merge, not only when it merged. Today the host's
mark wears a green corner check once the request merges, and nothing shows an approval. After this change:

- **Approved and every thread resolved**: the mark wears the green check disc (today's merged mark). A request
  with no review threads needs only the approval.
- **Approved with threads open**: no corner; the tooltip and VoiceOver still say "approved".
- **Merged**: a purple disc with a merge glyph replaces it, and the thread bubble with its `n/n` is dropped, from
  the tooltip and VoiceOver too, which say "merged".
- Both discs grow from 6 to 8 pt. Resolved threads get no mark of their own: `n/n` says it.

The same on GitLab and GitHub. Drawn and picked on the design page's Proposals tab (23 Nov, option G2 at 8 pt).

## Approach

`ReviewThreadsReader` already fetches a request's threads and the request itself, both or neither; it now also
fetches who approves it, through the `approvals(of:)` both hosts' repositories already have (GitHub: each reviewer's
latest approving or changes-requested review; GitLab: `approved_by`). Any current approval counts as approved; the
host's required-approvals rule is not read. A failed approvals read fails the whole read, so the watcher keeps the
row's last good answer, as it does today.

The badge's corner stops being a Bool and becomes a kind: none, `finished` (the green check: a Jira ticket in Done,
a request approved with every thread resolved) or a new `merged` (`SettledMark`'s third kind: a `Palette.merged`
disc, `.systemPurple`, with a merge glyph drawn as a shape in proportions of its size, white on the purple and cut
out of a white disc on the accent, as the other kinds are). Merged wins over approved. Where a GitLab issue and its
merge request share one mark, the mark wears the request's kind. When that line shows the issue's number but not the
request's, and the request has nothing left of its own to draw (merged, so no bubble; or no threads, as today), its
tooltip and VoiceOver words join the issue's badge, as they already do when neither number shows; a click on that
badge opens the issue, as it does today for a request without threads. The line's composition moves into a value
that tests can read without rendering. `Size.cornerBadge` grows from 6 to 8 pt for every
badge that wears a corner, Jira's Done check included; the disc stays overlaid on the 10 pt icon's corner,
overhanging it by `Space.hairline`, so the chip's size does not change.

Grilling decided: approval colour and shape (the green check, with purple merged), no resolved-threads mark, the
bubble dropped once merged, 8 pt, "any current approval", the check only once every thread is resolved, and the
design page updated locally only (publishing it needs a full read of the 2.2 MB live page).

## Files

- `app/Sources/AiTermCore/CodeHost.swift` — modify: `ReviewThreads` gains `approved`, with its doc.
- `app/Sources/AiTermCore/CodeHosts/ReviewThreadsReader.swift` — modify: read approvals beside threads and request,
  all three or none.
- `app/Sources/AiTermUI/Palette.swift` — modify: add `merged` (`.systemPurple`).
- `app/Sources/AiTermUI/Metrics.swift` — modify: `Size.cornerBadge` 6 → 8, its doc.
- `app/Sources/AiTermUI/SettledMark.swift` — modify: a `.merged` kind and its `MergeGlyph`; `CheckGlyph`'s stroke
  doc (a sixth of the disc is no longer one point at the corner size).
- `app/Sources/AiTermUI/Badge.swift` — modify: `checked: Bool` becomes a corner kind; `CornerCheck` draws either
  kind; the type's doc.
- `app/Sources/AiTerm/SidebarRowValues.swift` — modify: `TaskRowBadges.Link` carries the corner kind and its word;
  the approved-and-resolved rule; merged drops the thread suffix; "approved" in help and VoiceOver whenever approved.
- `app/Sources/AiTerm/Views/QuietBadgeLine.swift`, `app/Sources/AiTerm/Views/SidebarRows.swift` — modify: pass the
  kind through; on the shared GitLab mark the request's kind wins over the ticket's; the badges the line draws become
  a value computed from its inputs, and a request with nothing of its own to draw folds its help and VoiceOver words
  into the issue's badge.
- `app/Sources/AiTerm/Snapshots/SidebarSnapshots.swift` — modify: the review-threads snapshot shows approved with
  threads open, approved and all resolved, and merged.
- `app/Sources/AiTermUI/README.md` — modify: the `Badge` and `SettledMark` inventory lines.
- `docs/design/design-system.html` — modify: remove the proposal and sync Foundations and Components to the Swift.

## Proof

- `ReviewThreadsBadgeTests` (AiTermTests): approved with 2/5 resolved has no corner but says "approved"; approved
  with 5/5 wears the check; approved with no threads wears the check; merged wears the merged kind, has no thread
  suffix and says "merged"; merged and approved is merged; open and unapproved has no corner; the existing merged
  tests move to the new kind.
- The shared GitLab mark (`ReviewTicketFieldTests`, beside its `sharesGitLabMark` cases, on the line's new value):
  the mark wears the request's kind; with the issue's number shown and the request's hidden, a merged request, and an
  approved one without threads, draw one badge whose help and VoiceOver words name the request and say "merged" or
  "approved".
- `ReviewThreadsReaderTests` (AiTermCoreTests): `approved` follows a non-empty approvals list on GitLab and GitHub;
  an approvals read that fails throws.
- `SettledMarkTests` (AiTermUITests): merged is a `Palette.merged` disc with an `onAccent` glyph; on the accent the
  disc is `onAccent` and its glyph the ground's.
- `BadgeTests`: a badge with either corner kind is the same chip as one without, at every scale.
- `PaletteDistinctionTests`: `merged` in the manifest.
- Visible: `scripts/snapshots.sh build/snapshots-before` on `main`, `build/snapshots-after` on the branch; read both
  sets (the review-threads rows, and any row with a Jira Done check) and compare.
- Gate: `scripts/test.sh` before each commit; a recent green full suite before merging (`docs/workflow/project.md`).

## To-dos

- [x] The approval reaches the row: `ReviewThreads.approved`, the reader reads approvals, and the check shows once
      approved and every thread is resolved, with "approved" in the tooltip either way (tests first).
- [x] The merged mark: `Palette.merged`, `SettledMark.merged`, the badge's corner kind; a merged request wears it and
      drops the thread suffix; the shared GitLab mark wears the request's kind, and a request with nothing left to draw
      keeps its words on the issue's badge (tests first).
- [x] `Size.cornerBadge` 6 → 8 and the glyph docs; the corner overlay tests stay green.
- [x] The snapshot shows the new states; read before and after.
- [x] README inventory and the design page synced, the proposal removed.
