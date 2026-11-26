# Update scripts

**Once this version has opened your workspace, an earlier AiTerm must not open it again.** It
would open it, and a save there leaves a workspace this version refuses (see below).

From this version, the workspace records which AiTerm format it is in. When a new version saves the
workspace differently, it updates the file once, on its first launch, and from then on reads only
its own format. Every update between the version you had and the one you install runs in turn, so
skipping releases is fine.

## Upgrade

1. Quit AiTerm: the installed app and any development build. iTerm2 and its windows can stay open.
2. Install this version and open it. A small window says **Updating your workspace for AiTerm
   2.0.0…** while it runs. Your workspace as it was is kept beside it as
   `state.json.before-update-1.5.0`.
3. What to expect: your projects, tasks, terminals, the Archive, conversations, signals and the
   Operator's records are all there.
4. On a version before 1.0, install 1.5.0 first and open it once, then install this one.

## Going back is not supported

An earlier AiTerm that saves a workspace this version updated drops what it does not know, and
this version then refuses the file. To go back anyway, quit AiTerm, put
`state.json.before-update-1.5.0` in place of `state.json` (both in
`~/Library/Application Support/AiTerm/`) and open the earlier version; changes made since the
update are lost.

## What changes

- A workspace saved by a newer AiTerm is refused at launch with the version to install, instead of
  being opened partly.
- Dividers you had made between signals are gone: the update removes them from the workspace, and
  signals are grouped by section instead ([Signals by section](2026-11-signals-by-section.md)).
- A task of a retired agent (Grok) is a Claude task on Claude's defaults, as 1.5.0 showed it, and
  now resumes its Claude conversations.
- A development build asks before it updates the workspace it shares with the installed AiTerm.
