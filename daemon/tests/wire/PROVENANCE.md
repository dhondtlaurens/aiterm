# Wire extension · 15 November 2026

Re-captured deliberately for the daemon to-do of the Operator signals plan, after `ee24a0ff`.
`SessionInfo.contextTokens` adds this conversation's current input count, nullable when unknown.
The scripted synthetic daemon records 39,239 tokens on its Claude worker and null on other
sessions. The app still decodes a session that omits the key; strict producer/consumer field
parity remains enabled. Names and other values retain the existing scripted capture.

Capture: from `daemon/`, `AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py`.
Then run the producer normally and the app's WireContractTests. No live account or iTerm2 is used.
The separate frozen operator-current tool and workspace fixtures were not regenerated.

Activation adds `session.closeIdle`, a generation- and conversation-checked idle worker handover.
Only its new reply frame and the method manifest were captured; existing frames are unchanged.
The scripted reply refuses unsent input. Delivery adapter tests separately prove safe closure,
sibling preservation and refusal for work, ownership, conversation, typing and permission changes.
