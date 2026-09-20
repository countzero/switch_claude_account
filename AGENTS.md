# AGENTS.md

This file is the canonical agent-instructions source for this repository, read natively by both OpenCode and Claude Code (2.1.277+). Single-file PowerShell tool: core logic lives in `switch_claude_account.ps1`; tests live in `tests/` and use Pester 5. It carries the always-on rules as one invariant per area; the contracts behind them are the documents under `docs/`, read on demand through *Reference* at the end.

## Security Rules

This repository's subject is live OAuth credentials. Three rules, in force in every session:

- **Never surface a token.** Do not read, print, or copy `.credentials.json`, a `.credentials.<name>(<email>).json` slot file, or an `accessToken` / `refreshToken` value into a transcript, a scratch file, a test fixture, or a commit. Inspect such a file from the outside only: its length, its mode, its mtime, whether a hash matches. A masked or partial read is still a read.
- **Never commit an identity.** Slot filenames carry account email addresses and sidecars carry account uuids. Neither goes into a commit message, a changelog entry, a pull request body, or a pasted `sca usage` / `sca list` output. Examples use `alice` / `bob` and an all-zero uuid.
- **Never run a side-effecting action against the real `~/.claude`.** `save`, `switch`, `remove`, `warmup` and `monitor` write the user's live login, and `warmup` and `monitor -KeepWarm` additionally spend money (~$0.004/slot). Verify through `tests/`, which sandboxes both home variables and `CLAUDE_CONFIG_DIR` into `$TestDrive`. Ask before running any of them for real.

## Documentation

`AGENTS.md` carries orientation and repo-global rules only, one invariant per area, each ending in a pointer. A contract, a procedure, or the reasoning behind a decision lives in the reference document of that task; how a function works lives in a comment on that function, never here. A rule stated elsewhere appears here only as `` `docs/<file>.md` → *Section* ``, and a pointed-at heading is an interface: renaming one means re-pointing its callers. Describe the **current** shape only, and when you remove a design from the code remove its references here too. Budgets, measured with `(Get-Item <file>).Length`: this file about 12,000 bytes and never over 18,500; a reference document about 12,000 and never over 24,000. The routing table, the `AGENTS.md` / `README.md` split and the review checklist are `docs/documentation.md`.

## Key facts

- **Supported platforms**: Windows, Linux, and macOS, all three covered by the CI matrix.
- **Requires PowerShell 7.4+** (`#Requires -Version 7.4`), the lowest LTS carrying `FileStreamOptions.UnixCreateMode`. Install target is `$PROFILE.CurrentUserAllHosts`.
- **Four artifacts**: `.credentials.json` (the active login, Claude Code's own), a slot as `.credentials.<name>(<email>).json` plus its `.account.json` identity sidecar, `.sca-state.json` (which slot is active), and `~/.claude.json` (Claude Code's config, whose `oauthAccount` block is the "Email:" in `/status`).
- **`$CredDir` may be `$null`.** When neither `CLAUDE_CONFIG_DIR` nor a home directory resolves, every derived path stays `$null` rather than throwing at load, so `help` and `-Version` still work; `Assert-CredentialDir` refuses the rest.
- **Enumerate slots only via `Get-CredentialSlotFiles`**, which centralizes the `-Force` that dotfiles need on Unix and the sidecar exclusion. A slot without a valid sidecar is hidden from `list` / `usage` / rotation and refused by `switch`.
- **Every credential-shaped file is created by `Write-PrivateFileBytes` and moved by `Set-CredentialFileAtomic`.** Both are load-bearing, for the 0600 mode and for surviving the handle Claude Code holds. Do not hand-roll a write.
- What a user sees of the above is `README.md` → *Platform Notes*; the contracts and the reasoning are `docs/architecture.md`.

## Script actions

`save`, `switch`, `list`, `remove`, `usage`, `monitor`, `warmup`, `install`, `uninstall`, `help`. The list is the `ValidateSet` on `$Action`, each one's contract is its `Invoke-<Action>Action` function, and the user-facing summary is `sca help` and `README.md` → *Usage*. Which of them refuse beside a running Claude Code is `Test-ClaudeRunning`; which reconcile first is below.

## Editing the script

The top-level dispatcher is wrapped in `Invoke-Main` and guarded by `if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` so tests can dot-source without triggering a live run. Each action body lives in an `Invoke-*Action` function so tests can call it directly. New actions: put the body in `Invoke-<Action>Action`, add a one-line dispatch to `Invoke-Main`.

`switch`, `usage`, `list`, and `warmup` call `Invoke-Reconcile` first; `save` skips it (the explicit save IS the capture) and so does `remove`. New actions follow the same rule: reconcile when the action's output or downstream writes depend on a fresh slot file or an accurate `state.active_slot`.

## Unofficial endpoints

The `usage` action and the identity-fallback path depend on constants extracted from `claude.exe`, pinned in `switch_claude_account.ps1` under `# --- Unofficial Claude Code OAuth-flow constants ---` with the measured HTTP budgets and retry policy. **Undocumented and unsupported by Anthropic**: when the calls start returning 4xx after a Claude Code upgrade, re-extract, bump the constants, and re-run the suite. The tests verify shape contract only and will not catch the constants drifting; only a live `sca usage` will. The provenance, the re-extraction recipe, the response schemas and that file's admission rule are `docs/claude-code-internals.md`.

## Platform gotchas

- **Hot-swapping a live client is supported.** Every action but `save` runs with Claude Code open, the warm round-robin included; `save` alone refuses. `Test-ClaudeRunning` owns the evidence and that one exception.
- **POSIX has no mandatory locking**, so a share-mode test is `-Skip:(-not $IsWindows)` and pairs with a Unix test asserting the inode property instead.
- **`Get-SafeName` is Windows-strict on every platform**, and every credential-file operation also passes `-LiteralPath` as defense in depth.
- **Guard every `System.Console` call.** `[Console]::CursorVisible` is Windows-only to read and throws off an attached console to write; a failed capture stays `$null` so the restore is skipped rather than defaulted to a wrong value.
- The reasoning for each of these, and token expiry, are `docs/architecture.md` → *Platform behavior*.

## Testing

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1; "EXIT=$LASTEXITCODE"
```

The exit code is the verdict, so never narrow the run to find one: a filter that fits the output to a terminal drops the summary and costs a second full run. Coverage on `switch_claude_account.ps1` runs by default behind a **90% gate**; `-SkipCoverage` for the fastest local loop. One file per action at `tests/Invoke-<Action>Action.Tests.ps1`, every outer `Describe` named `'switch_claude_account'`, and `tests/Common.ps1` dot-sourced from each `BeforeEach` to sandbox both home variables, `CLAUDE_CONFIG_DIR` and `$PROFILE.CurrentUserAllHosts` into `$TestDrive`. The filter recipes, the direct-call pattern, the output-capture rule, reading the result and the complexity diagnostic are `docs/testing.md`.

## README image regeneration

`pwsh -NoProfile -File tools/Render-ReadmeImages.ps1` re-renders the four SVGs in `docs/images/` via `charmbracelet/freeze`. Re-run when a README example number changes, or when a `Write-Color` / `Get-StatusColor` / `Get-AggregateBarColor` mapping changes. That script's header owns the palette, the truecolor rationale and the README `width` contract.

## Default Change Workflow

After any code change, run `pwsh -NoProfile -File tests/Invoke-Tests.ps1` (the implicit parse-time check when the script is dot-sourced is the only "typecheck"). Commit and push are **not** automatic: commit only when explicitly asked, push only when explicitly asked, and "commit" does not imply "push."

## Code Comments

Comments explain **why**, not **what**. Default to no comment; prefer a clearer name or a smaller function. Document a rationale once at its authoritative place and reference it tersely elsewhere. History lives in git: never "previously X". A why-comment over ~3 lines is a smell unless it records something unrecoverable from the code, a platform fact, a reverse-engineered constant, or a measured number. `docs/conventions.md` → *Comments*.

## Scratch files

Every ad-hoc artifact of an agent session (screenshots, diffs, scratch scripts, traces: anything not meant to be committed) goes under `.tmp/sessions/<session-id>/` at the repo root, `<session-id>` per rule 3 in *Multi-Agent Working Tree Discipline*; `.tmp/` is gitignored. Nowhere else: not `.claude/`, not the repo root, not `tests/` or `tools/`, and not the operating-system temp directory under any name or helper (`$env:TEMP`, `os.tmpdir()`), which sits outside the workspace.

## Multi-Agent Working Tree Discipline

Multiple agents may share this directory; foreign uncommitted changes and untracked files are untouchable.

1. **Foreign changes off-limits.** Never run `git checkout --`, `restore --`, `reset --hard`, `clean`, `rm`, `mv`, or `git stash pop/apply` on a path another agent modified or an untracked file another agent created. "Commit and push" does NOT authorize destructive cleanup of foreign paths.
2. **Preflight.** `git status --porcelain -u` at task start and again before `git commit`.
3. **Session-scoped scratch.** At task start take `SESSION_ID` from your session-start context (Claude Code) or the shell environment (OpenCode, where it is spent unread in a command and read once with `Write-Output $env:SESSION_ID` for a Write or Edit path; `.opencode/plugins/session-id-injector.js` has why it is not in the prompt), use it as `<session-id>` and write every scratch artifact into `.tmp/sessions/<session-id>/` under a readable name (`foreign-baseline.diff`). A resumed session gets the same id; unset, it collapses the path to `.tmp/sessions/`, so without one mint `YYYYMMDD-HHMMSS-<random6>` and lose resume support.
4. **Stashes session-scoped.** Only with explicit pathspec and tagged message: `git stash push --message "session-<id>: <reason>" -- <files>`. Bare `git stash`, `-u`, `--all`, and pop/apply of foreign stashes are forbidden.
5. **Edit and shell writes are mutually exclusive per file.** If a file was written outside the Edit tool, the cached content is stale. Re-Read before the next Edit. If Edit fails with "oldString not found", assume concurrent foreign write: surface to the user, do not guess.
6. **Worktrees.** `.claude/worktrees/<branch-name>/` is gitignored. Cleanup with `git worktree remove <path>`; no `--force`.

When your changes overlap foreign WIP in the same file, stop and ask. Do not reset, restore, or stash.

## Version Control

- [Semantic Versioning](https://semver.org/). LF line endings enforced via `.gitattributes`.
- **Branches**: `main` and `develop` are long-lived. A pull request takes `develop` into `main` and carries a release.
- **Commits** take the [Conventional Commits](https://www.conventionalcommits.org/) form, `type(scope): imperative summary`, with the *why* in the body and no `Co-Authored-By` trailer. Common Changelog argues against this convention; the reason this repository keeps it anyway is `docs/conventions.md` → *Commit messages*.
- **Changelog** follows [Common Changelog](https://common-changelog.org) with two deliberate deviations, each recorded with its reason in `docs/conventions.md` → *Changelog*. An entry is one imperative line of around 100 characters saying what changed, never why; the why is the commit body. Edit `CHANGELOG.md` only as a step of a release.
- A **pull request** body is English and answers **what** changed and **why**, names the **shortcomings** of the approach, says **which feedback** you want, and lists **what is not done**. A link supplements it and never carries it. A release groups its account by version, newest first. `docs/pull_requests.md`.

## Skills

- `plan-review` / `pr-code-review` (under `.claude/skills/`): second-pass design review before non-trivial plans; multi-pass PR review.

## Output Formatting

The em dash (`—`) is reserved for genuine emphatic interruption or a sudden break in thought. Everywhere else reach for the specific mark: a comma for a short aside, parentheses for a tangential one, a colon to introduce, a semicolon or period to join two independent clauses, an en dash (`–`) for a range, a hyphen for a compound modifier. Do not strip one where it is the right mark. Pad every cell of a markdown table so all cells in a column share one width. American spelling in code, comments and prose. `docs/conventions.md` → *Punctuation*, *Spelling*.

## Reference

All under `docs/`; the sentence is the document's own opening line.

| Document                   | When to read                                                                            |
| -------------------------- | --------------------------------------------------------------------------------------- |
| `documentation.md`         | Read before adding or moving a paragraph in `AGENTS.md`, `docs/`, a skill or the README |
| `conventions.md`           | Read when writing or reviewing code, a comment, a commit message or changelog text      |
| `architecture.md`          | Read when changing how a credential, slot, sidecar or state file is resolved or written |
| `testing.md`               | Read when writing or running a Pester test, or when the coverage gate is red            |
| `claude-code-internals.md` | Read when an unofficial endpoint or constant needs re-verifying against a new build     |
| `pull_requests.md`         | Read before opening a pull request or writing its description                           |
