#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-MonitorAction in switch_claude_account.ps1: the
# `sca monitor` action that always auto-rotates (no -Auto flag) and, with
# -KeepWarm, keeps every slot warm for the life of the watch. Invoke-MonitorAction
# is a thin adapter over the shared watch engine (Invoke-UsageWatch); the
# rotation and keep-warm mechanics themselves are covered by
# Invoke-AutoRotation.Tests.ps1 and the Invoke-KeepWarmStep / Invoke-WarmAllSlots
# contexts in Invoke-UsageAction.Tests.ps1. Here we cover the action-level
# contract: that monitor maps to the engine with -Auto set, threads -Threshold
# and -KeepWarm through, ignores a positional name, and surfaces the
# watch-engine guards (Claude-Code refusal, interactive-terminal requirement).
# Per-test sandbox setup lives in tests/Common.ps1.

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
    }

    Context 'Invoke-MonitorAction routing' {
        # The engine is mocked here, so none of its guards run; we only assert
        # the public surface maps onto Invoke-UsageWatch's internal contract.
        BeforeEach {
            Mock Invoke-UsageWatch -MockWith { }
        }

        It 'always drives the watch engine with auto-rotation enabled' {
            Invoke-MonitorAction
            Should -Invoke Invoke-UsageWatch -Times 1 -Exactly -ParameterFilter { $Auto }
        }

        It 'passes the default threshold of 95 and no keep-warm by default' {
            Invoke-MonitorAction
            Should -Invoke Invoke-UsageWatch -Times 1 -Exactly -ParameterFilter {
                $Auto -and $Threshold -eq 95 -and -not $Warmup
            }
        }

        It 'threads -Threshold through to the engine' {
            Invoke-MonitorAction -Threshold 90
            Should -Invoke Invoke-UsageWatch -Times 1 -Exactly -ParameterFilter { $Threshold -eq 90 }
        }

        It 'maps -KeepWarm onto the engine -Warmup switch' {
            Invoke-MonitorAction -KeepWarm
            Should -Invoke Invoke-UsageWatch -Times 1 -Exactly -ParameterFilter { $Auto -and $Warmup }
        }

        It 'threads -Interval through to the engine' {
            Invoke-MonitorAction -Interval 300
            Should -Invoke Invoke-UsageWatch -Times 1 -Exactly -ParameterFilter { $Interval -eq 300 }
        }

        It 'ignores a positional name (monitor watches the whole fleet)' {
            Invoke-MonitorAction -Name 'work'
            Should -Invoke Invoke-UsageWatch -Times 1 -Exactly -ParameterFilter { -not $Name }
        }
    }

    Context 'Invoke-MonitorAction watch-engine guards' {
        # The engine is NOT mocked here, so its pre-loop guards run for real.

        It 'refuses at startup when Claude Code is running, naming sca monitor' {
            # The Claude-Code guard runs BEFORE the IsOutputRedirected guard
            # inside Invoke-UsageWatch, so this is safe on an interactive
            # terminal: the $true mock short-circuits before any alt-screen
            # Write-VTSequence fires.
            Mock Test-ClaudeRunning -MockWith { $true }

            { Invoke-MonitorAction 6>$null } | Should -Throw -ExpectedMessage '*Claude Code is running*sca monitor*'
        }

        It 'passes the Claude-Code guard then short-circuits on IsOutputRedirected' {
            # Test-ClaudeRunning's default mock returns $false, so the guard
            # passes; the IsOutputRedirected guard throws next because Pester's
            # stdout is redirected. On an interactive terminal (test runner
            # invoked without redirection), IsOutputRedirected is $false and
            # the alt-screen would blank the terminal; skip in that case
            # (same pattern as the watch-mode tests elsewhere in the suite).
            if (-not [Console]::IsOutputRedirected) {
                Set-ItResult -Skipped -Because 'Console stdout is not redirected; running this test would enter the alt-screen buffer and blank the terminal.'
                return
            }
            { Invoke-MonitorAction 6>$null } | Should -Throw -ExpectedMessage '*requires an interactive terminal*'
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
