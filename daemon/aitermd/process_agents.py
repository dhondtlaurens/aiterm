"""Find native agent children hidden behind a foreground runner, such as a piped review."""
from __future__ import annotations

import os
import shlex
import subprocess
from dataclasses import dataclass, replace

from .models import AGENT_BINARIES, RawSession, classify_agent


@dataclass(frozen=True, slots=True)
class Process:
    pid: int
    parent: int
    group: int
    command: str


def read_processes() -> list[Process]:
    # One bounded, current-user read for the whole snapshot, off the event loop. `comm` reads
    # command names (which agents can set), without arguments, so prompts are not identity evidence.
    # This is deliberately not the resolved executable path: Claude's binary can be a version number.
    result = subprocess.run(["/bin/ps", "-xww", "-o", "pid=,ppid=,pgid=,comm="],
                            capture_output=True, text=True, errors="replace", check=True, timeout=1)
    processes = []
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4 and all(value.isdecimal() for value in fields[:3]):
            processes.append(Process(int(fields[0]), int(fields[1]), int(fields[2]), fields[3]))
    return processes


def resolve_agents(sessions: list[RawSession]) -> list[RawSession]:
    # An idle login shell puts each job in another process group, so none of its children could
    # qualify. Wait for iTerm to report the foreground runner rather than probing idle tabs.
    candidates = [s for s in sessions if s.job_pid and classify_agent(s.command_line) == "shell"
                  and not (s.command_line or "").lstrip().startswith("-")]
    if not candidates:
        return sessions
    try:
        processes = read_processes()
    except (OSError, subprocess.SubprocessError):
        return sessions  # A failed process probe cannot make iTerm's sessions disappear.
    by_pid = {p.pid: p for p in processes}
    children: dict[int, list[Process]] = {}
    for process in processes:
        children.setdefault(process.parent, []).append(process)
    resolved: dict[str, Process] = {}
    for session in candidates:
        root = by_pid.get(session.job_pid or 0)
        if root is None:
            continue
        pending = list(children.get(root.pid, []))
        seen = {root.pid}
        agents = []
        while pending:
            child = pending.pop()
            # Other process groups are background jobs, not the foreground runner's agent.
            if child.pid in seen or child.group != root.group:
                continue
            seen.add(child.pid)
            if os.path.basename(child.command).casefold() in AGENT_BINARIES:
                agents.append(child)
                # The agent owns its children; a nested subagent cannot replace its identity.
            else:
                pending.extend(children.get(child.pid, []))
        if len(agents) == 1:
            resolved[session.session_id] = agents[0]
    return [replace(s, job_pid=p.pid, command_line=shlex.quote(p.command))
            if (p := resolved.get(s.session_id)) else s for s in sessions]
