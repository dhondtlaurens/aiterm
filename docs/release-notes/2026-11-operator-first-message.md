# The Operator's first message

**Once this version has opened your workspace, an earlier AiTerm refuses it.** This version updates
the workspace once, on its first launch.

## Upgrade

1. Quit AiTerm: the installed app and any development build. iTerm2 and its windows can stay open.
2. Install this version and open it. A small window says **Updating your workspace for AiTerm
   2.1.0…** while it runs. Your workspace as it was is kept beside it as
   `state.json.before-update-<format>`, named after the format it was in: `2.0.0` from 2.0.x, or
   `1.5.0` when you skipped 2.0.
3. What to expect: everything is there except the Operator's snag reports, which the update removes.

## Going back is not supported

An earlier AiTerm refuses a workspace this version updated. To go back anyway, quit AiTerm, put
the `state.json.before-update-<format>` it kept in place of `state.json` (both in
`~/Library/Application Support/AiTerm/`) and open the earlier version; changes made since the
update are lost.

## What changes

- A new Operator chat opens on one line asking it to read AiTerm's status, instead of the whole
  status as JSON. The Operator reads its status once instead of twice.
- The Operator no longer records snags, AiTerm discrepancies it worked around. No screen had shown
  them since broadcasts were removed, and they filled most of every status the Operator read.
- An update to the saved workspace may now come with a minor or patch release, not only a major one.
