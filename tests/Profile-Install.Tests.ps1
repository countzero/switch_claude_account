#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Add-To-Profile / Remove-From-Profile in
# switch_claude_account.ps1. Per-test sandbox setup lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
    $script:OriginalHome        = $env:HOME
    $script:OriginalConfigDir   = $env:CLAUDE_CONFIG_DIR

    # Local helper for install/uninstall round-trip tests. Throws with a
    # precise offset on first mismatch so Pester shows exactly where the
    # byte sequences diverge instead of a generic "not equal" failure.
    # Used only by this file, so kept local rather than in Common.ps1.
    function Assert-BytesEqual ([byte[]] $Expected, [byte[]] $Actual) {
        $Actual.Length | Should -Be $Expected.Length
        for ($i = 0; $i -lt $Expected.Length; $i++) {
            if ($Expected[$i] -ne $Actual[$i]) {
                throw "Byte mismatch at offset $i"
            }
        }
    }
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Add-To-Profile / Remove-From-Profile' {
        It 'install creates the profile and writes both markers' {
            Add-To-Profile 6>$null

            Test-Path -LiteralPath $script:FakeProfilePath | Should -BeTrue
            $content = Get-Content -LiteralPath $script:FakeProfilePath -Raw
            $content | Should -Match '# === Switch Claude Account ==='
            $content | Should -Match '# === End Switch Claude Account ==='
            $content | Should -Match 'switch_claude_account_caller'
            $content | Should -Match 'Set-Alias -Name sca'
            $content | Should -Match 'Set-Alias -Name switch-claude-account'
        }

        It 'install separates the block with a blank line when profile is non-empty' {
            # Pre-existing content ends in \r\n. Add-To-Profile prepends another
            # \r\n to its block, producing a blank line between the two.
            Set-Content -LiteralPath $script:FakeProfilePath -Value "Write-Host 'existing'`r`n" -NoNewline

            Add-To-Profile 6>$null

            $content = Get-Content -LiteralPath $script:FakeProfilePath -Raw
            $content | Should -Match "existing'\r?\n\r?\n# === Switch Claude Account ==="
        }

        It 'install terminates the block with the platform newline' {
            # Add-To-Profile joins on [Environment]::NewLine so it does not
            # inject CRLF into an otherwise-LF profile. Every other assertion
            # in this file is terminator-agnostic (Should -Match uses \r?\n,
            # and the byte round-trips pass under either terminator because
            # Remove-From-Profile splices on \r?\n), and on Windows the join
            # yields CRLF either way. Pin the terminator explicitly or Unix
            # regresses silently.
            Add-To-Profile 6>$null

            $content = Get-Content -LiteralPath $script:FakeProfilePath -Raw
            $expected = @(
                '# === Switch Claude Account ===',
                "function switch_claude_account_caller { & '$($ScriptPath -replace "'", "''")' @args }",
                'Set-Alias -Name sca -Value switch_claude_account_caller -Option AllScope',
                'Set-Alias -Name switch-claude-account -Value switch_claude_account_caller -Option AllScope',
                '# === End Switch Claude Account ==='
            ) -join [Environment]::NewLine

            $content | Should -BeLike "*$expected*"

            if (-not $IsWindows) {
                # The regression this guards: a CR anywhere in a profile the
                # platform writes as LF-only.
                $content | Should -Not -Match "`r"
            }
        }

        It 'install is byte-idempotent (two runs produce identical files)' {
            Add-To-Profile 6>$null
            $bytes1 = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            $bytes2 = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Assert-BytesEqual $bytes1 $bytes2
        }

        It 'install + uninstall round-trip preserves pre-existing UTF-8 content byte-for-byte' {
            $pre = "# my profile`r`nWrite-Host 'hello'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $pre -Encoding utf8NoBOM -NoNewline
            $preBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            Assert-BytesEqual $preBytes $postBytes
        }

        It 'install + uninstall round-trip preserves LF-only line endings byte-for-byte' {
            # Write raw bytes so PowerShell does not normalize LF to CRLF.
            $pre = "line1`nline2`n"
            [System.IO.File]::WriteAllBytes(
                $script:FakeProfilePath,
                [System.Text.Encoding]::UTF8.GetBytes($pre))
            $preBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            Assert-BytesEqual $preBytes $postBytes
        }

        It 'install + uninstall round-trip preserves mixed LF/CRLF line endings byte-for-byte' {
            $pre = "line1`r`nline2`nline3`r`n"
            [System.IO.File]::WriteAllBytes(
                $script:FakeProfilePath,
                [System.Text.Encoding]::UTF8.GetBytes($pre))
            $preBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            Assert-BytesEqual $preBytes $postBytes
        }

        It 'install + uninstall round-trip preserves UTF-16 LE BOM and content' {
            $pre = "# umlauts: ä ö ü`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $pre -Encoding unicode -NoNewline
            $preBom = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)[0..1]

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBom = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)[0..1]
            $postBom[0] | Should -Be $preBom[0]
            $postBom[1] | Should -Be $preBom[1]

            $post = Get-Content -LiteralPath $script:FakeProfilePath -Encoding unicode -Raw
            $post | Should -Match 'ä ö ü'
            $post | Should -Not -Match 'Switch Claude Account'
        }

        It 'install + uninstall round-trip preserves UTF-8 with BOM' {
            $pre = "# bom test`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $pre -Encoding utf8BOM -NoNewline

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            $postBytes[0] | Should -Be 0xEF
            $postBytes[1] | Should -Be 0xBB
            $postBytes[2] | Should -Be 0xBF

            $post = Get-Content -LiteralPath $script:FakeProfilePath -Raw
            $post | Should -Match 'bom test'
            $post | Should -Not -Match 'Switch Claude Account'
        }

        It 'uninstall throws and leaves file byte-identical when only start marker is present' {
            $orphan = "# stuff`r`n# === Switch Claude Account ===`r`nWrite-Host 'dangling'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $orphan -Encoding utf8NoBOM -NoNewline
            $before = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            { Remove-From-Profile 6>$null } | Should -Throw -ExpectedMessage '*orphan*'

            $after = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            Assert-BytesEqual $before $after
        }

        It 'uninstall throws when only end marker is present' {
            $orphan = "# stuff`r`n# === End Switch Claude Account ===`r`nWrite-Host 'x'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $orphan -Encoding utf8NoBOM -NoNewline

            { Remove-From-Profile 6>$null } | Should -Throw -ExpectedMessage '*orphan*'
        }

        It 'uninstall on a profile without our block is a no-op' {
            $content = "# user profile`r`nWrite-Host 'unchanged'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $content -Encoding utf8NoBOM -NoNewline
            $before = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            { Remove-From-Profile 6>$null } | Should -Not -Throw

            $after = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            Assert-BytesEqual $before $after
        }

        # Both profile actions touch $ProfilePath and nothing else, so neither
        # has any use for the credentials directory and neither should be
        # blocked on resolving one. Driven out of process because the exemption
        # lives in Invoke-Main, which the direct-call pattern bypasses, and
        # CLAUDE_CONFIG_DIR is pointed at a path that does not exist so a
        # regression shows up as a created directory.
        #
        # Keyed 'ProfileAction', not 'Action': dot-sourcing the script binds its
        # own top-level [string] $Action parameter into the test scope, which
        # shadows a -ForEach variable of that name and silently feeds every case
        # an empty action.
        It 'runs <ProfileAction> without resolving a credentials directory' -ForEach @(
            @{ ProfileAction = 'install';   Expected = 'Installed!' }
            @{ ProfileAction = 'uninstall'; Expected = 'Uninstalled.' }
        ) {
            $absent      = Join-Path $TestDrive 'never-created'
            $profilePath = Join-Path $TestDrive "profile-$ProfileAction.ps1"

            # Seed a block so uninstall has something to remove and therefore
            # something to say; install overwrites its own block regardless.
            Set-Content -LiteralPath $profilePath -NoNewline -Encoding utf8NoBOM -Value (
                @($MarkerStart, 'Write-Host seeded', $MarkerEnd) -join [Environment]::NewLine)

            $out = pwsh -NoProfile -Command "
                `$env:CLAUDE_CONFIG_DIR = '$absent'
                `$PROFILE = [pscustomobject]@{ CurrentUserAllHosts = '$profilePath' }
                & '$script:ScriptPath' $ProfileAction
            " 2>&1 | Out-String

            $out | Should -Not -Match 'No credentials directory'
            Test-Path -LiteralPath $absent | Should -BeFalse
            # Pin that the action actually ran, so a failure for an unrelated
            # reason cannot pass by simply not creating the directory.
            $out | Should -Match ([regex]::Escape($Expected))
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
