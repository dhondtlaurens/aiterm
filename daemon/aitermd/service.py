# daemon/aitermd/service.py
from __future__ import annotations
import asyncio
import logging
import time
from collections.abc import Awaitable, Callable, Iterator, Mapping
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path
from typing import Any, TypeVar

from . import protocol
from .claude_sessions import ClaudeSessionFile, ClaudeSessionFiles
from .claude_subagents import SubagentTranscripts, TranscriptTail
from .codex_sessions import CodexSessionFiles
from .connection import ItermSupervisor
from .delivery import NOT_CHECKED, Deliverer, Verdict, read_policy
from .hook_router import HookRouter
from .hooks_server import HookServer
from .iterm_bridge import ItermPort
from .keystrokes import YOUR_PROMPT_SECONDS, TypingGuard
from .offload import run_detached
from .operator_mcp import OperatorRoute, OperatorTokens
from .publisher import Publisher
from .resolver import SessionResolver
from .rpc_params import frame_param, guard, optional_param, param, require_iterm
from .rpc_server import RpcError, RpcServer
from .models import HARNESS_BY_AGENT, AgentKind, SessionInfo, State
from .sessions import SessionRegistry, SnapshotDiff
from .slash_commands import SlashCommands
from .status import StatusEngine, shows_trust_prompt
from .stop_failures import LIMIT_ERRORS, RESET_READ_SECONDS, limit_resets_at
from .test_activity import TestActivityReader
from .usage import UsageReadFailure, UsageStore, parse_codex_rate_limits
from .windows import WindowManager

log = logging.getLogger(__name__)


@contextmanager
def _logged(step: str) -> Iterator[None]:
    """Runs a step that must not stop the ones after it: a failure is logged and the caller carries on."""
    try:
        yield
    except Exception:  # noqa: BLE001 - the steps after it are independent of it
        log.exception("%s failed", step)


POLL_SECONDS = 2.0
# How long a tick waits for a check it runs on a worker thread: the subagent transcripts, the Codex
# rollouts.
OFF_LOOP_CHECK_SECONDS = 1.0
# Both of a tick's Codex reads -- the account's rate limits and the sessions' context fill -- run
# under this one off-loop name. They share CodexSessionFiles' caches, which nothing locks, so a read
# still stuck from an earlier tick holds back the other kind as well, rather than race it on a
# second worker thread.
CODEX_READ = "the Codex rollout read"

T = TypeVar("T")


class Service:
    """The daemon's composition root: builds the registry, status engine and usage store, wires
    the supervisor, the hook router and the window manager to them, answers the RPC methods none
    of those own, and polls iTerm2 into the registry."""

    def __init__(self, iterm: ItermPort, rpc: RpcServer, hooks: HookServer, claude_files: ClaudeSessionFiles,
                 clock: Callable[[], float], codex_files: CodexSessionFiles,
                 supervisor: ItermSupervisor | None = None, monotonic: Callable[[], float] = time.monotonic,
                 delivery_policy: Callable[[], Mapping[AgentKind, Verdict]] | None = None,
                 operator_runs: Path | None = None):
        self.iterm, self.rpc, self.hooks = iterm, rpc, hooks
        # `clock` is the wall clock, in seconds. Fractional: the status engine stamps each hook with
        # it and compares the stamp with a session file's mtime, which a whole second would blur.
        self.claude_files, self.codex_files, self.clock = claude_files, codex_files, clock
        # Claude's folder as the app last named it, which a snapshot echoes as it was sent: the app compares
        # the strings, and pathlib would spell some paths otherwise ("a/./b" as "a/b").
        self._claude_directory: str | None = None
        self.supervisor = supervisor or ItermSupervisor(iterm, rpc.broadcast, lambda: rpc.client_count)
        self.registry = SessionRegistry()
        self.status = StatusEngine(self.registry, clock, monotonic)
        self.usage = UsageStore()
        self.resolver = SessionResolver(self.registry, claude_files)
        self.publisher = Publisher(rpc.broadcast, self.registry, self.usage)
        self.hook_router = HookRouter(self.resolver, self.status, self.usage, clock, self.publisher, tick=self.tick)
        self.hooks.on_post = self.hook_router.handle_hook
        self.windows = WindowManager(iterm, self.registry, self.tick)
        self.supervisor.on_connected = self.windows.forget_titles
        self.supervisor.on_launched_connected = self.windows.capture_startup_window
        # The delivery adapter (Operators spec §7.1), and when you last typed in each session, which
        # holds back an operator's wake line (§7.4). The policy is read on every delivery, so the
        # delivery check that writes it needs no restart.
        self._monotonic = monotonic
        self.typing = TypingGuard(self.iterm.keystroke_epoch)
        self.deliverer = Deliverer(iterm, self.registry, delivery_policy or read_policy, self.typing, monotonic=monotonic)
        self.hook_router.typed_by_you = self._typed_by_you
        # What became of each slash command delivered to a Claude tab, read on every tick from its transcript.
        self.slash_commands = SlashCommands(self.registry, clock)
        # The operator's MCP server (Operators spec §5), on the hook server's port: its tool calls
        # are forwarded to the attached app, which answers them over this socket.
        # `operator_runs` is where the app keeps each run's token file, which a restarted daemon loads
        # (spec §11); None keeps tokens in memory only.
        self.operators = OperatorRoute(rpc.broadcast, lambda: rpc.client_count, OperatorTokens(operator_runs))
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
        self.test_activity = TestActivityReader(clock=clock)
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
        r("window.activate", lambda p: self._place(self.iterm.activate_window, param(p, "windowId", str)))
        r("session.activate", lambda p: self._place(self.iterm.activate_session, param(p, "sessionId", str)))
        r("window.setFrame", lambda p: self._place(self.iterm.set_frame, param(p, "windowId", str), frame_param(p)))
        r("window.close", self._h_close)
        r("tab.create", self.windows.create_tab)
        r("sessions.list", self._h_sessions_list)
        r("sessions.setTitles", self.windows.set_titles)
        r("sessions.markSeen", self._h_mark_seen)
        r("session.deliver", self._h_deliver)
        r("session.prompt", self._h_prompt)
        r("session.dismissStartup", self._h_dismiss_startup)
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
        except Exception:  # noqa: BLE001 - the last known registry beats no bootstrap at all
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

    async def _h_deliver(self, p: Any) -> dict[str, Any]:
        session_id, text, ownership = param(p, "sessionId", str), param(p, "text", str), param(p, "ownership", int)
        wake, worktree = bool(optional_param(p, "wake", bool)), optional_param(p, "worktree", str)
        # A slash command is stamped before it is typed: what Claude Code records of it comes after.
        command = None if wake else self.slash_commands.stamp(session_id, text)
        result = await self.deliverer.deliver(session_id, text, ownership, wake=wake, worktree=worktree)
        if command is not None and result.result == "delivered":
            await self.publisher.session_changed(self.slash_commands.delivered(session_id, command))
        return result.to_json()

    async def _h_prompt(self, p: Any) -> dict[str, Any]:
        session_id = param(p, "sessionId", str)
        require_iterm(self.iterm)
        return dict(await guard(self.deliverer.prompt_details(session_id)))

    async def _h_dismiss_startup(self, p: Any) -> dict[str, Any]:
        session_id = param(p, "sessionId", str)
        require_iterm(self.iterm)
        return {"dismissed": await guard(self.deliverer.dismiss_startup(session_id))}

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
        except Exception:  # noqa: BLE001 - must not escape into the iTerm2 library's dispatch
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
        self.codex_files.begin_tick()
        try:
            await self._read_codex_usage()
        except Exception:  # noqa: BLE001 - another process's file must not stop session polling
            log.exception("reading Codex usage failed")
        if not self.iterm.is_connected():
            return
        positions_before = {s.session_id: (s.window_id, s.tab_index) for s in self.registry.all()}
        windows_before = {window for window, _ in positions_before.values()}
        diff = self.registry.apply_snapshot(await self.iterm.snapshot())
        # A session.changed from the snapshot diff is deliberately *not* broadcast as it is found:
        # the status pass can change the same session again in this very tick (its state, its
        # model, the agent's cwd), and two events for one tick make a client redraw twice and,
        # worse, make "the next session.changed" ambiguous. Held back and merged into `changed`, it
        # is re-rendered from the registry once, at the end -- in a `finally`: the registry already
        # holds the snapshot, so a tick that raised without publishing would leave the next one
        # diffing nothing, and the app stale for that session until something else moved it.
        changed = list(diff.changed)
        try:
            await self._after_snapshot(diff, windows_before, positions_before, changed)
        finally:
            await self.publisher.session_changed(changed)

    async def _after_snapshot(self, diff: SnapshotDiff, windows_before: set[str],
                              positions_before: dict[str, tuple[str, int]], changed: list[str]) -> None:
        """Announces what the snapshot opened and closed, then reads the corroborating signals, each
        step guarded so one that raises costs only its own changes. Appends to `changed` as it goes."""
        # Tick owns structural registry changes. Keep one ordered view for this pass;
        # hooks and status updates still mutate the same SessionInfo values.
        sessions = self.registry.all()
        # A session moved to another tab or window keeps its id but not its tab's title.
        for s in sessions:
            if positions_before.get(s.session_id, (s.window_id, s.tab_index)) != (s.window_id, s.tab_index):
                with _logged(f"forgetting the title of moved session {s.session_id}"):
                    self.windows.forget_title(s.session_id)
        with _logged("validating the bindings after the snapshot"):
            self.resolver.snapshot_applied()
        for sid in diff.replaced:
            with _logged(f"resetting the turn of replaced session {sid}"):
                self.status.reset_turn(sid)
        for sid in diff.opened:
            with _logged(f"announcing opened session {sid}"):
                if opened := self.registry.get(sid):
                    await self.rpc.broadcast(protocol.SESSION_OPENED, opened.to_json())
        for sid in diff.closed:
            self._forget_session(sid)
            with _logged(f"announcing closed session {sid}"):
                await self.rpc.broadcast(protocol.SESSION_CLOSED, {"sessionId": sid})
        windows_after = {s.window_id for s in sessions}
        for wid in windows_before - windows_after:
            self.windows.forget_window(wid)
            with _logged(f"announcing closed window {wid}"):
                await self.rpc.broadcast(protocol.WINDOW_CLOSED, {"windowId": wid})
        threads: dict[str, str] = {}
        screens: list[str] = []
        # Consume snapshot titles and process exits before suspending for file I/O, so hooks
        # arriving during that read supersede the snapshot rather than being overwritten by it.
        for s in sessions:
            with _logged(f"corroborating session {s.session_id}"):
                self._corroborate(s, {}, threads, screens, changed)
        claude_readings = await self._read_claude_files(sessions)
        for s in sessions:
            if s.session_id not in claude_readings:
                continue
            # Another process's file must not stop the other tabs.
            with _logged(f"corroborating session {s.session_id}"):
                self._corroborate(s, claude_readings, threads, screens, changed)
        with _logged("reading the screens for trust prompts"):
            changed += await self._apply_trust_prompts(screens)
        with _logged("reading the Codex rollouts"):
            changed += await self._apply_codex_rollouts(threads)
        with _logged("releasing dead subagents"):
            changed += self.status.release_dead_subagents(await self._subagent_tails(self.status.subagent_transcripts()))
        with _logged("reading what became of the slash commands"):
            changed += await self._apply_slash_commands()
        with _logged("reading when the limits that stopped sessions reset"):
            changed += await self._apply_limit_resets()
        with _logged("reading worktree test activity"):
            captured = [replace(s) for s in sessions]
            reading = await run_detached(lambda: self.test_activity.read(captured))
            changed += self.test_activity.apply(self.registry, reading)

    async def _read_claude_files(self, sessions: list[SessionInfo]) -> dict[str, ClaudeSessionFile | None]:
        """Read the pass's Claude files in one worker, then reject replaced sessions or configuration."""
        files, root = self.claude_files, self.claude_files.root
        identities = {s.session_id: (s.agent, s.job_pid, s.conversation_id, s.agent_cwd)
                      for s in sessions if s.agent != "shell" and HARNESS_BY_AGENT[s.agent].corroboration == "claude_file"}
        if not identities:
            return {}

        def read() -> dict[str, ClaudeSessionFile | None]:
            readings: dict[str, ClaudeSessionFile | None] = {}
            for sid, (_, pid, _, _) in identities.items():
                with _logged(f"reading the Claude file of session {sid}"):
                    readings[sid] = files.read(pid) if pid else None
            return readings

        readings = await run_detached(read)
        if files.root != root:
            return {}
        return {sid: value for sid, value in readings.items()
                if (s := self.registry.get(sid)) is not None
                and (s.agent, s.job_pid, s.conversation_id, s.agent_cwd) == identities[sid]}

    def _corroborate(self, s: SessionInfo, claude_readings: dict[str, ClaudeSessionFile | None],
                    threads: dict[str, str], screens: list[str], changed: list[str]) -> None:
        """Adds to `changed` what the agent's own files and the tab say of `s` that its hooks have
        not, to `threads` the Codex thread it runs, by session, and to `screens` a session whose
        screen may show a folder-trust dialog. A step that raises keeps the changes before it. The
        Codex rollout and the screens are not read here: see `_apply_codex_rollouts` and
        `_apply_trust_prompts`."""
        if s.agent == "shell":
            if s.state != "idle":
                changed += self.status.agent_exited(s.session_id)
            return
        corroboration = HARNESS_BY_AGENT[s.agent].corroboration
        if corroboration == "claude_file":
            if s.session_id not in claude_readings:
                return
            if f := claude_readings[s.session_id]:
                # Claude writes its file only once its folder is trusted.
                changed += self.status.apply_trust_prompt(s.session_id, False)
                changed += self.status.apply_claude_file_status(s.session_id, f.status, f.written_at)
                # The file's cwd is the agent's own, and it follows it into a worktree;
                # `s.cwd` is the shell's and never moves (spec: branch awareness, §1).
                changed += self.status.apply_metadata(s.session_id, cwd=f.cwd)
                # The running Claude's own version, which delivery is held against (delivery.Verdict).
                self.registry.set_cli_version(s.session_id, f.version)
            elif s.job_pid and (s.state == "idle" or self.status.showing_trust_prompt(s.session_id)):
                # No file yet: the trust dialog, which only the screen shows, or a Claude just starting.
                screens.append(s.session_id)
        elif corroboration == "codex_title":
            changed += self.status.apply_codex_title(s.session_id, s.title)
            if thread_id := self.resolver.codex_thread(s.session_id):
                threads[s.session_id] = thread_id

    async def _apply_trust_prompts(self, session_ids: list[str]) -> list[str]:
        """The sessions a folder-trust dialog opened or closed on, read from their screens at once. A
        screen that cannot be read costs only its own session, and changes nothing."""
        screens = await asyncio.gather(*(self.iterm.screen_text(sid) for sid in session_ids), return_exceptions=True)
        changed: list[str] = []
        for sid, screen in zip(session_ids, screens, strict=True):
            if isinstance(screen, BaseException):
                log.warning("reading the screen of session %s failed: %s", sid, screen)
            elif screen is not None and (s := self.registry.get(sid)) is not None:
                changed += self.status.apply_trust_prompt(sid, shows_trust_prompt(s.agent, screen))
        return changed

    async def _apply_codex_rollouts(self, threads: dict[str, str]) -> list[str]:
        """The sessions whose context fill their Codex rollouts changed, and the rollouts'
        caches pruned to the threads still running. A rollout grows without bound and a hung mount can
        stall its read, so it is read on a worker thread: everything that touches the caches runs there."""
        files = self.codex_files

        def attempt(reading: Callable[[str], T], what: str, thread_id: str) -> T | None:
            # Another process's file: one that cannot be read costs only its own thread, and only
            # the reading that failed.
            try:
                return reading(thread_id)
            except Exception:  # noqa: BLE001
                log.exception("reading the Codex %s of thread %s failed", what, thread_id)
                return None

        def read() -> dict[str, tuple[int | None, str | None, tuple[State, float] | None]]:
            readings: dict[str, tuple[int | None, str | None, tuple[State, float] | None]] = {}
            for thread_id in set(threads.values()):
                readings[thread_id] = (attempt(files.context_percent, "context", thread_id),
                                       attempt(files.cli_version, "version", thread_id),
                                       attempt(files.turn_state, "turn boundary", thread_id))
            files.retain(set(threads.values()))
            return readings

        none: dict[str, tuple[int | None, str | None, tuple[State, float] | None]] = {}
        readings = await self._off_loop(CODEX_READ, read, none)
        changed: list[str] = []
        for session_id, thread_id in threads.items():
            # A hook or a replacement process may have changed the binding during the read.
            if self.resolver.codex_thread(session_id) != thread_id:
                continue
            context, version, turn = readings.get(thread_id, (None, None, None))
            # The running Codex's version, which delivery is held against (delivery.Verdict).
            self.registry.set_cli_version(session_id, version)
            changed += self.status.apply_metadata(session_id, context=context)
            if turn is not None:
                changed += self.status.apply_codex_rollout(session_id, *turn)
        return changed

    async def _subagent_tails(self, paths: set[str]) -> dict[str, TranscriptTail | None]:
        """The end of each of `paths`, the transcripts of every child the status engine counts; None
        for one not found. A read that cannot answer holds none, which proves no child dead, nor any
        stop."""
        if not paths:
            return {}
        read = self.subagent_transcripts.read_all
        return await self._off_loop("the subagent transcript read", lambda: read(paths), {})

    async def _apply_slash_commands(self) -> list[str]:
        """The sessions whose slash commands their transcripts, or the time, moved on. Each transcript a command is
        looked for in is read on a worker thread, on from where it was typed; a read that cannot answer changes nothing."""
        now, read = self.clock(), self.slash_commands.reader.read_all
        starts = self.slash_commands.starts(now)
        records = await self._off_loop("the slash command read", lambda: read(starts), None) if starts else {}
        return [] if records is None else self.slash_commands.apply(records, now)

    async def _apply_limit_resets(self) -> list[str]:
        """The sessions whose transcripts now say when the usage limit that stopped their turn resets. Each is looked
        for, on a worker thread, from the StopFailure until RESET_READ_SECONDS after it; a read that cannot answer
        changes nothing."""
        now = self.clock()
        stopped = {s.session_id: (s.stopped_on, s.transcript) for s in self.registry.all()
                   if s.stopped_on is not None and s.stopped_on.error in LIMIT_ERRORS and s.stopped_on.resets_at is None
                   and s.transcript and now - s.stopped_on.at <= RESET_READ_SECONDS}
        if not stopped:
            return []
        paths = {transcript for _, transcript in stopped.values() if transcript}
        none: dict[str, int | None] = {}
        resets = await self._off_loop("the usage limit read", lambda: {path: limit_resets_at(path) for path in paths}, none)
        changed: list[str] = []
        for session_id, (stopped_on, transcript) in stopped.items():
            # A hook may have moved the session on during the read.
            if (s := self.registry.get(session_id)) is None or s.stopped_on is not stopped_on or not transcript:
                continue
            if (resets_at := resets.get(transcript)) is not None:
                changed += [session_id] if self.registry.set_stopped_on(session_id, replace(stopped_on, resets_at=resets_at)) else []
        return changed

    async def _off_loop(self, name: str, work: Callable[[], T], nothing: T) -> T:
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
        except Exception:  # noqa: BLE001 - a check that cannot answer finds nothing, as documented
            log.exception("%s failed", name)
            return nothing

    def _forget_session(self, session_id: str) -> None:
        """Drops what each part keeps of a closed session, each on its own: one that raises keeps
        only its own state, not the others'."""
        for what, forget in (("window state", self.windows.forget_session), ("turn", self.status.forget_session),
                             ("bindings", self.resolver.forget), ("delivery state", self.deliverer.forget_session),
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

        found = await self._off_loop(CODEX_READ, read, None)
        if isinstance(found, UsageReadFailure):
            if self.usage.failed("codex", found.message, found.at):
                await self.publisher.usage_changed()
            return
        if found is None:
            return
        limits, written_at = found
        usage = parse_codex_rate_limits(limits, written_at if written_at is not None else int(self.clock()))
        if self.usage.set("codex", usage):
            await self.publisher.usage_changed()

