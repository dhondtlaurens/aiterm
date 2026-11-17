"""Single Operator authority for the socket and HTTP transport."""
import asyncio
import hashlib
import json
from pathlib import Path

import pytest

from aitermd.hook_events import parse_claude_statusline
from aitermd.operator_session import OperatorSessionTokens
from aitermd.operator_mcp import OperatorRoute
from tests.test_operator_mcp import App, answer_with, call, message

ID = "E7A1C0DE-0000-4000-8000-000000000042"
TOKEN, OTHER = "ab" * 32, "cd" * 32
AUTH = {"authorization": "Bearer " + TOKEN}


def write_session(root: Path, generation=1, token=TOKEN):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root.chmod(0o700)
    (root / "token").write_text(token)
    (root / "session.json").write_text(json.dumps({"id": ID, "generation": generation,
        "tokenHash": hashlib.sha256(token.encode()).hexdigest()}))
    for name in ("token", "session.json"):
        (root / name).chmod(0o600)


def test_restart_rotation_and_revoke_never_restore_an_old_token(tmp_path):
    write_session(tmp_path)
    tokens = OperatorSessionTokens(tmp_path)
    assert tokens.owner_for(TOKEN) == (ID, 1)
    tokens.revoke(ID, generation=1)
    assert tokens.owner_for(TOKEN) is None
    assert OperatorSessionTokens(tmp_path).owner_for(TOKEN) is None
    write_session(tmp_path, generation=2, token=OTHER)
    tokens.register(ID, 2, OTHER)
    assert tokens.owner_for(TOKEN) is None
    assert tokens.owner_for(OTHER) == (ID, 2)
    tokens.revoke(ID, generation=1)  # A late revocation cannot revoke its successor.
    assert tokens.owner_for(OTHER) == (ID, 2)
    assert OperatorSessionTokens(tmp_path).owner_for(OTHER) == (ID, 2)


@pytest.mark.parametrize("fault", ["public-token", "public-manifest", "mismatch", "symlink", "public-folder"])
def test_incomplete_or_public_authority_is_not_loaded(tmp_path, fault):
    write_session(tmp_path)
    if fault == "public-token":
        (tmp_path / "token").chmod(0o644)
    elif fault == "public-manifest":
        (tmp_path / "session.json").chmod(0o644)
    elif fault == "mismatch":
        (tmp_path / "token").write_text(OTHER)
    elif fault == "public-folder":
        tmp_path.chmod(0o755)
    else:
        (tmp_path / "token").rename(tmp_path / "secret")
        (tmp_path / "token").symlink_to(tmp_path / "secret")
    assert OperatorSessionTokens(tmp_path).owner_for(TOKEN) is None
    assert OperatorSessionTokens(tmp_path).owner_for(OTHER) is None


@pytest.mark.parametrize("generation", [True, 0, -1, "2", 1.5])
def test_register_rejects_invalid_generations(generation):
    with pytest.raises(ValueError):
        OperatorSessionTokens().register(ID, generation, TOKEN)


async def test_single_authority_serves_only_new_tools_and_forwards_its_generation():
    app, sessions = App(), OperatorSessionTokens()
    sessions.register(ID, 3, TOKEN)
    route = OperatorRoute(app.broadcast, lambda: 1, sessions)
    tools = json.loads((await route.serve("POST", AUTH, message("tools/list")))[1])["result"]["tools"]
    assert len(tools) == 14 and "choose_agent" in {tool["name"] for tool in tools} and "answer_worker" in {tool["name"] for tool in tools}
    assert (await route.serve("POST", {"authorization": "Bearer " + OTHER}, message("tools/list")))[0] == 401
    invalid = json.loads((await route.serve("POST", AUTH, call("create_task")))[1])
    assert invalid["error"]["code"] == -32602
    calling = asyncio.create_task(route.serve("POST", AUTH, call("note", {"task": "t", "key": "n"})))
    request = await answer_with(app, route, result={"status": "recorded"})
    assert request["operatorId"] == ID and request["generation"] == 3
    assert (await calling)[0] == 200


async def test_revocation_while_a_gate_waits_cannot_allow_its_command():
    app, sessions = App(), OperatorSessionTokens()
    sessions.register(ID, 1, TOKEN)
    route = OperatorRoute(app.broadcast, lambda: 1, sessions)
    hook = json.dumps({"cwd": "/tmp", "tool_input": {"command": "echo test"}}).encode()
    waiting = asyncio.create_task(route.gate("POST", AUTH, hook))
    await asyncio.wait_for(app.arrived.wait(), 2)
    sessions.revoke(ID, generation=1)
    await route.reply({"requestId": app.events[-1][1]["requestId"], "result": {"decision": "allow", "reason": "yes"}})
    result = json.loads((await waiting)[1])["hookSpecificOutput"]
    assert result["permissionDecision"] == "deny"
    result = json.loads((await route.gate("POST", AUTH, hook))[1])["hookSpecificOutput"]
    assert result["permissionDecision"] == "deny"


@pytest.mark.parametrize("usage,expected", [
    ({"input_tokens": 2, "cache_creation_input_tokens": 9227, "cache_read_input_tokens": 30010, "output_tokens": 9000}, 39239),
    ({"input_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}, 0),
])
def test_exact_current_input_wins_over_percentage(usage, expected):
    window = {"current_usage": usage, "used_percentage": 4, "context_window_size": 1000000}
    tick = parse_claude_statusline({"context_window": window}, now=1)
    assert tick.context_tokens == expected


@pytest.mark.parametrize("cw,expected", [
    ({"current_usage": None}, None),
    ({"used_percentage": 4, "context_window_size": 1000000}, 40000),
    ({"used_percentage": float("nan"), "context_window_size": 1000000}, None),
    ({"current_usage": {"input_tokens": True}}, None),
    ({"used_percentage": 50, "context_window_size": -1}, None),
])
def test_unknown_context_stays_unknown_and_estimation_needs_a_valid_window(cw, expected):
    assert parse_claude_statusline({"context_window": cw}, now=1).context_tokens == expected


async def test_register_and_revoke_use_generation_over_the_socket_surface():
    app, sessions = App(), OperatorSessionTokens()
    route = OperatorRoute(app.broadcast, lambda: 1, sessions)
    await route.register({"operatorId": ID, "generation": 1, "token": TOKEN})
    assert sessions.owner_for(TOKEN) == (ID, 1)
    await route.register({"operatorId": ID, "generation": 2, "token": OTHER})
    await route.revoke({"operatorId": ID, "generation": 1})
    assert sessions.owner_for(OTHER) == (ID, 2)
    await route.revoke({"operatorId": ID, "generation": 2})
    assert sessions.owner_for(OTHER) is None


def test_a_failed_revoke_retries_its_file_deletion_before_reporting_success(tmp_path, monkeypatch):
    write_session(tmp_path)
    tokens = OperatorSessionTokens(tmp_path)
    unlink, fail = Path.unlink, True

    def delete(path, *args, **kwargs):
        if fail and path == tmp_path / "token":
            raise OSError("temporarily unavailable")
        return unlink(path, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", delete)
    with pytest.raises(OSError):
        tokens.revoke(ID, generation=1)
    assert tokens.owner_for(TOKEN) is None
    fail = False
    tokens.revoke(ID, generation=1)
    assert not (tmp_path / "token").exists()
    assert OperatorSessionTokens(tmp_path).owner_for(TOKEN) is None


async def test_per_run_registration_is_retired():
    from aitermd.rpc_server import RpcError
    route = OperatorRoute(App().broadcast, lambda: 1)
    with pytest.raises(RpcError):
        await route.register({"operatorId": ID, "token": TOKEN})
