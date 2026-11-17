import json

import pytest

from aitermd.codex_threads import CodexThreads
from aitermd.models import RawSession
from aitermd.sessions import SessionRegistry

from tests.builders import raw_session as raw


class Tags:
    """The iTerm2 port as far as CodexThreads writes to it: each tag write, in order."""

    def __init__(self):
        self.writes: list[tuple[str, dict[str, str]]] = []

    async def set_session_tags(self, session_id, tags):
        self.writes.append((session_id, tags))


class World:
    """A registry and its CodexThreads; `snapshot` applies raw sessions to both, as a tick does."""

    def __init__(self):
        self.registry, self.tags = SessionRegistry(), Tags()
        self.threads = CodexThreads(self.registry, self.tags)

    def snapshot(self, *sessions: RawSession) -> list[str]:
        self.registry.apply_snapshot(list(sessions))
        return self.threads.restore(list(sessions))


@pytest.fixture
def world():
    """A Codex tab `x` running process 103 in /repo."""
    w = World()
    w.snapshot(RawSession("x", "w1", 2, "codex", 103, "", "/repo", {}))
    return w


@pytest.mark.parametrize(("agent", "pid", "tag", "conversation"), [
    ("codex", 42, json.dumps({"pid": 42, "thread": "worker"}), "worker"),
    ("codex", 43, json.dumps({"pid": 42, "thread": "worker"}), None),
    ("claude", 42, json.dumps({"pid": 42, "thread": "worker"}), None),
    ("codex", None, json.dumps({"pid": 42, "thread": "worker"}), None),
    ("codex", 42, "not json", None),
    ("codex", 42, json.dumps({"pid": 42, "thread": ""}), None),
])
def test_a_saved_codex_thread_belongs_only_to_its_process(agent, pid, tag, conversation):
    w = World()
    session = raw(cmd=agent, pid=pid, aiterm_codex_thread=tag)
    assert w.snapshot(session) == (["s1"] if conversation else [])
    assert (w.threads.thread("s1"), w.registry.get("s1").conversation_id) == (conversation, conversation)
    assert w.snapshot(session) == []
    assert (w.threads.thread("s1"), w.registry.get("s1").conversation_id) == (conversation, conversation)


async def test_a_thread_restored_after_a_helper_restart_is_not_written_again():
    w = World()
    w.snapshot(raw(cmd="codex", pid=42, aiterm_codex_thread=json.dumps({"pid": 42, "thread": "worker"})))
    await w.threads.remember(w.registry.all())
    assert w.tags.writes == []
    # A hook naming another thread is written once, with the process it belongs to.
    w.threads.bind("s1", "other", "Stop")
    await w.threads.remember(w.registry.all())
    await w.threads.remember(w.registry.all())
    assert w.tags.writes == [("s1", {"aiterm_codex_thread": json.dumps({"pid": 42, "thread": "other"})})]


async def test_a_codex_thread_waits_for_the_next_snapshot_to_learn_its_process(world):
    world.threads.bind("x", "thread-1", "UserPromptSubmit")
    # The replacement process posts before iTerm2 has reported its pid.
    world.snapshot(RawSession("x", "w1", 2, "codex", 104, "", "/repo", {}))
    assert world.threads.thread("x") == "thread-1"
    # Bound to 104 from here on: another process in the tab is another conversation.
    world.snapshot(RawSession("x", "w1", 2, "codex", 105, "", "/repo", {}))
    assert world.threads.thread("x") is None


async def test_a_stop_binds_the_thread_to_the_process_it_came_from(world):
    world.threads.bind("x", "thread-1", "Stop")
    world.snapshot(RawSession("x", "w1", 2, "codex", 104, "", "/repo", {}))
    assert world.threads.thread("x") is None


@pytest.mark.parametrize("event", ["SubagentStart", "SubagentStop"])
async def test_a_codex_child_does_not_replace_its_parents_thread(world, event):
    world.threads.bind("x", "parent", "Stop")
    world.threads.bind("x", "child", event)
    assert world.threads.thread("x") == "parent"
