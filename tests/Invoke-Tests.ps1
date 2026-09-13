#Requires -Version 7.4

# Local test runner. Auto-installs Pester 5 on first use, runs
# PSScriptAnalyzer (Warning advisory, Error fatal), then invokes the
# Pester suite. By default, code coverage is collected on
# switch_claude_account.ps1 and a summary line is printed; use
# -SkipCoverage for the fastest local iteration loop. Exit code is 1
# if any test failed or coverage falls below -CoverageThreshold
# (default 90), 0 otherwise.

[CmdletBinding()]
Param (
    [switch] $SkipCoverage,
    # Minimum command-coverage percent required to pass the run. Wired
    # into Pester's CodeCoverage.CoveragePercentTarget so the gate is
    # owned by the same component that computes the number; below the
    # threshold, $result.Result becomes 'Failed' and the exit predicate
    # below honors it. Pass -CoverageThreshold 0 to disable the gate
    # without losing the printed summary (-SkipCoverage skips both).
    [ValidateRange(0, 100)]
    [int] $CoverageThreshold = 90
)

$ErrorActionPreference = 'Stop'

# --- Pester 5 (auto-install if missing) ---
$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Host 'Pester 5 not found; installing to CurrentUser scope...' -ForegroundColor Cyan
    Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
}

Import-Module Pester -MinimumVersion 5.5.0

# --- PSScriptAnalyzer (Warning advisory, Error fatal) ---
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\switch_claude_account.ps1')).Path
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $settings = (Resolve-Path (Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1')).Path
    $findings = Invoke-ScriptAnalyzer -Path $scriptPath -Settings $settings
    if ($findings) {
        Write-Host ''
        Write-Host 'PSScriptAnalyzer findings:' -ForegroundColor Yellow
        $findings | Format-Table Severity, RuleName, Line, Message -AutoSize | Out-String | Write-Host
        # Error severity fails the run; Warning stays advisory. The
        # repo's PSScriptAnalyzerSettings.psd1 silences five rules
        # documented there as deliberate design choices, so the
        # remaining Warning surface is small and a new Error-level
        # finding is almost always a genuine bug.
        if ($findings | Where-Object { $_.Severity -eq 'Error' }) {
            Write-Host 'PSScriptAnalyzer: Error-severity findings present; failing run.' -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host 'PSScriptAnalyzer: no findings.' -ForegroundColor Green
    }
} else {
    Write-Host 'PSScriptAnalyzer not installed; skipping (Install-Module PSScriptAnalyzer -Scope CurrentUser).' -ForegroundColor DarkGray
}

# --- Pester suite ---
$config = New-PesterConfiguration
$config.Run.Path         = $PSScriptRoot
$config.Run.PassThru     = $true
$config.Output.Verbosity = 'Detailed'

if (-not $SkipCoverage) {
    # Ensure the output directory exists; Pester does not create it.
    # tests/TestResults/ is already gitignored.
    $coverageDir = Join-Path $PSScriptRoot 'TestResults'
    if (-not (Test-Path -LiteralPath $coverageDir)) {
        New-Item -ItemType Directory -Path $coverageDir -Force | Out-Null
    }

    $config.CodeCoverage.Enabled        = $true
    # CodeCoverage.Path accepts string[]; wrap defensively so older 5.x
    # versions don't trip on a bare string. We measure ONLY the script
    # under test, not the test files themselves.
    $config.CodeCoverage.Path           = @($scriptPath)
    # Pester 5.2+ profiler-based collector: faster than the legacy
    # breakpoint-based path and does not mutate the script during the
    # run via Set-PSBreakpoint.
    $config.CodeCoverage.UseBreakpoints = $false
    $config.CodeCoverage.OutputFormat   = 'JaCoCo'
    $config.CodeCoverage.OutputPath     = Join-Path $coverageDir 'coverage.xml'
    # Pester-native gate: below this percent, $result.Result becomes
    # 'Failed' and the exit predicate below picks it up. Keeping the
    # threshold inside Pester avoids a second, slightly-different
    # percent calculation drifting out of sync with the displayed value.
    $config.CodeCoverage.CoveragePercentTarget = $CoverageThreshold
}

$result = Invoke-Pester -Configuration $config

# --- Coverage summary + gate (when enabled) ---
# $coverageGateFailed is the explicit signal the exit predicate
# consumes. We do NOT rely on Pester's $result.Result here: Pester
# 5.7.1 sets CodeCoverage.CoveragePercentTarget on the config but
# does NOT propagate a missed target into $result.Result, so the
# native target alone leaves exit code 0 on a coverage shortfall.
# The native target stays set (cheap; documents intent; may start
# flipping $result.Result in a future Pester); the authoritative
# gate decision is computed here from the same percent we display.
$coverageGateFailed = $false
if (-not $SkipCoverage -and $result.CodeCoverage) {
    $cov = $result.CodeCoverage
    Write-Host ''
    if ($cov.CommandsAnalyzedCount -le 0) {
        # No commands measured (configuration error or a brand-new
        # collector behavior change). Skip the gate rather than fail
        # spuriously at 0%; the missing commands surface elsewhere.
        Write-Host 'Code coverage: no commands analyzed (gate skipped).' -ForegroundColor DarkGray
    } else {
        # CommandsExecutedCount / CommandsAnalyzedCount has been stable
        # across Pester 5.0+. Direct $cov.CoveragePercent is available
        # in newer 5.x but not all releases.
        $pct = 100.0 * $cov.CommandsExecutedCount / $cov.CommandsAnalyzedCount
        # InvariantCulture so the decimal is always '.' regardless of
        # host locale; keeps the line parseable by any consumer.
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        $pctText   = $pct.ToString('N1', $invariant)
        $passed    = $pct -ge $CoverageThreshold
        $color     = if ($passed) { 'Green' } else { 'Red' }
        Write-Host ('Code coverage: {0}% (threshold {1}%)' -f $pctText, $CoverageThreshold) -ForegroundColor $color
        if (-not $passed) {
            # Show two extra decimals on failure so a value that rounds
            # up to the threshold (e.g. 89.95 -> 90.0) cannot make the
            # red line look like a contradiction with the summary above.
            $pctPrecise = $pct.ToString('N2', $invariant)
            Write-Host ('Coverage gate FAILED: {0}% < {1}% minimum.' -f $pctPrecise, $CoverageThreshold) -ForegroundColor Red
            $coverageGateFailed = $true
        }
    }
}

# --- Exit code ---
# Nonzero iff any test failed OR the coverage gate was not met.
if ($result.FailedCount -gt 0 -or $coverageGateFailed) {
    exit 1
} else {
    exit 0
}
