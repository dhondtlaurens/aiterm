"""The shim installed as Claude Code's `statusLine` command.

The callback forwards usage silently unless the user already has a custom status line.
These tests run the real script and capture both its output and the daemon payload. The shim
posts to the app's fixed hook port, so `curl` on PATH is a wrapper that connects that port to
this test's server: nothing reaches a daemon that happens to be running.
"""
import json
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

SHIM = Path(__file__).resolve().parents[2] / "hooks" / "claude-statusline-shim.sh"
HOOK_PORT = 47821  # AiTermPaths.hookPort
PAYLOAD = {
    "model": {"id": "claude-opus-5", "display_name": "Opus 5"},
    "rate_limits": {"five_hour": {"used_percentage": 23.4, "resets_at": 1790000000}},
}


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
    return subprocess.run([str(SHIM)], input=json.dumps(payload), capture_output=True,
                          text=True, env={"HOME": str(home), "PATH": f"{home / 'bin'}:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"})


def forwarded(daemon, timeout=3.0):
    """The POST is fired into the background so the status line is never held up; wait for it."""
    deadline = time.time() + timeout
    while time.time() < deadline and not daemon.received:
        time.sleep(0.02)
    return daemon.received


def support_of(home):
    return home / "Library" / "Application Support" / "AiTerm"


def test_forwards_the_payload_to_the_daemon(home, daemon):
    run_shim(home)
    received = forwarded(daemon)
    assert len(received) == 1
    path, headers, body = received[0]
    assert path == "/statusline"
    assert headers.get("X-AiTerm-Hook") == "1"
    assert body["rate_limits"]["five_hour"]["used_percentage"] == 23.4


def test_without_a_custom_statusline_is_silent_and_still_forwards(home, daemon):
    result = run_shim(home)
    assert result.returncode == 0
    assert result.stdout == ""
    assert result.stderr == ""
    assert forwarded(daemon)


def test_preserves_custom_statusline_and_forwards_the_same_payload(home, daemon):
    original = home / "mine.sh"
    original.write_text("#!/bin/sh\ncat > \"$HOME/original-input.json\"\necho 'my own status line'\n")
    original.chmod(0o755)
    (support_of(home) / "statusline-original.cmd").write_text(str(original))
    result = run_shim(home)
    assert result.returncode == 0
    assert result.stdout.strip() == "my own status line"
    assert json.loads((home / "original-input.json").read_text()) == PAYLOAD
    assert forwarded(daemon)[0][2] == PAYLOAD


@pytest.mark.parametrize("mode", ["quiet", "aiterm", "original", "nonsense"])
def test_legacy_display_modes_do_not_add_a_statusline(home, daemon, mode):
    (support_of(home) / "statusline-mode").write_text(mode + "\n")
    result = run_shim(home)
    assert result.returncode == 0
    assert result.stdout == ""
    assert forwarded(daemon)


def test_legacy_aiterm_mode_no_longer_replaces_custom_statusline(home, daemon):
    original = home / "mine.sh"
    original.write_text("#!/bin/sh\nread -r _line\necho 'my own status line'\n")
    original.chmod(0o755)
    (support_of(home) / "statusline-original.cmd").write_text(str(original))
    (support_of(home) / "statusline-mode").write_text("aiterm\n")
    assert run_shim(home).stdout.strip() == "my own status line"
    assert forwarded(daemon)
