"""Small text checks shared by hook payloads, rollout records and terminal screens."""
from typing import Any


def nonempty_string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def shows(screen: str, phrases: tuple[str, ...]) -> bool:
    """Ignore whitespace: terminals wrap lines and can draw spaces as cursor moves."""
    text = "".join(screen.split())
    return any("".join(phrase.split()) in text for phrase in phrases)
