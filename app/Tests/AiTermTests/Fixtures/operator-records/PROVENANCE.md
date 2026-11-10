# Operator records as they save

`sparse.json` and `full.json` are a run and one of its tasks as the workspace file holds them, written
once by the unmodified product sources at `0c6c5297` (2026-11-10), before the second refactor round
changed how these records are coded. The values are synthetic: no broadcast, conversation, credential
or repository of anyone's.

`sparse` has only what the initialisers require, so it shows which fields are written at their
default and which are left out. `full` sets every stored field of every Operator record to something
other than its default: 44 keys on the run, 37 on the task, 23 on its publication, 17 on a question,
16 on a challenge. `OperatorRecords` in `Operators/OperatorCurrentContractTests.swift` builds both;
the test saves each and compares the bytes, then loads the file and compares the values.

Phase 4 of that round added one key by decision, the plan's one saved-format change: `problemKind`, the kind
of the publication's problem, now in `full` beside its `problem` (24 keys on its publication). `sparse` did not
change.

There is no update mode. A field added to a record is added to `full` and to its builder by a
decision about the saved format; a difference found any other way is a regression in the coding.
The frozen broadcast beside this folder (`operator-current/`) is older and stays untouched.
