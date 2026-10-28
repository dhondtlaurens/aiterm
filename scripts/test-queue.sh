# Sourced after selection, so a docs-only run never enters the machine-wide queue.
# Re-exec with an inherited BSD lock: a killed shell cannot release its live suite's slot.
WAITED_FOR_LOCK="${AITERM_TEST_WAITED:-0}"
if [[ -z "${AITERM_TEST_LOCK_HELD:-}" ]]; then
    exec "$PYTHON" "$ROOT/scripts/test-queue.py" "${AITERM_TEST_LOCK:-/tmp/aiterm-test.lock}" "$SUITE" "$ROOT" \
        "$ROOT/scripts/test.sh" "${TEST_RUN_ARGS[@]}"
fi
