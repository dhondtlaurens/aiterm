from __future__ import annotations
import math
import os
import re
import shlex
from dataclasses import dataclass, field
from typing import Any, Literal

AgentKind = Literal["claude", "codex", "grok", "pi", "shell"]
State = Literal["idle", "working", "needsInput", "done"]
# What a hook says happened to a turn. Metadata (model, reasoning, context, cwd) is not a kind: it
# rides along on any event and is applied separately. `promptStart`/`promptEnd` bracket a PI input
# prompt, which can open between turns as well as inside one. `settle` is a turn end reported late,
# as a state rather than an event: it ends a turn still working or needing input, and leaves any
# other state -- a done, seen or not -- alone.
Transition = Literal["working", "needsInput", "done", "settle", "subagentStart", "subagentStop", "sessionStart",
                     "promptStart", "promptEnd"]

@dataclass(frozen=True, slots=True)
class Harness:
    """What the daemon knows about one agent CLI. Its name is also its binary's, and a new harness
    is one more row in HARNESSES; the sets below, and the hook server's routes, derive from it."""
    agent: AgentKind
    # The route its hooks post to (hook_events.HOOK_PARSERS parses each).
    hook_route: str
    # Another process title the CLI runs under, matched in full against the case-folded basename.
    title_pattern: re.Pattern[str] | None = None
    # Whether its hook posts carry the tab they came from, in X-AiTerm-iTerm-Session. Claude's
    # travel over HTTP from the agent itself, and are placed by its pid instead.
    tab_id_from_header: bool = True
    # Whether its end-of-turn signal reaches the daemon without a process spawned in the session's
    # cwd. A harness without one is settled by the daemon once its cwd vanishes
    # (StatusEngine.settle_orphans), and gets one only when its driver meets that bar.
    end_of_turn_survives_cwd_loss: bool = False
    # The route its status-line shim posts to, if it has one (hook_events.STATUSLINE_PARSERS).
    statusline_route: str | None = None


HARNESSES: tuple[Harness, ...] = (
    # HTTP hooks and a session file.
    Harness("claude", "/hook/claude", tab_id_from_header=False, end_of_turn_survives_cwd_loss=True,
            statusline_route="/statusline"),
    # `Stop` over MCP; the other hooks are spawned curl.
    Harness("codex", "/hook/codex", end_of_turn_survives_cwd_loss=True),
    # Spawned command hooks only. `~/.grok/bin/grok` is a symlink to the downloaded binary, and the
    # process may be titled with the resolved name: versioned since 1.0.44
    # (`grok-1.0.44-macos-aarch64`), and naming the architecture (`grok-macos-x86_64`).
    Harness("grok", "/hook/grok", title_pattern=re.compile(r"grok(-\d+(\.\d+)*)?-macos-[a-z0-9_]+"),
            statusline_route="/statusline/grok"),
    # An in-process extension.
    Harness("pi", "/hook/pi", end_of_turn_survives_cwd_loss=True),
)

AGENT_BINARIES: frozenset[AgentKind] = frozenset(h.agent for h in HARNESSES)
AGENT_TITLE_PATTERNS: tuple[tuple[re.Pattern[str], AgentKind], ...] = tuple(
    (h.title_pattern, h.agent) for h in HARNESSES if h.title_pattern)
END_OF_TURN_SURVIVES_CWD_LOSS: frozenset[AgentKind] = frozenset(h.agent for h in HARNESSES if h.end_of_turn_survives_cwd_loss)
TAB_ID_FROM_HEADER: frozenset[AgentKind] = frozenset(h.agent for h in HARNESSES if h.tab_id_from_header)
# The payload field the hook server puts X-AiTerm-iTerm-Session in, and discards from a body: a
# trusted private field, which only the header may set.
ITERM_SESSION_FIELD = "_aiterm_iterm_session_id"

# The iTerm2 user variables (`user.<name>`) that make a session AiTerm's: a task window's, or a
# terminal window's opened by window.createTerminal. A tab opened beside one inherits it.
TASK_TAG = "aiterm_task"
PROJECT_TAG = "aiterm_project"
# The tab's user variable an AiTerm branch title is kept in; the tab's title interpolates it.
TITLE_TAG = "aiterm_title"


def classify_agent(command_line: str | None) -> AgentKind:
    if not command_line:
        return "shell"
    try:
        argv = shlex.split(command_line)
    except (ValueError, IndexError):
        argv = command_line.split()
    first = argv[0] if argv else ""
    # Case-folded: an agent CLI owns its process title, and Claude Code's argv[0] is
    # "Claude" as often as "claude" (both observed live, side by side, on 2.1.274). A
    # case-sensitive match classified half of the real Claude sessions as a plain shell.
    name = os.path.basename(first).casefold()
    if name in AGENT_BINARIES:
        return name
    for pattern, agent in AGENT_TITLE_PATTERNS:
        if pattern.fullmatch(name):
            return agent
    # PI's npm/Homebrew executable is a Node script. After its `#!/usr/bin/env node`
    # shebang is resolved, iTerm reports the real foreground command as
    # `.../node .../pi`, not as `pi`. Match that exact script basename only; an
    # arbitrary Node process remains a shell session.
    if name in {"node", "nodejs"} and len(argv) > 1 and os.path.basename(argv[1]).casefold() == "pi":
        return "pi"
    return "shell"


@dataclass(frozen=True)
class Frame:
    x: float
    y: float
    w: float
    h: float

    @classmethod
    def from_json(cls, d: dict[str, Any]) -> Frame:
        return cls(*(_coordinate(d, key) for key in ("x", "y", "w", "h")))


def _coordinate(d: dict[str, Any], key: str) -> float:
    """A JSON number that can place a window. `float()` alone would take `true` as 1, a numeric
    string, and the NaN and Infinity that Python's JSON parser accepts."""
    value = d[key]
    if isinstance(value, bool) or not isinstance(value, int | float) or not math.isfinite(value):
        raise ValueError(f"{key} must be a finite number, not {value!r}")
    return float(value)


@dataclass
class RawSession:
    session_id: str
    window_id: str
    tab_index: int
    command_line: str | None
    job_pid: int | None
    title: str
    cwd: str
    user_vars: dict[str, str] = field(default_factory=dict)
    # True for the session iTerm2 reports as current in its window, at the moment of the snapshot.
    active: bool = False


@dataclass
class SessionInfo:
    session_id: str
    window_id: str
    tab_index: int
    task_id: str | None
    project_id: str | None
    agent: AgentKind
    model: str | None
    state: State
    # The tab's process title, which only the status engine reads (a Codex spinner). Left out of
    # equality: a spinner turns on almost every poll, and clients do not use it, so a title-only
    # difference is not a change to announce.
    title: str = field(compare=False)
    cwd: str
    job_pid: int | None
    reasoning: str | None = None
    # The directory the *agent* is in. iTerm2 only ever reports the shell's (`cwd`), and a
    # Claude that has entered a worktree chdirs its own process without moving the shell, so
    # this is filled in from the agent's own session file (Claude) or its hook posts (Codex).
    agent_cwd: str | None = None
    # The tab that was current in its window as of the last snapshot.
    active: bool = False
    # The provider's last-known context fill within this task, 0-100. The status engine shares it
    # across sibling tabs running the same provider; an unassociated session retains its own value.
    context_percent: int | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "sessionId": self.session_id, "windowId": self.window_id, "tabIndex": self.tab_index,
            "taskId": self.task_id, "projectId": self.project_id, "agent": self.agent, "model": self.model,
            "reasoning": self.reasoning, "state": self.state, "title": self.title, "cwd": self.cwd, "agentCwd": self.agent_cwd,
            "active": self.active, "contextPercent": self.context_percent,
        }


@dataclass(frozen=True, slots=True)
class UsageWindow:
    used_percent: int
    resets_at: int | None

    def to_json(self) -> dict[str, Any]:
        return {"usedPercent": self.used_percent, "resetsAt": self.resets_at}


@dataclass(frozen=True, slots=True)
class Usage:
    five_hour: UsageWindow | None
    seven_day: UsageWindow | None
    spend: UsageWindow | None
    plan: str | None
    updated_at: int

    def to_json(self) -> dict[str, Any]:
        return {
            "fiveHour": self.five_hour.to_json() if self.five_hour else None,
            "sevenDay": self.seven_day.to_json() if self.seven_day else None,
            "spend": self.spend.to_json() if self.spend else None,
            "plan": self.plan, "updatedAt": self.updated_at,
        }
