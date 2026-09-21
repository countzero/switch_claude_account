#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Test-ClaudeRunning in switch_claude_account.ps1: the
# guard `save` refuses on and `warmup` warns about.
#
# Its own file because tests/Common.ps1 mocks this function for the whole
# suite, and a mock cannot be lifted once set. The BeforeEach below sets
# $script:ScaKeepRealClaudeRunning first, which is the only supported way to
# opt out; see the comment on that mock for why nothing else may.
#
# The pattern match itself lives in Test-ClaudeNodeProcess and is covered in
# Helpers.Tests.ps1 on every platform. What is left here is the part that
# differs by platform: which probes run at all.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
    $script:OriginalHome        = $env:HOME
    $script:OriginalConfigDir   = $env:CLAUDE_CONFIG_DIR
}

Describe 'switch_claude_account' {

    BeforeEach {
        # Must be set BEFORE Common.ps1 is dot-sourced: the mock it installs
        # is conditional on this flag.
        $script:ScaKeepRealClaudeRunning = $true
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Test-ClaudeRunning' {
        # The native installer produces a real executable named 'claude', so
        # the name probe finds it on every platform and nothing else needs to
        # run.
        It 'reports true when a process named claude is running' {
            Mock Get-Process -ParameterFilter { $Name -eq 'claude' } -MockWith {
                [pscustomobject]@{ Name = 'claude'; Id = 4242 }
            }

            Test-ClaudeRunning | Should -BeTrue
        }

        # Reading .CommandLine off every process costs about 53 s on Windows,
        # where the property is backed by a per-process CIM query. A guard that
        # runs before every save / switch / rotation cannot spend that, so the
        # second probe is skipped there. The catch-all mock below turns a
        # regression into a failure rather than a slow suite.
        It 'reports false on Windows without enumerating every process' -Skip:(-not $IsWindows) {
            Mock Get-Process -MockWith { throw 'the full enumeration must not run on Windows' }
            Mock Get-Process -ParameterFilter { $Name -eq 'claude' } -MockWith { }

            Test-ClaudeRunning | Should -BeFalse

            Should -Invoke Get-Process -Times 1 -Exactly -ParameterFilter { $Name -eq 'claude' }
        }

        # The npm package is a Node script behind a shim, so its process is
        # 'node' and the name probe misses it entirely. Off Windows the
        # command-line probe is what catches it.
        It 'falls through to the command-line probe off Windows' -Skip:$IsWindows {
            Mock Get-Process -ParameterFilter { $Name -eq 'claude' } -MockWith { }
            Mock Get-Process -ParameterFilter { -not $Name } -MockWith {
                @(
                    [pscustomobject]@{ Name = 'bash'; CommandLine = '-bash' }
                    [pscustomobject]@{ Name = 'node'; CommandLine = '/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js' }
                )
            }

            Test-ClaudeRunning | Should -BeTrue
        }

        It 'reports false off Windows when no command line matches' -Skip:$IsWindows {
            Mock Get-Process -ParameterFilter { $Name -eq 'claude' } -MockWith { }
            Mock Get-Process -ParameterFilter { -not $Name } -MockWith {
                @([pscustomobject]@{ Name = 'node'; CommandLine = '/srv/claude-notes/server.js' })
            }

            Test-ClaudeRunning | Should -BeFalse
        }

        # An unreadable /proc entry, or a process that exits mid-scan, must not
        # turn a safety guard into a terminating error. "Not detected" is the
        # answer the name probe already gave.
        It 'treats an enumeration failure as not detected' -Skip:$IsWindows {
            Mock Get-Process -ParameterFilter { $Name -eq 'claude' } -MockWith { }
            Mock Get-Process -ParameterFilter { -not $Name } -MockWith {
                throw [System.InvalidOperationException]::new('process exited mid-scan')
            }

            Test-ClaudeRunning | Should -BeFalse
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
