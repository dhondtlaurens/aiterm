# Current Operator brief baseline

Captured from unmodified product sources at `f152f6e9`. The fixtures cover all features enabled,
the minimal setup, local merge and the current structured real-agent eval setup. The always-on
`OperatorCommandTests` compare the complete model-facing briefs without launching agents.

Changes to these bytes are deliberate changes to the model's execution contract, not a routine
step in moving or consolidating code. The separate opt-in eval compares model behavior; it does
not replace these always-on checks.
