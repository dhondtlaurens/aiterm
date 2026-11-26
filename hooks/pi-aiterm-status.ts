// AiTerm PI extension schema: 7
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// The port is AiTermPaths.hookPort, which PiDriver writes in place of the placeholder.
const endpoint = "http://127.0.0.1:__AITERM_HOOK_PORT__/hook/pi";

// PI may wait on what a handler returns, and reporting must never hold PI up: a daemon that accepts
// the connection and stalls would cost every turn the request's whole timeout. Handlers hand back
// nothing, except under the driver test, which has to see the acknowledgement before PI exits.
const settle = (posted: Promise<void>) => process.env.AITERM_INTEGRATION_TEST ? posted : undefined;

// Posts leave one at a time, in the order PI raised them. Each is its own request, so sent at once
// they could reach the daemon out of order -- an Escape right after a turn starts would land its
// `agent_settled` before that `turn_start`, and leave the row spinning. A post that fails or times
// out still lets the next one go.
let queue: Promise<void> = Promise.resolve();

function report(event: string, ctx: ExtensionContext, overrides: Record<string, unknown> = {}): Promise<void> {
	let body: Record<string, unknown>;
	try {
		// A session another extension runs inside this process (a subagent, say) loads this extension
		// too, with this tab's ITERM_SESSION_ID. It has no UI; only the session the user drives reports.
		if (!ctx.hasUI) return Promise.resolve();
		// Read now, while PI raises the event: by the time the post leaves, the ctx may have moved on.
		const usage = ctx.getContextUsage();
		const testId = process.env.AITERM_INTEGRATION_TEST;
		body = {
			hook_event_name: event,
			session_id: ctx.sessionManager.getSessionId(),
			cwd: ctx.cwd,
			model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : null,
			reasoning: ctx.thinkingLevel ?? null,
			context_percent: usage?.percent ?? null,
			...(testId ? { _aiterm_test_id: testId } : {}),
			...overrides,
		};
	} catch {
		// A ctx PI has invalidated throws from every getter.
		return Promise.resolve();
	}
	const posted = queue.then(() => post(body));
	queue = posted;
	return posted;
}

async function post(body: Record<string, unknown>) {
	try {
		const testId = body._aiterm_test_id;
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
		// Status reporting must never interrupt PI.
	}
}

export default function (pi: ExtensionAPI) {
	// The reason tells the daemon whether a new conversation began or the extensions merely reloaded.
	pi.on("session_start", (event, ctx) => settle(report("session_start", ctx, { reason: event.reason })));
	pi.on("agent_start", (_event, ctx) => settle(report("agent_start", ctx)));
	pi.on("agent_settled", (_event, ctx) => settle(report("agent_settled", ctx)));
	// Each turn of a run says the agent is at work, so a run whose `agent_start` the daemon could not
	// place -- PI starts its launch prompt before iTerm2 names the tab's job -- still shows working.
	pi.on("turn_start", (_event, ctx) => settle(report("turn_start", ctx)));
	pi.on("turn_end", (_event, ctx) => settle(report("turn_end", ctx)));
	pi.on("ui_prompt_start", (_event, ctx) => settle(report("ui_prompt_start", ctx)));
	pi.on("ui_prompt_end", (_event, ctx) => settle(report("ui_prompt_end", ctx)));
	// PI's Codex provider gets the ChatGPT account's limits with each response: the same quota Codex
	// spends, so they fill Codex's usage footer.
	pi.on("provider_stream_event", (event, ctx) => {
		const data = event.data as { type?: unknown; rate_limits?: unknown } | null;
		if (event.provider !== "openai-codex" || data?.type !== "codex.rate_limits" || typeof data.rate_limits !== "object" || !data.rate_limits) return;
		return settle(report("rate_limits", ctx, { vendor: "codex", rate_limits: data.rate_limits }));
	});
	pi.on("model_select", (event, ctx) => settle(report("model_select", ctx, {
		model: `${event.model.provider}/${event.model.id}`,
	})));
	pi.on("thinking_level_select", (event, ctx) => settle(report("thinking_level_select", ctx, {
		reasoning: event.level,
	})));
}
