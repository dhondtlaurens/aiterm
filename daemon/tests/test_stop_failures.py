"""A Claude turn an API error ended (its StopFailure hook, in place of a Stop): what the session says stopped it, when
a usage limit it hit resets, as its transcript records that, and what clears it once the session works again."""
import json

import pytest

from aitermd.hook_events import parse_claude_hook
from aitermd.models import Frame, RawSession, StoppedOn
from aitermd.sessions import SessionRegistry
from aitermd.status import StatusEngine
from aitermd.stop_failures import limit_resets_at
from tests.test_slash_commands import IDLE, Clock, iso, write

T0 = 1_793_000_000.0
# When the limit in the records below resets: 26 Oct 2026, 13:20 in Brussels.
RESETS_AT = 1793017200
BASE = {"session_id": "c-4242", "cwd": "/wt"}


# What Claude Code 2.1.310 wrote as a turn hit the usage limit, and as it carried on by itself once the limit reset
# (a worker's transcript, 26 Oct 2026, trimmed to the fields AiTerm reads and with no path or branch of its own).
def limit_reached(at: float, resets_at: int | None = RESETS_AT) -> dict:
    info = {"status": "rejected", "rateLimitType": "five_hour", "overageStatus": "rejected", "isUsingOverage": False}
    return {"parentUuid": "648d2f48", "isSidechain": False, "type": "assistant", "uuid": "f49a312f", "timestamp": iso(at),
            "message": {"model": "<synthetic>", "role": "assistant", "stop_reason": "stop_sequence", "type": "message",
                        "content": [{"type": "text", "text": "You've hit your org's monthly spend limit · run /usage-credits "
                                                             "to ask your admin for a higher limit · your session limit "
                                                             "resets 1:20pm (Europe/Brussels)"}]},
            "apiError": "usage_limit_reached",
            "apiErrorParams": {"rate_limit_info": info if resets_at is None else {**info, "resetsAt": resets_at}},
            "error": "rate_limit", "isApiErrorMessage": True, "apiErrorStatus": 429, "sessionId": "c-4242"}


def notice(text: str, at: float) -> dict:
    return {"parentUuid": "f49a312f", "isSidechain": False, "type": "system", "subtype": "informational", "content": text,
            "isMeta": False, "timestamp": iso(at), "uuid": "8899e0fb", "level": "notice", "sessionId": "c-4242"}


def turn_duration(at: float) -> dict:
    return {"parentUuid": "8899e0fb", "isSidechain": False, "type": "system", "subtype": "turn_duration", "durationMs": 329669,
            "messageCount": 1578, "timestamp": iso(at), "uuid": "23d253f1", "isMeta": False, "sessionId": "c-4242"}


def auto_continuation(at: float) -> dict:
    return {"parentUuid": "ecffafa3", "isSidechain": False, "promptId": "8bb8ebdf", "type": "user", "isMeta": True,
            "message": {"role": "user", "content": "Your claude.ai usage limit has reset. Continue the task you were working on "
                                                   "when the limit was reached; do not repeat work that is already complete."},
            "uuid": "d8a03871", "timestamp": iso(at), "origin": {"kind": "auto-continuation"}, "promptSource": "system",
            "turnOrigin": "auto_continuation", "sessionId": "c-4242"}


def assistant(text: str, at: float) -> dict:
    return {"isSidechain": False, "type": "assistant", "timestamp": iso(at), "sessionId": "c-4242",
            "message": {"model": "claude-opus-5-5", "role": "assistant", "content": [{"type": "text", "text": text}]}}


def stop_failure(error: str | None = "rate_limit", **extra) -> dict:
    """A StopFailure as Claude Code 2.1.311 builds it: the session's common fields, the error, and the turn's last text."""
    body = {**BASE, "hook_event_name": "StopFailure", "transcript_path": "/p/c-4242.jsonl",
            "error_details": None, "last_assistant_message": "You've hit your org's monthly spend limit", **extra}
    if error is not None:
        body["error"] = error
    return body


# -- the hook ------------------------------------------------------------------------------------


@pytest.mark.parametrize("error,said", [("rate_limit", "rate_limit"), ("billing_error", "billing_error"),
                                        ("authentication_failed", "authentication_failed"), (None, "unknown"), ("", "unknown")])
def test_a_stop_failure_ends_the_turn_with_its_error(error, said):
    ev = parse_claude_hook(stop_failure(error))
    assert (ev.kind, ev.stop_error, ev.event_name, ev.transcript) == ("done", said, "StopFailure", "/p/c-4242.jsonl")


def test_a_plain_stop_carries_no_error():
    assert parse_claude_hook({**BASE, "hook_event_name": "Stop"}).stop_error is None


# -- the session ---------------------------------------------------------------------------------


class Tab:
    """A status engine over one Claude tab, `s1`, at work in a turn."""

    def __init__(self):
        self.clock = Clock(T0)
        self.registry = SessionRegistry()
        self.registry.apply_snapshot([RawSession("s1", "w1", 0, "claude", 4242, "", "/wt", {"aiterm_task": "t1"})])
        self.status = StatusEngine(self.registry, self.clock, monotonic=lambda: 500.0)
        self.post({**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "go"})

    def post(self, body: dict) -> list[str]:
        return self.status.apply_event("s1", parse_claude_hook(body))

    @property
    def session(self):
        return self.registry.get("s1")


@pytest.fixture
def tab():
    return Tab()


def test_a_turn_an_api_error_ended_is_done_and_says_what_stopped_it(tab):
    assert set(tab.post(stop_failure())) == {"s1"}
    assert (tab.session.state, tab.session.stopped_on) == ("done", StoppedOn("rate_limit"))
    assert tab.session.to_json()["stoppedOn"] == {"error": "rate_limit", "resetsAt": None}


@pytest.mark.parametrize("resumed", [
    {**BASE, "hook_event_name": "UserPromptSubmit", "prompt": "carry on"},
    {**BASE, "hook_event_name": "Stop"},
    {**BASE, "hook_event_name": "SessionStart", "source": "resume"},
])
def test_a_new_turn_a_clean_stop_or_another_conversation_clears_it(tab, resumed):
    tab.post(stop_failure())
    tab.post(resumed)
    assert tab.session.stopped_on is None


def test_the_session_file_saying_it_works_again_clears_it(tab):
    # Claude Code carried on by itself once the limit reset: no hook says so, its session file does.
    tab.post(stop_failure())
    tab.clock.now = T0 + 5
    assert tab.status.apply_claude_file_status("s1", "idle", T0 + 2) == []
    assert tab.session.stopped_on is not None, "idle while it waits for the reset"
    tab.status.apply_claude_file_status("s1", "busy", T0 + 1400)
    assert (tab.session.state, tab.session.stopped_on) == ("working", None)


def test_seeing_the_stopped_turn_keeps_what_stopped_it(tab):
    tab.post(stop_failure("billing_error"))
    tab.status.mark_seen("t1")
    assert (tab.session.state, tab.session.stopped_on) == ("idle", StoppedOn("billing_error"))


def test_another_process_in_the_tab_does_not_inherit_it(tab):
    tab.post(stop_failure())
    tab.registry.apply_snapshot([RawSession("s1", "w1", 0, "claude", 4243, "", "/wt", {"aiterm_task": "t1"})])
    assert tab.session.stopped_on is None


def test_the_same_process_keeps_it_across_snapshots(tab):
    tab.post(stop_failure())
    tab.registry.apply_snapshot([RawSession("s1", "w1", 0, "claude", 4242, "retitled", "/wt", {"aiterm_task": "t1"})])
    assert tab.session.stopped_on == StoppedOn("rate_limit")


def test_an_agent_that_exits_leaves_nothing_stopped(tab):
    tab.post(stop_failure())
    tab.status.agent_exited("s1")
    assert tab.session.stopped_on is None


# -- the transcript ------------------------------------------------------------------------------


def test_a_limit_resets_when_the_turns_last_record_says(tmp_path):
    path = tmp_path / "c.jsonl"
    write(path, assistant("Working on it.", T0 - 60), limit_reached(T0),
          notice("Usage limit reached · continuing automatically at 1:20pm · esc to cancel", T0), turn_duration(T0))
    assert limit_resets_at(str(path)) == RESETS_AT


@pytest.mark.parametrize("records", [
    # Not written yet: the turn's last record is the work before it.
    [assistant("Working on it.", T0)],
    # A limit that named no reset: none is made up.
    [limit_reached(T0, resets_at=None), turn_duration(T0)],
    # Claude Code carried on once it reset: that limit is over.
    [limit_reached(T0), turn_duration(T0), auto_continuation(T0 + 1400)],
    # An earlier turn's limit, and a turn since that ended otherwise.
    [limit_reached(T0), auto_continuation(T0 + 1400), assistant("Done.", T0 + 1500)],
])
def test_no_reset_is_read_where_the_turns_last_record_names_none(tmp_path, records):
    path = tmp_path / "c.jsonl"
    write(path, *records)
    assert limit_resets_at(str(path)) is None


def test_a_transcript_not_there_names_no_reset(tmp_path):
    assert limit_resets_at(str(tmp_path / "missing.jsonl")) is None


def test_a_record_still_being_written_is_passed_over(tmp_path):
    path = tmp_path / "c.jsonl"
    write(path, limit_reached(T0))
    with open(path, "a") as f:
        f.write('{"type": "system", "subtype": "turn_dur')
    assert limit_resets_at(str(path)) == RESETS_AT


# -- the service ---------------------------------------------------------------------------------


@pytest.fixture
async def stopped(make_service, tmp_path):
    """A started service with a Claude idle in a task window, its transcript named by its own hooks."""
    clock = Clock(T0)
    svc = make_service(clock=clock, monotonic=lambda: 500.0)
    await svc.start()
    _wid, sid = await svc.iterm.create_window("/wt", "x", {"aiterm_task": "t1"}, Frame(0, 0, 10, 10))
    (tmp_path / "claude-sessions").mkdir(exist_ok=True)
    (tmp_path / "claude-sessions" / "4242.json").write_text(json.dumps({
        "pid": 4242, "sessionId": "c-4242", "cwd": "/wt", "status": "idle", "version": "2.1.310"}))
    await svc.iterm.user_runs(sid, "claude", job_pid=4242)
    svc.iterm.screens[sid] = IDLE
    await svc.tick()
    transcript = tmp_path / "projects" / "c-4242.jsonl"
    write(transcript, assistant("Working on it.", T0 - 60))
    yield svc, sid, transcript, clock


async def test_a_tick_reads_when_the_limit_resets_from_the_transcript(stopped):
    svc, sid, transcript, clock = stopped
    await svc.hook_router.handle_hook("/hook/claude", stop_failure(transcript_path=str(transcript)))
    assert svc.registry.get(sid).stopped_on == StoppedOn("rate_limit")
    # Claude Code writes in batches: its record of the limit can reach the file after the hook.
    clock.now = T0 + 1
    await svc.tick()
    assert svc.registry.get(sid).stopped_on == StoppedOn("rate_limit")
    write(transcript, limit_reached(T0), turn_duration(T0))
    clock.now = T0 + 2
    await svc.tick()
    assert svc.registry.get(sid).stopped_on == StoppedOn("rate_limit", RESETS_AT)
    [listed] = [s for s in svc.registry.all() if s.session_id == sid]
    assert listed.to_json()["stoppedOn"] == {"error": "rate_limit", "resetsAt": RESETS_AT}


async def test_a_billing_failure_has_no_reset_to_read(stopped):
    svc, sid, transcript, clock = stopped
    write(transcript, limit_reached(T0))
    await svc.hook_router.handle_hook("/hook/claude", stop_failure("billing_error", transcript_path=str(transcript)))
    clock.now = T0 + 1
    await svc.tick()
    assert svc.registry.get(sid).stopped_on == StoppedOn("billing_error")


async def test_a_reset_not_written_soon_after_the_stop_is_not_looked_for_again(stopped):
    from aitermd.stop_failures import RESET_READ_SECONDS

    svc, sid, transcript, clock = stopped
    await svc.hook_router.handle_hook("/hook/claude", stop_failure(transcript_path=str(transcript)))
    write(transcript, limit_reached(T0))
    clock.now = T0 + RESET_READ_SECONDS + 1
    await svc.tick()
    assert svc.registry.get(sid).stopped_on == StoppedOn("rate_limit")
