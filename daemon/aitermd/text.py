"""Small text checks shared by hook payloads, rollout records and terminal screens."""
from datetime import UTC, datetime
from typing import Any


def nonempty_string(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def shows(screen: str, phrases: tuple[str, ...]) -> bool:
    """Ignore whitespace: terminals wrap lines and can draw spaces as cursor moves."""
    text = "".join(screen.split())
    return any("".join(phrase.split()) in text for phrase in phrases)


def iso_seconds(value: Any) -> float | None:
    """An ISO 8601 timestamp (`2026-10-26T08:21:16.304Z`) in epoch seconds; None when it is not one. Claude Code and Codex
    both write UTC, so one without a zone is UTC too, never the wall clock's zone."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
        return (parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)).timestamp()
    except ValueError:
        return None
