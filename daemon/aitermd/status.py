from __future__ import annotations

import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Literal

from .hook_events import HookEvent
from .models import BackgroundJob, State, StoppedOn, TranscriptWork
from .screens import shows_trust_prompt as shows_trust_prompt
from .sessions import SessionRegistry

if TYPE_CHECKING:
    from .agents.agy import AgyReading, AgyTask
    from .agents.claude import ShellReading, TranscriptTail

# How long Antigravity's status line can take to count a command after it went to the background: agy 1.5.18 took
# about two seconds (docs/research/2026-11-26-antigravity-background-work.md).
AGY_COUNT_LAG_SECONDS = 5.0
# The states a tick's evidence can claim of a turn.
EvidenceState = Literal["working", "needsInput", "done"]
# Where tick evidence comes from: Claude's session file, the spinner in a Codex tab's title, a turn
# boundary in a Codex rollout, or Antigravity's status line. Each agent module under `agents/` maps its
# own readings.
EvidenceSource = Literal["claude_file", "codex_title", "codex_rollout", "agy_statusline"]
# How long after a hook Antigravity's status line is not believed to say working or done: it runs on
# the same change of state, and its post can land after the hook's while still describing the moment
# before. A tool waiting for approval is believed at once: it may be reported once only, and no hook
# follows it faster than a person answers.
STATUSLINE_SETTLE_SECONDS = 1.0


@dataclass(frozen=True, slots=True)
class Evidence:
    """What a corroborating source read on the tick says of a session's turn: the state it claims,
    the wall-clock time it speaks for, and the source, which decides how it ranks against the hooks."""
    state: EvidenceState
    at: float
    source: EvidenceSource


@dataclass(slots=True)
class _Child:
    """A running subagent. `transcript` is where a Claude child writes (None for the other
    harnesses), `started_at` the wall clock at its latest SubagentStart. `stopped_at` is when
    its latest SubagentStop came, on the monotonic clock, None while none has: the transcript
    says whether it ended the child."""
    transcript: str | None
    started_at: float
    stopped_at: float | None = None
    label: str = "Subagent"
    conversation: str | None = None
    generation: int = 0
    accepts_labels: bool = True
    display_label: str | None = None


@dataclass(slots=True)
class Turn:
    """What the engine remembers of one session's turn, beside the state the registry holds. Made on
    the first event that needs it, and forgotten whole when the conversation ends (`reset_turn`)."""
    # When a hook last said what the turn is doing. The tick's corroborating signals lag the hooks:
    # a session file written before then speaks for an earlier moment.
    hook_at: float = float("-inf")
    # Whether a Codex title has shown a spinner since the last hook said working. Codex draws it a
    # moment after UserPromptSubmit; its absence before then does not end a turn.
    spun: bool = False
    # Last explicit rollout boundary applied; an unchanged event never restores stale state.
    rollout_at: float = float("-inf")
    # The subagents running, by id.
    children: dict[str, _Child] = field(default_factory=dict)
    # A repeated child id may still have cached metadata for its previous run: use its
    # native type/Stop fallback rather than guessing which assignment a label belongs to.
    child_history: set[str] = field(default_factory=set)
    child_generation: int = 0
    # A hook, title or session file said the foreground turn ended while a child still runs: the
    # last child to stop finishes the change.
    deferred_done: bool = False
    # The state an open PI prompt interrupted: closing the last prompt puts it back. PI can open a
    # prompt over another, so how many are open is counted.
    before_prompt: State | None = None
    prompts_open: int = 0
    # Display provenance, not turn readiness. A genuine start establishes when this process began work.
    work_since: float | None = None
    shell_snapshot: tuple[BackgroundJob, ...] | None = None
    shell_snapshot_at: float = float("-inf")
    shell_snapshot_valid: bool = True
    # Antigravity's status line counts the background commands (`task_count`) but names none. The commands the
    # transcript listed last (AgyTask, by when this daemon first read each), and the moment before which a reading that
    # counted none has ended every command seen, killed or not, whatever the transcript still lists. The count lags a
    # command going to the background by seconds (AGY_COUNT_LAG_SECONDS): a reading that counts none says nothing of
    # a command seen just before it.
    agy_tasks: tuple[AgyTask, ...] = ()
    agy_ended_before: float = float("-inf")


class StatusEngine:
    def __init__(self, registry: SessionRegistry, clock: Callable[[], float],
                 monotonic: Callable[[], float] = time.monotonic):
        self.reg = registry
        # `clock` is the wall clock, which a hook's stamp must share with a session file's mtime;
        # `monotonic` orders SubagentStop against the transcript read's start.
        self._clock, self._monotonic = clock, monotonic
        self._turns: dict[str, Turn] = {}
        # When the subagents' transcripts were last asked for (subagent_transcripts), on the monotonic clock: the read
        # that answers began then, and cannot say a SubagentStop that came after it stands.
        self._asked_at = float("-inf")
        # The sessions whose row a folder-trust dialog holds at needs input. Not a turn's: the dialog
        # belongs to the tab until it closes, and comes before any conversation.
        self._trust_prompts: set[str] = set()
        # Each tab's latest Antigravity status-line reading the settle window held back
        # (STATUSLINE_SETTLE_SECONDS), with the row's state then: a hook or a newer reading replaces it,
        # and the tick applies it once the window has passed (settle_held_ticks), so a lost Stop cannot
        # leave a row working -- unless the row has moved on since, as a done row the person opened.
        self._held_ticks: dict[str, tuple[Evidence, State]] = {}

    def turn(self, session_id: str) -> Turn | None:
        """What the engine remembers of the session's turn, if anything: a view for inspection, by a
        test or a diagnosis, and not to be changed through. The engine's own methods change it."""
        return self._turns.get(session_id)

    def _turn(self, session_id: str) -> Turn:
        if (turn := self._turns.get(session_id)) is None:
            turn = self._turns[session_id] = Turn()
        return turn

    def apply_event(self, session_id: str, ev: HookEvent) -> list[str]:
        if ev.kind is None:
            return []
        # The agent loads its hooks once its folder is trusted, so any hook says the dialog is over.
        return list(dict.fromkeys(self.apply_trust_prompt(session_id, False) + self._apply_event(session_id, ev)))

    def _apply_event(self, session_id: str, ev: HookEvent) -> list[str]:
        """What a hook says happened to the session's turn (`ev.kind`; its metadata is
        `apply_metadata`'s). `ev.subagent_transcript` is where a starting Claude child writes;
        `ev.running_subagents`, on a Claude Stop, the children still running."""
        if (kind := ev.kind) is None or self.reg.get(session_id) is None:
            return []
        # A hook is newer than any status-line reading held back before it.
        self._held_ticks.pop(session_id, None)
        turn = self._turn(session_id)
        if kind == "sessionStart":
            self.reset_turn(session_id)
            self._turn(session_id).work_since = self._clock()
            session = self.reg.get(session_id)
            if session is not None and session.agent == "codex":
                self._turn(session_id).rollout_at = self._clock()
            # Another conversation: what stopped the last one's turn is not this one's.
            cleared = self.reg.set_stopped_on(session_id, None)
            return [session_id] if self._show_children(session_id) or cleared else []
        if kind == "subagentStart":
            return self.subagent_started(session_id, ev.subagent_id, ev.subagent_transcript, ev.subagent_label)
        if kind == "subagentStop":
            return self.subagent_stopped(session_id, ev.subagent_id)
        if kind == "promptStart":
            return self._prompt_started(session_id)
        if kind == "promptEnd":
            return self._prompt_ended(session_id)
        turn.hook_at = self._clock()
        released: list[str] = []
        # A new turn, or one its Stop ended cleanly, is past whatever stopped the last; a StopFailure says what stopped this one.
        if kind == "working" or ev.event_name in ("Stop", "StopFailure"):
            stopped = StoppedOn(ev.stop_error, at=turn.hook_at) if ev.stop_error else None
            released += [session_id] if self.reg.set_stopped_on(session_id, stopped) else []
        # What the session waits on once its turn ends, said by the Stop; a new turn waits on nothing yet. A subagent
        # this engine does not count holds nothing up.
        if (work := ev.background_work if kind == "done" else () if kind == "working" else None) is not None:
            work = tuple(job for job in work if job.agent_id is None or job.agent_id in turn.children)
            released += [session_id] if self.reg.set_stop_work(session_id, work) else []
        if kind == "done" and (running_subagents := ev.running_subagents) is not None:
            # A child the Stop no longer lists is gone, SubagentStop or not; the last one lands a
            # completion an earlier turn deferred, before this one lands its own.
            for child_id in [c for c in turn.children if c not in running_subagents]:
                released += self._subagent_ended(session_id, child_id)
        if ev.event_name == "Stop" or ev.display_shells is not None:
            turn.shell_snapshot, turn.shell_snapshot_at = ev.display_shells, self._clock()
            turn.shell_snapshot_valid = ev.display_shells is not None
        changed = released + self._apply_state(session_id, kind, turn.hook_at, source="hook")
        return list(dict.fromkeys(changed + ([session_id] if self._show_children(session_id) else [])))

    def apply_evidence(self, session_id: str, evidence: Evidence) -> list[str]:
        """What a corroborating source read on the tick says of the session's turn (Evidence), so a
        missed hook cannot strand its row."""
        return self._apply_state(session_id, evidence.state, evidence.at, source=evidence.source)

    def _apply_state(self, session_id: str, target: State, at: float, *,
                     source: Literal["hook"] | EvidenceSource) -> list[str]:
        """Land a turn signal, retaining each source's freshness and new-turn semantics.
        Corroborating busy files and spinners do not start another turn or discard a deferred Stop."""
        s = self.reg.get(session_id)
        if s is None:
            return []
        if source == "codex_title":
            if target == "working":
                # Codex draws its spinner a moment after UserPromptSubmit: only once it has been seen
                # can its absence end the turn.
                self._turn(session_id).spun = True
            elif s.state != "working" or (current := self._turns.get(session_id)) is None or not current.spun:
                return []
        turn = self._turns.get(session_id)
        if source == "agy_statusline":
            # Needs-input at a tool's approval and working again once it is answered, which no hook
            # reports; done when a Stop was missed. An idle tab -- one a restarted daemon found mid-turn
            # -- takes working or needs-input from it, as from Claude's file or Codex's spinner; a stale
            # working reading after a Stop finds the row done, not idle. Done only ends a turn under way.
            # A newer reading replaces a held one; one inside the window is held, not believed yet.
            self._held_ticks.pop(session_id, None)
            if target != "needsInput" and turn is not None and at - turn.hook_at < STATUSLINE_SETTLE_SECONDS:
                if target != "idle":  # tick evidence never says idle
                    self._held_ticks[session_id] = (Evidence(target, at, source), s.state)
                return []
            allowed = {"needsInput": ("working", "idle"), "working": ("needsInput", "idle"), "done": ("working", "needsInput")}
            if s.state not in allowed[target]:
                return []
        if source == "claude_file":
            # A file no newer than the last hook is ignored: Claude rewrites it after the hook fires,
            # and until then it still describes the moment before -- `busy` under a fresh permission
            # prompt.
            if turn is not None and at <= turn.hook_at:
                return []
            # A file that says the turn ended changes only a turn under way, or one a child holds open.
            if target == "done" and s.state not in ("working", "needsInput") and not (turn is not None and turn.children):
                return []
        if source == "codex_rollout":
            turn = self._turn(session_id)
            if at <= max(turn.hook_at, turn.rollout_at):
                return []
            turn.rollout_at = at
        # Claude's file stays busy while children run past their parent's StopFailure. Only
        # the parent's transcript can corroborate recovery then; a busy child proves none.
        child_file = source == "claude_file" and turn is not None and bool(turn.children)
        active = target in ("working", "needsInput") and not (child_file and target == "working")
        changed = self.reg.set_stopped_on(session_id, None) if active else False
        if target == "done" and turn is not None and turn.children:
            # A Claude file cannot cover an input request, or even defer its completion.
            if source == "claude_file" and s.state == "needsInput":
                return []
            self._defer_done(turn)
            # Only the file also corroborates that the children are still working.
            if source != "claude_file":
                return []
            target = "working"
        if source in ("hook", "codex_rollout"):
            turn = self._turn(session_id)
            # An explicit boundary supersedes the state a prompt interrupted.
            turn.before_prompt, turn.prompts_open = None, 0
            if target == "working":
                turn.deferred_done = False
                if source == "hook" or s.state != "working":
                    turn.spun = False
                if source == "codex_rollout":
                    changed = self.reg.set_stop_work(session_id, ()) or changed
        return [session_id] if self.reg.set_state(session_id, target, preserve_stop=child_file) or changed else []

    def apply_metadata(self, session_id: str, *, context: int | None = None, cwd: str | None = None,
                       context_tokens: int | None = None, clear_context_tokens: bool = False,
                       conversation: str | None = None, transcript: str | None = None) -> list[str]:
        """What an agent reports beside its state: each value present replaces the session's, and
        an absent one leaves it be, unless clear_context_tokens explicitly clears the token count.
        Returns the sessions that changed; the transcript is not sent."""
        s = self.reg.get(session_id)
        if s is None:
            return []
        self.reg.set_transcript(session_id, transcript)
        changed: list[str] = []
        if self.reg.set_agent_cwd(session_id, cwd):
            changed.append(session_id)
        if self.reg.set_conversation(session_id, conversation):
            if (turn := self._turns.get(session_id)) is not None:
                turn.work_since, turn.shell_snapshot = None, None
                self._hide_work(session_id)
            changed.append(session_id)
        if (context_tokens is not None or clear_context_tokens) and self.reg.set_context_tokens(session_id, context_tokens):
            changed.append(session_id)
        if context is not None:
            # Context is presented per provider within a task. Updating sibling tabs for the same
            # agent keeps its last value stable across tab changes without letting a Claude and a
            # Codex conversation overwrite each other.
            own = [other for other in self.reg.for_task(s.task_id) if other.agent == s.agent] if s.task_id else [s]
            changed += [other.session_id for other in own if self.reg.set_context(other.session_id, context)]
        return changed

    def showing_trust_prompt(self, session_id: str) -> bool:
        return session_id in self._trust_prompts

    def apply_trust_prompt(self, session_id: str, shown: bool) -> list[str]:
        """Whether the tab's screen shows its agent's folder-trust dialog (shows_trust_prompt). It
        holds an idle row at needs input, and closing it puts the row back to idle: no turn ran. A row
        in any other state is left alone, and so is one a hook has moved since the dialog was seen."""
        s = self.reg.get(session_id)
        if s is None:
            return []
        if shown:
            if s.state != "idle" or session_id in self._trust_prompts:
                return []
            self._trust_prompts.add(session_id)
            return [session_id] if self.reg.set_state(session_id, "needsInput") else []
        if session_id not in self._trust_prompts:
            return []
        self._trust_prompts.discard(session_id)
        return [session_id] if s.state == "needsInput" and self.reg.set_state(session_id, "idle") else []

    def forget_session(self, session_id: str) -> None:
        """Drops everything the engine keeps of a closed tab."""
        self.reset_turn(session_id)
        self._trust_prompts.discard(session_id)
        self._held_ticks.pop(session_id, None)

    def settle_held_ticks(self) -> list[str]:
        """Applies each held status-line reading whose settle window has passed with no hook or newer
        reading after it: it is then the tab's latest word on its turn. Run on every tick."""
        now, changed = self._clock(), []
        for session_id, (held, state_then) in list(self._held_ticks.items()):
            turn = self._turns.get(session_id)
            if turn is None or now - turn.hook_at >= STATUSLINE_SETTLE_SECONDS:
                del self._held_ticks[session_id]
                if (s := self.reg.get(session_id)) is not None and s.state == state_then:
                    changed += self._apply_state(session_id, held.state, now, source=held.source)
        return changed

    def reset_turn(self, session_id: str) -> None:
        """Forgets the subagents and deferred completion of a conversation that has ended: a new
        session started, or another process took over the tab. A child whose SubagentStop was lost
        would otherwise hold the row at working for good."""
        self._turns.pop(session_id, None)
        self._hide_work(session_id)

    def _hide_work(self, session_id: str) -> bool:
        """Marks the live sources of the session's work unavailable; says whether that changed it."""
        hidden = self.reg.set_shown_subagents(session_id, None)
        hidden = self.reg.set_transcript_work(session_id, None) or hidden
        return self.reg.set_shown_shells(session_id, None) or hidden

    def _prompt_started(self, session_id: str) -> list[str]:
        s = self.reg.get(session_id)
        if s is None:
            return []
        turn = self._turn(session_id)
        # A prompt opened over another keeps the state the first one interrupted.
        if turn.before_prompt is None:
            turn.before_prompt = s.state
        turn.prompts_open += 1
        return [session_id] if self.reg.set_state(session_id, "needsInput") else []

    def _prompt_ended(self, session_id: str) -> list[str]:
        """Once the last open prompt closes, puts back the state the first interrupted -- which
        is working only if a turn was running. The deferred completion is left alone: a background
        child still owes it. What changed underneath the prompt was written into the remembered
        state (`_behind_input`)."""
        if (turn := self._turns.get(session_id)) is None:
            return []
        turn.prompts_open -= 1
        if turn.prompts_open > 0:
            return []
        before, turn.before_prompt, turn.prompts_open = turn.before_prompt, None, 0
        if before is None:
            return []
        return [session_id] if self.reg.set_state(session_id, before) else []

    @staticmethod
    def _behind_input(turn: Turn, state: State) -> None:
        """A change an input request keeps off the row. Under an open PI prompt it lands in the state
        the prompt will restore, so closing the prompt shows it; PI has no tick to correct it later."""
        if turn.before_prompt is not None:
            turn.before_prompt = state

    def subagent_started(self, session_id: str, subagent_id: str | None, transcript: str | None = None,
                         label: str | None = None) -> list[str]:
        s = self.reg.get(session_id)
        if s is None or not subagent_id:
            return []
        turn = self._turn(session_id)
        turn.child_generation += 1
        accepts_labels = subagent_id not in turn.child_history and len(turn.child_history) < 4096
        if accepts_labels:
            turn.child_history.add(subagent_id)
        # A resumed child starts again under the same id with fresh completion evidence.
        turn.children[subagent_id] = _Child(transcript, self._clock(),
                                          label=label or "Subagent", conversation=s.conversation_id,
                                          generation=turn.child_generation, accepts_labels=accepts_labels)
        shown = self._show_children(session_id)
        # An input request must stay visible; every other state means the
        # task is actively progressing while this child is alive.
        if s.state == "needsInput":
            self._behind_input(turn, "working")
            return [session_id] if shown else []
        return [session_id] if self.reg.set_state(session_id, "working") or shown else []

    def subagent_stopped(self, session_id: str, subagent_id: str | None) -> list[str]:
        """A child's SubagentStop. A Claude child's need not end its run: Claude Code fires it each time the
        child's turn ends, then can run the child on -- to hand back a report it has not handed back yet. One
        with a transcript stays counted until a tick reads there that the run is over (`release_dead_subagents`)."""
        turn = self._turns.get(session_id)
        if turn is not None and subagent_id and (child := turn.children.get(subagent_id)) and child.transcript:
            child.stopped_at = self._monotonic()
            return []
        return self._subagent_ended(session_id, subagent_id)

    def _defer_done(self, turn: Turn) -> None:
        """The turn ended while its children work: the last to stop lands its done."""
        turn.deferred_done = True

    def _subagent_ended(self, session_id: str, subagent_id: str | None) -> list[str]:
        s = self.reg.get(session_id)
        if s is None or not subagent_id:
            return []
        turn = self._turns.get(session_id)
        if turn is None or turn.children.pop(subagent_id, None) is None:
            return []
        shown = self._show_children(session_id)
        if turn.children or not turn.deferred_done:
            return [session_id] if shown else []
        turn.deferred_done = False
        if s.state == "needsInput":
            self._behind_input(turn, "done")
            return [session_id] if shown else []
        return [session_id] if self.reg.set_state(session_id, "done") or shown else []

    def _show_children(self, session_id: str) -> bool:
        """Puts the children counted now on the session, and says whether that changed it: the subagents its Stop
        listed among its work, and those of its current conversation as shown. A child no longer counted leaves both."""
        if (s := self.reg.get(session_id)) is None:
            return False
        children = turn.children if (turn := self._turns.get(session_id)) is not None else {}
        work = tuple(job for job in s.stop_work if job.agent_id is None or job.agent_id in children)
        changed = self.reg.set_stop_work(session_id, work)
        descriptions = {job.agent_id: job.text for job in work if job.agent_id is not None}
        for child_id, child in children.items():
            if child_id in descriptions:
                child.label = descriptions[child_id]
        shown = tuple(BackgroundJob("subagent", child.label, agent_id=child_id, display_label=child.display_label)
                      for child_id, child in children.items() if child.conversation == s.conversation_id)
        return self.reg.set_shown_subagents(session_id, shown) or changed

    def child_generations(self, session_id: str) -> dict[str, int]:
        turn = self._turns.get(session_id)
        return {key: child.generation for key, child in turn.children.items()} if turn else {}

    def apply_child_labels(self, session_id: str, labels: tuple[tuple[str, str], ...],
                           captured: Mapping[str, int]) -> list[str]:
        session, turn = self.reg.get(session_id), self._turns.get(session_id)
        if session is None or turn is None:
            return []
        for key, label in labels:
            child = turn.children.get(key)
            if (child is not None and child.accepts_labels and child.conversation == session.conversation_id
                    and captured.get(key, child.generation) == child.generation):
                child.display_label = label
        return [session_id] if self._show_children(session_id) else []

    def subagent_transcripts(self) -> set[str]:
        """The transcripts release_dead_subagents needs: those of every child counted, its turn under
        way or ended. Only a Claude child has one. The caller reads them, off the event loop, and
        passes them in; the read begins now."""
        self._asked_at = self._monotonic()
        return {c.transcript for turn in self._turns.values() for c in turn.children.values() if c.transcript}

    def apply_shell_reading(self, session_id: str, reading: ShellReading | None) -> list[str]:
        """Refreshes the shells the reader lists (SessionInfo.shown_shells), None while the reading cannot be trusted.
        The Stop's work and the turn's state stay untouched."""
        session, turn = self.reg.get(session_id), self._turns.get(session_id)
        if session is None or turn is None:
            return []
        changed = self._show_children(session_id)
        shells: tuple[BackgroundJob, ...] | None = None
        if reading is not None and turn.work_since is not None and turn.shell_snapshot_valid:
            known = reading.ended | {task.job.task_id for task in reading.tasks}
            expected = {job.task_id for job in turn.shell_snapshot or ()}
            if expected <= known:
                shells = tuple(task.job for task in reading.tasks
                               if turn.shell_snapshot is None or task.started_at > turn.shell_snapshot_at
                               or task.job.task_id in expected)
        changed = self.reg.set_shown_shells(session_id, shells) or changed
        return [session_id] if changed else []

    def apply_task_count(self, session_id: str, count: int) -> list[str]:
        """What an Antigravity status line counts of the tab's background commands. One that counts none ends every
        command seen more than AGY_COUNT_LAG_SECONDS before it: had it still run, the count would include it. They
        leave the Stop's work and the shown shells. A command seen since, which the count may not include yet, stays."""
        if self.reg.get(session_id) is None or count > 0:
            return []
        turn = self._turn(session_id)
        turn.agy_ended_before = max(turn.agy_ended_before, self._clock() - AGY_COUNT_LAG_SECONDS)
        return [session_id] if self._keep_running_commands(session_id) else []

    def _keep_running_commands(self, session_id: str) -> bool:
        """Takes each Antigravity command that no longer runs (its end in the transcript, or ended by a count) out of the
        Stop's work and the shown shells; says whether that changed the session."""
        s, turn = self.reg.get(session_id), self._turns.get(session_id)
        if s is None or turn is None:
            return False
        running = {task.task_id for task in turn.agy_tasks if task.seen_at > turn.agy_ended_before}
        changed = self.reg.set_stop_work(session_id, tuple(job for job in s.stop_work
                                                           if job.kind != "shell" or job.task_id in running))
        if s.shown_shells:
            changed = self.reg.set_shown_shells(session_id, tuple(
                job for job in s.shown_shells if job.task_id in running)) or changed
        return changed

    def agy_running_commands(self, session_id: str, reading: AgyReading) -> tuple[BackgroundJob, ...]:
        """The background commands an Antigravity transcript reading lists that the status line has not since
        counted ended (apply_task_count)."""
        turn = self._turn(session_id)
        turn.agy_tasks = reading.tasks
        return tuple(BackgroundJob("shell", task.command, task_id=task.task_id)
                     for task in reading.tasks if task.seen_at > turn.agy_ended_before)

    def agy_stop_work(self, session_id: str, reading: AgyReading) -> tuple[BackgroundJob, ...]:
        """What an Antigravity Stop that says work still runs (`fullyIdle: false`) waits on: the transcript's running
        commands, then its subagents, each by the prompt it was given and its role. Only a subagent this engine
        still counts holds anything (_apply_event)."""
        return self.agy_running_commands(session_id, reading) + tuple(
            BackgroundJob("subagent", child.prompt, child.conversation, display_label=child.role)
            for child in reading.subagents)

    def apply_agy_reading(self, session_id: str, reading: AgyReading | None) -> list[str]:
        """Refreshes an Antigravity tab's shown shells from its transcript, working or ended, takes a command its
        transcript shows ended out of the Stop's work, and names its counted subagents by their role. None while the
        transcript cannot be read. The state stays."""
        session, turn = self.reg.get(session_id), self._turns.get(session_id)
        if session is None or turn is None:
            return []
        shells = self.agy_running_commands(session_id, reading) if reading is not None else None
        changed = self.reg.set_shown_shells(session_id, shells)
        if reading is not None:
            changed = self._keep_running_commands(session_id) or changed
            for child in reading.subagents:
                if (counted := turn.children.get(child.conversation)) is not None and child.role:
                    counted.display_label = child.role
        return [session_id] if self._show_children(session_id) or changed else []

    def child_ids(self, session_id: str) -> frozenset[str]:
        """The subagents counted now for the session's turn."""
        turn = self._turns.get(session_id)
        return frozenset(turn.children) if turn is not None else frozenset()

    def apply_transcript_work(self, session_id: str, work: TranscriptWork | None) -> list[str]:
        """Refreshes what the transcript says of the Stop's work (SessionInfo.transcript_work), None while the reading
        cannot be trusted. Neither the turn's state nor its Stop's work changes: work_items reads it to tell an idle
        teammate from a running one, and to leave out what ended."""
        if self.reg.get(session_id) is None or self._turns.get(session_id) is None:
            return []
        return [session_id] if self.reg.set_transcript_work(session_id, work) else []

    def release_dead_subagents(self, tails: Mapping[str, TranscriptTail | None]) -> list[str]:
        """Drops each child whose transcript ends in an interruption or a SubagentStop that left
        it nothing to answer, written since its latest SubagentStart.
        `tails` is what the read asked for last (subagent_transcripts) found of each transcript: None
        for one not there yet, which proves nothing, except that a SubagentStop that came before the
        read began stands. A transcript it holds nothing for -- not asked for, or the read did not
        answer -- proves nothing."""
        changed = []
        for sid, turn in list(self._turns.items()):
            for child_id, child in list(turn.children.items()):
                if child.transcript is None or child.transcript not in tails:
                    continue
                if (tail := tails[child.transcript]) is None:
                    stood = child.stopped_at is not None and child.stopped_at <= self._asked_at
                    changed += self._subagent_ended(sid, child_id) if stood else []
                    continue
                # An ending from before a resume belongs to the earlier turn. Claude can write
                # it to the file after the resume's SubagentStart, so use the record's time.
                ended = tail.ended_at is not None and tail.ended_at > child.started_at
                if ended:
                    changed += self._subagent_ended(sid, child_id)
            changed += [sid] if self._show_children(sid) else []
        return list(dict.fromkeys(changed))

    def apply_progress(self, session_id: str, at: float) -> list[str]:
        """The session's agent carried on at `at`: a parent prompt or successful response newer than
        its failure and the last hook clears what stopped its turn. A child's file activity cannot do
        this; the reader checks only the parent's transcript."""
        session, turn = self.reg.get(session_id), self._turns.get(session_id)
        if (session is None or session.stopped_on is None
                or at <= max(session.stopped_on.at, turn.hook_at if turn is not None else float("-inf"))):
            return []
        if turn is not None:
            turn.deferred_done = False
        return [session_id] if self.reg.set_stopped_on(session_id, None) else []

    def agent_exited(self, session_id: str) -> list[str]:
        displayed = (session := self.reg.get(session_id)) is not None and (
            session.shown_subagents is not None or session.shown_shells is not None)
        self.reset_turn(session_id)
        self._trust_prompts.discard(session_id)
        cleared = self.reg.set_stop_work(session_id, ())
        cleared = self.reg.set_stopped_on(session_id, None) or cleared
        return [session_id] if self.reg.set_state(session_id, "idle") or cleared or displayed else []

    def mark_seen(self, task_id: str) -> list[str]:
        sessions = self.reg.for_task(task_id)
        for s in sessions:
            # A completion seen while a prompt covers it must not come back unseen when it closes.
            if (turn := self._turns.get(s.session_id)) is not None and turn.before_prompt == "done":
                turn.before_prompt = "idle"
        return [s.session_id for s in sessions if s.state == "done" and self.reg.set_state(s.session_id, "idle")]
