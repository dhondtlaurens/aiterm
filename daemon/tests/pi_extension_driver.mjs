// Loads the PI extension into a fake PI and prints, per phase, what it would have posted.
// `test_pi_extension.py` runs it and asserts on the output. pi-subagents loads every extension
// into each child session, in the same process, so there are two activations sharing one bus.
import { EventEmitter } from "node:events";

let posts = [];
globalThis.fetch = async (_url, init) => {
	posts.push(JSON.parse(init.body));
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
await phase("background", async () => {
	bus.emit("subagents:started", { id: "a1", type: "Explore", description: "x" });
	bus.emit("subagents:started", { id: "a2", type: "Explore", description: "y" });
	bus.emit("subagents:started", { type: "Explore" });
	await child("agent_settled", childCtx);
	await root("agent_settled", rootCtx);
	bus.emit("subagents:completed", { id: "a1" });
	bus.emit("subagents:failed", { id: "a2" });
});
// A child that outlives its session's shutdown (a reload, say) still reports while PI keeps the ctx.
await phase("after_shutdown", async () => {
	await root("session_shutdown", rootCtx, { reason: "reload" });
	bus.emit("subagents:completed", { id: "a5" });
});
await phase("shutdown", async () => {
	await root("session_shutdown", rootCtx, { reason: "quit" });
	rootCtx.invalidate();
	bus.emit("subagents:completed", { id: "a3" });
});
const staleCtx = context("stale", true);
await root("session_start", staleCtx);
staleCtx.invalidate();
await phase("stale", async () => {
	bus.emit("subagents:started", { id: "a4" });
});

process.stdout.write(JSON.stringify(phases));
