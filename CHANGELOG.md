# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Hot-swapping a live Claude Code session. `sca switch` and `sca monitor` no longer refuse while `claude` is running: 2.1.274 polls `~/.claude.json` once a second and re-`stat`s `.credentials.json` at the top of every token-refresh check, so it follows a swap without a restart. Verified by handing a running `claude -p` a second account's credentials four seconds in; it re-read them and died on that account's 5h limit four seconds later. `sca monitor` is no longer OpenCode-scoped, and needs Claude Code >= 2.1.274 or opencode-claude-auth >= 1.5.4.

### Changed
- `sca save`, `sca warmup` and `sca monitor -KeepWarm` are now the only actions that refuse while Claude Code is running. `save` pairs tokens from `.credentials.json` with an identity from `~/.claude.json`, two files a `/login` updates separately, and catching that window mislabels a slot permanently. The other two make every slot active in turn, which would drag a live session across every account on the machine.

### Fixed
- Reconcile no longer overwrites a saved slot with another account's tokens. It decided whether `.credentials.json` had changed account by reading an email out of `~/.claude.json`, a different file, so anything that moved the tokens without moving that email was taken for a token refresh and mirrored over the tracked slot. A `/login` does exactly that between its two writes. Two checks now stand ahead of that write: bytes byte-identical to another saved slot are recognised as that slot and adopted, leaving both slot files untouched, and anything else is confirmed against `/api/oauth/profile` using the incoming tokens themselves before the slot is overwritten. The second check runs only while a client is live, which is the only time the window can be open, and only a proven mismatch blocks the write, so an unreachable endpoint cannot freeze slot files. It compares account uuids rather than emails, because Claude Code fills `~/.claude.json`'s email from the profile response on one login path and from the access token's own embedded address on another, and the two need not agree for one account.
- Reconcile adopts a byte-identical slot even when no slot is tracked, instead of auto-saving a second copy of an account already saved and moving active tracking onto the copy. The check sat inside the tracked-slot branch, which a corrupt state file skips entirely: `Read-ScaState` returns null from its parse failure without running the hash bootstrap that covers a missing file.
- `sca monitor` captures a token refresh that lands mid-poll before rotating away from a slot. The poll reconciles before reading usage, then spends a full serial HTTP pass across every slot, and the swap at the end overwrote anything Claude Code wrote in between, leaving the outgoing slot holding a refresh token the server had already rotated. Only reachable since rotation stopped refusing beside a live Claude Code.
- Reconcile declines to write when it cannot attribute the new bytes to an account, rather than mirroring them into the tracked slot on the assumption that continuity beats caution. It took that branch whenever `~/.claude.json` carried no email and `/api/oauth/profile` did not answer, and the slot file it overwrote is the one artifact a login cannot be recovered from.

## [4.0.0] - 2026-09-13

### Changed
- **BREAKING**: `#Requires -Version` raised from 7.2 to 7.4, the lowest LTS carrying `FileStreamOptions.UnixCreateMode`. 7.2 and 7.3 are past end of life.
- **BREAKING**: `CLAUDE_CONFIG_DIR` is honoured on every platform, so a session with it set is no longer billing an account `sca` cannot see. Anyone who has it set reads a different directory than before and no longer lists slots left in the default `~/.claude`; one line names both when that happens. No `~` expansion, matching Claude Code; a relative value binds once at startup to the launch directory.
- `sca install` and `sca uninstall` run on every platform, including one with no resolvable home directory. Neither creates the credentials directory any more.
- `sca help` prints the paths the invocation actually uses instead of hardcoded `%USERPROFILE%` literals.
- The `Status` column renders short fixed labels only; why a slot failed prints below the table as `[Usage] <slot>: <reason>`. Status sizes the aggregate bars, so one long cell wrapped its own row and both bars.
- The usage advisory prints one line per condition instead of letting the cache-fallback line suppress the rest, and distinguishes a failed live read from a limit. It is bounded at eight lines, reserving the ones that name every affected slot, so it cannot push the table out of a watch frame.
- Per-endpoint HTTP budgets replace the shared 5 s one: 12 s for usage, 15 s for the token refresh. Measured round-trips span 46-2108 ms, so 5 s left no headroom.
- A failed usage read falls back to the last known percentages instead of blanking the row, but only for a failure that says nothing about the request: a `5xx`, or no status from the HTTP stack itself. Any `4xx`, an unusable refresh response, and a slot-file write that fails after the server rotated the token are reported instead.
- A cached reading is refused past six hours. Without an upper age bound, a permanently unreadable active slot was judged on days-old numbers while `sca monitor` reported itself armed.
- A failed usage read retries once only when a second attempt can plausibly differ: a `5xx`, or a codeless transport failure. A timeout has already spent its budget; a `4xx` is rejected identically. The retry's own failure is classified on its merits rather than inheriting the first one's label.
- Auto-rotation reads cached percentages when a live read fails, so a throttled active slot at 100% rotates instead of freezing. It still refuses to move *into* a slot it could not verify, though a destination may be entered on a reading up to the cache TTL old.
- A usage bucket whose window has rolled is dropped as the reading is built, so the table cell, the plan status, the bars, the title and the rotation decision cannot disagree about it.
- `sca monitor -KeepWarm` no longer spends a billable `claude -p` on a slot already at the rotation threshold, and says the window reset is what will release it rather than the cooldown.
- `sca usage -Json`: a row may carry `data` with `status: "error"` and `error` with `status: "ok"`, `is_cached_fallback` remains the only freshness marker, and a `data` block may omit a bucket whose window has rolled.

### Added
- Linux and macOS support. `~` resolves via `$env:HOME` off Windows, falling back to the account database when unset; slot enumeration sees dotfiles; `sca install` writes the platform's own line ending. Claude Code keeps the same plaintext `.credentials.json` on all three, the macOS Keychain holding only a device key.
- A test workflow running the suite on `windows-latest`, `ubuntu-latest` and `macos-latest`. Coverage and its 90% gate run on Windows only, because the gate counts one run.
- A `workflow_dispatch` step that re-checks Claude Code's credential backends against the darwin build and fails if the plaintext backend disappears.

### Fixed
- Credential files are no longer written world-readable on Linux and macOS. The atomic rename handed the destination the temp file's mode, so a `0022` umask downgraded Claude Code's `0600` to `0644` and left live refresh tokens readable by every user on the machine. The temp file is now `0600` from `open(2)` itself.
- Credential files left readable by other users are tightened to `0600` on the first run of any action, and the count is reported. Covers only the files `sca` creates: `~/.claude.json` is Claude Code's and symlinks are skipped, since `chmod` would follow them.
- A credentials directory `sca` creates is `0700`, because slot filenames carry account email addresses. One that already exists keeps its mode, so where Claude Code ran first the exposure stays open and `chmod 700 ~/.claude` is the user's to run.
- A credential write that fails mid-stream no longer leaves a partial temp file behind.
- `sca` no longer aborts with a parameter-binder error when neither the home variable nor `CLAUDE_CONFIG_DIR` is set, which is reachable in a container or systemd unit. `sca help` and `sca -Version` work there; every other action refuses with a message naming both variables.
- `sca` resolves the home directory from the account database when `$env:HOME` / `%USERPROFILE%` is unset, matching what `claude` itself does rather than refusing where it works.
- `sca save` / `switch` / `monitor` detect an npm-installed Claude Code on Linux, which runs as `node` and so slipped past a guard matching only a process named `claude`. Still undetected on Windows, where reading command lines costs ~53 s, and on macOS, where PowerShell does not expose them.
- `sca monitor -KeepWarm` no longer reports a slot at its Claude.ai session or weekly limit as a hard `error`. Claude Code phrases those as "You've hit your session limit", which says neither "rate limit" nor "429".
- `sca monitor` no longer goes silently inert when the active slot cannot be read: it reports `[Monitor] Active slot usage unknown (<status>); rotation paused.` and clears that only on a poll that actually judged the slot.
- Whether `CLAUDE_CONFIG_DIR` already points at the default directory is decided as a path question, not a string one. A trailing separator, a different separator style, or a session parked on `Env:\` each produced a permanent advisory naming one directory as both in use and skipped.
- The aggregate bars no longer overflow the terminal, and no longer present one account's numbers as the whole pool when another slot's read fails transiently.
- The aggregate bars and the terminal title count a slot whose percentages came from the cache, as the table and rotation already did.
- `[Watch] Last poll failed:`, `[Monitor] Rotation failed!` and `[Warmup] Re-warm failed!` no longer break the footer layout on a multi-line exception.
- A poll that outran `-Interval` no longer re-polls with no delay; the interval is measured from when the poll finished.
- A network timeout no longer stamps a rate-limit backoff, which had suppressed live probing for two minutes and mislabelled the slot as throttled.
- Three `sca save` tests asserted a file count using an enumeration blind to dotfiles on Unix, so they would have passed whether or not the files existed.

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
