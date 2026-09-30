import assert from "node:assert/strict";
import { join } from "node:path";
import { describe, it } from "node:test";

import {
	CLAUDE_ARGS,
	createExtension,
	createSingleFlight,
	EXTERNAL_REFRESH,
	MESSAGE_CLAUDE_MISSING,
	MESSAGE_NOT_RENEWED,
	PROVIDER,
	resolveCredentialsPath,
	type Deps,
	type OAuthCredential,
} from "./claude_credentials.ts";

const NOW = 1_800_000_000_000;
const HOUR = 3_600_000;
const PATH = join("sandbox", ".credentials.json");

// omp's permanent-disable patterns; a thrown message matching one would
// disable the row for good.
const DISABLE_PATTERN = /invalid_grant|invalid_token|unauthorized_client|revoked|refresh token expired|\b40[13]\b|unauthorized|forbidden/i;

function fileText(access: string, expires: number): string {
	return JSON.stringify({ claudeAiOauth: { accessToken: access, refreshToken: "fake-refresh", expiresAt: expires } });
}

class FakePool {
	rows: Array<Record<string, unknown>> = [];
	sets = 0;
	set(provider: string, credential: Record<string, unknown>): void {
		assert.equal(provider, PROVIDER);
		this.sets += 1;
		this.rows = [credential];
	}
	// omp's shape: enabled rows only, each wrapping its credential.
	entries(provider: string): Array<{ id: number; credential: any }> {
		assert.equal(provider, PROVIDER);
		return this.rows.map((credential, id) => ({ id, credential }));
	}
}

function harness(overrides: Partial<Deps> = {}) {
	const state = { file: fileText("fake-a", NOW + 2 * HOUR) as string | Error, now: NOW, claudeRuns: 0, warnings: [] as string[] };
	const handlers = new Map<string, (event: any, ctx: any) => unknown>();
	let provider: any;
	const pool = new FakePool();

	const deps: Deps = {
		credentialsPath: PATH,
		readFile: (path) => {
			assert.equal(path, PATH);
			if (state.file instanceof Error) throw state.file;
			return state.file;
		},
		now: () => state.now,
		runClaude: async () => {
			state.claudeRuns += 1;
		},
		warn: (message) => state.warnings.push(message),
		...overrides,
	};

	createExtension(deps)({
		registerProvider(id, definition: any) {
			assert.equal(id, PROVIDER);
			provider = definition.oauth;
		},
		on(event, handler) {
			handlers.set(event, handler);
		},
	});

	return {
		state,
		pool,
		get oauth() {
			return provider;
		},
		startSession: () => handlers.get("session_start")!({}, { modelRegistry: { authStorage: { credentials: pool } } }),
		startSessionWith: (ctx: unknown) => handlers.get("session_start")!({}, ctx),
		disable: (name: string) => handlers.get("credential_disabled")!({ provider: name, disabledCause: "test" }),
	};
}

const stored = (access: string, expires = NOW + HOUR): OAuthCredential => ({ access, refresh: EXTERNAL_REFRESH, expires });
const settle = () => new Promise((resolve) => setImmediate(resolve));

describe("resolveCredentialsPath", () => {
	it("prefers CLAUDE_CONFIG_DIR", () => {
		assert.equal(resolveCredentialsPath({ CLAUDE_CONFIG_DIR: "cfg" }, "home"), join("cfg", ".credentials.json"));
	});

	it("falls back to ~/.claude, also for an empty CLAUDE_CONFIG_DIR", () => {
		assert.equal(resolveCredentialsPath({}, "home"), join("home", ".claude", ".credentials.json"));
		assert.equal(resolveCredentialsPath({ CLAUDE_CONFIG_DIR: "" }, "home"), join("home", ".claude", ".credentials.json"));
	});
});

describe("session_start", () => {
	it("stores exactly one row without the real refresh token or an identity", async () => {
		const h = harness();
		await h.startSession();
		assert.deepEqual(h.pool.rows, [{ type: "oauth", access: "fake-a", refresh: EXTERNAL_REFRESH, expires: NOW + 2 * HOUR }]);
	});

	it("does not write again when the pool already holds the file's token", async () => {
		const h = harness();
		h.pool.rows = [{ type: "oauth", access: "fake-a", refresh: EXTERNAL_REFRESH, expires: NOW + 2 * HOUR }];
		await h.startSession();
		await h.disable(PROVIDER);
		assert.equal(h.pool.sets, 0);
	});

	it("replaces rows another login added", async () => {
		const h = harness();
		h.pool.rows = [{ access: "x" }, { access: "y" }];
		await h.startSession();
		assert.equal(h.pool.rows.length, 1);
	});

	it("warns and never re-seeds when the build exposes no pool", async () => {
		const h = harness();
		await h.startSessionWith({ modelRegistry: {} });
		assert.equal(h.state.warnings.length, 1);
		h.state.file = fileText("fake-b", NOW + 3 * HOUR);
		assert.equal(h.oauth.getApiKey(stored("fake-a")), "fake-b");
		await settle();
		assert.equal(h.pool.sets, 0);
	});
});

describe("getApiKey", () => {
	it("returns the file's token, not the stored one", () => {
		const h = harness();
		assert.equal(h.oauth.getApiKey(stored("fake-old")), "fake-a");
	});

	it("follows a switch on the next call", () => {
		const h = harness();
		assert.equal(h.oauth.getApiKey(stored("fake-a")), "fake-a");
		h.state.file = fileText("fake-b", NOW + 3 * HOUR);
		assert.equal(h.oauth.getApiKey(stored("fake-a")), "fake-b");
	});

	it("re-seeds the stored row after a switch so usage polling follows", async () => {
		const h = harness();
		await h.startSession();
		h.state.file = fileText("fake-b", NOW + 3 * HOUR);
		h.oauth.getApiKey(stored("fake-a"));
		await settle();
		assert.deepEqual(h.pool.rows, [{ type: "oauth", access: "fake-b", refresh: EXTERNAL_REFRESH, expires: NOW + 3 * HOUR }]);
	});

	it("does not re-seed when the stored row already matches", async () => {
		const h = harness();
		await h.startSession();
		const before = h.pool.sets;
		h.oauth.getApiKey(stored("fake-a"));
		await settle();
		assert.equal(h.pool.sets, before);
	});

	it("re-seeds when a second row appeared", async () => {
		const h = harness();
		await h.startSession();
		h.pool.rows.push({ access: "fake-login" });
		h.oauth.getApiKey(stored("fake-a"));
		await settle();
		assert.equal(h.pool.rows.length, 1);
	});

	it("keeps the last good token when a read fails mid-rename", () => {
		const h = harness();
		h.oauth.getApiKey(stored("fake-a"));
		h.state.file = Object.assign(new Error("EBUSY"), { code: "EBUSY" });
		assert.equal(h.oauth.getApiKey(stored("fake-a")), "fake-a");
		h.state.file = '{"claudeAiOauth":{"accessT';
		assert.equal(h.oauth.getApiKey(stored("fake-a")), "fake-a");
	});

	it("falls back to the stored token when the file was never readable", () => {
		const h = harness();
		h.state.file = new Error("ENOENT");
		assert.equal(h.oauth.getApiKey(stored("fake-stored")), "fake-stored");
	});

	it("logs a failing store and does not throw", async () => {
		const h = harness();
		await h.startSession();
		h.pool.set = () => {
			throw new Error("db locked");
		};
		h.state.file = fileText("fake-b", NOW + 3 * HOUR);
		assert.equal(h.oauth.getApiKey(stored("fake-a")), "fake-b");
		await settle();
		assert.match(h.state.warnings.join("\n"), /db locked/);
	});
});

describe("refreshToken", () => {
	it("returns a fresh file token with its real expiry and no claude run", async () => {
		const h = harness();
		const result = await h.oauth.refreshToken({ ...stored("fake-old", 0), email: "kept" });
		assert.deepEqual(result, { access: "fake-a", refresh: EXTERNAL_REFRESH, expires: NOW + 2 * HOUR, email: "kept" });
		assert.equal(h.state.claudeRuns, 0);
	});

	it("runs claude once when the file token is inside the 60 s margin, then re-reads", async () => {
		const h = harness({
			runClaude: async () => {
				h.state.claudeRuns += 1;
				h.state.file = fileText("fake-renewed", NOW + 8 * HOUR);
			},
		});
		h.state.file = fileText("fake-a", NOW + 30_000);
		const result = await h.oauth.refreshToken(stored("fake-a", 0));
		assert.equal(result.access, "fake-renewed");
		assert.equal(result.expires, NOW + 8 * HOUR);
		assert.equal(h.state.claudeRuns, 1);
	});

	it("shares one claude run between concurrent refreshes", async () => {
		let release!: () => void;
		const h = harness({
			runClaude: () =>
				new Promise<void>((resolve) => {
					h.state.claudeRuns += 1;
					release = () => {
						h.state.file = fileText("fake-renewed", NOW + 8 * HOUR);
						resolve();
					};
				}),
		});
		h.state.file = fileText("fake-a", NOW - HOUR);
		const both = Promise.all([h.oauth.refreshToken(stored("fake-a", 0)), h.oauth.refreshToken(stored("fake-a", 0))]);
		await settle();
		release();
		const results = await both;
		assert.equal(h.state.claudeRuns, 1);
		assert.deepEqual(
			results.map((r: OAuthCredential) => r.access),
			["fake-renewed", "fake-renewed"],
		);
	});

	it("throws a non-disabling message when claude did not renew the token", async () => {
		const h = harness();
		h.state.file = fileText("fake-a", NOW - HOUR);
		await assert.rejects(h.oauth.refreshToken(stored("fake-a", 0)), (error: Error) => {
			assert.equal(error.message, MESSAGE_NOT_RENEWED);
			return true;
		});
		assert.equal(h.state.claudeRuns, 1);
	});

	it("throws a non-disabling message when claude fails", async () => {
		const h = harness({ runClaude: async () => Promise.reject(Object.assign(new Error("exit 1"), { code: 1 })) });
		h.state.file = fileText("fake-a", NOW - HOUR);
		await assert.rejects(h.oauth.refreshToken(stored("fake-a", 0)), { message: MESSAGE_NOT_RENEWED });
	});

	it("says so when claude is not installed", async () => {
		const h = harness({ runClaude: async () => Promise.reject(Object.assign(new Error("spawn claude ENOENT"), { code: "ENOENT" })) });
		h.state.file = fileText("fake-a", NOW - HOUR);
		await assert.rejects(h.oauth.refreshToken(stored("fake-a", 0)), { message: MESSAGE_CLAUDE_MISSING });
	});

	it("never throws a message omp would disable the row for", () => {
		for (const message of [MESSAGE_CLAUDE_MISSING, MESSAGE_NOT_RENEWED]) {
			assert.doesNotMatch(message, DISABLE_PATTERN);
		}
	});
});

describe("credential_disabled", () => {
	it("re-seeds the anthropic row once omp dropped it", async () => {
		const h = harness();
		await h.startSession();
		h.pool.rows = [];
		await h.disable(PROVIDER);
		assert.equal(h.pool.rows.length, 1);
	});

	it("ignores other providers", async () => {
		const h = harness();
		await h.startSession();
		h.pool.rows = [];
		await h.disable("openai");
		assert.equal(h.pool.rows.length, 0);
	});
});

describe("login", () => {
	it("returns the file token in the stored shape", async () => {
		const h = harness();
		assert.deepEqual(await h.oauth.login(), { type: "oauth", access: "fake-a", refresh: EXTERNAL_REFRESH, expires: NOW + 2 * HOUR });
	});
});

describe("createSingleFlight", () => {
	it("allows a new run after the previous one settled, even on failure", async () => {
		let runs = 0;
		const run = createSingleFlight(async () => {
			runs += 1;
			throw new Error("boom");
		});
		await assert.rejects(run());
		await assert.rejects(run());
		assert.equal(runs, 2);
	});
});

describe("CLAUDE_ARGS", () => {
	it("keeps --safe-mode so no project config loads beside omp", () => {
		assert.ok(CLAUDE_ARGS.includes("--safe-mode"));
	});
});
