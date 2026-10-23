"""The operator's MCP server (Operators spec §5, §6): the run tokens that open it, the tools it
serves, and the `/operator` route that forwards every tool call to the app."""
from __future__ import annotations

import asyncio
import hmac
import itertools
import uuid
import json
import logging
import os
import re
import stat
import time
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from . import delivery, mcp, protocol
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


def _gate_open(why: str) -> str:
    """The gate's answer when it cannot ask: allow, saying the command ran unchallenged."""
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                                              "permissionDecisionReason": f"AiTerm ran this command unchallenged: {why}"}})


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
        self._revoked: set[str] = set()
        self._loaded_at = float("-inf")
        self._root_stamp: int | None = None
        self._load()

    def register(self, run_id: str, token: str) -> None:
        """Opens /operator to `token` for `run_id`, in place of any token the run had. In memory:
        the file is the app's to write."""
        if not well_formed(token):
            raise ValueError("a run token is 64 hex characters")
        if (owner := self._runs.get(token)) is not None and owner != run_id:
            raise ValueError("that token belongs to another run")
        self._forget(run_id)
        self._revoked.discard(run_id)
        self._runs[token], self._tokens[run_id] = run_id, token

    def revoke(self, run_id: str) -> None:
        """Closes /operator to the run for good: its token leaves memory, and its file goes, so no
        later read of the folder brings it back. The run folder itself is the app's."""
        self._forget(run_id)
        self._revoked.add(run_id)
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
            stamp = self._root.stat().st_mtime_ns
            if stamp == self._root_stamp and time.monotonic() - self._loaded_at < 1:
                return
            self._root_stamp, self._loaded_at = stamp, time.monotonic()
            folders = [path for path in self._root.iterdir() if path.is_dir()]
        except OSError:
            return  # no runs yet
        for folder in folders:
            if folder.name in self._revoked:
                continue
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
_END = _choice("Where the task ends, from the broadcast's Done when: commit; draftMR, push and open a draft merge request; "
               "merge, push, open a merge request and merge it once the host says it can be; or mergeLocal, merge the "
               "accepted commit into the project's own default branch, with nothing pushed. A merge needs the broadcast's "
               "Merge slice. Left out, a task ends at a draftMR, or at a commit when the Done says a commit.",
               "commit", "draftMR", "merge", "mergeLocal")
_MODEL = _text("A model id from the agent's own list, as run_status shows it under agents. Left out, the agent's default. "
               "A model not in that list is refused.")
_DEPENDS_ON: dict[str, Any] = {
    "type": "array",
    "description": "What the task waits for. An order dependency waits until the other task is accepted or needs no change; "
                   "a code dependency also builds on its accepted commit, in the same project. At most one code dependency.",
    "items": {"type": "object", "additionalProperties": False, "required": ["task", "kind"],
              "properties": {"task": _TASK, "kind": _choice("order or code.", "order", "code")}},
}
_CHALLENGE = {
    "challengeId": _text("The challengeId a challenged call returned: send it with your revised arguments, or with "
                         "challengeReply. A reply that says pending has no answer yet: call again with its challengeId "
                         "and the same arguments. For create_task and finish_task, the call again acts only on the Oracle's "
                         "yes. The same "
                         "challengeId again, once answered, returns the recorded result."),
    "challengeReply": _text("Your answer to each point of the second opinion's critique, when you keep the act as it was."),
}
# The tools the Oracle can challenge (spec §8): the first call returns a critique, and only the call
# that answers it, with its challengeId, takes effect. An Oracle not back within the app's 20 s answers
# {"challenged": true, "challengeId": …, "critique": null, "pending": true}, and the operator calls
# again with that challengeId (integration decision 3). Whether a call is challenged follows the
# broadcast's Oracle switch, and is the app's to decide. A create_task past the backlog's threshold, and a
# finish_task that would merge, get the Oracle's yes or no the same way: it may answer pending, and only a yes acts.
CHALLENGED_TOOLS = ("submit_plan", "mark_task", "create_task", "finish_task")


def _tool(name: str, description: str, properties: dict[str, Any] | None = None, required: tuple[str, ...] = ()) -> dict[str, Any]:
    """One tool as MCP's tools/list serves it. A closed schema: the Operator's model shapes its calls
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
    _tool("run_status", "The broadcast now, numbered by revision: every task with its state, live status, branch, last commit "
          "and a one-line summary, and what is open: questions waiting, prompts waiting on the person (a prompt open in a "
          "worker's terminal), tasks ready to accept, "
          "tasks whose worker ended its turn with work still running in the background (under background; each task's "
          "background lists the commands, and the worker wakes on its own when they end, so it is not ready yet), "
          "tasks possibly stalled, anything uncertain. A worker whose live reads working? says working but its transcript has not "
          "grown for two minutes, so the flag may be stuck: it is listed under uncertain, so look at the worker before trusting "
          "it. A task whose worker the person is driving, by a prompt they typed "
          "into its window themselves, says youAreDriving with yourPrompt, its first line, until that turn ends: leave that "
          "worker alone meanwhile, and read its result afterwards as you would one of your own. "
          "A task with tabs added by open_tab lists every worker tab under tabs, "
          "its first worker as main, and is ready to accept only once every tab ended its turn; a prompt in an added tab is "
          "named task/tab, and a tab that was closed is marked closed and never opened again. "
          "Under run it also shows the off-brief finds, the snags you recorded with report_snag (so you don't record one "
          "twice after a restart), each agent's weekly use, and under agents each installed agent's models with its default "
          "model and, under delivery, whether its workers can be messaged. A task with a merge request shows what the host "
          "says of it under mergeRequest (draft, pipeline, mergeable, approvedBy, head), or why it could not be read "
          "under mergeRequestNote. Call it first after any restart or compaction."),
    _tool("jira_search", "Searches Jira, read-only, within the Jira projects linked to the broadcast's projects.",
          {"jql": _text("The JQL query.")}, ("jql",)),
    _tool("jira_create", "Creates a Jira ticket in one of the broadcast's Jira projects. Refused unless the broadcast's Jira slice "
          "is on, and outside its Jira projects; AiTerm then leaves it for the person. The same key returns the ticket "
          "the first call made, so call again with it after a lost reply.",
          {"key": _KEY, "project": _text("The Jira project's key, one of the broadcast's."),
           "type": _text("The issue type, such as Task, Bug or Story."),
           "summary": _text("The ticket's title."), "description": _text("What the ticket says, in plain text."),
           "parent": _text("The key of the epic or parent ticket it belongs under, if any.")},
          ("key", "project", "type", "summary", "description")),
    _tool("jira_move", "Moves a Jira ticket to the status of that name, by the transition that leads there. Refused unless the "
          "broadcast's Jira slice is on, and outside its Jira projects. A status the ticket cannot reach from where it is "
          "is refused with the statuses it can reach.",
          {"key": _text("The ticket's key, such as PAY-231."), "status": _text("The status to move it to, such as In Review or Done.")},
          ("key", "status")),
    _tool("jira_link", "Links two Jira tickets, read from the first: the first blocks, relates to or duplicates the second. "
          "Refused unless the broadcast's Jira slice is on, and when either is outside its Jira projects.",
          {"key": _text("The ticket the link is read from."), "to": _text("The ticket it points to."),
           "type": _text("The Jira link type's name, such as Blocks, Relates or Duplicate.")},
          ("key", "to", "type")),
    _tool("jira_board", "Reads the Jira boards of each of the broadcast's Jira projects: for each board its id, name and type, "
          "its active and future sprints (id, name, state, dates; only a scrum board has any) and its columns with the "
          "statuses in each. Read-only; needs no slice. Use a sprint's id with jira_sprint, and a column's status names "
          "with jira_move."),
    _tool("jira_sprint", "Puts Jira tickets in an active or future sprint, or back on the backlog. The tickets must be in "
          "the broadcast's Jira projects, and a sprint must be on one of their boards (jira_board lists them). Refused "
          "unless the broadcast's Jira slice is on; AiTerm then leaves it for the person. The same key again moves "
          "nothing, so call again with it after a lost reply.",
          {"key": _KEY, "tickets": {"type": "array", "items": {"type": "string"},
                                    "description": "The tickets' keys, such as PAY-231; at most 50."},
           "sprint": {"type": ["integer", "string"],
                      "description": "The sprint's id from jira_board, or backlog to take the tickets out of their sprints."}},
          ("key", "tickets", "sprint")),
    _tool("jira_edit", "Edits a ticket of one of the broadcast's Jira projects: its summary, description, labels (added and "
          "removed, the others stay), priority, fix versions or assignee. Name at least one. Refused unless the broadcast's "
          "Jira slice is on, and outside its Jira projects; AiTerm then leaves it for the person. Setting the same values "
          "again changes nothing, so call again after a lost reply.",
          {"key": _KEY, "ticket": _text("The ticket's key, such as PAY-231."),
           "summary": _text("The new title."),
           "description": _text("The new description, in plain text; it replaces the old one, and an empty one clears it."),
           "labelsAdd": {"type": "array", "items": {"type": "string"}, "description": "Labels to add."},
           "labelsRemove": {"type": "array", "items": {"type": "string"}, "description": "Labels to remove."},
           "priority": _text("The priority's name, such as High."),
           "fixVersions": {"type": "array", "items": {"type": "string"},
                           "description": "The version names the ticket ends with, replacing its fix versions; empty clears them."},
           "assignee": _text("me, none, or a name or email that matches exactly one person Jira can assign the ticket to; "
                             "several matches are refused with their names.")},
          ("key", "ticket")),
    _tool("jira_comment", "Comments on a ticket of one of the broadcast's Jira projects. A comment reaches the ticket's "
          "watchers, so write it for them. Refused unless the broadcast's Jira slice is on, and outside its Jira projects; "
          "AiTerm then leaves it for the person. The same key again posts nothing: after a lost reply call again with it, and "
          "AiTerm looks for the comment on the ticket before it posts anything.",
          {"key": _KEY, "ticket": _text("The ticket's key, such as PAY-231."), "body": _text("The comment, in plain text.")},
          ("key", "ticket", "body")),
    _tool("create_task", "Adds an unstarted task to the open plan revision, in one of the broadcast's projects. The same key "
          "in this broadcast returns the task already made. Once the first plan is submitted, additions past a quarter of its "
          "size need the Oracle's yes. One the Oracle refuses, or any past that limit with the Oracle off, is refused and "
          "noted for the summary by AiTerm.",
          {"key": _KEY, "title": _text("The task's title, as its row shows it."),
           "brief": _text("The worker's first prompt: everything it needs, since it sees nothing else."),
           "project": _text("The project it belongs to, one of the broadcast's, by name or by id from run_status."),
           "ticket": _text("The Jira key it works, if any."),
           "issueType": _text("The Jira issue type, or feat, fix or chore. Sets the branch prefix."),
           "agent": _AGENT, "model": _MODEL,
           "modelReason": _text("Why this agent and model, in one line, as the task's card and the summary show it."),
           "agentPinned": {"type": "boolean", "description": "True when the person's words named this task's agent: it then "
                                                             "starts on that agent whatever its weekly use."},
           "end": _END, "dependsOn": _DEPENDS_ON},
          ("key", "title", "brief", "project", "agent", "modelReason")),
    _tool("update_task", "Changes an unstarted task's brief, agent, model, end or dependencies. Steer a started task with "
          "message_task instead.",
          {"task": _TASK, "brief": _text("The new brief."), "agent": _AGENT, "model": _MODEL, "end": _END,
           "dependsOn": _DEPENDS_ON}, ("task",)),
    _tool("submit_plan", "Closes a plan revision: its planned tasks are queued at once, with nothing to approve. "
          "Submitting the same revision again returns the earlier result.",
          {"revision": {"type": "integer", "description": "The revision run_status shows open."}}, ("revision",)),
    _tool("read_task", "Reads a task: its worker's last message, its diff, the prompt open in its session, or its review: the "
          "agent review's findings, and for a task whose request people review, its threads with their ids, who approved "
          "and who was asked. A task with tabs added by open_tab: tab names the one whose last message or prompt to read. "
          "A key the task has no tab for is refused with its tabs.",
          {"task": _TASK, "what": _choice("lastMessage, diff, prompt or review.", "lastMessage", "diff", "prompt", "review"),
           "tab": _text("For lastMessage and prompt, the key of the tab to read, as run_status lists it. Left out, or main, "
                        "the first worker.")},
          ("task", "what")),
    _tool("review_task", "Starts an agent review of a working task's branch, or its accepted commit while inReview: another agent "
          "reads its commits, diff and worktree headless and read-only, as instructions asks, a skill they name passed to it as text. "
          "Nobody is notified, so it needs no slice. It answers started at once; AiTerm wakes you when the findings are in, "
          "and read_task with what: review reads them. Have the task's agent fix them with message_task. A review running "
          "already, or the same review of the same commit, is not started again.",
          {"task": _TASK, "instructions": _text("What the review checks and how, from the broadcast's Review, such as "
                                                "an adversarial review with /review-skill."),
           "agent": _choice("Who reviews: claude, codex or pi. Left out, the other of Claude and Codex from the task's own agent.",
                            "claude", "codex", "pi")},
          ("task", "instructions")),
    _tool("request_review", "Marks a task's merge request ready and asks people to review it. Refused unless the broadcast's "
          "Review slice is on; AiTerm then leaves it for the person. The same reviewers again change nothing.",
          {"task": _TASK, "reviewers": {"type": "array", "items": {"type": "string"},
                                        "description": "The usernames to ask, as find_user gives them."}},
          ("task", "reviewers")),
    _tool("reply_thread", "Replies in a review thread on a task's merge request, by the thread's id from read_task with what: "
          "review. Refused unless the broadcast's Review slice is on. The same key posts once.",
          {"task": _TASK, "key": _KEY, "thread": _text("The thread's id."), "body": _text("The reply, in plain text.")},
          ("task", "key", "thread", "body")),
    _tool("find_user", "Finds people on the code host of a task's project who may review there, by username or name. It only "
          "reads, so it needs no slice.",
          {"task": _TASK, "query": _text("A username or a name, or part of one.")}, ("task", "query")),
    _tool("message_task", "Sends a started task's worker a message, typed into its session by AiTerm's rules. Returns "
          "delivered, partial (pasted, its Enter held back) or refused, with the reason; nothing is retried. A task with tabs "
          "added by open_tab: tab names the one to message. A key the task has no tab for is refused with its tabs. "
          "Messaging an accepted task that isn't published yet sends it back to working; accept its new commit again.",
          {"task": _TASK, "text": _text("The message."),
           "tab": _text("The key of the tab to message, as run_status lists it. Left out, or main, the first worker.")},
          ("task", "text")),
    _tool("open_tab", "Adds a worker tab to a task that is working or in review: another agent in the task's window, on the "
          "same worktree and branch, for more work on that task. It is part of the task: one card, one branch, accepted once. "
          "Its first prompt is your brief, after AiTerm's lines on where it works and that it shares the worktree. It opens "
          "behind the person's work. The same key on the same task returns the first call's tab and opens nothing more; the same "
          "key with other arguments is refused. Returns the tab's key, agent, model, and opened or opening.",
          {"task": _TASK, "key": _KEY, "agent": _AGENT, "model": _MODEL,
           "modelReason": _text("Why this agent and model, in one line."),
           "agentPinned": {"type": "boolean", "description": "True when the person's words named this agent: an agent whose "
                                                             "workers can't be messaged is then not refused."},
           "brief": _text("The tab's first prompt: what this worker does, since it sees nothing else.")},
          ("task", "key", "agent", "modelReason", "brief")),
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
    _tool("finish_task",
          "Carries out an accepted task's end from the plan, for its accepted commit only. "
          "draft MR: pushes the task's own branch and opens a draft merge request; a stacked task's targets "
          "its parent's branch, so finish the parent first. "
          "merge: pushes, opens a merge request and merges it at the accepted commit, once the host calls it "
          "mergeable with its pipelines green, read twice at least 30 seconds apart. A stacked task waits for its "
          "parent's merge, then retargets to the default branch. While it waits this answers waitingToMerge, and "
          "AiTerm wakes you when it merged or is blocked; after about an hour of waiting it answers blocked. A failed "
          "pipeline or a conflict blocks it: have the worker fix it, accept the new commit, and call finish_task "
          "again. A task that ends in a commit has nothing to finish. "
          "With the broadcast's Review written and its Review slice on, the request opens as a draft and the task "
          "goes into review instead, answering inReview: AiTerm wakes you on people's feedback, and the next "
          "finish_task after the last fix ends the review, a draft end published, a merge end going on to merge. "
          "A merge, through the request or local, is refused unless the broadcast's Merge slice is on; AiTerm then "
          "leaves it for the person. Before it merges a request that is still a draft, AiTerm marks it ready, only to "
          "merge it, and it merges only with every one of its review threads resolved. "
          "mergeLocal: merges the accepted commit into the project's own checkout's default branch and never pushes; "
          "that checkout must be on its default branch with nothing uncommitted. AiTerm leaves the push for the person, "
          "as \"Push main in <project>: merged locally.\" "
          "With the Oracle on, a finish_task that would merge first needs the Oracle's yes that the conditions written "
          "in the Review and the Done hold; a no is recorded on the task and refuses the merge. "
          "A push the repository's pre-push hook refused fails with the hook's output as its reason. noVerify pushes past "
          "the hook, and only after such a refusal; with the Oracle on it first needs the Oracle's yes that the hook failed "
          "on the environment, not the code, judged from that output and your reason. A call that also merges asks both at "
          "once, and only a yes to both acts. "
          "It answers result: published, inReview, waitingToMerge, blocked, refused or failed, with reason, mergeRequest, "
          "pushedSHA, merged and mergedSHA as far as they are known; refused and failed also say what was already "
          "done. draftNote says what this call did to the request's draft state (opened as a draft, opened ready, "
          "left as a draft, marked ready), and is left out when it did nothing. "
          "Each step is recorded and calling again resumes at the next step: it never pushes or opens a request "
          "twice, and on a task that is done it answers what was done. A push that timed out may have landed: call "
          "finish_task again. A takeover stops a merge's waiting: call finish_task again once the task is handed "
          "back. "
          "Refused if the task ends in a commit, the task was taken over, its branch moved past the accepted commit, "
          "its parent was accepted again, the broadcast is paused, stopped or offline, the host protects its branch "
          "or cannot say whether it does, or it is the default branch. "
          "AiTerm never deploys, never force-pushes, and never pushes to a default or protected branch.",
          {"task": _TASK,
           "noVerify": {"type": "boolean", "description": "Skip the repository's push hooks: only when the hook failed on the "
                        "environment and your repair didn't work. The Oracle judges it."},
           "reason": _text("With noVerify: what you tried to repair the environment, for the Oracle. Left out, it reads your "
                           "last shell commands in the task's worktree.")},
          ("task",)),
    _tool("ask_you", "Lists a question you asked in your chat under Waiting on you, with the same text, and notifies the person. "
          "They answer in this window; close it with resolve_question. The same key returns the open question.",
          {"key": _KEY, "question": _text("The question, complete on its own."),
           "task": _text("Only when that task's worker is itself stopped on the answer: the task, by its key or its id from "
                         "run_status. Your row then shows waiting on the person, naming the task, and the task waits for the answer: it "
                         "isn't ready to accept and isn't watched for stalls until you resolve the question. "
                         "Left out for a question about your own next step, such as a reviewer's username, a scope choice or a "
                         "merge decision.")},
          ("key", "question")),
    _tool("resolve_question", "Closes a question once the person has answered it, with a one-line summary of the answer: one "
          "you asked with ask_you, or AiTerm's question about a merge on the host, which only the person decides. Call it at "
          "once when they answer in your chat. A worker's prompt is refused: AiTerm closes it itself once the worker leaves "
          "the prompt. A gate- question, opened when your shell's command needs the person's word, is answered with allow "
          "true or false, from what the person said in this chat.",
          {"key": _text("The question's key."), "summary": _text("The answer, in one line."),
           "allow": {"type": "boolean", "description": "For a gate- question only: whether the person allowed the command."}},
          ("key", "summary")),
    _tool("report_find", "Records something off-brief that you or an agent found, such as a leak in another module: it is not "
          "worked on, and the summary may mention it with why it matters. With the broadcast's Jira slice on, AiTerm also files it as a "
          "Task in the first of its Jira projects and answers the ticket's key, or why it could not. The same key is recorded once.",
          {"key": _KEY, "title": _text("The find, in a few words."), "why": _text("Why it matters, in one line.")},
          ("key", "title", "why")),
    _tool("report_snag", "Records that AiTerm itself showed you something wrong and you worked around it: a state that was not "
          "true, a prompt it missed, a tab it lost. After you checked the real source (the tab, git, the host), say what AiTerm "
          "showed, what was true, and how you got unstuck. AiTerm keeps it beside the summary, and the person can start an "
          "AiTerm task from it to fix the bug. A find (report_find) is about the project's code; a snag is about AiTerm itself. "
          "It needs no slice, and nothing is filed or sent. The same key is recorded once.",
          {"key": _KEY, "title": _text("The snag, in a few words."),
           "showed": _text("What AiTerm showed, such as a status or a count, in one sentence."),
           "actual": _text("What was true, and how you checked it, in one sentence."),
           "workaround": _text("What you did to carry on, in one sentence."),
           "evidence": _text("Optional: the exact text, state or output that shows it, such as a line from the tab."),
           "task": _text("The task it happened on, by its key or its id from run_status. Left out when it is not about a task.")},
          ("key", "title", "showed", "actual", "workaround")),
    _tool("leave_for_you", "Records what a slice kept you from doing, naming what is left and why. "
          "It changes no task and sends nothing. The same key is recorded once.",
          {"key": _KEY, "text": _text("What is left for the person and why, in one sentence.")}, ("key", "text")),
    _tool("log_decision", "Writes a decision you took on your own to the broadcast's log, for the summary. The same key is "
          "written once.",
          {"key": _KEY, "text": _text("The decision, in a few words."), "task": _TASK,
           "why": _text("Why you decided it, in one sentence."),
           "objection": _text("The Oracle's objection, when you decided against it.")}, ("key", "text")),
    _tool("write_summary", "When the broadcast is complete, write its summary with write_summary: a few short paragraphs, in "
          "plain prose, no lists or headings. Say what was done and how it went, honestly: what went wrong and how it was "
          "handled, not only what succeeded. Fold in what you decided on your own and what you found along the way. Keep it "
          "short enough to read in a minute. Refused until the broadcast is complete; calling it again replaces the summary.",
          {"text": _text("The summary: a few short paragraphs of plain prose.")}, ("text",)),
)
TOOL_NAMES = frozenset(tool["name"] for tool in TOOLS)



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
        # unique across route lifetimes; an answer from before a restart finds nothing and is dropped.
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._ids = itertools.count(1)
        self._prefix = uuid.uuid4().hex

    def _run(self, headers: dict[str, str]) -> str | None:
        token = mcp.bearer(headers.get("authorization", ""))
        return self.tokens.run_for(token) if token else None

    async def serve(self, method: str, headers: dict[str, str], body: bytes) -> tuple[int, str]:
        if (run_id := self._run(headers)) is None:
            return 401, json.dumps({"error": "a registered run's token is required"})
        if method != "POST":
            # No stream from the server: each answer is the reply to its own POST.
            return 405, ""
        try:
            request = json.loads(body or b"{}")
        except (ValueError, RecursionError):
            return 200, json.dumps(mcp.error(None, -32700, "parse error"), separators=(",", ":"))
        if not isinstance(request, dict):
            return 200, json.dumps(mcp.error(None, -32600, "a message must be a JSON object"), separators=(",", ":"))
        request_id, name = request.get("id"), request.get("method")
        if request_id is None:
            # A notification -- notifications/initialized among them -- has no answer.
            return 202, ""
        response = mcp.respond(request_id, name, TOOLS)
        if response is None:
            response = await self._call(run_id, request_id, request.get("params"))
        return 200, json.dumps(response, separators=(",", ":"))

    async def _call(self, run_id: str, request_id: Any, params: Any) -> dict[str, Any]:
        tool = params.get("name") if isinstance(params, dict) else None
        arguments = params.get("arguments") if isinstance(params, dict) else None
        if arguments is None:
            arguments = {}
        if not isinstance(tool, str) or tool not in TOOL_NAMES or not isinstance(arguments, dict):
            return mcp.error(request_id, -32602, f"no such tool, or arguments that are not an object: {tool}")
        try:
            result = await self.ask_app(run_id, tool, arguments)
        except ToolError as exc:
            return mcp.answer(request_id, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
        return mcp.answer(request_id, {"content": [{"type": "text", "text": json.dumps(result)}], "structuredContent": result,
                                    "isError": False})

    async def ask_app(self, run_id: str, tool: str, arguments: dict[str, Any],
                      timeout: float | None = None) -> dict[str, Any]:
        """The app's answer to one tool call: broadcast as `operator.request` and awaited until its
        `operator.reply`, for `timeout` at most (OPERATOR_REQUEST_TIMEOUT unless given). Raises ToolError with what the
        operator is told: the app's own error, NOT_OPEN with no app attached, NOT_ANSWERING after the
        timeout -- after which the app may still have acted, which every mutating tool's key makes
        safe to repeat (spec §11)."""
        if self.client_count() == 0:
            raise ToolError(NOT_OPEN)
        request_id = f"op-{self._prefix}-{next(self._ids)}"
        answer: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = answer
        try:
            await self.broadcast(protocol.OPERATOR_REQUEST, {"requestId": request_id, "runId": run_id, "tool": tool,
                                                             "arguments": arguments})
            async with asyncio.timeout(delivery.OPERATOR_REQUEST_TIMEOUT if timeout is None else timeout):
                return await answer
        except TimeoutError as exc:
            raise ToolError(NOT_ANSWERING) from exc
        finally:
            self._pending.pop(request_id, None)

    async def gate(self, method: str, headers: dict[str, str], body: bytes) -> tuple[int, str]:
        """The Operator's Claude Code `PreToolUse` hook on its Bash calls (/operator/gate): the command
        goes to the app as `gate_command` -- no MCP tool, so the Operator cannot call it -- and the
        app's allow or deny comes back as Claude's hook JSON, an allow with a rewrite carrying it as
        `updatedInput`. Waits GATE_TIMEOUT for the app. Fails open: with no app, no answer in time, a
        bad token, a body or an answer it cannot read, the command is allowed and the reason says it
        ran unchallenged, since a gate that is closed must not stall the Operator."""
        if (run_id := self._run(headers)) is None:
            return 200, _gate_open("a registered run's token was missing")
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
                                        timeout=delivery.GATE_TIMEOUT)
        except ToolError as exc:
            return 200, _gate_open(str(exc))
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
        result, error = p.get("result"), optional_param(p, "error", str)
        if isinstance(result, list):
            # List tools (jira_search, find_user) answer arrays. MCP's structuredContent
            # needs an object, so normalize every list reply at this shared boundary.
            result = {"items": result}
        elif result is not None and not isinstance(result, dict):
            raise RpcError(protocol.BAD_PARAMS, "result must be an object or array")
        answer = self._pending.get(request_id)
        if answer is None or answer.done():
            log.info("dropped the app's reply to %s: nothing waits for it", request_id)
            return {}
        if error is not None:
            answer.set_exception(ToolError(error))
        else:
            answer.set_result(result if result is not None else {})
        return {}
