// Loads the PI extension into a fake PI and prints, per phase, what it would have posted.
// `test_pi_extension.py` runs it and asserts on the output. pi-subagents loads every extension
// into each child session, in the same process, so there are two activations sharing one bus.
import { EventEmitter } from "node:events";

let posts = [];
let stalled = false;
// How long the fake daemon takes to answer each post, by event: a slow one must not be overtaken.
let delays = {};
globalThis.fetch = async (url, init) => {
	const body = JSON.parse(init.body);
	// Recorded as the daemon reads it: a post on a slow connection arrives late.
	if (delays[body.hook_event_name]) await new Promise((resolve) => setTimeout(resolve, delays[body.hook_event_name]));
	posts.push({ ...body, _url: url });
	// A daemon that accepts the connection and never answers.
	if (stalled) await new Promise(() => {});
	return { json: async () => ({}) };
};
const settled = () => new Promise((resolve) => setTimeout(resolve, 20));

const bus = new EventEmitter();
function activate(factory) {
	const handlers = new Map();
	factory({
		on: (name, fn) => handlers.set(name, fn),
		events: {
			on: (channel, fn) => { bus.on(channel, fn); return () => bus.off(channel, fn); },
			emit: (channel, data) => bus.emit(channel, data),
		},
	});
	return async (name, ctx, event = {}) => handlers.get(name)?.(event, ctx);
}

// PI throws from every ctx getter once its session is gone.
function context(sessionId, hasUI) {
	let stale = false;
	const live = (value) => { if (stale) throw new Error("stale ctx"); return value; };
	return {
		get hasUI() { return live(hasUI); },
		get cwd() { return live("/wt"); },
		get sessionManager() { return live({ getSessionId: () => sessionId }); },
		get model() { return live({ provider: "openai", id: "model-x" }); },
		get thinkingLevel() { return live("high"); },
		getContextUsage: () => live({ percent: 12 }),
		invalidate() { stale = true; },
	};
}

const phases = {};
async function phase(name, steps) {
	posts = [];
	await steps();
	await settled();
	phases[name] = posts;
	posts = [];
}

const { default: factory } = await import(process.argv[2]);
const root = activate(factory);
const child = activate(factory);
const rootCtx = context("root", true);
const childCtx = context("child", false);

await phase("startup", async () => {
	await root("session_start", rootCtx, { reason: "startup" });
	await root("agent_start", rootCtx);
	await child("session_start", childCtx, { reason: "startup" });
	await child("agent_start", childCtx);
});
// A subagent package's announcements on the shared bus: AiTerm follows PI's own events only.
await phase("bus", async () => {
	bus.emit("subagents:started", { id: "a1", type: "Explore", description: "x" });
	bus.emit("subagents:completed", { id: "a1" });
});
await phase("turn_end", async () => {
	const nextTurn = context("root", true);
	nextTurn.getContextUsage = () => ({ percent: 37 });
	await child("turn_end", childCtx);
	await root("turn_end", nextTurn);
});
// PI's Codex provider receives the account's limits beside every other stream event.
await phase("stream", async () => {
	const limits = { primary: { used_percent: 12, window_minutes: 10080, reset_at: 1796200613 }, secondary: null };
	await root("provider_stream_event", rootCtx, { provider: "openai-codex", data: { type: "response.created" } });
	await root("provider_stream_event", rootCtx, { provider: "openai-codex", data: { type: "codex.rate_limits", rate_limits: limits } });
	await root("provider_stream_event", rootCtx, { provider: "anthropic", data: { type: "codex.rate_limits", rate_limits: limits } });
	await child("provider_stream_event", childCtx, { provider: "openai-codex", data: { type: "codex.rate_limits", rate_limits: limits } });
});
// An Escape right after a turn starts: the turn's post is slow, and the settle must not overtake it.
await phase("in_order", async () => {
	delays = { turn_start: 60 };
	await child("turn_start", childCtx);
	await root("turn_start", rootCtx);
	await root("agent_settled", rootCtx, { aborted: true });
	await new Promise((resolve) => setTimeout(resolve, 100));
	delays = {};
});
// PI throws from every getter of a ctx it has invalidated: the post is dropped, and nothing throws.
await phase("stale", async () => {
	const staleCtx = context("stale", true);
	staleCtx.invalidate();
	await root("agent_settled", staleCtx);
});

// What a handler hands back to PI, which may wait on it: nothing, unless the driver test asked for
// the acknowledgement. Raced against a timer so a handler that does return the stalled post fails
// rather than hangs.
const returned = async (steps) => {
	const timedOut = Symbol("timed out");
	const results = [];
	for (const step of steps) {
		const outcome = await Promise.race([Promise.resolve(step()).then((value) => ({ value })), settled().then(() => timedOut)]);
		results.push(outcome === timedOut ? "pending" : outcome.value === undefined ? "nothing" : "a value");
	}
	return results;
};
stalled = true;
const handlerCtx = context("root", true);
const handlers = ["session_start", "agent_start", "agent_settled", "ui_prompt_start", "ui_prompt_end", "turn_start", "turn_end"];
phases.returned = await returned(handlers.map((name) => () => root(name, handlerCtx, { reason: "startup" })));
phases.returned.push(...await returned([
	() => root("provider_stream_event", handlerCtx, { provider: "openai-codex", data: { type: "codex.rate_limits", rate_limits: {} } }),
	() => root("model_select", handlerCtx, { model: { provider: "p", id: "m" } }),
	() => root("thinking_level_select", handlerCtx, { level: "low" }),
]));
process.env.AITERM_INTEGRATION_TEST = "t-1";
phases.returned_under_test = await returned([() => root("agent_start", handlerCtx)]);
delete process.env.AITERM_INTEGRATION_TEST;
stalled = false;

process.stdout.write(JSON.stringify(phases));
