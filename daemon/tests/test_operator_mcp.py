# daemon/tests/test_operator_mcp.py
"""The operator's MCP server (operator_mcp): the run tokens, the tool catalogue, the MCP methods and
the forwarding of tool calls to the app, driven directly rather than over HTTP."""
import os

import pytest

from aitermd.operator_mcp import OperatorTokens, well_formed

TOKEN = "ab" * 32
OTHER = "cd" * 32
UNKNOWN = "ef" * 32


def write_token(root, run_id, token, mode=0o600):
    """A run folder's token file, as the app writes it."""
    folder = root / run_id
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "token").write_text(token + "\n", encoding="utf-8")
    os.chmod(folder / "token", mode)
    return folder / "token"


def test_a_token_opens_its_own_run_only():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    tokens.register("run-2", OTHER)
    assert tokens.run_for(TOKEN) == "run-1" and tokens.run_for(OTHER) == "run-2"
    assert tokens.run_for(UNKNOWN) is None and tokens.run_for("") is None


def test_registering_a_run_again_replaces_its_token():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    tokens.register("run-1", OTHER)
    assert tokens.run_for(TOKEN) is None and tokens.run_for(OTHER) == "run-1"
    tokens.register("run-1", OTHER)  # the app registering again after it reattached: no change
    assert tokens.run_for(OTHER) == "run-1"


def test_a_revoked_token_opens_nothing():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    tokens.revoke("run-1")
    tokens.revoke("run-404")
    assert tokens.run_for(TOKEN) is None


@pytest.mark.parametrize("token", ["", "short", "ab" * 16, "AB" * 32 + "a", "xy" * 32])
def test_a_token_that_is_not_64_hex_characters_is_refused(token):
    assert not well_formed(token)
    with pytest.raises(ValueError, match="64 hex"):
        OperatorTokens().register("run-1", token)


def test_one_token_cannot_open_two_runs():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    with pytest.raises(ValueError, match="another run"):
        tokens.register("run-2", TOKEN)
    assert tokens.run_for(TOKEN) == "run-1"


def test_a_token_that_is_not_ascii_is_compared_without_raising():
    tokens = OperatorTokens()
    tokens.register("run-1", TOKEN)
    assert tokens.run_for("é" * 40) is None


def test_a_restarted_daemon_knows_the_tokens_in_the_run_folders(tmp_path):
    write_token(tmp_path, "run-1", TOKEN)
    write_token(tmp_path, "run-2", OTHER)
    tokens = OperatorTokens(tmp_path)
    assert tokens.run_for(TOKEN) == "run-1" and tokens.run_for(OTHER) == "run-2"


def test_a_token_file_that_is_not_a_runs_own_is_skipped(tmp_path, caplog):
    write_token(tmp_path, "readable", TOKEN, mode=0o644)   # others could read it
    write_token(tmp_path, "malformed", "not a token")
    (tmp_path / "no-token").mkdir()
    (tmp_path / "stray-file").write_text(OTHER, encoding="utf-8")
    tokens = OperatorTokens(tmp_path)
    assert tokens.run_for(TOKEN) is None and tokens.run_for(OTHER) is None
    assert "readable" in caplog.text and "malformed" in caplog.text


def test_a_missing_runs_folder_is_no_runs(tmp_path):
    assert OperatorTokens(tmp_path / "nowhere").run_for(TOKEN) is None


def test_an_unknown_well_formed_token_rereads_the_folder_once(tmp_path):
    tokens = OperatorTokens(tmp_path)
    write_token(tmp_path, "run-3", TOKEN)  # written by the app after this daemon started
    assert tokens.run_for(TOKEN) == "run-3"


def test_a_malformed_token_never_rereads_the_folder(tmp_path, monkeypatch):
    tokens = OperatorTokens(tmp_path)
    reads = []
    monkeypatch.setattr(tokens, "_load", lambda: reads.append(1))
    assert tokens.run_for("short") is None and tokens.run_for("é" * 64) is None
    assert reads == []
    assert tokens.run_for(UNKNOWN) is None
    assert reads == [1], "an unknown well-formed token rereads once"


def test_revoke_deletes_the_runs_token_file_so_a_reread_cannot_bring_it_back(tmp_path):
    path = write_token(tmp_path, "run-1", TOKEN)
    tokens = OperatorTokens(tmp_path)
    tokens.revoke("run-1")
    assert not path.exists() and path.parent.is_dir(), "the file goes; the run folder is the app's"
    assert tokens.run_for(TOKEN) is None


def test_revoke_deletes_nothing_outside_the_runs_folder(tmp_path):
    root = tmp_path / "runs"
    root.mkdir()
    outside = write_token(tmp_path, "elsewhere", TOKEN)
    tokens = OperatorTokens(root)
    for run_id in ("../elsewhere", "..", ".", "", "a/b"):
        tokens.revoke(run_id)
    assert outside.exists()


def test_memory_wins_over_a_file(tmp_path):
    tokens = OperatorTokens(tmp_path)
    tokens.register("run-1", OTHER)  # rotated, its file not written yet
    write_token(tmp_path, "run-1", TOKEN)
    assert tokens.run_for(TOKEN) is None and tokens.run_for(OTHER) == "run-1"
