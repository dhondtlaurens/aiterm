"""The operator's MCP server (Operators spec §5, §6): the run tokens that open it, the tools it
serves, and the `/operator` route that forwards every tool call to the app."""
from __future__ import annotations

import asyncio
import itertools
import uuid
import json
import logging
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from . import delivery, mcp, protocol
from .models import support_dir
from .operator_session import OperatorSessionTokens
from .rpc_params import optional_param, param
from .rpc_server import RpcError

log = logging.getLogger(__name__)
# What the operator is told when its call cannot reach the app (spec §11): its brief says to wait.
NOT_OPEN = "AiTerm isn't open"
NOT_ANSWERING = "AiTerm isn't answering"
# Where the app keeps each run's folder, named by its id: brief.md, mcp.json and `token` (spec §5.1).
SINGLE_ROOT = support_dir() / "operators" / "operator"
# A run's token: the app's 32 random bytes, as hex.
SIGNAL_TOOLS: tuple[dict[str, Any], ...] = tuple(json.loads(Path(__file__).with_name("signal_tools.json").read_text()))
SIGNAL_TOOL_NAMES = frozenset(tool["name"] for tool in SIGNAL_TOOLS)


def _gate_open(why: str) -> str:
    """The gate's answer when it cannot ask: allow, saying the command ran unchallenged."""
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                              "permissionDecisionReason": f"AiTerm ran this command unchallenged: {why}"}})


def _gate_denied(why: str) -> str:
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                              "permissionDecisionReason": why}})


class ToolError(Exception):
    """A tool call that failed, with what the operator is told: answered as a tool result with
    isError, as MCP has a tool's own failures, never as a protocol error."""


class OperatorRoute:
    """The operator's MCP server, on the hook server's /operator route (spec §5): MCP's streamable
    HTTP transport answered with plain JSON, one POST per message, as the Codex hook MCP is. A request
    opens only with a registered run's token, sent as `Authorization: Bearer <token>`, which names the
    run; anything else is a 401. Every tool call is forwarded to the app, the only writer of runs and
    tasks (`ask_app`). The daemon checks no tool's arguments: the app does, against the run the token
    named."""

    def __init__(self, broadcast: Callable[[str, Any], Awaitable[None]], client_count: Callable[[], int],
                 session_tokens: OperatorSessionTokens | None = None):
        self.broadcast, self.client_count = broadcast, client_count
        self.session_tokens = session_tokens if session_tokens is not None else OperatorSessionTokens()
        # The tool calls waiting for the app's answer, by the request id the event carried. Ids are
        # unique across route lifetimes; an answer from before a restart finds nothing and is dropped.
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._ids = itertools.count(1)
        self._prefix = uuid.uuid4().hex

    async def serve(self, method: str, headers: dict[str, str], body: bytes) -> tuple[int, str]:
        token = mcp.bearer(headers.get("authorization", ""))
        owner = self.session_tokens.owner_for(token) if token else None
        if owner is None:
            return 401, json.dumps({"error": "a registered Operator token is required"})
        run_id, generation = owner
        if method != "POST":
            # No stream from the server: each answer is the reply to its own POST.
            return 405, ""
        async def call(request: dict[str, Any]) -> dict[str, Any]:
            return await self._call(run_id, request.get("id"), request.get("params"), generation=generation)

        return await mcp.serve(body, SIGNAL_TOOLS, "aiterm", call)

    async def _call(self, run_id: str, request_id: Any, params: Any, generation: int) -> dict[str, Any]:
        tool = params.get("name") if isinstance(params, dict) else None
        arguments = params.get("arguments") if isinstance(params, dict) else None
        if arguments is None:
            arguments = {}
        names = SIGNAL_TOOL_NAMES
        if not isinstance(tool, str) or tool not in names or not isinstance(arguments, dict):
            return mcp.error(request_id, -32602, f"no such tool, or arguments that are not an object: {tool}")
        try:
            result = await self.ask_app(run_id, tool, arguments, generation=generation)
        except ToolError as exc:
            return mcp.answer(request_id, mcp.tool_result(str(exc), is_error=True))
        return mcp.answer(request_id, mcp.tool_result(result))

    async def ask_app(self, run_id: str, tool: str, arguments: dict[str, Any],
                      generation: int, timeout: float | None = None) -> dict[str, Any]:
        """The app's answer to one tool call: broadcast as `operator.request` and awaited until its
        `operator.reply`, for `timeout` at most (OPERATOR_REQUEST_TIMEOUT unless given). Raises ToolError with what the
        operator is told: the app's own error, NOT_OPEN with no app attached, NOT_ANSWERING after the
        timeout -- after which the app may still have acted, which every mutating tool's key makes
        safe to repeat."""
        if not self.session_tokens.owns(run_id, generation):
            raise ToolError("This Operator session was revoked.")
        if self.client_count() == 0:
            raise ToolError(NOT_OPEN)
        request_id = f"op-{self._prefix}-{next(self._ids)}"
        answer: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = answer
        try:
            payload: dict[str, Any] = {"requestId": request_id, "runId": run_id, "tool": tool, "arguments": arguments,
                                       "generation": generation}
            await self.broadcast(protocol.OPERATOR_REQUEST, payload)
            async with asyncio.timeout(delivery.OPERATOR_REQUEST_TIMEOUT if timeout is None else timeout):
                result = await answer
                if not self.session_tokens.owns(run_id, generation):
                    raise ToolError("This Operator session was revoked.")
                return result
        except TimeoutError as exc:
            raise ToolError(NOT_ANSWERING) from exc
        finally:
            self._pending.pop(request_id, None)

    async def gate(self, method: str, headers: dict[str, str], body: bytes) -> tuple[int, str]:
        """The Operator's Claude Code `PreToolUse` hook on its Bash calls (/operator/gate): the command
        goes to the app as `gate_command` -- no MCP tool, so the Operator cannot call it -- and the
        app's allow or deny comes back as Claude's hook JSON, an allow with a rewrite carrying it as
        `updatedInput`. Waits GATE_TIMEOUT for the app. Fails open: with no app, no answer in time, a
        a body or an answer it cannot read, the command is allowed and the reason says it
        ran unchallenged. A missing or revoked token always denies, including revocation while waiting."""
        token = mcp.bearer(headers.get("authorization", ""))
        owner = self.session_tokens.owner_for(token) if token else None
        def revoked() -> bool:
            return self.session_tokens.owner_for(token) != owner if token else True
        if owner is None:
            return 200, _gate_denied("This Operator token is missing or revoked.")
        run_id, generation = owner
        try:
            hook = json.loads(body or b"{}")
        except (ValueError, RecursionError):
            return 200, _gate_open("the hook's body was not JSON")
        if not isinstance(hook, dict) or not isinstance(tool_input := hook.get("tool_input"), dict):
            return 200, _gate_open("the hook's body was malformed")
        command, directory, description = tool_input.get("command"), hook.get("cwd", ""), tool_input.get("description", "")
        if not isinstance(command, str) or not isinstance(directory, str) or not isinstance(description, str):
            return 200, _gate_open("the hook's body was malformed")
        try:
            answer = await self.ask_app(run_id, "gate_command", {"command": command, "directory": directory,
                                                                 "description": description},
                                        timeout=delivery.GATE_TIMEOUT, generation=generation)
        except ToolError as exc:
            return 200, _gate_denied("This Operator token was revoked.") if revoked() else _gate_open(str(exc))
        if revoked():
            return 200, _gate_denied("This Operator token was revoked.")
        decision, reason, rewrite = answer.get("decision"), answer.get("reason"), answer.get("rewrite")
        if decision not in ("allow", "deny") or not isinstance(reason, str) or not (rewrite is None or isinstance(rewrite, str)):
            return 200, _gate_open("the app's answer was unreadable")
        output: dict[str, Any] = {"hookEventName": "PreToolUse", "permissionDecision": decision,
                                  "permissionDecisionReason": reason}
        if decision == "allow" and rewrite:
            output["updatedInput"] = {**tool_input, "command": rewrite}
        return 200, json.dumps({"hookSpecificOutput": output})

    # -- the app's half, over the socket ----------------------------------
    async def register(self, p: Any) -> dict[str, Any]:
        """operator.register: opens /operator to a run's token, in memory. The app sends it when a
        run starts, beside the token file it writes, which is what a restarted daemon reads."""
        run_id, token = param(p, "runId", str), param(p, "token", str)
        try:
            generation = param(p, "generation", int)
            self.session_tokens.register(run_id, generation, token)
        except ValueError as exc:
            raise RpcError(protocol.BAD_PARAMS, str(exc)) from exc
        return {}

    async def revoke(self, p: Any) -> dict[str, Any]:
        """operator.revoke: closes /operator to a run's token -- a stopped run's (spec §9) -- and
        deletes its token file, so no restart brings it back."""
        run_id = param(p, "runId", str)
        try:
            self.session_tokens.revoke(run_id, generation=param(p, "generation", int))
        except ValueError as exc:
            raise RpcError(protocol.BAD_PARAMS, str(exc)) from exc
        return {}

    async def reply(self, p: Any) -> dict[str, Any]:
        """operator.reply: the app's answer to an operator.request, its result or the error the
        operator is told. One nobody waits for any more -- timed out, or answered already -- is dropped."""
        request_id = param(p, "requestId", str)
        result, error = p.get("result"), optional_param(p, "error", str)
        if result is not None and not isinstance(result, (dict, list)):
            raise RpcError(protocol.BAD_PARAMS, "result must be an object or array")
        result = mcp.normalize_result(result)
        answer = self._pending.get(request_id)
        if answer is None or answer.done():
            log.info("dropped the app's reply to %s: nothing waits for it", request_id)
            return {}
        if error is not None:
            answer.set_exception(ToolError(error))
        else:
            answer.set_result(result if result is not None else {})
        return {}
