"""The keys you type in each session, which an operator's wake line waits on (Operators spec §7.4)."""
from __future__ import annotations

from collections.abc import Callable

from .delivery import TYPING_QUIET

# The keys that leave a CLI's input empty: Return, which submits it -- held with a modifier it types
# a newline instead -- and Ctrl-C and Ctrl-U, which clear it. The keypad's Enter arrives as Ctrl-C's
# character, and submits too.
_SUBMIT = "\r"
_EMPTIES = ("\x03", "\x15")
_NEWLINE_MODIFIERS = frozenset({"shift", "option", "control", "command"})
# Esc interrupts a turn or closes a menu, and a modifier key alone has no characters: neither types.
_TYPES_NOTHING = ("", "\x1b")


class TypingGuard:
    """When a key was last pressed in each session, and whether its input may hold text not yet
    sent, from iTerm2's keystroke monitor (ItermPort.on_keystroke). Of a key only that is kept, never
    the key itself: the monitor sees every session's keys, passwords among them.

    A session typed in within TYPING_QUIET is one you are typing in, where a wake line would land in
    the middle of your words. One whose input may hold unsent text is one where a wake line would be
    submitted together with it, however long ago you typed. Any key but Esc may have put text there
    -- a letter, Tab taking a suggestion, an arrow recalling history, ⌘V -- until Return, Ctrl-C or
    Ctrl-U empties it; Delete may have emptied it, which cannot be told, so it counts as text.
    Unknown input history refuses wake lines until an observed key empties the input."""

    def __init__(self, monitoring: Callable[[], object | None] = lambda: None) -> None:
        self._monitoring = monitoring
        self._epoch: object | None = None
        self._known: set[str] = set()
        self._last: dict[str, float] = {}
        self._unsent: set[str] = set()

    def note_key(self, session_id: str, at: float, characters: str, modifiers: frozenset[str] = frozenset()) -> None:
        self._sync_monitor()
        self._last[session_id] = at
        if characters in _TYPES_NOTHING:
            return
        if characters in _EMPTIES or (characters == _SUBMIT and not modifiers & _NEWLINE_MODIFIERS):
            if self._epoch is not None:
                self._known.add(session_id)
            self._unsent.discard(session_id)
        else:
            self._unsent.add(session_id)

    def mark_unsent(self, session_id: str) -> None:
        """Text left in the session's input without its Enter: a paste whose Enter was held back."""
        self._unsent.add(session_id)

    def is_typing(self, session_id: str, now: float) -> bool:
        last = self._last.get(session_id)
        return last is not None and now - last < TYPING_QUIET

    def has_unsent_input(self, session_id: str) -> bool:
        self._sync_monitor()
        return self._epoch is None or session_id not in self._known or session_id in self._unsent

    def _sync_monitor(self) -> None:
        epoch = self._monitoring()
        if epoch is not self._epoch:
            self._known.clear()
            self._epoch = epoch

    def forget(self, session_id: str) -> None:
        """A closed session's last key and input."""
        self._known.discard(session_id)
        self._last.pop(session_id, None)
        self._unsent.discard(session_id)
