"""Update the requested CLIs before a compatibility run and pin every fresh launch to those checks.

Only scripts/compat-check.sh invokes prepare; importing the command helper never updates anything.
The public npm latest tags name releases for Claude Code, Codex and PI, including native installations;
Antigravity's changelog, which the CLI itself links, heads each release with its version.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

PACKAGES = {"claude": "@anthropic-ai/claude-code", "codex": "@openai/codex", "pi": "@earendil-works/pi-coding-agent"}
CHANGELOGS = {"agy": "https://raw.githubusercontent.com/google-antigravity/antigravity-cli/refs/heads/main/CHANGELOG.md"}
# Every CLI a run checks, in AiTerm's order: launched through its checked launcher.
CHECKED = ("claude", "codex", "agy", "pi")
RELEASE_HEADING = re.compile(r"^## (\d+\.\d+\.\d+)\s*$", re.MULTILINE)
VERSION = re.compile(r"\d+\.\d+\.\d+")


class PreflightFailed(Exception):
    pass


def command(argv: list[str]) -> list[str]:
    """Use the run's checked launcher, also in fresh iTerm shells with a different PATH or HOME."""
    if (directory := os.environ.get("AITERM_COMPAT_BIN")) and argv[0] in CHECKED:
        launcher = Path(directory) / argv[0]
        if not launcher.is_file():
            raise PreflightFailed(f"{argv[0]}: not checked for this compatibility run")
        return [str(launcher), *argv[1:]]
    return argv


def latest_version(agent: str) -> str:
    try:
        if agent in CHANGELOGS:
            with urllib.request.urlopen(CHANGELOGS[agent], timeout=30) as response:
                heading = RELEASE_HEADING.search(response.read().decode("utf-8", "replace"))
            if heading is None:
                raise ValueError("the changelog names no release")
            return heading[1]
        with urllib.request.urlopen(f"https://registry.npmjs.org/{PACKAGES[agent]}/latest", timeout=30) as response:
            version = json.load(response).get("version")
        if not isinstance(version, str) or not VERSION.fullmatch(version):
            raise ValueError("release metadata does not name a stable version")
        return version
    except (OSError, urllib.error.URLError, ValueError, AttributeError) as error:
        raise PreflightFailed(f"{agent}: cannot check latest version: {error}") from error


def installed_version(agent: str, executable: str) -> tuple[str, str]:
    try:
        result = subprocess.run([executable, "--version"], capture_output=True, text=True,
                                stdin=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        raise PreflightFailed(f"{agent}: cannot read installed version: {error}") from error
    output = result.stdout.strip()
    found = re.search(r"(?<![\w.])\d+\.\d+\.\d+(?![\w.+-])", output)
    if result.returncode or not found:
        raise PreflightFailed(f"{agent}: --version failed or did not name a stable version: {output}")
    return found[0], output


def update_command(agent: str, executable: str) -> list[str]:
    # Native Claude's update follows the configured channel. Explicit latest leaves that preference
    # alone. Package-manager installations use their own updater instead of migrating to native.
    parent = Path(executable).resolve().parent
    if agent == "claude" and parent.name == "versions" and parent.parent.name == "claude":
        return [executable, "install", "latest"]
    if agent == "pi":
        return [executable, "update", "--self", "--no-approve"]
    return [executable, "update"]


def prepare(agents: tuple[str, ...], into: Path) -> dict[str, str]:
    # Check every requested installation and release before updating anything. A missing/broken CLI
    # is a failed preflight, never an implicitly skipped compatibility check.
    checked = {}
    for agent in agents:
        executable = shutil.which(agent)
        if not executable:
            raise PreflightFailed(f"{agent}: not installed (not found on PATH)")
        executable = str(Path(executable).absolute())
        version, output = installed_version(agent, executable)
        latest = latest_version(agent)
        print(f"{agent}: installed {version}; latest {latest}", flush=True)
        checked[agent] = (executable, version, output, latest)
    for agent, (executable, version, output, latest) in list(checked.items()):
        if version != latest:
            if tuple(map(int, version.split("."))) > tuple(map(int, latest.split("."))):
                raise PreflightFailed(f"{agent}: installed {version} is ahead of published latest {latest}; refusing to downgrade")
            print(f"{agent}: updating to latest", flush=True)
            try:
                result = subprocess.run(update_command(agent, executable), stdin=subprocess.DEVNULL, timeout=600)
            except (OSError, subprocess.SubprocessError) as error:
                raise PreflightFailed(f"{agent}: update failed: {error}") from error
            if result.returncode:
                raise PreflightFailed(f"{agent}: update failed (exit {result.returncode})")
            version, output = installed_version(agent, executable)
            if version != latest:
                raise PreflightFailed(f"{agent}: update left {version} on PATH; expected latest {latest}. "
                                      "Check the installation and release channel, then rerun.")
            checked[agent] = (executable, version, output, latest)
        print(f"{agent}: ready at {version}", flush=True)
    # Publish launchers only after every update succeeded. Absolute paths avoid aliases, shell
    # hashing, and another global install in new windows. Each launch rechecks the actual version;
    # an updater returning success on a different install cannot produce a verified capture.
    into.mkdir(parents=True, exist_ok=False)
    for agent, (executable, version, output, _) in checked.items():
        launcher = into / agent
        launcher.write_text(
            "#!/bin/sh\nset -eu\n"
            f"export PATH={shlex.quote(os.environ.get('PATH', '/usr/bin:/bin'))}\n"
            f"actual=$({shlex.quote(executable)} --version)\n"
            f"if [ \"$actual\" != {shlex.quote(output)} ]; then\n"
            f"  echo '{agent}: version changed since preflight (expected {version}); rerun compat-check.sh' >&2\n"
            "  exit 1\nfi\n"
            f"exec {shlex.quote(executable)} \"$@\"\n",
            encoding="utf-8",
        )
        launcher.chmod(0o755)
    return {agent: entry[1] for agent, entry in checked.items()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agents", default=",".join(CHECKED))
    parser.add_argument("--bin", type=Path, required=True, help="new directory for this run's checked launchers")
    ns = parser.parse_args(argv)
    wanted = {name.strip() for name in ns.agents.split(",") if name.strip()}
    if not wanted or wanted - set(CHECKED):
        parser.error("--agents must name one or more of " + ",".join(CHECKED))
    try:
        prepare(tuple(agent for agent in CHECKED if agent in wanted), ns.bin)
    except (PreflightFailed, OSError) as error:
        print(f"Preflight failed: {error}. Compatibility checks have not started.", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
