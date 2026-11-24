# Inline merge glyph and centered hover labels

## Goal

Show that a GitLab merge request or GitHub pull request has merged using the joined-branches glyph selected in option A of the local design preview. Center each raised hover label over the badge or Usage reading that raised it.

## Approach

A merged request shows its host, its number when enabled, then a 10 pt joined-branches glyph in the badge label’s ink with the usual 4 pt gap at standard scale. Match the three nodes and connecting strokes in the selected preview. Approval with all threads resolved and a Jira ticket in Done retain their green corner checks. Merged wins over approved, suppresses the thread bubble and count, and still says “Merged” on hover and “merged” to VoiceOver.

Carry the merge indication separately from the thread count so it cannot accidentally create an extra link. Compose the shared GitLab badges first. With a visible request number, put the glyph and hover label on that request’s badge. With only the issue number visible, fold both into the issue badge, which opens the issue. With both numbers hidden, the single shared badge opens the request. A standalone request with its number hidden shows its host and the glyph together. Preserve the existing order in which badges drop as the row narrows.

Use the shared hover-chip modifier to align the horizontal midpoints of the chip and its own hover target. For a badge, use the whole fixed-size badge. For Usage, anchor the label over the visible span from the window label to the actual percentage. Apply the width reservation for “100%” outside that anchor. Keep the existing column alignment and pointer hit area. Keep the current scaled vertical gap, immediate reveal and click-through overlay.

## Files

- Modify `app/Sources/AiTerm/SidebarRowValues.swift`, `Views/SidebarRows.swift` and `Views/QuietBadgeLine.swift` under the same target to project the merged state and place its glyph, hover label and spoken words on the correct badge.
- Modify `app/Sources/AiTermUI/Badge.swift` to support a decorative trailing glyph in the label ink. Reuse its existing size, spacing and suffix layout. Draw the chosen shape at the sidebar scale.
- Modify `app/Sources/AiTermUI/SettledMark.swift`, `Palette.swift` and the corner-size comment in `Metrics.swift` to retire the purple merged disc and its dedicated colour.
- Modify `app/Sources/AiTermUI/HoverChip.swift` to center the overlay. Modify the reading in `app/Sources/AiTerm/Views/SidebarFooter.swift` so the invisible trailing space reserved for shorter percentages is outside the alignment measurement.
- Update the merged fixture descriptions in `app/Sources/AiTerm/Snapshots/SidebarSnapshots.swift` and the sidebar badge description in `docs/design/ui-patterns.md` to match the selected design.
- Update the badge projection, composition and tooltip tests in AiTermTests and the badge, settled-mark, palette and hover-chip tests in AiTermUITests.
- Update `app/Sources/AiTermUI/README.md` and the local `docs/design/design-system.html` reference after implementation. Remove this proposal once its shipped examples are in Components.

## Proof

- Test standalone requests on both hosts, approved and merged together, and merged with old thread counts. Check that the glyph follows the number or host at each sidebar scale and in label ink with either brand setting. Assert the hover and VoiceOver words and the absence of a purple corner and thread count.
- Cover all four issue/request number combinations on a shared GitLab badge. Assert one glyph, one Merged hover owner, spoken text and the existing action destinations. Exercise narrow fits that drop the request.
- Render the shared modifier with targets wider and narrower than the chip at all three interface sizes. Measure the chip’s horizontal midpoint and vertical clearance, and confirm showing it preserves target size. Exercise passive and clickable badges. In SidebarFooterGeometryTests, render a hovered Usage reset with 5%, 42% and 100%, and compare its center with the span of the displayed reading at each scale. Verify column positions at minimum sidebar width.
- Compare before/after images from `scripts/snapshots.sh` on the base and feature branch, including review-thread badges and the hovered Usage footer. Run the focused Swift tests through `scripts/test.sh swift -- --filter` and the project gate through `scripts/test.sh`.

## To-dos

- [ ] Add and test the trailing glyph in Badge at all interface sizes. Update its entry in the AiTermUI spec.
- [ ] Wire the glyph through the sidebar, cover shared GitLab actions and hover ownership, and retire the purple mark. Update the SettledMark spec, fixture descriptions and sidebar pattern.
- [ ] Center the shared hover chip, verify badge and visible footer reading geometry, and update the HoverChip spec.
- [ ] Compare snapshots, sync the local reference and run the gate.
