# daemon/tests/test_delivery_service.py
"""session.deliver, session.prompt, session.dismissStartup, session.setOwnership and
delivery.policy over the app's socket."""
import asyncio
import json

import pytest

from aitermd import delivery
from aitermd.delivery import PASTE_END, PASTE_START

FRAME = {"x": 324, "y": 36, "w": 1104, "h": 852}
IDLE = "────────────────\n❯\x20\n────────────────\n  ? for shortcuts"


@pytest.fixture
async def claude(make_service, monkeypatch, tmp_path):
    """A started service with an app attached and a Claude 2.1.301 idle in a task window, its version
    read by the tick from its session file: the service, its FakeIterm, the Claude tab's session id, a
    `call` that sends one request and returns its reply, and the delivery policy the service reads,
    which a test may change."""
    monkeypatch.setattr(delivery, "SUBMIT_DELAY", 0)
    policy = {"claude": ("auto", "2.1.301")}
    svc = make_service(delivery_policy=lambda: policy, monotonic=lambda: 500.0)
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    ids = iter(range(1, 1000))

    async def call(method, params=None):
        request_id = next(ids)
        w.write((json.dumps({"id": request_id, "method": method, "params": params}) + "\n").encode())
        await w.drain()
        while True:
            message = json.loads(await asyncio.wait_for(r.readline(), 2))
            if message.get("id") == request_id:
                return message

    wid = (await call("window.createTask", {"taskId": "t1", "cwd": "/wt", "title": "x", "frame": FRAME}))["result"]["windowId"]
    sid = svc.iterm.windows[wid]["sessions"][0]
    # Claude's session file, as Claude Code 2.1.301 writes it (make_service reads them under tmp_path).
    (tmp_path / "claude-sessions").mkdir()
    (tmp_path / "claude-sessions" / "4242.json").write_text(json.dumps({
        "pid": 4242, "sessionId": "c-4242", "cwd": "/wt", "status": "idle", "version": "2.1.301"}))
    await svc.iterm.user_runs(sid, "claude", job_pid=4242)
    await svc.tick()
    assert svc.registry.get(sid).cli_version == "2.1.301"
    svc.iterm.screens[sid] = IDLE
    svc.iterm.sent.clear()
    yield svc, svc.iterm, sid, call, policy
    w.close()


async def test_a_message_is_delivered_over_the_socket(claude):
    _svc, it, sid, call, _policy = claude
    reply = await call("session.deliver", {"sessionId": sid, "text": "Run the tests.", "ownership": 1})
    assert reply["result"] == {"result": "delivered", "reason": None}
    assert it.sent == [(sid, PASTE_START + "Run the tests." + PASTE_END), (sid, "\r")]


async def test_a_cli_without_a_passed_check_gets_nothing(claude):
    _svc, it, sid, call, policy = claude
    policy.clear()
    reply = await call("session.deliver", {"sessionId": sid, "text": "hello", "ownership": 1})
    assert reply["result"]["result"] == "refused" and it.sent == []


async def test_a_cli_updated_since_its_check_gets_nothing(claude):
    _svc, it, sid, call, policy = claude
    policy["claude"] = ("auto", "2.1.300")
    reply = await call("session.deliver", {"sessionId": sid, "text": "hello", "ownership": 1})
    assert reply["result"] == {"result": "refused", "reason": "claude 2.1.301 has not passed the delivery check"}
    assert it.sent == []


async def test_set_ownership_turns_away_an_older_send(claude):
    _svc, it, sid, call, _policy = claude
    assert (await call("session.setOwnership", {"sessionId": sid, "ownership": 2}))["result"] == {}
    reply = await call("session.deliver", {"sessionId": sid, "text": "hello", "ownership": 1})
    assert reply["result"] == {"result": "refused", "reason": "the task changed hands after this message was written"}


async def test_set_ownership_never_lowers_a_generation(claude):
    _svc, it, sid, call, _policy = claude
    await call("session.setOwnership", {"sessionId": sid, "ownership": 5})
    assert (await call("session.setOwnership", {"sessionId": sid, "ownership": 2}))["result"] == {}
    reply = await call("session.deliver", {"sessionId": sid, "text": "hello", "ownership": 4})
    assert reply["result"] == {"result": "refused", "reason": "the task changed hands after this message was written"}
    assert it.sent == []


async def test_a_wake_line_waits_while_you_type_in_that_session(claude):
    _svc, it, sid, call, _policy = claude
    await it.user_types(sid)
    reply = await call("session.deliver", {"sessionId": sid, "text": "[AiTerm] 1 update, call run_status", "ownership": 1,
                                           "wake": True})
    assert reply["result"] == {"result": "refused", "reason": "you are typing"}
    assert it.sent == []


async def test_a_long_message_goes_through_the_worktree(claude, tmp_path):
    _svc, it, sid, call, _policy = claude
    reply = await call("session.deliver", {"sessionId": sid, "text": "y" * 2500, "ownership": 1, "worktree": str(tmp_path)})
    assert reply["result"]["result"] == "delivered"
    assert it.sent[0] == (sid, PASTE_START + "Read .aiterm/messages/1.md and act on it." + PASTE_END)


async def test_session_prompt_reads_the_open_prompt(claude):
    _svc, it, sid, call, _policy = claude
    assert (await call("session.prompt", {"sessionId": sid}))["result"] == {"kind": None}
    it.screens[sid] = " Do you want to proceed?\n ❯ 1. Yes\n   2. No"
    assert (await call("session.prompt", {"sessionId": sid}))["result"] == {"kind": "permission"}
    assert (await call("session.prompt", {"sessionId": "s404"}))["error"]["code"] == "not_found"


async def test_session_dismiss_startup_leaves_every_dialog_but_an_update_offer(claude):
    _svc, it, sid, call, _policy = claude
    it.screens[sid] = " Quick safety check: Is this a project you created or one you trust?\n ❯ 1. No, exit\n   2. Yes, I trust this folder"
    assert (await call("session.dismissStartup", {"sessionId": sid}))["result"] == {"dismissed": False}
    assert it.sent == []
    assert (await call("session.dismissStartup", {"sessionId": "s404"}))["error"]["code"] == "not_found"


async def test_the_policy_names_every_harness_and_the_version_its_check_vouches_for(claude):
    """What the Operator is told before it plans: each CLI's verdict as the daemon reads it on every
    delivery, a CLI the check never passed `off` with no version. Read again on every call."""
    _svc, _it, _sid, call, policy = claude
    reply = await call("delivery.policy")
    assert reply["result"] == {"agents": {
        "claude": {"policy": "auto", "version": "2.1.301"}, "codex": {"policy": "off", "version": None},
        "grok": {"policy": "off", "version": None}, "pi": {"policy": "off", "version": None}}}
    policy["codex"] = ("pasteOnly", "0.160.0")
    assert (await call("delivery.policy"))["result"]["agents"]["codex"] == {"policy": "pasteOnly", "version": "0.160.0"}


@pytest.mark.parametrize("method,params", [
    ("session.deliver", {"text": "hello", "ownership": 1}),
    ("session.deliver", {"sessionId": "s1", "ownership": 1}),
    ("session.deliver", {"sessionId": "s1", "text": "hello"}),
    ("session.deliver", {"sessionId": "s1", "text": "hello", "ownership": "1"}),
    ("session.deliver", {"sessionId": "s1", "text": "hello", "ownership": True}),
    ("session.deliver", {"sessionId": "s1", "text": "hello", "ownership": 1, "wake": "yes"}),
    ("session.deliver", {"sessionId": "s1", "text": "hello", "ownership": 1, "worktree": 7}),
    ("session.prompt", {}),
    ("session.dismissStartup", {}),
    ("session.setOwnership", {"sessionId": "s1"}),
])
async def test_a_malformed_request_is_bad_params(claude, method, params):
    *_, call, _policy = claude
    assert (await call(method, params))["error"]["code"] == "bad_params"


async def test_a_closed_session_forgets_its_generation_and_last_key(claude):
    svc, it, sid, call, _policy = claude
    await call("session.setOwnership", {"sessionId": sid, "ownership": 5})
    await it.user_types(sid)
    await it.user_closes_session(sid)  # the service ticks on the close, and forgets the session
    assert not svc.typing.is_typing(sid, 500.0) and svc.typing.has_unsent_input(sid)
    assert sid not in svc.deliverer._ownership
