#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-Reconcile in switch_claude_account.ps1.
#
# Reconcile is the heart of the new robust active-slot tracking model: on
# every credentials-touching action it brings the saved slot file in line
# with .credentials.json (which Claude Code may have rewritten via an
# atomic-rename refresh since the last sca call). The tests below exercise
# all four documented outcomes plus the offline-tolerance and missing-slot
# fallbacks. Per-test sandbox setup lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
    $script:OriginalHome        = $env:HOME
    $script:OriginalConfigDir   = $env:CLAUDE_CONFIG_DIR
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')

        $script:CD = Join-Path $script:SandboxHome '.claude'
        New-Item -ItemType Directory -Path $script:CD -Force | Out-Null

        # An OAuth-shaped credentials body. The exact tokens are irrelevant
        # because identity comes from ~/.claude.json (or the fallback profile
        # endpoint); the JSON only needs to be parseable by Get-SlotOAuth.
        $script:CredsBody = '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}'
    }

    # ----- noop branches -------------------------------------------------

    Context 'Invoke-Reconcile (noop)' {
        It 'returns noop when .credentials.json is missing' {
            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'noop'
            $r.Reason | Should -Be 'no-active-credentials'

            # No state file should have been written by a noop.
            Test-Path -LiteralPath $StateFile | Should -BeFalse
        }

        It 'returns noop when hash matches state.last_sync_hash' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = Join-Path $script:CD '.credentials.work.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            Set-Content -LiteralPath $slotFile -Value $script:CredsBody -NoNewline

            # Seed state with the current hash (matching .credentials.json).
            $hash = (Get-FileHash -LiteralPath $credFile -Algorithm SHA256).Hash
            Update-ScaState -ActiveSlot 'work' -LastSyncHash $hash | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'noop'
            $r.Reason | Should -Be 'hash-match'
        }
    }

    # ----- mirror branch -------------------------------------------------

    Context 'Invoke-Reconcile (mirror)' {
        It 'mirrors .credentials.json into the tracked slot when emails match' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            # Sidecar email == ~/.claude.json email -> mirror branch.
            $slotFile = New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'STALE_OLD_CONTENT'
            Set-SandboxClaudeJson -Email 'alice@example.com'

            # Seed state pointing at the slot, with a stale hash so the
            # noop fast-path doesn't fire.
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE_HASH' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            $r.Slot   | Should -Be 'work'

            # Slot file now byte-equal to .credentials.json.
            Get-Content -LiteralPath $slotFile -Raw | Should -Be $script:CredsBody

            # state.last_sync_hash updated to the current hash.
            $expectedHash = (Get-FileHash -LiteralPath $credFile -Algorithm SHA256).Hash
            (Read-ScaState).last_sync_hash | Should -Be $expectedHash
        }

        # Offline tolerance: when ~/.claude.json is missing AND the
        # /api/oauth/profile fallback fails, the new identity is unknown
        # and we mirror rather than auto-save. Same "preserve continuity"
        # principle as before, just with the new probe.
        It 'mirrors when neither ~/.claude.json nor /api/oauth/profile yields an email' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            $slotFile = New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'STALE'

            # ~/.claude.json missing entirely; default Common.ps1 mock
            # makes the profile endpoint throw.
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            $r.Slot   | Should -Be 'work'

            Get-Content -LiteralPath $slotFile -Raw | Should -Be $script:CredsBody
        }
    }

    # ----- identity-change branch ----------------------------------------

    Context 'Invoke-Reconcile (identity-change)' {
        It 'auto-saves under a new name when emails differ; preserves previous slot' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            $slotFile = New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'OLD_ALICE_TOKENS'

            # New identity probe via ~/.claude.json: bob != alice -> identity-change.
            Set-SandboxClaudeJson -Email 'bob@example.com' -AccountUuid 'bob-uuid' -OrganizationName 'bob-org'

            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action       | Should -Be 'identity-change'
            $r.PreviousSlot | Should -Be 'work'
            $r.Email        | Should -Be 'bob@example.com'
            $r.Slot         | Should -Match '^auto-\d{8}T\d{6}Z$'

            # Original slot file (alice's tokens) preserved untouched.
            Get-Content -LiteralPath $slotFile -Raw | Should -Be 'OLD_ALICE_TOKENS'

            # New auto-save slot AND its sidecar exist, labeled with bob's email.
            $autoPath    = Join-Path $script:CD ".credentials.$($r.Slot)(bob@example.com).json"
            $autoSidecar = Join-Path $script:CD ".credentials.$($r.Slot)(bob@example.com).account.json"
            Test-Path -LiteralPath $autoPath    | Should -BeTrue
            Test-Path -LiteralPath $autoSidecar | Should -BeTrue
            Get-Content -LiteralPath $autoPath -Raw | Should -Be $script:CredsBody
            $sidecarObj = Get-Content -LiteralPath $autoSidecar -Raw | ConvertFrom-Json
            $sidecarObj.oauthAccount.emailAddress | Should -Be 'bob@example.com'
            $sidecarObj.oauthAccount.accountUuid  | Should -Be 'bob-uuid'

            (Read-ScaState).active_slot | Should -Be $r.Slot
        }
    }

    # ----- auto-save branch ----------------------------------------------

    Context 'Invoke-Reconcile (auto-save)' {
        It 'auto-saves when no state file exists and identity comes from ~/.claude.json' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            Set-SandboxClaudeJson -Email 'fresh@example.com' -AccountUuid 'fresh-uuid'

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'auto-save'
            $r.Email  | Should -Be 'fresh@example.com'
            $r.Slot   | Should -Match '^auto-\d{8}T\d{6}Z$'

            # Auto-saved slot file with labeled form + sidecar.
            $autoPath    = Join-Path $script:CD ".credentials.$($r.Slot)(fresh@example.com).json"
            $autoSidecar = Join-Path $script:CD ".credentials.$($r.Slot)(fresh@example.com).account.json"
            Test-Path -LiteralPath $autoPath    | Should -BeTrue
            Test-Path -LiteralPath $autoSidecar | Should -BeTrue
            Get-Content -LiteralPath $autoPath -Raw | Should -Be $script:CredsBody

            (Read-ScaState).active_slot | Should -Be $r.Slot
        }

        It 'auto-saves with unlabeled form (no sidecar) when both identity sources fail' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            # No ~/.claude.json, default mock for profile endpoint throws.
            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'auto-save'
            $r.Email  | Should -BeNullOrEmpty

            # Slot file exists but no sidecar -> Get-Slots will hide it.
            # Bytes are preserved on disk; user can `sca remove auto-<ts>`
            # to clean up if they don't want it.
            $autoPath = Join-Path $script:CD ".credentials.$($r.Slot).json"
            Test-Path -LiteralPath $autoPath | Should -BeTrue
        }

        # state.active_slot was set on a previous run, but the slot file
        # has since been deleted (e.g. user manually rm'd it). Reconcile
        # must not crash; it falls through to auto-save so the new bytes
        # are still captured under a generated name.
        It 'auto-saves when state.active_slot points at a missing slot file' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            Update-ScaState -ActiveSlot 'gone-slot' -LastSyncHash 'STALE' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'auto-save'
            $r.Slot   | Should -Match '^auto-\d{8}T\d{6}Z$'

            (Read-ScaState).active_slot | Should -Be $r.Slot
        }

        It 'prints a yellow advisory line for auto-save' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            $out = Invoke-Reconcile 6>&1 | Out-String
            $out | Should -Match '\[Sync\] Auto-saved unknown active credentials as'
        }

        It 'prints a yellow advisory line for identity-change' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'OLD' | Out-Null
            Set-SandboxClaudeJson -Email 'bob@example.com'

            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            $out = Invoke-Reconcile 6>&1 | Out-String
            $out | Should -Match "\[Sync\] Active credentials are now bob@example\.com"
            $out | Should -Match "previous slot 'work' \(alice@example\.com\) preserved"
        }
    }

    # ----- migration via Read-ScaState's hash-bootstrap ------------------

    Context 'Invoke-Reconcile (migration)' {
        # Read-ScaState auto-migrates by hash on first call when the state
        # file is missing. Reconcile sees the result as a normal state and
        # branches into noop because the hash matches what the migration
        # just wrote. Verifies migration -> noop integrates cleanly.
        It 'noops on first run when hash matches an existing slot (silent migration)' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            New-SlotPair -CredDir $script:CD -Name 'work' -Content $script:CredsBody | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'noop'
            $r.Reason | Should -Be 'hash-match'

            (Read-ScaState).active_slot | Should -Be 'work'
        }
    }

    # ----- /api/oauth/profile identity-fallback path --------------------
    #
    # When ~/.claude.json has no oauthAccount block (Get-OAuthAccountFromClaudeJson
    # returns $null), reconcile falls back to /api/oauth/profile to learn
    # the current identity. The synthesized accountInfo has only
    # emailAddress populated; the other four fields default to $null.
    # Exercises the lines 1362-1382 branch that the claude.json-only
    # tests above cannot reach.

    Context 'Invoke-Reconcile (profile-endpoint fallback identity)' {
        It 'auto-saves using the /api/oauth/profile email when claude.json has no oauthAccount' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            # ~/.claude.json present but has no oauthAccount, so
            # Get-OAuthAccountFromClaudeJson returns $null and the
            # profile fallback fires.
            Set-Content -LiteralPath $ClaudeJsonPath -Value '{"numStartups":1}' -NoNewline -Encoding utf8NoBOM

            # Override Common.ps1's default profile mock (which throws)
            # to return a real ok+Email shape.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account = [pscustomobject]@{ email = 'fallback@example.com' }
                }
            }

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'auto-save'
            $r.Email  | Should -Be 'fallback@example.com'

            # Auto-save slot is labeled with the fallback email and a sidecar exists.
            $autoPath    = Join-Path $script:CD ".credentials.$($r.Slot)(fallback@example.com).json"
            $autoSidecar = Join-Path $script:CD ".credentials.$($r.Slot)(fallback@example.com).account.json"
            Test-Path -LiteralPath $autoPath    | Should -BeTrue
            Test-Path -LiteralPath $autoSidecar | Should -BeTrue

            # Sidecar source is 'api_profile' (not 'claude_json') because
            # the synthesized accountInfo has no accountUuid.
            $sidecar = Get-Content -LiteralPath $autoSidecar -Raw | ConvertFrom-Json
            $sidecar.source | Should -Be 'api_profile'
            $sidecar.oauthAccount.emailAddress | Should -Be 'fallback@example.com'
            # The four optional fields default to $null in the fallback path.
            $sidecar.oauthAccount.accountUuid      | Should -BeNullOrEmpty
            $sidecar.oauthAccount.organizationUuid | Should -BeNullOrEmpty
        }

        # When state.active_slot points at a slot whose sidecar email
        # matches the profile-fallback email, reconcile mirrors (no
        # cross-account swap). Exercises the sidecar-email comparison
        # via the profile fallback.
        It 'mirrors when claude.json is empty but profile fallback email matches the tracked slot' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            $slotFile = New-SlotPair -CredDir $script:CD -Name 'work' -Email 'samesame@example.com' -Content 'STALE'
            Set-Content -LiteralPath $ClaudeJsonPath -Value '{"numStartups":1}' -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account = [pscustomobject]@{ email = 'samesame@example.com' }
                }
            }

            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            $r.Slot   | Should -Be 'work'

            Get-Content -LiteralPath $slotFile -Raw | Should -Be $script:CredsBody
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
