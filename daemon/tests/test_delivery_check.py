# daemon/tests/test_delivery_check.py
"""The delivery check's verdicts: what it writes for each run of scenarios, and that the daemon
reads it as meant. Live dependencies are faked here; real iTerm2 and logged-in CLIs are checked by hand."""
import json

import pytest

from aitermd.delivery import load_policy
from tools.delivery_check import (
    ITERM_CHECKS, PASTE_SAFE, SUBMIT_SAFE, ScenarioResult, agent_entry, allow_rules, chosen_agents, iterm_entry, merged_policy,
    parse_version, scratch_codex_home,
)

NOW = "2026-10-16T07:30:00Z"
OK = ScenarioResult(True, "ok")
FAILED = ScenarioResult(False, "the p chose always allow")


def every(names, result):
    return {name: result for name in names}


def read_back(tmp_path, entries):
    path = tmp_path / "delivery-policy.json"
    path.write_text(json.dumps(entries), encoding="utf-8")
    return load_policy(path)


def test_every_scenario_passed_is_auto_for_the_daemon(tmp_path):
    entry = agent_entry("2.1.301", every(PASTE_SAFE + SUBMIT_SAFE, OK), NOW)
    assert (entry["version"], entry["pasteSafe"], entry["submitSafe"], entry["checkedAt"]) == ("2.1.301", True, True, NOW)
    assert read_back(tmp_path, {"claude": entry})["claude"] == ("auto", "2.1.301")


def test_a_failed_submit_scenario_is_paste_only(tmp_path):
    entry = agent_entry("2.1.301", every(PASTE_SAFE + SUBMIT_SAFE, OK) | {"takeover": FAILED}, NOW)
    assert read_back(tmp_path, {"claude": entry})["claude"] == ("pasteOnly", "2.1.301")


def test_a_failed_paste_scenario_is_off_whatever_else_passed(tmp_path):
    entry = agent_entry("0.160.0", every(PASTE_SAFE + SUBMIT_SAFE, OK) | {"permissionPaste": FAILED}, NOW)
    assert read_back(tmp_path, {"codex": entry})["codex"].policy == "off"


def test_a_cli_whose_version_was_not_read_is_off_whatever_passed(tmp_path):
    entry = agent_entry(None, every(PASTE_SAFE + SUBMIT_SAFE, OK), NOW)
    assert entry["pasteSafe"] and entry["submitSafe"]
    assert read_back(tmp_path, {"claude": entry})["claude"] == ("off", None)


def test_a_scenario_not_run_counts_as_failed():
    entry = agent_entry("0.160.0", every(SUBMIT_SAFE, OK) | {"permissionPaste": OK}, NOW)
    assert not entry["pasteSafe"] and entry["submitSafe"]


def test_each_scenarios_detail_is_kept_for_you_to_read():
    assert agent_entry(None, {"permissionPaste": FAILED}, NOW)["scenarios"] == {
        "permissionPaste": {"passed": False, "detail": "the p chose always allow"}}


def test_the_iterm_entry_is_no_cli_the_daemon_reads(tmp_path):
    entry = iterm_entry("3.7.5", {"keystrokesPassThrough": OK}, NOW)
    assert {name: entry[name] for name in ITERM_CHECKS} == {"keystrokesPassThrough": True, "backgroundWindow": False}
    assert set(read_back(tmp_path, {"iterm": entry}).values()) == {("off", None)}


def test_checking_one_cli_keeps_the_others_verdict():
    old = {"claude": {"pasteSafe": True, "submitSafe": True}, "codex": {"pasteSafe": False}}
    assert merged_policy(old, {"codex": {"pasteSafe": True}}) == {"claude": {"pasteSafe": True, "submitSafe": True},
                                                                  "codex": {"pasteSafe": True}}
    assert merged_policy([1, 2], {"codex": {}}) == {"codex": {}}, "a file that is no object is replaced"


@pytest.mark.parametrize("output,version", [
    ("2.1.301 (Claude Code)\n", "2.1.301"), ("codex-cli 0.160.0", "0.160.0"), ("command not found", None)])
def test_the_version_is_read_from_the_clis_own_line(output, version):
    assert parse_version(output) == version


def test_only_the_known_clis_are_checked_in_their_order():
    assert chosen_agents("codex, claude") == ("claude", "codex")
    assert chosen_agents("claude,claude") == ("claude",)
    assert chosen_agents(" codex ") == ("codex",)


def test_the_scratch_codex_home_gets_only_the_login_and_the_settings(tmp_path):
    real = tmp_path / "real"
    (real / "rules").mkdir(parents=True)
    for name in ("auth.json", "config.toml", "history.jsonl"):
        (real / name).write_text(name, encoding="utf-8")
    (real / "rules" / "default.rules").write_text("allow", encoding="utf-8")
    home = scratch_codex_home(real, tmp_path / "scratch")
    assert sorted(path.name for path in home.iterdir()) == ["auth.json", "config.toml"]
    assert (home / "auth.json").read_text(encoding="utf-8") == "auth.json"


def test_an_allow_rule_a_paste_wrote_is_found(tmp_path):
    assert allow_rules("codex", tmp_path) == [] and allow_rules("claude", tmp_path) == []
    (tmp_path / "codex-home" / "rules").mkdir(parents=True)
    (tmp_path / "codex-home" / "rules" / "default.rules").write_text("allow", encoding="utf-8")
    (tmp_path / "work" / ".claude").mkdir(parents=True)
    (tmp_path / "work" / ".claude" / "settings.local.json").write_text("{}", encoding="utf-8")
    assert allow_rules("codex", tmp_path) == [str(tmp_path / "codex-home" / "rules" / "default.rules")]
    assert allow_rules("claude", tmp_path) == [str(tmp_path / "work" / ".claude" / "settings.local.json")]


@pytest.mark.parametrize("missing", ["menuPaste", "updatePaste", "approvalRace"])
@pytest.mark.parametrize("failed", [False, True])
def test_required_prompt_checks_must_run_and_pass(tmp_path, missing, failed):
    results = every(PASTE_SAFE + SUBMIT_SAFE + ("menuPaste", "updatePaste", "approvalRace"), OK)
    results.pop(missing)
    if failed:
        results[missing] = FAILED
    entry = agent_entry("2.1.301", results, NOW)
    assert read_back(tmp_path, {"claude": entry})["claude"].policy == "off"


@pytest.mark.parametrize("value", ["claude-code", "claude codex", "", " ", "claude,", "claude,grok"])
def test_invalid_agents_are_refused(value):
    with pytest.raises(ValueError, match="--agents claude,codex") as error:
        chosen_agents(value)
    assert repr(value.split(",")[-1].strip()) in str(error.value)


@pytest.mark.parametrize("value", ["claude-code", "claude codex", ""])
def test_main_rejects_agents_before_running(value, capsys, monkeypatch):
    from tools import delivery_check as check
    monkeypatch.setattr(check, "run", lambda *args: pytest.fail("must not run"))
    with pytest.raises(SystemExit) as error:
        check.main(["--agents", value])
    assert error.value.code == 2
    assert "--agents claude,codex" in capsys.readouterr().err


async def fake_session():
    from aitermd.models import Frame
    from tests.fake_iterm import FakeIterm
    bridge = FakeIterm()
    _, sid = await bridge.create_window("/tmp", "test", {}, Frame(0, 0, 100, 100))
    return bridge, sid


async def no_sleep(seconds):
    pass


@pytest.mark.parametrize("scenario,marker", [
    ("startup_paste", "Yes, I trust this folder"),
    ("idle_submit", "ALPHA 42"),
    ("multi_line", "DELTA 5"),
    ("busy_queue", "tointerrupt"),
    ("permission_paste", "Do you want to proceed?"),
])
async def test_failed_scenario_keeps_expected_marker_and_screen(scenario, marker, tmp_path, monkeypatch):
    from types import SimpleNamespace
    from tools import delivery_check as check

    class NeverReady(check.Live):
        async def wait_for(self, sid, seen, seconds):
            return await super().wait_for(sid, seen, 0)

        def deliverer(self, agent, **kwargs):
            async def deliver(*args):
                return SimpleNamespace(result="delivered", reason=None)
            return SimpleNamespace(deliver=deliver)

    bridge, sid = await fake_session()
    bridge.screens[sid] = "unexpected screen text\n\n"
    live = NeverReady(bridge)
    args = (live, "claude", sid, tmp_path) if scenario == "permission_paste" else (live, "claude", sid)
    result = await getattr(check, scenario)(*args)
    assert not result.passed
    assert marker in result.detail
    assert "unexpected screen text" in result.detail
    assert "open_prompt=None" in result.detail
    assert "shows_input_box=False" in result.detail
    assert agent_entry(None, {"failure": result}, NOW)["scenarios"]["failure"]["detail"] == result.detail


async def test_background_waits_for_app_switch():
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm
    bridge = FakeIterm()
    apps = iter(["iterm", "iterm", "other", "other"])
    sleeps = []

    async def sleep(seconds):
        sleeps.append(seconds)

    result = await check.background_window(check.Live(bridge), front=lambda: next(apps), sleep=sleep,
                                           iterm_asn="iterm", seconds=3)
    assert result.passed
    assert sleeps[:2] == [0.5, 0.5]
    assert bridge.screen_reads


async def test_background_timeout_creates_no_window():
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm
    bridge = FakeIterm()
    result = await check.background_window(check.Live(bridge), front=lambda: "iterm", sleep=no_sleep,
                                           iterm_asn="iterm", seconds=1)
    assert not result.passed
    assert "iTerm2 was still in front" in result.detail
    assert "background window was not checked" in result.detail
    assert not bridge.windows and not bridge.sessions


@pytest.mark.parametrize("scenario", ["idle_submit", "multi_line", "busy_queue", "takeover", "permission_paste"])
async def test_delivery_refusal_includes_screen(scenario, tmp_path):
    from types import SimpleNamespace
    from tools import delivery_check as check

    class Refused(check.Live):
        def deliverer(self, agent, **kwargs):
            async def deliver(*args):
                return SimpleNamespace(result="blocked", reason="screen unknown")
            return SimpleNamespace(deliver=deliver, set_ownership=lambda *args: None)

    bridge, sid = await fake_session()
    bridge.screens[sid] = "login expired"
    args = (Refused(bridge), "claude", sid)
    if scenario == "permission_paste":
        args += (tmp_path,)
    result = await getattr(check, scenario)(*args)
    assert not result.passed
    assert "Expected" in result.detail and "login expired" in result.detail
    assert "❯" in result.detail


async def test_not_idle_failure_is_kept_in_scenarios(tmp_path, monkeypatch):
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm

    class NotIdle(check.Live):
        async def ready(self, agent, sid, seconds=180):
            self.bridge.screens[sid] = "login expired"
            await self.screen(sid)
            return False

    async def startup(*args):
        return OK

    monkeypatch.setattr(check, "startup_paste", startup)
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    results = await check.check_agent(NotIdle(FakeIterm()), "claude", tmp_path)
    detail = results["idleSubmit"].detail
    assert not results["idleSubmit"].passed
    assert "❯" in detail and "tointerrupt" in detail and "no prompt" in detail
    assert "login expired" in detail


async def test_screen_diagnostic_is_bounded_and_keeps_last_read():
    from tools import delivery_check as check
    bridge, sid = await fake_session()
    bridge.screens[sid] = "discard me\n" + "\n".join(f"line {i}" for i in range(50)) + "\n \n"
    live = check.Live(bridge)
    assert not await live.wait_for(sid, check.shows("missing"), 0)
    bridge.screens[sid] = "a later screen"
    result = await live.failure(sid, "claude", "missing")
    assert "line 49" in result.detail and "line 10" in result.detail
    assert "discard me" not in result.detail and "line 9\n" not in result.detail
    assert "a later screen" not in result.detail
    assert not result.detail.endswith("\n")


@pytest.mark.parametrize("agent", ["claude", "codex"])
@pytest.mark.parametrize("kind", ["startup", "permission"])
async def test_paste_failure_keeps_prompt_markers_and_screen(agent, kind, tmp_path, monkeypatch):
    from types import SimpleNamespace
    from aitermd.models import HARNESS_BY_AGENT
    from tools import delivery_check as check

    class Prompt(check.Live):
        async def wait_for(self, sid, seen, seconds):
            return True

        def deliverer(self, agent, **kwargs):
            async def deliver(*args):
                return SimpleNamespace(result="delivered", reason=None)
            return SimpleNamespace(deliver=deliver)

    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    monkeypatch.setattr("builtins.input", lambda *args: "")
    bridge, sid = await fake_session()
    bridge.screens[sid] = "dialog vanished"
    live = Prompt(bridge)
    result = (await check.startup_paste(live, agent, sid) if kind == "startup"
              else await check.permission_paste(live, agent, sid, tmp_path))
    assert not result.passed
    assert "dialog vanished" in result.detail
    for marker in getattr(HARNESS_BY_AGENT[agent], kind + "_prompt"):
        assert marker in result.detail


@pytest.mark.parametrize("waiting,submitted,answered", [(False, False, True), (True, True, True), (True, False, False)])
async def test_takeover_keeps_screen_from_each_failed_stage(waiting, submitted, answered):
    from types import SimpleNamespace
    from tools import delivery_check as check

    class Takeover(check.Live):
        async def wait_for(self, sid, seen, seconds):
            outcome, screen = next(stages)
            self.bridge.screens[sid] = screen
            await self.screen(sid)
            return outcome

        def deliverer(self, agent, **kwargs):
            async def deliver(*args):
                return SimpleNamespace(result="partial", reason=None)
            return SimpleNamespace(deliver=deliver, set_ownership=lambda *args: None)

    bridge, sid = await fake_session()
    stages = iter([(waiting, "input stage"), (submitted, "before Enter stage"), (answered, "after Enter stage")])
    result = await check.takeover(Takeover(bridge), "claude", sid)
    assert not result.passed
    expected = "input stage" if not waiting else "before Enter stage" if submitted else "after Enter stage"
    assert expected in result.detail and "ECHO" in result.detail
    assert "open_prompt=None" in result.detail


async def test_keystroke_failure_names_echo_and_screen(monkeypatch):
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm

    class NoEcho(check.Live):
        async def wait_for(self, sid, seen, seconds):
            self.bridge.screens[sid] = "shell did not echo"
            return await super().wait_for(sid, seen, 0)

    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    monkeypatch.setattr("builtins.input", lambda *args: "")
    result = await check.keystrokes_pass_through(NoEcho(FakeIterm()))
    assert not result.passed
    assert "GOT:aiterm" in result.detail and "shell did not echo" in result.detail
    assert "shows_input_box=False" in result.detail


async def test_background_failure_reports_front_apps_and_screen():
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm

    class Screen(check.Live):
        async def screen(self, sid):
            self.bridge.screens[sid] = "background shell"
            return await super().screen(sid)

    apps = iter(["other", "iterm"])
    result = await check.background_window(Screen(FakeIterm()), front=lambda: next(apps), sleep=no_sleep,
                                           iterm_asn="iterm")
    assert not result.passed
    assert "front app before other, after iterm" in result.detail
    assert "background shell" in result.detail and "Expected" in result.detail


@pytest.mark.parametrize("queued", ["blocked", "delivered"])
async def test_busy_queue_failure_after_working_keeps_screen(queued):
    from types import SimpleNamespace
    from tools import delivery_check as check

    deliveries = iter(["delivered", queued])
    waits = iter([True, False])

    class Busy(check.Live):
        async def wait_for(self, sid, seen, seconds):
            self.bridge.screens[sid] = "working screen without reply"
            await self.screen(sid)
            return next(waits)

        def deliverer(self, agent, **kwargs):
            async def deliver(*args):
                return SimpleNamespace(result=next(deliveries), reason="test reason")
            return SimpleNamespace(deliver=deliver)

    bridge, sid = await fake_session()
    result = await check.busy_queue(Busy(bridge), "claude", sid)
    assert not result.passed
    assert ("tointerrupt" if queued == "blocked" else "CHARLIE 9") in result.detail
    assert "working screen without reply" in result.detail


async def test_screen_diagnostic_caps_long_lines():
    from tools import delivery_check as check
    bridge, sid = await fake_session()
    bridge.screens[sid] = "x" * 10000 + "last characters"
    result = await check.Live(bridge).failure(sid, "codex", "expected marker")
    assert result.detail.endswith("last characters")
    assert len(result.detail) < 8300
