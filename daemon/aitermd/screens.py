"""Pure recognition of terminal screens and typed cells."""
from __future__ import annotations

import re
from collections.abc import Iterable
from typing import Literal, Protocol, TypedDict

from .models import HARNESS_BY_AGENT, AgentKind, Harness, SessionInfo
from .text import shows


class _Cell(Protocol):
    """What `typed_line` reads of iterm2's CellStyle."""
    @property
    def faint(self) -> bool: ...
    @property
    def inverse(self) -> bool: ...


class _Line(Protocol):
    """What `typed_line` reads of iterm2's LineContents."""
    def string_at(self, x: int) -> str: ...
    def style_at(self, x: int) -> _Cell | None: ...


def typed_line(line: _Line) -> str:
    """`line` as typed text, cell for cell, its ghost text blanked to spaces. Ghost text is drawn, not typed: a
    faint cell (SGR 2: Claude Code draws its empty input's placeholder and its prompt suggestion faint), and an inverse
    cell right before a faint one (its own cursor drawn on a placeholder's first character)."""
    cells: list[tuple[str, _Cell | None]] = []
    while True:
        try:
            cells.append((line.string_at(len(cells)), line.style_at(len(cells))))
        except IndexError:
            break

    def faint(x: int) -> bool:
        return x < len(cells) and (style := cells[x][1]) is not None and style.faint

    def ghost(x: int) -> bool:
        style = cells[x][1]
        return faint(x) or (style is not None and style.inverse and faint(x + 1))

    return "".join(" " * len(text) if ghost(x) else text for x, (text, _style) in enumerate(cells))


def screen_string(lines: Iterable[str]) -> str:
    """A screen's lines as one text, each cell a program skipped with a cursor move -- which iTerm2
    hands back as NUL -- read as the space it shows. Unread, the NULs split the words every prompt
    marker is matched by, and Claude Code draws its dialogs that way."""
    return "\n".join(lines).replace("\x00", " ")


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


def input_text(agent: AgentKind, screen: str, typed: str) -> str | None:
    """What the CLI's input holds as one screen read shows it: `screen` its text, `typed` the same lines with their
    ghost text blanked (iterm_bridge.typed_line), since Claude Code draws its empty input's placeholder and its prompt
    suggestion as faint text that reads as typed. "" for an input with nothing typed; None for a screen with no input
    to read: no ruled input frame -- a prompt, the transcript view, a blank or unrecognised screen -- or a harness
    without one (only Claude draws it). The frame is found in `screen`, whose rules no style blanks."""
    harness = HARNESS_BY_AGENT.get(agent)
    lines, typed_lines = screen.splitlines(), typed.splitlines()
    if harness is None or not harness.numbered_menus or len(lines) != len(typed_lines) or _shows_transcript(harness, screen):
        return None
    framed = [index for index, _ in _arrow_lines(harness, screen) if _in_input_frame(harness, lines, index)]
    if not framed:
        return None
    start = framed[-1]
    end = next(index for index in range(start + 1, len(lines)) if _RULE.fullmatch(lines[index].strip()))
    arrow = len(lines[start]) - len(lines[start].lstrip()) + 1
    return "\n".join([typed_lines[start][arrow:], *typed_lines[start + 1:end]]).strip()


def _below_input(harness: Harness, screen: str) -> str:
    """Markers above the last input arrow belong to the transcript, not an unannounced dialog."""
    lines = screen.splitlines()
    for index, text in reversed(_arrow_lines(harness, screen)):
        if not _OPTION.match(text) or _in_input_frame(harness, lines, index):
            return "\n".join(lines[index:])
    return screen


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


def shows_trust_prompt(agent: AgentKind, screen: str) -> bool:
    """Whether `screen` shows the agent's folder-trust dialog. Compared without whitespace: a line
    can come back with its spaces drawn as cursor moves, or wrapped where the window is narrow."""
    if (harness := HARNESS_BY_AGENT.get(agent)) is None:
        return False
    return shows(screen, harness.trust_prompt)
