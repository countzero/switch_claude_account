#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-WarmupAction in switch_claude_account.ps1: the
# one-shot `sca warmup [name]` action that activates each saved slot via the
# real Claude Code CLI (`claude -p`) and prints the usage table. The per-slot
# swap/activate/restore round-robin itself is covered by the Invoke-WarmAllSlots
# context in Invoke-UsageAction.Tests.ps1; here we cover the action-level
# guards, the no-slots path, and that it renders the table. Per-test sandbox
# setup lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
    $script:OriginalHome        = $env:HOME
    $script:OriginalConfigDir   = $env:CLAUDE_CONFIG_DIR
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')

        $script:CredDirPath = Join-Path $script:SandboxHome '.claude'
        New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null

        # Pretend the claude CLI is installed so the binary-presence guard
        # passes regardless of the host environment. The missing-binary test
        # overrides this locally. A tight ParameterFilter leaves every other
        # Get-Command call (the script's / Pester's own) untouched.
        Mock Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith {
            [pscustomobject]@{ Name = 'claude'; Source = 'claude'; CommandType = 'Application' }
        }

        # Stub the orchestration's side effects so no real claude spawns and
        # no real HTTP fires; each slot resolves to a healthy 'ok' row.
        Mock Invoke-SlotSwap      -MockWith { }
        Mock Invoke-Reconcile     -MockWith { }
        Mock Invoke-SlotActivator -MockWith { [pscustomobject]@{ Status = 'ok' } }
        Mock Get-SlotUsage        -MockWith {
            [pscustomobject]@{
                Status = 'ok'
                Data   = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 3.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 9.0; resets_at = $null }
                }
                Error            = $null
                IsCachedFallback = $false
            }
        }
    }

    Context 'Invoke-WarmupAction' {
        It 'refuses when Claude Code is running' {
            Mock Test-ClaudeRunning -MockWith { $true }
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            { Invoke-WarmupAction -Name '' 6>$null } | Should -Throw -ExpectedMessage '*Claude Code is running*'
        }

        It 'refuses when the claude CLI is not on PATH' {
            Mock Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith { $null }
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            { Invoke-WarmupAction -Name '' 6>$null } | Should -Throw -ExpectedMessage "*claude*not found*"
        }

        It 'prints an advisory and does not throw when no slots are saved' {
            $out = Invoke-WarmupAction -Name '' 6>&1 | Out-String
            $out | Should -Match 'No slots'
            Should -Invoke Invoke-SlotActivator -Times 0 -Exactly
        }

        It 'activates every saved slot and renders the usage table' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'b' -Email 'b@test.local' -Content '{}' | Out-Null

            $out = Invoke-WarmupAction -Name '' 6>&1 | Out-String

            $out | Should -Match 'Activating'
            $out | Should -Match '\ba\b'
            $out | Should -Match '\bb\b'
            # One activation per slot.
            Should -Invoke Invoke-SlotActivator -Times 2 -Exactly
        }

        It '-Name narrows the warm pass to a single slot' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'b' -Email 'b@test.local' -Content '{}' | Out-Null

            Invoke-WarmupAction -Name 'a' 6>$null

            Should -Invoke Invoke-SlotActivator -Times 1 -Exactly
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
