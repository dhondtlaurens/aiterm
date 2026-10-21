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
from aitermd.delivery import PASTE_END, PASTE_START, Deliverer, DeliveryResult, load_policy, open_prompt, shows_input_box
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
# Codex 0.163's own review of hooks it has not trusted, as the delivery check met it: a numbered menu
# with no input box under it.
CODEX_HOOKS_REVIEW = """\
  Hooks need review
  6 hooks are new or changed.
  Hooks can run outside the sandbox after you trust them.

› 1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won't run)

  enter confirm · esc skip
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
# Idle and at work, as the spike drew them: Claude's input line starts with ❯ between two rules,
# Codex's with ›. (The empty input's trailing space is written \x20 for ruff's W291.)
IDLE = "────────────────\n❯\x20\n────────────────\n  ? for shortcuts"
CLAUDE_WORKING = "✻ Thinking… (esc to interrupt)\n\n────────────────\n❯\x20\n────────────────\n  ⏵⏵ accept edits on"
CODEX_IDLE = "›\x20Ask Codex to do anything\n\n  ? for shortcuts"
CODEX_WORKING = "• Working (3s • esc to interrupt)\n\n›\x20Ask Codex to do anything\n\n  ? for shortcuts"
# A shell prompt, a crash trace: non-empty, no prompt open, and not the CLI's own screen.
UNRECOGNISED = "zsh: command not found: claude\nlaurens@mac ~/wt % "


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
    ("codex", CODEX_IDLE, None),
    # The banner only announces an update; the dialog is known by its own options.
    ("codex", CODEX_IDLE_WITH_UPDATE_BANNER, None),
    ("codex", CODEX_HOOKS_REVIEW, "menu"),
    # Drawn with cursor moves for spaces, or wrapped where the window is narrow.
    ("claude", "Doyouwantto\nproceed?", "permission"),
    ("codex", "Press enter to confirm\nor esc to cancel", "menu"),
])
def test_open_prompt_reads_each_harness_markers(agent, screen, expected):
    assert open_prompt(agent, screen) == expected


@pytest.mark.parametrize("agent,screen", [
    ("claude", IDLE), ("claude", CLAUDE_WORKING), ("codex", CODEX_IDLE), ("codex", CODEX_WORKING),
    ("codex", CODEX_IDLE_WITH_UPDATE_BANNER),
])
def test_an_idle_or_working_cli_screen_shows_its_input_box(agent, screen):
    assert shows_input_box(agent, screen)


@pytest.mark.parametrize("agent,screen", [
    ("claude", UNRECOGNISED), ("claude", "  \n"), ("codex", IDLE),  # Claude's ❯ is not Codex's ›
    ("claude", "text then ❯ mid-line"), ("grok", IDLE), ("pi", CODEX_IDLE), ("shell", IDLE),
    # A menu's selected option is drawn with the same arrow: a menu no marker knows yet is no input box.
    ("codex", CODEX_HOOKS_REVIEW), ("claude", CLAUDE_TRUST),
])
def test_anything_else_shows_no_input_box(agent, screen):
    assert not shows_input_box(agent, screen)


@pytest.mark.parametrize("agent", ["grok", "pi", "shell"])
def test_a_harness_without_markers_never_shows_a_prompt(agent):
    assert open_prompt(agent, CLAUDE_PERMISSION + CODEX_PERMISSION) is None


def test_the_markers_are_the_spikes():
    claude, codex = HARNESS_BY_AGENT["claude"], HARNESS_BY_AGENT["codex"]
    assert claude.permission_prompt == ("Do you want to proceed?",)
    assert claude.menu_prompt == ("Enter to select", "Esc to cancel")
    assert "Yes, I trust this folder" in claude.startup_prompt
    assert codex.permission_prompt == ("Would you like to run the following command?",)
    assert codex.menu_prompt == ("Press enter to confirm or esc to cancel", "enter confirm ·")
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
    iterm, registry, guard, clock, pauses = FakeIterm(), SessionRegistry(), TypingGuard(lambda: True), Clock(), Pauses()
    _wid, sid = await iterm.create_window("/wt", "x", {"aiterm_task": "t1"}, Frame(0, 0, 10, 10))
    await iterm.user_runs(sid, "claude", job_pid=4242)
    registry.apply_snapshot(await iterm.snapshot())
    registry.set_cli_version(sid, "2.1.301")
    guard.note_key(sid, -100, "\r")
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
    ("2.2.0", "claude 2.2.0 has not passed the delivery check"),       # a new minor since its check
    ("3.1.301", "claude 3.1.301 has not passed the delivery check"),   # a new major
    ("2.1", "claude 2.1 has not passed the delivery check"),           # not a version the rule can read
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


async def test_deliveries_to_one_session_take_turns(rig):
    first = asyncio.create_task(rig.deliverer.deliver(rig.sid, "one", 1))
    second = asyncio.create_task(rig.deliverer.deliver(rig.sid, "two", 1))
    await asyncio.gather(first, second)
    assert [text for _sid, text in rig.iterm.sent] == [pasted("one"), "\r", pasted("two"), "\r"]


@pytest.mark.parametrize("screen", [IDLE, CLAUDE_WORKING])
async def test_claudes_idle_and_working_screens_take_text(rig, screen):
    rig.iterm.screens[rig.sid] = screen
    assert (await rig.deliverer.deliver(rig.sid, "hello", 1)).result == "delivered"


@pytest.mark.parametrize("screen", [CODEX_IDLE, CODEX_WORKING])
async def test_codexs_idle_and_working_screens_take_text(rig, screen):
    rig.iterm.sessions[rig.sid].job_pid = 4343
    await rig.iterm.user_runs(rig.sid, "codex", job_pid=4343)
    rig.registry.apply_snapshot([rig.iterm.sessions[rig.sid]])
    rig.registry.set_cli_version(rig.sid, "0.160.0")
    rig.iterm.screens[rig.sid] = screen
    assert (await rig.deliverer.deliver(rig.sid, "hello", 1)).result == "delivered"


async def test_a_non_empty_screen_without_the_input_box_is_refused_and_nothing_is_typed(rig):
    rig.iterm.screens[rig.sid] = UNRECOGNISED
    assert await rig.deliverer.deliver(rig.sid, "hello", 1) == DeliveryResult("refused", "unrecognised screen")
    assert rig.iterm.sent == []


async def test_a_prompt_is_named_before_the_screen_is_called_unrecognised(rig):
    # An approval's selected option starts with the input marker too; the prompt wins.
    assert "❯" in CLAUDE_PERMISSION
    rig.iterm.screens[rig.sid] = CLAUDE_PERMISSION
    assert (await rig.deliverer.deliver(rig.sid, "hello", 1)).reason == "a permission prompt is open"


async def test_an_input_box_that_disappears_between_paste_and_enter_gets_no_enter(rig):
    rig.pauses.during.append(lambda: rig.iterm.screens.__setitem__(rig.sid, UNRECOGNISED))
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert result == DeliveryResult("partial", "before Enter, unrecognised screen; the text waits unsent in the input")
    assert rig.iterm.sent == [(rig.sid, pasted("hello"))]


WAKE = "[AiTerm] updates waiting, call run_status"


async def test_a_send_older_than_the_tasks_ownership_is_refused(rig):
    rig.deliverer.set_ownership(rig.sid, 3)
    result = await rig.deliverer.deliver(rig.sid, "hello", 2)
    assert result == DeliveryResult("refused", "the task changed hands after this message was written")
    assert rig.iterm.sent == []
    assert (await rig.deliverer.deliver(rig.sid, "hello", 3)).result == "delivered"


async def test_a_takeover_between_paste_and_enter_holds_the_enter_back(rig):
    rig.deliverer.set_ownership(rig.sid, 1)
    rig.pauses.during.append(lambda: rig.deliverer.set_ownership(rig.sid, 2))
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert result == DeliveryResult("partial", "you took the task over before Enter; the text waits unsent in the input")
    assert rig.iterm.sent == [(rig.sid, pasted("hello"))]


async def test_a_session_with_no_generation_takes_the_first_sends_and_any_newer(rig):
    assert (await rig.deliverer.deliver(rig.sid, "one", 4)).result == "delivered"
    assert (await rig.deliverer.deliver(rig.sid, "two", 3)).result == "refused"
    assert (await rig.deliverer.deliver(rig.sid, "three", 5)).result == "delivered"


async def test_a_wake_line_waits_while_you_type(rig):
    rig.guard.note_key(rig.sid, rig.clock.now - 3, "a")
    rig.guard.note_key(rig.sid, rig.clock.now - 2, "\r")  # sent: only the moment holds the line back
    assert await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True) == DeliveryResult("refused", "you are typing")
    assert rig.iterm.sent == []
    # A worker's message is not held by typing: you take a worker's task over to type in it.
    assert (await rig.deliverer.deliver(rig.sid, "hello", 1)).result == "delivered"
    rig.clock.now += delivery.TYPING_QUIET
    assert (await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)).result == "delivered"


async def test_a_wake_line_waits_while_your_words_wait_unsent(rig):
    rig.guard.note_key(rig.sid, rig.clock.now - 600, "a")  # typed long ago, never sent
    result = await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)
    assert result == DeliveryResult("refused", "unsent text waits in its input")
    assert rig.iterm.sent == []
    rig.guard.note_key(rig.sid, rig.clock.now - 60, "\x15")  # Ctrl-U: the input is empty again
    assert (await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)).result == "delivered"


async def test_typing_between_a_wake_lines_paste_and_enter_holds_the_enter_back(rig):
    rig.pauses.during.append(lambda: rig.guard.note_key(rig.sid, rig.clock.now, "a"))
    result = await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)
    assert result == DeliveryResult("partial", "you started typing before Enter; the wake line waits unsent in the input")


async def test_text_left_without_its_enter_holds_back_the_next_wake_line(rig):
    rig.pauses.during.append(lambda: rig.iterm.screens.__setitem__(rig.sid, CLAUDE_PERMISSION))
    assert (await rig.deliverer.deliver(rig.sid, "hello", 1)).result == "partial"
    rig.pauses.during.clear()
    rig.iterm.screens[rig.sid] = IDLE
    result = await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)
    assert result == DeliveryResult("refused", "unsent text waits in its input")
    rig.guard.note_key(rig.sid, rig.clock.now - delivery.TYPING_QUIET, "\r")  # you sent it, or cleared it
    assert (await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)).result == "delivered"


async def test_a_closed_session_forgets_its_generation(rig):
    rig.deliverer.set_ownership(rig.sid, 7)
    rig.deliverer.forget_session(rig.sid)
    assert (await rig.deliverer.deliver(rig.sid, "hello", 1)).result == "delivered"


async def test_a_long_message_is_left_in_a_file_and_one_fixed_line_typed(rig, tmp_path):
    text = "Step.\n" * 400  # 2400 characters, past MESSAGE_FILE_THRESHOLD
    result = await rig.deliverer.deliver(rig.sid, text, 1, worktree=str(tmp_path))
    assert result.result == "delivered"
    assert rig.iterm.sent == [(rig.sid, pasted("Read .aiterm/messages/1.md and act on it.")), (rig.sid, "\r")]
    messages = tmp_path / ".aiterm" / "messages"
    assert (messages / "1.md").read_text(encoding="utf-8") == text
    assert (messages / ".gitignore").read_text(encoding="utf-8") == "*\n", "the folder keeps itself out of git"


async def test_message_files_are_numbered_on_from_the_highest(rig, tmp_path):
    messages = tmp_path / ".aiterm" / "messages"
    messages.mkdir(parents=True)
    (messages / "7.md").write_text("earlier", encoding="utf-8")
    (messages / "notes.md").write_text("not a message", encoding="utf-8")
    await rig.deliverer.deliver(rig.sid, "x" * 2001, 1, worktree=str(tmp_path))
    assert rig.iterm.sent[0] == (rig.sid, pasted("Read .aiterm/messages/8.md and act on it."))
    assert (messages / "8.md").read_text(encoding="utf-8") == "x" * 2001
    assert (messages / "7.md").read_text(encoding="utf-8") == "earlier"


async def test_a_message_at_the_threshold_is_still_pasted(rig, tmp_path):
    text = "x" * delivery.MESSAGE_FILE_THRESHOLD
    await rig.deliverer.deliver(rig.sid, text, 1, worktree=str(tmp_path))
    assert rig.iterm.sent[0] == (rig.sid, pasted(text))
    assert not (tmp_path / ".aiterm").exists()


@pytest.mark.parametrize("worktree,reason", [
    (None, "the message is too long to paste and has no worktree to be left in"),
    ("relative/wt", "the worktree relative/wt is not a folder"),
    ("/nowhere/at/all", "the worktree /nowhere/at/all is not a folder"),
])
async def test_a_long_message_with_nowhere_to_go_is_refused(rig, worktree, reason):
    assert await rig.deliverer.deliver(rig.sid, "x" * 2001, 1, worktree=worktree) == DeliveryResult("refused", reason)
    assert rig.iterm.sent == []


def test_two_writers_never_take_the_same_number(tmp_path):
    lines = {delivery.write_message_file(str(tmp_path), f"message {i}") for i in range(5)}
    assert lines == {f"Read .aiterm/messages/{n}.md and act on it." for n in range(1, 6)}


def _another_process(rig):
    tab = rig.iterm.sessions[rig.sid]
    tab.job_pid = 4343
    rig.registry.apply_snapshot([tab])


@pytest.mark.parametrize("change,reason", [
    (lambda rig: rig.deliverer.set_ownership(rig.sid, 2), "the task changed hands after this message was written"),
    (lambda rig: rig.iterm.screens.__setitem__(rig.sid, CLAUDE_PERMISSION), "a permission prompt is open"),
    (lambda rig: rig.registry.apply_snapshot([]), "the session has closed"),
    (_another_process, "another process now runs in the session"),
    (lambda rig: rig.policy.__setitem__("claude", ("auto", "2.0.301")), "claude 2.1.301 has not passed the delivery check"),
])
async def test_what_changed_while_the_message_file_was_written_is_checked_again_before_the_paste(
        rig, tmp_path, monkeypatch, change, reason):
    write = delivery.write_message_file

    def write_then_change(worktree, text):
        line = write(worktree, text)
        change(rig)
        return line

    monkeypatch.setattr(delivery, "write_message_file", write_then_change)
    result = await rig.deliverer.deliver(rig.sid, "x" * 2001, 1, worktree=str(tmp_path))
    assert result == DeliveryResult("refused", reason)
    assert rig.iterm.sent == []


async def test_a_verdict_that_became_paste_only_while_the_file_was_written_keeps_the_enter_back(rig, tmp_path, monkeypatch):
    write = delivery.write_message_file

    def write_then_downgrade(worktree, text):
        line = write(worktree, text)
        rig.policy["claude"] = ("pasteOnly", "2.1.301")
        return line

    monkeypatch.setattr(delivery, "write_message_file", write_then_downgrade)
    result = await rig.deliverer.deliver(rig.sid, "x" * 2001, 1, worktree=str(tmp_path))
    assert result.result == "partial"
    assert rig.iterm.sent == [(rig.sid, pasted("Read .aiterm/messages/1.md and act on it."))]


async def _now_codex(rig):
    await rig.iterm.user_runs(rig.sid, "codex", job_pid=5151)
    rig.registry.apply_snapshot(await rig.iterm.snapshot())


async def test_codexs_update_offer_is_declined_with_esc(rig):
    await _now_codex(rig)
    rig.iterm.screens[rig.sid] = CODEX_UPDATE
    assert await rig.deliverer.dismiss_startup(rig.sid) is True
    assert rig.iterm.sent == [(rig.sid, "\x1b")]


@pytest.mark.parametrize("agent,screen", [
    ("codex", CODEX_TRUST),                    # trusting a folder is yours to answer
    ("codex", CODEX_IDLE_WITH_UPDATE_BANNER),  # the banner is no dialog
    ("codex", CODEX_PERMISSION),
    ("codex", IDLE),
    ("claude", CLAUDE_TRUST),
    ("claude", CODEX_UPDATE),                  # Claude has no update offer of its own to decline
])
async def test_any_other_screen_is_left_as_it_is(rig, agent, screen):
    if agent == "codex":
        await _now_codex(rig)
    rig.iterm.screens[rig.sid] = screen
    assert await rig.deliverer.dismiss_startup(rig.sid) is False
    assert rig.iterm.sent == []


async def test_dismissing_needs_an_open_session(rig):
    with pytest.raises(KeyError):
        await rig.deliverer.dismiss_startup("s404")


def test_the_update_offer_is_known_by_every_one_of_its_markers():
    assert HARNESS_BY_AGENT["codex"].update_prompt == ("Update now", "Skip until next version")
    assert HARNESS_BY_AGENT["claude"].update_prompt == ()
    assert delivery.shows_update_offer("codex", CODEX_UPDATE)
    assert not delivery.shows_update_offer("codex", CODEX_UPDATE.replace("Skip until next version", "Not now"))


async def test_a_generation_is_never_lowered(rig):
    rig.deliverer.set_ownership(rig.sid, 5)
    rig.deliverer.set_ownership(rig.sid, 2)
    assert (await rig.deliverer.deliver(rig.sid, "hello", 4)).result == "refused"
    assert (await rig.deliverer.deliver(rig.sid, "hello", 5)).result == "delivered"


@pytest.mark.parametrize("read_number", [1, 2])
@pytest.mark.parametrize("change", ["ownership", "typing", "dirty", "closed", "prompt"])
async def test_screen_read_rechecks_safety_after_await(rig, read_number, change):
    entered, release = asyncio.Event(), asyncio.Event()
    original = rig.iterm.screen_text
    reads = 0

    async def held(sid):
        nonlocal reads
        reads += 1
        if reads == read_number:
            entered.set()
            await release.wait()
        return await original(sid)

    rig.iterm.screen_text = held
    task = asyncio.create_task(rig.deliverer.deliver(rig.sid, "wake", 1, wake=True))
    await entered.wait()
    if change == "ownership":
        rig.deliverer.set_ownership(rig.sid, 2)
    elif change == "typing":
        rig.guard.note_key(rig.sid, rig.clock(), "\x1b")
    elif change == "dirty":
        rig.guard.mark_unsent(rig.sid)
    elif change == "closed":
        rig.registry.apply_snapshot([])
    else:
        rig.iterm.screens[rig.sid] = CLAUDE_PERMISSION
    release.set()
    result = await task
    assert result.result == ("refused" if read_number == 1 else "partial")
    assert len(rig.iterm.sent) == read_number - 1


async def test_wake_refused_without_observed_input_history(rig):
    rig.guard.forget(rig.sid)
    result = await rig.deliverer.deliver(rig.sid, "wake", 1, wake=True)
    assert result.result == "refused"
    assert rig.iterm.sent == []


# -- a verdict holds across patch releases ------------------------------------------------------

@pytest.mark.parametrize("checked,installed,covered", [
    ("2.1.301", "2.1.301", True),     # the very version checked
    ("2.1.301", "2.1.305", True),     # a later patch
    ("2.1.301", "2.1.300", True),     # an earlier patch
    ("2.1.301", "2.2.0", False),      # a new minor
    ("2.1.301", "3.1.301", False),    # a new major
    ("0.160.0", "0.160.4", True),
    ("0.160.0", "0.16.0", False),     # compared as numbers, not text
    ("2.1.301", None, False),         # a version its files have not named yet
    ("2.1.301", "", False),
    ("2.1.301", "2.1", False),        # versions the rule cannot read
    ("2.1.301", "2.1.301-beta", False),
    ("2.1.301", "v2.1.301", False),
    (None, "2.1.301", False),
    ("garbage", "garbage", False),
])
def test_a_verdict_covers_the_patch_releases_of_its_version(checked, installed, covered):
    assert delivery.verdict_covers(checked, installed) is covered


@pytest.mark.parametrize("running", ["2.1.301", "2.1.309", "2.1.2"])
async def test_a_patch_release_of_the_checked_version_takes_text(rig, running):
    rig.registry.get(rig.sid).cli_version = running
    assert (await rig.deliverer.deliver(rig.sid, "hello", 1)).result == "delivered"


# -- the operator's wake line --------------------------------------------------------------------

async def test_a_wake_line_needs_no_pass_from_the_delivery_check(rig):
    rig.policy.clear()  # as with no policy file at all
    assert await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True) == DeliveryResult("delivered", None)
    assert rig.iterm.sent == [(rig.sid, pasted(WAKE)), (rig.sid, "\r")]


@pytest.mark.parametrize("running", ["2.9.0", None])
async def test_a_wake_line_goes_to_any_version_the_check_did_not_pass(rig, running):
    rig.registry.get(rig.sid).cli_version = running
    assert (await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)).result == "delivered"


async def test_a_workers_message_still_needs_the_pass(rig):
    rig.policy.clear()
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert (result.result, result.code) == ("refused", "notChecked")
    assert rig.iterm.sent == []


@pytest.mark.parametrize("screen,code", [
    (CLAUDE_PERMISSION, "prompt"), (CLAUDE_TRUST, "prompt"), (CLAUDE_MENU, "prompt"),
    (UNRECOGNISED, "unrecognisedScreen"), ("  \n", "screenUnread"),
])
async def test_a_wake_line_is_refused_on_a_prompt_or_without_the_input_box(rig, screen, code):
    rig.policy.clear()
    rig.iterm.screens[rig.sid] = screen
    result = await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)
    assert (result.result, result.code) == ("refused", code)
    assert rig.iterm.sent == []


async def test_a_wake_line_is_refused_while_you_type_without_a_pass(rig):
    rig.policy.clear()
    rig.guard.note_key(rig.sid, rig.clock.now - 1, "a")
    result = await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)
    assert (result.result, result.reason, result.code) == ("refused", "you are typing", "typing")


async def test_a_prompt_that_opens_before_a_wake_lines_enter_gets_no_enter(rig):
    rig.policy.clear()
    rig.pauses.during.append(lambda: rig.iterm.screens.__setitem__(rig.sid, CLAUDE_PERMISSION))
    result = await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)
    assert (result.result, result.code) == ("partial", "prompt")
    assert rig.iterm.sent == [(rig.sid, pasted(WAKE))]


async def test_a_wake_line_is_refused_without_iterm2_or_its_session(rig):
    rig.policy.clear()
    assert (await rig.deliverer.deliver("s404", WAKE, 1, wake=True)).code == "sessionClosed"
    await rig.iterm.disconnect()
    assert (await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)).code == "itermDisconnected"


async def test_a_wake_line_is_held_to_ownership(rig):
    rig.deliverer.set_ownership(rig.sid, 3)
    assert (await rig.deliverer.deliver(rig.sid, WAKE, 2, wake=True)).code == "ownership"


async def test_a_wake_line_to_a_cli_whose_prompts_cannot_be_read_is_refused(rig):
    await rig.iterm.user_runs(rig.sid, "pi", job_pid=6161)
    rig.registry.apply_snapshot(await rig.iterm.snapshot())
    rig.iterm.screens[rig.sid] = IDLE
    result = await rig.deliverer.deliver(rig.sid, WAKE, 1, wake=True)
    assert (result.result, result.code) == ("refused", "unsupported")
    assert rig.iterm.sent == []


@pytest.mark.parametrize("text,reason", [
    ("[AiTerm] 2 updates, call run_status", "a wake line may not carry a digit"),
    ("[AiTerm] review feedback on PAY-12: call run_status", "a wake line may not carry a digit"),
    ("[AiTerm] y", "a wake line may not carry a one-letter word"),
    ("[AiTerm] a task merged: call run_status", "a wake line may not carry a one-letter word"),
    ("[AiTerm] “a” waits", "a wake line may not carry a one-letter word"),
])
async def test_a_wake_line_that_a_prompt_could_read_as_an_answer_is_refused(rig, text, reason):
    result = await rig.deliverer.deliver(rig.sid, text, 1, wake=True)
    assert (result.result, result.reason, result.code) == ("refused", reason, "wakeText")
    assert rig.iterm.sent == []


@pytest.mark.parametrize("text", [
    WAKE, "[AiTerm] reconnected, call run_status", "[AiTerm] Codex’s review failed: call run_status",
    "[AiTerm] broadcast complete, call run_status",
])
def test_plain_wake_lines_pass(text):
    assert delivery.wake_text_problem(text) is None


async def test_a_wake_line_never_goes_through_a_message_file(rig, tmp_path):
    result = await rig.deliverer.deliver(rig.sid, "wake " * 500, 1, wake=True, worktree=str(tmp_path))
    assert (result.result, result.reason, result.code) == ("refused", "a wake line is too long to paste", "wakeText")
    assert rig.iterm.sent == [] and not (tmp_path / ".aiterm").exists()


# -- why, in one word ----------------------------------------------------------------------------

@pytest.mark.parametrize("setup,code", [
    (lambda rig: rig.policy.clear(), "notChecked"),
    (lambda rig: setattr(rig.registry.get(rig.sid), "cli_version", "2.2.0"), "notChecked"),
    (lambda rig: rig.iterm.screens.__setitem__(rig.sid, CLAUDE_PERMISSION), "prompt"),
    (lambda rig: rig.iterm.screens.__setitem__(rig.sid, UNRECOGNISED), "unrecognisedScreen"),
    (lambda rig: setattr(rig.iterm, "screen_error", ItermUnavailable("no answer")), "screenUnread"),
    (lambda rig: setattr(rig.iterm, "send_error", ItermUnavailable("closed")), "itermRefused"),
    (lambda rig: rig.registry.apply_snapshot([]), "sessionClosed"),
    (lambda rig: rig.deliverer.set_ownership(rig.sid, 9), "ownership"),
])
async def test_each_refusal_names_its_reason_in_one_word(rig, setup, code):
    setup(rig)
    assert (await rig.deliverer.deliver(rig.sid, "hello", 1)).code == code


@pytest.mark.parametrize("change,code", [
    (_another_process, "replaced"),
    (lambda rig: rig.deliverer.set_ownership(rig.sid, 2), "ownership"),
    (lambda rig: rig.iterm.screens.__setitem__(rig.sid, UNRECOGNISED), "unrecognisedScreen"),
])
async def test_an_enter_held_back_keeps_the_code_of_what_changed(rig, change, code):
    rig.deliverer.set_ownership(rig.sid, 1)
    rig.pauses.during.append(lambda: change(rig))
    result = await rig.deliverer.deliver(rig.sid, "hello", 1)
    assert (result.result, result.code) == ("partial", code)


def test_the_reply_carries_the_code():
    assert DeliveryResult("refused", "you are typing", "typing").to_json() == {
        "result": "refused", "reason": "you are typing", "code": "typing"}
    assert DeliveryResult("delivered").to_json() == {"result": "delivered", "reason": None, "code": None}
