"""The JSON-RPC envelopes and stateless methods shared by AiTerm's MCP endpoints."""
from __future__ import annotations

import json
from collections.abc import Sequence
from typing import Any

MCP_PROTOCOL_VERSION = "2025-06-18"


def answer(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def respond(request_id: Any, method: Any, tools: Sequence[dict[str, Any]], server: str = "aiterm") -> dict[str, Any] | None:
    """None leaves tools/call to the endpoint, which owns validation and execution."""
    if method == "initialize":
        return answer(request_id, {"protocolVersion": MCP_PROTOCOL_VERSION, "capabilities": {"tools": {"listChanged": False}},
                                   "serverInfo": {"name": server, "version": "1"}})
    if method == "ping":
        return answer(request_id, {})
    if method == "tools/list":
        return answer(request_id, {"tools": list(tools)})
    if method == "tools/call":
        return None
    return error(request_id, -32601, f"method not found: {method}")


def bearer(authorization: str) -> str | None:
    scheme, _, token = authorization.partition(" ")
    return token.strip() or None if scheme.lower() == "bearer" else None


def tool_result(value: Any, *, is_error: bool = False) -> dict[str, Any]:
    if isinstance(value, list):
        value = {"items": value}
    result = {"content": [{"type": "text", "text": value if is_error else json.dumps(value)}], "isError": is_error}
    if isinstance(value, dict) and not is_error:
        result["structuredContent"] = value
    return result
