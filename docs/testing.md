# Testing

Read when writing or running a Pester test, or when the coverage gate is red.

## Running the suite

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

Single test or context (`-FullNameFilter` is wildcard/regex against the full
`Describe > Context > It` path):

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ -FullNameFilter '*Get-SafeName*' -Output Detailed"
```

The runner auto-installs Pester 5 (CurrentUser scope) on first use. PSScriptAnalyzer,
if installed, runs in advisory mode. Coverage on `switch_claude_account.ps1` runs by
default with a **90% gate** (`-CoverageThreshold <int>` to override, `0` disables the
gate but keeps the summary); JaCoCo XML lands in `tests/TestResults/coverage.xml`
(gitignored). `-SkipCoverage` for the fastest local loop.

## Test conventions

- **Layout**: one file per action at `tests/Invoke-<Action>Action.Tests.ps1`, plus
  cross-cutting suites (`Helpers`, `Profile-Install`, `Invoke-Reconcile`,
  `Invoke-AutoRotation`, `State-File`). Every outer `Describe` is named
  `'switch_claude_account'` so `-FullNameFilter` recipes work uniformly.
- **Sandboxing**: `tests/Common.ps1`, dot-sourced from each `BeforeEach`, sandboxes
  `$env:USERPROFILE`, `$env:HOME`, `$env:CLAUDE_CONFIG_DIR` and
  `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive` (both home variables,
  because the script reads whichever its platform uses; each test file restores the
  originals in its own `AfterAll`); the real profile and real `.claude` directory are
  never touched. It also sets `$PSStyle.OutputRendering = 'PlainText'` so string
  assertions see ANSI-stripped output.
- **Direct-call pattern**: the script is dot-sourced and tests call `Invoke-*Action`
  directly, bypassing `Invoke-Main`. The `-NoColor` `try/finally` in `Invoke-Main`
  therefore never fires in tests; `Common.ps1` substitutes for it.
- **Output capture**: `6>&1 | Out-String` captures `Write-Host` (information stream
  6). Stream 4 (`Write-Progress`) is not captured by that pattern; relevant when
  adding rendering helpers.

## What the suite cannot catch

The tests mock `Invoke-RestMethod` by `$Uri` and verify shape contract only, so they
pass whether or not the pinned OAuth constants still match the shipping Claude Code
build. Only a live `sca usage` detects that drift
(`docs/claude-code-internals.md` → *Re-extraction recipe*).

## Complexity diagnostic

Advisory, on-demand, not part of the suite or any gate:

```powershell
pwsh -NoProfile -File tests/Measure-Complexity.ps1
```

An AST walker reporting LOC, McCabe CC, and max nesting per function. Rows with
CC >= 10 or nest >= 4 are flagged.
