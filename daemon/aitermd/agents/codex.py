"""What the daemon knows of Codex: its hook payloads, the spinner in its tab's title, its rollout files
(turn boundaries, context fill, version, account rate limits), and which thread each tab runs. The
rollout reader does blocking file I/O: the service runs it on a worker thread."""
from __future__ import annotations

import contextlib
import json
import logging
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal, NamedTuple

from .. import corroboration
from ..hook_events import SIMPLE_EVENTS, HookEvent, session_start, subagent_event, submitted_prompt
from ..iterm_port import ItermPort
from ..jsonl import JsonlCursor, records_newest_first
from ..models import CODEX_THREAD_TAG, ITERM_SESSION_FIELD, RawSession, SessionInfo, Usage
from ..sessions import SessionRegistry
from ..status import Evidence, StatusEngine
from ..text import iso_seconds, nonempty_string
from ..usage import clamped_percent, finite_number, usage_window

log = logging.getLogger(__name__)

# How long, in minutes, Codex says its five-hour and weekly rate-limit windows are.
FIVE_HOUR_MINS, WEEK_MINS = 300, 10080


# -- hooks ---------------------------------------------------------------------------------------
def parse_codex_hook(p: dict[str, Any]) -> HookEvent | None:
    if not isinstance(p, dict):
        return None
    name = nonempty_string(p.get("hook_event_name"))
    sid, cwd = (nonempty_string(p.get(key)) for key in ("session_id", "cwd"))
    iterm_session_id = nonempty_string(p.get(ITERM_SESSION_FIELD))
    if name == "SessionStart":
        return HookEvent("codex", session_start(p), sid, cwd, iterm_session_id=iterm_session_id, event_name=name)
    if name in {"SubagentStart", "SubagentStop"}:
        child = subagent_event(name, p)
        return HookEvent("codex", child[0], sid, cwd, subagent_id=child[1], iterm_session_id=iterm_session_id, event_name=name,
                         subagent_label=nonempty_string(p.get("agent_type"))) if child else None
    if name in SIMPLE_EVENTS:
        return HookEvent("codex", SIMPLE_EVENTS[name], sid, cwd, iterm_session_id=iterm_session_id, event_name=name,
                         prompt=submitted_prompt(name, p))
    return None


# -- the tab title -------------------------------------------------------------------------------
def has_spinner(title: str) -> bool:
    """Whether the title starts with the braille spinner Codex draws while its turn runs."""
    return bool(title) and "⠀" <= title[0] <= "⣿"


def title_evidence(title: str, at: float) -> Evidence:
    """What the tab's title, read at `at`, says of the turn: a spinner, working -- also the reliable
    resume signal after a permission or elicitation answer, which emits no UserPromptSubmit -- and
    none, done."""
    return Evidence("working" if has_spinner(title) else "done", at, "codex_title")


# -- rollout files -------------------------------------------------------------------------------
# How often the whole sessions tree is listed again. In between, only the rollouts last seen to be
# the newest, the tracked threads' own and today's directory are looked at: a new session writes
# under today's date, and a resumed one appends to a rollout already known.
LIST_SECONDS = 30.0
RECENT_KEPT = 8
# What every `token_count` record contains, so a line without it can be skipped unparsed.
_TOKEN_COUNT = b'"token_count"'
# The same for a `session_meta` record, the one that names the Codex version.
_SESSION_META = b'"session_meta"'


# Account usage and thread corroboration share this off-loop name: their reader caches
# are not locked, so an outstanding read must hold back both kinds of work.
CODEX_READ = "the Codex rollout read"
READ_BYTES = 8 * 1024 * 1024
MAX_CHILD_LABELS = 4096
# A turn boundary a rollout records: a task started, or one completed.
Boundary = Literal["working", "done"]


class CodexReading(NamedTuple):
    context: int | None
    version: str | None
    turn: tuple[Boundary, float] | None
    child_labels: tuple[tuple[str, str], ...] = ()


@dataclass(slots=True)
class _RolloutCursor(JsonlCursor):
    version: str | None = None
    turn: tuple[Boundary, float] | None = None
    context: int | None = None
    child_labels: dict[str, str] = field(default_factory=dict)
    # Whether the first clipped tail line still needs dropping once it is complete.
    clipped: bool = False

    def consume(self, lines: list[bytes], thread_id: str) -> None:
        for line in lines:
            if not any(marker in line for marker in (_SESSION_META, b'"task_started"', b'"task_complete"',
                                                     b'"turn_aborted"', b'"SubAgentActivity"', _TOKEN_COUNT)):
                continue
            try:
                record = json.loads(line)
            except ValueError:
                logging.getLogger(__name__).warning("skipping an unparsable Codex rollout line for thread %s", thread_id)
                continue
            if not isinstance(record, dict) or not isinstance(payload := record.get("payload"), dict):
                continue
            if record.get("type") == "session_meta" and payload.get("id") == thread_id:
                if (version := nonempty_string(payload.get("cli_version"))) is not None:
                    self.version = version
            if record.get("type") != "event_msg":
                continue
            kind = payload.get("type")
            if kind in ("turn_aborted", "task_started", "task_complete"):
                at = iso_seconds(record.get("timestamp"))
                self.turn = (("working" if kind == "task_started" else "done", at)
                             if kind != "turn_aborted" and at is not None else None)
            elif kind == "token_count":
                info = payload.get("info")
                last = info.get("last_token_usage") if isinstance(info, dict) else None
                total = finite_number(last.get("total_tokens")) if isinstance(last, dict) else None
                window = finite_number(info.get("model_context_window")) if isinstance(info, dict) else None
                if total is not None and window is not None and window > 0:
                    if (percent := clamped_percent(total / window * 100)) is not None:
                        self.context = percent
            elif kind == "item_completed" and isinstance(item := payload.get("item"), dict):
                if (item.get("type") == "SubAgentActivity" and item.get("kind") == "started"
                        and (child := nonempty_string(item.get("agent_thread_id")))
                        and (path := nonempty_string(item.get("agent_path")))):
                    label = " ".join(path.rsplit("/", 1)[-1].replace("_", " ").replace("-", " ").split())
                    if label:
                        self.child_labels[child] = label[0].upper() + label[1:]
                        while len(self.child_labels) > MAX_CHILD_LABELS:
                            del self.child_labels[next(iter(self.child_labels))]


class CodexSessionFiles:
    def __init__(self, root: Path | None = None, clock: Callable[[], float] = time.monotonic):
        self.root = root or Path.home() / ".codex" / "sessions"
        self._clock = clock
        self._paths: dict[str, Path] = {}
        # Thread id -> when a full listing last failed to find its rollout.
        self._missed: dict[str, float] = {}
        self._listed_at: float | None = None
        self._batch_listing = False
        self._tree: list[Path] | None = None
        self._recent: list[Path] = []
        # Rollout -> the version, turn and context followed from its last read.
        self._rollouts: dict[Path, _RolloutCursor] = {}
        # The rollouts `rate_limits()` last consulted, by (path, mtime), and what they said: the
        # tick asks every two seconds, and a file nobody has written to has nothing new to say.
        self._limits_seen: tuple[tuple[Path, int], ...] | None = None
        self._limits_answer: tuple[dict[str, Any], int | None] | None = None

    def begin_tick(self) -> None:
        """Share any full tree discovery across usage and thread reads in this tick."""
        self._batch_listing, self._tree = True, None

    def retain(self, session_ids: set[str]) -> None:
        """Drops what is cached for threads no tab is running any more."""
        for cache in (self._paths, self._missed):
            for session_id in cache.keys() - session_ids:
                del cache[session_id]
        for path in self._rollouts.keys() - set(self._paths.values()):
            del self._rollouts[path]

    def reading(self, thread_id: str) -> CodexReading:
        """Follow one rollout for the thread's version, last turn boundary and context fill."""
        try:
            if (path := self._path_for(thread_id)) is None:
                return CodexReading(None, None, None)
            stat = path.stat()
            old = self._rollouts.get(path)
            first = b""
            if old is None or old.rewritten(stat.st_ino, stat.st_size):
                cursor = _RolloutCursor(stat.st_ino)
                if stat.st_size > READ_BYTES:
                    with path.open("rb") as stream:
                        first = stream.readline(READ_BYTES)
                    cursor.offset = stat.st_size - READ_BYTES
                    cursor.clipped = True
            else:
                if old.offset == stat.st_size:
                    return CodexReading(old.context, old.version, old.turn, tuple(old.child_labels.items()))
                cursor = replace(old, child_labels=dict(old.child_labels))
            lines = cursor.read_lines(path, stat.st_size)
        except OSError:
            return CodexReading(None, None, None)
        if first.endswith(b"\n"):
            cursor.consume([first], thread_id)
        if cursor.clipped and lines:
            lines = lines[1:]
            cursor.clipped = False
        cursor.consume(lines, thread_id)
        self._rollouts[path] = cursor
        return CodexReading(cursor.context, cursor.version, cursor.turn, tuple(cursor.child_labels.items()))

    def rate_limits(self) -> tuple[dict[str, Any], int | None] | None:
        """The newest `rate_limits` block any Codex session has written, with the record's own
        timestamp (epoch seconds, None if unreadable) as the number's age. Rate limits are
        account-wide, so the most recently written rollout is the truth whichever session AiTerm
        happens to track -- and a Codex run outside AiTerm counts just the same. Only the few
        newest rollouts are consulted: a file without a single such record is read in full, and
        a hundred of them on every tick would not be."""
        newest = self._newest_rollouts(3)
        if newest == self._limits_seen:
            return self._limits_answer
        try:
            answer = self._read_rate_limits([path for path, _ in newest])
        except FileNotFoundError:
            return None
        self._limits_seen, self._limits_answer = newest, answer
        return self._limits_answer

    def _read_rate_limits(self, paths: list[Path]) -> tuple[dict[str, Any], int | None] | None:
        for path in paths:
            for record, payload in self._token_counts(path):
                limits = payload.get("rate_limits")
                if isinstance(limits, dict):
                    return limits, _epoch(record.get("timestamp"))
        return None

    def _newest_rollouts(self, count: int) -> tuple[tuple[Path, int], ...]:
        """The `count` most recently written rollouts with their mtimes, newest first."""
        if self._listed_at is None or self._clock() - self._listed_at >= LIST_SECONDS:
            self._listed_at = self._clock()
            candidates = set(self._list_all())
        else:
            candidates = {*self._recent, *self._paths.values(), *self._list_today()}
        stamped = [(path, mtime) for path in candidates if (mtime := _mtime(path)) is not None]
        stamped.sort(key=lambda item: item[1], reverse=True)
        self._recent = [path for path, _ in stamped[:RECENT_KEPT]]
        return tuple(stamped[:count])

    def _path_for(self, session_id: str) -> Path | None:
        cached = self._paths.get(session_id)
        if cached is not None and cached.is_file():
            return cached
        # A thread whose rollout is nowhere is looked for across the whole tree once per
        # LIST_SECONDS; in between only under today's date, where a new thread's rollout appears.
        missed = self._missed.get(session_id)
        full = missed is None or self._clock() - missed >= LIST_SECONDS
        suffix = f"-{session_id}.jsonl"
        shared_tree = full and self._tree is not None
        matches = [path for path in (self._list_all() if full else self._list_today()) if path.name.endswith(suffix)]
        path = max(matches, key=lambda item: _mtime(item) or -1, default=None)
        if path is None and shared_tree:
            # The shared tree is a snapshot. A new rollout may already exist under today's
            # date, even when the tree was listed earlier in this tick.
            today = [candidate for candidate in self._list_today() if candidate.name.endswith(suffix)]
            path = max(today, key=lambda item: _mtime(item) or -1, default=None)
        if path is None:
            if full:
                self._missed[session_id] = self._clock()
            return None
        self._missed.pop(session_id, None)
        self._paths[session_id] = path
        return path

    def _list_all(self) -> list[Path]:
        if self._tree is not None:
            return self._tree
        try:
            paths = list(self.root.rglob("rollout-*.jsonl"))
            if self._batch_listing:
                self._tree = paths
            return paths
        except OSError:
            return []

    def _list_today(self) -> list[Path]:
        days = {datetime.now().strftime("%Y/%m/%d"), datetime.now(UTC).strftime("%Y/%m/%d")}
        found: list[Path] = []
        for day in days:
            with contextlib.suppress(OSError):
                found += (self.root / day).glob("rollout-*.jsonl")
        return found

    @classmethod
    def _token_counts(cls, path: Path) -> Iterator[tuple[dict[str, Any], dict[str, Any]]]:
        """Every `token_count` event of a rollout, newest first, with the record that carries it."""
        # Most of a rollout is messages and tool output: parsing them to find that they are not
        # token counts made a rollout with none cost tens of milliseconds a megabyte.
        for record in records_newest_first(path, None, containing=_TOKEN_COUNT):
            if not isinstance(record, dict) or record.get("type") != "event_msg":
                continue
            payload = record.get("payload")
            if isinstance(payload, dict) and payload.get("type") == "token_count":
                yield record, payload


def _mtime(path: Path) -> int | None:
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return None


def _epoch(timestamp: Any) -> int | None:
    """Codex stamps records in RFC 3339 UTC (`2026-09-22T14:31:09.229Z`)."""
    seconds = iso_seconds(timestamp)
    return int(seconds) if seconds is not None else None


def rollout_evidence(boundary: tuple[Boundary, float]) -> Evidence:
    """What a rollout's last turn boundary says: working from its start, done from its end, at the
    time the record gives."""
    state, at = boundary
    return Evidence(state, at, "codex_rollout")


def parse_codex_rate_limits(rl: dict[str, Any], updated_at: int) -> Usage:
    """The `rate_limits` block Codex writes into every `token_count` record of its rollout file.
    `primary`/`secondary` are told apart by `window_minutes` (300 → 5h, 10080 → wk); a window of
    unknown length fills 5h first, then wk."""
    five_hour = seven_day = None
    for key in ("primary", "secondary"):
        w = usage_window(rl.get(key), "used_percent")
        if w is None:
            continue
        mins = rl[key].get("window_minutes")
        if mins == WEEK_MINS and not isinstance(mins, bool) and seven_day is None:
            seven_day = w
        elif mins == FIVE_HOUR_MINS and not isinstance(mins, bool) and five_hour is None:
            five_hour = w
        elif five_hour is None:
            five_hour = w
        elif seven_day is None:
            seven_day = w
    return Usage(five_hour, seven_day, None, updated_at)


# -- which thread each tab runs ------------------------------------------------------------------
# Learnt from hooks placed on the tab by evidence, valid only for the process that posted them, and
# kept on the tab's iTerm2 variable so a helper restart recovers it.
@dataclass(slots=True)
class CodexBinding:
    """The Codex thread a tab runs, replaced by every Codex hook placed on the tab by evidence. A
    non-None `pending_generation` leaves the process open until a newer snapshot, because a
    replacement Codex can post before iTerm2 reports its new pid."""
    thread_id: str
    pid: int | None
    pending_generation: int | None


class CodexThreads:
    def __init__(self, registry: SessionRegistry, iterm: ItermPort):
        self.registry, self.iterm = registry, iterm
        self._bindings: dict[str, CodexBinding] = {}
        self._generation = 0
        # The (pid, thread) last written to each tab's tag.
        self._written: dict[str, tuple[int, str]] = {}

    def restore(self, raw: list[RawSession]) -> list[str]:
        """Called after every registry snapshot. Validates every binding, including those of tabs
        no longer running Codex, then binds each Codex tab that has none to the thread its tag saved
        for its current process. Returns the tabs whose conversation the tag supplied."""
        self._generation += 1
        for sid in tuple(self._bindings):
            self._validate(sid)
        restored: list[str] = []
        for r in raw:
            session = self.registry.get(r.session_id)
            if (session is None or session.agent != "codex" or not session.job_pid
                    or r.session_id in self._bindings or (thread := _saved_thread(r, session.job_pid)) is None):
                continue
            self._bindings[r.session_id] = CodexBinding(thread, session.job_pid, None)
            self._written[r.session_id] = (session.job_pid, thread)
            if session.conversation_id is None and self.registry.set_conversation(r.session_id, thread):
                restored.append(r.session_id)
        return restored

    def bind(self, session_id: str, thread: str, hook_event: str | None) -> None:
        """Records the thread a Codex hook placed on the tab by evidence names."""
        if hook_event in ("SubagentStart", "SubagentStop"):
            return
        session = self.registry.get(session_id)
        pid = session.job_pid if session else None
        current = self._bindings.get(session_id)
        if hook_event == "Stop":
            # A final hook cannot authorize this thread to follow a future process id. Binding it
            # to the currently observed process makes replacement invalidate it.
            self._bindings[session_id] = CodexBinding(thread, pid, None)
        elif current is None or current.thread_id != thread or hook_event == "SessionStart":
            # A different thread, or an explicit resume of the same thread, may belong to a
            # replacement process whose pid iTerm2 has not reported yet.
            self._bindings[session_id] = CodexBinding(thread, pid, self._generation)

    def thread(self, session_id: str) -> str | None:
        """The tab's thread as the last snapshot and the hooks since left it: pids change only at a
        snapshot, where `restore` validates every binding."""
        binding = self._bindings.get(session_id)
        return binding.thread_id if binding else None

    def forget(self, session_id: str) -> None:
        self._bindings.pop(session_id, None)
        self._written.pop(session_id, None)

    async def remember(self, sessions: list[SessionInfo]) -> None:
        """Keeps each tab's thread on its tag with the process it belongs to, writing only what changed."""
        for captured in sessions:
            if (session := self.registry.get(captured.session_id)) is None:
                continue
            sid, pid = session.session_id, session.job_pid
            if session.agent != "codex" or pid is None or (thread := self.thread(sid)) is None:
                continue
            identity = (pid, thread)
            if self._written.get(sid) == identity:
                continue
            try:
                await self.iterm.set_session_tags(sid, {CODEX_THREAD_TAG: json.dumps({"pid": pid, "thread": thread})})
            except Exception:  # one tab's write must not cost the others'
                log.exception("remembering the Codex thread of session %s failed", sid)
                continue
            self._written[sid] = identity

    def _validate(self, session_id: str) -> None:
        binding = self._bindings[session_id]
        session = self.registry.get(session_id)
        if session is None or session.agent != "codex":
            del self._bindings[session_id]
        elif binding.pending_generation is not None:
            if self._generation > binding.pending_generation:
                binding.pid, binding.pending_generation = session.job_pid, None
        elif session.job_pid != binding.pid:
            del self._bindings[session_id]


def _saved_thread(raw: RawSession, pid: int) -> str | None:
    """The thread the tab's tag saved for process `pid`, if it saved one for that process."""
    try:
        saved = json.loads(raw.user_vars.get(CODEX_THREAD_TAG, ""))
    except (ValueError, TypeError):
        return None
    if (isinstance(saved, dict) and type(saved.get("pid")) is int and saved["pid"] == pid
            and isinstance(thread := saved.get("thread"), str) and thread.strip()):
        return thread
    return None


# -- the tick's read plans -----------------------------------------------------------------------
def tab_threads(threads: CodexThreads, sessions: list[SessionInfo]) -> dict[str, str]:
    """The thread each Codex tab runs, as the snapshot left them: what the rollout plan reads."""
    return {s.session_id: thread for s in sessions if s.agent == "codex" and (thread := threads.thread(s.session_id))}


def rollout_plan(registry: SessionRegistry, status: StatusEngine, threads: CodexThreads, files: CodexSessionFiles,
                 tabs: dict[str, str]) -> corroboration.ReadPlan[dict[str, CodexReading | None]]:
    """Each tab's rollout, by the thread `tabs` names: its context fill, version and last turn boundary."""
    captured = dict(tabs)
    generations = {sid: status.child_generations(sid) for sid in captured}

    def key(session: SessionInfo) -> corroboration.SessionKey:
        return corroboration.SessionKey.capture(session, threads.thread(session.session_id))

    keys = {sid: corroboration.SessionKey.capture(session, thread) for sid, thread in captured.items()
            if (session := registry.get(sid)) is not None}

    def read() -> dict[str, CodexReading | None]:
        readings: dict[str, CodexReading | None] = {}
        for thread in set(captured.values()):
            try:
                readings[thread] = files.reading(thread)
            except Exception:  # a different thread's file must still be read
                log.exception("reading the Codex rollout of thread %s failed", thread)
                readings[thread] = None
        files.retain(set(captured.values()))
        return {sid: readings[thread] for sid, thread in captured.items()}

    def apply(readings: dict[str, CodexReading | None]) -> list[str]:
        changed: list[str] = []
        for sid, reading in readings.items():
            value = reading or CodexReading(None, None, None)
            registry.set_cli_version(sid, value.version)
            changed += status.apply_metadata(sid, context=value.context)
            if value.turn is not None:
                changed += status.apply_evidence(sid, rollout_evidence(value.turn))
            changed += status.apply_child_labels(sid, value.child_labels, generations[sid])
        return changed

    return corroboration.ReadPlan(CODEX_READ, read, dict.fromkeys(captured), apply, keys, key)
