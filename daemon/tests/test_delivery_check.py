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


def test_the_scratch_codex_settings_keep_only_what_its_screens_have_shown_you(tmp_path):
    # Hooks trusted by the real config's path would all ask for review again, servers would start and
    # fill the context, and a reviewer would answer the approvals the check pastes into.
    import tomllib
    real = tmp_path / "real"
    real.mkdir()
    (real / "auth.json").write_text("{}", encoding="utf-8")
    (real / "config.toml").write_text("""model = "gpt-6-astra"
approvals_reviewer = "auto_review"

[projects."/Users/me"]
trust_level = "trusted"

[tui]
theme = "dark"
screen_reader_detection_done = true

[tui.model_availability_nux]
"gpt-6.1-sol" = 1

[mcp_servers.cloudflare]
command = "npx"
args = [
  "-y",
  "cloudflare",
]

[hooks.state."/Users/me/.codex/config.toml:stop:0:0"]
trusted_hash = "abc"

[[hooks.SessionStart]]
command = "curl"
""", encoding="utf-8")
    home = scratch_codex_home(real, tmp_path / "scratch")
    assert tomllib.loads((home / "config.toml").read_text(encoding="utf-8")) == {
        "tui": {"theme": "dark", "screen_reader_detection_done": True, "model_availability_nux": {"gpt-6.1-sol": 1}}}


def test_an_allow_rule_a_paste_wrote_is_found(tmp_path):
    assert allow_rules("codex", tmp_path) == [] and allow_rules("claude", tmp_path) == []
    (tmp_path / "codex-home" / "rules").mkdir(parents=True)
    (tmp_path / "codex-home" / "rules" / "default.rules").write_text("allow", encoding="utf-8")
    (tmp_path / "work" / ".claude").mkdir(parents=True)
    (tmp_path / "work" / ".claude" / "settings.local.json").write_text("{}", encoding="utf-8")
    assert allow_rules("codex", tmp_path) == [str(tmp_path / "codex-home" / "rules" / "default.rules")]
    assert allow_rules("claude", tmp_path) == [str(tmp_path / "work" / ".claude" / "settings.local.json")]


@pytest.mark.parametrize("agent", ["claude", "codex"])
@pytest.mark.parametrize("missing", ["menuPaste", "updatePaste", "approvalRace"])
@pytest.mark.parametrize("failed", [False, True])
def test_required_prompt_checks_must_run_and_pass(tmp_path, agent, missing, failed):
    results = every(PASTE_SAFE + SUBMIT_SAFE + ("menuPaste", "updatePaste", "approvalRace"), OK)
    results.pop(missing)
    if failed:
        results[missing] = FAILED
    entry = agent_entry("2.1.301", results, NOW)
    assert not entry["pasteSafe"]
    assert read_back(tmp_path, {agent: entry})[agent].policy == "off"


@pytest.mark.parametrize("value", ["claude-code", "claude codex", "", " ", "claude,", "claude,gemini"])
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
    ("busy_queue", "CHARLIE 9"),
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
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
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
async def test_busy_queue_failure_after_working_keeps_screen(queued, monkeypatch):
    from types import SimpleNamespace
    from tools import delivery_check as check

    deliveries = iter(["delivered", queued])

    class Busy(check.Live):
        async def wait_for(self, sid, seen, seconds):
            await self.screen(sid)
            return False

        def deliverer(self, agent, **kwargs):
            async def deliver(*args):
                return SimpleNamespace(result=next(deliveries), reason="test reason")
            return SimpleNamespace(deliver=deliver)

    bridge, sid = await fake_session()
    bridge.screens[sid] = "working screen without reply"
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    result = await check.busy_queue(Busy(bridge), "claude", sid)
    assert not result.passed
    assert ("queued delivery" if queued == "blocked" else "CHARLIE 9") in result.detail
    assert "working screen without reply" in result.detail


async def test_busy_queue_types_the_second_message_only_while_the_story_is_unfinished(monkeypatch):
    from types import SimpleNamespace
    from tools import delivery_check as check
    sent = []

    class Done(check.Live):
        def deliverer(self, agent, **kwargs):
            async def deliver(sid, text, *args):
                sent.append(text)
                return SimpleNamespace(result="delivered", reason="")
            return SimpleNamespace(deliver=deliver)

    bridge, sid = await fake_session()
    # The story typed out in full before the second message: the agent was not busy when it would go.
    bridge.screens[sid] = "Once upon a time.\n\nFIN 7"
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    result = await check.busy_queue(Done(bridge), "claude", sid)
    assert not result.passed and "FIN 7" in result.detail
    assert len(sent) == 1


async def test_busy_queue_passes_once_the_message_typed_while_busy_is_answered(monkeypatch):
    from types import SimpleNamespace
    from tools import delivery_check as check

    class Busy(check.Live):
        def deliverer(self, agent, **kwargs):
            async def deliver(sid, text, *args):
                # Codex steers a message typed mid-turn into that turn, and may answer only it.
                if text.startswith("When you are done"):
                    self.bridge.screens[sid] = "Write a story\n\nWhen you are done\n\nCHARLIE9"
                return SimpleNamespace(result="delivered", reason="")
            return SimpleNamespace(deliver=deliver)

    bridge, sid = await fake_session()
    bridge.screens[sid] = "Once upon a"
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    assert (await check.busy_queue(Busy(bridge), "claude", sid)).passed


async def test_screen_diagnostic_caps_long_lines():
    from tools import delivery_check as check
    bridge, sid = await fake_session()
    bridge.screens[sid] = "x" * 10000 + "last characters"
    result = await check.Live(bridge).failure(sid, "codex", "expected marker")
    assert result.detail.endswith("last characters")
    assert len(result.detail) < 8300


@pytest.mark.parametrize("agent", ["claude", "codex"])
async def test_check_agent_runs_all_required_scenarios(agent, tmp_path, monkeypatch):
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm

    class Ready(check.Live):
        async def ready(self, *args, **kwargs):
            return True

        async def wait_for(self, *args, **kwargs):
            return True

    called = []
    for name in ("startup_paste", "update_paste", "menu_paste", "approval_race", "permission_paste",
                 "idle_submit", "multi_line", "busy_queue", "takeover"):
        async def scenario(*args, name=name):
            called.append(name)
            return OK
        monkeypatch.setattr(check, name, scenario, raising=False)
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    results = await check.check_agent(Ready(FakeIterm()), agent, tmp_path)
    assert set(results) == set(PASTE_SAFE + SUBMIT_SAFE)
    assert len(called) == len(results)
    entry = agent_entry("1.2.3", results, NOW)
    assert entry["pasteSafe"] and entry["submitSafe"]


@pytest.mark.parametrize("agent", ["claude", "codex"])
@pytest.mark.parametrize("failure", [None, "missing", "closed", "changed", "rules"])
async def test_menu_paste_checks_screen_and_rules(agent, failure, tmp_path, monkeypatch):
    from aitermd.delivery import ESC, PASTE_START, PASTE_END
    from aitermd.models import HARNESS_BY_AGENT
    from tools import delivery_check as check

    menu = "Model picker\n" + "\n".join(HARNESS_BY_AGENT[agent].menu_prompt)
    bridge, sid = await fake_session()

    class Menu(check.Live):
        async def wait_for(self, sid, seen, seconds):
            bridge.screens[sid] = "missing menu" if failure == "missing" else menu
            return await super().wait_for(sid, seen, 0)

        async def paste(self, sid, text):
            await super().paste(sid, text)
            if text == check.HAZARD:
                bridge.screens[sid] = "closed menu" if failure == "closed" else menu + (" changed" if failure == "changed" else "")
                if failure == "rules":
                    write_allow_rule(agent, tmp_path)

    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    result = await check.menu_paste(Menu(bridge), agent, sid, tmp_path)
    assert result.passed == (failure is None)
    sent = [text for _, text in bridge.sent]
    assert PASTE_START + "/model" + PASTE_END in sent
    assert sent[-1] == ESC
    assert (PASTE_START + check.HAZARD + PASTE_END in sent) == (failure != "missing")
    if failure:
        assert "Expected" in result.detail and "Last screen" in result.detail


def write_allow_rule(agent, folder):
    path = (folder / "work" / ".claude" / "settings.local.json" if agent == "claude"
            else folder / "codex-home" / "rules" / "default.rules")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("allow")


async def test_update_paste_without_markers_is_not_applicable(tmp_path, monkeypatch):
    from aitermd.models import HARNESS_BY_AGENT
    from tests.fake_iterm import FakeIterm
    from tools import delivery_check as check

    assert not HARNESS_BY_AGENT["claude"].update_prompt
    bridge = FakeIterm()
    live = check.Live(bridge)
    monkeypatch.setattr(live, "wait_for", lambda *args: pytest.fail("must not wait"))
    monkeypatch.setattr(check.asyncio, "sleep", lambda *args: pytest.fail("must not sleep"))
    result = await check.update_paste(live, "claude", "unused", tmp_path)
    assert result == ScenarioResult(
        True, "not applicable: this CLI has no update dialog marker (update_prompt is empty), "
        "so there is no update dialog to paste into")
    assert not bridge.screen_reads and not bridge.sent
    assert not bridge.windows and not bridge.sessions
    results = every(PASTE_SAFE + SUBMIT_SAFE, OK) | {"updatePaste": result}
    entry = agent_entry("2.1.301", results, NOW)
    assert entry["pasteSafe"]
    assert read_back(tmp_path, {"claude": entry})["claude"].policy == "auto"
    results.pop("updatePaste")
    assert not agent_entry("2.1.301", results, NOW)["pasteSafe"]


@pytest.mark.parametrize("failure", [None, "missing", "unrecognised", "closed", "rules", "dismiss"])
async def test_update_paste_checks_offer_and_declines(failure, tmp_path, monkeypatch):
    from dataclasses import replace
    from aitermd.delivery import ESC, PASTE_START, PASTE_END
    from tools import delivery_check as check

    agent = "codex"
    offer = "Update now\nSkip until next version"
    bridge, sid = await fake_session()
    bridge.sessions[sid] = replace(bridge.sessions[sid], command_line=agent)
    bridge.screens[sid] = {"missing": "› idle", "unrecognised": "a crashed shell"}.get(failure, offer)

    class Update(check.Live):
        async def wait_for(self, sid, seen, seconds):
            return await super().wait_for(sid, seen, 0)

        async def paste(self, sid, text):
            await super().paste(sid, text)
            if failure == "closed":
                bridge.screens[sid] = "offer disappeared"
            if failure == "rules":
                write_allow_rule(agent, tmp_path)

        def deliverer(self, agent, **kwargs):
            adapter = super().deliverer(agent, **kwargs)
            if failure == "dismiss":
                async def dismiss(sid):
                    return False
                adapter.dismiss_startup = dismiss
            return adapter

    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    result = await check.update_paste(Update(bridge), agent, sid, tmp_path)
    # No update offered, its idle screen instead: nothing to paste into, and nothing pasted.
    assert result.passed == (failure in (None, "missing"))
    sent = [text for _, text in bridge.sent]
    assert (PASTE_START + check.HAZARD + PASTE_END in sent) == (failure not in ("missing", "unrecognised"))
    if failure is None:
        assert sent[-1] == ESC
    if failure == "missing":
        assert result.detail.startswith("not shown")
    elif failure:
        assert "Expected" in result.detail and "Last screen" in result.detail
    if failure == "unrecognised":
        assert "no update dialog showed" in result.detail


@pytest.mark.parametrize("agent", ["claude", "codex"])
@pytest.mark.parametrize("failure", [
    None, "request", "setup_partial", "early", "missing", "closed", "command", "rules", "enter", "enter_error"])
async def test_approval_race_uses_adapter_and_requires_paste_in_approval(agent, failure, tmp_path, monkeypatch):
    from dataclasses import replace
    from aitermd.delivery import ESC, PASTE_START, PASTE_END
    from aitermd.models import HARNESS_BY_AGENT
    from tools import delivery_check as check

    bridge, sid = await fake_session()
    bridge.sessions[sid] = replace(bridge.sessions[sid], command_line=agent)
    prompt = HARNESS_BY_AGENT[agent].permission_prompt[0]
    box = HARNESS_BY_AGENT[agent].input_box[0]
    bridge.screens[sid] = "unknown" if failure == "request" else box
    pasted_in = []
    adapters = []
    original_send = bridge.send_text

    async def send(session_id, text):
        from aitermd.iterm_bridge import ItermUnavailable
        await original_send(session_id, text)
        if failure == "enter_error" and text == "\r" and len(adapters) == 2:
            bridge.screens[sid] = prompt
            raise ItermUnavailable("Enter transport failed")

    bridge.send_text = send

    class Race(check.Live):
        async def wait_for(self, sid, seen, seconds):
            bridge.screens[sid] = box if failure == "missing" else prompt
            return await super().wait_for(sid, seen, 0)

        async def paste(self, sid, text):
            pasted_in.append(await self.screen(sid))
            await super().paste(sid, text)
            if failure == "closed":
                bridge.screens[sid] = "unknown"
            if failure in ("enter", "enter_error"):
                bridge.screens[sid] = box
            if failure == "command":
                list(tmp_path.rglob("outside" if agent == "codex" else "work"))[0].joinpath("race-approved.txt").touch()
            if failure == "rules":
                write_allow_rule(agent, tmp_path)

        def deliverer(self, agent, **kwargs):
            if failure == "early" and adapters:
                bridge.screens[sid] = prompt

            async def settle(seconds):
                if failure == "setup_partial":
                    bridge.screens[sid] = prompt
            adapter = super().deliverer(agent, sleep=settle)
            adapters.append(adapter)
            return adapter

    live = Race(bridge)
    live.versions[agent] = "1.2.3"
    live.registry.apply_snapshot(await bridge.snapshot())
    live.registry.set_cli_version(sid, "1.2.3")
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    result = await check.approval_race(live, agent, sid, tmp_path)
    assert result.passed == (failure is None)
    sent = [text for _, text in bridge.sent]
    assert sent[-1] == ESC
    if failure is None:
        assert pasted_in == [prompt]
        assert sent.count("\r") == 1, "only the setup request may be submitted"
        assert PASTE_START + check.HAZARD + PASTE_END in sent
    if failure:
        assert "Expected" in result.detail and "Last screen" in result.detail
    if failure == "missing":
        assert "No approval prompt opened" in result.detail
    if failure == "early":
        assert not pasted_in
        assert "refused" in result.detail


@pytest.mark.parametrize("update_first", [False, True])
async def test_startup_checks_update_on_either_side_of_trust(update_first, tmp_path, monkeypatch):
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm

    calls = []

    class Startup(check.Live):
        async def wait_for(self, sid, seen, seconds):
            self.bridge.screens[sid] = ("Update now\nSkip until next version" if update_first else "Trust this folder?")
            return await super().wait_for(sid, seen, 0)

        async def ready(self, *args, **kwargs):
            return False

    async def trust(*args):
        calls.append("trust")
        return OK

    async def update(*args):
        calls.append("update")
        return OK

    async def answered(*args):
        return True

    monkeypatch.setattr(check, "startup_paste", trust)
    monkeypatch.setattr(check, "answer_trust", answered)
    monkeypatch.setattr(check, "update_paste", update, raising=False)
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    await check.check_agent(Startup(FakeIterm()), "codex", tmp_path)
    assert calls == (["update", "trust"] if update_first else ["trust", "update"])


@pytest.mark.parametrize("changed_to_update", [False, True])
async def test_startup_paste_waits_past_stale_update_frame(changed_to_update, monkeypatch):
    from tools import delivery_check as check

    bridge, sid = await fake_session()
    frames = iter(["Update now\nSkip until next version", "Trust this folder?"])
    pasted_on = []

    class Startup(check.Live):
        async def wait_for(self, sid, seen, seconds):
            for frame in frames:
                bridge.screens[sid] = frame
                if await super().wait_for(sid, seen, 0):
                    return True
            return False

        async def paste(self, sid, text):
            pasted_on.append(await self.screen(sid))
            await super().paste(sid, text)
            if changed_to_update:
                bridge.screens[sid] = "Update now\nSkip until next version"

    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    result = await check.startup_paste(Startup(bridge), "codex", sid)
    assert result.passed == (not changed_to_update)
    assert pasted_on == ["Trust this folder?"]


# The trust dialogs as each CLI draws them, the selection on the option its arrow marks.
CLAUDE_TRUST = {"No": " ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel",
                "Yes": "   No, exit\n ❯ Yes, I trust this folder\n Enter to confirm · Esc to cancel"}
CODEX_TRUST = "  Trust this folder?\n› 1. Yes, allow Codex to work in this folder\n  2. No, ask me to approve edits and commands"
IDLE = {"claude": "────────────────\n❯\x20\n────────────────", "codex": "›\x20Ask Codex to do anything"}


async def keyed_session(screens):
    """A session whose screen answers each key as `screens` says: (screen, key) -> the next screen."""
    from tests.fake_iterm import FakeIterm

    class Keyed(FakeIterm):
        async def send_text(self, session_id, text):
            await super().send_text(session_id, text)
            self.screens[session_id] = screens.get((self.screens[session_id], text), self.screens[session_id])

    bridge, sid = await fake_session()
    bridge.__class__ = Keyed
    return bridge, sid


@pytest.mark.parametrize("agent,start,keys", [
    # Claude's dialog opens on "No, exit": one Down reaches the trust, then Enter.
    ("claude", CLAUDE_TRUST["No"], ["\x1b[B", "\r"]),
    ("codex", CODEX_TRUST, ["\r"]),
])
async def test_the_check_trusts_its_own_scratch_folder(agent, start, keys, monkeypatch):
    from tools import delivery_check as check
    bridge, sid = await keyed_session({(CLAUDE_TRUST["No"], "\x1b[B"): CLAUDE_TRUST["Yes"],
                                       (CLAUDE_TRUST["Yes"], "\r"): IDLE["claude"], (CODEX_TRUST, "\r"): IDLE["codex"]})
    bridge.screens[sid] = start
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    assert await check.answer_trust(check.Live(bridge), agent, sid)
    assert [text for _, text in bridge.sent] == keys


async def test_the_check_never_enters_on_an_option_it_did_not_select(monkeypatch):
    from tools import delivery_check as check
    # Down moves nothing: the selection never reaches the trust, so no Enter answers "No, exit".
    bridge, sid = await keyed_session({})
    bridge.screens[sid] = CLAUDE_TRUST["No"]
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    assert not await check.answer_trust(check.Live(bridge), "claude", sid)
    assert "\r" not in [text for _, text in bridge.sent]


async def test_a_folder_already_trusted_needs_no_answer(monkeypatch):
    from tools import delivery_check as check
    bridge, sid = await keyed_session({})
    bridge.screens[sid] = IDLE["claude"]
    assert await check.answer_trust(check.Live(bridge), "claude", sid)
    assert bridge.sent == []


async def test_an_unanswered_trust_ends_the_agents_check_at_once(tmp_path, monkeypatch):
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm
    ran = []

    class Stuck(check.Live):
        async def ready(self, *args, **kwargs):
            ran.append("ready")
            return True

    async def unanswered(*args):
        return False

    monkeypatch.setattr(check, "startup_paste", lambda *args: _ok())
    monkeypatch.setattr(check, "answer_trust", unanswered)
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    results = await check.check_agent(Stuck(FakeIterm()), "claude", tmp_path)
    assert ran == []
    assert set(results) == set(PASTE_SAFE + SUBMIT_SAFE)
    assert not results["startupPaste"].passed and "trust" in results["startupPaste"].detail
    assert results["idleSubmit"].detail == "not run: the check stopped at startupPaste"


async def _ok():
    return OK


def test_each_cli_runs_on_its_cheapest_model():
    from tools.delivery_check import COMMANDS
    assert "--model haiku --effort low" in COMMANDS["claude"]
    assert "-m gpt-6-luna -c model_reasoning_effort=low" in COMMANDS["codex"]


def test_the_window_says_a_failure_briefly_and_the_file_keeps_it_whole(capsys):
    from tools import delivery_check as check
    screen = "\n".join(f"line {n}" for n in range(40))
    detail = ("Expected answer marker 'ALPHA 42'. \nopen_prompt=None, shows_input_box=True\n"
              f"Last screen (up to 40 lines, 8000 characters):\n{screen}")
    check.report("claude", "idleSubmit", ScenarioResult(False, detail))
    check.report("claude", "multiLine", ScenarioResult(True, "all three lines arrived as one message"))
    printed = capsys.readouterr().out
    assert "Expected answer marker 'ALPHA 42'" in printed and "line 39" in printed
    assert "line 27" not in printed, "the last twelve lines of the screen, not forty"
    assert "claude multiLine: pass\n" in printed, "a pass in one short line"


@pytest.mark.parametrize("agent,idle_screen", [("codex", "› Ask Codex to do anything"), ("claude", "────\n❯\x20\n────")])
async def test_a_cli_that_opens_on_its_idle_screen_has_no_trust_dialog_to_paste_into(agent, idle_screen, monkeypatch):
    from tools import delivery_check as check
    bridge, sid = await fake_session()
    bridge.screens[sid] = idle_screen
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    result = await check.startup_paste(check.Live(bridge), agent, sid)
    assert result.passed and result.detail.startswith("not shown")
    assert bridge.sent == []


async def test_a_trust_dialog_after_the_idle_screen_is_still_pasted_into(monkeypatch):
    from tools import delivery_check as check
    bridge, sid = await fake_session()
    bridge.screens[sid] = "› Ask Codex to do anything"

    async def dialog_opens(seconds):
        bridge.screens[sid] = CODEX_TRUST

    monkeypatch.setattr(check.asyncio, "sleep", dialog_opens)
    result = await check.startup_paste(check.Live(bridge), "codex", sid)
    assert result.passed and not result.detail.startswith("not shown")
    assert any(check.HAZARD in text for _, text in bridge.sent)


def _scenarios_that(monkeypatch, check, called, outcome):
    for name in ("startup_paste", "update_paste", "menu_paste", "approval_race", "permission_paste",
                 "idle_submit", "multi_line", "busy_queue", "takeover"):
        async def scenario(*args, name=name):
            called.append(name)
            return outcome(name)
        monkeypatch.setattr(check, name, scenario, raising=False)

    async def answered(*args):
        return True
    monkeypatch.setattr(check, "answer_trust", answered)
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)


async def test_the_first_failure_ends_the_agents_check(tmp_path, monkeypatch):
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm

    class Ready(check.Live):
        async def ready(self, *args, **kwargs):
            return True

    called: list[str] = []
    _scenarios_that(monkeypatch, check, called, lambda name: FAILED if name == "multi_line" else OK)
    results = await check.check_agent(Ready(FakeIterm()), "claude", tmp_path)
    assert called == ["startup_paste", "update_paste", "idle_submit", "multi_line"]
    assert results["multiLine"] == FAILED
    assert results["busyQueue"].detail == "not run: the check stopped at multiLine"
    entry = agent_entry("1.2.3", results, NOW)
    assert entry["failedAt"] == "multiLine" and entry["failure"] == FAILED.detail


async def test_an_error_mid_check_is_that_steps_failure(tmp_path, monkeypatch):
    from tools import delivery_check as check
    from tests.fake_iterm import FakeIterm
    from aitermd.iterm_bridge import ItermUnavailable

    class Ready(check.Live):
        async def ready(self, *args, **kwargs):
            return True

        async def wait_for(self, *args, **kwargs):
            return True

    def outcome(name):
        if name == "busy_queue":
            raise ItermUnavailable("iTerm2 quit")
        return OK

    called: list[str] = []
    _scenarios_that(monkeypatch, check, called, outcome)
    bridge = FakeIterm()
    results = await check.check_agent(Ready(bridge), "codex", tmp_path)
    assert "iTerm2 quit" in results["busyQueue"].detail and not results["busyQueue"].passed
    assert results["takeover"].detail == "not run: the check stopped at busyQueue"
    assert bridge.windows == {} or all(not w["sessions"] for w in bridge.windows.values()), "its window closed"


def test_a_passing_entry_names_no_failure():
    entry = agent_entry("1.2.3", every(PASTE_SAFE + SUBMIT_SAFE, OK), NOW)
    assert "failedAt" not in entry and "failure" not in entry


def test_the_entrys_failure_is_the_windows_brief_one():
    screen = "\n".join(f"line {n}" for n in range(40))
    failed = ScenarioResult(False, f"Expected X. \nopen_prompt=None\nLast screen (up to 40 lines, 8000 characters):\n{screen}")
    entry = agent_entry("1.2.3", {**every(PASTE_SAFE + SUBMIT_SAFE, OK), "takeover": failed}, NOW)
    assert entry["failedAt"] == "takeover"
    assert entry["failure"].startswith("Expected X.") and "line 39" in entry["failure"] and "line 27" not in entry["failure"]
    assert entry["scenarios"]["takeover"]["detail"] == failed.detail, "the whole screen kept beside it"


# approvalRace waits inside its own transport, which a stubbed delivery never reaches.
@pytest.mark.parametrize("scenario", ["idle_submit", "multi_line", "busy_queue", "takeover", "menu_paste",
                                      "permission_paste", "startup_paste", "update_paste"])
async def test_no_step_waits_longer_than_its_limit(scenario, tmp_path, monkeypatch):
    from dataclasses import replace
    from types import SimpleNamespace
    from tools import delivery_check as check
    waits: list[float] = []

    class Timed(check.Live):
        async def wait_for(self, sid, seen, seconds):
            waits.append(seconds)
            return False

        def deliverer(self, agent, **kwargs):
            async def deliver(*args):
                return SimpleNamespace(result="partial" if scenario == "takeover" else "delivered", reason="")
            return SimpleNamespace(deliver=deliver, set_ownership=lambda *a: None)

    bridge, sid = await fake_session()
    bridge.sessions[sid] = replace(bridge.sessions[sid], command_line="codex")
    monkeypatch.setattr(check.asyncio, "sleep", no_sleep)
    folder = (tmp_path,) if scenario in ("menu_paste", "permission_paste", "approval_race", "update_paste") else ()
    await getattr(check, scenario)(Timed(bridge), "codex", sid, *folder)
    assert waits and max(waits) <= check.START_SECONDS
    starting = scenario in ("startup_paste", "update_paste")
    assert max(waits) <= (check.START_SECONDS if starting or scenario == "busy_queue" else check.STEP_SECONDS)


def test_the_limits_are_fifteen_seconds_a_step_and_thirty_to_start():
    from tools import delivery_check as check
    assert (check.STEP_SECONDS, check.START_SECONDS) == (15, 30)


def test_codex_is_asked_to_escalate_so_it_must_ask_for_approval(tmp_path):
    from tools import delivery_check as check
    assert "require_escalated" in check.permission_request("codex", tmp_path / "x")
    assert "require_escalated" not in check.permission_request("claude", tmp_path / "x")


async def test_no_iterm2_is_written_as_each_agents_failure(tmp_path, monkeypatch):
    from tools import delivery_check as check
    from aitermd.iterm_bridge import ItermUnavailable

    class Unreachable:
        async def connect(self):
            raise ItermUnavailable("iTerm2 is not running")

        async def close(self):
            pass

    monkeypatch.setattr(check, "ItermBridge", Unreachable)
    monkeypatch.setattr(check, "cli_version", lambda agent: "0.163.0")
    policy = tmp_path / "delivery-policy.json"
    assert await check.run(("codex",), True, True, policy) == 0
    entry = json.loads(policy.read_text(encoding="utf-8"))["codex"]
    assert entry["failedAt"] == "startupPaste" and "iTerm2 is not running" in entry["failure"]
    assert not entry["pasteSafe"] and entry["version"] == "0.163.0"
