#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the watch engine against a real terminal on Linux and macOS and
    asserts it emitted the VT control sequences that bracket a watch session.

.DESCRIPTION
    Everything in tests/Helpers.Tests.ps1 runs with stdout redirected, because
    that is what a test host is. Under redirection the console cursor API is a
    no-op or throws, and the alternate screen buffer is a string in a
    StringWriter rather than a terminal mode. So the suite can prove the watch
    lifecycle does not crash, and cannot prove it works.

    That gap hides a whole class of bug: `[Console]::CursorVisible`'s getter is
    Windows-only, so a read of it throws on Linux and macOS and aborts
    `sca usage -Watch` and `sca monitor` at startup on two of the three
    supported platforms. The Pester suite cannot catch that, because the
    interactive guard refuses before that line whenever a test is watching.

    This probe closes it by re-entering itself under script(1), whose pseudo
    terminal makes `[Console]::IsOutputRedirected` false. The real guard then
    passes and the real `Enter-WatchTerminal` runs against a real console
    handle. script(1) records everything the watch painted, and the outer pass
    asserts the markers are present.

    Only the network and credential boundary is stubbed. The terminal
    lifecycle, the poll step, the renderers and the frame paint are the
    shipping code.

    Windows has no script(1) and is not covered here; ConPTY would be
    disproportionate for one probe. Windows keeps the Pester suite and the
    coverage gate.

.PARAMETER Ticks
    Redraw iterations before the run stops itself. The bound is a counted
    number of `Start-Sleep` calls rather than a wall-clock timeout, so the
    probe cannot flake on a slow runner.

.PARAMETER Inner
    Internal. Marks the re-entry that runs under script(1); not for direct use.

.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-WatchPtyProbe.ps1
#>

[CmdletBinding()]
Param (
    [int]    $Ticks = 3,
    [switch] $Inner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Sentinel that ends the run. The watch loop is `while ($true)` with no exit,
# so the only way out is to throw from something it calls every tick, and
# unwinding through its real try/finally is what makes the restore markers
# below meaningful rather than incidental.
$script:StopSentinel = 'pty-probe-stop'
$script:DoneMarker   = 'PTY-PROBE-COMPLETED'

# ---------------------------------------------------------------------------
# Inner pass: runs under the pseudo terminal.
# ---------------------------------------------------------------------------
if ($Inner) {
    # Never let the probe see the operator's real login, even though the two
    # functions that would read it are stubbed below. AGENTS.md -> Security
    # Rules: no side-effecting action against the real ~/.claude.
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) "sca-pty-probe-$PID"
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $env:CLAUDE_CONFIG_DIR = $sandbox

    . (Join-Path $PSScriptRoot '..' 'switch_claude_account.ps1')

    # Stub the boundary only. Both shadow the dot-sourced definitions because
    # function lookup walks the scope chain at call time.
    function Invoke-Reconcile { [pscustomobject]@{ Captured = $true } }

    function Get-UsageSnapshot {
        [pscustomobject]@{
            NoSlots        = $false
            HasRateLimited = $false
            Results        = @(
                [pscustomobject]@{
                    Name     = 'alpha'
                    Status   = 'ok'
                    IsActive = $true
                    Email    = $null
                    Data     = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = 10; resets_at = $null }
                        seven_day = [pscustomobject]@{ utilization = 20; resets_at = $null }
                    }
                    Error            = $null
                    IsCachedFallback = $false
                }
            )
        }
    }

    $script:tickCount  = 0
    $script:tickBudget = $Ticks
    function Start-Sleep {
        Param ([int] $Seconds, [int] $Milliseconds)

        $script:tickCount++
        if ($script:tickCount -ge $script:tickBudget) { throw $script:StopSentinel }
    }

    try {
        Invoke-UsageWatch
    } catch {
        if ($_.Exception.Message -ne $script:StopSentinel) { throw }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Printed after the watch has restored the terminal, so its presence
    # separates "the watch ran and exited cleanly" from "the markers are
    # missing because it crashed".
    Write-Host $script:DoneMarker
    exit 0
}

# ---------------------------------------------------------------------------
# Outer pass: allocate the pseudo terminal, then read back what was painted.
# ---------------------------------------------------------------------------
if ($IsWindows) {
    Write-Host '[PtyProbe] Skipped: script(1) is a Unix tool and Windows is covered by the Pester suite.'
    exit 0
}
if (-not (Get-Command script -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'script(1) not found. It ships with util-linux on Linux and with the base system on macOS; without it this probe cannot allocate a pseudo terminal.'
}

$typescript = Join-Path ([IO.Path]::GetTempPath()) "sca-pty-probe-$PID.typescript"
$self       = $PSCommandPath

try {
    # util-linux and BSD script take their arguments in different orders and
    # the BSD one has no -e, so the exit status is not comparable between
    # them. The verdict therefore comes from the recorded output, never from
    # $LASTEXITCODE.
    if ($IsMacOS) {
        & script -q $typescript pwsh -NoProfile -File $self -Inner -Ticks $Ticks | Out-Null
    } else {
        & script -qec "pwsh -NoProfile -File '$self' -Inner -Ticks $Ticks" $typescript | Out-Null
    }

    if (-not (Test-Path -LiteralPath $typescript)) {
        throw "script(1) produced no typescript at $typescript; nothing was recorded, so nothing is proven."
    }
    $recorded = [IO.File]::ReadAllText($typescript)

    if ($recorded -notmatch [regex]::Escape($script:DoneMarker)) {
        throw @"
The watch did not reach the end of its run under a real terminal. This is the
failure the probe exists to catch: the recorded session is below.

$recorded
"@
    }

    # Each pair is one half of the terminal contract. The enters prove the
    # watch set the terminal up against a real console handle; the leaves
    # prove it put everything back, which is what stops a Ctrl-C from
    # stranding the user in the alternate buffer with no cursor.
    $markers = [ordered]@{
        'alt buffer entered  (ESC[?1049h)' = "`e[?1049h"
        'cursor hidden       (ESC[?25l)'   = "`e[?25l"
        'frame painted       (ESC[?2026h)' = "`e[?2026h"
        'title set           (ESC]0;)'     = "`e]0;"
        'cursor restored     (ESC[?25h)'   = "`e[?25h"
        'alt buffer left     (ESC[?1049l)' = "`e[?1049l"
    }

    $missing = @()
    foreach ($name in $markers.Keys) {
        $found = $recorded.Contains($markers[$name])
        "{0} {1}" -f $(if ($found) { '  ok  ' } else { ' MISS ' }), $name
        if (-not $found) { $missing += $name }
    }

    if ($missing.Count -gt 0) {
        throw "Missing $($missing.Count) of $($markers.Count) terminal markers: $($missing -join '; ')"
    }

    Write-Host "[PtyProbe] All $($markers.Count) markers present after $Ticks ticks under a real terminal."
} finally {
    Remove-Item -LiteralPath $typescript -Force -ErrorAction SilentlyContinue
}
