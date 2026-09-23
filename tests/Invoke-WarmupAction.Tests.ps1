#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-WarmupAction in switch_claude_account.ps1: the
# one-shot `sca warmup [name]` action that activates each saved slot via the
# real Claude Code CLI (`claude -p`) and prints the usage table. The per-slot
# swap/activate/restore round-robin itself is covered by the Invoke-WarmAllSlots
# context in Invoke-UsageAction.Tests.ps1; this file covers the action-level
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

    }

    Context 'Invoke-WarmupAction' {
        BeforeEach {
            # Stub the orchestration's side effects so no real claude spawns and
            # no real HTTP fires; each slot resolves to a healthy 'ok' row.
            # Scoped to this context rather than the file, because the
            # activator-internals context below needs the real
            # Invoke-SlotActivator and a mock cannot be lifted once set.
            Mock Invoke-SlotSwap      -MockWith { }
            Mock Invoke-Reconcile     -MockWith { New-ReconcileResult }
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

        # Not a refusal: claude serializes refreshes across its own processes,
        # so the pass cannot cost a credential. The warning names the one cost
        # that remains, a prompt sent mid-pass billing the mounted slot.
        It 'warns but proceeds when Claude Code is running' {
            Mock Test-ClaudeRunning -MockWith { $true }
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            $out = Invoke-WarmupAction -Name '' 6>&1 | Out-String

            $out | Should -Match 'Claude Code is running'
            $out | Should -Match 'bills whichever slot is mounted'
            Should -Invoke Invoke-SlotActivator -Times 1 -Exactly
        }

        # The warning alone is not a decision: the first billable `claude -p`
        # follows it by milliseconds, so a user reads it with the round-robin
        # already under way. The pause is what makes the Ctrl-C it implies
        # reachable. Common.ps1 zeroes the constant for the rest of the suite.
        It 'pauses before the first activation when Claude Code is running' {
            Mock Test-ClaudeRunning -MockWith { $true }
            Mock Start-Sleep -MockWith { }
            $Script:WarmupLiveClientPauseSec = 5
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            $out = Invoke-WarmupAction -Name '' 6>&1 | Out-String

            $out | Should -Match 'Ctrl-C to abort'
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        }

        It 'does not pause when no Claude Code is running' {
            Mock Start-Sleep -MockWith { }
            $Script:WarmupLiveClientPauseSec = 5
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            Invoke-WarmupAction -Name '' 6>$null

            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        # The notice describes what the round-robin will cost and the pause
        # offers five seconds to call it off. Neither has anything to say when
        # the pass is about to report that no slot matched: there is no cost
        # coming and nothing to abort.
        It 'says nothing about a live client when <Case>' -ForEach @(
            @{ Case = 'no slots are saved';   Slot = $null; Filter = '' }
            @{ Case = '-Name matches nothing'; Slot = 'a';   Filter = 'no-such-slot' }
        ) {
            Mock Test-ClaudeRunning -MockWith { $true }
            Mock Start-Sleep -MockWith { }
            $Script:WarmupLiveClientPauseSec = 5
            if ($Slot) {
                New-SlotPair -CredDir $script:CredDirPath -Name $Slot -Email "$Slot@test.local" -Content '{}' | Out-Null
            }

            $out = Invoke-WarmupAction -Name $Filter 6>&1 | Out-String

            $out | Should -Not -Match 'Claude Code is running'
            $out | Should -Not -Match 'Ctrl-C to abort'
            $out | Should -Match 'No slots'
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        # Get-SafeName advises when it changes the name. Resolving it once and
        # reusing the result is what keeps that advisory from being printed by
        # the preflight, by the pass, and by the no-slots message in turn.
        It 'advises about a sanitized name exactly once' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            $out = Invoke-WarmupAction -Name 'my missing' 6>&1 | Out-String

            ([regex]::Matches($out, "Sanitized to: 'my_missing'")).Count | Should -Be 1
        }

        # The pass stops rather than overwrite bytes nothing captured, which
        # leaves the user on a slot they did not choose. That is the one thing
        # they have to read, so it precedes the table.
        It 'prints the pass advisory ahead of the usage table' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null
            Mock Invoke-WarmAllSlots -MockWith {
                [pscustomobject]@{
                    Results        = @(
                        [pscustomobject]@{
                            Name = 'a'; Email = 'a@test.local'; IsActive = $true
                            Status = 'ok'; Data = $null; Error = $null
                            IsCachedFallback = $false; HttpStatus = $null; FallbackReason = $null
                        }
                    )
                    NoSlots        = $false
                    HasRateLimited = $false
                    Advisory       = "[Warmup] Stopped at 'a': nothing captured the credentials Claude Code left active."
                }
            }

            $out = Invoke-WarmupAction -Name '' 6>&1 | Out-String

            $out | Should -Match "Stopped at 'a'"
            $out.IndexOf('Stopped at') | Should -BeLessThan $out.IndexOf('Plan usage')
        }

        It 'refuses when the claude CLI is not on PATH' {
            Mock Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith { $null }
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            { Invoke-WarmupAction -Name '' 6>$null } | Should -Throw -ExpectedMessage "*claude*not found*"
        }

        # The warm pass makes every slot active in turn, so it overwrites
        # .credentials.json once per slot. Starting it on bytes reconcile could
        # not attribute discards them on the very first swap.
        It 'refuses when reconcile could not capture the active credentials' {
            Mock Invoke-Reconcile -MockWith {
                [pscustomobject]@{ Action = 'noop'; Reason = 'identity-unresolved'; Slot = 'a'; Captured = $false }
            }
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            { Invoke-WarmupAction -Name '' 6>$null } |
                Should -Throw -ExpectedMessage '*could not be attributed to an account*'
            Should -Invoke Invoke-SlotActivator -Times 0 -Exactly
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
            Should -Invoke Invoke-SlotActivator -Times 2 -Exactly
        }

        It '-Name narrows the warm pass to a single slot' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'b' -Email 'b@test.local' -Content '{}' | Out-Null

            Invoke-WarmupAction -Name 'a' 6>$null

            Should -Invoke Invoke-SlotActivator -Times 1 -Exactly
        }

        # "No slots saved" and "no slot by that name" are different problems
        # with different fixes, and the advisory is the only place the
        # difference is visible. The name is echoed through Get-SafeName so
        # what is quoted back is the name actually looked for.
        It 'names the filter when -Name matches nothing' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null

            $out = Invoke-WarmupAction -Name 'my missing' 6>&1 | Out-String

            $out | Should -Match "No slots matching 'my_missing' to activate"
            Should -Invoke Invoke-SlotActivator -Times 0 -Exactly
        }

        # The pass spaces successive activations so a multi-slot warm does not
        # arrive at the endpoint as a burst. Spacing is collapsed to 0 for the
        # suite, so the only way to see the pacing is to put it back.
        It 'pauses between slots but not after the last one' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' -Content '{}' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'b' -Email 'b@test.local' -Content '{}' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'c' -Email 'c@test.local' -Content '{}' | Out-Null

            $Script:WarmupSpacingMs = 1
            Mock Start-Sleep -MockWith { }

            Invoke-WarmupAction -Name '' 6>$null

            # Three slots, two gaps.
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }
    }

    Context 'Invoke-SlotActivator / Invoke-ClaudeActivatorProcess internals' {
        # No Invoke-SlotActivator stub here: these cases are about that
        # function's own classification and the child-process wrapper beneath
        # it. Nothing spawns a real claude, because the wrapper is either
        # mocked or driven through a mocked Start-Process.

        # Kill can lose the race with a process that exits just after
        # WaitForExit gave up. The answer is still "timed out": the caller
        # needs a verdict about the activation, not about the cleanup.
        It 'still reports a timeout when killing the hung process fails' {
            Mock Start-Process -MockWith {
                $p = [pscustomobject]@{ ExitCode = 0 }
                $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { Param ($ms) return $false }
                $p | Add-Member -MemberType ScriptMethod -Name Kill -Value {
                    Param ($entireTree)
                    throw [System.InvalidOperationException]::new('process has already exited')
                }
                return $p
            }

            $r = Invoke-ClaudeActivatorProcess -ClaudeArgs @('-p', 'Hi') -TimeoutSec 1

            $r.TimedOut | Should -BeTrue
            $r.ExitCode | Should -BeNullOrEmpty
            $r.Stdout   | Should -Be ''
        }

        # claude's JSON envelope does not always carry a sentence. subtype is
        # the last field with any signal in it; without this arm such a failure
        # renders as the bare exit code.
        It 'falls back to the JSON subtype when there is no result or error text' {
            $slot = New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Email 'a@test.local' `
                -Content '{"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT","expiresAt":9999999999999}}'

            Mock Invoke-ClaudeActivatorProcess -MockWith {
                [pscustomobject]@{
                    TimedOut = $false
                    ExitCode = 1
                    Stdout   = '{"type":"result","is_error":true,"subtype":"error_during_execution"}'
                    Stderr   = ''
                }
            }

            $r = Invoke-SlotActivator -SlotPath $slot 6>$null

            $r.Status | Should -Not -Be 'ok'
            $r.Error  | Should -Match 'error_during_execution'
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
