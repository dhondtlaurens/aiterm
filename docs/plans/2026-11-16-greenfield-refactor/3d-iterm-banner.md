# 3d. The iTerm2 banner

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 3c (by order; it touches no file 3a to 3c change
except `SidebarView.swift`). Audit findings: WD F7.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The plan lists three banner states. There is a fourth a person can act on: iTerm2 is running but
AiTerm is not connected to it, because iTerm2's Python API is switched off or the person has not
answered iTerm2's prompt yet. That is the first-run case. Today it shows "Waiting for iTerm2…" for
ever with nothing to do. Showing nothing would leave a new user with an empty sidebar and no hint,
so after the grace this state gets a banner that says so and opens Settings at the iTerm2 card,
which already names what is missing.

Phase 6 runs on its own track. If 6b has landed before this step, `ItermConnection.helperMismatch` and
`DaemonConnection`'s `HeldStatus` may be gone: skip what this brief says about them. If not, keep them as
described.

## Why

The banner above the sidebar speaks the plumbing: "Starting AiTerm’s helper…", "Reconnecting to AiTerm’s
helper…", "Waiting for iTerm2…", "Reconnecting to iTerm2…". After a person quits iTerm2 on purpose it says
"Reconnecting to iTerm2…" for ever, because AiTerm (by design) never restarts iTerm2 after a quit, and it
offers no action. The app already knows iTerm2 is not running: it answers each of the helper's cookie
requests with `.notRunning`, but that answer never reaches the status. The end state: the banner shows
only what a person can act on: "iTerm2 isn’t running" with an Open iTerm2 link; "iTerm2 refused AiTerm"
with the Automation fix it shows today; "AiTerm’s helper isn’t working" with what to do (the log, or the
missing piece); and "AiTerm isn’t connected to iTerm2" with a link to the Settings card that names the
fix. While starting, reconnecting or connected it shows nothing, and a start, a reconnect or a wait for
iTerm2 gets a short grace before it counts as a problem.

## Today

All in `app/Sources/`.

- `AiTermCore/Daemon/ItermConnection.swift`: `ItermConnection`, ten cases (`starting`, `helperMissing`,
  `pythonMissing`, `helperFailing(String)`, `helperMismatch`, `helperUnreachable`, `waitingForIterm`,
  `itermReconnecting`, `refused(String)`, `connected(version:)`); `forSnapshot(_:)`; `status` (the iTerm2
  card's status line); `banner: DaemonBanner?`, whose text opens with `status`; `logPath`.
- `AiTermCore/Daemon/DaemonBanner.swift`: `DaemonBanner` (text, tone `.info` grey or `.warning`). Only
  `ItermConnection.banner`, `SidebarConnectionBanner`, `SidebarSnapshots` and `DaemonTypesTests` use it
  (`grep -rn "DaemonBanner" app/`).
- `AiTerm/DaemonConnection.swift`: `run()` reports statuses through `HeldStatus.report` (or `onStatus`):
  `forSnapshot` on each snapshot, `.itermReconnecting` on `.itermDisconnected`, `.refused` on
  `.itermAuthFailed`, `.helperMismatch` or `.helperUnreachable` when a connection ends. The nested
  `answer(_:)` sends `requestCookie()`'s result (`ItermCookieAnswer`: `granted`, `notRunning`,
  `refused`) to the daemon and reports nothing.
- `AiTerm/ItermCookie.swift`: `request()` answers `.notRunning` from `NSRunningApplication` before sending
  the Apple event. The daemon (`daemon/aitermd/connection.py`, `_reconnect_loop`) asks for a cookie on
  every retry while iTerm2 is away, so the app is asked again every few seconds.
- `AiTerm/HelperLink.swift`: `itermConnection` (observable) set by `start()` (`.helperMissing`,
  `.pythonMissing`), `supervisorChanged` (`.helperFailing` from the second failure) and the connection's
  `onStatus`.
- `AiTerm/Views/SidebarView.swift`: `SidebarBanners` shows
  `SidebarConnectionBanner(banner: controller.helper.itermConnection.banner!, status: ...)`;
  `SidebarConnectionBanner` draws `.warning` as a `Notice` (title and description split by
  `notice(_:status:)`) and `.info` as grey `HelpText`. `Notice` (`AiTerm/Views/Notice.swift`) takes
  `title`, `description`, `help` and an actions builder of `Button`s, as `IssueBanner` uses it.
- `AiTerm/Views/ItermSettingsCard.swift`: `ItermCardPresentation.diagnose` switches over every case.
  `AiTerm/Views/SettingsView.swift`: `SettingsTab.opening(iterm:serviceTestFailed:)` opens Integrations
  for anything not connected.
- `AiTerm/AppController.swift`: the `launchIterm` port (live: `NSWorkspace.openApplication` with
  `activates = false`), private; used by `start()` and by the window owner. `AppTimings` in
  `AiTerm/AppPorts.swift` (3a left `peekDelay`, `checkoutPollInterval`, `toastLifetime`).
- Snapshots: `AiTerm/Snapshots/SidebarSnapshots.swift` `sidebar-banners.png` draws the refused banner and
  a hand-made `.info("Waiting for iTerm2…")`; `SettingsSnapshots.swift` `settings-iterm-off.png` draws the
  card for `.waitingForIterm` with the API off.
- Tests: `AiTermCoreTests/DaemonTypesTests` (`bannerWarnsWhileITerm2RefusesAndOtherwiseOnlyWaits`,
  `everyStateButConnectedKeepsItsBanner`), `AiTermTests/DaemonConnectionTests`
  (`refusedITerm2AuthenticationIsAWarningFromTheSnapshotAndFromTheEvent` expects `.itermReconnecting`;
  `cookieRequestsFromTheSnapshotAndTheEventAreEachAnsweredOnce`), `ItermSettingsTests`,
  `HarnessSettingsLayoutTests`, `AppControllerTests` (`ControllerStorageTests` expects the starting banner
  about line 24 and sets `.itermReconnecting` about line 40), `SheetPreparationTests` (uses
  `.waitingForIterm` as an input only).
- Docs that quote the old banner: `README.md` (install step 3), `docs/configuration.md` (iTerm2 section),
  `docs/ai-install.md` (about line 109), `docs/daemon-protocol.md` (`iterm.connected` and
  `iterm.disconnected` rows).

## Change

1. **States.** In `ItermConnection`, add `itermNotRunning` (status "iTerm2 isn’t running") and delete
   `itermReconnecting`: a lost iTerm2 is `waitingForIterm`, whose status stays "Waiting for iTerm2…" for
   the card. Other cases and their `status` strings stay.
2. **The banner value.** Replace `DaemonBanner` (delete its file) with a Core value `ConnectionBanner`:
   `title`, optional `description`, optional `help` (the tooltip), `opensIterm` (whether it carries the
   Open iTerm2 link) and `opensSettings` (whether it carries the Open Settings link). Replace `ItermConnection.banner` with `banner(waited:)`, where `waited` says the
   state has lasted the grace:
   - `itermNotRunning`: title "iTerm2 isn’t running.", the link.
   - `refused(reason)`: title "iTerm2 refused AiTerm.", description "In System Settings › Privacy &
     Security › Automation, turn on iTerm2 under AiTerm. AiTerm retries on its own within a minute.",
     help the reason.
   - title "AiTerm’s helper isn’t working." with the cause's own description: `helperMissing` "Reinstall
     AiTerm.app, which bundles the helper."; `pythonMissing` "Python 3.11+ was not found. Install it with
     brew install python, then quit and reopen AiTerm."; `helperFailing(message)` "It keeps stopping:
     <message>. Read why in <logPath>."; `helperMismatch` (if it still exists) "It is from another version.
     Quit and reopen AiTerm.app."; `starting` and `helperUnreachable` only when `waited`, "Read why in
     <logPath>.".
   - `waitingForIterm` only when `waited`: title "AiTerm isn’t connected to iTerm2.", description
     "iTerm2 has to allow AiTerm’s connection. Settings shows what is missing.", the Open Settings link.
   - nil for `starting`, `helperUnreachable` and `waitingForIterm` before the grace, and always for
     `connected`.
3. **Report "not running".** In `DaemonConnection.run()`'s `answer(_:)`, after `requestCookie()`
   returns, report `.itermNotRunning` for `.notRunning` and `.waitingForIterm` for `.granted` (the
   not-running banner goes as soon as iTerm2 hands over a cookie); a `.refused` answer reports nothing
   (the daemon's `iterm.auth_failed` follows). Report through the same path the other statuses use
   (`HeldStatus.report` while it exists). `.itermDisconnected` reports `.waitingForIterm`.
4. **The grace.** `HelperLink` gets an observable `connectionBanner: ConnectionBanner?` and an init
   parameter `connectionGrace: Duration`. Whenever `itermConnection` changes, and at `start()`, it sets
   `connectionBanner = itermConnection.banner(waited: false)` and cancels any grace task; for `starting`,
   `helperUnreachable` and `waitingForIterm` it starts one that, after `connectionGrace`, sets `banner(waited: true)` if the state
   is still the one it started for. `AppTimings` gains `connectionGrace`, ten seconds in `AppTimings.live`
   (it covers a cold Python start and the helper's first three reconnect waits of 1, 2 and 5 s);
   `AppController` passes it to `HelperLink`. `HelperLink.shutdown()` cancels the grace task.
5. **Open iTerm2.** Add `AppController.openIterm()`, which calls the `launchIterm` port.
6. **The view.** `SidebarBanners` draws `SidebarConnectionBanner` from `controller.helper.connectionBanner`.
   `SidebarConnectionBanner(banner:openIterm:)` is one `SidebarBanner(trailing: Space.block)` holding a
   `Notice(title:description:help:)` whose actions are an "Open iTerm2" `Button` when `opensIterm` and an
   "Open Settings" `Button` when `opensSettings`, which presents Settings on the tab `SettingsTab.opening`
   already picks for a connection that is not made (Integrations, at the iTerm2 card). Delete
   `notice(_:status:)` and the grey `.info` branch. Update the doc comments of `SidebarBanners`,
   `SidebarConnectionBanner` and `Notice` ("the grey line while iTerm2 connects" no longer exists). All
   sizes and colours are the ones `Notice` and `SidebarBanner` already use.
7. **The card.** In `ItermCardPresentation.diagnose`, `itermNotRunning` goes through the same "is iTerm2
   installed, is its API on" checks as `waitingForIterm` and `refused`, then gets
   `SettingsStatus(.attention, "iTerm2 isn’t running")` with the steps "Open iTerm2" and "AiTerm connects on
   its own within a few seconds". Remove `itermReconnecting` from the switch.
8. **Snapshots.** In `sidebar-banners.png`, draw the four connection banners from real states:
   `.itermNotRunning`, `.refused("not allowed")`, `.helperFailing("exit 1")` and `.waitingForIterm`
   after the grace, in place of the refused
   one and the hand-made grey line.
9. **Docs.** `README.md` step 3 and `docs/configuration.md`'s iTerm2 paragraph: "Until then the sidebar
   says AiTerm isn’t connected to iTerm2, and Settings › Integrations › iTerm2 shows what is missing."
   `docs/ai-install.md`: the same for "Until they do". `docs/daemon-protocol.md`: `iterm.connected` "ends
   the wait for iTerm2", `iterm.disconnected` "the app waits; after a short grace its banner says it
   isn’t connected; the daemon retries on its own, without launching iTerm2 again; a cookie answer of not
   running shows iTerm2 isn’t running".

## Keep

- `ItermCookie`'s answers and the daemon never relaunching iTerm2 after a quit: the banner's link is the
  person's way to start it.
- `ItermConnection.status`: the card's status line, read by `ItermCardPresentation` and tests.
- `forSnapshot(_:)`, the bootstrap gating, the `answered` cookie dedupe and the `steadyAfter` backoff
  reset in `DaemonConnection`: the audit's "sound, keep".
- `SettingsTab.opening` (Integrations for anything not connected).
- `ItermEnvironment` and the card's install and API checks: the card is where the silent waiting state is
  explained.
- `settings-iterm-off.png`: it draws `.waitingForIterm` with the API off and must not change.

## Decisions already taken

- The grace is ten seconds and applies to `starting`, `helperUnreachable` and `waitingForIterm`. Every
  other banner shows at once. A reconnect after iTerm2 restarts is normally done within the grace, so
  the waiting banner shows only when iTerm2 really does not let AiTerm in.
- Open iTerm2 starts iTerm2 without bringing it forward (the live port's `activates = false`); the banner
  goes when the next cookie request is granted, a few seconds later.
- iTerm2 not installed: the banner still says it isn't running and the link does nothing; the card says
  it is not installed. AiTerm is for iTerm2 users; no special case.
- The tone split (`.warning` amber, `.info` grey) goes: every banner left is a `Notice`, whose mark carries
  the tone.
- A test controller gets the live grace (ten seconds) by default, so no test sees a helper banner unless
  it passes a short one.

## Tests

Delete: `DaemonTypesTests.everyStateButConnectedKeepsItsBanner`: the behaviour (every state keeps a
banner) is deleted; replaced below.

Adjust:

- `DaemonTypesTests.bannerWarnsWhileITerm2RefusesAndOtherwiseOnlyWaits`: a refusing snapshot gives the
  refused banner (title, Automation description, the reason as help); a not-connected snapshot gives no
  banner; a connected one none.
- `DaemonConnectionControllerTests.refusedITerm2AuthenticationIsAWarningFromTheSnapshotAndFromTheEvent`:
  expects `[.refused("first refusal"), .waitingForIterm, .refused("second refusal")]`.
- `ItermSettingsTests` and `HarnessSettingsLayoutTests`: drop `.itermReconnecting`; add `.itermNotRunning`
  to the lists of broken states.
- `ControllerStorageTests`: the never-started controller has `connectionBanner == nil`; `.itermReconnecting`
  becomes `.waitingForIterm`.
- `ScratchController` gains `connectionGrace` (default ten seconds).

Add:

- `DaemonTypesTests`: `banner(waited:)` for every case: the three titles, each cause's description, the
  link only for not running, nothing for waiting and connected, nothing for starting and unreachable
  until `waited`.
- `DaemonConnectionControllerTests`: a cookie request answered `.notRunning` reports `.itermNotRunning`;
  a later request answered `.granted` reports `.waitingForIterm` (use the existing `PythonSocketServer`
  pattern of `cookieRequestsFromTheSnapshotAndTheEventAreEachAnsweredOnce` with a scripted
  `requestCookie`).
- A controller test (`ControllerStorageTests` or a new `ConnectionBannerTests`): with a grace of a few
  milliseconds, `.helperUnreachable` shows no banner at once and the helper banner after the grace; a
  change to `.connected` before the grace ends shows none; `openIterm()` calls the `launchIterm` port once
  (count with `ControllerCallCounter`).

## Proof

While iterating: `scripts/test.sh swift -- --filter "DaemonTypesTests|DaemonConnectionControllerTests|ItermSettingsTests|HarnessSettingsLayoutTests|ControllerStorageTests|SheetPreparationTests"`.
Then plain `scripts/test.sh` in the background.

Snapshots: `scripts/snapshots.sh build/refactor-3d`. Compare with `build/refactor-before`: only
`sidebar-banners.png` differs, and only in its connection banners (three `Notice`s, the not-running one
with an Open iTerm2 link, no grey line). Read it against `app/Sources/AiTermUI/README.md` for `Notice`.
Every other PNG, `settings-iterm-off.png` included, is equal.

## Done when

- `grep -rn "itermReconnecting\|DaemonBanner\|Reconnecting to iTerm2" app/ docs/*.md README.md` returns
  nothing.
- `grep -rn "Waiting for iTerm2" README.md docs/configuration.md docs/ai-install.md docs/daemon-protocol.md`
  returns nothing (the card's status string in `ItermConnection` keeps it).
- `grep -n "notRunning" app/Sources/AiTerm/DaemonConnection.swift` shows the report.
- Plain `scripts/test.sh` green; snapshots as above.

## Not in this step

- Ending a stale helper instead of adopting it, and the mismatch hold: 6b.
- The daemon's own iTerm2 launch at its start: daemon lane, left as is.
- The window docs: 3e. Syncing `docs/design/design-system.html` is done on request by the
  `design-system` skill, not here.
