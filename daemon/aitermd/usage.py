from __future__ import annotations
import math
from dataclasses import dataclass, replace
from typing import Any

from .models import USAGE_VENDORS, Usage, UsageWindow

# How far `updatedAt` may advance before an otherwise unchanged `Usage` is news again. The
# footer greys a number whose age passes a threshold, so its idea of the age has to keep up
# with the daemon's -- but not at the rate a status line ticks.
HEARTBEAT_SECONDS = 60


@dataclass(frozen=True)
class UsageReadFailure:
    message: str
    at: int


class UsageStore:
    def __init__(self) -> None:
        # Every vendor is in the snapshot, a None until it first reports.
        self._usage: dict[str, Usage | None] = dict.fromkeys(USAGE_VENDORS)
        # What the clients were last told, per vendor: the reference for "is this news?", which
        # the latest stored value cannot be once a quiet minute has been absorbed into it.
        self._announced: dict[str, Usage] = {}
        self._failures: dict[str, UsageReadFailure] = {}

    def set(self, vendor: str, usage: Usage) -> bool:
        """Stores `usage` and says whether clients should hear about it: new content, or the same
        content a heartbeat older than the last announcement."""
        # Feed gaps are not measurements. A newly touched older rollout can also be returned when
        # a newer file is unavailable; neither should erase or rejuvenate the last known account data.
        previous = self._usage.get(vendor)
        if not (usage.five_hour or usage.seven_day or usage.spend) or (
                previous is not None and usage.updated_at < previous.updated_at):
            return False
        failure = self._failures.pop(vendor, None)
        told = self._announced.get(vendor)
        changed = (failure is not None or told is None or replace(told, updated_at=usage.updated_at) != usage
                   or usage.updated_at - told.updated_at >= HEARTBEAT_SECONDS)
        self._usage[vendor] = usage
        if changed:
            self._announced[vendor] = usage
        return changed

    def failed(self, vendor: str, message: str, at: int) -> bool:
        if self._failures.get(vendor) is not None and self._failures[vendor].message == message:
            return False
        self._failures[vendor] = UsageReadFailure(message, at)
        return True

    def snapshot(self) -> dict[str, Any]:
        result: dict[str, Any] = {v: (u.to_json() if u else None) for v, u in self._usage.items()}
        for vendor, failure in self._failures.items():
            reading = result[vendor] or Usage(None, None, None, 0).to_json()
            result[vendor] = reading | {"retrievalFailure": {"message": failure.message, "at": failure.at}}
        return result


def finite_number(value: Any) -> float | None:
    """A number from another process's JSON. json.loads accepts Infinity and NaN, and `int()` or
    `round()` raise on both -- and on an int too large for a float -- so those are no number at
    all; bool is excluded by name, being an int to Python."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except OverflowError:
        return None
    return number if math.isfinite(number) else None


def clamped_percent(value: Any) -> int | None:
    """A percentage from another process's arithmetic, rounded and held to 0-100 for a ring that
    cannot render 140%; None when it is no finite number."""
    number = finite_number(value)
    return max(0, min(100, round(number))) if number is not None else None


def usage_window(d: Any, percent_key: str) -> UsageWindow | None:
    """One rate-limit window, as Claude's and Codex's parsers both read it: a used percentage (a float,
    under `percent_key`) and `resets_at` (epoch seconds). Anything that is not a number is not a window."""
    if not isinstance(d, dict) or (used := finite_number(d.get(percent_key))) is None:
        return None
    resets = finite_number(d.get("resets_at"))
    return UsageWindow(round(used), int(resets) if resets is not None else None)
