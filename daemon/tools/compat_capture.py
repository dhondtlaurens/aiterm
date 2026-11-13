# daemon/tools/compat_capture.py
"""The compatibility capture (docs/testing.md, "Agent compatibility"): what each agent CLI sends
AiTerm and writes for it, recorded live from the real, logged-in CLI, so the contract suites can say
whether AiTerm still reads it. Run by `scripts/compat-check.sh` after a CLI update; by hand from
daemon/, with iTerm2 open:

    .venv/bin/python -m tools.compat_capture capture                     # every CLI installed
    .venv/bin/python -m tools.compat_capture capture --agents claude,pi

`scripts/compat-check.sh` runs it, then the delivery check, whose verdict it reads back (`gate`), then
the contract suites, and only when all passed records the versions (`verified`).

Never run by the test suite: it opens windows and starts agents that spend tokens, on each CLI's
cheapest model. Each CLI runs in a scratch config holding a copy of what keeps it logged in, with
AiTerm's driver installed from `compat/drivers/` (kept equal to what the app installs by
CompatContractTests) and pointed at a listener of this process's own: nothing reaches the running
AiTerm, and nothing lands in ~/.claude, ~/.codex, ~/.pi or AiTerm's support folder. Claude's status
line runs the bundled shim unchanged, with HOME set to a scratch home for that command alone, whose
`hook-port` names the listener.

What a CLI sent and wrote is saved into daemon/tests/fixtures/compat/<agent>/, replacing the last
capture, once every account detail, the home folder, the user's name and the scratch folder are
replaced with placeholders, and the records of Claude's transcripts that describe the account (its
organisation, skills, connectors, system prompt) left out. A capture that still holds a private value,
or any of the person's own terms in ~/.config/aiterm/compat-private.txt, is not written."""
from __future__ import annotations

import argparse
import asyncio
import base64
import contextlib
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
import uuid
from collections.abc import Awaitable, Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from aitermd.delivery import ESC, open_prompt, shows_update_offer
from aitermd.hooks_server import HookServer
from aitermd.iterm_bridge import ItermBridge
from aitermd.models import AgentKind, Frame, classify_agent

from tools.delivery_check import (Live, answer_trust, idle, parse_version, read_json, scratch_claude_config, scratch_codex_home,
                                  screen_settings)

REPO = Path(__file__).resolve().parents[2]
COMPAT = REPO / "compat"
CAPTURES = REPO / "daemon" / "tests" / "fixtures" / "compat"
SHIM = REPO / "hooks" / "claude-statusline-shim.sh"
PI_EXTENSION = REPO / "hooks" / "pi-aiterm-status.ts"
# What stands for a value in compat/drivers/ (CompatContractTests).
PORT_WORD, SHIM_WORD = "__AITERM_HOOK_PORT__", "__AITERM_SHIM__"
AGENTS: tuple[AgentKind, ...] = ("claude", "codex", "pi")
# Each CLI's cheapest model, at low effort: the capture reads what the CLI sends, which no model changes.
MODELS: dict[AgentKind, tuple[str, str]] = {
    "claude": ("haiku", "low"),
    "codex": ("gpt-6-luna", "low"),
    "pi": ("openai-codex/gpt-6-luna", "low"),
}
# How long one turn may take, and a CLI to start.
TURN_SECONDS = 90.0
START_SECONDS = 45.0
# Codex's review of hooks it has not run before (case-folded), the option that trusts them, and the
# footer of its list of hooks, where `t` trusts them all.
HOOK_REVIEW, HOOK_TRUST, HOOK_LIST = "hooks need review", "Trust all and continue", "t trust all"
# The footer of one event's hooks, opened from that list: closed with Esc.
HOOK_DETAIL = "space/enter toggle · esc back"
# The event a driver posts when a prompt is submitted.
PROMPTED = frozenset({"UserPromptSubmit", "agent_start"})
# The event a CLI's driver posts as it starts, and how long an idle screen must hold without one.
SESSION_START = frozenset({"SessionStart", "session_start"})
IDLE_HOLD = 5.0
# The event that ends a turn, as each CLI's driver posts it.
TURN_END: dict[AgentKind, frozenset[str]] = {
    "claude": frozenset({"Stop", "StopFailure"}),
    "codex": frozenset({"Stop"}),
    "pi": frozenset({"agent_settled"}),
}
# Flags AiTerm passes that a CLI's --help leaves out, each proved instead by a headless run whose
# answer shows the flag took effect: the marker it makes the model say.
HIDDEN_FLAG_PROBES: dict[AgentKind, dict[str, str]] = {"claude": {"--append-system-prompt-file": "ZULU"}}


# -- the parts tests/test_compat_capture.py pins ---------------------------------------------------
def fill(words: Iterable[str], values: Mapping[str, str]) -> list[str]:
    """A launch template's words with each `{name}` in `values` filled in; a word naming nothing else
    is kept, so a template never loses a word."""
    def one(word: str) -> str:
        for name, value in values.items():
            word = word.replace("{" + name + "}", value)
        return word
    return [one(word) for word in words]


def version_line(version: str | None) -> str | None:
    """The major and minor a verification covers, the app's rule (`DeliveryCheck.covers`)."""
    found = re.fullmatch(r"(\d+)\.(\d+)\.\d+", version or "")
    return f"{int(found[1])}.{int(found[2])}" if found else None


def merged_verified(existing: Any, versions: Mapping[str, str], day: str) -> dict[str, Any]:
    """compat/verified.json with each CLI just verified in place of its old entry, every other kept."""
    entries = dict(existing) if isinstance(existing, dict) else {}
    for agent, version in versions.items():
        if (line := version_line(version)) is not None:
            entries[agent] = {"verified": line, "version": version, "checkedAt": day}
    return dict(sorted(entries.items()))


# The CLIs the delivery check covers (delivery_check.AGENTS): Messaging is part of their verdict.
MESSAGED: tuple[AgentKind, ...] = ("claude", "codex")


def delivery_problems(policy: Any, versions: Mapping[str, str], since: str) -> list[str]:
    """Why the delivery check run alongside this capture does not count as passed for each messaged
    CLI captured: its exit code says nothing (it returns 0 when a scenario fails, or iTerm2 is out of
    reach), so its file is read. An entry must be there, written during this run (`checkedAt` no
    earlier than `since`, both UTC in the check's own format), for the version captured, with
    pasteSafe and submitSafe. Empty when it passed."""
    problems = []
    entries = policy if isinstance(policy, dict) else {}
    for agent in (agent for agent in MESSAGED if agent in versions):
        entry = entries.get(agent)
        if not isinstance(entry, dict):
            problems.append(f"{agent}: the delivery check wrote no verdict")
        elif not isinstance(entry.get("checkedAt"), str) or entry["checkedAt"] < since:
            problems.append(f"{agent}: the delivery check wrote no verdict during this run")
        elif entry.get("version") != versions[agent]:
            problems.append(f"{agent}: the delivery check ran {entry.get('version')}, not the {versions[agent]} captured")
        elif entry.get("pasteSafe") is not True or entry.get("submitSafe") is not True:
            problems.append(f"{agent}: messaging failed" + (f" at {entry['failedAt']}" if entry.get("failedAt") else ""))
    return problems


@dataclass(frozen=True, slots=True)
class Secret:
    """A value no capture may hold, and what stands for it there. `kind` names it in a refusal,
    which never prints the value itself."""
    value: str
    placeholder: str
    kind: str


HOME_PATH = re.compile(r"(?:/|-)HOME(?:/|-|\b)")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
# Short values (a first name, a three-letter id) would replace innocent text; none of AiTerm's
# private values is that short, and an email is caught by its shape whatever its length.
MIN_SECRET = 4


def _jwt_claims(token: Any) -> dict[str, Any]:
    if not isinstance(token, str) or token.count(".") != 2:
        return {}
    body = token.split(".")[1]
    try:
        claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    except (ValueError, TypeError):
        return {}
    return claims if isinstance(claims, dict) else {}


def account_values(claude_state: Any, codex_auth: Any, pi_auth: Any) -> list[tuple[str, str]]:
    """Every account detail the CLIs' own files hold, as (kind, value): Claude's account in
    ~/.claude.json, Codex's login and its token's claims, PI's sign-ins. The tokens are among them,
    though no CLI writes one where the capture reads: a capture that held one must never be written."""
    found: list[tuple[str, str]] = []
    account = claude_state.get("oauthAccount") if isinstance(claude_state, dict) else None
    if isinstance(account, dict):
        for key in ("emailAddress", "displayName", "fullName", "organizationName", "accountUuid", "organizationUuid"):
            if isinstance(value := account.get(key), str):
                found.append((f"claude {key}", value))
    if isinstance(codex_auth, dict):
        found_tokens = codex_auth.get("tokens")
        tokens: dict[str, Any] = found_tokens if isinstance(found_tokens, dict) else {}
        for key in ("account_id", "access_token", "refresh_token", "id_token"):
            if isinstance(value := tokens.get(key), str):
                found.append((f"codex {key}", value))
        if isinstance(value := codex_auth.get("OPENAI_API_KEY"), str):
            found.append(("codex api key", value))
        claims = _jwt_claims(tokens.get("id_token"))
        for key in ("email", "name", "sub", "sid"):
            if isinstance(value := claims.get(key), str):
                found.append((f"codex {key}", value))
        # Its account claims' identifiers and the organisations' names; not the plan, dates or role,
        # ordinary words a transcript says too.
        auth = claims.get("https://api.openai.com/auth")
        if isinstance(auth, dict):
            for key in ("chatgpt_account_id", "chatgpt_user_id", "user_id"):
                if isinstance(value := auth.get(key), str):
                    found.append((f"codex {key}", value))
            for organization in auth.get("organizations") or []:
                for key in ("id", "title"):
                    # "Personal" is every ChatGPT account's own organisation, and an ordinary word.
                    if isinstance(organization, dict) and isinstance(value := organization.get(key), str) and value != "Personal":
                        found.append((f"codex organization {key}", value))
    if isinstance(pi_auth, dict):
        for provider, entry in pi_auth.items():
            if isinstance(entry, dict):
                for key in ("access", "refresh", "accountId", "key"):
                    if isinstance(value := entry.get(key), str):
                        found.append((f"pi {provider} {key}", value))
    return found


def secrets(home: Path, user: str, scratch: Path, accounts: Iterable[tuple[str, str]], outside: Path | None = None) -> tuple[Secret, ...]:
    """What a capture is scrubbed of, longest first, so the scratch folder (under the home) goes before
    the home and a value never leaves a piece of itself behind. A value too short to tell from
    ordinary text is left out (MIN_SECRET), and the same value is listed once."""
    listed = [Secret(str(scratch.resolve()), "/SCRATCH", "scratch folder"), Secret(str(scratch), "/SCRATCH", "scratch folder"),
              Secret(str(home), "/HOME", "home folder"), Secret(user, "USER", "user name")]
    if outside is not None:
        listed += [Secret(str(outside.resolve()), "/OUTSIDE", "outside folder"), Secret(str(outside), "/OUTSIDE", "outside folder")]
    # The machine's temporary folder, which the scratch folder is in: not private, but this Mac's own,
    # so a capture taken elsewhere reads the same.
    temporary = Path(tempfile.gettempdir())
    listed += [Secret(str(temporary.resolve()), "/TMPDIR", "temporary folder"), Secret(str(temporary), "/TMPDIR", "temporary folder")]
    # Claude names a project's folder by its path with every other character a dash
    # (`-Users-me-Library-Caches-…`).
    listed += [Secret(re.sub(r"[^A-Za-z0-9]", "-", str(path)), placeholder, kind)
               for path, placeholder, kind in ((scratch.resolve(), "-SCRATCH", "scratch folder"), (scratch, "-SCRATCH", "scratch folder"),
                                               (home, "-HOME", "home folder"))]
    for index, (kind, value) in enumerate(accounts):
        listed.append(Secret(value, f"ACCOUNT{index}", kind))
    seen: set[str] = set()
    unique = []
    for secret in listed:
        if len(secret.value) >= MIN_SECRET and secret.value not in seen:
            seen.add(secret.value)
            unique.append(secret)
    return tuple(sorted(unique, key=lambda secret: len(secret.value), reverse=True))


def scrub(text: str, listed: Iterable[Secret]) -> str:
    for secret in listed:
        text = text.replace(secret.value, secret.placeholder)
    return EMAIL.sub("EMAIL", text)


def leaks(text: str, listed: Iterable[Secret]) -> list[str]:
    """What of `listed` the text still holds, by kind, in any case (scrubbing replaces the exact value,
    so a user name capitalised in a path survives it), and whether it holds anything shaped like an
    email: empty for a text that may be written."""
    folded = text.casefold()
    found = [secret.kind for secret in listed if secret.value.casefold() in folded]
    # Nothing the capture runs lives in the home folder, so a path there is a file of the person's
    # the CLI read on its own: their instructions (a CLAUDE.md up the tree), their settings.
    if HOME_PATH.search(text):
        found.append("a path in the home folder")
    if EMAIL.search(text):
        found.append("an email address")
    return found


class Leak(Exception):
    """A capture that still held a private value after scrubbing: nothing of it was written into the
    repository. `kept` is where it was put instead, scrubbed, for the maintainer to read."""

    def __init__(self, message: str, kept: Path | None = None):
        super().__init__(message)
        self.kept = kept


def write_capture(files: Mapping[str, str], into: Path, listed: tuple[Secret, ...]) -> None:
    """Writes `files` (relative path to text) as the capture in `into`, scrubbed, in place of the last
    one: built beside it and moved in whole, so a refused or failed capture leaves the last one as it
    was. Refuses (`Leak`) when a name or a text still holds a private value."""
    scrubbed = {scrub(name, listed): scrub(text, listed) for name, text in files.items()}
    found = sorted({f"{name}: {kind}" for name, text in scrubbed.items() for kind in leaks(name + "\n" + text, listed)})
    if found:
        kept = Path(tempfile.mkdtemp(prefix=f"aiterm-compat-refused-{into.name}-"))
        for name, text in scrubbed.items():
            (kept / name).parent.mkdir(parents=True, exist_ok=True)
            (kept / name).write_text(text, encoding="utf-8")
        raise Leak("the capture still holds private values, so nothing was written: " + "; ".join(found), kept)
    staging = into.with_name(f".{into.name}.new")
    shutil.rmtree(staging, ignore_errors=True)
    for name, text in scrubbed.items():
        path = staging / name
        if not path.resolve().is_relative_to(staging.resolve()):
            raise ValueError(f"a capture file outside its folder: {name}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    shutil.rmtree(into, ignore_errors=True)
    staging.rename(into)


def claude_settings(template: str, port: int, scratch_home: Path, shim: Path, kept: Mapping[str, Any]) -> str:
    """The scratch settings.json: the app's merge (compat/drivers/claude-settings.json) at the
    listener's port, beside what of the person's settings the scratch config kept (its theme), with
    the status line running the unchanged shim on the scratch HOME, whose hook-port names the
    listener. Claude runs the status-line command through a shell."""
    settings = json.loads(template.replace(PORT_WORD, str(port)))
    settings["statusLine"]["command"] = f"env HOME={shlex.quote(str(scratch_home))} {shlex.quote(str(shim))}"
    return json.dumps({**kept, **settings}, indent=2, sort_keys=True) + "\n"


def codex_config(template: str, port: int, real_config: str) -> str:
    """The scratch config.toml: the person's screen settings (delivery_check.screen_settings) and the
    app's hook block (compat/drivers/codex-hooks.toml) at the listener's port."""
    kept = screen_settings(real_config)
    return (kept + "\n" if kept else "") + template.replace(PORT_WORD, str(port))


def pi_settings(real: Any) -> str:
    """The scratch agent dir's settings.json: the default provider and model alone, so none of the
    person's packages or extensions load beside AiTerm's."""
    kept = {key: real[key] for key in ("defaultProvider", "defaultModel") if isinstance(real, dict) and key in real}
    return json.dumps(kept, indent=2) + "\n"


# The records of a Claude transcript that describe the account's environment rather than the
# conversation: its organisation, the skills, agents and connectors it provisions, the system prompt
# and every API request. No reader of AiTerm's reads them, and a capture is public.
CLAUDE_ACCOUNT_RECORDS = frozenset({"api-request", "api-request-shape", "api-request-blob"})
CLAUDE_ACCOUNT_ATTACHMENTS = frozenset({"prompt_snapshot", "skill_listing", "agent_listing_delta", "deferred_tools_delta",
                                        "mcp_instructions_delta", "credential_org", "session_context", "environment",
                                        "remote_session_change"})


def without_account(transcript: str) -> str:
    """A Claude transcript with the records that describe the account left out (CLAUDE_ACCOUNT_*);
    every other line as it was, a line that is no JSON object included."""
    kept = []
    for line in transcript.splitlines(keepends=True):
        try:
            record = json.loads(line)
        except ValueError:
            kept.append(line)
            continue
        attachment = record.get("attachment") if isinstance(record, dict) else None
        if isinstance(record, dict) and (record.get("type") in CLAUDE_ACCOUNT_RECORDS or (
                isinstance(attachment, dict) and attachment.get("type") in CLAUDE_ACCOUNT_ATTACHMENTS)):
            continue
        kept.append(line)
    return "".join(kept)


def private_terms(path: Path) -> list[tuple[str, str]]:
    """Words of the person's own no capture may hold, one a line (`#` starts a comment): an
    employer's or client's name the account's skills or connectors might carry. The file is theirs,
    outside the repository; none when it is missing."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    return [("a private term", line.strip()) for line in lines if line.strip() and not line.lstrip().startswith("#")]


# -- the live capture (by hand only) -----------------------------------------------------------------
def say(line: str) -> None:
    print(f"  {line}", flush=True)


def now_day() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")


def run(argv: list[str], env: Mapping[str, str] | None = None, cwd: Path | None = None,
        seconds: float = 180) -> subprocess.CompletedProcess[str]:
    """A CLI run to its end, its stdin closed: `codex exec` otherwise waits on it for ever."""
    return subprocess.run(argv, capture_output=True, text=True, timeout=seconds, stdin=subprocess.DEVNULL,
                          env={**os.environ, **(env or {})}, cwd=cwd)


def cli_version(agent: AgentKind, env: Mapping[str, str] | None = None) -> str | None:
    try:
        return parse_version(run([agent, "--version"], env=env, seconds=60).stdout)
    except (OSError, subprocess.SubprocessError):
        return None


def help_text(agent: AgentKind, env: Mapping[str, str]) -> str:
    """Every --help text AiTerm's flags may be listed in: Codex's subcommands have their own."""
    commands = {"claude": [["claude", "--help"]], "pi": [["pi", "--help"]],
                "codex": [["codex", "--help"], ["codex", "exec", "--help"], ["codex", "resume", "--help"]]}[agent]
    return "\n".join(f"$ {' '.join(command)}\n{run(command, env=env, seconds=60).stdout}" for command in commands)


def launches() -> dict[str, dict[str, list[str]]]:
    templates: dict[str, dict[str, list[str]]] = json.loads((COMPAT / "launch.json").read_text(encoding="utf-8"))
    return templates


@dataclass
class Listener:
    """The capture's stand-in for the daemon: the daemon's own HookServer, every post kept in order."""
    posts: list[dict[str, Any]] = field(default_factory=list)
    server: HookServer | None = None

    async def start(self) -> int:
        async def record(route: str, payload: dict[str, Any]) -> None:
            self.posts.append({"route": route, "body": payload})
        self.server = HookServer(on_post=record, port=0)
        await self.server.start()
        return self.server.port

    async def stop(self) -> None:
        if self.server:
            await self.server.stop()

    def count(self, events: frozenset[str]) -> int:
        return sum(1 for post in self.posts if post["body"].get("hook_event_name") in events)

    def names(self) -> set[str]:
        return {name for post in self.posts if isinstance(name := post["body"].get("hook_event_name"), str)}

    def jsonl(self) -> str:
        return "".join(json.dumps(post, sort_keys=True) + "\n" for post in self.posts)


@dataclass
class Session:
    """One CLI running in an iTerm2 window the capture drives."""
    live: Live
    listener: Listener
    agent: AgentKind
    sid: str
    window: str
    # Each distinct screen title the tab showed, and each distinct session file Claude wrote.
    titles: list[str] = field(default_factory=list)
    session_files: dict[str, str] = field(default_factory=dict)
    claude_sessions: Path | None = None
    # Whether the tab's foreground process is the agent: until it is, a prompt glyph on the screen is
    # the shell's (a ❯ prompt reads as Claude's input box).
    running: bool = False

    async def look(self) -> str:
        """The screen, the tab's title and Claude's session file, as they are now."""
        screen = await self.live.screen(self.sid)
        info = await self.live.bridge.session_info(self.sid)
        if info is not None:
            self.running = classify_agent(info.command_line) == self.agent
            if info.title and info.title not in self.titles:
                self.titles.append(info.title)
            if self.claude_sessions and info.job_pid:
                path = self.claude_sessions / f"{info.job_pid}.json"
                with contextlib.suppress(OSError, ValueError):
                    text = path.read_text(encoding="utf-8")
                    status = json.loads(text).get("status")
                    if isinstance(status, str) and status not in self.session_files:
                        self.session_files[status] = text
        return screen

    async def wait(self, done: Callable[[str], bool], seconds: float) -> bool:
        deadline = time.monotonic() + seconds
        while True:
            if done(await self.look()):
                return True
            if time.monotonic() >= deadline:
                return False
            await asyncio.sleep(0.5)

    async def type(self, text: str) -> None:
        """A bracketed paste, then Enter once it has landed."""
        await self.live.paste(self.sid, text)
        await asyncio.sleep(0.8)
        await self.live.bridge.send_text(self.sid, "\r")

    async def turn(self, text: str, *, approve: bool = False, ends: int = 1, seconds: float = TURN_SECONDS, hold: float = 0) -> None:
        """Sends `text` once the CLI is idle and waits for `ends` more turn ends from the driver,
        answering each approval it asks with its default (Enter, which runs the command once) when
        `approve`, else Esc, once it has been open `hold` seconds: a CLI tells its hooks about a
        waiting prompt only after a while. A hook review that took the text is answered, and the
        text typed again."""
        await self.settle()
        before, asked = self.listener.count(TURN_END[self.agent]), self.listener.count(PROMPTED)
        await self.type(text)
        deadline = time.monotonic() + seconds
        while self.listener.count(TURN_END[self.agent]) < before + ends:
            if time.monotonic() >= deadline:
                raise CaptureFailed(f"{self.agent}: no turn end within {seconds:g} seconds of {text!r}", await self.look())
            screen = await self.look()
            if await self.answer_hook_review(screen):
                await self.settle()
                if self.listener.count(PROMPTED) == asked:
                    say(f"{self.agent}: the review took the prompt; typing it again")
                    await self.type(text)
                continue
            if open_prompt(self.agent, screen) == "permission":
                await asyncio.sleep(hold)
                await self.live.bridge.send_text(self.sid, "\r" if approve else ESC)
                await asyncio.sleep(1.5)
            await asyncio.sleep(0.5)

    async def settle(self, seconds: float = START_SECONDS) -> None:
        """Waits for the CLI's idle screen, answering a hook review on the way; PI draws no input box
        to wait for, and its turns wait on its posts alone."""
        if self.agent == "pi":
            return
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            screen = await self.look()
            if not await self.answer_hook_review(screen) and idle(self.agent)(screen):
                return
            await asyncio.sleep(0.5)
        raise CaptureFailed(f"{self.agent}: not idle within {seconds:g} seconds", await self.look())

    async def answer_hook_review(self, screen: str) -> bool:
        """Trusts the driver's hooks where Codex asks to review them, as a person installing AiTerm's
        driver does once. Its dialog (0.167: "Hooks need review") opens on reviewing them: the arrow
        moves to HOOK_TRUST, then Enter. Its list of hooks, where an Enter on that default leads,
        trusts them all with `t`, then closes with Esc, as does one event's page opened from it.
        Whether any of them was there."""
        if HOOK_DETAIL in screen:
            say(f"{self.agent}: closing a hook's page")
            await self.live.bridge.send_text(self.sid, ESC)
            await asyncio.sleep(1)
            return True
        if HOOK_LIST in screen:
            say(f"{self.agent}: trusting the hooks from their list, then closing it")
            if HOOK_REVIEW in screen.casefold():
                await self.live.bridge.send_text(self.sid, "t")
                await asyncio.sleep(1.5)
            await self.live.bridge.send_text(self.sid, ESC)
            await asyncio.sleep(1)
            return True
        if HOOK_REVIEW not in screen.casefold():
            return False
        for _ in range(6):
            option = next((line for line in screen.splitlines() if HOOK_TRUST in line), None)
            if option is None:
                return False
            if option.lstrip().startswith("›"):
                say(f"{self.agent}: trusting the hooks it asked to review")
                await self.live.bridge.send_text(self.sid, "\r")
                await asyncio.sleep(1.5)
                return True
            await self.live.bridge.send_text(self.sid, "\x1b[B")
            await asyncio.sleep(0.5)
            screen = await self.look()
        raise CaptureFailed(f"{self.agent}: could not trust the driver's hooks in its review", screen)


class CaptureFailed(Exception):
    def __init__(self, reason: str, screen: str = ""):
        super().__init__(reason + ("\nLast screen:\n" + "\n".join(screen.rstrip().splitlines()[-30:]) if screen else ""))


async def open_session(live: Live, listener: Listener, agent: AgentKind, folder: Path, command: str,
                       claude_sessions: Path | None = None) -> Session:
    """Starts `command` in a new window in `folder`, and answers what the CLI asks first: an update
    offer (declined with Esc, as the daemon declines one), its folder trust, and Codex's review of
    hooks it has not seen (its default, trust them)."""
    window, sid = await live.bridge.create_window(str(folder), f"compat capture · {agent}", {}, Frame(120, 80, 1100, 760))
    session = Session(live, listener, agent, sid, window, claude_sessions=claude_sessions)
    # A CLI that never gets ready is closed here: its caller only closes a session it was handed.
    try:
        await asyncio.sleep(1)
        await live.bridge.send_text(sid, f" {command}\n")
        deadline = time.monotonic() + START_SECONDS
        idle_since: float | None = None
        while time.monotonic() < deadline:
            screen = await session.look()
            if not session.running:
                await asyncio.sleep(0.5)
                continue
            prompt = open_prompt(agent, screen) if agent != "pi" else None
            if agent == "pi" and listener.count(frozenset({"session_start"})):
                await asyncio.sleep(2)
                return session
            if prompt == "startup" and shows_update_offer(agent, screen):
                await live.bridge.send_text(sid, ESC)
                await asyncio.sleep(1.5)
            elif prompt == "startup":
                if not await answer_trust(live, agent, sid):
                    raise CaptureFailed(f"{agent}: could not trust the scratch folder", screen)
            elif await session.answer_hook_review(screen):
                pass
            elif prompt == "menu":
                await live.bridge.send_text(sid, "\r")
                await asyncio.sleep(1.5)
            elif agent != "pi" and idle(agent)(screen):
                # Idle once the CLI's own session start posted, or once its idle screen has held: a
                # dialog can draw a moment after the CLI starts, over a screen that already looked idle.
                idle_since = idle_since or time.monotonic()
                if listener.count(SESSION_START) or time.monotonic() - idle_since >= IDLE_HOLD:
                    return session
            else:
                idle_since = None
            await asyncio.sleep(0.5)
        raise CaptureFailed(f"{agent}: not ready within {START_SECONDS:g} seconds", await session.look())
    except BaseException:
        await close(session)
        raise


async def close(session: Session) -> None:
    """Ends the CLI with two Ctrl-Cs and closes its window, whatever state it was left in."""
    with contextlib.suppress(Exception):
        await session.live.bridge.send_text(session.sid, "\x03\x03")
        await asyncio.sleep(1.5)
        await session.live.bridge.close_window(session.window)


async def slash_command(session: Session, command: str) -> None:
    """Types a slash command that only reports, and closes whatever it opened."""
    await session.type(command)
    await asyncio.sleep(4)
    if open_prompt(session.agent, await session.look()) is not None:
        await session.live.bridge.send_text(session.sid, ESC)
    await asyncio.sleep(1)


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def tree(root: Path, into: str, pattern: str = "*") -> dict[str, str]:
    """Every text file under `root` matching `pattern`, named under `into`."""
    found: dict[str, str] = {}
    if root.is_dir():
        for path in sorted(root.rglob(pattern)):
            if path.is_file() and (text := read_text(path)) is not None:
                found[f"{into}/{path.relative_to(root)}"] = text
    return found


def capture_note(agent: AgentKind, version: str, launch: list[str], turns: list[str], extra: Mapping[str, Any] | None = None) -> str:
    model, reasoning = MODELS[agent]
    note = {"agent": agent, "version": version, "capturedAt": now_day(), "model": model, "reasoning": reasoning,
            "launch": launch, "turns": turns, **(extra or {})}
    return json.dumps(note, indent=2, sort_keys=True) + "\n"


async def capture_claude(live: Live, listener: Listener, port: int, scratch: Path, version: str) -> dict[str, str]:
    home = Path.home()
    config = scratch_claude_config(home / ".claude", home / ".claude.json", scratch)
    kept = read_json(config / "settings.json") or {}
    scratch_home = scratch / "shim-home"
    support = scratch_home / "Library" / "Application Support" / "AiTerm"
    support.mkdir(parents=True)
    (support / "hook-port").write_text(str(port), encoding="utf-8")
    template = (COMPAT / "drivers" / "claude-settings.json").read_text(encoding="utf-8")
    (config / "settings.json").write_text(claude_settings(template, port, scratch_home, SHIM, kept), encoding="utf-8")
    work = scratch / "work"
    work.mkdir()
    env = {"CLAUDE_CONFIG_DIR": str(config), "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""}
    model, reasoning = MODELS["claude"]
    values = {"model": model, "reasoning": reasoning}
    launch = fill(launches()["claude"]["task"], values)
    command = " ".join(["env"] + [f"{key}={shlex.quote(value)}" for key, value in env.items()] + [shlex.quote(word) for word in launch])
    turns = ["plain", "shellCommand", "subagent", "backgroundShell", "slashCommand", "approval"]
    session = await open_session(live, listener, "claude", work, command, claude_sessions=config / "sessions")
    try:
        say("claude: a plain turn")
        await session.turn("Reply with only the word ALPHA followed by the result of 6 times 7.")
        say("claude: a turn that runs a command")
        await session.turn("Run exactly this shell command and nothing else: touch BRAVO-42.txt", approve=True)
        say("claude: a turn that starts a subagent")
        await session.turn("Use the Agent tool to start exactly one subagent with the prompt 'Reply with only the word CHARLIE.' "
                           "Then reply with only what it answered.", approve=True)
        say("claude: a turn that starts a background shell")
        await session.turn("Run this shell command in the background with run_in_background set to true, and do not wait for it: "
                           "sleep 4 && touch DELTA-DONE.txt. Reply with only the word STARTED.", approve=True)
        # The shell ends after the turn: Claude is told, and takes another turn to say so.
        stops = listener.count(TURN_END["claude"])
        deadline = time.monotonic() + TURN_SECONDS
        while listener.count(TURN_END["claude"]) == stops and time.monotonic() < deadline:
            await asyncio.sleep(1)
            await session.look()
        await asyncio.sleep(2)
        # One AiTerm types itself. A session launched with --model keeps it, so nothing switches: its
        # output reports nothing of the account, where /context lists the account's connectors.
        say("claude: a slash command")
        await slash_command(session, "/model sonnet")
        await session.look()
    finally:
        await close(session)
    # The task launch names no permission mode, and Claude's default (auto) lets a classifier approve:
    # the approval runs where Claude asks, as the delivery check starts it. A command that writes, as
    # Claude runs one that only reads (echo, sleep) without asking in any mode.
    say("claude: a turn that asks for approval, in a session that asks")
    asking = await open_session(live, listener, "claude", work, command + " --permission-mode default")
    try:
        await asking.turn("Run exactly this shell command and nothing else: touch ECHO-42.txt", approve=True, hold=10)
    finally:
        await close(asking)
    files: dict[str, str] = {"posts.jsonl": listener.jsonl(), "titles.json": json.dumps(session.titles, indent=2) + "\n"}
    for status, text in session.session_files.items():
        files[f"sessions/{status}.json"] = text
    projects = config / "projects"
    files |= {name: without_account(text) for name, text in tree(projects, "projects", "*.jsonl").items()}
    files |= tree(config / "cache" / "model-catalog", "model-catalog", "*-cc.json")
    catalogue = "the session's own"
    if not any(name.startswith("model-catalog/") for name in files):
        # Claude Code fetches its signed catalogue on a schedule of its own, which a short scratch
        # session need not reach: then the catalogue it keeps for the person, which the app reads too.
        # ~/.claude, as everywhere here: its account is the one `private_values` scrubs.
        kept_catalogue = sorted((home / ".claude" / "cache" / "model-catalog")
                                .glob("*-cc.json"), key=lambda path: path.stat().st_mtime)
        if kept_catalogue:
            files[f"model-catalog/{kept_catalogue[-1].name}"] = kept_catalogue[-1].read_text(encoding="utf-8")
            fetched = (read_json(kept_catalogue[-1]) or {}).get("fetchedAt")
            catalogue = "the person's, fetched " + (datetime.datetime.fromtimestamp(fetched / 1000, datetime.UTC).strftime("%Y-%m-%d")
                                                    if isinstance(fetched, int) else "at an unknown time")
    state = read_json(config / ".claude.json") or {}
    files["claude-state.json"] = json.dumps({key: state[key] for key in ("additionalModelOptionsCache",) if key in state},
                                            indent=2, sort_keys=True) + "\n"
    files |= claude_headless(env, work, scratch)
    files["help.txt"] = help_text("claude", env)
    files["capture.json"] = capture_note("claude", version, launch, turns, {"modelCatalogue": catalogue})
    return files


def claude_headless(env: Mapping[str, str], work: Path, scratch: Path) -> dict[str, str]:
    """The app's headless Claude runs: the Oracle's challenge, the fixer's look with its schema, and
    the flags --help leaves out, each proved by its marker in the answer."""
    model, reasoning = MODELS["claude"]
    templates = launches()["claude"]
    base = {"model": model, "reasoning": reasoning, "folder": str(work), "project": str(work), "answer": str(scratch / "answer.txt")}
    files: dict[str, str] = {}
    say("claude: headless runs")
    challenge = run(fill(templates["challenge"], base | {"prompt": "Reply with only the word OK."}), env=env, cwd=work)
    files["headless/challenge.json"] = challenge.stdout
    look = run(fill(templates["fixerLook"], base | {"session": str(uuid.uuid4()),
               "prompt": "This is a test of your answer's format only; nothing needs fixing. Answer with outcome none "
                         "and a one-sentence summary saying so."}), env=env, cwd=work)
    files["headless/fixer-look.json"] = look.stdout
    probes: dict[str, Any] = {}
    for flag, marker in HIDDEN_FLAG_PROBES["claude"].items():
        extra = scratch / f"probe{flag.replace('-', '_')}.md"
        extra.write_text(f"End every answer with the word {marker}.\n", encoding="utf-8")
        argv = fill(templates["challenge"], base | {"prompt": "Reply with only the word OK."}) + [flag, str(extra)]
        answer = run(argv, env=env, cwd=work)
        result = (json.loads(answer.stdout) if answer.stdout.strip().startswith("{") else {}).get("result")
        probes[flag] = {"marker": marker, "status": answer.returncode, "answer": result}
    files["probes.json"] = json.dumps(probes, indent=2, sort_keys=True) + "\n"
    return files


async def capture_codex(live: Live, listener: Listener, port: int, scratch: Path, version: str) -> dict[str, str]:
    real = Path.home() / ".codex"
    codex_home = scratch_codex_home(real, scratch)
    template = (COMPAT / "drivers" / "codex-hooks.toml").read_text(encoding="utf-8")
    (codex_home / "config.toml").write_text(codex_config(template, port, read_text(real / "config.toml") or ""), encoding="utf-8")
    work = scratch / "work"
    work.mkdir()
    # Its own HOME too: Codex reads skills from ~/.claude/skills and ~/.agents/skills, the person's,
    # and names them in every rollout. Its login is the copy in CODEX_HOME.
    (scratch / "home").mkdir(exist_ok=True)
    env = {"CODEX_HOME": str(codex_home), "HOME": str(scratch / "home")}
    model, reasoning = MODELS["codex"]
    values = {"model": model, "reasoning": reasoning}
    templates = launches()["codex"]
    launch = fill(templates["task"], values)
    prefix = "env " + " ".join(f"{key}={shlex.quote(value)}" for key, value in env.items()) + " "
    turns = ["plain", "shellCommand", "subagent", "approval"]
    session = await open_session(live, listener, "codex", work, prefix + " ".join(map(shlex.quote, launch)))
    try:
        say("codex: a plain turn")
        await session.turn("Reply with only the word ALPHA followed by the result of 6 times 7.")
        say("codex: a turn that runs a command")
        await session.turn("Run exactly this shell command and nothing else: echo BRAVO-$((20+22))")
        say("codex: a turn that starts a subagent")
        await session.turn("Spawn exactly one subagent with the task 'Reply with only the word CHARLIE.', wait for it, "
                           "then reply with only its answer.")
    finally:
        await close(session)
    titles = list(session.titles)
    # The task launch never asks; the approval runs where Codex does, as the delivery check starts it.
    say("codex: a turn that asks for approval, in a session that asks")
    asking = fill(templates["task"][:1], values) + ["-s", "workspace-write", "-a", "on-request"] + fill(templates["task"][2:], values)
    session = await open_session(live, listener, "codex", work, prefix + " ".join(map(shlex.quote, asking)))
    try:
        # Outside the sandbox's reach ($TMPDIR is in it), so Codex must ask: `outside` links there.
        # Approved, as declining ends the turn with no Stop; the file is the capture's to delete.
        target = (scratch / "outside").resolve() / "approved.txt"
        await session.turn(f"Run exactly this shell command and nothing else: touch {target} -- run it with sandbox_permissions "
                           "set to require_escalated", approve=True, hold=10)
    finally:
        await close(session)
    files: dict[str, str] = {"posts.jsonl": listener.jsonl(), "titles.json": json.dumps(titles + session.titles, indent=2) + "\n"}
    files |= tree(codex_home / "sessions", "sessions", "*.jsonl")
    if (cache := read_text(codex_home / "models_cache.json")) is not None:
        files["models_cache.json"] = cache
    say("codex: a headless run")
    answer = scratch / "answer.txt"
    challenge = run(fill(templates["challenge"], values | {"prompt": "Reply with only the word OK.", "folder": str(work),
                                                           "project": str(work), "answer": str(answer)}), env=env, cwd=work)
    files["headless/challenge.jsonl"] = challenge.stdout
    files["headless/challenge-answer.txt"] = read_text(answer) or ""
    files["help.txt"] = help_text("codex", env)
    files["capture.json"] = capture_note("codex", version, launch, turns, {"approvalLaunch": asking})
    return files


async def capture_pi(live: Live, listener: Listener, port: int, scratch: Path, version: str) -> dict[str, str]:
    real = Path.home() / ".pi" / "agent"
    agent_dir = scratch / "pi-agent"
    (agent_dir / "extensions").mkdir(parents=True)
    for name in ("auth.json",):
        if (real / name).is_file():
            shutil.copy2(real / name, agent_dir / name)
    (agent_dir / "settings.json").write_text(pi_settings(read_json(real / "settings.json")), encoding="utf-8")
    (agent_dir / "extensions" / "aiterm-status.ts").write_text(
        PI_EXTENSION.read_text(encoding="utf-8").replace(PORT_WORD, str(port)), encoding="utf-8")
    work = scratch / "work"
    work.mkdir()
    # Its own HOME too, as Codex's: PI reads skills from ~/.agents/skills. Its sign-ins are the copy in
    # the agent dir.
    (scratch / "home").mkdir(exist_ok=True)
    env = {"PI_CODING_AGENT_DIR": str(agent_dir), "HOME": str(scratch / "home")}
    model, reasoning = MODELS["pi"]
    values = {"model": model, "reasoning": reasoning}
    templates = launches()["pi"]
    launch = fill(templates["task"], values)
    turns = ["plain", "shellCommand"]
    command = "env " + " ".join(f"{key}={shlex.quote(value)}" for key, value in env.items()) + " " + " ".join(map(shlex.quote, launch))
    session = await open_session(live, listener, "pi", work, command)
    try:
        say("pi: a plain turn")
        await session.turn("Reply with only the word ALPHA followed by the result of 6 times 7.")
        say("pi: a turn that runs a command")
        await session.turn("Run exactly this shell command with your bash tool and nothing else: echo BRAVO-$((20+22))")
    finally:
        await close(session)
    files: dict[str, str] = {"posts.jsonl": listener.jsonl()}
    files["list-models.txt"] = run(["pi", "--offline", "--list-models"], env=env | {"PI_OFFLINE": "1"}, seconds=60).stdout
    say("pi: a headless run")
    challenge = run(fill(templates["challenge"], values | {"prompt": "Reply with only the word OK.", "folder": str(work),
                                                           "project": str(work), "answer": ""}), env=env, cwd=work)
    files["headless/challenge.txt"] = challenge.stdout
    files["help.txt"] = help_text("pi", env)
    files["capture.json"] = capture_note("pi", version, launch, turns)
    return files


CAPTURE: dict[AgentKind, Callable[[Live, Listener, int, Path, str], Awaitable[dict[str, str]]]] = {
    "claude": capture_claude, "codex": capture_codex, "pi": capture_pi}


def chosen_agents(text: str) -> tuple[AgentKind, ...]:
    wanted = {name.strip() for name in text.split(",") if name.strip()}
    if bad := sorted(wanted - set(AGENTS)):
        raise ValueError(f"invalid --agents value {', '.join(map(repr, bad))}; use a comma-separated list of {', '.join(AGENTS)}")
    return tuple(agent for agent in AGENTS if agent in wanted)


# Where the person keeps their private terms (`private_terms`).
PRIVATE_TERMS = Path.home() / ".config" / "aiterm" / "compat-private.txt"


def private_values(scratch: Path, outside: Path) -> tuple[Secret, ...]:
    home = Path.home()
    accounts = account_values(read_json(home / ".claude.json"), read_json(home / ".codex" / "auth.json"),
                              read_json(home / ".pi" / "agent" / "auth.json")) + private_terms(PRIVATE_TERMS)
    return secrets(home, os.environ.get("USER") or home.name, scratch, accounts, outside)


async def capture(agents: tuple[AgentKind, ...], into: Path) -> dict[AgentKind, str]:
    """Captures each of `agents` installed, and writes each capture; the versions written."""
    bridge = ItermBridge()
    await bridge.connect()
    live = Live(bridge)
    written: dict[AgentKind, str] = {}
    try:
        for agent in agents:
            if (version := cli_version(agent)) is None:
                print(f"{agent}: not installed, skipped", flush=True)
                continue
            print(f"{agent} {version}", flush=True)
            listener = Listener()
            port = await listener.start()
            try:
                # The scratch folder is outside the home folder: a CLI looks for instructions up the
                # tree from where it runs (Claude finds ~/.claude/CLAUDE.md from anywhere under ~),
                # and the person's must never reach a capture. Only the folder Codex must ask to
                # write to is in the home folder, where its sandbox does not reach.
                with (tempfile.TemporaryDirectory(prefix=f"aiterm-compat-{agent}-") as folder,
                      tempfile.TemporaryDirectory(prefix="aiterm-compat-outside-", dir=Path.home() / "Library" / "Caches") as outside):
                    scratch = Path(folder)
                    (scratch / "outside").symlink_to(outside)
                    files = await CAPTURE[agent](live, listener, port, scratch, version)
                    files["version.txt"] = version + "\n"
                    write_capture(files, into / agent, private_values(scratch, Path(outside)))
            except Leak as error:
                print(f"{agent}: FAILED -- {error}\nIt is kept, scrubbed, outside the repository for you to see what "
                      f"leaked: {error.kept}. Delete it once read.", flush=True)
                continue
            except CaptureFailed as error:
                print(f"{agent}: FAILED -- {error}", flush=True)
                continue
            finally:
                await listener.stop()
            written[agent] = version
            print(f"{agent}: captured into {into / agent}", flush=True)
    finally:
        await bridge.close()
    return written


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="compat_capture", description="Captures what each agent CLI sends and writes for AiTerm.")
    commands = parser.add_subparsers(dest="command", required=True)
    take = commands.add_parser("capture", help="capture each CLI live")
    take.add_argument("--agents", default=",".join(AGENTS), help=f"comma-separated, from {', '.join(AGENTS)}")
    take.add_argument("--into", type=Path, default=CAPTURES, help="where the captures go (default: the test fixtures)")
    take.add_argument("--written", type=Path, help="a file to write the captured versions into, as JSON")
    gate = commands.add_parser("gate", help="whether the delivery check run alongside passed each CLI captured")
    gate.add_argument("--policy", type=Path, required=True)
    gate.add_argument("--versions", type=Path, required=True, help="the capture's --written file")
    gate.add_argument("--since", required=True, help="when the run started, UTC, as %%Y-%%m-%%dT%%H:%%M:%%SZ")
    record = commands.add_parser("verified", help="record the captured versions in compat/verified.json")
    record.add_argument("--versions", type=Path, required=True, help="the capture's --written file")
    record.add_argument("--file", type=Path, default=COMPAT / "verified.json")
    ns = parser.parse_args(argv)
    if ns.command == "gate":
        problems = delivery_problems(read_json(ns.policy), read_json(ns.versions) or {}, ns.since)
        for problem in problems:
            print(problem, flush=True)
        return 1 if problems else 0
    if ns.command == "verified":
        versions = read_json(ns.versions) or {}
        ns.file.write_text(json.dumps(merged_verified(read_json(ns.file), versions, now_day()), indent=2) + "\n", encoding="utf-8")
        return 0
    try:
        agents = chosen_agents(ns.agents)
    except ValueError as error:
        parser.error(str(error))
    written = asyncio.run(capture(agents, ns.into))
    if ns.written:
        ns.written.write_text(json.dumps(written, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    missing = [agent for agent in agents if agent not in written and cli_version(agent) is not None]
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
