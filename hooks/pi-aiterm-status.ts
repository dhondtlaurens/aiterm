// AiTerm PI extension schema: 3
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const endpoint = "http://127.0.0.1:47821/hook/pi";

async function report(event: string, ctx: ExtensionContext, overrides: Record<string, unknown> = {}) {
	try {
		// pi-subagents loads every extension into each child session, in this process and so with
		// this tab's ITERM_SESSION_ID. A child has no UI; only the session the user drives reports.
		if (!ctx.hasUI) return;
		const usage = ctx.getContextUsage();
		const testId = process.env.AITERM_INTEGRATION_TEST;
		const body = {
			hook_event_name: event,
			session_id: ctx.sessionManager.getSessionId(),
			cwd: ctx.cwd,
			model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : null,
			reasoning: ctx.thinkingLevel ?? null,
			context_percent: usage?.percent ?? null,
			...(testId ? { _aiterm_test_id: testId } : {}),
			...overrides,
		};
		const response = await fetch(endpoint, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				"X-AiTerm-Hook": "1",
				...(process.env.ITERM_SESSION_ID ? { "X-AiTerm-iTerm-Session": process.env.ITERM_SESSION_ID } : {}),
			},
			body: JSON.stringify(body),
			signal: AbortSignal.timeout(1500),
		});
		if (testId) {
			const acknowledgement = await response.json() as { ok?: boolean; testId?: string };
			if (acknowledgement.ok && acknowledgement.testId === testId) {
				process.stderr.write(`AITERM_INTEGRATION_TEST_OK=${testId}\n`);
			}
		}
	} catch {
		// Status reporting must never interrupt PI — nor must a ctx gone stale.
	}
}

export default function (pi: ExtensionAPI) {
	// Background subagents outlive the turn that started them. pi-subagents announces them on the
	// shared bus, whose handlers get no ctx: report them against the last session that started.
	// Kept past `session_shutdown`, so a child ending then is still reported rather than left
	// running in the sidebar; a ctx PI has invalidated throws, and `report` drops the post.
	let session: ExtensionContext | undefined;
	const relay = (event: string) => (data: unknown) => {
		const id = (data as { id?: unknown } | null)?.id;
		if (session && typeof id === "string" && id) void report(event, session, { agent_id: id });
	};
	pi.events.on("subagents:started", relay("subagent_start"));
	pi.events.on("subagents:completed", relay("subagent_stop"));
	pi.events.on("subagents:failed", relay("subagent_stop"));

	// The reason tells the daemon whether a new conversation began (it forgets the old one's
	// subagents) or the extensions merely reloaded.
	pi.on("session_start", (event, ctx) => { session = ctx; return report("session_start", ctx, { reason: event.reason }); });
	pi.on("agent_start", (_event, ctx) => report("agent_start", ctx));
	pi.on("agent_settled", (_event, ctx) => report("agent_settled", ctx));
	pi.on("ui_prompt_start", (_event, ctx) => report("ui_prompt_start", ctx));
	pi.on("ui_prompt_end", (_event, ctx) => report("ui_prompt_end", ctx));
	pi.on("model_select", (event, ctx) => report("model_select", ctx, {
		model: `${event.model.provider}/${event.model.id}`,
	}));
	pi.on("thinking_level_select", (event, ctx) => report("thinking_level_select", ctx, {
		reasoning: event.level,
	}));
}
