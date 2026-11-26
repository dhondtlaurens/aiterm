"""Each agent's own knowledge, in one module per agent: `claude`, `codex` and `pi` turn that agent's
hook posts, files and screens into the status engine's evidence. This package routes the hook
server's posts to their agent's parser."""
from __future__ import annotations

from ..hook_events import HookParser, StatusLineParser
from ..models import HARNESSES, AgentKind
from . import claude, codex, pi

# Each harness's parsers. A route in models.HARNESSES without its parser here fails at import.
_HOOK_PARSER: dict[AgentKind, HookParser] = {
    "claude": claude.parse_claude_hook, "codex": codex.parse_codex_hook, "pi": pi.parse_pi_hook,
}
_STATUSLINE_PARSER: dict[AgentKind, StatusLineParser] = {"claude": claude.parse_claude_statusline}

# The agent hook routes, each with the parser for its agent's payload.
HOOK_PARSERS: dict[str, HookParser] = {h.hook_route: _HOOK_PARSER[h.agent] for h in HARNESSES}
# Each status-line shim's route, with the agent it reports on and the parser for its payload.
STATUSLINE_PARSERS: dict[str, tuple[AgentKind, StatusLineParser]] = {
    h.statusline_route: (h.agent, _STATUSLINE_PARSER[h.agent]) for h in HARNESSES if h.statusline_route}
# Account usage a hook post carries, by route: PI's extension relays the rate limits its providers
# receive. Each parser returns the vendor whose footer the post fills, and its usage.
USAGE_PARSERS = {"/hook/pi": pi.parse_pi_usage}
