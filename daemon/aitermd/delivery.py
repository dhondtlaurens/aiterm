"""Typing into an agent's session the one way the spike found safe (Operators spec §7.1), and
reading off its screen whether a prompt is open that typed text could answer."""
from __future__ import annotations

import asyncio
import functools
import json
import os
import re
import string
import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, Literal, NamedTuple, TypedDict

from .iterm_bridge import ItermPort, ItermUnavailable
from .models import HARNESS_BY_AGENT, AgentKind, Harness, SessionInfo, support_dir
from .offload import run_detached
from .text import shows
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
# The longest the Oracle may take on an Operator shell command before it runs, unchallenged.
GATE_TIMEOUT = 200.0
# How long /operator waits for the app to answer a forwarded tool call (operator_mcp).
OPERATOR_REQUEST_TIMEOUT = 30.0

# What a screen can show that typed text could answer: an approval, a startup dialog (folder trust,
# an update offer) or a menu, by its markers or Claude's consecutive numbered options at the last
# arrow. Checked in that order: approvals and startup dialogs draw menu options and footers too.
PromptKind = Literal["permission", "startup", "menu"]


class PromptDetails(TypedDict):
    kind: PromptKind | None
    text: str | None



def open_prompt(agent: AgentKind, screen: str, *, needs_input: bool = True) -> PromptKind | None:
    """The prompt open on `screen`, by the harness's markers or numbered menus. The last arrow
    must select an option next to its neighbour, outside the input frame. A later input arrow
    rules that out; sent numbered messages use the same arrow. An unsupported harness shows
    none, which proves nothing: delivery stays off. Without a needs-input hook, markers above
    a later input arrow are transcript text."""
    if (harness := HARNESS_BY_AGENT.get(agent)) is None:
        return None
    if _shows_transcript(harness, screen):
        return None
    markers = screen if needs_input else _below_input(harness, screen)
    if shows(markers, harness.permission_prompt):
        return "permission"
    if shows(markers, harness.startup_prompt):
        return "startup"
    if shows(markers, harness.menu_prompt):
        return "menu"
    if harness.numbered_menus and (arrows := _arrow_lines(harness, screen)):
        index, text = arrows[-1]
        lines = screen.splitlines()
        if (option := _OPTION.match(text)) and not _in_input_frame(harness, lines, index):
            if any(_neighbour_option(lines, index, offset) == int(option[1]) + offset for offset in (-1, 1)):
                return "menu"
    return None


def _session_prompt(session: SessionInfo, screen: str) -> PromptKind | None:
    """The prompt open on `session`'s screen, read as its state stands now: only a needs-input hook
    makes markers above a later input arrow count. Both what refuses a message and what session.prompt
    reports, so the two never disagree."""
    return open_prompt(session.agent, screen, needs_input=session.state == "needsInput")


# A numbered option or draft line, with its arrow (if any) already removed.
_OPTION = re.compile(r"\s*(\d+)\.\s")
_RULE = re.compile(r"─{4,}")


def _neighbour_option(lines: list[str], index: int, direction: int) -> int | None:
    """The adjacent option, across blank lines or indented wraps and descriptions."""
    indent = len(lines[index]) - len(lines[index].lstrip())
    neighbour = index + direction
    while 0 <= neighbour < len(lines):
        line = lines[neighbour]
        if option := _OPTION.match(line):
            return int(option[1])
        if line.strip() and len(line) - len(line.lstrip()) <= indent + 2:
            break
        neighbour += direction
    return None


def _arrow_lines(harness: Harness, screen: str) -> list[tuple[int, str]]:
    """The lines starting with the harness's arrow, with their index and the text past it."""
    if not harness.input_box:
        return []
    return [(index, text[1:]) for index, line in enumerate(screen.splitlines())
            if (text := line.lstrip()) and text[:1] in harness.input_box]


def _shows_transcript(harness: Harness, screen: str) -> bool:
    """The transcript footer is below every arrow, not quoted above a live input or menu."""
    arrows = _arrow_lines(harness, screen)
    lines = screen.splitlines()
    if any(_in_input_frame(harness, lines, index) for index, _ in arrows):
        return False
    start = arrows[-1][0] + 1 if arrows else 0
    return shows("\n".join(lines[start:]), harness.transcript_view)


def _in_input_frame(harness: Harness, lines: list[str], index: int) -> bool:
    """Claude's inline draft starts directly below a rule and has a closing rule."""
    if not harness.numbered_menus or index == 0 or not _RULE.fullmatch(lines[index - 1].strip()):
        return False
    for end in range(index + 1, len(lines)):
        if _RULE.fullmatch(lines[end].strip()):
            return True
    return False


def shows_input_box(agent: AgentKind, screen: str) -> bool:
    """Positive evidence of the CLI's own screen, idle or working, rather than a blank or crashed
    shell. A menu uses the same arrow, so a numbered line counts only inside the ruled input frame.
    Transcript views and unsupported harnesses show no input box."""
    if (harness := HARNESS_BY_AGENT.get(agent)) is None:
        return False
    if _shows_transcript(harness, screen):
        return False
    return any(not _OPTION.match(text) or (harness.numbered_menus and _in_input_frame(harness, screen.splitlines(), index))
               for index, text in _arrow_lines(harness, screen))


def _below_input(harness: Harness, screen: str) -> str:
    """Markers above the last input arrow belong to the transcript, not an unannounced dialog."""
    lines = screen.splitlines()
    for index, text in reversed(_arrow_lines(harness, screen)):
        if not _OPTION.match(text) or _in_input_frame(harness, lines, index):
            return "\n".join(lines[index:])
    return screen


# How AiTerm may type into one CLI, from the delivery check it last passed (tools/delivery_check.py):
# `auto` pastes and presses Enter; `pasteOnly` pastes and leaves the Enter to you; `off` types nothing.
DeliveryPolicy = Literal["auto", "pasteOnly", "off"]
# Written by the delivery check; read on every delivery, so a new check needs no daemon restart.
POLICY_PATH = support_dir() / "delivery-policy.json"


class Verdict(NamedTuple):
    """What the delivery check found for one CLI: the policy, and the version it was checked against.
    It vouches for that version's patch releases alone (`verdict_covers`): the Deliverer types into a
    session only while the CLI there reports one of them (SessionInfo.cli_version), so a new minor or
    major version the CLI installed since gets nothing until it is checked again."""
    policy: DeliveryPolicy
    version: str | None


_RELEASE = re.compile(r"(\d+)\.(\d+)\.(\d+)")


def verdict_covers(checked: str | None, installed: str | None) -> bool:
    """Whether a verdict written for version `checked` holds for the `installed` one. Both must be
    plain `major.minor.patch` numbers, as the delivery check writes them (`2.1.301`); a verdict for
    X.Y.Z then holds for every X.Y.W, a later patch or an earlier one, since a patch release does not
    redraw the screens the check read. Another major or minor version gets nothing until it is
    checked again, and so does a version missing on either side or written any other way
    (`2.1`, `2.1.301-beta`, `v2.1.301`). The app's Settings holds a CLI's version to the same rule."""
    if checked is None or installed is None:
        return False
    a, b = _RELEASE.fullmatch(checked), _RELEASE.fullmatch(installed)
    return a is not None and b is not None and (int(a[1]), int(a[2])) == (int(b[1]), int(b[2]))


# A CLI the delivery check has not passed, or passed for no version it named.
NOT_CHECKED = Verdict("off", None)


def _screen_is_readable(agent: AgentKind) -> bool:
    # Prompt markers to refuse on and an input box to recognise the screen by: delivery needs both.
    harness = HARNESS_BY_AGENT[agent]
    return bool(harness.permission_prompt or harness.startup_prompt or harness.menu_prompt) and bool(harness.input_box)


def load_policy(path: Path) -> dict[AgentKind, Verdict]:
    """Every harness's verdict from the delivery check's file: paste-safe and submit-safe is `auto`,
    paste-safe alone `pasteOnly`, and anything else -- a harness the file does not name, a value
    that is not a JSON true, an entry that names no version, a file missing or unreadable -- `off`.
    So is a harness with no prompt markers, whatever the file says: `open_prompt` reads none off its
    screen, and that must not pass for a screen with no prompt open. Delivery fails closed: a CLI
    whose pasted text might act as keys in one of its prompts gets none at all (spec §7.1)."""
    raw: Any
    try:
        st = path.stat()
        raw = _policy_at(path, (st.st_ino, st.st_mtime_ns, st.st_ctime_ns, st.st_size))
    except (OSError, ValueError, RecursionError):  # ValueError: not JSON, or bytes that are not UTF-8
        raw = None
    entries = raw if isinstance(raw, dict) else {}
    verdicts: dict[AgentKind, Verdict] = {}
    for agent in HARNESS_BY_AGENT:
        entry = entries.get(agent)
        version = entry.get("version") if isinstance(entry, dict) else None
        if not isinstance(version, str) or not version or not _screen_is_readable(agent):
            verdicts[agent] = NOT_CHECKED
            continue
        paste = isinstance(entry, dict) and entry.get("pasteSafe") is True
        submit = isinstance(entry, dict) and entry.get("submitSafe") is True
        verdicts[agent] = Verdict("auto" if paste and submit else "pasteOnly" if paste else "off", version)
    return verdicts


@functools.lru_cache(maxsize=1)
def _policy_at(path: Path, stamp: tuple[int, int, int, int]) -> Any:
    # Cache successful reads only; a transient I/O failure must be retried even without a rewrite.
    return json.loads(path.read_text(encoding="utf-8"))


def read_policy() -> dict[AgentKind, Verdict]:
    return load_policy(POLICY_PATH)


def shows_update_offer(agent: AgentKind, screen: str) -> bool:
    """Whether `screen` shows the CLI's update offer: a startup dialog (open_prompt) that bears every
    one of the harness's update markers. Never a folder's trust dialog, which has other words."""
    harness = HARNESS_BY_AGENT.get(agent)
    if harness is None or not harness.update_prompt or open_prompt(agent, screen, needs_input=False) != "startup":
        return False
    # A numbered Codex draft has the same arrow as a menu option. No arrow may sit below all
    # the update words; selecting the last update option itself still leaves its words on that line.
    if arrows := _arrow_lines(harness, screen):
        if not shows("\n".join(screen.splitlines()[arrows[-1][0]:]), harness.update_prompt):
            return False
    return all(shows(_below_input(harness, screen), (phrase,)) for phrase in harness.update_prompt)


# Bracketed paste: what a terminal wraps pasted text in, so the CLI reads it as text, not keys. A
# prompt that opens while it arrives receives a paste rather than shortcut keys (spec §7.1).
PASTE_START, PASTE_END = "\x1b[200~", "\x1b[201~"
SUBMIT = "\r"
# Esc: what declines Codex's update offer (session.dismissStartup).
ESC = "\x1b"
# What a paste may not carry: every C0 control but tab and newline -- ESC above all, which could end
# the paste early and type the rest as keys -- DEL, and the C1 controls, CSI among them.
_UNPASTEABLE = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def pasteable(text: str) -> str:
    """`text` as it may be pasted: Windows and old Mac line endings as newlines -- a CR is Enter --
    and every control that could act as a key removed."""
    return _UNPASTEABLE.sub("", text.replace("\r\n", "\n").replace("\r", "\n"))


def write_message_file(worktree: str, text: str) -> str:
    """Leaves `text` in the worktree's next `.aiterm/messages/<n>.md` and returns the one line that
    tells the agent to read it (spec §7.1, the message-file fallback): one known string, so the
    delivery check tests exactly what is typed. The folder keeps itself out of git with its own
    `.gitignore`, as `.aiterm/first-prompt.md` is kept out. Numbered on from the highest there, each
    made exclusively, so two tabs of one worktree cannot take the same number. ValueError for a
    worktree that is not a folder; OSError for one that cannot be written."""
    if not os.path.isabs(worktree) or not os.path.isdir(worktree):
        raise ValueError(f"the worktree {worktree} is not a folder")
    folder = Path(worktree) / ".aiterm" / "messages"
    folder.mkdir(parents=True, exist_ok=True)
    ignore = folder / ".gitignore"
    if not ignore.exists():
        ignore.write_text("*\n", encoding="utf-8")
    number = max((int(path.stem) for path in folder.glob("*.md") if path.stem.isdigit()), default=0)
    while True:
        number += 1
        try:
            with open(folder / f"{number}.md", "x", encoding="utf-8") as f:
                f.write(text)
        except FileExistsError:
            continue
        return f"Read .aiterm/messages/{number}.md and act on it."


# Why a delivery was refused, or its Enter held back, in one word the app can tell apart and say in its
# own words (the Operator's wake Notice); the reason says it in the daemon's.
RefusalCode = Literal[
    "ownership",           # the task changed hands
    "itermDisconnected",   # iTerm2 is not connected
    "sessionClosed",       # the session has closed
    "replaced",            # another process now runs in the session
    "notChecked",          # the CLI's version has no pass from the delivery check
    "unsupported",         # prompts cannot be read off this CLI's screen
    "typing",              # you are typing (a wake line only)
    "unsentInput",         # unsent text waits in the input (a wake line only)
    "screenUnread",        # the screen could not be read, or came back empty
    "prompt",              # a prompt is open: it waits on the person
    "unrecognisedScreen",  # the screen shows no input box
    "nothing",             # nothing left to paste
    "messageFile",         # too long to paste, and no message file could be left
    "wakeText",            # a wake line that is not plain enough to type
    "itermRefused",        # iTerm2 did not take the text, or the Enter
    "pasteOnly",           # pasted, the Enter left to the person
]


@dataclass(frozen=True, slots=True)
class Refusal:
    """Why a session cannot take text now, or why its Enter was held back."""
    code: RefusalCode
    reason: str


@dataclass(frozen=True, slots=True)
class DeliveryResult:
    """`delivered`: pasted and entered. `partial`: pasted, and the Enter held back -- the text waits
    visibly in the input, and `reason` says why. `refused`: nothing was typed. Neither is retried.
    `code` names the reason (RefusalCode); tests compare the words, so it is left out of equality."""
    result: Literal["delivered", "partial", "refused"]
    reason: str | None = None
    code: RefusalCode | None = field(default=None, compare=False)

    def to_json(self) -> dict[str, Any]:
        return {"result": self.result, "reason": self.reason, "code": self.code}


def _refused(why: Refusal) -> DeliveryResult:
    return DeliveryResult("refused", why.reason, why.code)


def _partial(why: Refusal) -> DeliveryResult:
    return DeliveryResult("partial", why.reason, why.code)


# Quotes a word may be wrapped in, besides ASCII punctuation, when a wake line's words are counted.
_QUOTES = "‘’“”"


def wake_text_problem(text: str) -> str | None:
    """Why `text` may not be typed as a wake line, or None when it may. A wake line is fixed and plain
    (the app's OperatorWaker): no digit and no one-letter word, which a menu opening as it arrives could
    take for its answer (`1`, `y`, `a`), and short enough to paste, since a wake line never goes
    through a message file."""
    if any(ch.isdigit() for ch in text):
        return "a wake line may not carry a digit"
    words = (word.strip(string.punctuation + _QUOTES) for word in text.split())
    if any(len(word) == 1 and word.isalpha() for word in words):
        return "a wake line may not carry a one-letter word"
    if len(text) > MESSAGE_FILE_THRESHOLD:
        return "a wake line is too long to paste"
    return None


class Deliverer:
    """The delivery adapter (spec §7.1): types into an agent's session the one way the spike found
    safe. It checks the session can take text -- iTerm2 connected, the session open, its CLI checked
    paste-safe for the version it runs (`load_policy`, `verdict_covers`, SessionInfo.cli_version), its
    screen read and no prompt open -- pastes the text bracketed, waits SUBMIT_DELAY, checks again, and
    only then presses Enter. Anything that changed in between holds the Enter back: the result is
    `partial`, and the text waits in the input for whoever looks next. An operator's wake line is held
    to every check but the delivery check's pass (`_ready`). Deliveries to one session take turns, so
    two pastes never interleave with their Enters. Which run and task a session belongs to, and whether
    that run is active, is the app's to check before it asks."""

    def __init__(self, iterm: ItermPort, registry: SessionRegistry, policy: Callable[[], Mapping[AgentKind, Verdict]],
                 typing: TypingGuard, *, monotonic: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep):
        self.iterm, self.registry, self.policy, self.typing = iterm, registry, policy, typing
        self._monotonic, self._sleep = monotonic, sleep
        self._locks: dict[str, asyncio.Lock] = {}
        self._ownership: dict[str, int] = {}
        # When text was last pasted into each session: a prompt it submits soon after is AiTerm's, not yours.
        self._pasted: dict[str, float] = {}

    def forget_session(self, session_id: str) -> None:
        """What a closed session leaves behind: its turn lock, its ownership generation and its last paste."""
        self._locks.pop(session_id, None)
        self._ownership.pop(session_id, None)
        self._pasted.pop(session_id, None)

    def delivered_within(self, session_id: str, now: float, seconds: float) -> bool:
        """Whether AiTerm pasted text into the session within `seconds` of `now`."""
        at = self._pasted.get(session_id)
        return at is not None and 0 <= now - at <= seconds

    def set_ownership(self, session_id: str, ownership: int) -> None:
        """The task's ownership generation, which a takeover increments (session.setOwnership): a
        send begun under an older one is refused, and one in flight when it changes gets no Enter.
        Kept in memory only: after a daemon restart the app sets each again. Never lowered: a late or
        repeated call cannot turn an older send current again."""
        self._ownership[session_id] = max(ownership, self._ownership.get(session_id, ownership))

    def _turn(self, session_id: str) -> asyncio.Lock:
        return self._locks.setdefault(session_id, asyncio.Lock())

    async def deliver(self, session_id: str, text: str, ownership: int, *, wake: bool = False,
                      worktree: str | None = None) -> DeliveryResult:
        """Types `text` into the session. `ownership` is the task's generation as the caller knew it;
        `wake` marks an operator's wake line, which waits while you type and needs no pass from the
        delivery check; `worktree` is where a message too long to paste is left."""
        async with self._turn(session_id):
            result = await self._deliver(session_id, text, ownership, wake, worktree)
            if result.result == "partial":
                # The text waits in the input: a wake line pasted after it would be sent with it.
                self.typing.mark_unsent(session_id)
            return result

    async def _deliver(self, session_id: str, text: str, ownership: int, wake: bool, worktree: str | None) -> DeliveryResult:
        # A session no generation was set for takes the first send's: until the app sets one, a
        # send is as current as anything known. A newer one becomes the session's.
        if ownership < self._ownership.setdefault(session_id, ownership):
            return _refused(Refusal("ownership", "the task changed hands after this message was written"))
        self._ownership[session_id] = ownership
        if isinstance(ready := await self._check(session_id, ownership, wake), Refusal):
            return _refused(ready)
        session, policy = ready
        if not (body := pasteable(text)).strip():
            return _refused(Refusal("nothing", "there is nothing to deliver"))
        if wake and (problem := wake_text_problem(body)) is not None:
            return _refused(Refusal("wakeText", problem))
        if len(body) > MESSAGE_FILE_THRESHOLD:
            if worktree is None:
                return _refused(Refusal("messageFile", "the message is too long to paste and has no worktree to be left in"))
            try:
                # Another repository's disk: written on a worker thread, as the tick reads one.
                body = await run_detached(functools.partial(write_message_file, worktree, body))
            except ValueError as exc:
                return _refused(Refusal("messageFile", str(exc)))
            except OSError as exc:
                return _refused(Refusal("messageFile", f"the message file could not be written: {exc}"))
            # The write took a worker thread's while: everything checked before it is checked again,
            # right before the paste. A refusal now leaves the file behind, unread and out of git.
            if isinstance(again := await self._check(session_id, ownership, wake, process=session), Refusal):
                return _refused(again)
            session, policy = again  # a verdict that changed to paste-only meanwhile keeps the Enter back
        try:
            await self.iterm.send_text(session_id, PASTE_START + body + PASTE_END)
        except KeyError:
            return _refused(Refusal("sessionClosed", "the session has closed"))
        except ItermUnavailable as exc:
            self._pasted[session_id] = self._monotonic()
            return _partial(Refusal("itermRefused", f"iTerm2 may have taken the text before the connection failed: {exc}"))
        self._pasted[session_id] = self._monotonic()
        if policy == "pasteOnly":
            return _partial(Refusal("pasteOnly", f"pasted without Enter: this {session.agent} version is checked paste-safe only, "
                                                 "so you press Enter"))
        await self._sleep(SUBMIT_DELAY)
        if (why := await self._changed(session, ownership, wake)) is not None:
            return _partial(why)
        try:
            await self.iterm.send_text(session_id, SUBMIT)
        except (KeyError, ItermUnavailable) as exc:
            return _partial(Refusal("itermRefused", f"the Enter could not be sent ({exc}); the text waits unsent in the input"))
        return DeliveryResult("delivered")

    async def _check(self, session_id: str, ownership: int, wake: bool, *,
                     process: SessionInfo | None = None) -> tuple[SessionInfo, DeliveryPolicy] | Refusal:
        """Why the session cannot take text now -- or, when it can, the session and how its CLI may be
        typed into. Made before anything is typed, and again right before the paste when a message
        file was written in between, `process` then the session as the first check found it."""
        ready = self._ready(session_id, ownership, wake, process=process)
        if isinstance(ready, Refusal):
            return ready
        session, _policy = ready
        if (why := await self._ineligible(session_id)) is not None:
            return why
        return self._ready(session_id, ownership, wake, process=session)

    def _ready(self, session_id: str, ownership: int, wake: bool, *,
               process: SessionInfo | None = None) -> tuple[SessionInfo, DeliveryPolicy] | Refusal:
        if self._ownership.get(session_id) != ownership:
            return Refusal("ownership", "the task changed hands after this message was written")
        if not self.iterm.is_connected():
            return Refusal("itermDisconnected", "iTerm2 is not connected")
        if process is not None and (why := self._replaced(process)) is not None:
            return why
        if (session := self.registry.get(session_id)) is None:
            return Refusal("sessionClosed", "the session has closed")
        policy: DeliveryPolicy
        if wake:
            # The operator's own tab, which only the app's OperatorWaker types into, with a fixed plain
            # line (`wake_text_problem`): held to every check of its screen and of you, and not to the
            # delivery check's pass, so the operator is woken whatever version runs it. Its screen must
            # still be one whose prompts can be read: a harness without markers shows none.
            if session.agent not in HARNESS_BY_AGENT or not _screen_is_readable(session.agent):
                return Refusal("unsupported", f"AiTerm cannot read whether a prompt is open in {session.agent}")
            policy = "auto"
        else:
            policy, version = self.policy().get(session.agent, NOT_CHECKED)
            if policy == "off":
                return Refusal("notChecked", f"AiTerm has not checked that it can type into this {session.agent} version safely")
            if not verdict_covers(version, session.cli_version):
                # The check vouches for its version's patch releases: another minor or major version, or
                # one whose files have not named their version yet, gets nothing until it is checked.
                return Refusal("notChecked",
                               f"{session.agent} {session.cli_version or '(version unknown)'} has not passed the delivery check")
        if wake and self.typing.is_typing(session_id, self._monotonic()):
            # Not lost: the operator sees the news at its next run_status (spec §7.4).
            return Refusal("typing", "you are typing")
        if wake and self.typing.has_unsent_input(session_id):
            # Pasted after words not yet sent, the wake line's Enter would send them with it.
            return Refusal("unsentInput", "unsent text waits in its input")
        return session, policy

    def _replaced(self, session: SessionInfo) -> Refusal | None:
        """Why `session`, as a delivery began with it, is no longer the one open: closed, or another
        process -- another conversation, maybe another CLI -- in its tab."""
        if (now := self.registry.get(session.session_id)) is None:
            return Refusal("sessionClosed", "the session has closed")
        if now.job_pid != session.job_pid or now.agent != session.agent:
            return Refusal("replaced", "another process now runs in the session")
        return None

    async def _ineligible(self, session_id: str) -> Refusal | None:
        """Why the session cannot take text now, as its screen shows it; None when it can. The prompt
        it refuses on is the one `prompt` reads, so a message is never held back by one nobody sees."""
        try:
            screen = await self.iterm.screen_text(session_id)
        except ItermUnavailable as exc:
            return Refusal("screenUnread", f"its screen could not be read: {exc}")
        if screen is None or (session := self.registry.get(session_id)) is None:
            return Refusal("sessionClosed", "the session has closed")
        if not screen.strip():
            # The spike saw a read come back empty: nothing then shows that no prompt is open.
            return Refusal("screenUnread", "the screen came back empty, so whether a prompt is open is unknown")
        if (prompt := _session_prompt(session, screen)) is not None:
            return Refusal("prompt", f"a {prompt} prompt is open")
        if not shows_input_box(session.agent, screen):
            # Prompts are checked first: an approval's menu draws `❯` on its selected option too.
            return Refusal("unrecognisedScreen", "unrecognised screen")
        return None

    async def _changed(self, session: SessionInfo, ownership: int, wake: bool) -> Refusal | None:
        """What holds the Enter back: anything that changed while the paste settled."""
        ready = await self._check(session.session_id, ownership, wake, process=session)
        if isinstance(ready, Refusal):
            if ready.code == "ownership":
                return Refusal("ownership", "you took the task over before Enter; the text waits unsent in the input")
            if ready.code == "typing":
                return Refusal("typing", "you started typing before Enter; the wake line waits unsent in the input")
            return Refusal(ready.code, f"before Enter, {ready.reason}; the text waits unsent in the input")
        if ready[1] != "auto":
            return Refusal("pasteOnly", "before Enter, automatic submission is no longer checked safe")
        return None

    async def prompt(self, session_id: str) -> PromptKind | None:
        """The prompt open in the session now. KeyError for a session not open."""
        return (await self.prompt_details(session_id))["kind"]

    async def prompt_details(self, session_id: str) -> PromptDetails:
        """Classify and quote one screen read, so the operator sees the question and all its options.
        The full visible screen preserves context that harness-specific menu slicing could lose."""
        if (session := self.registry.get(session_id)) is None or (screen := await self.iterm.screen_text(session_id)) is None:
            raise KeyError(session_id)
        if not screen.strip():
            raise ItermUnavailable("the screen came back empty, so whether a prompt is open is unknown")
        kind = _session_prompt(session, screen)
        return {"kind": kind, "text": screen if kind is not None else None}

    async def dismiss_startup(self, session_id: str) -> bool:
        """Declines the CLI's update offer with Esc (session.dismissStartup): AiTerm always declines one
        itself (spec §7.1), so a task's agent is not left waiting on it. Sent only while the screen,
        read within the session's turn, shows that offer below any input arrow and the tab is not
        working. It must bear every update marker: any other
        startup dialog -- a folder's trust above all -- is yours to answer, and is left open. True
        when Esc was sent. KeyError for a session not open."""
        if self.registry.get(session_id) is None:
            raise KeyError(session_id)
        async with self._turn(session_id):
            if (screen := await self.iterm.screen_text(session_id)) is None:
                raise KeyError(session_id)
            if (current := self.registry.get(session_id)) is None:
                raise KeyError(session_id)
            if current.state == "working" or not shows_update_offer(current.agent, screen):
                return False
            await self.iterm.send_text(session_id, ESC)
            return True
