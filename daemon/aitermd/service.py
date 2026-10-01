# daemon/aitermd/service.py
from __future__ import annotations
import asyncio
import logging
import time
from collections.abc import Callable
from typing import Any, TypeVar

from . import protocol
from .claude_sessions import ClaudeSessionFiles
from .claude_subagents import SubagentTranscripts, TranscriptTail
from .codex_sessions import CodexSessionFiles
from .connection import ItermSupervisor
from .hook_router import HookRouter
from .hooks_server import HookServer
from .iterm_bridge import ItermPort
from .publisher import Publisher
from .resolver import SessionResolver
from .rpc_params import frame_param, guard, param, require_iterm
from .rpc_server import RpcServer
from .sessions import SessionRegistry
from .status import StatusEngine, path_is_missing
from .usage import UsageStore, parse_codex_rate_limits
from .windows import WindowManager

log = logging.getLogger(__name__)
POLL_SECONDS = 2.0
# How long a tick waits for a check it runs on a worker thread: the orphan directories, the subagent
# transcripts.
OFF_LOOP_CHECK_SECONDS = 1.0

T = TypeVar("T")


class Service:
    """The daemon's composition root: builds the registry, status engine and usage store, wires
    the supervisor, the hook router and the window manager to them, answers the RPC methods none
    of those own, and polls iTerm2 into the registry."""

    def __init__(self, iterm: ItermPort, rpc: RpcServer, hooks: HookServer, claude_files: ClaudeSessionFiles,
                 clock: Callable[[], float], codex_files: CodexSessionFiles | None = None,
                 supervisor: ItermSupervisor | None = None, path_missing: Callable[[str], bool] = path_is_missing,
                 monotonic: Callable[[], float] = time.monotonic):
        self.iterm, self.rpc, self.hooks = iterm, rpc, hooks
        # `clock` is the wall clock, in seconds. Fractional: the status engine stamps each hook with
        # it and compares the stamp with a session file's mtime, which a whole second would blur.
        # `monotonic` times the orphan settle, and `path_missing` is its directory check, which runs
        # on a worker thread: a stat on a hung network mount must not stall the daemon.
        self.claude_files, self.codex_files, self.clock = claude_files, codex_files, clock
        self.supervisor = supervisor or ItermSupervisor(iterm, rpc.broadcast, lambda: rpc.client_count)
        self.registry = SessionRegistry()
        self.status = StatusEngine(self.registry, clock, monotonic)
        self.usage = UsageStore()
        self.resolver = SessionResolver(self.registry, claude_files)
        self.publisher = Publisher(rpc.broadcast, self.registry, self.usage)
        self.hook_router = HookRouter(self.resolver, self.status, self.usage, clock, self.publisher)
        self.hooks.on_post = self.hook_router.handle_hook
        self.windows = WindowManager(iterm, self.registry, self.tick)
        self.supervisor.on_connected = self.windows.forget_titles
        self._poll_task: asyncio.Task[None] | None = None
        # window.setFrame and window.activate each leave a state the next one replaces, and the app
        # sends them from separate tasks; requests are answered concurrently, so they take this in
        # turn, in the order they came, and the last one sent is the one that stays.
        self._placement_lock = asyncio.Lock()
        self._tick_lock = asyncio.Lock()
        # Ticks started so far, and the number of the last to finish without raising: a tick whose
        # caller asked before another started and finished has nothing left to read.
        self._ticks_started = 0
        self._last_good_tick = 0
        self._path_missing = path_missing
        self.subagent_transcripts = SubagentTranscripts()
        # Each off-loop check's latest run, by name, while its worker thread may still be running: a
        # thread stuck on a hung mount cannot be cancelled, so no second one is started beside it.
        self._checks: dict[str, asyncio.Future[Any]] = {}
        self._register_handlers()

    # -- lifecycle ---------------------------------------------------------
    async def start(self) -> None:
        self.iterm.on_new_session(self.windows.on_new_session)
        self.iterm.on_session_closed(self._on_session_closed)
        self.iterm.on_window_activated(self._on_window_activated)
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
        await self.supervisor.stop()
        await self.hooks.stop()
        await self.rpc.stop()

    async def _poll_forever(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:  # noqa: BLE001
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
        r("window.activate", self._h_activate)
        r("window.setFrame", self._h_set_frame)
        r("window.close", self._h_close)
        r("tab.create", self.windows.create_tab)
        r("sessions.list", self._h_sessions_list)
        r("sessions.setTitles", self.windows.set_titles)
        r("sessions.markSeen", self._h_mark_seen)
        r("usage.get", self._h_usage_get)
        r("interface.setMatchItermBackground", self.windows.set_match_iterm_background)

    async def _h_snapshot(self, _p: Any) -> dict[str, Any]:
        try:
            await self.tick()
        except Exception:  # noqa: BLE001 - the last known registry beats no bootstrap at all
            log.exception("tick failed")
        # No await between reading state and returning it. RpcServer writes the reply
        # before yielding, making it a barrier between earlier and later events.
        return {"protocolVersion": protocol.VERSION, **self.supervisor.snapshot_fields(),
                "sessions": [s.to_json() for s in self.registry.all()],
                "usage": self.usage.snapshot()}

    async def _h_activate(self, p: Any) -> dict[str, Any]:
        window_id = param(p, "windowId", str)
        async with self._placement_lock:
            require_iterm(self.iterm)
            await guard(self.iterm.activate_window(window_id))
        return {}

    async def _h_set_frame(self, p: Any) -> dict[str, Any]:
        window_id, frame = param(p, "windowId", str), frame_param(p)
        async with self._placement_lock:
            require_iterm(self.iterm)
            await guard(self.iterm.set_frame(window_id, frame))
        return {}

    async def _h_close(self, p: Any) -> dict[str, Any]:
        window_id = param(p, "windowId", str)
        require_iterm(self.iterm)
        await guard(self.iterm.close_window(window_id))
        try:
            await self.tick()
        except Exception:  # noqa: BLE001 - the window is closed either way; the next tick sees it
            log.exception("tick after closing a window failed")
        return {}

    async def _h_sessions_list(self, _p: Any) -> list[dict[str, Any]]:
        return [s.to_json() for s in self.registry.all()]

    async def _h_mark_seen(self, p: Any) -> dict[str, Any]:
        changed = self.status.mark_seen(param(p, "taskId", str))
        await self.publisher.session_changed(changed)
        return {"changed": len(changed)}

    async def _h_usage_get(self, _p: Any) -> dict[str, Any]:
        return self.usage.snapshot()

    # -- iTerm2 notifications ------------------------------------------------
    async def _on_window_activated(self, window_id: str) -> None:
        # A macOS notification can bring an iTerm2 window forward without an AiTerm row being
        # clicked. Tell the app which window received focus so it can keep its sidebar selection
        # in sync. The window id is enough: the app owns the task/terminal mapping.
        try:
            await self.rpc.broadcast(protocol.WINDOW_ACTIVATED, {"windowId": window_id})
        except Exception:  # noqa: BLE001 - must not escape into the iTerm2 library's dispatch
            log.exception("on_window_activated failed for %s", window_id)

    async def _on_session_closed(self, session_id: str) -> None:
        try:
            await self.tick()
        except Exception:  # noqa: BLE001 - must not escape into the iTerm2 library's dispatch
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
        try:
            await self._read_codex_usage()
        except Exception:  # noqa: BLE001 - another process's file must not stop session polling
            log.exception("reading Codex usage failed")
        if not self.iterm.is_connected():
            return
        windows_before = {s.window_id for s in self.registry.all()}
        positions_before = {s.session_id: (s.window_id, s.tab_index) for s in self.registry.all()}
        diff = self.registry.apply_snapshot(await self.iterm.snapshot())
        # A session moved to another tab or window keeps its id but not its tab's title.
        for s in self.registry.all():
            if positions_before.get(s.session_id, (s.window_id, s.tab_index)) != (s.window_id, s.tab_index):
                self.windows.forget_title(s.session_id)
        self.resolver.snapshot_applied()
        for sid in diff.replaced:
            self.status.reset_turn(sid)
        for sid in diff.opened:
            if opened := self.registry.get(sid):
                await self.rpc.broadcast(protocol.SESSION_OPENED, opened.to_json())
        for sid in diff.closed:
            self._forget_session(sid)
            await self.rpc.broadcast(protocol.SESSION_CLOSED, {"sessionId": sid})
        # A session.changed from the snapshot diff is deliberately *not* broadcast here:
        # the status pass below can change the same session again in this very tick (its
        # state, its model, the agent's cwd), and two events for one tick make a client
        # redraw twice and, worse, make "the next session.changed" ambiguous. Held back
        # and merged into `changed`, it is re-rendered from the registry once, at the end.
        changed = list(diff.changed)
        windows_after = {s.window_id for s in self.registry.all()}
        for wid in windows_before - windows_after:
            await self.rpc.broadcast(protocol.WINDOW_CLOSED, {"windowId": wid})
        threads: set[str] = set()
        for s in self.registry.all():
            if s.agent == "claude" and s.job_pid and (f := self.claude_files.read(s.job_pid)):
                changed += self.status.apply_claude_file_status(s.session_id, f.status, f.written_at)
                # The file's cwd is the agent's own, and it follows it into a worktree;
                # `s.cwd` is the shell's and never moves (spec: branch awareness, §1).
                changed += self.status.apply_metadata(s.session_id, cwd=f.cwd)
            elif s.agent == "codex":
                changed += self.status.apply_codex_title(s.session_id, s.title)
                if self.codex_files is not None and (thread_id := self.resolver.codex_thread(s.session_id)):
                    threads.add(thread_id)
                    if (context := self.codex_files.context_percent(thread_id)) is not None:
                        changed += self.status.apply_metadata(s.session_id, context=context)
            elif s.agent == "shell" and s.state != "idle":
                changed += self.status.agent_exited(s.session_id)
        if self.codex_files is not None:
            self.codex_files.retain(threads)
        changed += self.status.settle_orphans(await self._missing_paths(self.status.orphan_paths()))
        changed += self.status.release_dead_subagents(await self._subagent_tails(self.status.subagent_transcripts()))
        await self.publisher.session_changed(changed)

    async def _missing_paths(self, paths: set[str]) -> frozenset[str]:
        """Which of `paths` are gone. A check that cannot answer finds nothing missing: a directory
        it cannot see is not proof that a turn ended."""
        if not paths:
            return frozenset()
        check = self._path_missing
        return await self._off_loop("the directory check", lambda: frozenset(p for p in paths if check(p)), frozenset())

    async def _subagent_tails(self, paths: set[str]) -> dict[str, TranscriptTail]:
        """The end of each of `paths`, the transcripts of the children a deferred done waits on. Only
        a turn that has one reads any. A read that cannot answer finds none, which proves no child dead."""
        if not paths:
            return {}
        read = self.subagent_transcripts.read_all
        return await self._off_loop("the subagent transcript read", lambda: read(paths), {})

    async def _off_loop(self, name: str, work: Callable[[], T], nothing: T) -> T:
        """`work`, run on a worker thread. It answers `nothing` if it has not finished within
        OFF_LOOP_CHECK_SECONDS, or if the run an earlier tick started is still stuck."""
        running = self._checks.get(name)
        if running is not None and not running.done():
            return nothing
        check: asyncio.Future[T] = asyncio.ensure_future(asyncio.to_thread(work))
        self._checks[name] = check
        try:
            # Shielded: a timeout leaves the thread's future pending until the thread returns.
            return await asyncio.wait_for(asyncio.shield(check), OFF_LOOP_CHECK_SECONDS)
        except TimeoutError:
            log.warning("%s took over %.0f s", name, OFF_LOOP_CHECK_SECONDS)
            return nothing

    def _forget_session(self, session_id: str) -> None:
        self.windows.forget_session(session_id)
        self.status.reset_turn(session_id)
        self.resolver.forget(session_id)

    async def _read_codex_usage(self) -> None:
        # Codex writes its account rate limits into every `token_count` record of its rollout
        # file, so the number arrives the way Claude's does -- as data the agent already emits --
        # with no subprocess to spawn, time out or kill. Account-wide, hence once per tick rather
        # than per session, and before the iTerm2 check: the feed does not depend on the terminal.
        if self.codex_files is None or (found := self.codex_files.rate_limits()) is None:
            return
        limits, written_at = found
        usage = parse_codex_rate_limits(limits, written_at if written_at is not None else int(self.clock()))
        if self.usage.set("codex", usage):
            await self.publisher.usage_changed()

