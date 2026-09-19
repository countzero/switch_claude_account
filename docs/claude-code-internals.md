# Claude Code internals

Findings about **someone else's binary**, kept here rather than in
`switch_claude_account.ps1` because they are archaeology rather than rationale:
they describe what Anthropic ships, not why this tool is written the way it is.

**Admission rule.** A fact belongs here only if all three hold:

1. It is about an external artifact (`claude.exe`, the npm package, an
   undocumented endpoint), not about this script.
2. It carries the **version it was observed against**.
3. It has a **re-verification recipe**, so staleness is detectable by running
   something rather than by noticing.

A fact that fails any of these stays in the code, at its point of use. Measured
constants (HTTP budgets, retry policy) and the rules this tool derives from the
findings below are *not* here for that reason: a number and what measured it
must be adjacent, and a rule must be visible where it is applied.

Nothing here is a second copy. Where the code needs a rule that follows from a
finding, the code states the rule and this file states the evidence.

## Re-extraction recipe

`claude.exe` is a Bun-compiled binary with the JS source embedded, so a string
scan reaches it. From a PowerShell 7 prompt:

```powershell
$bin   = (Get-Command claude -ErrorAction Stop).Source
$bytes = [IO.File]::ReadAllBytes($bin)
$text  = [Text.Encoding]::ASCII.GetString($bytes)

$text | Select-String '/api/oauth/usage'      # usage endpoint path
$text | Select-String '/api/oauth/profile'    # profile endpoint path (function Ql)
$text | Select-String 'TOKEN_URL:"'           # base API URL + TOKEN_URL + CLIENT_ID
$text | Select-String 'lj="oauth-'            # beta header value
$text | Select-String 'anthropic-version'     # API version header
$text | Select-String 'claude-code/\$\{'      # UA version convention
```

After re-extracting, bump the constants in
`# --- Unofficial Claude Code OAuth-flow constants ---`, bump
`$Script:UsageUserAgent`, update the version stamps below, and re-run the suite.
The suite mocks `Invoke-RestMethod` by `$Uri` and checks shape only, so it will
**not** catch constants drifting out of date. Only a live `sca usage` will.

## OAuth flow

**Undocumented and unsupported by Anthropic.** Expect breakage when Anthropic
bumps the beta flag, rotates the OAuth client id, or reshapes a response body.

Originally extracted from `claude.exe` 2.1.119; `TOKEN_URL`, `CLIENT_ID` and the
beta flag re-verified unchanged against **2.1.278 on 2026-09-19**.

### Client id

The pinned client id is the **Claude.ai subscription** flow's, matching the
`user:sessions:claude_code` scope that slot files carry. The other client id in
the binary (`22422756-...`) belongs to the Console API-key flow and does not
accept our refresh tokens.

### `GET /api/oauth/usage` response

Verified against a live Team-plan call on 2026-04-24. Every branch is optional;
free-tier and API-key accounts receive `{}`.

```
five_hour        { utilization: 0..100, resets_at: <ISO-8601>|null }
seven_day        { utilization: 0..100, resets_at: <ISO-8601>|null }
seven_day_opus   null | { utilization, resets_at }
seven_day_sonnet null | { utilization, resets_at }
extra_usage      { is_enabled, monthly_limit, used_credits,
                   utilization, currency }   (all nullable)
```

Plus internal/unreleased buckets, null for external subscriptions and rendered
in no view (they round-trip only via `-Json`): `seven_day_oauth_apps`,
`seven_day_cowork`, `seven_day_omelette`, `iguana_necktie`,
`omelette_promotional`.

Only `five_hour` (Session) and `seven_day` (Week) are rendered, matching Claude
Code's own `/usage` bars.

### `GET /api/oauth/profile` response

Extracted from `claude.exe` 2.1.276. The client validates the body with a Zod
schema before use, which is the authoritative statement of the shape. Locate it
via `Select-String 'api/oauth/profile'`, then the `safeParse` call one function
above:

```
et({ account:      et({ uuid: ce(), email: ce() }).passthrough(),
     organization: et({ uuid: ce() }).passthrough() }).passthrough()
```

So `account.uuid`, `account.email` and `organization.uuid` are required strings.
Everything else (`account.display_name`, `account.full_name`,
`organization.billing_type`, `organization.rate_limit_tier`, ...) passes through
unvalidated and is optional.

### Why the identity guard compares uuid and not email

The evidence behind the rule stated at `Test-CredentialAccountMatch` and
`Test-SameOAuthAccount`.

The same binary assigns this response straight into `~/.claude.json`:
`accountUuid: M.account.uuid` and `emailAddress: M.account.email`. So
`oauthAccount.accountUuid` **is** this endpoint's `account.uuid`, and the two
are directly comparable.

The email is not equally safe. A login that never fetched a profile takes the
binary's other path and fills `emailAddress` from the access token's own
embedded `account_email`, which need not equal `account.email` here. The uuid is
the one field both paths agree on.

The binary also lowercases uuids on some of its own comparison paths, so two
records of one account can differ in case alone. Compare them
case-insensitively.

## Credential storage

Extracted from `claude.exe` 2.1.274 with the recipe above.

This tool's entire premise is that `.credentials.json` is the active login. That
premise is an observation about someone else's binary, not a contract, which is
why `.github/workflows/tests.yml` re-scans the darwin build for the markers
below on `workflow_dispatch` and fails if the plaintext backend disappears.

Claude Code's `secureStorage` module defines exactly two credential backends:

```
name:"plaintext"        <CredDir>/.credentials.json, every platform
name:"windows-credman"  Windows Credential Manager, via Bun.secrets
```

### macOS is not a Keychain platform

There is no macOS Keychain *credential* backend. The Keychain holds only the
device key, under service `Claude Code-device-keys`, and the single Keychain
API-key path sits behind a hardcoded `let s=!1`. macOS reads and writes the same
`.credentials.json` as Linux, which is why `sca` supports it.

### The flag that would invalidate the premise

`windows-credman` is **not** active by default. It is selected by:

```
$env:CLAUDE_CODE_FORCE_WINDOWS_CREDMAN -eq '1'
  -or (.claude.json).cachedGrowthBookFeatures.tengu_windows_credman -eq $true
```

The second is a **server-controlled GrowthBook flag**, so it can turn on without
the user doing anything. When it does, storage becomes credman-primary with
plaintext as fallback, and the first successful credman write **deletes**
`.credentials.json`. From that point `sca switch` writes a file Claude Code no
longer reads: it would report success while the previous account stayed
authenticated and billing, which is the exact failure this tool exists to
prevent.

**Symptom to watch for:** `.credentials.json` missing or stale on Windows while
Claude Code is logged in, and `sca switch` silently failing to change `/status`.
Check with `cmdkey /list` for a `Claude Code-credentials` entry.

### Why the credman backend is not implemented

The credman item is service `Claude Code` + `OAUTH_FILE_SUFFIX` (`""` in
production) + `-credentials`, suffixed with `-<sha256(CLAUDE_CONFIG_DIR)[0..8]>`
when that variable is set, under account `claude-code-user`. Payloads over 2400
bytes are split into base64 chunks named `<service>#0..#n` with a `#m` manifest.

Reading that back would mean P/Invoking `CredRead`/`CredWrite` and
reimplementing the chunking, which is not worth building against a flag nobody
has been observed to receive.
