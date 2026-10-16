"""Typing into an agent's session the one way the spike found safe (Operators spec §7.1), and
reading off its screen whether a prompt is open that typed text could answer."""
from __future__ import annotations

from typing import Literal

from .models import HARNESS_BY_AGENT, AgentKind

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
