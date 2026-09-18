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

        # When ~/.claude.json is missing AND the /api/oauth/profile fallback
        # fails, nothing can say whose tokens these are. Mirroring on a guess
        # is what overwrote a working login in practice, so the unattributable
        # case now writes nothing at all and waits for a later reconcile.
        It 'refuses to write when neither ~/.claude.json nor /api/oauth/profile yields an email' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            $slotFile = New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'STALE'

            # ~/.claude.json missing entirely; default Common.ps1 mock
            # makes the profile endpoint throw.
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'noop'
            $r.Reason | Should -Be 'identity-unresolved'
            $r.Slot   | Should -Be 'work'

            # The slot file is the artifact a login cannot be recovered from.
            Get-Content -LiteralPath $slotFile -Raw | Should -Be 'STALE'

            # And the hash is NOT advanced, so the next reconcile retries.
            (Read-ScaState).last_sync_hash | Should -Be 'STALE'
        }

        It 'names the untouched slot in a yellow advisory when identity is unresolvable' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'STALE' | Out-Null
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            $out = Invoke-Reconcile 6>&1 | Out-String
            # The advisory has to name both failed sources and the recovery
            # step, because the user's only other signal is slot files
            # silently ceasing to track refreshes.
            $out | Should -Match 'no account could be read'
            $out | Should -Match '~/\.claude\.json'
            $out | Should -Match '/api/oauth/profile'
            $out | Should -Match "slot 'work' is left untouched"
            $out | Should -Match "re-run 'sca save work'"
        }
    }

    # ----- adopt branch --------------------------------------------------

    Context 'Invoke-Reconcile (adopt)' {
        # The shape of a real incident: something moved another slot's bytes
        # into .credentials.json while state still named the old slot. The
        # email probe reads ~/.claude.json, which had not caught up, so it
        # reported "same account" and the bytes were mirrored over the tracked
        # slot, destroying that login. Byte equality settles it instead.
        It 'adopts the matching slot instead of mirroring another account over the tracked one' {
            $credFile  = Join-Path $script:CD '.credentials.json'
            $otherBody = '{"claudeAiOauth":{"accessToken":"sk-ant-oat-OTHER","refreshToken":"sk-ant-ort-OTHER","expiresAt":9999999999999}}'

            # 'work' is tracked active and holds its own tokens.
            $workFile = New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content $script:CredsBody
            # 'personal' holds different tokens, and those are what is active.
            $persFile = New-SlotPair -CredDir $script:CD -Name 'personal' -Email 'bob@example.com' -Content $otherBody
            Set-Content -LiteralPath $credFile -Value $otherBody -NoNewline

            # ~/.claude.json still shows the OLD account: the lying probe.
            Set-SandboxClaudeJson -Email 'alice@example.com'
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE_HASH' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action       | Should -Be 'adopt'
            $r.Slot         | Should -Be 'personal'
            $r.PreviousSlot | Should -Be 'work'

            # Neither slot file was written.
            Get-Content -LiteralPath $workFile -Raw | Should -Be $script:CredsBody
            Get-Content -LiteralPath $persFile -Raw | Should -Be $otherBody

            # State now tracks the slot that is genuinely active.
            $st = Read-ScaState
            $st.active_slot    | Should -Be 'personal'
            $st.last_sync_hash | Should -Be (Get-FileHash -LiteralPath $credFile -Algorithm SHA256).Hash

            # Adopt is the one outcome that changes WHICH account is active, so
            # it must carry the identity across. Left stale, the next reconcile
            # would read 'alice', find it differs from the adopted slot's 'bob',
            # and auto-save a duplicate of an account already saved.
            (Get-OAuthAccountFromClaudeJson).emailAddress | Should -Be 'bob@example.com'
        }

        It 'adopts anyway when the ~/.claude.json identity update fails' {
            $credFile  = Join-Path $script:CD '.credentials.json'
            $otherBody = '{"claudeAiOauth":{"accessToken":"sk-ant-oat-OTHER","refreshToken":"sk-ant-ort-OTHER","expiresAt":9999999999999}}'
            New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content $script:CredsBody | Out-Null
            New-SlotPair -CredDir $script:CD -Name 'personal' -Email 'bob@example.com' -Content $otherBody | Out-Null
            Set-Content -LiteralPath $credFile -Value $otherBody -NoNewline
            Set-SandboxClaudeJson -Email 'alice@example.com'
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE_HASH' | Out-Null

            Mock Set-OAuthAccountInClaudeJson { throw 'claude.json is locked' }

            $out = Invoke-Reconcile 6>&1 | Out-String

            # The credentials are already in place, so a failed display update
            # must not undo the adoption; it downgrades to an advisory.
            (Read-ScaState).active_slot | Should -Be 'personal'
            $out | Should -Match 'still names the previous account'
            $out | Should -Match 'claude.json is locked'

            # Nothing retries this on its own: the next reconcile hash-matches
            # and returns before reaching the adopt branch, so the advisory has
            # to carry the recovery command and say what it costs to ignore.
            $out | Should -Match "Run 'sca switch personal'"
            $out | Should -Match 'auto-save a duplicate'

            # Cause before consequence: the adoption line is the event, the
            # failure is a footnote to it.
            $adoptAt = $out.IndexOf('Active credentials match saved slot')
            $failAt  = $out.IndexOf('still names the previous account')
            $adoptAt | Should -BeGreaterThan -1
            $failAt  | Should -BeGreaterThan $adoptAt
        }

        It 'prints a yellow advisory naming the adopted slot' {
            $credFile  = Join-Path $script:CD '.credentials.json'
            $otherBody = '{"claudeAiOauth":{"accessToken":"sk-ant-oat-OTHER","refreshToken":"sk-ant-ort-OTHER","expiresAt":9999999999999}}'
            New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content $script:CredsBody | Out-Null
            New-SlotPair -CredDir $script:CD -Name 'personal' -Email 'bob@example.com' -Content $otherBody | Out-Null
            Set-Content -LiteralPath $credFile -Value $otherBody -NoNewline
            Set-SandboxClaudeJson -Email 'alice@example.com'
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE_HASH' | Out-Null

            $out = Invoke-Reconcile 6>&1 | Out-String
            $out | Should -Match 'Active credentials match saved slot'
            $out | Should -Match 'personal'
        }

        # Byte equality with the slot state ALREADY names is not an adopt; it
        # only means last_sync_hash was stale. Excluding the active slot keeps
        # that case on the mirror path, where the write is a no-op.
        It 'does not adopt when the bytes match the tracked slot itself' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content $script:CredsBody | Out-Null
            Set-SandboxClaudeJson -Email 'alice@example.com'
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE_HASH' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            $r.Slot   | Should -Be 'work'
        }

        # The adopt check sits ahead of the tracked-slot block, not inside it,
        # because the auto-save fallback is destructive in its own way: it
        # writes a SECOND copy of an account already saved and moves active
        # tracking onto the copy. Byte equality answers that case too, and it
        # needs no tracked slot to compare against.
        It 'adopts rather than auto-saving a duplicate when no slot is tracked' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = New-SlotPair -CredDir $script:CD -Name 'personal' -Email 'bob@example.com' -Content $script:CredsBody
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            Set-SandboxClaudeJson -Email 'bob@example.com'

            # Written directly, not via Update-ScaState: that would call
            # Read-ScaState, whose no-state-file hash bootstrap would itself
            # identify 'personal' and defeat the setup. A state file that
            # EXISTS with a null active_slot skips the bootstrap, which is the
            # shape this branch has to handle.
            Set-Content -LiteralPath $StateFile -NoNewline `
                -Value '{"schema":1,"active_slot":null,"last_sync_hash":"STALE_HASH"}'

            $r = Invoke-Reconcile 6>$null
            $r.Action       | Should -Be 'adopt'
            $r.Slot         | Should -Be 'personal'
            $r.PreviousSlot | Should -BeNullOrEmpty

            (Read-ScaState).active_slot | Should -Be 'personal'
            Get-Content -LiteralPath $slotFile -Raw | Should -Be $script:CredsBody
            @(Get-Slots).Count | Should -Be 1 -Because 'no duplicate slot may be created for an account already saved'
        }

        # Read-ScaState's hash bootstrap only runs when the state file is
        # ABSENT. A corrupt one takes the catch and returns $null, so this is
        # the reachable path to "no tracked slot while a matching slot exists".
        It 'adopts rather than auto-saving a duplicate when the state file is corrupt' {
            $credFile = Join-Path $script:CD '.credentials.json'
            New-SlotPair -CredDir $script:CD -Name 'personal' -Email 'bob@example.com' -Content $script:CredsBody | Out-Null
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            Set-SandboxClaudeJson -Email 'bob@example.com'
            Set-Content -LiteralPath $StateFile -Value '{ this is not json' -NoNewline

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'adopt'
            $r.Slot   | Should -Be 'personal'
            @(Get-Slots).Count | Should -Be 1
        }
    }

    # ----- Find-SlotByHash ------------------------------------------------

    Context 'Find-SlotByHash' {
        It 'returns the slot whose file matches the hash' {
            New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'AAA' | Out-Null
            New-SlotPair -CredDir $script:CD -Name 'personal' -Email 'bob@example.com' -Content 'BBB' | Out-Null

            $hash = Get-SHA256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes('BBB'))
            (Find-SlotByHash -Hash $hash).Name | Should -Be 'personal'
        }

        It 'returns $null when no slot matches' {
            New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'AAA' | Out-Null

            $hash = Get-SHA256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes('NOTHING_HAS_THIS'))
            Find-SlotByHash -Hash $hash | Should -BeNullOrEmpty
        }

        It 'skips the excluded slot even when it is the only match' {
            New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content 'AAA' | Out-Null

            $hash = Get-SHA256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes('AAA'))
            Find-SlotByHash -Hash $hash -ExcludeName 'work' | Should -BeNullOrEmpty
            (Find-SlotByHash -Hash $hash).Name | Should -Be 'work'
        }

        It 'returns $null when no slots are saved' {
            $hash = Get-SHA256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes('AAA'))
            Find-SlotByHash -Hash $hash | Should -BeNullOrEmpty
        }
    }

    # ----- the /login window ---------------------------------------------
    #
    # Byte equality (adopt) closes the case where the incoming account is
    # already saved. This is the rest of it: a /login to an account with NO
    # slot produces bytes matching nothing, while ~/.claude.json still carries
    # the previous account's email, so the email probe says "same account,
    # just refreshed" and the mirror overwrites the only copy of that login.
    # Asking /api/oauth/profile with the incoming tokens is the one probe that
    # cannot lag them.
    Context 'Invoke-Reconcile (identity guard on the mirror branch)' {
        BeforeEach {
            $script:GuardCred  = Join-Path $script:CD '.credentials.json'
            $script:GuardOther = '{"claudeAiOauth":{"accessToken":"sk-ant-oat-NEW","refreshToken":"sk-ant-ort-NEW","expiresAt":9999999999999}}'

            # 'work' is tracked and holds its own tokens; .credentials.json now
            # holds tokens matching NO slot; ~/.claude.json still says alice.
            $script:GuardSlot = New-SlotPair -CredDir $script:CD -Name 'work' -Email 'alice@example.com' -Content $script:CredsBody
            Set-Content -LiteralPath $script:GuardCred -Value $script:GuardOther -NoNewline
            Set-SandboxClaudeJson -Email 'alice@example.com'
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE_HASH' | Out-Null
        }

        # New-SlotPair's sidecar uuid is "test-acct-uuid-<name>".
        function script:MockProfileUuid {
            Param ([string] $Uuid, [string] $Email = 'someone@example.com')
            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/profile'
            } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ uuid = $Uuid; email = $Email }
                    organization = [pscustomobject]@{ uuid = 'org-uuid' }
                }
            }.GetNewClosure()
        }

        It 'refuses the mirror when the tokens prove a different account' {
            Mock Test-ClaudeRunning { $true }
            MockProfileUuid -Uuid 'test-acct-uuid-INTRUDER' -Email 'intruder@example.com'

            $r = Invoke-Reconcile 6>$null

            # Preserve-both, not overwrite.
            $r.Action | Should -Be 'identity-change'
            $r.Email  | Should -Be 'intruder@example.com'
            Get-Content -LiteralPath $script:GuardSlot -Raw |
                Should -Be $script:CredsBody -Because 'the tracked login is the artifact that cannot be recovered'
        }

        It 'mirrors when the tokens confirm the same account despite a new token pair' {
            Mock Test-ClaudeRunning { $true }
            MockProfileUuid -Uuid 'test-acct-uuid-work' -Email 'alice@example.com'

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            Get-Content -LiteralPath $script:GuardSlot -Raw | Should -Be $script:GuardOther
        }

        # 'unknown' must not behave like 'mismatch'. Treating "could not ask"
        # as "different account" would freeze every slot file behind an
        # unreachable profile endpoint, and a slot that stops tracking
        # refreshes is dead after two of them.
        It 'mirrors when the probe cannot answer' {
            Mock Test-ClaudeRunning { $true }
            # Common.ps1's default profile mock throws.
            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            Get-Content -LiteralPath $script:GuardSlot -Raw | Should -Be $script:GuardOther
        }

        # With no client running, nothing can be between a /login's two writes,
        # so the offline answer stands and `sca list` stays network-free.
        It 'does not probe at all when no client is running' {
            Mock Test-ClaudeRunning { $false }
            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/profile'
            } -MockWith { throw 'profile must not be called' }

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/profile'
            }
        }

        # The probe runs against tokens a live client may be mid-request on.
        # Refreshing them to answer a question would rotate the refresh token
        # out from under it, which is the loss the guard exists to prevent.
        It 'never refreshes the tokens it is probing' {
            Mock Test-ClaudeRunning { $true }
            Mock Update-SlotTokens { throw 'the identity probe must not rotate tokens' }

            $expired = '{"claudeAiOauth":{"accessToken":"sk-ant-oat-OLD","refreshToken":"sk-ant-ort-OLD","expiresAt":1}}'
            Set-Content -LiteralPath $script:GuardCred -Value $expired -NoNewline

            $r = Invoke-Reconcile 6>$null

            Should -Invoke Update-SlotTokens -Times 0
            # Unresolvable identity is 'unknown', so the mirror still happens.
            $r.Action | Should -Be 'mirror'
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
