import asyncio
import contextlib
import json
import pytest
import pytest_asyncio
from aitermd import hooks_server
from aitermd.hooks_server import HookServer
from tests.conftest import http, http_request as post_json, mcp, operator_post


class Received(list):
    """Every delivered post, in order. A post is delivered after its reply is written, so a test
    waits for it with `delivered(n)` instead of reading the list straight after the reply."""

    def __init__(self):
        super().__init__()
        self._changed = asyncio.Condition()

    async def add(self, item):
        async with self._changed:
            self.append(item)
            self._changed.notify_all()

    async def delivered(self, count):
        async with self._changed:
            await asyncio.wait_for(self._changed.wait_for(lambda: len(self) >= count), 2)


@pytest_asyncio.fixture
async def server():
    received = Received()

    async def on_post(path, body):
        await received.add((path, body))
        if body.get("boom"):
            raise RuntimeError("handler failed")

    srv = HookServer(port=0, on_post=on_post)
    await srv.start()
    yield srv, received
    await srv.stop()


async def closed_by_server(r):
    """Reads the rest of the reply, returning once the server has closed its end: its handler for
    that request has finished."""
    await asyncio.wait_for(r.read(), 2)
    assert r.at_eof()


def test_the_routes_derive_from_the_harness_table():
    assert hooks_server.ROUTES == {"/hook/claude", "/hook/codex", "/hook/pi", "/mcp", "/statusline"}


async def test_post_routes_deliver_body(server):
    srv, received = server
    assert await http(srv.port, "POST", "/hook/claude", {"hook_event_name": "Stop"}) == 200
    assert await http(srv.port, "POST", "/statusline", {"model": {"id": "x"}}) == 200
    await received.delivered(2)
    assert received == [("/hook/claude", {"hook_event_name": "Stop"}), ("/statusline", {"model": {"id": "x"}})]


@pytest.mark.parametrize("path,event,tab", [
    ("/hook/codex", "SubagentStart", "w0t0p0:child"),
    ("/hook/pi", "agent_start", "w0t0p0:pi"),
])
async def test_a_route_forwards_the_inherited_iterm_session_id(server, path, event, tab):
    srv, received = server
    assert await http(srv.port, "POST", path, {"hook_event_name": event}, iterm_session_id=tab) == 200
    await received.delivered(1)
    assert received == [(path, {"hook_event_name": event, "_aiterm_iterm_session_id": tab})]


async def test_a_client_supplied_iterm_session_id_without_the_header_is_dropped(server):
    # The field is trusted as the inherited $ITERM_SESSION_ID; only the header may set it.
    srv, received = server
    assert await http(srv.port, "POST", "/hook/codex", {"hook_event_name": "Stop", "_aiterm_iterm_session_id": "w0t0p0:other"}) == 200
    await received.delivered(1)
    assert received == [("/hook/codex", {"hook_event_name": "Stop"})]


@pytest.mark.parametrize("path", ["/hook/codex", "/hook/pi"])
async def test_header_routes_take_the_tab_from_the_header_over_the_body(server, path):
    srv, received = server
    body = {"hook_event_name": "Stop", "_aiterm_iterm_session_id": "w0t0p0:forged"}
    assert await http(srv.port, "POST", path, body, iterm_session_id="w0t0p0:own-tab") == 200
    assert await http(srv.port, "POST", path, body) == 200
    await received.delivered(2)
    # Each post is delivered after its own reply, so the two can land in either order.
    assert len(received) == 2
    assert (path, {"hook_event_name": "Stop", "_aiterm_iterm_session_id": "w0t0p0:own-tab"}) in received
    assert (path, {"hook_event_name": "Stop"}) in received


@pytest.mark.parametrize("path", ["/hook/unknown", "/statusline/unknown"])
async def test_unknown_agents_are_not_served(server, path):
    srv, received = server
    assert await http(srv.port, "POST", path, {"hook_event_name": "Stop"}, iterm_session_id="w0t0p0:tab") == 404
    assert received == []


@pytest.mark.parametrize("length", [b"-5", b"abc", b"+3"])
async def test_an_unusable_content_length_is_a_400(server, length):
    srv, received = server
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(b"POST /hook/claude HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: " + length + b"\r\n\r\n{}")
    await w.drain()
    assert int((await asyncio.wait_for(r.readline(), 2)).split()[1]) == 400
    w.close()
    assert received == []


@pytest.mark.parametrize("path", sorted(hooks_server.ROUTES - {"/mcp"}))
@pytest.mark.parametrize("probe,answer", [
    ({"_aiterm_daemon_test_id": "daemon-3"}, {"ok": True, "daemonTestId": "daemon-3"}),
    # The PI extension sends its probe on a real event, which must not count.
    ({"_aiterm_test_id": "probe-7", "hook_event_name": "agent_start", "session_id": "s"}, {"ok": True, "testId": "probe-7"}),
])
async def test_a_probe_is_answered_without_being_delivered(server, path, probe, answer):
    srv, received = server
    status, response = await post_json(srv.port, path, probe)
    assert status == 200 and response == answer
    # A real post sent after it is delivered first: the probe was never handed on.
    assert await http(srv.port, "POST", path, {"hook_event_name": "Stop"}) == 200
    await received.delivered(1)
    assert received == [(path, {"hook_event_name": "Stop"})]


@pytest.mark.parametrize("path", ["/hook/claude", "/hook/codex"])
async def test_pretooluse_is_ordinary_telemetry_acknowledged_before_delivery(path):
    # No hook response carries a decision: the agent is never held up while the daemon works.
    release, delivered = asyncio.Event(), Received()

    async def on_post(received_path, body):
        await release.wait()
        await delivered.add((received_path, body["hook_event_name"]))
        return {"hookSpecificOutput": {"permissionDecision": "allow"}}

    srv = HookServer(port=0, on_post=on_post)
    await srv.start()
    try:
        status, response = await post_json(srv.port, path, {"hook_event_name": "PreToolUse", "tool_name": "Bash"})
        assert status == 200 and response == {}
        assert delivered == []
        release.set()
        await delivered.delivered(1)
        assert delivered == [(path, "PreToolUse")]
    finally:
        release.set()
        await srv.stop()


async def test_mcp_stop_hook_uses_an_existing_connection_and_delivers_to_codex_route(server):
    srv, received = server
    status, initialized = await mcp(srv.port, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}},
    })
    assert status == 200
    assert initialized["result"]["capabilities"] == {"tools": {"listChanged": False}}

    status, listed = await mcp(srv.port, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    assert status == 200 and listed["result"]["tools"][0]["name"] == "post_codex_hook"

    event = {"hook_event_name": "Stop", "session_id": "thread-1", "cwd": "/deleted/worktree", "model": "gpt-5.6"}
    status, called = await mcp(srv.port, {
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "post_codex_hook", "arguments": event},
    }, iterm_session_id="w0t0p0:codex")
    assert status == 200 and called["result"]["structuredContent"] == {}
    assert received == [("/hook/codex", {**event, "_aiterm_iterm_session_id": "w0t0p0:codex"})]


async def test_unknown_path_bad_json_and_handler_error(server):
    srv, _ = server
    assert await http(srv.port, "POST", "/nope", {}) == 404
    assert await http(srv.port, "GET", "/hook/claude") == 404
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(b"POST /hook/codex HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: 3\r\n\r\n{{{")
    await w.drain()
    assert int((await r.readline()).split()[1]) == 400
    w.close()
    assert await http(srv.port, "POST", "/hook/codex", {"boom": True}) == 200


@pytest.mark.parametrize("path", ["/hook/claude", "/hook/codex", "/hook/pi", "/statusline"])
async def test_every_hook_route_rejects_non_object_and_malformed_json(path, server):
    srv, _ = server
    assert await http(srv.port, "POST", path, ["not", "an", "object"]) == 400
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(f"POST {path} HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: 3\r\n\r\n".encode() + b"{{{")
    await w.drain()
    assert int((await r.readline()).split()[1]) == 400
    w.close()


@pytest.mark.parametrize("path", ["/hook/claude", "/hook/codex", "/hook/pi", "/statusline"])
async def test_missing_hook_header_is_404(path, server):
    srv, received = server
    assert await http(srv.port, "POST", path, {"hook_event_name": "Stop"}, header=False) == 404
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(b"GET /hook/claude HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
    await w.drain()
    assert int((await r.readline()).split()[1]) == 404
    await closed_by_server(r)
    w.close()
    assert received == []  # the handler never even sees a request without the header


async def _status_for_head(port, head: bytes) -> int:
    r, w = await asyncio.open_connection("127.0.0.1", port)
    w.write(head)
    await w.drain()
    status = int((await asyncio.wait_for(r.readline(), 2)).split()[1])
    await closed_by_server(r)
    w.close()
    return status


@pytest.mark.parametrize("filler", [
    b"".join(b"X-Filler-%d: x\r\n" % i for i in range(hooks_server.MAX_HEADER_LINES)),   # too many lines
    b"X-Filler: " + b"x" * 40_000 + b"\r\n",                                              # too many bytes
], ids=["lines", "bytes"])
async def test_a_head_past_the_cap_is_a_431_before_the_hook_header_is_read(server, filler):
    # Each line is capped at 64 KiB by the stream, but their number was not, for the whole read timeout.
    srv, received = server
    body = b'{"hook_event_name": "Stop"}'
    head = b"POST /hook/claude HTTP/1.1\r\n" + filler + b"X-AiTerm-Hook: 1\r\nContent-Length: %d\r\n\r\n" % len(body)
    assert await _status_for_head(srv.port, head + body) == 431
    assert received == []


async def test_a_head_just_under_the_cap_is_served(server):
    srv, received = server
    filler = b"".join(b"X-Filler-%d: x\r\n" % i for i in range(hooks_server.MAX_HEADER_LINES - 3))
    head = b"POST /hook/claude HTTP/1.1\r\nHost: x\r\n" + filler + b"X-AiTerm-Hook: 1\r\nContent-Length: 2\r\n\r\n{}"
    assert await _status_for_head(srv.port, head) == 200
    await received.delivered(1)


async def test_server_without_callback_still_replies_200():
    """Test that server works without a callback (callback is optional)."""
    srv = HookServer(port=0)
    await srv.start()
    try:
        assert await http(srv.port, "POST", "/statusline", {"model": {"id": "x"}}) == 200
        assert await http(srv.port, "POST", "/hook/claude", {"test": "data"}) == 200
    finally:
        await srv.stop()


async def test_stalled_client_is_dropped():
    """A client that never completes its request is dropped once the read timeout passes."""
    srv = HookServer(port=0, read_timeout=0.1)
    await srv.start()
    try:
        r, w = await asyncio.open_connection("127.0.0.1", srv.port)
        # Send only the request line, no headers or body
        w.write(b"POST /statusline HTTP/1.1\r\n")
        await w.drain()
        result = await asyncio.wait_for(r.read(), 2)
        assert result == b"", "Server should close connection on stalled client"
        w.close()
    finally:
        await srv.stop()


async def test_a_deeply_nested_body_is_a_400(server, caplog, monkeypatch):
    srv, received = server
    caplog.set_level("ERROR")
    # How deep the parser goes before RecursionError depends on the interpreter's C stack:
    # Homebrew's 3.14 parses this body, mise's gives up. Raise it outright so every build tests
    # the same path: a parser that gives up is a bad request, not a dropped connection.
    def too_deep(*_args, **_kwargs):
        raise RecursionError("maximum recursion depth exceeded while decoding a JSON object")

    monkeypatch.setattr(hooks_server.json, "loads", too_deep)
    nested = ('{"a":' * 100_000 + "1" + "}" * 100_000).encode()
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(b"POST /hook/claude HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: %d\r\n\r\n" % len(nested) + nested)
    await w.drain()
    status_line = await asyncio.wait_for(r.readline(), 2)
    await closed_by_server(r)
    w.close()
    assert int(status_line.split()[1]) == 400
    assert received == [] and not caplog.records


async def test_expect_100_continue_gets_interim_response_then_200(server):
    srv, received = server
    body = json.dumps({"hook_event_name": "Stop"}).encode()
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(
        f"POST /hook/claude HTTP/1.1\r\nHost: x\r\nX-AiTerm-Hook: 1\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\nExpect: 100-continue\r\n\r\n".encode()
    )
    await w.drain()
    interim = await asyncio.wait_for(r.readline(), 2)
    assert interim.split()[1] == b"100"
    await asyncio.wait_for(r.readline(), 2)  # the blank line terminating the interim response
    w.write(body)
    await w.drain()
    status_line = await asyncio.wait_for(r.readline(), 2)
    assert int(status_line.split()[1]) == 200
    w.close()
    await received.delivered(1)
    assert ("/hook/claude", {"hook_event_name": "Stop"}) in received


@pytest.mark.parametrize("head", [
    b"POST /statusline HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n",
    b"POST /hook/pi HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: 2000000\r\n\r\n",
], ids=["statusline", "pi"])
async def test_oversized_body_is_rejected_with_413(head):
    """Test that Content-Length exceeding MAX_BODY is rejected with 413."""
    srv = HookServer(port=0)
    await srv.start()
    try:
        r, w = await asyncio.open_connection("127.0.0.1", srv.port)
        w.write(head)
        await w.drain()
        status_line = await asyncio.wait_for(r.readline(), 2)
        status = int(status_line.split()[1])
        assert status == 413, f"Expected 413 for oversized body, got {status}"
        w.close()
    finally:
        await srv.stop()


class StubRoute:
    """Answers /operator with what a test set, and records what reached it."""

    def __init__(self, status=200, text='{"ok":true}'):
        self.status, self.text, self.seen = status, text, []

    async def serve(self, method, headers, body):
        self.seen.append((method, headers.get("authorization"), body))
        if self.status == 500:
            raise RuntimeError("the route failed")
        return self.status, self.text

    async def gate(self, method, headers, body):
        self.seen.append(("GATE", headers.get("authorization"), body))
        return 200, '{"gate":true}'


async def test_the_operator_route_reaches_its_own_handler_not_the_hooks(server):
    srv, received = server
    srv.operator_route = route = StubRoute()
    status, body = await operator_post(srv.port, {"jsonrpc": "2.0", "id": 1, "method": "ping"}, token="t" * 40)
    assert (status, body) == (200, {"ok": True})
    assert route.seen == [("POST", "Bearer " + "t" * 40, b'{"jsonrpc": "2.0", "id": 1, "method": "ping"}')]
    assert received == []


@pytest.mark.parametrize("status", [401, 405])
async def test_the_operator_routes_refusals_are_its_own(server, status):
    srv, _ = server
    srv.operator_route = StubRoute(status=status, text="")
    assert await operator_post(srv.port, None, method="GET") == (status, None)


async def test_the_operator_route_hides_behind_the_hook_header_like_every_route(server):
    srv, _ = server
    srv.operator_route = route = StubRoute()
    assert (await operator_post(srv.port, {}, token="t" * 40, hook=False))[0] == 404
    assert route.seen == []


async def test_the_operator_gate_hides_behind_the_hook_header_too(server):
    srv, _ = server
    srv.operator_route = route = StubRoute()
    assert (await operator_post(srv.port, {}, token="t" * 40, hook=False, path="/operator/gate"))[0] == 404
    assert route.seen == []


async def test_the_operator_gate_reaches_the_routes_gate(server):
    srv, received = server
    srv.operator_route = route = StubRoute()
    status, body = await operator_post(srv.port, {"tool_name": "Bash"}, token="t" * 40, path="/operator/gate")
    assert (status, body) == (200, {"gate": True})
    assert route.seen == [("GATE", "Bearer " + "t" * 40, b'{"tool_name": "Bash"}')]
    assert received == []


async def test_without_an_operator_route_there_is_no_gate(server):
    srv, _ = server
    assert (await operator_post(srv.port, {}, token="t" * 40, path="/operator/gate"))[0] == 404


async def test_without_an_operator_route_there_is_none(server):
    srv, _ = server
    assert (await operator_post(srv.port, {}, token="t" * 40))[0] == 404


async def test_an_operator_route_that_fails_is_a_500_not_a_dropped_connection(server, caplog):
    srv, _ = server
    srv.operator_route = StubRoute(status=500)
    assert (await operator_post(srv.port, {}, token="t" * 40))[0] == 500
    assert "operator route failed" in caplog.text


async def test_stop_closes_an_incomplete_request(server):
    srv, _ = server
    reader, writer = await asyncio.open_connection("127.0.0.1", srv.port)
    # Wait for the server to own this connection before stopping it. A completed TCP
    # connect alone can precede the server's accept callback on a busy event loop.
    writer.write(b"POST /hook/claude HTTP/1.1\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n")
    await writer.drain()
    try:
        assert await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 1) == b"HTTP/1.1 100 Continue\r\n\r\n"
        # The request remains incomplete: none of its promised body has arrived.
        await asyncio.wait_for(srv.stop(), 0.2)
        with contextlib.suppress(ConnectionResetError):
            assert await asyncio.wait_for(reader.read(), 0.2) == b""
    finally:
        writer.close()
        with contextlib.suppress(ConnectionResetError):
            await writer.wait_closed()


async def test_stop_cancels_an_active_hook_delivery():
    entered, finished, release = asyncio.Event(), asyncio.Event(), asyncio.Event()

    async def deliver(path, body):
        entered.set()
        try:
            await release.wait()
        finally:
            finished.set()

    srv = HookServer(port=0, on_post=deliver)
    await srv.start()
    try:
        assert await http(srv.port, "POST", "/hook/claude", {}) == 200
        await asyncio.wait_for(entered.wait(), 1)
        await asyncio.wait_for(srv.stop(), 0.2)
        assert finished.is_set()
    finally:
        release.set()
        await srv.stop()


async def test_stop_is_bounded_when_a_client_does_not_read_its_response():
    entered = asyncio.Event()

    class LargeResponse:
        async def serve(self, method, headers, body):
            entered.set()
            return 200, "x" * (8 << 20)

    srv = HookServer(port=0)
    srv.operator_route = LargeResponse()
    await srv.start()
    reader, writer = await asyncio.open_connection("127.0.0.1", srv.port)
    writer.write(b"POST /operator HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: 0\r\n\r\n")
    await writer.drain()
    try:
        await asyncio.wait_for(entered.wait(), 1)
        # Leave the large response unread so the server's drain remains backpressured.
        await asyncio.wait_for(srv.stop(), 0.2)
    finally:
        writer.close()
        with contextlib.suppress(ConnectionResetError):
            await writer.wait_closed()
        await srv.stop()


async def test_stop_owns_a_finished_request_until_its_buffered_transport_closes():
    completed = asyncio.Event()
    accepted = []

    class BufferedResponseServer(HookServer):
        async def _serve(self, reader, writer):
            # drain() legitimately returns with pending output below the low watermark.
            writer.transport.set_write_buffer_limits(high=16 << 20, low=8 << 20)
            accepted.append((asyncio.current_task(), writer))
            await super()._serve(reader, writer)
            completed.set()

    srv = BufferedResponseServer(port=0)
    srv.operator_route = StubRoute(text="x" * (8 << 20))
    await srv.start()
    reader, writer = await asyncio.open_connection("127.0.0.1", srv.port)
    writer.write(b"POST /operator HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: 0\r\n\r\n")
    await writer.drain()
    try:
        await asyncio.wait_for(completed.wait(), 1)
        _, response_writer = accepted[0]
        await asyncio.sleep(0)  # Let the completed request's ownership callback run.
        assert response_writer.is_closing()
        assert response_writer.transport.get_write_buffer_size() > 0
        await asyncio.wait_for(srv.stop(), 0.2)
    finally:
        writer.close()
        with contextlib.suppress(ConnectionResetError):
            await writer.wait_closed()
        await srv.stop()


async def test_route_can_reply_with_a_standard_status_outside_hook_errors(server):
    srv, _ = server

    class Route:
        async def serve(self, method, headers, body):
            return 201, '{"created":true}'

    srv.operator_route = Route()
    assert await operator_post(srv.port, {}, token="token") == (201, {"created": True})
