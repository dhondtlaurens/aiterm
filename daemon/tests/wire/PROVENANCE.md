# Wire extension · 15 November 2026

Re-captured deliberately for the daemon to-do of the Operator signals plan, after `ee24a0ff`.
`SessionInfo.contextTokens` adds this conversation's current input count, nullable when unknown.
The scripted synthetic daemon records 39,239 tokens on its Claude worker and null on other
sessions. The app still decodes a session that omits the key; strict producer/consumer field
parity remains enabled. Names and other values retain the existing scripted capture.

Capture: from `daemon/`, `AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py`.
Then run the producer normally and the app's WireContractTests. No live account or iTerm2 is used.

Activation adds `session.closeIdle`, a generation- and conversation-checked idle worker handover.
Only its new reply frame and the method manifest were captured; existing frames are unchanged.
The scripted reply refuses unsent input. Delivery adapter tests separately prove safe closure,
sibling preservation and refusal for work, ownership, conversation, typing and permission changes.

On 15 Nov 2026 the Signal activation/deletion deliberately added `generation: 1` to the
`operator.request` event. Register and revoke now require the single Operator's generation;
per-run tokens are retired. The existing capture driver produced this frame through the real
socket and HTTP route. Every other previously captured frame stayed byte-for-byte unchanged.

On 17 Nov 2026, greenfield refactor step 1g removed `model`, `reasoning`, `title`,
`subagentsWrittenAt` and `slashCommands` from every session, and `session.prompt` and
`session.dismissStartup` from the manifest and reply fixtures. Re-recorded with
`AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py` through the synthetic
Service and FakeIterm; no live account or iTerm2 used. All other frames retain their bytes.

On 17 Nov 2026, greenfield refactor step 1j renamed `runId` to `operatorId` in the
`operator.request` event and the `operator.register`/`operator.revoke` params. Re-recorded with
`AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py` through the synthetic
Service and FakeIterm; no other frame changed and no live account was used.

On 17 Nov 2026, 6a of the greenfield refactor replaced `background` and `displayWork` (with
`legacyIndex`) by one ordered `work` list whose items carry `holdsTurn`; re-captured with the same
scripted run (`AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py`, the
synthetic Service and FakeIterm, no live account or iTerm2). Only the session payloads changed, in
`event.session.opened`, `event.session.changed`, `reply.sessions.list` and
`reply.workspace.snapshot`; the snapshot's working Claude tab now lists its Stop's subagent with
`holdsTurn` and leaves out the Stop's shell, which no reader shows while that turn works.
