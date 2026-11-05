# The person sees every question for them in one list, and answers the one they mean

Plan F of the Operator snags (`2026-11-04-operator-snags.md`, area F). Branch `feat/questions-for-the-person`, built on
the local main with B, C, A, D, E and G merged, and the broadcast fix v1 after them (23e719e2). This rewrite replaces the earlier three-option plan
(1B, 2B, 3B). The drawings are in the "Questions for the person" section of the Proposals tab in
`docs/design/design-system.html`, with every pick marked.

## Goal

Four snags from broadcast "Aikido findings 2026-11" (AiTerm 0.39.0):

- **The chat is the only place a question lives.** Several `ask_you` questions were open at once among status
  reports. They scrolled away, and the board has no list of them.
- **Answers aren't tied to questions.** The person types free text and the Operator guesses which key it answers. Only
  `fixRounds` has an answer addressed to its question (`answeredOnCard`).
- **"About a task" and "holds the task" are one bit.** A question on a task always holds it, so the brief keeps scope
  questions (T2's access gate, T6's confirmation scope, T7's chat reset, T4's token) off their tasks, and the cards
  show nothing.
- **A worker's question is a reading with no record** (`RunStatus.WorkerAsk`). When the Operator relays it with
  `ask_you`, that makes a second question with no link to the first.

The rule: every question for the person is one record, whoever asks. It is listed once, where they can find it again,
on the task it is about, and their answer reaches the question they meant. `OperatorQuestion` already holds all four
kinds of question, told apart by key prefix (`ask_you`'s, `prompt-`, `gate-`, `merged-on-host-`). This plan makes that
explicit and brings worker questions in. It adds no new store.

## Decided with the person

- **The record.** One question holds: who asks (the Operator; a worker, relayed by the Operator; or AiTerm), who
  answers, its optional task, whether it holds, optional choices (two to four), its answer channel, one answer, and its
  addressing history.
- **Holds** defaults to true, today's meaning. The Operator may set it false, and `fixRounds` always holds. A holding
  question makes its task's row `waiting on you`; otherwise a task row keeps its own line (22 Oct rule).
- **A. The pointer.** The question lives in the list only. The Operator's chat gets one pointer line ("Asked you in
  AiTerm: PAY-232's access gate for admins."). Typing the answer in the chat still works.
- **B2. A worker's question.**
  - It belongs to the Operator: it is shown muted on its card, two lines at most, under `asking the Operator`.
  - It becomes a record only when the Operator relays it. The record carries the worker's own words, so it is the same
    question, never a second one.
  - AiTerm's scan of the worker's last message only labels and wakes. It never opens or closes a record.
- **C2. The Oracle vets a relay.** How strictly is a per-broadcast setting on the Done step: straight to you,
  challenged once (the default), or agreed first.
  - Agreed first runs rounds until no major or important point is left, at most three. After three it reaches the
    person with both sides.
  - An Oracle that can't answer lets the question through (fail-open).
  - The Operator's own questions and AiTerm's are never vetted.
- **Copy 2** names the Done step's fields: **Goal rounds**, and **Worker questions** with *Straight to you*,
  *Challenged once* and *Agreed first*.
- **D1a. One "Waiting on you" list, above the columns on the Board tab.**
  - It is ordered oldest first, and the board scrolls as one.
  - Each block has one notification shape and one answered state.
  - A click on the Operator row, a notification or a card's question opens the board at that block.
- **Two answer shapes.**
  - **Answer here:** the question, its choices as links, any other answer in a field, and Send. This covers the
    Operator's questions, relayed questions, `fixRounds` (fixed choices, no field) and a merge on the host (no
    choices).
  - **Answer there:** one link. A permission prompt has "Open its window", since AiTerm never types a permission. A
    command the Oracle stopped has "Open the Operator's chat" (22 Oct, trust over a button).
- **E1. Order of work.**
  1. The record and its hold.
  2. The list.
  3. Worker questions, with the scan hardened (H1–H3) in slice 3.

  Each slice is one commit, tested first, with the gate green.
- **Migration.** Saved questions migrate as holding and addressed to the person.

## The record, made explicit

| Field | In `OperatorQuestion` | Saved as |
|---|---|---|
| who asks | `asker`, computed: AiTerm by key prefix (`aitermPrefixes`), a worker when `relayedFrom` is set, else the Operator | nothing new |
| who answers | always the person: a worker's question addressed to the Operator is not a record (B2), only a reading on its card | nothing |
| task | `task`, as now | as now |
| holds | `holds: Bool?`, nil meaning true; `holdsTask` computed (`fixRounds` and AiTerm's own always true) | written only when false |
| choices | `choices: [String]?` | written only when given |
| answer channel | `channel`, computed: *there* for `prompt-` (its window) and `gate-` (the Operator's chat), *here* for the rest | nothing |
| one answer | `answeredHere: String?` with `answeredHereAt: Date?`; `fixRounds` keeps `answeredOnCard`; `answer`, computed, is the one given, whichever place | new fields written once |
| history | `relayedFrom: String?` (the worker tab's key, `WorkerTab.firstKey` for the first worker) and `history: [QuestionStep]?` (relayed, each Oracle round, each reply, unchallenged and why) | written only for a relay |

Why "who answers" is not stored: by B2 a record exists only once a question is addressed to the person. A worker's
question addressed to the Operator stays the reading it is today. The user's model allowed for a record addressed to
the Operator; B2 turned that into the card's muted line, so nothing on disk names an addressee.

## The four paths, today and in the model

| Path today | Asker | Channel | What changes |
|---|---|---|---|
| `ask_you`, an `OperatorQuestion` with the Operator's key (`about: fixRounds` among them) | the Operator | here | `holds` and `choices` on the tool; answered in its block (`answeredHere`), or for `fixRounds` through `answerFixRounds` (`answeredOnCard`) from the block or the card; listed; never vetted |
| A worker's question: `WorkerTurnReader`'s reading, `RunStatus.WorkerAsk`, the row `asking the Operator`, the wake line "one worker asks something" | a worker | none until relayed | its card shows it, muted. `relay_question` makes the record from the reading: the worker's words, `relayedFrom`, `history`, holding by default. Vetted per C2 |
| `prompt-<task>-<n>`: a worker's permission or unknown prompt (`WorkerPrompts`) | AiTerm | there (its window) | listed with "Open its window"; still opened and closed by AiTerm alone. Its notification opens its block |
| `gate-<n>` (a command the Oracle stopped) and `merged-on-host-<task>` | AiTerm | `gate-` there (the Operator's chat); `merged-on-host-` here (free text, no choices) | listed. A merge on the host is answered in its block and still can't be withdrawn. A gate is still answered in the chat with `allow` |

## Approach

### Slice 1: the record and its hold

- **Model.** Add the `OperatorQuestion` fields above, all optional, with `asker`, `channel`, `holdsTask` and `answer`
  computed. Absent fields decode as today's meaning.
- **`ask_you`.** It gains `holds` (boolean, default true) and `choices` (two to four, each one line of 60 characters at
  most).
  - Refused: `holds: false` without a task; `holds: false` with `about: fixRounds`; fewer than two or more than four
    choices; a choice over one line or the limit; choices with `about: fixRounds`, whose choices are fixed.
  - It inserts `.waitingOnYou` only for a question that holds its task.
  - The answer's `note` says where the person sees it and whether the task waits.
- **Release by one predicate.** `OperatorRun.holds(task:)` is true when the task has an open question that holds it.
  The three places that remove `.waitingOnYou` after a question closes use it: `resolveQuestion`,
  `WorkerPrompts.resolvePrompt`, and the gate and merge paths that close through `resolveQuestion`. So a non-holding
  question left open never keeps the flag, and a holding one never loses it while another question closes.
- **Requests.** `BroadcastRequest` gains `holds` and the question's key on a permission request (taken from the
  recorded `prompt-` question).
  - `OperatorRequests.open` silences a question on a finished task only when it holds. A non-holding question asks
    until the Operator resolves or withdraws it.
  - A task you took over still silences every question. Stopping a task still resolves its questions.
- **Lines and cards.**
  - `OperatorLine.task` takes only a holding question as its line.
  - `BroadcastBoard.Card` gains `question: CardQuestion?`: the oldest open question addressed to the person about the
    task, with its text, holds, asker and answered. The card draws it under its rule. A holding question keeps the
    card's line `waiting on you`. A non-holding one adds the needs-you chip `question for you`, keeps the card's own
    line, and edges the card as one that needs you.
  - Until slice 2 the card's question link opens the Operator's window, as `opens` does now.
- **Brief.** `OperatorCommand.questionRule` and `askExamples` say: a question about a task goes on that task; it holds
  only when the task can't go on without the answer; give `choices` when the answers are few and known. The Operator
  still asks in its chat as today, because the list that replaces the chat comes in slice 2.

### Slice 2: the Waiting on you list (D1a)

- **The board.** `BroadcastBoard` gains `waiting: [ListedQuestion]`, read from `run.questions` itself: every open
  question, under the same silencing rules as `OperatorRequests.open`. It is not built from the requests, because
  `open` folds a task's permission prompts into one (the first by tab order), while `WorkerPrompts` records one
  `prompt-` question per asking tab. So two tabs prompting on one task make two blocks, each naming its tab. Each
  entry has its key, task label (ticket and title, or "The broadcast"), tab, age, asker line, question, choices,
  channel and answer.
  - It is ordered oldest first by `askedAt`, with a permission prompt by when its question was recorded.
  - `BroadcastBoardSheet`'s Board tab draws it above the columns: a header "Waiting on you" with its count, then one
    block each, drawn as on the proposal.
  - A block is a `groupChrome` group edged in `Palette.statusChipAttentionStroke`. Choices are links. The field is the
    kit's `Input` with Send, enabled once the field holds text, ⌘↩ sending.
  - An answered block takes the hairline edge and says "You answered "…" 2 min ago. Waiting for the Operator to take
    it." until the Operator resolves the question and it leaves.
- **Answering here.** `OperatorController.answer(question:with:)` mirrors `answerFixRounds`.
  - It records `answeredHere` and `answeredHereAt` once. A second answer is refused ("Already answered: wait for the
    Operator, or answer again in its chat.").
  - It wakes the Operator through `OperatorWaker.say` with a fixed reason. For a question on a task, the reason is
    "the person answered letter-tee-two's question in AiTerm", with the key spoken by `OperatorWaker.taskReference`,
    as main's wake lines name tasks. For a question on no task, it is "the person answered one question in AiTerm".
    Neither reason has a digit or a one-letter word, so both pass `isPlain` and `wake_text_problem`. The answer itself
    never travels in the line.
  - It never resolves the question. A `fixRounds` block calls `answerFixRounds` (`answeredOnCard`), and both read
    `answer`, so an answer on the card shows in the list and the other way round.
  - Refused: an answer on a task you took over, a holding question on a finished task (it is silent and not listed),
    and an AiTerm question answered there. A non-holding question on a finished task stays listed (slice 1), so it can
    still be answered here, until the Operator resolves or withdraws it.
- **`run_status`.** `RunStatus.Question` gains:
  - `answeredHere`: what the person answered in AiTerm;
  - `choices`;
  - `holds: false` when it doesn't hold;
  - `asker: "worker"` and `tab` for a relayed question.

  Each is written only when it is not the default, so today's lines are byte-for-byte the same.
- **Getting there.**
  - `OperatorNote.Target` gains `.question(run:key:)`, saved as `aiterm.question` beside `aiterm.overview`. An older
    notification without it still opens the board.
  - `OperatorNotifier` posts one shape for every request addressed to the person: "The Operator asks: …", "PAY-236's
    worker asks: …", or "AiTerm asks: …"; a permission keeps its sentence. Each targets its block. A task's permission
    notification stays one per task, as today (its id `request-<run>-<task>-permission`), and opens the block of the
    tab it names.
  - `AppController.openNote` sets `presentBoard` and the question to show. The sheet opens on the Board tab, scrolled
    to that block. A question gone by the click opens the board at its top.
  - The Operator row's click while its line says `waiting on you` opens the board at the oldest block. A prompt in the
    Operator's own tab still opens its window, since it is not a record.
  - A card's question link opens the board at its block.
- **Answer there.** A permission block's "Open its window" raises its own tab, by the block's tab key, through a
  `choose(task:tab:)` beside `choose(task:)`, which today picks the first requesting tab. A gate block's "Open the
  Operator's chat" opens the Operator's window.
- **Brief (A).** Now that the list exists, `questionRule`, `askRules` and `askExamples` say: ask with `ask_you`, not in
  the chat, and in the reply write one line, "Asked you in AiTerm: …". "When run_status shows `answeredHere`, act on
  it, then `resolve_question` with it." Gate questions keep their chat rule. The `resolve_question` description says
  the same.

### Slice 3: worker questions

- **The card's muted line (B2).** `OperatorActs` gains `asks: [UUID: String]`, filled in `OperatorController.acting`
  from the same unmessaged readings (`turns.readings`, `extraReadings`) that set `.asks`, as
  `WorkerTurn.question(lastMessage)`: the first worker's, else the first asking tab's, with its key before it.
  - `BroadcastBoard.make` reads it for `Card.workerAsks`, drawn under `asking the Operator`: muted, two lines, the
    whole text in its tooltip, with no link.
  - It clears when the reading is messaged or a new turn starts. Once the question is relayed, the card shows the
    record instead ("From its worker:").
- **`relay_question(key, task, tab?, holds?, choices?, challengeId?, challengeReply?)`.** It is a new tool, not an
  argument of `ask_you`. Why: it takes no question text, since AiTerm takes the worker's words; it is vetted while
  `ask_you` never is; and its refusals are its own.
  - **The text** is `WorkerTurn.question` of the named worker's last message, read now. The tab key defaults to the
    first worker.
  - **Refused:**
    - the worker is at work;
    - its turn's reading was already messaged ("PAY-236's worker has moved on since it asked: answer with
      message_task");
    - there is no reading;
    - the task was taken over or has finished;
    - the Operator names a key in AiTerm's namespaces.

    The scan's verdict is not a condition: a turn the scan missed can still be relayed (H2).
  - **One record per worker question.** The same key returns the open record. Another key for the same worker turn
    (same task, tab and text, still open) returns that record too.
  - **Holds** by default, like any question, so a relayed question keeps the task out of ready even when the scan
    missed it (H2).
  - **History.** It records `relayedFrom`, the steps, and the reading's last message in full, which the block's "Read
    the discussion" shows.
- **The Oracle, as the broadcast says (C2).** `OperatorRun.relayCheck: RelayCheck?` (`straight`, `challengeOnce`,
  `agreeFirst`), with nil meaning `challengeOnce`. With the Oracle off, a relay goes straight. The relay's own handler
  (`OperatorToolHandler+Relay.swift`) reuses `ChallengeRecord`, `runner.challenge`, `ports.challengeReplyBudget` and
  the pending answers.
  - **The prompt** is `ChallengeLaunch.relayPrompt`: the worker's question and last message, the task's brief, the
    broadcast's prompt and plan, and its decisions. The Oracle reads the worktree read-only. Its answer ends in a
    verdict line, `relay` (only the person can answer) or `answer` (the Operator can answer itself), with each point
    marked major, important or minor.
  - **`challengeOnce`.**
    - `relay`: the record is made at once.
    - `answer`: the critique comes back with a `challengeId`. The Operator either answers the worker with
      `message_task` and doesn't call again, or calls again with the `challengeId` and a `challengeReply`, and the
      record is made with both sides in its history.
  - **`agreeFirst`.**
    - A call again with a reply runs another Oracle round, with the discussion so far in its prompt. The record keeps
      its round (`ChallengeRecord.round`).
    - The record is made once the Oracle says `relay`, or once the Oracle answers with no major or important point
      left.
    - After the third round still apart, it is made with both sides.
  - **Fail-open.** An Oracle missing, failed, too slow, or lost with AiTerm's restart leaves the relay unchallenged.
    The record is made, and its history says why.
- **The Done step (copy 2).**
  - `Extra rounds` becomes **Goal rounds**, help "Times the Operator may plan more work when the goal isn't met once
    every task is done."
  - New **Worker questions**, a select with *Straight to you*, *Challenged once* (the default for each new broadcast,
    as Goal rounds starts at 2) and *Agreed first*. Help: "How hard the Oracle checks a worker's question before the
    Operator passes it on to you."
  - With the Oracle off, both fields are dimmed, Worker questions reads *Straight to you*, and the goal's help says:
    "The Oracle is off in Settings › Operator, and a goal needs it: the broadcast ends when its tasks do, and a
    worker's question the Operator passes on reaches you straight away."
  - The value goes through `NewBroadcastModel.Request` to `OperatorRun.relayCheck`. The brief's `Extra rounds: 2` line
    stays as it is: the label is the person's, the brief line the Operator's.
- **The scan hardened (H1–H3).**
  - **H1.** `WorkerStarter.worktreeLine` gains one sentence: "When you stop to ask, end your last message with a
    paragraph starting Question:, its choices under it, and nothing after them." The marker becomes a contract with
    the worker, as the review verdict block is.
  - **H2.** A relayed question holds its task whatever the scan said, and `message_task` already clears a false hit.
  - **H3.** One shared table of last messages pins the rules, as the wake lines' table does:
    - marked, with choices under the marker;
    - unmarked, like "Want me to update the tests too?";
    - a status report quoting "Question:";
    - a scope stop with "May I…?".

    `WorkerTurnTests` and `RunStatusTests` both read it.
- **Brief.** "A worker's question is yours first. Answer it with message_task when the brief, the plan or the code
  answers it. Relay it with relay_question only when the person must decide; never ask_you with a worker's words."
  The `PAY-14` example becomes a `relay_question` one.

## Migration

- Every saved `OperatorQuestion` decodes with `holds`, `choices`, `answeredHere`, `answeredHereAt`, `relayedFrom` and
  `history` absent. That means it holds, has no choices, is unanswered here, and was asked by the Operator, or by
  AiTerm by its prefix.
- So every open question in a saved broadcast is addressed to the person and still holds its task, exactly as before.
  `OperatorRun.relayCheck` absent means `challengeOnce`.
- Nothing is rewritten on load. A field is written only when it differs from the default, so a saved state that never
  uses them writes back the same bytes.

## The tools and `run_status`

- **`ask_you`.**
  - Slice 1: new `holds` (boolean): "False when the task can go on without the answer: the question shows on its card,
    and the task stays ready to accept and watched. Left out, it holds." New `choices` (array of two to four strings).
    The `task` description changes to: "the task the question is about".
  - Slice 2: the description changes: the person sees the question under Waiting on you in AiTerm and answers there
    or in this chat, and the chat gets one pointer line. `holds` adds "and in the list".
- **`relay_question`** (new, after `ask_you`): key, task, tab, holds, choices, plus `challengeId` and `challengeReply`
  from `_CHALLENGE`.
- **`resolve_question`.** Its description adds: "answeredHere is the person's answer in AiTerm: act on it, then
  resolve with it."
- **`run_status`.** `questionsWaiting[]` gains `answeredHere`, `choices`, `holds` (only when false), and `asker` and
  `tab` (only for a relayed question). `workerAsks` is unchanged: a worker's question addressed to the Operator stays
  there until it is relayed or answered.

## Frozen contracts

Nothing is regenerated. Each entry below is edited by hand, with this plan and the snag log as the decision and
evidence (`docs/testing.md`).

- **`daemon/tests/fixtures/operator-current-tools.json`:**
  - the `ask_you` entry (description, `task`, `holds`, `choices`);
  - the `resolve_question` entry (description);
  - a new `relay_question` entry after `ask_you`.

  That makes 37 schemas. `docs/testing.md`'s count follows.
- **`brief-minimal.md`, `brief-all-on.md`, `brief-local-merge.md`, `eval-brief.md`:** only the question rule,
  ask-rule and example lines, in slices 1 to 3.
- **`app/Tests/AiTermTests/Fixtures/operator-current/contract.json`:** only the `"question"` entry's `note`, which
  says where the person answers and that the task waits. Its `questionsWaiting` entries stay byte-for-byte, because the
  new fields are omitted at their defaults.
- **`state.json`:** untouched. A new test checks that it decodes, and that re-encoding it adds none of the new keys
  (`holds`, `choices`, `answeredHere`, `answeredHereAt`, `relayedFrom`, `history`, `relayCheck`, `round`).
  `OperatorCurrentContractTests` checks only selected properties and the journey's replies, not the re-encoding.
- **`daemon/tests/wire/`:** untouched. No daemon wire message changes; the wake line is an existing call.
- **`daemon/tests/fixtures/wake-lines.json`** is a shared table, not a golden: it gains the two answer lines.
- **`worktreeLine`** is in no frozen fixture. `WorkerStarterTests`, `WorkerLaunchTests`, `OperatorOpenTabTests` and
  `OperatorVerdictTests` build their expected prompt from `WorkerStarter.worktreeLine` itself, so H1 changes no golden.
  The new sentence gets its own assertion.

## Decided without the person

- **`relay_question` is its own tool**, for the reasons above, rather than an argument of `ask_you`.
- **Who answers is not stored.** It follows from B2; see the record table.
- **A relay doesn't need the scan's yes** (H2): the Operator reads turns the scan misses.
- **A permission prompt's notification opens its block**, as the person's rule says for every notification, and the
  block's one link opens its window: one click more than today.
- **The Oracle's `relay` verdict on the first round makes the record at once**, at every strength, so a question the
  Oracle agrees only the person can answer doesn't wait on a round trip.
- **`fixRounds` keeps `answeredOnCard`**, so its challenge path (the person's word on fix rounds standing against the
  verdicts) reads it unchanged.
- **The relay setting resets to Challenged once for each new broadcast**, as Goal rounds resets to 2. Nothing carries
  over between broadcasts today.
- **The Operator's own prompt** (its permission prompt) stays out of the list: it is not a record, and its row already
  opens its window.

## Files

| File | Change | Why |
|---|---|---|
| `app/Sources/AiTermCore/Operators/OperatorModels.swift` | modify | `OperatorQuestion` fields and computed `asker`, `channel`, `holdsTask`, `answer`; `QuestionStep`; `OperatorRun.relayCheck`, `holds(task:)`; `RelayCheck`; `ChallengeRecord.round` |
| `app/Sources/AiTerm/Operators/OperatorToolHandler.swift` | modify | `askYou` with `holds` and `choices`; release by `holds(task:)`; `askAnswer`'s note; dispatch `relay_question` |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Relay.swift` | create | `relay_question`: the reading, refusals, the Oracle by strength, the record and its history |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Challenge.swift` | modify | share the runner, budget and pending answers with the relay's rounds |
| `app/Sources/AiTermCore/Operators/ChallengeLaunch.swift` | modify | `relayPrompt` and its verdict |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Gate.swift`, `WorkerPrompts.swift`, `OperatorController.swift` (merge on host) | modify | the flag set and released through `holds(task:)` |
| `app/Sources/AiTermCore/Operators/OperatorTool.swift` | modify | `relayQuestion` |
| `app/Sources/AiTermCore/Operators/RunStatus.swift` | modify | `Question.answeredHere`, `choices`, `holds`, `asker`, `tab` |
| `app/Sources/AiTermCore/Operators/OperatorRequests.swift` | modify | `holds`; a permission's key; finished tasks silence only holding questions |
| `app/Sources/AiTermCore/Sidebar/OperatorLine.swift` | modify | only a holding question is a task's line; `OperatorActs.asks` |
| `app/Sources/AiTermCore/Sidebar/BroadcastBoard.swift` | modify | `Card.question`, `Card.workerAsks`, `waiting`, `opens` to a block |
| `app/Sources/AiTerm/Views/Operators/BroadcastBoardSheet.swift` (and a new `WaitingOnYouList.swift` beside it) | modify, create | the list above the columns, its blocks, scroll to a block; the card's question lines |
| `app/Sources/AiTerm/Operators/OperatorController+Controls.swift` | modify | `answer(question:with:)` |
| `app/Sources/AiTerm/Operators/OperatorController.swift` | modify | `acting` fills `asks`; `presentBoard` with a question |
| `app/Sources/AiTerm/SidebarProjection.swift` | modify | `asks` to the board |
| `app/Sources/AiTerm/Operators/OperatorNotifier.swift`, `AppController.swift`, `AppController+Operators.swift`, `SheetCoordinator.swift` | modify | `.question(run:key:)`, one notification shape, the Operator row and card open the block |
| `app/Sources/AiTerm/Operators/WorkerStarter.swift` | modify | H1's sentence in `worktreeLine` |
| `app/Sources/AiTerm/Operators/NewBroadcastModel.swift`, `app/Sources/AiTerm/Views/Operators/DoneStep.swift` | modify | Goal rounds, Worker questions, the Oracle-off help; `Request.relayCheck` |
| `app/Sources/AiTermCore/Operators/OperatorCommand.swift` | modify | the question rule, ask rules and examples |
| `app/Sources/AiTermCore/Operators/ActivityLine.swift` | modify | the Activity tab's line for `relay_question` |
| `daemon/aitermd/operator_mcp.py` | modify | `ask_you`, `resolve_question`, `relay_question` |
| `daemon/tests/fixtures/operator-current-tools.json` | modify (deliberate) | the three entries above |
| `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-current/brief-*.md`, `eval-brief.md` | modify (deliberate) | the question lines only |
| `app/Tests/AiTermTests/Fixtures/operator-current/contract.json` | modify (deliberate) | the `"question"` entry's note |
| `app/Tests/AiTermCoreTests/Operators/Fixtures/worker-last-messages.json` | create | H3's shared table |
| `app/Sources/AiTerm/Snapshots/OperatorSnapshots.swift` | modify | the board with the list, the cards, the Done step |
| `docs/operators.md`, `docs/testing.md` | modify | Ask you, relay, the list; 37 schemas |
| `app/Sources/AiTermUI/README.md`, `docs/design/design-system.html` | modify | the list block, the card's question lines and the Done step once built; the proposal removed from the Proposals tab |

## Proof

Each test is written first and fails before its change. The fixture is the broadcast's case:

- **T2:** the Operator asks about the access gate on the export page, on T2, with `holds: false` and two choices.
- **T4:** the Operator asks for T4's token. Its worker is stopped on it, so the question holds.
- **T6:** its worker's turn ends on "Question: Should the confirmation cover bulk deletes too, or single deletes
  only?".
- **T7:** the Operator asks whether the chat reset keeps drafts, on T7, with `holds: false` and no choices. The person
  answers it in the chat.

### Slice 1

1. `OperatorRecordToolsTests`:
   - T2 with `holds: false` stays ready to accept and watched for stalls; T4 is held as today.
   - Refused: `holds: false` with no task, `holds: false` with `fixRounds`, one choice, five choices, choices with
     `fixRounds`, and a choice over one line.
   - Resolving T4 while T4 has a non-holding question open releases T4.
   - A worker prompt on T7 answered in its window releases T7 while T7's non-holding question stays open (through the
     existing `WorkerPrompts` tests).
2. `OperatorRequestsTests`: T2's non-holding question still asks after T2 is accepted. A holding one on a finished task,
   and any question on a task you took over, are silent as today.
3. `OperatorLineTests` and `BroadcastBoardTests`:
   - T2's card keeps its line and adds `question for you`, and T2's row keeps its line.
   - T4's card and row say `waiting on you`.
4. Migration (`OperatorModelsTests`): a saved open question with none of the new fields decodes as
   holding, asked by the Operator, unanswered, and re-encodes with no new key. The frozen `state.json` decodes, and
   re-encoded it carries none of the new keys on its run, questions or challenges.
5. `OperatorCommandTests` against the hand-edited brief lines; `test_operator_mcp.py` against the hand-edited `ask_you`
   entry.

### Slice 2

6. `BroadcastBoardTests`:
   - T2, T4, T7 and a `prompt-` question on T6 make four blocks, oldest first, each with its task, asker line and
     channel.
   - A `gate-` block offers only the chat; a `merged-on-host-` block takes free text.
   - Two tabs of T6 prompting at once make two blocks, each naming its tab, and each "Open its window" raises its own
     tab.
   - T2's non-holding question, after T2 is accepted as a commit-only task, is still listed and can be answered.
7. `TaskEndControlsTests` (fake daemon):
   - Answering T2 with "Drop it for admins" records `answeredHere` once.
   - It wakes the Operator with the exact fixed line. Both lines (on a task, and on no task) are added to the shared
     `daemon/tests/fixtures/wake-lines.json` as plain, so the daemon's `wake_text_problem` and `OperatorWakerTests`'
     `isPlain` read the same rows.
   - A second answer is refused, and the question stays open until `resolve_question`.
   - A `fixRounds` question answered on its card shows answered in the list and refuses an answer there, and the other
     way round.
8. `RunStatusTests`: `questionsWaiting` carries `answeredHere`, `choices` and `holds: false`. A question with only
   today's fields encodes as today. `OperatorCurrentContractTests` checks the `waiting-for-person` entry unchanged.
9. `OperatorNotifierTests`:
   - T2's notification says "The Operator asks: …", carries `aiterm.question`, and decodes back to `.question`.
   - One without the key decodes to `.board`.
   - The controller suite that covers `openNote` shows the board presented at T2's block. A question resolved before
     the click opens the board at its top.

### Slice 3

10. `OperatorProjectionTests`: a fake reading whose last message is T6's question puts it on T6's card through `acting`
    and `SidebarProjection`. `message_task` to T6 clears it.
11. `OperatorRelayTests` (new; fake runner, the Oracle's verdicts scripted):
    - **Straight:** the record is made at once, with T6's words, `relayedFrom: main`, T6 held, and the card showing it
      "From its worker:".
    - **Challenged once:**
      - `relay` makes the record at once.
      - `answer` returns a critique and makes no record; the call again with a reply makes it, with both sides in its
        history.
    - **Agreed first:**
      - A second round runs with the reply in its prompt.
      - A round with only minor points makes the record.
      - Three rounds still apart make the record with both sides.
    - **Fail-open:** a failed, slow, or restarted Oracle makes the record unchallenged, with why. The Oracle off goes
      straight.
    - **Refused:** a worker at work; a messaged reading; no reading; a taken-over or finished task.
    - The same key, or another key for the same turn, returns the one record.
    - A turn the scan doesn't call a question (unmarked) can be relayed, and it then holds T6 out of ready (H2).
12. `WorkerTurnTests` and `RunStatusTests` read `worker-last-messages.json` (H3): marked counts; quoting a status report
    doesn't count; the scope-stop cases as today. `WorkerStarterTests` asserts H1's sentence.
13. `NewBroadcastModelTests`:
    - The labels are Goal rounds and Worker questions, the help texts are as above, and the default is Challenged
      once.
    - With the Oracle off, Worker questions reads Straight to you, and the goal's help is the new one.
    - Start carries `relayCheck` to the run.
14. `test_operator_mcp.py` against the new `relay_question` entry and the 37 schemas.

### Every slice

15. Snapshots: `scripts/snapshots.sh build/f-questions` draws the board with the list, the four cards, the sidebar rows
    and the Done step. Read the PNGs against `app/Sources/AiTermUI/README.md` and the proposal.
16. Gate: `scripts/test.sh` in the background before each slice's commit, and `scripts/test.sh all` once before
    merging. Nothing is run against the installed AiTerm or a live broadcast. `scripts/run-dev.sh` only on the person's
    go.

## To-dos

### Slice 1: the record and its hold

- [ ] `OperatorQuestion` fields and computed parts; migration test (test 4)
- [ ] `ask_you` with `holds` and `choices`; release by `holds(task:)` in every path (test 1)
- [ ] Requests, task lines and cards read holds (tests 2, 3)
- [ ] The brief's task and holds lines; `ask_you` served schema; goldens by hand; `contract.json`'s note (test 5)

### Slice 2: the Waiting on you list

- [ ] `BroadcastBoard.waiting` and the list above the columns, answer here and answer there (test 6)
- [ ] `answer(question:with:)`, its wake line, and `run_status` (tests 7, 8)
- [ ] Notifications, the Operator row and a card's question open the block (test 9)
- [ ] The brief's pointer and `answeredHere` lines (A); the `resolve_question` description; goldens by hand (test 5)

### Slice 3: worker questions

- [ ] The card's muted worker question (test 10)
- [ ] `relay_question` with the three strengths and fail-open (test 11)
- [ ] The Done step: Goal rounds, Worker questions (test 13)
- [ ] H1 to H3 (test 12)
- [ ] The relay brief lines, the served schema, goldens by hand, 37 schemas (test 14)

### At the end

- [ ] `docs/operators.md`, the UI README and the design page synced; the proposal removed from the Proposals tab (test 15)

## Plan review

Codex, one round against 23e719e2: three Important findings and one Minor, all fixed in this plan.

- **Finished tasks.** A non-holding question on a finished task stayed listed but couldn't be answered. It can now be
  answered.
- **Several tabs prompting.** The list was built from `OperatorRequests.open`, which folds a task's permission prompts
  into one. It now reads `run.questions` itself, with one block per prompting tab, each opening its own tab.
- **Slice 1 too early.** Slice 1 removed the questions from the chat before the list existed. The pointer-only brief
  now lands in slice 2.
- **Migration proof.** The plan claimed a migration check that `OperatorCurrentContractTests` doesn't make. An explicit
  re-encode check of `state.json` is added.
