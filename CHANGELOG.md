# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.0.0] - 2026-09-13

### Changed

- **BREAKING**: `#Requires -Version` bumped from 7.2 to 7.4. `FileStreamOptions.UnixCreateMode`, which the Unix file-permission fix depends on, needs .NET 7; 7.4 is the lowest LTS release carrying it, and both 7.2 and 7.3 are past end of life.
- **BREAKING**: `CLAUDE_CONFIG_DIR` is now honoured, on Windows as well as Unix. Claude Code reads this variable to relocate its whole config tree, `.credentials.json` and `.claude.json` included, so a session with it set was already billing an account `sca` could not see. Anyone who has the variable set will find `sca` reading a different directory than before, and their existing slots in the default `~/.claude` no longer listed. The value is used as given, with no `~` expansion, matching Claude Code rather than correcting it; a relative value is bound once at startup to the directory the command was run in, which is the directory a `claude` started in the same shell would resolve it against. Binding it is not cosmetic: PowerShell's provider cmdlets resolve a relative path against the current location while .NET resolves it against the process start directory, so an unbound value would have `sca save` enumerate one directory and write the credential bytes into another after any `cd`. When the relocation strands saved slots in the default directory, `sca` prints one line naming the directory in use and counting what is being skipped, so the move is never silent; with nothing stranded it stays quiet, because the variable is a permanent setting and a line on every invocation would only train the user to ignore it.
- Linux and macOS are supported. `~` resolves via `$env:HOME` there and `%USERPROFILE%` on Windows, falling back to the account database when neither is set, slot enumeration passes `-Force` so the dotfiles this tool owns are visible, and `sca install` writes the alias block with the platform's own line ending. Claude Code's credential storage ships exactly two backends, a plaintext `.credentials.json` used on every platform and a Windows Credential Manager backend that is off by default; the macOS Keychain holds only a device key, so macOS reads and writes the same file as Linux.
- `sca install` and `sca uninstall` run on every platform, including an environment with no resolvable home directory. They touch nothing but the PowerShell profile, and `$PROFILE.CurrentUserAllHosts` is the same path on Linux and macOS, so a synced profile can carry the alias block onto a machine the other actions refuse to run on. Neither creates the credentials directory any more; they never read it.
- The `FILES` section of `sca help` prints the paths this invocation actually uses instead of hardcoded `%USERPROFILE%` literals, so it stays correct on every platform and under `CLAUDE_CONFIG_DIR`.
- The `Status` column of `sca usage` renders short fixed labels only (`error`, `error <code>`, `expired`, `unauthorized`, `no-oauth`, `rate-limited`), matching what the README always documented. The reason a slot failed prints below the table as `[Usage] <slot>: <reason>`, capped at three slots, with `expired` / `unauthorized` / `no-oauth` grouped onto one line per status naming every slot the cap left unreported, so no failed slot is left unexplained. Status is the last column and its width also sizes the Session / Week bars, so one long cell wrapped both its own row and the two bars.
- A single slow `/api/oauth/usage` response no longer erases a slot's numbers. A failed read falls back to the last known percentages instead of collapsing the row to `error: The request was canceled due to the configured HttpClient.Timeout...`. The endpoint answers in 46-2108 ms in practice, so the previous shared 5-second budget left almost no headroom; usage now gets 12 seconds and the token refresh gets its own 15. Twelve seconds is also what one unreachable slot can add to a frozen watch frame, since slots are polled serially and the loop cannot repaint mid-poll, which is why a timeout is never retried. The same fallback covers a token refresh that dies in transport, which carries the largest budget of the three calls and is therefore the likeliest place for a blip to land. The cache is reached only by a failure that says nothing about the request: no HTTP status from the HTTP stack itself, or a `5xx`. A `4xx` from either endpoint is reported as the failure it is, because `invalid_grant` means the refresh token is rejected for good and a `4xx` from the usage endpoint is how an endpoint change after a Claude Code upgrade would first show itself; serving either from cache would paint fresh-looking numbers under an `ok` status for the life of the cache entry. A refresh response missing `access_token` or `expires_in`, and a slot-file write that fails after the server already rotated the refresh token, are hard failures for the same reason: they carry no HTTP status either, but the slot behind them is not fine.
- When nothing is cached, a failed usage read retries once only if a second immediate attempt can plausibly answer differently: a `5xx` (Anthropic's `529 Overloaded` clears in seconds) or a codeless transport failure. A timeout is not retried, because it has already spent the full budget and slots are polled serially, so retrying it doubled every slot's contribution to the first frame of a watch; nor is a `4xx`, which the server rejects identically the second time.
- Auto-rotation reads a slot's cached percentages when a live read fails, instead of treating every non-`ok` row as 0% utilized. A throttled or briefly unreachable active slot at 100% now rotates rather than freezing. Rotation still refuses to move *into* a slot it could not verify.
- A bucket whose reset time has already passed counts as 0% for rotation and keep-warm decisions, so cached data cannot report a slot as exhausted after its window has rolled.
- `sca monitor -KeepWarm`'s per-poll pass no longer spends a billable `claude -p` on a slot that is already at the rotation threshold: warming re-opens the 5h window, which achieves nothing when that window is open and full. Such a slot reports `[Warmup] Rate-limited at the rotation threshold; will re-warm after the next window reset.` rather than promising a cooldown that cannot release it. The startup pass and `sca warmup` still warm every slot, because no usage data exists yet at that point.
- The usage advisory prints one line per condition instead of letting the cache-fallback line suppress everything else, and distinguishes a failed live read from a limit. Its condition lines name no source, because the same renderer also draws warmup frames whose rows come from `claude -p` rather than the usage API; the per-slot reason line below carries the actual cause.
- `sca usage -Json` may now emit `data` on a row whose `status` is `"error"`, and `error` on a row whose `status` is `"ok"`. Both follow from the same rule: `is_cached_fallback: true` is the only freshness marker, and a row served from a recent cache keeps its live-quality status while still reporting what the failed live read said. A failure reason is reported in full; the bound belongs to each renderer, which applies it at its own width.

### Added

- A test workflow running the suite on `windows-latest`, `ubuntu-latest` and `macos-latest`. No workflow ran the tests before. Coverage and its 90% gate run on Windows only, because the gate counts one run and each platform necessarily leaves the others' branches untouched.
- An on-demand workflow step re-checks Claude Code's credential backends against the darwin build and fails if the plaintext backend ever disappears. Gated to `workflow_dispatch`: it pulls a ~200 MB package for a fact that changes at most once a release. A failed install, or a package layout that presents nothing to scan, fails as itself rather than as a missing marker, because the step's only value is that its verdict can be trusted.

### Fixed

- Credential files are no longer written world-readable on Linux and macOS. Every file `sca` writes goes through an atomic rename, which on Unix is a bare `rename(2)`, so the destination inherits the temp file's mode: under the usual `0022` umask that silently downgraded Claude Code's `0600` to `0644` and left live refresh tokens readable by every user on the machine. The temp file is now created `0600` by `open(2)` itself, so the bytes are never readable by anyone but the owner, not even for the duration of the write. Covers `.credentials.json`, slot files, identity sidecars, the state file, and `~/.claude.json`.
- Files an earlier version left at `0644` are tightened to `0600` on the first run of any action, and the count is reported once. Writing new files correctly does not heal the ones already on disk: a slot that is never re-saved and whose token never refreshes would keep a world-readable refresh token indefinitely, and `sca switch` rewrites only `.credentials.json`. A credentials directory that `sca` creates is now `0700` as well, because slot filenames carry the account's email address; a directory that already exists is left exactly as it is, mode included, since it is usually Claude Code's own.
- A credential write that fails mid-stream no longer leaves a partially written temp file in the credentials directory. The atomic write's cleanup runs only after the write returns, so the file is now removed by the write itself, which is also the only place that can prove it created it.
- `sca` no longer aborts with a parameter-binder error when neither the home variable nor `CLAUDE_CONFIG_DIR` is set, which is reachable in a container or a systemd unit. The credentials directory was resolved at load time, so the failure landed before `sca help` or `sca -Version` could report which variable to set. Those two now work, and every other action refuses with a message naming both variables.
- `sca` resolves the home directory from the account database when `$env:HOME` / `%USERPROFILE%` is unset, instead of refusing. Node's `os.homedir()` and .NET both fall back that way, so `claude` kept working in an environment where `sca` would have reported no credentials directory, which is precisely the divergence this tool exists to prevent.
- `sca save` / `sca switch` / `sca monitor` detect an npm-installed Claude Code on Linux. The refusal-while-running guard matched only a process literally named `claude`, which the native installer produces but the npm package does not: it runs as `node`, so the guard silently passed and the `~/.claude.json` write went ahead against a live in-memory cache. On Linux the guard now also matches the package's own entry point in the command line. An npm-installed Claude Code stays undetected on Windows, where reading command lines costs ~53 s that a guard on every write cannot spend, and on macOS, where PowerShell does not expose `Process.CommandLine` at all; the native installer's Claude Code is detected on all three.
- `sca monitor -KeepWarm` no longer reports a slot that has hit its Claude.ai session or weekly limit as a hard `error`. Claude Code phrases those as "You've hit your session limit", which says neither "rate limit" nor "429", so the classifier missed it: such a slot now shows `rate-limited` in yellow, keeps its reset time visible on the advisory line, and is re-probed once its window may have rolled instead of being written off. A context-window or tool-output failure from `claude -p` is not caught by that classifier, which would otherwise strand the slot as throttled.
- `sca monitor` no longer goes silently inert when the active slot's usage cannot be read. It previously kept displaying the last `Rotated from ... to ... at ...` line while being structurally unable to rotate; it now reports `[Monitor] Active slot usage unknown (<status>); rotation paused.`, and returns to `[Monitor] Automatic slot switching is enabled.` on the first poll that can judge the slot again, so the paused line never outlives the state it describes.
- The aggregate Session / Week bars no longer overflow the terminal, and no longer present one account's numbers as the whole pool when another slot's read fails transiently. They fit to the table, but the table is content-sized, so a long slot name or a wide status pushed the bar past the right edge and it wrapped onto a second line.
- The aggregate bars now count a slot whose percentages came from the cache fallback, and so does the terminal title. The table already printed those numbers and rotation already acted on them, so excluding the same row from the pool mean made the bars contradict the rows directly beneath them, a pool whose reads had all gone stale lost both bars entirely while every row still showed a percentage, and the title blanked to the bare product name during exactly the transient failure the fallback exists to survive.
- The aggregate bars count a bucket whose reset time has passed as 0%, the same rule rotation and keep-warm apply. A cached entry has no upper age bound once it goes stale, so its window can roll while it is still on screen, and the bars would keep reporting a slot as exhausted while rotation treated it as free.
- `[Watch] Last poll failed:`, `[Monitor] Rotation failed!` and `[Warmup] Re-warm failed!` no longer break the footer layout when the underlying exception spans several lines. The footer is split on newlines so each entry can be coloured, which forked one multi-line message into several unprefixed lines.
- A poll that outran `-Interval` pre-credited the interval with its own duration, so the watch loop re-polled immediately with no delay. The interval is now measured from when the poll finished.
- A network timeout no longer stamps a rate-limit backoff, which had suppressed live probing for two minutes and mislabelled the slot as throttled.
- Three `sca save` tests asserted that a file count was zero using an enumeration that cannot see dotfiles on Unix, so they would have passed whether or not the files existed.

## [3.0.1] - 2026-06-23

### Fixed
- `sca usage -Watch` and `sca monitor` no longer flash to black and repaint row by row on a heavily loaded machine. Each frame is now painted as a single in-place overwrite (cursor-home, per-line erase, no full-screen clear), so the terminal can never be caught showing a half-drawn frame; DEC 2026 synchronized output is now a bonus on capable terminals rather than the sole safeguard.
- The live watch renders the aggregate bars (`█` / `▓`), the auto-rotation `▶` indicator, and the `…` / `—` glyphs correctly instead of as `?` on a legacy OEM codepage (e.g. CP850); it now writes UTF-8 to the console and restores the previous encoding on exit.

## [3.0.0] - 2026-06-22

### Added
- `sca monitor` action: the live, side-effecting supervisor. It always auto-rotates to the next eligible slot when the active slot reaches `-Threshold` (default 95), and `-KeepWarm` additionally keeps every slot warm by re-opening closed 5h windows on each poll. Auto-rotation remains OpenCode-scoped and refuses to run while Claude Code is open.

### Changed
- **BREAKING**: `sca usage` is now read-only. It keeps `[name]`, `-Watch`, `-Interval`, and `-Json`; the live auto-rotation and keep-warm modes moved to the new `sca monitor` action.
- **BREAKING**: auto-rotation is invoked as `sca monitor` (rotation is unconditional, so there is no `-Auto` flag) instead of `sca usage -Watch -Auto`. Tune the rotation point with `sca monitor -Threshold <n>`.
- **BREAKING**: keep-warm is invoked as `sca monitor -KeepWarm` instead of `sca usage -Watch -Warmup`.
- The auto-rotation watch footer is now labelled `[Monitor]` (was `[Auto]`); the keep-warm footer keeps the `[Warmup]` label it shares with the standalone `warmup` action.
- `sca` help corrects the FILES section to the real slot filename (`.credentials.<name>(<email>).json` plus the `.account.json` sidecar and `.sca-state.json` state file).

### Removed
- **BREAKING**: the `-Auto`, `-Threshold`, and `-Warmup` flags on `sca usage`. Use `sca monitor` / `sca monitor -Threshold <n>` / `sca monitor -KeepWarm`.

## [2.4.0] - 2026-06-17

### Added
- `sca warmup [name]` action: opens each saved slot's 5h session window (or just `<name>`) and prints the usage table. Refuses while Claude Code is running or the `claude` CLI is absent.

### Changed
- Warmup now opens a slot's 5h window by running the real Claude Code CLI (`claude -p` on Haiku in safe-mode, ~$0.004/slot) instead of a raw `/v1/messages` request, delegating the OAuth refresh to Claude Code's own flow. A throttled slot is reported and skipped, not retried.
- The `sca usage` rate-limit advisory moved into the watch footer as a single line that fits the table width.
- Agent instructions now live in `AGENTS.md`; `CLAUDE.md` is a thin `@AGENTS.md` import shim so Claude Code loads the same content.

### Fixed
- `sca usage` shows a short `error <code>` label (e.g. `error 529`) for HTTP errors instead of a verbose .NET message that wrapped the table row.

## [2.3.0] - 2026-05-29

### Added
- `sca usage -Watch -Warmup` primes every saved slot before polling so the first frame shows real Session/Week percentages instead of empty cells. Each prime sends a minimal billable `/v1/messages` request (~2 tokens per slot). Combines with `-Auto`; refused while Claude Code is running.

### Changed
- A transient `429` now keeps a slot's last-known Session/Week percentages on screen (marked, status stays `rate-limited`) instead of blanking the row to em-dashes.

### Fixed
- A `429` during token refresh retries with backoff and self-recovers within the same poll, instead of leaving the slot stuck on `rate-limited` until the next command.

## [2.2.1] - 2026-05-20

### Fixed
- `sca -Version` prints the version string instead of `True`, and every other action no longer emits a red `InvalidArgument` error at startup. The internal version constant collided with the `[switch] $Version` parameter; renamed to `$Script:ScriptVersion`.

## [2.2.0] - 2026-05-19

### Added
- `-Version` flag prints `$Script:Version` and exits.

### Changed
- `sca usage -Watch -Auto` title shows the pool mean across HTTP-ok slots, not the active slot.
- Pool-mean math extracted into `Get-PoolMeanUtilization`, shared by `Format-AggregateBars` and `Format-WatchTitle -Aggregate`.

## [2.1.0] - 2026-05-18

### Added
- `sca usage -Watch -Auto [-Threshold <1..100>]` auto-rotates to the next eligible slot when the active slot's utilization reaches the threshold (default 95).
- Right-aligned `▶ switching slot at N%` header indicator and latched `[Auto] …` footer line on the watch frame when `-Auto` is set.
- `Invoke-SlotSwap` extracted from `Invoke-SwitchAction` as the shared atomic swap primitive used by `sca switch` and the auto-rotation step.
- `docs/images/usage-watch-auto.svg` rendered example for the auto-mode watch frame; promoted to the README hero image.

### Changed
- `sca switch` output no longer ends with the cyan `[Info]` apply hint.
- README restructured: dashboard hoisted above the fold, watch content relocated into the Usage subsection, disclaimer blockquote-styled, Support section reframed.
- README usage screenshots rendered at a uniform 720px canvas and pinned to 1× intrinsic width via the HTML `width` attribute.

## [2.0.2] - 2026-05-03

### Added
- MIT license.
- GitHub Sponsors and Ko-fi funding via `.github/FUNDING.yml`.
- Unofficial-tool disclaimer and Anthropic-ToS discretion note in README.

### Changed
- Project canonically renamed to "Switch Claude Account". Profile-installer block markers renamed from `# === Claude Account Switcher ===` to `# === Switch Claude Account ===`. Existing installs: re-run `sca install` on the new version, then manually remove the leftover old-marker block from `$PROFILE`.

### Fixed
- `sca save` rolls back to the pre-existing slot pair when the sidecar write fails after the tokens-file write. The previous behaviour (delete-then-write) could leave the user with no slot for a name on a transient AV / disk-full / share-violation persisting past the 3-attempt retry on `Set-CredentialFileAtomic`.
- `sca usage` emits a yellow advisory pointing at `sca save` / `sca switch` when an OAuth refresh rotates tokens for the active slot but the slot's `.account.json` sidecar is missing (so `Find-SlotByName` returns null and `.credentials.json` is not updated). Previously the rotation silently desynchronised, forcing a Claude Code re-login on its next own-refresh.

## [2.0.1] - 2026-05-03

### Added
- GitHub Actions workflow `release-assets.yml` attaching `switch_claude_account.ps1` to each published release (skips pre-releases; `workflow_dispatch` fallback for backfill).
- `plan-review` skill for second-pass review of multi-step plans.
- Cross-project agent conventions: scratch-file discipline under `.tmp/sessions/<id>/`, multi-agent working-tree rules, version-control basics, em-dash punctuation rule.
- Explicit `@`-references in `CLAUDE.md` so OpenCode picks up `.claude/rules/script-internals.md` and `.claude/rules/tests.md` (Claude Code already auto-loads them).
- LF line-ending enforcement via `.gitattributes`.

### Changed
- Empty progress-bar cells render with U+2593 DARK SHADE instead of U+2591 LIGHT SHADE for cell-uniform width with U+2588 FULL BLOCK in terminal fonts.
- `sca usage -Watch` footer collapsed to a single advisory line.
- README screenshots regenerated against actual `Format-AggregateBars` and `Format-UsageTable` output; use ASCII space for empty bar cells for GitHub render alignment.
- Em-dash punctuation rule applied across docs, script, and tests; rate-limit advisory repunctuated from em dash to semicolon.
- Refreshed `pr-code-review` skill with metadata header, severity glyphs, and Pass-1 test-coverage check.
- README Download section replaced with a click-to-download link to `releases/latest/download/switch_claude_account.ps1`, which serves `Content-Disposition: attachment` via `objects.githubusercontent.com`.

### Removed
- `next in Xs` countdown footer from `sca usage -Watch`.

### Fixed
- Stale `Format-WatchTitle` prose claiming pool-mean across slots; the watch-mode title shows the active slot only.
- Unreachable `api-key / no-oauth` row in the lower README screenshot (slots without OAuth are refused at save time).

## [2.0.0] - 2026-04-26

### Added
- State file at `%USERPROFILE%\.claude\.sca-state.json` (schema v1) as the single source of truth for which slot is active; auto-migrates from 1.x installs on first read by content-hashing `.credentials.json` against existing slot files.
- Atomic-rename credential-file writes via `MoveFileEx`, surviving the share-delete handle Claude Code holds on `.credentials.json` while running. Retry policy: 3 attempts with 50 ms backoff.
- Reconcile pass that mirrors active credentials into the tracked slot or auto-saves under `auto-<UTC-timestamp>(<email>)` on cross-account swap; fires before `usage`, `switch`, and `list`.
- Active-slot OAuth-refresh propagation into `.credentials.json` with paired state-hash update, so the next reconcile no-ops.
- Identity sidecars `.credentials.<name>(<email>).account.json` capturing the slot's whitelisted `oauthAccount` snapshot at save time and restoring it to `~/.claude.json` on `sca switch`. Tokens-then-sidecar atomic-pair invariant: sidecar-write failure rolls back the tokens file.
- Identity resolution at save time reads `~/.claude.json`'s `oauthAccount` block first (offline) and falls back to `/api/oauth/profile` only when the cache is empty; both failing refuses the save.
- Targeted regex substitution into `~/.claude.json`'s `oauthAccount` block via `MatchEvaluator`, preserving every other byte (project history, mcp configs, ~50 other fields). Null-valued whitelisted fields are skipped.
- `-NoColor` flag and `NO_COLOR` env-var support via `$PSStyle.OutputRendering = 'PlainText'`.
- `Write-Color` helper routing all colored output through inline SGR codes; replaces 33 `-ForegroundColor` call sites.
- `Write-VTSequence` helper bypassing PowerShell's `StringDecorated.AnsiRegex` so DEC private modes survive regardless of `OutputRendering`.
- Flicker-free `sca usage -Watch` via DEC 2026 synchronized output mode and alternate screen buffer; pre-watch scrollback restored on Ctrl-C.
- Watch-mode terminal title via OSC 0, with `[!]` / `[~]` alarm prefix when any bucket crosses `UtilLimitPct` / `UtilWarnPct`.
- 429 cache-fallback path covering both `/api/oauth/usage` and `/v1/oauth/token`; non-429 refresh failures route through 60-char tail truncation so timeouts and 5xx no longer wrap the table.
- `is_cached_fallback` field on `-Json` rows served from cache; rate-limit advisory retitled to the endpoint-agnostic "Anthropic API rate limited".
- `[CmdletBinding()]`, parameter sets separating `-Json` from `-Watch`, and `[ValidateRange(1, [int]::MaxValue)]` on `-Interval`.
- Path-scoped agent rules under `.claude/rules/` (`script-internals.md`, `tests.md`) with per-path triggers; root `CLAUDE.md` trimmed from 390 to 122 lines.
- Pester suite: 36 new cases covering state-file atomic-rename behaviour, reconcile branches, `-NoColor` / `NO_COLOR`, watch-mode VT rendering, null-sidecar preservation, and refresh-429 / cache-fallback paths.
- `tests/Measure-Complexity.ps1` advisory AST walker reporting LOC, McCabe CC, and max nesting per function.

### Changed
- **BREAKING**: active-slot tracking moved from NTFS hardlinks to a state file. The hardlink approach was structurally fragile against Claude Code's atomic-rename token-refresh writes, which silently detached `.credentials.json` from any hardlink graph.
- **BREAKING**: `#Requires -Version` bumped from 7.0 to 7.2 for `$PSStyle.OutputRendering` support.
- **BREAKING**: synthetic `<active>` row removed from the `sca usage` data model. Reconcile guarantees the active credentials live in a real slot before rendering, so `<active>` and `<active> (unsaved)` argument aliases are no longer accepted.
- **BREAKING**: slots without a valid sidecar are hidden from `list` / `usage` / rotation and refused by `switch`. Re-running `sca save <name>` while the slot is active recaptures the sidecar.
- `sca save` and `sca switch` no longer require closing Claude Code to update `.credentials.json`, but still refuse to operate while it is running because they read/write `~/.claude.json`'s `oauthAccount` block.
- `Invoke-Reconcile` now fires on `list` as well so cross-account swaps surface in the active-marker column on the next render.
- Cross-account identity comparison uses the sidecar email as source of truth, not the filename email.
- `Invoke-RemoveAction` refuses to delete the slot tracked as active in state, and walks the raw filesystem so sidecar-less legacy slots can still be cleaned by name.
- Reset-delta rendering: `in 2h 37m` becomes `(2h 37m)`, matching the rest of the table.
- Top-level `Param` block migrated to PowerShell-idiomatic shape: PascalCase names, explicit `[Parameter(Position = …)]` for `Action` / `Name`.
- `-NoColor` flag spelled `-nocolor` for consistency with `-help` / `-json` / `-watch` / `-interval`.
- `Get-Slots` is now a thin enumerator: no per-slot SHA-256 hashing, sources `IsActive` from state, and silently sweeps leftover `.credentials.*.profile.json` cache sidecars from v1.
- README rewritten for the state-file plus sidecar model; CLAUDE.md split into root plus path-scoped rules.

### Removed
- `Test-HardlinkSupport` and its preflight call sites; non-NTFS volumes are no longer rejected.
- Synthetic-slot machinery in `Get-UsageSnapshot` / `Format-UsageFrame` and the `-SuppressAdvisory` parameter.
- Hardlink-broken / `not hardlinked to any slot` / `ActiveLocked` advisories from `sca list`.

### Fixed
- Token-refresh 429 from `/v1/oauth/token` no longer surfaces as wrapped `expired:` rows; classified via `Test-Is429` and routed through the cache-fallback path.
- Watch-mode color rendering on Windows. `Write-Host -ForegroundColor` called `SetConsoleTextAttribute` out-of-band, landing on a different channel than the buffered cell writes inside the DEC 2026 sync envelope; inline SGR codes via `Write-Color` now render correctly.
- `sca usage -Watch -nocolor` no longer flickers. `OutputRendering = 'PlainText'` was stripping DEC private modes via `StringDecorated.AnsiRegex`; `Write-VTSequence` bypasses the filter.
- `Set-OAuthAccountInClaudeJson` no longer wipes Claude Code's cached `oauthAccount` fields when the sidecar carries nulls (e.g. from the `/api/oauth/profile`-fallback save path).
- Token-sync propagation-failure advisory rewritten: now names `sca switch <slot>` as the recovery and states the realistic refresh-token rotation consequence (Claude Code's next own-refresh fails with 401).

## [1.2.0] - 2026-04-25

### Added
- `usage` action reporting live 5-hour Session and 7-day Week plan-usage percentages per slot via Anthropic's undocumented `GET /api/oauth/usage`. Auto-refreshes expired OAuth tokens against `platform.claude.com/v1/oauth/token`.
- `sca usage -watch` live self-refreshing view with 1 s redraw cadence and `-interval`-controlled polling (default and floor 60 s); refuses non-interactive output.
- `sca usage <name>` verbose single-slot view with `Account`, `Status`, `Session`, and `Week` rows including absolute local-timezone reset stamps.
- Pool-wide aggregate Session and Week progress bars rendered above the `sca usage` summary table.
- Plan-usability `Status` column (`ok`, `near limit`, `limited 5h`, `limited 7d`, `limited`, `expired`, `unauthorized`, `error: …`, `no-oauth`) derived from `UtilWarnPct = 90` and `UtilLimitPct = 100` thresholds.
- Synthetic `<active>` row when `.credentials.json` is not hardlinked to any saved slot, addressable via `sca usage '<active>'` for verbose drill-down.
- OAuth account email embedded in slot filenames as `.credentials.<slot>(<email>).json`; resolved at save time via `GET /api/oauth/profile` and rendered in a new `Account` column.
- `sca list` rebuilt as `Slot | Account` table sharing layout with `Format-UsageTable`.
- `sca switch` output rebuilt with DarkYellow header, post-switch saved-slot table, and cyan `[Info]` hint as the last line.
- 429 rate-limit resilience in `Get-SlotUsage`: per-slot in-memory cache reused with a yellow `displaying cached data` advisory.
- `(` and `)` sanitized in user-provided slot names to avoid filename-grammar ambiguity.
- `Get-UsageSnapshot` / `Format-UsageFrame` / `Invoke-UsageWatch` split: pure data, pure rendering, thin timing loop.
- Pester suite split into per-action files; total 152 in-process tests.

### Changed
- Section-title headers recolored from Yellow to DarkYellow; Yellow reserved for advisories. Green / Red / Cyan / DarkGray roles codified.
- Help screen `FILES` section emits literal `%USERPROFILE%` placeholders instead of interpolating the running user's name.
- README expanded with `usage`, `usage -watch`, aggregate-bar, Status-column, Account-column, and synth-row sections.
- `.claude/worktrees/` added to `.gitignore`.

### Fixed
- `save` no longer aborts when the `/api/oauth/profile` response carries an email with NTFS-invalid characters or when a labeled slot file is locked. Slot persists unlabeled with a yellow advisory; success line no longer claims an email label that did not land on disk.

## [1.1.0] - 2026-04-24

### Added
- `Test-HardlinkSupport` preflight for `save` and `switch` failing early on filesystems that cannot create hardlinks (FAT32, most network shares).
- `list` warns when `.credentials.json` is no longer hardlinked to any saved slot and suggests `sca switch <name>` to repair auto-sync.

### Changed
- `save` and `switch` replace `.credentials.json` with a hardlink to the named slot file instead of copying bytes; OAuth token refreshes flow into the saved slot through the shared inode.
- Slot names containing `[` or `]` are sanitized to `_`; all credential-file operations use `-LiteralPath` as defense-in-depth.
- README documents `sca switch` (no name) auto-rotation in its own subsection.

### Fixed
- `uninstall` preserves profile line endings byte-for-byte via raw regex splice instead of `Get-Content` + `-join "`r`n"`, no longer converting LF or mixed-ending profiles to CRLF.
- Test suite restores `$env:USERPROFILE` and `$global:PROFILE` in `AfterAll` so interactive `Invoke-Pester` runs do not leak the sandbox into the caller's session.

## [1.0.0] - 2026-04-23

### Added
- Single-file PowerShell switcher with `save`, `switch`, `list`, `remove`, `install`, `uninstall`, and `help` actions.
- Named credential slots stored as `.credentials.<name>.json` under `%USERPROFILE%\.claude\`.
- Auto-rotation: `sca switch` without a name rotates to the next saved slot alphabetically, wrapping.
- Help screen as default action plus `-h` / `--help` switch.
- `sca` and `switch-claude-account` aliases installed into the PowerShell profile via marker-delimited block.
- Windows filename sanitization with reserved device-name rejection (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`).
- Profile install / uninstall preserving existing encoding (UTF-8 with or without BOM, UTF-16 LE/BE) and refusing to mutate on orphan markers.
- Pester 5 test suite (65 in-process tests) with auto-install and sandboxed `$env:USERPROFILE` / `$PROFILE.CurrentUserAllHosts` per test.
- Optional PSScriptAnalyzer advisory pass in the test runner.
- README with installation, usage, workflow, Windows notes, and testing sections.
- `CLAUDE.md` with agent guidance for repo structure, gotchas, and script-shape conventions.
