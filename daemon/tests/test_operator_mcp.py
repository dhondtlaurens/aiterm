"""The single Operator's authenticated MCP transport and fourteen tools."""
import asyncio
import json
import pytest
from uuid import UUID
from aitermd import delivery, operator_mcp
from aitermd.operator_mcp import OperatorRoute, SIGNAL_TOOLS as TOOLS
from aitermd.rpc_server import RpcError
TOKEN, OTHER, UNKNOWN = "ab" * 32, "cd" * 32, "ef" * 32
ID = "E7A1C0DE-0000-4000-8000-000000000042"
SECOND = "E7A1C0DE-0000-4000-8000-000000000043"
AUTH = {"authorization": "Bearer " + TOKEN}


class App:
    """The app's end of the socket, as the route sees it: what was broadcast, and whether one is attached."""

    def __init__(self, attached: bool = True):
        self.attached = attached
        self.events: list[tuple[str, dict]] = []  # annotated: mypy checks an annotated __init__'s body
        self.arrived = asyncio.Event()

    async def broadcast(self, name, payload):
        self.events.append((name, payload))
        self.arrived.set()

    def client_count(self):
        return 1 if self.attached else 0


def route_for(app=None):
    app = app or App()
    route = OperatorRoute(app.broadcast, app.client_count)
    route.session_tokens.register(ID, 1, TOKEN)
    return route


def message(method, request_id=1, params=None):
    body = {"jsonrpc": "2.0", "method": method}
    if request_id is not None:
        body["id"] = request_id
    if params is not None:
        body["params"] = params
    return json.dumps(body).encode()


async def test_initialize_names_the_server_and_its_tools():
    status, text = await route_for().serve("POST", AUTH, message("initialize", params={
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-code", "version": "2.1.301"}}))
    reply = json.loads(text)
    assert status == 200 and reply["jsonrpc"] == "2.0" and reply["id"] == 1
    assert reply["result"] == {"protocolVersion": "2025-06-18", "capabilities": {"tools": {"listChanged": False}},
                               "serverInfo": {"name": "aiterm", "version": "1"}}


async def test_tools_list_serves_the_catalogue():
    status, text = await route_for().serve("POST", AUTH, message("tools/list", 2))
    assert status == 200 and json.loads(text)["result"] == {"tools": json.loads(json.dumps(list(TOOLS)))}


async def test_ping_is_answered():
    assert json.loads((await route_for().serve("POST", AUTH, message("ping", 3)))[1])["result"] == {}


@pytest.mark.parametrize("headers", [
    {}, {"authorization": "Bearer"}, {"authorization": "Bearer "}, {"authorization": f"Basic {TOKEN}"},
    {"authorization": f"Bearer {UNKNOWN}"}, {"authorization": TOKEN},
])
async def test_without_a_registered_token_nothing_is_answered(headers):
    status, _ = await route_for().serve("POST", headers, message("tools/list"))
    assert status == 401


async def test_a_revoked_token_is_refused():
    route = route_for()
    route.session_tokens.revoke(ID, generation=1)
    assert (await route.serve("POST", AUTH, message("tools/list")))[0] == 401


async def test_the_scheme_is_read_whatever_its_case():
    assert (await route_for().serve("POST", {"authorization": f"bearer {TOKEN}"}, message("tools/list")))[0] == 200


async def test_only_post_is_served_and_only_once_authorised():
    assert await route_for().serve("GET", AUTH, b"") == (405, "")
    assert (await route_for().serve("GET", {}, b""))[0] == 401


async def test_a_notification_is_accepted_without_an_answer():
    assert await route_for().serve("POST", AUTH, message("notifications/initialized", request_id=None)) == (202, "")


@pytest.mark.parametrize("raw,code", [(b"{nope", -32700), (b"[1]", -32600)])
async def test_a_message_that_is_no_request_is_a_json_rpc_error(raw, code):
    status, text = await route_for().serve("POST", AUTH, raw)
    assert status == 200 and json.loads(text)["error"]["code"] == code


async def test_an_unknown_method_is_a_json_rpc_error():
    reply = json.loads((await route_for().serve("POST", AUTH, message("resources/list", 9)))[1])
    assert reply["id"] == 9 and reply["error"]["code"] == -32601


async def answer_with(app, route, **reply):
    """Waits for the route's operator.request and answers it as the app does; returns the request."""
    await asyncio.wait_for(app.arrived.wait(), 2)
    _name, payload = app.events[-1]
    assert await route.reply({"requestId": payload["requestId"], **reply}) == {}
    return payload


def call(tool, arguments=None, request_id=1):
    params = {"name": tool} if arguments is None else {"name": tool, "arguments": arguments}
    return message("tools/call", request_id, params)


async def test_a_tool_call_is_forwarded_to_the_app_and_its_answer_returned():
    app = App()
    route = route_for(app)
    calling = asyncio.create_task(route.serve("POST", AUTH, call("ask_you", {"key": "q1", "question": "Which project?"}, 7)))
    request = await answer_with(app, route, result={"open": True}, error=None)
    status, text = await calling
    assert app.events[0][0] == "operator.request"
    assert request == {"requestId": request["requestId"], "operatorId": ID, "generation": 1, "tool": "ask_you",
                       "arguments": {"key": "q1", "question": "Which project?"}}
    reply = json.loads(text)
    assert status == 200 and reply["id"] == 7
    assert reply["result"] == {"content": [{"type": "text", "text": '{"open": true}'}], "structuredContent": {"open": True},
                               "isError": False}


async def test_a_call_without_arguments_forwards_an_empty_object():
    app = App()
    route = route_for(app)
    calling = asyncio.create_task(route.serve("POST", AUTH, call("run_status")))
    assert (await answer_with(app, route, result=None))["arguments"] == {}
    assert json.loads((await calling)[1])["result"]["structuredContent"] == {}


async def test_the_token_names_the_run_whatever_the_arguments_say():
    app = App()
    route = route_for(app)
    route.session_tokens.register(SECOND, 1, OTHER)
    calling = asyncio.create_task(route.serve(
        "POST", {"authorization": f"Bearer {OTHER}"}, call("run_status", {"operatorId": ID, "generation": 1})))
    assert (await answer_with(app, route, result={}))["operatorId"] == SECOND
    await calling


async def test_the_apps_error_is_a_tool_error():
    app = App()
    route = route_for(app)
    calling = asyncio.create_task(route.serve("POST", AUTH, call("message_task", {"task": "PLUTO-1", "text": "go on"})))
    await answer_with(app, route, error="you took PLUTO-1 over")
    assert json.loads((await calling)[1])["result"] == {"content": [{"type": "text", "text": "you took PLUTO-1 over"}], "isError": True}


async def test_without_the_app_the_operator_is_told_aiterm_isnt_open():
    app = App(attached=False)
    status, text = await route_for(app).serve("POST", AUTH, call("run_status", {}))
    assert json.loads(text)["result"] == {"content": [{"type": "text", "text": "AiTerm isn't open"}], "isError": True}
    assert app.events == []


async def test_an_app_that_does_not_answer_in_time_is_not_answering(monkeypatch):
    monkeypatch.setattr(delivery, "OPERATOR_REQUEST_TIMEOUT", 0.05)
    app = App()
    route = route_for(app)
    _status, text = await route.serve("POST", AUTH, call("run_status", {}))
    assert json.loads(text)["result"] == {"content": [{"type": "text", "text": "AiTerm isn't answering"}], "isError": True}
    # Its late answer is dropped, and still answered.
    assert await route.reply({"requestId": app.events[0][1]["requestId"], "result": {}}) == {}


async def test_each_call_gets_its_own_request_id():
    app = App()
    route = route_for(app)
    first = asyncio.create_task(route.serve("POST", AUTH, call("run_status", {}, 1)))
    second = asyncio.create_task(route.serve("POST", AUTH, call("run_status", {}, 2)))
    await asyncio.wait_for(_until(lambda: len(app.events) == 2), 2)
    ids = [payload["requestId"] for _name, payload in app.events]
    assert ids[0] != ids[1]
    assert ids[0].endswith("-1") and ids[1].endswith("-2")
    await route.reply({"requestId": ids[1], "result": {"which": 2}})
    await route.reply({"requestId": ids[0], "result": {"which": 1}})
    assert json.loads((await first)[1])["result"]["structuredContent"] == {"which": 1}
    assert json.loads((await second)[1])["result"]["structuredContent"] == {"which": 2}


@pytest.mark.parametrize("params", [{"name": "merge_everything", "arguments": {}}, {"name": "run_status", "arguments": [1]}, None])
async def test_a_call_to_no_such_tool_is_a_json_rpc_error(params):
    _status, text = await route_for().serve("POST", AUTH, message("tools/call", 1, params))
    assert json.loads(text)["error"]["code"] == -32602


@pytest.mark.parametrize("handler,params", [
    ("register", {"operatorId": "operator-3", "token": "short"}),
    ("register", {"operatorId": "operator-3", "token": "xy" * 32}),  # 64 characters, not hex
    ("register", {"operatorId": "operator-3", "token": TOKEN}),  # another session's
    ("register", {"operatorId": "operator-3"}),
    ("revoke", {}),
    ("reply", {"result": {}}),
    ("reply", {"requestId": "op-1", "result": "not an object or array"}),
    ("reply", {"requestId": "op-1", "error": 404}),
])
async def test_the_rpc_handlers_refuse_malformed_params(handler, params):
    with pytest.raises(RpcError) as raised:
        await getattr(route_for(), handler)(params)
    assert raised.value.code == "bad_params"


async def test_register_opens_and_revoke_closes_the_route():
    route = OperatorRoute(App().broadcast, lambda: 1)
    assert await route.register({"operatorId": ID, "generation": 1, "token": TOKEN}) == {}
    assert (await route.serve("POST", AUTH, message("tools/list")))[0] == 200
    assert await route.revoke({"operatorId": ID, "generation": 1}) == {}
    assert (await route.serve("POST", AUTH, message("tools/list")))[0] == 401


async def test_restart_drops_old_reply_while_new_call_waits(monkeypatch):
    prefixes = iter([UUID(int=1), UUID(int=2)])
    monkeypatch.setattr(operator_mcp.uuid, "uuid4", lambda: next(prefixes))
    ids = []
    routes = []

    async def broadcast(_event, payload):
        ids.append(payload["requestId"])
        route = routes[-1]
        if len(ids) == 2:
            await route.reply({"requestId": ids[0], "result": {"stale": True}})
        await route.reply({"requestId": ids[-1], "result": {"fresh": True}})

    for _ in range(2):
        routes.append(OperatorRoute(broadcast, lambda: 1))
        routes[-1].session_tokens.register(ID, 1, TOKEN)
        assert await routes[-1].ask_app(ID, "run_status", {}, generation=1) == {"fresh": True}
    assert ids[0] != ids[1]









async def _until(predicate):
    while not predicate():
        await asyncio.sleep(0.005)
