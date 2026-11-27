"""Capture native skill catalogues in an unsigned-in scratch home. Invocations never send a model prompt."""
from __future__ import annotations

import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import termios
import time
from pathlib import Path

from tools.compat_preflight import command

PI_ARGS = ["--offline", "--mode", "rpc", "--no-session", "--no-extensions", "--no-mcp"]
AGY_ARGS = ["plugin", "list", "--json"]
REQUEST = '{"type":"get_commands","id":"aiterm-skills"}\n'
DESCRIPTION = "Synthetic catalogue menu marker"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def pi_menu(cwd: Path, env: dict[str, str], *, undecided: bool) -> bool:
    """Type a partial name. A rendered input proves Pi took the keys even when the menu stays empty."""
    master, slave = pty.openpty()
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
        args = command(["pi", "--offline", "--no-session", "--no-mcp", "--no-extensions", "--tui-mode", "regular"])
        proc = subprocess.Popen(args, stdin=slave, stdout=slave, stderr=slave, cwd=cwd, env=env)
        try:
            def read_until(marker: bytes, seconds: float) -> bytes:
                deadline = time.monotonic() + seconds
                output = bytearray()
                while marker not in output and (left := deadline - time.monotonic()) > 0:
                    if not select.select([master], [], [], left)[0]:
                        break
                    data = os.read(master, 65536)
                    if not data:
                        break
                    if b"\x1b[6n" in data:
                        os.write(master, b"\x1b[1;1R")
                    output.extend(data)
                return bytes(output)

            if undecided:
                marker = b"Trust project folder?"
                if marker not in read_until(marker, 10):
                    raise RuntimeError("Pi did not ask for project trust")
                os.write(master, b"\x1b")  # Dismiss the question without storing a decision.
            if b"No models available" not in read_until(b"No models available", 10):
                raise RuntimeError("Pi did not render the scratch project's prompt")
            os.write(master, b"/skill:fixt")
            output = read_until(DESCRIPTION.encode(), 2)
            rendered = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", output)
            if b"/skill:fixt" not in rendered:
                raise RuntimeError("Pi did not render the menu query")
            return b"skill:fixture-check" in rendered
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    finally:
        os.close(slave)
        os.close(master)


def capture_skills(agent: str, scratch: Path, version: str) -> dict[str, str]:
    root = (scratch / "skill-catalogue").resolve()
    home, project = root / "home", root / "project"
    home.mkdir(parents=True)
    project.mkdir()
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG") if key in os.environ}
    env.update(HOME=str(home), TERM="xterm-256color")
    if agent == "agy":
        pack = home / ".gemini/config/plugins/fixture-pack"
        write(pack / ".antigravity-plugin/plugin.json", '{"name":"fixture-pack","version":"1.0.0"}')
        args = AGY_ARGS
    elif agent == "pi":
        pack = root / "fixture-pack"
        agent_dir = home / ".pi/agent"
        env.update(PI_CODING_AGENT_DIR=str(agent_dir), PI_OFFLINE="1")
        write(agent_dir / "settings.json", json.dumps({"packages": [str(pack)]}))
        args = PI_ARGS
    else:
        raise ValueError(f"No native skill capture for {agent}")
    write(pack / "skills/fixture-check/SKILL.md", f"---\nname: fixture-check\ndescription: {DESCRIPTION}\n---\nExample.\n")
    request = REQUEST if agent == "pi" else None
    output = subprocess.run(command([agent, *args]), input=request or "", capture_output=True, text=True,
                            cwd=project, env=env, check=True, timeout=10).stdout
    files = {"probe.json": json.dumps({"version": version, "arguments": args, "request": request}, indent=2) + "\n",
             "commands.jsonl": output}
    if agent == "pi":
        menus = []
        for name, enabled, trusted in (("enabled", True, True), ("project disables", False, True),
                                       ("denied override", False, False), ("undecided override", False, None)):
            global_json = json.dumps({"packages": [str(pack)], "theme": "dark", "lastChangelogVersion": version})
            project_json = json.dumps({"enableSkillCommands": enabled})
            write(agent_dir / "settings.json", global_json)
            write(project / ".pi/settings.json", project_json)
            store = agent_dir / "trust.json"
            decisions = {} if trusted is None else {str(project): trusted}
            write(store, json.dumps(decisions))
            visible = pi_menu(project, env, undecided=trusted is None)
            if json.loads(store.read_text()) != decisions:
                raise RuntimeError("Pi changed the scratch trust decision during the menu capture")
            menus.append(dict(name=name, global_settings=global_json, project=project_json, trust=trusted, visible=visible))
        files["menus.json"] = json.dumps(menus, indent=2) + "\n"
    return files
