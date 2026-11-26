"""A Claude Code agent team's members as the lead's transcript tells them, and how its Stop's teammate entries show.

Claude Code lists a live teammate in a Stop's `background_tasks` as `running`, idle or not (2.1.332), so an agent that
finished its work and waits for messages used to hold the row's turn, spinner and job count until it was stopped."""
import json

import pytest

from aitermd.agents import claude
from aitermd.agents.claude import BackgroundTranscripts, parse_claude_hook
from aitermd.hook_events import HookEvent
from aitermd.models import BackgroundJob, RawSession, SessionInfo, Teammate, TranscriptWork, work_items
from aitermd.sessions import SessionRegistry
from aitermd.status import StatusEngine

from tests.builders import (
    idle_notice,
    send_message,
    shell_completed,
    shell_launch,
    teammate_spawn as spawn,
    teammate_task,
    teammate_task_stop as task_stop,
    teammate_terminated,
    write_transcript as write,
)


def team(reader, path, since=100):
    return reader.read_with_labels({"s": (str(path), since)})["s"].transcript_work


def states(reading):
    return {member.name: member.state for member in reading.teammates}


def append(path, records):
    with path.open("a") as f:
        f.write("".join(json.dumps(r) + "\n" for r in records))


# -- the reader ----------------------------------------------------------------------------------------------------
def test_a_spawned_teammate_runs_until_its_idle_notification(tmp_path):
    path = tmp_path / "lead.jsonl"
    write(path, spawn())
    reader = BackgroundTranscripts()
    reading = team(reader, path)
    assert reading.teammates == (Teammate("skin-a", "askin-a-0123456789abcdef", "Build skin A", "running"),)
    append(path, [idle_notice()])
    assert states(team(reader, path)) == {"skin-a": "idle"}


def test_a_message_wakes_an_idle_teammate_and_its_next_notification_idles_it_again(tmp_path):
    path = tmp_path / "lead.jsonl"
    write(path, spawn() + [idle_notice(at=110)])
    reader = BackgroundTranscripts()
    assert states(team(reader, path)) == {"skin-a": "idle"}
    append(path, send_message(at=112))
    assert states(team(reader, path)) == {"skin-a": "running"}
    # A notification queued before the message reached it, delivered after, says nothing of it now.
    append(path, [idle_notice(at=114, written=111)])
    assert states(team(reader, path)) == {"skin-a": "running"}
    append(path, [idle_notice(at=118)])
    assert states(team(reader, path)) == {"skin-a": "idle"}


def test_a_teammate_that_goes_idle_before_its_messages_result_is_written_is_idle(tmp_path):
    path = tmp_path / "lead.jsonl"
    message = send_message(at=112)
    message[1]["timestamp"] = "1970-01-01T00:01:55.000Z"  # The result lands 3 s after the call.
    write(path, spawn() + [idle_notice(at=110)] + message + [idle_notice(at=116, written=113)])
    assert states(team(BackgroundTranscripts(), path)) == {"skin-a": "idle"}


def test_a_broadcast_wakes_every_live_teammate_and_a_failed_message_wakes_none(tmp_path):
    path = tmp_path / "lead.jsonl"
    write(path, spawn("skin-a") + spawn("skin-b", description="Build skin B", at=103)
          + [idle_notice("skin-a", at=110), idle_notice("skin-b", at=111)] + send_message("skin-a", at=112, success=False))
    reader = BackgroundTranscripts()
    assert states(team(reader, path)) == {"skin-a": "idle", "skin-b": "idle"}
    append(path, send_message("*", at=114))
    assert states(team(reader, path)) == {"skin-a": "running", "skin-b": "running"}


@pytest.mark.parametrize("value", ["skin-a", "askin-a-0123456789abcdef", "tq1abcdef"])
def test_an_idle_teammate_ends_with_a_task_stop_by_name_agent_or_task_id(tmp_path, value):
    path = tmp_path / "lead.jsonl"
    write(path, spawn() + [idle_notice()] + task_stop(value))
    reading = team(BackgroundTranscripts(), path)
    assert states(reading) == {"skin-a": "ended"}
    assert reading.ended_tasks == frozenset({"tq1abcdef"})


def test_a_teammate_ends_with_its_termination_and_stays_ended(tmp_path):
    path = tmp_path / "lead.jsonl"
    write(path, spawn("skin-a") + spawn("skin-b", description="Build skin B", at=103)
          + [idle_notice("skin-a"), teammate_terminated("skin-a", at=116)] + send_message("*", at=117))
    assert states(team(BackgroundTranscripts(), path)) == {"skin-a": "ended", "skin-b": "running"}


def test_the_team_is_unknown_while_the_transcript_is_not_read_to_its_end(tmp_path):
    path = tmp_path / "lead.jsonl"
    write(path, spawn() + [idle_notice()])
    assert team(BackgroundTranscripts(read_bytes=100), path) is None
    with path.open("a") as f:
        f.write('{"type": "user", "timestamp": "1970-01-01T00:02:00.000Z", "message": {"content": "half')
    assert team(BackgroundTranscripts(), path) is None


def test_a_gap_leaves_the_team_unknown_after_a_stop_recovers_the_shells(tmp_path):
    """A Stop's shell list makes the shells known again after a gap; it says nothing of an idle notification or a
    wake the gap may have swallowed, so the team stays unknown and its entries fall back to running."""
    path = tmp_path / "lead.jsonl"
    write(path, spawn() + [idle_notice(at=110)])
    with path.open("a") as f:
        f.write("{not json\n")
    reader = BackgroundTranscripts(clock=lambda: 112)
    assert team(reader, path) is None
    assert reader.read_with_labels({"s": (str(path), 100)}, {"s": 115})["s"].transcript_work is None
    assert reader.read_all({"s": (str(path), 100)}, {"s": 115})["s"] is not None  # The shells recovered.


def test_a_teammate_spawned_before_the_work_began_is_not_known(tmp_path):
    path = tmp_path / "lead.jsonl"
    write(path, spawn(at=90) + [idle_notice(at=110)])
    assert team(BackgroundTranscripts(), path) == TranscriptWork()


def test_a_teammates_description_labels_its_counted_agent(tmp_path):
    path = tmp_path / "lead.jsonl"
    write(path, spawn())
    reading = BackgroundTranscripts().read_with_labels({"s": (str(path), 100)})["s"]
    assert reading.child_labels == (("askin-a-0123456789abcdef", "Build skin A"),)


# -- the Stop's entries -------------------------------------------------------------------------------------------
def test_a_stop_flags_its_teammate_entries():
    ev = parse_claude_hook({"hook_event_name": "Stop", "session_id": "c", "background_tasks": [
        teammate_task(), {"id": "b1", "type": "shell", "status": "running", "command": "npm run dev"}]})
    assert ev.background_work == (BackgroundJob("task", "Build skin A", task_id="tq1abcdef", teammate=True),
                                  BackgroundJob("shell", "npm run dev", task_id="b1"))


def ended_session(*members, stopped=frozenset(), counted=()):
    session = SessionInfo("s1", "w1", 0, "t1", None, "claude", "done", "", "/x", 1)
    session.stop_work = (BackgroundJob("task", "Build skin A", task_id="tq1abcdef", teammate=True),)
    session.transcript_work = TranscriptWork(tuple(members), stopped) if members or stopped else None
    session.shown_subagents = tuple(BackgroundJob("subagent", "Build skin A", agent_id=agent) for agent in counted)
    return session


A = "askin-a-0123456789abcdef"


@pytest.mark.parametrize("members,stopped,counted,expected", [
    # No reading: a listed teammate keeps holding the turn, as before.
    ((), frozenset(), (), [{"kind": "subagent", "text": "Build skin A", "holdsTurn": True, "idle": False}]),
    ((Teammate("skin-a", A, "Build skin A", "running"),), frozenset(), (),
     [{"kind": "subagent", "text": "Build skin A", "holdsTurn": True, "idle": False}]),
    ((Teammate("skin-a", A, "Build skin A", "idle"),), frozenset(), (),
     [{"kind": "subagent", "text": "Build skin A", "holdsTurn": False, "idle": True}]),
    # Idle by its transcript, but its agent woke (a peer's message) and counts: running, on one line.
    ((Teammate("skin-a", A, "Build skin A", "idle"),), frozenset(), (A,),
     [{"kind": "subagent", "text": "Build skin A", "holdsTurn": True, "idle": False}]),
    ((Teammate("skin-a", A, "Build skin A", "ended"),), frozenset(), (), []),
    ((Teammate("skin-a", A, "Build skin A", "idle"),), frozenset({"tq1abcdef"}), (), []),
    # Two teammates spawned with one description: idle only once both are.
    ((Teammate("skin-a", A, "Build skin A", "idle"), Teammate("skin-a2", "a2", "Build  skin A", "running")),
     frozenset(), (), [{"kind": "subagent", "text": "Build skin A", "holdsTurn": True, "idle": False}]),
    # One the transcript does not know (spawned before the work began): as before.
    ((Teammate("other", "a9", "Something else", "idle"),), frozenset(), (),
     [{"kind": "subagent", "text": "Build skin A", "holdsTurn": True, "idle": False}]),
])
def test_a_listed_teammate_shows_as_its_transcript_says(members, stopped, counted, expected):
    assert [item.to_json() for item in work_items(ended_session(*members, stopped=stopped, counted=counted))] == expected


# -- end to end: Stop hook, transcript, engine, wire ----------------------------------------------------------------
class Clock:
    now = 100.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def lead(tmp_path):
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("s1", "w1", 0, "claude", 1, "", "/x", {"aiterm_task": "t1"})])
    engine, reader, path = StatusEngine(reg, Clock()), BackgroundTranscripts(), tmp_path / "lead.jsonl"
    # The hook's metadata lands before its event: the conversation is named, then its work begins.
    engine.apply_metadata("s1", transcript=str(path), conversation="c")
    engine.apply_event("s1", HookEvent("claude", "sessionStart", "c", "/x", event_name="SessionStart"))

    def tick(records=None):
        if records is not None:
            write(path, records)
        plan = claude.background_plan(engine, reader, reg.all())
        assert plan.read is not None
        plan.apply(plan.read())
        session = reg.get("s1")
        return session.state, session.to_json()["work"]

    return engine, reg, tick


def hook(kind, child=None):
    return HookEvent("claude", kind, "c", "/x", subagent_id=child)


def stop(*tasks):
    return parse_claude_hook({"hook_event_name": "Stop", "session_id": "c", "background_tasks": list(tasks)})


def test_a_working_teammate_holds_the_turn_until_it_goes_idle(lead):
    engine, reg, tick = lead
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", A))
    engine.apply_event("s1", stop(teammate_task()))
    assert tick(spawn()) == ("working", [{"kind": "subagent", "text": "Subagent", "holdsTurn": False, "idle": False,
                                          "displayLabel": "Build skin A"}])
    # Its turn ends: its agent is released, and its notification reaches the lead.
    engine.apply_event("s1", hook("subagentStop", A))
    assert tick(spawn() + [idle_notice()]) == ("done", [
        {"kind": "subagent", "text": "Build skin A", "holdsTurn": False, "idle": True}])


def test_an_idle_teammate_a_message_wakes_holds_the_turn_again(lead):
    engine, reg, tick = lead
    engine.apply_event("s1", stop(teammate_task()))
    assert tick(spawn() + [idle_notice()])[1] == [{"kind": "subagent", "text": "Build skin A", "holdsTurn": False, "idle": True}]
    assert tick(spawn() + [idle_notice()] + send_message(at=112)) == ("done", [
        {"kind": "subagent", "text": "Build skin A", "holdsTurn": True, "idle": False}])


def test_an_idle_teammate_stopped_by_task_stop_leaves_the_list(lead):
    engine, reg, tick = lead
    engine.apply_event("s1", stop(teammate_task()))
    assert tick(spawn() + [idle_notice()] + task_stop("skin-a")) == ("done", [])


def test_a_completed_background_shell_holds_the_turn_until_the_lead_takes_it_up_beside_an_idle_teammate(lead):
    """A shell's completion is handed to the lead as its next prompt: the shell holds the turn until that turn starts
    (as before), and is gone from the next Stop. The idle teammate beside it holds nothing throughout."""
    engine, reg, tick = lead
    shell = {"id": "job1", "type": "shell", "status": "running", "command": "npm run test"}
    engine.apply_event("s1", stop(teammate_task(), shell))
    records = spawn() + shell_launch(at=103) + [idle_notice()]
    idle = {"kind": "subagent", "text": "Build skin A", "holdsTurn": False, "idle": True}
    assert tick(records)[1] == [idle, {"kind": "shell", "text": "npm run test", "holdsTurn": True, "idle": False}]
    records += [shell_completed(at=112)]
    assert tick(records) == ("done", [idle, {"kind": "shell", "text": "npm run test", "holdsTurn": True, "idle": False}])
    engine.apply_event("s1", hook("working"))
    assert tick(records) == ("working", [])
    engine.apply_event("s1", stop(teammate_task()))
    assert tick(records) == ("done", [idle])


def test_a_session_with_only_idle_teammates_holds_nothing(lead):
    engine, reg, tick = lead
    names = [f"skin-{n}" for n in "abcdefgh"]
    engine.apply_event("s1", stop(*(teammate_task(f"t{n}", f"Build {n}") for n in names)))
    records = sum((spawn(n, description=f"Build {n}", at=101 + i * 2) for i, n in enumerate(names)), [])
    state, work = tick(records + [idle_notice(n, at=118) for n in names])
    assert state == "done"
    assert len(work) == 8 and all(item["idle"] and not item["holdsTurn"] and item["kind"] == "subagent" for item in work)
    assert [item for item in work if item["holdsTurn"]] == []
