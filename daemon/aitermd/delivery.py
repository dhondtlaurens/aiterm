"""Typing into an agent's session the one way the spike found safe (Operators spec §7.1), and
reading off its screen whether a prompt is open that typed text could answer."""
from __future__ import annotations

import asyncio
import json
import re
import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Literal, NamedTuple

from .iterm_bridge import ItermPort, ItermUnavailable
from .models import HARNESS_BY_AGENT, AgentKind, SessionInfo
from .sessions import SessionRegistry

if TYPE_CHECKING:  # keystrokes imports this module's TYPING_QUIET
    from .keystrokes import TypingGuard

# The Operators timings, the same in the app's `OperatorTiming`. Seconds, unless named otherwise.
# Between a bracketed paste and its Enter: sent together, the CLI takes the Enter as part of the
# paste, and it does not submit.
SUBMIT_DELAY = 0.4
# No wake line goes into the operator's session within this of your last key there (§7.4).
TYPING_QUIET = 10.0
# A message longer than this, in characters, is left in a message file, and the session is sent
# one fixed line telling it to read it.
MESSAGE_FILE_THRESHOLD = 2000
# Wake lines within this of each other are merged into one (the app's OperatorWaker).
WAKE_COALESCE = 3.0
# How often the app reconciles runs with the real sessions and branches.
RECONCILE_INTERVAL = 60.0
# A task working with no hook, transcript or screen change for this long is flagged possibly stalled.
STALL_AFTER = 20 * 60.0
# The longest a second opinion may take before the act goes ahead, unchallenged.
CHALLENGE_TIMEOUT = 180.0
# How long /operator waits for the app to answer a forwarded tool call (operator_mcp).
OPERATOR_REQUEST_TIMEOUT = 30.0
# A launch attempt older than this with no session tagged for it may be launched again.
LAUNCH_ADOPT_AFTER = 60.0

# What a screen can show that typed text could answer: an approval, a startup dialog (folder trust,
# an update offer) or any other menu. Checked in that order: an approval and a startup dialog draw
# a menu's footer too.
PromptKind = Literal["permission", "startup", "menu"]


def _shows(screen: str, phrases: tuple[str, ...]) -> bool:
    """Compared without whitespace, as status.shows_trust_prompt does: a line can come back with its
    spaces drawn as cursor moves, or wrapped where the window is narrow."""
    text = "".join(screen.split())
    return any("".join(phrase.split()) in text for phrase in phrases)


def open_prompt(agent: AgentKind, screen: str) -> PromptKind | None:
    """The prompt `screen` shows open in the agent's session, if any. A harness without markers
    shows none, which proves nothing: delivery to it stays off (`load_policy`) until it has them."""
    if (harness := HARNESS_BY_AGENT.get(agent)) is None:
        return None
    if _shows(screen, harness.permission_prompt):
        return "permission"
    if _shows(screen, harness.startup_prompt):
        return "startup"
    if _shows(screen, harness.menu_prompt):
        return "menu"
    return None


# How AiTerm may type into one CLI, from the delivery check it last passed (tools/delivery_check.py):
# `auto` pastes and presses Enter; `pasteOnly` pastes and leaves the Enter to you; `off` types nothing.
DeliveryPolicy = Literal["auto", "pasteOnly", "off"]
# Written by the delivery check; read on every delivery, so a new check needs no daemon restart.
POLICY_PATH = Path.home() / "Library" / "Application Support" / "AiTerm" / "delivery-policy.json"


class Verdict(NamedTuple):
    """What the delivery check found for one CLI: the policy, and the version it was checked against.
    It vouches for that version alone: the Deliverer types into a session only while the CLI there
    reports the same version (SessionInfo.cli_version), so an update the CLI installed since gets
    nothing until it is checked again."""
    policy: DeliveryPolicy
    version: str | None


# A CLI the delivery check has not passed, or passed for no version it named.
NOT_CHECKED = Verdict("off", None)


def _has_prompt_markers(agent: AgentKind) -> bool:
    harness = HARNESS_BY_AGENT[agent]
    return bool(harness.permission_prompt or harness.startup_prompt or harness.menu_prompt)


def load_policy(path: Path) -> dict[AgentKind, Verdict]:
    """Every harness's verdict from the delivery check's file: paste-safe and submit-safe is `auto`,
    paste-safe alone `pasteOnly`, and anything else -- a harness the file does not name, a value
    that is not a JSON true, an entry that names no version, a file missing or unreadable -- `off`.
    So is a harness with no prompt markers, whatever the file says: `open_prompt` reads none off its
    screen, and that must not pass for a screen with no prompt open. Delivery fails closed: a CLI
    whose pasted text might act as keys in one of its prompts gets none at all (spec §7.1)."""
    raw: Any
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError):  # ValueError: not JSON, or bytes that are not UTF-8
        raw = None
    entries = raw if isinstance(raw, dict) else {}
    verdicts: dict[AgentKind, Verdict] = {}
    for agent in HARNESS_BY_AGENT:
        entry = entries.get(agent)
        version = entry.get("version") if isinstance(entry, dict) else None
        if not isinstance(version, str) or not version or not _has_prompt_markers(agent):
            verdicts[agent] = NOT_CHECKED
            continue
        paste = isinstance(entry, dict) and entry.get("pasteSafe") is True
        submit = isinstance(entry, dict) and entry.get("submitSafe") is True
        verdicts[agent] = Verdict("auto" if paste and submit else "pasteOnly" if paste else "off", version)
    return verdicts


# Bracketed paste: what a terminal wraps pasted text in, so the CLI reads it as text, not keys. A
# prompt that opens while it arrives receives a paste rather than shortcut keys (spec §7.1).
PASTE_START, PASTE_END = "\x1b[200~", "\x1b[201~"
SUBMIT = "\r"
# Claude's and Codex's interrupt key, sent only on your click (session.interrupt).
ESC = "\x1b"
# What a paste may not carry: every C0 control but tab and newline -- ESC above all, which could end
# the paste early and type the rest as keys -- DEL, and the C1 controls, CSI among them.
_UNPASTEABLE = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def pasteable(text: str) -> str:
    """`text` as it may be pasted: Windows and old Mac line endings as newlines -- a CR is Enter --
    and every control that could act as a key removed."""
    return _UNPASTEABLE.sub("", text.replace("\r\n", "\n").replace("\r", "\n"))


@dataclass(frozen=True, slots=True)
class DeliveryResult:
    """`delivered`: pasted and entered. `partial`: pasted, and the Enter held back -- the text waits
    visibly in the input, and `reason` says why. `refused`: nothing was typed. Neither is retried."""
    result: Literal["delivered", "partial", "refused"]
    reason: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {"result": self.result, "reason": self.reason}


def _refused(reason: str) -> DeliveryResult:
    return DeliveryResult("refused", reason)


def _partial(reason: str) -> DeliveryResult:
    return DeliveryResult("partial", reason)


class Deliverer:
    """The delivery adapter (spec §7.1): types into an agent's session the one way the spike found
    safe. It checks the session can take text -- iTerm2 connected, the session open, its CLI checked
    paste-safe for the very version it runs (`load_policy`, SessionInfo.cli_version), its screen
    read and no prompt open -- pastes the text bracketed, waits SUBMIT_DELAY, checks again, and only
    then presses Enter. Anything that changed in between holds the Enter back: the result is
    `partial`, and the text waits in the input for whoever looks next. Deliveries to one session
    take turns, so two pastes never interleave with their Enters. Which run and task a session
    belongs to, and whether that run is active, is the app's to check before it asks."""

    def __init__(self, iterm: ItermPort, registry: SessionRegistry, policy: Callable[[], Mapping[AgentKind, Verdict]],
                 typing: TypingGuard, *, monotonic: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep):
        self.iterm, self.registry, self.policy, self.typing = iterm, registry, policy, typing
        self._monotonic, self._sleep = monotonic, sleep
        self._locks: dict[str, asyncio.Lock] = {}

    def forget_session(self, session_id: str) -> None:
        """What a closed session leaves behind: its turn lock."""
        self._locks.pop(session_id, None)

    def _turn(self, session_id: str) -> asyncio.Lock:
        return self._locks.setdefault(session_id, asyncio.Lock())

    async def deliver(self, session_id: str, text: str, ownership: int, *, wake: bool = False,
                      worktree: str | None = None) -> DeliveryResult:
        """Types `text` into the session. `ownership` is the task's generation as the caller knew it;
        `wake` marks an operator's wake line, which waits while you type; `worktree` is where a
        message too long to paste is left."""
        async with self._turn(session_id):
            return await self._deliver(session_id, text, ownership, wake, worktree)

    async def _deliver(self, session_id: str, text: str, ownership: int, wake: bool, worktree: str | None) -> DeliveryResult:
        if isinstance(ready := await self._check(session_id), str):
            return _refused(ready)
        session, policy = ready
        if not (body := pasteable(text)).strip():
            return _refused("there is nothing to deliver")
        try:
            await self.iterm.send_text(session_id, PASTE_START + body + PASTE_END)
        except KeyError:
            return _refused("the session has closed")
        except ItermUnavailable as exc:
            return _refused(f"iTerm2 did not take the text: {exc}")
        if policy == "pasteOnly":
            return _partial(f"pasted without Enter: this {session.agent} version is checked paste-safe only, so you press Enter")
        await self._sleep(SUBMIT_DELAY)
        if (why := await self._changed(session, ownership, wake)) is not None:
            return _partial(why)
        try:
            await self.iterm.send_text(session_id, SUBMIT)
        except (KeyError, ItermUnavailable) as exc:
            return _partial(f"the Enter could not be sent ({exc}); the text waits unsent in the input")
        return DeliveryResult("delivered")

    async def _check(self, session_id: str) -> tuple[SessionInfo, DeliveryPolicy] | str:
        """Why the session cannot take text now -- or, when it can, the session and how its CLI may be
        typed into."""
        if not self.iterm.is_connected():
            return "iTerm2 is not connected"
        if (session := self.registry.get(session_id)) is None:
            return "the session has closed"
        policy, version = self.policy().get(session.agent, NOT_CHECKED)
        if policy == "off":
            return f"AiTerm has not checked that it can type into this {session.agent} version safely"
        if session.cli_version is None or session.cli_version != version:
            # The check vouches for the version it ran against: one updated since, or one whose files
            # have not named their version yet, gets nothing until it is checked.
            return f"{session.agent} {session.cli_version or '(version unknown)'} has not passed the delivery check"
        if (why := await self._ineligible(session_id, session.agent)) is not None:
            return why
        return session, policy

    def _replaced(self, session: SessionInfo) -> str | None:
        """Why `session`, as a delivery began with it, is no longer the one open: closed, or another
        process -- another conversation, maybe another CLI -- in its tab."""
        if (now := self.registry.get(session.session_id)) is None:
            return "the session has closed"
        if now.job_pid != session.job_pid or now.agent != session.agent:
            return "another process now runs in the session"
        return None

    async def _ineligible(self, session_id: str, agent: AgentKind) -> str | None:
        """Why the session cannot take text now, as its screen shows it; None when it can."""
        try:
            screen = await self.iterm.screen_text(session_id)
        except ItermUnavailable as exc:
            return f"its screen could not be read: {exc}"
        if screen is None:
            return "the session has closed"
        if not screen.strip():
            # The spike saw a read come back empty: nothing then shows that no prompt is open.
            return "the screen came back empty, so whether a prompt is open is unknown"
        if (prompt := open_prompt(agent, screen)) is not None:
            return f"a {prompt} prompt is open"
        return None

    async def _changed(self, session: SessionInfo, ownership: int, wake: bool) -> str | None:
        """What holds the Enter back: anything that changed while the paste settled."""
        if (why := self._replaced(session) or await self._ineligible(session.session_id, session.agent)) is not None:
            return f"before Enter, {why}; the text waits unsent in the input"
        return None

    async def prompt(self, session_id: str) -> PromptKind | None:
        """The prompt open in the session now (session.prompt). KeyError for a session not open."""
        if (session := self.registry.get(session_id)) is None or (screen := await self.iterm.screen_text(session_id)) is None:
            raise KeyError(session_id)
        return open_prompt(session.agent, screen)

    async def interrupt(self, session_id: str) -> None:
        """Sends the agent's interrupt key, Esc (session.interrupt): only ever on your click, never
        the operator's. It takes its turn, so it cannot land between a paste and its Enter."""
        if self.registry.get(session_id) is None:
            raise KeyError(session_id)
        async with self._turn(session_id):
            await self.iterm.send_text(session_id, ESC)
