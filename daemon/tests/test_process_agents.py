import subprocess

import pytest

from aitermd import process_agents
from aitermd.models import RawSession, classify_agent
from aitermd.process_agents import Process, resolve_agents


def raw(pid=10, cmd="node review.mjs", sid="review"):
    return RawSession(sid, "window", 0, cmd, pid, "review", "/repo")


@pytest.mark.parametrize("children,expected", [
    # The runner can insert another shell between itself and the native CLI.
    ([Process(11, 10, 10, "/bin/sh"), Process(12, 11, 10, "/tools/Claude")], (12, "claude")),
    # An agent's own subprocesses do not change its identity.
    ([Process(11, 10, 10, "/tools/claude"), Process(12, 11, 10, "/tools/codex")], (11, "claude")),
    # A shell's background job and a different runner's agent are not this tab's foreground.
    ([Process(11, 10, 11, "/tools/claude"), Process(12, 99, 10, "/tools/codex")], (10, "shell")),
    # A parallel runner has no single agent to display. Do not guess from process-table order.
    ([Process(11, 10, 10, "/tools/claude"), Process(12, 10, 10, "/tools/codex")], (10, "shell")),
    ([Process(11, 10, 10, "/tools/worker")], (10, "shell")),
])
def test_only_a_single_foreground_agent_beneath_the_runner_is_resolved(monkeypatch, children, expected):
    monkeypatch.setattr(process_agents, "read_processes", lambda: [Process(10, 1, 10, "/tools/node"), *children])
    session = resolve_agents([raw()])[0]
    assert (session.job_pid, classify_agent(session.command_line)) == expected


@pytest.mark.parametrize("sessions", [[], [raw(pid=None)], [raw(cmd="claude -p")], [raw(cmd="node /tools/pi")],
                                     [raw(cmd="-zsh")], [raw(cmd="-bash")]])
def test_known_agents_and_sessions_without_a_pid_need_no_process_probe(monkeypatch, sessions):
    def unexpected():
        pytest.fail("no process probe needed")
    monkeypatch.setattr(process_agents, "read_processes", unexpected)
    assert resolve_agents(sessions) is sessions


@pytest.mark.parametrize("count", [1, 150])
def test_one_process_table_read_serves_every_unclassified_tab(monkeypatch, count):
    reads = []

    def processes():
        reads.append(True)
        return []

    monkeypatch.setattr(process_agents, "read_processes", processes)
    sessions = [raw(pid=i + 1, sid=str(i)) for i in range(count)]
    assert resolve_agents(sessions) == sessions
    assert len(reads) == 1


@pytest.mark.parametrize("error", [OSError("unavailable"), subprocess.TimeoutExpired("ps", 1),
                                   subprocess.CalledProcessError(1, "ps")])
def test_an_unavailable_process_table_preserves_the_iterm_snapshot(monkeypatch, error):
    def unavailable():
        raise error

    monkeypatch.setattr(process_agents, "read_processes", unavailable)
    sessions = [raw()]
    assert resolve_agents(sessions) is sessions
