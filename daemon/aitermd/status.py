from __future__ import annotations

import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Literal

from .claude_subagents import TranscriptTail
from .hook_events import HookEvent
from .text import shows
from .models import HARNESS_BY_AGENT, AgentKind, State, StoppedOn
from .sessions import SessionRegistry

CLAUDE_FILE_STATUS: dict[str, State | None] = {
    "busy": "working", "thinking": "working", "running": "working",
    "waiting": "needsInput", "idle": None, "shell": None,
}

# How long a Claude subagent's transcript may go unwritten, once its parent's ended turn waits on it or its
# SubagentStop came, before the child counts as dead. A child of a turn still under way is left to the turn's Stop,
# which says what still runs. Claude's stream watchdog kills a child after 600 s without progress, but
# that leaves an interruption in the transcript, which ends the child at once. Live children have gone
# 28 minutes without a write -- a long generation, a stream retry -- so this only catches one that died
# writing nothing at all.
SUBAGENT_QUIET_SECONDS = 45 * 60.0


@dataclass(slots=True)
class _Child:
    """A running subagent. `transcript` is where a Claude child writes (None for the other
    harnesses), `started_at` the wall clock at its latest SubagentStart. `stamp` is its transcript's
    (mtime, size) as last seen, and `quiet_since` when that stamp was first seen, on the monotonic clock;
    `written_at` is that mtime, on the wall clock. `stopped_at` is when the latest SubagentStop since
    that start came, on the monotonic clock, None while none has: the transcript says whether it ended the run."""
    transcript: str | None
    started_at: float
    stamp: tuple[int, int] | None = None
    quiet_since: float = 0.0
    stopped_at: float | None = None
    written_at: float | None = None


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
    # A hook, title or session file said the foreground turn ended while a child still runs: the
    # last child to stop finishes the change. `deferred_since` is when one first said so, on the
    # monotonic clock.
    deferred_done: bool = False
    deferred_since: float = 0.0
    # The state an open PI prompt interrupted: closing the last prompt puts it back. PI can open a
    # prompt over another, so how many are open is counted.
    before_prompt: State | None = None
    prompts_open: int = 0


def shows_trust_prompt(agent: AgentKind, screen: str) -> bool:
    """Whether `screen` shows the agent's folder-trust dialog. Compared without whitespace: a line
    can come back with its spaces drawn as cursor moves, or wrapped where the window is narrow."""
    if (harness := HARNESS_BY_AGENT.get(agent)) is None:
        return False
    return shows(screen, harness.trust_prompt)


def _has_spinner(title: str) -> bool:
    return bool(title) and "⠀" <= title[0] <= "⣿"


class StatusEngine:
    def __init__(self, registry: SessionRegistry, clock: Callable[[], float],
                 monotonic: Callable[[], float] = time.monotonic):
        self.reg = registry
        # `clock` is the wall clock, which a hook's stamp must share with a session file's mtime;
        # `monotonic` times how long a subagent's transcript stays quiet, which an NTP step must
        # not shorten.
        self._clock, self._monotonic = clock, monotonic
        self._turns: dict[str, Turn] = {}
        # When the subagents' transcripts were last asked for (subagent_transcripts), on the monotonic clock: the read
        # that answers began then, and cannot say a SubagentStop that came after it stands.
        self._asked_at = float("-inf")
        # The sessions whose row a folder-trust dialog holds at needs input. Not a turn's: the dialog
        # belongs to the tab until it closes, and comes before any conversation.
        self._trust_prompts: set[str] = set()

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
        return self.apply_trust_prompt(session_id, False) + self._apply_event(session_id, ev)

    def _apply_event(self, session_id: str, ev: HookEvent) -> list[str]:
        """What a hook says happened to the session's turn (`ev.kind`; its metadata is
        `apply_metadata`'s). `ev.subagent_transcript` is where a starting Claude child writes;
        `ev.running_subagents`, on a Claude Stop, the children still running."""
        if (kind := ev.kind) is None or self.reg.get(session_id) is None:
            return []
        turn = self._turn(session_id)
        if kind == "sessionStart":
            self.reset_turn(session_id)
            session = self.reg.get(session_id)
            if session is not None and session.agent == "codex":
                self._turn(session_id).rollout_at = self._clock()
            # Another conversation: what stopped the last one's turn is not this one's.
            cleared = self.reg.set_stopped_on(session_id, None)
            return [session_id] if self._show_children(session_id) or cleared else []
        if kind == "subagentStart":
            return self.subagent_started(session_id, ev.subagent_id, ev.subagent_transcript)
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
            released += [session_id] if self.reg.set_background(session_id, work) else []
        if kind == "done" and (running_subagents := ev.running_subagents) is not None:
            # A child the Stop no longer lists is gone, SubagentStop or not; the last one lands a
            # completion an earlier turn deferred, before this one lands its own.
            for child_id in [c for c in turn.children if c not in running_subagents]:
                released += self._subagent_ended(session_id, child_id)
        return released + self._apply_state(session_id, kind, turn.hook_at, source="hook")

    def _apply_state(self, session_id: str, target: State, at: float, *,
                     source: Literal["hook", "claude_file", "codex_title", "rollout"]) -> list[str]:
        """Land a turn signal, retaining each source's freshness and new-turn semantics.
        Corroborating busy files and spinners do not start another turn or discard a deferred Stop."""
        s = self.reg.get(session_id)
        if s is None:
            return []
        turn = self._turns.get(session_id)
        if source == "claude_file" and turn is not None and at <= turn.hook_at:
            return []
        if source == "rollout":
            turn = self._turn(session_id)
            if at <= max(turn.hook_at, turn.rollout_at):
                return []
            turn.rollout_at = at
        if target == "done" and turn is not None and turn.children:
            # A Claude file cannot cover an input request, or even defer its completion.
            if source == "claude_file" and s.state == "needsInput":
                return []
            self._defer_done(turn)
            # Only the file also corroborates that the children are still working.
            if source != "claude_file":
                return []
            target = "working"
        changed = False
        if source in ("hook", "rollout"):
            turn = self._turn(session_id)
            # An explicit boundary supersedes the state a prompt interrupted.
            turn.before_prompt, turn.prompts_open = None, 0
            if target == "working":
                turn.deferred_done = False
                if source == "hook" or s.state != "working":
                    turn.spun = False
                if source == "rollout":
                    changed = self.reg.set_stopped_on(session_id, None)
                    changed = self.reg.set_background(session_id, ()) or changed
        return [session_id] if self.reg.set_state(session_id, target) or changed else []

    def apply_metadata(self, session_id: str, *, model: str | None = None, reasoning: str | None = None,
                       context: int | None = None, cwd: str | None = None,
                       conversation: str | None = None, transcript: str | None = None,
                       clear_reasoning: bool = False) -> list[str]:
        """What an agent reports beside its state: each value present replaces the session's, and
        an absent one leaves it be, unless clear_reasoning explicitly clears an absent effort.
        Returns the sessions that changed; the transcript is not sent."""
        s = self.reg.get(session_id)
        if s is None:
            return []
        self.reg.set_transcript(session_id, transcript)
        changed: list[str] = []
        if model and self.reg.set_model(session_id, model):
            changed.append(session_id)
        if (reasoning or clear_reasoning) and self.reg.set_reasoning(session_id, reasoning):
            changed.append(session_id)
        if self.reg.set_agent_cwd(session_id, cwd):
            changed.append(session_id)
        if self.reg.set_conversation(session_id, conversation):
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

    def reset_turn(self, session_id: str) -> None:
        """Forgets the subagents and deferred completion of a conversation that has ended: a new
        session started, or another process took over the tab. A child whose SubagentStop was lost
        would otherwise hold the row at working for good."""
        self._turns.pop(session_id, None)

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

    def subagent_started(self, session_id: str, subagent_id: str | None, transcript: str | None = None) -> list[str]:
        s = self.reg.get(session_id)
        if s is None or not subagent_id:
            return []
        turn = self._turn(session_id)
        # A resumed child starts again under the same id, and its quiet window with it.
        turn.children[subagent_id] = _Child(transcript, self._clock(), None, self._monotonic())
        # An input request must stay visible; every other state means the
        # task is actively progressing while this child is alive.
        if s.state == "needsInput":
            self._behind_input(turn, "working")
            return []
        return [session_id] if self.reg.set_state(session_id, "working") else []

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
        """The turn ended while its children run: the last to stop lands its done. A session file or a
        title says so again on every tick, which leaves when it was first said."""
        if not turn.deferred_done:
            turn.deferred_done, turn.deferred_since = True, self._monotonic()

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
        """Puts the children counted now on the session, and says whether that changed it: the subagents
        among its background work, and when the newest of their transcripts was written. A child no
        longer counted leaves both."""
        if (s := self.reg.get(session_id)) is None:
            return False
        children = turn.children if (turn := self._turns.get(session_id)) is not None else {}
        work = tuple(job for job in s.background if job.agent_id is None or job.agent_id in children)
        written_at = max((c.written_at for c in children.values() if c.written_at is not None), default=None)
        shown = self.reg.set_background(session_id, work)
        return self.reg.set_subagents_written_at(session_id, written_at) or shown

    def subagent_transcripts(self) -> set[str]:
        """The transcripts release_dead_subagents needs: those of every child counted, its turn under
        way or ended. Only a Claude child has one. The caller reads them, off the event loop, and
        passes them in; the read begins now."""
        self._asked_at = self._monotonic()
        return {c.transcript for turn in self._turns.values() for c in turn.children.values() if c.transcript}

    def release_dead_subagents(self, tails: Mapping[str, TranscriptTail | None]) -> list[str]:
        """Notes when each counted child's transcript was last written, and drops each child whose
        transcript proves its run over: it ends in an interruption or a SubagentStop that left the
        child nothing to answer, written since its latest SubagentStart, or it has not changed for
        SUBAGENT_QUIET_SECONDS since its parent's ended turn began to wait on it or its SubagentStop came.
        `tails` is what the read asked for last (subagent_transcripts) found of each transcript: None
        for one not there yet, which proves nothing, except that a SubagentStop that came before the
        read began stands. A transcript it holds nothing for -- not asked for, or the read did not
        answer -- proves nothing."""
        now, changed = self._monotonic(), []
        for sid, turn in list(self._turns.items()):
            for child_id, child in list(turn.children.items()):
                if child.transcript is None or child.transcript not in tails:
                    continue
                if (tail := tails[child.transcript]) is None:
                    stood = child.stopped_at is not None and child.stopped_at <= self._asked_at
                    changed += self._subagent_ended(sid, child_id) if stood else []
                    continue
                if tail.stamp != child.stamp:
                    child.stamp, child.quiet_since, child.written_at = tail.stamp, now, tail.written_at
                # A verdict from before a resume speaks for the run that ended, not this one. Told by the time the
                # record gives: Claude can write it to the file after the resume's SubagentStart.
                ended = tail.ended_at is not None and tail.ended_at > child.started_at
                # Quiet counts only since the child was first waited on: its parent's ended turn deferred its done, or
                # its SubagentStop came.
                waited = [t for t in (turn.deferred_since if turn.deferred_done else None, child.stopped_at) if t is not None]
                quiet = bool(waited) and now - max(child.quiet_since, min(waited)) >= SUBAGENT_QUIET_SECONDS
                if ended or quiet:
                    changed += self._subagent_ended(sid, child_id)
            changed += [sid] if self._show_children(sid) else []
        return list(dict.fromkeys(changed))

    def apply_claude_file_status(self, session_id: str, status: str, written_at: float) -> list[str]:
        """Corroborates the hooks with Claude's own session file, written at `written_at`. A file no
        newer than the last hook is ignored: Claude rewrites it after the hook fires, and until
        then it still describes the moment before -- `busy` under a fresh permission prompt."""
        s = self.reg.get(session_id)
        turn = self._turns.get(session_id)
        if s is None:
            return []
        if status not in CLAUDE_FILE_STATUS:
            # A status this daemon does not know says nothing about the turn -- least of all that
            # it ended.
            return []
        mapped = CLAUDE_FILE_STATUS[status]
        if mapped is not None:
            # `waiting` keeps a hook-derived input request visible. Once the
            # user answers, Claude changes the session file back to one of the
            # active statuses; that is the resume signal which restores the
            # spinner even though no new UserPromptSubmit hook is emitted.
            target = mapped
        else:
            target = "done" if s.state in {"working", "needsInput"} or (turn is not None and turn.children) else s.state
        return self._apply_state(session_id, target, written_at, source="claude_file")

    def apply_codex_rollout(self, session_id: str, state: State, reported_at: float) -> list[str]:
        """Recover a missing hook from a structured Codex boundary; a newer hook or boundary wins."""
        s = self.reg.get(session_id)
        if s is None or s.agent != "codex" or state not in ("working", "done"):
            return []
        return self._apply_state(session_id, state, reported_at, source="rollout")

    def apply_codex_title(self, session_id: str, title: str) -> list[str]:
        s = self.reg.get(session_id)
        if s is None:
            return []
        turn = self._turns.get(session_id)
        if _has_spinner(title):
            # Permission and elicitation answers do not emit UserPromptSubmit.
            # The spinner returning is Codex's reliable resume signal.
            self._turn(session_id).spun = True
            target: State = "working"
        elif s.state != "working" or turn is None or not turn.spun:
            return []
        else:
            target = "done"
        return self._apply_state(session_id, target, self._clock(), source="codex_title")

    def agent_exited(self, session_id: str) -> list[str]:
        self.reset_turn(session_id)
        self._trust_prompts.discard(session_id)
        cleared = self.reg.set_background(session_id, ())
        cleared = self.reg.set_stopped_on(session_id, None) or cleared
        cleared = self.reg.set_subagents_written_at(session_id, None) or cleared
        return [session_id] if self.reg.set_state(session_id, "idle") or cleared else []

    def mark_seen(self, task_id: str) -> list[str]:
        sessions = self.reg.for_task(task_id)
        for s in sessions:
            # A completion seen while a prompt covers it must not come back unseen when it closes.
            if (turn := self._turns.get(s.session_id)) is not None and turn.before_prompt == "done":
                turn.before_prompt = "idle"
        return [s.session_id for s in sessions if s.state == "done" and self.reg.set_state(s.session_id, "idle")]
