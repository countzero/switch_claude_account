#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-ListAction in switch_claude_account.ps1.
# Invoke-ListAction reconciles first (so cross-account swaps detected
# since the last sca call surface in the marker column) and then
# renders. The active marker `*` is sourced from .sca-state.json (with
# one-time hash-based migration on first call). The reconcile prelude
# may hash .credentials.json and may HTTP-fall-back through
# Get-SlotProfile when ~/.claude.json has no oauthAccount; the test
# bodies below mock those out where needed. Per-test sandbox setup
# lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
    $script:OriginalHome        = $env:HOME
    $script:OriginalConfigDir   = $env:CLAUDE_CONFIG_DIR
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Invoke-ListAction' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
        }

        It 'prints the empty-directory message when no slots are saved' {
            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Match 'No slots saved yet'
        }

        It 'lists slot names and marks the active slot with *' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'B' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+alpha\s'
            $out | Should -Match '(?m)^\s+\*\s+bravo\s'
            $out | Should -Not -Match '\(active\)'
            $out | Should -Match 'Slot'
            $out | Should -Match 'Account'
        }

        It 'lists slots without * when no active file exists' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+alpha\s'
            $out | Should -Not -Match '\(active\)'
            $out | Should -Not -Match '(?m)^\s+\*\s+\w'
        }

        It 'excludes .credentials.json itself from the slot listing' {
            Set-Content -LiteralPath $script:CredFilePath -Value 'X' -NoNewline
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Content 'W' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match 'work'
            $out | Should -Not -Match '(?m)^\s*\*?\s+\.credentials(\s|$)'
        }

        # Post-v2.1.0: slots without sidecars are hidden entirely.
        # Re-running `sca save <name>` while that slot is active
        # recaptures the sidecar and makes it visible again.
        It 'hides slot files that have no sidecar' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'modern' -Content 'M' | Out-Null
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.legacy.json') -Value 'L' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+modern\s'
            $out | Should -Not -Match '(?m)^\s+legacy\s'
            # Legacy slot file remains on disk (not deleted by `list`),
            # but is invisible in the table. User can `sca remove legacy`
            # to clean up explicitly.
            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.legacy.json') | Should -BeTrue
        }

        # Email column rendering: parallels the Invoke-UsageAction email
        # rendering tests below. The list table now carries the email
        # inline in an Account column instead of the old `└─ <email>`
        # continuation line.
        It 'renders the email in the Account column when slot is labeled' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'ada.lovelace@arpa.net' -Content 'X' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+work\s+ada\.lovelace@arpa\.net\b'
            $out | Should -Not -Match '└─'
        }

        It "renders '-' in the Account column when slot name equals the embedded email (dedup form)" {
            $email = 'alice@example.com'
            New-SlotPair -CredDir $script:CredDirPath -Name $email -Content 'X' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match "(?m)^\s+$([regex]::Escape($email))\s+—\s*$"
            $out | Should -Not -Match '└─'
        }

        It "renders '-' in the Account column for unlabeled slot" {
            New-SlotPair -CredDir $script:CredDirPath -Name 'pending' -Content 'X' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+pending\s+—\s*$'
            $out | Should -Not -Match '└─'
        }

        It 'middle-truncates long emails in the Account column' {
            $longEmail = 'extremely.long.local.part@extraordinarily-long-domain.example.com'
            $longEmail.Length | Should -BeGreaterThan $Script:AccountColumnMaxWidth

            New-SlotPair -CredDir $script:CredDirPath -Name 'longslot' -Email $longEmail -Content 'X' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '…'
            $out | Should -Not -Match ([regex]::Escape($longEmail))
        }
    }

    Context 'Invoke-ListAction (state file)' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
        }

        # The hardlink-broken / ActiveLocked / "not hardlinked to any
        # slot" advisories are gone with the rest of the hardlink
        # mechanism. List is now a pure offline render: NO advisories
        # under any state. The pending-state cases the old advisories
        # warned about are now handled silently by reconcile next time
        # the user runs `sca usage` or `sca switch`.

        It 'no advisory output ever, regardless of .credentials.json state' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'UNKNOWN' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Not -Match 'Warning'
            $out | Should -Not -Match 'not hardlinked'
            $out | Should -Not -Match 'auto-sync'
        }

        # Active marker comes from the state file when it exists.
        It 'IsActive marker reflects state.active_slot' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null

            Update-ScaState -ActiveSlot 'alpha' -LastSyncHash 'X' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+\*\s+alpha\s'
            $out | Should -Not -Match '(?m)^\s+\*\s+bravo\s'
        }

        # Auto-migration on first call (no state file): hash-match
        # .credentials.json against existing slot files and seed state
        # transparently. Read-ScaState's auto-migration walks raw files
        # (not Get-Slots) so the active slot is identified even when
        # the slot's sidecar exists.
        It 'auto-migrates state on first call by hash-matching .credentials.json' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'B' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+\*\s+bravo\s'
            (Read-ScaState).active_slot | Should -Be 'bravo'
        }

        # No content-hash to compute when no .credentials.json exists.
        # state.active_slot stays whatever it was (maybe null on a fresh
        # install with no prior saves). Either way, no advisory.
        It 'list works without .credentials.json (no active marker; no advisory)' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+alpha\s'
            $out | Should -Not -Match '(?m)^\s+\*\s+\w'
            $out | Should -Not -Match 'Warning'
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
