# daemon/tests/test_operator_surface.py
"""The operator's tool calls end to end: over HTTP to /operator, as an operator.request event to the
attached app, and back with its operator.reply."""
import asyncio

import pytest

from tests.conftest import operator_post, read_until, send, wait_until

TOKEN = "f" * 64


@pytest.fixture
async def app(make_service):
    """A started service with an app attached: the service and the app's end of the socket."""
    svc = make_service()
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    yield svc, r, w
    w.close()


async def register(r, w, request_id=1, run_id="run-1", token=TOKEN):
    await send(w, request_id, "operator.register", {"runId": run_id, "token": token})
    return await read_until(r, lambda m: m.get("id") == request_id)


def tool_call(name, arguments, request_id=1):
    return {"jsonrpc": "2.0", "id": request_id, "method": "tools/call", "params": {"name": name, "arguments": arguments}}


async def test_a_tool_call_reaches_the_app_and_its_reply_reaches_the_operator(app):
    svc, r, w = app
    assert (await register(r, w))["result"] == {}
    calling = asyncio.create_task(operator_post(svc.hooks.port, tool_call("run_status", {}), token=TOKEN))
    request = (await read_until(r, lambda m: m.get("event") == "operator.request"))["payload"]
    assert request["requestId"].startswith("op-") and request["requestId"].endswith("-1")
    assert {k: v for k, v in request.items() if k != "requestId"} == {"runId": "run-1", "tool": "run_status", "arguments": {}}
    await send(w, 2, "operator.reply", {"requestId": request["requestId"], "result": {"revision": 4}, "error": None})
    assert (await read_until(r, lambda m: m.get("id") == 2))["result"] == {}
    status, reply = await calling
    assert status == 200 and reply["result"]["structuredContent"] == {"revision": 4}


async def test_a_revoked_run_is_shut_out(app):
    svc, r, w = app
    await register(r, w)
    await send(w, 2, "operator.revoke", {"runId": "run-1"})
    assert (await read_until(r, lambda m: m.get("id") == 2))["result"] == {}
    assert (await operator_post(svc.hooks.port, tool_call("run_status", {}), token=TOKEN))[0] == 401


async def test_with_the_app_gone_the_operator_is_told_aiterm_isnt_open(make_service):
    svc = make_service()
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    await register(r, w)
    w.close()
    await wait_until(lambda: svc.rpc.client_count == 0)
    status, reply = await operator_post(svc.hooks.port, tool_call("run_status", {}), token=TOKEN)
    assert status == 200 and reply["result"] == {"content": [{"type": "text", "text": "AiTerm isn't open"}], "isError": True}


async def test_the_operator_route_still_needs_the_hook_marker(app):
    svc, r, w = app
    await register(r, w)
    assert (await operator_post(svc.hooks.port, tool_call("run_status", {}), token=TOKEN, hook=False))[0] == 404


# -- the PreToolUse gate on /operator/gate --------------------------------------------------------

GATE = "/operator/gate"


def pre_tool_use(command="rm -rf build", cwd="/work/repo", description="Clean up"):
    """Claude's PreToolUse body for one Bash call."""
    return {"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": cwd,
            "tool_input": {"command": command, "description": description}}


def hook_output(decision, reason, **extra):
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision,
                                   "permissionDecisionReason": reason, **extra}}


async def answer_gate(r, w, result, request_id=2):
    """The app's end: the gate request it sees, answered with `result`."""
    request = (await read_until(r, lambda m: m.get("event") == "operator.request"))["payload"]
    await send(w, request_id, "operator.reply", {"requestId": request["requestId"], "result": result, "error": None})
    return request


async def test_the_gate_relays_the_command_and_answers_claude(app):
    svc, r, w = app
    await register(r, w)
    gating = asyncio.create_task(operator_post(svc.hooks.port, pre_tool_use(), token=TOKEN, path=GATE))
    request = await answer_gate(r, w, {"decision": "deny", "reason": "r", "rewrite": None})
    assert request["tool"] == "gate_command" and request["runId"] == "run-1"
    assert request["arguments"] == {"command": "rm -rf build", "directory": "/work/repo", "description": "Clean up"}
    assert await gating == (200, hook_output("deny", "r"))


async def test_a_rewrite_becomes_updated_input(app):
    svc, r, w = app
    await register(r, w)
    gating = asyncio.create_task(operator_post(svc.hooks.port, pre_tool_use(), token=TOKEN, path=GATE))
    await answer_gate(r, w, {"decision": "allow", "reason": "narrowed", "rewrite": "rm -rf build/tmp"})
    assert await gating == (200, hook_output("allow", "narrowed", updatedInput={"command": "rm -rf build/tmp", "description": "Clean up"}))


async def test_an_allow_without_a_rewrite_leaves_the_input_alone(app):
    svc, r, w = app
    await register(r, w)
    gating = asyncio.create_task(operator_post(svc.hooks.port, pre_tool_use(), token=TOKEN, path=GATE))
    await answer_gate(r, w, {"decision": "allow", "reason": "fine"})
    assert await gating == (200, hook_output("allow", "fine"))


def assert_unchallenged(reply):
    output = reply["hookSpecificOutput"]
    assert output["hookEventName"] == "PreToolUse" and output["permissionDecision"] == "allow"
    assert "unchallenged" in output["permissionDecisionReason"] and "updatedInput" not in output


async def test_the_gate_fails_open_when_aiterm_is_closed(make_service):
    svc = make_service()
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    await register(r, w)
    w.close()
    await wait_until(lambda: svc.rpc.client_count == 0)
    status, reply = await operator_post(svc.hooks.port, pre_tool_use(), token=TOKEN, path=GATE)
    assert status == 200
    assert_unchallenged(reply)


async def test_the_gate_fails_open_on_timeout(app, monkeypatch):
    from aitermd import delivery
    monkeypatch.setattr(delivery, "GATE_TIMEOUT", 0.01)
    svc, r, w = app
    await register(r, w)
    status, reply = await operator_post(svc.hooks.port, pre_tool_use(), token=TOKEN, path=GATE)
    assert status == 200
    assert_unchallenged(reply)


async def test_the_gate_fails_open_on_a_bad_token(app):
    svc, r, w = app
    await register(r, w)
    for token in ("e" * 64, None):
        status, reply = await operator_post(svc.hooks.port, pre_tool_use(), token=token, path=GATE)
        assert status == 200
        assert_unchallenged(reply)


@pytest.mark.parametrize("body", [[], {"tool_input": "ls"}, {"tool_input": {}}, {"tool_input": {"command": 3}},
                                  {"tool_input": {"command": "ls"}, "cwd": 4}])
async def test_the_gate_fails_open_on_a_malformed_body(app, body):
    svc, r, w = app
    await register(r, w)
    status, reply = await operator_post(svc.hooks.port, body, token=TOKEN, path=GATE)
    assert status == 200
    assert_unchallenged(reply)


async def test_the_gate_fails_open_on_an_answer_it_cannot_read(app):
    svc, r, w = app
    await register(r, w)
    gating = asyncio.create_task(operator_post(svc.hooks.port, pre_tool_use(), token=TOKEN, path=GATE))
    await answer_gate(r, w, {"decision": "maybe"})
    status, reply = await gating
    assert status == 200
    assert_unchallenged(reply)


async def test_the_gate_fails_open_when_the_app_answers_with_an_error(app):
    svc, r, w = app
    await register(r, w)
    gating = asyncio.create_task(operator_post(svc.hooks.port, pre_tool_use(), token=TOKEN, path=GATE))
    request = (await read_until(r, lambda m: m.get("event") == "operator.request"))["payload"]
    await send(w, 2, "operator.reply", {"requestId": request["requestId"], "result": None, "error": "no such run"})
    status, reply = await gating
    assert status == 200
    assert_unchallenged(reply)


async def test_the_operator_cannot_call_the_gate_as_a_tool(app):
    svc, r, w = app
    await register(r, w)
    status, reply = await operator_post(svc.hooks.port, tool_call("gate_command", {"command": "ls"}), token=TOKEN)
    assert status == 200 and reply["error"]["code"] == -32602
