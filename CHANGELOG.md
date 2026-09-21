# Changelog

This changelog follows [Common Changelog](https://common-changelog.org) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.2.0] - 2026-09-21

### Changed
- Run the warm round-robin of `sca warmup` and `sca monitor -KeepWarm` beside a live Claude Code.
- Average the `Session` aggregate bar over reachable slots only, dropping any slot whose week has capped.
- Pause `sca warmup` for five seconds before the first billable activation when Claude Code is running.

### Added
- Add `SCA_THEME`, which pins output to an exact palette instead of the terminal's own ANSI colors.
- Add ten themes: the base16 schemes `dracula`, `everforest`, `flexoki`, `gruvbox`, `kanagawa`, `material`, `monokai`, `nord` and `onedark`, plus an original `claude`.
- Paint the watch's alternate screen in the active theme's background, erases and window padding included.
- Add `docs/themes.md`, showing every theme as a full `sca monitor` view under a heading of its own.
- List the available theme names in `sca help` under a new `ENVIRONMENT` section.

### Fixed
- Mirror the active credentials after every activation, including one whose `claude -p` then threw.
- Stop the warm pass, and skip its restore, when nothing could capture the credentials left active.
- Show the warm pass's restore failure instead of discarding it into a suppressed stream.
- Carry the live-client warning into `sca monitor -KeepWarm`, at startup and at every re-warm.
- Guard the watch's console cursor restore so a failure there cannot unwind the terminal restore.
- Correct the README's claim that a full `Session` bar means the week has capped every slot.

## [4.1.0] - 2026-09-19

_A hot swap is only followed without a restart by Claude Code >= 2.1.274 or opencode-claude-auth >= 1.5.4, and `sca switch` can now refuse, and exit non-zero, where it previously always succeeded._

### Changed
- Collapse the token-refresh ladder to one attempt once another slot has drawn a `429` in the same run.
- Send the `scope` field the client has always sent, and re-pin the `User-Agent` to `claude-code/2.1.278`.
- Refuse only `sca save`, `sca warmup` and `sca monitor -KeepWarm` while Claude Code is running.

### Added
- Add hot-swapping of a live Claude Code session: `sca switch` and `sca monitor` run beside an open client.

### Fixed
- Stop reconcile overwriting a saved slot with another account's tokens.
- Decline to write when the new bytes cannot be attributed to an account, on both reconcile paths.
- Stop a token refresh propagating onto active credentials no reconcile has captured.
- Check on every action that overwrites `.credentials.json` that the reconcile before it captured.
- Stop reconcile adopting a byte-identical slot while `~/.claude.json` is unreadable.
- Write the `~/.claude.json` identity before adopting a slot, so a failure leaves both files agreeing.
- Adopt a byte-identical slot even when no slot is tracked, instead of saving a second copy of it.
- Stop reconcile refreshing the tokens it is only asking about.
- Stop `sca switch` and `sca monitor` dropping a `~/.claude.json` change that lands mid-substitution.
- Capture a token refresh that lands mid-poll before `sca monitor` rotates away from the slot.
- Start `sca usage -Watch` and `sca monitor` on Linux and macOS instead of aborting at once.
- Report a revoked login as needing re-authentication rather than as rate-limited.
- Stop the usage advisory describing a slot sca has never read as being at a limit.
- Extend the rate-limit backoff to throttled slots holding no cached reading.
- Double the keep-warm cooldown per consecutive failed warm, and reset it on the first success.

## [4.0.0] - 2026-09-13

_Upgrading needs PowerShell 7.4, and a session with `CLAUDE_CONFIG_DIR` set now reads that directory on every platform, so slots left behind in the default `~/.claude` stop being listed; one line names both directories when that happens._

### Changed
- **BREAKING**: Raise `#Requires -Version` from 7.2 to 7.4, the lowest LTS carrying `FileStreamOptions.UnixCreateMode`.
- **BREAKING**: Honour `CLAUDE_CONFIG_DIR` on every platform, with no `~` expansion and a relative value bound at startup.
- Run `sca install` and `sca uninstall` on every platform, and stop either creating the credentials directory.
- Print the paths `sca help` actually uses, instead of hardcoded `%USERPROFILE%` literals.
- Render short fixed labels in the `Status` column, and print why a slot failed below the table.
- Print one advisory line per condition, bounded at eight lines, instead of letting one suppress the rest.
- Replace the shared 5 s HTTP budget with 12 s for usage and 15 s for the token refresh.
- Fall back to the last known percentages only for a failure that says nothing about the request.
- Refuse a cached reading past six hours.
- Retry a failed usage read once only where a second attempt can plausibly differ.
- Read cached percentages for auto-rotation when a live read fails, so a throttled slot at 100% still rotates.
- Drop a usage bucket whose window has rolled as the reading is built, so nothing downstream disagrees about it.
- Stop `sca monitor -KeepWarm` spending a billable `claude -p` on a slot already at the rotation threshold.
- Document the `sca usage -Json` shape: a row may carry `data` with `status: "error"` and `error` with `status: "ok"`, `is_cached_fallback` remains the only freshness marker, and a `data` block may omit a bucket whose window has rolled.

### Added
- Add Linux and macOS support: `~` from `$env:HOME` off Windows, dotfile-aware enumeration, native line endings on install.
- Add a test workflow running the suite on `windows-latest`, `ubuntu-latest` and `macos-latest`.
- Add a `workflow_dispatch` step re-checking Claude Code's credential backends against the darwin build.

### Fixed
- Stop writing credential files world-readable on Linux and macOS; the temp file is `0600` from `open(2)` itself.
- Tighten credential files left readable by other users to `0600` on the first run of any action, and report the count.
- Create a credentials directory `0700`, because slot filenames carry account email addresses.
- Stop leaving a partial temp file behind when a credential write fails mid-stream.
- Stop aborting with a binder error where neither the home variable nor `CLAUDE_CONFIG_DIR` is set.
- Resolve the home directory from the account database when `$env:HOME` or `%USERPROFILE%` is unset.
- Detect an npm-installed Claude Code on Linux, which runs as `node` and slipped past a guard matching `claude`.
- Stop reporting a slot at its Claude.ai session or weekly limit as a hard `error`.
- Report `[Monitor] Active slot usage unknown (<status>); rotation paused.` instead of going silently inert.
- Decide whether `CLAUDE_CONFIG_DIR` points at the default directory as a path question, not a string one.
- Stop the aggregate bars overflowing the terminal, and presenting one account's numbers as the whole pool.
- Count a slot whose percentages came from the cache in the aggregate bars and the terminal title.
- Stop a multi-line exception breaking the watch footer layout.
- Measure the poll interval from when the poll finished, so a slow poll no longer re-polls with no delay.
- Stop a network timeout stamping a rate-limit backoff and mislabelling the slot as throttled.
- Fix three `sca save` tests that asserted a file count through an enumeration blind to dotfiles on Unix.

## [3.0.1] - 2026-06-23

### Fixed
- Paint each watch frame as one in-place overwrite, so a loaded terminal cannot show a half-drawn frame.
- Write UTF-8 to the console so the bars and glyphs render on a legacy OEM codepage, restoring the encoding on exit.

## [3.0.0] - 2026-06-22

_Upgrading moves the live modes off `sca usage`: `-Auto`, `-Threshold` and `-Warmup` are gone, and `sca monitor` carries them._

### Changed
- **BREAKING**: Make `sca usage` read-only, keeping `[name]`, `-Watch`, `-Interval` and `-Json`.
- **BREAKING**: Invoke auto-rotation as `sca monitor`, tuned with `-Threshold <n>`, rather than `sca usage -Watch -Auto`.
- **BREAKING**: Invoke keep-warm as `sca monitor -KeepWarm` rather than `sca usage -Watch -Warmup`.
- Label the auto-rotation watch footer `[Monitor]` rather than `[Auto]`.
- Correct the help screen's FILES section to the real slot filename, its sidecar and the state file.

### Added
- Add the `sca monitor` action: the live supervisor that auto-rotates at `-Threshold` and, with `-KeepWarm`, re-opens closed 5h windows.

### Removed
- **BREAKING**: Remove the `-Auto`, `-Threshold` and `-Warmup` flags from `sca usage`.

## [2.4.0] - 2026-06-17

### Changed
- Open a slot's 5h window with the real Claude Code CLI (`claude -p` on Haiku, ~$0.004 a slot) rather than a raw `/v1/messages` request.
- Move the `sca usage` rate-limit advisory into the watch footer, as one line that fits the table width.
- Move agent instructions into `AGENTS.md`, leaving `CLAUDE.md` a thin import shim.

### Added
- Add the `sca warmup [name]` action, opening each saved slot's 5h session window and printing the usage table.

### Fixed
- Show a short `error <code>` label for an HTTP error, instead of a verbose .NET message that wrapped the row.

## [2.3.0] - 2026-05-29

### Changed
- Keep a slot's last-known percentages on screen through a transient `429`, instead of blanking the row.

### Added
- Add `sca usage -Watch -Warmup`, priming every saved slot so the first frame shows real percentages.

### Fixed
- Retry a `429` during token refresh with backoff, so the slot self-recovers within the same poll.

## [2.2.1] - 2026-05-20

### Fixed
- Print the version string from `sca -Version` instead of `True`, by renaming the constant off the `[switch]` parameter.

## [2.2.0] - 2026-05-19

### Changed
- Show the pool mean across HTTP-ok slots in the `sca usage -Watch -Auto` title, not the active slot.
- Extract the pool-mean math into `Get-PoolMeanUtilization`, shared by the aggregate bars and the watch title.

### Added
- Add a `-Version` flag that prints the version and exits.

## [2.1.0] - 2026-05-18

### Changed
- Drop the cyan `[Info]` apply hint from the end of `sca switch` output.
- Restructure the README: dashboard above the fold, watch content under Usage, disclaimer as a blockquote.
- Render the README usage screenshots at a uniform 720 px canvas, pinned to 1x intrinsic width.

### Added
- Add `sca usage -Watch -Auto [-Threshold <1..100>]`, rotating to the next eligible slot at the threshold.
- Add the right-aligned `▶ switching slot at N%` header indicator and the latched `[Auto] …` footer line.
- Extract `Invoke-SlotSwap` as the atomic swap primitive shared by `sca switch` and auto-rotation.
- Add `docs/images/usage-watch-auto.svg`, and promote it to the README hero image.

## [2.0.2] - 2026-05-03

_Upgrading renames the profile-installer block markers: re-run `sca install`, then remove the leftover old-marker block from `$PROFILE` by hand._

### Changed
- Rename the project to "Switch Claude Account", and its profile-installer block markers with it.

### Added
- Add the MIT license.
- Add GitHub Sponsors and Ko-fi funding through `.github/FUNDING.yml`.
- Add the unofficial-tool disclaimer and the Anthropic-ToS discretion note to the README.

### Fixed
- Roll `sca save` back to the pre-existing slot pair when the sidecar write fails after the tokens file.
- Emit a yellow advisory when a refresh rotates the active slot's tokens but its sidecar is missing.

## [2.0.1] - 2026-05-03

### Changed
- Render an empty progress-bar cell with U+2593 DARK SHADE, for cell-uniform width against U+2588.
- Collapse the `sca usage -Watch` footer to a single advisory line.
- Regenerate the README screenshots against actual `Format-AggregateBars` and `Format-UsageTable` output.
- Apply the em-dash punctuation rule across the docs, the script and the tests.
- Refresh the `pr-code-review` skill with a metadata header, severity glyphs and a Pass-1 coverage check.
- Replace the README Download section with a click-to-download link to the latest release asset.

### Added
- Add the `release-assets.yml` workflow, attaching `switch_claude_account.ps1` to each published release.
- Add the `plan-review` skill for second-pass review of multi-step plans.
- Add cross-project agent conventions: scratch-file discipline, multi-agent working-tree rules, punctuation.
- Add explicit `@`-references in `CLAUDE.md`, so OpenCode picks up the path-scoped rules.
- Enforce LF line endings through `.gitattributes`.

### Removed
- Remove the `next in Xs` countdown footer from `sca usage -Watch`.

### Fixed
- Correct the stale `Format-WatchTitle` prose claiming a pool mean; the watch title shows the active slot.
- Remove the unreachable `api-key / no-oauth` row from the lower README screenshot.

## [2.0.0] - 2026-04-26

_Upgrading migrates active-slot tracking from hardlinks to a state file on first read, and hides every slot without an identity sidecar until `sca save <name>` recaptures it._

### Changed
- **BREAKING**: Move active-slot tracking from NTFS hardlinks to a state file, which Claude Code's atomic-rename refresh writes had silently detached.
- **BREAKING**: Raise `#Requires -Version` from 7.0 to 7.2, for `$PSStyle.OutputRendering`.
- **BREAKING**: Remove the synthetic `<active>` row from the `sca usage` data model, and its argument aliases with it.
- **BREAKING**: Hide a slot without a valid sidecar from `list`, `usage` and rotation, and refuse it in `switch`.
- Stop `sca save` and `sca switch` needing Claude Code closed to update `.credentials.json`, while still refusing beside it.
- Fire `Invoke-Reconcile` on `list` as well, so a cross-account swap surfaces in the active-marker column.
- Compare cross-account identity on the sidecar email rather than the filename email.
- Refuse to delete the slot tracked as active, and walk the raw filesystem so a legacy slot stays reachable by name.
- Render a reset delta as `(2h 37m)` rather than `in 2h 37m`, matching the rest of the table.
- Migrate the top-level `Param` block to PascalCase names with explicit positions.
- Spell the `-NoColor` flag `-nocolor`, for consistency with the other switches.
- Make `Get-Slots` a thin enumerator: no per-slot hashing, `IsActive` from state, v1 cache sidecars swept.
- Rewrite the README for the state-file and sidecar model, and split `CLAUDE.md` into root plus path-scoped rules.

### Added
- Add a schema-v1 state file as the single source of truth for which slot is active, auto-migrating from 1.x on first read.
- Write credential files by atomic rename, surviving the share-delete handle Claude Code holds while running.
- Add the reconcile pass, mirroring active credentials into the tracked slot or auto-saving on a cross-account swap.
- Propagate an active-slot OAuth refresh into `.credentials.json`, with a paired state-hash update.
- Add identity sidecars capturing a slot's `oauthAccount` snapshot, restored to `~/.claude.json` on switch.
- Resolve identity at save time from `~/.claude.json` first, falling back to `/api/oauth/profile` only when empty.
- Substitute into `~/.claude.json`'s `oauthAccount` block by targeted regex, preserving every other byte.
- Add a `-NoColor` flag and `NO_COLOR` support, through `$PSStyle.OutputRendering`.
- Add the `Write-Color` helper, replacing 33 `-ForegroundColor` call sites with inline SGR codes.
- Add `Write-VTSequence`, bypassing PowerShell's ANSI filter so DEC private modes survive.
- Add flicker-free `sca usage -Watch`, through DEC 2026 synchronized output and the alternate screen buffer.
- Add a watch-mode terminal title through OSC 0, with `[!]` and `[~]` alarm prefixes.
- Add a 429 cache-fallback path covering both the usage and the token endpoint.
- Add the `is_cached_fallback` field on `-Json` rows served from cache.
- Add `[CmdletBinding()]`, parameter sets separating `-Json` from `-Watch`, and a range check on `-Interval`.
- Add path-scoped agent rules under `.claude/rules/`, trimming root `CLAUDE.md` from 390 to 122 lines.
- Add 36 Pester cases covering the state file, reconcile branches, `-NoColor`, watch VT rendering and the 429 paths.
- Add `tests/Measure-Complexity.ps1`, an advisory AST walker reporting LOC, McCabe CC and max nesting.

### Removed
- Remove `Test-HardlinkSupport` and its preflight call sites; a non-NTFS volume is no longer rejected.
- Remove the synthetic-slot machinery and the `-SuppressAdvisory` parameter.
- Remove the hardlink-broken advisories from `sca list`.

### Fixed
- Classify a token-refresh 429 through `Test-Is429`, instead of surfacing it as a wrapped `expired:` row.
- Fix watch-mode color on Windows, by writing inline SGR codes inside the DEC 2026 envelope.
- Stop `sca usage -Watch -nocolor` flickering, by bypassing the filter that stripped DEC private modes.
- Stop `Set-OAuthAccountInClaudeJson` wiping Claude Code's cached fields when the sidecar carries nulls.
- Rewrite the propagation-failure advisory to name `sca switch <slot>` and the real rotation consequence.

## [1.2.0] - 2026-04-25

### Changed
- Recolor section-title headers from Yellow to DarkYellow, reserving Yellow for advisories.
- Emit literal `%USERPROFILE%` placeholders in the help screen's FILES section.
- Expand the README with the usage, watch, aggregate-bar, Status-column and Account-column sections.
- Add `.claude/worktrees/` to `.gitignore`.

### Added
- Add the `usage` action, reporting live 5-hour and 7-day plan usage per slot and refreshing an expired token.
- Add `sca usage -watch`, a self-refreshing view with a 1 s redraw and a 60 s polling floor.
- Add `sca usage <name>`, a verbose single-slot view with absolute local-timezone reset stamps.
- Add pool-wide aggregate Session and Week progress bars above the summary table.
- Add the plan-usability `Status` column, derived from the 90% and 100% thresholds.
- Add a synthetic `<active>` row for credentials not hardlinked to a saved slot, addressable for drill-down.
- Embed the OAuth account email in slot filenames, resolved at save time, and render it in an `Account` column.
- Rebuild `sca list` as a `Slot | Account` table, sharing its layout with the usage table.
- Rebuild `sca switch` output with a header, a post-switch slot table and a closing hint.
- Add 429 resilience to `Get-SlotUsage`: a per-slot cache reused behind a yellow advisory.
- Sanitize `(` and `)` in a slot name, to keep the filename grammar unambiguous.
- Split usage into pure data, pure rendering and a thin timing loop, and the Pester suite into per-action files.

### Fixed
- Stop `save` aborting when the profile email carries NTFS-invalid characters, or a labeled slot file is locked.

## [1.1.0] - 2026-04-24

### Changed
- Replace `.credentials.json` with a hardlink to the named slot, so a token refresh flows through the shared inode.
- Sanitize `[` and `]` in a slot name, and pass `-LiteralPath` on every credential-file operation.
- Document `sca switch` auto-rotation in its own README subsection.

### Added
- Add a `Test-HardlinkSupport` preflight to `save` and `switch`, failing early where hardlinks cannot be created.
- Warn from `list` when `.credentials.json` is no longer hardlinked to any saved slot.

### Fixed
- Preserve profile line endings byte-for-byte in `uninstall`, through a raw regex splice.
- Restore `$env:USERPROFILE` and `$global:PROFILE` in `AfterAll`, so an interactive run cannot leak the sandbox.

## [1.0.0] - 2026-04-23

### Added
- Add a single-file PowerShell switcher with `save`, `switch`, `list`, `remove`, `install`, `uninstall` and `help`.
- Store named credential slots as `.credentials.<name>.json` under `%USERPROFILE%\.claude\`.
- Rotate to the next saved slot alphabetically when `sca switch` is given no name, wrapping at the end.
- Show the help screen as the default action, and behind `-h` and `--help`.
- Install `sca` and `switch-claude-account` aliases into the PowerShell profile, as a marker-delimited block.
- Sanitize Windows filenames, rejecting reserved device names.
- Preserve the existing profile encoding on install and uninstall, refusing to mutate on orphan markers.
- Add a Pester 5 suite of 65 in-process tests, sandboxing `$env:USERPROFILE` and `$PROFILE` per test.
- Add an optional PSScriptAnalyzer advisory pass to the test runner.
- Add a README with installation, usage, workflow, Windows notes and testing sections.
- Add `CLAUDE.md` with agent guidance for the repo structure, gotchas and script-shape conventions.

[4.2.0]: https://github.com/countzero/switch_claude_account/releases/tag/v4.2.0
[4.1.0]: https://github.com/countzero/switch_claude_account/releases/tag/v4.1.0
[4.0.0]: https://github.com/countzero/switch_claude_account/releases/tag/v4.0.0
[3.0.1]: https://github.com/countzero/switch_claude_account/releases/tag/v3.0.1
[3.0.0]: https://github.com/countzero/switch_claude_account/releases/tag/v3.0.0
[2.4.0]: https://github.com/countzero/switch_claude_account/releases/tag/v2.4.0
[2.3.0]: https://github.com/countzero/switch_claude_account/releases/tag/v2.3.0
[2.2.1]: https://github.com/countzero/switch_claude_account/releases/tag/v2.2.1
[2.2.0]: https://github.com/countzero/switch_claude_account/releases/tag/v2.2.0
[2.1.0]: https://github.com/countzero/switch_claude_account/releases/tag/v2.1.0
[2.0.2]: https://github.com/countzero/switch_claude_account/releases/tag/v2.0.2
[2.0.1]: https://github.com/countzero/switch_claude_account/releases/tag/v2.0.1
[2.0.0]: https://github.com/countzero/switch_claude_account/releases/tag/v2.0.0
[1.2.0]: https://github.com/countzero/switch_claude_account/releases/tag/v1.2.0
[1.1.0]: https://github.com/countzero/switch_claude_account/releases/tag/v1.1.0
[1.0.0]: https://github.com/countzero/switch_claude_account/releases/tag/v1.0.0
