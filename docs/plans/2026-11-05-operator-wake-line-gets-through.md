# The Operator's wake line gets through

Plan A of the snags from broadcast "Aikido findings 2026-11" (`2026-11-04-operator-snags.md`, section A).
Branch `fix/a-the-operator-s-wake-line-doesn-t-get-through`, on top of B and C.

## Goal

Two snags. The person had to tell the Operator by hand each time, and it then called run_status itself.

1. **"AiTerm couldn't type the wake line"** (T7 workerAsks, T6/T10 finishedWithoutCommit). The Operator was
   in a turn answering the person. The wake should have waited for the turn to end, not been dropped.
2. **"Text may wait unsent in its input: send it there, or clear it with ⌃U"** (T8/T10 finished, T5
   reviewQuiet). The Operator was idle with an empty input, so the warning was false, and the wake should
   have been typed.

The person's decisions:
- A wake that can't be typed because the Operator is in a turn is held, and typed once the turn ends.
  It is never dropped.
- "Text may wait unsent" shows only when the input holds text. Find out from the screen why an idle,
  empty Claude Code input was read as maybe holding text. Reproduce it with a captured screen as the
  fixture. Fix the reading, not the Notice's words. Fixtures only; no live typing checks.

## What the code shows

**Case 1 is the line's wording, not the turn.** `OperatorWaker` already holds a wake while the
Operator's tab is `working` (`send` returns, and `operatorSessionChanged` sends it when the turn ends).
That part works. What fails is the line itself. Since actionable wake lines were added,
`OperatorWaker.actionReason` writes a worker's question as `<key> asks a question`. The daemon refuses
every wake line that carries a one-letter word (`delivery.wake_text_problem`: a menu opening as the line
lands could take `a` for its answer), so it answers `wakeText`. The Notice then reads "AiTerm couldn't
type the wake line".

Every retry sends the same line, and every retry is refused, so the wake is lost for good. Any line with
a worker's question in it is affected. That includes T6/T10's finishedWithoutCommit when it went in the
same line as T7's question: `… finished with no commit; … asks a question, call run_status`. The current
`OperatorWakerTests.aWorkerQuestionWakesTheOperatorNamingTheKind` expects exactly that line.
`RecordingDaemon` delivers any text, so nothing in the Swift suite caught it. Checked: `wake_text_problem`
refuses `[AiTerm] PAY-two asks a question, call run_status`.

The turn was a coincidence. The first try happens while the Operator is idle and is refused at once.
The person sees the Notice, answers the Operator, and the Operator's turn is running when they look.

**Case 2 is a guess from keys that no screen confirms.** The daemon's `unsentInput` comes from
`keystrokes.TypingGuard.has_unsent_input` alone. Any key since the last Return, ⌃C or ⌃U counts as text
left in the input. So does an input history the daemon doesn't know: before the first emptying key in a
session, and after every iTerm2 reconnect, since the keystroke epoch changes. The guard can't tell what a
key did, and Claude Code has many keys that type nothing into its input:
- Shift+Tab (mode), ⌃O (transcript) and ⌃T (todos);
- arrows and Tab;
- a digit or Esc answering one of its menus.

After any of these, an empty input stays "maybe holding text" until the person presses Return there, and
after a minute the Notice says so (`OperatorTiming.unsentWakeNotice`). The screen is never read for it.

The screen would mislead too, if read as plain text. A captured screen shows why. Claude Code 2.1.318
was started in a private pty with a scratch config, in a pre-trusted scratch folder, and no key was
typed. It drew its idle, empty input as:

    ────────────────…
    ❯\xa0ESC[2mTry "write a test for <filepath>"
    ────────────────…

That is a placeholder in dim (SGR 2), with neither rule dim. As text, the line reads
`❯ Try "write a test for <filepath>"`, the same as typed words. Its binary also shows:
- the renderer draws that placeholder dim, with the first character inverted when it draws its own
  cursor;
- the same empty input shows a prompt suggestion after a turn, on by default
  (`promptSuggestionEnabled`: "When absent or true, prompt suggestions are enabled").

Only the cell styles tell ghost text from typed text. iTerm2 already sends them:
`async_get_screen_contents` asks for styles, and `CellStyle.faint` and `.inverse` are in the pinned
iterm2 2.30. One thing is not checked: that iTerm2 reports SGR 2 as `faint`. That is what the API calls
it, and no live read was allowed.

## Approach

**Case 1. The line is always one the daemon accepts.**
- `actionReason` writes a question as `<key> asks something`, which is the wording `turnReasons` already
  uses.
- `send` checks the line it composed, after `boundedLine`, against `isPlain`. A line that isn't plain is
  replaced by the generic `[AiTerm] updates waiting, call run_status`. A wake can then never be refused
  for its own text and lost.
- The two plainness rules (Swift `isPlain`, Python `wake_text_problem`) are pinned by one shared table of
  lines, `daemon/tests/fixtures/wake-lines.json`, read by both suites. It includes the T7 line as it was
  (not plain) and as it is now (plain).
- The hold while the Operator works stays as it is. A test proves it with T7's question arriving
  mid-turn: nothing is typed during the turn, and one plain line goes when the turn ends.

**Case 2. When the keys say "maybe", the screen decides.**
- New port read `ItermPort.typed_screen(session_id)`. It returns one screen read twice over: the text
  `screen_text` returns, and the same lines with ghost text blanked. Ghost text is every faint cell, and
  an inverse cell directly before a faint one (the cursor drawn on a suggestion's first character).
- New pure rule `delivery.input_text(agent, screen, typed)`. It reads what Claude's ruled input frame
  holds, finding the frame in the plain text the way `_in_input_frame` does, so dim rules can't hide it.
  It returns:
  - `""` when the typed view shows nothing between the `❯` and the closing rule;
  - the text when it shows some;
  - `None` when there is no frame to read. That covers a transcript view, a prompt, an unrecognised
    screen, and any harness without Claude's ruled frame. The Operator always runs on Claude
    (`OperatorCommand`), so no wake goes to another harness.
- `Deliverer._check`: a wake line that `_ready` refuses as `unsentInput` reads `typed_screen`:
  - empty input: the guard records it (`TypingGuard.note_empty`) and the checks run again;
  - text in the input: the refusal stands, and is now true;
  - no frame: the screen's own refusal, from `_ineligible` (`prompt`, `unrecognisedScreen`,
    `screenUnread`), replaces `unsentInput`. The Notice then says what the tab shows. Example: ⌃O
    pressed, with the transcript view left open.

  A screen `_ineligible` accepts that still has no frame keeps `unsentInput`, since AiTerm can't tell
  what its input holds.
- `note_empty(session, read_at)` makes the session's input known and empty, unless a key arrived after
  `read_at`, the moment before the read: that key could have typed text after the read.
- The check before Enter (`_changed`) goes through the same `_check`. There the wake line just pasted
  is in the input, so the screen shows text and nothing changes there.
- **No keystroke monitor gets its own refusal, `keysUnwatched`.** Today `has_unsent_input` answers yes
  when iTerm2 gave no keystroke monitor, so the Notice claims text in the input that nobody saw. With no
  keys watched, AiTerm can't tell that you aren't typing, so it still refuses to type, as commit 8a7c999a
  decided, but it now says why:
  - `_ready` refuses a wake line with `keysUnwatched` while the guard has no live monitor
    (`TypingGuard.watching()`), before the unsent check;
  - the app's `DeliveryCode` gains `keysUnwatched`, and the Notice says "AiTerm can’t see your keys in
    iTerm2." without Fix in Settings, since Settings can't fix iTerm2's refusal;
  - an older app decodes the code as `.unknown` ("AiTerm couldn’t type into its tab").

  This is a new situation with its own words. The unsent Notice keeps its words.
- In the app, the unsent Notice's words and its one-minute hold stay, and the app still retries an
  `unsentInput` refusal. That Notice now shows only for text the screen shows in the input, or for
  input on a screen that can't be read.

## Files

| File | Change | Why |
|---|---|---|
| `app/Sources/AiTerm/Operators/OperatorWaker.swift` | modify | `asks something`; `send` falls back to the generic line when the composed one isn't plain |
| `daemon/aitermd/iterm_bridge.py` | modify | `TypedScreen`, `ItermPort.typed_screen`, the bridge's read, a pure `typed_line(line)` over iterm2's `LineContents` |
| `daemon/aitermd/delivery.py` | modify | `input_text`; `_check` reads the input on an `unsentInput` refusal of a wake line; the `keysUnwatched` refusal code |
| `daemon/aitermd/keystrokes.py` | modify | `TypingGuard.note_empty(session_id, read_at)`, `TypingGuard.watching()` |
| `app/Sources/AiTermCore/Daemon/DaemonTypes.swift` | modify | `DeliveryCode.keysUnwatched` |
| `app/Sources/AiTermCore/Operators/OperatorWakeNotice.swift` | modify | its sentence; no Fix in Settings for it |
| `daemon/tests/wire/manifest.json` | modify (deliberate, by hand) | `deliveryCodes` gains `keysUnwatched`, and nothing else changes. The wire contract is frozen (docs/testing.md); this entry changes because the person's rule says the unsent words may stand only for text in the input |
| `app/Tests/AiTermCoreTests/Operators/OperatorWakeNoticeTests.swift` | modify | the new code's Notice |
| `daemon/tests/fake_iterm.py` | modify | `typed_screens` (default: the screen itself) and `typed_screen` |
| `daemon/tests/fixtures/screens/claude-2.1.318-idle.json` | create | the captured screen: Claude Code 2.1.318 idle with its empty input and dim placeholder. Each line's text with its faint and inverse cell ranges, rendered from the raw capture, and its provenance (how it was captured; the scratch path replaced) |
| `daemon/tests/fixtures/wake-lines.json` | create | the shared plainness table |
| `daemon/tests/test_delivery.py` | modify | case 2 tests; two existing unsent tests move their text onto the screen |
| `daemon/tests/test_iterm_bridge.py` | modify | `typed_line` over the fixture's cells |
| `daemon/tests/test_keystrokes.py` | modify | `note_empty` |
| `app/Tests/AiTermTests/Operators/OperatorWakerTests.swift` | modify | case 1 test; the plainness table; the old `asks a question` expectations become `asks something` |
| `app/Tests/AiTermTests/Operators/WorkerTurnReaderTests.swift` | modify | its expected `PLUTO-one asks a question` line becomes `asks something` |
| `scripts/test-routes.tsv` | modify | `daemon/tests/fixtures/wake-lines.json` also routes to `AiTermTests.OperatorWakerTests`, which now reads it |

No served tool schema, brief, `contract.json` or `state.json` changes. Wake lines aren't part of the
frozen Operator contract. The one frozen file that changes is the wire manifest's `deliveryCodes`,
edited by hand as described above.

## Proof

Tests first. Each one fails before its fix.

1. **Case 1, Swift** (`OperatorWakerTests`, fixture T7 workerAsks, T6/T10 finishedWithoutCommit):
   - T7's question arrives while the Operator's tab is `working`: nothing is delivered;
   - the tab turns idle and `operatorSessionChanged` runs: exactly one line is delivered,
     `[AiTerm] letter-tee-seven asks something, call run_status`, and it is plain;
   - T6, T10 and T7 at once give one plain line naming all three.

   Today the line says `asks a question`, which isn't plain.
2. **Case 1, the guard** (Swift): when the composed line isn't plain, `send` types the generic line.
   This is driven through `say` with an action whose text the test makes not plain, if the API allows;
   otherwise through the pure line function `send` uses.
3. **Shared table**: `OperatorWakerTests` and `test_delivery.py` both read `wake-lines.json`, and each
   rule agrees with every row.
4. **Case 2, daemon** (`test_delivery.py`, the captured screen; the wake line is the one T8/T10 finished
   and T5 reviewQuiet bring):
   - the key history says "maybe": ⌃O pressed long ago, and an unknown history after an epoch change;
   - the screen shows the empty input with its dim placeholder;
   - so the wake line is delivered.

   Today it is refused `unsentInput`. The fixture read as plain text (`typed` = `text`) is not empty: that
   is why a plain screen read would also take the suggestion for typed text.
5. Case 2, its other sides:
   - text really typed (not faint) in the frame is still refused `unsentInput`;
   - a transcript view with uncertain keys is refused `unrecognisedScreen`, not `unsentInput`;
   - a prompt is refused `prompt`;
   - a key that arrives between the read and `note_empty` keeps the input unknown;
   - with no keystroke monitor, the wake is refused `keysUnwatched`, not `unsentInput` as today, and its
     Notice (`OperatorWakeNoticeTests`) says "AiTerm can’t see your keys in iTerm2." with no Fix in
     Settings.
6. `typed_line` (`test_iterm_bridge.py`): the fixture's cells give the typed line, with faint cells and
   the cursor on a faint cell blanked; plain cells, and an inverse cell not followed by a faint one, are
   kept.
7. `note_empty` (`test_keystrokes.py`).
8. Gate: `scripts/test.sh` before the commit, `scripts/test.sh all` once at the end. No live run: this
   broadcast runs inside the installed AiTerm.

## To-dos

- [x] Case 1: failing tests (1–3), then `asks something`, the plainness guard in `send`, the shared table and its route
- [x] Case 2: the fixture screen and failing tests (4–7), then `typed_screen`, `input_text`, `note_empty` and the `_check` change; the existing unsent tests move their text onto the screen
- [x] No monitor: `keysUnwatched` in the daemon, the app's code and Notice, and the wire manifest by hand
- [x] Gate, review, `scripts/test.sh all`, one commit

## Decided without the person

- **The screen is captured outside iTerm2.** Claude Code 2.1.318 ran in a private pty with a scratch
  config, the way `delivery_check` isolates it. Nothing was typed into it, and it was ended after 12 s.
  This is not a live typing check, and it doesn't touch iTerm2 or the installed AiTerm.
- **Not checked:** how iTerm2 turns those bytes into cells. A read through iTerm2's API from outside
  AiTerm could open a permission dialog nobody is there to answer. The fixture's cells come from the
  raw bytes, with SGR 2 taken as faint, as iTerm2's `CellStyle.faint` names it.
- **No prompt suggestion was captured.** That would need a turn. The placeholder is drawn by the same
  dim renderer, as the binary shows.
- **Case 1's cause is the wording, not the turn.** The turn needs no new mechanism: it already holds the
  wake, and a test now proves it.
- **The screen is only read for Claude's ruled frame.** The Operator always runs on Claude.
- **No keystroke monitor still means no wake, now with its own words** (`keysUnwatched`): "AiTerm can’t
  see your keys in iTerm2." Like every refusal but `unsentInput`, it shows at once.
- **Old test expectations change.** The expectations that encoded `asks a question` are a bug's output,
  not a frozen contract.
