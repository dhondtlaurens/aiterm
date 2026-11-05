# daemon/tests/test_keystrokes.py
import pytest

from aitermd.keystrokes import TypingGuard

UP_ARROW = ""  # what macOS reports for the arrow keys: a private-use character


def test_a_key_within_the_quiet_window_is_typing_and_after_it_is_not():
    guard = TypingGuard(lambda: True)
    guard.note_key("s1", -100, "\r")
    guard.note_key("s2", -100, "\r")
    assert not guard.is_typing("s1", 100.0)
    guard.note_key("s1", 100.0, "a")
    assert guard.is_typing("s1", 109.9)
    assert not guard.is_typing("s1", 110.0)
    assert not guard.is_typing("s2", 101.0), "a key counts only in its own session"


@pytest.mark.parametrize("keys", [
    ["a"], ["a", "\r", "b"], ["\t"], [UP_ARROW], ["\x7f"], [("\r", {"shift"})], [("\r", {"option"})],
    [("v", {"command"})], ["a", "\x1b"],
])
def test_a_key_that_may_have_put_text_in_the_input_leaves_it_unsent(keys):
    guard = TypingGuard(lambda: True)
    guard.note_key("s1", -100, "\r")
    guard.note_key("s2", -100, "\r")
    for key in keys:
        characters, modifiers = key if isinstance(key, tuple) else (key, set())
        guard.note_key("s1", 100.0, characters, frozenset(modifiers))
    assert guard.has_unsent_input("s1")
    assert not guard.has_unsent_input("s2")


@pytest.mark.parametrize("keys", [
    ["a", "\r"], ["a", "\x03"], [("a", set()), ("\x03", {"control"})], ["a", "\x15"], ["\x1b"], [""], ["a", "\x1b", "\r"],
])
def test_return_ctrl_c_and_ctrl_u_empty_the_input_and_esc_types_nothing(keys):
    guard = TypingGuard(lambda: True)
    guard.note_key("s1", -100, "\r")
    guard.note_key("s2", -100, "\r")
    for key in keys:
        characters, modifiers = key if isinstance(key, tuple) else (key, set())
        guard.note_key("s1", 100.0, characters, frozenset(modifiers))
    assert not guard.has_unsent_input("s1")


def test_a_paste_left_without_its_enter_is_unsent_until_you_send_it():
    guard = TypingGuard(lambda: True)
    guard.note_key("s1", -100, "\r")
    guard.note_key("s2", -100, "\r")
    guard.mark_unsent("s1")
    assert guard.has_unsent_input("s1") and not guard.is_typing("s1", 100.0)
    guard.note_key("s1", 100.0, "\r")
    assert not guard.has_unsent_input("s1")


def test_a_closed_session_is_forgotten():
    guard = TypingGuard(lambda: True)
    guard.note_key("s1", -100, "\r")
    guard.note_key("s2", -100, "\r")
    guard.note_key("s1", 100.0, "a")
    guard.forget("s1")
    guard.forget("s404")
    assert not guard.is_typing("s1", 100.5) and guard.has_unsent_input("s1")


def test_unknown_history_and_lost_monitor_refuse_wakes():
    epoch = [None]
    guard = TypingGuard(lambda: epoch[0])
    assert guard.has_unsent_input("s1")
    epoch[0] = object()
    assert guard.has_unsent_input("s1")
    guard.note_key("s1", 0, "\r")
    assert not guard.has_unsent_input("s1")
    epoch[0] = None
    assert guard.has_unsent_input("s1")
    epoch[0] = object()
    assert guard.has_unsent_input("s1")


def test_unobserved_input_is_not_assumed_empty():
    assert TypingGuard().has_unsent_input("s1")


def test_an_input_the_screen_shows_empty_is_known_empty_until_the_next_key():
    guard = TypingGuard(lambda: True)
    guard.note_key("s1", 10, "\x0f")  # ⌃O, which types nothing in Claude Code but cannot be told from text
    assert guard.has_unsent_input("s1")
    guard.note_empty("s1", read_at=20)
    assert not guard.has_unsent_input("s1")
    guard.note_key("s1", 30, "a")
    assert guard.has_unsent_input("s1")
    # Unknown history, the daemon's first look at a session, is settled by the screen too.
    guard.note_empty("s2", read_at=0)
    assert not guard.has_unsent_input("s2")


def test_a_key_after_the_screen_was_read_keeps_the_input_unknown():
    guard = TypingGuard(lambda: True)
    guard.note_key("s1", 25, "a")  # pressed while the screen read was out
    guard.note_empty("s1", read_at=20)
    assert guard.has_unsent_input("s1")


def test_without_a_keystroke_monitor_nothing_is_watched_and_no_screen_settles_the_input():
    epoch = [None]
    guard = TypingGuard(lambda: epoch[0])
    assert not guard.watching()
    guard.note_empty("s1", read_at=0)
    assert guard.has_unsent_input("s1")
    epoch[0] = object()
    assert guard.watching()
