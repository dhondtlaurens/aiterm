# daemon/tests/test_delivery_check.py
"""The delivery check's verdicts: what it writes for each run of scenarios, and that the daemon
reads it as meant. The scenarios themselves need real iTerm2 and logged-in CLIs, and are run by hand."""
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
    assert chosen_agents("codex, claude,grok") == ("claude", "codex")
    assert chosen_agents("pi") == ()


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
