"""The port is SDK-independent and importing the adapter does not patch authentication."""
import os
from pathlib import Path
import subprocess
import sys

import pytest

from aitermd import iterm_bridge
from aitermd.iterm_port import ItermUnavailable


def test_importing_the_port_or_adapter_has_no_authentication_effect():
    probe = '''
import sys
import aitermd.iterm_port
assert "iterm2" not in sys.modules
import iterm2
before = iterm2.connection._auth_authenticate
import aitermd.iterm_bridge
assert iterm2.connection._auth_authenticate is before
'''
    result = subprocess.run([sys.executable, "-c", probe], cwd=Path(__file__).resolve().parents[1],
                            env={key: value for key, value in os.environ.items() if key != "PYTHONPATH"},
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr


async def test_connect_applies_the_authentication_patch_before_using_the_sdk(monkeypatch):
    monkeypatch.setattr(iterm_bridge, "request_cookie", lambda: None)
    monkeypatch.setattr(iterm_bridge.iterm2.connection, "_auth_authenticate", lambda *args: True)

    async def connect():
        assert iterm_bridge.iterm2.connection._auth_authenticate is iterm_bridge._no_cookie_request
        raise OSError("probe stopped before any connection")

    monkeypatch.setattr(iterm_bridge.iterm2.Connection, "async_create", connect)
    with pytest.raises(ItermUnavailable, match="probe stopped"):
        await iterm_bridge.ItermBridge().connect()
