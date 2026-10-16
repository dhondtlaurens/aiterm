# daemon/tools/delivery_check.py
"""The delivery check (Operators spec §7.1, §12): whether AiTerm may type into each agent CLI, run
by hand against the real iTerm2 and real, logged-in Claude Code and Codex, each in a scratch
folder. Its verdicts go into ~/Library/Application Support/AiTerm/delivery-policy.json, which the
daemon's delivery adapter reads on every delivery (aitermd.delivery.load_policy): a CLI gets
automatic Enter only once it has passed here.

From daemon/, with iTerm2 open:

    .venv/bin/python -m tools.delivery_check                  # run, and print the verdicts
    .venv/bin/python -m tools.delivery_check --write          # and write them into the policy file
    .venv/bin/python -m tools.delivery_check --agents codex --skip-iterm

Never run by the test suite: it opens windows, starts agents that spend tokens, and asks you to
answer a dialog and type once. Codex runs with a scratch CODEX_HOME holding copies of its login and
settings, so an allow rule a failing scenario writes lands there and never in ~/.codex. Nothing is
typed into an agent but each scenario's own text, Enter and Esc. Claude's answer to the scratch
folder's trust dialog is the one thing left behind, in ~/.claude.json."""
from __future__ import annotations

import argparse
import asyncio
import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from aitermd.delivery import ESC, PASTE_END, PASTE_START, POLICY_PATH, Deliverer, Verdict, open_prompt, shows_input_box
from aitermd.iterm_bridge import ItermBridge, ItermPort
from aitermd.keystrokes import TypingGuard
from aitermd.models import AgentKind, Frame
from aitermd.sessions import SessionRegistry

# Which scenarios each verdict needs. Paste-safe: text pasted into an open prompt never acts as its
# keys. Submit-safe: the whole text arrives, Enter submits it once, and a takeover holds Enter back.
PASTE_SAFE = ("permissionPaste", "startupPaste", "menuPaste", "updatePaste", "approvalRace")
SUBMIT_SAFE = ("idleSubmit", "multiLine", "busyQueue", "takeover")
# iTerm2's own, checked once: the keystroke monitor lets keys through, and a background window stays behind.
ITERM_CHECKS = ("keystrokesPassThrough", "backgroundWindow")
AGENTS: tuple[AgentKind, ...] = ("claude", "codex")
# Pasted into an open prompt: the keys that answer one -- Codex's y, a and p (p chose "always allow"
# in the spike, §2.2), Claude's digits.
HAZARD = "please wait 1 2 3 y a p"
# Both CLIs' footer while a turn runs ("esc to interrupt"), without whitespace and case-folded.
WORKING = "tointerrupt"
# How each CLI starts: Claude asking before every command, Codex sandboxed and asking on request.
COMMANDS: dict[AgentKind, str] = {"claude": "claude --permission-mode default", "codex": "codex -s workspace-write -a on-request"}


@dataclass(frozen=True, slots=True)
class ScenarioResult:
    passed: bool
    detail: str

    def to_json(self) -> dict[str, Any]:
        return {"passed": self.passed, "detail": self.detail}


# -- the verdicts (pure; tests/test_delivery_check.py) ---------------------------------------------
def parse_version(output: str) -> str | None:
    """The version in a CLI's `--version` line: `2.1.301 (Claude Code)`, `codex-cli 0.160.0`."""
    found = re.search(r"\d+\.\d+\.\d+", output)
    return found.group(0) if found else None


def chosen_agents(text: str) -> tuple[AgentKind, ...]:
    """The CLIs `--agents` names that this check knows, in its own order."""
    wanted = {name.strip() for name in text.split(",")}
    return tuple(agent for agent in AGENTS if agent in wanted)


def _passed(results: Mapping[str, ScenarioResult], names: tuple[str, ...]) -> bool:
    """Whether every one of `names` ran and passed: a scenario not run counts as failed."""
    return all(name in results and results[name].passed for name in names)


def _scenarios(results: Mapping[str, ScenarioResult]) -> dict[str, Any]:
    return {name: result.to_json() for name, result in sorted(results.items())}


def agent_entry(version: str | None, results: Mapping[str, ScenarioResult], checked_at: str) -> dict[str, Any]:
    """One CLI's entry in delivery-policy.json, as load_policy reads it."""
    return {"version": version, "pasteSafe": _passed(results, PASTE_SAFE), "submitSafe": _passed(results, SUBMIT_SAFE),
            "checkedAt": checked_at, "scenarios": _scenarios(results)}


def iterm_entry(version: str | None, results: Mapping[str, ScenarioResult], checked_at: str) -> dict[str, Any]:
    """iTerm2's entry: no CLI's, so load_policy reads past it; it is for you, and the morning checklist."""
    return {"version": version, **{name: _passed(results, (name,)) for name in ITERM_CHECKS}, "checkedAt": checked_at,
            "scenarios": _scenarios(results)}


def merged_policy(existing: Any, entries: Mapping[str, dict[str, Any]]) -> dict[str, Any]:
    """The policy file with the entries just checked in place of their old ones and every other kept:
    checking Codex alone leaves Claude's verdict as it was. A file that is no object is replaced."""
    return (dict(existing) if isinstance(existing, dict) else {}) | dict(entries)


def scratch_codex_home(real: Path, into: Path) -> Path:
    """A CODEX_HOME holding only copies of the real one's login and settings, so an allow rule a
    failing scenario writes (its `rules/`) lands here and never in ~/.codex (the spike's hazard, §2.2)."""
    home = into / "codex-home"
    home.mkdir(parents=True)
    for name in ("auth.json", "config.toml"):
        if (real / name).is_file():
            shutil.copy2(real / name, home / name)
    return home


def allow_rules(agent: AgentKind, folder: Path) -> list[str]:
    """Where an approval the paste gave for good would have been written, under an agent's scratch
    folder: Codex's rules in its scratch CODEX_HOME, Claude's project settings in the work folder."""
    place = folder / "codex-home" / "rules" if agent == "codex" else folder / "work" / ".claude" / "settings.local.json"
    if place.is_dir():
        return sorted(str(path) for path in place.rglob("*") if path.is_file())
    return [str(place)] if place.exists() else []


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def write_policy(path: Path, policy: Mapping[str, Any]) -> None:
    """Written whole and then moved into place, so the daemon never reads half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(policy, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


# -- the live scenarios (by hand only) ---------------------------------------------------------------
def _flat(text: str) -> str:
    return "".join(text.split())


def shows(*phrases: str) -> Callable[[str], bool]:
    """Whether a screen shows every phrase, compared without whitespace as open_prompt compares."""
    return lambda screen: all(_flat(phrase) in _flat(screen) for phrase in phrases)


def idle(agent: AgentKind) -> Callable[[str], bool]:
    """The CLI's own screen, as the adapter recognises it (its input-box marker), with no prompt open and no
    turn running: a blank or an unrecognised screen is not idle, as the adapter would refuse it too."""
    return lambda screen: shows_input_box(agent, screen) and open_prompt(agent, screen) is None and WORKING not in _flat(screen).lower()


def report(where: str, name: str, result: ScenarioResult) -> None:
    print(f"  {where} {name}: {'pass' if result.passed else 'FAIL'} -- {result.detail}")


def front_app() -> str:
    """The frontmost app's ASN, from lsappinfo: it asks Launch Services, and starts no AppleEvent client."""
    return subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()


def cli_version(agent: AgentKind) -> str | None:
    try:
        return parse_version(subprocess.run([agent, "--version"], capture_output=True, text=True, timeout=60).stdout)
    except (OSError, subprocess.SubprocessError):
        return None


class Live:
    """The real iTerm2, through the daemon's own bridge, and the daemon's own adapter over it."""

    def __init__(self, bridge: ItermPort):
        self.bridge, self.registry, self.typing = bridge, SessionRegistry(), TypingGuard(bridge.keystroke_epoch)
        self.keys: Counter[str] = Counter()
        # Each CLI's version, as its `--version` printed it: the one the verdict is written for.
        self.versions: dict[AgentKind, str] = {}
        bridge.on_keystroke(self._key)

    async def _key(self, session_id: str, characters: str, modifiers: frozenset[str]) -> None:
        self.keys[session_id] += 1
        self.typing.note_key(session_id, time.monotonic(), characters, modifiers)

    async def screen(self, session_id: str) -> str:
        return await self.bridge.screen_text(session_id) or ""

    async def wait_for(self, session_id: str, seen: Callable[[str], bool], seconds: float) -> bool:
        """Whether the screen shows what `seen` looks for within `seconds`, read twice a second."""
        deadline = time.monotonic() + seconds
        while True:
            if seen(await self.screen(session_id)):
                return True
            if time.monotonic() >= deadline:
                return False
            await asyncio.sleep(0.5)

    async def paste(self, session_id: str, text: str) -> None:
        """A bracketed paste and nothing else: what reaches a prompt the adapter would refuse to type into."""
        await self.bridge.send_text(session_id, PASTE_START + text + PASTE_END)

    def deliverer(self, agent: AgentKind, sleep: Callable[[float], Awaitable[None]] = asyncio.sleep) -> Deliverer:
        """The daemon's adapter, told this CLI's version is checked: the scenarios are what decide whether it is."""
        policy: dict[AgentKind, Verdict] = {agent: Verdict("auto", self.versions.get(agent))}
        return Deliverer(self.bridge, self.registry, lambda: policy, self.typing, sleep=sleep)

    async def ready(self, agent: AgentKind, session_id: str, seconds: float = 180) -> bool:
        """Whether the CLI is idle with no prompt open, and known to the adapter's registry as itself,
        at the version `--version` printed: the daemon's tick reads the same string from the CLI's own
        files, which this check does not tick."""
        if not await self.wait_for(session_id, idle(agent), seconds):
            return False
        self.registry.apply_snapshot(await self.bridge.snapshot())
        self.registry.set_cli_version(session_id, self.versions.get(agent))
        return (session := self.registry.get(session_id)) is not None and session.agent == agent


async def startup_paste(live: Live, agent: AgentKind, sid: str) -> ScenarioResult:
    """Pastes the hazard into the folder-trust dialog a fresh folder opens with; the dialog must stay
    open. Then you answer it: Claude's default option is "No, exit", so the check never presses Enter."""
    if not await live.wait_for(sid, lambda screen: open_prompt(agent, screen) == "startup", 60):
        return ScenarioResult(False, "no startup dialog showed, so pasting into one was not checked")
    await live.paste(sid, HAZARD)
    await asyncio.sleep(3)
    after = await live.screen(sid)
    passed = open_prompt(agent, after) == "startup"
    await asyncio.to_thread(input, f"  {agent}: trust the folder in its window's dialog yourself, then press Return here. ")
    return ScenarioResult(passed, "the dialog stayed open under the paste" if passed else f"the paste answered the dialog:\n{after}")


async def idle_submit(live: Live, agent: AgentKind, sid: str) -> ScenarioResult:
    result = await live.deliverer(agent).deliver(sid, "Reply with only the word ALPHA followed by the result of 6 times 7.", 1)
    if result.result != "delivered":
        return ScenarioResult(False, f"{result.result}: {result.reason}")
    answered = await live.wait_for(sid, shows("ALPHA 42"), 120)
    return ScenarioResult(answered, "answered" if answered else "no answer within 2 minutes: the Enter did not submit")


async def multi_line(live: Live, agent: AgentKind, sid: str) -> ScenarioResult:
    text = ("Line one holds the word DELTA.\nLine two holds the sum 8 minus 3.\n"
            "Reply with only the word from line one followed by the result from line two.")
    result = await live.deliverer(agent).deliver(sid, text, 1)
    if result.result != "delivered":
        return ScenarioResult(False, f"{result.result}: {result.reason}")
    answered = await live.wait_for(sid, shows("DELTA 5"), 120)
    return ScenarioResult(answered, "all three lines arrived as one message" if answered else "no DELTA 5: the lines did not arrive whole")


async def busy_queue(live: Live, agent: AgentKind, sid: str) -> ScenarioResult:
    story = "Write a 200-word story about a lighthouse keeper, then end with the line STORY OVER."
    first = await live.deliverer(agent).deliver(sid, story, 1)
    if first.result != "delivered":
        return ScenarioResult(False, f"the first message: {first.result}: {first.reason}")
    if not await live.wait_for(sid, lambda screen: WORKING in _flat(screen).lower(), 30):
        return ScenarioResult(False, "the agent never showed it was working, so a queued message was not checked")
    second = await live.deliverer(agent).deliver(sid, "When you are done, reply with only the word CHARLIE followed by 5 plus 4.", 1)
    if second.result != "delivered":
        return ScenarioResult(False, f"the queued message: {second.result}: {second.reason}")
    answered = await live.wait_for(sid, shows("CHARLIE 9"), 240)
    return ScenarioResult(answered, "the message typed while it worked was queued and answered" if answered
                          else "no CHARLIE 9: the message typed while it worked was lost")


async def takeover(live: Live, agent: AgentKind, sid: str) -> ScenarioResult:
    """A takeover between paste and Enter: the result is partial and the text waits, unsent."""
    deliverers: list[Deliverer] = []

    async def taken_over(seconds: float) -> None:
        await asyncio.sleep(seconds)
        deliverers[0].set_ownership(sid, 2)

    deliverers.append(live.deliverer(agent, sleep=taken_over))
    deliverers[0].set_ownership(sid, 1)
    result = await deliverers[0].deliver(sid, "Reply with only the word ECHO followed by the result of 2 plus 2.", 1)
    if result.result != "partial":
        return ScenarioResult(False, f"expected partial, got {result.result}: {result.reason}")
    waiting = await live.wait_for(sid, shows("ECHO followed by the result of 2 plus 2"), 5)
    submitted = await live.wait_for(sid, shows("ECHO 4"), 10)
    # Entered now, by the check, so the session is left idle for the next scenario.
    await live.bridge.send_text(sid, "\r")
    answered = await live.wait_for(sid, shows("ECHO 4"), 120)
    passed = waiting and not submitted and answered
    return ScenarioResult(passed, f"text waiting in the input: {waiting}; submitted without Enter: {submitted}; "
                                  f"answered once entered: {answered}")


async def permission_paste(live: Live, agent: AgentKind, sid: str, folder: Path) -> ScenarioResult:
    """Has the agent ask to run a command, pastes the hazard into the approval, and checks nothing was
    approved -- once or for good -- before declining with Esc."""
    # Codex asks only to write outside its workspace (and outside $TMPDIR, which its sandbox allows);
    # Claude, started in default mode, asks before any command.
    target = folder / "outside" / "approved.txt" if agent == "codex" else folder / "work" / "approved.txt"
    target.parent.mkdir(parents=True, exist_ok=True)
    asked = await live.deliverer(agent).deliver(sid, f"Run exactly this shell command and nothing else: touch {target}", 1)
    if asked.result != "delivered":
        return ScenarioResult(False, f"the request: {asked.result}: {asked.reason}")
    if not await live.wait_for(sid, lambda screen: open_prompt(agent, screen) == "permission", 120):
        return ScenarioResult(False, "no approval prompt opened, so pasting into one was not checked")
    await live.paste(sid, HAZARD)
    await asyncio.sleep(3)
    still_open = open_prompt(agent, await live.screen(sid)) == "permission"
    approved, rules = target.exists(), allow_rules(agent, folder)
    await live.bridge.send_text(sid, ESC)
    passed = still_open and not approved and not rules
    return ScenarioResult(passed, f"prompt still open: {still_open}; command ran: {approved}; allow rules written: {rules or 'none'}")


async def check_agent(live: Live, agent: AgentKind, folder: Path) -> dict[str, ScenarioResult]:
    """Every scenario against one CLI, in its own window and scratch folder. One that leaves the CLI
    unable to go on ends the rest, which then count as failed."""
    work = folder / "work"
    work.mkdir(parents=True)
    command = COMMANDS[agent]
    if agent == "codex":
        home = scratch_codex_home(Path.home() / ".codex", folder)
        command = f"env CODEX_HOME={shlex.quote(str(home))} {command}"
    window, sid = await live.bridge.create_window(str(work), f"delivery check · {agent}", {}, Frame(120, 80, 1100, 760))
    results: dict[str, ScenarioResult] = {}
    try:
        await asyncio.sleep(1)  # the shell starting
        await live.bridge.send_text(sid, f" {command}\n")
        results["startupPaste"] = await startup_paste(live, agent, sid)
        report(agent, "startupPaste", results["startupPaste"])
        steps: tuple[tuple[str, Callable[[], Awaitable[ScenarioResult]]], ...] = (
            ("idleSubmit", lambda: idle_submit(live, agent, sid)),
            ("multiLine", lambda: multi_line(live, agent, sid)),
            ("busyQueue", lambda: busy_queue(live, agent, sid)),
            ("takeover", lambda: takeover(live, agent, sid)),
            ("permissionPaste", lambda: permission_paste(live, agent, sid, folder)),
        )
        for name, step in steps:
            if not await live.ready(agent, sid):
                print(f"  {agent} is not idle with no prompt open (answer any dialog in its window); {name} and the rest are not run")
                break
            results[name] = await step()
            report(agent, name, results[name])
    finally:
        await live.bridge.close_window(window)
    return results


async def keystrokes_pass_through(live: Live) -> ScenarioResult:
    """You type into a shell's tab: the monitor must see the keys, and the shell must still get them."""
    window, sid = await live.bridge.create_window(str(Path.home()), "delivery check · keys", {}, Frame(160, 120, 900, 500))
    try:
        await asyncio.sleep(1)
        await live.bridge.send_text(sid, ' read -r line && echo "GOT:$line"\n')
        await asyncio.to_thread(input, '  In the window "delivery check · keys", type aiterm and press Return; then press Return here. ')
        echoed = await live.wait_for(sid, shows("GOT:aiterm"), 10)
        seen = live.keys[sid]
    finally:
        await live.bridge.close_window(window)
    return ScenarioResult(echoed and seen >= len("aiterm"), f"the shell got the keys: {echoed}; the monitor saw {seen} keys")


async def background_window(live: Live) -> ScenarioResult:
    """A window made in the background must neither activate iTerm2 nor come forward."""
    print("  In the next 5 seconds, click a window of an app other than iTerm2, and leave it in front.")
    await asyncio.sleep(5)
    before = front_app()
    window, _sid = await live.bridge.create_window(str(Path.home()), "delivery check · background", {},
                                                   Frame(200, 160, 700, 400), background=True)
    try:
        await asyncio.sleep(2)
        after = front_app()
        answer = await asyncio.to_thread(input, '  Did a window "delivery check · background" come to the front? [y/N] ')
    finally:
        await live.bridge.close_window(window)
    raised = answer.strip().lower().startswith("y")
    return ScenarioResult(before == after and not raised, f"front app before {before}, after {after}; you saw it come forward: {raised}")


async def run(agents: tuple[AgentKind, ...], skip_iterm: bool, write: bool, policy_path: Path) -> int:
    bridge = ItermBridge()
    iterm_version = await bridge.connect()
    live = Live(bridge)
    checked_at = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    entries: dict[str, dict[str, Any]] = {}
    # Outside $TMPDIR and /tmp: Codex's workspace-write sandbox writes there unasked, and the
    # permission scenario needs a write it must ask for.
    caches = Path.home() / "Library" / "Caches"
    try:
        if not skip_iterm:
            iterm_results = {"keystrokesPassThrough": await keystrokes_pass_through(live),
                             "backgroundWindow": await background_window(live)}
            for name, result in iterm_results.items():
                report("iterm", name, result)
            entries["iterm"] = iterm_entry(iterm_version, iterm_results, checked_at)
        for agent in agents:
            if (version := cli_version(agent)) is None:
                print(f"{agent}: not installed, skipped")
                continue
            print(f"{agent} {version}")
            live.versions[agent] = version
            with tempfile.TemporaryDirectory(prefix=f"aiterm-delivery-{agent}-", dir=caches) as scratch:
                entries[agent] = agent_entry(version, await check_agent(live, agent, Path(scratch)), checked_at)
    finally:
        await bridge.close()
    print(json.dumps(entries, indent=2, sort_keys=True))
    if write:
        write_policy(policy_path, merged_policy(read_json(policy_path), entries))
        print(f"written to {policy_path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="delivery_check", description="Checks whether AiTerm may type into each agent CLI.")
    parser.add_argument("--agents", default=",".join(AGENTS), help="comma-separated, of claude and codex")
    parser.add_argument("--skip-iterm", action="store_true", help="leave out iTerm2's own two checks")
    parser.add_argument("--write", action="store_true", help="write the verdicts into the policy file")
    parser.add_argument("--policy", type=Path, default=POLICY_PATH, help="the policy file (default: the daemon's)")
    ns = parser.parse_args(argv)
    return asyncio.run(run(chosen_agents(ns.agents), ns.skip_iterm, ns.write, ns.policy))


if __name__ == "__main__":
    sys.exit(main())
