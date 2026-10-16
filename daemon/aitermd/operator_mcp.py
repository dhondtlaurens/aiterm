"""The operator's MCP server (Operators spec §5, §6): the run tokens that open it, the tools it
serves, and the `/operator` route that forwards every tool call to the app."""
from __future__ import annotations

import asyncio
import hmac
import itertools
import json
import logging
import os
import re
import stat
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from . import delivery, protocol
from .hooks_server import MCP_PROTOCOL_VERSION
from .rpc_params import optional_param, param
from .rpc_server import RpcError

log = logging.getLogger(__name__)
# What the operator is told when its call cannot reach the app (spec §11): its brief says to wait.
NOT_OPEN = "AiTerm isn't open"
NOT_ANSWERING = "AiTerm isn't answering"
# Where the app keeps each run's folder, named by its id: brief.md, mcp.json and `token` (spec §5.1).
RUNS_ROOT = Path.home() / "Library" / "Application Support" / "AiTerm" / "operators" / "runs"
# A run's token: the app's 32 random bytes, as hex.
_TOKEN = re.compile(r"[0-9a-fA-F]{64}")


class ToolError(Exception):
    """A tool call that failed, with what the operator is told: answered as a tool result with
    isError, as MCP has a tool's own failures, never as a protocol error."""


def well_formed(token: str) -> bool:
    return _TOKEN.fullmatch(token) is not None


def _run_folder_name(run_id: str) -> bool:
    """Whether `run_id` names one folder inside the runs root, and nothing above or beside it."""
    return bool(run_id) and run_id not in (".", "..") and os.sep not in run_id and "/" not in run_id


class OperatorTokens:
    """Each run's token, the only thing that opens /operator, and the run it names (spec §5.2). The
    app writes each run's `token` file (mode 0600) and registers it; the daemon loads every one at
    start and reads the folder again when a well-formed token it does not know arrives, so a daemon
    restart costs the operator nothing (spec §11). It stops a worker from acting as an operator by
    accident or because a ticket told it to; it is no wall against a process of the same user, which
    can read the run folder. With no runs root, tokens live in memory only."""

    def __init__(self, runs_root: Path | None = None) -> None:
        self._root = runs_root
        self._runs: dict[str, str] = {}    # token -> run id
        self._tokens: dict[str, str] = {}  # run id -> token
        self._load()

    def register(self, run_id: str, token: str) -> None:
        """Opens /operator to `token` for `run_id`, in place of any token the run had. In memory:
        the file is the app's to write."""
        if not well_formed(token):
            raise ValueError("a run token is 64 hex characters")
        if (owner := self._runs.get(token)) is not None and owner != run_id:
            raise ValueError("that token belongs to another run")
        self._forget(run_id)
        self._runs[token], self._tokens[run_id] = run_id, token

    def revoke(self, run_id: str) -> None:
        """Closes /operator to the run for good: its token leaves memory, and its file goes, so no
        later read of the folder brings it back. The run folder itself is the app's."""
        self._forget(run_id)
        if self._root is not None and _run_folder_name(run_id):
            try:
                (self._root / run_id / "token").unlink(missing_ok=True)
            except OSError:
                log.exception("could not delete the token file of run %s", run_id)

    def _forget(self, run_id: str) -> None:
        if (token := self._tokens.pop(run_id, None)) is not None:
            self._runs.pop(token, None)

    def run_for(self, token: str) -> str | None:
        """The run `token` opens, if any. An unknown well-formed token reads the folder once more
        first: the app may have written a run's file since this daemon looked."""
        if (run := self._known(token)) is not None or not well_formed(token):
            return run
        self._load()
        return self._known(token)

    def _known(self, token: str) -> str | None:
        """Compared in constant time, as bytes: a str compare_digest raises on anything but ASCII,
        and a header can carry anything."""
        offered = token.encode("utf-8", "replace")
        return next((run for known, run in self._runs.items() if hmac.compare_digest(known.encode(), offered)), None)

    def _load(self) -> None:
        """Adopts every run folder's token that memory does not contradict: memory wins, as it holds
        what the app registered last. AiTerm's own folder, a few small files: read on the loop."""
        if self._root is None:
            return
        try:
            folders = [path for path in self._root.iterdir() if path.is_dir()]
        except OSError:
            return  # no runs yet
        for folder in folders:
            path = folder / "token"
            try:
                if not path.is_file():
                    continue
                if stat.S_IMODE(path.stat().st_mode) & 0o077:
                    log.warning("skipped the token of run %s: others can read %s", folder.name, path)
                    continue
                token = path.read_text(encoding="utf-8").strip()
            except (OSError, ValueError):
                log.warning("skipped the token of run %s: it cannot be read", folder.name)
                continue
            if not well_formed(token):
                log.warning("skipped the token of run %s: it is malformed", folder.name)
                continue
            if folder.name not in self._tokens and token not in self._runs:
                self._runs[token], self._tokens[folder.name] = folder.name, token


def _text(description: str) -> dict[str, Any]:
    return {"type": "string", "description": description}


def _choice(description: str, *values: str) -> dict[str, Any]:
    return {"type": "string", "enum": list(values), "description": description}


_TASK = _text("The task: its key as you gave it to create_task, or its id from run_status.")
_KEY = _text("Your idempotency key for this act: the same key again returns what the first call did.")
_AGENT = _choice("The agent that works the task, among those installed.", "claude", "codex")
_END = _choice("Where the task ends, from the operation's Done when: commit; draftMR, push and open a draft merge request; "
               "or merge, push, open a merge request and merge it once the host says it can be.", "commit", "draftMR", "merge")
_DEPENDS_ON: dict[str, Any] = {
    "type": "array",
    "description": "What the task waits for. An order dependency waits until the other task is accepted or needs no change; "
                   "a code dependency also builds on its accepted commit, in the same project. At most one code dependency.",
    "items": {"type": "object", "additionalProperties": False, "required": ["task", "kind"],
              "properties": {"task": _TASK, "kind": _choice("order or code.", "order", "code")}},
}
_CHALLENGE = {
    "challengeId": _text("The challengeId a challenged call returned: send it with your revised arguments, or with "
                         "challengeReply. A reply that says pending has no critique yet: call again with its challengeId "
                         "and the same arguments. The same challengeId again, once answered, returns the recorded result."),
    "challengeReply": _text("Your answer to each point of the second opinion's critique, when you keep the act as it was."),
}
# The tools a second opinion can challenge (spec §4.4): the first call returns a critique, and only
# the call that answers it, with its challengeId, takes effect. A second opinion not back within the
# app's 20 s answers {"challenged": true, "challengeId": …, "critique": null, "pending": true}, and the
# operator calls again with that challengeId (integration decision 3). Which calls are challenged
# follows the operator's setting, and is the app's to decide.
CHALLENGED_TOOLS = ("submit_plan", "mark_task", "propose_lesson", "message_task")


def _tool(name: str, description: str, properties: dict[str, Any] | None = None, required: tuple[str, ...] = ()) -> dict[str, Any]:
    """One tool as MCP's tools/list serves it. A closed schema: the operator's model shapes its calls
    by it. The daemon checks no argument; the app does."""
    properties = dict(properties or {})
    if name in CHALLENGED_TOOLS:
        properties |= _CHALLENGE
    schema: dict[str, Any] = {"type": "object", "properties": properties, "additionalProperties": False}
    if required:
        schema["required"] = list(required)
    return {"name": name, "description": description, "inputSchema": schema}


# The operator's tools (spec §6), served by /operator and answered by the app's OperatorToolHandler.
# Every one that changes something is safe to repeat: the repeat returns the recorded result.
TOOLS: tuple[dict[str, Any], ...] = (
    _tool("run_status", "The operation now, numbered by revision: every task with its state, live status, branch, last commit "
          "and a one-line summary, and what is open -- questions waiting, prompts waiting on the user, tasks ready to accept, "
          "tasks possibly stalled, anything uncertain. Call it first after any restart or compaction."),
    _tool("jira_search", "Searches Jira, read-only, within the Jira projects linked to the operation's projects.",
          {"jql": _text("The JQL query.")}, ("jql",)),
    _tool("create_task", "Adds an unstarted task to the open plan revision. The same key in this operation returns the task "
          "already made.",
          {"key": _KEY, "title": _text("The task's title, as its row shows it."),
           "brief": _text("The worker's first prompt: everything it needs, since it sees nothing else."),
           "project": _text("The project it belongs to, by name or by id from run_status."),
           "ticket": _text("The Jira key it works, if any."), "agent": _AGENT,
           "model": _text("The model, when not the agent's default."), "end": _END, "dependsOn": _DEPENDS_ON},
          ("key", "title", "brief", "project", "agent", "end")),
    _tool("update_task", "Changes an unstarted task's brief, agent, model, end or dependencies. Steer a started task with "
          "message_task instead.",
          {"task": _TASK, "brief": _text("The new brief."), "agent": _AGENT, "model": _text("The new model."), "end": _END,
           "dependsOn": _DEPENDS_ON}, ("task",)),
    _tool("submit_plan", "Closes a plan revision. Where the user approves plans, its new and changed tasks wait for that; "
          "otherwise they are queued at once. Submitting the same revision again returns the earlier result.",
          {"revision": {"type": "integer", "description": "The revision run_status shows open."}}, ("revision",)),
    _tool("read_task", "Reads a task: its worker's last message, its diff, or the prompt open in its session.",
          {"task": _TASK, "what": _choice("lastMessage, diff or prompt.", "lastMessage", "diff", "prompt")}, ("task", "what")),
    _tool("message_task", "Sends a started task's worker a message, typed into its session by AiTerm's rules. Returns "
          "delivered, partial (pasted, its Enter held back) or refused, with the reason; nothing is retried.",
          {"task": _TASK, "text": _text("The message.")}, ("task", "text")),
    _tool("mark_task", "Records a working task's outcome: accepted, with the result commit on its branch and the worker's check "
          "output; noChange; blocked or failed, with the reason in note. The same outcome for the same commit returns the earlier "
          "result.",
          {"task": _TASK, "outcome": _choice("accepted, noChange, blocked or failed.", "accepted", "noChange", "blocked", "failed"),
           "sha": _text("The accepted commit, unmoved on the task's branch."),
           "checkOutput": _text("The worker's check output: tests, lint, build."), "note": _text("Why, for blocked and failed.")},
          ("task", "outcome")),
    _tool("resume_task", "Puts a blocked task back to work once its reason is resolved; the same worker session continues.",
          {"task": _TASK}, ("task",)),
    _tool("retry_task", "Queues a failed task again, if it has retries left.", {"task": _TASK}, ("task",)),
    _tool("finish_task", "Carries out an accepted task's recorded end: pushes its branch and opens the merge request, and merges "
          "it where the plan says merge. Calling again resumes where it stopped.", {"task": _TASK}, ("task",)),
    _tool("ask_you", "Asks the user a question: it shows under Waiting on you and notifies them. They answer in this window; "
          "close it with resolve_question. The same key returns the open question.",
          {"key": _KEY, "question": _text("The question, complete on its own."), "task": _TASK}, ("key", "question")),
    _tool("resolve_question", "Closes a question the user answered, with a one-line summary of the answer.",
          {"key": _text("The question's key."), "summary": _text("The answer, in one line.")}, ("key", "summary")),
    _tool("propose_lesson", "Offers a lesson after the user corrected you: one sentence of behaviour, and the moment that "
          "prompted it. Only the user keeps it. The same key is offered once.",
          {"key": _KEY, "lesson": _text("The behaviour, in one sentence."), "because": _text("The correction that prompted it.")},
          ("key", "lesson", "because")),
    _tool("log_decision", "Writes a decision you took on your own to the operation's log. The same key is written once.",
          {"key": _KEY, "text": _text("The decision, and why."), "task": _TASK}, ("key", "text")),
)
TOOL_NAMES = frozenset(tool["name"] for tool in TOOLS)


def _answer(request_id: Any, result: dict[str, Any]) -> str:
    return json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}, separators=(",", ":"))


def _error(request_id: Any, code: int, message: str) -> str:
    return json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}, separators=(",", ":"))


class OperatorRoute:
    """The operator's MCP server, on the hook server's /operator route (spec §5): MCP's streamable
    HTTP transport answered with plain JSON, one POST per message, as the Codex hook MCP is. A request
    opens only with a registered run's token, sent as `Authorization: Bearer <token>`, which names the
    run; anything else is a 401. Every tool call is forwarded to the app, the only writer of runs and
    tasks (`ask_app`). The daemon checks no tool's arguments: the app does, against the run the token
    named."""

    def __init__(self, broadcast: Callable[[str, Any], Awaitable[None]], client_count: Callable[[], int],
                 tokens: OperatorTokens | None = None):
        self.broadcast, self.client_count = broadcast, client_count
        self.tokens = tokens if tokens is not None else OperatorTokens()
        # The tool calls waiting for the app's answer, by the request id the event carried. Ids are
        # unique within this process; an answer from before a restart finds nothing and is dropped.
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._ids = itertools.count(1)

    def _run(self, headers: dict[str, str]) -> str | None:
        scheme, _, token = headers.get("authorization", "").partition(" ")
        token = token.strip()
        return self.tokens.run_for(token) if scheme.lower() == "bearer" and token else None

    async def serve(self, method: str, headers: dict[str, str], body: bytes) -> tuple[int, str]:
        if (run_id := self._run(headers)) is None:
            return 401, json.dumps({"error": "a registered run's token is required"})
        if method != "POST":
            # No stream from the server: each answer is the reply to its own POST.
            return 405, ""
        try:
            request = json.loads(body or b"{}")
        except (ValueError, RecursionError):
            return 200, _error(None, -32700, "parse error")
        if not isinstance(request, dict):
            return 200, _error(None, -32600, "a message must be a JSON object")
        request_id, name = request.get("id"), request.get("method")
        if request_id is None:
            # A notification -- notifications/initialized among them -- has no answer.
            return 202, ""
        return 200, await self._respond(run_id, request_id, name, request.get("params"))

    async def _respond(self, run_id: str, request_id: Any, name: Any, params: Any) -> str:
        if name == "initialize":
            return _answer(request_id, {"protocolVersion": MCP_PROTOCOL_VERSION, "capabilities": {"tools": {"listChanged": False}},
                                        "serverInfo": {"name": "aiterm", "version": "1"}})
        if name == "ping":
            return _answer(request_id, {})
        if name == "tools/list":
            return _answer(request_id, {"tools": list(TOOLS)})
        if name == "tools/call":
            return await self._call(run_id, request_id, params)
        return _error(request_id, -32601, f"method not found: {name}")

    async def _call(self, run_id: str, request_id: Any, params: Any) -> str:
        tool = params.get("name") if isinstance(params, dict) else None
        arguments = params.get("arguments") if isinstance(params, dict) else None
        if arguments is None:
            arguments = {}
        if not isinstance(tool, str) or tool not in TOOL_NAMES or not isinstance(arguments, dict):
            return _error(request_id, -32602, f"no such tool, or arguments that are not an object: {tool}")
        try:
            result = await self.ask_app(run_id, tool, arguments)
        except ToolError as exc:
            return _answer(request_id, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
        return _answer(request_id, {"content": [{"type": "text", "text": json.dumps(result)}], "structuredContent": result,
                                    "isError": False})

    async def ask_app(self, run_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        """The app's answer to one tool call: broadcast as `operator.request` and awaited until its
        `operator.reply`, for OPERATOR_REQUEST_TIMEOUT at most. Raises ToolError with what the
        operator is told: the app's own error, NOT_OPEN with no app attached, NOT_ANSWERING after the
        timeout -- after which the app may still have acted, which every mutating tool's key makes
        safe to repeat (spec §11)."""
        if self.client_count() == 0:
            raise ToolError(NOT_OPEN)
        request_id = f"op-{next(self._ids)}"
        answer: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = answer
        try:
            await self.broadcast(protocol.OPERATOR_REQUEST, {"requestId": request_id, "runId": run_id, "tool": tool,
                                                             "arguments": arguments})
            async with asyncio.timeout(delivery.OPERATOR_REQUEST_TIMEOUT):
                return await answer
        except TimeoutError as exc:
            raise ToolError(NOT_ANSWERING) from exc
        finally:
            self._pending.pop(request_id, None)

    # -- the app's half, over the socket ----------------------------------
    async def register(self, p: Any) -> dict[str, Any]:
        """operator.register: opens /operator to a run's token, in memory. The app sends it when a
        run starts, beside the token file it writes, which is what a restarted daemon reads."""
        run_id, token = param(p, "runId", str), param(p, "token", str)
        try:
            self.tokens.register(run_id, token)
        except ValueError as exc:
            raise RpcError(protocol.BAD_PARAMS, str(exc)) from exc
        return {}

    async def revoke(self, p: Any) -> dict[str, Any]:
        """operator.revoke: closes /operator to a run's token -- a stopped run's (spec §9) -- and
        deletes its token file, so no restart brings it back."""
        self.tokens.revoke(param(p, "runId", str))
        return {}

    async def reply(self, p: Any) -> dict[str, Any]:
        """operator.reply: the app's answer to an operator.request, its result or the error the
        operator is told. One nobody waits for any more -- timed out, or answered already -- is dropped."""
        request_id = param(p, "requestId", str)
        result, error = optional_param(p, "result", dict), optional_param(p, "error", str)
        answer = self._pending.get(request_id)
        if answer is None or answer.done():
            log.info("dropped the app's reply to %s: nothing waits for it", request_id)
            return {}
        if error is not None:
            answer.set_exception(ToolError(error))
        else:
            answer.set_result(result if result is not None else {})
        return {}
