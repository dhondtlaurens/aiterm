"""The extension installed into PI, run under Node against a fake PI (`pi_extension_driver.mjs`).

pi-subagents runs background agents that outlive the turn which started them, and loads every
extension into each child session — in PI's own process, with the tab's `ITERM_SESSION_ID`.
"""
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
EXTENSION = HERE.parents[1] / "hooks" / "pi-aiterm-status.ts"
NODE = shutil.which("node")


def _strips_types(node: str) -> bool:
    # Node runs a `.ts` file without flags from 23.6.
    version = subprocess.run([node, "--version"], capture_output=True, text=True).stdout
    match = re.match(r"v(\d+)\.(\d+)", version)
    return match is not None and (int(match[1]), int(match[2])) >= (23, 6)


pytestmark = pytest.mark.skipif(not NODE or not _strips_types(NODE), reason="needs Node 23.6+")


@pytest.fixture(scope="module")
def phases():
    out = subprocess.run([NODE, str(HERE / "pi_extension_driver.mjs"), str(EXTENSION)],
                         capture_output=True, text=True, timeout=20, check=True)
    return json.loads(out.stdout)


def _events(posts):
    return [(p["hook_event_name"], p["session_id"], p.get("agent_id")) for p in posts]


def test_a_child_session_reports_nothing(phases):
    assert _events(phases["startup"]) == [("session_start", "root", None), ("agent_start", "root", None)]


def test_background_subagents_are_relayed_once_against_the_root_session(phases):
    assert _events(phases["background"]) == [
        ("subagent_start", "root", "a1"), ("subagent_start", "root", "a2"),
        ("agent_settled", "root", None),
        ("subagent_stop", "root", "a1"), ("subagent_stop", "root", "a2"),
    ]


def test_a_relayed_subagent_carries_the_sessions_metadata(phases):
    first = phases["background"][0]
    assert (first["cwd"], first["model"], first["reasoning"], first["context_percent"]) == (
        "/wt", "openai/model-x", "high", 12)


def test_session_start_forwards_why_the_session_started(phases):
    assert phases["startup"][0]["reason"] == "startup"
    assert all("reason" not in post for post in phases["startup"][1:])


def test_a_subagent_ending_after_its_session_shut_down_is_still_reported(phases):
    assert _events(phases["after_shutdown"]) == [("subagent_stop", "root", "a5")]


def test_nothing_is_reported_once_the_sessions_ctx_has_gone_stale(phases):
    assert phases["shutdown"] == []


def test_a_stale_context_is_dropped_rather_than_thrown(phases):
    assert phases["stale"] == []
