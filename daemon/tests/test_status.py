import pytest
from aitermd import status
from aitermd.claude_subagents import TranscriptTail
from aitermd.hook_events import HookEvent
from aitermd.models import BackgroundJob, RawSession
from aitermd.sessions import SessionRegistry
from aitermd.status import StatusEngine


class Clock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


# When a session file was written, for a test about what it says rather than about its age: after
# any hook the engine's clock has stamped.
FRESH = 1000.0


def hook(kind, subagent_id=None, **fields):
    """A hook that reports `kind`: the engine reads only what it says of the turn, not whose it is."""
    return HookEvent("claude", kind, None, None, None, subagent_id, **fields)


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def eng(clock):
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("s1", "w1", 0, "claude", 1, "", "/x", {"aiterm_task": "t1"}),
                        RawSession("s2", "w1", 1, "codex", 2, "", "/x", {})])
    return StatusEngine(reg, clock), reg


@pytest.mark.parametrize("sequence,expected", [
    (["working"], "working"),
    (["working", "needsInput"], "needsInput"),
    (["working", "needsInput", "working"], "working"),
    (["working", "done"], "done"),
    (["working", "needsInput", "done"], "done"),
])
def test_hook_signal_transitions(eng, sequence, expected):
    engine, reg = eng
    for kind in sequence:
        engine.apply_event("s1", hook(kind))
    assert reg.get("s1").state == expected


@pytest.mark.parametrize("field,value", [("model", "claude-opus-5"), ("reasoning", "high")])
def test_a_metadata_signal_sets_its_field_without_touching_state(eng, field, value):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    assert engine.apply_metadata("s1", **{field: value}) == ["s1"]
    assert getattr(reg.get("s1"), field) == value and reg.get("s1").state == "working"
    assert engine.apply_metadata("s1", **{field: value}) == []


def test_claude_file_status_mapping(eng):
    engine, reg = eng
    assert engine.apply_claude_file_status("s1", "idle", FRESH) == []          # idle at start: nothing
    engine.apply_claude_file_status("s1", "thinking", FRESH)
    assert reg.get("s1").state == "working"
    engine.apply_claude_file_status("s1", "waiting", FRESH)
    assert reg.get("s1").state == "needsInput"
    engine.apply_claude_file_status("s1", "busy", FRESH)
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "done"


@pytest.mark.parametrize("start_state,file_status,expected", [
    ("needsInput", "busy", "working"),
    ("needsInput", "thinking", "working"),
    ("needsInput", "running", "working"),
    ("needsInput", "waiting", "needsInput"),
    ("needsInput", "idle", "done"),
    ("working", "idle", "done"),
])
def test_claude_file_status_tracks_resume_after_input(eng, start_state, file_status, expected):
    engine, reg = eng
    reg.set_state("s1", start_state)
    engine.apply_claude_file_status("s1", file_status, FRESH)
    assert reg.get("s1").state == expected


def test_codex_title_spinner(eng):
    engine, reg = eng
    engine.apply_codex_title("s2", "⠋ acme-web")
    assert reg.get("s2").state == "working"
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "done"
    assert engine.apply_codex_title("s2", "acme-web") == []


def test_codex_title_without_spinner_waits_for_background_subagent(eng):
    engine, reg = eng
    engine.apply_codex_title("s2", "⠋ acme-web")
    engine.apply_event("s2", hook("subagentStart", "child-1"))
    engine.apply_event("s2", hook("subagentStart", "child-2"))
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "working"
    engine.apply_event("s2", hook("subagentStop", "child-1"))
    assert reg.get("s2").state == "working"
    engine.apply_event("s2", hook("subagentStop", "child-2"))
    assert reg.get("s2").state == "done"


def test_claude_idle_file_waits_for_background_subagent(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "working"
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "done"


def test_a_new_prompt_is_not_completed_by_the_previous_turns_deferred_done(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("working"))  # the next prompt, before the child reports back
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "working"


def test_session_start_forgets_a_subagent_whose_stop_was_lost(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "lost"))
    engine.apply_event("s1", hook("sessionStart"))
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "done"


def test_a_replaced_process_forgets_the_previous_turns_subagents(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "lost"))
    engine.apply_event("s1", hook("done"))
    engine.reset_turn("s1")
    engine.apply_event("s1", hook("working"))
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "done"
    engine.apply_event("s1", hook("subagentStop", "lost"))
    assert reg.get("s1").state == "done"


@pytest.mark.parametrize("start_state", ["working", "needsInput", "done"])
def test_an_unknown_claude_file_status_is_ignored(eng, start_state):
    engine, reg = eng
    reg.set_state("s1", start_state)
    assert engine.apply_claude_file_status("s1", "compacting", FRESH) == []
    assert reg.get("s1").state == start_state


def test_needs_input_wins_over_background_subagent_completion(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("needsInput"))
    engine.apply_event("s1", hook("done"))
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "needsInput"


def test_claude_idle_file_does_not_hide_needs_input_while_child_runs(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("needsInput"))
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "needsInput"


def test_codex_spinner_restores_working_after_input(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("needsInput"))
    engine.apply_codex_title("s2", "⠋ acme-web")
    assert reg.get("s2").state == "working"


def test_codex_title_without_spinner_keeps_needs_input(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("needsInput"))
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "needsInput"


def test_mark_seen_and_agent_exit(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("done"))
    assert engine.mark_seen("t1") == ["s1"] and reg.get("s1").state == "idle"
    engine.apply_event("s2", hook("needsInput"))
    assert engine.agent_exited("s2") == ["s2"] and reg.get("s2").state == "idle"


def test_unknown_session_is_ignored(eng):
    engine, _ = eng
    assert engine.apply_event("nope", hook("working")) == []


def test_context_signal_stays_with_its_provider_without_touching_state(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    assert engine.apply_metadata("s1", context=42) == ["s1"]
    assert reg.get("s1").context_percent == 42 and reg.get("s1").state == "working"
    assert reg.get("s2").context_percent is None and reg.get("s2").state == "idle"
    assert engine.apply_metadata("s1", context=42) == []


def test_context_signal_replaces_the_tasks_value_when_a_tab_rereports_the_same_number():
    reg = SessionRegistry()
    reg.apply_snapshot([
        RawSession("a", "w1", 0, "claude", 1, "", "/x", {"aiterm_task": "t1"}),
        RawSession("b", "w1", 1, "claude", 2, "", "/x", {}),
    ])
    reg.set_context("a", 42)
    reg.set_context("b", 18)
    engine = StatusEngine(reg, Clock())

    assert engine.apply_metadata("b", context=18) == ["a"]
    assert [session.context_percent for session in reg.for_task("t1")] == [18, 18]
    assert engine.apply_metadata("b", context=18) == []


@pytest.mark.parametrize("before", ["idle", "done", "working"])
def test_a_closed_prompt_restores_the_state_it_interrupted(eng, before):
    engine, reg = eng
    reg.set_state("s1", before)
    assert engine.apply_event("s1", hook("promptStart")) == ["s1"]
    assert reg.get("s1").state == "needsInput"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == before


def test_a_closed_prompt_keeps_the_completion_a_background_child_holds(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "working"
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "done"


def test_a_prompt_opened_over_another_restores_the_state_before_the_first(eng):
    engine, reg = eng
    reg.set_state("s1", "done")
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("promptEnd"))
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "done"


def test_a_nested_prompt_closing_leaves_the_outer_one_visible(eng):
    engine, reg = eng
    reg.set_state("s1", "working")
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("promptStart"))
    assert engine.apply_event("s1", hook("promptEnd")) == []
    assert reg.get("s1").state == "needsInput", "the first prompt is still open"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "working"


def test_a_completion_deferred_during_a_prompt_ends_the_turn_the_prompt_restores(eng):
    """The done a child defers is not a hook that says what the turn is doing now: the turn is
    still working, so the prompt keeps what it interrupted and the last child completes it."""
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "needsInput", "the open prompt stays visible"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "done"


def test_a_prompt_closing_before_the_deferred_completion_lands_restores_working(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "working"
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "done"


def test_a_prompt_end_without_its_start_changes_nothing(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("needsInput"))
    assert engine.apply_event("s1", hook("promptEnd")) == []
    assert reg.get("s1").state == "needsInput"


def test_a_hook_during_a_prompt_supersedes_the_state_it_interrupted(eng):
    engine, reg = eng
    reg.set_state("s1", "working")
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("done"))
    assert engine.apply_event("s1", hook("promptEnd")) == []
    assert reg.get("s1").state == "done"


@pytest.mark.parametrize("kind,file_status", [
    ("needsInput", "busy"),     # a permission prompt, over the file of the turn it interrupted
    ("working", "idle"),        # a new prompt, over the file of the turn before
    ("done", "busy"),           # the end of the turn, before Claude rewrites its file
])
def test_a_session_file_older_than_the_last_hook_does_not_override_it(eng, clock, kind, file_status):
    engine, reg = eng
    engine.apply_event("s1", hook(kind))
    assert engine.apply_claude_file_status("s1", file_status, clock.now - 0.5) == []
    assert engine.apply_claude_file_status("s1", file_status, clock.now) == []
    assert reg.get("s1").state == kind


def test_a_session_file_written_after_the_last_hook_still_moves_the_row(eng, clock):
    engine, reg = eng
    engine.apply_event("s1", hook("needsInput"))
    # The prompt was answered: Claude marks its file busy again and no hook says so.
    assert engine.apply_claude_file_status("s1", "busy", clock.now + 0.5) == ["s1"]
    assert reg.get("s1").state == "working"


def test_a_codex_prompt_is_not_ended_before_its_spinner_first_appears(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("working"))
    assert engine.apply_codex_title("s2", "acme-web") == []
    assert reg.get("s2").state == "working"
    engine.apply_codex_title("s2", "⠋ acme-web")
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "done"


def test_the_previous_turns_spinner_does_not_end_the_next_prompt(eng):
    engine, reg = eng
    engine.apply_codex_title("s2", "⠋ acme-web")
    engine.apply_codex_title("s2", "acme-web")
    engine.apply_event("s2", hook("working"))
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "working"


def test_a_spinner_after_an_answered_prompt_lets_its_absence_end_the_turn(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("working"))
    engine.apply_event("s2", hook("needsInput"))
    engine.apply_codex_title("s2", "⠋ acme-web")
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "done"


def test_a_child_finishing_during_a_prompt_completes_the_turn_the_prompt_restores(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "needsInput", "the open prompt stays visible"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "done"


@pytest.mark.parametrize("before", ["idle", "done"])
def test_a_child_starting_during_a_prompt_leaves_the_turn_working_once_it_closes(eng, before):
    engine, reg = eng
    reg.set_state("s1", before)
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    assert reg.get("s1").state == "needsInput", "the open prompt stays visible"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "working"


def test_a_done_seen_during_a_prompt_is_not_restored_unseen(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("done"))
    engine.apply_event("s1", hook("promptStart"))
    assert engine.mark_seen("t1") == [], "the prompt is still what the row shows"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "idle"


# -- a Claude subagent that died without SubagentStop -------------------------------------------

TRANSCRIPT = "/p/sess/subagents/agent-c1.jsonl"


def _claude_engine(monotonic):
    """A Claude tab whose turn ended while child `c1` runs in the background: its Stop is deferred.
    The child started at wall-clock 100; its transcript quiet window runs on `monotonic`."""
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("s1", "w1", 0, "claude", 1, "", "/x", {"aiterm_task": "t1"})])
    wall = Clock()
    eng = StatusEngine(reg, wall, monotonic=monotonic)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c1", subagent_transcript=TRANSCRIPT))
    eng.apply_event("s1", hook("done"))
    assert reg.get("s1").state == "working"
    return eng, reg, wall


def _tail(ended=False, written_at=200.0, size=10, ended_at=None):
    """A transcript as read: its end, by default, written at `written_at`."""
    ended_at = ended_at if ended_at is not None else written_at if ended else None
    return TranscriptTail(stamp=(int(written_at * 1e9), size), written_at=written_at, ended_at=ended_at)


def test_every_counted_childs_transcript_is_read(clock):
    # Its turn deferred or under way: what shows the child still at work (`subagents_written_at`).
    eng, reg, _ = _claude_engine(clock)
    assert eng.subagent_transcripts() == {TRANSCRIPT}
    eng.apply_event("s1", hook("working"))
    assert eng.subagent_transcripts() == {TRANSCRIPT}
    eng.apply_event("s1", hook("subagentStart", "c2"))   # no transcript to read
    assert eng.subagent_transcripts() == {TRANSCRIPT}


def test_a_child_whose_transcript_ends_interrupted_releases_the_deferred_done(clock):
    eng, reg, _ = _claude_engine(clock)
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)}) == ["s1"]
    assert reg.get("s1").state == "done"
    assert eng.subagent_transcripts() == set()


def test_a_quiet_child_past_the_window_releases_it(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.release_dead_subagents({TRANSCRIPT: _tail()})     # first seen: the window starts
    clock.now += status.SUBAGENT_QUIET_SECONDS - 1
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []
    clock.now += 1
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == ["s1"]
    assert reg.get("s1").state == "done"


def test_a_quiet_child_of_a_turn_under_way_is_left_to_the_turns_stop(clock):
    # Neither deferred nor stopped: the turn's Stop says whether it still runs.
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    eng.release_dead_subagents({TRANSCRIPT: _tail()})
    clock.now += 10 * status.SUBAGENT_QUIET_SECONDS
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []
    assert eng.turn("s1").children and reg.get("s1").state == "working"
    # Stopped, with nothing in its transcript to show the run over: quiet as long after its stop, it is taken for dead.
    eng.apply_event("s1", hook("subagentStop", "c1"))
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []
    clock.now += status.SUBAGENT_QUIET_SECONDS
    eng.release_dead_subagents({TRANSCRIPT: _tail()})
    assert not eng.turn("s1").children


def test_a_childs_quiet_counts_from_the_stop_that_leaves_the_turn_waiting_on_it(clock):
    # Quiet while its parent worked is no sign of its death; nor does the session file, saying on every tick that the
    # turn ended, begin the window again.
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    eng.release_dead_subagents({TRANSCRIPT: _tail()})
    clock.now += 10 * status.SUBAGENT_QUIET_SECONDS
    eng.apply_event("s1", hook("done", running_subagents=frozenset({"c1"})))
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []
    clock.now += status.SUBAGENT_QUIET_SECONDS - 1
    eng.apply_claude_file_status("s1", "idle", FRESH)
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []
    clock.now += 1
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == ["s1"]
    assert reg.get("s1").state == "done"


def test_the_quiet_window_ignores_the_wall_clock(clock):
    # A laptop that slept, or an NTP step, must not make a live child look quiet.
    eng, reg, wall = _claude_engine(clock)
    eng.release_dead_subagents({TRANSCRIPT: _tail()})
    wall.now += 10 * status.SUBAGENT_QUIET_SECONDS
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []


def test_a_child_still_being_written_keeps_the_row_working(clock):
    eng, reg, _ = _claude_engine(clock)
    for size in range(1, 5):
        eng.release_dead_subagents({TRANSCRIPT: _tail(size=size)})
        clock.now += status.SUBAGENT_QUIET_SECONDS - 1
    assert reg.get("s1").state == "working"


def test_a_missing_transcript_keeps_it_working(clock):
    eng, reg, _ = _claude_engine(clock)
    assert eng.release_dead_subagents({}) == []
    clock.now += 10 * status.SUBAGENT_QUIET_SECONDS
    assert eng.release_dead_subagents({}) == []
    assert reg.get("s1").state == "working"


def test_a_late_real_subagent_stop_after_the_backstop_is_harmless(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    eng.mark_seen("t1")
    assert eng.apply_event("s1", hook("subagentStop", "c1")) == []
    assert reg.get("s1").state == "idle"


def test_a_resent_subagent_start_re_adds_the_child(clock):
    # A stalled child resumed later fires SubagentStart again under the same agent_id.
    eng, reg, wall = _claude_engine(clock)
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    wall.now = 300.0
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c1", subagent_transcript=TRANSCRIPT))
    eng.apply_event("s1", hook("done"))
    assert reg.get("s1").state == "working"
    # Its transcript still ends in the interruption from before the resume: that verdict is stale.
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, written_at=200.0)})
    assert reg.get("s1").state == "working"
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, written_at=301.0, size=20)}) == ["s1"]


def test_a_dead_child_waits_for_its_live_siblings(clock):
    eng, reg, _ = _claude_engine(clock)
    other = "/p/sess/subagents/agent-c2.jsonl"
    eng.apply_event("s1", hook("subagentStart", "c2", subagent_transcript=other))
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True), other: _tail()})
    assert reg.get("s1").state == "working" and eng.subagent_transcripts() == {other}
    eng.apply_event("s1", hook("subagentStop", "c2"))
    assert eng.release_dead_subagents({other: _tail(ended=True, size=20)}) == ["s1"]


def test_a_child_without_a_transcript_is_never_released(clock):
    # Codex and PI children, and a Claude hook without transcript_path: nothing to read.
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("subagentStart", "c2"))
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    assert reg.get("s1").state == "working"


def test_a_stop_that_no_longer_lists_a_child_drops_it(clock):
    # Claude woke the parent to say the child failed; that turn's Stop lists no such task.
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    assert eng.apply_event("s1", hook("done", running_subagents=frozenset())) == ["s1"]
    assert reg.get("s1").state == "done"
    assert eng.apply_event("s1", hook("subagentStop", "c1")) == []


def test_a_stop_that_drops_the_last_child_lands_the_deferred_done(clock):
    # No UserPromptSubmit came between: the earlier deferred done is the one that lands.
    eng, reg, _ = _claude_engine(clock)
    assert eng.apply_event("s1", hook("done", running_subagents=frozenset({"b1"}))) == ["s1"]
    assert reg.get("s1").state == "done"


def test_a_stop_that_lists_the_child_keeps_the_turn_working(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    assert eng.apply_event("s1", hook("done", running_subagents=frozenset({"c1"}))) == []
    assert reg.get("s1").state == "working"
    assert eng.subagent_transcripts() == {TRANSCRIPT}


def test_a_stop_drops_only_the_children_it_does_not_list(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c2", subagent_transcript="/p/sess/subagents/agent-c2.jsonl"))
    eng.apply_event("s1", hook("done", running_subagents=frozenset({"c2"})))
    assert reg.get("s1").state == "working"
    assert eng.subagent_transcripts() == {"/p/sess/subagents/agent-c2.jsonl"}
    eng.apply_event("s1", hook("subagentStop", "c2"))
    assert eng.release_dead_subagents({"/p/sess/subagents/agent-c2.jsonl": _tail(ended=True)}) == ["s1"]


def test_a_stop_without_a_list_proves_nothing(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("done", running_subagents=None))
    assert reg.get("s1").state == "working"


def test_a_stop_after_needs_input_ends_the_turn_as_without_children(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("needsInput"))
    eng.apply_event("s1", hook("done", running_subagents=frozenset()))
    assert reg.get("s1").state == "done", "a Stop says what the turn is doing now, as without children"


# -- a Claude subagent's SubagentStop -------------------------------------------------------------
# Claude Code fires a background child's SubagentStop when its turn ends, and then may run it on: it reminds a child
# that has not handed back its report (2.1.283 to 2.1.308 at least). Only the child's transcript tells which stop ended it.


def test_a_claude_childs_subagent_stop_ends_it_at_the_tick_that_reads_the_stop(clock):
    eng, reg, _ = _claude_engine(clock)
    assert eng.apply_event("s1", hook("subagentStop", "c1")) == []
    # Claude writes the stop's record a moment after the hook: a tick before then reads the child's last message.
    eng.release_dead_subagents({TRANSCRIPT: _tail(size=20)})
    assert reg.get("s1").state == "working"
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, size=30)}) == ["s1"]
    assert reg.get("s1").state == "done"


def test_a_claude_child_run_on_after_its_subagent_stop_keeps_the_row_working(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("subagentStop", "c1"))
    # The reminder and the stop's record, then the child answering it: nothing that ends it.
    for size in (20, 30):
        eng.release_dead_subagents({TRANSCRIPT: _tail(size=size)})
    assert reg.get("s1").state == "working"
    assert eng.apply_event("s1", hook("subagentStop", "c1")) == []
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, size=40)}) == ["s1"]
    assert reg.get("s1").state == "done"


def test_a_subagent_stop_stands_when_the_childs_transcript_cannot_be_found(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("subagentStop", "c1"))
    eng.subagent_transcripts()
    assert eng.release_dead_subagents({TRANSCRIPT: None}) == ["s1"]
    assert reg.get("s1").state == "done"


def test_a_stopped_child_waits_while_its_transcript_goes_unread(clock):
    # A read that did not answer in time says nothing of the child.
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("subagentStop", "c1"))
    eng.subagent_transcripts()
    assert eng.release_dead_subagents({}) == []
    assert reg.get("s1").state == "working"


def test_a_read_begun_before_the_stop_says_nothing_of_a_transcript_it_did_not_find(clock):
    # The stop came while the transcripts were read: what the child wrote before it may not have been there yet.
    eng, reg, _ = _claude_engine(clock)
    assert eng.subagent_transcripts() == {TRANSCRIPT}
    clock.now += 0.5
    eng.apply_event("s1", hook("subagentStop", "c1"))
    assert eng.release_dead_subagents({TRANSCRIPT: None}) == []
    assert reg.get("s1").state == "working"
    clock.now += 2
    eng.subagent_transcripts()
    assert eng.release_dead_subagents({TRANSCRIPT: None}) == ["s1"]
    assert reg.get("s1").state == "done"


def test_a_resumed_childs_earlier_stop_reaching_the_file_late_does_not_end_it(clock):
    # Claude writes in batches: the stop that ended the earlier run can land after the resume's SubagentStart.
    eng, reg, wall = _claude_engine(clock)
    eng.apply_event("s1", hook("subagentStop", "c1"))
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    wall.now = 300.0
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c1", subagent_transcript=TRANSCRIPT))
    eng.apply_event("s1", hook("done"))
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, ended_at=299.98, written_at=300.05)})
    assert reg.get("s1").state == "working"


def test_a_child_that_stops_mid_turn_is_gone_before_its_parents_stop(clock):
    # A foreground child stops while its parent's turn runs; a Stop without `background_tasks` cannot drop it.
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("s1", "w1", 0, "claude", 1, "", "/x", {"aiterm_task": "t1"})])
    eng = StatusEngine(reg, Clock(), monotonic=clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c1", subagent_transcript=TRANSCRIPT))
    eng.apply_event("s1", hook("subagentStop", "c1"))
    assert eng.subagent_transcripts() == {TRANSCRIPT}
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)}) == []
    assert eng.apply_event("s1", hook("done")) == ["s1"]
    assert reg.get("s1").state == "done"


def test_a_resumed_childs_stop_is_not_ended_by_its_earlier_runs_record(clock):
    # SendMessage resumes a child that ended: SubagentStart comes again under its id (Claude Code 2.1.308).
    eng, reg, wall = _claude_engine(clock)
    eng.apply_event("s1", hook("subagentStop", "c1"))
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    wall.now = 300.0
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c1", subagent_transcript=TRANSCRIPT))
    eng.apply_event("s1", hook("done"))
    eng.apply_event("s1", hook("subagentStop", "c1"))
    # Read before the resumed run's records reach the file: the earlier run's end, written at 200.
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    assert reg.get("s1").state == "working"
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, written_at=301.0, size=20)}) == ["s1"]


# -- what a turn that ended on its subagents waits on ---------------------------------------------

OTHER = "/p/sess/subagents/agent-c2.jsonl"
SHELL = BackgroundJob("shell", "scripts/test.sh")
REVIEW = BackgroundJob("subagent", "Review the fix", agent_id="c1")


def test_a_stop_lists_the_children_the_turn_waits_on_beside_its_other_work(clock):
    # One the daemon does not count holds nothing up, so it is left out.
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    stranger = BackgroundJob("subagent", "Not counted", agent_id="x9")
    stop = hook("done", background_work=(REVIEW, stranger, SHELL), running_subagents=frozenset({"c1", "x9"}))
    assert eng.apply_event("s1", stop) == ["s1"]
    assert reg.get("s1").background == (REVIEW, SHELL) and reg.get("s1").state == "working"


def test_a_childs_end_takes_it_off_what_the_turn_waits_on(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("done", background_work=(REVIEW, SHELL), running_subagents=frozenset({"c1"})))
    eng.apply_event("s1", hook("subagentStop", "c1"))
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)}) == ["s1"]
    assert reg.get("s1").background == (SHELL,) and reg.get("s1").state == "done"


def test_a_child_that_ends_at_its_subagent_stop_is_taken_off_what_the_turn_waits_on_at_once(clock):
    # One with no transcript to read ends at its hook: the done it lands must not still list it.
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("s1", "w1", 0, "claude", 1, "", "/x", {"aiterm_task": "t1"})])
    eng = StatusEngine(reg, Clock(), monotonic=clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c2"))
    index = BackgroundJob("subagent", "Index the docs", agent_id="c2")
    eng.apply_event("s1", hook("done", background_work=(index, SHELL), running_subagents=frozenset({"c2"})))
    assert reg.get("s1").background == (index, SHELL)
    assert eng.apply_event("s1", hook("subagentStop", "c2")) == ["s1"]
    assert (reg.get("s1").state, reg.get("s1").background) == ("done", (SHELL,))


def test_a_new_conversation_takes_its_children_off_what_the_turn_waits_on(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("done", background_work=(REVIEW, SHELL), running_subagents=frozenset({"c1"})))
    assert eng.apply_event("s1", hook("sessionStart")) == ["s1"]
    assert reg.get("s1").background == (SHELL,)


def test_when_the_counted_childrens_transcripts_were_last_written_is_published(clock):
    # Turn under way or ended, it shows a child still at work: the newest write of any child the daemon counts.
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("s1", "w1", 0, "claude", 1, "", "/x", {"aiterm_task": "t1"})])
    eng = StatusEngine(reg, Clock(), monotonic=clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c1", subagent_transcript=TRANSCRIPT))
    eng.apply_event("s1", hook("subagentStart", "c2", subagent_transcript=OTHER))
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(written_at=210.0), OTHER: _tail(written_at=230.0)}) == ["s1"]
    assert reg.get("s1").subagents_written_at == 230.0 and reg.get("s1").state == "working"
    assert eng.release_dead_subagents({}) == [], "a read that did not answer changes nothing"
    eng.apply_event("s1", hook("subagentStop", "c2"))
    eng.release_dead_subagents({TRANSCRIPT: _tail(written_at=210.0), OTHER: _tail(ended=True, written_at=240.0, size=20)})
    assert reg.get("s1").subagents_written_at == 210.0, "an ended child's writes are not its parent's"
    eng.apply_event("s1", hook("subagentStop", "c1"))
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, written_at=250.0, size=20)})
    assert reg.get("s1").subagents_written_at is None


def test_a_new_conversation_forgets_when_its_children_wrote(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.release_dead_subagents({TRANSCRIPT: _tail()})
    assert reg.get("s1").subagents_written_at == 200.0
    assert eng.apply_event("s1", hook("sessionStart")) == ["s1"]
    assert reg.get("s1").subagents_written_at is None


# What Claude Code 2.1.299 draws in a folder it has not been told to trust, read back from iTerm2.
CLAUDE_TRUST_SCREEN = """\
 Accessing workspace:
 /Users/me/new-project
 Quick safety check: Is this a project you created or one you trust? (Like your
 own code, a well-known open source project, or work from your team). If not,
 take a moment to review what's in this folder first.
 ❯ 1. No, exit
   2. Yes, I trust this folder
 Enter to confirm · Esc to cancel
"""


@pytest.mark.parametrize("screen,expected", [
    (CLAUDE_TRUST_SCREEN, True),
    # Drawn with cursor moves for spaces, as a terminal without iTerm2's line model shows it.
    ("❯No,exit Yes,Itrustthisfolder Entertoconfirm·Esctocancel", True),
    # The older dialog's wording.
    (" Do you trust the files in this folder?\n ❯ 1. Yes, proceed\n   2. No, exit", True),
    ("> what does trust this folder mean?", False),
    ("", False),
])
def test_shows_trust_prompt(screen, expected):
    assert status.shows_trust_prompt("claude", screen) is expected


def test_shows_trust_prompt_knows_only_the_harnesses_that_have_one():
    assert not status.shows_trust_prompt("pi", CLAUDE_TRUST_SCREEN)


def test_a_trust_prompt_turns_an_idle_row_to_needs_input_and_back(eng):
    engine, reg = eng
    assert engine.apply_trust_prompt("s1", True) == ["s1"]
    assert reg.get("s1").state == "needsInput" and engine.showing_trust_prompt("s1")
    assert engine.apply_trust_prompt("s1", True) == []
    # Answered: the row was never in a turn, so it goes back to idle rather than done.
    assert engine.apply_trust_prompt("s1", False) == ["s1"]
    assert reg.get("s1").state == "idle" and not engine.showing_trust_prompt("s1")
    assert engine.apply_trust_prompt("s1", False) == []


@pytest.mark.parametrize("state", ["working", "done", "needsInput"])
def test_a_trust_prompt_is_only_read_into_an_idle_row(eng, state):
    engine, reg = eng
    reg.set_state("s1", state)
    assert engine.apply_trust_prompt("s1", True) == []
    assert reg.get("s1").state == state and not engine.showing_trust_prompt("s1")


def test_a_hook_ends_the_trust_prompt(eng):
    """Claude loads its hooks only once the folder is trusted, so any hook says the dialog is gone."""
    engine, reg = eng
    engine.apply_trust_prompt("s1", True)
    assert engine.apply_event("s1", hook("sessionStart")) == ["s1"]
    assert reg.get("s1").state == "idle" and not engine.showing_trust_prompt("s1")


def test_a_hook_after_the_trust_prompt_still_sets_its_own_state(eng):
    engine, reg = eng
    engine.apply_trust_prompt("s1", True)
    engine.apply_event("s1", hook("needsInput"))
    assert reg.get("s1").state == "needsInput" and not engine.showing_trust_prompt("s1")
    # So the tick that finds the dialog gone does not end the real input request.
    assert engine.apply_trust_prompt("s1", False) == []
    assert reg.get("s1").state == "needsInput"


def test_the_trust_prompt_outlives_a_new_process_in_the_tab_but_not_the_tab(eng):
    engine, reg = eng
    engine.apply_trust_prompt("s1", True)
    engine.reset_turn("s1")
    assert engine.showing_trust_prompt("s1")
    engine.forget_session("s1")
    assert not engine.showing_trust_prompt("s1")


def test_an_agent_exiting_from_its_trust_prompt_forgets_it(eng):
    engine, reg = eng
    engine.apply_trust_prompt("s1", True)
    engine.agent_exited("s1")
    assert reg.get("s1").state == "idle" and not engine.showing_trust_prompt("s1")


def test_codex_rollout_completion_recovers_missed_stop_and_spinner(eng, clock):
    engine, reg = eng
    engine.apply_event("s2", hook("working"))
    assert engine.apply_codex_title("s2", "Codex") == [], "no spinner was observed"
    assert engine.apply_codex_rollout("s2", "done", 101.25) == ["s2"]
    assert reg.get("s2").state == "done"
    assert engine.apply_codex_rollout("s2", "done", 101.25) == [], "one completion event"
    assert engine.apply_codex_rollout("s2", "working", 102.5) == ["s2"]
    assert reg.get("s2").state == "working"
    assert engine.apply_codex_rollout("s2", "done", 101.25) == [], "old completion cannot undo a later start"
    clock.now = 104.0
    engine.apply_event("s2", hook("needsInput"))
    assert engine.apply_codex_rollout("s2", "done", 103.0) == []
    assert reg.get("s2").state == "needsInput", "a newer hook wins"


def test_resumed_codex_ignores_completion_from_before_session_start(eng, clock):
    engine, reg = eng
    engine.apply_event("s2", hook("working"))
    clock.now = 110.0
    engine.apply_event("s2", hook("sessionStart"))
    assert engine.apply_codex_rollout("s2", "done", 105.0) == []
    assert reg.get("s2").state == "working"


def test_rollout_start_clears_the_previous_turns_deferred_completion(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("working"))
    engine.apply_event("s2", hook("subagentStart", "child"))
    engine.apply_codex_rollout("s2", "done", 101.0)
    engine.apply_codex_rollout("s2", "working", 102.0)
    engine.apply_event("s2", hook("subagentStop", "child"))
    assert reg.get("s2").state == "working"
