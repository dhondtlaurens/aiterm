import json
import pytest

from aitermd.claude_background import BackgroundTranscripts


def record(kind, content, at=101, **extra):
    return {"type": kind, "timestamp": f"1970-01-01T00:01:{at - 60:02d}.000Z",
            "message": {"content": content}, **extra}


def launch(task="job1", call="call1", at=101, command="npm run test"):
    return [record("assistant", [{"type": "tool_use", "id": call, "name": "Bash",
                                  "input": {"command": command, "run_in_background": True}}], at),
            record("user", [{"type": "tool_result", "tool_use_id": call, "content": "not parsed"}], at + 1,
                   toolUseResult={"backgroundTaskId": task, "stdout": "", "stderr": "", "interrupted": False})]


def completed(task="job1", at=110, status="completed"):
    return record("user", [{"type": "text", "text":
                  f"<task-notification>\n<task-id>{task}</task-id>\n<status>{status}</status>\n</task-notification>"}], at)


def write(path, records):
    path.write_text("".join(json.dumps(r) + "\n" for r in records))


def read(reader, path, since=100):
    return reader.read_all({"session": (str(path), since)})["session"]


def test_only_native_confirmed_background_results_establish_jobs(tmp_path):
    path = tmp_path / "parent.jsonl"
    write(path, launch())
    reader = BackgroundTranscripts()
    result = read(reader, path)
    assert [(task.job.task_id, task.job.text) for task in result.tasks] == [("job1", "npm run test")]
    write(path, launch()[:1])
    assert read(reader, path).tasks == ()  # A flag requesting background execution is not a successful launch.


def test_completion_is_seen_without_a_tool_poll_and_never_replayed_as_running(tmp_path):
    path = tmp_path / "parent.jsonl"
    write(path, launch())
    reader = BackgroundTranscripts()
    assert len(read(reader, path).tasks) == 1
    with path.open("a") as f:
        f.write(json.dumps(completed()) + "\n")
    result = read(reader, path)
    assert result.tasks == () and result.ended == frozenset({"job1"})
    assert read(reader, path) == result


@pytest.mark.parametrize("carrier", ["user", "attachment", "enqueue"])
@pytest.mark.parametrize("status", ["completed", "failed", "killed", "stopped"])
def test_native_mid_turn_terminal_notices_retire_only_the_named_shell(tmp_path, carrier, status):
    path = tmp_path / "parent.jsonl"
    notice = completed("a", status=status)
    text = notice["message"]["content"][0]["text"]
    if carrier == "attachment":
        notice = {"type": "attachment", "timestamp": notice["timestamp"],
                  "attachment": {"type": "queued_command", "commandMode": "task-notification", "prompt": text}}
    elif carrier == "enqueue":
        notice = {"type": "queue-operation", "operation": "enqueue", "timestamp": notice["timestamp"], "content": text}
    write(path, launch("a", "ca") + launch("b", "cb", at=104) + [notice])
    result = read(BackgroundTranscripts(), path)
    assert result is not None
    assert [task.job.task_id for task in result.tasks] == ["b"]
    assert "a" in result.ended  # Terminal display evidence says nothing about success or turn completion.


@pytest.mark.parametrize("carrier", ["user", "attachment", "enqueue"])
@pytest.mark.parametrize("body", [
    '<task-id>monitor</task-id><summary>Monitor event: "Wait for test process to end"</summary><event>ready</event>',
    '<summary>Artifact watch started</summary>',
    '<task-id>other-task</task-id><status>unverified-status</status>',
])
def test_unrelated_native_notices_leave_verified_shells_available(tmp_path, carrier, body):
    path = tmp_path / "parent.jsonl"
    write(path, launch())
    reader = BackgroundTranscripts()
    before = read(reader, path)
    text = f"<task-notification>\n{body}\n</task-notification>"
    notice = record("user", [{"type": "text", "text": text}], 110)
    if carrier == "attachment":
        notice = {"type": "attachment", "timestamp": notice["timestamp"],
                  "attachment": {"type": "queued_command", "commandMode": "task-notification", "prompt": text}}
    elif carrier == "enqueue":
        notice = {"type": "queue-operation", "operation": "enqueue", "timestamp": notice["timestamp"], "content": text}
    with path.open("a") as f:
        f.write(json.dumps(notice) + "\n")
    assert read(reader, path) == before


def test_a_statusless_notice_about_a_tracked_shell_is_unavailable_until_verified(tmp_path):
    path = tmp_path / "parent.jsonl"
    write(path, launch() + [record("user", [{"type": "text", "text":
          '<task-notification><task-id>job1</task-id><summary>Unknown event</summary></task-notification>'}], 110)])
    reader = BackgroundTranscripts()
    assert read(reader, path) is None
    with path.open("a") as f:
        f.write(json.dumps(completed(at=112)) + "\n")
    assert read(reader, path).tasks == ()


def test_replay_waits_for_its_captured_end_and_handles_partial_records(tmp_path):
    path = tmp_path / "parent.jsonl"
    write(path, launch() + [completed()])
    reader = BackgroundTranscripts(read_bytes=100)
    result = read(reader, path)
    assert result is None
    for _ in range(20):
        result = read(reader, path)
        if result is not None:
            break
    assert result is not None and result.tasks == ()
    write(path, launch())
    with path.open("a") as f:
        f.write(json.dumps(completed())[:-3])
    reader = BackgroundTranscripts()
    assert read(reader, path) is None  # Incomplete trailing evidence is not a current inventory.
    with path.open("a") as f:
        f.write(json.dumps(completed())[-3:] + "\n")
    assert read(reader, path).tasks == ()


def test_identity_cutoff_rewrite_and_unavailable_file(tmp_path):
    path = tmp_path / "parent.jsonl"
    write(path, launch())
    reader = BackgroundTranscripts()
    assert len(read(reader, path).tasks) == 1
    assert read(reader, path, since=105).tasks == ()
    path.unlink()
    assert read(reader, path, since=105) is None
    write(path, launch("new", "new-call", at=106))
    assert read(reader, path, since=105).tasks[0].job.task_id == "new"
    reader.read_all({})
    assert not reader._read


def test_task_ids_not_command_strings_define_identity(tmp_path):
    path = tmp_path / "parent.jsonl"
    write(path, launch("a", "ca") + launch("b", "cb", at=104) + [completed("a")])
    result = read(BackgroundTranscripts(), path)
    assert [task.job.task_id for task in result.tasks] == ["b"]


def test_foreground_quoted_and_child_records_do_not_create_or_finish_parent_work(tmp_path):
    path = tmp_path / "parent.jsonl"
    ordinary = launch("not-bg", "fg")
    ordinary[1]["toolUseResult"] = {"stdout": "backgroundTaskId", "stderr": ""}
    quoted = completed()
    quoted["type"] = "assistant"
    child = completed()
    child["isSidechain"] = True
    write(path, ordinary + launch() + [quoted, child])
    assert [task.job.task_id for task in read(BackgroundTranscripts(), path).tasks] == ["job1"]


def test_successful_native_task_stop_and_unknown_status(tmp_path):
    path = tmp_path / "parent.jsonl"
    stop = [record("assistant", [{"type": "tool_use", "id": "stop", "name": "TaskStop", "input": {"task_id": "job1"}}], 108),
            record("user", [{"type": "tool_result", "tool_use_id": "stop", "content": "stopped"}], 109,
                   toolUseResult={"task_id": "job1", "task_type": "local_bash", "message": "stopped", "command": "npm run test"})]
    write(path, launch() + stop)
    assert read(BackgroundTranscripts(), path).tasks == ()
    write(path, launch() + [completed(status="unverified-status")])
    assert read(BackgroundTranscripts(), path) is None


def test_unverifiable_task_stop_does_not_retain_a_running_claim(tmp_path):
    path = tmp_path / "parent.jsonl"
    write(path, launch() + [
        record("assistant", [{"type": "tool_use", "id": "stop", "name": "TaskStop", "input": {"task_id": "job1"}}], 108),
        record("user", [{"type": "tool_result", "tool_use_id": "stop", "content": "unverified result"}], 109)])
    assert read(BackgroundTranscripts(), path) is None


def test_unchanged_transcript_does_not_reopen_the_file(tmp_path, monkeypatch):
    path = tmp_path / "parent.jsonl"
    write(path, launch())
    reader = BackgroundTranscripts()
    expected = read(reader, path)

    def unexpected_open(*args, **kwargs):
        raise AssertionError("unchanged transcript was reopened")

    monkeypatch.setattr(type(path), "open", unexpected_open)
    assert read(reader, path) == expected


def test_an_unknown_outcome_recovers_when_completion_later_arrives(tmp_path):
    path = tmp_path / "parent.jsonl"
    write(path, launch() + [completed(status="unverified-status")])
    reader = BackgroundTranscripts()
    assert read(reader, path) is None
    with path.open("a") as f:
        f.write(json.dumps(completed(at=112)) + "\n")
        for r in launch("new", "new-call", at=113):
            f.write(json.dumps(r) + "\n")
    assert [task.job.task_id for task in read(reader, path).tasks] == ["new"]


def test_a_later_complete_stop_recovers_from_a_gap_without_replaying_the_file(tmp_path):
    path = tmp_path / "parent.jsonl"
    path.write_text('{"a truncated historical record\n')
    with path.open("a") as f:
        for r in launch():
            f.write(json.dumps(r) + "\n")
    reader = BackgroundTranscripts(clock=lambda: 110)
    assert read(reader, path) is None
    # A complete Stop after the gap observation can establish the current set again. The
    # status engine still checks its native IDs and filters tasks not listed by that Stop.
    recovered = reader.read_all({"session": (str(path), 100)}, {"session": 111})["session"]
    assert recovered is not None and recovered.tasks[0].job.task_id == "job1"
