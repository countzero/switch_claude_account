# AGENTS.md

This file is the canonical agent-instructions source for this repository, read natively by OpenCode and loaded by Claude Code through the `CLAUDE.md` import shim. Single-file PowerShell tool: core logic lives in `switch_claude_account.ps1`; tests live in `tests/` and use Pester 5.

## Editing this file

- Hard ceiling: 18,500 bytes, about 4,600 tokens, measured with `(Get-Item AGENTS.md).Length`. Cut content to stay under it. Bytes rather than lines because the lines here run past 300 characters, so a line count measures nothing and a long paragraph joined onto one line reads as a saving.
- This file is for **orientation and repo-global rules only**. How a function works belongs in a comment on that function, never here: a second copy in a separate file drifts silently, and this repo has already shipped documentation describing behaviour the code never had.
- A rule whose full form lives under `docs/` appears here only as a pointer, written `` `docs/<file>.md` → *Section* ``, or as the file alone when the whole document is that rule. A pointed-at heading is an interface: renaming one means re-pointing its callers.
- Describe the **current** shape only. Rationale, design history, and "why not the alternative" prose belong in commit messages.
- When you remove a design from the code, remove its references here too.

## Key facts

- **Supported platforms**: Windows, Linux, and macOS, all three covered by the CI matrix. The block comment under `# --- Where Claude Code actually keeps the active login ---` records where Claude Code keeps credentials on each, why macOS is not a Keychain platform, and the one flag that could change it.
- **Credential directory**: `$CredDir`, resolved once at the top of the script. `$env:CLAUDE_CONFIG_DIR` when set, else `<home>/.claude`, else **`$null`** when neither is set: every path derived from it is left `$null` rather than throwing at load time, so `help` and `-Version` still work, and `Assert-CredentialDir` refuses the other actions. Home is the platform's environment variable (`$env:USERPROFILE` / `$env:HOME`) **first**, then the `$HOME` automatic variable. The environment leads because `$HOME` binds at session start and never re-reads it, so the test sandbox could not redirect it; `$HOME` is kept as the fallback because it is the only getpwuid path we have, and `claude` keeps working without the variable.
- **`CLAUDE_CONFIG_DIR`**: no `~` expansion, because Claude Code does none (anthropics/claude-code#78988). A relative value is bound to `$PWD` once at load by `Resolve-ScaConfigDir`, which keeps the parity (a `claude` launched in the same directory resolves it the same way) while removing the split between provider cmdlets resolving against `$PWD` and .NET resolving against `[Environment]::CurrentDirectory`. `Get-ConfigDirAdvisory` prints one line when the relocation strands slots in the default directory, and stays silent otherwise, because the variable is a permanent setting and an unconditional line would train the user to ignore it.
- **Active credentials**: `.credentials.json`, written by Claude Code via atomic rename on every OAuth refresh. `sca` writes it through the same primitive (`Set-CredentialFileAtomic`) so the file is byte-equal to the tracked slot file after every `sca save` / `sca switch` / reconcile pass.
- **Claude Code config**: `$ClaudeJsonPath`. `<home>/.claude.json` by default, a **sibling** of `.claude/` rather than a file inside it, but it moves inside `CLAUDE_CONFIG_DIR` when that is set (verified against Claude Code 2.1.263). Its top-level `oauthAccount` block is what `/status` displays as "Email:". `sca` reads it at save time and writes the destination slot's captured block back on `sca switch`; see `Get-OAuthAccountFromClaudeJson` / `Set-OAuthAccountInClaudeJson`.
- **State file**: `$CredDir/.sca-state.json`, schema v1: `{ schema, active_slot, last_sync_hash }`. Single source of truth for "which slot is active." See `Read-ScaState` / `Update-ScaState`.
- **Slot files**: `.credentials.<name>(<email>).json` plus a paired `.credentials.<name>(<email>).account.json` identity sidecar. **Slots without a valid sidecar are hidden from `list` / `usage` / rotation and refused by `switch`**; re-run `sca save <name>` while that slot is active to recapture it. Details on `Get-Slots` and `Invoke-SaveAction`. Enumerate them **only** via `Get-CredentialSlotFiles`, which centralizes the `-Force` that dotfiles need on Unix and the sidecar exclusion.
- **File modes**: every credential-shaped file is created 0600 by `open(2)` itself, in `Write-PrivateFileBytes`, before any byte is written. On Unix `::Replace` is a bare `rename(2)`, so the destination inherits the temp file's mode; a chmod after the write would leave the tokens world-readable for its duration, and not setting the mode at all silently downgrades Claude Code's 0600 to 0644. `Repair-CredentialFileModes` (Unix only, from `Invoke-Main`) heals what older versions wrote; `New-CredentialDirectory` creates a missing `$CredDir` 0700 and never re-permissions an existing one.
- **PS version**: requires PowerShell 7.4+ (`#Requires -Version 7.4`), the lowest LTS carrying `FileStreamOptions.UnixCreateMode` (.NET 7). 7.2 and 7.3 are both EOL. Install target is `$PROFILE.CurrentUserAllHosts` (`~/.config/powershell/profile.ps1` on Linux and macOS alike).
- **Alias installer**: `sca` and `switch-claude-account` added to the PowerShell profile inside a marker-delimited block (`# === Switch Claude Account ===`). Keep the markers intact when touching `Add-To-Profile` / `Remove-From-Profile`.

## Script actions

| Action | Requires name | What it does |
|------------|---------------|--------------|
| `save` | Yes | Refuses if Claude Code is running. Captures `.credentials.json` plus an identity sidecar into a named slot. Refuses if no identity can be resolved. |
| `switch` | Optional | Refuses if Claude Code is running. Reconciles, swaps slot bytes into `.credentials.json`, writes the slot's `oauthAccount` into `~/.claude.json`. No name rotates to the next slot alphabetically (wraps). |
| `list` | No | Reconciles, then renders saved slots as `Slot \| Account` with an active-marker column. |
| `remove` | Yes | Deletes a named slot and its sidecar. Refuses to remove the active slot. |
| `usage` | Optional | Read-only. Reconciles, then calls the **undocumented** `GET /api/oauth/usage` per slot for 5h / 7d percentages. `-Json` for scripted output, `-Watch` (`-Interval <seconds>`, floor 60) for a live view. With `<name>`, renders a verbose single-slot block. |
| `monitor` | No | Live, side-effecting supervisor. Auto-rotates to the next eligible slot when the active slot reaches `-Threshold` (default 95, range 1..100). OpenCode-only; refuses if Claude Code is running. `-KeepWarm` also keeps every slot warm for the life of the watch. A positional `<name>` is ignored. |
| `warmup` | Optional | Refuses if Claude Code is running or the `claude` binary is absent. One-shot warm pass over each slot (swap, `claude -p`, mirror, usage read), then restores the original active slot. Billable, ~$0.004/slot. |
| `install` / `uninstall` | No | Adds / removes the wrapper function and aliases in the PowerShell profile. Both are exempt from `Assert-CredentialDir` and from the credentials-directory creation: they touch nothing but `$PROFILE`, so they must stay usable on a machine the other actions refuse. |
| `help` | No | Shows detailed help. |

## Editing the script

The top-level dispatcher is wrapped in `Invoke-Main` and guarded by `if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` so tests can dot-source without triggering a live run. Each action body lives in an `Invoke-*Action` function so tests can call it directly. New actions: put the body in `Invoke-<Action>Action`, add a one-line dispatch to `Invoke-Main`.

`switch`, `usage`, `list`, and `warmup` call `Invoke-Reconcile` first; `save` skips it (the explicit save IS the capture) and so does `remove`. New actions follow the same rule: reconcile when the action's output or downstream writes depend on a fresh slot file or an accurate `state.active_slot`.

## Unofficial endpoints

The `usage` action and the identity-fallback path depend on constants extracted from `claude.exe` 2.1.119, pinned at the top of `switch_claude_account.ps1` under `# --- Unofficial Claude Code OAuth-flow constants ---`. That block also carries the response schema, the per-endpoint HTTP budgets, and the re-extraction recipe.

**Undocumented and unsupported by Anthropic.** When the calls start returning 4xx after a Claude Code upgrade, re-extract using the recipe in that comment, bump the constants, and re-run the suite. The tests mock `Invoke-RestMethod` by `$Uri` and verify shape contract only; they will not catch the constants drifting out of date. Only a live `sca usage` will.

The block below it, `# --- Where Claude Code actually keeps the active login ---`, records the same kind of finding for credential storage: the two backends Claude Code ships, why macOS is not a Keychain platform, and the `tengu_windows_credman` flag that would move Windows credentials into the Credential Manager and delete `.credentials.json`. The Tests workflow re-checks it against the darwin build on `workflow_dispatch`.

## Platform gotchas

- **Atomic-rename writes survive an open Claude Code**, for `.credentials.json` only. `Set-CredentialFileAtomic` uses `MoveFileEx` semantics, which succeed against the `FILE_SHARE_DELETE` handle Claude Code holds. `save` / `switch` still refuse to run while Claude Code is open, for the different reason documented on `Test-ClaudeRunning`.
- **Execution policy** (Windows): may need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` on first run.
- **POSIX has no mandatory locking**: `FileShare` is a Win32 concept, so on Linux and macOS `::Replace` succeeds regardless of open handles and a reader keeps the old inode. Share-mode tests are therefore `-Skip:(-not $IsWindows)`, paired with a Unix test asserting the inode property instead.
- **Token expiry**: OAuth tokens refresh after roughly an hour of inactivity. Without a daemon a slot file is at most one Claude-Code refresh behind; the next reconciling action captures it. Harmless, because the slot's previous refresh token stays valid until rotated again.
- **Name sanitization**: `Get-SafeName` replaces invalid filename characters, parentheses, PowerShell wildcard brackets, and spaces with `_`, strips trailing dots, and rejects reserved device names. Windows-strict on **every** platform on purpose, via a hardcoded character class rather than `GetInvalidFileNameChars()`, so one slot name yields one filename everywhere. The reason for each class is on the function; every credential-file operation also passes `-LiteralPath` as defense in depth.

## Testing

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

Single test or context (`-FullNameFilter` is wildcard/regex against the full `Describe > Context > It` path):

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ -FullNameFilter '*Get-SafeName*' -Output Detailed"
```

The runner auto-installs Pester 5 (CurrentUser scope) on first use. PSScriptAnalyzer, if installed, runs in advisory mode. Coverage on `switch_claude_account.ps1` runs by default with a **90% gate** (`-CoverageThreshold <int>` to override, `0` disables the gate but keeps the summary); JaCoCo XML lands in `tests/TestResults/coverage.xml` (gitignored). `-SkipCoverage` for the fastest local loop.

Per-function complexity diagnostic (advisory, on-demand): `pwsh -NoProfile -File tests/Measure-Complexity.ps1`, an AST walker reporting LOC, McCabe CC, and max nesting. Rows with CC >= 10 or nest >= 4 are flagged.

### Test conventions

- **Layout**: one file per action at `tests/Invoke-<Action>Action.Tests.ps1`, plus cross-cutting suites (`Helpers`, `Profile-Install`, `Invoke-Reconcile`, `Invoke-AutoRotation`, `State-File`). Every outer `Describe` is named `'switch_claude_account'` so `-FullNameFilter` recipes work uniformly.
- **Sandboxing**: `tests/Common.ps1`, dot-sourced from each `BeforeEach`, sandboxes `$env:USERPROFILE`, `$env:HOME`, `$env:CLAUDE_CONFIG_DIR` and `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive` (both home variables, because the script reads whichever its platform uses; each test file restores the originals in its own `AfterAll`); the real profile and real `.claude` directory are never touched. It also sets `$PSStyle.OutputRendering = 'PlainText'` so string assertions see ANSI-stripped output.
- **Direct-call pattern**: the script is dot-sourced and tests call `Invoke-*Action` directly, bypassing `Invoke-Main`. The `-NoColor` `try/finally` in `Invoke-Main` therefore never fires in tests; `Common.ps1` substitutes for it.
- **Output capture**: `6>&1 | Out-String` captures `Write-Host` (information stream 6). Stream 4 (`Write-Progress`) is not captured by that pattern; relevant when adding rendering helpers.

## README image regeneration

Four SVG terminal-output examples in `docs/images/` are rendered by `tools/Render-ReadmeImages.ps1` via [`charmbracelet/freeze`](https://github.com/charmbracelet/freeze) (`winget install charmbracelet.freeze`). The harness is hand-authored ANSI matching the README literally; it does not call `Format-UsageFrame`. Palette choices, the truecolor rationale, and the README `width` contract are documented in that script. Re-run when README example numbers change, or when `Write-Color` / `Get-StatusColor` / `Get-AggregateBarColor` mappings change:

```powershell
pwsh -NoProfile -File tools/Render-ReadmeImages.ps1
```

## Default Change Workflow

After any code change, run `pwsh -NoProfile -File tests/Invoke-Tests.ps1` (the implicit parse-time check when the script is dot-sourced is the only "typecheck"). Commit and push are **not** automatic: commit only when explicitly asked, push only when explicitly asked, and "commit" does not imply "push."

## Code Comments

Comments explain **why**, not **what**; the code already states what it does, and a comment that restates it drifts out of sync.

- **Default to no comment.** Prefer a clearer name or a smaller function; comment only when the *reason* is non-obvious from the code.
- **One source of truth per rationale.** Document a non-obvious decision once at the authoritative place and reference it tersely from other call sites.
- **History lives in git.** The commit message and `git blame` carry change history, not comments. Do not write "previously X" or "the old behaviour was Y".
- **No WHAT-comments.** Don't preface a line or block with prose that paraphrases it.
- **Length is a smell.** A why-comment over ~3 lines usually signals unclear code or naming; fix the code first.
- **Earn the exception.** A long comment is justified when it records something unrecoverable from the code: a platform or API fact, a reverse-engineered constant, a measured number, or a decision with a real cost if reversed. `Write-Color` and the unofficial-constants block are the reference examples.

## Scratch files

Ad-hoc agent artifacts (screenshots, diffs, scratch scripts, traces) go under `.tmp/sessions/<session-id>/`. `.tmp/` is gitignored. Never write scratch files to `.claude/`, the repo root, or `tests/`.

## Multi-Agent Working Tree Discipline

Multiple agents may share this directory; foreign uncommitted changes and untracked files are untouchable.

1. **Foreign changes off-limits.** Never run `git checkout --`, `restore --`, `reset --hard`, `clean`, `rm`, `mv`, or `git stash pop/apply` on a path another agent modified or an untracked file another agent created. "Commit and push" does NOT authorise destructive cleanup of foreign paths.
2. **Preflight.** `git status --porcelain -u` at task start and again before `git commit`.
3. **Session-scoped scratch.** Use `<session-id>` from your runtime's session metadata if exposed; otherwise mint `YYYYMMDD-HHMMSS-<random6>`.
4. **Stashes session-scoped.** Only with explicit pathspec and tagged message: `git stash push --message "session-<id>: <reason>" -- <files>`. Bare `git stash`, `-u`, `--all`, and pop/apply of foreign stashes are forbidden.
5. **Edit and shell writes are mutually exclusive per file.** If a file was written outside the Edit tool, the cached content is stale. Re-Read before the next Edit. If Edit fails with "oldString not found", assume concurrent foreign write: surface to the user, do not guess.
6. **Worktrees.** `.claude/worktrees/<branch-name>/` is gitignored. Cleanup with `git worktree remove <path>`; no `--force`.

When your changes overlap foreign WIP in the same file, stop and ask. Do not reset, restore, or stash.

## Version Control

- [Semantic Versioning](https://semver.org/).
- Changelog follows [Common Changelog](https://common-changelog.org).
- LF line endings enforced via `.gitattributes`.
- No `Co-Authored-By` trailer in commit messages.
- A pull request body is English and answers **what** changed and **why**, names the **shortcomings** of the approach, says **which feedback** you want, and lists **what is not done**. A link supplements it and never carries it. A release groups its account by version, newest first. `docs/pull_requests.md`.

## Skills

- `plan-review` / `pr-code-review` (under `.claude/skills/`): second-pass design review before non-trivial plans; multi-pass PR review.

## Punctuation: prefer specific marks over the em dash

The em dash (`—`) is reserved for genuine emphatic interruption or a sudden break in thought. For every other use, prefer the more specific mark (rewriting the sentence is also fine), and do not strip a dash where it is the right mark: a comma for a short aside tightly bound to the sentence; parentheses for a tangential aside; a colon to introduce an explanation, list, or summary; a semicolon or period to join two related independent clauses; a rewrite or period for a rhetorical "not X, Y" contrast; an en dash (`–`) for a numeric or date range; a hyphen (`-`) for a compound modifier. The rule is to stop using `—` as a default joiner where `:`, `;`, `,`, `(...)`, or a period would be clearer.
