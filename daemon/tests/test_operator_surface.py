# daemon/tests/test_operator_surface.py
"""The operator's tool calls end to end: over HTTP to /operator, as an operator.request event to the
attached app, and back with its operator.reply."""
import asyncio
import json

import pytest

from tests.conftest import operator_post, wait_until

TOKEN = "f" * 64


def write_token(root, run_id, token):
    """A run folder's token file, as the app writes it."""
    (root / run_id).mkdir(parents=True, exist_ok=True)
    (root / run_id / "token").write_text(token, encoding="utf-8")
    (root / run_id / "token").chmod(0o600)
    return root / run_id / "token"


@pytest.fixture
async def app(make_service):
    """A started service with an app attached: the service and the app's end of the socket."""
    svc = make_service()
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    yield svc, r, w
    w.close()


async def send(w, request_id, method, params):
    w.write((json.dumps({"id": request_id, "method": method, "params": params}) + "\n").encode())
    await w.drain()


async def read_until(r, matches):
    while True:
        line = json.loads(await asyncio.wait_for(r.readline(), 2))
        if matches(line):
            return line


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
    assert request == {"requestId": "op-1", "runId": "run-1", "tool": "run_status", "arguments": {}}
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


async def test_another_runs_token_does_not_open_this_one(app):
    svc, r, w = app
    await register(r, w)
    assert (await operator_post(svc.hooks.port, tool_call("run_status", {}), token="e" * 64))[0] == 401
    assert (await operator_post(svc.hooks.port, tool_call("run_status", {})))[0] == 401


async def test_a_short_token_is_bad_params(app):
    _svc, r, w = app
    assert (await register(r, w, token="short"))["error"]["code"] == "bad_params"


async def test_with_the_app_gone_the_operator_is_told_aiterm_isnt_open(make_service):
    svc = make_service()
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    await register(r, w)
    w.close()
    await wait_until(lambda: svc.rpc.client_count == 0)
    status, reply = await operator_post(svc.hooks.port, tool_call("run_status", {}), token=TOKEN)
    assert status == 200 and reply["result"] == {"content": [{"type": "text", "text": "AiTerm isn't open"}], "isError": True}


async def test_a_restarted_daemon_knows_a_run_by_its_token_file(make_service, tmp_path):
    """Spec §11: the operator's calls go on across a daemon restart, before the app reattaches."""
    write_token(tmp_path / "operator-runs", "run-1", TOKEN)
    restarted = make_service()
    await restarted.start()
    status, reply = await operator_post(restarted.hooks.port, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, token=TOKEN)
    assert status == 200 and reply["result"]["tools"]


async def test_a_token_file_written_after_start_is_found_on_first_use(app, tmp_path):
    svc, _r, _w = app
    write_token(tmp_path / "operator-runs", "run-2", "e" * 64)
    assert (await operator_post(svc.hooks.port, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, token="e" * 64))[0] == 200


async def test_revoke_deletes_the_runs_token_file(app, tmp_path):
    svc, r, w = app
    path = write_token(tmp_path / "operator-runs", "run-1", TOKEN)
    await register(r, w)
    await send(w, 2, "operator.revoke", {"runId": "run-1"})
    await read_until(r, lambda m: m.get("id") == 2)
    assert not path.exists()
    assert (await operator_post(svc.hooks.port, tool_call("run_status", {}), token=TOKEN))[0] == 401


async def test_the_operator_route_still_needs_the_hook_marker(app):
    svc, r, w = app
    await register(r, w)
    assert (await operator_post(svc.hooks.port, tool_call("run_status", {}), token=TOKEN, hook=False))[0] == 404
