#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-SaveAction in switch_claude_account.ps1.
#
# Post-v2.1.0 contract:
#   * Identity comes primarily from ~/.claude.json's oauthAccount block
#     (same source Claude Code uses for /status, drift-proof).
#   * /api/oauth/profile is a fallback when ~/.claude.json has no
#     oauthAccount yet (rare).
#   * Both sources missing -> refuse to save (no unlabeled slots).
#   * Save writes a .credentials.<name>(<email>).account.json sidecar
#     atomic-paired with the credentials file.
#   * Refuses to operate while Claude Code is running.
#
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
        $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
        New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
        $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'

        # Default: populate ~/.claude.json with a known oauthAccount so
        # the primary identity-resolution path succeeds. Tests that
        # exercise the fallback or no-identity branches override this.
        Set-SandboxClaudeJson -Email 'alice@example.com'
    }

    Context 'Invoke-SaveAction' {
        It 'copies active credentials to the labeled slot file byte-for-byte' {
            [System.IO.File]::WriteAllBytes($script:CredFilePath, [byte[]](0x7B,0x22,0x74,0x22,0x3A,0x31,0x7D))

            Invoke-SaveAction -Name 'work' 6>$null

            $slot = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json'
            Test-Path -LiteralPath $slot | Should -BeTrue
            [System.IO.File]::ReadAllBytes($slot) | Should -Be ([System.IO.File]::ReadAllBytes($script:CredFilePath))
        }

        It 'writes a paired .account.json sidecar with the captured oauthAccount' {
            Set-Content -LiteralPath $script:CredFilePath -Value '{"t":1}' -NoNewline

            Invoke-SaveAction -Name 'work' 6>$null

            $sidecar = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).account.json'
            Test-Path -LiteralPath $sidecar | Should -BeTrue
            $obj = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json
            $obj.schema                       | Should -Be 1
            $obj.source                       | Should -Be 'claude_json'
            $obj.oauthAccount.emailAddress    | Should -Be 'alice@example.com'
            $obj.oauthAccount.accountUuid     | Should -Be '11111111-1111-1111-1111-111111111111'
            $obj.oauthAccount.organizationUuid| Should -Be '22222222-2222-2222-2222-222222222222'
        }

        It 'throws when active credentials file is missing' {
            { Invoke-SaveAction -Name 'work' 6>$null } | Should -Throw -ExpectedMessage '*not found. Log in*'
        }

        It 'sanitizes the slot name before creating the file' {
            Set-Content -LiteralPath $script:CredFilePath -Value '{"t":1}' -NoNewline

            Invoke-SaveAction -Name 'my work' 6>$null

            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.my_work(alice@example.com).json') | Should -BeTrue
        }

        It 'overwrites an existing slot file (idempotent re-save)' {
            $oldSlot = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json'
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content 'OLD' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'NEW' -NoNewline

            Invoke-SaveAction -Name 'work' 6>$null

            Get-Content -LiteralPath $oldSlot -Raw | Should -Be 'NEW'
        }

        It 'refuses to save while Claude Code is running' {
            Mock Test-ClaudeRunning -MockWith { $true }
            Set-Content -LiteralPath $script:CredFilePath -Value '{"t":1}' -NoNewline

            { Invoke-SaveAction -Name 'work' 6>$null } | Should -Throw -ExpectedMessage '*Claude Code is running*'
            # No slot or sidecar created.
            @(Get-ChildItem -LiteralPath $script:CredDirPath -Filter '.credentials.work*.json' -Force).Count | Should -Be 0
        }

        It 'falls back to /api/oauth/profile when ~/.claude.json has no oauthAccount' {
            # Wipe oauthAccount: leave ~/.claude.json present but without
            # the relevant block. Get-OAuthAccountFromClaudeJson returns
            # $null; save flips to the API-profile fallback.
            $minimal = [ordered]@{ numStartups = 1; autoUpdates = $true } | ConvertTo-Json
            Set-Content -LiteralPath $ClaudeJsonPath -Value $minimal -NoNewline

            Set-Content -LiteralPath $script:CredFilePath -Value '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}' -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'fallback@example.com' }
                    organization = [pscustomobject]@{ name  = 'fallback-org' }
                }
            }

            Invoke-SaveAction -Name 'work' 6>$null

            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.work(fallback@example.com).json') | Should -BeTrue
            $sidecar = Join-Path $script:CredDirPath '.credentials.work(fallback@example.com).account.json'
            Test-Path -LiteralPath $sidecar | Should -BeTrue
            (Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json).source | Should -Be 'api_profile'
        }

        It 'refuses to save when neither ~/.claude.json nor /api/oauth/profile yields an identity' {
            # No ~/.claude.json at all; Get-OAuthAccountFromClaudeJson
            # returns $null. Common.ps1's default mock makes the profile
            # call throw, which Get-SlotProfile reports as 'error'.
            Remove-Item -LiteralPath $ClaudeJsonPath -Force -ErrorAction SilentlyContinue
            Set-Content -LiteralPath $script:CredFilePath -Value '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}' -NoNewline

            { Invoke-SaveAction -Name 'work' 6>$null } | Should -Throw -ExpectedMessage '*Cannot resolve account identity*'

            # No slot or sidecar created.
            @(Get-ChildItem -LiteralPath $script:CredDirPath -Filter '.credentials.work*.json' -Force).Count | Should -Be 0
        }

        It 'dedups the label when slot name equals the resolved email' {
            Set-SandboxClaudeJson -Email 'alice@example.com'
            Set-Content -LiteralPath $script:CredFilePath -Value '{"t":1}' -NoNewline

            Invoke-SaveAction -Name 'alice@example.com' 6>$null

            # Slot name == email -> no parenthesized suffix.
            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.alice@example.com.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.alice@example.com.account.json') | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:CredDirPath -Filter '.credentials.alice@example.com(*).json' -Force).Count | Should -Be 0
        }

        # When re-saving a slot whose account has changed, the old labeled
        # file AND its sidecar must be removed so we don't accumulate one
        # file per historical account under the same name.
        It 'removes a pre-existing labeled file + sidecar when re-saving with a different email' {
            $oldSlotPath    = Join-Path $script:CredDirPath '.credentials.work(old@example.com).json'
            $oldSidecarPath = Join-Path $script:CredDirPath '.credentials.work(old@example.com).account.json'
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'old@example.com' -Content 'stale' | Out-Null
            Test-Path -LiteralPath $oldSlotPath    | Should -BeTrue
            Test-Path -LiteralPath $oldSidecarPath | Should -BeTrue

            # Now ~/.claude.json says alice@example.com (the default).
            Set-Content -LiteralPath $script:CredFilePath -Value '{"t":1}' -NoNewline

            Invoke-SaveAction -Name 'work' 6>$null

            # Stale files removed.
            Test-Path -LiteralPath $oldSlotPath    | Should -BeFalse
            Test-Path -LiteralPath $oldSidecarPath | Should -BeFalse
            # New labeled pair present.
            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json')         | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.work(alice@example.com).account.json') | Should -BeTrue
        }

        It 'rolls back the slot file if sidecar write fails (atomic-pair semantics)' {
            Set-Content -LiteralPath $script:CredFilePath -Value '{"t":1}' -NoNewline

            # Force Write-Sidecar to throw by replacing it with a stub.
            # The save must clean up its tokens file so we don't leave
            # an invisible (sidecar-less) slot behind.
            Mock Write-Sidecar -MockWith { throw [System.Exception]::new('disk full') }

            { Invoke-SaveAction -Name 'work' 6>$null } | Should -Throw -ExpectedMessage '*Save failed for slot*previous slot state*'

            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json') | Should -BeFalse
        }

        # Re-saving an existing slot whose account has changed: the old
        # labeled pair must be restored on sidecar-write failure so the
        # user is never left without a slot for this name. Regression
        # guard for the "delete-before-write" bug.
        It 'restores the pre-existing labeled pair when sidecar write fails (different-email re-save)' {
            $oldSlotPath    = Join-Path $script:CredDirPath '.credentials.work(old@example.com).json'
            $oldSidecarPath = Join-Path $script:CredDirPath '.credentials.work(old@example.com).account.json'
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'old@example.com' -Content 'OLDBYTES' | Out-Null
            $oldSlotBytes    = [System.IO.File]::ReadAllBytes($oldSlotPath)
            $oldSidecarBytes = [System.IO.File]::ReadAllBytes($oldSidecarPath)

            # ~/.claude.json says alice@example.com (the default fixture).
            Set-Content -LiteralPath $script:CredFilePath -Value 'NEWBYTES' -NoNewline

            Mock Write-Sidecar -MockWith { throw [System.Exception]::new('disk full') }

            { Invoke-SaveAction -Name 'work' 6>$null } | Should -Throw -ExpectedMessage '*Save failed for slot*previous slot state*'

            # Old pair restored byte-equal.
            Test-Path -LiteralPath $oldSlotPath    | Should -BeTrue
            Test-Path -LiteralPath $oldSidecarPath | Should -BeTrue
            [System.IO.File]::ReadAllBytes($oldSlotPath)    | Should -Be $oldSlotBytes
            [System.IO.File]::ReadAllBytes($oldSidecarPath) | Should -Be $oldSidecarBytes

            # New-email pair absent.
            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json')         | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $script:CredDirPath '.credentials.work(alice@example.com).account.json') | Should -BeFalse
        }

        # Re-saving an existing slot for the SAME account (the typical
        # token-refresh capture case): finalSlotPath coincides with the
        # snapshot path, so the atomic Replace overwrites the old bytes
        # in place. On sidecar failure we must restore those bytes from
        # the in-memory snapshot, not just delete the new tokens file.
        It 'restores the pre-existing pair byte-equal when sidecar write fails (same-email re-save)' {
            $slotPath    = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json'
            $sidecarPath = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).account.json'
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content 'OLD' | Out-Null
            $oldSlotBytes    = [System.IO.File]::ReadAllBytes($slotPath)
            $oldSidecarBytes = [System.IO.File]::ReadAllBytes($sidecarPath)

            Set-Content -LiteralPath $script:CredFilePath -Value 'NEW' -NoNewline

            Mock Write-Sidecar -MockWith { throw [System.Exception]::new('disk full') }

            { Invoke-SaveAction -Name 'work' 6>$null } | Should -Throw -ExpectedMessage '*Save failed for slot*previous slot state*'

            # Tokens at the path reverted to OLD bytes (atomic Replace
            # already overwrote them; restore put them back).
            Test-Path -LiteralPath $slotPath    | Should -BeTrue
            Test-Path -LiteralPath $sidecarPath | Should -BeTrue
            [System.IO.File]::ReadAllBytes($slotPath)    | Should -Be $oldSlotBytes
            [System.IO.File]::ReadAllBytes($sidecarPath) | Should -Be $oldSidecarBytes
        }
    }

    Context 'Invoke-SaveAction (state file)' {
        It 'updates state.active_slot to the saved slot' {
            Set-Content -LiteralPath $script:CredFilePath -Value 'SAL' -NoNewline

            Invoke-SaveAction -Name 'work' 6>$null

            $state = Read-ScaState
            $state.active_slot | Should -Be 'work'
            $state.last_sync_hash | Should -Be (Get-FileHash -LiteralPath $script:CredFilePath -Algorithm SHA256).Hash
        }

        It 'leaves .credentials.json byte-equal to the new slot' {
            Set-Content -LiteralPath $script:CredFilePath -Value 'NEWBYTES' -NoNewline

            Invoke-SaveAction -Name 'work' 6>$null

            $slot = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json'
            Get-Content -LiteralPath $slot                -Raw | Should -Be 'NEWBYTES'
            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'NEWBYTES'
        }

        # Save while Claude Code holds .credentials.json open (with
        # FILE_SHARE_DELETE) must succeed for the read of bytes; Claude
        # Code is closed by contract (refuse-while-running guard) but a
        # background process (antivirus) might have it open. Regression
        # guard for the atomic-rename property.
        It 'succeeds when .credentials.json is open with FileShare::ReadWrite|Delete' {
            Set-Content -LiteralPath $script:CredFilePath -Value 'OPEN' -NoNewline

            $stream = [System.IO.File]::Open($script:CredFilePath, 'Open', 'Read', 'ReadWrite, Delete')
            try {
                { Invoke-SaveAction -Name 'work' 6>$null } | Should -Not -Throw
            }
            finally {
                $stream.Dispose()
            }

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
