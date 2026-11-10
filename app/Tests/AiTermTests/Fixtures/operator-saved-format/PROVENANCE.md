# The saved format after its one change

`state.json` is the frozen broadcast of `../operator-current/state.json`, loaded and saved by the
product code of plan 2026-11-10's phase 4 (to-do 4f), after three of its tasks' publications were given
a problem through the product's writers (`TaskPublication.setProblem(_:kind:)`):

- SHOP-2: "its end changed to merge; call finish_task to merge it", a hold for the Operator;
- SHOP-3: "The pipeline failed.", a failure that needs you;
- SHOP-4: the Merge slice being off, a permanent refusal.

Each problem is saved with its kind beside it, `problemKind`: the one key that phase adds to the saved
format. It was captured once, on 2026-11-10, by running
`OperatorCurrentContractTests.theSavedFormatSavesAsItsFixtureAndBackToItsOwnBytes` with no fixture
here and copying what it saved. The values are the frozen broadcast's synthetic ones.

There is no update mode. The test builds the same state again and compares the bytes, then loads this
file and saves it back to its own bytes; `aSaveWithoutTheKindReadsEachProblemByItsWording` takes the
kinds out of it to stand for a save from before the change. The frozen broadcast stays untouched as the
migration input.
