import json
import os
from datetime import datetime
from types import SimpleNamespace

import pytest

from aitermd import jsonl
from aitermd.codex_sessions import LIST_SECONDS, CodexSessionFiles


def write_rollout(root, session_id, records, day="2026/09/22"):
    path = root / day / f"rollout-2026-09-22T09-26-25-{session_id}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(record) if isinstance(record, dict) else record for record in records) + "\n")
    return path


def token_count(total_tokens, context_window):
    return {
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": {"total_tokens": total_tokens},
                "model_context_window": context_window,
            },
        },
    }


def meta(thread_id):
    return {"type": "session_meta", "payload": {"id": thread_id, "session_id": thread_id}}


def test_reads_latest_valid_context_for_the_exact_codex_session(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "other-thread", [token_count(99, 100)])
    write_rollout(root, "thread-1", [
        token_count(10, 100),
        token_count(42_600, 100_000),
        "{unfinished",
    ])

    assert CodexSessionFiles(root).context_percent("thread-1") == 43


def test_rejects_unusable_codex_context_numbers_and_clamps_overflow(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "zero-window", [token_count(42, 0)])
    write_rollout(root, "boolean", [token_count(True, 100)])
    write_rollout(root, "overflow", [token_count(140, 100)])

    files = CodexSessionFiles(root)
    assert files.context_percent("missing") is None
    assert files.context_percent("zero-window") is None
    assert files.context_percent("boolean") is None
    assert files.context_percent("overflow") == 100


def rate_limited(primary, secondary=None, plan="team", timestamp="2026-09-22T14:31:09.229Z"):
    """A `token_count` record the way Codex writes it: the rate limits ride along with the tokens."""
    record = token_count(100, 1000)
    record["timestamp"] = timestamp
    record["payload"]["rate_limits"] = {"limit_id": "codex", "primary": primary, "secondary": secondary, "plan_type": plan}
    return record


def test_rate_limits_come_from_the_newest_record_of_the_newest_rollout(tmp_path):
    # Account-wide, so whichever session wrote last is the truth -- not the one AiTerm happens to
    # track. The record's own timestamp is the age of the number, not when we read it.
    root = tmp_path / "sessions"
    older = write_rollout(root, "older", [rate_limited({"used_percent": 10.0, "window_minutes": 10080, "resets_at": 1},
                                                       timestamp="2026-09-22T10:00:00.000Z")])
    newer = write_rollout(root, "newer", [
        rate_limited({"used_percent": 20.0, "window_minutes": 10080, "resets_at": 2}, timestamp="2026-09-22T12:00:00.000Z"),
        token_count(5, 1000),  # a later token_count without rate limits does not erase them
        rate_limited({"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1790582049}, timestamp="2026-09-22T14:31:09.229Z"),
        "{unfinished",
    ])
    os.utime(older, ns=(1, 1))
    os.utime(newer, ns=(2, 2))

    limits, at = CodexSessionFiles(root).rate_limits()
    assert limits["primary"] == {"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1790582049}
    assert limits["plan_type"] == "team"
    assert at == 1790087469  # 2026-09-22T14:31:09Z


def test_rate_limits_are_none_without_a_usable_record(tmp_path):
    root = tmp_path / "sessions"
    assert CodexSessionFiles(root).rate_limits() is None  # no sessions dir at all
    write_rollout(root, "tokens-only", [token_count(1, 10)])
    write_rollout(root, "not-a-dict", [{"type": "event_msg", "timestamp": "2026-09-22T14:31:09Z",
                                        "payload": {"type": "token_count", "rate_limits": ["nope"]}}])
    assert CodexSessionFiles(root).rate_limits() is None


def test_rate_limits_whose_time_has_no_zone_age_from_utc(tmp_path, away_from_utc):
    root = tmp_path / "sessions"
    write_rollout(root, "t", [rate_limited({"used_percent": 3.0, "window_minutes": 300, "resets_at": None},
                                           timestamp="2026-09-22T14:31:09.229")])
    assert CodexSessionFiles(root).rate_limits()[1] == 1790087469


def test_rate_limits_without_a_timestamp_still_count_and_age_as_unknown(tmp_path):
    root = tmp_path / "sessions"
    record = rate_limited({"used_percent": 3.0, "window_minutes": 300, "resets_at": None})
    del record["timestamp"]
    write_rollout(root, "t", [record])
    limits, at = CodexSessionFiles(root).rate_limits()
    assert limits["primary"]["used_percent"] == 3.0 and at is None


def test_rate_limits_are_not_reread_until_a_rollout_changes(tmp_path, monkeypatch):
    # The tick asks every two seconds; a rollout nobody has written to is not read again.
    root = tmp_path / "sessions"
    path = write_rollout(root, "t", [rate_limited({"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1})])
    files = CodexSessionFiles(root)
    reads = []
    real = jsonl._lines_reverse
    monkeypatch.setattr(jsonl, "_lines_reverse", lambda p, *a: reads.append(p) or real(p, *a))

    first = files.rate_limits()
    assert files.rate_limits() == first and reads == [path]

    with path.open("a") as stream:
        stream.write(json.dumps(rate_limited({"used_percent": 53.0, "window_minutes": 10080, "resets_at": 1})) + "\n")
    os.utime(path, ns=(path.stat().st_mtime_ns + 1, path.stat().st_mtime_ns + 1))
    limits, _ = files.rate_limits()
    assert limits["primary"]["used_percent"] == 53.0 and reads == [path, path]


def test_rejects_non_finite_codex_context_numbers(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "inf-window", [token_count(42, float("inf"))])
    write_rollout(root, "nan-total", [token_count(float("nan"), 100)])
    files = CodexSessionFiles(root)
    assert files.context_percent("inf-window") is None
    assert files.context_percent("nan-total") is None


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def limits(percent):
    return rate_limited({"used_percent": percent, "window_minutes": 10080, "resets_at": 1})


def test_the_tree_is_relisted_at_most_every_list_interval(tmp_path):
    root, clock = tmp_path / "sessions", Clock()
    first = write_rollout(root, "first", [limits(10.0)])
    os.utime(first, ns=(1, 1))
    files = CodexSessionFiles(root, clock=clock)
    assert files.rate_limits()[0]["primary"]["used_percent"] == 10.0

    # A newer rollout in an old day's directory waits for the next full listing...
    old_day = write_rollout(root, "old-day", [limits(20.0)], day="2001/01/01")
    os.utime(old_day, ns=(2, 2))
    assert files.rate_limits()[0]["primary"]["used_percent"] == 10.0
    clock.now += LIST_SECONDS
    assert files.rate_limits()[0]["primary"]["used_percent"] == 20.0

    # ...while one written under today's date, where a new Codex session writes, is seen at once.
    today = write_rollout(root, "today", [limits(30.0)], day=datetime.now().strftime("%Y/%m/%d"))
    os.utime(today, ns=(3, 3))
    assert files.rate_limits()[0]["primary"]["used_percent"] == 30.0


def test_context_is_not_reparsed_until_its_rollout_changes(tmp_path, monkeypatch):
    root = tmp_path / "sessions"
    path = write_rollout(root, "t", [token_count(10, 100)])
    files = CodexSessionFiles(root)
    reads = []
    real = jsonl._lines_reverse
    monkeypatch.setattr(jsonl, "_lines_reverse", lambda p, *a: reads.append(p) or real(p, *a))

    assert files.context_percent("t") == 10
    assert files.context_percent("t") == 10 and reads == [path]
    with path.open("a") as stream:
        stream.write(json.dumps(token_count(20, 100)) + "\n")
    assert files.context_percent("t") == 20 and reads == [path, path]


def test_a_thread_without_a_rollout_is_not_searched_for_across_the_tree_every_tick(tmp_path):
    root, clock = tmp_path / "sessions", Clock()
    files = CodexSessionFiles(root, clock=clock)
    write_rollout(root, "other", [token_count(1, 100)])
    assert files.context_percent("late") is None

    write_rollout(root, "late", [token_count(40, 100)], day="2001/01/01")
    assert files.context_percent("late") is None
    clock.now += LIST_SECONDS
    assert files.context_percent("late") == 40

    # A brand-new thread's rollout appears under today's date and is found without waiting.
    assert files.context_percent("new") is None
    write_rollout(root, "new", [token_count(7, 100)], day=datetime.now().strftime("%Y/%m/%d"))
    assert files.context_percent("new") == 7


def test_a_rollout_is_scanned_for_token_counts_without_parsing_every_line(tmp_path, monkeypatch):
    """Most of a rollout is messages and tool output, and one with no `token_count` at all is read
    in full on every poll while Codex writes to it: its lines are looked for as bytes, and only a
    candidate is parsed."""
    root = tmp_path / "sessions"
    chatter = {"type": "response_item", "payload": {"type": "message", "content": "hello"}}
    write_rollout(root, "thread-1", [token_count(42, 100), *[chatter] * 50])
    parsed = []

    def counting_loads(line, *args, **kwargs):
        parsed.append(line)
        return json.loads(line, *args, **kwargs)

    # The module's own name for json, not the json module every other caller shares.
    monkeypatch.setattr(jsonl, "json", SimpleNamespace(loads=counting_loads))

    assert CodexSessionFiles(root).context_percent("thread-1") == 42
    assert len(parsed) == 1


def test_a_line_that_mentions_token_count_without_being_one_is_still_skipped(tmp_path):
    root = tmp_path / "sessions"
    quoting = {"type": "response_item", "payload": {"type": "message", "content": 'grep "token_count" rollout.jsonl'}}
    write_rollout(root, "thread-1", [token_count(42, 100), quoting])

    assert CodexSessionFiles(root).context_percent("thread-1") == 42


@pytest.mark.parametrize("block_size", [1, 2, 3, 7, 16, 64, 4096])
def test_matching_lines_are_found_whichever_block_they_straddle(tmp_path, block_size):
    lines = [b"plain one", b'{"a": "token_count", "n": 1}', b"", b"x" * 40, b'"token_count"', b"tail", b'{"token_count": 2}']
    for ending in (b"\n", b""):
        path = tmp_path / f"rollout-{block_size}-{len(ending)}.jsonl"
        path.write_bytes(b"\n".join(lines) + ending)

        found = list(jsonl._lines_reverse(path, b'"token_count"', block_size))

        assert found == [lines[6], lines[4], lines[1]]


def versioned(thread_id, version):
    record = meta(thread_id)
    record["payload"]["cli_version"] = version
    return record


def test_the_cli_version_is_the_newest_the_threads_rollout_names(tmp_path):
    root = tmp_path / "sessions"
    path = write_rollout(root, "thread-1", [versioned("thread-1", "0.160.0"), token_count(5, 100)])
    files = CodexSessionFiles(root)
    assert files.cli_version("thread-1") == "0.160.0"
    with path.open("a") as stream:  # resumed under a newer Codex
        stream.write(json.dumps(versioned("thread-1", "0.161.0")) + "\n")
    assert files.cli_version("thread-1") == "0.161.0"
    assert files.cli_version("thread-404") is None


def test_another_threads_session_meta_is_not_its_version(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "thread-2", [versioned("thread-1", "0.150.0"), meta("thread-2"), token_count(5, 100)])
    assert CodexSessionFiles(root).cli_version("thread-2") is None


def test_a_session_meta_half_written_is_read_once_it_is_complete(tmp_path):
    root = tmp_path / "sessions"
    path = write_rollout(root, "thread-3", [token_count(5, 100)])
    line = json.dumps(versioned("thread-3", "0.160.0"))
    files = CodexSessionFiles(root)
    with path.open("a") as stream:
        stream.write(line[:40])
    assert files.cli_version("thread-3") is None
    with path.open("a") as stream:
        stream.write(line[40:] + "\n")
    assert files.cli_version("thread-3") == "0.160.0"


def test_a_rewritten_rollout_is_read_again_from_its_start(tmp_path):
    root = tmp_path / "sessions"
    path = write_rollout(root, "thread-4", [versioned("thread-4", "0.161.0"), token_count(5, 100)])
    files = CodexSessionFiles(root)
    assert files.cli_version("thread-4") == "0.161.0"
    path.write_text(json.dumps(versioned("thread-4", "0.160.0")) + "\n")
    assert files.cli_version("thread-4") == "0.160.0"
    files.retain(set())
    assert files._versions == {}


@pytest.mark.parametrize("reading", ["context", "limits"])
def test_unreadable_rollout_is_retried_without_a_file_change(tmp_path, monkeypatch, reading):
    root = tmp_path / "sessions"
    path = write_rollout(root, "t1", [meta("t1"), limits(30)])
    files = CodexSessionFiles(root)
    read = {"context": lambda: files.context_percent("t1"),
            "limits": files.rate_limits}[reading]
    original = type(path).open

    def unreadable(candidate, *args, **kwargs):
        if candidate == path:
            raise OSError("temporarily unavailable")
        return original(candidate, *args, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(type(path), "open", unreadable)
        if reading == "limits":
            with pytest.raises(OSError, match="temporarily unavailable"):
                read()
        else:
            assert read() is None
    expected = {"context": 10,
                "limits": ({"limit_id": "codex", "primary": {"used_percent": 30, "window_minutes": 10080, "resets_at": 1},
                            "secondary": None, "plan_type": "team"}, 1790087469)}[reading]
    assert read() == expected


def test_usage_and_multiple_threads_share_one_tree_listing(tmp_path, monkeypatch):
    write_rollout(tmp_path, "one", [token_count(10, 100)])
    write_rollout(tmp_path, "two", [token_count(20, 100)])
    scans = []
    original = type(tmp_path).rglob

    def counted(path, pattern):
        scans.append(path)
        return original(path, pattern)

    monkeypatch.setattr(type(tmp_path), "rglob", counted)
    files = CodexSessionFiles(tmp_path)
    files.begin_tick()
    files.rate_limits()
    assert files.context_percent("one") == 10
    assert files.context_percent("two") == 20
    assert scans == [tmp_path]


def test_structured_turn_state_tracks_completion_and_later_start(tmp_path):
    files = CodexSessionFiles(tmp_path)
    path = write_rollout(tmp_path, "turn-thread", [
        {"type": "event_msg", "timestamp": "1970-01-01T00:01:41.250Z", "payload": {"type": "task_complete"}},
    ])
    assert files.turn_state("turn-thread") == ("done", 101.25)
    with path.open("a") as stream:
        stream.write(json.dumps({"type": "event_msg", "timestamp": "1970-01-01T00:01:42.500Z",
                                 "payload": {"type": "task_started"}}) + "\n")
    assert files.turn_state("turn-thread") == ("working", 102.5)


def test_plain_assistant_text_is_not_a_completed_turn(tmp_path):
    write_rollout(tmp_path, "turn-thread", [{"type": "response_item", "timestamp": "1970-01-01T00:01:41Z",
        "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Done."}]}}])
    assert CodexSessionFiles(tmp_path).turn_state("turn-thread") is None


@pytest.mark.parametrize("later", [{"type": "task_started"}, {"type": "turn_aborted"}])
def test_later_unstamped_turn_boundary_invalidates_previous_completion(tmp_path, later):
    write_rollout(tmp_path, "thread", [
        {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_complete"}},
        {"type": "event_msg", "payload": later},
    ])
    assert CodexSessionFiles(tmp_path).turn_state("thread") is None


def test_rate_limit_permission_failure_is_distinct_from_no_report(tmp_path, monkeypatch):
    files = CodexSessionFiles(tmp_path)
    rollout = tmp_path / "rollout-test.jsonl"
    rollout.write_text("{}\n")
    monkeypatch.setattr(files, "_newest_rollouts", lambda count: ((rollout, 1),))

    def denied(paths):
        raise PermissionError("rollout is unreadable")

    monkeypatch.setattr(files, "_read_rate_limits", denied)
    with pytest.raises(PermissionError, match="unreadable"):
        files.rate_limits()
