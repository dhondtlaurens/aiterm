# daemon/tests/test_delivery.py
"""The delivery adapter (Operators spec §7.1): what it reads off a screen, the policy it obeys, and
how it types."""
from __future__ import annotations

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from aitermd import delivery
from aitermd.delivery import PASTE_END, PASTE_START, Deliverer, DeliveryResult, load_policy, open_prompt
from aitermd.iterm_bridge import ItermUnavailable
from aitermd.keystrokes import TypingGuard
from aitermd.models import HARNESS_BY_AGENT, Frame
from aitermd.sessions import SessionRegistry
from tests.fake_iterm import FakeIterm

# What Claude Code 2.1.301 and Codex 0.160.0 drew in the spike (15 Oct 2026), read back from iTerm2.
CLAUDE_PERMISSION = """\
 Bash command
   npm install
   Install the dependencies
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for npm install commands in /Users/me/wt
   3. No, and tell Claude what to do differently (esc)
"""
CLAUDE_MENU = """\
 Select model
 ❯ 1. Default (recommended)
   2. Opus
 Enter to select · Esc to cancel
"""
CLAUDE_TRUST = """\
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. No, exit
   2. Yes, I trust this folder
 Enter to confirm · Esc to cancel
"""
CODEX_PERMISSION = """\
  Would you like to run the following command?
  $ touch /Users/me/outside.txt
› 1. Yes, proceed (y)
  2. Yes, and don't ask again for this command (p)
  3. No, and tell Codex what to do differently (esc)
  Press enter to confirm or esc to cancel
"""
CODEX_TRUST = """\
  You are in /Users/me/wt
  Trust this folder?
› 1. Yes, allow Codex to work in this folder
  2. No, ask me to approve edits and commands
"""
CODEX_UPDATE = """\
  ✨ Update available! 0.160.0 -> 0.161.0
› 1. Update now (runs `npm install -g @openai/codex`)
  2. Skip
  3. Skip until next version
"""
# An idle Codex whose banner announces an update: no dialog is open, so this must read as none. The
# empty prompt's trailing space is written \x20: ruff (W291) flags trailing whitespace even in a string.
CODEX_IDLE_WITH_UPDATE_BANNER = """\
╭───────────────────────────────────────────────╮
│ >_ OpenAI Codex (v0.160.0)                    │
│ ✨ Update available! 0.160.0 -> 0.161.0        │
│ model: gpt-6-astra medium   /model to change  │
╰───────────────────────────────────────────────╯
›\x20
  ? for shortcuts
"""
IDLE = " ╭──────────╮\n │ >        │\n ╰──────────╯\n  ? for shortcuts"


@pytest.mark.parametrize("agent,screen,expected", [
    ("claude", CLAUDE_PERMISSION, "permission"),
    ("claude", CLAUDE_MENU, "menu"),
    # The trust dialog also says "Esc to cancel": a startup dialog wins over a menu.
    ("claude", CLAUDE_TRUST, "startup"),
    ("claude", IDLE, None),
    # Codex's approval ends with its menu's line: the permission wins.
    ("codex", CODEX_PERMISSION, "permission"),
    ("codex", CODEX_TRUST, "startup"),
    ("codex", CODEX_UPDATE, "startup"),
    ("codex", IDLE, None),
    # The banner only announces an update; the dialog is known by its own options.
    ("codex", CODEX_IDLE_WITH_UPDATE_BANNER, None),
    # Drawn with cursor moves for spaces, or wrapped where the window is narrow.
    ("claude", "Doyouwantto\nproceed?", "permission"),
    ("codex", "Press enter to confirm\nor esc to cancel", "menu"),
])
def test_open_prompt_reads_each_harness_markers(agent, screen, expected):
    assert open_prompt(agent, screen) == expected


@pytest.mark.parametrize("agent", ["grok", "pi", "shell"])
def test_a_harness_without_markers_never_shows_a_prompt(agent):
    assert open_prompt(agent, CLAUDE_PERMISSION + CODEX_PERMISSION) is None


def test_the_markers_are_the_spikes():
    claude, codex = HARNESS_BY_AGENT["claude"], HARNESS_BY_AGENT["codex"]
    assert claude.permission_prompt == ("Do you want to proceed?",)
    assert claude.menu_prompt == ("Enter to select", "Esc to cancel")
    assert "Yes, I trust this folder" in claude.startup_prompt
    assert codex.permission_prompt == ("Would you like to run the following command?",)
    assert codex.menu_prompt == ("Press enter to confirm or esc to cancel",)
    assert codex.startup_prompt == ("Trust this folder?", "Skip until next version", "Update now")
    assert not any("Update available" in marker for marker in codex.startup_prompt), "the idle banner says that too"


def test_the_timings_are_the_contracts():
    assert (delivery.SUBMIT_DELAY, delivery.TYPING_QUIET, delivery.MESSAGE_FILE_THRESHOLD) == (0.4, 10.0, 2000)
    assert (delivery.WAKE_COALESCE, delivery.RECONCILE_INTERVAL, delivery.STALL_AFTER) == (3.0, 60.0, 1200.0)
    assert (delivery.CHALLENGE_TIMEOUT, delivery.OPERATOR_REQUEST_TIMEOUT, delivery.LAUNCH_ADOPT_AFTER) == (180.0, 30.0, 60.0)


def _policy_file(tmp_path, content):
    path = tmp_path / "delivery-policy.json"
    path.write_bytes(content if isinstance(content, bytes) else json.dumps(content).encode())
    return path


NOTHING_CHECKED = {"claude": ("off", None), "codex": ("off", None), "grok": ("off", None), "pi": ("off", None)}


def test_paste_and_submit_safe_is_auto_and_paste_safe_alone_is_paste_only(tmp_path):
    path = _policy_file(tmp_path, {
        "claude": {"version": "2.1.301", "pasteSafe": True, "submitSafe": True, "checkedAt": "2026-10-16T08:00:00Z"},
        "codex": {"version": "0.160.0", "pasteSafe": True, "submitSafe": False, "checkedAt": "2026-10-16T08:00:00Z"},
        # The delivery check's own iTerm2 entry is no harness: it is read past.
        "iterm": {"version": "3.7.5", "keystrokesPassThrough": True},
    })
    assert load_policy(path) == {"claude": ("auto", "2.1.301"), "codex": ("pasteOnly", "0.160.0"), "grok": ("off", None),
                                 "pi": ("off", None)}
    assert load_policy(path)["claude"].version == "2.1.301"


@pytest.mark.parametrize("entry", [
    {"version": "2.1.301", "pasteSafe": False, "submitSafe": True},   # submit-safe means nothing without paste-safe
    {"version": "2.1.301", "pasteSafe": "true", "submitSafe": True},  # only a JSON true counts
    {"version": "2.1.301", "pasteSafe": 1, "submitSafe": 1},
    {"version": "2.1.301", "submitSafe": True},
    "auto",
])
def test_anything_short_of_paste_safe_is_off(tmp_path, entry):
    assert load_policy(_policy_file(tmp_path, {"claude": entry}))["claude"].policy == "off"


@pytest.mark.parametrize("version", [None, "", 2, ["2.1.301"]])
def test_a_verdict_that_names_no_version_vouches_for_none(tmp_path, version):
    entry = {"pasteSafe": True, "submitSafe": True} | ({} if version is None else {"version": version})
    assert load_policy(_policy_file(tmp_path, {"claude": entry}))["claude"] == ("off", None)


@pytest.mark.parametrize("content", [b"{not json", b"[]", b"null", b"\xff\xfe{}"])
def test_an_unreadable_policy_turns_every_delivery_off(tmp_path, content):
    assert load_policy(_policy_file(tmp_path, content)) == NOTHING_CHECKED


def test_a_missing_policy_turns_every_delivery_off(tmp_path):
    assert load_policy(tmp_path / "nowhere.json") == NOTHING_CHECKED


def test_the_policy_lives_in_application_support():
    assert delivery.POLICY_PATH == Path.home() / "Library" / "Application Support" / "AiTerm" / "delivery-policy.json"


@pytest.mark.parametrize("agent", ["grok", "pi"])
def test_a_harness_with_no_prompt_markers_stays_off_whatever_the_file_says(tmp_path, agent):
    # open_prompt sees nothing on such a harness's screen, which proves nothing: it must not fail open.
    entry = {"version": "1.0.44", "pasteSafe": True, "submitSafe": True}
    assert load_policy(_policy_file(tmp_path, {agent: entry}))[agent] == ("off", None)


class Clock:
    def __init__(self, now: float = 1000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


class Pauses:
    """Stands in for asyncio.sleep: records each pause, yields to the loop once as a real pause
    does, and runs what a test scripted for it -- a prompt opening, a takeover -- in the middle of
    a delivery."""

    def __init__(self):
        self.taken: list[float] = []
        self.during: list = []

    async def __call__(self, seconds: float) -> None:
        self.taken.append(seconds)
        for step in self.during:
            step()
        await asyncio.sleep(0)


@pytest.fixture
async def rig():
    """A Claude 2.1.301 idle in a task's tab, a Deliverer over it whose policy says auto for that
    Claude and Codex 0.160.0, and the clock and pauses it runs on."""
    iterm, registry, guard, clock, pauses = FakeIterm(), SessionRegistry(), TypingGuard(), Clock(), Pauses()
    _wid, sid = await iterm.create_window("/wt", "x", {"aiterm_task": "t1"}, Frame(0, 0, 10, 10))
    await iterm.user_runs(sid, "claude", job_pid=4242)
    registry.apply_snapshot(await iterm.snapshot())
    registry.set_cli_version(sid, "2.1.301")
    iterm.screens[sid] = IDLE
    policy = {"claude": ("auto", "2.1.301"), "codex": ("auto", "0.160.0")}
    deliverer = Deliverer(iterm, registry, lambda: policy, guard, monotonic=clock, sleep=pauses)
    return SimpleNamespace(iterm=iterm, registry=registry, guard=guard, clock=clock, pauses=pauses, policy=policy,
                           deliverer=deliverer, sid=sid)


def pasted(text: str) -> str:
    return PASTE_START + text + PASTE_END


async def test_text_is_pasted_then_entered_after_the_pause(rig):
    assert await rig.deliverer.deliver(rig.sid, "Run the tests.", 1) == DeliveryResult("delivered", None)
    assert rig.iterm.sent == [(rig.sid, pasted("Run the tests.")), (rig.sid, "\r")]
    assert rig.pauses.taken == [delivery.SUBMIT_DELAY]


async def test_multi_line_text_is_one_paste_and_one_enter(rig):
    await rig.deliverer.deliver(rig.sid, "First line.\r\nSecond line.\n", 1)
    assert rig.iterm.sent == [(rig.sid, pasted("First line.\nSecond line.\n")), (rig.sid, "\r")]


async def test_control_characters_cannot_end_the_paste_or_act_as_keys(rig):
    # An ESC would let the text end the paste early (ESC[201~) and type the rest as keys; U+009B is
    # a CSI to some terminals.
    await rig.deliverer.deliver(rig.sid, "a\x1b[201~p\x03b\tc\x9b1~", 1)
    assert rig.iterm.sent[0] == (rig.sid, pasted("a[201~pb\tc1~"))


@pytest.mark.parametrize("screen,reason", [
    (CLAUDE_PERMISSION, "a permission prompt is open"),
    (CLAUDE_TRUST, "a startup prompt is open"),
    (CLAUDE_MENU, "a menu prompt is open"),
    ("  \n \n", "the screen came back empty, so whether a prompt is open is unknown"),
])
async def test_nothing_is_typed_while_a_prompt_is_open_or_the_screen_is_unread(rig, screen, reason):
    rig.iterm.screens[rig.sid] = screen
    assert await rig.deliverer.deliver(rig.sid, "hello", 1) == DeliveryResult("refused", reason)
    assert rig.iterm.sent == []


async def test_a_screen_iterm2_cannot_read_is_refused(rig):
    rig.iterm.screen_error = ItermUnavailable("iTerm2 did not answer within 10s")
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert result == DeliveryResult("refused", "its screen could not be read: iTerm2 did not answer within 10s")


async def test_a_prompt_that_opens_between_paste_and_enter_gets_no_enter(rig):
    rig.pauses.during.append(lambda: rig.iterm.screens.__setitem__(rig.sid, CLAUDE_PERMISSION))
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert result == DeliveryResult("partial", "before Enter, a permission prompt is open; the text waits unsent in the input")
    assert rig.iterm.sent == [(rig.sid, pasted("hello"))]


async def test_another_process_in_the_tab_between_paste_and_enter_gets_no_enter(rig):
    def another_claude():
        tab = rig.iterm.sessions[rig.sid]
        tab.job_pid = 4343
        rig.registry.apply_snapshot([tab])

    rig.pauses.during.append(another_claude)
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert result == DeliveryResult("partial", "before Enter, another process now runs in the session; the text waits unsent "
                                               "in the input")
    assert rig.iterm.sent == [(rig.sid, pasted("hello"))]


@pytest.mark.parametrize("verdict", [("off", "2.1.301"), ("off", None), None])
async def test_a_cli_not_checked_paste_safe_gets_nothing(rig, verdict):
    if verdict is None:
        del rig.policy["claude"]
    else:
        rig.policy["claude"] = verdict
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert result == DeliveryResult("refused", "AiTerm has not checked that it can type into this claude version safely")
    assert rig.iterm.sent == [] and rig.iterm.screen_reads == []


@pytest.mark.parametrize("running,reason", [
    ("2.1.302", "claude 2.1.302 has not passed the delivery check"),   # updated since its check
    (None, "claude (version unknown) has not passed the delivery check"),
])
async def test_a_cli_version_the_check_did_not_pass_gets_nothing(rig, running, reason):
    rig.registry.get(rig.sid).cli_version = running
    assert await rig.deliverer.deliver(rig.sid, "hello", 1) == DeliveryResult("refused", reason)
    assert rig.iterm.sent == [] and rig.iterm.screen_reads == []


async def test_a_paste_only_cli_gets_the_text_and_no_enter(rig):
    rig.policy["claude"] = ("pasteOnly", "2.1.301")
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert result == DeliveryResult("partial", "pasted without Enter: this claude version is checked paste-safe only, so you press Enter")
    assert rig.iterm.sent == [(rig.sid, pasted("hello"))] and rig.pauses.taken == []


async def test_a_session_that_is_gone_is_refused(rig):
    assert await rig.deliverer.deliver("s404", "hello", 1) == DeliveryResult("refused", "the session has closed")
    await rig.iterm.user_closes_session(rig.sid)  # closed since the registry last looked
    assert await rig.deliverer.deliver(rig.sid, "hello", 1) == DeliveryResult("refused", "the session has closed")


async def test_without_iterm2_nothing_is_typed(rig):
    await rig.iterm.disconnect()
    assert await rig.deliverer.deliver(rig.sid, "hello", 1) == DeliveryResult("refused", "iTerm2 is not connected")


async def test_text_with_nothing_left_to_paste_is_refused(rig):
    assert await rig.deliverer.deliver(rig.sid, " \x1b\n", 1) == DeliveryResult("refused", "there is nothing to deliver")
    assert rig.iterm.sent == []


async def test_a_paste_iterm2_refuses_is_refused_and_not_retried(rig):
    rig.iterm.send_error = ItermUnavailable("iTerm2 closed the connection")
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert result == DeliveryResult("refused", "iTerm2 did not take the text: iTerm2 closed the connection")
    assert rig.iterm.sent == []


async def test_the_prompt_is_read_from_the_screen(rig):
    assert await rig.deliverer.prompt(rig.sid) is None
    rig.iterm.screens[rig.sid] = CLAUDE_PERMISSION
    assert await rig.deliverer.prompt(rig.sid) == "permission"
    with pytest.raises(KeyError):
        await rig.deliverer.prompt("s404")


async def test_interrupt_sends_esc_and_nothing_else(rig):
    await rig.deliverer.interrupt(rig.sid)
    assert rig.iterm.sent == [(rig.sid, "\x1b")]
    with pytest.raises(KeyError):
        await rig.deliverer.interrupt("s404")


async def test_deliveries_to_one_session_take_turns(rig):
    first = asyncio.create_task(rig.deliverer.deliver(rig.sid, "one", 1))
    second = asyncio.create_task(rig.deliverer.deliver(rig.sid, "two", 1))
    await asyncio.gather(first, second)
    assert [text for _sid, text in rig.iterm.sent] == [pasted("one"), "\r", pasted("two"), "\r"]
