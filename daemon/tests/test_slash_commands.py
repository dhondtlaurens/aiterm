import asyncio
import json
from datetime import UTC, datetime

import pytest

from aitermd import delivery
from aitermd.models import RawSession, SlashCommand
from aitermd.sessions import SessionRegistry
from aitermd.slash_commands import KEPT, UNSEEN_SECONDS, SlashCommands, TranscriptReader, settle
from tests.conftest import FRAME, call as rpc_call

# When AiTerm typed the command, on the wall clock the transcript's timestamps share.
T0 = 1_793_000_000.0


def iso(at: float) -> str:
    """A transcript timestamp: UTC, to the millisecond, as Claude Code writes it."""
    return datetime.fromtimestamp(at, UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


# A Claude transcript's records around the slash commands typed into it, as Claude Code 2.1.310 writes them (taken
# from a session driven live on 26 Oct 2026, its text shortened).
def caveat(at: float, prompt: str = "p1") -> dict:
    return {"isSidechain": False, "promptId": prompt, "type": "user", "isMeta": True, "timestamp": iso(at),
            "message": {"role": "user", "content": "<local-command-caveat>The command below was run directly in Claude Code, "
                                                   "not sent to you as a request.</local-command-caveat>"}}


def ran(name: str, args: str, at: float, prompt: str = "p1", sidechain: bool = False) -> dict:
    """A local command Claude Code ran, by its name and arguments."""
    return {"isSidechain": sidechain, "promptId": prompt, "type": "user", "timestamp": iso(at), "message": {"role": "user", "content":
            f"<command-name>/{name}</command-name>\n            <command-message>{name}</command-message>\n"
            f"            <command-args>{args}</command-args>"}}


def output(text: str, at: float, prompt: str = "p1") -> dict:
    return {"isSidechain": False, "promptId": prompt, "type": "user", "timestamp": iso(at),
            "message": {"role": "user", "content": f"<local-command-stdout>{text}</local-command-stdout>"}}


def prompted(name: str, at: float, prompt: str = "p2") -> dict:
    """A prompt command (a custom command, a skill) Claude Code ran: its name, then its prompt as a meta message."""
    return {"isSidechain": False, "promptId": prompt, "type": "user", "timestamp": iso(at),
            "message": {"role": "user", "content": f"<command-message>{name}</command-message>\n<command-name>/{name}</command-name>"}}


def queue(operation: str, at: float, content: str | None = None, **more) -> dict:
    record = {"type": "queue-operation", "operation": operation, "timestamp": iso(at), "sessionId": "s", **more}
    return record if content is None else {**record, "content": content}


# Claude Code 2.1.306 wrote a local command and its output as system records.
def system_ran(name: str, args: str, at: float) -> dict:
    return {"isSidechain": False, "type": "system", "subtype": "local_command", "level": "info", "isMeta": False, "timestamp": iso(at),
            "content": f"<command-name>/{name}</command-name>\n            <command-message>{name}</command-message>\n"
                       f"            <command-args>{args}</command-args>"}


def system_output(text: str, at: float, command: str) -> dict:
    return {"isSidechain": False, "type": "system", "subtype": "local_command", "level": "info", "isMeta": False, "timestamp": iso(at),
            "content": f"<local-command-stdout>{text}</local-command-stdout>", "commandRun": {"command": command, "args": ""}}


ASSISTANT = {"type": "assistant", "isSidechain": False, "timestamp": iso(T0 + 2), "effort": "max",
             "message": {"model": "claude-opus-5-5", "role": "assistant", "content": [{"type": "text", "text": "Done."}]}}
EFFORT_OUT = "Set effort level to high (saved as your default for new sessions): Comprehensive implementation"


def write(path, *records, tail=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write("".join(json.dumps(r) + "\n" for r in records) + tail)
    return str(path)


def read(path, *records, start=0):
    """What a fresh reader keeps of a transcript holding `records`, read from byte `start`."""
    write(path, *records)
    return TranscriptReader().read_all({str(path): start})[str(path)]


def typed(text: str) -> SlashCommand:
    return SlashCommand(text, T0)


# -- what the records say ---------------------------------------------------------------------------------------------

def test_a_command_its_transcript_shows_run_reads_ran_with_its_output(tmp_path):
    records = read(tmp_path / "t.jsonl", ASSISTANT, caveat(T0 + 1), ran("effort", "high", T0 + 1), output(EFFORT_OUT, T0 + 1))
    command = settle(typed("/effort high"), records, T0 + 2)
    assert (command.state, command.seen_at, command.output) == ("ran", pytest.approx(T0 + 1), EFFORT_OUT)


def test_a_command_queued_while_its_session_works_reads_queued_until_it_runs(tmp_path):
    path = tmp_path / "t.jsonl"
    queued = settle(typed("/probe"), read(path, ASSISTANT, queue("enqueue", T0 + 1, "/probe")), T0 + 600)
    # Still queued ten minutes on: a queue holds a command until the turn ends, however long that takes.
    assert (queued.state, queued.seen_at) == ("queued", pytest.approx(T0 + 1))
    records = read(path, queue("dequeue", T0 + 700), prompted("probe", T0 + 700.04))
    assert settle(queued, records, T0 + 701).state == "ran"


def test_a_command_with_nothing_in_its_transcript_is_delivered_then_unknown(tmp_path):
    # An /effort run mid-turn takes effect and writes nothing, and one waiting on a dialog nothing yet: no record is not
    # a sign it did not run.
    records = read(tmp_path / "t.jsonl", ASSISTANT)
    assert settle(typed("/effort high"), records, T0 + 5).state == "delivered"
    assert settle(typed("/effort high"), records, T0 + UNSEEN_SECONDS).state == "unknown"


def test_a_command_whose_transcript_cannot_be_read_is_unknown_at_once():
    command = settle(typed("/effort high"), None, T0 + 1)
    assert (command.state, command.seen_at, command.output) == ("unknown", None, None)


def test_a_record_from_before_it_was_typed_is_not_its_own(tmp_path):
    records = read(tmp_path / "t.jsonl", ran("effort", "high", T0 - 30), output(EFFORT_OUT, T0 - 30),
                   queue("enqueue", T0 - 20, "/effort high"))
    assert settle(typed("/effort high"), records, T0 + 1).state == "delivered"


@pytest.mark.parametrize("moved", [queue("dequeue", T0 + 40), queue("remove", T0 + 40, "/compact", reason="absorbed_mid_turn")])
def test_a_command_the_queue_moved_past_without_running_it_is_unknown(tmp_path, moved):
    # A dequeue names nothing, so one after it may have been another's; a remove names it but did not run it.
    records = read(tmp_path / "t.jsonl", queue("enqueue", T0 + 1, "/compact"), moved)
    assert settle(typed("/compact"), records, T0 + 41).state == "unknown"


def test_only_its_own_name_and_arguments_count(tmp_path):
    records = read(tmp_path / "t.jsonl", ran("effort", "low", T0 + 1), ran("model", "claude-opus-5-5", T0 + 2),
                   queue("enqueue", T0 + 3, "/effort  max "))
    assert settle(typed("/effort high"), records, T0 + 4).state == "delivered"
    assert settle(typed("/model claude-opus-5-5"), records, T0 + 4).state == "ran"
    assert settle(typed("/effort max"), records, T0 + 4).state == "queued", "spacing aside, the text is the same"


def test_its_output_is_the_one_its_own_prompt_carries_on_one_line(tmp_path):
    long = "Invalid argument: turbo.\nValid options are: " + "low, " * 80
    records = read(tmp_path / "t.jsonl", ran("effort", "turbo", T0 + 1, prompt="p1"), output("not mine", T0 + 1, prompt="p0"),
                   output(long, T0 + 1, prompt="p1"))
    command = settle(typed("/effort turbo"), records, T0 + 2)
    assert command.output == "Invalid argument: turbo."
    alone = settle(typed("/effort turbo"), read(tmp_path / "u.jsonl", ran("effort", "turbo", T0 + 1), output("x" * 500, T0 + 1)), T0 + 2)
    assert alone.output == "x" * 200


def test_a_prompt_command_ran_with_no_output(tmp_path):
    command = settle(typed("/probe"), read(tmp_path / "t.jsonl", prompted("probe", T0 + 1)), T0 + 2)
    assert (command.state, command.output) == ("ran", None)


def test_an_older_claude_codes_system_records_count(tmp_path):
    kept = "Kept model as `Opus 5.5 (default)`"
    records = read(tmp_path / "t.jsonl", system_ran("model", "", T0 + 1), system_output(kept, T0 + 1, "model"))
    command = settle(typed("/model"), records, T0 + 2)
    assert (command.state, command.output) == ("ran", kept)


def test_a_subagents_record_is_not_the_sessions(tmp_path):
    records = read(tmp_path / "t.jsonl", ran("effort", "high", T0 + 1, sidechain=True))
    assert settle(typed("/effort high"), records, T0 + 2).state == "delivered"


def test_a_command_that_ran_stays_as_it_ran(tmp_path):
    done = settle(typed("/effort high"), read(tmp_path / "t.jsonl", ran("effort", "high", T0 + 1), output(EFFORT_OUT, T0 + 1)), T0 + 2)
    assert settle(done, (), T0 + 3600) == done
    assert settle(done, None, T0 + 3600) == done


# -- reading the transcript -------------------------------------------------------------------------------------------

def test_the_reader_keeps_only_what_says_something_of_a_typed_command(tmp_path):
    tool_result = {"type": "user", "isSidechain": False, "timestamp": iso(T0 + 1), "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "<command-name>/effort</command-name><command-args>high</command-args>"}]}}
    said = {"type": "user", "isSidechain": False, "timestamp": iso(T0 + 1),
            "message": {"role": "user", "content": "Explain <command-name>/effort</command-name> to me"}}
    records = read(tmp_path / "t.jsonl", ASSISTANT, tool_result, said, caveat(T0 + 1), queue("enqueue", T0 + 1, "Operator: carry on"),
                   queue("enqueue", T0 + 1, "/probe"), queue("dequeue", T0 + 2), ran("effort", "high", T0 + 3), output(EFFORT_OUT, T0 + 3))
    assert [(r.kind, r.text) for r in records] == [
        ("enqueue", "/probe"), ("dequeue", None), ("command", "/effort high"), ("output", EFFORT_OUT)]


def test_the_reader_reads_on_from_where_the_command_was_typed(tmp_path):
    path = tmp_path / "t.jsonl"
    write(path, ran("effort", "high", T0 - 30))
    start = path.stat().st_size
    reader = TranscriptReader()
    assert reader.read_all({str(path): start}) == {str(path): ()}
    write(path, queue("enqueue", T0 + 1, "/probe"), tail='{"type": "queue-operation", "operation": "deq')
    assert [r.kind for r in reader.read_all({str(path): start})[str(path)]] == ["enqueue"]
    write(path, tail=f'ueue", "timestamp": "{iso(T0 + 2)}"}}\n')
    assert [r.kind for r in reader.read_all({str(path): start})[str(path)]] == ["enqueue", "dequeue"]


def test_a_transcript_not_written_yet_has_no_records_and_an_unreadable_one_none(tmp_path):
    (tmp_path / "dir.jsonl").mkdir()
    reader = TranscriptReader()
    assert reader.read_all({str(tmp_path / "new.jsonl"): 0, str(tmp_path / "dir.jsonl"): 0}) == {
        str(tmp_path / "new.jsonl"): (), str(tmp_path / "dir.jsonl"): None}


def test_a_rewritten_transcript_is_read_again_from_its_start(tmp_path):
    path = tmp_path / "t.jsonl"
    reader = TranscriptReader()
    write(path, ASSISTANT, queue("enqueue", T0 + 1, "/probe"))
    assert len(reader.read_all({str(path): 0})[str(path)]) == 1
    path.unlink()
    write(path, ran("probe", "", T0 + 2))
    assert [r.kind for r in reader.read_all({str(path): 0})[str(path)]] == ["command"]


# -- following what AiTerm typed --------------------------------------------------------------------------------------

def test_only_a_slash_command_into_a_claude_tab_is_followed(tmp_path):
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("s1", "w1", 0, "claude", 101, "", "/wt"), RawSession("s2", "w1", 1, "codex", 102, "", "/wt")])
    commands = SlashCommands(registry, lambda: T0)
    assert commands.stamp("s1", "Run the tests.") is None
    assert commands.stamp("s2", "/model gpt-6-astra") is None, "a Codex transcript records commands its own way"
    assert commands.stamp("s3", "/effort high") is None
    assert commands.stamp("s1", "  /effort high") == SlashCommand("/effort high", T0)
    # Too long to paste, it goes through a message file, and what is typed is the line that names the file.
    assert commands.stamp("s1", "/superpowers:brainstorming " + "x" * delivery.MESSAGE_FILE_THRESHOLD) is None


def test_a_command_is_followed_from_where_its_transcript_ended_when_it_was_typed(tmp_path):
    registry = SessionRegistry()
    registry.apply_snapshot([RawSession("s1", "w1", 0, "claude", 101, "", "/wt")])
    path = write(tmp_path / "t.jsonl", ASSISTANT)
    registry.set_transcript("s1", path)
    command = SlashCommands(registry, lambda: T0).stamp("s1", "/effort high")
    assert command is not None and command.start == (tmp_path / "t.jsonl").stat().st_size


class Clock:
    """A wall clock a test moves by hand."""

    def __init__(self, now: float):
        self.now = now

    def __call__(self) -> float:
        return self.now


IDLE = "────────────────\n❯\x20\n────────────────\n  ? for shortcuts"


@pytest.fixture
async def worker(make_service, monkeypatch, tmp_path):
    """A started service with an app attached and a Claude 2.1.301 idle in a task window, its delivery checked and its
    transcript named by its own hooks: the service, the Claude tab's session id, its transcript, a `call` that sends one
    request and returns its reply, and the wall clock, which a test moves."""
    monkeypatch.setattr(delivery, "SUBMIT_DELAY", 0)
    clock = Clock(T0)
    svc = make_service(delivery_policy=lambda: {"claude": ("auto", "2.1.301")}, clock=clock, monotonic=lambda: 500.0)
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    ids = iter(range(1, 1000))

    async def call(method, params=None):
        return await rpc_call(r, w, method, params, id_=next(ids))

    wid = (await call("window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = svc.iterm.windows[wid]["sessions"][0]
    (tmp_path / "claude-sessions").mkdir()
    (tmp_path / "claude-sessions" / "4242.json").write_text(json.dumps({
        "pid": 4242, "sessionId": "c-4242", "cwd": "/wt", "status": "idle", "version": "2.1.301"}))
    await svc.iterm.user_runs(sid, "claude", job_pid=4242)
    await svc.tick()
    transcript = tmp_path / "projects" / "c-4242.jsonl"
    write(transcript, ASSISTANT)
    await svc.hook_router.handle_hook("/hook/claude", {"hook_event_name": "Stop", "session_id": "c-4242", "cwd": "/wt",
                                                       "transcript_path": str(transcript)})
    svc.iterm.screens[sid] = IDLE
    yield svc, sid, transcript, call, clock
    w.close()


def followed(svc, sid) -> list[tuple]:
    return [(c.text, c.state, c.output) for c in svc.registry.get(sid).slash_commands]


async def test_a_slash_command_typed_into_a_claude_worker_is_followed_until_it_ran(worker):
    svc, sid, transcript, call, clock = worker
    assert (await call("session.deliver", {"sessionId": sid, "text": "/effort high", "ownership": 1}))["result"]["result"] == "delivered"
    [listed] = [s for s in (await call("sessions.list"))["result"] if s["sessionId"] == sid]
    assert listed["slashCommands"] == [{"text": "/effort high", "state": "delivered", "deliveredAt": T0, "seenAt": None, "output": None}]
    write(transcript, caveat(T0 + 1), ran("effort", "high", T0 + 1), output(EFFORT_OUT, T0 + 1))
    clock.now = T0 + 2
    await svc.tick()
    assert followed(svc, sid) == [("/effort high", "ran", EFFORT_OUT)]
    assert svc.registry.get(sid).slash_commands[0].seen_at == pytest.approx(T0 + 1)


async def test_a_slash_command_waiting_its_turn_is_queued(worker):
    svc, sid, transcript, call, clock = worker
    await call("session.deliver", {"sessionId": sid, "text": "/compact", "ownership": 1})
    write(transcript, queue("enqueue", T0 + 1, "/compact"))
    clock.now = T0 + 600
    await svc.tick()
    assert followed(svc, sid) == [("/compact", "queued", None)]


async def test_a_slash_command_its_transcript_never_shows_is_unknown_until_it_does(worker):
    svc, sid, transcript, call, clock = worker
    await call("session.deliver", {"sessionId": sid, "text": "/effort high", "ownership": 1})
    clock.now = T0 + 10
    await svc.tick()
    assert followed(svc, sid) == [("/effort high", "delivered", None)]
    clock.now = T0 + UNSEEN_SECONDS
    await svc.tick()
    assert followed(svc, sid) == [("/effort high", "unknown", None)]
    # The person answered the dialog it opened: it ran after all.
    write(transcript, ran("effort", "high", T0 + 150), output(EFFORT_OUT, T0 + 150))
    clock.now = T0 + 151
    await svc.tick()
    assert followed(svc, sid) == [("/effort high", "ran", EFFORT_OUT)]


async def test_a_worker_whose_transcript_is_not_named_has_its_command_unknown(worker):
    svc, sid, transcript, call, clock = worker
    svc.registry.get(sid).transcript = None
    await call("session.deliver", {"sessionId": sid, "text": "/effort high", "ownership": 1})
    await svc.tick()
    assert followed(svc, sid) == [("/effort high", "unknown", None)]


async def test_a_model_delivered_but_not_confirmed_shows_nothing_new(worker):
    svc, sid, transcript, call, clock = worker
    await svc.hook_router.handle_hook("/statusline", {"session_id": "c-4242", "cwd": "/wt", "model": {"id": "claude-fable-5-1[1m]"},
                                                      "effort": {"level": "max"}})
    await call("session.deliver", {"sessionId": sid, "text": "/model claude-opus-5-5", "ownership": 1})
    clock.now = T0 + 5
    await svc.tick()
    session = svc.registry.get(sid)
    assert (session.model, session.reasoning) == ("claude-fable-5-1[1m]", "max")
    assert followed(svc, sid) == [("/model claude-opus-5-5", "delivered", None)]


async def test_only_what_was_typed_and_entered_is_followed(worker):
    svc, sid, transcript, call, clock = worker
    await call("session.deliver", {"sessionId": sid, "text": "Run the tests.", "ownership": 1})
    svc.iterm.screens[sid] = " Do you want to proceed?\n ❯ 1. Yes\n   2. No"
    assert (await call("session.deliver", {"sessionId": sid, "text": "/effort high", "ownership": 1}))["result"]["result"] == "refused"
    assert followed(svc, sid) == []


async def test_a_session_keeps_its_last_commands_and_one_typed_again_replaces_its_earlier_self(worker):
    svc, sid, transcript, call, clock = worker
    for text in ("/effort high", "/model claude-opus-5-5", "/compact", "/effort low", "/model claude-opus-5-5"):
        await call("session.deliver", {"sessionId": sid, "text": text, "ownership": 1})
    assert [text for text, _, _ in followed(svc, sid)] == ["/compact", "/effort low", "/model claude-opus-5-5"][-KEPT:]
