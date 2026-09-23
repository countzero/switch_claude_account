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
default with a **97% gate** (`-CoverageThreshold <int>` to override, `0` disables the
gate but keeps the summary); JaCoCo XML lands in `tests/TestResults/coverage.xml`
(gitignored). `-SkipCoverage` for the fastest local loop.

### Reading the result

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1; "EXIT=$LASTEXITCODE"
```

Ask for the exit code in the same command as the run. It is the whole verdict, tests
and coverage gate together, and the runner's header comment owns that contract.

Never narrow the run to find the verdict instead. `-Output Detailed` prints a line per
test, so the `Tests Passed: N, Failed: N` summary and the coverage line sit under
roughly a thousand of them, and a filter picked to fit a terminal (`Select-Object
-Last`, a `Select-String` pattern) is overwhelmingly likely to cut exactly those two
lines. The only way back to them is a second full run of a suite that takes minutes.
An agent harness that truncates long output has already written the whole of it to a
file and says where: search that file rather than narrowing the command. On a nonzero
exit the failures are the `[-]` lines.

## Test conventions

- **Layout**: one file per action at `tests/Invoke-<Action>Action.Tests.ps1`, plus
  cross-cutting suites named after the helper or subsystem they cover. Every outer
  `Describe` is named `'switch_claude_account'` so `-FullNameFilter` recipes work
  uniformly.
- **Sandboxing**: `tests/Common.ps1`, dot-sourced from each `BeforeEach`, sandboxes
  `$env:USERPROFILE`, `$env:HOME`, `$env:CLAUDE_CONFIG_DIR` and
  `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive` (both home variables,
  because the script reads whichever its platform uses; each test file restores the
  originals in its own `AfterAll`); the real profile and real `.claude` directory are
  never touched. It also sets `$PSStyle.OutputRendering = 'PlainText'` so string
  assertions see ANSI-stripped output.
- **Direct-call pattern**: the script is dot-sourced and tests call `Invoke-*Action`
  directly, bypassing `Invoke-Main`. The `-NoColor` `try/finally` in `Invoke-Main`
  therefore never fires in tests; `Common.ps1` substitutes for it. `Invoke-Main`'s own
  dispatch is covered in `Helpers.Tests.ps1` by assigning the script's `Param()`
  variables in the `It` body; a `-ForEach` key may not be named `Action`, which
  collides with that parameter and expands to empty.
- **Blanket mocks**: `Common.ps1` mocks `Test-ClaudeRunning` for the whole suite so no
  action refuses on the developer's own processes. A mock cannot be lifted once set, so
  the one file that needs the real body sets `$script:ScaKeepRealClaudeRunning` before
  dot-sourcing `Common.ps1` and mocks `Get-Process` instead. Nothing else may.
- **Output capture**: `6>&1 | Out-String` captures `Write-Host` (information stream
  6). Stream 4 (`Write-Progress`) is not captured by that pattern; relevant when
  adding rendering helpers.

## The ceiling

Coverage is collected on one OS (`windows-latest` in CI, per the comment on that
workflow step), so **100% is not reachable and is not the target**. A full Windows run
lands at about **98.6%**, leaving 34 instructions in three groups. Check a new gap
against these before assuming it is a missing test.

| Group                    | Instr | What it is                                                                  |
| ------------------------ | ----- | --------------------------------------------------------------------------- |
| Unix-only code           | 25    | The non-Windows arms, all covered on the Linux and macOS legs               |
| No seam in the harness   | 5     | Failures the test host cannot provoke                                       |
| Deliberately not tested  | 4     | Defense-in-depth arms reachable only by mocking an internal                 |

**Unix-only**: the `$ScaHomeDir` and `Test-SamePath` platform arms, `UnixCreateMode`
in `Write-PrivateFileBytes`, the `HOME` name in `Assert-CredentialDir`, the 0700
`New-CredentialDirectory` path, the whole `Repair-CredentialFileModes` body, and
`Test-ClaudeRunning`'s command-line probe. Each has tests; they run on the other legs.

**No seam**: `Write-PrivateFileBytes`' cleanup needs a write that fails after the
stream opened, which means a real ENOSPC. `Enter-WatchTerminal`'s two `catch` arms
need `$Host.UI.RawUI` or the `OutputEncoding` setter to throw, and `$Host` is a
**Constant** variable, so it cannot be swapped for a stub that does.

**Not tested on purpose**: the `emailAddress`-less refusal in `Invoke-SaveAction`
(both identity sources already reject a blank address), the two `Format-AggregateBars`
clamps, and the negative-budget floor in `Format-UsageAdvisory`. Reaching any of them
means mocking the function immediately upstream, which pins the mock rather than
anything that can regress.

Raising the gate above 97 is therefore the wrong reflex: the headroom is what the next
platform-conditional branch spends, and losing it fails the run for a branch that is
tested, just not on this leg.

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
