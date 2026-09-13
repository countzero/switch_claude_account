#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-SwitchAction in switch_claude_account.ps1.
#
# Post-v2.1.0 contract:
#   * Refuses to operate while Claude Code is running.
#   * Refuses to switch to a slot that has no sidecar.
#   * Restores the destination slot's captured oauthAccount into
#     ~/.claude.json so /status displays the active slot's email.
#   * .credentials.json byte-equal to the slot file post-switch.
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
    }

    Context 'Invoke-SwitchAction' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'

            # Default ~/.claude.json so the switch's Set-OAuthAccount...
            # call has something to mutate. Tests that exercise the
            # missing-claude-json path override this.
            Set-SandboxClaudeJson -Email 'baseline@example.com'
        }

        It 'copies named slot to active credentials byte-for-byte' {
            $slot = New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Content ([byte[]](0xDE,0xAD,0xBE,0xEF))

            Invoke-SwitchAction -Name 'work' 6>$null

            [System.IO.File]::ReadAllBytes($script:CredFilePath) | Should -Be ([byte[]](0xDE,0xAD,0xBE,0xEF))
        }

        # `sca switch <name>` must find the slot file whether it was saved
        # with the labeled form `.credentials.<slot>(<email>).json` or the
        # unlabeled form. User types the slot-name only; Find-SlotByName
        # resolves to the right file by parsing the filename.
        It 'finds a labeled slot file by slot-name only' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content ([byte[]](0xBE,0xEF)) | Out-Null

            Invoke-SwitchAction -Name 'work' 6>$null

            [System.IO.File]::ReadAllBytes($script:CredFilePath) | Should -Be ([byte[]](0xBE,0xEF))
        }

        It 'throws when the named slot does not exist' {
            { Invoke-SwitchAction -Name 'missing' 6>$null } | Should -Throw -ExpectedMessage "*Slot 'missing' not found*"
        }

        It 'refuses to switch to a slot that has no sidecar (post-v2.1.0)' {
            # Bare slot file without sidecar; invisible, treated as "not found".
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.legacy.json') -Value 'L' -NoNewline

            { Invoke-SwitchAction -Name 'legacy' 6>$null } | Should -Throw -ExpectedMessage "*Slot 'legacy' not found*"
        }

        It 'refuses to operate while Claude Code is running' {
            Mock Test-ClaudeRunning -MockWith { $true }
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Content 'X' | Out-Null

            { Invoke-SwitchAction -Name 'work' 6>$null } | Should -Throw -ExpectedMessage '*Claude Code is running*'
            # .credentials.json untouched.
            Test-Path -LiteralPath $script:CredFilePath | Should -BeFalse
        }

        It 'overwrites an existing active credentials file' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Content 'NEW' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'OLD' -NoNewline

            Invoke-SwitchAction -Name 'work' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'NEW'
        }

        It 'rotates to the next slot alphabetically when called without a name' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'b' -Content 'B' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'c' -Content 'C' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'B' -NoNewline

            Invoke-SwitchAction -Name '' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'C'
        }

        It 'rotation wraps from the last slot back to the first' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'b' -Content 'B' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'B' -NoNewline

            Invoke-SwitchAction -Name '' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'A'
        }

        It 'rotation throws when no slots are saved' {
            { Invoke-SwitchAction -Name '' 6>$null } | Should -Throw -ExpectedMessage '*No slots saved*'
        }

        # Regression for the "no currently active slot detected" advisory:
        # fires when reconcile noops (no .credentials.json) AND state has
        # no active_slot AND slots are saved. Rotation still proceeds to
        # the first slot alphabetically.
        It "prints '[Switch] No currently active slot detected' advisory when no active slot is tracked" {
            # No .credentials.json -> reconcile noops with
            # 'no-active-credentials' so no auto-save happens.
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null

            $out = Invoke-SwitchAction -Name '' 6>&1 | Out-String

            $out | Should -Match '\[Switch\] No currently active slot detected'
            $out | Should -Match "Rotating to 'alpha'"
            # Rotation landed on the first slot alphabetically.
            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'A'
        }

        It 'rotation is a no-op when only one slot exists and it is active' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'only' -Content 'X' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'X' -NoNewline

            { Invoke-SwitchAction -Name '' 6>$null } | Should -Not -Throw

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'X'
        }

        # Active credentials don't match any saved slot: reconcile auto-saves
        # them under a fresh `auto-<ts>` name (preserving the unknown
        # tokens) and then rotation moves to the next alphabetical slot
        # AFTER the auto-name. With slots [a, auto-<ts>, b] and active
        # = auto-<ts>, the next alphabetical slot is 'b'.
        It 'rotation auto-saves unknown active credentials and rotates from there' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'b' -Content 'B' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'UNKNOWN' -NoNewline

            $out = Invoke-SwitchAction -Name '' 6>&1 | Out-String

            # Reconcile auto-save advisory.
            $out | Should -Match '\[Sync\] Auto-saved unknown active credentials'

            # Auto slot exists with the unknown bytes preserved.
            $autoFiles = @(Get-ChildItem -LiteralPath $script:CredDirPath -Filter '.credentials.auto-*.json' -Force |
                Where-Object { $_.Name -notlike '*.account.json' })
            $autoFiles.Count | Should -Be 1
            Get-Content -LiteralPath $autoFiles[0].FullName -Raw | Should -Be 'UNKNOWN'

            # Rotation lands on 'b' (next alphabetical after 'auto-<ts>').
            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'B'
        }

        # Regression: if a literal bracket-containing slot file exists on disk
        # (e.g., from a pre-sanitization version or manual placement), rotation
        # must land on it without PowerShell's -Path wildcard expansion
        # matching unrelated slots.
        It 'rotation onto a literal bracket slot copies the correct bytes' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'a'      -Content 'A'  | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'b[c]'   -Content 'BC' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'A' -NoNewline

            Invoke-SwitchAction -Name '' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'BC'
        }

        # The new switch output renders the filename-encoded email
        # alongside the slot name so the user sees which account they
        # just activated. The format is `'<slot>' (<email>)` for labeled
        # slots, plain `'<slot>'` for unlabeled / dedup slots.
        It "renders email in success message when target slot is labeled" {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content 'X' | Out-Null

            $out = Invoke-SwitchAction -Name 'work' 6>&1 | Out-String

            $out | Should -Match "Switched to 'work' \(alice@example\.com\)"
        }

        It "omits email parens when target slot is unlabeled" {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Content 'X' | Out-Null

            $out = Invoke-SwitchAction -Name 'work' 6>&1 | Out-String

            # `(?m)...$` anchors the slot identity to end-of-line so an
            # accidental `(email)` suffix or a stale trailing period would
            # both fail this assertion. The success line is now a yellow
            # header without a trailing dot.
            $out | Should -Match "(?m)Switched to 'work'\s*$"
            $out | Should -Not -Match '\([^)]*@[^)]*\)'
        }

        It "omits email parens when slot name equals the embedded email (dedup form)" {
            $email = 'alice@example.com'
            New-SlotPair -CredDir $script:CredDirPath -Name $email -Content 'X' | Out-Null

            $out = Invoke-SwitchAction -Name $email 6>&1 | Out-String

            $out | Should -Match "(?m)Switched to '$([regex]::Escape($email))'\s*$"
            # No `(alice@example.com)` suffix duplicating the slot name.
            $out | Should -Not -Match "'$([regex]::Escape($email))' \($([regex]::Escape($email))\)"
        }

        It 'rotation prints success line for destination + table beneath' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'slot-1' -Email 'alice@example.com' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'slot-2' -Email 'bob@example.com'   -Content 'B' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'B' -NoNewline

            $out = Invoke-SwitchAction -Name '' 6>&1 | Out-String

            $out | Should -Match "Switched to 'slot-1' \(alice@example\.com\)"
            $out | Should -Match '(?m)^\s+Slot\s+Account\s*$'
            $out | Should -Match '(?m)^\s+\*\s+slot-1\s+alice@example\.com\b'
            $out | Should -Match '(?m)^\s+slot-2\s+bob@example\.com\b'
            $out | Should -Not -Match 'Rotating from'
        }

        It 'rotation does not print the rotation banner' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'A' -NoNewline

            $out = Invoke-SwitchAction -Name '' 6>&1 | Out-String

            $out | Should -Not -Match 'Rotating'
            $out | Should -Match "Switched to 'bravo'"
        }

        It 'named switch prints the saved-slot table beneath the success line' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null

            $out = Invoke-SwitchAction -Name 'alpha' 6>&1 | Out-String

            $out | Should -Match "Switched to 'alpha'"
            $out | Should -Match '(?m)^\s+Slot\s+Account\s*$'
            $out | Should -Not -Match '\[List\] Saved slots'
        }

        It 'switch table marks the just-activated slot with *' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'B' -NoNewline

            $out = Invoke-SwitchAction -Name 'alpha' 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+\*\s+alpha\s'
            $out | Should -Match '(?m)^\s+bravo\s'
            $out | Should -Not -Match '(?m)^\s+\*\s+bravo\s'
        }

        It 'success line drops the "Close and restart" wording and the trailing period' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content 'X' | Out-Null

            $out = Invoke-SwitchAction -Name 'work' 6>&1 | Out-String

            $out | Should -Not -Match "Switched to[^`r`n]*Close and restart"
            $out | Should -Match "Switched to 'work' \(alice@example\.com\)(?!\.)"
        }

        It "table appears beneath the [Switch] header" {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Content 'B' | Out-Null

            $out = Invoke-SwitchAction -Name 'alpha' 6>&1 | Out-String

            # The retired [Info] apply hint must not reappear; the previous
            # "Restart Claude Code…running sessions" wording from before
            # the refuse-while-running guard is also gone.
            $out | Should -Not -Match '\[Info\] Start'
            $out | Should -Not -Match 'running sessions may continue'

            # Ordering check: [Switch] header < active table row.
            $switchIdx = $out.IndexOf('[Switch] Switched')
            $rowIdx    = ($out | Select-String -Pattern '(?m)^\s+\*\s+alpha\s').Matches[0].Index
            $switchIdx | Should -BeLessThan $rowIdx
        }

        It "single-slot no-op skips the success line and table" {
            New-SlotPair -CredDir $script:CredDirPath -Name 'only' -Content 'X' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'X' -NoNewline

            $out = Invoke-SwitchAction -Name '' 6>&1 | Out-String

            $out | Should -Match 'Only one slot'
            $out | Should -Match 'already active'
            $out | Should -Not -Match 'Switched to'
        }
    }

    Context 'Invoke-SwitchAction (~/.claude.json mutation)' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'

            # Pre-existing ~/.claude.json with one identity.
            Set-SandboxClaudeJson -Email 'old@example.com' -AccountUuid 'old-uuid' -OrganizationName 'old-org'
        }

        It "writes the destination slot's oauthAccount fields into ~/.claude.json" {
            New-SlotPair -CredDir $script:CredDirPath -Name 'slot' -Email 'new@example.com' -Content 'X' -OAuthAccount ([pscustomobject]@{
                accountUuid      = 'new-uuid'
                emailAddress     = 'new@example.com'
                organizationUuid = 'new-org-uuid'
                displayName      = 'New User'
                organizationName = 'new-org'
            }) | Out-Null

            Invoke-SwitchAction -Name 'slot' 6>$null

            $obj = Get-Content -LiteralPath $ClaudeJsonPath -Raw | ConvertFrom-Json
            $obj.oauthAccount.emailAddress     | Should -Be 'new@example.com'
            $obj.oauthAccount.accountUuid      | Should -Be 'new-uuid'
            $obj.oauthAccount.organizationUuid | Should -Be 'new-org-uuid'
            $obj.oauthAccount.displayName      | Should -Be 'New User'
            $obj.oauthAccount.organizationName | Should -Be 'new-org'
        }

        It 'preserves non-whitelisted top-level fields in ~/.claude.json byte-equal' {
            # Add some unrelated fields to ~/.claude.json. Switch must
            # leave them untouched so we don't accidentally clobber
            # Claude Code's project history / mcp configs / etc.
            Set-SandboxClaudeJson -Email 'old@example.com' -ExtraTopLevel @{
                projects        = @{ 'D:\foo' = @{ allowed = $true; lastUsedDate = '2026-01-01' } }
                mcpServers      = @{ memory = @{ command = 'mcp-memory' } }
                customSomething = 'sentinel-value-xyz'
            }
            $beforeRaw = Get-Content -LiteralPath $ClaudeJsonPath -Raw

            New-SlotPair -CredDir $script:CredDirPath -Name 'slot' -Email 'new@example.com' -Content 'X' | Out-Null

            Invoke-SwitchAction -Name 'slot' 6>$null

            $afterObj = Get-Content -LiteralPath $ClaudeJsonPath -Raw | ConvertFrom-Json
            # Top-level fields untouched.
            $afterObj.customSomething               | Should -Be 'sentinel-value-xyz'
            $afterObj.projects.'D:\foo'.allowed     | Should -BeTrue
            $afterObj.mcpServers.memory.command     | Should -Be 'mcp-memory'

            # The sentinel value still appears verbatim in the raw file:
            # we did not re-serialize it.
            $afterRaw = Get-Content -LiteralPath $ClaudeJsonPath -Raw
            $afterRaw | Should -Match 'sentinel-value-xyz'
        }

        It 'preserves non-whitelisted oauthAccount metadata fields (billingType, accountCreatedAt, etc.)' {
            $beforeObj = Get-Content -LiteralPath $ClaudeJsonPath -Raw | ConvertFrom-Json
            $beforeBillingType         = $beforeObj.oauthAccount.billingType
            $beforeAccountCreatedAt    = $beforeObj.oauthAccount.accountCreatedAt
            $beforeSubscriptionCreated = $beforeObj.oauthAccount.subscriptionCreatedAt

            New-SlotPair -CredDir $script:CredDirPath -Name 'slot' -Email 'new@example.com' -Content 'X' | Out-Null

            Invoke-SwitchAction -Name 'slot' 6>$null

            $afterObj = Get-Content -LiteralPath $ClaudeJsonPath -Raw | ConvertFrom-Json
            $afterObj.oauthAccount.billingType           | Should -Be $beforeBillingType
            $afterObj.oauthAccount.accountCreatedAt      | Should -Be $beforeAccountCreatedAt
            $afterObj.oauthAccount.subscriptionCreatedAt | Should -Be $beforeSubscriptionCreated
        }

        # Regression guard for the fix that blocks real → null overwrites:
        # /api/oauth/profile-fallback sidecars carry only emailAddress; the
        # other four whitelisted fields default to $null. Switching to such
        # a slot must NOT overwrite Claude Code's populated ~/.claude.json
        # cache with null literals; the cached value is the better source
        # of truth than no value.
        It 'preserves populated ~/.claude.json fields when sidecar carries nulls' {
            Set-SandboxClaudeJson `
                -Email 'old@example.com' `
                -AccountUuid 'preserved-uuid-123' `
                -OrganizationUuid 'preserved-org-uuid' `
                -DisplayName 'Preserved User' `
                -OrganizationName 'Preserved Org'

            New-SlotPair -CredDir $script:CredDirPath -Name 'slot' -Email 'new@example.com' -Content 'X' -OAuthAccount ([pscustomobject]@{
                accountUuid      = $null
                emailAddress     = 'new@example.com'
                organizationUuid = $null
                displayName      = $null
                organizationName = $null
            }) | Out-Null

            Invoke-SwitchAction -Name 'slot' 6>$null

            $obj = Get-Content -LiteralPath $ClaudeJsonPath -Raw | ConvertFrom-Json
            # Email IS updated (the only sidecar field that was non-null).
            $obj.oauthAccount.emailAddress     | Should -Be 'new@example.com'
            # The other four are PRESERVED from ~/.claude.json's existing values.
            $obj.oauthAccount.accountUuid      | Should -Be 'preserved-uuid-123'
            $obj.oauthAccount.organizationUuid | Should -Be 'preserved-org-uuid'
            $obj.oauthAccount.displayName      | Should -Be 'Preserved User'
            $obj.oauthAccount.organizationName | Should -Be 'Preserved Org'
        }

        # Asymmetric-design check: blocking real → null must NOT also block
        # null → real. A user whose ~/.claude.json had null cached fields
        # (partial sign-in state) should still see those fields populated
        # when they switch to a slot whose sidecar has the real values.
        It 'upgrades previously-null ~/.claude.json fields when the sidecar carries real values' {
            $rawJson = @'
{
  "numStartups": 1,
  "autoUpdates": true,
  "oauthAccount": {
    "accountUuid": null,
    "emailAddress": "old@example.com",
    "organizationUuid": null,
    "displayName": null,
    "organizationName": null
  }
}
'@
            Set-Content -LiteralPath $ClaudeJsonPath -Value $rawJson -NoNewline -Encoding utf8NoBOM

            New-SlotPair -CredDir $script:CredDirPath -Name 'slot' -Email 'new@example.com' -Content 'X' -OAuthAccount ([pscustomobject]@{
                accountUuid      = 'fresh-uuid'
                emailAddress     = 'new@example.com'
                organizationUuid = 'fresh-org-uuid'
                displayName      = 'Fresh User'
                organizationName = 'Fresh Org'
            }) | Out-Null

            Invoke-SwitchAction -Name 'slot' 6>$null

            $obj = Get-Content -LiteralPath $ClaudeJsonPath -Raw | ConvertFrom-Json
            # All five fields upgraded from null to the sidecar's real values.
            $obj.oauthAccount.accountUuid      | Should -Be 'fresh-uuid'
            $obj.oauthAccount.emailAddress     | Should -Be 'new@example.com'
            $obj.oauthAccount.organizationUuid | Should -Be 'fresh-org-uuid'
            $obj.oauthAccount.displayName      | Should -Be 'Fresh User'
            $obj.oauthAccount.organizationName | Should -Be 'Fresh Org'
        }

        # Failure path: ~/.claude.json missing or malformed shouldn't
        # cascade into a broken switch; the credentials swap already
        # happened, we just emit a yellow advisory.
        It 'tolerates ~/.claude.json missing (yellow advisory; tokens still swap)' {
            Remove-Item -LiteralPath $ClaudeJsonPath -Force -ErrorAction SilentlyContinue
            New-SlotPair -CredDir $script:CredDirPath -Name 'slot' -Content 'X' | Out-Null

            $out = Invoke-SwitchAction -Name 'slot' 6>&1 | Out-String

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'X'
            $out | Should -Match '~/\.claude\.json oauthAccount update failed'
        }
    }

    Context 'Invoke-SwitchAction (state file)' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
            Set-SandboxClaudeJson -Email 'baseline@example.com'
        }

        It 'updates state.active_slot to the switched slot' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Content ([byte[]](0xDE,0xAD)) | Out-Null

            Invoke-SwitchAction -Name 'work' 6>$null

            (Read-ScaState).active_slot | Should -Be 'work'
            (Read-ScaState).last_sync_hash |
                Should -Be (Get-FileHash -LiteralPath $script:CredFilePath -Algorithm SHA256).Hash
        }

        It 'succeeds when .credentials.json is open with FileShare::ReadWrite|Delete' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Content 'NEW' | Out-Null
            Set-Content -LiteralPath $script:CredFilePath -Value 'OLD' -NoNewline

            $stream = [System.IO.File]::Open($script:CredFilePath, 'Open', 'Read', 'ReadWrite, Delete')
            try {
                { Invoke-SwitchAction -Name 'work' 6>$null } | Should -Not -Throw
            }
            finally {
                $stream.Dispose()
            }

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'NEW'
        }

        # Reconcile runs first, before the slot lookup. Verifies that a
        # pending Claude Code refresh on the outgoing active slot is
        # captured into its saved-slot file BEFORE we overwrite
        # .credentials.json with the destination slot.
        It 'reconciles before switching: outgoing slot bytes match the active file' {
            $oldSlot = New-SlotPair -CredDir $script:CredDirPath -Name 'old' -Content 'STALE_OLD'  -OAuthAccount ([pscustomobject]@{
                accountUuid      = 'old-uuid'
                emailAddress     = 'baseline@example.com'
                organizationUuid = 'old-org-uuid'
                displayName      = 'Old'
                organizationName = 'old-org'
            })
            $newSlot = New-SlotPair -CredDir $script:CredDirPath -Name 'new' -Content 'NEW_TARGET'

            Set-Content -LiteralPath $script:CredFilePath -Value 'REFRESHED' -NoNewline
            Update-ScaState -ActiveSlot 'old' -LastSyncHash 'STALE_HASH' | Out-Null

            Invoke-SwitchAction -Name 'new' 6>$null

            Get-Content -LiteralPath $oldSlot              -Raw | Should -Be 'REFRESHED'
            Get-Content -LiteralPath $script:CredFilePath  -Raw | Should -Be 'NEW_TARGET'
            (Read-ScaState).active_slot | Should -Be 'new'
        }
    }

    Context 'Invoke-SlotSwap' {
        # Direct tests for the swap helper extracted from
        # Invoke-SwitchAction; the watch loop's -Auto path calls
        # Invoke-SlotSwap directly without going through
        # Invoke-SwitchAction's reconcile + name resolution, so the
        # helper's invariants need their own coverage.
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
            Set-SandboxClaudeJson -Email 'baseline@example.com'
        }

        It 'writes the slot bytes into .credentials.json' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content ([byte[]](0xC0,0xDE,0x01)) | Out-Null
            $slot = Find-SlotByName -Name 'work'

            Invoke-SlotSwap -Slot $slot 6>$null

            [System.IO.File]::ReadAllBytes($script:CredFilePath) | Should -Be ([byte[]](0xC0,0xDE,0x01))
        }

        It 'updates state.active_slot to the swapped-in slot name' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content 'X' | Out-Null
            $slot = Find-SlotByName -Name 'work'

            Invoke-SlotSwap -Slot $slot 6>$null

            (Read-ScaState).active_slot | Should -Be 'work'
        }

        It "substitutes the slot's oauthAccount email into ~/.claude.json" {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content 'X' | Out-Null
            $slot = Find-SlotByName -Name 'work'

            Invoke-SlotSwap -Slot $slot 6>$null

            $claudeJson = Get-Content -LiteralPath $ClaudeJsonPath -Raw
            $claudeJson | Should -Match '"emailAddress"\s*:\s*"alice@example\.com"'
            # Pre-swap email is gone.
            $claudeJson | Should -Not -Match '"emailAddress"\s*:\s*"baseline@example\.com"'
        }

        It 'does NOT print the [Switch] header line (Invoke-SwitchAction owns that, not Invoke-SlotSwap)' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content 'X' | Out-Null
            $slot = Find-SlotByName -Name 'work'

            $out = Invoke-SlotSwap -Slot $slot 6>&1 | Out-String

            $out | Should -Not -Match '\[Switch\] Switched to'
        }

        It 'does NOT call Test-ClaudeRunning itself (caller is responsible for that guard)' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'work' -Email 'alice@example.com' -Content 'X' | Out-Null
            $slot = Find-SlotByName -Name 'work'

            Mock Test-ClaudeRunning -MockWith { $true }

            { Invoke-SlotSwap -Slot $slot 6>$null } | Should -Not -Throw
            Should -Invoke Test-ClaudeRunning -Times 0
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
