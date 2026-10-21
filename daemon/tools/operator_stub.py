# daemon/tools/operator_stub.py
"""A stand-in for AiTerm's /operator route, for the Operator's live evals (OperatorEvalTests): it
serves MCP the way aitermd.operator_mcp.OperatorRoute does, plain JSON answering one POST at a time,
but lists the tools it is given and answers every call from a scenario's canned replies instead of
asking the app. Each call is appended to a log the eval grades.

From daemon/:

    .venv/bin/python -m tools.operator_stub --tools tools.json --replies replies.json --log calls.jsonl

Its first line on stdout is `port <n>`, the port it listens on, on 127.0.0.1. `tools.json` is a
tools/list's `tools`, as operator_mcp.TOOLS serves them. `replies.json` answers by tool name, and
read_task by `read_task/<what>` before `read_task`; `*` answers any other tool, and with nothing
matching a call answers {"ok": true}. A reply that is {"error": "<text>"} answers the call failed with
that text, as the route answers a refusal or "AiTerm isn't answering". The log holds one
{"tool", "arguments"} per call, in the order they came.

Any bearer token opens it, and it requires the X-AiTerm-Hook header the hook port requires. It never
reaches the app, the daemon or a person."""
from __future__ import annotations

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from aitermd.hooks_server import MCP_PROTOCOL_VERSION, OPERATOR_ROUTE


def reply_for(replies: dict[str, Any], tool: str, arguments: dict[str, Any]) -> Any:
    """The canned answer to one call: read_task's by what it reads, then the tool's, then `*`'s, then ok."""
    keys = ([f"read_task/{arguments.get('what')}"] if tool == "read_task" else []) + [tool, "*"]
    return next((replies[key] for key in keys if key in replies), {"ok": True})


def tool_result(reply: Any) -> dict[str, Any]:
    """A tools/call result as OperatorRoute answers one: an {"error"} reply as a failed call with its text,
    anything else as the JSON it is, with structuredContent when it is an object, as MCP has it."""
    if isinstance(reply, dict) and set(reply) == {"error"} and isinstance(reply["error"], str):
        return {"content": [{"type": "text", "text": reply["error"]}], "isError": True}
    result: dict[str, Any] = {"content": [{"type": "text", "text": json.dumps(reply)}], "isError": False}
    if isinstance(reply, dict):
        result["structuredContent"] = reply
    return result


class Stub:
    """The tools, the replies and the log one eval run is served from."""

    def __init__(self, tools: list[dict[str, Any]], replies: dict[str, Any], log: Path) -> None:
        self.tools, self.replies, self.log = tools, replies, log
        self.names = frozenset(tool["name"] for tool in tools)
        self._lock = threading.Lock()

    def respond(self, message: dict[str, Any]) -> dict[str, Any]:
        request_id, method, params = message.get("id"), message.get("method"), message.get("params")
        if method == "initialize":
            return _answer(request_id, {"protocolVersion": MCP_PROTOCOL_VERSION, "capabilities": {"tools": {"listChanged": False}},
                                        "serverInfo": {"name": "aiterm", "version": "1"}})
        if method == "ping":
            return _answer(request_id, {})
        if method == "tools/list":
            return _answer(request_id, {"tools": self.tools})
        if method == "tools/call":
            tool = params.get("name") if isinstance(params, dict) else None
            arguments = (params.get("arguments") if isinstance(params, dict) else None) or {}
            if not isinstance(tool, str) or tool not in self.names or not isinstance(arguments, dict):
                return _error(request_id, -32602, f"no such tool, or arguments that are not an object: {tool}")
            with self._lock, self.log.open("a", encoding="utf-8") as log:
                log.write(json.dumps({"tool": tool, "arguments": arguments}) + "\n")
            return _answer(request_id, tool_result(reply_for(self.replies, tool, arguments)))
        return _error(request_id, -32601, f"method not found: {method}")


def _answer(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def handler(stub: Stub) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            if self.path != OPERATOR_ROUTE or self.headers.get("X-AiTerm-Hook") != "1":
                return self._send(404, "")
            scheme, _, token = (self.headers.get("Authorization") or "").partition(" ")
            if scheme.lower() != "bearer" or not token.strip():
                return self._send(401, json.dumps({"error": "a registered run's token is required"}))
            try:
                message = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            except ValueError:
                return self._send(200, json.dumps(_error(None, -32700, "parse error")))
            if not isinstance(message, dict):
                return self._send(200, json.dumps(_error(None, -32600, "a message must be a JSON object")))
            if message.get("id") is None:
                # A notification, notifications/initialized among them, has no answer.
                return self._send(202, "")
            self._send(200, json.dumps(stub.respond(message)))

        def do_GET(self) -> None:
            # No stream from the server: each answer is the reply to its own POST.
            self._send(405, "")

        def _send(self, status: int, body: str) -> None:
            data = body.encode()
            self.send_response(status)
            if data:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, format: str, *args: Any) -> None:
            pass  # stdout carries only the port line; a request log would bury it

    return Handler


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="operator_stub", description="Serves the Operator's tools from canned replies.")
    parser.add_argument("--tools", type=Path, required=True, help="the tools to list, as tools/list serves them")
    parser.add_argument("--replies", type=Path, required=True, help="each tool's answer, by name")
    parser.add_argument("--log", type=Path, required=True, help="where each call is appended, one JSON line each")
    parser.add_argument("--port", type=int, default=0, help="the port to listen on (default: any free one)")
    ns = parser.parse_args(argv)
    stub = Stub(json.loads(ns.tools.read_text(encoding="utf-8")), json.loads(ns.replies.read_text(encoding="utf-8")), ns.log)
    server = ThreadingHTTPServer(("127.0.0.1", ns.port), handler(stub))
    print(f"port {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
