#Requires -Version 7.4
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Switch between multiple Claude Code accounts on Windows, Linux, and macOS.

.DESCRIPTION
This script manages named credential slots for Claude Code. It saves, switches,
lists, and removes account slots by copying credentials files within the .claude
directory. Each slot is stored as a separate .credentials.<name>(<email>).json file.

.PARAMETER Action
Specifies the action to perform. Supported values are: save, switch, list, remove,
usage, monitor, warmup, install, uninstall, help.

.PARAMETER Name
Specifies the name of the credential slot. Required for save and remove.
Optional for switch: when omitted, switch rotates to the next saved slot in
alphabetical order (wrapping from the last slot back to the first). Special
characters are automatically sanitized to underscores.

.EXAMPLE
# Snapshot the currently logged-in account into a slot called "work".
.\switch_claude_account.ps1 save work

.EXAMPLE
# Restore the "personal" slot as the active Claude Code account.
.\switch_claude_account.ps1 switch personal

.EXAMPLE
# Rotate to the next saved slot (alphabetical order, wraps).
.\switch_claude_account.ps1 switch

.EXAMPLE
# Show all saved slots (the active one is marked with *).
.\switch_claude_account.ps1 list

.EXAMPLE
# Add the `sca` / `switch-claude-account` aliases to your PowerShell profile.
.\switch_claude_account.ps1 install
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param (
    [Parameter(Position = 0)]
    [ValidateSet('save', 'switch', 'list', 'remove', 'usage', 'monitor', 'warmup', 'install', 'uninstall', 'help')]
    [string] $Action,

    [Parameter(Position = 1)]
    [string] $Name,

    [switch] $Help,

    # -Json: emit the `usage` action's output as a machine-parseable JSON
    # object keyed by slot name. Ignored by other actions. Lives in its
    # own parameter set so the binder rejects -Json -Watch combinations
    # before any function body runs (Get-Help shows them as separate
    # syntax forms).
    [Parameter(ParameterSetName = 'Json')]
    [switch] $Json,

    # -Watch: render a live, self-refreshing `usage` view that polls
    # /api/oauth/usage every -Interval seconds and redraws every second
    # (so reset deltas refresh and a terminal resize is reflected within
    # ~1 s rather than at the next poll). Interactive only; exits on
    # Ctrl-C (runtime default). Mutually exclusive with -Json (enforced
    # by parameter sets). READ-ONLY: `usage -Watch` never rotates or
    # spends money. The side-effecting live modes (auto-rotation and
    # keep-warm) moved to the `monitor` action in 3.0.0.
    # Mandatory in the 'Watch' set so it anchors the set and the binder
    # keeps -Watch and -Json on separate syntax forms.
    [Parameter(ParameterSetName = 'Watch', Mandatory = $true)]
    [switch] $Watch,

    # -Interval: seconds between HTTP polls for `usage -Watch` and for
    # `monitor`. In __AllParameterSets because `monitor` has no switch
    # anchor of its own (its set is selected by the positional Action,
    # which parameter sets cannot key off). [ValidateRange] rejects zero /
    # negatives at bind time; the 60-second floor is a runtime
    # clamp-with-advisory inside Invoke-UsageWatch. Ignored by actions other
    # than `usage -Watch` / `monitor`.
    [ValidateRange(1, [int]::MaxValue)]
    [int] $Interval = 60,

    # -Threshold: utilization percentage at or above which `sca monitor`
    # rotates to the next eligible slot. Applied to
    # max(five_hour.utilization, seven_day.utilization) on the active slot;
    # null bucket counts as 0%. Range [1, 100]; default 95 leaves a small
    # safety margin because /api/oauth/usage reporting lags real
    # consumption; rotating exactly at 100 risks overshooting before the
    # next poll lands. In __AllParameterSets (monitor has no switch anchor;
    # see -Interval); a non-monitor action ignores it.
    [ValidateRange(1, 100)]
    [int] $Threshold = 95,

    # -KeepWarm: in `sca monitor`, also keep every saved slot warm for the
    # life of the watch -- a startup warm pass plus a per-poll re-warm of
    # closed 5h windows (mechanics + cost at Invoke-WarmAllSlots /
    # Invoke-KeepWarmStep). In __AllParameterSets because monitor has no
    # switch anchor of its own; rejected on non-monitor actions by Invoke-Main.
    [switch] $KeepWarm,

    # -NoColor: suppress ANSI colour for this invocation. Mechanism is on
    # Write-Color; Invoke-Main flips $PSStyle.OutputRendering to strip the
    # inline SGR that helper emits.
    # Precedence: -NoColor > $env:NO_COLOR non-empty > colored.
    # NO_COLOR (https://no-color.org) is the de facto standard for opting out
    # without a per-invocation flag. Watch mode still works in B&W: its
    # alt-buffer / sync / cursor VT sequences are not SGR and survive.
    [switch] $NoColor,

    # -Version: print $Script:ScriptVersion and exit before any action runs.
    # Outside the 'Json' / 'Watch' sets so it composes with -NoColor and with
    # a positional Action, which it short-circuits past. `-V` is ambiguous
    # (prefix-matches -Verbose from CmdletBinding); shortest unambiguous
    # prefix is `-Versi`.
    [switch] $Version
)

# We are resolving the script path to reference this file when
# installing the alias into the user's PowerShell profile.
$ScriptPath     = (Resolve-Path $PSCommandPath).Path

# $env:HOME is consulted BEFORE the $HOME automatic variable, not instead of
# it. $HOME is bound once at session start and never re-reads the environment,
# so the test sandbox (which swaps $env:HOME per test) could not redirect it
# and every test would operate on the developer's real ~/.claude.
#
# $HOME is still the fallback, because it is the only getpwuid path we have.
# With HOME unset on Unix, Node's os.homedir() falls back to the passwd entry,
# so `claude` keeps working and writes ~/.claude; .NET's GetFolderPath does the
# same, and that is what PowerShell binds $HOME from. Consulting only the
# environment variable would make `sca` refuse in a container or systemd unit
# where the process it mirrors is running fine.
$ScaHomeDir     = if ($IsWindows) {
    if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
} else {
    if ($env:HOME) { $env:HOME } else { $HOME }
}

# CLAUDE_CONFIG_DIR relocates Claude Code's whole config tree, .credentials.json
# and .claude.json included (verified against Claude Code 2.1.263). The value is
# used as given, with no ~ expansion, because Claude Code does none
# (anthropics/claude-code#78988 treats a leading ~ as a literal cwd-relative
# directory) and GetFullPath leaves such a segment alone.
#
# A relative value is bound to the current directory once, here, rather than
# carried relative: PowerShell's provider cmdlets resolve a relative path
# against $PWD while every .NET call in this script ([IO.File]::ReadAllBytes,
# the FileStream in Write-PrivateFileBytes, ::Replace / ::Move) resolves
# against [Environment]::CurrentDirectory, which PowerShell never syncs to
# Set-Location. Measured on Windows: after `Set-Location C:\`,
# [IO.Path]::GetFullPath('x') still returns the process start directory. Left
# relative, one `sca save` after a `cd` enumerates slots under $PWD while
# writing the credential bytes under the launch directory. Binding here keeps
# the parity that matters (a `claude` started in this directory resolves the
# same value against the same base) and removes the split.
#
# Defined above the assignment below because that assignment calls it at load
# time; the rest of the credentials-directory helpers live together further
# down.
function Resolve-ScaConfigDir {
    Param (
        [AllowNull()] [AllowEmptyString()] [String] $Value,
        [String] $BaseDir
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    if ([string]::IsNullOrWhiteSpace($BaseDir)) {
        # $PWD can sit on a non-filesystem provider (HKCU:\ and friends), whose
        # ProviderPath is no base for a file path.
        $BaseDir = if ($PWD.Provider.Name -eq 'FileSystem') { $PWD.ProviderPath } else { [Environment]::CurrentDirectory }
    }

    # An unusable value (invalid characters, a base that is not rooted) is
    # handed on verbatim so the failure surfaces as the action's own error
    # naming the directory, not as a load-time throw before `sca help` runs.
    try   { return [System.IO.Path]::GetFullPath($Value, $BaseDir) }
    catch { return $Value }
}

$ScaConfigDir   = Resolve-ScaConfigDir -Value $env:CLAUDE_CONFIG_DIR

# Every path below stays $null when neither CLAUDE_CONFIG_DIR nor the
# platform's home variable is set, rather than calling Join-Path on a blank
# base. Join-Path's binder rejects null outright, and these run at load time:
# a container or systemd unit started without HOME would abort on this line
# with "Cannot bind argument to parameter 'Path'" before `sca help` or
# `sca -Version` could tell the user which variable to set. Assert-CredentialDir
# does the refusing instead, from inside Invoke-Main.
$CredDir        = if ($ScaConfigDir) { $ScaConfigDir } elseif ($ScaHomeDir) { Join-Path $ScaHomeDir ".claude" } else { $null }
$CredFile       = if ($CredDir) { Join-Path $CredDir ".credentials.json" } else { $null }
$StateFile      = if ($CredDir) { Join-Path $CredDir ".sca-state.json" }   else { $null }
# Claude Code's persistent config. A top-level dotfile beside .claude/ by
# default, but it moves inside CLAUDE_CONFIG_DIR when that is set.
# We read its `oauthAccount` block as the authoritative identity source
# (it's what /status displays) and write whitelisted identity fields back
# at switch time so Claude Code's display follows the active slot.
$ClaudeJsonPath = if ($ScaConfigDir) { Join-Path $ScaConfigDir ".claude.json" } elseif ($ScaHomeDir) { Join-Path $ScaHomeDir ".claude.json" } else { $null }
$ProfilePath    = $PROFILE.CurrentUserAllHosts

# Version of this script. Bumped in the same commit that adds the matching
# CHANGELOG.md release section and the git tag (vX.Y.Z) so `sca -Version`
# matches the tag for users who downloaded the standalone .ps1 from the
# GitHub release asset and have no git context. A Helpers.Tests.ps1 case
# cross-checks this string against the most recent CHANGELOG section header.
# Named $Script:ScriptVersion (not $Script:Version) to avoid colliding with
# the [switch] $Version parameter declared above: a same-named parameter
# enforces its [switch] type on every assignment to the script-scope
# variable, silently coercing this string to $true.
$Script:ScriptVersion = '4.0.0'

# Marker constants delimiting the block we manage in the user's profile.
# Kept at script scope so both Add-To-Profile and Remove-From-Profile share
# a single source of truth.
$MarkerStart = "# === Switch Claude Account ==="
$MarkerEnd   = "# === End Switch Claude Account ==="

# --- Unofficial Claude Code OAuth-flow constants ---
#
# These values power the `usage` action, which replicates the live 5h /
# 7d rate-limit read that Claude Code's own `/usage` slash command
# performs. Extracted from claude.exe 2.1.119 (a Bun-compiled binary
# that embeds the JS source) by string-scanning the file.
#
# These endpoints are UNDOCUMENTED and unsupported by Anthropic. Expect
# them to break when Anthropic bumps the beta flag, rotates the OAuth
# client id, or reshapes the response body. To re-extract after an
# upstream change, from a PowerShell 7 prompt:
#
#   $bin   = (Get-Command claude -ErrorAction Stop).Source
#   $bytes = [IO.File]::ReadAllBytes($bin)
#   $text  = [Text.Encoding]::ASCII.GetString($bytes)
#   # Usage endpoint path:    $text | Select-String '/api/oauth/usage'
#   # Profile endpoint path:  $text | Select-String '/api/oauth/profile' (function Ql)
#   # Base API URL + TOKEN_URL + CLIENT_ID: Select-String 'TOKEN_URL:"'
#   # Beta header value:      Select-String 'lj="oauth-'
#   # API version header:     Select-String 'anthropic-version'
#   # UA version convention:  Select-String 'claude-code/\$\{'
#
# The client id below is the Claude.ai subscription flow's client id
# (matches the `user:sessions:claude_code` scope slot files carry); the
# other client id in the binary (22422756-...) is for the Console API-key
# flow and does not accept our refresh tokens.
#
# GET /api/oauth/usage response body, verified against a live Team-plan call
# on 2026-04-24. Every branch is optional; free-tier and API-key accounts
# receive `{}`:
#
#   five_hour        { utilization: 0..100, resets_at: <ISO-8601>|null }
#   seven_day        { utilization: 0..100, resets_at: <ISO-8601>|null }
#   seven_day_opus   null | { utilization, resets_at }
#   seven_day_sonnet null | { utilization, resets_at }
#   extra_usage      { is_enabled, monthly_limit, used_credits,
#                      utilization, currency }  (all nullable)
#
# Plus internal/unreleased buckets that are null for external subscriptions
# and are NOT rendered in any view (they round-trip only via -Json):
# seven_day_oauth_apps, seven_day_cowork, seven_day_omelette,
# iguana_necktie, omelette_promotional. Only five_hour (Session) and
# seven_day (Week) are rendered, matching Claude Code's own /usage bars.
$Script:UsageEndpoint       = "https://api.anthropic.com/api/oauth/usage"
$Script:ProfileEndpoint     = "https://api.anthropic.com/api/oauth/profile"
$Script:TokenEndpoint       = "https://platform.claude.com/v1/oauth/token"
$Script:OAuthClientId       = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
$Script:AnthropicBeta       = "oauth-2025-04-20"
# anthropic-version: sent on every authenticated request for defense-in-
# depth. The OAuth-namespaced endpoints (/api/oauth/usage, /api/oauth/
# profile, /v1/oauth/token) accept calls without it today, but if
# Anthropic later tightens any of them the script keeps working without
# an emergency patch. Pinned to the stable 2023-06-01 API version that
# Claude Code itself ships with.
$Script:AnthropicApiVersion = "2023-06-01"
$Script:UsageUserAgent      = "claude-code/2.1.119"
# Per-endpoint HTTP budgets. Measured /api/oauth/usage round-trips against
# a live subscription span 46-2108 ms, so a shared 5 s budget left under
# 2.4x headroom and a single latency spike collapsed a slot's row to an
# 'error' carrying no numbers.
# The refresh POST gets its own (larger) budget rather than borrowing the
# usage constant: it does server-side crypto plus refresh-token rotation, so
# it is the slowest of the three calls and was the one running tightest.
$Script:UsageTimeoutSec     = 12
$Script:TokenTimeoutSec     = 15
$Script:ProfileTimeoutSec   = 10

# Retry policy for /v1/oauth/token on a 429 response. Empirically the
# refresh endpoint's per-token rate limiter has a short cooldown
# (~seconds): a slot whose access token expired days ago is "stuck"
# only until one retry slips through. Three total attempts with
# exponential backoff (2 s, then 4 s) gives a ~6 s worst-case extra
# latency per stuck slot, which the watch loop absorbs inside the 60 s
# poll cadence. Without retry the same slot showed `rate-limited`
# every poll until the user happened to invoke another sca command
# during the brief unlock window; the retry collapses that gap.
# Tunable for tests (Pester overrides them to zero so mocked 429 paths
# run instantly).
$Script:TokenRefreshRetryMax     = 3
$Script:TokenRefreshRetryDelayMs = 2000

# --- Where Claude Code actually keeps the active login ---
#
# Everything this tool does rests on .credentials.json being the active login,
# so it is worth recording what that premise is and how it could stop holding.
# Extracted from claude.exe 2.1.270 with the same string-scan recipe as above.
#
# Claude Code's secureStorage module defines exactly two credential backends:
#
#   name:"plaintext"        <CredDir>/.credentials.json, every platform
#   name:"windows-credman"  Windows Credential Manager, via Bun.secrets
#
# There is no macOS Keychain credential backend. The Keychain holds only the
# device key, under service "Claude Code-device-keys", and the one Keychain
# API-key path is behind a hardcoded `let s=!1`. macOS reads and writes the
# same .credentials.json as Linux, which is why `sca` supports it.
#
# windows-credman is NOT active by default. It is selected by
#
#   $env:CLAUDE_CODE_FORCE_WINDOWS_CREDMAN -eq '1'
#     -or (.claude.json).cachedGrowthBookFeatures.tengu_windows_credman -eq $true
#
# a server-controlled GrowthBook flag, so it can turn on without the user doing
# anything. When it does, storage becomes credman-primary with plaintext as
# fallback, and the first successful credman write DELETES .credentials.json.
# From that point `sca switch` writes a file Claude Code no longer reads: it
# would report success while the previous account stayed authenticated and
# billing, which is the exact failure this tool exists to prevent.
#
# The credman item is service "Claude Code" + OAUTH_FILE_SUFFIX ("" in
# production) + "-credentials", suffixed with -<sha256(CLAUDE_CONFIG_DIR)[0..8]>
# when that variable is set, under account "claude-code-user"; payloads over
# 2400 bytes are split into base64 chunks named <service>#0..#n with a #m
# manifest. Reading it back would mean P/Invoking CredRead/CredWrite and
# reimplementing that chunking, which is not worth building against a flag
# nobody has been observed to receive.
#
# Symptom to watch for: .credentials.json missing or stale on Windows while
# Claude Code is logged in and `sca switch` silently fails to change /status.
# Check with `cmdkey /list` for a "Claude Code-credentials" entry.

# Per-slot record of the last /api/oauth/usage attempt, keyed by slot path.
# One structure (not two parallel maps) so the data and the throttle state
# cannot drift. Entry shape:
#
#   @{ Data; Timestamp; RateLimitedUntil }
#
#   Data             last successful response body; the fallback served on a 429.
#   Timestamp        when Data was captured; fresh < $Script:UsageCacheTTL min.
#   RateLimitedUntil [DateTime] set on every 'rate-limited' return; absent/past
#                    otherwise. While in the future Get-SlotUsage short-circuits
#                    to the cache with NO token/usage HTTP, so a sustained 429
#                    stops the loop re-tripping a hot limiter every poll. A
#                    successful read replaces the whole entry (clearing it);
#                    Clear-SlotRateLimitBackoff drops just the stamp.
$Script:SlotUsageCache = @{}
$Script:UsageCacheTTL  = 10

# Hard upper bound on how old a reading may be and still be shown at all.
# Past it Get-CachedUsageOrNull refuses even under -AllowStale, so the row
# loses its numbers and reports the failure instead.
#
# -AllowStale exists so a row keeps its percentages through a BRIEF outage
# rather than collapsing to em-dashes and looking like a dead slot. Without a
# ceiling that argument kept applying at any age, and the consequence was not
# cosmetic: Get-AutoRotationDecision's 'active-unknown' arm fires only for an
# active row with no Data, so an unbounded entry meant a permanently
# unreadable active slot was judged on a days-old reading while the monitor
# reported itself armed.
#
# 360 minutes is one five_hour window plus an hour of slack: beyond it the
# session bucket has certainly rolled and the reading describes a window the
# account is no longer in.
$Script:UsageCacheMaxAgeMin = 360

# Seconds to suppress live token/usage HTTP for a slot after it returns
# 'rate-limited' (see RateLimitedUntil above). Short enough to re-probe
# within a poll or two once the throttle likely clears, long enough to break
# the per-poll refresh storm on an expired idle-slot token. Tunable for tests.
$Script:RateLimitBackoffSec = 120

# Plan-usability thresholds used by Get-PlanStatus / Format-UsageTable /
# Format-UsageVerbose. The Status column on the usage table mixes HTTP
# health (expired / unauthorized / error / no-oauth) with plan-state
# derived from these two thresholds:
#
#   util < UtilWarnPct                   -> 'ok'         (green if active, gray otherwise)
#   UtilWarnPct  <= util < UtilLimitPct  -> 'near limit' (yellow)
#   UtilLimitPct <= util (5h only)       -> 'limited 5h' (red; slot cannot serve prompts until 5h reset)
#   UtilLimitPct <= util (7d only)       -> 'limited 7d' (red)
#   UtilLimitPct <= util (both)          -> 'limited'    (red)
#
# 100% is the hard cap enforced by Anthropic; 90% is the heads-up tier.
# Keep these as script-scope constants so tests can reason about the
# thresholds without duplicating magic numbers.
$Script:UtilWarnPct            = 90
$Script:UtilLimitPct           = 100

# Color thresholds for the aggregate progress bars rendered above the
# usage table. The bars show pool-wide USAGE (sum of utilization across
# HTTP-ok slots divided by N*100, equivalently the mean utilization
# across eligible rows), so the thresholds align with the per-slot
# UtilWarn/UtilLimit semantics above (in spirit, not in value -- pool
# aggregates flip to red sooner because one fully-burned slot in a
# multi-slot pool barely moves the aggregate):
#
#   usedPct >= AggregateRedPct      -> Red     (pool nearly exhausted)
#   usedPct >= AggregateYellowPct   -> Yellow  (half or more burned)
#   otherwise                       -> Green
#
# Red anchored to UtilWarnPct (90) so 'red' carries the same near-cap
# meaning at per-slot and pool scale; pure 100% would be a knife-edge
# transition that fires only after the pool is already exhausted.
# Yellow at the half-burned mark.
$Script:AggregateRedPct        = 90
$Script:AggregateYellowPct     = 50

# Middle-truncation target for the Account column in the usage table.
# Emails longer than this get rendered as `aaa…zzz` with an ellipsis in
# the middle so the domain (which disambiguates accounts under the same
# local-part) stays visible. The verbose `sca usage <name>` view and
# `-Json` output always carry the full email.
$Script:AccountColumnMaxWidth  = 32

# Default bound on a failure reason for renderers that own a whole terminal
# line (Format-UsageAdvisory's per-slot lines, the [Watch] poll-failure
# footer). Generous because those lines wrap harmlessly, unlike the Status
# column they replaced: Claude Code's own limit sentence ("You've hit your
# session limit · resets 6:10pm (Europe/Berlin)") is 61 chars and used to get
# cut mid-timezone at 60. Still bounded so a runaway stderr cannot flood a
# frame.
$Script:AdvisoryReasonMaxWidth = 200

# --- Atomic credential-file write primitives ------------------------------
#
# Every credential-shaped file this tool writes (.credentials.json, slot
# files, identity sidecars, .sca-state.json, ~/.claude.json) goes through
# Set-CredentialFileAtomic, which creates it via Write-PrivateFileBytes and
# renames it into place.

# Atomic temp-file-plus-rename write of $Bytes to $Path. The single write
# primitive used by every credential-shaped file (.credentials.json, slot
# files, .sca-state.json).
#
# Why atomic-rename rather than truncate-and-write: Claude Code keeps
# .credentials.json open with FILE_SHARE_DELETE while running, and the
# only Windows write path that succeeds against an open-but-share-delete
# handle is `MoveFileEx` / `ReplaceFile` (the Win32 primitives behind
# [System.IO.File]::Move / ::Replace). A plain Set-Content / Out-File
# would fail with a sharing violation while Claude Code is running.
#
# Side effect: the destination always becomes a fresh inode after Replace.
# Harmless, because nothing depends on inode identity; the state file is
# what tracks the active slot.
#
# Retry: up to 3 attempts on transient sharing violations with 50 ms
# backoff. Persistent failure throws after the final attempt; the temp
# file is cleaned up in the finally block whether we succeeded or not
# (Replace consumes the temp on success so Test-Path is false there).
function Set-CredentialFileAtomic {
    Param (
        [Parameter(Mandatory)] [String] $Path,
        # AllowEmptyCollection so callers can write a zero-byte placeholder
        # without tripping PowerShell's mandatory-collection guard. Real
        # credential / state writes are always non-empty, but defensive
        # callers (and tests) shouldn't have to special-case zero-length.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes
    )

    # Random suffix lets two concurrent writes coexist safely: each picks
    # its own tmp name, the rename then serializes at the destination.
    $tmp = "$Path.sca-tmp.$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $maxAttempts = 3
    $wrote       = $false

    try {
        Write-PrivateFileBytes -Path $tmp -Bytes $Bytes
        $wrote = $true

        $lastErr = $null
        for ($i = 1; $i -le $maxAttempts; $i++) {
            try {
                if (Test-Path -LiteralPath $Path) {
                    # [NullString]::Value passes a real .NET null; a bare $null
                    # would be coerced to "" by PowerShell's argument binder
                    # and Replace would reject it as an invalid backup path.
                    [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
                } else {
                    [System.IO.File]::Move($tmp, $Path)
                }
                return
            }
            catch [System.IO.IOException] {
                $lastErr = $_
                if ($i -lt $maxAttempts) {
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        throw $lastErr
    }
    finally {
        # Cleanup on the rename-failure path. The success path leaves $tmp
        # consumed by Replace/Move so Test-Path is already false here.
        #
        # Gated on $wrote so this cannot delete a file we did not create:
        # Write-PrivateFileBytes opens CreateNew precisely so a pre-existing
        # temp path is refused rather than overwritten, and deleting it here
        # would undo that refusal and destroy whatever planted it. A write that
        # fails after that open leaves nothing behind either, because
        # Write-PrivateFileBytes removes its own partial file.
        if ($wrote -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# Write $Bytes to a NEW file that is owner-only from the moment it exists.
#
# On Unix the mode must be set by open(2) itself, not by a chmod afterwards.
# A chmod-after-write leaves the credential bytes group- and world-readable
# for the duration of the write (0644 under the usual 0022 umask), and
# creating the file empty first does not help either: POSIX checks
# permissions at open time, so a reader that opened the empty file keeps a
# readable descriptor across the chmod and sees whatever is written next.
# FileStreamOptions.UnixCreateMode (.NET 7, hence the 7.4 floor in #Requires;
# 7.4 is the lowest LTS carrying it and 7.2 / 7.3 are both EOL) passes the
# mode down to open(2), so there is no window at all.
#
# This matters because Set-CredentialFileAtomic renames the result over the
# destination, and on Unix ::Replace / ::Move is a bare rename(2): the
# destination inherits THIS file's mode rather than keeping its own. Measured
# on Debian 13 / .NET 8: a 0600 destination plus a 0644 temp yields 0644
# after Replace, which would silently downgrade Claude Code's own 0600
# .credentials.json.
#
# Windows sets no mode because it has no Unix mode bits (assigning
# UnixCreateMode there throws PlatformNotSupportedException). The file inherits
# the ACL of the directory it is created in, and sca writes no explicit DACL.
# That is the user's profile by default, which restricts it to the owning user,
# but CLAUDE_CONFIG_DIR makes the directory user-chosen: pointed at, say,
# C:\ProgramData\claude, the tokens land under whatever that location inherits.
# Unix is protected unconditionally by the line below; Windows is protected by
# where it is pointed.
#
# CreateNew rather than Create on BOTH platforms: the caller always passes a
# fresh GUID-suffixed path, so an existing file means something else planted
# it and we refuse to write a credential into it. Truncating on one platform
# and refusing on the other would be a contract nobody could rely on.
function Write-PrivateFileBytes {
    Param (
        [Parameter(Mandatory)] [String] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes
    )

    $options = [System.IO.FileStreamOptions]::new()
    $options.Mode   = [System.IO.FileMode]::CreateNew
    $options.Access = [System.IO.FileAccess]::Write
    if (-not $IsWindows) {
        $options.UnixCreateMode = [System.IO.UnixFileMode]'UserRead, UserWrite'
    }

    $stream = [System.IO.FileStream]::new($Path, $options)
    $written = $false
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        # Disposed inside the try, not only in the finally, so a flush failure
        # (the buffered half of an ENOSPC) still counts as a failed write.
        $stream.Dispose()
        $written = $true
    }
    finally {
        if (-not $written) {
            # The open succeeded, so CreateNew proves we created this file, and
            # deleting it cannot destroy anything another process planted. The
            # caller's cleanup only runs when this function returns, so without
            # this a half-written credential would sit in $CredDir forever.
            try { $stream.Dispose() } catch { Write-Verbose "Temp stream dispose failed: $_" }
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Credentials directory ------------------------------------------------

# Every slot-credential file in $Directory (default $CredDir), unsorted, as
# FileInfo. Get-ConfigDirAdvisory is the only caller that passes a directory,
# to count the slots left behind in the default location.
#
# -Force is load-bearing on Linux: .NET reports any name starting with '.' as
# FileAttributes.Hidden, and Get-ChildItem omits hidden entries without it.
# Since every file this tool owns is a dotfile, omitting -Force makes the
# directory look empty, which silently degrades `list`, `usage`, rotation and
# the state auto-migration into "no slots saved" rather than failing loudly.
#
# Excludes `.credentials.json` (the active file, not a slot) and the
# `.account.json` identity sidecars (introduced in v2.1.0), both of which
# the wildcard matches but neither of which is a slot credential.
function Get-CredentialSlotFiles {
    Param ([String] $Directory = $CredDir)

    return Get-ChildItem -LiteralPath $Directory -Filter '.credentials.*.json' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.credentials.json' -and $_.Name -notlike '*.account.json' }
}

# One-line advisory when CLAUDE_CONFIG_DIR has moved the working directory
# away from the default AND slots are being left behind there, or $null.
#
# Honouring CLAUDE_CONFIG_DIR relocates every slot sca can see. Someone who
# set the variable for an unrelated reason would run `sca list`, get "No slots
# saved yet", and have nothing to tell them their slots are still sitting in
# the default ~/.claude. Naming the directory in use, plus a count of what is
# being skipped, turns a silent relocation into a visible one.
#
# Orphans are the whole trigger, not a detail appended to it. Setting the
# variable is a permanent configuration, so an unconditional line would print
# on every `sca list` and `sca switch` forever and teach the user to skip
# yellow lines. When the default directory holds no slots, nothing is hidden
# from anyone and there is nothing to say.
#
# GetFullPath normalises separators and relative segments without requiring
# either path to exist, so the "already the default" case stays quiet instead
# of emitting a permanent noise line for anyone who sets the variable
# explicitly to ~/.claude. The base is passed explicitly for the same reason
# Resolve-ScaConfigDir binds one: the one-argument overload would resolve
# against [Environment]::CurrentDirectory. Production values arrive absolute
# from Resolve-ScaConfigDir; the parameter keeps a relative one (a caller's,
# a test's) comparing against the same base every other read uses. A malformed
# value fails open into the orphan check rather than being treated as "already
# the default".
# The three inputs arrive as parameters defaulting to the script-scope values
# so the function is pure and the suite can drive every branch by argument,
# rather than leaning on PowerShell's dynamic scoping to reach in and rebind
# globals (which reads as dead assignments to both PSScriptAnalyzer and to the
# next person). Assert-CredentialDir takes its directory the same way.
function Get-ConfigDirAdvisory {
    Param (
        [AllowNull()] [AllowEmptyString()] [String] $ConfigDir = $ScaConfigDir,
        [String] $HomeDir   = $ScaHomeDir,
        [String] $ActiveDir = $CredDir
    )

    if ([string]::IsNullOrWhiteSpace($ConfigDir)) { return $null }

    # No resolvable home means there is no default directory, so no slot can be
    # stranded in one and there is nothing to report. Returning early also
    # keeps Join-Path's binder off the empty string, which would throw and
    # abort an otherwise-working invocation over an advisory line; reachable
    # whenever the home lookup fails on Unix, which is exactly the kind of
    # environment (a container, a systemd unit) that sets CLAUDE_CONFIG_DIR in
    # the first place, and where $CredDir never needed a home directory.
    if ([string]::IsNullOrWhiteSpace($HomeDir)) { return $null }

    $defaultDir = Join-Path $HomeDir '.claude'
    try {
        $base       = $PWD.ProviderPath
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if ([string]::Equals(
                [System.IO.Path]::GetFullPath($defaultDir, $base),
                [System.IO.Path]::GetFullPath($ActiveDir,  $base),
                $comparison)) {
            return $null
        }
    }
    catch { Write-Verbose "Config-dir comparison failed, emitting advisory: $_" }

    $orphaned = @(Get-CredentialSlotFiles -Directory $defaultDir).Count
    if ($orphaned -eq 0) { return $null }
    return "[Config] CLAUDE_CONFIG_DIR is set; using '$ActiveDir'. $orphaned slot(s) in '$defaultDir' are not in use."
}

# Refuse when no credentials directory could be resolved.
#
# $CredDir is blank only when the platform's home variable is unset AND
# CLAUDE_CONFIG_DIR is not set either, which is reachable in a container or a
# systemd unit started without HOME. Named here rather than at the assignment
# site so `sca help` and `sca -Version` still work in that environment and can
# tell the user which variable to set; see the comment on $CredDir for why the
# paths are left blank instead of throwing at load time.
#
# The directory arrives as a parameter defaulting to the script value for the
# reason spelled out on Get-ConfigDirAdvisory: it keeps the production call
# site argument-free while letting the suite drive both arms.
function Assert-CredentialDir {
    Param ([AllowNull()] [AllowEmptyString()] [String] $Directory = $CredDir)

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        $homeVar = if ($IsWindows) { 'USERPROFILE' } else { 'HOME' }
        throw "No credentials directory: `$env:$homeVar is not set, so '<home>/.claude' cannot be resolved. Set `$env:$homeVar, or set `$env:CLAUDE_CONFIG_DIR to the directory Claude Code uses."
    }
}

# Create $Directory when it is missing, owner-only on Unix.
#
# 0700 rather than the 0755 a umask-default mkdir produces: slot FILENAMES
# embed the account's email address, so a world-readable directory leaks the
# account list even though Write-PrivateFileBytes keeps the bytes to 0600. An
# existing directory is left exactly as it is, including its mode: it is
# usually Claude Code's own ~/.claude, and silently re-permissioning another
# tool's directory is not this tool's call to make.
function New-CredentialDirectory {
    Param ([Parameter(Mandatory)] [String] $Directory)

    if (Test-Path -LiteralPath $Directory) { return }

    if ($IsWindows) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        return
    }
    [System.IO.Directory]::CreateDirectory(
        $Directory,
        [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute') | Out-Null
}

# Every file sca owns under $Directory, plus Claude Code's config when one is
# given: slot files, their .account.json sidecars, .credentials.json and the
# state file. The wildcard is wider than Get-CredentialSlotFiles' on purpose,
# because this answers "what did sca write here", not "what is a slot".
function Get-CredentialFilePaths {
    Param (
        [String] $Directory = $CredDir,
        [AllowNull()] [AllowEmptyString()] [String] $ClaudeJson = $ClaudeJsonPath
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory)) { return @() }

    $paths = @(Get-ChildItem -LiteralPath $Directory -Filter '.credentials*.json' -Force -ErrorAction SilentlyContinue |
                   ForEach-Object { $_.FullName })
    $paths += @((Join-Path $Directory '.sca-state.json'), $ClaudeJson) |
                  Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    return @($paths)
}

# True when a mode grants any group or other bit. [UnixFileMode] is a flags
# enum, so this reads as one test rather than six comparisons; kept separate
# from the repair loop below so the rule is checkable on a platform that has no
# modes to read.
function Test-UnixModeIsShared {
    Param ([Parameter(Mandatory)] [System.IO.UnixFileMode] $Mode)

    $shared = [System.IO.UnixFileMode]'GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
    return (($Mode -band $shared) -ne [System.IO.UnixFileMode]::None)
}

# Tighten any credential-shaped file in $Directory that is readable by someone
# other than its owner back to 0600, and return how many were changed.
#
# Write-PrivateFileBytes fixes the mode of files this version writes. It cannot
# fix the installed base: before 4.0.0 every atomic write handed the destination
# the temp file's umask-default 0644, so a slot that is not re-saved, and whose
# token is never refreshed, would keep a world-readable refresh token forever
# while the release notes said the hole was closed. `sca switch` only rewrites
# .credentials.json, so upgrading heals exactly one file without this.
#
# Best-effort per file (a file owned by another user, or on a filesystem that
# reports no mode, must not abort the action the user actually asked for), and
# a no-op on Windows, which has no mode bits; see Write-PrivateFileBytes for
# what stands in for them there.
function Repair-CredentialFileModes {
    Param (
        [String] $Directory   = $CredDir,
        [AllowNull()] [AllowEmptyString()] [String] $ClaudeJson = $ClaudeJsonPath
    )

    if ($IsWindows) { return 0 }

    $fixed = 0
    foreach ($path in (Get-CredentialFilePaths -Directory $Directory -ClaudeJson $ClaudeJson)) {
        try {
            $mode = [System.IO.File]::GetUnixFileMode($path)
            if (-not (Test-UnixModeIsShared -Mode $mode)) { continue }
            [System.IO.File]::SetUnixFileMode($path, [System.IO.UnixFileMode]'UserRead, UserWrite')
            $fixed++
        }
        catch { Write-Verbose "Could not tighten '$path': $_" }
    }
    return $fixed
}

# --- State file -----------------------------------------------------------
#
# `sca` tracks the currently-active slot in $StateFile (a small JSON
# document) rather than relying on inode equality between .credentials.json
# and a saved slot file. Inode equality cannot survive Claude Code's
# atomic-rename token-refresh writes, which replace the destination inode.
#
# Schema v1:
#   { "schema": 1, "active_slot": "<name>"|null, "last_sync_hash": "<sha256>"|null }
#
# Concurrent writes: every write goes through Set-CredentialFileAtomic,
# which is atomic on NTFS. Two concurrent updates -> last writer wins;
# the loser's changes are silently dropped. Acceptable for an interactive
# tool that is rarely (and never deliberately) invoked in parallel.

# Persist $State to $StateFile via atomic rename. The schema field is
# enforced to 1 here so callers cannot accidentally write a stale or
# missing version. last_sync_hash and active_slot may be $null (initial
# state where reconcile has not yet captured any sync).
function Write-ScaState {
    Param (
        [Parameter(Mandatory)] [psobject] $State
    )

    $payload = [ordered]@{
        schema         = 1
        active_slot    = $State.active_slot
        last_sync_hash = $State.last_sync_hash
    }
    $json  = $payload | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    Set-CredentialFileAtomic -Path $StateFile -Bytes $bytes
}

# Load the state file. Returns a [pscustomobject] with .schema /
# .active_slot / .last_sync_hash on success, or $null when the file is
# missing, unreadable, or schema-incompatible.
#
# Auto-migration: when no state file exists AND .credentials.json exists,
# this function attempts to identify the active slot by hashing every
# slot file for a content match (mirrors the pre-state-file IsActive
# computation). On a hit, it persists the fresh state and returns it. On
# a miss it returns $null and Invoke-Reconcile (the only caller that
# acts on the null branch) auto-saves the unidentified bytes under a
# generated name. Other callers tolerate $null gracefully: Invoke-
# RemoveAction's active-slot guard short-circuits when state is null;
# Invoke-ListAction reconciles before reading state, so by then the
# state has been bootstrapped.
#
# Legacy field tolerance: state files written by v2.3.0 - v2.4.0-draft
# carry a `last_warmup_at` field. We parse the file unchanged but
# silently ignore the field; the next state-mutating write drops it.
# This is one-way: a downgrade to an older script reading our
# field-less file works because v2.3.0's Read-ScaState defaults the
# field to @{} when absent.
#
# Errors are swallowed so a corrupt state file or a transient migration
# write failure does not break the tool; the next state-mutating call
# rewrites it.
function Read-ScaState {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $raw = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($obj.schema -ne 1) { return $null }
            return [pscustomobject]@{
                schema         = [int]$obj.schema
                active_slot    = if ($obj.active_slot)    { [string]$obj.active_slot }    else { $null }
                last_sync_hash = if ($obj.last_sync_hash) { [string]$obj.last_sync_hash } else { $null }
            }
        }
        catch {
            return $null
        }
    }

    # No state file. Try to bootstrap by hash-matching .credentials.json
    # against existing slot files (transparent upgrade for users coming
    # from the hardlink-based version).
    if (-not (Test-Path -LiteralPath $CredFile)) { return $null }
    try {
        $activeHash = Get-SHA256Hex -Path $CredFile
    }
    catch {
        return $null
    }

    $files = Get-CredentialSlotFiles
    foreach ($f in $files) {
        $parsed = Get-SlotFileInfo -FileName $f.Name
        if (-not $parsed) { continue }
        try {
            if ((Get-SHA256Hex -Path $f.FullName) -eq $activeHash) {
                $state = [pscustomobject]@{
                    schema         = 1
                    active_slot    = $parsed.Name
                    last_sync_hash = $activeHash
                }
                # Persist the migration so subsequent reads are O(1).
                # Failure here is non-fatal; callers see correct behavior
                # for this call and the migration retries on the next read.
                try { Write-ScaState -State $state } catch { Write-Verbose "ScaState migration write deferred: $_" }
                return $state
            }
        }
        catch { continue }
    }
    return $null
}

# Read-modify-write helper. Pass any subset of -ActiveSlot / -LastSyncHash;
# parameters not bound are left at their current state-file value (or null
# when no state file existed). -ClearActiveSlot wins over -ActiveSlot in
# the unusual case both are bound, so callers expressing "forget the
# active slot" cannot accidentally re-set it.
function Update-ScaState {
    Param (
        [String] $ActiveSlot,
        [String] $LastSyncHash,
        [switch] $ClearActiveSlot
    )

    $current = Read-ScaState
    if (-not $current) {
        $current = [pscustomobject]@{
            schema         = 1
            active_slot    = $null
            last_sync_hash = $null
        }
    }

    if ($PSBoundParameters.ContainsKey('ActiveSlot'))   { $current.active_slot    = $ActiveSlot }
    if ($PSBoundParameters.ContainsKey('LastSyncHash')) { $current.last_sync_hash = $LastSyncHash }
    if ($ClearActiveSlot)                               { $current.active_slot    = $null }

    Write-ScaState -State $current
    return $current
}

# --- ~/.claude.json identity bridge ---------------------------------------
#
# Claude Code keeps `oauthAccount` (accountUuid, emailAddress, organizationUuid,
# displayName, organizationName, plus billing/trial metadata) in a top-level
# `~/.claude.json` config file. The /status screen's "Email:" line reads
# `oauthAccount.emailAddress` from this cache; the cache is populated once at
# login (from /api/oauth/profile) and is NOT refreshed on subsequent token
# refreshes. This file is therefore the single
# authoritative source of "what email is Claude Code displaying right now."
#
# sca uses ~/.claude.json two ways:
#   1. READ (sca save / reconcile identity probe): the email Claude Code
#      shows IS what we want to label slots with. Drift between sca and
#      Claude Code becomes structurally impossible.
#   2. WRITE (sca switch): we copy the destination slot's captured oauthAccount
#      block back into ~/.claude.json so Claude Code's display follows the
#      active slot across switches.
#
# Writing is gated by Test-ClaudeRunning: Claude Code holds ~/.claude.json
# in an in-memory cache (Un.config) that is not auto-invalidated on external
# changes, and a flush from a running Claude Code instance would silently
# overwrite our oauthAccount mutation. Refuse-while-running is the chosen
# mitigation.

# Returns $true if Claude Code is running on the host.
#
# Two probes, because the CLI ships in two shapes. The native installer
# produces a real executable named 'claude', which the name probe finds on
# both platforms. The npm package (@anthropic-ai/claude-code) is a Node
# script behind a shim, so its process is 'node' and the name probe misses
# it entirely; on Unix the second probe matches the package's own entry
# point in the command line instead.
#
# The command-line probe skips Windows, and the reason is measured, not
# stylistic: reading .CommandLine off every process costs ~53 s there, where
# the property is backed by a per-process CIM query, against a few ms on Linux,
# where it is a /proc/<pid>/cmdline read. A guard that runs before every
# save / switch / rotation cannot spend that.
#
# On macOS the probe runs but cannot match: PowerShell defines .CommandLine as
# a ScriptProperty whose body branches on $IsWindows and $IsLinux and nothing
# else (types.ps1xml, verified against 7.4), so it is always $null on Darwin.
# Measured on a macos-latest runner: 0 of 534 processes carried a value, at
# 38 ms for the sweep. The call is left in rather than short-circuited because
# 38 ms is not worth a branch, and because it would start working on its own if
# PowerShell ever grows a Darwin branch, where a hardcoded early return would
# freeze the gap in place.
#
# The residual gap is therefore an npm-installed Claude Code on Windows or
# macOS: the name probe cannot see it and the command-line probe does not run
# or cannot match.
#
# Get-Process enumerates processes from ALL users on the system (limited
# detail for processes owned by other users, but the Process objects
# themselves still come back), so this refuses save/switch even when a
# DIFFERENT user on a shared host has Claude Code open. That is intentional
# multi-user safety: if any user's Claude Code holds the ~/.claude.json
# in-memory cache, our oauthAccount mutation could race its flush. Wrapped as
# a function so tests can mock it without driving real process state.
#
# This is our whole concurrency story for ~/.claude.json, and it is a
# deliberate non-participation: Claude Code serialises its OWN writes with
# proper-lockfile via ~/.claude.json.lock, and we do not take that lock.
# Taking it would only order our write against theirs; it would not evict the
# in-memory copy a running Claude Code may still flush over the top of us.
# Refusing to run at all is the stronger guarantee, because there is no live
# cache to lose the race against. Recovery if a write ever does corrupt the
# file: Claude Code keeps rolling ~/.claude.json.backup.<unix-ms> copies.
function Test-ClaudeRunning {
    if (Get-Process -Name 'claude' -ErrorAction SilentlyContinue) { return $true }
    if ($IsWindows) { return $false }

    # Never let an unreadable /proc entry or a process that exits mid-scan
    # turn a safety guard into a terminating error; an enumeration failure
    # means "not detected", which the name probe above has already answered.
    try   { return (Test-ClaudeNodeProcess -Processes (Get-Process -ErrorAction SilentlyContinue)) }
    catch {
        Write-Verbose "Claude Code command-line probe failed: $_"
        return $false
    }
}

# True when any process in $Processes is an npm-installed Claude Code.
#
# Split out of Test-ClaudeRunning because that function's own body cannot be
# tested: a Get-Process mock does not reach a dot-sourced function the way an
# Invoke-RestMethod or Get-ChildItem mock does (verified against Pester 5.7).
# Taking the process list as a parameter puts the part worth pinning, the
# pattern itself, under test on every platform.
#
# The pattern is the npm package's own entry point,
# @anthropic-ai/claude-code/cli.js, which argv carries as the resolved script
# path behind the `claude` shim. Anchored on the surrounding path separators
# rather than the bare word 'claude', because a checkout directory with
# 'claude' in its name is not a running Claude Code and must not lock the user
# out of `sca save`. Over-matching would only refuse a safe action, but
# under-matching races Claude Code's in-memory ~/.claude.json cache, so the
# pattern is deliberately the narrower of the two.
function Test-ClaudeNodeProcess {
    Param ([AllowNull()] $Processes)

    foreach ($process in @($Processes)) {
        if ($process.CommandLine -like '*/claude-code/cli.js*') { return $true }
    }
    return $false
}

# Read Claude Code's `oauthAccount` block out of ~/.claude.json. Returns a
# pscustomobject with the whitelisted identity fields when the file exists,
# parses, and contains a populated oauthAccount.emailAddress; otherwise $null.
#
# Whitelist (these are the fields that determine identity; volatile metadata
# like billingType / trial dates is intentionally not surfaced: it changes
# over time and should not round-trip through sca):
#   accountUuid, emailAddress, organizationUuid, displayName, organizationName
#
# Failure modes (all -> $null, never throws):
#   * file missing                     (fresh install / Claude Code never run)
#   * file unparseable                 (corrupt JSON; Claude Code probably broken too)
#   * no oauthAccount key              (logged out / API-key-only mode)
#   * oauthAccount.emailAddress empty  (incomplete cache; treat as no identity)
function Get-OAuthAccountFromClaudeJson {
    if (-not (Test-Path -LiteralPath $ClaudeJsonPath)) { return $null }

    try {
        $obj = Get-Content -LiteralPath $ClaudeJsonPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if (-not $obj.oauthAccount) { return $null }
    $oa = $obj.oauthAccount
    if ([string]::IsNullOrWhiteSpace([string]$oa.emailAddress)) { return $null }

    return [pscustomobject]@{
        accountUuid      = if ($oa.accountUuid)      { [string]$oa.accountUuid }      else { $null }
        emailAddress     = [string]$oa.emailAddress
        organizationUuid = if ($oa.organizationUuid) { [string]$oa.organizationUuid } else { $null }
        displayName      = if ($oa.displayName)      { [string]$oa.displayName }      else { $null }
        organizationName = if ($oa.organizationName) { [string]$oa.organizationName } else { $null }
    }
}

# JSON-encode a string value. Returns the value with surrounding double
# quotes and standard JSON escapes applied (\\ \" \n \r \t \b \f). Used by
# Set-OAuthAccountInClaudeJson to substitute new field values into the
# raw JSON text without depending on PowerShell's JSON serializer (which
# would re-format the entire 18 KB+ config file and risk drift).
function ConvertTo-ScaJsonString {
    Param ([AllowEmptyString()] [AllowNull()] [string] $Value)
    if ($null -eq $Value) { return 'null' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b').Replace("`f", '\f').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
    return '"' + $escaped + '"'
}

# Compute SHA-256 of bytes (or a file's bytes) as uppercase hex with no
# separators. This format matches Get-FileHash's .Hash output exactly,
# which is the implicit invariant that state.last_sync_hash equality
# depends on: callers may produce a hash here from in-memory bytes
# during a save / switch / refresh, and Read-ScaState's auto-migration
# may produce a hash here from a slot file on disk. Both code paths
# need to compare equal byte-for-byte. Centralizing the format in one
# helper makes that contract enforced rather than convention.
function Get-SHA256Hex {
    [CmdletBinding(DefaultParameterSetName = 'Bytes')]
    Param (
        [Parameter(Mandatory, ParameterSetName = 'Bytes', Position = 0)]
        [byte[]] $Bytes,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [String] $Path
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $Bytes = [System.IO.File]::ReadAllBytes($Path)
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try   { return [BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '' }
    finally { $sha.Dispose() }
}

# Replace the whitelisted identity fields inside ~/.claude.json's
# oauthAccount block, leaving every other top-level field byte-equal.
#
# Strategy: locate the `"oauthAccount": { ... }` block by brace-counting,
# then substitute each whitelisted "field": "value" pair within the block
# via a single regex replace (a MatchEvaluator, not a replacement string, so
# a value containing $1 / $& cannot be reinterpreted as a capture token).
# The non-whitelisted fields (billingType, claudeCodeTrialEndsAt, etc.)
# inside oauthAccount are also preserved byte-equal; we only touch the five
# identity fields.
#
# Why not parse and reserialize: ~/.claude.json is large and structurally
# complex, and a ConvertTo-Json round-trip silently shifts key ordering,
# integer vs decimal rendering, and escape casing. Targeted substitution is
# the smaller blast radius, and the tests assert byte-equal preservation of
# unrelated top-level fields across a save -> switch round trip.
#
# Null-valued whitelisted fields are skipped (they preserve the existing
# ~/.claude.json value). The asymmetry is deliberate: null → real
# (upgrading a previously-null cached field to a populated value) still
# works because the substituted value is non-null; real → null (which
# would wipe Claude Code's cached identity when the sidecar carries the
# /api/oauth/profile-fallback's null defaults) is blocked.
#
# A pre-flight test verified this approach: editing
# emailAddress and restarting Claude Code makes /status report the new
# value, and the rest of the file round-trips byte-equal.
#
# Errors:
#   * file missing                  -> throw
#   * oauthAccount block missing    -> throw
#   * unbalanced braces in block    -> throw (never seen in practice;
#                                            indicates a corrupt file
#                                            and we refuse to touch it)
function Set-OAuthAccountInClaudeJson {
    Param ([Parameter(Mandatory)] [pscustomobject] $OAuthAccount)

    if (-not (Test-Path -LiteralPath $ClaudeJsonPath)) {
        throw "~/.claude.json not found at '$ClaudeJsonPath'. Sign in to Claude Code first ('claude /login')."
    }

    $raw = Get-Content -LiteralPath $ClaudeJsonPath -Raw -ErrorAction Stop

    # Locate the opening `"oauthAccount": {`. We accept whitespace variations
    # because Claude Code's serializer indents with 2 spaces but a hand-edited
    # file might have different whitespace; we tolerate that.
    $startMatch = [regex]::Match($raw, '"oauthAccount"\s*:\s*\{')
    if (-not $startMatch.Success) {
        throw "~/.claude.json has no oauthAccount block. Sign in to Claude Code first."
    }

    # Brace-count from the opening { to find the matching close. Naive
    # counter; does NOT track string-literal context. Per RFC 8259, JSON
    # strings may legally contain unescaped `{` and `}`; only `"`, `\`,
    # and U+0000-U+001F must be escaped. So this counter would miscount
    # an oauthAccount value like `"organizationName": "Acme {LLC}"`.
    #
    # Why this is acceptable in practice (NOT by JSON-spec construction):
    #   * Of the five whitelisted identity fields, three are UUIDs and
    #     one is an RFC 5321 email; none can contain `{` / `}`.
    #   * `displayName` / `organizationName` are user-set in Anthropic's
    #     console, but braces in those values are vanishingly rare.
    #   * Non-whitelisted oauthAccount fields Claude Code emits today
    #     (billingType enum, ISO timestamps, booleans, `ccOnboardingFlags`
    #     nested object) cannot contain string-literal `}`; nested
    #     object close-braces ARE real structural braces and counted
    #     correctly.
    #   * If a future Claude Code field with brace-bearing string content
    #     trips this, ~/.claude.json may be corrupted; recovery is via
    #     Claude Code's own `~/.claude.json.backup.<unix-ms>` rolling
    #     backups (last 5 retained).
    # If this assumption ever stops holding (e.g., Anthropic adds a free-
    # form notes field), upgrade this to a string-literal-aware scanner.
    $openBrace = $startMatch.Index + $startMatch.Length - 1
    $depth = 1
    $i = $openBrace + 1
    while ($i -lt $raw.Length -and $depth -gt 0) {
        $ch = $raw[$i]
        if     ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth-- }
        $i++
    }
    if ($depth -ne 0) {
        throw "~/.claude.json oauthAccount block has unbalanced braces; refusing to write."
    }
    # $i now points just past the closing `}`. The block text spans
    # [openBrace .. i), inclusive of both braces.
    $blockText = $raw.Substring($openBrace, $i - $openBrace)

    $whitelist = @('accountUuid', 'emailAddress', 'organizationUuid', 'displayName', 'organizationName')
    $newBlock  = $blockText
    foreach ($field in $whitelist) {
        if (-not $OAuthAccount.PSObject.Properties[$field]) { continue }
        $value = $OAuthAccount.$field
        # Skip null values: preserve the existing ~/.claude.json field rather
        # than nulling it out. This handles /api/oauth/profile-fallback
        # sidecars that captured only emailAddress (the other four
        # whitelisted fields default to $null in that path). The asymmetry
        # is deliberate: a null value carries no information about Claude
        # Code's actual identity, so the existing cached value is the better
        # source of truth. The inverse direction (null → real, upgrading a
        # previously-null cache to a populated value) still works because
        # the new value is non-null and falls through to the substitution
        # below.
        if ($null -eq $value) { continue }
        # Field-pattern: `"name": "<any-string-or-null>"`. The capture
        # accepts both quoted strings and the bare `null` literal so a
        # null-valued cached field can be replaced with a real value.
        $pattern = '"' + [regex]::Escape($field) + '"\s*:\s*("(?:[^"\\]|\\.)*"|null)'
        $rx = [regex]::new($pattern)

        $encoded = ConvertTo-ScaJsonString $value
        # MatchEvaluator avoids `$1` / `$&` regex-replacement-token
        # surprises if the JSON-encoded value happens to contain `$`.
        $replacement = '"' + $field + '": ' + $encoded
        $newBlock = $rx.Replace($newBlock, [System.Text.RegularExpressions.MatchEvaluator] {
            Param ($m)
            return $replacement
        }, 1)
    }

    if ($newBlock -eq $blockText) { return }  # no-op write

    $newRaw = $raw.Substring(0, $openBrace) + $newBlock + $raw.Substring($i)
    Set-CredentialFileAtomic -Path $ClaudeJsonPath -Bytes ([System.Text.Encoding]::UTF8.GetBytes($newRaw))
}

# --- Per-slot identity sidecar -------------------------------------------
#
# Each slot has a sidecar `.account.json` file alongside its credentials
# file that captures the slot's frozen identity at save time:
#
#   .credentials.<name>(<email>).json         <- tokens (what Claude Code reads)
#   .credentials.<name>(<email>).account.json <- identity sidecar (sca-only)
#
# Claude Code never reads the sidecar; it's purely sca state. The sidecar
# is the authoritative source for switching: when sca switches, the
# captured oauthAccount is written back into ~/.claude.json so Claude
# Code's display follows. The slot filename's email and the sidecar's
# emailAddress agree by construction (save writes both atomically).
#
# Slots without a valid sidecar are HIDDEN from list/usage/rotation and
# refused by switch; there is no migration path from old states.
# Re-running `sca save <name>` while that slot is active recaptures the
# sidecar, making the slot visible again.

# Map a slot credentials file path to its sidecar path.
function Get-SidecarPath {
    Param ([Parameter(Mandatory)] [string] $SlotPath)
    return $SlotPath -replace '\.json$', '.account.json'
}

# Read the sidecar JSON for a slot. Returns a pscustomobject with the
# parsed contents, or $null if the sidecar is missing, unparseable, or
# fails the schema/email shape check.
function Read-Sidecar {
    Param ([Parameter(Mandatory)] [string] $SlotPath)

    $sidecarPath = Get-SidecarPath -SlotPath $SlotPath
    if (-not (Test-Path -LiteralPath $sidecarPath)) { return $null }

    try {
        $obj = Get-Content -LiteralPath $sidecarPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if ($obj.schema -ne 1) { return $null }
    if (-not $obj.oauthAccount) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$obj.oauthAccount.emailAddress)) { return $null }
    return $obj
}

# Atomic-write a sidecar for the given slot path. Source is informational:
# 'claude_json' when oauthAccount came from ~/.claude.json (preferred),
# 'api_profile' when it came from /api/oauth/profile (fallback), 'test'
# in tests, etc. captured_at is informational for diagnostics.
function Write-Sidecar {
    Param (
        [Parameter(Mandatory)] [string]       $SlotPath,
        [Parameter(Mandatory)] [pscustomobject] $OAuthAccount,
        [string] $Source = 'claude_json'
    )

    $payload = [ordered]@{
        schema       = 1
        captured_at  = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        source       = $Source
        oauthAccount = [ordered]@{
            accountUuid      = $OAuthAccount.accountUuid
            emailAddress     = $OAuthAccount.emailAddress
            organizationUuid = $OAuthAccount.organizationUuid
            displayName      = $OAuthAccount.displayName
            organizationName = $OAuthAccount.organizationName
        }
    }
    $json  = $payload | ConvertTo-Json -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Set-CredentialFileAtomic -Path (Get-SidecarPath -SlotPath $SlotPath) -Bytes $bytes
}

# Best-effort sidecar deletion. Silent on missing file.
function Remove-Sidecar {
    Param ([Parameter(Mandatory)] [string] $SlotPath)
    $sidecarPath = Get-SidecarPath -SlotPath $SlotPath
    if (Test-Path -LiteralPath $sidecarPath) {
        Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction SilentlyContinue
    }
}

# We are detecting the profile file's encoding so install/uninstall can
# preserve it. Without this, reading a UTF-16 profile as UTF-8 corrupts
# the content on rewrite. Files without a BOM are treated as utf8NoBOM
# per PowerShell 7 convention; ANSI-encoded profiles are indistinguishable
# from utf8NoBOM without a BOM and are out of scope.
function Get-ProfileEncoding {
    Param ([String] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 'utf8NoBOM' }

    $buf    = New-Object byte[] 4
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $n = $stream.Read($buf, 0, 4)
    }
    finally {
        $stream.Dispose()
    }

    if ($n -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { return 'utf8BOM' }
    if ($n -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE)                      { return 'unicode' }
    if ($n -ge 2 -and $buf[0] -eq 0xFE -and $buf[1] -eq 0xFF)                      { return 'bigendianunicode' }

    return 'utf8NoBOM'
}

# We are rendering a compact, locale-independent help screen so the
# user always sees the same layout regardless of the OS UI language.
function Show-Help {
    # Blank when no home directory resolved (see the comment on $CredDir).
    # Help has to render there, since it is where the user finds out which
    # variable to set, so the FILES rows degrade to a marker rather than
    # letting Join-Path's binder throw mid-render.
    $unresolved = '(unresolved: set HOME or CLAUDE_CONFIG_DIR)'
    $slotGlob   = if ($CredDir) { Join-Path $CredDir '.credentials.<name>(<email>).json' } else { $unresolved }

    $lines = @(
        "",
        "Switch Claude Account - manage multiple Claude Code logins.",
        "",
        "USAGE",
        "  sca <action> [options] [name]",
        "",
        "ACTIONS",
        "",
        "  MANAGEMENT",
        "    save <name>      Snapshot the active login into a named slot",
        "    switch [name]    Restore a named slot; without <name>, rotate to next",
        "    list             List all saved slots",
        "    remove <name>    Delete a named slot",
        "    install          Add 'sca' aliases to your PowerShell profile",
        "    uninstall        Remove the aliases from your PowerShell profile",
        "",
        "  OPERATIONS",
        "    usage [name]     Show session and week plan usage per slot",
        "    monitor          Auto-rotate slots when the usage threshold is reached",
        "    warmup [name]    Open each slot's 5h session window",
        "",
        "OPTIONS",
        "",
        "  USAGE",
        "    -Watch           Live view that polls every 60 seconds",
        "    -Interval <sec>  Seconds between polls when -Watch is set (default 60)",
        "    -Json            Emit usage as machine-readable JSON",
        "",
        "  MONITOR",
        "    -Threshold <n>   Rotate slots at or above this utilization % (default 95)",
        "    -KeepWarm        Keep every slot warm by re-opening closed 5h windows each poll",
        "    -Interval <sec>  Seconds between polls (default 60)",
        "",
        "  GLOBAL",
        "    -NoColor         Suppress all ANSI color output",
        "    -Version         Print the script version and exit",
        "    -h, -Help        Show this help",
        "",
        "EXAMPLES",
        "  sca save slot-1                  # save current login as 'slot-1'",
        "  sca switch slot-2                # activate the 'slot-2' slot",
        "  sca switch                       # rotate to the next saved slot",
        "  sca list                         # show all slots",
        "  sca remove slot-1                # delete a slot",
        "  sca usage                        # session and week usage for every slot",
        "  sca usage work                   # verbose single-slot view",
        "  sca usage -Watch                 # live view; polls every 60s",
        "  sca usage -Watch -Interval 300   # live view; slower 300s polls",
        "  sca usage -Json                  # machine-readable JSON for scripting",
        "  sca warmup                       # open every slot's 5h window once",
        "  sca warmup slot-2                # warm just one slot",
        "  sca monitor                      # auto-rotate when the active slot hits 95%",
        "  sca monitor -Threshold 90        # rotate earlier (default is 95%)",
        "  sca monitor -KeepWarm            # auto-rotate AND keep all slots warm (recommended)",
        "",
        # Resolved rather than written as literals: the paths differ per
        # platform and shift again under CLAUDE_CONFIG_DIR, so printing what
        # this invocation actually uses cannot drift out of date.
        "FILES",
        "  Active login : $(if ($CredFile)  { $CredFile }  else { $unresolved })",
        "  Saved slots  : $slotGlob",
        "  State        : $(if ($StateFile) { $StateFile } else { $unresolved })",
        "  PS profile   : $ProfilePath",
        "",
        "NOTES",
        "  • Close Claude Code / VS Code before 'save', 'switch', 'warmup', or 'monitor'.",
        "  • OpenCode + opencode-claude-auth support swapping accounts without restart.",
        ""
    )

    $lines | ForEach-Object { Write-Host $_ }
}

# Single chokepoint for ALL colored output. No production path may call
# `Write-Host -ForegroundColor`.
#
# Why this exists: on Windows, `Write-Host -ForegroundColor` does NOT
# emit ANSI SGR codes. It calls the legacy Win32 `SetConsoleTextAttribute`
# API (an out-of-band kernel RPC into conhost), then writes the text
# bytes via `Console.Out.Write`, then restores the attribute. The two
# channels (byte stream + Win32 attribute API) are not synchronized
# with each other -- inside DEC 2026 sync mode + the alternate screen
# buffer (`sca usage -Watch`) the per-cell attributes don't align with
# the buffered cell writes, and the body renders in default colors.
# Verified against PS 7.6 source: ConsoleHostUserInterface.cs's
# `Write(fg, bg, value, newLine)` is `RawUI.ForegroundColor = X` ->
# `WriteImpl` -> restore. No ANSI emission anywhere.
#
# `Write-Color` puts SGR codes INTO the message string itself:
#   `\e[<color>m<message>\e[0m`
# That moves the color information into the byte stream, which:
#   1. Sits inside the DEC 2026 sync envelope correctly -> watch mode
#      renders in color.
#   2. Flows through PowerShell's `WriteImpl(string)` -> `GetOutputString
#      (value, supportsVT)` filter, which strips SGR when
#      `$PSStyle.OutputRendering = 'PlainText'` -> -NoColor mode works.
#
# That second point is what makes `Invoke-Main`'s `OutputRendering` toggle
# effective at all: the toggle cannot reach the legacy `-ForegroundColor`
# path, only SGR bytes in the stream.
#
# Color name mapping: PowerShell legacy `ConsoleColor` and PS7's
# `$PSStyle.Foreground` use opposite naming conventions. Legacy
# "Dark*" names = the standard ANSI 30-37 colors; legacy un-prefixed
# names (Yellow, Green, Red...) = ANSI bright 90-97. So our existing
# `DarkYellow` (warm amber/mustard headers) maps to
# `$PSStyle.Foreground.Yellow` (ANSI 33), and `Yellow` (advisory)
# maps to `BrightYellow` (ANSI 93). Visually equivalent to the
# pre-refactor rendering on every modern terminal palette.
#
# Palette convention. Not derivable from any single call site, so it is
# recorded once here; pick from this set rather than inventing a colour:
#   DarkYellow : section-title headers ('[Usage] Plan usage', '[List] Saved
#                slots'). Never a sentence.
#   Yellow     : advisories and warnings. "Attention required", never a header.
#   Green      : success on a side-effecting action ('[Save] Saved ...').
#   Red        : destructive completion ('[Remove] Removed ...').
#   DarkGray   : dimmed metadata (verbose account row, watch footer).
#
# FORCE_COLOR is deliberately unsupported: Write-Host writes to the
# information stream (6), not stdout, so a pipe or redirect never captures
# colour in the first place and there is nothing for the override to force.
function Write-Color {
    Param (
        [Parameter(Mandatory)] [String]              $Message,
        [AllowEmptyString()]   [AllowNull()] [String] $Color,
        [switch] $NoNewline
    )

    $sgr = switch ($Color) {
        'Yellow'     { $PSStyle.Foreground.BrightYellow }
        'DarkYellow' { $PSStyle.Foreground.Yellow       }
        'Green'      { $PSStyle.Foreground.BrightGreen  }
        'Red'        { $PSStyle.Foreground.BrightRed    }
        'Cyan'       { $PSStyle.Foreground.BrightCyan   }
        'Gray'       { $PSStyle.Foreground.White        }
        'DarkGray'   { $PSStyle.Foreground.BrightBlack  }
        default      { '' }
    }

    if ($sgr) { $Message = "$sgr$Message$($PSStyle.Reset)" }

    if ($NoNewline) {
        Write-Host -NoNewline $Message
    } else {
        Write-Host $Message
    }
}

# Terminal width in columns, or 0 when it cannot be determined.
#
# [Console]::WindowWidth throws in hosts with no attached console (Pester,
# CI, a redirected stdout), so every width-aware renderer needs the same
# try/catch. 0 rather than a guessed default: callers decide what "unknown"
# means for them (drop the auto-mode indicator, skip the bar clamp) instead
# of laying out against a width the terminal may not have. A function rather
# than an inline expression so tests can mock a width.
function Get-ConsoleWidth {
    try { return [int][Console]::WindowWidth } catch { return 0 }
}

# Single chokepoint for ALL non-color VT control sequences in the watch
# lifecycle (alt screen buffer, cursor hide/show, DEC 2026 synchronized
# output, clear screen, cursor home).
#
# Why this exists: PowerShell's `OutputRendering = 'PlainText'` (set by
# `-NoColor` / `$env:NO_COLOR` in `Invoke-Main`) routes every `Write-Host`
# string through `StringDecorated.AnsiRegex`, which is the union of
#   GraphicsRegex  : \x1b\[\d*(;\d+)*m       SGR (color/style)
#   CsiRegex       : \x1b\[\?\d+[hl]         DEC private modes
#   HyperlinkRegex : \x1b\]8;;.*?\x1b\\      OSC 8 hyperlinks
# (verified against PowerShell `StringDecorated.cs`). The DEC 2026 sync
# envelope (`ESC[?2026h`/`l`), alt buffer (`ESC[?1049h`/`l`), and cursor
# hide/show (`ESC[?25l`/`h`) all match `CsiRegex` and are stripped through
# Write-Host -- which silently disables flicker-free rendering in NoColor
# watch mode. `[Console]::Out.Write` bypasses `StringDecorated` entirely,
# so DEC private modes survive regardless of `OutputRendering`.
#
# Body color SGR continues to flow through `Write-Color` -> `Write-Host`
# so `PlainText` still strips body color in `-NoColor` mode (correct).
# `ESC[2J` (clear) and `ESC[H` (cursor home) survive both paths because
# their terminators (J, H) match neither regex; they could go through
# Write-Host without harm, but routing them through this helper keeps
# the watch lifecycle's VT writes consistent.
#
# `[Console]::Out.Flush()` is belt-and-suspenders -- on an interactive
# console handle .NET's TextWriter wrapper writes through immediately,
# but the explicit flush guarantees ordering vs. subsequent Write-Host
# body emission and costs nothing on a 1Hz loop.
function Write-VTSequence {
    Param ([Parameter(Mandatory)] [String] $Sequence)

    [Console]::Out.Write($Sequence)
    [Console]::Out.Flush()
}

# Capture a frame renderer's Write-Host / Write-Color output as one string.
# The renderer writes to the information stream (6); `6>&1` merges it so we
# can rebuild the line breaks from each record's NoNewLine flag (which keeps
# the -Auto header's multi-segment line -- built with `Write-* -NoNewline`
# -- as a single line). The captured `.Message` carries the raw SGR bytes
# that Write-Color embedded; [Console]::Out.Write does NOT strip them, so we
# drop SGR ourselves when -NoColor / NO_COLOR put OutputRendering into
# PlainText, mirroring the StringDecorated filter Write-Host would apply (see
# Write-VTSequence docblock for the regex). This is the capture half of the
# watch loop's flicker-free single-write paint; ConvertTo-WatchFrameSequence
# is the transform half.
function Get-WatchFrameText {
    Param ([Parameter(Mandatory)] [scriptblock] $RenderScript)

    $sb = [System.Text.StringBuilder]::new()
    foreach ($rec in (& $RenderScript 6>&1)) {
        $md = $rec.MessageData
        if ($md -is [System.Management.Automation.HostInformationMessage]) {
            [void]$sb.Append($md.Message)
            if (-not $md.NoNewLine) { [void]$sb.Append("`n") }
        } else {
            # Defensive: a renderer that leaks a non-Write-Host object to the
            # success stream still round-trips as text rather than crashing.
            [void]$sb.Append([string]$rec).Append("`n")
        }
    }
    $text = $sb.ToString()
    if ($PSStyle.OutputRendering -eq 'PlainText') {
        $text = [regex]::Replace($text, "`e\[[0-9;]*m", '')
    }
    return $text
}

# Turn a captured frame string into an in-place-overwrite VT sequence:
# cursor-home (ESC[H), every line self-clearing its tail (ESC[K), then a
# trailing erase-below (ESC[0J) to drop any rows left by a taller previous
# frame. Deliberately NO ESC[2J: the frame is never blanked to black, so a
# render tick that lands mid-paint on a loaded machine shows the previous
# frame under the new one (imperceptible, the frames are near-identical)
# instead of the "black -> row for row" flash that a clear-then-redraw
# produces when the terminal lacks DEC 2026 or is too busy to honor it.
# This is the ANSI equivalent of how PSReadLine / SetBufferContents repaint:
# overwrite in place, never clear.
function ConvertTo-WatchFrameSequence {
    Param ([AllowEmptyString()] [AllowNull()] [string] $FrameText)

    $body = (($FrameText -split "`n") | ForEach-Object { $_ + "`e[K" }) -join "`n"
    return "`e[H" + $body + "`e[0J"
}

# We are sanitizing names by replacing invalid characters with underscores,
# trimming trailing dots, and rejecting reserved device names like CON, PRN,
# AUX, NUL, COM1-9, LPT1-9.
#
# The rule set is Windows-strict and applied on every platform on purpose,
# not by omission. Linux permits nearly every byte in a filename, so relaxing
# per-platform would mean the same slot name produces different filenames on
# different machines, and a `.claude` directory copied or synced from Linux to
# Windows could contain slots Windows cannot open. A single conservative rule
# set keeps slot files portable; the cost is that a Linux user cannot name a
# slot `CON`, which is not a real loss.
function Get-SafeName {
    Param ([String] $inputName)

    if ([string]::IsNullOrWhiteSpace($inputName)) { throw "Name required." }

    # A hardcoded class rather than [IO.Path]::GetInvalidFileNameChars(),
    # which returns only '/' and NUL on Unix and would silently relax the
    # rules there. Space is included so slot names stay shell-friendly.
    # [ and ] are valid on the Windows filesystem but PowerShell's -Path
    # parameter treats them as character-class wildcards, so we sanitize
    # them to keep every Test-Path / Copy-Item / Remove-Item call below
    # unambiguous (defense-in-depth alongside -LiteralPath on those calls).
    # ( and ) are sanitized because slot filenames encode the OAuth account
    # email as `.credentials.<slot>(<email>).json`; parens in the slot
    # name would confuse the parser in Get-SlotFileInfo and produce the
    # wrong (slot, email) split.
    $clean = $inputName -replace '[\\/:*?"<>|\[\]()\x00-\x1F ]', '_'

    # Strip trailing dots (Windows silently drops them, which would
    # collapse e.g. 'foo.' and 'foo' into the same slot file).
    $clean = $clean.TrimEnd('.')

    if ([string]::IsNullOrEmpty($clean) -or $clean -eq '.' -or $clean -eq '..') {
        throw "Name '$inputName' resolves to an invalid filename."
    }

    # Windows reserves these device names regardless of extension, so
    # CON.bak is just as forbidden as CON. Compare the pre-first-dot
    # segment against the reserved list.
    $baseSegment = ($clean -split '\.', 2)[0]
    $reserved    = @('CON','PRN','AUX','NUL') + (1..9 | ForEach-Object { "COM$_" }) + (1..9 | ForEach-Object { "LPT$_" })
    if ($reserved -contains $baseSegment.ToUpperInvariant()) {
        throw "'$clean' uses the reserved Windows device name '$baseSegment'."
    }

    if ($clean -ne $inputName) {
        Write-Color "Sanitized to: '$clean'" 'Yellow'
    }

    return $clean
}

# Parse a slot filename (base name, e.g. ".credentials.work(alice@x.com).json")
# into a (Name, Email) tuple. The filename format is:
#   .credentials.<slot-name>.json                    -> unlabeled
#   .credentials.<slot-name>(<email>).json           -> labeled; email must
#                                                       contain '@' to be
#                                                       treated as an email
# The @-in-parens requirement keeps a slot named e.g. "work(v2)" parsing as
# "slot = work(v2), email = none" rather than mis-splitting at the parens.
# Slot names cannot themselves contain '(' or ')' because Get-SafeName
# replaces them with '_' at save time. Returns $null if the filename does
# not match the .credentials.*.json convention.
function Get-SlotFileInfo {
    Param ([String] $FileName)

    # Group 1 = slot name (lazy, so the optional parens-email group wins
    # when present). Group 2 = email (optional; only matches when the
    # parenthesized content contains '@'). .NET regex groups default to
    # empty string when the group did not participate; we coerce to $null
    # below for clarity at the call site.
    if ($FileName -notmatch '^\.credentials\.(.+?)(?:\(([^()]*@[^()]*)\))?\.json$') {
        return $null
    }
    $slotName = $Matches[1]
    $email    = if ($Matches.Count -ge 3 -and $Matches[2]) { $Matches[2] } else { $null }
    return [pscustomobject]@{
        Name  = $slotName
        Email = $email
    }
}

# Build the slot filename for a given (name, email) pair. When email is
# absent, or when the email (case-insensitively) equals the slot name, the
# unlabeled form is returned: the slot name already conveys the account
# and a redundant parenthesized email suffix would only add visual noise.
function Get-SlotFileName {
    Param (
        [String] $Name,
        [String] $Email
    )

    if (-not $Email -or $Name.ToLowerInvariant() -eq $Email.ToLowerInvariant()) {
        return ".credentials.$Name.json"
    }
    return ".credentials.$Name($Email).json"
}

# Enumerate saved credential slots and fingerprint each one against the
# active .credentials.json so callers (list, rotation, usage) share a
# single source of truth. Slots are returned sorted alphabetically by
# name for deterministic rotation order and consistent list output.
#
# Sidecar requirement (post-v2.1.0): slots without a valid
# `.credentials.<name>(<email>).account.json` sidecar are HIDDEN. The
# sidecar carries the captured oauthAccount block restored to
# ~/.claude.json on switch; without it, sca cannot keep Claude Code's
# /status display in sync with the active slot, so the slot is
# unusable. Re-running `sca save <name>` while that slot is active
# recaptures the sidecar from ~/.claude.json and restores visibility.
# No automated migration; legacy slots from pre-v2.1.0 simply become
# invisible until re-saved.
#
# Returns an array of slot objects { Name, Email, Path, IsActive, Sidecar },
# sorted alphabetically by Name. Empty array when no slots saved.
#
# Sidecar is the parsed sidecar object (not raw JSON), which Invoke-
# SwitchAction needs to restore ~/.claude.json. Carrying it inline
# avoids re-reading the file at switch time.
#
# IsActive is sourced from $StateFile via Read-ScaState (which auto-
# migrates by content-hash on first call). This function itself makes
# zero network calls and zero hash computations on the slot files; HTTP
# and hashing live in the calling action's Invoke-Reconcile prelude
# (Invoke-ListAction, Invoke-SwitchAction, Invoke-UsageAction). Callers
# that want a true offline read should call Get-Slots without first
# reconciling.
function Get-Slots {
    $files = @(Get-CredentialSlotFiles | Sort-Object -Property Name)

    $state      = Read-ScaState
    $activeName = if ($state) { $state.active_slot } else { $null }

    $slots = foreach ($file in $files) {
        $parsed = Get-SlotFileInfo -FileName $file.Name
        if (-not $parsed) { continue }

        # Sidecar requirement: skip slots without a valid sidecar so
        # they don't appear in list / usage / rotation. The slot file
        # itself stays on disk untouched; re-saving via `sca save
        # <name>` while it's active will recapture the sidecar.
        $sidecar = Read-Sidecar -SlotPath $file.FullName
        if (-not $sidecar) { continue }

        [pscustomobject]@{
            Name     = $parsed.Name
            Email    = $parsed.Email
            Path     = $file.FullName
            IsActive = ($activeName -and $parsed.Name -eq $activeName)
            Sidecar  = $sidecar
        }
    }

    # `foreach` assignment yields $null / scalar / Object[] for 0 / 1 / N
    # iterations; PowerShell's pipeline unrolls on emit, so callers that
    # wrap with `@(Get-Slots)` or pipe through Where-Object / ForEach-Object
    # see the right shape across all three cases.
    $slots
}

# Find a slot file by its parsed slot-name, regardless of whether the
# file on disk has the labeled `(email)` suffix or not. Returns the
# matching slot object (same shape as entries in Get-Slots.Slots) or
# $null when no slot matches. Used by Invoke-SwitchAction /
# Invoke-RemoveAction / Invoke-UsageAction so callers can reference a
# slot by user-visible name only.
function Find-SlotByName {
    Param ([String] $Name)

    return Get-Slots | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

# We are determining which slot should become active when `switch` is
# called without an explicit name. Behavior:
#   * No slots saved          -> throw (nothing to rotate to).
#   * One slot, already active -> print warning and return $null (caller exits).
#   * Active slot tracked      -> return { To; HasActiveSlot=$true } for the
#                                next slot (alphabetical, wraps).
#   * No active slot tracked   -> return { To=first; HasActiveSlot=$false }
#                                so the caller can emit a yellow advisory.
#
# `To` is a `{ Name; Email }` object (Email may be $null for unlabeled
# slots) so callers can render the filename-encoded email inline without
# re-looking-up the slot. Active-slot identification reads $StateFile
# (slot.IsActive populated by Get-Slots from state); no content hashing.
function Get-NextSlotName {
    $slots = @(Get-Slots)

    if ($slots.Count -eq 0) {
        throw "No slots saved. Use: sca save <name>"
    }

    $activeIdx = -1
    for ($i = 0; $i -lt $slots.Count; $i++) {
        if ($slots[$i].IsActive) { $activeIdx = $i; break }
    }

    if ($slots.Count -eq 1 -and $activeIdx -eq 0) {
        Write-Color "[Switch] Only one slot ($(Format-SlotIdentity -Name $slots[0].Name -Email $slots[0].Email)) and it is already active. Nothing to do." 'Yellow'
        return $null
    }

    $toSlot = if ($activeIdx -lt 0) { $slots[0] } else { $slots[($activeIdx + 1) % $slots.Count] }

    return [pscustomobject]@{
        To            = [pscustomobject]@{ Name = $toSlot.Name; Email = $toSlot.Email }
        HasActiveSlot = ($activeIdx -ge 0)
    }
}

# We are adding the switch_claude_account_caller function and aliases
# sca (short) and switch-claude-account (long) to the user's PowerShell
# profile for convenient access. The block is written in a single
# Add-Content call so a failure mid-write cannot leave an orphan marker.
function Add-To-Profile {
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    }

    # Remove any existing block before re-adding to ensure the
    # wrapper function is always up to date. If the profile has an
    # orphan marker, Remove-From-Profile throws rather than proceeding.
    Remove-From-Profile -Quiet

    # Escape single quotes in the script path so an apostrophe in the
    # path cannot break the single-quoted string in the wrapper.
    $escapedPath = $ScriptPath -replace "'", "''"
    $funcDef     = "function switch_claude_account_caller { & '$escapedPath' @args }"

    $aliasShort  = "Set-Alias -Name sca -Value switch_claude_account_caller -Option AllScope"
    $aliasLong   = "Set-Alias -Name switch-claude-account -Value switch_claude_account_caller -Option AllScope"

    # Native newline so the block matches the platform convention of the
    # profile we are appending to (CRLF on Windows, LF elsewhere), rather
    # than injecting CRLF into an otherwise-LF file. Remove-From-Profile
    # splices on `\r?\n`, so either terminator round-trips.
    $newline = [Environment]::NewLine
    $block   = @($MarkerStart, $funcDef, $aliasShort, $aliasLong, $MarkerEnd) -join $newline

    # Separate our block from any preceding profile content with a blank
    # line. Works for every encoding because the separator is just text.
    $profileInfo = Get-Item -LiteralPath $ProfilePath
    if ($profileInfo.Length -gt 0) {
        $block = $newline + $block
    }

    $encoding = Get-ProfileEncoding $ProfilePath
    Add-Content -LiteralPath $ProfilePath -Value $block -Encoding $encoding

    Write-Color "[Install] Installed! Close and reopen PowerShell, then use: sca save <name>" 'Green'
    Write-Host "   Quick ref: sca | sca -h | sca list | sca save <name> | sca switch <name> | sca remove <name>"
}

# We are removing the switch_claude_account_caller block from the
# user's PowerShell profile by splicing the marker-delimited region out
# of the raw file content. Reading with -Raw and writing -NoNewline
# preserves the user's existing line endings (LF, CRLF, or mixed), BOM,
# and trailing-newline convention byte-for-byte. A line-based read/write
# would silently rewrite the whole profile to CRLF. When only one of
# the two markers is present, we refuse to mutate the profile and throw
# so the user can inspect the damage manually. -Quiet suppresses only
# the benign "no block found" message; the orphan-marker throw is never
# silenced.
function Remove-From-Profile {
    param([switch]$Quiet)
    if (-not (Test-Path -LiteralPath $ProfilePath)) { return }

    $encoding = Get-ProfileEncoding $ProfilePath
    $raw      = Get-Content -LiteralPath $ProfilePath -Raw -Encoding $encoding
    if ($null -eq $raw) { $raw = '' }

    # Line-anchored, case-sensitive marker detection. [ \t]* allows trimmed
    # horizontal whitespace around the marker text on its line but nothing
    # else, so a user comment that merely contains the marker substring will
    # not be misclassified. The (?=\r?\n|\z) lookahead matches end-of-line
    # for both LF and CRLF as well as end-of-input; the simpler $ anchor
    # would fail on CRLF lines because .NET treats $ as "before \n" only.
    $startLine = '(?m)^[ \t]*' + [regex]::Escape($MarkerStart) + '[ \t]*(?=\r?\n|\z)'
    $endLine   = '(?m)^[ \t]*' + [regex]::Escape($MarkerEnd)   + '[ \t]*(?=\r?\n|\z)'

    $hasStart = [regex]::IsMatch($raw, $startLine)
    $hasEnd   = [regex]::IsMatch($raw, $endLine)

    if (-not $hasStart -and -not $hasEnd) {
        if (-not $Quiet) {
            Write-Color "[Uninstall] No Switch Claude Account block found; profile unchanged." 'Yellow'
        }
        return
    }

    if ($hasStart -xor $hasEnd) {
        $orphan = if ($hasStart) { $MarkerStart } else { $MarkerEnd }
        throw "Profile '$ProfilePath' has an orphan '$orphan' marker without its counterpart. Remove it manually and re-run. Profile left unchanged."
    }

    # Splice the block out of the raw content. The leading (?:\r?\n)? absorbs
    # the blank-line separator Add-To-Profile prepends when the profile was
    # non-empty; the trailing (?:\r?\n)? absorbs the line terminator Add-Content
    # appends after the block. Together they keep install -> uninstall
    # byte-identical to the pre-install state. (?s) so . matches newlines;
    # (?m) so ^ matches line starts; .*? is non-greedy so the earliest
    # MarkerEnd closes the match.
    $blockPattern =
        '(?sm)(?:\r?\n)?' +
        '^[ \t]*' + [regex]::Escape($MarkerStart) + '[ \t]*\r?\n' +
        '.*?' +
        '^[ \t]*' + [regex]::Escape($MarkerEnd)   + '[ \t]*' +
        '(?:\r?\n)?'

    $new = [regex]::Replace($raw, $blockPattern, '')

    # -NoNewline so Remove leaves no trailing newline of its own. Add-To-Profile
    # prepends a separator when the file is non-empty and Add-Content adds one
    # trailing newline, which keeps install -> install byte-idempotent.
    Set-Content -LiteralPath $ProfilePath -Value $new -Encoding $encoding -Force -NoNewline

    if (-not $Quiet) {
        Write-Color "[Uninstall] Uninstalled. Close and reopen PowerShell to remove the alias." 'Red'
    }
}

# Atomic-write a fresh auto-save slot file (and its identity sidecar, when
# OAuthAccount is non-null) and update state.active_slot to point at it.
# Returns the generated slot name on success.
#
# Caller owns the user-visible advisory message and the return-object
# `Action` discriminator. Invoke-Reconcile has two auto-save callers
# (cross-account swap detection vs unknown-state recovery) whose
# advisory text and return shape differ enough that merging them into
# one helper would conflate semantically distinct events; keeping the
# advisory + return at the call sites preserves that distinction while
# this helper handles the mechanical write sequence.
#
# Sidecar-write failure is non-fatal: a yellow advisory is printed
# (Get-Slots will hide a sidecar-less slot, so the orphan tokens file
# is invisible-but-on-disk and `sca remove` cleans it up by name).
function New-AutoSaveSlot {
    Param (
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [String] $Email,
        $OAuthAccount,
        [String] $SourceLabel,
        [Parameter(Mandatory)] [String] $LastSyncHash
    )

    $autoName = 'auto-' + ([DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'"))
    $autoPath = Join-Path $CredDir (Get-SlotFileName -Name $autoName -Email $Email)
    Set-CredentialFileAtomic -Path $autoPath -Bytes $Bytes
    if ($OAuthAccount) {
        try {
            Write-Sidecar -SlotPath $autoPath -OAuthAccount $OAuthAccount -Source $SourceLabel
        }
        catch {
            Write-Color "[Sync] Auto-save sidecar write failed for '$autoName': $($_.Exception.Message)" 'Yellow'
        }
    }
    Update-ScaState -ActiveSlot $autoName -LastSyncHash $LastSyncHash | Out-Null
    return $autoName
}

# Reconcile .credentials.json with the saved slot tracked in $StateFile.
# Called at the start of every credentials-touching action that needs the
# tracked slot to reflect Claude Code's most recent token refresh (sca
# switch and sca usage in the redesigned model).
#
# Algorithm (5 outcomes; never throws unless an atomic write itself fails):
#   1. .credentials.json missing                   -> noop
#   2. hash matches state.last_sync_hash           -> noop
#   3. tracked slot exists, identity matches       -> mirror bytes -> slot
#   4. tracked slot exists, identity DIFFERS       -> auto-save under new name
#                                                     (cross-account swap detected;
#                                                      old slot file preserved)
#   5. no tracked slot, OR slot file is gone       -> auto-save under new name
#
# Identity probe: ~/.claude.json's oauthAccount.emailAddress. This is the
# same source Claude Code uses for /status, so reconcile and Claude Code can
# never disagree about the active identity, and it is offline. Preferred over
# /api/oauth/profile, which can return a different email for the same
# account. When ~/.claude.json has no
# oauthAccount yet (rare: fresh install, never logged into Claude Code),
# we fall back to /api/oauth/profile so the noop / mirror branches still
# work for users in that transient state.
#
# Tracked slot's identity comes from the slot's sidecar (which was
# captured at save time from ~/.claude.json or /api/oauth/profile). This
# is what we compare ~/.claude.json's current value against.
#
# Race protection: bytes are read from .credentials.json once, then both
# hashed and written. If Claude Code rewrites the file between our read
# and our write, the slot file is consistent with our hash; the next
# reconcile catches up to the newer bytes. No retry loop needed.
#
# Returns a [pscustomobject] describing the outcome so tests and callers
# can assert on the action without parsing stdout. Stdout still carries
# the user-visible advisory for the two non-silent branches (auto-save,
# identity-change).
function Invoke-Reconcile {
    if (-not (Test-Path -LiteralPath $CredFile)) {
        return [pscustomobject]@{ Action = 'noop'; Reason = 'no-active-credentials' }
    }

    $bytes = [System.IO.File]::ReadAllBytes($CredFile)

    # Hash the bytes we just read (not the file path) so the (bytes, hash)
    # pair is internally consistent even if Claude Code rewrites the file
    # mid-reconcile. Get-SHA256Hex produces uppercase hex matching the
    # format Read-ScaState's auto-migration uses, so values round-trip
    # equality across credential-file sources.
    $hash = Get-SHA256Hex -Bytes $bytes

    $state = Read-ScaState
    if ($state -and $state.last_sync_hash -eq $hash) {
        return [pscustomobject]@{ Action = 'noop'; Reason = 'hash-match' }
    }

    # Bytes differ from last sync. Resolve new identity. Preferred: read
    # ~/.claude.json's oauthAccount.emailAddress (offline; same source
    # Claude Code uses). Fallback: /api/oauth/profile (network) when
    # ~/.claude.json has no oauthAccount populated yet.
    $newAccount = Get-OAuthAccountFromClaudeJson
    $newEmail   = if ($newAccount) { $newAccount.emailAddress } else { $null }
    if (-not $newEmail) {
        $profileResult = Get-SlotProfile -SlotPath $CredFile
        if ($profileResult.Status -eq 'ok') {
            $newEmail = $profileResult.Email
            # Synthesize a minimal accountInfo for the auto-save sidecar.
            $newAccount = [pscustomobject]@{
                accountUuid      = $null
                emailAddress     = $newEmail
                organizationUuid = $null
                displayName      = $null
                organizationName = $null
            }
        }
    }
    $sourceLabel = if ($newAccount -and $newAccount.accountUuid) { 'claude_json' } else { 'api_profile' }

    if ($state -and $state.active_slot) {
        $slot = Find-SlotByName -Name $state.active_slot
        if ($slot) {
            # Tracked slot's email comes from its sidecar (Get-Slots
            # always populates this on the slot object). Tolerate
            # offline / unknown-new-identity by falling into the
            # same-identity branch; preserves continuity over paranoia.
            $slotEmail    = if ($slot.Sidecar) { [string]$slot.Sidecar.oauthAccount.emailAddress } else { $slot.Email }
            $sameIdentity = (-not $newEmail) -or (-not $slotEmail) -or ($newEmail -eq $slotEmail)
            if ($sameIdentity) {
                Set-CredentialFileAtomic -Path $slot.Path -Bytes $bytes
                Update-ScaState -LastSyncHash $hash | Out-Null
                return [pscustomobject]@{
                    Action = 'mirror'
                    Slot   = $state.active_slot
                    Email  = $slotEmail
                }
            }

            # Cross-account swap detected. DON'T overwrite; auto-save the
            # new credentials under a fresh name so both identities are
            # preserved on disk and the user can resolve the conflict.
            $autoName = New-AutoSaveSlot -Bytes $bytes -Email $newEmail `
                                         -OAuthAccount $newAccount `
                                         -SourceLabel $sourceLabel `
                                         -LastSyncHash $hash

            $oldIdent = Format-SlotIdentity -Name $state.active_slot -Email $slotEmail
            Write-Color "[Sync] Active credentials are now $newEmail; previous slot $oldIdent preserved. Active slot is now '$autoName'." 'Yellow'
            return [pscustomobject]@{
                Action       = 'identity-change'
                Slot         = $autoName
                PreviousSlot = $state.active_slot
                Email        = $newEmail
            }
        }
        # state.active_slot pointed at a slot file that no longer exists
        # OR the slot file exists but has no sidecar (Get-Slots filtered
        # it out). Fall through to auto-save so the new bytes still land
        # in a fresh, sidecared slot.
    }

    # No tracked slot, or tracked slot file/sidecar is gone. Auto-save fallback.
    $autoName = New-AutoSaveSlot -Bytes $bytes -Email $newEmail `
                                 -OAuthAccount $newAccount `
                                 -SourceLabel $sourceLabel `
                                 -LastSyncHash $hash

    $autoIdent = Format-SlotIdentity -Name $autoName -Email $newEmail
    Write-Color "[Sync] Auto-saved unknown active credentials as $autoIdent." 'Yellow'
    return [pscustomobject]@{
        Action = 'auto-save'
        Slot   = $autoName
        Email  = $newEmail
    }
}

# We are extracting each action body into its own function so the logic
# is directly invokable from tests without spawning a subprocess and
# without re-parsing the $Action dispatcher. The dispatcher below becomes
# a thin switch that forwards to these functions.

function Invoke-SaveAction {
    Param ([String] $Name)

    $safeName = Get-SafeName $Name

    if (-not (Test-Path -LiteralPath $CredFile)) {
        throw "$CredFile not found. Log in via Claude Code first."
    }

    # Refuse if Claude Code is running. We resolve identity from
    # ~/.claude.json's oauthAccount, which Claude Code keeps in an
    # in-memory cache and may flush back to disk at any moment. Saving
    # while Claude Code runs would silently capture stale identity into
    # the sidecar AND risk overwriting our writes if a flush races our
    # write. Refuse-while-running is the chosen mitigation.
    if (Test-ClaudeRunning) {
        throw "Claude Code is running. Close it before 'sca save' so identity capture is consistent."
    }

    # Resolve identity. ~/.claude.json's oauthAccount is the preferred
    # source (it's exactly what Claude Code's /status displays, drift-
    # proof by construction). Fall back to a live /api/oauth/profile
    # call only when ~/.claude.json has no oauthAccount yet (rare:
    # fresh install, user wiped the config, etc.). Failing both ->
    # refuse the save: a sidecar without identity is invalid by design.
    $accountInfo = Get-OAuthAccountFromClaudeJson
    $sourceLabel = 'claude_json'
    if (-not $accountInfo) {
        # Fallback path: live /api/oauth/profile. Returns only the email,
        # so the rest of the oauthAccount fields default to $null. The
        # slot is still usable (Claude Code re-derives missing fields
        # from the next refresh response). Use a non-automatic-variable
        # name (`$profileResult` rather than `$profile`); `$profile` is
        # PowerShell's automatic for the running profile path and a
        # collision could surprise downstream code.
        $profileResult = Get-SlotProfile -SlotPath $CredFile
        if ($profileResult.Status -eq 'ok' -and $profileResult.Email) {
            $accountInfo = [pscustomobject]@{
                accountUuid      = $null
                emailAddress     = $profileResult.Email
                organizationUuid = $null
                displayName      = $null
                organizationName = $null
            }
            $sourceLabel = 'api_profile'
        } else {
            $reason = if ($profileResult.Error) {
                Format-StatusErrorTail -Message $profileResult.Error -Max 60
            } else {
                $profileResult.Status
            }
            throw "Cannot resolve account identity: ~/.claude.json has no oauthAccount and /api/oauth/profile failed ($reason). Sign in to Claude Code first ('claude /login')."
        }
    }

    $email = $accountInfo.emailAddress
    if ([string]::IsNullOrWhiteSpace($email)) {
        throw "Resolved oauthAccount has no emailAddress; cannot save."
    }

    # Read .credentials.json bytes once. The same bytes are written to
    # the slot file via atomic rename and hashed for state.last_sync_hash;
    # this read-once-write-once approach ensures internal consistency
    # even if Claude Code rewrites .credentials.json during the save.
    # (Claude Code is closed, but a background process, antivirus or
    # backup tool, could still touch the file.)
    $bytes = [System.IO.File]::ReadAllBytes($CredFile)

    # Final filename now that identity is known. We write directly to the
    # final path; no unlabeled-then-rename dance.
    $finalSlotName = Get-SlotFileName -Name $safeName -Email $email
    $finalSlotPath = Join-Path $CredDir $finalSlotName

    # Find any pre-existing slot files / sidecars for this slot name
    # (labeled or unlabeled, possibly with stale email) and SNAPSHOT
    # their bytes into memory before any disk mutation. The snapshot is
    # the rollback source for the catch path: if either the tokens or
    # sidecar write fails, we restore from these buffers so a transient
    # failure on a re-save cannot leave the user with no slot for this
    # name. Get-Slots filters out sidecar-less slots, so we enumerate
    # the raw file system here to also catch invisible legacy slots
    # that share this slot name.
    $snapshots = @()
    $rawFiles = @(Get-CredentialSlotFiles)
    foreach ($rf in $rawFiles) {
        $parsed = Get-SlotFileInfo -FileName $rf.Name
        if (-not $parsed -or $parsed.Name -ne $safeName) { continue }

        $snap = [pscustomobject]@{
            Path         = $rf.FullName
            Bytes        = $null
            SidecarPath  = Get-SidecarPath -SlotPath $rf.FullName
            SidecarBytes = $null
        }
        try {
            $snap.Bytes = [System.IO.File]::ReadAllBytes($rf.FullName)
        }
        catch {
            # Read failure (file locked / unreadable). Mark non-restorable
            # but proceed with the save: refusing on a stale file the
            # user is explicitly overwriting would be surprising.
            Write-Color "[Save] WARNING: could not snapshot $($rf.FullName) ($($_.Exception.Message)); rollback for this path will be skipped." 'Yellow'
        }
        if (Test-Path -LiteralPath $snap.SidecarPath) {
            try {
                $snap.SidecarBytes = [System.IO.File]::ReadAllBytes($snap.SidecarPath)
            }
            catch {
                Write-Color "[Save] WARNING: could not snapshot $($snap.SidecarPath) ($($_.Exception.Message)); rollback for this path will be skipped." 'Yellow'
            }
        }
        $snapshots += $snap
    }

    # Write tokens, then sidecar. Order matters for atomic-pair semantics.
    # On any failure we clear partial new state at $finalSlotPath, then
    # restore each snapshot's bytes (tokens AND sidecar) so the slot
    # returns to its pre-save state. An orphan sidecar without a matching
    # tokens file is harmless; Get-Slots only iterates tokens files,
    # sidecars are looked up by-path.
    try {
        Set-CredentialFileAtomic -Path $finalSlotPath -Bytes $bytes
        Write-Sidecar -SlotPath $finalSlotPath -OAuthAccount $accountInfo -Source $sourceLabel
    }
    catch {
        $innerMsg = $_.Exception.Message

        # Clear any partial new pair we wrote. If $finalSlotPath happened
        # to coincide with a snapshot path (same-email re-save), this
        # also wipes the just-overwritten old bytes; the restore loop
        # below puts them back.
        Remove-Item -LiteralPath $finalSlotPath -Force -ErrorAction SilentlyContinue
        Remove-Sidecar -SlotPath $finalSlotPath

        # Restore each snapshot. Per-snapshot try/catch so one restore
        # failure does not abort the others.
        foreach ($snap in $snapshots) {
            if ($null -ne $snap.Bytes) {
                try {
                    Set-CredentialFileAtomic -Path $snap.Path -Bytes $snap.Bytes
                }
                catch {
                    Write-Color "[Save] WARNING: could not restore $($snap.Path) ($($_.Exception.Message))." 'Yellow'
                }
            }
            if ($null -ne $snap.SidecarBytes) {
                try {
                    Set-CredentialFileAtomic -Path $snap.SidecarPath -Bytes $snap.SidecarBytes
                }
                catch {
                    Write-Color "[Save] WARNING: could not restore $($snap.SidecarPath) ($($_.Exception.Message))." 'Yellow'
                }
            }
        }

        throw "Save failed for slot '$safeName' ($innerMsg); attempted to restore previous slot state."
    }

    # New pair is durable. Delete obsolete siblings (any snapshot whose
    # path differs from $finalSlotPath). Same-path snapshots were
    # overwritten in place by the atomic Replace above and need no
    # further action.
    foreach ($snap in $snapshots) {
        if ($snap.Path -ne $finalSlotPath) {
            Remove-Item -LiteralPath $snap.Path -Force -ErrorAction SilentlyContinue
            Remove-Sidecar -SlotPath $snap.Path
        }
    }

    # Update state: this slot is now the active one, and its bytes match
    # .credentials.json (we just wrote them). Hash the bytes we wrote
    # rather than re-reading either file, for the read-once-write-once
    # consistency property described above.
    $hash = Get-SHA256Hex -Bytes $bytes
    Update-ScaState -ActiveSlot $safeName -LastSyncHash $hash | Out-Null

    $sourceTail = if ($sourceLabel -eq 'api_profile') { ' [identity from /api/oauth/profile]' } else { '' }
    Write-Color "[Save] Saved as $(Format-SlotIdentity -Name $safeName -Email $email)$sourceTail" 'Green'
}

# Pure swap mechanism, factored out of Invoke-SwitchAction so the watch
# loop's -Auto path can rotate without rendering the `[Switch]` header
# or the saved-slot table that follows it in the user-facing switch
# action. Side effects only:
#
#   1. Atomic-rename write the slot's bytes into .credentials.json.
#   2. Substitute the destination slot's captured oauthAccount into
#      ~/.claude.json's top-level oauthAccount block. Failure here is
#      surfaced as a yellow advisory (NOT fatal): the credentials swap
#      has already happened, so the user sees the partial-success state
#      and can re-run once the ~/.claude.json issue clears.
#   3. Update $StateFile so state.active_slot points at the destination
#      and state.last_sync_hash matches the new credentials bytes.
#
# Preconditions (callers MUST enforce):
#   * Test-ClaudeRunning returned $false. The ~/.claude.json write
#     races Claude Code's in-memory oauthAccount cache; this helper
#     does NOT recheck the running guard.
#   * $Slot has a valid sidecar (the caller resolved it via
#     Find-SlotByName / Get-Slots, both of which filter out
#     sidecar-less slots).
#
# No reconcile prelude here either; the caller's higher-level workflow
# already reconciled or has its own per-tick capture (the watch loop's
# per-poll Invoke-Reconcile covers the -Auto case).
function Invoke-SlotSwap {
    Param (
        [Parameter(Mandatory)] [pscustomobject] $Slot
    )

    # Atomic-rename copy: works even if Claude Code has .credentials.json
    # open (it grants share-delete); but with the running guard enforced
    # by the caller, this path normally only executes when Claude Code
    # is closed. Bytes are read from the slot file once and reused for
    # both the write and the state hash so the post-swap state.hash
    # matches the bytes we just wrote (not a re-read that could race a
    # concurrent refresh from another tool).
    $slotBytes = [System.IO.File]::ReadAllBytes($Slot.Path)
    Set-CredentialFileAtomic -Path $CredFile -Bytes $slotBytes

    # Restore the captured oauthAccount into ~/.claude.json so Claude
    # Code's /status display matches the active slot on next start.
    # Failure to write ~/.claude.json (file locked, malformed,
    # disappeared) is surfaced as an advisory; we do NOT rollback the
    # credentials write because Claude Code (or the OpenCode plugin in
    # the -Auto case) may have already started using the new tokens.
    try {
        Set-OAuthAccountInClaudeJson -OAuthAccount $Slot.Sidecar.oauthAccount
    }
    catch {
        Write-Color "[Switch] Tokens swapped to '$($Slot.Name)' but ~/.claude.json oauthAccount update failed: $($_.Exception.Message)" 'Yellow'
        Write-Color "[Switch] Claude Code's /status email may not reflect the new slot until you fix and re-run." 'Yellow'
    }

    $hash = Get-SHA256Hex -Bytes $slotBytes
    Update-ScaState -ActiveSlot $Slot.Name -LastSyncHash $hash | Out-Null
}

function Invoke-SwitchAction {
    Param ([String] $Name)

    # Refuse if Claude Code is running. Switch writes to ~/.claude.json's
    # oauthAccount block from the destination slot's sidecar, and a
    # running Claude Code instance keeps that file in an in-memory
    # cache that may flush and clobber our update. Refusing is the
    # simplest reliability guarantee.
    if (Test-ClaudeRunning) {
        throw "Claude Code is running. Close it before 'sca switch' so the email-display change applies cleanly."
    }

    # Reconcile FIRST so any pending Claude Code refresh on the outgoing
    # active slot is mirrored into the saved slot file before we
    # overwrite .credentials.json. If reconcile triggers an auto-save or
    # identity-change branch, its yellow advisory prints above the
    # subsequent switch output; that is desired (the user sees
    # context for the unusual state).
    Invoke-Reconcile | Out-Null

    # When invoked without a name, rotate to the next saved slot
    # (alphabetical, wrap-around). Get-NextSlotName returns $null for
    # the single-slot-already-active no-op and prints its own yellow
    # advisory; we return in that case so neither the success line nor
    # the table render (nothing has changed, the user already saw the
    # advisory).
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $rotation = Get-NextSlotName
        if (-not $rotation) { return }

        $safeName = $rotation.To.Name
        $toIdent  = Format-SlotIdentity -Name $rotation.To.Name -Email $rotation.To.Email

        # No-active-slot advisory: yellow line surfaced before the green
        # success line so the user notices the unusual state. Rotation
        # proceeds either way. The happy path (HasActiveSlot=true)
        # emits no advisory; the slot table beneath the success line
        # makes the transition self-evident via the `*` marker.
        if (-not $rotation.HasActiveSlot) {
            Write-Color "[Switch] No currently active slot detected. Rotating to $toIdent." 'Yellow'
        }
    } else {
        $safeName = Get-SafeName $Name
    }

    $slot = Find-SlotByName -Name $safeName
    if (-not $slot) {
        # Find-SlotByName goes through Get-Slots which filters out
        # sidecar-less slots, so the missing-slot error covers both
        # "never existed" and "exists on disk but no sidecar". Tell the
        # user about both possibilities so they can recover from a
        # stale-state scenario.
        throw "Slot '$safeName' not found (or missing its identity sidecar; re-save while active to recapture)."
    }

    # Perform the swap via the extracted pure-mechanism helper. Any
    # ~/.claude.json write failure is surfaced as an advisory by the
    # helper (yellow, not fatal) so the credentials swap is observable
    # even when the identity update fails.
    Invoke-SlotSwap -Slot $slot

    # DarkYellow header line; matches the `[List] Saved slots` /
    # `[Usage] Plan usage` convention so all three actions present a
    # consistent table-header look. No trailing period: this is a
    # header, not a complete sentence.
    $toIdent = Format-SlotIdentity -Name $slot.Name -Email $slot.Email
    Write-Color "[Switch] Switched to $toIdent" 'DarkYellow'

    # Render the saved-slot table beneath the success line so the user
    # sees the new active slot in context (the `*` marker now points at
    # the just-activated row). Re-enumerate via Get-Slots so IsActive
    # reflects the post-switch state. -SuppressHeader keeps the visual
    # weight low; the `[Switch]` line above is enough of a section
    # header.
    Write-Host ''
    Format-ListTable -Slots @(Get-Slots) -SuppressHeader
    Write-Host ''
}

function Invoke-ListAction {
    # Reconcile first so a cross-account swap that happened since the last
    # sca call surfaces in the marker column. state.active_slot only
    # changes through reconcile's identity-change branch (auto-save under
    # auto-<UTC>); same-identity drift mirrors bytes but leaves the
    # active slot unchanged, so the marker would be identical with or
    # without reconcile in that case. The reconcile is also what
    # bootstraps state on a fresh install (auto-migration via
    # Read-ScaState, then auto-save via Invoke-Reconcile if no slot
    # matched the active-credentials hash). Mirrors the prelude pattern
    # in Invoke-SwitchAction / Invoke-UsageAction.
    Invoke-Reconcile | Out-Null

    $slots = @(Get-Slots)

    if ($slots.Count -eq 0) {
        Write-Color "[List] No slots saved yet. Use: sca save <name>" 'Yellow'
        return
    }

    Format-ListTable -Slots $slots
}

function Invoke-RemoveAction {
    Param ([String] $Name)

    $safeName = Get-SafeName $Name

    # Lookup walks the raw filesystem rather than Get-Slots so the user
    # can clean up sidecar-less legacy slots that Get-Slots hides.
    # Without this, an invisible legacy slot would be impossible to
    # remove without manual filesystem editing.
    $rawFiles = @(Get-CredentialSlotFiles)
    $matching = @()
    foreach ($rf in $rawFiles) {
        $parsed = Get-SlotFileInfo -FileName $rf.Name
        if ($parsed -and $parsed.Name -eq $safeName) {
            $matching += $rf
        }
    }
    if ($matching.Count -eq 0) {
        throw "Slot '$safeName' not found."
    }

    # Refuse to remove the currently-active slot. Forces the user to
    # explicitly switch to another slot first, which is the natural
    # workflow and avoids leaving .credentials.json pointing at bytes
    # we just deleted from disk.
    $state = Read-ScaState
    if ($state -and $state.active_slot -eq $safeName) {
        throw "Cannot remove active slot '$safeName'. Run 'sca switch <other>' first, or delete .credentials.json manually if you want to drop tracking."
    }

    foreach ($rf in $matching) {
        Remove-Item -LiteralPath $rf.FullName -Force
        Remove-Sidecar -SlotPath $rf.FullName
    }
    Write-Color "[Remove] Removed '$safeName'" 'Red'
}

# --- usage action internals ---

# The usage body with every bucket whose window has already rolled removed.
#
# A bucket carries the utilization of a window that ENDS at resets_at, so once
# that instant passes the number says nothing about the window the account is
# in now. The endpoint never returns one (it reports the new window), but the
# per-process cache can: an entry served after a reset boundary holds a reading
# the world has moved past. $Script:UsageCacheMaxAgeMin bounds how far past,
# not whether.
#
# Removed rather than zeroed, because "the 5h window rolled" is the same fact
# as "this account made no call in the current window", which is exactly what
# an absent bucket already means to every consumer: the table renders an
# em-dash, Get-PlanStatus falls to its 'no plan data' tier, the bars and
# Get-RowMaxUtilization count 0. Zeroing would instead assert a measurement we
# do not have.
#
# This runs at New-UsageResult, the single construction site for every row, so
# the answer is computed once. Applying the rule per consumer is what let the
# Session cell print '100% now' beside a 0% aggregate bar, a '[!] 100%' title
# and a rotation engine that read the same row as idle.
#
# The input is never mutated: $Script:SlotUsageCache holds what the server
# actually said, and its own Timestamp is what ages it. PSObject.Copy() is a
# shallow clone, which is enough because only top-level bucket properties are
# replaced, never anything inside one.
function Select-LiveBuckets {
    Param (
        [AllowNull()] $Data,
        [Parameter(Mandatory)] [DateTimeOffset] $Now
    )

    if (-not $Data) { return $Data }

    $rolled = @(
        foreach ($key in @('five_hour', 'seven_day')) {
            $bucket = $Data.$key
            if (-not $bucket -or -not $bucket.resets_at) { continue }
            $reset = ConvertTo-DateTimeOffsetOrNull $bucket.resets_at
            if ($null -ne $reset -and $reset -le $Now) { $key }
        }
    )
    if ($rolled.Count -eq 0) { return $Data }

    # Select-Object -ExcludeProperty rather than assigning $null, so the
    # bucket is ABSENT from `sca usage -Json` rather than present-and-null.
    # A scripted consumer testing for the key then sees the same thing every
    # renderer sees.
    return ($Data | Select-Object -Property * -ExcludeProperty $rolled)
}

# The one shape every usage read returns, whatever happened. Get-SlotUsage,
# Get-CachedUsageOrNull and Get-UsageSnapshot all build through this, so a
# consumer can read any field on any result without an existence check and
# without knowing which of the ladder's arms produced it.
#
# Six fields, always present:
#   Status           'ok' | 'no-oauth' | 'expired' | 'rate-limited' |
#                    'unauthorized' | 'error'. Answers "may I switch INTO this
#                    slot", which is why Get-AutoRotationDecision gates peers
#                    on it.
#   Data             the parsed /api/oauth/usage body, or $null. Answers "are
#                    there numbers to show or judge", which is a different
#                    question: a non-ok row served from cache carries Data, and
#                    Test-RowHasUsableData is the predicate for that question.
#   Error            human-readable failure detail, or $null.
#   HttpStatus       numeric status when the failure carried one, else $null.
#   IsCachedFallback $true when Data came from $Script:SlotUsageCache.
#   FallbackReason   'rate-limit' | 'network' for a cached result, else $null.
#
# Four consumers used to re-derive "is this row trustworthy" from different
# subsets of those fields and disagreed with each other; the union of return
# shapes this replaces is what made that easy to do by accident.
#
# Data is projected through Select-LiveBuckets on the way in, which is what
# makes this the ONE place the "is this reading still current" question is
# answered. Every producer of a row builds here, so no renderer or decision
# path can disagree with another about a rolled window.
function New-UsageResult {
    Param (
        [Parameter(Mandatory)]
        [ValidateSet('ok', 'no-oauth', 'expired', 'rate-limited', 'unauthorized', 'error')]
        [String] $Status,
        [AllowNull()] $Data = $null,
        # Named ErrorMessage rather than Error: a parameter named $Error would
        # shadow PowerShell's automatic error variable inside this function.
        [AllowNull()] [AllowEmptyString()] [String] $ErrorMessage,
        [AllowNull()] $HttpStatus,
        [AllowNull()] [ValidateSet('rate-limit', 'network')] [String] $CachedReason,
        # Injected only by the tests; production always means "as of now",
        # because the row is consumed in the same tick it is built.
        [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow
    )

    return [pscustomobject]@{
        Status           = $Status
        Data             = Select-LiveBuckets -Data $Data -Now $Now
        Error            = if ([string]::IsNullOrEmpty($ErrorMessage)) { $null } else { $ErrorMessage }
        HttpStatus       = $HttpStatus
        IsCachedFallback = [bool]$CachedReason
        FallbackReason   = if ($CachedReason) { $CachedReason } else { $null }
    }
}

# True if $Exception came from an Invoke-RestMethod call that hit HTTP 429.
# Reads the status through Get-ExceptionHttpStatus so the two exception shapes
# our codebase encounters (a real HttpResponseException whose .Response
# .StatusCode is a System.Net.HttpStatusCode enum, and the pscustomobject
# Response shim the tests use, where it is already an integer) are handled in
# one place. Returns $false for null exceptions, exceptions without a Response
# member, and any non-429 status; the caller's catch block falls through to its
# pre-existing error handling for those.
function Test-Is429 {
    Param ($Exception)
    if (-not $Exception) { return $false }
    return ((Get-ExceptionHttpStatus $Exception) -eq 429)
}

# Collapse and tail-truncate an exception message so it renders on a single
# line. The whitespace collapse is the part every caller needs: some socket
# exceptions span multiple lines, which breaks any one-line layout.
#
# Bounding is the RENDERER's job: every display path funnels through here, so
# producers store the raw message and each renderer bounds at its own width.
# The default is the full-line width; Invoke-SaveAction narrows it because its
# reason sits parenthesised mid-sentence rather than owning a line.
function Format-StatusErrorTail {
    Param (
        [AllowNull()] [String] $Message,
        [int] $Max = $Script:AdvisoryReasonMaxWidth
    )
    if ([string]::IsNullOrEmpty($Message)) { return '' }
    $msg = ($Message -replace "\s+", ' ').Trim()
    if ($msg.Length -gt $Max) { $msg = $msg.Substring(0, $Max) + '...' }
    return $msg
}

# Read OAuth material from a slot file. Returns an object carrying the
# parsed token fields plus the raw parsed JSON so Update-SlotTokens can
# round-trip unknown fields (subscriptionType, rateLimitTier, scopes,
# clientId, ...) without losing them. HasOAuth is false for slots that
# are API-key-only or otherwise lack the claudeAiOauth section.
function Get-SlotOAuth {
    Param ([String] $SlotPath)

    $json = Get-Content -LiteralPath $SlotPath -Raw -ErrorAction Stop
    $obj  = $json | ConvertFrom-Json -ErrorAction Stop
    $oa   = $obj.claudeAiOauth

    if (-not $oa -or -not $oa.accessToken -or -not $oa.refreshToken) {
        return [pscustomobject]@{
            HasOAuth     = $false
            AccessToken  = $null
            RefreshToken = $null
            ExpiresAt    = $null
            RawObject    = $obj
        }
    }

    # expiresAt is a Unix epoch in MILLISECONDS (Claude Code convention;
    # the OAuth2 'expires_in' -> absolute ms conversion is how the CLI
    # persists it). Treat 0 / missing as "unknown, force a refresh".
    $expiresAt = $null
    if ($oa.expiresAt) {
        $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$oa.expiresAt).UtcDateTime
    }

    return [pscustomobject]@{
        HasOAuth     = $true
        AccessToken  = [string]$oa.accessToken
        RefreshToken = [string]$oa.refreshToken
        ExpiresAt    = $expiresAt
        RawObject    = $obj
    }
}

# Refresh the slot's OAuth tokens against platform.claude.com/v1/oauth/token,
# using the same request shape Claude Code itself sends (verified against
# claude.exe 2.1.119). Writes the new tokens via Set-CredentialFileAtomic
# (single write primitive shared with save / switch / state-file writes),
# then, if the slot being refreshed is the currently-tracked active slot,
# also writes the same bytes to .credentials.json so Claude Code's next
# call sees the new refresh_token.
#
# Returns the new access token on success; throws with a descriptive
# message on failure.
#
# Race with a running Claude Code: `sca usage` does NOT refuse while
# Claude Code is running (only `save` / `switch` do; see
# Test-ClaudeRunning callers), so an active-slot refresh triggered here
# can race against Claude Code's own refresh. Anthropic rotates the
# refresh_token on every successful /v1/oauth/token call: whichever
# party (sca or Claude Code) calls second presents the now-rotated old
# token and gets a 4xx, losing its session. We accept this as a
# deliberate trade-off: refusing `sca usage` while Claude Code runs
# would defeat the action's main use case (live monitoring during
# work). In practice the race is rare (the refresh window is a ~60s
# slice once per hour) and recoverable: if a refresh fails after this
# function rotated the token, the slot file holds the new tokens; rerun
# `sca switch <slot>` to repropagate them into .credentials.json. If
# Claude Code rotated first and our call here lost, the user re-logs
# into Claude Code and reruns `sca save <slot>` to recapture.
function Update-SlotTokens {
    Param ([String] $SlotPath)

    # Suppress PowerShell's built-in 'Web request' progress activity
    # (Write-Progress / stream 4: rotating status messages including
    # "Waiting for response..." and "Reading web response (NNN bytes)")
    # so it does not paint the host UI between `sca usage -Watch`
    # frames. The progress activity is host-managed and bypasses the
    # DEC 2026 byte-stream sync envelope around each frame, so without
    # this suppression it flashes in the alt buffer for the duration
    # of the HTTP call. Function-scoped: PowerShell's preference-
    # variable scope chain restores the parent value automatically on
    # function exit (no try/finally needed). Same suppression applied
    # identically in Get-SlotUsage and Get-SlotProfile (the other two
    # Invoke-RestMethod call sites in the script).
    $ProgressPreference = 'SilentlyContinue'

    $info = Get-SlotOAuth -SlotPath $SlotPath
    if (-not $info.HasOAuth) {
        throw "Slot '$SlotPath' has no OAuth material to refresh."
    }

    $body = @{
        grant_type    = 'refresh_token'
        refresh_token = $info.RefreshToken
        client_id     = $Script:OAuthClientId
    } | ConvertTo-Json -Compress

    $headers = @{
        'Content-Type'      = 'application/json'
        'anthropic-beta'    = $Script:AnthropicBeta
        'anthropic-version' = $Script:AnthropicApiVersion
        'User-Agent'        = $Script:UsageUserAgent
    }

    # 429 retry loop. The token endpoint's per-token rate limiter
    # unlocks within ~seconds, so a short exponential backoff
    # (2 s, 4 s) recovers a stuck slot inside one watch-loop tick
    # without surfacing a spurious 'rate-limited' status. Non-429
    # exceptions rethrow on the first failure (no point retrying a
    # 4xx with a malformed request or a 5xx with a server-side
    # problem). Tests override $Script:TokenRefreshRetryDelayMs to
    # zero so the mocked 429 paths complete instantly.
    $resp = $null
    for ($attempt = 1; $attempt -le $Script:TokenRefreshRetryMax; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Method Post `
                                      -Uri $Script:TokenEndpoint `
                                      -Headers $headers `
                                      -Body $body `
                                      -TimeoutSec $Script:TokenTimeoutSec `
                                      -ErrorAction Stop
            break
        }
        catch {
            $is429 = Test-Is429 $_.Exception
            if (-not $is429 -or $attempt -ge $Script:TokenRefreshRetryMax) {
                throw
            }
            # Exponential backoff: 2 s, 4 s, 8 s ... capped by RetryMax.
            $sleepMs = $Script:TokenRefreshRetryDelayMs * [Math]::Pow(2, $attempt - 1)
            Start-Sleep -Milliseconds ([int]$sleepMs)
        }
    }

    if (-not $resp.access_token) {
        throw "OAuth refresh succeeded but response missing access_token."
    }
    if (-not $resp.expires_in) {
        throw "OAuth refresh succeeded but response missing expires_in."
    }

    $newAccess  = [string]$resp.access_token
    # The OAuth2 refresh response MAY omit refresh_token; per RFC 6749 the
    # client should continue using the old one in that case. Matches
    # Claude Code's `w.refresh_token || z` fallback.
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $info.RefreshToken }
    $newExpMs   = [DateTimeOffset]::UtcNow.AddSeconds([double]$resp.expires_in).ToUnixTimeMilliseconds()

    # Mutate the parsed object in place, preserving any unknown fields
    # (scopes, subscriptionType, rateLimitTier, clientId, ...).
    $raw = $info.RawObject
    $raw.claudeAiOauth.accessToken  = $newAccess
    $raw.claudeAiOauth.refreshToken = $newRefresh
    $raw.claudeAiOauth.expiresAt    = $newExpMs

    $newJson  = $raw | ConvertTo-Json -Depth 10 -Compress
    $newBytes = [System.Text.Encoding]::UTF8.GetBytes($newJson)

    Set-CredentialFileAtomic -Path $SlotPath -Bytes $newBytes

    # Active-slot auto-sync: if this slot is currently tracked as active,
    # propagate the new tokens to .credentials.json so Claude Code's
    # next call uses the latest refresh_token. Without this propagation
    # the slot would silently drift ahead of .credentials.json after a
    # refresh, and Anthropic's refresh-token rotation could invalidate
    # the version Claude Code still holds. Belt-and-suspenders: also
    # update state.last_sync_hash so the next Invoke-Reconcile no-ops
    # rather than re-mirroring.
    $state = Read-ScaState
    if ($state -and $state.active_slot) {
        $activeSlot = Find-SlotByName -Name $state.active_slot
        if ($activeSlot -and $activeSlot.Path -eq $SlotPath) {
            try {
                Set-CredentialFileAtomic -Path $CredFile -Bytes $newBytes

                $newHash = Get-SHA256Hex -Bytes $newBytes
                Update-ScaState -LastSyncHash $newHash | Out-Null
            }
            catch {
                # Slot file holds the new tokens; .credentials.json still
                # has the old ones. The next Invoke-Reconcile will hash-
                # match-noop (state.last_sync_hash equals .credentials.json's
                # current bytes) so this gap does NOT auto-heal -- the
                # mirror direction is .credentials.json -> slot, never the
                # reverse. The user must re-propagate explicitly via
                # `sca switch <slot>` (which writes the slot's bytes back
                # into .credentials.json). Until they do, Anthropic may
                # have rotated the refresh_token we just consumed; Claude
                # Code reading the stale .credentials.json could fail its
                # own next refresh and require re-login.
                Write-Color "[Sync] Token refreshed in slot '$($state.active_slot)' but propagation to .credentials.json failed: $($_.Exception.Message). Run 'sca switch $($state.active_slot)' to propagate manually; otherwise Claude Code's own refresh may fail and require re-login." 'Yellow'
            }
        }
        elseif (-not $activeSlot) {
            # state.active_slot is set but Find-SlotByName returned $null,
            # so the tracked active slot has no valid sidecar and Get-Slots
            # filtered it out. If the slot we just refreshed IS that
            # sidecar-hidden active slot, the rotated tokens are now
            # orphaned in the slot file: .credentials.json still holds
            # the old refresh_token Anthropic just rotated away. Without
            # this branch the user gets no signal until Claude Code's own
            # next refresh fails and forces a re-login. The yellow
            # advisory in the catch above only covers the write-failure
            # path, not the "active slot was filtered out" path.
            #
            # Deliberate: do NOT auto-propagate. Sidecar absence is the
            # visibility-gate signal documented in AGENTS.md ("Slots
            # without a valid sidecar are HIDDEN from list / usage /
            # rotation"); silently writing to .credentials.json for a
            # hidden slot would violate the contract enforced by
            # Get-Slots. Escalate to the user instead.
            #
            # Invariant: state.active_slot and last_sync_hash stay as-is.
            # .credentials.json is unchanged, so its bytes still hash to
            # last_sync_hash and the next Invoke-Reconcile no-ops cleanly
            # (no spurious cross-account swap detection) until the user
            # runs `sca save <name>` (recapture sidecar) or `sca switch
            # <name>` (force propagation).
            $parsed = Get-SlotFileInfo -FileName ([System.IO.Path]::GetFileName($SlotPath))
            if ($parsed -and $parsed.Name -eq $state.active_slot) {
                Write-Color "[Sync] Token refreshed in slot '$($state.active_slot)' but its identity sidecar is missing, so propagation to .credentials.json was skipped. Run 'sca save $($state.active_slot)' to recapture the sidecar, or 'sca switch $($state.active_slot)' to force propagation now; otherwise Claude Code's own refresh may fail and require re-login." 'Yellow'
            }
        }
    }

    return $newAccess
}

# Look up the slot's last successful /api/oauth/usage response in the
# per-process cache and return it wrapped as an IsCachedFallback result.
# Returns $null on cache miss (or on a stale entry unless -AllowStale).
#
# Sole construction site for cache-fallback results; builds through
# New-UsageResult like every other producer.
#
# Freshness policy:
#   * Fresh entry (within $Script:UsageCacheTTL minutes) -> served as
#     'ok'+IsCachedFallback so the watch display stays fully functional
#     during a brief failure (usage data only changes every few hours).
#     'ok' is deliberate: aggregate bars and auto-rotation gate on it, and a
#     reading this recent is trustworthy enough for both.
#   * Stale entry -> $null by default. With -AllowStale the LAST-KNOWN
#     percentages stay visible (so the row keeps its numbers instead of
#     collapsing to em-dashes and looking like a dead slot) but the status
#     drops out of 'ok' so stale data is never mistaken for a live reading.
#   * Past $Script:UsageCacheMaxAgeMin -> $null even under -AllowStale. See
#     that constant for why an unbounded last-known reading is not a display
#     question.
#
# -Reason distinguishes WHY the live read failed. It picks the stale label
# ('rate-limited' for a 429, 'error' for a network/transport failure) and is
# stamped on the row so Format-UsageAdvisory can word the advisory
# accurately instead of calling every fallback a rate limit.
#
# -ErrorMessage / -HttpStatus are stamped on BOTH results. The fresh one keeps
# its 'ok' status, so the table and the bars are unaffected, but the reason the
# live read failed survives into Format-UsageAdvisory's per-slot line and the
# -Json row. Dropping it on the fresh path left the most common transient
# failure of all (a blip with a cache under $Script:UsageCacheTTL minutes old)
# reported as "showing last known usage" with nothing saying why.
function Get-CachedUsageOrNull {
    Param (
        [String] $SlotPath,
        [switch] $AllowStale,
        [ValidateSet('rate-limit', 'network')]
        [String] $Reason = 'rate-limit',
        [AllowNull()] [AllowEmptyString()] [String] $ErrorMessage,
        [AllowNull()] $HttpStatus
    )
    if (-not $Script:SlotUsageCache.ContainsKey($SlotPath)) { return $null }
    $entry   = $Script:SlotUsageCache[$SlotPath]
    $ageMin  = ([DateTime]::UtcNow - $entry.Timestamp).TotalMinutes
    if ($ageMin -ge $Script:UsageCacheMaxAgeMin) { return $null }

    $isStale = $ageMin -ge $Script:UsageCacheTTL
    if ($isStale) {
        if (-not $AllowStale) { return $null }
        $staleStatus = if ($Reason -eq 'network') { 'error' } else { 'rate-limited' }
        return New-UsageResult -Status $staleStatus -Data $entry.Data -CachedReason $Reason `
                               -ErrorMessage $ErrorMessage -HttpStatus $HttpStatus
    }
    return New-UsageResult -Status 'ok' -Data $entry.Data -CachedReason $Reason `
                           -ErrorMessage $ErrorMessage -HttpStatus $HttpStatus
}

# Shared resilience ladder for a failed /api/oauth/usage read. Both arms of
# Get-SlotUsage's catch need the same decision and differ only in -Reason:
#
#   1. Fresh cache -> serve it as 'ok', carrying the failure's message and
#                     status so the row can still say what went wrong.
#   2. Stale cache -> serve the last-known percentages under a non-ok label.
#                     No retry: a stale entry means we have been failing long
#                     enough that another attempt in the same poll will not
#                     change the outcome.
#   3. Nothing cached -> $null, which tells the caller to run its own
#                     retry-once path. The retry stays with the caller
#                     because its shape differs per arm (the 429 arm sleeps
#                     out the limiter window, the network arm does not).
function Resolve-UsageFailureFallback {
    Param (
        [Parameter(Mandatory)] [String] $SlotPath,
        [Parameter(Mandatory)] [ValidateSet('rate-limit', 'network')] [String] $Reason,
        [AllowNull()] [AllowEmptyString()] [String] $ErrorMessage,
        [AllowNull()] $HttpStatus
    )

    $fresh = Get-CachedUsageOrNull -SlotPath $SlotPath -Reason $Reason `
                                   -ErrorMessage $ErrorMessage -HttpStatus $HttpStatus
    if ($fresh) { return $fresh }

    return Get-CachedUsageOrNull -SlotPath $SlotPath -AllowStale -Reason $Reason `
                                 -ErrorMessage $ErrorMessage -HttpStatus $HttpStatus
}

# Mark a slot as throttled: stamp RateLimitedUntil on its cache entry so the
# next Get-SlotUsage short-circuits to the cache without token/usage HTTP
# (see $Script:SlotUsageCache). Existing entry only -- a slot with no prior
# successful read has no data to protect, so it keeps the legacy retry-once
# behaviour rather than getting a data-less marker that would complicate
# Get-CachedUsageOrNull's staleness math.
function Set-SlotRateLimitBackoff {
    Param ([Parameter(Mandatory)] [string] $SlotPath)
    if ($Script:SlotUsageCache.ContainsKey($SlotPath)) {
        $Script:SlotUsageCache[$SlotPath].RateLimitedUntil = [DateTime]::UtcNow.AddSeconds($Script:RateLimitBackoffSec)
    }
}

# Drop a slot's backoff stamp so the next Get-SlotUsage probes live again,
# keeping any cached Data intact. Called by Invoke-WarmAllSlots right before
# its post-activation verify read: a fresh `claude -p` is evidence the throttle
# may be over, and without this the verify read would be suppressed by the very
# backoff it is trying to recover from.
function Clear-SlotRateLimitBackoff {
    Param ([Parameter(Mandatory)] [string] $SlotPath)
    if ($Script:SlotUsageCache.ContainsKey($SlotPath)) {
        $Script:SlotUsageCache[$SlotPath].Remove('RateLimitedUntil')
    }
}

# Read a slot's OAuth tokens and return a non-expired access token,
# refreshing via /v1/oauth/token first if the cached token is past or
# within 60s of its expiry. Shared prelude for Get-SlotUsage and
# Get-SlotProfile. Warmup activation does not use it: `claude -p` does its
# own token refresh.
#
# Returns one of:
#   @{ Status = 'ok'; AccessToken = <string> }     # caller proceeds with HTTP
#   @{ Status = 'no-oauth' }                       # slot has no claudeAiOauth
#   @{ Status = 'rate-limited' }                   # 429 from /v1/oauth/token
#   @{ Status = 'expired'; Error; HttpStatus; Transport }  # refresh failed (non-429)
#   @{ Status = 'error';   Error = <msg> }         # Get-SlotOAuth threw (corrupt slot file etc.)
#
# This is the token-resolution shape, not New-UsageResult's row shape; callers
# translate. Get-SlotUsage additionally checks $Script:SlotUsageCache for a
# fresh entry before returning 'rate-limited' (the cache-fallback path); the
# other two callers have no cache and read Status / Error only.
#
# Does NOT set $ProgressPreference: Get-SlotOAuth performs no HTTP, and
# Update-SlotTokens sets it inside its own scope.
function Resolve-SlotAccessToken {
    Param ([String] $SlotPath)

    try {
        $info = Get-SlotOAuth -SlotPath $SlotPath
    }
    catch {
        return [pscustomobject]@{ Status = 'error'; Error = $_.Exception.Message }
    }

    if (-not $info.HasOAuth) {
        return [pscustomobject]@{ Status = 'no-oauth' }
    }

    $accessToken = $info.AccessToken

    # Refresh if expired OR within a 60s grace window; covers clock skew
    # and the case where the token technically has 30s left but would
    # expire mid-call.
    $threshold = [DateTime]::UtcNow.AddSeconds(60)
    if ($info.ExpiresAt -and $info.ExpiresAt -lt $threshold) {
        try {
            $accessToken = Update-SlotTokens -SlotPath $SlotPath
        }
        catch {
            # 429 from the token endpoint: surface a clean 'rate-limited'
            # status. No retry; the token endpoint shares an upstream
            # limiter with the usage endpoint, so a 5s sleep would just
            # extend the user's wait without changing the outcome.
            if (Test-Is429 $_.Exception) {
                return [pscustomobject]@{ Status = 'rate-limited' }
            }
            # Non-429 refresh failure (timeout, 4xx other than 429, 5xx,
            # malformed JSON, ...): the token IS expired and we couldn't
            # refresh it, so 'expired' remains the accurate label.
            #
            # Transport is decided HERE, where the exception still exists, and
            # carried as a verdict rather than re-derived from HttpStatus by the
            # caller. Update-SlotTokens also throws for a response missing
            # access_token or expires_in, and for a failed slot-file write after
            # the server already rotated the refresh token: all three arrive
            # with no HTTP status, so a caller reading "no status" as "transport
            # blip" served those dead slots from cache as a healthy 'ok'. The
            # last one is the worst, because the rotated token is gone from the
            # slot file for good.
            #
            # HttpStatus stays on the result for the table's 'error <code>' cell
            # and for the advisory.
            $ex = $_.Exception
            $status = Get-ExceptionHttpStatus $ex
            return [pscustomobject]@{
                Status     = 'expired'
                Error      = $ex.Message
                HttpStatus = $status
                Transport  = (Test-IsTransportFailure -HttpStatus $status -Exception $ex)
            }
        }
    }

    return [pscustomobject]@{ Status = 'ok'; AccessToken = $accessToken }
}

# Call /api/oauth/usage for one slot. Auto-refreshes a token that is expired or
# within 60s of expiry via Resolve-SlotAccessToken. Always returns
# New-UsageResult's single shape; never throws, so Invoke-UsageAction can
# render mixed-health tables without aborting.
#
# A failure that the slot can recover from never discards known-good data: both
# catch arms run the Resolve-UsageFailureFallback ladder, so a transport blip
# degrades the row to "last known percentages, labelled" instead of wiping it
# to em-dashes for a whole poll interval.
#
# A failure that describes the slot or the request does NOT reach the cache:
# a 4xx from either endpoint (invalid_grant, and the endpoint drift that a
# Claude Code upgrade can cause) means the reading we hold is not evidence the
# slot is fine, and serving it as 'ok' would hide the one failure only a live
# `sca usage` can catch. Test-IsTransportFailure draws that line once.
#
# Parse the RAW body shape documented at $Script:UsageEndpoint. Claude Code
# re-shapes it into { rate_limits: { five_hour: { used_percentage, resets_at } } }
# for its status-line hook; do NOT model that hook-input schema here, it is a
# downstream projection with different key names.
function Get-SlotUsage {
    Param (
        [String] $SlotPath
    )

    # Suppress PowerShell's built-in 'Web request' progress activity
    # (Write-Progress / stream 4) so it does not paint over the watch
    # loop's alt-screen buffer between frames. See Update-SlotTokens
    # for the full rationale; same suppression is applied identically
    # in Get-SlotProfile and Invoke-UsageRequest. Kept here as well as in
    # Invoke-UsageRequest so it also covers Resolve-SlotAccessToken below.
    $ProgressPreference = 'SilentlyContinue'

    # Backoff short-circuit: while a recent 429's RateLimitedUntil is still
    # in the future, serve last-known data with NO token/usage HTTP so a
    # sustained throttle stops re-tripping a hot limiter every poll. Status
    # stays 'rate-limited' (we are throttled, just not re-confirming) so the
    # keep-warm step can still recover the slot.
    $entry = $Script:SlotUsageCache[$SlotPath]
    if ($entry -and $entry.RateLimitedUntil -and [DateTime]::UtcNow -lt $entry.RateLimitedUntil) {
        # Same ceiling as Get-CachedUsageOrNull: the backoff suppresses HTTP for
        # $Script:RateLimitBackoffSec, but the entry it serves instead can be
        # arbitrarily older than that. Past the ceiling the short-circuit still
        # applies (the point is not to re-trip a hot limiter) but it stops
        # carrying numbers nobody should act on.
        $tooOld = ([DateTime]::UtcNow - $entry.Timestamp).TotalMinutes -ge $Script:UsageCacheMaxAgeMin
        $data   = if ($tooOld) { $null } else { $entry.Data }
        return New-UsageResult -Status 'rate-limited' -Data $data -CachedReason 'rate-limit'
    }

    # Resolve a non-expired access token (refresh if needed). A token-endpoint
    # failure that the slot can recover from gets the same cache-fallback
    # ladder as a usage-endpoint failure; a failure that says the grant itself
    # is dead returns verbatim.
    $tok = Resolve-SlotAccessToken -SlotPath $SlotPath
    if ($tok.Status -ne 'ok') {
        if ($tok.Status -eq 'rate-limited') {
            # Stamp the backoff so subsequent polls stop hammering the token
            # endpoint (the expired-idle-slot refresh storm).
            Set-SlotRateLimitBackoff -SlotPath $SlotPath
            # Fresh cache, else last-known percentages, rather than dropping
            # the row to a dead-looking em-dash line during a token-endpoint
            # throttle. No retry arm here: the token endpoint has its own
            # 429 retry loop inside Update-SlotTokens.
            $fallback = Resolve-UsageFailureFallback -SlotPath $SlotPath -Reason 'rate-limit'
            if ($fallback) { return $fallback }
        }
        elseif ($tok.Status -eq 'expired' -and $tok.Transport) {
            # The refresh POST died in transport, not on its merits. Its budget
            # is the largest of the three calls ($Script:TokenTimeoutSec), so
            # this is the likeliest place for a blip to land, and without the
            # ladder one slow hourly refresh wiped the row to em-dashes, printed
            # the 'run sca switch' remedy for something sca switch cannot fix,
            # and (in `sca monitor`) turned the active row into 'active-unknown',
            # pausing rotation until the next poll happened to succeed.
            #
            # The verdict comes from Resolve-SlotAccessToken, which had the
            # exception; see Test-IsTransportFailure for what it excludes.
            $fallback = Resolve-UsageFailureFallback -SlotPath $SlotPath -Reason 'network' `
                                                     -ErrorMessage $tok.Error -HttpStatus $tok.HttpStatus
            if ($fallback) { return $fallback }
        }
        # Token-shaped result, so it is translated rather than returned: the
        # row shape is New-UsageResult's and carries no AccessToken field.
        return New-UsageResult -Status $tok.Status -ErrorMessage $tok.Error -HttpStatus $tok.HttpStatus
    }
    $accessToken = $tok.AccessToken

    $headers = @{
        'Authorization'     = "Bearer $accessToken"
        'anthropic-beta'    = $Script:AnthropicBeta
        'anthropic-version' = $Script:AnthropicApiVersion
        'Content-Type'      = 'application/json'
        'User-Agent'        = $Script:UsageUserAgent
    }

    try {
        return Invoke-UsageRequest -SlotPath $SlotPath -Headers $headers
    }
    catch {
        $ex      = $_.Exception
        $status  = Get-ExceptionHttpStatus $ex
        $message = $ex.Message

        if ($status -eq 401 -or $status -eq 403) {
            # No message: Format-UsageAdvisory prints the per-status remedy for
            # a row that carries none, and "re-authenticate this account" is
            # more use than the raw 401 sentence.
            return New-UsageResult -Status 'unauthorized'
        }

        # Both arms below run the same Resolve-UsageFailureFallback ladder
        # (fresh cache -> stale-with-numbers -> $null meaning "nothing cached,
        # retry once"). They differ in the reason they report, in whether the
        # retry sleeps first, and in how a doomed retry is labelled.
        if ($status -eq 429) {
            # Stamp the backoff (no-op without a prior entry; see
            # Set-SlotRateLimitBackoff) so subsequent polls stop re-tripping a
            # hot limiter.
            Set-SlotRateLimitBackoff -SlotPath $SlotPath
            $fallback = Resolve-UsageFailureFallback -SlotPath $SlotPath -Reason 'rate-limit'
            if ($fallback) { return $fallback }
            # Nothing cached: retry once after sleeping out the limiter window,
            # so back-to-back slot polls don't all fail together on the first
            # pass after startup.
            Start-Sleep -Seconds 5
            try   { return Invoke-UsageRequest -SlotPath $SlotPath -Headers $headers }
            catch { return New-UsageResult -Status 'rate-limited' }
        }

        # Transport failure (no status, or a 5xx). Deliberately does NOT call
        # Set-SlotRateLimitBackoff: a timeout is not a throttle, and stamping
        # RateLimitedUntil here would make the next poll short-circuit to
        # 'rate-limited' for $Script:RateLimitBackoffSec and stop probing live
        # for a fault that may already be gone.
        #
        # Gated, unlike before: any other 4xx (the endpoint drift a Claude Code
        # upgrade can cause) used to reach the cache and paint fresh-looking
        # numbers under an 'ok' status for the whole TTL, which is the one
        # failure the unofficial-constants comment says only a live read can
        # catch.
        if (Test-IsTransportFailure -HttpStatus $status -Exception $ex) {
            $fallback = Resolve-UsageFailureFallback -SlotPath $SlotPath -Reason 'network' `
                                                    -ErrorMessage $message -HttpStatus $status
            if ($fallback) { return $fallback }
        }

        # Nothing cached, which is the state of every slot on the first poll of
        # a watch, so this arm sets that poll's wall clock. Retry only when a
        # second immediate attempt can plausibly answer differently; no sleep,
        # because the first attempt already waited.
        if (Test-IsRetriableUsageFailure -Exception $ex -HttpStatus $status) {
            try {
                return Invoke-UsageRequest -SlotPath $SlotPath -Headers $headers
            }
            catch {
                return New-UsageResult -Status 'error' `
                                       -HttpStatus (Get-ExceptionHttpStatus $_.Exception) `
                                       -ErrorMessage $_.Exception.Message
            }
        }

        return New-UsageResult -Status 'error' -HttpStatus $status -ErrorMessage $message
    }
}

# True when a failed /api/oauth/usage read is worth one more immediate attempt.
#
# The retry is not free: it doubles the slot's contribution to the poll's wall
# clock, and Get-UsageSnapshot walks slots serially, so an indiscriminate retry
# turns one unreachable endpoint into minutes of frozen watch frame before the
# first paint. Retry therefore has to earn its cost per failure class.
#
#   timeout    -> no. It has already burned the full $Script:UsageTimeoutSec,
#                 so it is both the most expensive class to repeat and the
#                 least likely to differ. Detected by exception type
#                 (-TimeoutSec surfaces as TaskCanceledException, verified on
#                 PowerShell 7.4) rather than by matching the message, which
#                 is localized.
#   no status  -> yes. A DNS or socket failure fails fast, so a second attempt
#                 costs almost nothing and does clear transient blips.
#   5xx        -> yes. Anthropic answers 529 Overloaded under load and it
#                 clears in seconds; this is the case the retry exists for.
#   other 4xx  -> no. 401 / 403 / 429 are handled by their own arms above; the
#                 rest describe the request, and the server will reject it
#                 identically the second time.
function Test-IsRetriableUsageFailure {
    Param (
        [Parameter(Mandatory)] $Exception,
        [AllowNull()] $HttpStatus
    )

    if ($Exception -is [System.OperationCanceledException]) { return $false }
    return (Test-IsTransportFailure -HttpStatus $HttpStatus -Exception $Exception)
}

# True when a failed HTTP call says nothing about the request's merits: no
# status at all (DNS, socket, the -TimeoutSec TaskCanceledException) or a 5xx.
#
# The distinction this draws is "retry / cached data may still be valid" versus
# "the server rejected this request, or never made it, and the slot is not
# fine": a 4xx describes the credential or the call, so neither a second
# attempt nor a stale reading is defensible. Shared by every gate that has to
# make that call so they cannot drift apart.
#
# -Exception is mandatory because a missing status alone does not mean
# "transport". Update-SlotTokens throws plain PowerShell errors for a malformed
# refresh response and for a failed credential write, and those carry no status
# either; reading their absence as a blip served a dead slot from cache as
# 'ok'. Only an exception the HTTP stack itself raised earns that reading:
# HttpRequestException (which Microsoft.PowerShell.Commands.HttpResponseException
# derives from) or the OperationCanceledException a -TimeoutSec cancellation
# surfaces as.
function Test-IsTransportFailure {
    Param (
        [AllowNull()] $HttpStatus,
        [Parameter(Mandatory)] $Exception
    )

    if ($null -ne $HttpStatus) { return ([int]$HttpStatus -ge 500) }

    return ($Exception -is [System.Net.Http.HttpRequestException] -or
            $Exception -is [System.OperationCanceledException]    -or
            $Exception -is [System.Net.WebException])
}

# One live GET against /api/oauth/usage: caches the body on success and returns
# it wrapped as an 'ok' result. Throws on any failure so the caller's catch owns
# the classification. Extracted because Get-SlotUsage makes this exact call in
# three places (primary, 429 retry, network retry) and the cache write must not
# drift between them.
function Invoke-UsageRequest {
    Param (
        [Parameter(Mandatory)] [String]    $SlotPath,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    # See Get-SlotUsage for the rationale; the suppression has to live in the
    # function that actually calls Invoke-RestMethod.
    $ProgressPreference = 'SilentlyContinue'

    $resp = Invoke-RestMethod -Method Get `
                              -Uri $Script:UsageEndpoint `
                              -Headers $Headers `
                              -TimeoutSec $Script:UsageTimeoutSec `
                              -ErrorAction Stop

    $Script:SlotUsageCache[$SlotPath] = @{
        Data      = $resp
        Timestamp = [DateTime]::UtcNow
    }
    return New-UsageResult -Status 'ok' -Data $resp
}

# Numeric HTTP status carried by a web exception, or $null when it has none.
# $null is the normal case for a codeless transport failure (DNS, socket, and
# the -TimeoutSec TaskCanceledException). Two consumers turn on that
# distinction: Format-UsageTable renders 'error <code>' when a status is
# present and a bare 'error' when it is not, and Test-IsTransportFailure reads
# it to decide whether a retry or a cached reading is defensible.
function Get-ExceptionHttpStatus {
    Param ($Exception)

    $resp = $Exception.Response
    if ($resp -and $resp.StatusCode) { return [int]$resp.StatusCode }
    return $null
}

# Resolve the OAuth account email for a slot. Returns one of:
#   @{ Status = 'ok';           Email = <string> }
#   @{ Status = 'no-oauth' }                        # slot has no claudeAiOauth
#   @{ Status = 'expired' }                         # token expired + refresh failed (non-429)
#   @{ Status = 'rate-limited' }                    # 429 from refresh endpoint OR profile endpoint
#   @{ Status = 'unauthorized' }                    # 401/403 from profile endpoint
#   @{ Status = 'error';        Error = <msg> }     # network / shape / other
#
# No caching: email is authoritative only at `sca save` time, which writes
# it directly into the slot filename. Subsequent `sca usage` / `sca list`
# reads parse the filename via Get-SlotFileInfo. No HTTP. This keeps the
# email self-consistent with the stored OAuth tokens: the only way to
# update the email on a slot is to re-run `sca save`, which also re-runs
# this call against the freshly-saved tokens.
#
# The HTTP call mirrors Claude Code's Ql() shape: Authorization +
# Content-Type, no anthropic-beta / User-Agent. The single deliberate
# deviation is the `anthropic-version` header, which Ql() omits but
# which we send on every authenticated request for defense-in-depth (see
# the $Script:AnthropicApiVersion docstring up top). The OAuth-namespaced
# endpoints accept the call with or without it today; sending it
# uniformly insulates the script from a future tightening at this
# endpoint without an emergency patch.
function Get-SlotProfile {
    Param (
        [String] $SlotPath
    )

    # See Get-SlotUsage for the $ProgressPreference rationale; same
    # suppression here for the /api/oauth/profile HTTP call below.
    $ProgressPreference = 'SilentlyContinue'

    # Resolve a non-expired access token; non-ok statuses (including
    # 429-as-rate-limited from the token endpoint) return verbatim. No
    # profile cache to fall back on (Get-SlotProfile is no-cache by
    # design; see the function docstring above).
    $tok = Resolve-SlotAccessToken -SlotPath $SlotPath
    if ($tok.Status -ne 'ok') { return $tok }
    $accessToken = $tok.AccessToken

    $headers = @{
        'Authorization'     = "Bearer $accessToken"
        'anthropic-version' = $Script:AnthropicApiVersion
        'Content-Type'      = 'application/json'
    }

    try {
        $resp = Invoke-RestMethod -Method Get `
                                  -Uri $Script:ProfileEndpoint `
                                  -Headers $headers `
                                  -TimeoutSec $Script:ProfileTimeoutSec `
                                  -ErrorAction Stop
    }
    catch {
        $status = $null
        $r      = $_.Exception.Response
        if ($r -and $r.StatusCode) { $status = [int]$r.StatusCode }
        if ($status -eq 401 -or $status -eq 403) {
            return [pscustomobject]@{ Status = 'unauthorized' }
        }
        if ($status -eq 429) {
            return [pscustomobject]@{ Status = 'rate-limited' }
        }
        return [pscustomobject]@{ Status = 'error'; Error = $_.Exception.Message }
    }

    $email = $null
    if ($resp -and $resp.account -and $resp.account.email) {
        $email = [string]$resp.account.email
    }
    if (-not $email) {
        return [pscustomobject]@{ Status = 'error'; Error = 'profile response missing account.email' }
    }

    return [pscustomobject]@{ Status = 'ok'; Email = $email }
}

# Run the Claude Code CLI (`claude`) as a child process and return its raw
# result so Invoke-SlotActivator can classify it. Extracted as the single
# mockable seam for the activator: tests stub THIS to feed synthetic exit
# codes / stdout / stderr without spawning a real `claude`, while the
# parsing/classification logic in Invoke-SlotActivator is exercised
# directly. A missing binary, a timeout, and a non-zero exit are all
# reported through the returned object.
#
# Returns: @{ TimedOut = <bool>; ExitCode = <int|null>; Stdout = <string>;
#             Stderr = <string> }. A null ExitCode means the binary was not
# found (Stderr = 'claude-not-found') or the call timed out (TimedOut).
function Invoke-ClaudeActivatorProcess {
    Param (
        [string[]] $ClaudeArgs,
        [int]      $TimeoutSec = 90
    )

    $claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue
    if (-not $claude) {
        return [pscustomobject]@{ TimedOut = $false; ExitCode = $null; Stdout = ''; Stderr = 'claude-not-found' }
    }

    # Redirect stdout/stderr to temp files so claude's output never paints
    # over the watch alt-buffer, and so the JSON envelope (stdout) stays
    # uncorrupted by any stderr noise. -NoNewWindow keeps it inline with
    # the current console; WaitForExit(ms) bounds a hung model load.
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $claude.Source -ArgumentList $ClaudeArgs -NoNewWindow -PassThru `
                           -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { Write-Verbose "Activator kill after timeout failed: $_" }
            return [pscustomobject]@{ TimedOut = $true; ExitCode = $null; Stdout = ''; Stderr = '' }
        }
        $stdout = [System.IO.File]::ReadAllText($outFile)
        $stderr = [System.IO.File]::ReadAllText($errFile)
        return [pscustomobject]@{ TimedOut = $false; ExitCode = $p.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

# Activate a slot by running the real Claude Code CLI as that slot, exactly
# as a user typing one message would: `claude -p "Hi"` opens Anthropic's
# server-side 5h session window so subsequent /api/oauth/usage calls return
# real bucket data. The slot must already be active (Invoke-SlotSwap wrote
# its tokens into .credentials.json); claude reads those, refreshes them
# through its own canonical OAuth flow if needed, and makes the billable
# request. Used by Invoke-WarmAllSlots.
#
# Returns the same status vocabulary as Get-SlotUsage so the warmup
# orchestrator can copy the result onto the row without translation:
#   @{ Status = 'ok' }                     # claude returned a successful result
#   @{ Status = 'no-oauth' }               # slot has no claudeAiOauth (skip claude)
#   @{ Status = 'rate-limited'; Error = <msg> } # claude reported a rate limit or a plan limit
#   @{ Status = 'unauthorized' }           # claude reported an auth/permission failure
#   @{ Status = 'expired'; Error = <msg> } # claude reported the login expired / needs re-auth
#   @{ Status = 'error'; Error = <msg> }   # binary missing, timeout, or other failure
#
# Failure classification is best-effort: claude's success envelope is well
# defined ({type:'result', is_error:false}), but its failure surface (exit
# code + stderr vs a JSON error) is not contractually stable, so the
# non-ok arms scan the message text. Returns an object for every
# documented outcome.
function Invoke-SlotActivator {
    Param (
        [String] $SlotPath
    )

    # Cheap pre-check: a slot with no OAuth material (e.g. an API-key-only
    # file) can never open a subscription session window, so skip the
    # billable claude call entirely and surface 'no-oauth' like the old
    # prime did. claude reads .credentials.json (the swapped-in active
    # slot), which equals this slot's bytes by construction.
    $oauth = Get-SlotOAuth -SlotPath $SlotPath
    if (-not $oauth.HasOAuth) {
        return [pscustomobject]@{ Status = 'no-oauth' }
    }

    $claudeArgs = @(
        '-p', $Script:ActivatorPrompt,
        '--safe-mode',
        '--model', $Script:ActivatorModel,
        '--output-format', 'json',
        '--no-session-persistence'
    )

    $proc = Invoke-ClaudeActivatorProcess -ClaudeArgs $claudeArgs -TimeoutSec $Script:ActivatorTimeoutSec

    if ($proc.Stderr -eq 'claude-not-found') {
        return [pscustomobject]@{ Status = 'error'; Error = "claude CLI not found on PATH; warmup activation requires Claude Code installed." }
    }
    if ($proc.TimedOut) {
        return [pscustomobject]@{ Status = 'error'; Error = "claude -p timed out after $($Script:ActivatorTimeoutSec)s." }
    }

    $parsed = $null
    if ($proc.Stdout) {
        try { $parsed = $proc.Stdout | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    }

    if ($proc.ExitCode -eq 0 -and $parsed -and $parsed.type -eq 'result' -and -not $parsed.is_error) {
        return [pscustomobject]@{ Status = 'ok' }
    }

    # Non-ok: build a probe string from the richest message available, then
    # classify. Prefer claude's JSON error text, fall back to stderr.
    $msg = $null
    if ($parsed) {
        if    ($parsed.result)  { $msg = [string]$parsed.result }
        elseif ($parsed.error)  { $msg = [string]$parsed.error }
        elseif ($parsed.subtype){ $msg = [string]$parsed.subtype }
    }
    if (-not $msg) { $msg = [string]$proc.Stderr }
    if (-not $msg) { $msg = "claude -p exited with code $($proc.ExitCode)" }

    # 'hit your <bucket> limit' / '<bucket> limit reached' are Claude Code's
    # own plan-limit sentences, e.g. "You've hit your session limit · resets
    # 6:10pm (Europe/Berlin)" from claude.exe 2.1.119. They never contain the
    # words 'rate limit' or '429', so without them a plainly limited slot fell
    # into the default arm and rendered as a hard 'error'.
    #
    # Anchored to the known bucket words rather than a bare 'limit reached':
    # claude says 'limit' for context-window and tool-output failures too, and
    # a row misfiled as throttled is silently re-probed instead of reported.
    $planLimit = 'hit your (?:session|week(?:ly)?|opus|usage) limit|(?:session|week(?:ly)?|opus|usage) limit reached'
    $probe = "$msg $($proc.Stderr)"
    switch -Regex ($probe) {
        "(?i)rate.?limit|\b429\b|$planLimit"                        { return [pscustomobject]@{ Status = 'rate-limited'; Error = $msg } }
        '(?i)\b401\b|\b403\b|unauthor|forbidden|permission'         { return [pscustomobject]@{ Status = 'unauthorized' } }
        '(?i)expired|invalid.?grant|re-?auth|\blog ?in\b|\blogin\b' { return [pscustomobject]@{ Status = 'expired'; Error = $msg } }
        default                                                     { return [pscustomobject]@{ Status = 'error'; Error = $msg } }
    }
}

# Coerce a reset-timestamp value (ISO-8601 string, DateTime, DateTimeOffset,
# or null/empty) to a [DateTimeOffset], or $null on missing / unparseable
# input. Centralizes the parser shared by Format-ResetDelta /
# Format-ResetAbsolute so both renderers cannot drift on accepted input
# shapes. ISO-8601 strings come from live /api/oauth/usage; DateTime /
# DateTimeOffset values come from tests passing pre-parsed timestamps.
function ConvertTo-DateTimeOffsetOrNull {
    Param ($Value)

    if ($null -eq $Value -or $Value -eq '') { return $null }
    try {
        if ($Value -is [DateTimeOffset]) { return $Value }
        if ($Value -is [DateTime])       { return [DateTimeOffset]$Value }
        return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    }
    catch {
        return $null
    }
}

# Render an ISO-8601 reset timestamp as a compact relative delta for the
# summary table column. Verified shape from live /api/oauth/usage:
#   "resets_at": "2026-04-24T19:50:00.027299+02:00"  (ISO with tz offset)
#                 OR null (no active window yet; pairs with 0% utilization)
# Output (variant C: hours+minutes under 24h, integer hours above):
#   null / empty / parse fail        -> '—' (defensive: never throws)
#   timestamp in the past            -> 'now'
#   < 1 hour                         -> 'in 42m'
#   >= 1 hour and < 24 hours         -> '(2h 14m)'    (minute precision matters in the session window)
#   >= 24 hours                      -> '(42h)'       (integer total hours; minutes are noise at weekly scale)
function Format-ResetDelta {
    Param ($ResetsAt)

    $target = ConvertTo-DateTimeOffsetOrNull $ResetsAt
    if ($null -eq $target) { return '—' }

    $delta = $target - [DateTimeOffset]::UtcNow
    if ($delta.TotalSeconds -le 0) { return 'now' }

    if ($delta.TotalHours -ge 24) {
        # Total hours, floor; at this scale minutes would only add noise.
        $h = [int][math]::Floor($delta.TotalHours)
        return "(${h}h)"
    }

    $h = [int]$delta.Hours
    $m = [int]$delta.Minutes
    if ($h -gt 0) { return "(${h}h ${m}m)" }
    return "(${m}m)"
}

# Render an ISO-8601 reset timestamp as an absolute wall-clock time in the
# user's local timezone, mirroring Claude Code's own /usage rendering:
#   same calendar day    -> 'Resets 7:50pm Europe/Berlin'
#   different day        -> 'Resets Apr 26, 9am Europe/Berlin'
#   null / parse failure -> '—'
# The endpoint emits its own tz offset in the ISO string; we convert to
# the shell's local tz for display so "7:50pm" matches the user's watch.
function Format-ResetAbsolute {
    Param ($ResetsAt)

    $target = ConvertTo-DateTimeOffsetOrNull $ResetsAt
    if ($null -eq $target) { return '—' }

    $localTz   = [TimeZoneInfo]::Local
    $localTime = [TimeZoneInfo]::ConvertTime($target, $localTz).DateTime
    $now       = [DateTime]::Now

    # .NET's "h:mmtt" renders "7:50PM"; Claude Code uses lowercase am/pm.
    $timePart = $localTime.ToString('h:mmtt', [Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()

    if ($localTime.Date -eq $now.Date) {
        return "Resets $timePart $($localTz.Id)"
    }
    $datePart = $localTime.ToString('MMM d', [Globalization.CultureInfo]::InvariantCulture)
    # Second form also drops the ":00" for on-the-hour times like "9am" to
    # match the screenshot; keep ":mm" otherwise for unambiguous precision.
    if ($localTime.Minute -eq 0) {
        $timePart = $localTime.ToString('htt', [Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()
    }
    return "Resets $datePart, $timePart $($localTz.Id)"
}

# Render one utilization value (0..100 number or $null) as a fixed-width
# 4-char cell that aligns whether the value is numeric (' 34%') or the
# em-dash no-data sentinel ('   —'). Em-dash is a single visible char in
# monospace fonts, so right-pad with 3 spaces to match ' 34%'.
function Format-UtilCell {
    Param ($Utilization)

    if ($null -eq $Utilization) { return '   —' }
    return '{0,3}%' -f [int][math]::Round([double]$Utilization)
}

# Middle-truncate a string to at most $Max characters using '…' (U+2026)
# in the middle. A single ellipsis is one visible cell in monospace, so
# the truncated form is exactly $Max cells wide. Returns the input
# unchanged when it already fits, or '—' for null/empty (the caller
# decides whether that means "no email" or "truncate").
function Format-Truncate {
    Param (
        [AllowNull()] [String] $Text,
        [int] $Max
    )

    if ([string]::IsNullOrEmpty($Text)) { return '—' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 1) { return '…' }

    # Keep more of the tail than the head so the domain (after the '@')
    # stays visible for emails; the domain is the disambiguating part
    # when multiple slots share a local-part. For $Max = 32 this gives
    # 15 leading + '…' + 16 trailing = 32 cells.
    $headLen = [math]::Max(1, [int][math]::Floor(($Max - 1) / 2))
    $tailLen = $Max - 1 - $headLen
    return $Text.Substring(0, $headLen) + '…' + $Text.Substring($Text.Length - $tailLen, $tailLen)
}

# Render the Account column cell for a single row. '—' when the slot has
# no labeled email or when the email is a redundant duplicate of the
# slot name (case-insensitive); otherwise the middle-truncated email.
function Format-AccountCell {
    Param (
        [AllowNull()] [String] $SlotName,
        [AllowNull()] [String] $Email
    )

    if ([string]::IsNullOrEmpty($Email)) { return '—' }
    if ($SlotName -and $SlotName.ToLowerInvariant() -eq $Email.ToLowerInvariant()) { return '—' }
    return Format-Truncate -Text $Email -Max $Script:AccountColumnMaxWidth
}

# Render a slot identity for inline prose (the `switch` action's status
# messages). Renders as `'<slot>'` for unlabeled / dedup-form slots and
# `'<slot>' (<email>)` for labeled slots whose email differs from the
# slot name. Single source of truth so the rotation banner and the
# success line carry the same shape, and so future callers can render
# slot identities consistently without rebuilding the dedup logic.
function Format-SlotIdentity {
    Param (
        [AllowNull()] [String] $Name,
        [AllowNull()] [String] $Email
    )

    if ([string]::IsNullOrEmpty($Email)) { return "'$Name'" }
    if ($Name -and $Name.ToLowerInvariant() -eq $Email.ToLowerInvariant()) { return "'$Name'" }
    return "'$Name' ($Email)"
}

# Merge a utilization value and its reset timestamp into a single cell
# for the summary table. Layout rules:
#   null utilization, any reset     -> '   —'                (no data at all)
#   numeric utilization, null reset -> ' 34%'                (cold bucket, no active window)
#   numeric utilization, reset      -> ' 34% (2h 14m)'     (normal row)
# Width is variable because reset deltas range from 'now' (3 chars) to
# '(103h)' (6 chars) to '(2h 14m)' (8 chars); the table's column
# width is computed from the widest cell per invocation.
function Format-BucketCell {
    Param (
        $Utilization,
        $ResetsAt
    )

    if ($null -eq $Utilization) { return '   —' }
    $pct = Format-UtilCell $Utilization
    if ($null -eq $ResetsAt -or $ResetsAt -eq '') { return $pct }
    return "$pct $(Format-ResetDelta $ResetsAt)"
}

# Classify a slot's usage response into a plan-usability status. Returns
# one of:
#   ok                 - both buckets below the warn threshold
#   near limit         - any bucket at or above UtilWarnPct but all below UtilLimitPct
#   limited 5h         - 5h bucket at or above UtilLimitPct (prompts refused until 5h reset)
#   limited 7d         - 7d bucket at or above UtilLimitPct
#   limited            - both buckets at or above UtilLimitPct
#   ok (no plan data)  - HTTP ok but response had neither bucket
# HTTP-failure states (expired / unauthorized / error / no-oauth) are
# surfaced via the caller's own mapping; this helper only runs when the
# caller has already determined HTTP was 'ok'.
function Get-PlanStatus {
    Param ($Data)

    $fiveUtil  = $null
    $sevenUtil = $null
    if ($Data) {
        if ($Data.five_hour -and $null -ne $Data.five_hour.utilization) {
            $fiveUtil = [double]$Data.five_hour.utilization
        }
        if ($Data.seven_day -and $null -ne $Data.seven_day.utilization) {
            $sevenUtil = [double]$Data.seven_day.utilization
        }
    }

    if ($null -eq $fiveUtil -and $null -eq $sevenUtil) {
        return 'ok (no plan data)'
    }

    $fiveLimit  = ($null -ne $fiveUtil  -and $fiveUtil  -ge $Script:UtilLimitPct)
    $sevenLimit = ($null -ne $sevenUtil -and $sevenUtil -ge $Script:UtilLimitPct)
    if ($fiveLimit -and $sevenLimit) { return 'limited' }
    if ($fiveLimit)                  { return 'limited 5h' }
    if ($sevenLimit)                 { return 'limited 7d' }

    $fiveNear  = ($null -ne $fiveUtil  -and $fiveUtil  -ge $Script:UtilWarnPct)
    $sevenNear = ($null -ne $sevenUtil -and $sevenUtil -ge $Script:UtilWarnPct)
    if ($fiveNear -or $sevenNear) { return 'near limit' }

    return 'ok'
}

# Return the Write-Host color for a given rendered status label, mixing
# HTTP-health and plan-usability outcomes. Centralized so the summary
# table and the verbose view stay in lockstep.
function Get-StatusColor {
    Param (
        [String] $Label,
        [bool]   $IsActive
    )

    $okColor = if ($IsActive) { 'Green' } else { 'Gray' }
    switch -Regex ($Label) {
        '^limited'      { return 'Red' }
        '^near limit'   { return 'Yellow' }
        '^ok \(no plan' { return $okColor }
        '^ok$'          { return $okColor }
        '^no-oauth'     { return 'DarkGray' }
        '^expired'      { return 'Yellow' }
        '^unauthorized' { return 'Red' }
        '^error'        { return 'Red' }
        '^rate-limited' { return 'Yellow' }
        # 'warming up' is the transient monitor -KeepWarm queued state
        # (slot not yet processed). Yellow matches its "attention
        # required" cousins (near limit, rate-limited, expired) so
        # the user immediately knows the row is in flight, not in
        # steady state.
        '^warming up'    { return 'Yellow' }
        # 'priming' is the per-slot in-flight state during the warmup
        # pass: Invoke-SlotActivator's `claude -p` call is running for
        # this row right now. Once the call completes, the row
        # transitions directly to a real status ('ok' / 'rate-limited' /
        # 'no-oauth' / 'expired' / 'unauthorized' / 'error'), which are
        # already mapped above.
        '^priming$'      { return 'Yellow' }
        default          { return 'Gray' }
    }
}

# One-sentence English rationale for a status. Keyed on both the
# plan-usability labels (from the verbose `sca usage <slot>` view) and the
# raw hard-failure Status values (from Format-UsageAdvisory's per-slot
# lines). Returns $null when no rationale applies, either because the label
# is self-explanatory ('ok') or because the row carries a real error message
# to print instead ('error', 'rate-limited').
function Get-StatusRationale {
    Param ([String] $Label)

    switch ($Label) {
        'limited 5h'        { return 'no prompts until 5h window resets' }
        'limited 7d'        { return 'no prompts until 7d window resets' }
        'limited'           { return 'no prompts until both 5h and 7d windows reset' }
        'near limit'        { return "at or above $($Script:UtilWarnPct)% on at least one bucket" }
        'ok (no plan data)' { return 'HTTP ok but response carried no bucket data' }
        'expired'           { return 'token refresh failed; run sca switch to refresh' }
        'unauthorized'      { return 'token revoked; run sca switch then /login' }
        'no-oauth'          { return 'api key or non-claude.ai slot' }
        default             { return $null }
    }
}

# Map a pool-wide USAGE percentage (0..100) to the Write-Host color used
# by the aggregate bars. Extracted as a pure helper rather than inlined
# so it can be unit-tested without mocking Write-Host (whose parameter
# capture across Pester scope boundaries is fragile).
function Get-AggregateBarColor {
    Param ([int] $UsedPct)

    if ($UsedPct -ge $Script:AggregateRedPct)    { return 'Red'    }
    if ($UsedPct -ge $Script:AggregateYellowPct) { return 'Yellow' }
    return 'Green'
}

# Compute the pool-mean utilization for a single bucket key across the
# HTTP-ok rows of a usage-snapshot Results list. Pure function. Used by
# both Format-AggregateBars (renders the bar above the table) and
# Format-WatchTitle's -Aggregate branch (renders the OSC 0 title in
# monitor mode); colocating the math here keeps the title number
# and the on-screen bar percentage structurally in lockstep instead of
# coupled by copy-paste.
#
# Inputs:
#   * $Results   - raw Results array from Get-UsageSnapshot (mixed
#                  Status values). Internal filter keeps callers from
#                  having to pre-filter; both call sites pass the raw
#                  list.
#   * $BucketKey - 'five_hour' or 'seven_day'.
#
# Return:
#   * Integer in [0, 100], rounded with [math]::Round, when at least one
#     eligible row exists. Math: sum of per-row utilization (each clamped
#     to [0,100]; null or missing counted as 0, which by Select-LiveBuckets
#     also covers a window that has rolled) divided by cap = N*100, scaled
#     to percent. Equivalently the mean utilization across all eligible rows.
#   * $null when zero eligible rows. Callers decide what to render for
#     the empty case (Format-AggregateBars emits nothing; Format-WatchTitle
#     collapses to bare suffix).
function Get-PoolMeanUtilization {
    Param (
        [object[]] $Results,
        [string]   $BucketKey
    )

    if (-not $Results) { return $null }

    $eligible = @($Results | Where-Object { Test-RowIsMeasurable -Row $_ })
    if ($eligible.Count -eq 0) { return $null }

    $n   = $eligible.Count
    $cap = $n * 100

    $usedSum = 0.0
    foreach ($r in $eligible) {
        # Same helper as Get-RowMaxUtilization, so a bar and the rotation
        # decision drawn from the same row cannot report different numbers.
        # A bucket whose window has rolled is already gone (Select-LiveBuckets)
        # and therefore counts 0 here, exactly as a missing one does.
        $u = Get-BucketUtilizationOrZero -Bucket $r.Data.$BucketKey
        if ($u -lt 0)   { $u = 0 }
        if ($u -gt 100) { $u = 100 }
        $usedSum += $u
    }

    # usedSum is in [0, cap] by construction (each $u clamped to [0,100],
    # summed N times with cap = N*100), so no outer clamp needed here.
    return [int][math]::Round(($usedSum / $cap) * 100)
}

# Whether a snapshot row carries percentages to render or judge.
#
# The one definition of "there are numbers here", shared by Format-UsageTable's
# bucket cells and Get-RowMaxUtilization. Status answers a different question
# ("may I switch INTO this slot"), which is why Get-AutoRotationDecision gates
# peers on Status instead: since the cache-fallback ladder landed a non-ok row
# can carry last-known percentages, and every consumer that re-derived this
# from Status ended up contradicting the row printed next to it.
function Test-RowHasUsableData {
    Param ([Parameter(Mandatory)] $Row)

    return [bool]$Row.Data
}

# Whether a percentage can be assigned to the row at all. Used by the aggregate
# bars and by the watch title, the two renderings that must agree.
#
# Usable data, OR 'ok' as its own arm: an 'ok' row whose response carried no
# buckets is a real 0%-utilized account, not an unknown one. It stays in the
# bars' denominator (the behaviour those percentages were tuned against) and it
# keeps the title's '— | —', which says "active slot, cold" as opposed to the
# bare suffix's "nothing to show".
function Test-RowIsMeasurable {
    Param ([Parameter(Mandatory)] $Row)

    return ($Row.Status -eq 'ok' -or (Test-RowHasUsableData -Row $Row))
}

# Render aggregate progress bars showing pool-wide USAGE above the
# usage table. Two bars: 'Session' (five_hour) and 'Week' (seven_day).
# For each bucket the function sums per-slot utilization across eligible
# rows, computes pool-used % as used / cap where cap = N * 100
# (equivalently the mean utilization across eligible rows), and draws a
# fit-to-table-width bar. Filled portion = used; empty portion = remaining
# headroom -- standard progress-bar convention, matching the per-slot
# Session/Week table cells beneath.
#
# Width math: bar width = TotalLineWidth - 17, floored at 8. The 17 is
# 2 (indent) + 8 (label pad) + 1 ('[') + 1 (']') + 1 (space) + 4
# ("NNN%"). Floor keeps narrow 1-slot tables visually meaningful.
#
# Slot inclusion rules (Test-RowIsMeasurable):
#   * Status='ok', or any row carrying Data from the cache fallback.
#   * Buckets with null/missing utilization counted as 0% used.
#
# Color thresholds via $Script:AggregateRedPct / $Script:AggregateYellowPct.
#
# Output: 4 Write-Host lines per call (Session bar, blank, Week bar,
# blank); the leading blank that precedes them comes from the caller's
# post-header padding in Format-UsageTable. When no qualifying rows
# exist, emits nothing; the table below renders cleanly without
# orphan padding.
#
# Uses Write-Host (information stream / 6) rather than Write-Progress
# (stream 4) for three reasons: (1) the suite's `6>&1 | Out-String`
# capture pattern would miss stream-4 output; (2) Write-Progress is
# host-managed and transient (it would not sit inline above the table);
# (3) it does not compose with Clear-Host watch redraws.
function Format-AggregateBars {
    Param (
        [object[]] $Results,
        [int]      $TotalLineWidth
    )

    if (-not $Results) { return }

    # Skip-render when no eligible rows exist. Get-PoolMeanUtilization
    # returns $null in that case; checking once up front (rather than
    # per-bucket) keeps the per-bucket loop branch-free. Same predicate as
    # that helper, so the skip decision and the math cannot disagree.
    $eligible = @($Results | Where-Object { Test-RowIsMeasurable -Row $_ })
    if ($eligible.Count -eq 0) { return }

    # Width derivation explained above. Floor 8 so 1-slot tables with
    # short status text still render a visible bar instead of an
    # empty `[]` next to the right label.
    $barWidth = [math]::Max(8, $TotalLineWidth - 17)

    $buckets = @(
        @{ Key = 'five_hour'; Label = 'Session' },
        @{ Key = 'seven_day'; Label = 'Week'    }
    )

    # Each iteration emits one bar line followed by one blank. With the
    # caller's pre-bars blank line (from Format-UsageTable) the visual
    # cadence is:
    #   <caller blank> / Session bar / <blank> / Week bar / <blank>
    # which gives the requested padding before, between, and after.
    foreach ($b in $buckets) {
        $key   = $b.Key
        $label = $b.Label

        # Shared math via Get-PoolMeanUtilization so the bar percentage
        # and Format-WatchTitle's -Aggregate title number cannot drift.
        # $eligible.Count > 0 guarantees a non-null return.
        $usedPct = Get-PoolMeanUtilization -Results $Results -BucketKey $key

        $filled = [int][math]::Round(($usedPct / 100.0) * $barWidth)
        if ($filled -lt 0)         { $filled = 0 }    # defense-in-depth
        if ($filled -gt $barWidth) { $filled = $barWidth }

        $bar = ('█' * $filled) + ('▓' * ($barWidth - $filled))

        $color = Get-AggregateBarColor -UsedPct $usedPct

        $line = '  {0,-8}[{1}] {2,3}%' -f $label, $bar, $usedPct
        Write-Color $line $color
        Write-Host ''
    }
}

# Render per-slot usage rows as a fixed-width table. Uses Write-Host (the
# information stream) to match the other Invoke-*Action functions so the
# existing `$out = Invoke-*Action 6>&1 | Out-String` test pattern keeps
# working. Fixed-width + manually padded columns (rather than Format-Table)
# so tests can assert on stable column headers without fighting PowerShell's
# responsive-width formatter.
#
# Column shape (5 data columns + leading active-marker):
#   *  Slot    Account                      Session         Week         Status
#
# - `Session` / `Week` cells merge utilization and reset delta into one
#   string ('100% (2h 37m)'); width auto-fits to the widest cell in the batch.
# - `Account` renders the slot's filename-encoded email, middle-truncated
#   at $Script:AccountColumnMaxWidth. Slots with no email (offline save)
#   or whose email equals the slot name (dedup form) render as '—'.
# - `Status` mixes HTTP health (expired / unauthorized / error / no-oauth)
#   with plan-usability derived via Get-PlanStatus; see that helper for
#   the threshold semantics.
#
# -IncludeAggregateBars : when set, render the pool-wide aggregate bar
# block (Format-AggregateBars) between the [Usage] header and the
# column header. Set by Format-UsageFrame for the table view; not set
# by Format-UsageVerbose's non-ok fallback (which reuses this function
# for a single failed-row render).
function Format-UsageTable {
    Param (
        [object[]] $Results,
        [switch]   $IncludeAggregateBars,
        # When > 0, append a right-aligned '▶ switching slot at N%'
        # indicator to the '[Usage] Plan usage' header line. Used by
        # the watch loop's -Auto mode to indicate auto-rotation is
        # engaged. The indicator's right edge anchors to the terminal
        # width minus 1 (preserves a 1-char right margin); when the
        # terminal is too narrow to fit the left header AND a 2-space
        # gap AND the indicator, the indicator is silently dropped
        # (the footer's [Monitor] line still carries the state). When
        # -Auto is set, an extra blank line is inserted under the
        # header to balance the visually-busier right-aligned indicator.
        [int]      $AutoThreshold = 0
    )

    if (-not $Results) { return }

    # Precompute per-row cell content so column widths can auto-fit.
    $rows = foreach ($r in $Results) {
        $fiveCell  = '   —'
        $sevenCell = '   —'

        # Render bucket percentages whenever the row carries data, not only
        # on 'ok'. A 'rate-limited' row served from the (possibly stale)
        # cache fallback carries last-known Data; showing those numbers
        # keeps the row from looking like a dead/unused slot during a
        # transient throttle. Rows with no Data (expired / unauthorized /
        # error / no-oauth / no-cache rate-limited) keep the em-dash.
        if (Test-RowHasUsableData -Row $r) {
            if ($r.Data.five_hour -and $null -ne $r.Data.five_hour.utilization) {
                $fiveCell = Format-BucketCell $r.Data.five_hour.utilization $r.Data.five_hour.resets_at
            }
            if ($r.Data.seven_day -and $null -ne $r.Data.seven_day.utilization) {
                $sevenCell = Format-BucketCell $r.Data.seven_day.utilization $r.Data.seven_day.resets_at
            }
        }

        $email = if ($r.PSObject.Properties['Email']) { $r.Email } else { $null }
        $accountCell = Format-AccountCell -SlotName $r.Name -Email $email

        # Status: plan-usability when HTTP was ok, HTTP-state otherwise.
        # Every label is a short fixed string, because this is the last
        # column and its width also sizes the aggregate bars above the
        # header: one long cell wrapped both its own row AND the two bars.
        # Reasons (an exception tail, or the remedy for a hard failure)
        # therefore live on Format-UsageAdvisory's per-slot lines below the
        # table, which own a full terminal line. The one bounded exception
        # is 'error <code>', short enough to read at a glance and the single
        # most useful discriminator between transient 5xx and everything else.
        $statusText = switch ($r.Status) {
            'ok'           { Get-PlanStatus $r.Data }
            'no-oauth'     { 'no-oauth' }
            'expired'      { 'expired' }
            'unauthorized' { 'unauthorized' }
            'error'        {
                if ($r.PSObject.Properties['HttpStatus'] -and $r.HttpStatus) {
                    "error $($r.HttpStatus)"
                } else {
                    'error'
                }
            }
            'rate-limited' { 'rate-limited' }
            # 'warming-up' is the transient initial label rendered when
            # Invoke-WarmAllSlots starts iterating slots on `sca warmup`
            # or `sca monitor -KeepWarm` startup. Synthetic snapshot rows carry
            # it; the warmup pass mutates each row's Status to 'priming'
            # while its `claude -p` activation is in flight, then to the
            # real outcome ('ok' / 'rate-limited' / 'no-oauth' /
            # 'expired' / 'unauthorized' / 'error') once it returns. The
            # hyphenated internal value renders space-separated to match
            # the existing label convention ('rate limited' / 'limited
            # 5h' / 'near limit').
            'warming-up'    { 'warming up' }
            'priming'       { 'priming' }
            default         { [string]$r.Status }
        }

        [pscustomobject]@{
            Row     = $r
            Marker  = if ($r.IsActive) { '*' } else { ' ' }
            Name    = $r.Name
            Account = $accountCell
            Five    = $fiveCell
            Seven   = $sevenCell
            Status  = $statusText
        }
    }

    # Minimum widths are the header label lengths so headers never get
    # clipped. Data-driven max keeps narrow tables narrow for 1-2 slots.
    # 'Session' (7) / 'Week' (4) are the new header literals; min widths
    # match. Status header is 6 chars but the column flows; track the
    # widest rendered status so $totalLineWidth below is accurate.
    $nameW = 4; $acctW = 7; $fiveW = 7; $sevenW = 4; $statusW = 6
    foreach ($e in $rows) {
        if ($e.Name.Length    -gt $nameW)   { $nameW   = $e.Name.Length }
        if ($e.Account.Length -gt $acctW)   { $acctW   = $e.Account.Length }
        if ($e.Five.Length    -gt $fiveW)   { $fiveW   = $e.Five.Length }
        if ($e.Seven.Length   -gt $sevenW)  { $sevenW  = $e.Seven.Length }
        if ($e.Status.Length  -gt $statusW) { $statusW = $e.Status.Length }
    }

    $fmt = "  {0} {1,-$nameW}  {2,-$acctW}  {3,-$fiveW}  {4,-$sevenW}  {5}"

    # Total rendered line width; used to fit-to-table the aggregate
    # bars above the header. Mirrors the $fmt pattern: 2 (indent) + 1
    # (marker) + 1 (sep) + nameW + 2 + acctW + 2 + fiveW + 2 + sevenW
    # + 2 + statusW.
    $totalLineWidth = 2 + 1 + 1 + $nameW + 2 + $acctW + 2 + $fiveW + 2 + $sevenW + 2 + $statusW

    # Header: '[Usage] Plan usage' left-anchored, optional right-aligned
    # auto-mode indicator. The indicator is computed against the terminal
    # width (Get-ConsoleWidth) so it floats to the right edge with
    # a 1-column right margin. Width-aware fallback: when the terminal
    # is too narrow to fit both segments with a 2-space minimum gap, the
    # indicator is silently dropped (the footer's [Monitor] line still
    # carries the state, so no information is lost). An unknown width (0)
    # counts as "narrow" and drops the indicator.
    #
    # Indicator visual: '<glyph><space><text>' where:
    #   glyph = '▶' (U+25B6, "black right-pointing triangle"), white
    #           (high-contrast lozenge so the auto-mode signal pops
    #            against the dimmer header / footer text).
    #   text  = 'switching slot at N%', DarkGray (matches the footer
    #           '[Watch]' / '[Monitor]' line color so the indicator recedes
    #           into ambient-metadata weight).
    # Rendered via three Write-Color calls with -NoNewline so each segment
    # carries its own SGR color while the line is still a single logical
    # row. The trailing un-piped Write-Host '' terminates the row.
    $headerLeft  = '[Usage] Plan usage'
    $autoGlyph   = $null
    $autoText    = $null
    $autoPadding = $null
    if ($AutoThreshold -gt 0) {
        $autoGlyph    = "$([char]0x25B6)"
        $autoText     = " switching slot at $AutoThreshold%"
        $indicatorLen = $autoGlyph.Length + $autoText.Length
        $termWidth    = Get-ConsoleWidth
        # Reserve 1 col right margin so the indicator isn't flush with
        # the terminal edge. Need: leftLen + 2 (min gap) + indicatorLen
        # + 1 (right margin) <= width.
        if ($termWidth -lt ($headerLeft.Length + 2 + $indicatorLen + 1)) {
            $autoGlyph = $null
            $autoText  = $null
        } else {
            $padCount    = $termWidth - $headerLeft.Length - $indicatorLen - 1
            $autoPadding = ' ' * $padCount
        }
    }
    if ($autoGlyph) {
        # Three-segment colored line: DarkYellow header + padding (no
        # color) + white glyph (high-contrast lozenge) + DarkGray text
        # (matches footer ambient-metadata color). -NoNewline chains
        # them onto one logical row; final Write-Host '' below terminates.
        Write-Color $headerLeft  'DarkYellow' -NoNewline
        Write-Host  $autoPadding -NoNewline
        Write-Color $autoGlyph   'Gray'       -NoNewline
        Write-Color $autoText    'DarkGray'
    } else {
        Write-Color $headerLeft 'DarkYellow'
    }
    Write-Host ''
    # Extra breathing room under the header when -Auto is engaged: the
    # right-side indicator makes the header row visually busier, so an
    # additional blank balances the layout. Without -Auto the original
    # one-blank cadence is preserved (matches existing screenshots / SVG).
    if ($AutoThreshold -gt 0) {
        Write-Host ''
    }
    # Aggregate bars sit between the post-header blank and the column
    # header. Format-AggregateBars emits per bar: 'bar line' + blank,
    # so the caller's blank above acts as the leading padding. When
    # there are no eligible rows the helper returns silently; the
    # leading blank still separates header from column header.
    #
    # The bars fit to the table, but the table is content-sized and can be
    # wider than the terminal (a long email plus a wide Status label clears
    # 80 columns), and a wrapped bar reads as a rendering bug rather than as
    # an overflowing table. Ceiling at width - 1 (1-col right margin, same
    # as the auto-mode indicator above); the helper's own floor of 8 caps
    # the other end. Unknown width (0) leaves the fit-to-table width alone.
    if ($IncludeAggregateBars) {
        $barLineWidth = $totalLineWidth
        $termWidth    = Get-ConsoleWidth
        if ($termWidth -gt 0 -and $barLineWidth -gt ($termWidth - 1)) {
            $barLineWidth = $termWidth - 1
        }
        Format-AggregateBars -Results $Results -TotalLineWidth $barLineWidth
    }
    Write-Host ($fmt -f ' ',  'Slot',         'Account',       'Session',     'Week',          'Status')
    Write-Host ($fmt -f ' ', ('-' * $nameW), ('-' * $acctW),  ('-' * $fiveW), ('-' * $sevenW), '------')

    foreach ($entry in $rows) {
        $color = Get-StatusColor -Label $entry.Status -IsActive ([bool]$entry.Row.IsActive)
        Write-Color ($fmt -f $entry.Marker, $entry.Name, $entry.Account, $entry.Five, $entry.Seven, $entry.Status) $color
    }
}

# Render the saved-slot inventory as a fixed-width 2-data-column table:
# `Slot | Account`, plus the leading active-marker column. Mirrors
# Format-UsageTable's column-width algorithm and row-coloring rules so
# `sca list` and `sca usage` look like sibling views (same header style,
# same active-marker conventions, same Account-cell truncation). Pure
# offline render: no network calls, unlike Format-UsageTable. Used by
# Invoke-ListAction; kept as a sibling rather than a generic helper
# because the column counts and per-cell rules differ enough that an
# abstraction would cost more than it saves with only two callers.
function Format-ListTable {
    Param (
        [object[]] $Slots,
        # When set, skip the `[List] Saved slots` header and the leading
        # blank line. Used by Invoke-SwitchAction so the table renders
        # cleanly under the switch's own success line without a redundant
        # second DarkYellow header.
        [switch]   $SuppressHeader
    )

    if (-not $Slots) { return }

    # Precompute account cells so column widths can auto-fit. The Slot
    # column carries the parsed slot name (Get-SlotFileInfo); the Account
    # column reuses Format-AccountCell so dedup and truncation match the
    # usage table.
    $rows = foreach ($s in $Slots) {
        [pscustomobject]@{
            Slot     = $s
            Marker   = if ($s.IsActive) { '*' } else { ' ' }
            Name     = $s.Name
            Account  = Format-AccountCell -SlotName $s.Name -Email $s.Email
        }
    }

    # Minimum widths are the header label lengths so the headers never
    # get clipped on a 1-2 slot table.
    $nameW = 4; $acctW = 7
    foreach ($e in $rows) {
        if ($e.Name.Length    -gt $nameW) { $nameW = $e.Name.Length }
        if ($e.Account.Length -gt $acctW) { $acctW = $e.Account.Length }
    }

    $fmt = "  {0} {1,-$nameW}  {2}"

    if (-not $SuppressHeader) {
        Write-Color "[List] Saved slots" 'DarkYellow'
        Write-Host ''
    }
    Write-Host ($fmt -f ' ',  'Slot',         'Account')
    Write-Host ($fmt -f ' ', ('-' * $nameW), ('-' * $acctW))

    foreach ($entry in $rows) {
        $color = if ($entry.Slot.IsActive) { 'Green' } else { $null }
        if ($color) {
            Write-Color ($fmt -f $entry.Marker, $entry.Name, $entry.Account) $color
        } else {
            Write-Host ($fmt -f $entry.Marker, $entry.Name, $entry.Account)
        }
    }

    # Trailing blank line so the table has breathing room before the
    # next prompt (or before any advisory the caller emits below). Mirrors
    # Format-UsageFrame's footer behavior; both `sca list` / `sca switch`
    # / `sca usage` now end with a blank line so the views look consistent.
    Write-Host ''
}

# Render the full response for a single slot in verbose form. Used when
# `sca usage <name>` targets one slot; shows absolute local-tz reset times
# (Claude-Code-style) for the two buckets we care about: five_hour
# ("Current session") and seven_day ("Current week (all models)"). Other
# buckets returned by the endpoint are intentionally not rendered here
# because they are not the limits the user is tracking; they remain
# accessible via `sca usage <name> -Json`.
function Format-UsageVerbose {
    Param ([object] $Result)

    $name = $Result.Name
    Write-Color "[Usage] Slot '$name'$(if ($Result.IsActive) { ' (active)' })" 'DarkYellow'

    # Surface the OAuth account email whenever we could resolve it, so the
    # verbose drill-down answers the "which account is this?" question
    # without forcing the user to cross-reference the table.
    if ($Result.PSObject.Properties['Email'] -and $Result.Email) {
        Write-Color "  Account: $($Result.Email)" 'DarkGray'
    }

    if ($Result.Status -ne 'ok') {
        Format-UsageTable -Results @($Result)
        return
    }
    if (-not $Result.Data) {
        Write-Color "  (empty response)" 'DarkGray'
        return
    }

    # Status line between Account and the bucket rows, so the first thing
    # the user reads is "can I use this slot right now?". Same label set
    # as the summary table, plus a short English rationale when the
    # label alone is not self-explanatory (near limit, limited, no plan
    # data).
    $planStatus  = Get-PlanStatus $Result.Data
    $rationale   = Get-StatusRationale $planStatus
    $statusLine  = if ($rationale) { "$planStatus - $rationale" } else { $planStatus }
    $statusColor = Get-StatusColor -Label $planStatus -IsActive ([bool]$Result.IsActive)
    Write-Color ("  Status:  $statusLine") $statusColor

    # Two-bucket render. Each Render-Bucket closure inlines the label so
    # this function does not depend on a lookup table; when buckets change
    # (scope decision to track only these two) the change is local.
    $renderOne = {
        Param ([string] $Label, $Bucket)
        $util  = $null
        $reset = $null
        if ($Bucket) {
            $util  = $Bucket.utilization
            $reset = $Bucket.resets_at
        }
        $pctCell   = Format-UtilCell $util
        $resetCell = if ($reset) { Format-ResetAbsolute $reset } else { '—' }
        # Label pad of 10 matches the bar block's 8-pad plus the
        # verbose view's natural breathing room (longest label 'Session'
        # = 7 chars, leaving 3 trailing spaces before the percent).
        Write-Host ("  {0,-10} {1}  {2}" -f $Label, $pctCell, $resetCell)
    }

    $five  = $Result.Data.five_hour
    $seven = $Result.Data.seven_day

    if (-not $five -and -not $seven) {
        Write-Color "  No plan-usage data (account may not have a subscription, or has not made a live API call yet)." 'DarkGray'
        return
    }

    & $renderOne 'Session' $five
    & $renderOne 'Week'    $seven
}

# --- usage action: data + rendering split ---------------------------------
#
# Invoke-UsageAction was originally a single function that both gathered
# per-slot usage data and wrote the output. Splitting the two makes
# `sca usage -Watch` possible: the watch loop re-gathers a fresh snapshot
# each poll, keeps the previous snapshot visible during HTTP failures,
# and calls the same frame renderer that the one-shot path uses. The
# split also keeps the test matrix clean: unit tests mock the data
# layer and assert on the rendered frame.
#
# Snapshot shape (Get-UsageSnapshot):
#   Results          : array of per-slot result rows
#                      { Name, IsActive, Status, Data, Error, Email,
#                        IsCachedFallback, HttpStatus, FallbackReason }
#                      Invoke-WarmAllSlots builds the same shape for its
#                      synthetic warmup rows; keep the two in step.
#   NoSlots          : $true when there are zero saved slots. Caller
#                      prints the "no slots" hint.
#   HasRateLimited   : $true when at least one row is 'rate-limited'. Read
#                      only by Invoke-UsageWatch, to schedule an early
#                      repoll after a warmup pass that ended throttled.
#
# Per-row conditions are NOT summarised here. Format-UsageAdvisory needs the
# affected slot NAMES, not a boolean, so it partitions Results itself; a
# parallel set of flags would be a second copy of the same predicate, kept in
# sync by hand at every site that builds a snapshot.
#
# The caller (Invoke-UsageAction) runs Invoke-Reconcile before invoking
# this function, so by the time we enumerate slots the active-slot file is
# byte-equal to .credentials.json: the active slot file IS the active
# credentials, and no synthetic <active> row is needed.

# Gather the per-slot usage snapshot used by both the one-shot action and
# the live watch loop. Performs all network IO (Get-SlotUsage per slot).
# Never renders; callers decide between table, verbose, JSON, and
# watch-frame presentations.
function Get-UsageSnapshot {
    Param ([String] $Name)

    $slots = @(Get-Slots)

    if ($slots.Count -eq 0) {
        return [pscustomobject]@{
            Results        = @()
            NoSlots        = $true
            HasRateLimited = $false
        }
    }

    # -Name filter: select a single slot by name (after Get-SafeName
    # sanitization). Throws 'not found' when no match.
    $selectedSlots = $slots
    if ($Name) {
        $safeName      = Get-SafeName $Name
        $selectedSlots = @($slots | Where-Object { $_.Name -eq $safeName })
        if ($selectedSlots.Count -eq 0) {
            throw "Slot '$safeName' not found."
        }
    }

    $results = foreach ($slot in $selectedSlots) {
        $usage = Get-SlotUsage -SlotPath $slot.Path
        [pscustomobject]@{
            Name     = $slot.Name
            IsActive = $slot.IsActive
            Status   = $usage.Status
            Data     = $usage.Data
            Error    = $usage.Error
            # HttpStatus must be projected, not dropped: Format-UsageTable's
            # 'error' arm keys off it to render the compact 'error 529' label
            # instead of the verbose .NET sentence. Omitting it here silently
            # made that arm unreachable through every real code path.
            HttpStatus     = $usage.HttpStatus
            # Why the live read fell back to cache ('rate-limit' / 'network'),
            # so Format-UsageAdvisory can word the advisory accurately.
            FallbackReason = $usage.FallbackReason
            # Email comes from the slot filename via Get-Slots (parsed by
            # Get-SlotFileInfo). No HTTP call here; the only source of
            # truth for a slot's email is its filename, which was written
            # by `sca save` from a fresh profile fetch at that moment.
            Email            = $slot.Email
            IsCachedFallback = $usage.IsCachedFallback
        }
    }

    return [pscustomobject]@{
        Results        = @($results)
        NoSlots        = $false
        HasRateLimited = ($results | Where-Object { $_.Status -eq 'rate-limited' }).Count -gt 0
    }
}

# Format a list of slot names as quoted, comma-joined text, collapsing to
# "'a', 'b', 'c' and N more" past 3 names so a wide pool can't overflow the
# advisory line. Returns $null for an empty list. Pure.
function Format-SlotNameList {
    Param ([string[]] $Names)

    $names = @($Names | Where-Object { $_ })
    if ($names.Count -eq 0) { return $null }

    $cap = 3
    if ($names.Count -le $cap) {
        return (($names | ForEach-Object { "'$_'" }) -join ', ')
    }
    $shown = @($names[0..($cap - 1)] | ForEach-Object { "'$_'" })
    $more  = $names.Count - $cap
    return (($shown -join ', ') + " and $more more")
}

# Build the yellow advisory block for a usage frame, or $null when every row
# read cleanly. Pure (no Write-Host) so it unit-tests without host capture.
# Returns a newline-joined string; Format-UsageFooter splits and colours each
# line the same way it already splits $Footer.
#
# Two groups: condition lines naming the affected slots, then per-slot reason
# lines. Always names the affected slot(s), because the affected row is
# usually a non-active peer rather than the '*' active slot.
#
# One condition line per distinct condition, worst first, because a slot can
# only be in one of the four buckets. Collapsing to a single line hides a hard
# failure behind whichever condition wins:
#   * no-data failures  : the row shows em-dashes. States the condition
#     without promising recovery, because the renderer is shared by one-shot
#     `sca usage` (no "next poll") and the watch loop.
#   * cache fallbacks   : the row keeps last-known percentages, so the line
#     says so. Worded per FallbackReason so a network blip is not reported as
#     a rate limit. A missing/null reason reads as 'rate-limit', which covers
#     the inline backoff short-circuit in Get-SlotUsage.
function Format-UsageAdvisory {
    Param ([pscustomobject] $Snapshot)

    if (-not $Snapshot) { return $null }

    $rows = @($Snapshot.Results)
    if ($rows.Count -eq 0) { return $null }

    # Cached rows are excluded from the no-data buckets: a stale fallback row
    # carries a non-ok Status too, and reporting it twice would contradict
    # itself (once as "unreadable", once as "showing last known usage").
    $bareError  = @($rows | Where-Object { $_.Status -eq 'error'        -and -not $_.IsCachedFallback })
    $bareLimit  = @($rows | Where-Object { $_.Status -eq 'rate-limited' -and -not $_.IsCachedFallback })
    $cachedNet  = @($rows | Where-Object { $_.IsCachedFallback -and $_.FallbackReason -eq 'network' })
    $cachedLim  = @($rows | Where-Object { $_.IsCachedFallback -and $_.FallbackReason -ne 'network' })

    $lines = [System.Collections.Generic.List[string]]::new()

    # NeedsCopula: the limit tails read "<slots> is/are currently ..."; the
    # read-failure tails carry their own verb, so injecting one would produce
    # "'a' is could not be read".
    #
    # The tails name no source and no cause, because this renderer serves two
    # producers. Get-UsageSnapshot's rows come from /api/oauth/usage, but
    # Invoke-WarmAllSlots feeds the same function rows whose Status came from
    # `claude -p` (reachable from `sca warmup` and from monitor -KeepWarm's
    # startup repaint). Saying "from the usage API" was false for an activation
    # failure, and saying "by Anthropic" contradicted the plan-limit classifier
    # in Invoke-SlotActivator, whose entire point is that "You've hit your
    # session limit" is a plan limit and not a rate limit. The per-slot reason
    # line below carries the real cause, which is accurate for both producers.
    foreach ($bucket in @(
        @{ Rows = $bareError; NeedsCopula = $false; Tail = 'could not be read; usage unknown.' },
        @{ Rows = $bareLimit; NeedsCopula = $true;  Tail = 'currently rate-limited or at a plan limit.' },
        @{ Rows = $cachedNet; NeedsCopula = $false; Tail = 'could not be read live; showing last known usage.' },
        @{ Rows = $cachedLim; NeedsCopula = $true;  Tail = 'currently rate-limited or at a plan limit; showing last known usage.' }
    )) {
        $names = @($bucket.Rows | ForEach-Object { $_.Name })
        if ($names.Count -eq 0) { continue }
        $list = Format-SlotNameList -Names $names
        if (-not $list) { continue }
        if ($bucket.NeedsCopula) {
            $verb = if ($names.Count -eq 1) { 'is' } else { 'are' }
            $lines.Add("[Usage] $list $verb $($bucket.Tail)")
        } else {
            $lines.Add("[Usage] $list $($bucket.Tail)")
        }
    }

    # Per-slot reason lines below the condition lines. The Status column
    # carries only a short label, so this is where the detail lands: the row's
    # own error message when it has one, otherwise the remedy for a hard
    # failure. A 'rate-limited' row without a message is deliberately silent,
    # because the condition line above already says exactly that.
    #
    # Messages are capped at 3, for the same reason Format-SlotNameList caps
    # names: under -Watch a wide failing pool would push the table off screen.
    # The cap costs detail, not coverage, because the condition lines above
    # already name every affected slot. Hard failures take the cap first; see
    # the IsCached sort key below.
    $messages = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($row in $rows) {
        if (-not $row.Error) { continue }
        $tail = Format-StatusErrorTail -Message $row.Error
        if ($tail) {
            $messages.Add([pscustomobject]@{
                Name     = $row.Name
                Line     = "[Usage] $($row.Name): $tail"
                # Sort key, not display: a row still showing numbers is the
                # least urgent thing here, and since a fresh cache fallback
                # carries its reason too, unsorted it could take all three
                # slots from rows that have nothing left to show.
                IsCached = [bool]$row.IsCachedFallback
            })
        }
    }
    $reported = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($message in @($messages | Sort-Object -Property IsCached -Stable | Select-Object -First 3)) {
        $lines.Add($message.Line)
        [void]$reported.Add($message.Name)
    }

    # Remedies are grouped per status, worst first, like the condition lines: a
    # remedy is a per-status constant, so one line covers every slot sharing it.
    # Sharing the messages' cap instead spent N lines on identical text for N
    # api-key slots, and no ordering could stop three transport errors from
    # dropping the remedy outright.
    #
    # Keyed on "did this row already get a line", NOT on "does this row carry
    # a message". Every producer of 'expired' stamps an Error, so the latter
    # test made the expired remedy unreachable and left the slot silent
    # whenever the cap above dropped its message. These three statuses get no
    # condition line, so that silence was total, on the one failure class that
    # does not clear on its own.
    foreach ($status in @('expired', 'unauthorized', 'no-oauth')) {
        $names = @($rows | Where-Object { $_.Status -eq $status -and -not $reported.Contains($_.Name) } | ForEach-Object { $_.Name })
        $list  = Format-SlotNameList -Names $names
        if (-not $list) { continue }
        $lines.Add("[Usage] ${list}: $(Get-StatusRationale -Label $status)")
    }

    if ($lines.Count -eq 0) { return $null }
    return ($lines -join "`n")
}

# Render one usage frame (table OR verbose view, plus optional advisory
# and optional footer). Pure presentation; does not call the network.
# Used by both the one-shot action and the live watch loop; the same
# frame renders identically in either context so tests assert on the
# frame shape without running the loop.
#
# -Name           : when set, selects the single-slot verbose view. Empty
#                   -> summary table.
# -Snapshot       : output of Get-UsageSnapshot for this frame.
# -Footer         : optional string printed below the table / verbose view
#                   for the watch-mode "Last poll" line. Multi-line
#                   strings are split and each line rendered in the
#                   DarkGray information color.
# -AutoThreshold  : when set (1..100), append a right-aligned
#                   '▶ switching slot at N%' indicator to the
#                   `[Usage] Plan usage` header. Used by `sca monitor`
#                   to indicate auto-rotation is engaged.
#                   Width-aware: if the terminal is too narrow to fit
#                   both the left header and the indicator with a
#                   2-space gap, the indicator is silently dropped
#                   (the footer's `[Monitor]` line still
#                   carries the state, so no info is lost).
function Format-UsageFrame {
    Param (
        [String]                $Name,
        [pscustomobject]        $Snapshot,
        [AllowEmptyString()]
        [AllowNull()] [String]  $Footer,
        [int]                   $AutoThreshold = 0
    )

    if (-not $Snapshot -or $Snapshot.NoSlots) {
        Write-Color "[Usage] No slots saved yet. Use: sca save <name>" 'Yellow'
        if ($Footer) { Format-UsageFooter $Footer }
        return
    }

    $results = @($Snapshot.Results)
    if ($Name -and $results.Count -eq 1) {
        Format-UsageVerbose -Result $results[0]
    } else {
        # -IncludeAggregateBars: render the pool-wide Session/Week
        # progress bars above the column header. Format-UsageVerbose's
        # non-ok fallback also calls Format-UsageTable but does NOT pass
        # this switch; bars are a pool-level summary and would be
        # off-topic on a single-slot drill-down.
        # -AutoThreshold is threaded through unchanged; the table is
        # the layer that renders the [Usage] header where the tag goes.
        Format-UsageTable -Results @($results) -IncludeAggregateBars -AutoThreshold $AutoThreshold
    }

    # Read-failure / cache-fallback advisory (wording + slot naming in
    # Format-UsageAdvisory). Rendered in the footer block (alongside the
    # [Monitor] / [Watch] lines), NOT directly under the table: the advisory
    # leads the footer group so the signal sits with the other per-frame
    # status lines instead of crowding the table's last row.
    $advisory = Format-UsageAdvisory -Snapshot $Snapshot

    if ($Footer -or $advisory) {
        Format-UsageFooter -Footer $Footer -Advisory $advisory
    } else {
        Write-Host ''
    }
}

# Render the multi-line footer block under a usage frame. Internal helper
# for Format-UsageFrame; extracted so the watch loop and any future
# footer-consumers share one wrapping policy.
#
# -Footer   : the [Watch] / [Monitor] lines (DarkGray). Kept as the first
#             positional parameter so the existing positional call sites
#             (`Format-UsageFooter $Footer`) bind unchanged.
# -Advisory : optional usage advisory (Yellow), one line per condition.
#             Leads the footer block, above the DarkGray footer lines, so the
#             warning stays visually distinct while grouping with the
#             per-frame status. Split on newlines like $Footer, because
#             several conditions (a throttled peer and an unreadable active
#             slot, say) can hold at once.
function Format-UsageFooter {
    Param (
        [AllowEmptyString()] [AllowNull()] [String] $Footer,
        [AllowEmptyString()] [AllowNull()] [String] $Advisory
    )

    # Two blank lines between the table and the footer: the first
    # closes the table block (paired with `Format-UsageTable`'s output),
    # the second adds breathing room so the footer doesn't visually
    # touch the table's last row. This matters most under -Watch where
    # the screen never scrolls and the table-to-footer gap is the
    # user's main horizontal landmark.
    Write-Host ""
    Write-Host ""
    if ($Advisory) {
        foreach ($line in ($Advisory -split "`r?`n")) {
            Write-Color $line 'Yellow'
        }
    }
    if ($Footer) {
        foreach ($line in ($Footer -split "`r?`n")) {
            Write-Color $line 'DarkGray'
        }
    }
}

# Brand suffix appended to the watch-mode terminal title. Lives as a
# script-scope constant so the wording is editable in one place. The
# title's job is "make this background tab identifiable + show two
# numbers"; the leading data carries the actionable bits, this trails.
$Script:WatchTitleSuffix = 'Switch Claude Account'

# Build the OSC 0 terminal-title string for `sca usage -Watch`. Exact output
# shapes are pinned by the Format-WatchTitle tests.
#
# Why the two modes differ rather than sharing one number:
#   * Default (active slot) reports the active row only. A pool mean averages
#     a burned slot down to noise (1 of 5 slots at 100% reads as ~20%), which
#     destroys the alarm-glance value the title exists for.
#   * -Aggregate (wired to -Auto) reports the pool mean instead, because under
#     rotation the active slot moves under the user and an active-slot title
#     stops being actionable. It shares Get-PoolMeanUtilization with
#     Format-AggregateBars so the title and the on-screen bar cannot drift.
#
# Each mode therefore needs its own alarm tiers: the per-slot
# UtilWarnPct / UtilLimitPct would need nearly every slot maxed before firing
# on a pool mean, so -Aggregate uses AggregateYellowPct / AggregateRedPct.
#
# Control bytes (\x00-\x1F, \x7F) are stripped from the assembled string as
# defense-in-depth. Slot names already pass Get-SafeName, so nothing can reach
# here with control bytes today; the strip keeps a future caller from opening
# an OSC-envelope breakout.
function Format-WatchTitle {
    Param (
        [String]         $Name,
        [pscustomobject] $Snapshot,
        # -Aggregate: switch to pool-mean mode (see docblock above).
        # Wired to -Auto by Invoke-UsageWatch's single call site so the
        # mode tracks the engine's -Auto rotation (i.e. `sca monitor`).
        [switch]         $Aggregate
    )

    $suffix = $Script:WatchTitleSuffix

    if (-not $Snapshot -or $Snapshot.NoSlots) { return $suffix }

    $results = @($Snapshot.Results)
    if ($results.Count -eq 0) { return $suffix }

    if ($Aggregate) {
        # Pool-mean mode. Math delegated to Get-PoolMeanUtilization so
        # the title number tracks Format-AggregateBars byte-for-byte.
        # $null return = no HTTP-ok rows in the snapshot -> bare suffix
        # (matches the aggregate bar's skip-render behavior).
        $five  = Get-PoolMeanUtilization -Results $results -BucketKey 'five_hour'
        $seven = Get-PoolMeanUtilization -Results $results -BucketKey 'seven_day'
        if ($null -eq $five -and $null -eq $seven) { return $suffix }

        $warnPct  = $Script:AggregateYellowPct
        $limitPct = $Script:AggregateRedPct
    }
    else {
        # Active-slot mode. Source row: explicit -Name wins; otherwise
        # the active slot. We do NOT fall back to "first row" or "pool
        # mean"; the active slot is the right answer for an alarm-style
        # display, and -Name is the only reason to override it. Strict
        # Name match (defense-in-depth against an upstream caller that
        # did not pre-filter the snapshot).
        $row = if ($Name) {
            $results | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        } else {
            $results | Where-Object { $_.IsActive } | Select-Object -First 1
        }
        # Same predicate as the bars above the table, so the two alarm-glance
        # surfaces cannot disagree. On Status alone this blanked the title for a
        # stale-cache active row that was still painting numbers one line below
        # and still counting toward rotation, which removed the signal during
        # exactly the transient failure the cache fallback exists to survive.
        if (-not $row -or -not (Test-RowIsMeasurable -Row $row)) { return $suffix }

        $five  = if ($row.Data -and $row.Data.five_hour) { $row.Data.five_hour.utilization } else { $null }
        $seven = if ($row.Data -and $row.Data.seven_day) { $row.Data.seven_day.utilization } else { $null }

        $warnPct  = $Script:UtilWarnPct
        $limitPct = $Script:UtilLimitPct
    }

    # Render one bucket value to either 'NN%' (rounded percent) or '—'
    # for null. Local closure so the prefix branch and the format string
    # share one rendering rule.
    $renderPct = {
        Param ($v)
        if ($null -eq $v) { return '—' }
        return ('{0}%' -f [int][math]::Round([double]$v))
    }

    # Alarm prefix: tiered. '[!]' wins over '[~]' (at-limit is more
    # actionable than only-near-limit). Null buckets contribute nothing
    # to the alarm; they cannot be at or above any threshold by
    # definition. Threshold pair varies by mode (set above).
    $hasLimit = (
        ($null -ne $five  -and [double]$five  -ge $limitPct) -or
        ($null -ne $seven -and [double]$seven -ge $limitPct)
    )
    $prefix = ''
    if ($hasLimit) {
        $prefix = '[!] '
    } else {
        $hasWarn = (
            ($null -ne $five  -and [double]$five  -ge $warnPct) -or
            ($null -ne $seven -and [double]$seven -ge $warnPct)
        )
        if ($hasWarn) { $prefix = '[~] ' }
    }

    $title = '{0}{1} | {2} | {3}' -f $prefix, (& $renderPct $five), (& $renderPct $seven), $suffix

    # Strip control bytes (C0 + DEL). Defense-in-depth against an OSC
    # envelope breakout via a malformed slot name, sidecar email, or
    # future caller path. Tab/CR/LF are unusual in titles too; drop
    # them all.
    return ([regex]::Replace($title, '[\x00-\x1F\x7F]', ''))
}

function Invoke-UsageAction {
    Param (
        [string] $Name,
        [switch] $Json,
        [switch] $Watch,
        [int]    $Interval = $Script:UsageWatchMinInterval
    )

    # The top-level Param block enforces -Json/-Watch mutual exclusion via
    # parameter sets; this runtime guard is belt-and-suspenders for direct
    # callers (notably the test suite) that bypass Invoke-Main.
    if ($Json -and $Watch) {
        throw "-Watch and -Json cannot be combined; -Watch is interactive, -Json is for scripting."
    }

    if ($Watch) {
        # Read-only live view: no auto-rotation, no keep-warm. Those modes
        # are `sca monitor` (Invoke-MonitorAction), which calls the same
        # watch engine with -Auto / -Warmup set.
        Invoke-UsageWatch -Name $Name -Interval $Interval
        return
    }

    # Reconcile first so the slot file matches whatever Claude Code may
    # have written into .credentials.json since the last sca call. The
    # subsequent Get-SlotUsage calls then read fresh tokens and the table
    # marker is correct without relying on a synthetic <active> row.
    # Suppress any reconcile advisory in -Json mode so the JSON output
    # stays parseable.
    if ($Json) {
        Invoke-Reconcile 6>$null | Out-Null
    } else {
        Invoke-Reconcile | Out-Null
    }

    $snapshot = Get-UsageSnapshot -Name $Name

    if ($Json) {
        # Per-slot dictionary. Each entry carries the raw response under
        # .data so scripts can pull any field Anthropic returns, including
        # buckets this script does not render in the table or verbose view.
        # The `account` block is included whenever the email was resolved;
        # currently only .email is surfaced (scope decision).
        #
        # plan_status mirrors the summary-table Status column for HTTP-ok
        # rows so scripts can branch on usability without re-deriving the
        # thresholds. Absent for HTTP-failure rows; callers already have
        # `status` (expired / unauthorized / error / no-oauth) there.
        $out = [ordered]@{}
        foreach ($r in $snapshot.Results) {
            $entry = [ordered]@{
                status    = $r.Status
                is_active = [bool]$r.IsActive
            }
            if ($r.Status -eq 'ok') {
                $entry.plan_status = Get-PlanStatus $r.Data
            }
            # is_cached_fallback: true when the row was served from
            # $Script:SlotUsageCache rather than from a fresh live response,
            # after a 429 (usage or token-refresh endpoint) OR a network /
            # transport failure. Exposed on the JSON contract so scripts can
            # detect stale data without parsing the human-readable advisory
            # text. Only emitted when true to keep the output minimal;
            # absence == fresh. Note this is the ONLY freshness marker: a
            # `status: "error"` row can now carry `data`, and it is flagged
            # here rather than by a second field.
            if ($r.IsCachedFallback) { $entry.is_cached_fallback = $true }
            if ($r.Email) { $entry.account = [ordered]@{ email = $r.Email } }
            if ($r.Data)  { $entry.data    = $r.Data }
            if ($r.Error) { $entry.error   = $r.Error }
            $out[$r.Name] = $entry
        }
        $out | ConvertTo-Json -Depth 10
        return
    }

    Format-UsageFrame -Name $Name -Snapshot $snapshot
}

# `sca monitor`: the live, side-effecting supervisor. Always a watch loop
# that auto-rotates to the next eligible slot when the active slot reaches
# -Threshold (the headline job, hence no -Auto flag); -KeepWarm adds the
# per-poll keep-warm pass. Thin adapter over the shared watch engine
# (Invoke-UsageWatch), which keeps its internal -Auto / -Warmup parameter
# names; the public surface is `monitor` (rotation is unconditional) and
# -KeepWarm. A positional <name> is ignored: rotation and keep-warm span
# the whole slot fleet, so scoping to one slot is meaningless. The
# Claude-Code-running refusal lives in Invoke-UsageWatch's pre-loop guard.
#
# Scope is OpenCode-only by design (issue #8). Rotation depends on the client
# re-reading .credentials.json when its cached token misses, which
# opencode-claude-auth >= 1.5.4 does, so a swap propagates without a restart.
# Claude Code caches ~/.claude.json in memory instead and would race the
# swap, which is why the guard refuses rather than warns.
function Invoke-MonitorAction {
    Param (
        [string] $Name,
        [int]    $Threshold = 95,
        [switch] $KeepWarm,
        [int]    $Interval  = $Script:UsageWatchMinInterval
    )

    Invoke-UsageWatch -Interval $Interval -Auto -Threshold $Threshold -Warmup:$KeepWarm
}

# `sca warmup [name]`: one-shot, non-watch warm pass. Activates every saved
# slot (or just <name>) via the real Claude Code CLI (`claude -p`), so each
# slot's server-side 5h session window opens, then prints the usual usage
# table with live percentages and exits. This is the automation of the
# manual "switch to a slot, send one message" routine across all slots.
#
# Refuses up front if Claude Code is already running (the per-slot swap
# writes ~/.claude.json's oauthAccount, which a live Claude Code caches)
# and if the `claude` binary is not on PATH (the activation IS `claude`).
# The original active slot is restored by Invoke-WarmAllSlots' finally
# block. Billable: ~$0.004 per slot on the pinned Haiku model.
function Invoke-WarmupAction {
    Param ([String] $Name)

    if (Test-ClaudeRunning) {
        throw "Claude Code is running. Close it before 'sca warmup' so each per-slot credentials swap applies cleanly without racing Claude Code's in-memory ~/.claude.json cache."
    }
    if (-not (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "The 'claude' CLI was not found on PATH. 'sca warmup' activates each slot by running 'claude -p', so Claude Code must be installed."
    }

    # Reconcile first so a cross-account swap landed since the last sca call
    # is captured before any slot bytes are read (matches list / usage).
    Invoke-Reconcile | Out-Null

    Write-Color "[Warmup] Activating saved slots via 'claude -p' (billable; ~`$0.004/slot on Haiku, a few seconds each)..." 'DarkYellow'

    # No-op repaint: the one-shot path has no live frame to redraw, so the
    # per-slot state transitions are not rendered; only the final snapshot
    # is printed below as the usual usage table.
    $snapshot = Invoke-WarmAllSlots -Name $Name -Repaint { Param ($snap) }

    if ($null -eq $snapshot) {
        $scope = if ($Name) { "matching '$(Get-SafeName $Name)'" } else { 'saved' }
        Write-Color "[Warmup] No slots $scope to activate. Use: sca save <name>" 'Yellow'
        return
    }

    Write-Host ''
    Format-UsageFrame -Name $Name -Snapshot $snapshot
}

# Decide whether the watch loop's -Auto mode should rotate, suggest a
# cooldown, or do nothing this tick. Pure function: no IO, no rendering,
# no state mutation. Inputs are a usage snapshot (Get-UsageSnapshot
# output) and the integer threshold. The Invoke-UsageWatch loop
# interprets the returned decision: 'rotate' triggers Invoke-SlotSwap,
# 'no-eligible' renders the cooldown footer, 'noop' is the steady-state
# case. Active-slot identification reads the snapshot's IsActive flag
# (Get-Slots populates that from state.active_slot via Read-ScaState),
# so the state file does NOT need to be passed in separately.
#
# Decision shape:
#   @{
#     Action            : 'rotate' | 'no-eligible' | 'active-unknown' | 'noop'
#     FromName          : <string>  # active slot name (when known); null otherwise
#     ToName            : <string>  # destination slot name (Action='rotate')
#     SuggestionName    : <string>  # slot whose bucket resets soonest (Action='no-eligible')
#     SuggestionBucket  : 'Session' | 'Week'   # which bucket (Action='no-eligible')
#     SuggestionResetsAt: <ISO-8601 string|DateTime|DateTimeOffset>  # the reset timestamp
#     ActiveStatus      : <string>  # the active row's Status (Action='active-unknown' only)
#   }
#
# Trigger semantics:
#   * Active slot's max(five_hour.utilization, seven_day.utilization)
#     is compared to $Threshold. Null bucket counts as 0% (matches
#     Format-AggregateBars and the existing 'ok (no plan data)' tier).
#   * Below threshold       -> 'noop'.
#   * At or above threshold -> walk peer slots in alphabetical wrap
#                              order (matches Get-NextSlotName), skip
#                              any with non-ok HTTP status or whose own
#                              max(util) is also at/above threshold.
#                              First eligible candidate -> 'rotate'.
#                              No candidate -> 'no-eligible' with the
#                              soonest future reset across all slots
#                              and both buckets as the cooldown
#                              suggestion.
#
# Edge cases:
#   * Empty snapshot, NoSlots snapshot, or no active row in the snapshot
#     -> 'noop'. The watch loop's footer surfaces these out-of-band; a
#     missing active row is a state problem, not a network one, so it must
#     not be reported as 'active-unknown'.
#   * Active row HTTP-non-ok WITH cached data (a stale fallback, or a
#     throttled slot whose last reading survives): judged on that data like
#     any other row. See Get-RowMaxUtilization for why.
#   * Active row HTTP-non-ok with NO data -> 'active-unknown', carrying
#     ActiveStatus so the caller can name the failure. Rotation does not
#     fire: moving off a slot we know nothing about would burn a healthy
#     account. It must still be REPORTED, or a failed read silently disarms
#     rotation for as long as it lasts.
function Get-AutoRotationDecision {
    Param (
        [Parameter(Mandatory)] [pscustomobject] $Snapshot,
        [Parameter(Mandatory)] [int]            $Threshold
    )

    $noop = [pscustomobject]@{
        Action             = 'noop'
        FromName           = $null
        ToName             = $null
        SuggestionName     = $null
        SuggestionBucket   = $null
        SuggestionResetsAt = $null
    }

    if (-not $Snapshot -or $Snapshot.NoSlots) { return $noop }

    $results = @($Snapshot.Results)
    if ($results.Count -eq 0) { return $noop }

    # Identify the active row by the snapshot's IsActive flag. The
    # snapshot is built from Get-Slots which populates IsActive from
    # $StateFile via Read-ScaState, so this matches state.active_slot
    # without re-reading the file.
    $activeRow = $results | Where-Object { $_.IsActive } | Select-Object -First 1
    if (-not $activeRow) { return $noop }

    # Hoisted from the no-eligible reset walk below so the utilization reads
    # and the cooldown suggestion share one instant.
    $nowUtc = [DateTimeOffset]::UtcNow

    # A non-ok active row with NO data at all is the one case where we cannot
    # reason about the slot: reporting 0% would look like a healthy idle slot
    # and silently disarm rotation, which is exactly how a single timeout used
    # to freeze the monitor while it kept displaying a reassuring "Rotated ..."
    # line. Surface it instead. A non-ok row that DOES carry cached data falls
    # through and is judged on that data.
    if ($activeRow.Status -ne 'ok' -and -not $activeRow.Data) {
        return [pscustomobject]@{
            Action             = 'active-unknown'
            FromName           = $activeRow.Name
            ToName             = $null
            SuggestionName     = $null
            SuggestionBucket   = $null
            SuggestionResetsAt = $null
            ActiveStatus       = $activeRow.Status
        }
    }

    $activeMax = Get-RowMaxUtilization -Row $activeRow
    if ($activeMax -lt $Threshold) {
        # Steady state: active is below threshold; nothing to do.
        return [pscustomobject]@{
            Action             = 'noop'
            FromName           = $activeRow.Name
            ToName             = $null
            SuggestionName     = $null
            SuggestionBucket   = $null
            SuggestionResetsAt = $null
        }
    }

    # Active is at or above threshold. Walk peer slots in alphabetical
    # wrap order starting AFTER the active slot. This mirrors
    # Get-NextSlotName's ordering so -Auto and `sca switch` (no name)
    # rotate in the same direction.
    $sorted = @($results | Sort-Object -Property Name)
    $activeIdx = -1
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if ($sorted[$i].Name -eq $activeRow.Name) { $activeIdx = $i; break }
    }

    # Walk N-1 peers in wrap order (skip the active slot itself).
    $eligible = $null
    for ($offset = 1; $offset -lt $sorted.Count; $offset++) {
        $candidate = $sorted[($activeIdx + $offset) % $sorted.Count]
        # Peers still require a live-quality 'ok'. Deciding to LEAVE an
        # exhausted slot on cached evidence is safe; deciding to ENTER an
        # unverified one is not, and a 'rate-limited' peer is by definition a
        # bad destination. A fresh cache fallback already reports 'ok', so a
        # transient blip does not disqualify a peer.
        if ($candidate.Status -ne 'ok')         { continue }
        $candMax = Get-RowMaxUtilization -Row $candidate
        if ($candMax -ge $Threshold)            { continue }
        $eligible = $candidate
        break
    }

    if ($eligible) {
        return [pscustomobject]@{
            Action             = 'rotate'
            FromName           = $activeRow.Name
            ToName             = $eligible.Name
            SuggestionName     = $null
            SuggestionBucket   = $null
            SuggestionResetsAt = $null
        }
    }

    # No eligible peer. Find the soonest FUTURE reset across all slots
    # and both buckets; that is the moment at which auto-rotation can
    # next return something other than 'no-eligible'. Used by the
    # watch loop's "[Monitor] No free slot available! Cooling down for
    # <delta>" footer line.
    $soonestSlot   = $null
    $soonestBucket = $null
    $soonestTime   = $null

    foreach ($r in $results) {
        if (-not $r.Data) { continue }
        foreach ($pair in @(
            @{ Key = 'five_hour'; Label = 'Session' },
            @{ Key = 'seven_day'; Label = 'Week'    }
        )) {
            $bucket = $r.Data.($pair.Key)
            if (-not $bucket -or -not $bucket.resets_at) { continue }
            $t = ConvertTo-DateTimeOffsetOrNull $bucket.resets_at
            if ($null -eq $t)        { continue }
            if ($t -le $nowUtc)      { continue }
            if ($null -eq $soonestTime -or $t -lt $soonestTime) {
                $soonestTime   = $t
                $soonestSlot   = $r.Name
                $soonestBucket = $pair.Label
            }
        }
    }

    return [pscustomobject]@{
        Action             = 'no-eligible'
        FromName           = $activeRow.Name
        ToName             = $null
        SuggestionName     = $soonestSlot
        SuggestionBucket   = $soonestBucket
        SuggestionResetsAt = if ($soonestTime) { $soonestTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
    }
}

# Pull the max(five_hour, seven_day) utilization from a snapshot row. Shared
# by auto-rotation (Get-AutoRotationDecision) and keep-warm eligibility
# (Test-WarmEligible) so "this slot is at limit" has exactly one definition.
#
# Judged on $Row.Data whenever it is present, regardless of Status. That
# matches Format-UsageTable, which already renders bucket percentages from
# Data alone: a row good enough to show numbers to the user is good enough to
# decide on. Rows with no Data (including every hard HTTP failure) return 0%,
# as do null/missing buckets, matching Get-PlanStatus's 'ok (no plan data)'
# tier; an account that has not made a live API call yet is by definition not
# utilized. Callers that must distinguish "0% because idle" from "0% because
# unreadable" check $Row.Data themselves.
#
# A bucket whose window has rolled never reaches here: Select-LiveBuckets
# removes it at New-UsageResult, so "missing" already covers "obsolete" and
# this function does not re-test resets_at. Keeping a second copy of that rule
# here is what let this function and the renderers disagree about one row.
#
# Format-WatchTitle and Get-PlanStatus keep their own bucket walking; their
# semantics differ (Format-WatchTitle preserves nulls for display).
function Get-RowMaxUtilization {
    Param ([Parameter(Mandatory)] [pscustomobject] $Row)

    if (-not (Test-RowHasUsableData -Row $Row)) { return 0.0 }

    $five  = Get-BucketUtilizationOrZero -Bucket $Row.Data.five_hour
    $seven = Get-BucketUtilizationOrZero -Bucket $Row.Data.seven_day
    if ($five -ge $seven) { return $five }
    return $seven
}

# Utilization of one usage bucket, or 0 when it is missing or carries no
# utilization. Extracted so Get-RowMaxUtilization reads as the max of two
# comparable numbers instead of two inline ternaries. A rolled window is
# already absent by the time a row exists; see Select-LiveBuckets.
function Get-BucketUtilizationOrZero {
    Param ([AllowNull()] $Bucket)

    if (-not $Bucket -or $null -eq $Bucket.utilization) { return 0.0 }
    return [double]$Bucket.utilization
}

# Render a positive future reset duration as a compact "Xh Ym" / "Xm"
# string for the [Monitor] "Cooling down for <delta>" footer line. Uses
# Format-ResetDelta's shape with the surrounding parentheses stripped
# (parentheses are a table-cell convention; the footer reads as prose).
#
# Output (matches Format-ResetDelta's value semantics, minus the parens):
#   null / parse fail               -> 'unknown'  (defensive; never throws)
#   non-positive (already past)     -> 'less than a minute'
#   < 1 hour                        -> '42m'
#   >= 1 hour and < 24 hours        -> '2h 14m'
#   >= 24 hours                     -> '42h'
function Format-AutoCooldownDelta {
    Param ($ResetsAt)

    $target = ConvertTo-DateTimeOffsetOrNull $ResetsAt
    if ($null -eq $target) { return 'unknown' }

    $delta = $target - [DateTimeOffset]::UtcNow
    if ($delta.TotalSeconds -le 0) { return 'less than a minute' }

    if ($delta.TotalHours -ge 24) {
        $h = [int][math]::Floor($delta.TotalHours)
        return "${h}h"
    }

    $h = [int]$delta.Hours
    $m = [int]$delta.Minutes
    if ($h -gt 0) { return "${h}h ${m}m" }
    return "${m}m"
}

# Per-poll auto-rotation step for the watch loop's -Auto mode. Wraps:
#
#   1. Get-AutoRotationDecision (pure) to classify the active slot's
#      state against -Threshold.
#   2. Re-check Test-ClaudeRunning before any rotation (covers the
#      "Claude Code launched after -Auto started" race; the pre-loop
#      guard in Invoke-UsageWatch only fires once at startup).
#   3. Find-SlotByName + Invoke-SlotSwap when a peer is eligible.
#   4. Map the outcome to a single-line latched footer string that
#      Invoke-UsageWatch appends to every subsequent frame until the
#      next state change.
#
# Returns the new footer-latch string. Never throws: any exception from
# the swap path is caught and rendered as '[Monitor] Rotation failed! …'
# so the watch loop never aborts because of an auto-rotation issue.
#
# -CurrentLatch carries the previous frame's latched string. Used for
# two distinct cases:
#   * Decision 'noop' AND no prior rotation event: preserves the
#     initial $Script:MonitorSteadyLatch line (or whatever steady-state
#     caller supplied).
#   * Decision 'noop' AFTER a prior rotation: the 'Rotated …' line
#     stays latched. The user choice (this conversation) was that
#     transition lines stay visible until the next state change, not
#     revert to the steady-state line on every tick.
#
# All [Monitor] lines start with a capital letter per the user's locked
# convention.

# The two latched [Monitor] lines that describe a state rather than an event.
# Constants because this function has to both write the paused line and
# recognise it later: a latch is only safe to clear if the code clearing it
# agrees, character for character, with the code that set it.
$Script:MonitorSteadyLatch       = '[Monitor] Automatic slot switching is enabled.'
$Script:MonitorPausedLatchPrefix = '[Monitor] Active slot usage unknown'

function Invoke-AutoRotationStep {
    Param (
        [Parameter(Mandatory)] [pscustomobject] $Snapshot,
        [Parameter(Mandatory)] [int]            $Threshold,
        [AllowNull()] [AllowEmptyString()] [string] $CurrentLatch
    )

    $decision = Get-AutoRotationDecision -Snapshot $Snapshot -Threshold $Threshold

    switch ($decision.Action) {
        'noop' {
            # No state change, so the caller's latch stands: on the first tick
            # that is the initialiser, after a rotation it is the 'Rotated
            # A -> B at HH:mm:ss' line, and transition lines stay visible until
            # the next state change.
            #
            # One exception: a paused latch describes a state we are no longer
            # in. Reaching 'noop' means the active slot was read and judged, so
            # leaving "rotation paused" on screen would report a blind monitor
            # that is in fact armed -- the same lie as the stale 'Rotated' line
            # the paused arm was added to prevent, pointing the other way.
            if ($CurrentLatch -and $CurrentLatch.StartsWith($Script:MonitorPausedLatchPrefix)) {
                return $Script:MonitorSteadyLatch
            }
            return $CurrentLatch
        }

        'active-unknown' {
            # Rotation has nothing to judge and deliberately does not fire
            # (moving off a possibly-fine slot on no evidence would burn a
            # healthy account). Must NOT fall through to $CurrentLatch: a
            # latched 'Rotated ...' line would leave a blind, inert monitor
            # looking like a working one.
            return ('{0} ({1}); rotation paused.' -f $Script:MonitorPausedLatchPrefix, $decision.ActiveStatus)
        }

        'rotate' {
            # Per-rotation Test-ClaudeRunning re-check. The pre-loop
            # guard caught the startup case; this catches the "Claude
            # Code launched mid-watch" race. Surface the refusal as
            # a [Monitor] line; the credentials swap does NOT happen.
            if (Test-ClaudeRunning) {
                return '[Monitor] Rotation refused! Claude Code is running.'
            }

            try {
                $slot = Find-SlotByName -Name $decision.ToName
                if (-not $slot) {
                    # Sidecar disappeared between snapshot and lookup.
                    # Rare; surfaces as a 'Rotation failed' line.
                    return "[Monitor] Rotation failed! Slot '$($decision.ToName)' not found (or missing its identity sidecar)."
                }
                Invoke-SlotSwap -Slot $slot 6>$null
                $ts = [DateTime]::Now.ToString('HH:mm:ss')
                return ('[Monitor] Rotated from "{0}" to "{1}" at {2}' -f $decision.FromName, $decision.ToName, $ts)
            }
            catch {
                # Collapsed before interpolating: Format-UsageFooter splits the
                # footer on newlines to colour each entry, so a multi-line
                # exception would fork this one line into several unprefixed
                # ones. Same reason as the [Watch] poll-failure line.
                return "[Monitor] Rotation failed! $(Format-StatusErrorTail -Message $_.Exception.Message)"
            }
        }

        'no-eligible' {
            # All peers also at or above threshold. Suggest the soonest
            # reset across all slots and buckets so the user has a
            # concrete cooldown ETA.
            if ($decision.SuggestionResetsAt) {
                $delta = Format-AutoCooldownDelta $decision.SuggestionResetsAt
                return ('[Monitor] No free slot available! Cooling down for {0}.' -f $delta)
            }
            # No future reset across any slot is rare (would mean every
            # bucket has resets_at=null, i.e. no slot has made a live
            # API call yet). Give the user a short message rather than
            # interpolating a useless 'unknown'.
            return '[Monitor] No free slot available! Waiting for the next poll.'
        }

        default {
            # Unknown action label. Defensive; surface as a no-op so
            # the loop keeps running.
            return $CurrentLatch
        }
    }
}

# Minimum poll interval for -Watch. Matches the default so users can only
# adjust the interval upward; the floor is the "polite" setting for the
# unofficial endpoint and we refuse to go faster. Clamping up (rather
# than throwing) keeps the call ergonomic for users who just typed a
# round number.
$Script:UsageWatchMinInterval = 60

# How soon to re-poll after a warmup pass that ended with rate-limited
# rows. The 429 cooldown is short, so a quick second poll usually returns
# real data instead of leaving the user staring at em-dash cells for a
# full -Interval. See Get-EarlyRepollLastPoll for how this maps onto the
# loop's elapsed-since-last-poll trigger.
$Script:WarmupRepollDelaySec  = 10

# Inter-slot spacing during the warmup loop. After each slot is
# activated, sleep this many milliseconds before moving to the next.
# Cheap insurance against per-IP burst rate-limits: a small gap between
# `claude -p` spawns keeps a pool well under typical burst thresholds
# while adding only ~300 ms * (N-1) of startup latency. Tunable for
# tests (Common.ps1 overrides to zero).
$Script:WarmupSpacingMs    = 300

# Minimum minutes between re-warms of the SAME slot in a `monitor -KeepWarm`
# session; in-memory per session (Invoke-UsageWatch), never persisted to
# .sca-state.json. Rationale for the cooldown lives at Invoke-KeepWarmStep.
# Tunable for tests (Common.ps1 overrides to zero).
$Script:WarmupCooldownMin  = 5

# Slot activator (`claude -p`) settings. Warmup opens a slot's 5h session
# window by running the real Claude Code CLI as that slot, exactly as a
# user typing one message would (Invoke-SlotActivator). This delegates the
# OAuth token refresh to Claude Code's own canonical flow instead of
# re-implementing it, and removes any doubt about whether a minimal request
# "counts" as opening the window (a real one-turn message always does).
#   --safe-mode      keeps OAuth auth but disables CLAUDE.md / MCP / hooks /
#                    plugins / skills, so the activation cannot trigger this
#                    repo's own Claude config and stays cheap (no project
#                    context loaded). (NOT --bare: that never reads OAuth.)
#   --model haiku    cheapest current model; ~$0.004 per activation.
#   --output-format json  structured {type,subtype,is_error,result,...} so
#                    Invoke-SlotActivator can classify success vs failure.
#   --no-session-persistence  no session files written to disk.
# Model alias drifts when Anthropic deprecates Haiku; bump it then.
$Script:ActivatorModel      = "haiku"
$Script:ActivatorPrompt     = "Hi"
$Script:ActivatorTimeoutSec = 90

# Warmup-as-swap-then-activate orchestrator for `sca warmup` and
# `sca monitor -KeepWarm`. Round-robins through every saved slot in
# alphabetical order: per slot, Invoke-SlotSwap makes it active (writes
# .credentials.json AND ~/.claude.json's oauthAccount AND state.active_slot)
# and Invoke-SlotActivator runs the real Claude Code CLI (`claude -p`) as
# that slot so Anthropic opens a server-side 5h session window. Either
# throwing collapses into Status='error' on the row; the loop continues
# with the remaining slots.
#
# Why a real `claude -p` instead of an /api/oauth/usage probe: a slot's
# /api/oauth/usage returns empty bucket data (or 429) until a server-side
# 5h session window has been opened, which only a billable message can do.
# Running claude (rather than re-implementing the request) delegates the
# OAuth refresh to Claude Code's own flow and is exactly what a user does
# by hand. Cost: ~$0.004 per slot per warmup on the pinned Haiku model.
#
# Mirror-then-verify (only after an 'ok' activation):
#   1. Invoke-Reconcile copies the (possibly refreshed) tokens claude just
#      wrote into .credentials.json back into the slot file. This MUST run
#      before the usage read: otherwise Get-SlotUsage reads the slot's
#      stale pre-activation token and triggers sca's own refresh against
#      the (sometimes throttled) token endpoint -- the exact amplification
#      this design removes. The reconcile takes the same-identity mirror
#      branch (the swap wrote this slot's email to ~/.claude.json), so it
#      never auto-saves.
#   2. Get-SlotUsage reads /api/oauth/usage with the fresh token so the
#      warmup frame shows live percentages immediately instead of
#      'ok (no plan data)' until the first poll ~60 s later.
# A failed activation (rate-limited / unauthorized / expired / no-oauth /
# error) skips both the mirror and the usage read -- no token to refresh,
# nothing to verify -- and surfaces the activator's own outcome, so a
# throttled slot incurs zero sca refresh calls.
#
# Builds the rendered snapshot in place: one row per slot (filtered by
# -Names, else -Name, when set), each starting at Status='warming-up' with Data=$null,
# transitioning through 'priming' (the claude -p call in flight) to its
# real outcome. The end state is the first frame of the polling loop; the
# caller wires it to $snapshot and sets $lastPoll = now. Returns $null
# when no slots match.
#
# The original active slot is captured before the loop via Read-ScaState
# + Find-SlotByName. A finally block restores it via one more Invoke-Slot-
# Swap so a clean exit (or Ctrl-C, which still runs finally) returns the
# user where they started. Restore failure logs a yellow advisory naming
# the slot the user is now active on. No active slot captured (fresh
# install, sidecar-hidden active) is fine: the finally guard skips the
# restore and the user ends on the last activated slot.
#
# $Repaint is invoked as: & $Repaint $snapshot. The `claude -p` spawn
# (seconds) naturally floors the 'priming' label's on-screen visibility,
# so no artificial min-visibility sleep is needed.
function Invoke-WarmAllSlots {
    Param (
        [string]                             $Name,
        # -Names: restrict the pass to this set of (already-sanitized) slot
        # names. Used by Invoke-KeepWarmStep to re-warm only the slots whose
        # 5h window has closed mid-watch, reusing this function's swap ->
        # activate -> mirror -> read -> restore machinery for the subset.
        # Takes precedence over -Name when both are supplied. Names come
        # from Get-Slots output (snapshot rows), so no Get-SafeName needed.
        [string[]]                           $Names,
        [Parameter(Mandatory)] [scriptblock] $Repaint
    )

    $slots = @(Get-Slots)
    if ($Names) {
        $slots = @($slots | Where-Object { $Names -contains $_.Name })
    }
    elseif ($Name) {
        $safe  = Get-SafeName $Name
        $slots = @($slots | Where-Object { $_.Name -eq $safe })
    }
    if ($slots.Count -lt 1) { return $null }

    # Each row carries IsCachedFallback / FallbackReason so the verify-after-
    # prime usage read (below) renders through Format-UsageAdvisory exactly as
    # a polling-loop row would.
    $rows = @($slots | ForEach-Object {
        [pscustomobject]@{
            Name             = $_.Name
            Email            = $_.Email
            Path             = $_.Path
            IsActive         = $_.IsActive
            Sidecar          = $_.Sidecar
            Status           = 'warming-up'
            Data             = $null
            Error            = $null
            IsCachedFallback = $false
            # Same shape as Get-UsageSnapshot's rows so every renderer and
            # predicate behaves identically on a warmup frame.
            HttpStatus       = $null
            FallbackReason   = $null
        }
    })
    $snapshot = [pscustomobject]@{
        Results        = $rows
        NoSlots        = $false
        HasRateLimited = $false
    }
    & $Repaint $snapshot

    $origActive = $null
    $state = Read-ScaState
    if ($state -and $state.active_slot) {
        $origActive = Find-SlotByName -Name $state.active_slot
    }

    # Track the slot the process is actually active on. Seeded to
    # $origActive (the active slot before any swap) and advanced only
    # after a successful Invoke-SlotSwap below, so it always names the
    # live active slot even when a mid-loop swap throws (the throw skips
    # the advance and routes to the catch). The restore-failure advisory
    # in the finally reads it, so a double swap failure names the slot
    # the user is genuinely left on rather than blindly assuming rows[-1].
    $lastSwapped = $origActive

    $last = $rows.Count - 1
    try {
        for ($i = 0; $i -le $last; $i++) {
            $row = $rows[$i]
            $row.Status = 'priming'
            & $Repaint $snapshot

            # 6>$null suppresses [Switch] / [Sync] advisories so they
            # don't paint outside the DEC 2026 sync envelope. The try/
            # catch catches Invoke-SlotSwap throws AND defends against
            # any Invoke-SlotActivator contract violation (its documented
            # surface is non-throwing, but defense-in-depth against
            # unexpected exceptions keeps the loop alive for the remaining
            # slots). Normal activation failure modes route through
            # $r.Status (rate-limited / expired / unauthorized / no-oauth /
            # error) without throwing; this catch only fires on actual
            # exceptions.
            try {
                Invoke-SlotSwap -Slot $row 6>$null
                # Swap succeeded (it throws on failure): this slot is now
                # the live active slot. Record it for the restore advisory.
                $lastSwapped = $row
                $r = Invoke-SlotActivator -SlotPath $row.Path 6>$null
                if ($r.Status -eq 'ok') {
                    # Mirror claude's (possibly refreshed) tokens from
                    # .credentials.json back into the slot file BEFORE the
                    # verify read, so Get-SlotUsage reads the fresh token
                    # rather than the slot's stale pre-activation one (which
                    # would trigger sca's own refresh against a possibly
                    # throttled token endpoint). Same-identity mirror only;
                    # never auto-saves (the swap wrote this slot's email to
                    # ~/.claude.json). Then read usage so the warmup frame
                    # shows live percentages immediately instead of
                    # 'ok (no plan data)'. Neither call throws.
                    Invoke-Reconcile 6>$null | Out-Null
                    # Drop any backoff stamp first: a successful activation is
                    # evidence the throttle may be over, and the verify read
                    # must probe live rather than be short-circuited by the
                    # backoff it is recovering from.
                    Clear-SlotRateLimitBackoff -SlotPath $row.Path
                    $u = Get-SlotUsage -SlotPath $row.Path 6>$null
                    $row.Status           = $u.Status
                    $row.Data             = $u.Data
                    $row.Error            = $u.Error
                    $row.IsCachedFallback = [bool]$u.IsCachedFallback
                    $row.HttpStatus       = $u.HttpStatus
                    $row.FallbackReason   = $u.FallbackReason
                }
                else {
                    # Activation failed (rate-limited / unauthorized /
                    # expired / no-oauth / error): surface its real outcome;
                    # a usage read would not add signal and a throttled slot
                    # must not incur extra refresh calls.
                    $row.Status = $r.Status
                    $row.Error  = $r.Error
                }
            }
            catch {
                $row.Status = 'error'
                $row.Error  = $_.Exception.Message
            }

            # Recomputed per slot rather than once at the end so the flag is
            # already accurate at each repaint, and on an early return.
            # Format-UsageAdvisory partitions the rows itself and needs nothing
            # from here.
            $snapshot.HasRateLimited = (@($rows | Where-Object { $_.Status -eq 'rate-limited' }).Count -gt 0)
            & $Repaint $snapshot

            if ($i -lt $last -and $Script:WarmupSpacingMs -gt 0) {
                Start-Sleep -Milliseconds $Script:WarmupSpacingMs
            }
        }
    }
    finally {
        if ($origActive) {
            try { Invoke-SlotSwap -Slot $origActive 6>$null }
            catch { Write-Color "[Warmup] Restore of original active slot '$($origActive.Name)' failed: $($_.Exception.Message). You are now active on '$($lastSwapped.Name)'." 'Yellow' 6>$null }
        }
    }
    return $snapshot
}

# Pure predicate deciding whether the keep-warm step should re-open a slot's
# 5h window this tick. Extracted from Invoke-KeepWarmStep so the policy is
# unit-testable without the swap / activate / mirror orchestration. $Now is
# the current UTC instant (passed in for determinism).
#
# A slot already at limit is never eligible: warming opens the 5h window, and
# a window that is open and full has nothing to gain from a billable
# `claude -p`. Checked FIRST so it also gates the rate-limited branch, which
# is where an exhausted slot usually shows up. Shares Get-RowMaxUtilization
# with auto-rotation so "at limit" means the same thing to both, which is also
# what keeps warm-eligible and rotation-source sets disjoint.
#
# Otherwise: a 'rate-limited' slot is eligible (a real `claude -p` can clear
# the throttle); an 'ok' slot only once its five_hour window is closed (a
# mid-window slot carries a FUTURE resets_at). Hard-fail rows (expired /
# unauthorized / no-oauth / error) are not: a billable `claude -p` would
# not fix them.
function Test-WarmEligible {
    Param (
        [Parameter(Mandatory)] [pscustomobject] $Row,
        [Parameter(Mandatory)] [DateTimeOffset] $Now,
        [Parameter(Mandatory)] [int]            $Threshold
    )

    if ((Get-RowMaxUtilization -Row $Row) -ge $Threshold) { return $false }

    if ($Row.Status -eq 'rate-limited') { return $true }
    if ($Row.Status -ne 'ok')          { return $false }

    $reset = $null
    if ($Row.Data -and $Row.Data.five_hour) {
        $reset = ConvertTo-DateTimeOffsetOrNull $Row.Data.five_hour.resets_at
    }
    return -not ($null -ne $reset -and $reset -gt $Now)
}

# Per-poll keep-warm step for `sca monitor -KeepWarm`. Mirrors
# Invoke-AutoRotationStep: returns the footer-latch string the watch loop
# appends to every frame until the next state change. Via Invoke-WarmAllSlots
# it re-opens the 5h window of every Test-WarmEligible slot whose window has
# closed since the startup pass. Without this the startup pass alone would let
# every slot expire ~5h in and stay dark for the rest of the watch.
#
# $WarmupTimes (slot name -> last attempt) gates retries to one per
# $Script:WarmupCooldownMin, stamped on every attempt. It only bounds the
# pathological FAILED-warm case: a successful warm pushes resets_at ~5h out,
# so the closed-window check holds a healthy slot off on its own.
#
# Re-checks Test-ClaudeRunning per tick (the swap writes ~/.claude.json), same
# rationale as Invoke-AutoRotationStep. Re-warmed rows are NOT merged back into
# $Snapshot; the next poll re-reads /api/oauth/usage. Never throws: a warm-path
# exception surfaces as a '[Warmup] Re-warm failed! ...' line.
# -Threshold is mandatory rather than defaulted: it must be the SAME value
# auto-rotation uses, and the caller always has it. A default here would let a
# wiring mistake silently disable the at-limit skip instead of failing loudly.
function Invoke-KeepWarmStep {
    Param (
        [Parameter(Mandatory)] [pscustomobject] $Snapshot,
        [Parameter(Mandatory)] [hashtable]      $WarmupTimes,
        [Parameter(Mandatory)] [int]            $Threshold,
        [int]                                   $CooldownMin = $Script:WarmupCooldownMin,
        [AllowNull()] [AllowEmptyString()] [string] $CurrentLatch
    )

    if (-not $Snapshot -or $Snapshot.NoSlots) { return $CurrentLatch }
    $results = @($Snapshot.Results)
    if ($results.Count -eq 0) { return $CurrentLatch }

    $now    = [DateTime]::Now
    $nowUtc = [DateTimeOffset]::UtcNow
    $cold   = @(
        foreach ($r in $results) {
            if (-not (Test-WarmEligible -Row $r -Now $nowUtc -Threshold $Threshold)) { continue }

            $last = $WarmupTimes[$r.Name]
            if ($last -and ($now - $last).TotalMinutes -lt $CooldownMin) { continue }

            $r.Name
        }
    )

    if ($cold.Count -eq 0) {
        # Nothing eligible this tick. If a throttled slot is just held off by
        # its cooldown, say so rather than claim "Keeping all slots warm." (the
        # yellow advisory above the table already names the affected slots).
        $limited = @($results | Where-Object { $_.Status -eq 'rate-limited' })
        if ($limited.Count -gt 0) {
            # Split by WHY, because the two have different recoveries and only
            # one of them is the cooldown. A throttled slot whose cached numbers
            # are at or above -Threshold is held off by Test-WarmEligible's
            # at-limit gate, not by $CooldownMin: warming re-opens a window that
            # is already full, so waiting out the cooldown changes nothing and
            # only the next window reset will.
            $waiting = @($limited | Where-Object { (Get-RowMaxUtilization -Row $_) -lt $Threshold })
            if ($waiting.Count -gt 0) {
                return '[Warmup] Rate-limited; will re-warm when cooldown clears.'
            }
            return '[Warmup] Rate-limited at the rotation threshold; will re-warm after the next window reset.'
        }
        return $CurrentLatch
    }

    if (Test-ClaudeRunning) {
        return '[Warmup] Re-warm refused! Claude Code is running.'
    }

    $list = ($cold | Sort-Object | ForEach-Object { "'$_'" }) -join ', '
    try {
        # 6>$null: suppress Invoke-WarmAllSlots's nested advisories so they
        # don't paint outside the watch loop's sync envelope (matches
        # Invoke-AutoRotationStep). No-op repaint: the loop's own redraw
        # covers the table; only the footer latch reports the event.
        Invoke-WarmAllSlots -Names $cold -Repaint { Param ($snap) } 6>$null | Out-Null
        foreach ($n in $cold) { $WarmupTimes[$n] = $now }
        return "[Warmup] Re-warmed $list at $($now.ToString('HH:mm:ss'))"
    }
    catch {
        # Stamp the attempt anyway so a hard failure does not re-fire every
        # poll; the cooldown then holds the slot off until it likely recovers.
        foreach ($n in $cold) { $WarmupTimes[$n] = $now }
        # Collapsed for the same reason as the [Monitor] rotation-failure line:
        # this string becomes one footer entry, and Format-UsageFooter splits
        # the footer on newlines.
        return "[Warmup] Re-warm failed! $(Format-StatusErrorTail -Message $_.Exception.Message)"
    }
}

# Compute the $lastPoll value that schedules the next watch poll roughly
# $DelaySec from now. The watch loop polls when (now - $lastPoll) >=
# $Interval, so to fire $DelaySec out we must rewind by ($Interval -
# $DelaySec), NOT by $DelaySec. Clamped at 0 so a $DelaySec >= $Interval
# never pushes $lastPoll into the future (which would DELAY the poll);
# at the clamp the loop polls immediately. Pure; unit-tested in
# Helpers.Tests.ps1.
function Get-EarlyRepollLastPoll {
    Param (
        [DateTime] $Now,
        [int]      $Interval,
        [int]      $DelaySec
    )
    return $Now.AddSeconds(-[Math]::Max(0, $Interval - $DelaySec))
}

# Live `sca usage -Watch` loop: redraws once per second and re-polls the
# endpoint every -Interval seconds. The redraw cadence is decoupled from
# the poll cadence so the frame self-heals on terminal resize within
# ~1 s instead of waiting up to -Interval seconds for the next poll.
# Interactive only; throws when output is redirected because the
# alt-screen + cursor-control sequences would poison a captured log.
# Exits on Ctrl-C via the runtime's default handler; the `finally`
# block leaves the alternate screen buffer and restores cursor
# visibility. On HTTP failure the previous snapshot stays visible and
# an advisory is appended to the footer so the display never blanks.
#
# Flicker-free rendering. Each frame is rendered to a string
# (Get-WatchFrameText), then painted in a single write as cursor-home
# (ESC[H) + per-line erase-to-EOL (ESC[K) + trailing erase-below (ESC[0J)
# via ConvertTo-WatchFrameSequence, wrapped in the DEC 2026 sync envelope
# (ESC[?2026h … ESC[?2026l). The frame is overwritten in place and never
# blanked to black -- there is no ESC[2J -- so even when the terminal
# lacks DEC 2026 or is too loaded to honor it, a render tick that lands
# mid-paint shows the previous (near-identical) frame underneath instead
# of the "black -> row for row" flash a clear-then-redraw produces. This
# is the ANSI equivalent of how PSReadLine / SetBufferContents repaint:
# overwrite in place, never clear. DEC 2026 (Win Terminal >= 1.23, VS
# Code, iTerm2, kitty, alacritty, WezTerm, foot, gnome-terminal, mintty,
# modern ConHost) is now a bonus tier that also suppresses sub-frame
# tearing on capable terminals; older terminals ignore the unknown DEC
# private mode with no regression. The watch also enters the alternate
# screen buffer (ESC[?1049h) so the pre-watch terminal scrollback is
# restored on exit, mirroring how top / htop / vim behave. Renderer
# functions are reused unchanged; this loop captures and repaints them.
#
# VT control sequences (alt buffer, sync mode, cursor hide/show, home,
# erase) are emitted via `Write-VTSequence` so they bypass the
# `Write-Host` -> `StringDecorated.AnsiRegex` filter that
# `OutputRendering = 'PlainText'` (set by `-NoColor` / `NO_COLOR`)
# applies. The filter strips DEC private modes (`ESC[?...h/l`) including
# the DEC 2026 envelope and the `ESC[?1049h` alt-buffer toggle, which
# would re-introduce the pre-36e5e27 flicker. Body color SGR keeps
# flowing through `Write-Color` -> `Write-Host` so `PlainText` correctly
# strips body color in `-NoColor` mode. See `Write-VTSequence` docblock
# for the verified mechanism.
#
# The loop is deliberately simple: blocking Invoke-RestMethod (via
# Get-UsageSnapshot) inside the poll step, then a plain 1 s sleep
# between frames. A runspace-based async poll would feel snappier
# during the HTTP call but adds substantial complexity that is not
# worth v1's budget.
function Invoke-UsageWatch {
    Param (
        [String] $Name,
        [int]    $Interval = $Script:UsageWatchMinInterval,
        # -Auto: auto-rotate to the next eligible slot when the active
        # slot's max(five_hour, seven_day) utilization reaches -Threshold.
        # See Get-AutoRotationDecision for the rotation logic and the
        # comments inside the watch loop for the per-tick mechanics.
        [switch] $Auto,
        # -Threshold: utilization percentage (1..100) at or above which
        # -Auto fires a rotation. Ignored when -Auto is absent.
        [int]    $Threshold = 95,
        # -Warmup: keep every saved slot warm for the life of the watch.
        # The startup pass (Invoke-WarmAllSlots, below the alt-screen entry)
        # activates every slot via the real Claude Code CLI (`claude -p`)
        # before the first poll; thereafter Invoke-KeepWarmStep re-opens any
        # slot whose 5h window has closed at each poll boundary. Driven only
        # by `sca monitor -KeepWarm` (which always sets -Auto too).
        [switch] $Warmup
    )

    # Pre-loop Claude Code guard for -Auto and -Warmup. Both write
    # ~/.claude.json's oauthAccount block via Invoke-SlotSwap (-Auto
    # during the in-loop rotation step; -Warmup during the per-slot
    # swap-then-activate round-robin). Claude Code keeps that block in an
    # in-memory cache; racing its flush would clobber our update. The
    # short-lived `claude -p` the warmup spawns is awaited to exit before
    # the next swap, so it never overlaps a file write.
    # Same guard / wording as Invoke-SwitchAction so the user sees a
    # consistent message regardless of entry point. Only `sca monitor`
    # reaches this branch ($Auto is always set by Invoke-MonitorAction;
    # `usage -Watch` is read-only and sets neither switch). -Auto
    # additionally re-checks Test-ClaudeRunning before every rotation
    # attempt to cover the "Claude Code launched mid-watch" race;
    # -Warmup's window is short enough (one round-robin pass) that the
    # pre-loop check is the only one needed.
    # Checked BEFORE the IsOutputRedirected guard so the user sees the
    # more actionable "close Claude Code" message rather than the
    # interactive-terminal one (which the test harness always hits).
    if (($Auto -or $Warmup) -and (Test-ClaudeRunning)) {
        throw "Claude Code is running. Close it before 'sca monitor' so the credentials swap applies cleanly without racing Claude Code's in-memory ~/.claude.json cache."
    }

    if ([Console]::IsOutputRedirected) {
        throw "-Watch requires an interactive terminal; for scripted output use 'sca usage -Json'."
    }

    if ($Interval -lt $Script:UsageWatchMinInterval) {
        Write-Color "[Usage] -Interval below minimum; clamping to $($Script:UsageWatchMinInterval)s (polite to the unofficial endpoint)." 'Yellow'
        $Interval = $Script:UsageWatchMinInterval
    }

    $origCursor = [Console]::CursorVisible
    # Capture the pre-watch console output encoding. The frame body is
    # painted via Write-VTSequence -> [Console]::Out.Write, which encodes
    # the string through [Console]::OutputEncoding; on Windows that defaults
    # to a legacy OEM codepage (e.g. CP850) that cannot represent the bar
    # glyphs (█ ▓), the auto-mode glyph (▶), the ellipsis (…), or the em
    # dash (—), so they render as '?'. Write-Host did not hit this because
    # the PowerShell host writes UTF-16 to the console (WriteConsoleW),
    # bypassing the codepage. Forcing UTF-8 for the watch's duration makes
    # [Console]::Out.Write emit those glyphs correctly; the finally restores
    # the original encoding so the user's post-watch shell is unaffected.
    $origEncoding = [Console]::OutputEncoding
    # Capture the pre-watch terminal title so the `finally` block can
    # restore it on Ctrl-C. $Host.UI.RawUI.WindowTitle is the only
    # portable read path (no terminal protocol reliably reports the
    # current OSC 0 title back). Some hosts throw when RawUI is not
    # available (test runners, ssh-without-tty); $null then signals
    # "no restore" to the finally block.
    $origTitle  = try { $Host.UI.RawUI.WindowTitle } catch { $null }
    $enteredAlt = $false
    try {
        # UTF-8 so [Console]::Out.Write renders the non-ASCII frame glyphs
        # (see $origEncoding capture above). Wrapped in try so a host that
        # forbids the change (rare) does not abort the watch; the glyphs
        # would degrade to '?' but the loop still runs.
        try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { Write-Verbose "UTF-8 console encoding not settable: $_" }
        # Enter alt screen buffer + hide cursor in one write. The alt
        # buffer gives a clean canvas and ensures the user's pre-watch
        # scrollback is restored on exit. Cursor-hide stops the caret
        # from blinking inside the table during the (atomic) repaint.
        Write-VTSequence "`e[?1049h`e[?25l"
        $enteredAlt = $true
        [Console]::CursorVisible = $false

        $snapshot      = $null
        $lastPoll      = [DateTime]::MinValue
        $lastPollError = $null

        # -Auto footer-line latch. Updated at each poll boundary based on
        # Get-AutoRotationDecision's verdict; the latched string is
        # appended (in DarkGray, like the [Watch] lines) to every frame
        # until the next state change. Initial value 'Enabled' shows the
        # mode is engaged before the first rotation event.
        $lastAutoFooter = if ($Auto) { $Script:MonitorSteadyLatch } else { $null }

        # -Warmup footer-line latch + per-slot last-re-warm map. The latch
        # parallels $lastAutoFooter (steady-state line until a keep-warm
        # event replaces it). $warmupTimes (slot name -> last attempt
        # [DateTime]) lives only for this watch session and feeds the
        # cooldown gate in Invoke-KeepWarmStep; it is never persisted.
        $lastWarmupFooter = if ($Warmup) { '[Warmup] Keeping all slots warm.' } else { $null }
        $warmupTimes      = @{}

        # -Warmup startup pass. Invoke-WarmAllSlots does the per-slot
        # swap-then-activate round-robin and returns a populated snapshot
        # we hand off to the polling loop as its first frame ($lastPoll
        # = now so the loop's first iteration falls into the redraw
        # branch, not the poll branch). Reconcile first so a cross-
        # account swap landed since the last sca call is captured before
        # any slot bytes are read; matches the polling loop's per-poll
        # contract below.
        if ($Warmup) {
            Invoke-Reconcile 6>$null | Out-Null

            # -Auto's right-aligned "▶ switching slot at N%" header
            # indicator stays off when -Auto is absent.
            $autoHeader = if ($Auto) { $Threshold } else { 0 }
            $snapshot = Invoke-WarmAllSlots -Name $Name -Repaint {
                Param ($snap)
                $startupFooter = ''
                if ($lastAutoFooter)   { $startupFooter = $lastAutoFooter + "`n" }
                if ($lastWarmupFooter) { $startupFooter += $lastWarmupFooter }
                # Same in-place-overwrite single-write paint as the polling
                # loop (no ESC[2J); the alt buffer is already blank on entry,
                # so the first warmup repaint has nothing stale to clear and
                # each subsequent per-slot repaint overwrites in place.
                $frameText = Get-WatchFrameText {
                    Format-UsageFrame -Name $Name -Snapshot $snap -Footer $startupFooter -AutoThreshold $autoHeader
                }
                Write-VTSequence ("`e[?2026h" + (ConvertTo-WatchFrameSequence $frameText) + "`e[?2026l")
            }
            if ($null -ne $snapshot) {
                $lastPoll = [DateTime]::Now
                try {
                    Write-VTSequence ("`e]0;{0}`a" -f (Format-WatchTitle -Name $Name -Snapshot $snapshot -Aggregate:$Auto))
                } catch { Write-Verbose "Warmup title set deferred: $_" }
            }
            # If warmup ended with rate-limited rows, the user sees dashes
            # for the full poll interval. Schedule an early repoll
            # ~$Script:WarmupRepollDelaySec from now (regardless of
            # -Interval) so the short 429 cooldown likely clears and real
            # data appears sooner. If the early repoll also gets 429,
            # $lastPoll resets to now and we fall back to the normal
            # interval — no worse than current behaviour.
            if ($snapshot -and $snapshot.HasRateLimited) {
                $lastPoll = Get-EarlyRepollLastPoll -Now ([DateTime]::Now) -Interval $Interval -DelaySec $Script:WarmupRepollDelaySec
            }

            # Seed the cooldown map with the startup pass: every slot just
            # warmed counts as a re-warm at "now", so a slot whose startup
            # verify-read failed/lagged (still reporting a closed window) is
            # not immediately re-warmed on the first poll. The closed-window
            # check covers the healthy slots; this covers the laggy ones.
            if ($null -ne $snapshot) {
                $seed = [DateTime]::Now
                foreach ($r in @($snapshot.Results)) { $warmupTimes[$r.Name] = $seed }
            }
        }

        while ($true) {
            $now = [DateTime]::Now
            $dueForPoll = ($null -eq $snapshot) -or (($now - $lastPoll).TotalSeconds -ge $Interval)

            if ($dueForPoll) {
                try {
                    # Reconcile at every poll boundary so a refresh that
                    # happened since the last poll is captured into the
                    # tracked slot before we read its bytes for the
                    # /api/oauth/usage call. Suppressed stdout; any
                    # advisory the reconcile emits would print straight to
                    # the alt buffer (outside the captured frame) and the
                    # in-place repaint would not overwrite it cleanly anyway.
                    Invoke-Reconcile 6>$null | Out-Null
                    # 6>$null on Get-UsageSnapshot: Update-SlotTokens
                    # (called via Get-SlotUsage when a token is within 60s
                    # of expiry) emits yellow [Sync] advisories on its two
                    # unhappy paths (propagation-to-.credentials.json
                    # failure, or active slot sidecar-orphaned). Those
                    # Write-Host calls would print to the alt buffer outside
                    # the captured frame and linger (the in-place repaint
                    # overwrites only the cells the frame occupies, never
                    # ESC[2J-clears), producing a stray line the user cannot
                    # dismiss. Suppress
                    # them here; the user still sees the same condition
                    # in non-watch contexts (`sca usage`, `sca list`).
                    # Matches the Invoke-Reconcile 6>$null above and the
                    # Invoke-SlotSwap 6>$null inside Invoke-AutoRotationStep.
                    $snapshot      = Get-UsageSnapshot -Name $Name 6>$null
                    $lastPollError = $null

                    # Update the terminal title only on a successful poll;
                    # on a failed poll the previous title (and body) persist
                    # together until the next tick. OSC 0 ('ESC ] 0 ; <title>
                    # BEL') sets both window and icon title; supported by
                    # Windows Terminal, modern ConHost, VS Code, iTerm2,
                    # kitty, alacritty, WezTerm, foot, gnome-terminal,
                    # mintty. Routed through Write-VTSequence for parity
                    # with DEC sequences (bypasses the
                    # OutputRendering=PlainText filter; see Write-VTSequence
                    # docblock).
                    # -Aggregate is tied to -Auto: in -Auto mode the
                    # active slot moves under the user as the script
                    # rotates, so the active-slot title loses signal;
                    # pool-mean matches the aggregate bars rendered
                    # above the table. Bare -Watch keeps the per-slot
                    # alarm-glance title. See Format-WatchTitle docblock.
                    Write-VTSequence ("`e]0;{0}`a" -f (Format-WatchTitle -Name $Name -Snapshot $snapshot -Aggregate:$Auto))

                    # Auto-rotation decision happens after each successful
                    # poll. The latched footer string is updated based on
                    # the decision so it stays visible until the next
                    # state change (the next 'rotate' / 'no-eligible'
                    # outcome). Failures inside the swap are caught and
                    # surfaced as 'Rotation failed!' / 'Rotation refused!'
                    # lines; the loop never aborts because of an auto-
                    # rotation issue (user can still quit with Ctrl-C
                    # and inspect the table).
                    if ($Auto) {
                        $lastAutoFooter = Invoke-AutoRotationStep -Snapshot $snapshot -Threshold $Threshold -CurrentLatch $lastAutoFooter
                    }

                    # Keep-warm decision after auto-rotation so the slot
                    # Invoke-WarmAllSlots restores to is the post-rotation
                    # active one. Keep-warm and rotation cannot fight over a
                    # slot: both gate on Get-RowMaxUtilization against the same
                    # -Threshold, and Test-WarmEligible skips anything at or
                    # above it, so a rotation source is never warm-eligible.
                    # Re-opens any slot whose 5h window has closed; the latched
                    # footer reports it.
                    if ($Warmup) {
                        $lastWarmupFooter = Invoke-KeepWarmStep -Snapshot $snapshot -WarmupTimes $warmupTimes `
                                                               -Threshold $Threshold -CurrentLatch $lastWarmupFooter
                    }
                }
                catch {
                    # Keep the previous snapshot visible. If the very first
                    # poll failed we still need to show SOMETHING below the
                    # header, so render an empty frame and surface the
                    # error in the footer; the user can still quit cleanly.
                    $lastPollError = $_.Exception.Message
                }
                # Stamped AFTER the poll, not from the pre-poll $now: a poll
                # that outruns -Interval (slow endpoint x N slots) would
                # otherwise be pre-credited with its own duration and the next
                # iteration would re-poll with zero delay, hammering a limiter
                # that 429s after a handful of calls in a few seconds. Matches
                # the post-warmup stamp above.
                $lastPoll = [DateTime]::Now
            }

            # Footer rebuilt every tick. The string is constant between
            # poll boundaries (timestamp updates only on poll), but the
            # rebuild is a cheap concat and keeps the redraw path single-
            # branch. Multi-line only when the previous poll failed.
            # Order: [Monitor] state (if -Auto) -> [Warmup] state (if -Warmup)
            # -> [Watch] Last poll -> [Watch] Last poll failed (if any).
            # The mode-state lines ([Monitor], [Warmup]) lead the block so the
            # user's eye finds them first; transport-level details (poll
            # timestamp, failure tail) follow underneath.
            $footer = ''
            if ($lastAutoFooter) {
                $footer = $lastAutoFooter + "`n"
            }
            if ($lastWarmupFooter) {
                $footer += $lastWarmupFooter + "`n"
            }
            $footer += "[Watch] Last poll at $($lastPoll.ToString('HH:mm:ss'))"
            if ($lastPollError) {
                # Collapse before interpolating: the footer is split on newlines
                # by Format-UsageFooter, so a multi-line socket exception would
                # otherwise fork one footer entry into several unprefixed lines.
                $pollReason = Format-StatusErrorTail -Message $lastPollError
                $footer += "`n[Watch] Last poll failed: $pollReason (keeping previous data; will retry on next tick)"
            }

            # Auto-mode threshold for the header tag. Passed only when
            # -Auto is set; otherwise 0 (Format-UsageTable interprets
            # 0 as "no tag").
            $autoHeaderThreshold = if ($Auto) { $Threshold } else { 0 }

            # In-place-overwrite frame: render to a string, then paint it in
            # a single write as cursor-home + per-line erase-to-EOL + trailing
            # erase-below (ConvertTo-WatchFrameSequence), wrapped in the DEC
            # 2026 sync envelope. The single write + the absence of ESC[2J is
            # what makes this flicker-free even on a loaded machine or a
            # terminal without DEC 2026: nothing is ever blanked to black, so
            # a mid-paint render tick shows the previous (near-identical)
            # frame underneath rather than the "black -> row for row" flash a
            # clear-then-redraw produces. DEC 2026 (Win Terminal >= 1.23, VS
            # Code, iTerm2, kitty, alacritty, WezTerm, foot, gnome-terminal,
            # mintty, modern ConHost) is now a bonus that also suppresses
            # sub-frame tearing, not the sole defense. The repaint runs every
            # tick unconditionally, which also self-heals a terminal resize
            # within ~1 s (the per-line ESC[K + trailing ESC[0J reclaim any
            # stale cells from the old geometry).
            $frameText = Get-WatchFrameText {
                if ($null -ne $snapshot) {
                    Format-UsageFrame -Name $Name -Snapshot $snapshot -Footer $footer -AutoThreshold $autoHeaderThreshold
                } else {
                    # First poll failed and we have nothing to render yet.
                    # $footer already leads with the [Monitor] line (when -Auto
                    # is set) via the composition above, so a single
                    # Format-UsageFooter call places auto-mode state above
                    # the 'Waiting...' advisory; no separate standalone
                    # print needed.
                    Write-Color "[Watch] Waiting for first successful /api/oauth/usage response..." 'Yellow'
                    Format-UsageFooter $footer
                }
            }
            Write-VTSequence ("`e[?2026h" + (ConvertTo-WatchFrameSequence $frameText) + "`e[?2026l")

            # 1-second inter-frame wait. Decoupling redraw cadence from
            # poll cadence lets the screen self-heal on terminal resize
            # within ~1 s instead of waiting up to -Interval seconds.
            # Ctrl-C terminates the loop via the runtime's default
            # handler; the surrounding `finally` block leaves the alt
            # buffer and restores cursor visibility on exit.
            Start-Sleep -Seconds 1
        }
    }
    finally {
        # Order matters: show cursor + leave alt buffer in one write so
        # the user's pre-watch terminal state is restored atomically.
        # The CursorVisible API restore is belt-and-suspenders for the
        # .NET-side state.
        if ($enteredAlt) {
            # Restore the pre-watch terminal title via OSC 0. Empty
            # payload when capture failed (RawUI unavailable); most
            # terminals reset the tab label to their profile default
            # (Windows Terminal: profile name; VS Code: shell name).
            # Emitted before the alt-buffer leave so the title swap and
            # screen restore land in the same frame.
            $restoreTitle = if ($null -ne $origTitle) { [string]$origTitle } else { '' }
            $restoreTitle = [regex]::Replace($restoreTitle, '[\x00-\x1F\x7F]', '')
            Write-VTSequence ("`e]0;{0}`a" -f $restoreTitle)
            Write-VTSequence "`e[?25h`e[?1049l"
        }
        [Console]::CursorVisible = $origCursor
        # Restore the pre-watch console output encoding last, after the
        # alt-buffer leave + title restore have been written through the
        # UTF-8 writer (the original title may itself carry non-ASCII).
        if ($origEncoding) {
            try { [Console]::OutputEncoding = $origEncoding } catch { Write-Verbose "Restoring console encoding failed: $_" }
        }
    }
}

# We are wrapping the top-level dispatcher in Invoke-Main so the script
# file is safe to dot-source from tests. Help uses `return` instead of
# `exit` to avoid killing a host that dot-sourced us; the redundant
# `exit` calls from install/uninstall branches are dropped because the
# script naturally exits at the end of Invoke-Main with status 0.
#
# No-color mode lives entirely in this function via a single
# $PSStyle.OutputRendering = 'PlainText' toggle. PS 7.2+ honors this at
# the chokepoint of every Write-Host -ForegroundColor call (and every
# other ANSI-emitting cmdlet), so no per-call-site refactor is needed.
# Precedence (most -> least specific):
#   1. -NoColor switch (CLI flag)
#   2. $env:NO_COLOR non-empty (https://no-color.org de facto standard)
#   3. default colored
# The previous $PSStyle.OutputRendering value is captured up-front and
# restored in the `finally` block so the toggle is scoped to this
# invocation -- callers that dot-source this script (notably the test
# suite, which calls Invoke-*Action directly and bypasses Invoke-Main)
# are unaffected.
function Invoke-Main {
    # -Version short-circuit. Runs before the help / action dispatch so
    # `sca -Version usage` (or any positional Action) prints the version
    # without touching the network, the credentials directory, or any
    # Invoke-*Action body. Plain Write-Host (information stream 6) matches
    # the rest of the script's output convention so `6>&1 | Out-String`
    # tests capture it the same way as Show-Help.
    if ($Version) {
        Write-Host $Script:ScriptVersion
        return
    }

    if ($Help -or $Action -eq "help" -or $Action -eq "") {
        Show-Help
        return
    }

    # After -Version / help so those stay informational everywhere, and before
    # the credentials directory is created so a refused run leaves no trace on
    # disk.
    #
    # `install` and `uninstall` are exempt from the precondition, and from the
    # directory creation below: Add-To-Profile and Remove-From-Profile touch
    # nothing but $ProfilePath, so a missing home directory does not apply to
    # either. Refusing `uninstall` would strand the alias block on any machine
    # that cannot satisfy the guard, with no way to remove it but a hand edit,
    # and $PROFILE.CurrentUserAllHosts is the same path on Linux and macOS, so
    # a synced profile puts a block there without anyone installing it. The
    # same argument covers `install`, which additionally has no use for the
    # credentials directory the guarded path would create for it.
    $profileOnly = ($Action -eq 'install' -or $Action -eq 'uninstall')
    if (-not $profileOnly) {
        Assert-CredentialDir
    }

    # Cross-action flag-misuse guards. Only the switch flags are guarded:
    # -Watch / -Json belong to read-only `usage`, -KeepWarm to `monitor`.
    # The int flags (-Threshold / -Interval) live in __AllParameterSets and
    # are harmless when an action ignores them, so they need no guard.
    if ($Action -eq 'monitor' -and ($Watch -or $Json)) {
        throw "'monitor' is always a live, side-effecting watch; -Watch / -Json do not apply. For a read-only live view use 'sca usage -Watch'."
    }
    if ($KeepWarm -and $Action -ne 'monitor') {
        throw "-KeepWarm applies only to 'sca monitor'. Did you mean 'sca monitor -KeepWarm'?"
    }

    # We are ensuring the credentials directory exists before
    # attempting any file operations within it.
    if (-not $profileOnly) {
        New-CredentialDirectory -Directory $CredDir
    }

    $previousRendering = $PSStyle.OutputRendering
    try {
        if ($NoColor -or -not [string]::IsNullOrEmpty($env:NO_COLOR)) {
            $PSStyle.OutputRendering = 'PlainText'
        }

        # Suppressed under -Json so scripted callers get nothing but the
        # document. Write-Host targets the information stream, which `|` and
        # `>` do not capture, so this is belt-and-suspenders rather than a
        # correctness fix. The watch actions paint into the alternate screen
        # buffer, so emitting here means the advisory scrolls past once
        # before the frame takes over rather than fighting the repaint.
        if (-not $Json) {
            $configAdvisory = Get-ConfigDirAdvisory
            if ($configAdvisory) { Write-Color $configAdvisory 'Yellow' }
        }

        # Heals files written by a pre-4.0.0 sca before any action reads or
        # rewrites them. Runs regardless of -Json (the repair is the point, the
        # line is not) and reports only when it actually changed something, so
        # it stays silent forever after the first run.
        if (-not $profileOnly) {
            $tightened = Repair-CredentialFileModes
            if ($tightened -gt 0 -and -not $Json) {
                Write-Color "[Security] Tightened permissions to 0600 on $tightened credential file(s) written by an older version." 'Yellow'
            }
        }

        switch ($Action) {
            "install"   { Add-To-Profile }
            "uninstall" { Remove-From-Profile }
            "save"      { Invoke-SaveAction   -Name $Name }
            "switch"    { Invoke-SwitchAction -Name $Name }
            "list"      { Invoke-ListAction }
            "remove"    { Invoke-RemoveAction -Name $Name }
            "usage"     { Invoke-UsageAction   -Name $Name -Json:$Json -Watch:$Watch -Interval $Interval }
            "monitor"   { Invoke-MonitorAction -Name $Name -Threshold $Threshold -KeepWarm:$KeepWarm -Interval $Interval }
            "warmup"    { Invoke-WarmupAction  -Name $Name }
        }
    }
    finally {
        $PSStyle.OutputRendering = $previousRendering
    }
}

# We are detecting dot-sourcing by checking the invocation name; the
# dispatcher only runs when the script is invoked normally, not when
# tests dot-source the file to exercise individual functions in
# isolation.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}