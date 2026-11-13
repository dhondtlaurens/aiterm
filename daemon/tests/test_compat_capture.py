"""The compatibility capture's pure parts (tools/compat_capture.py): what it fills in, what it scrubs
and refuses to write, and the verified list it keeps. The capture itself runs only by hand."""
import base64
import json
from pathlib import Path

import pytest

from tools.compat_capture import (Leak, account_values, chosen_agents, claude_settings, codex_config, delivery_problems, fill, leaks,
                                  merged_verified, pi_settings, private_terms, scrub, secrets, version_line, without_account, write_capture)

HOME = Path("/Users/someone")
SCRATCH = HOME / "Library" / "Caches" / "aiterm-compat-claude-x1"


def _jwt(claims: dict) -> str:
    body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return f"head.{body}.sig"


CLAUDE_STATE = {"oauthAccount": {"emailAddress": "someone@example.org", "displayName": "Some", "fullName": "Some One",
                                 "organizationName": "Some Org", "accountUuid": "acc-1111-2222",
                                 "organizationUuid": "org-3333-4444", "billingType": "max"}}
CODEX_AUTH = {"OPENAI_API_KEY": None, "tokens": {"account_id": "codex-acct-5555", "access_token": "access-secret-token",
              "refresh_token": "refresh-secret-token",
              "id_token": _jwt({"email": "other@example.net", "name": "Other Person", "sub": "auth0|sub-6666",
                                "https://api.openai.com/auth": {"chatgpt_account_id": "chat-7777", "chatgpt_plan_type": "plus",
                                                                "organizations": [{"id": "org-8888", "title": "Team Name",
                                                                                   "role": "owner"},
                                                                                  {"id": "org-8889", "title": "Personal"}]}})}}
PI_AUTH = {"openai-codex": {"type": "oauth", "access": "pi-access-token", "refresh": "pi-refresh-token", "accountId": "pi-acct-9999"}}


def listed():
    return secrets(HOME, "someone", SCRATCH, account_values(CLAUDE_STATE, CODEX_AUTH, PI_AUTH))


def test_fill_replaces_each_named_value_and_keeps_every_word():
    assert fill(["claude", "--model", "{model}", "--effort", "{reasoning}", "{unknown}"], {"model": "haiku", "reasoning": "low"}) \
        == ["claude", "--model", "haiku", "--effort", "low", "{unknown}"]
    assert fill(["-c", "model_reasoning_effort={reasoning}"], {"reasoning": "low"}) == ["-c", "model_reasoning_effort=low"]


def test_a_version_line_is_its_major_and_minor_as_the_app_covers_it():
    assert version_line("2.1.323") == "2.1"
    assert version_line("0.167.0") == "0.167"
    assert version_line("1.4") is None
    assert version_line(None) is None


def test_the_verified_list_replaces_what_was_checked_and_keeps_the_rest():
    existing = {"codex": {"verified": "0.160", "version": "0.160.0", "checkedAt": "2026-10-01"},
                "pi": {"verified": "1.3", "version": "1.3.2", "checkedAt": "2026-10-01"}}
    merged = merged_verified(existing, {"codex": "0.167.0", "claude": "2.1.323"}, "2026-11-13")
    assert merged == {"claude": {"verified": "2.1", "version": "2.1.323", "checkedAt": "2026-11-13"},
                      "codex": {"verified": "0.167", "version": "0.167.0", "checkedAt": "2026-11-13"},
                      "pi": existing["pi"]}
    assert list(merged) == ["claude", "codex", "pi"]
    assert merged_verified("not a list", {"pi": "x"}, "d") == {}


def test_every_account_detail_the_clis_keep_is_private():
    values = {value for _, value in account_values(CLAUDE_STATE, CODEX_AUTH, PI_AUTH)}
    assert {"someone@example.org", "Some One", "Some Org", "acc-1111-2222", "org-3333-4444", "codex-acct-5555",
            "access-secret-token", "refresh-secret-token", "other@example.net", "Other Person", "auth0|sub-6666",
            "chat-7777", "org-8888", "Team Name", "pi-access-token", "pi-refresh-token", "pi-acct-9999"} <= values
    # The plan and role are ordinary words: scrubbing them would refuse every transcript.
    assert not {"max", "plus", "owner", "Personal"} & values
    assert "org-8889" in values
    assert account_values(None, "garbage", []) == []


def test_scrubbing_takes_the_scratch_folder_before_the_home_and_leaves_nothing_private():
    text = (f'{{"cwd": "{SCRATCH}/work", "transcript_path": "{HOME}/x", "user": "someone", '
            '"org": "org-3333-4444", "who": "someone@example.org", "author": "a@b.io"}')
    clean = scrub(text, listed())
    assert '"/SCRATCH/work"' in clean and '"/HOME/x"' in clean
    # Scrubbed, the home path still says where it was, and so is refused (the next test).
    assert leaks(clean, listed()) == ["a path in the home folder"]
    for private in ("someone", "org-3333-4444", "example.org", "a@b.io"):
        assert private not in clean


def test_claudes_dashed_project_folder_is_scrubbed_like_its_path():
    folder = "projects/" + str(SCRATCH).replace("/", "-").replace(".", "-") + "-work/x.jsonl"
    assert scrub(folder, listed()) == "projects/-SCRATCH-work/x.jsonl"
    assert scrub("-Users-someone-elsewhere", listed()) == "-HOME-elsewhere"


def test_a_path_in_the_home_folder_is_never_written(tmp_path):
    # Claude reads ~/.claude/CLAUDE.md from any folder under the home: the person's instructions.
    text = '{"type": "Project", "path": "/Users/someone/.claude/CLAUDE.md", "content": "# Working with me"}'
    assert "a path in the home folder" in leaks(scrub(text, listed()), listed())
    assert "a path in the home folder" in leaks(scrub("projects/-Users-someone-x/a.jsonl", listed()), listed())
    assert leaks("/opt/homebrew/bin and HOMEBREW and /SCRATCH/home", listed()) == []
    with pytest.raises(Leak):
        write_capture({"posts.jsonl": text}, tmp_path / "claude", listed())


def test_the_folder_codex_must_ask_for_has_a_placeholder_of_its_own():
    outside = HOME / "Library" / "Caches" / "aiterm-compat-outside-x"
    found = secrets(HOME, "someone", SCRATCH, [], outside)
    clean = scrub(f"touch {outside}/approved.txt", found)
    assert clean == "touch /OUTSIDE/approved.txt"
    assert leaks(clean, found) == []


def test_short_values_are_not_scrubbed_from_ordinary_text():
    found = secrets(HOME, "abc", SCRATCH, [("claude displayName", "Al")])
    assert "Al" not in {secret.value for secret in found}
    assert scrub("Also abc", found) == "Also abc"


def test_a_capture_is_written_scrubbed_in_place_of_the_last(tmp_path):
    into = tmp_path / "claude"
    (into / "old").mkdir(parents=True)
    (into / "old" / "gone.txt").write_text("old")
    name = "model-catalog/org-3333-4444-cc.json"
    write_capture({"posts.jsonl": f'{{"cwd": "{SCRATCH}"}}\n', name: "{}"}, into, listed())
    assert (into / "posts.jsonl").read_text() == '{"cwd": "/SCRATCH"}\n'
    assert (into / scrub(name, listed())).read_text() == "{}"
    assert sorted(str(path.relative_to(into)) for path in into.rglob("*") if path.is_file()) == \
        sorted(["posts.jsonl", scrub(name, listed())])


def test_a_capture_still_holding_a_private_value_in_another_case_is_not_written(tmp_path):
    into = tmp_path / "codex"
    into.mkdir()
    (into / "posts.jsonl").write_text("last\n")
    with pytest.raises(Leak) as refusal:
        write_capture({"posts.jsonl": '{"cwd": "/Users/SOMEONE/elsewhere"}\n'}, into, listed())
    assert "posts.jsonl: user name" in str(refusal.value)
    assert "SOMEONE" not in str(refusal.value)
    assert (into / "posts.jsonl").read_text() == "last\n"
    assert not (tmp_path / ".codex.new").exists()


def test_the_claude_settings_point_at_the_listener_and_run_the_shim_on_a_scratch_home():
    template = json.dumps({"hooks": {"Stop": [{"matcher": "", "hooks": [{"url": "http://127.0.0.1:__AITERM_HOOK_PORT__/hook/claude"}]}]},
                           "statusLine": {"type": "command", "command": "__AITERM_SHIM__", "padding": 0}})
    settings = json.loads(claude_settings(template, 50123, Path("/tmp/x home"), Path("/r/shim.sh"), {"theme": "dark"}))
    assert settings["hooks"]["Stop"][0]["hooks"][0]["url"] == "http://127.0.0.1:50123/hook/claude"
    assert settings["statusLine"] == {"type": "command", "command": "env HOME='/tmp/x home' /r/shim.sh", "padding": 0}
    assert settings["theme"] == "dark"


def test_the_codex_config_is_the_screen_settings_then_the_hook_block():
    real = '[tui]\ntheme = "dark"\n\n[mcp_servers.other]\nurl = "x"\n'
    config = codex_config('url = "http://127.0.0.1:__AITERM_HOOK_PORT__/mcp"\n', 50123, real)
    assert config.startswith('[tui]\ntheme = "dark"\n')
    assert "other" not in config
    assert config.endswith('url = "http://127.0.0.1:50123/mcp"\n')


def test_pi_keeps_only_its_default_provider_and_model():
    assert json.loads(pi_settings({"defaultProvider": "p", "defaultModel": "m", "packages": ["npm:x"]})) == \
        {"defaultProvider": "p", "defaultModel": "m"}
    assert json.loads(pi_settings(None)) == {}


def test_agents_are_named_from_the_three_in_their_own_order():
    assert chosen_agents("pi,claude") == ("claude", "pi")
    with pytest.raises(ValueError):
        chosen_agents("claude,grok")


# -- the delivery check's verdict, read back after its run (compat-check.sh) --
SINCE = "2026-11-13T10:00:00Z"


def _entry(version: str, at: str = "2026-11-13T10:05:00Z", **flags) -> dict:
    return {"version": version, "checkedAt": at, "pasteSafe": True, "submitSafe": True, **flags}


def test_a_fresh_pass_for_each_messaged_version_captured_is_a_pass():
    policy = {"claude": _entry("2.1.323"), "codex": _entry("0.167.0"), "iterm": {"version": "3.7"}}
    assert delivery_problems(policy, {"claude": "2.1.323", "codex": "0.167.0", "pi": "1.4.0"}, SINCE) == []
    # PI is never messaged: a capture of it alone needs no verdict.
    assert delivery_problems({}, {"pi": "1.4.0"}, SINCE) == []


def test_a_missing_old_other_version_or_failed_verdict_is_not_a_pass():
    versions = {"claude": "2.1.323", "codex": "0.167.0"}
    assert delivery_problems({}, versions, SINCE) == ["claude: the delivery check wrote no verdict",
                                                      "codex: the delivery check wrote no verdict"]
    old = {"claude": _entry("2.1.323", at="2026-11-12T09:00:00Z"), "codex": _entry("0.166.0")}
    assert delivery_problems(old, versions, SINCE) == ["claude: the delivery check wrote no verdict during this run",
                                                       "codex: the delivery check ran 0.166.0, not the 0.167.0 captured"]
    failed = {"claude": _entry("2.1.323", pasteSafe=False, failedAt="menuPaste"), "codex": _entry("0.167.0", submitSafe=False)}
    assert delivery_problems(failed, versions, SINCE) == ["claude: messaging failed at menuPaste", "codex: messaging failed"]
    assert delivery_problems("garbage", {"claude": "2.1.323"}, SINCE) == ["claude: the delivery check wrote no verdict"]


def test_a_claude_transcript_keeps_the_conversation_and_drops_the_accounts_environment():
    lines = [{"type": "user", "message": {"content": "hi"}},
             {"type": "attachment", "attachment": {"type": "skill_listing", "content": "org-skill: Some Org's brand"}},
             {"type": "attachment", "attachment": {"type": "credential_org", "org": "Some Org"}},
             {"type": "attachment", "attachment": {"type": "queued_command", "commandMode": "task-notification"}},
             {"type": "api-request-blob", "blob": "system prompt"},
             {"type": "queue-operation", "operation": "enqueue"}]
    text = "".join(json.dumps(line) + "\n" for line in lines) + "not json\n"
    kept = [line for line in without_account(text).splitlines()]
    assert [json.loads(line)["type"] for line in kept[:-1]] == ["user", "attachment", "queue-operation"]
    assert "queued_command" in kept[1] and kept[-1] == "not json"
    assert "Some Org" not in without_account(text)


def test_the_persons_private_terms_are_read_from_their_own_file(tmp_path):
    terms = tmp_path / "compat-private.txt"
    terms.write_text("# employer and clients\nSome Org\n\n  Client Co  \n")
    assert private_terms(terms) == [("a private term", "Some Org"), ("a private term", "Client Co")]
    assert private_terms(tmp_path / "missing.txt") == []
    found = secrets(HOME, "someone", SCRATCH, private_terms(terms))
    assert leaks("a skill for SOME ORG job posts", found) == ["a private term"]
