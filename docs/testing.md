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

### Watch smoke test

The suite and the real-terminal probe between them cover whether the watch runs, what
it writes and that it restores the terminal. What neither can judge is how a frame
*looks* to a person, because a flicker is a property of two frames a few milliseconds
apart and a wrong glyph is still a character. Run these by hand after changing the
watch engine, the frame paint or a renderer it calls:

| Check                    | Command                        | Looking for                                                                     |
| ------------------------ | ------------------------------ | ------------------------------------------------------------------------------- |
| No flicker               | `sca usage -Watch`             | Numbers update in place. No black flash, no row-by-row redraw, no scroll        |
| No flicker without color | `sca usage -Watch -NoColor`    | The same. `PlainText` must not strip the DEC envelope or the alt-buffer toggle  |
| Glyphs                   | `sca usage -Watch`             | Bars, `▶`, `…` and `—` render as themselves, never as `?`                       |
| Resize self-heals        | drag the window while watching | Layout reflows within about a second, no stale cells from the old geometry      |
| Ctrl-C returns the shell | Ctrl-C out of any of the above | Prompt back, cursor visible, pre-watch scrollback and window title restored     |
| Keep-warm startup        | `sca monitor -KeepWarm`        | Each slot in turn, then the table. **Billable, about $0.004 per slot**          |

Ctrl-C is on the list rather than in the suite because PowerShell models it as a
pipeline stop, not a terminating error. The loop tests unwind through the same
`try`/`finally` by throwing, which is a proxy and not the thing.

## Real-terminal probe

```powershell
pwsh -NoProfile -File tests/Invoke-WatchPtyProbe.ps1
```

Linux and macOS only; a no-op that exits 0 on Windows. Runs in CI on both those
matrix legs after the suite.

Pester runs with stdout redirected, because that is what a test host is, and under
redirection the console cursor API is a no-op or throws while the alternate screen
buffer is a string in a `StringWriter`. The suite can therefore prove the watch
lifecycle does not crash and cannot prove it works. This probe re-enters itself under
`script(1)`, whose pseudo terminal makes `[Console]::IsOutputRedirected` false, so the
interactive guard passes and `Enter-WatchTerminal` runs against a real console handle.
It then asserts the six VT markers that bracket a session: alt buffer in and out,
cursor hide and restore, one frame paint, one title set.

Only the network and credential boundary is stubbed, and `CLAUDE_CONFIG_DIR` is
pointed at a temporary directory so the operator's real login is never in reach. The
run bounds itself by a counted number of redraws rather than a wall clock, so it
cannot flake on a slow runner.

Windows is out of scope: it has no `script(1)`, and ConPTY is disproportionate for one
probe. It keeps the suite and the coverage gate.

## Complexity diagnostic

Advisory, on-demand, not part of the suite or any gate:

```powershell
pwsh -NoProfile -File tests/Measure-Complexity.ps1
```

An AST walker reporting LOC, McCabe CC, and max nesting per function. Rows with
CC >= 10 or nest >= 4 are flagged.
