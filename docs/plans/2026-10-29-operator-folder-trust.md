# Operator startup folder trust

## Goal

A broadcast must start without Claude's folder trust dialog blocking the Operator in the new
AiTerm-owned run directory. Workers' project trust and the Operator's existing tool/gate contract
remain unchanged.

## Approach

The isolated Claude 2.1.312 terminal probe reproduces the trust dialog in a newly created run
directory. Every broadcast creates a different directory outside a repository, so trusting a
previous run does not cover it. Claude documents the exact-folder `hasTrustDialogAccepted` record
in its global JSON as the supported persisted trust mechanism:
https://code.claude.com/docs/en/permissions#what-runs-before-you-trust-a-folder

During OperatorCommand.prepare, after creating its private run folder, merge that folder's
physical path (`realpath`, retaining macOS `/private`) into the resolved Claude profile's global JSON.
Skip the lock and write when the exact folder is already trusted. Use ClaudeConfig.globalJSON for
the default and custom configuration directory. Hold Claude's `.claude.json.lock` directory
while reading and writing, with bounded waiting and no stale-lock takeover. Preserve unknown
fields and symlinks, make a one-time backup through UserConfigFile, and use OperatorCommand.writePrivate
on UserConfigFile.target to write atomically with 0600 permissions. Refuse malformed configuration
rather than replacing it. Preparation fails
before a window opens if trust cannot be recorded. Fresh launch and reopening pass the same
resolved ClaudeConfig through to preparation. Do not bypass tool permissions or answer terminal
prompts.

## Files

- Modify app/Sources/AiTermCore/Operators/OperatorCommand.swift: scoped trust preparation.
- Modify app/Sources/AiTerm/Operators/OperatorController.swift and
  OperatorController+Controls.swift: pass the resolved Claude configuration on start and reopen.
- Modify app/Tests/AiTermCoreTests/Operators/OperatorCommandTests.swift: regression and real-file
  safety alternatives, including custom config, malformed data, symlinks and locking.
- Modify app/Tests/AiTermTests/Operators/OperatorControllerTests.swift if needed to prove the
  controller passes its selected configuration.
- Modify app/Tests/AiTermTests/Operators/RunControlsTests.swift and OperatorFakes.swift to prove
  reopening with that same profile, including the conversation fixture location.
- Modify docs/operators.md: document the owned-folder startup behavior.
- Modify docs/architecture.md: record the narrow automatic global-state write and its owner.

## Proof

Add a failing preparation regression before changing implementation. Run the focused Swift
suites with scripts/test.sh, then the affected gate. Re-run the isolated interactive Claude
probe with a trust file produced by the implementation to show startup clears the original
dialog. Keep the personal configuration and running app untouched. Have the other vendor
review the change and triage findings before handing it back.

## To-dos

- [x] Prove the preparation regression fails before the fix.
- [x] Record scoped trust safely and wire start/reopen to the selected profile.
- [x] Prove file safety and controller wiring, then re-run the terminal repro and affected gate.
- [x] Review and triage the finished change.

## Evidence

- The initial preparation regression failed because no global trust file existed.
- The focused Operator command, controller and controls suites pass: 114 tests. Profile fixtures
  use explicit home-relative and absolute paths to keep every write inside their scratch homes.
- A standalone probe linked the compiled AiTermCore object, called OperatorCommand.prepare for a
  fresh run in a scratch home and profile, then ran its generated command in a real PTY. Claude
  2.1.312 reached its input screen without a trust dialog, and the profile contained the exact
  physical folder's trust entry. No initial prompt or model turn was requested. The scratch
  profile and executable were removed afterwards.
- Plan review: four Minor findings, resolved by the already-trusted fast path, private-write
  assertions, realpath and architecture documentation. Refusing an unsafe config update remains
  deliberate: startup reports the error instead of silently opening another blocked terminal.
- Finished-change review: no findings. Its remaining live-startup proof request is covered by the
  compiled probe above.
- Final `scripts/test.sh` affected gate: passed, including 3,789 tests across core, app, UI and
  the separate snapshot pass. The runner reports three existing known issues as expected.
