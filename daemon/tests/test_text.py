import pytest

from aitermd.text import iso_seconds


@pytest.mark.parametrize(("value", "seconds"), [
    ("2026-10-26T08:21:16.304Z", 1_793_002_876.304),
    ("2026-10-26T09:21:16.304+01:00", 1_793_002_876.304),
    # Claude Code and Codex both write UTC: one that lost its zone is still UTC, not the wall clock's.
    ("2026-10-26T08:21:16.304", 1_793_002_876.304),
    ("yesterday", None), (1_792_052_476, None), (None, None),
])
def test_an_iso_timestamp_is_read_in_epoch_seconds(away_from_utc, value, seconds):
    assert iso_seconds(value) == (pytest.approx(seconds) if seconds else None)
