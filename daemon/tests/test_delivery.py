# daemon/tests/test_delivery.py
"""The delivery adapter (Operators spec §7.1): what it reads off a screen, the policy it obeys, and
how it types."""
from __future__ import annotations

import pytest

from aitermd import delivery
from aitermd.delivery import open_prompt
from aitermd.models import HARNESS_BY_AGENT

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
