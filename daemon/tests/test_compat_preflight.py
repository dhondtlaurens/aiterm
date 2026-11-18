"""The live check's update boundary, using fake CLIs so tests never update a real installation."""
import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest

from tools import compat_preflight as preflight


def cli(tmp_path, name, version="1.0.0", updated="1.1.0", update_exit=0):
    binary = tmp_path / name
    state = tmp_path / f"{name}.version"
    state.write_text(version)
    log = tmp_path / f"{name}.calls"
    binary.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >> {shlex.quote(str(log))}\n"
        f"if [ \"$1\" = --version ]; then cat {shlex.quote(str(state))}; printf '\\n'; exit 0; fi\n"
        f"printf '%s' {shlex.quote(updated)} > {shlex.quote(str(state))}\n"
        f"exit {update_exit}\n"
    )
    binary.chmod(0o755)
    return binary, state, log


def setup(monkeypatch, tmp_path, agents=("claude", "codex", "pi"), **kwargs):
    installed = {agent: cli(tmp_path, agent, **kwargs) for agent in agents}
    monkeypatch.setattr(preflight.shutil, "which", lambda name: str(installed[name][0]) if name in installed else None)
    monkeypatch.setattr(preflight, "latest_version", lambda agent: "1.1.0")
    return installed


def test_updates_selected_clis_and_checks_before_writing_launchers(monkeypatch, tmp_path):
    installed = setup(monkeypatch, tmp_path)
    into = tmp_path / "checked"
    assert preflight.prepare(("claude", "codex", "pi"), into) == dict.fromkeys(installed, "1.1.0")
    for agent, (_, state, log) in installed.items():
        assert state.read_text() == "1.1.0"
        assert log.read_text().splitlines()[0] == "--version"
        assert (into / agent).is_file()
    assert "update" in installed["codex"][2].read_text().splitlines()


def test_current_clis_are_not_updated_and_unselected_clis_are_untouched(monkeypatch, tmp_path):
    installed = setup(monkeypatch, tmp_path, version="1.1.0")
    preflight.prepare(("pi",), tmp_path / "checked")
    assert installed["pi"][2].read_text().splitlines() == ["--version"]
    assert not installed["claude"][2].exists()
    assert not installed["codex"][2].exists()


@pytest.mark.parametrize("kwargs", [{"updated": "1.0.0"}, {"update_exit": 1}, {"version": "garbage"}])
def test_failed_or_ineffective_updates_never_allow_a_capture(monkeypatch, tmp_path, kwargs):
    setup(monkeypatch, tmp_path, agents=("codex",), **kwargs)
    into = tmp_path / "checked"
    with pytest.raises(preflight.PreflightFailed, match="codex"):
        preflight.prepare(("codex",), into)
    assert not into.exists()


def test_missing_harness_aborts_before_updating_anything(monkeypatch, tmp_path):
    installed = setup(monkeypatch, tmp_path, agents=("claude",))
    with pytest.raises(preflight.PreflightFailed, match="codex.*not installed"):
        preflight.prepare(("claude", "codex"), tmp_path / "checked")
    assert installed["claude"][1].read_text() == "1.0.0"


def test_release_lookup_failure_is_not_assumed_current(monkeypatch, tmp_path):
    setup(monkeypatch, tmp_path)

    def unavailable(agent):
        raise preflight.PreflightFailed(f"{agent}: cannot check latest version")

    monkeypatch.setattr(preflight, "latest_version", unavailable)
    with pytest.raises(preflight.PreflightFailed, match="latest"):
        preflight.prepare(("claude",), tmp_path / "checked")


def test_native_claude_uses_latest_even_when_configured_for_stable(tmp_path):
    binary, _, _ = cli(tmp_path, "native")
    versions = tmp_path / "claude" / "versions"
    versions.mkdir(parents=True)
    target = versions / "1.0.0"
    binary.rename(target)
    link = tmp_path / "claude-bin"
    link.symlink_to(target)
    assert preflight.update_command("claude", str(link)) == [str(link), "install", "latest"]


def test_fresh_shells_use_checked_executable_and_reject_version_drift(monkeypatch, tmp_path):
    installed = setup(monkeypatch, tmp_path, agents=("codex",), version="1.1.0")
    into = tmp_path / "checked binaries"
    preflight.prepare(("codex",), into)
    monkeypatch.setenv("AITERM_COMPAT_BIN", str(into))
    # A terminal's PATH (or a scratch HOME) must not select another installation.
    env = os.environ | {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path / "scratch")}
    result = subprocess.run(preflight.command(["codex", "--version"]), env=env, capture_output=True, text=True)
    assert result.returncode == 0
    assert result.stdout.strip() == "1.1.0"
    installed["codex"][1].write_text("1.2.0")
    result = subprocess.run(preflight.command(["codex", "probe"]), env=env, capture_output=True, text=True)
    assert result.returncode != 0
    assert "version changed" in result.stderr
    assert "probe" not in installed["codex"][2].read_text().splitlines()
    with pytest.raises(preflight.PreflightFailed, match="pi.*not checked"):
        preflight.command(["pi", "--version"])


def test_capture_and_delivery_commands_both_use_checked_binaries(monkeypatch, tmp_path):
    from tools.compat_capture import run
    from tools.delivery_check import agent_command, cli_version

    installed = setup(monkeypatch, tmp_path, agents=("codex",), version="1.1.0")
    into = tmp_path / "checked"
    preflight.prepare(("codex",), into)
    monkeypatch.setenv("AITERM_COMPAT_BIN", str(into))
    assert run(["codex", "--version"]).stdout.strip() == "1.1.0"
    assert cli_version("codex") == "1.1.0"
    home = tmp_path / "home"
    (home / ".codex").mkdir(parents=True)
    launch = agent_command("codex", tmp_path / "delivery", home)
    assert str(into / "codex") in launch
    assert installed["codex"][2].exists()


def test_checked_cli_that_stops_running_is_a_failed_capture_not_a_skip(monkeypatch, tmp_path):
    from tools import compat_capture

    async def failed(*args):
        return {}

    monkeypatch.setenv("AITERM_COMPAT_BIN", str(tmp_path))
    monkeypatch.setattr(compat_capture, "capture", failed)
    monkeypatch.setattr(compat_capture, "cli_version", lambda agent: None)
    assert compat_capture.main(["capture", "--agents", "codex", "--into", str(tmp_path)]) == 1


def test_script_stops_before_capture_when_preflight_fails(tmp_path):
    root = Path(__file__).resolve().parents[2]
    (tmp_path / "scripts").mkdir()
    (tmp_path / "daemon" / ".venv" / "bin").mkdir(parents=True)
    script = tmp_path / "scripts" / "compat-check.sh"
    shutil.copy2(root / "scripts" / "compat-check.sh", script)
    python = tmp_path / "daemon" / ".venv" / "bin" / "python"
    log = tmp_path / "called"
    python.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {shlex.quote(str(log))}\nexit 7\n")
    python.chmod(0o755)
    result = subprocess.run(["zsh", str(script), "codex"], capture_output=True, text=True)
    assert result.returncode == 7
    calls = log.read_text().splitlines()
    assert len(calls) == 1
    assert calls[0].startswith("-m tools.compat_preflight --agents codex --bin ")
    assert "Capturing" not in result.stdout


def test_release_metadata_names_the_current_public_package(monkeypatch):
    import io

    requested = []

    def lookup(url, timeout):
        requested.append(url)
        return io.BytesIO(b'{"version":"1.1.0"}')

    monkeypatch.setattr(preflight.urllib.request, "urlopen", lookup)
    assert preflight.latest_version("pi") == "1.1.0"
    assert requested == ["https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest"]


@pytest.mark.parametrize("payload", [{"version": "1.1.0-beta.1"}, {}, {"version": "bad"}])
def test_invalid_release_metadata_fails_closed(monkeypatch, payload):
    import io

    monkeypatch.setattr(preflight.urllib.request, "urlopen", lambda *args, **kwargs: io.BytesIO(json.dumps(payload).encode()))
    with pytest.raises(preflight.PreflightFailed, match="latest"):
        preflight.latest_version("pi")
