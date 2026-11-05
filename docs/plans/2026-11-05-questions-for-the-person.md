# The person sees every open question in one place, and answers the one they mean

Plan F of the Operator snags (`2026-11-04-operator-snags.md`, area F). Branch
`chore/f-questions-for-the-person-pile-up-plan-and-desi`, built on the local main with B, C, A, D, E and G merged
(d4a69918).

**This plan ends at a pick.** It holds the three open questions of the snag log as options, with a recommendation
each, and the options are drawn on the Proposals tab of `docs/design/design-system.html` (section "Questions for the
person"). No Swift is written until the person picks. The Files, Proof and To-dos below are written for the
recommended picks (1B, 2B, 3B); a different pick changes them as each option says.

## Goal

Three snags from broadcast "Aikido findings 2026-11" (AiTerm 0.39.0):

- Several `ask_you` questions were open at once, mixed in with status reports in the Operator's chat. They scrolled
  out of sight, and answers got mixed up: nothing tied an answer to the question it answered.
- Questions about one task's scope (T2's access gate, T6's confirmation scope and copy, T7's chat reset, T4's token)
  all went into the chat, on no task. `ask_you` with a task also holds that task (not ready to accept, not watched for
  stalls), so the Operator avoided naming it, and the cards showed nothing.
- The Operator has no AskUserQuestion-style dialog. The person didn't experience `ask_you`'s "Waiting on you" as a
  dialog in the chat.

Rule: a question for the person is said once, in one place they can find again, with the task it is about, and their
answer reaches the question they meant. It fits the 2026-10-22 decision: the Operator's questions sit on its row as
`waiting on you`.

## What the code shows

- **ask_you** (`OperatorToolHandler.askYou`) records an `OperatorQuestion` (key, text, optional task, `about`). A task
  inserts `.waitingOnYou` on it, which keeps it out of `readyForAcceptance` and the stall watch until
  `resolve_question` removes the flag. The brief's rule (`OperatorCommand.questionRule`) says to name a task only when
  its worker is stopped on the answer or its fix rounds are used up, and to put "a scope choice" on no task. So the
  four scope questions were taskless by design: the hold is all-or-nothing.
- **Where a question shows.** `OperatorRequests.open` makes one `.question` request per open question: a
  notification each, and the Operator row's line (`BroadcastRow.operatorRow`): `waiting on you`, `waiting on you · T2`
  for one about a task, `waiting on you · 4 questions` for several, all texts joined in the tooltip. A card with a
  question opens the Operator's window (`BroadcastBoard.opens`), which is the chat, where the question has scrolled
  away. The board has no list of questions.
- **Answers.** The person types in the chat; the Operator decides which key the words answer and calls
  `resolve_question`. With four open, "yes, keep it" answers any of them.
- **One answer path in AiTerm already exists.** A `fixRounds` question is answered on its card (One More Round, Accept
  As It Is): `OperatorController.answerFixRounds` records `answeredOnCard` once, `run_status`'s `questionsWaiting`
  carries it, the Operator is woken and resolves the question. That is the AskUserQuestion-style shape, for one kind.
- **A worker's own question** (its turn ended on a question, `RunStatus.WorkerAsk`) makes the task row say `asking the
  Operator` and wakes the Operator. Its text shows nowhere in AiTerm.
- **Wake lines can't carry an answer.** The daemon refuses a wake line with a digit or a one-letter word
  (`delivery.wake_text_problem`, plan A), and a person's free text often has both. An answer given in AiTerm has to be
  recorded where `run_status` reads it, with a fixed wake line.
- **Claude Code's own AskUserQuestion** is not denied to the Operator (`OperatorCommand.shellDenials` filters it out),
  but the brief steers it to `ask_you`. A menu open in its window blocks its turn: it can't keep working on what
  doesn't depend on the answer, and every wake line waits behind the menu.

## Open questions for the person

### Q1. Can a question be put on a task's card without holding the task?

- **1A. No, as today.** A question on a task holds it, and scope questions stay on no task. Q3's list alone helps.
  Nothing in the tool, the brief or the hold changes.
- **1B. Yes, when the Operator says so (recommended).** `ask_you` gains an optional `holds` (boolean, default true,
  today's meaning). With a task and `holds: false`, the question shows on the task's card and in the list (Q3), and the
  task keeps its state, its acceptance and its stall watch: no `.waitingOnYou` flag. The brief's rule becomes: a
  question about a task goes on that task; it holds the task only when its worker is stopped on the answer or its fix
  rounds are used up (`about: fixRounds` always holds). The card's line stays the task's own (`Operator watching`);
  under its rule, as fix rounds' answers sit, the needs-you chip `question for you`, the question in `HelpText` and
  Answer… (to the list, 3B), the card edged as one that needs you: the question is the person's whether or not it
  holds. A holding question looks as today (`waiting on you` as the card's line). Why: the snag is that
  the hold scared the Operator off naming the task. A separate switch keeps every current call meaning what it means
  now, and saved questions decode as holding.
- **1C. Yes, always.** A question on a task never holds; only what AiTerm sees holds a task (a worker's prompt, a
  worker whose turn ended on a question, `fixRounds`). Fewer arguments, but a worker the Operator told "wait for the
  person" ends its turn without a question and reads as ready to accept, and every current call changes meaning.

### Q2. Should a worker's own question show on its card?

- **2A. No, as today.** The row says `asking the Operator`; the Operator reads the question and either answers it or
  relays it with `ask_you`.
- **2B. Yes, as the Operator's (recommended).** Under `asking the Operator`, the card shows the worker's question,
  two lines at most, in `Palette.muted`, the whole question in its tooltip. It is the Operator's to answer, so it never
  takes the person's colour and is not in the list. Once the Operator relays it with `ask_you` on the task, the card
  shows the relayed question as the person's (Q1, Q3). Why: the person sees what a worker is stuck on without being
  asked, and the Operator keeps its job.
- **2C. Yes, as the person's.** Every worker question is `waiting on you` on its card and in the list, answered in the
  worker's window. It skips the Operator, which then acts on answers it never saw; against "give the Operator its
  stuff".

### Q3. How does the person see the open questions and which one they're answering?

- **3A. In the chat, labelled.** The brief asks one question per reply, as `Question <key>: …`, and the person answers
  with the key. The Operator row's tooltip lists each open question by key. Cheap, but the chat still scrolls, and it
  is no dialog.
- **3B. A "Waiting on you" list on the board, each with its own answer (recommended).** The board sheet's Board tab
  opens with a block per open question of the broadcast, oldest first: the task it is about (its ticket key, or the
  title), the question, how long ago it was asked, and an answer. `ask_you` gains an optional `choices` (two to four
  short answers) drawn as links, as One More Round is, plus one text field for any other answer, with Send. An answer
  is recorded on its question once (`answeredHere`, the `answeredOnCard` path generalised), `run_status`'s
  `questionsWaiting` carries it, and the Operator is woken with a fixed reason through `OperatorWaker.say`
  ("You answered one question in AiTerm", typed as `[AiTerm] You answered one question in AiTerm, call run_status`:
  no digit and no one-letter word, as `wake_text_problem` and `OperatorWaker.isPlain` require). The block then says what you answered until the Operator resolves it. Answering in the chat still
  works. Clicking the Operator row while it says `waiting on you`, a question's notification, or a card's question
  opens the board at that block. AiTerm's own questions (`gate-`, `merged-on-host-`) are listed too but keep the chat
  as their answer, by the 2026-10-22 pick (trust over a button for allowing a command): their block says "Answer in
  the Operator's chat" and opens it. A worker's permission prompt stays its task row's, answered in its window.
- **3C. A dialog per question.** When a question is asked, a sheet opens over the sidebar with it, its choices and an
  Other field, `1 of 3` when several wait, AskUserQuestion's shape. It is the dialog the snag names, but it breaks
  into whatever the person is doing, and a sheet that exists for one thing is what the greenfield direction dropped.
  (Letting the Operator use Claude Code's own AskUserQuestion is not offered: it blocks the Operator's turn and every
  wake line behind it.)

## Decided without the person

- One plan for the three snags, the options left open; Files, Proof and To-dos written for 1B, 2B, 3B.
- `holds` defaults to true, so every current `ask_you` call and every saved question keeps its meaning.
- An answer given in AiTerm never travels in a wake line (plan A's rules): it is recorded on the question and read
  through `run_status`. The wake line is fixed and names no key.
- An answer in AiTerm is recorded once, like `answeredOnCard`: a second Send on the same question is refused with
  "Already answered: wait for the Operator, or answer again in its chat." It never resolves the question; the Operator
  does, as with an answer in its chat.
- The served schema change is deliberate: the `ask_you` entry of `daemon/tests/fixtures/operator-current-tools.json`
  gains `holds` and `choices` and is edited by hand for that entry only. The brief's question rule
  (`OperatorCommand.questionRule`, `askRules`, `askExamples`) changes on purpose, so the brief goldens
  (`brief-minimal.md`, `brief-all-on.md`, `brief-local-merge.md`, `eval-brief.md`) are edited by hand for those lines
  only, with this plan as the decision. `contract.json` and `state.json` stay untouched: absent `holds`, `choices`
  and `answeredHere` decode as now.
- Design: the list sits on the Board tab above the columns, not in a fourth tab (the 2026-10-21 sheet pick is Board ·
  Activity · Summary). Drawn from current tokens only: the block is a `groupChrome` group edged in
  `Palette.statusChipAttentionStroke`, as a card that needs you; the field is the kit's `Input`.

## Approach (for 1B, 2B, 3B)

1. **Hold is a choice.** `OperatorQuestion` gains `holds: Bool?` (nil = true), `choices: [String]?` and
   `answeredHere: String?`. `askYou` reads `holds` and `choices` (refused: `holds: false` with `about: fixRounds`; more
   than four choices; a choice over one line); it inserts `.waitingOnYou` only when the question holds.
   Two paths release the flag today, each once no open question on the task remains: `resolveQuestion` and
   `WorkerPrompts.resolvePrompt` (a worker's prompt answered in its window). Both read one new predicate,
   `OperatorRun.holds(task:)` (an open question on the task that holds it), so a non-holding question left open never
   keeps the flag after a prompt is answered. AiTerm's own questions (`prompt-`, `gate-`, `merged-on-host-`) always
   hold, as now.
   - **A task that finishes before its question is answered.** `OperatorRequests.open` silences every question on a
     finished task today, which was right while a question always held its task. A non-holding question stays open,
     listed and notified after its task finishes, until the Operator resolves or withdraws it: `silent` covers holding
     questions on a finished task and any question on a task you took over, as now. Stopping a task still resolves its
     questions (`OperatorController.stop`).
2. **The card says it.** `BroadcastBoard.Card` gains `question: CardQuestion?` (the oldest open `ask_you` question on
   the task: text, holds) and `workerAsks: String?` (2B). The card's view draws them under its rule.
   - **Where the worker's question comes from.** The board is built by `SidebarProjection.refresh` from state, sessions
     and `OperatorActs`, whose `turns` carries only `WorkerTurn.Ending`. `OperatorActs` gains `asks: [UUID: String]`,
     filled in `OperatorController.acting` from the same unmessaged `turns.readings` (and `extraReadings`) that set
     `.asks`, as `WorkerTurn.question(lastMessage)`: the first worker's, else the first asking tab's, with its key
     before it. `BroadcastBoard.make` reads it for `Card.workerAsks`, so it refreshes when `acting` does and clears
     when the reading is messaged or the turn moves on. Today `OperatorLine.task` makes any `.question` request on the task its line
   (`waiting on you`), and `BroadcastBoard.opens` sends it to the Operator's window. A `BroadcastRequest` gains
   `holds`: only a holding question becomes the line; a non-holding one makes the card need you (`Card.needsYou`, its
   edge) and adds the question part, with its line left as it was. The task's sidebar row keeps its own line too (the
   2026-10-22 rule: an Operator question is the Operator row's). A card's question opens the board's list block (3B),
   not the Operator's window.
3. **The list.** `BroadcastBoard` gains `questions: [ListedQuestion]` from `OperatorRequests.open`'s `.question`
   requests, joined to their `OperatorQuestion` (task label, age, choices, answered, AiTerm's own or not). The Board
   tab draws them above the columns. `OperatorController.answer(question:with:)` records `answeredHere` once and wakes
   the Operator with the fixed line; `run_status`'s `Question` gains `answeredHere` and `choices`.
   - **One answer per question, whatever the place.** A `fixRounds` question's block offers One More Round and Accept
     As It Is through the existing `answerFixRounds`, which writes `answeredOnCard`; it has no text field and never
     writes `answeredHere`. Both places read one `OperatorQuestion.answered` (`answeredOnCard ?? answeredHere`): once
     either is set, the card and the list both say what was answered and offer nothing more, and `answer` and
     `answerFixRounds` both refuse a second answer.
4. **Getting there.** The Operator row's click while `waiting on you` with an open question, a question
   notification's click, and a card's question open the board sheet scrolled to that block (`SheetCoordinator`).
   A question's notification today targets `.board(run.id)` (`OperatorNotifier`), serialised as the run's id alone,
   and `AppController.openNote` sets `OperatorController.presentBoard` to it. `OperatorNote.Target` gains
   `.question(run:key:)`, serialised with an `aiterm.question` key beside the run (an older notification without it
   still opens the board), and `openNote` sets `presentBoard` and the question to show; a question gone by the
   click opens the board at its top. A
   prompt in the Operator's own tab still opens its window.
5. **The brief and the tool text** say: ask in the chat as now, and also call `ask_you` with the task the question is
   about; `holds: false` unless the worker is stopped on it; `choices` when the answers are few and known. Read
   `answeredHere` in `questionsWaiting`, act on it, then resolve.

## Files

| File | Change | Why |
|---|---|---|
| `app/Sources/AiTermCore/Operators/OperatorModels.swift` | modify | `OperatorQuestion.holds`, `choices`, `answeredHere`; absent decodes as now |
| `app/Sources/AiTerm/Operators/OperatorToolHandler.swift` | modify | `askYou` reads `holds`/`choices`, flags only a holding question; `resolveQuestion` releases by `OperatorRun.holds(task:)`; `askAnswer`'s note says whether it holds |
| `app/Sources/AiTerm/Operators/WorkerPrompts.swift` | modify | `resolvePrompt` releases the flag by the same `OperatorRun.holds(task:)` |
| `app/Sources/AiTermCore/Operators/RunStatus.swift` | modify | `Question.answeredHere`, `choices`, `holds` |
| `app/Sources/AiTermCore/Operators/OperatorRequests.swift` | modify | a `.question` request carries `holds`, and what the list needs (or the list joins `run.questions`) |
| `app/Sources/AiTermCore/Sidebar/BroadcastBoard.swift` | modify | `Card.question`, `Card.workerAsks`, `questions` list, `opens` to the list |
| `app/Sources/AiTerm/Views/Operators/BroadcastBoardSheet.swift` | modify | the list above the columns; the card's question lines; scroll to a block |
| `app/Sources/AiTerm/Operators/OperatorController+Controls.swift` | modify | `answer(question:with:)`, as `answerFixRounds` |
| `app/Sources/AiTerm/AppController+Operators.swift`, `SheetCoordinator.swift` | modify | open the board at a question from the row and a card |
| `app/Sources/AiTerm/Operators/OperatorNotifier.swift`, `app/Sources/AiTerm/AppController.swift` (`openNote`), `OperatorController.swift` (`presentBoard`) | modify | a question's notification carries its key, and its click opens the board at that block |
| `app/Sources/AiTermCore/Sidebar/OperatorLine.swift` (`OperatorActs`), `OperatorController.swift` (`acting`), `app/Sources/AiTerm/SidebarProjection.swift` | modify | `OperatorActs.asks`: a worker's question text from the turn readings to the board |
| `app/Sources/AiTermCore/Operators/OperatorCommand.swift` | modify | the question rule, ask rules and examples |
| `daemon/aitermd/operator_mcp.py` | modify | `ask_you`'s `holds` and `choices`, and its description |
| `daemon/tests/fixtures/operator-current-tools.json` | modify (deliberate) | the `ask_you` entry only |
| `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-current/brief-*.md`, `eval-brief.md` | modify (deliberate) | the question rule lines only |
| `docs/operators.md` | modify | Ask you row: holds, choices, the list |
| `app/Sources/AiTermUI/README.md`, `docs/design/design-system.html` | modify | the list block and the card's question line, once built; the proposal removed |

## Proof

Tests first, with the broadcast's case as the fixture: T2, T4, T6, T7 each with a scope question, T6's worker
stopped on its own question.

1. `OperatorRecordToolsTests`: `ask_you` on T2 with `holds: false` leaves T2 ready to accept and watched; with no
   `holds`, T6 is held as now; `holds: false` with `about: fixRounds` and five choices are refused. Resolving T6's
   holding question while T6 has a non-holding one open releases T6. A worker prompt on T7 answered in its window,
   while a non-holding question on T7 is open, releases T7 too (`WorkerPrompts`, through its existing prompt tests).
2. `BroadcastBoardTests`: four open questions make four list blocks, oldest first, each naming its task; a non-holding
   question's card keeps `Operator watching` and adds `question for you`; T6's worker question shows muted under
   `asking the Operator`, and once relayed the card shows the relayed one. `OperatorProjectionTests`: a fake turn
   reading whose last message asks puts its question on T6's card through `OperatorController.acting` and
   `SidebarProjection`, and messaging T6 clears it. `OperatorRequestsTests`: T2's non-holding
   question stays a request after T2 is accepted and its end reached; a holding one on a finished task and any on a
   task you took over are silent, as now.
3. `TaskEndControlsTests` (where `answerFixRounds` is tested, fake daemon): answering T4's question records
   `answeredHere` once, wakes the Operator with the fixed line (which `wake_text_problem` accepts: a daemon test on the exact text), and a second answer is
   refused; `run_status` shows the answer under T4's key; the question stays open until `resolve_question`. A
   `fixRounds` question answered on its card is shown answered in the list and refuses an answer there, and the
   other way round.
4. `RunStatusTests`: `questionsWaiting` carries `holds`, `choices` and `answeredHere`.
4b. `OperatorNotifierTests`: T4's question notification carries its key and decodes back to `.question`; one
   without it decodes to `.board`. `BroadcastBoardSheetTests` (or the controller suite that covers `openNote`):
   opening that target presents the board at T4's block.
5. Daemon: `test_operator_mcp.py` against the hand-edited `ask_you` entry; `OperatorCommandTests` against the edited
   brief lines.
6. Snapshots: `scripts/snapshots.sh build/f-questions` draws the board with the list and the cards above; read the
   PNGs against `app/Sources/AiTermUI/README.md`.
7. Gate: `scripts/test.sh` before each commit, `scripts/test.sh all` once before merging.
8. Optional, on the person's go only: `scripts/run-dev.sh` and a two-task broadcast that asks two questions.

## To-dos (once the person has picked; for 1B, 2B, 3B)

- [ ] `holds`: model, `ask_you`, release on resolve, the tool's text and golden entry (test 1, 5)
- [ ] The card's question line and the worker's question (test 2)
- [ ] `choices` and `answeredHere`: model, `run_status`, the answer action and its wake line (tests 3, 4)
- [ ] The list on the Board tab and opening it at a question from the row, a notification and a card (test 2, 6)
- [ ] The brief's question rule, and its golden lines (test 5)
- [ ] `docs/operators.md`, the UI README and the design page synced; the proposal removed from the Proposals tab
