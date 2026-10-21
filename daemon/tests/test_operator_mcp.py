# daemon/tests/test_operator_mcp.py
"""The operator's MCP server (operator_mcp): the run tokens, the tool catalogue, the MCP methods and
the forwarding of tool calls to the app, driven directly rather than over HTTP."""
import asyncio
import json
import os
from uuid import UUID

import pytest

from aitermd import delivery, operator_mcp
from aitermd.operator_mcp import CHALLENGED_TOOLS, TOOL_NAMES, TOOLS, OperatorRoute, OperatorTokens, well_formed
from aitermd.rpc_server import RpcError

TOKEN = "ab" * 32
OTHER = "cd" * 32
UNKNOWN = "ef" * 32


def write_token(root, run_id, token, mode=0o600):
    """A run folder's token file, as the app writes it."""
    folder = root / run_id
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "token").write_text(token + "\n", encoding="utf-8")
    os.chmod(folder / "token", mode)
    return folder / "token"


def test_a_token_opens_its_own_run_only():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    tokens.register("run-2", OTHER)
    assert tokens.run_for(TOKEN) == "run-1" and tokens.run_for(OTHER) == "run-2"
    assert tokens.run_for(UNKNOWN) is None and tokens.run_for("") is None


def test_registering_a_run_again_replaces_its_token():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    tokens.register("run-1", OTHER)
    assert tokens.run_for(TOKEN) is None and tokens.run_for(OTHER) == "run-1"
    tokens.register("run-1", OTHER)  # the app registering again after it reattached: no change
    assert tokens.run_for(OTHER) == "run-1"


def test_a_revoked_token_opens_nothing():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    tokens.revoke("run-1")
    tokens.revoke("run-404")
    assert tokens.run_for(TOKEN) is None


@pytest.mark.parametrize("token", ["", "short", "ab" * 16, "AB" * 32 + "a", "xy" * 32])
def test_a_token_that_is_not_64_hex_characters_is_refused(token):
    assert not well_formed(token)
    with pytest.raises(ValueError, match="64 hex"):
        OperatorTokens().register("run-1", token)


def test_one_token_cannot_open_two_runs():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    with pytest.raises(ValueError, match="another run"):
        tokens.register("run-2", TOKEN)
    assert tokens.run_for(TOKEN) == "run-1"


def test_a_token_that_is_not_ascii_is_compared_without_raising():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    assert tokens.run_for("é" * 40) is None


def test_a_restarted_daemon_knows_the_tokens_in_the_run_folders(tmp_path):
    write_token(tmp_path, "run-1", TOKEN)
    write_token(tmp_path, "run-2", OTHER)
    tokens = OperatorTokens(tmp_path)
    assert tokens.run_for(TOKEN) == "run-1" and tokens.run_for(OTHER) == "run-2"


def test_a_token_file_that_is_not_a_runs_own_is_skipped(tmp_path, caplog):
    write_token(tmp_path, "readable", TOKEN, mode=0o644)   # others could read it
    write_token(tmp_path, "malformed", "not a token")
    (tmp_path / "no-token").mkdir()
    (tmp_path / "stray-file").write_text(OTHER, encoding="utf-8")
    tokens = OperatorTokens(tmp_path)
    assert tokens.run_for(TOKEN) is None and tokens.run_for(OTHER) is None
    assert "readable" in caplog.text and "malformed" in caplog.text


def test_a_missing_runs_folder_is_no_runs(tmp_path):
    assert OperatorTokens(tmp_path / "nowhere").run_for(TOKEN) is None


def test_an_unknown_well_formed_token_rereads_the_folder_once(tmp_path):
    tokens = OperatorTokens(tmp_path)
    write_token(tmp_path, "run-3", TOKEN)  # written by the app after this daemon started
    assert tokens.run_for(TOKEN) == "run-3"


def test_a_malformed_token_never_rereads_the_folder(tmp_path, monkeypatch):
    tokens = OperatorTokens(tmp_path)
    reads = []
    monkeypatch.setattr(tokens, "_load", lambda: reads.append(1))
    assert tokens.run_for("short") is None and tokens.run_for("é" * 64) is None
    assert reads == []
    assert tokens.run_for(UNKNOWN) is None
    assert reads == [1], "an unknown well-formed token rereads once"


def test_revoke_deletes_the_runs_token_file_so_a_reread_cannot_bring_it_back(tmp_path):
    path = write_token(tmp_path, "run-1", TOKEN)
    tokens = OperatorTokens(tmp_path)
    tokens.revoke("run-1")
    assert not path.exists() and path.parent.is_dir(), "the file goes; the run folder is the app's"
    assert tokens.run_for(TOKEN) is None


def test_revoke_deletes_nothing_outside_the_runs_folder(tmp_path):
    root = tmp_path / "runs"
    root.mkdir()
    outside = write_token(tmp_path, "elsewhere", TOKEN)
    tokens = OperatorTokens(root)
    for run_id in ("../elsewhere", "..", ".", "", "a/b"):
        tokens.revoke(run_id)
    assert outside.exists()


def test_memory_wins_over_a_file(tmp_path):
    tokens = OperatorTokens(tmp_path)
    tokens.register("run-1", OTHER)  # rotated, its file not written yet
    write_token(tmp_path, "run-1", TOKEN)
    assert tokens.run_for(TOKEN) is None and tokens.run_for(OTHER) == "run-1"


CONTRACT_TOOLS = {"run_status", "jira_search", "jira_create", "jira_move", "jira_link", "create_task", "update_task",
                  "submit_plan", "read_task", "message_task", "open_tab", "mark_task", "resume_task", "retry_task", "finish_task",
                  "ask_you", "resolve_question", "report_find", "log_decision", "leave_for_you", "review_task", "request_review",
                  "reply_thread", "find_user"}


def test_the_tools_are_the_contracts():
    names = [tool["name"] for tool in TOOLS]
    assert len(names) == len(set(names))
    assert set(names) == CONTRACT_TOOLS == TOOL_NAMES


@pytest.mark.parametrize("tool", TOOLS, ids=lambda tool: tool["name"])
def test_every_tool_has_a_description_and_a_closed_object_schema(tool):
    schema = tool["inputSchema"]
    assert tool["description"].strip()
    assert schema["type"] == "object" and schema["additionalProperties"] is False
    assert set(schema.get("required", [])) <= set(schema["properties"])
    assert schema.get("required", ["x"]), "an empty required list is left out"
    for name, prop in schema["properties"].items():
        assert prop.get("description") or prop.get("type") == "integer", name
    json.dumps(tool)


def test_only_the_challenged_tools_take_a_challenge_reply():
    assert set(CHALLENGED_TOOLS) == {"submit_plan", "mark_task", "create_task", "finish_task"}
    for tool in TOOLS:
        properties = tool["inputSchema"]["properties"]
        assert ("challengeId" in properties and "challengeReply" in properties) == (tool["name"] in CHALLENGED_TOOLS)
        assert "challengeId" not in tool["inputSchema"].get("required", [])
        if tool["name"] in CHALLENGED_TOOLS:
            # Integration decision 3: a pending challenge is called again with its id.
            assert "pending" in properties["challengeId"]["description"]


def test_the_values_are_the_apps():
    properties = {tool["name"]: tool["inputSchema"]["properties"] for tool in TOOLS}
    assert properties["create_task"]["end"]["enum"] == ["commit", "draftMR", "merge", "mergeLocal"]
    assert properties["update_task"]["end"]["enum"] == ["commit", "draftMR", "merge", "mergeLocal"]
    assert properties["create_task"]["agent"]["enum"] == ["claude", "codex"]
    assert properties["create_task"]["dependsOn"]["items"]["properties"]["kind"]["enum"] == ["order", "code"]
    assert properties["read_task"]["what"]["enum"] == ["lastMessage", "diff", "prompt", "review"]
    assert properties["mark_task"]["outcome"]["enum"] == ["accepted", "noChange", "blocked", "failed"]
    assert properties["submit_plan"]["revision"]["type"] == "integer"
    assert properties["run_status"] == {}
    required = {tool["name"]: set(tool["inputSchema"].get("required", [])) for tool in TOOLS}
    assert required["create_task"] == {"key", "title", "brief", "project", "agent", "modelReason"}
    assert required["mark_task"] == {"task", "outcome"} and required["ask_you"] == {"key", "question"}
    assert properties["create_task"]["agentPinned"]["type"] == "boolean"
    assert {"why", "objection"} <= set(properties["log_decision"]) and required["log_decision"] == {"key", "text"}
    assert required["jira_create"] == {"key", "project", "type", "summary", "description"} and "parent" in properties["jira_create"]
    assert required["jira_move"] == {"key", "status"} and required["jira_link"] == {"key", "to", "type"}


def test_open_tab_adds_a_worker_tab_to_a_running_task_by_key():
    tool = next(tool for tool in TOOLS if tool["name"] == "open_tab")
    schema = tool["inputSchema"]
    assert set(schema["properties"]) == {"task", "key", "agent", "model", "modelReason", "agentPinned", "brief"}
    assert set(schema["required"]) == {"task", "key", "agent", "modelReason", "brief"}
    assert schema["properties"]["agent"]["enum"] == ["claude", "codex"] and schema["properties"]["agentPinned"]["type"] == "boolean"
    assert "same worktree and branch" in tool["description"] and "same key" in tool["description"]


def test_message_task_and_read_task_take_a_tab_key_and_reach_the_first_worker_without_one():
    tools = {tool["name"]: tool for tool in TOOLS}
    for name in ("message_task", "read_task"):
        schema = tools[name]["inputSchema"]
        assert schema["properties"]["tab"]["type"] == "string" and "tab" not in schema["required"]
        assert "first worker" in schema["properties"]["tab"]["description"]
        assert "open_tab" in tools[name]["description"]
    assert "lastMessage" in tools["read_task"]["inputSchema"]["properties"]["tab"]["description"]


def test_the_jira_writes_say_what_the_slice_governs_and_there_is_no_comment_tool():
    tools = {tool["name"]: tool for tool in TOOLS}
    for name in ("jira_create", "jira_move", "jira_link"):
        assert "Jira slice" in tools[name]["description"]
    assert not [name for name in tools if "comment" in name]


def test_the_review_tools_say_what_the_slice_governs():
    tools = {tool["name"]: tool for tool in TOOLS}
    for name in ("request_review", "reply_thread"):
        assert "Review slice" in tools[name]["description"]
    for name in ("review_task", "find_user"):
        assert "needs no slice" in tools[name]["description"]
    required = {name: set(tool["inputSchema"].get("required", [])) for name, tool in tools.items()}
    assert required["review_task"] == {"task", "instructions"}
    assert tools["review_task"]["inputSchema"]["properties"]["agent"]["enum"] == ["claude", "codex"]
    assert required["request_review"] == {"task", "reviewers"} and required["reply_thread"] == {"task", "key", "thread", "body"}
    assert tools["request_review"]["inputSchema"]["properties"]["reviewers"]["items"] == {"type": "string"}
    assert "inReview" in tools["finish_task"]["description"]


def test_schema_has_report_find_and_no_propose_lesson():
    tools = {tool["name"]: tool for tool in TOOLS}
    assert "propose_lesson" not in tools
    report = tools["report_find"]["inputSchema"]
    assert set(report["properties"]) == {"key", "title", "why"} and set(report["required"]) == {"key", "title", "why"}
    assert "debrief" in tools["report_find"]["description"]


def test_create_task_end_is_optional():
    create = next(tool for tool in TOOLS if tool["name"] == "create_task")["inputSchema"]
    assert "end" in create["properties"] and "end" not in create["required"]
    assert "draftMR" in create["properties"]["end"]["description"]


def test_create_task_says_a_refused_addition_is_noted_for_the_debrief():
    description = next(tool for tool in TOOLS if tool["name"] == "create_task")["description"]
    assert "pending" in description and "noted for the debrief" in description and "report_find" not in description


def test_no_tool_text_carries_an_em_dash():
    assert "\u2014" not in json.dumps(TOOLS, ensure_ascii=False)


AUTH = {"authorization": f"Bearer {TOKEN}"}


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
    route.tokens.register("run-1", TOKEN)
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
    route.tokens.revoke("run-1")
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
    assert request == {"requestId": request["requestId"], "runId": "run-1", "tool": "ask_you",
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
    route.tokens.register("run-2", OTHER)
    calling = asyncio.create_task(route.serve("POST", {"authorization": f"Bearer {OTHER}"}, call("run_status", {"runId": "run-1"})))
    assert (await answer_with(app, route, result={}))["runId"] == "run-2"
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


async def _until(predicate):
    while not predicate():
        await asyncio.sleep(0.005)


@pytest.mark.parametrize("params", [{"name": "merge_everything", "arguments": {}}, {"name": "run_status", "arguments": [1]}, None])
async def test_a_call_to_no_such_tool_is_a_json_rpc_error(params):
    _status, text = await route_for().serve("POST", AUTH, message("tools/call", 1, params))
    assert json.loads(text)["error"]["code"] == -32602


@pytest.mark.parametrize("handler,params", [
    ("register", {"runId": "run-3", "token": "short"}),
    ("register", {"runId": "run-3", "token": "xy" * 32}),  # 64 characters, not hex
    ("register", {"runId": "run-3", "token": TOKEN}),  # run-1's
    ("register", {"runId": "run-3"}),
    ("revoke", {}),
    ("reply", {"result": {}}),
    ("reply", {"requestId": "op-1", "result": [1]}),
    ("reply", {"requestId": "op-1", "error": 404}),
])
async def test_the_rpc_handlers_refuse_malformed_params(handler, params):
    with pytest.raises(RpcError) as raised:
        await getattr(route_for(), handler)(params)
    assert raised.value.code == "bad_params"


async def test_register_opens_and_revoke_closes_the_route():
    route = OperatorRoute(App().broadcast, lambda: 1)
    assert await route.register({"runId": "run-9", "token": TOKEN}) == {}
    assert (await route.serve("POST", AUTH, message("tools/list")))[0] == 200
    assert await route.revoke({"runId": "run-9"}) == {}
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
        assert await routes[-1].ask_app("run", "run_status", {}) == {"fresh": True}
    assert ids[0] != ids[1]


def test_leave_for_you_is_record_only_and_requires_key_and_text():
    tool = next(tool for tool in TOOLS if tool["name"] == "leave_for_you")
    schema = tool["inputSchema"]
    assert set(schema["required"]) == {"key", "text"}
    assert set(schema["properties"]) == {"key", "text"}
    assert "sends nothing" in tool["description"]
    assert "leave_for_you" not in CHALLENGED_TOOLS
