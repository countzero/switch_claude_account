// omp extension: serve the `anthropic` provider from Claude Code's own
// `.credentials.json`, so `sca switch` and `sca monitor` switch omp too.
//
// Read-only by design. A refresh rotates the refresh token and invalidates the
// old one, and Claude Code, sca and opencode-claude-auth can already rotate it
// uncoordinated; only Claude Code serializes against itself. So this never
// calls the token endpoint and never hands omp the real refresh token. An
// expired file is renewed by running `claude -p` once, which refreshes under
// Claude Code's cross-process lock. The omp behavior this relies on is
// `docs/claude-code-internals.md` → *omp (oh-my-pi)*.

import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface FileToken {
	access: string;
	expires: number;
}

export interface OAuthCredential {
	access: string;
	refresh: string;
	expires: number;
	[key: string]: unknown;
}

export interface CredentialPool {
	set(provider: string, credential: OAuthCredential & { type: "oauth" }): unknown;
	entries(provider: string): Array<{ id?: unknown; credential?: { access?: unknown } }>;
}

export interface ExtensionApi {
	registerProvider(id: string, definition: unknown): void;
	on(event: string, handler: (event: any, ctx: any) => unknown): void;
}

export interface Deps {
	credentialsPath: string;
	readFile(path: string): string;
	now(): number;
	runClaude(): Promise<void>;
	warn(message: string): void;
}

export const PROVIDER = "anthropic";

// Stands in for the refresh token in omp's store, which omp only ever passes
// back to refreshToken below.
export const EXTERNAL_REFRESH = "external";

// omp refreshes a row once `now + 60 s >= expires`; a file token inside that
// margin would be refreshed again on the very next request.
export const FRESHNESS_MARGIN_MS = 60_000;

// Same flags and budget as sca's own activator (`$Script:ActivatorModel` and
// its neighbors): --safe-mode keeps OAuth but loads no CLAUDE.md, MCP or hooks
// from whatever directory omp runs in.
export const CLAUDE_ARGS = ["-p", "Hi", "--safe-mode", "--model", "haiku", "--no-session-persistence"];
export const CLAUDE_TIMEOUT_MS = 90_000;

// None of these may match omp's permanent-disable patterns (invalid_grant,
// revoked, "refresh token expired", an HTTP 401/403): a match disables the row
// for good, anything else only blocks it for 5 minutes.
export const MESSAGE_CLAUDE_MISSING =
	"Claude Code's login has lapsed and the claude CLI is not on PATH to renew it. Start Claude Code or run 'sca usage'.";
export const MESSAGE_NOT_RENEWED =
	"Claude Code's login has lapsed and 'claude -p' did not renew it. Start Claude Code or run 'sca usage'.";
export const MESSAGE_NO_LOGIN = "No Claude Code login found in .credentials.json. Log in with Claude Code or run 'sca switch'.";

export function resolveCredentialsPath(env: Record<string, string | undefined>, home: string): string {
	return join(env.CLAUDE_CONFIG_DIR || join(home, ".claude"), ".credentials.json");
}

export function parseClaudeOauth(text: string): FileToken | null {
	const oauth = JSON.parse(text)?.claudeAiOauth;
	if (typeof oauth?.accessToken !== "string" || typeof oauth?.expiresAt !== "number") return null;
	return { access: oauth.accessToken, expires: oauth.expiresAt };
}

// Falls back to the last good read, because a read can land inside sca's
// atomic replace on Windows and fail with a sharing violation.
export function createTokenSource(deps: Pick<Deps, "credentialsPath" | "readFile">): () => FileToken | null {
	let lastGood: FileToken | null = null;
	return () => {
		try {
			const token = parseClaudeOauth(deps.readFile(deps.credentialsPath));
			if (token) lastGood = token;
		} catch {
			// Keep lastGood.
		}
		return lastGood;
	};
}

export function createSingleFlight(run: () => Promise<void>): () => Promise<void> {
	let inFlight: Promise<void> | null = null;
	return () => {
		inFlight ??= run().finally(() => {
			inFlight = null;
		});
		return inFlight;
	};
}

export function isFresh(token: FileToken | null, now: number): token is FileToken {
	return token !== null && token.expires - now > FRESHNESS_MARGIN_MS;
}

function toCredential(token: FileToken): OAuthCredential & { type: "oauth" } {
	return { type: "oauth", access: token.access, refresh: EXTERNAL_REFRESH, expires: token.expires };
}

export function createExtension(deps: Deps): (pi: ExtensionApi) => void {
	return (pi) => {
		const readToken = createTokenSource(deps);
		const renew = createSingleFlight(deps.runClaude);
		let pool: CredentialPool | undefined;
		let seeding = false;

		function poolHoldsOnly(access: string): boolean {
			try {
				const rows = pool!.entries(PROVIDER);
				return rows.length === 1 && rows[0]?.credential?.access === access;
			} catch {
				return false;
			}
		}

		// Exactly one row, with no email or accountId: a second row would put
		// omp's usage-ranked rotation in charge instead of sca. `set` keeps
		// every row it replaces as a disabled one, so an unchanged login is
		// not written again.
		async function seed(): Promise<void> {
			const token = readToken();
			if (!pool || !token || seeding || poolHoldsOnly(token.access)) return;
			seeding = true;
			try {
				await pool.set(PROVIDER, toCredential(token));
			} catch (error) {
				deps.warn(`sca omp extension: could not store the Claude Code login (${String(error)})`);
			} finally {
				seeding = false;
			}
		}

		function needsSeed(storedAccess: string, fileAccess: string): boolean {
			if (!pool) return false;
			if (storedAccess !== fileAccess) return true;
			try {
				return pool.entries(PROVIDER).length !== 1;
			} catch {
				return false;
			}
		}

		pi.registerProvider(PROVIDER, {
			oauth: {
				name: "Claude Code credentials (sca)",

				async login(): Promise<OAuthCredential> {
					const token = readToken();
					if (!token) throw new Error(MESSAGE_NO_LOGIN);
					return toCredential(token);
				},

				async refreshToken(creds: OAuthCredential): Promise<OAuthCredential> {
					let token = readToken();
					if (!isFresh(token, deps.now())) {
						try {
							await renew();
						} catch (error: any) {
							throw new Error(error?.code === "ENOENT" ? MESSAGE_CLAUDE_MISSING : MESSAGE_NOT_RENEWED);
						}
						token = readToken();
					}
					if (!isFresh(token, deps.now())) throw new Error(MESSAGE_NOT_RENEWED);
					return { ...creds, access: token.access, refresh: EXTERNAL_REFRESH, expires: token.expires };
				},

				// Synchronous and called on every request. Usage polling and
				// model discovery read the stored row instead, so a switch seen
				// here is written back for them.
				getApiKey(creds: OAuthCredential): string {
					const token = readToken();
					if (!token) return creds.access;
					if (needsSeed(creds.access, token.access)) void seed();
					return token.access;
				},
			},
		});

		pi.on("session_start", async (_event, ctx) => {
			const candidate = ctx?.modelRegistry?.authStorage?.credentials;
			if (typeof candidate?.set !== "function" || typeof candidate?.entries !== "function") {
				deps.warn("sca omp extension: this omp build exposes no credential pool; the Claude Code login is not stored");
				return;
			}
			pool = candidate;
			await seed();
		});

		pi.on("credential_disabled", async (event) => {
			if (event?.provider === PROVIDER) await seed();
		});
	};
}

function runClaude(): Promise<void> {
	return new Promise((resolve, reject) => {
		execFile("claude", CLAUDE_ARGS, { timeout: CLAUDE_TIMEOUT_MS, windowsHide: true }, (error) => {
			if (error) reject(error);
			else resolve();
		});
	});
}

export default function claudeCredentials(pi: ExtensionApi): void {
	createExtension({
		credentialsPath: resolveCredentialsPath(process.env, homedir()),
		readFile: (path) => readFileSync(path, "utf8"),
		now: () => Date.now(),
		runClaude,
		warn: (message) => console.warn(message),
	})(pi);
}
