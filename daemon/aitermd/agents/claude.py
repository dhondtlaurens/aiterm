"""What the daemon knows of Claude Code: its hook and status-line payloads, its session files, its
subagents' and its own transcripts, and the tick's read plans that turn each into the status engine's
evidence. The readers do blocking file I/O: the service runs them on a worker thread."""
from __future__ import annotations

import json
import math
import os
import re
import time
from collections.abc import Callable, Collection, Iterator, Mapping
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from .. import corroboration
from ..hook_events import SIMPLE_EVENTS, HookEvent, StatusLine, session_start, subagent_event, submitted_prompt
from ..jsonl import JsonlCursor, records_newest_first
from ..models import ITERM_SESSION_FIELD, BackgroundJob, SessionInfo, Usage
from ..sessions import SessionRegistry
from ..status import Evidence, EvidenceState, StatusEngine
from ..text import iso_seconds, nonempty_string
from ..usage import clamped_percent, usage_window

# -- hooks and status line -----------------------------------------------------------------------
NEEDS_INPUT_NOTIFICATIONS = {"permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"}

# Observed native task-notification outcomes: terminal display evidence, never a success verdict.
CLAUDE_TERMINAL_TASK_STATUSES = frozenset({"completed", "failed", "killed", "stopped"})


def _claude_subagent_transcript(p: dict[str, Any], child: str) -> str | None:
    """The child's transcript. SubagentStart carries only the session's, `<dir>/<session>.jsonl`;
    Claude Code writes the child's beside it, at `<dir>/<session>/subagents/agent-<id>.jsonl`, or
    files it a directory or two further down, where the reader looks too. A path the hook gives for
    the child itself (`agent_transcript_path`, which so far only SubagentStop has carried) wins."""
    if (own := nonempty_string(p.get("agent_transcript_path"))) is not None:
        return own
    session = nonempty_string(p.get("transcript_path"))
    if session is None or not session.endswith(".jsonl"):
        return None
    return os.path.join(session.removesuffix(".jsonl"), "subagents", f"agent-{child}.jsonl")


# The `background_tasks` types whose children the daemon can match by id: a subagent's task id is its
# agent_id, and shells, monitors and MCP tasks run no agent. A teammate's task id is not the agent_id
# its hooks carry, and a workflow's agents sit behind the workflow's own id.
CLAUDE_MATCHABLE_TASK_TYPES = frozenset({"subagent", "shell", "monitor", "MCP task"})
# The statuses Claude Code lists a task under while it is in flight.
CLAUDE_IN_FLIGHT_TASK_STATUSES = frozenset({"running", "pending"})
# How Claude Code describes the watch it keeps on an artifact it published or was asked to watch: a monitor with no
# MCP server that runs for the rest of the session, which Claude Code counts as no activity (`ambient`, a flag its
# hooks do not carry). Its description is all a Stop says of it (Claude Code 2.1.308).
CLAUDE_ARTIFACT_WATCH_PREFIX = "live updates for artifact "


def _claude_background_work(tasks: Any) -> tuple[BackgroundJob, ...] | None:
    """What a Stop's `background_tasks` lists as in flight: the shells, subagents, monitors and other work Claude Code
    resumes the session for once each ends (a dev server left running among them), each by its kind, a subagent with
    its agent_id. None when there is no list to read."""
    if not isinstance(tasks, list):
        return None
    work: list[BackgroundJob] = []
    for task in tasks:
        if not isinstance(task, dict) or (kind := nonempty_string(task.get("type"))) is None:
            continue
        if nonempty_string(task.get("status")) not in CLAUDE_IN_FLIGHT_TASK_STATUSES or _claude_artifact_watch(task):
            continue
        said = nonempty_string(task.get("command")) if kind == "shell" else None
        if (said := said or nonempty_string(task.get("description"))) is None:
            continue
        if kind != "subagent":
            work.append(BackgroundJob("shell" if kind == "shell" else "monitor" if kind == "monitor" else "task", said,
                                      task_id=nonempty_string(task.get("id"))))
        # Only a subagent named by its agent_id is a child the status engine can count.
        elif (child := nonempty_string(task.get("id"))) is not None:
            work.append(BackgroundJob("subagent", said, child))
    return tuple(work)


def _claude_display_shells(tasks: Any) -> tuple[BackgroundJob, ...] | None:
    if not isinstance(tasks, list) or any(not isinstance(task, dict) or not nonempty_string(task.get("type")) for task in tasks):
        return None
    for task in tasks:
        if task["type"] != "shell":
            continue
        status = nonempty_string(task.get("status"))
        if status not in CLAUDE_IN_FLIGHT_TASK_STATUSES | CLAUDE_TERMINAL_TASK_STATUSES:
            return None
        if status in CLAUDE_IN_FLIGHT_TASK_STATUSES and not (
                nonempty_string(task.get("id")) and (nonempty_string(task.get("command")) or nonempty_string(task.get("description")))):
            return None
    return tuple(job for job in (_claude_background_work(tasks) or ()) if job.kind == "shell")


def _claude_artifact_watch(task: dict[str, Any]) -> bool:
    """Whether a `background_tasks` entry is Claude Code watching an artifact for comments, which never ends and
    wakes the session only when someone comments: no work in flight."""
    said = nonempty_string(task.get("description"))
    return (task.get("type") == "monitor" and task.get("server") is None
            and said is not None and said.startswith(CLAUDE_ARTIFACT_WATCH_PREFIX))


def _claude_running_subagents(tasks: Any) -> frozenset[str] | None:
    """The agent ids of the subagents a Stop's `background_tasks` lists as in flight. None when the
    list cannot prove a counted child gone: it is absent (an older Claude Code, or a registry it could
    not reach), malformed, or holds work whose agents it does not name by their agent_id."""
    if not isinstance(tasks, list):
        return None
    running: set[str] = set()
    for task in tasks:
        if not isinstance(task, dict) or nonempty_string(task.get("type")) not in CLAUDE_MATCHABLE_TASK_TYPES:
            return None
        if task["type"] != "subagent" or nonempty_string(task.get("status")) not in CLAUDE_IN_FLIGHT_TASK_STATUSES:
            continue
        if (child := nonempty_string(task.get("id"))) is None:
            return None
        running.add(child)
    return frozenset(running)


def parse_claude_hook(p: dict[str, Any]) -> HookEvent | None:
    # Another CLI that runs ~/.claude/settings.json hooks (Grok Build does) sends `hookEventName`,
    # which Claude never does: such a post is not Claude's.
    if not isinstance(p, dict) or "hookEventName" in p:
        return None
    ev = _claude_event(p)
    transcript = None if nonempty_string(p.get("agent_id")) else nonempty_string(p.get("transcript_path"))
    return replace(ev, transcript=transcript) if ev is not None else None


def _claude_event(p: dict[str, Any]) -> HookEvent | None:
    name = nonempty_string(p.get("hook_event_name"))
    sid, cwd = nonempty_string(p.get("session_id")), nonempty_string(p.get("cwd"))
    if name == "SessionStart":
        return HookEvent("claude", session_start(p), sid, cwd, event_name=name)
    if name in {"SubagentStart", "SubagentStop"}:
        if (child := subagent_event(name, p)) is None:
            return None
        transcript = _claude_subagent_transcript(p, child[1]) if name == "SubagentStart" else None
        return HookEvent("claude", child[0], sid, cwd, subagent_id=child[1], subagent_transcript=transcript, event_name=name,
                         subagent_label=nonempty_string(p.get("agent_type")))
    if name == "Stop":
        tasks = p.get("background_tasks")
        return HookEvent("claude", "done", sid, cwd, running_subagents=_claude_running_subagents(tasks),
                         background_work=_claude_background_work(tasks), display_shells=_claude_display_shells(tasks), event_name=name)
    if name == "StopFailure":
        # Fired in place of Stop when an API error ended the turn; Claude Code names one it cannot tell `unknown`.
        return HookEvent("claude", "done", sid, cwd, event_name=name, stop_error=nonempty_string(p.get("error")) or "unknown")
    if name in SIMPLE_EVENTS:
        return HookEvent("claude", SIMPLE_EVENTS[name], sid, cwd, event_name=name, prompt=submitted_prompt(name, p))
    if name == "Notification":
        nt = nonempty_string(p.get("notification_type"))
        if nt in NEEDS_INPUT_NOTIFICATIONS:
            return HookEvent("claude", "needsInput", sid, cwd, event_name=name)
        if nt == "agent_completed":
            return HookEvent("claude", "done", sid, cwd, event_name=name)
    return None


def _context_percent(p: dict[str, Any]) -> int | None:
    """`context_window.used_percentage`: how full *this conversation* is. Unlike the rate-limit
    windows it arrives from one session, so the service resolves that session and the status engine
    promotes it to the task's latest value rather than putting it in the vendor's `Usage`. Clamped,
    because the payload is another process's arithmetic and the ring cannot render 140%."""
    cw = p.get("context_window")
    if not isinstance(cw, dict):
        return None
    return clamped_percent(cw.get("used_percentage"))


def _context_tokens(p: dict[str, Any]) -> int | None:
    """Current input context, not session billing totals or output. Unknown remains unknown."""
    cw = p.get("context_window")
    if not isinstance(cw, dict):
        return None
    usage = cw.get("current_usage")
    if isinstance(usage, dict):
        counts: list[int] = []
        for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
            value = usage.get(key)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                break
            counts.append(value)
        if len(counts) == 3 and (total := sum(counts)) <= 2**63 - 1:
            return total
    percent, size = cw.get("used_percentage"), cw.get("context_window_size")
    if (isinstance(percent, (int, float)) and not isinstance(percent, bool) and math.isfinite(percent) and 0 <= percent <= 100
            and isinstance(size, int) and not isinstance(size, bool) and 0 < size <= 2**63 - 1):
        return round(percent * size / 100)
    return None


def parse_claude_statusline(p: dict[str, Any], now: int) -> StatusLine:
    return StatusLine(
        parse_claude_rate_limits(p.get("rate_limits"), now),
        nonempty_string(p.get("session_id")), nonempty_string(p.get("cwd")),
        nonempty_string(p.get(ITERM_SESSION_FIELD)),
        _context_percent(p),
        nonempty_string(p.get("transcript_path")), _context_tokens(p),
    )


def parse_claude_rate_limits(rl: Any, updated_at: int) -> Usage:
    """The `rate_limits` block of Claude Code's status-line payload, windows keyed by name."""
    if not isinstance(rl, dict):
        rl = {}
    five_hour, seven_day, spend = (usage_window(rl.get(key), "used_percentage") for key in ("five_hour", "seven_day", "spend_limit"))
    return Usage(five_hour, seven_day, spend, updated_at)


# -- session files -------------------------------------------------------------------------------
@dataclass(frozen=True, slots=True)
class ClaudeSessionFile:
    pid: int
    session_id: str
    cwd: str
    status: str
    # When Claude last wrote the file (its st_mtime): a status older than the latest hook is stale.
    written_at: float
    # The Claude Code version that writes the file: the running process's own, from its start, even
    # in a conversation an older version began. None when the file names none.
    version: str | None = None


# A session file as last parsed, keyed by (st_mtime_ns, st_size): only a file Claude has rewritten
# since needs parsing again.
_FileEntry = tuple[tuple[int, int], ClaudeSessionFile | None]


class ClaudeSessionFiles:
    def __init__(self, root: Path | None = None):
        self.root = root or Path.home() / ".claude" / "sessions"
        # Every session file as last parsed. A tick reads each Claude tab's file and a hook post
        # asks for a pid by session id; both go through this, so an unchanged file is not reparsed.
        self._index: dict[Path, _FileEntry] = {}

    def configure(self, directory: Path) -> None:
        """The app resolves the login shell's configuration."""
        root = directory / "sessions"
        if root != self.root:
            self.root = root
            self._index.clear()

    def read(self, pid: int) -> ClaudeSessionFile | None:
        path = self.root / f"{pid}.json"
        if (entry := self._load(path)) is None:
            self._index.pop(path, None)
            return None
        self._index[path] = entry
        return entry[1]

    def known_pid(self, session_id: str) -> int | None:
        """Last successful index evidence, without I/O while the resolver's worker is unavailable."""
        return next((cached.pid for _, cached in tuple(self._index.values())
                     if cached is not None and cached.session_id == session_id), None)

    def indexed_pid(self, session_id: str) -> int | None:
        """The pid of a conversation already read by a tick or an earlier post, with just that one
        file checked again: most posts name one. None for a renamed, removed or unknown one."""
        for _, cached in tuple(self._index.values()):
            if cached and cached.session_id == session_id:
                if (current := self.read(cached.pid)) and current.session_id == session_id:
                    return current.pid
        return None

    def pid_for_session(self, session_id: str) -> int | None:
        """`indexed_pid`, else every session file read to find the conversation."""
        if (pid := self.indexed_pid(session_id)) is not None:
            return pid
        root = self.root
        index = {path: entry for path in root.glob("*.json") if (entry := self._load(path)) is not None}
        self._index = index
        return next((f.pid for _, f in index.values() if f and f.session_id == session_id), None)

    def _load(self, path: Path) -> _FileEntry | None:
        """The file at `path`, reparsed only if it changed since the last look; None when it is gone."""
        try:
            st = path.stat()
        except OSError:
            return None
        stamp = (st.st_mtime_ns, st.st_size)
        cached = self._index.get(path)
        if cached is not None and cached[0] == stamp:
            return cached
        try:
            return stamp, self._parse(path, st.st_mtime)
        except OSError:
            # A failed read is not a parsed empty file; retry it on the next lookup.
            return None

    @staticmethod
    def _parse(path: Path, written_at: float) -> ClaudeSessionFile | None:
        try:
            d = json.loads(path.read_text())
            if not isinstance(d, dict):
                return None
            version = d.get("version")
            return ClaudeSessionFile(int(d["pid"]), str(d["sessionId"]), str(d.get("cwd", "")), str(d.get("status", "")),
                                     written_at, version if isinstance(version, str) and version else None)
        except (ValueError, KeyError, TypeError, OverflowError):
            return None


# What each status Claude writes into its session file says of the turn. `waiting` keeps a hook's
# input request visible; once the user answers, Claude writes an active status again, which restores
# working although no UserPromptSubmit hook is emitted. `idle` and `shell` say the turn ended.
FILE_STATUS: dict[str, EvidenceState] = {
    "busy": "working", "thinking": "working", "running": "working",
    "waiting": "needsInput", "idle": "done", "shell": "done",
}


def file_evidence(status: str, written_at: float) -> Evidence | None:
    """What a session file written at `written_at` with `status` says of the turn. A status this
    daemon does not know says nothing -- least of all that the turn ended."""
    state = FILE_STATUS.get(status)
    return Evidence(state, written_at, "claude_file") if state is not None else None


# -- subagent transcripts ------------------------------------------------------------------------
# How much of a transcript's end is read. The records that end a child -- an interruption, a
# SubagentStop hook's attachment -- are a few hundred bytes; a transcript grows to megabytes.
TAIL_BYTES = 64 * 1024
# The text Claude Code writes as a user message when it aborts an agent's run: Esc, or its stream
# watchdog ("Agent stalled: no progress for 600s"). Mid-tool it reads "... for tool use]".
INTERRUPTED = "[Request interrupted by user"


@dataclass(frozen=True, slots=True)
class TranscriptTail:
    """What the end of a subagent's transcript says; `written_at` is its wall-clock mtime."""
    written_at: float
    # When the last record ends the child's run -- an interruption, or a SubagentStop hook that ran with no prompt before
    # it for the child to answer -- the time that record gives, or `written_at` when it gives none. Claude writes in
    # batches, so a record can reach the file well after its time. None while the last record is no such end.
    ended_at: float | None


def _user_content(record: dict[str, Any]) -> str | list[Any] | None:
    """A user message's content: its text, or its blocks. None for any other record."""
    if record.get("type") != "user" or not isinstance(message := record.get("message"), dict):
        return None
    content = message.get("content")
    return content if isinstance(content, (str, list)) else None


def _is_interruption(record: dict[str, Any]) -> bool:
    if isinstance(content := _user_content(record), str):
        return content.startswith(INTERRUPTED)
    return content is not None and any(
        isinstance(block, dict) and block.get("type") == "text" and isinstance(text := block.get("text"), str)
        and text.startswith(INTERRUPTED) for block in content)


def _is_prompt(record: dict[str, Any]) -> bool:
    """A user message for the child to answer: not a tool's result, nor the interruption that ends it."""
    if (content := _user_content(record)) is None or _is_interruption(record):
        return False
    return isinstance(content, str) or not any(
        isinstance(block, dict) and block.get("type") == "tool_result" for block in content)


def _is_subagent_stop(record: dict[str, Any]) -> bool:
    """A SubagentStop hook's attachment, whatever came of the hook: Claude sent it, so the child
    stopped, even if the daemon never saw the post."""
    return record.get("type") == "attachment" and isinstance(a := record.get("attachment"), dict) \
        and a.get("hookEvent") == "SubagentStop"


def _ending(records: Iterator[Any]) -> dict[str, Any] | None:
    """The last complete record in the tail if it ends the child, else None. A record still being
    written, or one longer than the tail, is neither of the small records that do. A SubagentStop
    does not when the last message before it is a prompt the child has yet to answer: Claude Code
    (2.1.283 to 2.1.308 at least) reminds a background child that ends its turn without handing
    back its report, fires SubagentStop, then runs the child on to answer the reminder."""
    if not isinstance(last := next(records, None), dict):
        return None
    if _is_interruption(last):
        return last
    if not _is_subagent_stop(last):
        return None
    # Past the attachments of the other hooks that ran with it. A record the tail cannot show leaves the stop standing.
    message = next((r for r in records if not isinstance(r, dict) or r.get("type") in ("user", "assistant")), None)
    return None if isinstance(message, dict) and _is_prompt(message) else last


# A transcript as last read, keyed by its stamp: only a file Claude has appended to since is read again.
_TailEntry = tuple[tuple[str, int, int, int, int], TranscriptTail]


class SubagentTranscripts:
    """Reads the end of Claude subagents' transcripts, for the status engine: whether a child's run
    is over, at its SubagentStop or without one, and when it last wrote. Blocking file I/O: the
    service runs it on a worker thread."""

    def __init__(self) -> None:
        self._cache: dict[str, _TailEntry] = {}
        self._real_paths: dict[str, str] = {}

    def read_all(self, paths: Collection[str]) -> dict[str, TranscriptTail | None]:
        """Each of `paths`, read: None for one that cannot be found or read. The cache keeps only those read."""
        tails = {path: self.read(path) for path in paths}
        self._cache = {path: entry for path, entry in self._cache.items() if tails.get(path) is not None}
        self._real_paths = {path: real for path, real in self._real_paths.items() if tails.get(path) is not None}
        return tails

    def read(self, path: str) -> TranscriptTail | None:
        """The end of the transcript at `path`, or of the same file one or two directories below
        its own: Claude Code files some agents under `subagents/<subdir>/`, and a workflow's under
        `subagents/workflows/<run>/`. None while none exists."""
        if (st := self._stat(path)) is None:
            return None
        real, stat = st
        identity = (real, stat.st_ino, stat.st_ctime_ns, stat.st_mtime_ns, stat.st_size)
        if (cached := self._cache.get(path)) is not None and cached[0] == identity:
            return cached[1]
        try:
            ending = _ending(records_newest_first(Path(real), TAIL_BYTES, discard_boundary=True))
        except OSError:
            return None
        tail = TranscriptTail(stat.st_mtime, None if ending is None else iso_seconds(ending.get("timestamp")) or stat.st_mtime)
        self._cache[path] = (identity, tail)
        return tail

    def _stat(self, path: str) -> tuple[str, os.stat_result] | None:
        try:
            return path, os.stat(path)
        except (OSError, ValueError):
            pass
        if real := self._real_paths.get(path):
            try:
                return real, os.stat(real)
            except (OSError, ValueError):
                self._real_paths.pop(path, None)
        try:
            p = Path(path)
            for pattern in (f"*/{p.name}", f"*/*/{p.name}"):
                for candidate in p.parent.glob(pattern):
                    stat = candidate.stat()
                    self._real_paths[path] = str(candidate)
                    return str(candidate), stat
        except (OSError, ValueError):
            pass
        return None


# -- background shells, from the parent's transcript, for display only, never command stdout ---
READ_BYTES = 8 * 1024 * 1024
MAX_TRACKED = 4096
_TASK_ID = re.compile(r"<task-id>([^<]+)</task-id>")
_STATUS = re.compile(r"<status>([^<]+)</status>")


@dataclass(frozen=True, slots=True)
class ShellTask:
    job: BackgroundJob
    started_at: float


@dataclass(frozen=True, slots=True)
class ShellReading:
    tasks: tuple[ShellTask, ...]
    ended: frozenset[str]


@dataclass(slots=True)
class _Transcript:
    path: str
    since: float
    cursor: JsonlCursor
    calls: dict[str, tuple[str, str]] = field(default_factory=dict)
    tasks: dict[str, ShellTask] = field(default_factory=dict)
    ended: set[str] = field(default_factory=set)
    uncertain: dict[str, float] = field(default_factory=dict)
    gap_at: float | None = None

    def consume(self, line: bytes, observed_at: float) -> None:
        try:
            record = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            self.gap_at = observed_at
            return
        if not isinstance(record, dict) or record.get("isSidechain") is True:
            return
        at = iso_seconds(record.get("timestamp"))
        if at is None or at < self.since:
            return
        attachment = record.get("attachment")
        if (record.get("type") == "attachment" and isinstance(attachment, dict)
                and attachment.get("type") == "queued_command" and attachment.get("commandMode") == "task-notification"):
            self.notice(attachment.get("prompt"), at)
        elif record.get("type") == "queue-operation" and record.get("operation") == "enqueue":
            self.notice(record.get("content"), at)
        message = record.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        blocks = content if isinstance(content, list) else [{"type": "text", "text": content}]
        if record.get("type") == "assistant":
            for block in blocks:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                name, call = block.get("name"), nonempty_string(block.get("id"))
                args = block.get("input")
                if call and isinstance(args, dict) and name in ("Bash", "TaskStop"):
                    value = nonempty_string(args.get("command" if name == "Bash" else "task_id"))
                    if value:
                        self.calls[call] = (name, value)
        elif record.get("type") == "user":
            results = [block for block in blocks if isinstance(block, dict) and block.get("type") == "tool_result"]
            native = record.get("toolUseResult")
            for block in results:
                pending = self.calls.pop(str(block.get("tool_use_id")), None)
                if pending is None:
                    continue
                name, value = pending
                if block.get("is_error") is True:
                    if name == "TaskStop" and value in self.tasks:
                        self.uncertain[value] = at
                    continue
                if not isinstance(native, dict) or len(results) != 1:
                    if name == "TaskStop" and value in self.tasks:
                        self.uncertain[value] = at
                    continue
                if name == "Bash" and "backgroundTaskId" in native:
                    task = nonempty_string(native.get("backgroundTaskId"))
                    if task is None or native.get("interrupted") is True:
                        self.gap_at = observed_at
                    elif task not in self.ended:
                        self.tasks.setdefault(task, ShellTask(BackgroundJob("shell", value, task_id=task), at))
                elif name == "TaskStop" and native.get("task_id") == value and native.get("task_type") == "local_bash":
                    self.finish(value)
                elif name == "TaskStop" and value in self.tasks:
                    self.uncertain[value] = at
            for block in blocks:
                if not isinstance(block, dict) or block.get("type") != "text":
                    continue
                self.notice(block.get("text"), at)
        if len(self.calls) > MAX_TRACKED or len(self.tasks) + len(self.ended) > MAX_TRACKED:
            self.gap_at = observed_at
            self.calls.clear()
            self.tasks.clear()
            self.ended.clear()
            self.uncertain.clear()

    def notice(self, value: object, at: float) -> None:
        if not isinstance(value, str) or not value.lstrip().startswith("<task-notification>"):
            return
        task_match, status_match = _TASK_ID.search(value), _STATUS.search(value)
        if task_match is None:
            return  # Artifact-watch notices carry no shell identity.
        if status_match is not None and status_match[1] in CLAUDE_TERMINAL_TASK_STATUSES:
            self.finish(task_match[1])
        elif task_match[1] in self.tasks:
            # Monitor events and other task notices say nothing about unrelated shells.
            self.uncertain[task_match[1]] = at

    def finish(self, task: str) -> None:
        self.tasks.pop(task, None)
        self.ended.add(task)
        self.uncertain.pop(task, None)


class BackgroundTranscripts:
    """Worker-thread-owned cursors. A failed, incomplete or unsupported read is unavailable, not empty."""

    def __init__(self, read_bytes: int = READ_BYTES, clock: Callable[[], float] = time.time):
        self.read_bytes = read_bytes
        self.clock = clock
        self._read: dict[str, _Transcript] = {}

    def read_all(self, requests: Mapping[str, tuple[str, float]],
                 recoveries: Mapping[str, float] | None = None) -> dict[str, ShellReading | None]:
        self._read = {sid: value for sid, value in self._read.items() if sid in requests}
        return {sid: self._one(sid, path, since, (recoveries or {}).get(sid)) for sid, (path, since) in requests.items()}

    def _one(self, sid: str, path: str, since: float, recovery_at: float | None) -> ShellReading | None:
        try:
            stat = Path(path).stat()
        except (OSError, ValueError):
            self._read.pop(sid, None)
            return None
        value = self._read.get(sid)
        if (value is None or value.path != path or value.since != since
                or value.cursor.rewritten(stat.st_ino, stat.st_size)):
            value = self._read[sid] = _Transcript(path, since, JsonlCursor(stat.st_ino))
        try:
            lines = value.cursor.read_lines(Path(path), min(stat.st_size, value.cursor.offset + self.read_bytes))
        except OSError:
            return None
        for line in lines:
            value.consume(line, self.clock())
        if len(value.cursor.partial) > READ_BYTES:
            value.cursor.partial = b""
            value.gap_at = self.clock()
        if recovery_at is not None:
            value.uncertain = {task: at for task, at in value.uncertain.items() if at > recovery_at}
            if value.gap_at is not None and recovery_at >= value.gap_at:
                value.gap_at = None
        if value.gap_at is not None or value.uncertain or value.cursor.offset < stat.st_size or value.cursor.partial:
            return None
        return ShellReading(tuple(value.tasks.values()), frozenset(value.ended))


# -- a stopped parent's transcript: whether it carried on, and when its usage limit resets -------
# The StopFailure errors that are a usage or rate limit, which resets: Claude Code may carry on by itself then.
LIMIT_ERRORS = frozenset({"rate_limit"})
# How long after its StopFailure a limit's reset is looked for in the transcript. Claude Code writes in batches, so its
# record of the limit can reach the file a moment after the hook; one not there by then is not coming.
RESET_READ_SECONDS = 30.0


@dataclass(frozen=True)
class StopReading:
    resets_at: int | None = None
    progress_at: float | None = None


class StopTranscripts:
    """Bounded parent-transcript reads for stopped workers. An unchanged file is parsed once;
    children and tool results cannot impersonate a new parent prompt or successful response."""
    def __init__(self) -> None:
        self._cache: dict[str, tuple[tuple[int, int, int, int], StopReading]] = {}

    def read_all(self, paths: set[str]) -> dict[str, StopReading]:
        self._cache = {path: cached for path, cached in self._cache.items() if path in paths}
        readings: dict[str, StopReading] = {}
        for path in paths:
            try:
                stat = Path(path).stat()
                stamp = (stat.st_ino, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size)
                cached = self._cache.get(path)
                if cached is not None and cached[0] == stamp:
                    readings[path] = cached[1]
                    continue
                reading = self._read(path)
            except OSError:
                continue
            self._cache[path] = (stamp, reading)
            readings[path] = reading
        return readings

    @staticmethod
    def _read(path: str) -> StopReading:
        for record in records_newest_first(Path(path), TAIL_BYTES):
            if not isinstance(record, dict) or record.get("isSidechain") is True:
                continue
            kind = record.get("type")
            if kind not in ("user", "assistant"):
                continue
            if record.get("isApiErrorMessage") is True:
                return StopReading(resets_at=_resets_at(record.get("apiErrorParams")))
            if kind == "user":
                message = record.get("message")
                content = message.get("content") if isinstance(message, dict) else None
                text = content if isinstance(content, str) else "\n".join(
                    part["text"] for part in content if isinstance(part, dict) and isinstance(part.get("text"), str)
                ) if isinstance(content, list) else ""
                origin = record.get("origin")
                continuation = isinstance(origin, dict) and origin.get("kind") == "auto-continuation"
                # Background handbacks and local slash commands are user-role records too. They
                # can arrive while the parent is still stopped, without starting a model turn.
                if (not text.strip() or record.get("isMeta") is True and not continuation
                        or any(marker in text for marker in ("<task-notification>", "<local-command-", "<command-name>"))
                        or isinstance(content, list) and any(isinstance(part, dict) and part.get("type") == "tool_result"
                                                             for part in content)):
                    continue
            return StopReading(progress_at=iso_seconds(record.get("timestamp")))
        return StopReading()


def _resets_at(params: Any) -> int | None:
    info = params.get("rate_limit_info") if isinstance(params, dict) else None
    resets_at = info.get("resetsAt") if isinstance(info, dict) else None
    # A bool is an int to Python, and no time.
    return resets_at if isinstance(resets_at, int) and not isinstance(resets_at, bool) and resets_at > 0 else None


# -- the tick's read plans -----------------------------------------------------------------------
def session_file_plan(registry: SessionRegistry, status: StatusEngine, files: ClaudeSessionFiles, sessions: list[SessionInfo],
                      screens: list[str]) -> corroboration.ReadPlan[dict[str, ClaudeSessionFile | None]]:
    """Each Claude tab's session file, by its process. A tab whose process has written none yet, while
    its row is idle or a trust dialog holds it, is added to `screens`: its screen is the only sign of
    that dialog."""
    root = files.root
    captured = {s.session_id: s for s in sessions if s.agent == "claude"}

    def key(session: SessionInfo) -> corroboration.SessionKey:
        return corroboration.SessionKey.capture(session, session.agent_cwd)

    keys = {sid: key(session) for sid, session in captured.items()}

    def read() -> dict[str, ClaudeSessionFile | None]:
        readings: dict[str, ClaudeSessionFile | None] = {}
        for sid, captured_key in keys.items():
            with corroboration.logged(f"reading the Claude file of session {sid}"):
                pid = captured_key.job_pid
                readings[sid] = files.read(pid) if pid else None
        return readings

    def apply(readings: dict[str, ClaudeSessionFile | None]) -> list[str]:
        changed: list[str] = []
        if files.root != root:
            return changed
        for sid, file in readings.items():
            session = captured[sid]
            with corroboration.logged(f"corroborating session {sid}"):
                if file:
                    changed += status.apply_trust_prompt(sid, False)
                    if (evidence := file_evidence(file.status, file.written_at)) is not None:
                        changed += status.apply_evidence(sid, evidence)
                    changed += status.apply_metadata(sid, cwd=file.cwd)
                    if (current := registry.get(sid)) is not None and current.conversation_id is None:
                        changed += status.apply_metadata(sid, conversation=file.session_id)
                    registry.set_cli_version(sid, file.version)
                elif session.job_pid and (session.state == "idle" or status.showing_trust_prompt(sid)):
                    screens.append(sid)
        return changed

    return corroboration.ReadPlan("the Claude file read", read if captured else None, {}, apply, keys, key)


def subagent_plan(status: StatusEngine, reader: SubagentTranscripts) -> corroboration.ReadPlan[dict[str, TranscriptTail | None]]:
    """The transcripts of every child the engine counts, for whether each one's run is over."""
    paths = status.subagent_transcripts()
    read = reader.read_all
    return corroboration.ReadPlan("the subagent transcript read", (lambda: read(paths)) if paths else None,
                                  {}, status.release_dead_subagents)


def background_plan(status: StatusEngine, reader: BackgroundTranscripts,
                    sessions: list[SessionInfo]) -> corroboration.ReadPlan[dict[str, ShellReading | None]]:
    """Each Claude tab's background shells, from its own transcript since its turn's work began."""
    captured = {s.session_id: (s.transcript, status.turn(s.session_id)) for s in sessions if s.agent == "claude"}

    def key(session: SessionInfo) -> corroboration.SessionKey:
        turn = status.turn(session.session_id)
        return corroboration.SessionKey.capture(session, session.transcript, turn.work_since if turn is not None else None)

    keys = {s.session_id: key(s) for s in sessions if s.session_id in captured}
    requests = {sid: (path, owner.work_since)
                for sid, (path, owner) in captured.items()
                if path is not None and owner is not None and owner.work_since is not None}
    recoveries = {sid: owner.shell_snapshot_at
                  for sid, (_, owner) in captured.items()
                  if owner is not None and owner.shell_snapshot_valid and owner.shell_snapshot is not None}

    def read() -> dict[str, ShellReading | None]:
        readings = reader.read_all(requests, recoveries)
        return {sid: readings.get(sid) for sid in captured}

    def apply(readings: dict[str, ShellReading | None]) -> list[str]:
        changed: list[str] = []
        for sid, reading in readings.items():
            changed += status.apply_shell_reading(sid, reading)
        return changed

    return corroboration.ReadPlan("the Claude background read", read, dict.fromkeys(captured), apply, keys, key)


def stop_plan(registry: SessionRegistry, status: StatusEngine, reader: StopTranscripts,
              clock: Callable[[], float]) -> corroboration.ReadPlan[dict[str, StopReading]]:
    """The transcript of each session a StopFailure stopped: whether it carried on, and when a usage
    limit that stopped it resets."""
    now = clock()
    stopped = {s.session_id: (s.stopped_on, s.transcript) for s in registry.all()
               if s.stopped_on is not None and s.transcript}
    paths = {transcript for _, transcript in stopped.values() if transcript}

    def key(session: SessionInfo) -> corroboration.SessionKey:
        return corroboration.SessionKey.capture(session, session.transcript,
                                                session.stopped_on.at if session.stopped_on is not None else None)

    keys = {sid: key(session) for sid in stopped if (session := registry.get(sid)) is not None}

    def read() -> dict[str, StopReading]:
        readings = reader.read_all(paths)
        return {sid: readings[path] for sid, (_, path) in stopped.items() if path in readings}

    def apply(readings: dict[str, StopReading]) -> list[str]:
        changed: list[str] = []
        for sid, reading in readings.items():
            stopped_on, _ = stopped[sid]
            if reading.progress_at is not None:
                changed += status.apply_progress(sid, reading.progress_at)
            if (reading.resets_at is not None and stopped_on.error in LIMIT_ERRORS and stopped_on.resets_at is None
                    and now - stopped_on.at <= RESET_READ_SECONDS):
                changed += [sid] if registry.set_stopped_on(sid, replace(stopped_on, resets_at=reading.resets_at)) else []
        return changed

    return corroboration.ReadPlan("the stopped worker transcript read", read if stopped else None, {}, apply, keys, key)
