# daemon/tests/test_operator_stub.py
"""The live evals' stand-in for AiTerm's /operator route (tools.operator_stub): it serves the tools it
was given, answers each call from a scenario's replies, and logs every call, over real HTTP."""
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

DAEMON = Path(__file__).resolve().parent.parent
TOOLS = [
    {"name": "run_status", "description": "The broadcast now.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "read_task", "description": "Reads a task.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "find_user", "description": "Finds people.", "inputSchema": {"type": "object", "properties": {}}},
]
HEADERS = {"Authorization": "Bearer any-token", "X-AiTerm-Hook": "1", "Content-Type": "application/json"}


def post(port, message, headers=HEADERS):
    request = urllib.request.Request(f"http://127.0.0.1:{port}/operator", data=json.dumps(message).encode(), headers=headers,
                                     method="POST")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        return error.code, None


def call(port, request_id, tool, arguments):
    status, answer = post(port, {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                                 "params": {"name": tool, "arguments": arguments}})
    assert status == 200
    return answer["result"]


def test_the_stub_lists_the_tools_it_was_given_and_logs_each_call(tmp_path):
    (tmp_path / "tools.json").write_text(json.dumps(TOOLS), encoding="utf-8")
    replies = {"run_status": {"revision": 3}, "read_task/prompt": {"prompt": None}, "find_user": {"error": "AiTerm isn't answering"}}
    (tmp_path / "replies.json").write_text(json.dumps(replies), encoding="utf-8")
    log = tmp_path / "calls.jsonl"
    stub = subprocess.Popen([sys.executable, "-m", "tools.operator_stub", "--tools", str(tmp_path / "tools.json"),
                             "--replies", str(tmp_path / "replies.json"), "--log", str(log)],
                            cwd=DAEMON, stdout=subprocess.PIPE, text=True)
    try:
        assert stub.stdout is not None
        first = stub.stdout.readline().split()
        assert first[0] == "port" and int(first[1]) > 0
        port = int(first[1])

        status, answer = post(port, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        assert status == 200 and answer["result"]["serverInfo"]["name"] == "aiterm"
        assert post(port, {"jsonrpc": "2.0", "method": "notifications/initialized"})[0] == 202
        status, answer = post(port, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert answer["result"]["tools"] == TOOLS

        result = call(port, 3, "run_status", {})
        assert result["isError"] is False and result["structuredContent"] == {"revision": 3}
        assert json.loads(result["content"][0]["text"]) == {"revision": 3}
        # read_task is answered by what it reads; a tool with no reply answers ok; an error reply is a failed call.
        assert call(port, 4, "read_task", {"task": "PAY-14", "what": "prompt"})["structuredContent"] == {"prompt": None}
        assert call(port, 5, "read_task", {"task": "PAY-14", "what": "diff"})["structuredContent"] == {"ok": True}
        failed = call(port, 6, "find_user", {"task": "PAY-12", "query": "Sofie"})
        assert failed["isError"] is True and failed["content"][0]["text"] == "AiTerm isn't answering"

        lines = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        assert lines == [{"tool": "run_status", "arguments": {}},
                         {"tool": "read_task", "arguments": {"task": "PAY-14", "what": "prompt"}},
                         {"tool": "read_task", "arguments": {"task": "PAY-14", "what": "diff"}},
                         {"tool": "find_user", "arguments": {"task": "PAY-12", "query": "Sofie"}}]
        # As the hook port does: no X-AiTerm-Hook is a 404, no bearer token a 401.
        assert post(port, {"jsonrpc": "2.0", "id": 7, "method": "tools/list"}, {"Authorization": "Bearer t"})[0] == 404
        assert post(port, {"jsonrpc": "2.0", "id": 8, "method": "tools/list"}, {"X-AiTerm-Hook": "1"})[0] == 401
    finally:
        stub.terminate()
        stub.wait(timeout=10)
        if stub.stdout is not None:
            stub.stdout.close()
