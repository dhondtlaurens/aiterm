import json
import os

import pytest

from aitermd import claude_subagents
from aitermd.claude_subagents import SubagentTranscripts

# The records a Claude subagent transcript ends with, as Claude Code 2.1.285 writes them.
PROMPT = {"type": "user", "isSidechain": True, "agentId": "c1", "message": {"role": "user", "content": "Fix the tests"}}
ASSISTANT = {"type": "assistant", "isSidechain": True, "agentId": "c1",
             "message": {"role": "assistant", "content": [{"type": "text", "text": "Working on it"}]}}
# What the stream watchdog leaves when it kills a stalled child.
INTERRUPTED = {"type": "user", "isSidechain": True, "agentId": "c1",
               "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}}
INTERRUPTED_IN_TOOL = {"type": "user", "isSidechain": True, "agentId": "c1", "message": {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": "toolu_1", "content": "…"},
    {"type": "text", "text": "[Request interrupted by user for tool use]"}]}}
STOPPED = {"type": "attachment", "isSidechain": True, "agentId": "c1",
           "attachment": {"type": "hook_success", "hookName": "SubagentStop", "hookEvent": "SubagentStop", "exitCode": 200}}
# The same hook when the daemon was not listening.
STOP_FAILED = {"type": "attachment", "attachment": {"type": "hook_non_blocking_error", "hookEvent": "SubagentStop"}}
STARTED = {"type": "attachment", "attachment": {"type": "hook_success", "hookName": "SubagentStart:general-purpose",
                                                "hookEvent": "SubagentStart"}}
# What Claude Code 2.1.308 writes when a background child ends its turn without handing back its report: this
# reminder, then the SubagentStop hook's attachment; then it runs the child on to answer the reminder.
REMINDED = {"type": "user", "isSidechain": True, "agentId": "c1", "isMeta": True, "message": {"role": "user", "content": (
    "[handback-send-enforce] Your report has not been delivered. Call SubagentHandback({message: <your full report>}) now; "
    "the call ends your run.")}}
# The answer to the call that hands the report back, which ends the run.
HANDED_BACK = {"type": "user", "isSidechain": True, "agentId": "c1", "message": {"role": "user", "content": [
    {"tool_use_id": "toolu_1", "type": "tool_result",
     "content": [{"type": "text", "text": '{"success":true,"message":"Report delivered to your caller."}'}]}]}}


def write(path, *records, tail=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in records) + tail)
    return str(path)


def has_ended(path):
    """Whether the transcript at `path` reads as the end of its child's run."""
    return SubagentTranscripts().read(path).ended_at is not None


@pytest.mark.parametrize("last,ended", [
    (INTERRUPTED, True), (INTERRUPTED_IN_TOOL, True), (STOPPED, True), (STOP_FAILED, True),
    (ASSISTANT, False), (PROMPT, False), (STARTED, False),
    # The watchdog's text inside a tool result or an assistant message is not the interruption.
    ({"type": "assistant", "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}}, False),
])
def test_a_transcript_has_ended_only_on_an_interruption_or_a_subagent_stop(tmp_path, last, ended):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, ASSISTANT, last)
    assert has_ended(path) is ended


@pytest.mark.parametrize("records,ended", [
    ((ASSISTANT, HANDED_BACK, STOPPED), True),
    ((ASSISTANT, INTERRUPTED, STOPPED), True),
    # Reminded to hand its report back, the child answers that next: the stop is not its end, whichever hooks ran.
    ((ASSISTANT, REMINDED, STOPPED), False),
    ((ASSISTANT, REMINDED, STOPPED, STOP_FAILED), False),
])
def test_a_subagent_stop_after_a_prompt_the_child_has_yet_to_answer_has_not_ended(tmp_path, records, ended):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, *records)
    assert has_ended(path) is ended


def test_a_stop_stands_when_the_tail_cannot_show_what_came_before_it(tmp_path, monkeypatch):
    # A final message longer than the tail window: nothing shows a prompt waiting on the child.
    monkeypatch.setattr(claude_subagents, "TAIL_BYTES", 256)
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, {**ASSISTANT, "pad": "x" * 1000}, STOPPED)
    assert has_ended(path)


def test_a_missing_transcript_reads_as_none(tmp_path):
    assert SubagentTranscripts().read(str(tmp_path / "agent-c1.jsonl")) is None


def test_a_record_still_being_written_has_not_ended(tmp_path):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, INTERRUPTED, tail='{"type": "user", "mess')
    assert not has_ended(path)


def test_only_the_tail_is_read(tmp_path, monkeypatch):
    # A last record longer than the tail window is neither of the small records that end a child.
    monkeypatch.setattr(claude_subagents, "TAIL_BYTES", 256)
    big = {"type": "user", "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}, "pad": "x" * 1000}
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, big)
    assert not has_ended(path)
    path = write(tmp_path / "agent-c2.jsonl", *([ASSISTANT] * 50), INTERRUPTED)
    assert os.path.getsize(path) > 256
    assert has_ended(path)


def test_the_tail_is_stamped_with_the_files_mtime_and_size(tmp_path):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT)
    os.utime(path, ns=(5_000_000_000, 5_000_000_000))
    tail = SubagentTranscripts().read(path)
    assert tail.stamp == (5_000_000_000, os.path.getsize(path))
    assert tail.written_at == 5.0


def test_an_unchanged_transcript_is_not_read_again(tmp_path, monkeypatch):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, INTERRUPTED)
    transcripts = SubagentTranscripts()
    first = transcripts.read(path)
    monkeypatch.setattr(claude_subagents, "_ending", lambda _tail: pytest.fail("reparsed an unchanged file"))
    assert transcripts.read(path) == first


def test_a_transcript_in_a_subdirectory_of_subagents_is_found(tmp_path):
    # Claude Code files some agents under subagents/<subdir>/ (its agentTranscriptSubdirs).
    subagents = tmp_path / "sess" / "subagents"
    write(subagents / "wf-1" / "agent-c1.jsonl", PROMPT, INTERRUPTED)
    assert has_ended(str(subagents / "agent-c1.jsonl"))


def test_a_workflow_agents_transcript_two_directories_down_is_found(tmp_path):
    # Claude Code files a workflow's agents under subagents/workflows/<run>/ (2.1.308).
    subagents = tmp_path / "sess" / "subagents"
    path = write(subagents / "workflows" / "wf_155a408a-eb7" / "agent-c1.jsonl", PROMPT, ASSISTANT)
    os.utime(path, (1_900_000_000, 1_900_000_000))
    tail = SubagentTranscripts().read(str(subagents / "agent-c1.jsonl"))
    assert tail is not None and tail.written_at == 1_900_000_000


def test_read_all_answers_every_transcript_asked_for(tmp_path):
    # One it cannot find is answered with None: unlike one it was not asked for, it was looked for.
    present = write(tmp_path / "agent-c1.jsonl", PROMPT)
    missing = str(tmp_path / "agent-c2.jsonl")
    tails = SubagentTranscripts().read_all({present, missing})
    assert set(tails) == {present, missing}
    assert tails[present] is not None and tails[missing] is None


def test_a_tail_ends_at_the_time_its_ending_record_gives(tmp_path):
    # Claude writes in batches: a record can reach the file well after its own time, after a resume's SubagentStart.
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, ASSISTANT, {**STOPPED, "timestamp": "2026-10-22T20:34:55.612Z"})
    os.utime(path, (1_900_000_000, 1_900_000_000))
    tail = SubagentTranscripts().read(path)
    assert tail.ended_at == 1_792_701_295.612 and tail.written_at == 1_900_000_000


def test_an_ending_record_whose_time_has_no_zone_is_read_as_utc(tmp_path, away_from_utc):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, ASSISTANT, {**STOPPED, "timestamp": "2026-10-22T20:34:55.612"})
    assert SubagentTranscripts().read(path).ended_at == 1_792_701_295.612


def test_a_tail_ending_in_a_record_without_a_time_ends_at_its_write(tmp_path):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, ASSISTANT, STOPPED)
    os.utime(path, (1_900_000_000, 1_900_000_000))
    assert SubagentTranscripts().read(path).ended_at == 1_900_000_000
    path = write(tmp_path / "agent-c2.jsonl", PROMPT, ASSISTANT)
    assert SubagentTranscripts().read(path).ended_at is None
