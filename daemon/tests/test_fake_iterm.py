# daemon/tests/test_fake_iterm.py
from aitermd.models import Frame
from tests.fake_iterm import FakeIterm


async def test_fake_window_and_tab_lifecycle():
    it = FakeIterm()
    wid, _ = await it.create_window("/w", "t", {"aiterm_task": "t1"}, Frame(0, 0, 10, 10))
    seen = []
    it.on_new_session(lambda sid: _record(seen, sid))
    sid = await it.user_opens_tab(wid)
    assert seen == [sid]
    snap = await it.snapshot()
    assert [s.tab_index for s in snap] == [0, 1] and snap[1].cwd == "/Users/me" and snap[1].user_vars == {}
    await it.set_session_tags(sid, {"aiterm_task": "t1"})
    assert (await it.snapshot())[1].user_vars == {"aiterm_task": "t1"}


async def _record(seen, sid):
    seen.append(sid)
