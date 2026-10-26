from __future__ import annotations
import math
import os
import shlex
from dataclasses import dataclass, field
from typing import Any, Literal

AgentKind = Literal["claude", "codex", "pi", "shell"]
State = Literal["idle", "working", "needsInput", "done"]
# What a hook says happened to a turn. Metadata (model, reasoning, context, cwd) is not a kind: it
# rides along on any event and is applied separately. `promptStart`/`promptEnd` bracket a PI input
# prompt, which can open between turns as well as inside one.
Transition = Literal["working", "needsInput", "done", "subagentStart", "subagentStop", "sessionStart",
                     "promptStart", "promptEnd"]

@dataclass(frozen=True, slots=True)
class Harness:
    """What the daemon knows about one agent CLI. Its name is also its binary's, and a new harness
    is one more row in HARNESSES; the sets below, and the hook server's routes, derive from it."""
    agent: AgentKind
    # The route its hooks post to (hook_events.HOOK_PARSERS parses each).
    hook_route: str
    # How a hook post is placed on the tab it came from (SessionResolver.resolve_directly): by the tab
    # id it carries in X-AiTerm-iTerm-Session, or -- Claude's, which travel over HTTP from the agent
    # itself -- by the pid the agent's own session file names.
    placement: Literal["header", "pid_file"] = "header"
    # What the daemon's tick reads beside the hooks, so a missed post cannot strand a row
    # (Service._corroborate): Claude's own session file, or the spinner in a Codex tab's title --
    # with the context fill in its rollout. None: the hooks alone.
    corroboration: Literal["claude_file", "codex_title"] | None = None
    # Whether it reports the account's rate limits, which the usage footer shows: Claude in its
    # status line, Codex in its rollout.
    reports_usage: bool = False
    # The route its status-line shim posts to, if it has one (hook_events.STATUSLINE_PARSERS).
    statusline_route: str | None = None
    # Text that marks the CLI's folder-trust dialog on its screen, any one of them enough: it opens
    # before the CLI loads its hooks, so the screen is the only sign of it (status.shows_trust_prompt).
    trust_prompt: tuple[str, ...] = ()
    # Text that marks a prompt open on the CLI's screen, which delivery must not type into
    # (delivery.open_prompt): an approval, a startup dialog -- folder trust, an update offer -- and
    # any other menu. Any one enough, compared without whitespace. From the spike against Claude
    # Code 2.1.301 and Codex 0.160.0; a harness without them gets no automated delivery.
    permission_prompt: tuple[str, ...] = ()
    startup_prompt: tuple[str, ...] = ()
    menu_prompt: tuple[str, ...] = ()
    # Text that marks the CLI's update offer, every one of them needed: the one startup dialog AiTerm
    # answers itself, declining it with Esc (session.dismissStartup, spec §7.1). A folder's trust is
    # yours to give: no harness marks it here.
    update_prompt: tuple[str, ...] = ()
    # What an idle or working CLI draws at the start of its input line (delivery.shows_input_box): the
    # positive sign that the screen is the CLI's own and recognised, which no prompt marker proves.
    input_box: tuple[str, ...] = ()


CLAUDE_TRUST_PROMPT = ("Yes, I trust this folder", "Do you trust the files in this folder?")

HARNESSES: tuple[Harness, ...] = (
    # HTTP hooks and a session file.
    Harness("claude", "/hook/claude", placement="pid_file", corroboration="claude_file",
            statusline_route="/statusline", reports_usage=True,
            # 2.1.299's option, and the dialog's question before it.
            trust_prompt=CLAUDE_TRUST_PROMPT,
            permission_prompt=("Do you want to proceed?",), menu_prompt=("Enter to select", "Esc to cancel"),
            # The trust dialog, by the same words as `trust_prompt`.
            startup_prompt=CLAUDE_TRUST_PROMPT,
            input_box=("❯",)),
    # `Stop` over MCP; the other hooks are spawned curl.
    Harness("codex", "/hook/codex", corroboration="codex_title", reports_usage=True,
            permission_prompt=("Would you like to run the following command?",),
            # 0.163's dialogs end on "enter confirm · esc skip" (its review of untrusted hooks) or
            # "enter select · esc back" (its /model picker).
            menu_prompt=("Press enter to confirm or esc to cancel", "enter confirm ·", "enter select ·"),
            # The update dialog by its own options: the idle banner also says "Update available".
            startup_prompt=("Trust this folder?", "Skip until next version", "Update now"),
            update_prompt=("Update now", "Skip until next version"),
            input_box=("›",)),
    # An in-process extension.
    Harness("pi", "/hook/pi"),
)

HARNESS_BY_AGENT: dict[AgentKind, Harness] = {h.agent: h for h in HARNESSES}
AGENT_BINARIES: frozenset[AgentKind] = frozenset(HARNESS_BY_AGENT)
USAGE_VENDORS: tuple[AgentKind, ...] = tuple(h.agent for h in HARNESSES if h.reports_usage)
# The payload field the hook server puts X-AiTerm-iTerm-Session in, and discards from a body: a
# trusted private field, which only the header may set.
ITERM_SESSION_FIELD = "_aiterm_iterm_session_id"

# The iTerm2 user variables (`user.<name>`) that make a session AiTerm's: a task window's, or a
# terminal window's opened by window.createTerminal -- its project, and the terminal row's own id,
# which adopts a window iTerm2 renumbered. A tab opened beside one inherits them.
TASK_TAG = "aiterm_task"
PROJECT_TAG = "aiterm_project"
TERMINAL_TAG = "aiterm_terminal"
# The key of an Operator's extra worker tab (open_tab), on that one tab beside its task tag: it tells
# the tab apart from its task's first worker and from the task's other extra tabs. Never inherited.
TAB_TAG = "aiterm_tab"
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
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ValueError(f"{key} must be a finite number, not {value!r}")
    try:
        number = float(value)
    except OverflowError as exc:
        raise ValueError(f"{key} must be a finite number") from exc
    if not math.isfinite(number):
        raise ValueError(f"{key} must be a finite number, not {value!r}")
    return number


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


@dataclass(frozen=True, slots=True)
class BackgroundJob:
    """One piece of work a Claude turn left running when it ended (a Stop's `background_tasks`): a `shell` by its
    command, a `monitor`, a `subagent` or any other `task` by its description. The app marks the kinds apart. A
    subagent's `agent_id` names the child the status engine counts, and is not sent."""
    kind: Literal["shell", "monitor", "task", "subagent"]
    text: str
    agent_id: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {"kind": self.kind, "text": self.text}


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
    # The conversation the tab's agent runs, as the agent's own hooks name it (HookEvent.conversation_id),
    # and what the app resumes when it reopens the task's window. Another process in the tab is another
    # conversation, so it goes with the agent's process, as the model does (SessionRegistry).
    conversation_id: str | None = None
    # The terminal row this tab's window was opened for (TERMINAL_TAG), which the app adopts the
    # window by; None for a task's tab and for a terminal opened by an app too old to send it.
    terminal_id: str | None = None
    # The version of the agent CLI the tab runs, as the CLI's own files report it: Claude's session
    # file, Codex's rollout. What the delivery check's verdict is held against (delivery.Verdict).
    # Neither sent nor compared; it goes with the agent's process.
    cli_version: str | None = field(default=None, compare=False)
    # The key of the Operator's extra worker tab this is (TAB_TAG), None for any other tab.
    tab_key: str | None = None
    # What its agent left running in the background when its last turn ended, which wakes it again (a Claude Stop's
    # `background_tasks`): a turn ended with this is paused, not finished. Empty once a new turn starts. A subagent
    # stays on it while the status engine counts it.
    background: tuple[BackgroundJob, ...] = ()
    # When a transcript of the Claude subagents it counts was last written, the newest, as the tick last read them (the
    # file's mtime): a child still at work, whose parent's own transcript may say nothing for minutes. None while it
    # counts none, or has read none. It goes with the agent's process.
    subagents_written_at: float | None = None
    # The first line of the prompt you typed into this tab yourself, for the turn it started: AiTerm neither launched
    # the agent with it nor delivered it (HookRouter). None once that turn ends, and for every other prompt.
    your_prompt: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "sessionId": self.session_id, "windowId": self.window_id, "tabIndex": self.tab_index,
            "taskId": self.task_id, "projectId": self.project_id, "agent": self.agent, "model": self.model,
            "reasoning": self.reasoning, "state": self.state, "subagentsWrittenAt": self.subagents_written_at,
            "title": self.title, "cwd": self.cwd, "agentCwd": self.agent_cwd,
            "active": self.active, "contextPercent": self.context_percent,
            "conversationId": self.conversation_id, "terminalId": self.terminal_id, "tabKey": self.tab_key,
            "background": [job.to_json() for job in self.background], "yourPrompt": self.your_prompt,
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
    updated_at: int

    def to_json(self) -> dict[str, Any]:
        return {
            "fiveHour": self.five_hour.to_json() if self.five_hour else None,
            "sevenDay": self.seven_day.to_json() if self.seven_day else None,
            "spend": self.spend.to_json() if self.spend else None,
            "updatedAt": self.updated_at,
        }
