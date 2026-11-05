"""Screens captured from a CLI with their cell styles (`fixtures/screens/*.json`), as iTerm2's API hands
them over: lines whose cells have a text and a style, faint (SGR 2) or inverse (SGR 7)."""
from __future__ import annotations

import json
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

SCREENS = Path(__file__).parent / "fixtures" / "screens"


@dataclass(frozen=True)
class CellStyle:
    faint: bool = False
    inverse: bool = False


class Line:
    """Stands in for iterm2's LineContents: `string`, and per cell `string_at` and `style_at`. One code point
    is one cell, as on the captured screens, which hold no wide or combined characters."""

    def __init__(self, text: str, faint: Sequence[Sequence[int]] = (), inverse: Sequence[Sequence[int]] = ()):
        self.string = text
        self._styles = [CellStyle(any(a <= x < b for a, b in faint), any(a <= x < b for a, b in inverse)) for x in range(len(text))]

    def string_at(self, x: int) -> str:
        if x >= len(self.string):
            raise IndexError(x)
        return self.string[x]

    def style_at(self, x: int) -> CellStyle | None:
        return self._styles[x] if 0 <= x < len(self._styles) else None


def lines(name: str) -> list[Line]:
    """The captured screen `name`'s lines."""
    captured = json.loads((SCREENS / f"{name}.json").read_text(encoding="utf-8"))
    return [Line(line["text"], line["faint"], line["inverse"]) for line in captured["lines"]]


def text(screen: list[Line]) -> str:
    """The screen as `screen_text` reads it."""
    return "\n".join(line.string for line in screen)


# Claude Code 2.1.318 idle, its empty input showing its dim placeholder.
CLAUDE_IDLE = "claude-2.1.318-idle"
