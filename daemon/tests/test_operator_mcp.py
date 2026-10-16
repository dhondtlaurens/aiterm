# daemon/tests/test_operator_mcp.py
"""The operator's MCP server (operator_mcp): the run tokens, the tool catalogue, the MCP methods and
the forwarding of tool calls to the app, driven directly rather than over HTTP."""
import asyncio
import json
import os

import pytest

from aitermd.operator_mcp import CHALLENGED_TOOLS, TOOL_NAMES, TOOLS, OperatorRoute, OperatorTokens, well_formed

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


CONTRACT_TOOLS = {"run_status", "jira_search", "create_task", "update_task", "submit_plan", "read_task", "message_task",
                  "mark_task", "resume_task", "retry_task", "finish_task", "ask_you", "resolve_question", "propose_lesson",
                  "log_decision"}


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
    assert set(CHALLENGED_TOOLS) == {"submit_plan", "mark_task", "propose_lesson", "message_task"}
    for tool in TOOLS:
        properties = tool["inputSchema"]["properties"]
        assert ("challengeId" in properties and "challengeReply" in properties) == (tool["name"] in CHALLENGED_TOOLS)
        assert "challengeId" not in tool["inputSchema"].get("required", [])
        if tool["name"] in CHALLENGED_TOOLS:
            # Integration decision 3: a pending challenge is called again with its id.
            assert "pending" in properties["challengeId"]["description"]


def test_the_values_are_the_apps():
    properties = {tool["name"]: tool["inputSchema"]["properties"] for tool in TOOLS}
    assert properties["create_task"]["end"]["enum"] == ["commit", "draftMR", "merge"]
    assert properties["create_task"]["agent"]["enum"] == ["claude", "codex"]
    assert properties["create_task"]["dependsOn"]["items"]["properties"]["kind"]["enum"] == ["order", "code"]
    assert properties["read_task"]["what"]["enum"] == ["lastMessage", "diff", "prompt"]
    assert properties["mark_task"]["outcome"]["enum"] == ["accepted", "noChange", "blocked", "failed"]
    assert properties["submit_plan"]["revision"]["type"] == "integer"
    assert properties["run_status"] == {}
    required = {tool["name"]: set(tool["inputSchema"].get("required", [])) for tool in TOOLS}
    assert required["create_task"] == {"key", "title", "brief", "project", "agent", "end"}
    assert required["mark_task"] == {"task", "outcome"} and required["ask_you"] == {"key", "question"}


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
