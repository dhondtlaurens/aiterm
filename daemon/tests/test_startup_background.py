"""The untagged window opened by AiTerm's launch gets the override, not other windows."""
import asyncio

import pytest

from aitermd.iterm_bridge import ItermUnavailable
from aitermd.models import Frame
from tests.conftest import wait_until
from tests.fake_iterm import FakeIterm

FRAME = Frame(0, 0, 800, 600)


async def launched_service(make_service, *, window_count=1):
    it = FakeIterm(connected=False, notify_on_create=False)
    startup = []

    async def launch():
        for _ in range(window_count):
            startup.append(await it.create_window("/Users/me", "zsh", {}, FRAME))
        await it.reconnect()

    svc = make_service(iterm=it, supervisor={"launch_iterm": launch, "reconnect_seconds": 0.001})
    await svc.start()
    await wait_until(lambda: svc.supervisor.version is not None)
    return svc, it, startup


async def test_launched_window_is_painted_and_restored_without_project_ownership(make_service):
    svc, it, [(wid, sid)] = await launched_service(make_service)
    _, unrelated = await it.create_window("/elsewhere", "zsh", {}, FRAME)
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    assert it.background_requests[-1] == ([sid], True)
    assert it.sessions[sid].user_vars == {}
    assert svc.registry.get(sid).task_id is None
    assert svc.registry.get(sid).project_id is None
    await svc.windows.set_match_iterm_background({"matchItermBackground": False})
    assert it.background_requests[-1] == ([sid], False)
    assert all(unrelated not in ids for ids, _ in it.background_requests)


async def test_tabs_in_startup_window_follow_override_without_cd_or_tags(make_service):
    svc, it, [(wid, sid)] = await launched_service(make_service)
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    tab = await it.user_opens_tab(wid)
    assert it.background_requests[-1] == ([tab], True)
    assert it.sessions[tab].user_vars == {}
    assert not it.sent
    await svc.windows.set_match_iterm_background({"matchItermBackground": False})
    assert it.background_requests[-1] == ([sid, tab], False)


async def test_app_created_startup_tab_is_also_restored(make_service):
    svc, it, [(wid, sid)] = await launched_service(make_service)
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    tab = (await svc.windows.create_tab({"windowId": wid}))["sessionId"]
    assert it.background_requests[-1] == ([tab], True)
    await svc.windows.set_match_iterm_background({"matchItermBackground": False})
    assert it.background_requests[-1] == ([sid, tab], False)


async def test_reconnect_after_a_disconnect_does_not_give_an_enabled_override_the_persons_window(make_service):
    # The daemon does not relaunch iTerm2 after a disconnect, so no startup window is captured: the
    # window the person opens once iTerm2 is back is not theirs to have the override.
    it = FakeIterm(notify_on_create=False)
    launches = []

    async def launch():
        launches.append(1)

    svc = make_service(iterm=it, supervisor={"launch_iterm": launch, "reconnect_seconds": 0.001})
    await svc.start()
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    await it.disconnect()
    await asyncio.sleep(0.05)  # several failed retries while iTerm2 is away
    await it.reconnect()
    await wait_until(lambda: svc.supervisor.version is not None)
    _, sid = await it.create_window("/Users/me", "zsh", {}, FRAME)
    await svc.tick()
    assert launches == []
    assert all(sid not in ids for ids, _ in it.background_requests)


async def test_startup_tracking_survives_api_reconnect(make_service):
    svc, it, [(_, sid)] = await launched_service(make_service)
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    await it.disconnect()
    await it.reconnect()
    await wait_until(lambda: svc.supervisor.version is not None)
    await svc.windows.set_match_iterm_background({"matchItermBackground": False})
    assert it.background_requests[-1] == ([sid], False)


async def test_moving_a_startup_tab_does_not_adopt_its_unrelated_destination(make_service):
    svc, it, [(wid, sid)] = await launched_service(make_service)
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    other, _ = await it.create_window("/elsewhere", "zsh", {}, FRAME)
    it.windows[wid]["sessions"].remove(sid)
    it.windows[other]["sessions"].append(sid)
    it.sessions[sid].window_id = other
    await svc.tick()
    before = len(it.background_requests)
    await it.user_opens_tab(other)
    assert len(it.background_requests) == before
    await svc.windows.set_match_iterm_background({"matchItermBackground": False})
    assert it.background_requests[-1] == ([sid], False)


async def test_closed_startup_window_does_not_pass_override_to_next_window(make_service):
    svc, it, [(wid, _)] = await launched_service(make_service)
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    await it.close_window(wid)
    await svc.tick()
    unrelated, _ = await it.create_window("/Users/me", "zsh", {}, FRAME)
    await it.user_opens_tab(unrelated)
    await svc.windows.set_match_iterm_background({"matchItermBackground": False})
    assert it.background_requests[-1] == ([], False)


async def test_existing_untagged_window_is_not_adopted_on_connect(make_service):
    it = FakeIterm()
    await it.create_window("/Users/me", "zsh", {}, FRAME)
    svc = make_service(iterm=it)
    await svc.start()
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    assert it.background_requests[-1] == ([], True)


@pytest.mark.parametrize("window_count", [0, 2])
async def test_launch_does_not_guess_which_of_several_restored_windows_is_startup(make_service, window_count):
    svc, it, _ = await launched_service(make_service, window_count=window_count)
    await it.create_window("/unrelated", "zsh", {}, FRAME)
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    assert it.background_requests[-1] == ([], True)


class UnansweredAtFirst(FakeIterm):
    """A running iTerm2 that does not answer its first `misses` connections: a timeout, which is
    not ItermNotRunning. connect_error is single-shot, so the misses are counted here."""

    def __init__(self, misses: int, **kw):
        super().__init__(**kw)
        self.misses = misses

    async def connect(self) -> str | None:
        if self.misses:
            self.misses -= 1
            raise ItermUnavailable("iTerm2 did not answer within 10s")
        return await super().connect()


async def test_iterm_that_did_not_answer_is_not_adopted_by_the_launch_that_follows(make_service):
    # The start attempt and the first retry both go unanswered, so the loop launches iTerm2 on a
    # failure that does not say iTerm2 is absent. The window already there was not opened by that
    # launch, so it is not adopted as its startup window.
    it = UnansweredAtFirst(misses=2, notify_on_create=False)
    await it.create_window("/Users/me", "zsh", {}, FRAME)
    launches = []

    async def launch():
        launches.append(1)
        await it.reconnect()

    svc = make_service(iterm=it, supervisor={"launch_iterm": launch, "reconnect_seconds": 0.001})
    await svc.start()
    await wait_until(lambda: svc.supervisor.version is not None)
    assert launches == [1]
    await svc.windows.set_match_iterm_background({"matchItermBackground": True})
    assert it.background_requests[-1] == ([], True)


async def test_a_startup_window_closed_before_any_poll_is_forgotten_on_the_next_launch(make_service):
    svc, it, [(wid, _)] = await launched_service(make_service)
    await it.close_window(wid)  # before any poll could see it go
    await svc.windows.capture_startup_window()
    assert svc.windows._startup_windows == set()
    assert svc.windows._startup_sessions == set()
