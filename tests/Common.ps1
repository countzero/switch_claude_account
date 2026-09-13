# Per-test sandbox setup, dot-sourced from each *.Tests.ps1 file's BeforeEach.
#
# This file is intentionally NOT a function library. Wrapping the body in a
# function would break PowerShell scoping: `. $script:ScriptPath` inside a
# function dot-sources into the function's local scope, so the script's
# top-level $CredDir / $CredFile / $ProfilePath bindings, and the functions
# defined under switch_claude_account.ps1, would not be visible to the
# enclosing It block. Dot-sourcing this snippet from a BeforeEach script
# block instead places every assignment and function into the BeforeEach's
# test scope, which is exactly what Pester 5 expects.
#
# Each test file additionally captures $env:USERPROFILE, $env:HOME,
# $env:CLAUDE_CONFIG_DIR and $global:PROFILE in its own BeforeAll and restores
# them in its own AfterAll. Those captures must run exactly once per file, so
# they live there rather than here.

$script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\switch_claude_account.ps1')).Path

# Fresh sandbox per test: isolated user profile + fake PS profile path.
# $TestDrive is persistent within a Describe/Context in Pester 5, so we
# explicitly wipe the sandbox to prevent test-to-test leakage.
$script:SandboxHome = Join-Path $TestDrive 'home'
if (Test-Path -LiteralPath $script:SandboxHome) {
    Remove-Item -LiteralPath $script:SandboxHome -Recurse -Force
}
New-Item -ItemType Directory -Path $script:SandboxHome -Force | Out-Null

# Both home variables, because the script reads whichever its platform uses:
# $env:USERPROFILE on Windows, $env:HOME elsewhere. Setting only one would
# leave the suite testing the developer's real ~/.claude on the other
# platform, which is exactly how the missing Unix support went unnoticed.
$env:USERPROFILE = $script:SandboxHome
$env:HOME        = $script:SandboxHome

# Cleared so a developer (or CI job) that legitimately sets CLAUDE_CONFIG_DIR
# does not silently redirect $CredDir out of the sandbox and onto their real
# credentials. Individual tests that exercise the variable set it themselves.
$env:CLAUDE_CONFIG_DIR = $null

$script:FakeProfilePath = Join-Path $TestDrive 'profile.ps1'
if (Test-Path -LiteralPath $script:FakeProfilePath) {
    Remove-Item -LiteralPath $script:FakeProfilePath -Force
}
$global:PROFILE = [pscustomobject]@{ CurrentUserAllHosts = $script:FakeProfilePath }

# Dot-sourcing rebinds script-scope $CredDir / $CredFile / $ProfilePath /
# $ClaudeJsonPath against the sandboxed environment. The dot-source guard
# stops Invoke-Main from running, so tests drive individual functions.
. $script:ScriptPath

# Force PlainText rendering for the entire test session. With every colored
# call site now going through Write-Color (which emits inline ANSI SGR
# codes), PowerShell's WriteImpl -> GetOutputString filter strips those
# codes when OutputRendering=PlainText. That keeps every existing
# string-match assertion in the suite valid against the ANSI-stripped
# byte stream -- no test pattern needs to know about ANSI codes. Tests
# that need to verify the no-color toggle itself (Helpers.Tests.ps1's
# 'No-color mode' Context) override this to 'Host' in their It bodies
# and restore via try/finally.
$PSStyle.OutputRendering = 'PlainText'

# Default /api/oauth/profile mock: fails so rows have no email and the
# two-line display short-circuits. Tests that exercise email display
# override this with their own ParameterFilter mock. The filter makes
# sure we do not accidentally swallow usage/token-endpoint calls.
Mock Invoke-RestMethod -ParameterFilter {
    $Uri -eq 'https://api.anthropic.com/api/oauth/profile'
} -MockWith {
    throw [System.Exception]::new('profile endpoint unmocked in this test')
}

# Default Test-ClaudeRunning mock: returns $false so save / switch don't
# refuse to operate when no real claude.exe is in the test environment.
# The few tests that exercise the running guard override this locally.
Mock Test-ClaudeRunning -MockWith { $false }

# Collapse production sleep tunables to zero so the suite does not
# spend real seconds inside mocked 429 paths. The retry logic is still
# exercised end-to-end (mock invocation counts, final-status branches)
# because $Script:TokenRefreshRetryMax stays at its production value;
# only the wall-clock wait between attempts goes to zero. Same trick
# for $Script:WarmupSpacingMs so the warmup loop's per-slot 300 ms
# pacing does not multiply across many-slot tests.
$Script:TokenRefreshRetryDelayMs   = 0
$Script:WarmupSpacingMs            = 0

# --- Test fixtures --------------------------------------------------------
#
# New-SlotPair: build a slot file + sidecar pair as production save would
# produce. Without a sidecar, Get-Slots hides the slot per the post-v2.1.0
# contract, so every test that creates a slot via the filesystem (rather
# than via Invoke-SaveAction) needs a paired sidecar to remain visible.
#
# This helper is intentionally a thin wrapper: it writes the bytes you
# pass to the slot file and a synthetic sidecar with stable test values
# in the oauthAccount block. Tests that need to assert on specific
# sidecar values override -OAuthAccount; the default produces predictable
# accountUuid/orgUuid strings derived from the slot name.
function New-SlotPair {
    Param (
        [Parameter(Mandatory)] [string] $CredDir,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Email,
        $Content = 'X',                              # bytes (string -> UTF8) or byte[]
        [pscustomobject] $OAuthAccount               # optional sidecar oauthAccount override
    )

    if (-not (Test-Path -LiteralPath $CredDir)) {
        New-Item -ItemType Directory -Path $CredDir -Force | Out-Null
    }

    if ($Email) {
        $slotPath = Join-Path $CredDir ".credentials.$Name($Email).json"
    } else {
        $slotPath = Join-Path $CredDir ".credentials.$Name.json"
    }

    if ($Content -is [byte[]]) {
        [System.IO.File]::WriteAllBytes($slotPath, $Content)
    } else {
        Set-Content -LiteralPath $slotPath -Value $Content -NoNewline -Encoding utf8NoBOM
    }

    if (-not $OAuthAccount) {
        $sidecarEmail = if ($Email) { $Email } else { "$Name@test.local" }
        $OAuthAccount = [pscustomobject]@{
            accountUuid      = "test-acct-uuid-$Name"
            emailAddress     = $sidecarEmail
            organizationUuid = 'test-org-uuid'
            displayName      = $sidecarEmail
            organizationName = 'test-org'
        }
    }

    $sidecarPath = $slotPath -replace '\.json$', '.account.json'
    $payload = [ordered]@{
        schema       = 1
        captured_at  = '2026-04-26T00:00:00.000Z'
        source       = 'test'
        oauthAccount = [ordered]@{
            accountUuid      = $OAuthAccount.accountUuid
            emailAddress     = $OAuthAccount.emailAddress
            organizationUuid = $OAuthAccount.organizationUuid
            displayName      = $OAuthAccount.displayName
            organizationName = $OAuthAccount.organizationName
        }
    }
    Set-Content -LiteralPath $sidecarPath -Value ($payload | ConvertTo-Json -Depth 5) -NoNewline -Encoding utf8NoBOM

    return $slotPath
}

# Set-SandboxClaudeJson: write a minimal ~/.claude.json into the sandbox
# with the given oauthAccount. Used by Invoke-SaveAction tests to exercise
# the "primary identity from ~/.claude.json" path. Default produces a
# fully-populated oauthAccount so Get-OAuthAccountFromClaudeJson succeeds.
function Set-SandboxClaudeJson {
    Param (
        [string] $Email             = 'test@example.com',
        [string] $AccountUuid       = '11111111-1111-1111-1111-111111111111',
        [string] $OrganizationUuid  = '22222222-2222-2222-2222-222222222222',
        [string] $DisplayName       = 'Test User',
        [string] $OrganizationName  = 'test-org',
        [hashtable] $ExtraTopLevel  = @{}
    )

    # Mirror the on-disk shape Claude Code 2.1.119 writes: oauthAccount
    # carries the cached metadata fields populateOAuthAccountInfoIfNeeded
    # (ab6) checks before re-fetching the profile. We populate them all
    # so post-write ~/.claude.json behaves as if Claude Code had cached
    # the identity already.
    $oa = [ordered]@{
        accountUuid                 = $AccountUuid
        emailAddress                = $Email
        organizationUuid            = $OrganizationUuid
        hasExtraUsageEnabled        = $false
        billingType                 = 'stripe_subscription'
        accountCreatedAt            = '2026-01-01T00:00:00Z'
        subscriptionCreatedAt       = '2026-01-01T00:00:00Z'
        ccOnboardingFlags           = @{}
        claudeCodeTrialEndsAt       = $null
        claudeCodeTrialDurationDays = $null
        displayName                 = $DisplayName
        organizationRole            = 'user'
        workspaceRole               = $null
        organizationName            = $OrganizationName
    }
    $top = [ordered]@{
        numStartups        = 1
        autoUpdates        = $true
        oauthAccount       = $oa
        hasCompletedOnboarding = $true
    }
    foreach ($k in $ExtraTopLevel.Keys) { $top[$k] = $ExtraTopLevel[$k] }

    Set-Content -LiteralPath $ClaudeJsonPath -Value ($top | ConvertTo-Json -Depth 6) -NoNewline -Encoding utf8NoBOM
}
