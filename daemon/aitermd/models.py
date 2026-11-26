from __future__ import annotations
import math
import os
import shlex
from dataclasses import dataclass, field
from pathlib import Path
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
    # The route its hooks post to (agents.HOOK_PARSERS parses each).
    hook_route: str
    # How a hook post is placed on the tab it came from (SessionResolver.resolve_directly): by the tab
    # id it carries in X-AiTerm-iTerm-Session, or -- Claude's, which travel over HTTP from the agent
    # itself -- by the pid the agent's own session file names.
    placement: Literal["header", "pid_file"] = "header"
    # Whether it reports the account's rate limits, which the usage footer shows: Claude in its
    # status line, Codex in its rollout.
    reports_usage: bool = False
    # The route its status-line shim posts to, if it has one (agents.STATUSLINE_PARSERS).
    statusline_route: str | None = None
    # Text that marks the CLI's folder-trust dialog on its screen, any one of them enough: it opens
    # before the CLI loads its hooks, so the screen is the only sign of it (screens.shows_trust_prompt).
    trust_prompt: tuple[str, ...] = ()
    # Text that marks a prompt open on the CLI's screen, which delivery must not type into
    # (delivery.open_prompt): an approval, a startup dialog -- folder trust, an update offer -- and
    # any other menu. Any one enough, compared without whitespace. Markers from the spike against
    # Claude Code 2.1.301 and Codex 0.160.0; a harness without them gets no automated delivery.
    permission_prompt: tuple[str, ...] = ()
    startup_prompt: tuple[str, ...] = ()
    menu_prompt: tuple[str, ...] = ()
    # Menus without a known footer select consecutive numbered options outside the ruled input frame.
    numbered_menus: bool = False
    # Footer of the transcript-only view, which has no input box.
    transcript_view: tuple[str, ...] = ()
    # Text that marks the CLI's update offer, every one of them needed: the one startup dialog the
    # delivery check can decline with Esc. A folder's trust is
    # yours to give: no harness marks it here.
    update_prompt: tuple[str, ...] = ()
    # What an idle or working CLI draws at the start of its input line (delivery.shows_input_box): the
    # positive sign that the screen is the CLI's own and recognised, which no prompt marker proves.
    input_box: tuple[str, ...] = ()


CLAUDE_TRUST_PROMPT = ("Yes, I trust this folder", "Do you trust the files in this folder?")
# PI 1.6's project-trust select (core/project-trust.js, formatProjectTrustPrompt): its title, and the
# line under the folder that says what trusting allows.
PI_TRUST_PROMPT = ("Trust project folder?", "This allows pi to load .pi settings and resources")

HARNESSES: tuple[Harness, ...] = (
    # HTTP hooks and a session file.
    Harness("claude", "/hook/claude", placement="pid_file",
            statusline_route="/statusline", reports_usage=True,
            # 2.1.299's option, and the dialog's question before it.
            trust_prompt=CLAUDE_TRUST_PROMPT,
            permission_prompt=("Do you want to proceed?",), menu_prompt=("Enter to select", "Esc to cancel"),
            # The trust dialog, by the same words as `trust_prompt`.
            startup_prompt=CLAUDE_TRUST_PROMPT,
            input_box=("❯",), numbered_menus=True,
            transcript_view=("Showing detailed transcript · ctrl+o to toggle",)),
    # `Stop` over MCP; the other hooks are spawned curl.
    Harness("codex", "/hook/codex", reports_usage=True,
            permission_prompt=("Would you like to run the following command?",),
            # 0.163's dialogs end on "enter confirm · esc skip" (its review of untrusted hooks) or
            # "enter select · esc back" (its /model picker).
            menu_prompt=("Press enter to confirm or esc to cancel", "enter confirm ·", "enter select ·"),
            # The update dialog by its own options: the idle banner also says "Update available".
            startup_prompt=("Trust this folder?", "Skip until next version", "Update now"),
            update_prompt=("Update now", "Skip until next version"),
            input_box=("›",)),
    # An in-process extension. Its folder-trust dialog comes before the extension's first post, so
    # the screen is the only sign of it, as for Claude.
    Harness("pi", "/hook/pi", trust_prompt=PI_TRUST_PROMPT),
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
CODEX_THREAD_TAG = "aiterm_codex_thread"
# The tab's user variable an AiTerm branch title is kept in; the tab's title interpolates it.
TITLE_TAG = "aiterm_title"


def support_dir() -> Path:
    """The folder the app and the daemon keep their files in: the daemon's socket, the delivery
    policy, the Operator runs. A function, so a caller reads $HOME when it asks."""
    return Path.home() / "Library" / "Application Support" / "AiTerm"


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
    """One piece of work running beside a Claude turn: a `shell` by its command, a `monitor`, a `subagent`, an `agent`
    (agent work that is no counted child: a workflow, a cloud session, a dream) or any other `task` by its description.
    A subagent's `agent_id` names the child the status engine counts, any other job's `task_id` Claude Code's id for it;
    neither is sent. `teammate`: a named agent of Claude Code's agent team, which a Stop lists as running for as long as
    it lives, idle or not; its `text` is the description it was spawned with."""
    kind: Literal["shell", "monitor", "task", "agent", "subagent"]
    text: str
    agent_id: str | None = None
    task_id: str | None = None
    display_label: str | None = None
    teammate: bool = False

    def to_json(self) -> dict[str, Any]:
        return {"kind": self.kind, "text": self.text} | ({"displayLabel": self.display_label} if self.display_label else {})


@dataclass(frozen=True, slots=True)
class WorkItem:
    """One line of a session's work list (work_items). `holds_turn`: the last Stop listed it, so the agent takes the
    turn up again once it ends. `idle`: a teammate that finished its turn and waits for a message; it holds nothing."""
    kind: Literal["shell", "monitor", "task", "agent", "subagent"]
    text: str
    holds_turn: bool
    display_label: str | None = None
    idle: bool = False

    def to_json(self) -> dict[str, Any]:
        return {"kind": self.kind, "text": self.text, "holdsTurn": self.holds_turn, "idle": self.idle} | (
            {"displayLabel": self.display_label} if self.display_label else {})


@dataclass(frozen=True, slots=True)
class Teammate:
    """One named agent of the conversation's agent team, as its parent's transcript tells it (agents.claude): spawned
    (`running`), its idle notification (`idle`), a message sent to it (`running` again), its termination or a TaskStop
    of it (`ended`). `description` is what it was spawned with, the text its Stop entry carries."""
    name: str
    agent_id: str
    description: str
    state: Literal["running", "idle", "ended"]


@dataclass(frozen=True, slots=True)
class TranscriptWork:
    """What a conversation's transcript, read to its end since its work began, says of the teammates its Stop listed:
    the agent team's members, and the task ids it shows ended (a terminal task notification, or a TaskStop that stopped
    one), by the only id a Stop's entry carries. Positive evidence only: a task it does not name is not known ended.
    Only teammate entries read it. A shell the Stop listed holds the turn until the next hook even once it ended: Claude
    Code hands its completion to the agent as its next prompt, so the agent takes the turn up again."""
    teammates: tuple[Teammate, ...] = ()
    ended_tasks: frozenset[str] = frozenset()


def _same_text(a: str, b: str) -> bool:
    return " ".join(a.split()) == " ".join(b.split())


def teammate_fate(job: BackgroundJob, session: SessionInfo) -> tuple[Literal["running", "idle", "ended"], str | None]:
    """What a teammate the Stop listed is now, and its agent id when only one live teammate answers to its description.
    Claude Code lists every live teammate as running; the transcript tells an idle one apart. It is running while its
    transcript says so or the status engine counts its agent (it woke and fired SubagentStart); idle once every live
    teammate spawned with its description is idle and not counted; ended once a TaskStop named its task or every such
    teammate ended. With no reading, or none the reading knows by that description, it stays running, as before."""
    team = session.transcript_work
    if team is None:
        return "running", None
    if job.task_id is not None and job.task_id in team.ended_tasks:
        return "ended", None
    same = [t for t in team.teammates if _same_text(t.description, job.text)]
    if not same:
        return "running", None
    live = [t for t in same if t.state != "ended"]
    if not live:
        return "ended", None
    counted = {child.agent_id for child in session.shown_subagents or () if child.agent_id is not None}
    agent = live[0].agent_id if len(live) == 1 else None
    if all(t.state == "idle" and t.agent_id not in counted for t in live):
        return "idle", agent
    return "running", agent


def work_items(session: SessionInfo) -> tuple[WorkItem, ...]:
    """The session's work, in order: what its last Stop listed and still stands, each holding the turn (a subagent
    always; a shell once the turn ended, or while the shell reader lists it, by the reader's text; a monitor or task
    once the turn ended; a teammate as the agent it is, a `subagent` on the wire, once the turn ended while it runs,
    as `idle` and holding nothing while it waits for a message, and not at all once the transcript shows it ended:
    teammate_fate); then the counted subagents and the reader's shells that Stop did not list, holding nothing."""
    ended = session.state in ("idle", "done")
    shells = {job.task_id: job for job in session.shown_shells or () if job.task_id is not None}
    items: list[WorkItem] = []
    listed_agents = {job.agent_id for job in session.stop_work if job.agent_id is not None}
    for job in session.stop_work:
        if job.teammate:
            fate, agent = teammate_fate(job, session)
            if fate == "ended":
                continue
            if fate == "idle":
                items.append(WorkItem("subagent", job.text, False, job.display_label, idle=True))
                continue
            # A running teammate is a counted subagent too: one line for it, where its Stop entry stands.
            if ended and agent is not None:
                listed_agents.add(agent)
            if ended:
                items.append(WorkItem("subagent", job.text, True, job.display_label))
            continue
        shown = shells.get(job.task_id) if job.kind == "shell" and job.task_id is not None else None
        if job.kind == "subagent" or ended or shown is not None:
            items.append(WorkItem(job.kind, shown.text if shown is not None else job.text, True,
                                  job.display_label or (shown.display_label if shown is not None else None)))
    listed_tasks = {job.task_id for job in session.stop_work if job.task_id is not None}
    items += [WorkItem(job.kind, job.text, False, job.display_label)
              for job in session.shown_subagents or () if job.agent_id not in listed_agents]
    items += [WorkItem(job.kind, job.text, False, job.display_label) for job in session.shown_shells or ()
              if job.task_id is None or job.task_id not in listed_tasks]
    return tuple(items)


@dataclass(frozen=True, slots=True)
class StoppedOn:
    """What ended a Claude session's last turn short: the API error Claude Code reported in place of its Stop (a
    StopFailure hook). `error` is Claude Code's name for it: `rate_limit` for a usage or rate limit, which Claude Code
    may carry on from by itself once it resets; `billing_error`, `authentication_failed` and the like for one that
    blocks the session until someone acts. `resets_at`, a limit's reset in epoch seconds, only as the transcript's own
    record of the limit gives it (agents.claude.StopTranscripts); None while nothing has. `at`, the wall clock when
    the hook came, is excluded from value equality and wire data."""
    error: str
    resets_at: int | None = None
    at: float = field(default=0.0, compare=False)

    def to_json(self) -> dict[str, Any]:
        return {"error": self.error, "resetsAt": self.resets_at}


@dataclass(frozen=True, slots=True)
class TestActivity:
    """One test runner's own lifecycle. Live states require its inherited kernel liveness lock."""
    run_id: str
    suite: str
    state: Literal["queued", "running", "completed", "interrupted"]
    queue_position: int | None = None
    holder: str | None = None
    exit_code: int | None = None
    finished_at: float | None = None

    def to_json(self) -> dict[str, Any]:
        return {"runId": self.run_id, "suite": self.suite, "state": self.state,
                "queuePosition": self.queue_position, "holder": self.holder, "exitCode": self.exit_code,
                "finishedAt": self.finished_at}


@dataclass
class SessionInfo:
    session_id: str
    window_id: str
    tab_index: int
    task_id: str | None
    project_id: str | None
    agent: AgentKind
    state: State
    # The tab's process title, which only the status engine reads (a Codex spinner). Left out of
    # equality and the wire: a spinner turns on almost every poll, so a title-only difference
    # is not a change to announce.
    title: str = field(compare=False)
    cwd: str
    job_pid: int | None
    # The directory the *agent* is in. iTerm2 only ever reports the shell's (`cwd`), and a
    # Claude that has entered a worktree chdirs its own process without moving the shell, so
    # this is filled in from the agent's own session file (Claude) or its hook posts (Codex).
    agent_cwd: str | None = field(default=None, metadata={"process": True})
    # The tab that was current in its window as of the last snapshot.
    active: bool = False
    # The provider's last-known context fill within this task, 0-100. The status engine shares it
    # across sibling tabs running the same provider; an unassociated session retains its own value.
    context_percent: int | None = field(default=None, metadata={"process": True})
    # Current input context belongs to this conversation, never a sibling tab's.
    context_tokens: int | None = field(default=None, metadata={"process": True})
    # The conversation the tab's agent runs, as the agent's own hooks name it (HookEvent.conversation_id),
    # and what the app resumes when it reopens the task's window. Another process in the tab is another
    # conversation, so it goes with the agent's process (SessionRegistry).
    conversation_id: str | None = field(default=None, metadata={"process": True})
    # The terminal row this tab's window was opened for (TERMINAL_TAG), which the app adopts the
    # window by; None for a task's tab and for a terminal opened by an app too old to send it.
    terminal_id: str | None = None
    # The version of the agent CLI the tab runs, as the CLI's own files report it: Claude's session
    # file, Codex's rollout. What the delivery check's verdict is held against (delivery.Verdict).
    # Neither sent nor compared; it goes with the agent's process.
    cli_version: str | None = field(default=None, compare=False, metadata={"process": True})
    # The key of the Operator's extra worker tab this is (TAB_TAG), None for any other tab.
    tab_key: str | None = None
    # What its agent's last Stop listed as still running (`background_tasks`), which wakes it again: a turn ended with
    # this is paused, not finished. Empty once a new turn starts. A subagent stays on it while the status engine counts it.
    stop_work: tuple[BackgroundJob, ...] = field(default=(), metadata={"process": True})
    # What runs beside the turn as read live: the counted subagents of the tab's current conversation, and the
    # shells the background-shell reader lists. None while that source is unavailable. Neither decides the status.
    shown_subagents: tuple[BackgroundJob, ...] | None = field(default=None, metadata={"process": True})
    shown_shells: tuple[BackgroundJob, ...] | None = field(default=None, metadata={"process": True})
    # What the tab's transcript says of the teammates its Stop listed (TranscriptWork): an idle one apart from a running
    # one, and those it shows ended. None while that reading is unavailable. It decides only how work_items shows them
    # and whether they hold the turn, never the state.
    transcript_work: TranscriptWork | None = field(default=None, metadata={"process": True})
    # The first line of the prompt you typed into this tab yourself, for the turn it started: AiTerm neither launched
    # the agent with it nor delivered it (HookRouter). None once that turn ends, and for every other prompt.
    your_prompt: str | None = field(default=None, metadata={"process": True})
    # Where Claude writes this tab's conversation, as its own hooks name it (`transcript_path`).
    # Neither sent nor compared; it goes with the agent's process.
    transcript: str | None = field(default=None, compare=False, metadata={"process": True})
    # What ended its last turn short (StoppedOn), until it works again: a new turn, a Stop, another conversation. It goes
    # with the agent's process.
    stopped_on: StoppedOn | None = field(default=None, metadata={"process": True})
    # Exact-worktree test command metadata. Completed/interrupted records never count as live work.
    test_activity: TestActivity | None = field(default=None, metadata={"process": True})

    def to_json(self) -> dict[str, Any]:
        return {
            "sessionId": self.session_id, "windowId": self.window_id, "tabIndex": self.tab_index,
            "taskId": self.task_id, "projectId": self.project_id, "agent": self.agent,
            "state": self.state, "cwd": self.cwd, "agentCwd": self.agent_cwd,
            "active": self.active, "contextPercent": self.context_percent,
            "contextTokens": self.context_tokens,
            "conversationId": self.conversation_id, "terminalId": self.terminal_id, "tabKey": self.tab_key,
            "work": [item.to_json() for item in work_items(self)], "yourPrompt": self.your_prompt,
            "stoppedOn": self.stopped_on.to_json() if self.stopped_on else None,
            "testActivity": self.test_activity.to_json() if self.test_activity else None,
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
            "retrievalFailure": None,
        }
