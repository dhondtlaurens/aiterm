"""The shim installed as Antigravity's `statusLine` command: it posts each payload to the daemon with the
tab's iTerm session, and runs the person's own status line from its own record. The real script runs
against a stand-in daemon on the port written in `hook-port`."""
import json
import subprocess
from pathlib import Path

import pytest

SHIM = Path(__file__).resolve().parents[2] / "hooks" / "agy-statusline-shim.sh"
PAYLOAD = {"conversation_id": "c62469da", "agent_state": "tool_use", "tool_confirmation_pending": True,
           "context_window": {"used_percentage": 1.3}}


@pytest.fixture
def home(tmp_path, daemon):
    support = tmp_path / "Library" / "Application Support" / "AiTerm"
    support.mkdir(parents=True)
    (support / "hook-port").write_text(f"{daemon.server_port}\n")
    return tmp_path


def run_shim(home, iterm="w0t0p0:ABC"):
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}
    if iterm:
        env["ITERM_SESSION_ID"] = iterm
    return subprocess.run([str(SHIM)], input=json.dumps(PAYLOAD), capture_output=True, text=True, env=env, timeout=10)


def support_of(home):
    return home / "Library" / "Application Support" / "AiTerm"


def test_posts_the_payload_with_its_tab_before_it_ends(home, daemon):
    # The post is not in the background: it has arrived when the shim has printed.
    result = run_shim(home)
    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")
    [(path, headers, body)] = daemon.received
    assert path == "/statusline/agy"
    assert headers.get("X-AiTerm-Hook") == "1"
    assert headers.get("X-AiTerm-iTerm-Session") == "w0t0p0:ABC"
    assert body == PAYLOAD


def test_runs_its_own_saved_status_line_never_claudes(home, daemon):
    (support_of(home) / "statusline-original.cmd").write_text("cat >/dev/null; printf 'claude-mine'")
    assert run_shim(home).stdout == ""
    (support_of(home) / "statusline-original-agy.cmd").write_text("cat > \"$HOME/in.json\"; printf 'agy-mine'")
    assert run_shim(home).stdout == "agy-mine"
    assert json.loads((home / "in.json").read_text()) == PAYLOAD


def test_without_a_port_it_posts_nothing_and_still_runs_the_original(home, daemon):
    (support_of(home) / "hook-port").unlink()
    (support_of(home) / "statusline-original-agy.cmd").write_text("cat >/dev/null; printf 'mine'")
    result = run_shim(home)
    assert (result.returncode, result.stdout, result.stderr) == (0, "mine", "")
    assert daemon.received == []
