"""finish_task's schema, as the operator reads it: what it does for each end, and what it answers."""

from typing import Any

from aitermd import operator_mcp


def finish_task() -> dict[str, Any]:
    return next(tool for tool in operator_mcp.TOOLS if tool["name"] == "finish_task")


def test_finish_task_is_listed_once() -> None:
    assert [tool["name"] for tool in operator_mcp.TOOLS].count("finish_task") == 1


def test_finish_task_takes_one_task() -> None:
    schema = finish_task()["inputSchema"]
    assert schema["required"] == ["task"]
    # The Oracle's verdict on a merge's conditions may answer pending: the call again names it.
    assert "challengeId" in schema["properties"]
    assert schema["properties"]["task"]["type"] == "string"
    assert schema.get("additionalProperties") is False


def test_finish_task_says_what_each_end_does_and_what_it_answers() -> None:
    description = finish_task()["description"]
    for phrase in ("draft MR", "merge", "commit", "waitingToMerge", "blocked", "accepted commit", "calling again resumes",
                   "protected"):
        assert phrase in description, phrase


def test_finish_task_names_every_reply_and_what_it_carries() -> None:
    description = finish_task()["description"]
    for phrase in ("published", "waitingToMerge", "blocked", "refused", "failed", "reason", "mergeRequest", "pushedSHA",
                   "merged", "mergedSHA"):
        assert phrase in description, phrase


def test_finish_task_says_how_a_merge_waits_and_when_to_call_again() -> None:
    description = finish_task()["description"]
    for phrase in ("pipelines", "30 seconds", "hour", "may have landed", "taken over", "handed back", "parent"):
        assert phrase in description, phrase


def test_finish_task_says_what_refuses_it_and_what_it_never_does() -> None:
    description = finish_task()["description"]
    for phrase in ("paused", "stopped", "offline", "taken over", "moved past", "accepted again", "cannot say", "default branch",
                   "never deploys", "force-pushes"):
        assert phrase in description, phrase


def test_finish_task_says_what_the_merge_slice_allows_and_what_a_local_merge_leaves() -> None:
    description = finish_task()["description"]
    for phrase in ("Merge slice", "mergeLocal", "never pushes", "uncommitted", "Push", "review threads", "resolved",
                   "the Oracle's yes", "marks it ready"):
        assert phrase in description, phrase
    # A pending yes is called again with its challengeId: told once, in that property.
    assert "pending" in finish_task()["inputSchema"]["properties"]["challengeId"]["description"]
