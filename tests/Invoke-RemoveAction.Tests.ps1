#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-RemoveAction in switch_claude_account.ps1.
# After the state-file redesign Invoke-RemoveAction refuses to remove
# the currently-tracked active slot (the user must `sca switch` first)
# and there is no longer any hardlink involvement to verify. Per-test
# sandbox setup lives in tests/Common.ps1.

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

    Context 'Invoke-RemoveAction' {
        It 'deletes the slot file and its sidecar' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            $slot = New-SlotPair -CredDir $credDir -Name 'work' -Content 'X'
            $sidecar = $slot -replace '\.json$', '.account.json'
            Test-Path -LiteralPath $sidecar | Should -BeTrue   # baseline

            Invoke-RemoveAction -Name 'work' 6>$null

            Test-Path -LiteralPath $slot    | Should -BeFalse
            Test-Path -LiteralPath $sidecar | Should -BeFalse
        }

        # Regression for the filename-encoded-email feature: remove must
        # work by slot-name alone regardless of whether the on-disk file
        # uses the labeled `.credentials.<slot>(<email>).json` form or
        # the unlabeled `.credentials.<slot>.json` form.
        It 'removes a labeled slot file by slot-name argument' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            $labeled = New-SlotPair -CredDir $credDir -Name 'work' -Email 'alice@example.com' -Content 'X'

            Invoke-RemoveAction -Name 'work' 6>$null

            Test-Path -LiteralPath $labeled | Should -BeFalse
            Test-Path -LiteralPath ($labeled -replace '\.json$', '.account.json') | Should -BeFalse
        }

        It 'removes a sidecar-less legacy slot (raw filesystem walk, not Get-Slots)' {
            # Legacy slot: no sidecar -> Get-Slots hides it. Remove
            # walks the raw filesystem so the user can clean up these
            # invisible orphans without manual editing.
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $legacy = Join-Path $credDir '.credentials.legacy.json'
            Set-Content -LiteralPath $legacy -Value 'L' -NoNewline

            Invoke-RemoveAction -Name 'legacy' 6>$null

            Test-Path -LiteralPath $legacy | Should -BeFalse
        }

        It 'throws when the slot does not exist' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null

            { Invoke-RemoveAction -Name 'missing' 6>$null } | Should -Throw -ExpectedMessage "*Slot 'missing' not found*"
        }

        It 'sanitizes the name before deletion' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            $slot = New-SlotPair -CredDir $credDir -Name 'my_work' -Content 'X'

            Invoke-RemoveAction -Name 'my work' 6>$null

            Test-Path -LiteralPath $slot | Should -BeFalse
        }

        # Regression: a user typing `sca remove foo[bar]` must NOT cause
        # wildcard expansion of `foo[bar]` into a character class that
        # matches unrelated slot files (fooa, foob, foor). Get-SafeName
        # sanitizes brackets to _ so the user-facing name becomes
        # foo_bar_; the lookup then misses and throws. The key assertions
        # are that the unrelated slots survive and the throw message
        # references the sanitized name.
        It 'user-supplied bracket name is sanitized and does not wildcard-delete sibling slots' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            $fooaPath = New-SlotPair -CredDir $credDir -Name 'fooa' -Content 'A'
            $foobPath = New-SlotPair -CredDir $credDir -Name 'foob' -Content 'B'

            { Invoke-RemoveAction -Name 'foo[bar]' 6>$null } |
                Should -Throw -ExpectedMessage "*Slot 'foo_bar_' not found*"

            Test-Path -LiteralPath $fooaPath | Should -BeTrue
            Test-Path -LiteralPath $foobPath | Should -BeTrue
        }
    }

    Context 'Invoke-RemoveAction (state file)' {
        # Refusing to remove the active slot forces the user to switch
        # away first. Without this guard, the user could delete the slot
        # whose tokens .credentials.json depends on, leaving the script
        # with a state file pointing at a now-missing slot.
        It 'refuses to remove the slot tracked as active in state' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            $workPath = New-SlotPair -CredDir $credDir -Name 'work'  -Content 'W'
            New-SlotPair -CredDir $credDir -Name 'other' -Content 'O' | Out-Null
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'X' | Out-Null

            { Invoke-RemoveAction -Name 'work' 6>$null } |
                Should -Throw -ExpectedMessage "*Cannot remove active slot 'work'*"

            Test-Path -LiteralPath $workPath | Should -BeTrue
        }

        It 'removes a non-active slot without disturbing state.active_slot' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'work'  -Content 'W' | Out-Null
            $otherPath = New-SlotPair -CredDir $credDir -Name 'other' -Content 'O'
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'X' | Out-Null

            Invoke-RemoveAction -Name 'other' 6>$null

            Test-Path -LiteralPath $otherPath | Should -BeFalse
            (Read-ScaState).active_slot | Should -Be 'work'
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
