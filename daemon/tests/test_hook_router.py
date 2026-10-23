import asyncio

import pytest

from aitermd.claude_sessions import ClaudeSessionFiles
from aitermd.hook_router import HookRouter
from aitermd.models import RawSession
from aitermd.publisher import Publisher
from aitermd.resolver import SessionResolver
from aitermd.sessions import SessionRegistry
from aitermd.status import StatusEngine
from aitermd.usage import UsageStore


class Hooks:
    """A HookRouter over a registry the test fills directly: no sockets, no iTerm2. Every event it
    publishes is recorded in `events`."""

    def __init__(self, tmp_path):
        self.ticks = 0
        self.on_tick = None
        self.registry, self.usage = SessionRegistry(), UsageStore()
        self.status = StatusEngine(self.registry, lambda: 1000.0)
        self.resolver = SessionResolver(self.registry, ClaudeSessionFiles(tmp_path / "claude-sessions"))
        self.events: list[tuple[str, dict]] = []
        self.router = HookRouter(self.resolver, self.status, self.usage, lambda: 1000.0,
                                 Publisher(self._record, self.registry, self.usage), tick=self._tick,
                                 retick_seconds=0.02)

    async def _tick(self):
        """The service's tick, as far as the router can tell: counted, and running `on_tick` if a test set one."""
        self.ticks += 1
        if self.on_tick is not None:
            await self.on_tick()

    async def _record(self, name, payload):
        self.events.append((name, payload))

    def tabs(self, *tabs: tuple[str, str, int]) -> list[str]:
        """Task t1's window, one tab per (session id, command line, job pid), all in /wt."""
        self.registry.apply_snapshot([RawSession(sid, "w1", index, command, pid, "", "/wt", {"aiterm_task": "t1"})
                                      for index, (sid, command, pid) in enumerate(tabs)])
        self.resolver.snapshot_applied()
        return [sid for sid, _, _ in tabs]

    async def post(self, path, body):
        return await self.router.handle_hook(path, body)

    def state(self, sid):
        return self.registry.get(sid).state


@pytest.fixture
def hooks(tmp_path):
    return Hooks(tmp_path)


async def test_a_hook_publishes_one_change_for_its_session(hooks):
    [sid] = hooks.tabs(("s1", "codex", 101))
    await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/wt",
                                     "model": "gpt-5.6", "_aiterm_iterm_session_id": sid})
    assert [(name, payload["sessionId"], payload["state"], payload["model"]) for name, payload in hooks.events] == [
        ("session.changed", sid, "working", "gpt-5.6")]


async def test_statusline_updates_usage_and_publishes_it(hooks):
    await hooks.post("/statusline", {"session_id": "abc", "model": {"id": "claude-opus-5"},
                                     "rate_limits": {"five_hour": {"used_percentage": 23, "resets_at": 99}}})
    [(name, payload)] = hooks.events
    assert name == "usage.changed" and payload["claude"]["fiveHour"] == {"usedPercent": 23, "resetsAt": 99}
    assert hooks.usage.snapshot()["claude"]["fiveHour"]["usedPercent"] == 23


async def test_a_statusline_with_type_confused_fields_changes_nothing(hooks):
    [sid] = hooks.tabs(("s1", "claude", 100))
    # A dict session id used to raise out of the pin lookup, and a dict model to be broadcast.
    await hooks.post("/statusline", {"session_id": {"x": 1}, "cwd": ["/wt"], "model": {"id": {"not": "a string"}}})
    await hooks.post("/statusline", {"session_id": "abc", "cwd": "/wt", "model": {"id": {"not": "a string"}},
                                     "context_window": {"used_percentage": 12}})
    assert hooks.registry.get(sid).model is None
    assert [payload["contextPercent"] for _, payload in hooks.events] == [12]


async def test_codex_subagent_hook_uses_its_iterm_session_when_tabs_share_a_cwd(hooks):
    first, second = hooks.tabs(("s1", "codex", 101), ("s2", "codex", 102))
    await hooks.post("/hook/codex", {"hook_event_name": "SessionStart", "session_id": "thread-1", "cwd": "/wt",
                                     "model": "gpt-5.6", "_aiterm_iterm_session_id": first})
    assert hooks.registry.get(first).model == "gpt-5.6"
    assert hooks.registry.get(second).model is None
    await hooks.post("/hook/codex", {"hook_event_name": "SubagentStart", "session_id": "thread-2", "cwd": "/wt",
                                     "agent_id": "child-1", "_aiterm_iterm_session_id": second})
    assert hooks.state(first) == "idle"
    assert hooks.state(second) == "working"
    await hooks.post("/hook/codex", {"hook_event_name": "Stop", "session_id": "thread-2", "cwd": "/wt",
                                     "_aiterm_iterm_session_id": second})
    await hooks.post("/hook/codex", {"hook_event_name": "SubagentStop", "session_id": "thread-2", "cwd": "/wt",
                                     "agent_id": "child-1", "_aiterm_iterm_session_id": second})
    assert hooks.state(second) == "done"


async def test_codex_permission_hook_resolves_iterms_prefixed_session_id(hooks):
    [sid] = hooks.tabs(("s1", "codex", 103))
    hooks.registry.set_state(sid, "done")
    await hooks.post("/hook/codex", {
        "hook_event_name": "PermissionRequest", "session_id": "thread-3",
        "cwd": "/agent-cwd", "model": "gpt-5.6",
        "_aiterm_iterm_session_id": f"w1t0p0:{sid}",
    })
    assert hooks.state(sid) == "needsInput"


async def test_resuming_an_older_codex_thread_makes_it_current_for_the_tab(hooks):
    [sid] = hooks.tabs(("s1", "codex", 105))
    for thread_id in ("thread-a", "thread-b", "thread-a"):
        await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": thread_id,
                                         "cwd": "/wt", "_aiterm_iterm_session_id": sid})
    assert hooks.resolver.codex_thread(sid) == "thread-a"


async def test_codex_hook_matches_after_the_agent_moved(hooks):
    hooks.registry.apply_snapshot([RawSession("s1", "w1", 0, "codex", 5151, "", "/repo", {"aiterm_project": "p1"})])
    # The first post comes from the repo root: it matches on the shell's cwd and teaches us the agent's.
    await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/repo"})
    assert hooks.registry.get("s1").agent_cwd == "/repo"
    # The agent moves into a worktree; iTerm2's path still says /repo.
    await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/repo/.worktrees/feat"})
    assert hooks.registry.get("s1").agent_cwd == "/repo/.worktrees/feat"
    # A later post from the new directory must still find the session.
    await hooks.post("/hook/codex", {"hook_event_name": "Stop", "session_id": "c1", "cwd": "/repo/.worktrees/feat"})
    assert hooks.state("s1") == "done"


async def test_pi_hook_resolves_prefixed_iterm_session_and_updates_all_metadata(hooks):
    [sid] = hooks.tabs(("s1", "pi --model openai/model-x", 120))
    payload = {
        "hook_event_name": "session_start", "session_id": "pi-thread", "cwd": "/agent-cwd",
        "model": "openai/model-x", "reasoning": "high", "context_percent": 43,
        "_aiterm_iterm_session_id": f"w1t0p0:{sid}",
    }
    await hooks.post("/hook/pi", payload)

    session = hooks.registry.get(sid)
    assert session.state == "idle", "session_start metadata must not change lifecycle state"
    assert session.agent_cwd == "/agent-cwd"
    assert session.model == "openai/model-x" and session.reasoning == "high"
    assert session.context_percent == 43
    await hooks.post("/hook/pi", {**payload, "hook_event_name": "agent_start"})
    assert hooks.state(sid) == "working"


def pi_base(sid):
    return {"session_id": "pi-thread", "cwd": "/wt", "_aiterm_iterm_session_id": sid}


async def test_a_pi_background_subagent_holds_the_task_working_after_the_parent_settles(hooks):
    [sid] = hooks.tabs(("s1", "pi", 121))
    base = pi_base(sid)
    await hooks.post("/hook/pi", {**base, "hook_event_name": "agent_start"})
    await hooks.post("/hook/pi", {**base, "hook_event_name": "subagent_start", "agent_id": "child-1"})
    await hooks.post("/hook/pi", {**base, "hook_event_name": "agent_settled"})
    assert hooks.state(sid) == "working", "a background subagent is still running"
    await hooks.post("/hook/pi", {**base, "hook_event_name": "subagent_stop", "agent_id": "child-1"})
    assert hooks.state(sid) == "done"


@pytest.mark.parametrize("reason,forgotten", [("new", True), ("resume", True), ("reload", False)])
async def test_a_new_pi_session_forgets_the_previous_ones_subagents(hooks, reason, forgotten):
    [sid] = hooks.tabs(("s1", "pi", 123))
    base = pi_base(sid)
    await hooks.post("/hook/pi", {**base, "hook_event_name": "agent_start"})
    await hooks.post("/hook/pi", {**base, "hook_event_name": "subagent_start", "agent_id": "lost"})

    await hooks.post("/hook/pi", {**base, "hook_event_name": "session_start", "reason": reason})
    await hooks.post("/hook/pi", {**base, "hook_event_name": "agent_start"})
    await hooks.post("/hook/pi", {**base, "hook_event_name": "agent_settled"})

    assert hooks.state(sid) == ("done" if forgotten else "working")


async def test_a_pi_prompt_closed_between_turns_leaves_the_row_as_it_was(hooks):
    [sid] = hooks.tabs(("s1", "pi", 122))
    base = pi_base(sid)
    await hooks.post("/hook/pi", {**base, "hook_event_name": "ui_prompt_start"})
    assert hooks.state(sid) == "needsInput"
    await hooks.post("/hook/pi", {**base, "hook_event_name": "ui_prompt_end"})
    assert hooks.state(sid) == "idle", "no turn is running, so the row must not spin"


async def test_a_pi_child_that_finishes_under_a_prompt_ends_the_turn_when_the_prompt_closes(hooks):
    [sid] = hooks.tabs(("s1", "pi", 124))
    for event in ({"hook_event_name": "agent_start"}, {"hook_event_name": "subagent_start", "agent_id": "c"},
                  {"hook_event_name": "agent_settled"}, {"hook_event_name": "ui_prompt_start"},
                  {"hook_event_name": "subagent_stop", "agent_id": "c"}, {"hook_event_name": "ui_prompt_end"}):
        await hooks.post("/hook/pi", {**pi_base(sid), **event})
    assert hooks.state(sid) == "done", "PI has no tick to end a turn left working"


async def test_a_hook_from_an_agent_the_tick_has_not_yet_classified_is_retried_against_a_tick(hooks):
    # window.createTask sends the agent command and ticks at once, while the tab still reads `zsh`;
    # the agent's SessionStart and first prompt arrive before the next poll classifies it.
    [sid] = hooks.tabs(("s1", "-zsh", 100))

    async def classifies():
        hooks.tabs(("s1", "codex", 101))

    hooks.on_tick = classifies
    await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/wt",
                                     "model": "gpt-5.6", "_aiterm_iterm_session_id": sid})
    assert hooks.ticks == 1
    assert [(name, payload["state"], payload["model"]) for name, payload in hooks.events] == [
        ("session.changed", "working", "gpt-5.6")]


async def test_a_hook_that_the_tick_still_cannot_place_is_dropped_after_one_retry(hooks):
    hooks.tabs(("s1", "codex", 101))
    await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/elsewhere"})
    assert hooks.ticks == 1 and hooks.events == [] and hooks.state("s1") == "idle"


async def test_a_burst_of_unplaced_hooks_shares_a_few_ticks(hooks):
    hooks.tabs(("s1", "codex", 101))
    release = asyncio.Event()

    async def slow_tick():
        await release.wait()

    hooks.on_tick = slow_tick
    posts = [asyncio.ensure_future(hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit",
                                                              "session_id": f"c{i}", "cwd": "/elsewhere"}))
             for i in range(25)]
    await asyncio.sleep(0.1)
    release.set()
    await asyncio.wait_for(asyncio.gather(*posts), 2)
    assert hooks.ticks <= 2, "one tick running and one pending, however many posts wait on them"


async def test_a_retry_tick_that_raises_drops_the_hook_without_raising(hooks, caplog):
    hooks.tabs(("s1", "codex", 101))

    async def broken():
        raise RuntimeError("iterm2 library bug")

    hooks.on_tick = broken
    with caplog.at_level("WARNING", logger="aitermd.hook_router"):
        await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/elsewhere"})
    assert hooks.events == []
    assert any("tick" in rec.getMessage() for rec in caplog.records)


async def test_a_statusline_post_that_places_nowhere_does_not_trigger_a_tick(hooks):
    # Statuslines repeat on their own; only the one-off lifecycle hooks are worth a tick.
    hooks.tabs(("s1", "-zsh", 100))
    await hooks.post("/statusline", {"session_id": "abc", "model": {"id": "claude-opus-5"}, "cwd": "/nowhere"})
    assert hooks.ticks == 0


async def test_a_hook_that_already_places_triggers_no_tick(hooks):
    [sid] = hooks.tabs(("s1", "codex", 101))
    await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1", "cwd": "/wt",
                                     "_aiterm_iterm_session_id": sid})
    assert hooks.ticks == 0


async def test_a_hook_placed_by_its_tab_id_names_the_tabs_conversation(hooks):
    [sid] = hooks.tabs(("s1", "codex", 101))
    await hooks.post("/hook/codex", {"hook_event_name": "SessionStart", "session_id": "thread-1", "cwd": "/wt",
                                     "_aiterm_iterm_session_id": sid})
    assert hooks.registry.get(sid).conversation_id == "thread-1"
    assert hooks.events[-1][1]["conversationId"] == "thread-1"


async def test_a_hook_placed_by_its_directory_names_no_conversation(tmp_path):
    # A directory can be shared by sibling tabs: the conversation could be another tab's.
    hooks = Hooks(tmp_path)
    [sid] = hooks.tabs(("tab-1", "codex", 41))
    await hooks.post("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c-1", "cwd": "/wt"})
    assert hooks.state(sid) == "working"
    assert hooks.registry.get(sid).conversation_id is None


async def test_a_codex_subagents_start_and_stop_leave_the_tabs_conversation(hooks):
    # The child's post carries its own thread id and is placed by the tab id, which is direct evidence.
    [sid] = hooks.tabs(("s1", "codex", 101))
    base = {"cwd": "/wt", "_aiterm_iterm_session_id": sid}
    await hooks.post("/hook/codex", {**base, "hook_event_name": "SessionStart", "session_id": "thread-1"})
    for name in ("SubagentStart", "SubagentStop"):
        await hooks.post("/hook/codex", {**base, "hook_event_name": name, "session_id": "thread-2", "agent_id": "child-1"})
        assert hooks.registry.get(sid).conversation_id == "thread-1", name


async def test_cancelling_a_hook_wait_preserves_its_shared_tick(hooks):
    entered, finished, release = asyncio.Event(), asyncio.Event(), asyncio.Event()
    cancelled = []

    async def gated_tick():
        entered.set()
        try:
            await release.wait()
        except asyncio.CancelledError:
            cancelled.append(True)
            raise
        finally:
            finished.set()

    hooks.on_tick = gated_tick
    posting = asyncio.create_task(hooks.post("/hook/codex", {
        "hook_event_name": "UserPromptSubmit", "session_id": "unplaced", "cwd": "/missing"}))
    try:
        await asyncio.wait_for(entered.wait(), 1)
        posting.cancel()
        with pytest.raises(asyncio.CancelledError):
            await posting
        assert not finished.is_set()
    finally:
        release.set()
        await asyncio.wait_for(finished.wait(), 1)
    assert cancelled == []


async def test_claude_file_lookup_does_not_block_hook_event_loop(tmp_path, monkeypatch):
    import threading

    hooks = Hooks(tmp_path)
    hooks.tabs(("s1", "claude", 101))
    loop_thread = threading.get_ident()
    lookup_threads = []

    def lookup(session_id):
        lookup_threads.append(threading.get_ident())
        return 101

    monkeypatch.setattr(hooks.resolver.claude_files, "pid_for_session", lookup)
    await hooks.post("/hook/claude", {"hook_event_name": "UserPromptSubmit", "session_id": "conversation", "cwd": "/wt"})
    assert hooks.state("s1") == "working"
    assert lookup_threads and loop_thread not in lookup_threads


async def test_prompt_typed_after_clear_is_still_yours(hooks, monkeypatch):
    [sid] = hooks.tabs(("s1", "claude", 101))
    monkeypatch.setattr(hooks.resolver.claude_files, "pid_for_session", lambda _: 101)
    hooks.router.typed_by_you = lambda _: True
    base = {"session_id": "conversation", "cwd": "/wt"}
    await hooks.post("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit", "prompt": "launch prompt"})
    await hooks.post("/hook/claude", {**base, "hook_event_name": "SessionStart", "source": "clear"})
    await hooks.post("/hook/claude", {**base, "hook_event_name": "UserPromptSubmit", "prompt": "my next prompt"})
    assert hooks.registry.get(sid).your_prompt == "my next prompt"
