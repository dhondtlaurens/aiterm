import json
import os
from datetime import datetime
from types import SimpleNamespace

import pytest

from aitermd import jsonl
from aitermd.codex_sessions import LIST_SECONDS, CodexSessionFiles

from tests.codex_reference import MainCodexReference

from tests.builders import (
    write_rollout,
    token_count,
    codex_meta as meta,
    rate_limited,
    limits,
    codex_versioned as versioned,
)


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
    path.write_text(json.dumps(versioned("thread-4", "0.159.0")) + "\n")
    assert files.cli_version("thread-4") == "0.159.0"


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


# Captured against 6838b8f3 before the cursor consolidation. Each row is > 8 MiB.
@pytest.mark.parametrize("case,expected", [
    ("inside", ("0.161.0", ("done", 101.0))),
    ("boundary_head", ("0.161.0", ("done", 101.0))),
    ("meta_head", ("0.160.0", ("done", 101.0))),
    ("resume_middle", ("0.161.0", ("done", 101.0))),
    ("abort_head", ("0.161.0", None)),
    ("edge_partial", ("0.160.0", ("done", 101.0))),
    ("edge_complete", ("0.161.0", ("done", 101.0))),
    ("rewrite", ("0.161.0", ("done", 101.0))),
])
def test_large_rollout_answers_match_the_before_refactor_reference(tmp_path, case, expected):
    boundary = {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_complete"}}
    chatter = json.dumps({"type": "response_item", "payload": {"text": "x" * 1024}}) + "\n"
    padding = chatter * 8192
    def encode(value):
        return json.dumps(value) + "\n"
    head = encode(versioned("t", "0.160.0"))
    tail = encode(versioned("t", "0.161.0")) + encode(boundary)
    if case == "boundary_head":
        head += encode(boundary)
        tail = encode(versioned("t", "0.161.0"))
    elif case == "meta_head":
        tail = encode(boundary)
    elif case == "resume_middle":
        padding = chatter * 4096 + encode(versioned("t", "0.161.0")) + chatter * 8192
        tail = encode(boundary)
    elif case == "abort_head":
        head += encode(boundary) + encode({"type": "event_msg", "payload": {"type": "turn_aborted"}})
        tail = encode(versioned("t", "0.161.0"))
    elif case == "edge_complete":
        resumed = versioned("t", "0.161.0")
        resumed["payload"]["padding"] = "x" * (8 * 1024 * 1024 + 100)
        padding = encode(resumed)
        tail = encode(boundary) + chatter
    elif case == "edge_partial":
        head += encode(boundary)
        padding = '{"type":"response_item","text":"' + "x" * (8 * 1024 * 1024 + 100)
        tail = ""
    path = write_rollout(tmp_path, "t", [])
    files = CodexSessionFiles(tmp_path)
    reference = MainCodexReference(path)
    if case == "rewrite":
        path.write_text(encode(versioned("t", "9.999.0")))
        assert files.cli_version("t") == reference.cli_version("t") == "9.999.0"
        path.unlink()  # A replaced inode must discard its old cursor.
    path.write_text(head + padding + tail)
    if case == "resume_middle":
        assert (head + padding + tail).index(encode(versioned("t", "0.161.0"))) < path.stat().st_size - 8 * 1024 * 1024
    if case == "edge_complete":
        start = path.stat().st_size - 8 * 1024 * 1024
        assert len(head) < start < len(head + padding) < path.stat().st_size
    main_answer = reference.cli_version("t"), reference.turn_state("t")
    assert (files.cli_version("t"), files.turn_state("t")) == main_answer == expected
    if case == "edge_partial":
        with path.open("a") as stream:
            stream.write('"}\n' + encode(versioned("t", "0.162.0")))
        assert files.cli_version("t") == reference.cli_version("t") == "0.162.0"
        assert files.turn_state("t") == reference.turn_state("t") == expected[1]


@pytest.mark.parametrize("head_fallback", [False, True])
def test_large_rollout_first_sight_read_budget(tmp_path, monkeypatch, head_fallback):
    from aitermd.codex_sessions import READ_BYTES

    chatter = json.dumps({"type": "response_item", "payload": {"text": "x" * 1024}}) + "\n"
    boundary = {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_complete"}}
    path = write_rollout(tmp_path, "t", [])
    meta_line = json.dumps(versioned("t", "0.160.0")) + "\n"
    path.write_text((meta_line if head_fallback else "") + chatter * 8192
                    + ("" if head_fallback else meta_line) + json.dumps(boundary) + "\n")
    opened, read_bytes = [], []
    original = type(path).open

    class Counted:
        def __init__(self, stream):
            self.stream = stream

        def __enter__(self):
            self.stream.__enter__()
            return self

        def __exit__(self, *args):
            return self.stream.__exit__(*args)

        def read(self, *args):
            value = self.stream.read(*args)
            read_bytes.append(len(value))
            return value

        def __getattr__(self, name):
            return getattr(self.stream, name)

    def counted(candidate, *args, **kwargs):
        stream = original(candidate, *args, **kwargs)
        if candidate == path:
            opened.append(candidate)
            return Counted(stream)
        return stream

    monkeypatch.setattr(type(path), "open", counted)
    files = CodexSessionFiles(tmp_path)
    assert files.cli_version("t") == "0.160.0"
    assert files.turn_state("t") == ("done", 101.0)
    # Baseline: two opens and twice the size, for both shapes.
    assert len(opened) == 1
    assert sum(read_bytes) == (path.stat().st_size if head_fallback else READ_BYTES)
    assert READ_BYTES == 8 * 1024 * 1024


def test_one_thread_read_looks_up_its_path_once(tmp_path, monkeypatch):
    path = write_rollout(tmp_path, "t", [versioned("t", "0.160.0"), token_count(30, 100)])
    files, checked = CodexSessionFiles(tmp_path), []
    assert files.reading("t") == (30, "0.160.0", None)
    original = type(path).is_file

    def is_file(candidate):
        if candidate == path:
            checked.append(candidate)
        return original(candidate)

    monkeypatch.setattr(type(path), "is_file", is_file)
    assert files.reading("t") == (30, "0.160.0", None)
    assert checked == [path]  # Before: three known-path checks, one for each field.


def test_a_failed_combined_cursor_read_retries_without_a_file_change(tmp_path, monkeypatch):
    path = write_rollout(tmp_path, "t", [versioned("t", "0.160.0")])
    files = CodexSessionFiles(tmp_path)
    original = type(path).open

    def unavailable(candidate, *args, **kwargs):
        if candidate == path:
            raise OSError("unavailable")
        return original(candidate, *args, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(type(path), "open", unavailable)
        assert files.cli_version("t") is None
    assert files.cli_version("t") == "0.160.0"


def test_a_failed_context_does_not_discard_the_other_corroboration(tmp_path, monkeypatch):
    broken = '{"type":"event_msg","payload":{"type":"token_count","parser_error":true}}'
    write_rollout(tmp_path, "t", [versioned("t", "0.160.0"),
        {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_complete"}}, broken])
    original = json.loads

    def decode(line, *args, **kwargs):
        raw = line.encode() if isinstance(line, str) else line
        if b'"parser_error"' in raw:
            raise RecursionError("context parser unavailable")
        return original(line, *args, **kwargs)

    monkeypatch.setattr(json, "loads", decode)
    assert CodexSessionFiles(tmp_path).reading("t") == (None, "0.160.0", ("done", 101.0))


def test_history_refresh_still_stamps_every_candidate_before_picking_three(tmp_path, monkeypatch):
    for index in range(100):
        write_rollout(tmp_path, f"t{index}", [{"type": "response_item"}])
    clock, stamped = Clock(), []
    original = type(tmp_path).stat

    def stat(path, *args, **kwargs):
        if path.name.startswith("rollout-"):
            stamped.append(path)
        return original(path, *args, **kwargs)

    monkeypatch.setattr(type(tmp_path), "stat", stat)
    files = CodexSessionFiles(tmp_path, clock=clock)
    assert files.rate_limits() is None
    assert len(stamped) == 100
    stamped.clear()
    clock.now += LIST_SECONDS
    assert files.rate_limits() is None
    assert len(stamped) == 100  # Left out: newest-first discovery still traverses all history.


def test_rollout_cursor_detects_a_same_size_same_date_rewrite(tmp_path):
    path = write_rollout(tmp_path, "t", [versioned("t", "0.160.0")])
    files = CodexSessionFiles(tmp_path)
    assert files.cli_version("t") == "0.160.0"
    stamp = path.stat()
    path.write_text(path.read_text().replace("0.160.0", "0.161.0"))
    os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    assert path.stat().st_size == stamp.st_size
    assert files.cli_version("t") == "0.161.0"


def test_a_short_rollout_read_is_retried_without_a_stamp_change(tmp_path, monkeypatch):
    path = write_rollout(tmp_path, "t", [versioned("t", "0.160.0")])
    files, original = CodexSessionFiles(tmp_path), type(path).open

    class ShortRead:
        def __init__(self, stream):
            self.stream = stream

        def __enter__(self):
            self.stream.__enter__()
            return self

        def __exit__(self, *args):
            return self.stream.__exit__(*args)

        def __getattr__(self, name):
            return getattr(self.stream, name)

        def read(self, size):
            return self.stream.read(max(0, size - 1))

    def short(candidate, *args, **kwargs):
        stream = original(candidate, *args, **kwargs)
        return ShortRead(stream) if candidate == path else stream

    with monkeypatch.context() as patch:
        patch.setattr(type(path), "open", short)
        assert files.cli_version("t") is None
    assert files.cli_version("t") == "0.160.0"


def test_a_rollout_created_after_the_tick_listing_matches_the_reference(tmp_path):
    files = CodexSessionFiles(tmp_path, clock=lambda: 0)
    files.begin_tick()
    assert files.rate_limits() is None
    write_rollout(tmp_path, "late", [versioned("late", "0.160.0"), token_count(50, 100),
        {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_started"}}],
        day=datetime.now().strftime("%Y/%m/%d"))
    assert files.reading("late") == (None, "0.160.0", ("working", 101.0))
    files.begin_tick()
    assert files.reading("late") == (50, "0.160.0", ("working", 101.0))


@pytest.mark.parametrize("broken,expected", [
    ("session_meta", (50, None, ("working", 101.0))),
    ("task_started", (50, "0.160.0", None)),
])
def test_rollout_parse_failures_leave_the_other_readings_available(tmp_path, monkeypatch, caplog, broken, expected):
    original = json.loads

    def decode(line, *args, **kwargs):
        raw = line.encode() if isinstance(line, str) else line
        if b'"nested"' in raw:
            raise RecursionError("parser nesting limit")
        return original(line, *args, **kwargs)

    monkeypatch.setattr(json, "loads", decode)
    nested = "[" * 3000 + "0" + "]" * 3000
    bad = ('{"type":"session_meta","payload":{"id":"t","nested":' + nested + '}}' if broken == "session_meta"
           else '{"type":"event_msg","payload":{"type":"task_started","nested":' + nested + '}}')
    path = write_rollout(tmp_path, "t", [versioned("t", "0.160.0"),
        {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_started"}},
        bad, token_count(50, 100)])
    reference = MainCodexReference(path)
    answers = [reference.reading("t") for _ in range(3)]
    assert answers[0] == expected
    assert answers[1:] == [(50, "0.160.0", ("working", 101.0))] * 2
    caplog.clear()
    files = CodexSessionFiles(tmp_path)
    for answer in answers:
        assert files.reading("t") == answer
    assert len([record for record in caplog.records if record.exc_info]) == 1


def test_a_version_stat_failure_after_the_path_check_returns_no_version(tmp_path, monkeypatch):
    path = write_rollout(tmp_path, "t", [versioned("t", "0.160.0")])
    files = CodexSessionFiles(tmp_path)
    assert files.cli_version("t") == "0.160.0"
    original = type(path).stat
    is_file = type(path).is_file
    monkeypatch.setattr(type(path), "is_file", lambda candidate: True if candidate == path else is_file(candidate))

    def stat(candidate, *args, **kwargs):
        if candidate == path:
            raise PermissionError("stat unavailable after successful file check")
        return original(candidate, *args, **kwargs)

    monkeypatch.setattr(type(path), "stat", stat)
    assert files.cli_version("t") is None


def test_a_short_rollout_read_keeps_the_last_complete_boundary(tmp_path, monkeypatch):
    path = write_rollout(tmp_path, "t", [versioned("t", "0.160.0"),
        {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_started"}}])
    files = CodexSessionFiles(tmp_path)
    assert files.turn_state("t") == ("working", 101.0)
    with path.open("a") as stream:
        stream.write(json.dumps({"type": "event_msg", "timestamp": "1970-01-01T00:01:42Z",
                                 "payload": {"type": "task_complete"}}) + "\n")
    original = type(path).open

    class ShortRead:
        def __init__(self, stream):
            self.stream = stream

        def __enter__(self):
            self.stream.__enter__()
            return self

        def __exit__(self, *args):
            return self.stream.__exit__(*args)

        def __getattr__(self, name):
            return getattr(self.stream, name)

        def read(self, size):
            return self.stream.read(min(size, 10))

    def short(candidate, *args, **kwargs):
        stream = original(candidate, *args, **kwargs)
        return ShortRead(stream) if candidate == path else stream

    with monkeypatch.context() as patch:
        patch.setattr(type(path), "open", short)
        assert files.turn_state("t") == ("working", 101.0)
    assert files.turn_state("t") == ("done", 102.0)


@pytest.mark.parametrize("case,expected", [
    # Two independently approved differences: no prefix read, and field isolation during fallback.
    ("both_tail", (50, "0.161.0", ("done", 101.0))),
    ("need_version", (50, None, ("done", 101.0))),
    ("need_boundary", (50, "0.161.0", None)),
    ("boundary_fallback_only", (50, "0.161.0", ("done", 101.0))),
])
def test_prefix_parser_reference_rows(tmp_path, monkeypatch, case, expected):
    """Compare with main's retained parser code, including the two approved differences."""
    bad_meta = '{"type":"session_meta","payload":{"id":"t","unparseable":true}}'
    bad_turn = '{"type":"event_msg","payload":{"type":"task_complete","unparseable":true}}'
    done = {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_complete"}}
    chatter = json.dumps({"type": "response_item", "payload": {"text": "x" * 1024}}) + "\n"
    head = bad_turn if case == "need_boundary" else bad_meta
    if case == "boundary_fallback_only":
        head += "\n" + json.dumps(done)
    tail = [token_count(50, 100)]
    if case != "need_version":
        tail.append(versioned("t", "0.161.0"))
    if case not in ("need_boundary", "boundary_fallback_only"):
        tail.append(done)
    path = write_rollout(tmp_path, "t", [])
    path.write_text(head + "\n" + chatter * 8192 + "".join(json.dumps(record) + "\n" for record in tail))
    assert len(head) < path.stat().st_size - 8 * 1024 * 1024
    original = json.loads
    failed_prefix_parses = []

    def decode(line, *args, **kwargs):
        raw = line.encode() if isinstance(line, str) else line
        if b'"unparseable"' in raw:
            failed_prefix_parses.append(line)
            raise RecursionError("unsupported old record")
        return original(line, *args, **kwargs)

    monkeypatch.setattr(json, "loads", decode)
    main_answer = MainCodexReference(path).reading("t")
    failed_prefix_parses.clear()
    assert CodexSessionFiles(tmp_path).reading("t") == expected
    assert bool(failed_prefix_parses) == (case in ("need_version", "need_boundary"))
    if case in ("need_version", "need_boundary"):
        assert expected == main_answer
    else:
        assert expected != main_answer
        assert (expected[0], expected[2]) == (main_answer[0], main_answer[2])


@pytest.mark.parametrize("head_fallback", [False, True])
@pytest.mark.parametrize("reader_kind", ["main", "current"])
def test_unchanged_rollout_after_parser_failure_has_no_second_or_third_tick_io(
    tmp_path, monkeypatch, head_fallback, reader_kind,
):
    chatter = json.dumps({"type": "response_item", "payload": {"text": "x" * 1024}}) + "\n"
    facts = (json.dumps(versioned("t", "0.160.0")) + "\n"
             + '{"type":"session_meta","payload":{"id":"t","unparseable":true}}\n')
    tail = json.dumps({"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z",
                       "payload": {"type": "task_complete"}}) + "\n" + json.dumps(token_count(50, 100)) + "\n"
    path = write_rollout(tmp_path, "t", [])
    path.write_text((facts if head_fallback else "") + chatter * 8192
                    + ("" if head_fallback else facts) + tail)
    loads = json.loads

    def decode(line, *args, **kwargs):
        raw = line.encode() if isinstance(line, str) else line
        if b'"unparseable"' in raw:
            raise RecursionError("old metadata decoder failure")
        return loads(line, *args, **kwargs)

    monkeypatch.setattr(json, "loads", decode)
    opened, reads = [], []
    original = type(path).open

    class Counted:
        def __init__(self, stream):
            self.stream = stream

        def __enter__(self):
            self.stream.__enter__()
            return self

        def __exit__(self, *args):
            return self.stream.__exit__(*args)

        def __getattr__(self, name):
            return getattr(self.stream, name)

        def read(self, *args):
            result = self.stream.read(*args)
            reads.append(len(result))
            return result

    def counted(candidate, *args, **kwargs):
        stream = original(candidate, *args, **kwargs)
        if candidate == path:
            opened.append(candidate)
            return Counted(stream)
        return stream

    monkeypatch.setattr(type(path), "open", counted)
    files = MainCodexReference(path) if reader_kind == "main" else CodexSessionFiles(tmp_path)
    files.reading("t")
    ticks = []
    for _ in range(2):
        opened.clear()
        reads.clear()
        files.reading("t")
        ticks.append((len(opened), len(reads), sum(reads)))
    # Main: zero opens, zero reads and zero bytes on ticks two and three, for both shapes.
    assert ticks == [(0, 0, 0), (0, 0, 0)], f"second/third tick opens, reads, bytes: {ticks}"


@pytest.mark.parametrize("broken", ["session_meta", "task_started"])
def test_parser_failure_keeps_only_preceding_facts_and_later_appends_resume(tmp_path, monkeypatch, broken):
    path = write_rollout(tmp_path, "t", [versioned("t", "0.160.0"),
        {"type": "event_msg", "timestamp": "1970-01-01T00:01:41Z", "payload": {"type": "task_started"}},
        {"type": "session_meta" if broken == "session_meta" else "event_msg",
         "payload": {"id": "t", "type": broken, "unparseable": True}},
        versioned("t", "0.161.0"),
        {"type": "event_msg", "timestamp": "1970-01-01T00:01:42Z", "payload": {"type": "task_complete"}},
        token_count(50, 100)])
    loads = json.loads

    def decode(line, *args, **kwargs):
        raw = line.encode() if isinstance(line, str) else line
        if b'"unparseable"' in raw:
            raise RecursionError("decoder failed before the rest of this batch")
        return loads(line, *args, **kwargs)

    monkeypatch.setattr(json, "loads", decode)
    reference, files = MainCodexReference(path), CodexSessionFiles(tmp_path)
    for _ in range(3):
        assert files.reading("t") == reference.reading("t")
    with path.open("a") as stream:
        stream.write(json.dumps(versioned("t", "0.162.0")) + "\n")
        stream.write(json.dumps({"type": "event_msg", "timestamp": "1970-01-01T00:01:43Z",
                                 "payload": {"type": "task_started"}}) + "\n")
    assert files.reading("t") == reference.reading("t") == (50, "0.162.0", ("working", 103.0))
