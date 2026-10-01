"""The shim installed as Grok Build's `[ui.status_line]` command. Same recipe as Claude's: forward
the payload to the daemon, then show the user's original status line, if they had one."""
import json
import os
import signal
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

SHIM = Path(__file__).resolve().parents[2] / "hooks" / "grok-statusline-shim.sh"
HOOK_PORT = 47821  # AiTermPaths.hookPort
PAYLOAD = {"session_id": "g-1", "context_window": {"used_percentage": 37}}


class _Collector(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler's naming
        body = self.rfile.read(int(self.headers.get("content-length", 0) or 0))
        self.server.received.append((self.path, dict(self.headers), json.loads(body or b"{}")))
        self.send_response(200)
        self.send_header("content-length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_):
        pass


@pytest.fixture
def daemon():
    server = HTTPServer(("127.0.0.1", 0), _Collector)
    server.received = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield server
    server.shutdown()


@pytest.fixture
def home(tmp_path, daemon):
    support = tmp_path / "Library" / "Application Support" / "AiTerm"
    support.mkdir(parents=True)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    curl = bin_dir / "curl"
    curl.write_text(f'#!/bin/sh\nexec /usr/bin/curl --connect-to 127.0.0.1:{HOOK_PORT}:127.0.0.1:{daemon.server_port} "$@"\n')
    curl.chmod(0o755)
    return tmp_path


def run_shim(home, payload=PAYLOAD):
    """Runs the shim the way Grok does: in a process group of its own, which is killed the moment
    the script exits (25-status-line.md, "Background work does not survive")."""
    env = {"HOME": str(home), "PATH": f"{home / 'bin'}:/usr/bin:/bin",
           "ITERM_SESSION_ID": "w0t0p0:tab-1"}
    shim = subprocess.Popen([str(SHIM)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=env, start_new_session=True)
    stdout, stderr = shim.communicate(json.dumps(payload), timeout=5)
    try:
        os.killpg(shim.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass  # nothing was left running
    return subprocess.CompletedProcess(shim.args, shim.returncode, stdout, stderr)


def wait_for(daemon, count=1):
    deadline = time.monotonic() + 3
    while len(daemon.received) < count and time.monotonic() < deadline:
        time.sleep(0.02)
    return daemon.received


def test_shim_forwards_to_the_grok_route_and_prints_nothing(home, daemon):
    result = run_shim(home)
    assert result.returncode == 0 and result.stdout == ""
    path, headers, body = wait_for(daemon)[0]
    assert path == "/statusline/grok" and body == PAYLOAD
    assert headers["X-AiTerm-Hook"] == "1" and headers["X-AiTerm-iTerm-Session"] == "w0t0p0:tab-1"


def test_shim_runs_the_saved_original(home, daemon):
    original = home / "Library" / "Application Support" / "AiTerm" / "grok-statusline-original.cmd"
    original.write_text("cat >/dev/null; printf 'mine'")
    result = run_shim(home)
    assert result.stdout == "mine"
    assert wait_for(daemon)[0][0] == "/statusline/grok"


def test_shim_keeps_the_originals_exit_status(home, daemon):
    # Waiting for the post must not swallow the status Grok reads from the user's own command.
    original = home / "Library" / "Application Support" / "AiTerm" / "grok-statusline-original.cmd"
    original.write_text("cat >/dev/null; printf 'mine'; exit 3")
    result = run_shim(home)
    assert (result.returncode, result.stdout) == (3, "mine")
    assert wait_for(daemon)[0][0] == "/statusline/grok"
