# daemon/aitermd/service.py
from __future__ import annotations
import asyncio
import logging
import time
from collections.abc import Awaitable, Callable, Mapping
from pathlib import Path
from typing import Any, TypeVar, cast

from . import protocol
from .agents import agy, claude, codex, pi
from .agents.claude import BackgroundTranscripts, ClaudeSessionFiles, StopTranscripts, SubagentTranscripts
from .agents.codex import CODEX_READ, CodexSessionFiles, CodexThreads
from .connection import ItermSupervisor
from .corroboration import CorroboratingReaders, ReadPlan, logged as _logged
from .delivery import NOT_CHECKED, Deliverer, Verdict, read_policy
from .hook_router import HookRouter
from .hooks_server import HookServer
from .iterm_port import ItermPort
from .keystrokes import YOUR_PROMPT_SECONDS, TypingGuard
from .offload import run_detached
from .operator_mcp import OperatorRoute
from .operator_session import OperatorSessionTokens
from .publisher import Publisher
from .resolver import SessionResolver
from .rpc_params import frame_param, guard, optional_param, param, require_iterm
from .rpc_server import RpcError, RpcServer
from .models import HARNESS_BY_AGENT, AgentKind, RawSession, SessionInfo
from .sessions import SessionRegistry, SnapshotDiff
from .status import StatusEngine
from .test_activity import TestActivityReader
from .usage import UsageReadFailure, UsageStore
from .windows import WindowManager

log = logging.getLogger(__name__)


POLL_SECONDS = 2.0
# How long a tick waits for a check it runs on a worker thread: the subagent transcripts, the Codex
# rollouts.
OFF_LOOP_CHECK_SECONDS = 1.0

T = TypeVar("T")


class Service:
    """The daemon's composition root: builds the registry, status engine and usage store, wires
    the supervisor, the hook router and the window manager to them, answers the RPC methods none
    of those own, and polls iTerm2 into the registry."""

    def __init__(self, iterm: ItermPort, rpc: RpcServer, hooks: HookServer, claude_files: ClaudeSessionFiles,
                 clock: Callable[[], float], codex_files: CodexSessionFiles,
                 supervisor: ItermSupervisor | None = None, monotonic: Callable[[], float] = time.monotonic,
                 delivery_policy: Callable[[], Mapping[AgentKind, Verdict]] | None = None,
                 operator_folder: Path | None = None, test_activity: TestActivityReader | None = None):
        self.iterm, self.rpc, self.hooks = iterm, rpc, hooks
        # `clock` is the wall clock, in seconds. Fractional: the status engine stamps each hook with
        # it and compares the stamp with a session file's mtime, which a whole second would blur.
        self.claude_files, self.codex_files, self.clock = claude_files, codex_files, clock
        # A Claude already present on the first successful snapshot may have launched work since daemon startup.
        self._initial_snapshot_since: float | None = clock()
        # Claude's folder as the app last named it, which a snapshot echoes as it was sent: the app compares
        # the strings, and pathlib would spell some paths otherwise ("a/./b" as "a/b").
        self._claude_directory: str | None = None
        self.supervisor = supervisor or ItermSupervisor(iterm, rpc.broadcast, lambda: rpc.client_count)
        self.registry = SessionRegistry()
        self.status = StatusEngine(self.registry, clock, monotonic)
        self.usage = UsageStore()
        self.resolver = SessionResolver(self.registry, claude_files)
        self.codex_threads = CodexThreads(self.registry, iterm)
        self.publisher = Publisher(rpc.broadcast, self.registry, self.usage)
        self.hook_router = HookRouter(self.resolver, self.codex_threads, self.status, self.usage, clock, self.publisher, tick=self.tick)
        self.hooks.on_post = self.hook_router.handle_hook
        self.windows = WindowManager(iterm, self.registry, self.tick, typed_in=lambda sid: self.typing.typed_in(sid))
        self.supervisor.on_connected = self.windows.forget_titles
        self.supervisor.on_launched_connected = self.windows.capture_startup_window
        # The delivery adapter, and when you last typed in each session, which
        # holds back an operator's wake line. The policy is read on every delivery, so the
        # delivery check that writes it needs no restart.
        self._monotonic = monotonic
        self.typing = TypingGuard(self.iterm.keystroke_epoch)
        self.deliverer = Deliverer(iterm, self.registry, delivery_policy or read_policy, self.typing, monotonic=monotonic)
        self.hook_router.typed_by_you = self._typed_by_you
        self.readers = CorroboratingReaders(self.registry, self.status, iterm, clock)
        # The operator's MCP server, on the hook server's port: its tool calls
        # are forwarded to the attached app, which answers them over this socket.
        # `operator_folder` is where the app keeps the Operator's token file, which a restarted daemon loads;
        # None keeps tokens in memory only.
        self.operators = OperatorRoute(rpc.broadcast, lambda: rpc.client_count, OperatorSessionTokens(operator_folder))
        self.hooks.operator_route = self.operators
        self._poll_task: asyncio.Task[None] | None = None
        # window.setFrame, window.activate and session.activate each leave a state the next one replaces, and the app
        # sends them from separate tasks; requests are answered concurrently, so they take this in
        # turn, in the order they came, and the last one sent is the one that stays.
        self._placement_lock = asyncio.Lock()
        self._tick_lock = asyncio.Lock()
        # Ticks started so far, and the number of the last to finish without raising: a tick whose
        # caller asked before another started and finished has nothing left to read.
        self._ticks_started = 0
        self._last_good_tick = 0
        self.subagent_transcripts = SubagentTranscripts()
        self.background_transcripts = BackgroundTranscripts(clock=clock)
        self.stop_transcripts = StopTranscripts()
        self.test_activity = test_activity or TestActivityReader(clock=clock)
        # Each off-loop check's latest run, by name, while its worker thread may still be running: a
        # thread stuck on a hung mount cannot be cancelled, so no second one is started beside it.
        self._checks: dict[str, asyncio.Future[Any]] = {}
        self._register_handlers()

    # -- lifecycle ---------------------------------------------------------
    async def start(self) -> None:
        self.iterm.on_new_session(self.windows.on_new_session)
        self.iterm.on_session_closed(self._on_session_closed)
        self.iterm.on_window_activated(self._on_window_activated)
        self.iterm.on_keystroke(self._on_keystroke)
        await self.rpc.start()
        try:
            await self.hooks.start()
        except BaseException:
            await self.rpc.stop()
            raise
        await self.supervisor.start()
        self._poll_task = asyncio.get_running_loop().create_task(self._poll_forever())

    async def stop(self) -> None:
        if (task := self._poll_task) is not None and task is not asyncio.current_task():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        await self.hooks.stop()
        await self.hook_router.stop()
        await self.supervisor.stop()
        await self.rpc.stop()

    async def _poll_forever(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:
                log.exception("tick failed")
            await asyncio.sleep(POLL_SECONDS)

    # -- RPC ---------------------------------------------------------------
    def _register_handlers(self) -> None:
        r = self.rpc.register
        r("iterm.status", self.supervisor.status)
        r("iterm.provideCookie", self.supervisor.provide_cookie)
        r("workspace.snapshot", self._h_snapshot)
        r("window.createTask", self.windows.create_task)
        r("window.createTerminal", self.windows.create_terminal)
        r("window.activate", lambda p: self._place(self.iterm.activate_window, param(p, "windowId", str)))
        r("session.activate", lambda p: self._place(self.iterm.activate_session, param(p, "sessionId", str)))
        r("window.setFrame", lambda p: self._place(self.iterm.set_frame, param(p, "windowId", str), frame_param(p)))
        r("window.close", self._h_close)
        r("tab.create", self.windows.create_tab)
        r("sessions.list", self._h_sessions_list)
        r("sessions.setTitles", self.windows.set_titles)
        r("sessions.markSeen", self._h_mark_seen)
        r("session.deliver", self._h_deliver)
        r("session.closeIdle", self._h_close_idle)
        r("session.inputState", self._h_input_state)
        r("task.setWorkerSessions", self._h_set_worker_sessions)
        r("session.setOwnership", self._h_set_ownership)
        r("delivery.policy", self._h_delivery_policy)
        r("operator.register", self.operators.register)
        r("operator.revoke", self.operators.revoke)
        r("operator.reply", self.operators.reply)
        r("usage.get", self._h_usage_get)
        r("interface.setMatchItermBackground", self.windows.set_match_iterm_background)

    async def _h_snapshot(self, _p: Any) -> dict[str, Any]:
        if isinstance(_p, dict) and "claudeConfigDirectory" in _p:
            directory = param(_p, "claudeConfigDirectory", str)
            if not Path(directory).is_absolute():
                raise RpcError(protocol.BAD_PARAMS, "claudeConfigDirectory must be an absolute path")
            self._claude_directory = directory
            self.claude_files.configure(Path(directory))
        try:
            await self.tick()
        except Exception:  # the last known registry beats no bootstrap at all
            log.exception("tick failed")
        # No await between reading state and returning it. RpcServer writes the reply
        # before yielding, making it a barrier between earlier and later events.
        return {"protocolVersion": protocol.VERSION, **self.supervisor.snapshot_fields(),
                "claudeConfigDirectory": self._claude_directory if self._claude_directory is not None
                else str(self.claude_files.root.parent),
                "sessions": [s.to_json() for s in self.registry.all()],
                "usage": self.usage.snapshot()}

    async def _place(self, action: Callable[..., Awaitable[None]], *args: Any) -> dict[str, Any]:
        """Serialize changes to the selected tab, front window and its frame."""
        async with self._placement_lock:
            require_iterm(self.iterm)
            await guard(action(*args))
        return {}

    async def _h_close(self, p: Any) -> dict[str, Any]:
        window_id = param(p, "windowId", str)
        require_iterm(self.iterm)
        await guard(self.iterm.close_window(window_id))
        try:
            await self.tick()
        except Exception:  # the window is closed either way; the next tick sees it
            log.exception("tick after closing a window failed")
        return {}

    async def _h_sessions_list(self, _p: Any) -> list[dict[str, Any]]:
        try:
            await self.tick()
        except Exception:  # answer with the last known registry when iTerm2 cannot be read
            log.exception("tick failed")
        return [s.to_json() for s in self.registry.all()]

    async def _h_mark_seen(self, p: Any) -> dict[str, Any]:
        changed = self.status.mark_seen(param(p, "taskId", str))
        await self.publisher.session_changed(changed)
        return {"changed": len(changed)}

    async def _h_usage_get(self, _p: Any) -> dict[str, Any]:
        return self.usage.snapshot()

    async def _h_deliver(self, p: Any) -> dict[str, Any]:
        session_id, text, ownership = param(p, "sessionId", str), param(p, "text", str), param(p, "ownership", int)
        wake, worktree = bool(optional_param(p, "wake", bool)), optional_param(p, "worktree", str)
        guard_input = bool(optional_param(p, "guardInput", bool))
        result = await self.deliverer.deliver(session_id, text, ownership, wake=wake, guard_input=guard_input,
                                              worktree=worktree)
        return result.to_json()

    async def _h_close_idle(self, p: Any) -> dict[str, Any]:
        result = await self.deliverer.close_idle(param(p, "sessionId", str), param(p, "ownership", int),
                                                 param(p, "conversation", str))
        return result.to_json()

    async def _h_input_state(self, p: Any) -> dict[str, Any]:
        return {"input": await self.deliverer.input_state(param(p, "sessionId", str))}

    async def _h_set_worker_sessions(self, p: Any) -> dict[str, Any]:
        return await self.windows.set_worker_sessions(p, self.deliverer.set_ownership)

    async def _h_set_ownership(self, p: Any) -> dict[str, Any]:
        self.deliverer.set_ownership(param(p, "sessionId", str), param(p, "ownership", int))
        return {}

    async def _h_delivery_policy(self, _p: Any) -> dict[str, Any]:
        """Each harness's delivery verdict as the Deliverer reads it now (delivery.load_policy): what the
        app tells the Operator before it plans a task on that CLI, and checks against the version installed."""
        verdicts = self.deliverer.policy()
        agents: dict[str, Any] = {}
        for agent in HARNESS_BY_AGENT:
            policy, version = verdicts.get(agent, NOT_CHECKED)
            agents[agent] = {"policy": policy, "version": version}
        return {"agents": agents}

    # -- iTerm2 notifications ------------------------------------------------
    async def _on_window_activated(self, window_id: str) -> None:
        # A macOS notification can bring an iTerm2 window forward without an AiTerm row being
        # clicked. Tell the app which window received focus so it can keep its sidebar selection
        # in sync. The window id is enough: the app owns the task/terminal mapping.
        try:
            await self.rpc.broadcast(protocol.WINDOW_ACTIVATED, {"windowId": window_id})
        except Exception:  # must not escape into the iTerm2 library's dispatch
            log.exception("on_window_activated failed for %s", window_id)

    def _typed_by_you(self, session_id: str) -> bool:
        """Whether the prompt the session submits now is one you typed: you pressed Return there within
        YOUR_PROMPT_SECONDS, and AiTerm pasted nothing there within it."""
        now = self._monotonic()
        return (self.typing.submitted_within(session_id, now, YOUR_PROMPT_SECONDS)
                and not self.deliverer.delivered_within(session_id, now, YOUR_PROMPT_SECONDS))

    async def _on_keystroke(self, session_id: str, characters: str, modifiers: frozenset[str]) -> None:
        # Only the moment and the key's effect on the input are kept (keystrokes.TypingGuard), and
        # nothing here can raise into the library's dispatch.
        self.typing.note_key(session_id, self._monotonic(), characters, modifiers)

    async def _on_session_closed(self, session_id: str) -> None:
        try:
            await self.tick()
        except Exception:  # must not escape into the iTerm2 library's dispatch
            log.exception("on_session_closed failed for %s", session_id)

    # -- polling -------------------------------------------------------------------
    async def tick(self) -> None:
        # The poll loop, iTerm2 notification callbacks, and RPC handlers can
        # all call tick() concurrently; serialize the whole body so a
        # `windows_before` snapshot taken by one call can't be diffed against
        # a `windows_after` produced by an interleaved call (which double-
        # broadcasts window.closed, among other races).
        #
        # Callers queued behind one tick share the next: it starts after all of them asked, so it
        # reads everything each would have. The running one does not count -- it may have read
        # iTerm2 before the change its caller is waiting to see -- and neither does a failed one.
        asked_after = self._ticks_started
        async with self._tick_lock:
            if self._last_good_tick > asked_after:
                return
            self._ticks_started += 1
            number = self._ticks_started
            await self._tick()
            self._last_good_tick = number

    async def _tick(self) -> None:
        self.codex_files.begin_tick()
        try:
            await self._read_codex_usage()
        except Exception:  # another process's file must not stop session polling
            log.exception("reading Codex usage failed")
        if not self.iterm.is_connected():
            return
        before = {s.session_id: s for s in self.registry.all()}
        raw = await self.iterm.snapshot()
        diff = self.registry.apply_snapshot(raw)
        # A session.changed from the snapshot diff is deliberately *not* broadcast as it is found:
        # the status pass can change the same session again in this very tick (its state, its
        # model, the agent's cwd), and two events for one tick make a client redraw twice and,
        # worse, make "the next session.changed" ambiguous. Held back and merged into `changed`, it
        # is re-rendered from the registry once, at the end -- in a `finally`: the registry already
        # holds the snapshot, so a tick that raised without publishing would leave the next one
        # diffing nothing, and the app stale for that session until something else moved it.
        changed = list(diff.changed)
        try:
            await self._after_snapshot(raw, diff, before, changed)
        finally:
            await self.publisher.session_changed(changed)

    async def _after_snapshot(self, raw: list[RawSession], diff: SnapshotDiff, before: dict[str, SessionInfo],
                              changed: list[str]) -> None:
        """Announces what the snapshot opened and closed, then reads the corroborating signals, each
        step guarded so one that raises costs only its own changes. Appends to `changed` as it goes."""
        # Tick owns structural registry changes. Keep one ordered view for this pass;
        # hooks and status updates still mutate the same SessionInfo values.
        sessions = self.registry.all()
        self.windows.staged.sweep({s.session_id for s in sessions})
        since = self._initial_snapshot_since if self._initial_snapshot_since is not None else self.clock()
        self._initial_snapshot_since = None
        new_processes = set(diff.opened + diff.replaced)
        for s in sessions:
            old = before.get(s.session_id)
            # Reclassification can reveal Claude on the same PID (a shell exec). Its transcript belongs to this process.
            claude_changed = old is not None and old.agent != s.agent and "claude" in (old.agent, s.agent)
            if s.session_id in new_processes or claude_changed:
                with _logged(f"observing the new process of session {s.session_id}"):
                    if old is not None:
                        self.status.reset_turn(s.session_id)
                    if s.agent == "claude":
                        self.status.observe_claude_process(s.session_id, since)
            # A session moved to another tab or window keeps its id but not its tab's title.
            if old is not None and (old.window_id, old.tab_index) != (s.window_id, s.tab_index):
                with _logged(f"forgetting the title of moved session {s.session_id}"):
                    self.windows.forget_title(s.session_id)
        # Before opened sessions are announced, so that each one's first payload names its conversation.
        with _logged("restoring the Codex threads after the snapshot"):
            changed += self.codex_threads.restore(raw)
        for sid in diff.opened:
            with _logged(f"announcing opened session {sid}"):
                if opened := self.registry.get(sid):
                    await self.rpc.broadcast(protocol.SESSION_OPENED, opened.to_json())
        for sid in diff.closed:
            self._forget_session(sid)
            with _logged(f"announcing closed session {sid}"):
                await self.rpc.broadcast(protocol.SESSION_CLOSED, {"sessionId": sid})
        windows_after = {s.window_id for s in sessions}
        windows_before = {s.window_id for s in before.values()}
        for wid in windows_before - windows_after:
            self.windows.forget_window(wid)
            with _logged(f"announcing closed window {wid}"):
                await self.rpc.broadcast(protocol.WINDOW_CLOSED, {"windowId": wid})
        self.readers.snapshot(sessions, changed)
        threads = codex.tab_threads(self.codex_threads, sessions)
        screens: list[str] = []
        changed += await self.observe(claude.session_file_plan(self.registry, self.status, self.claude_files, sessions, screens))
        screens += pi.trust_screens(self.status, sessions) + agy.trust_screens(self.status, sessions)
        # Fixed order: hooks arriving during a read supersede the request that reader captured.
        observations: tuple[tuple[str, Callable[[], Awaitable[list[str]]]], ...] = (
            ("reading the screens for trust prompts", lambda: self.readers.trust_prompts(screens)),
            ("reading the Codex rollouts", lambda: self.observe_codex(threads)),
            ("releasing dead subagents", lambda: self.observe(claude.subagent_plan(self.status, self.subagent_transcripts))),
            ("reading Claude background shells", lambda: self.observe_background(sessions)),
            ("reading Antigravity background work",
             lambda: self.observe(agy.background_plan(self.status, self.hook_router.agy_transcripts, sessions))),
            ("reading stopped workers' recovery and usage resets",
             lambda: self.observe(claude.stop_plan(self.registry, self.status, self.stop_transcripts, self.clock))),
            ("reading worktree test activity", lambda: self.observe(self.readers.tests(self.test_activity, sessions))),
        )
        for name, observe in observations:
            with _logged(name):
                changed += await observe()
        changed += self.status.settle_held_ticks()
        await self.codex_threads.remember(sessions)

    async def observe(self, plan: ReadPlan[T]) -> list[str]:
        reading = plan.nothing if plan.read is None else await self.run_check(plan.name, plan.read, plan.nothing)
        if plan.keys is not None:
            current = {sid for sid, key in plan.keys.items()
                       if (session := self.registry.get(sid)) is not None and plan.current_key(session) == key}
            if plan.whole:
                # Assignment spans the registry: a new sibling can change who owns an activity.
                if current != plan.keys.keys() or self.registry.session_ids() != current:
                    return []
            else:
                reading = cast(T, {sid: value for sid, value in cast(dict[str, object], reading).items() if sid in current})
        return plan.apply(reading)

    async def observe_background(self, sessions: list[SessionInfo]) -> list[str]:
        return await self.observe(claude.background_plan(self.status, self.background_transcripts, sessions))

    async def observe_codex(self, threads: dict[str, str]) -> list[str]:
        return await self.observe(codex.rollout_plan(self.registry, self.status, self.codex_threads, self.codex_files, threads))

    async def run_check(self, name: str, work: Callable[[], T], nothing: T) -> T:
        """`work`, run on a worker thread. It answers `nothing` if it has not finished within
        OFF_LOOP_CHECK_SECONDS, if it raises, or if the run an earlier tick started is still stuck."""
        running = self._checks.get(name)
        if running is not None and not running.done():
            return nothing
        gave_up = False

        def consume(done: asyncio.Future[T]) -> None:
            # Retrieved here, so a run that fails after its tick stopped waiting is not reported by
            # asyncio as "exception was never retrieved" when the future is collected.
            if not done.cancelled() and (error := done.exception()) is not None and gave_up:
                log.warning("%s failed after its tick stopped waiting for it", name, exc_info=error)

        check = run_detached(work)
        check.add_done_callback(consume)
        self._checks[name] = check
        # Waited on, not awaited: a timeout must leave the worker's future pending until its thread returns.
        done, _ = await asyncio.wait({check}, timeout=OFF_LOOP_CHECK_SECONDS)
        if not done:
            gave_up = True
            log.warning("%s took over %.0f s", name, OFF_LOOP_CHECK_SECONDS)
            return nothing
        try:
            return check.result()
        except Exception:  # a check that cannot answer finds nothing, as documented
            log.exception("%s failed", name)
            return nothing

    def _forget_session(self, session_id: str) -> None:
        """Drops what each part keeps of a closed session, each on its own: one that raises keeps
        only its own state, not the others'."""
        for what, forget in (("window state", self.windows.forget_session), ("turn", self.status.forget_session),
                             ("pins", self.resolver.forget), ("Codex thread", self.codex_threads.forget),
                             ("delivery state", self.deliverer.forget_session),
                             ("last key", self.typing.forget), ("prompt attribution", self.hook_router.forget_session)):
            with _logged(f"forgetting the {what} of closed session {session_id}"):
                forget(session_id)

    async def _read_codex_usage(self) -> None:
        # Codex writes its account rate limits into every `token_count` record of its rollout
        # file, so the number arrives the way Claude's does -- as data the agent already emits --
        # with no subprocess to spawn, time out or kill. Account-wide, hence once per tick rather
        # than per session, and before the iTerm2 check: the feed does not depend on the terminal.
        # On a worker thread, as the contexts are: a rollout without a `token_count` is read to its start.
        def read() -> tuple[dict[str, Any], int | None] | UsageReadFailure | None:
            try:
                return self.codex_files.rate_limits()
            except Exception as error:  # noqa: BLE001 - distinguish a failed retrieval from absent telemetry
                return UsageReadFailure(str(error), int(self.clock()))

        found = await self.run_check(CODEX_READ, read, None)
        if isinstance(found, UsageReadFailure):
            if self.usage.failed("codex", found.message, found.at):
                await self.publisher.usage_changed()
            return
        if found is None:
            return
        limits, written_at = found
        usage = codex.parse_codex_rate_limits(limits, written_at if written_at is not None else int(self.clock()))
        if self.usage.set("codex", usage):
            await self.publisher.usage_changed()

