#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the `usage` action and its supporting helpers in
# switch_claude_account.ps1: Invoke-UsageAction, Format-ResetDelta,
# Format-ResetAbsolute, Get-SlotProfile, plus the email-rendering display
# path. Per-test sandbox setup lives in tests/Common.ps1.

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

    Context 'Invoke-UsageAction' {
        # Pester 5 only makes functions defined in BeforeAll visible to
        # every It in the Context; function definitions inside BeforeEach
        # live only for that one BeforeEach invocation. New-Slot is a
        # fixture builder the tests share, so it lives in BeforeAll. The
        # time-dependent $script:FutureMs / $script:PastMs cannot live
        # in BeforeAll because they would capture once and drift as the
        # suite runs; they are re-computed in BeforeEach instead.
        BeforeAll {
            function New-Slot {
                Param (
                    [string] $Name,
                    [string] $AccessToken = 'sk-ant-oat-fresh',
                    [string] $RefreshToken = 'sk-ant-ort-fresh',
                    $ExpiresAt  # defaults to $script:FutureMs
                )
                if ($null -eq $ExpiresAt) { $ExpiresAt = $script:FutureMs }
                $payload = @{
                    claudeAiOauth = @{
                        accessToken      = $AccessToken
                        refreshToken     = $RefreshToken
                        expiresAt        = $ExpiresAt
                        scopes           = @('user:inference','user:profile')
                        subscriptionType = 'team'
                        rateLimitTier    = 'default_claude_max_5x'
                    }
                } | ConvertTo-Json -Depth 10 -Compress
                $path = Join-Path $script:CredDirPath ".credentials.$Name.json"
                Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM

                # Sidecar pair so Get-Slots includes the slot. Mirrors
                # New-SlotPair from Common.ps1 but inline because this
                # helper writes its own credentials body shape.
                $sidecarPath = $path -replace '\.json$', '.account.json'
                $sidecar = [ordered]@{
                    schema       = 1
                    captured_at  = '2026-04-26T00:00:00.000Z'
                    source       = 'test'
                    oauthAccount = [ordered]@{
                        accountUuid      = (Get-TestAccountUuid -Email "$Name@test.local")
                        emailAddress     = "$Name@test.local"
                        organizationUuid = 'test-org-uuid'
                        displayName      = $Name
                        organizationName = 'test-org'
                    }
                }
                Set-Content -LiteralPath $sidecarPath -Value ($sidecar | ConvertTo-Json -Depth 5) -NoNewline -Encoding utf8NoBOM

                return $path
            }

            # Build an ISO-8601 string N time-units from now, matching the
            # shape the live /api/oauth/usage emits. In BeforeAll (not
            # BeforeEach) so every It in this Context sees the function.
            function Format-IsoReset {
                Param ([TimeSpan] $Offset)
                return [DateTimeOffset]::UtcNow.Add($Offset).ToString(
                    'o', [Globalization.CultureInfo]::InvariantCulture)
            }
        }

        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'

            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
            $script:PastMs   = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
        }

        It 'prints no-slots message when no slots exist' {
            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'No slots saved'
        }

        It 'happy path: real /api/oauth/usage shape (buckets at root, utilization, ISO resets_at) renders table' {
            # Saved slot + .credentials.json byte-equal: reconcile sees a
            # hash match, no-ops, and the table renders the saved slot
            # directly. The synth <active> row that previous versions
            # appended on broken-hardlink state is gone; the active slot
            # file IS the active credentials post-reconcile.
            $slotPath = New-Slot -Name 'work'
            Copy-Item -LiteralPath $slotPath -Destination $script:CredFilePath -Force

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{
                        utilization = 31.0
                        resets_at   = (Format-IsoReset ([TimeSpan]::FromMinutes(134)))  # ~2h 14m
                    }
                    seven_day = [pscustomobject]@{
                        utilization = 17.0
                        resets_at   = (Format-IsoReset ([TimeSpan]::FromHours(42)))     # ~1d 18h -> "(42h)"
                    }
                    seven_day_sonnet = [pscustomobject]@{
                        utilization = 0.0
                        resets_at   = $null
                    }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'work'
            # Integer percent, right-justified into 4-char cell.
            $out | Should -Match '\b31%'
            $out | Should -Match '\b17%'
            # Variant C: hours+minutes under 24h; elapsed test time may shave
            # a minute off, so accept 13-14m.
            $out | Should -Match '\(2h 1[34]m\)'
            # Variant C: integer total hours at/above 24h; elapsed test time
            # may drop 42h to 41h.
            $out | Should -Match '\(4[12]h\)(?!\d)'
            # 'ok' status (buckets were present, so not "no plan data").
            $out | Should -Match '(?m)\s+ok\s*$'
            # Unofficial-endpoint footer must not leak into output.
            $out | Should -Not -Match 'unofficial endpoint'
            # No synth row, no hardlink-broken warning (both gone).
            $out | Should -Not -Match '<active>'
            $out | Should -Not -Match 'not hardlinked'
            # And no row other than 'work' (one saved slot -> exactly one data row).
            ($out -split "`n" | Where-Object { $_ -match '(?:^|\s)work\b' }).Count | Should -Be 1
        }

        It 'true empty response ({}) renders "ok (no plan data)"' {
            New-Slot -Name 'free' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{}
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'free'
            $out | Should -Match 'ok \(no plan data\)'
        }

        It 'null resets_at paired with 0% renders just the percent (merged cell)' {
            New-Slot -Name 'cold' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 0.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 9.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(103))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # 0% five_hour with null reset: cell is just ' 0%' (no 'in ...'
            # suffix). With columns merged, the em-dash reset sentinel is
            # no longer emitted when utilization is known; a cold bucket
            # is naturally represented by its raw percent without a tail.
            $out | Should -Match '\b0%'
            # The 5h cell has no paren tail; the 7d cell does (103h).
            $out | Should -Not -Match '0%\s+\('
            $out | Should -Match '9%\s+\(10[23]h\)'
        }

        It '401 response: status is unauthorized' {
            New-Slot -Name 'revoked' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 401 }
                $inner = [System.Exception]::new('Unauthorized')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'unauthorized'
        }

        It 'network timeout: status is error; overall call still returns 0-exit' {
            New-Slot -Name 'offline' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Net.WebException]::new('The operation has timed out.')
            }

            { Invoke-UsageAction 6>$null } | Should -Not -Throw
            $out = Invoke-UsageAction 6>&1 | Out-String
            # Bare label in the cell; the reason on the advisory line below.
            $out | Should -Match '(?m)^\s+offline\b.*\berror\s*$'
            $out | Should -Match '\[Usage\] offline: The operation has timed out\.'
        }

        It 'slot with no claudeAiOauth section: status is no-oauth; no HTTP call made' {
            # Use New-SlotPair but with non-OAuth body. The sidecar is
            # synthesized by Common.ps1's helper so the slot is visible
            # to Get-Slots; the slot file itself carries an apiKey-only
            # body that Get-SlotOAuth recognizes as HasOAuth=false.
            New-SlotPair -CredDir $script:CredDirPath -Name 'apikey' -Content '{"apiKey":"sk-ant-api..."}' | Out-Null

            Mock Invoke-RestMethod -MockWith { throw 'should not be called' }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'apikey'
            $out | Should -Match 'no-oauth'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'expired token: refresh succeeds, slot file rewritten in place, usage retrieved' {
            $slotPath = New-Slot -Name 'stale' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                if ($Headers['Authorization'] -ne 'Bearer sk-ant-oat-NEW') {
                    throw "refresh did not propagate to usage call: got '$($Headers['Authorization'])'"
                }
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(3))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $after = Get-Content -LiteralPath $slotPath -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken  | Should -Be 'sk-ant-oat-NEW'
            $after.claudeAiOauth.refreshToken | Should -Be 'sk-ant-ort-NEW'
            [DateTimeOffset]::FromUnixTimeMilliseconds($after.claudeAiOauth.expiresAt).UtcDateTime |
                Should -BeGreaterThan ([DateTime]::UtcNow)
            $out | Should -Match '\b5%'

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'expired token + refresh fails (400): status is expired; slot unchanged' {
            $slotPath = New-Slot -Name 'stale' -ExpiresAt $script:PastMs
            $before   = [System.IO.File]::ReadAllBytes($slotPath)

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Exception]::new('refresh_token invalid')
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw 'should not be called if refresh failed'
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'expired'
            $after = [System.IO.File]::ReadAllBytes($slotPath)
            $after.Length | Should -Be $before.Length
            for ($i = 0; $i -lt $before.Length; $i++) { $after[$i] | Should -Be $before[$i] }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        # --- refresh-endpoint 429 handling ---
        #
        # Regression for the bug originally reported via screenshot: a 429
        # from /v1/oauth/token surfaced as `expired: Response status code
        # does not indicate success: 429 (Too Many Requests).`; long
        # enough to wrap the table row, and mislabeled relative to the
        # 'rate-limited' handling that already existed for the usage
        # endpoint. After the fix the same 429 routes through Test-Is429
        # and renders cleanly, with cache fallback when available.

        It 'refresh 429 with no cache: status is rate-limited (not expired); no long error tail' {
            $slotPath = New-Slot -Name 'slot-1' -ExpiresAt $script:PastMs
            $before   = [System.IO.File]::ReadAllBytes($slotPath)

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('Response status code does not indicate success: 429 (Too Many Requests).')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw 'should not be called when refresh 429s'
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Status renders as the short 'rate-limited' label, never as
            # the long 'expired: …429 (Too Many Requests)' string.
            $out | Should -Match 'rate-limited'
            $out | Should -Not -Match 'Too Many Requests'
            # The slot name's own data row carries 'rate-limited', not 'expired'.
            $out | Should -Match '(?m)^\s+slot-1\b.*\brate-limited\s*$'
            $out | Should -Not -Match '(?m)^\s+slot-1\b.*\bexpired\b'

            # Slot file untouched (refresh failed, nothing to write).
            $after = [System.IO.File]::ReadAllBytes($slotPath)
            $after.Length | Should -Be $before.Length
            for ($i = 0; $i -lt $before.Length; $i++) { $after[$i] | Should -Be $before[$i] }

            # Usage endpoint was never called; refresh failure short-circuits.
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'refresh 429 with fresh cache: serves cached usage data + emits cache-fallback advisory' {
            $slotPath = New-Slot -Name 'slot-1' -ExpiresAt $script:PastMs

            # Pre-populate the in-memory cache with a recent successful
            # response. `$Script:SlotUsageCache` is reinitialized to @{}
            # in each BeforeEach (Common.ps1 dot-sources the script),
            # so we start from a clean slate here.
            $cachedReset = (Format-IsoReset ([TimeSpan]::FromHours(2)))
            $Script:SlotUsageCache[$slotPath] = @{
                Data      = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 42.0; resets_at = $cachedReset }
                    seven_day = [pscustomobject]@{ utilization = 73.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(50))) }
                }
                Timestamp = [DateTime]::UtcNow
            }

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('429 Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw 'should not be called when refresh 429s'
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Cached values render via the regular 'ok' Status path.
            $out | Should -Match '\b42%'
            $out | Should -Match '\b73%'
            # Cache-fallback advisory fires, naming the slot and noting the
            # last-known data is being shown.
            $out | Should -Match 'currently rate-limited or at a plan limit; showing last known usage'
            # Old advisory wording must not leak through.
            $out | Should -Not -Match '/api/oauth/usage rate limited'
            $out | Should -Not -Match 'showing cached data'
        }

        It 'refresh failure with non-429 long message: reason line is truncated, row label is not widened' {
            New-Slot -Name 'slot-long' -ExpiresAt $script:PastMs | Out-Null

            $longMessage = 'X' * ($Script:AdvisoryReasonMaxWidth * 2)
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Exception]::new($longMessage)
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Still classified as 'expired' (no Response.StatusCode = 429), and
            # the message never reaches the Status cell: the cell is the last
            # column and its width also sizes the aggregate bars.
            $out | Should -Match '(?m)^\s+slot-long\b.*\bexpired\s*$'
            # The message lands on the advisory reason line, truncated there
            # (the helper appends '...').
            $out | Should -Match "\[Usage\] slot-long: X+\.\.\."
            # Bounded: the full 400-char message must NOT appear verbatim.
            $out | Should -Not -Match ('X' * ($Script:AdvisoryReasonMaxWidth + 1))
        }

        It '-Json emits is_cached_fallback when cache served the row' {
            $slotPath = New-Slot -Name 'slot-1' -ExpiresAt $script:PastMs

            $Script:SlotUsageCache[$slotPath] = @{
                Data      = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
                Timestamp = [DateTime]::UtcNow
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('429')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $parsed = Invoke-UsageAction -Json | ConvertFrom-Json
            $parsed.'slot-1'.status              | Should -Be 'ok'
            $parsed.'slot-1'.is_cached_fallback  | Should -Be $true
            $parsed.'slot-1'.data.five_hour.utilization | Should -Be 1
        }

        # A cached row keeps its live-quality 'ok' for every consumer that gates
        # on status, and still reports what the failed live read said, so a
        # script can tell a cached reading from a live one and say why.
        It '-Json reports the failure reason on a cached ok row' {
            $slotPath = New-Slot -Name 'blip' -ExpiresAt $script:PastMs

            $Script:SlotUsageCache[$slotPath] = @{
                Data      = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 3.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
                Timestamp = [DateTime]::UtcNow
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Net.Http.HttpRequestException]::new('No such host is known.')
            }

            $parsed = Invoke-UsageAction -Json | ConvertFrom-Json
            $parsed.blip.status             | Should -Be 'ok'
            $parsed.blip.is_cached_fallback | Should -Be $true
            $parsed.blip.error              | Should -Match 'No such host'
        }

        It '-Json omits is_cached_fallback for fresh live responses' {
            New-Slot -Name 'fresh' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                }
            }

            $parsed = Invoke-UsageAction -Json | ConvertFrom-Json
            $parsed.fresh.status | Should -Be 'ok'
            # Property either absent or explicitly false; never true.
            $hasField = ($parsed.fresh | Get-Member -Name 'is_cached_fallback' -MemberType NoteProperty)
            if ($hasField) { $parsed.fresh.is_cached_fallback | Should -Not -Be $true }
        }

        It '-Json emits a per-slot dictionary that round-trips via ConvertFrom-Json' {
            New-Slot -Name 'alpha' | Out-Null
            New-Slot -Name 'bravo' -AccessToken 'sk-ant-oat-bravo' -RefreshToken 'sk-ant-ort-bravo' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*fresh*' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 10.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*bravo*' } -MockWith {
                throw [System.Exception]::new('network down')
            }

            $raw    = Invoke-UsageAction -Json
            $parsed = $raw | ConvertFrom-Json

            ($parsed | Get-Member -MemberType NoteProperty | ForEach-Object Name) | Sort-Object |
                Should -Be @('alpha','bravo')
            $parsed.alpha.status | Should -Be 'ok'
            # Real schema: utilization at data.five_hour (no rate_limits wrapper).
            $parsed.alpha.data.five_hour.utilization | Should -Be 10
            $parsed.bravo.status | Should -Be 'error'
            $parsed.bravo.error  | Should -Match 'network down'
        }

        # --- plan-usability status (100% = limited, >=90% = near limit) ---

        # The Status column mixes HTTP-health (expired / unauthorized /
        # error / no-oauth) with plan-usability derived from the
        # utilization fields. A slot at 100% of its 5h window is rate-
        # limited and cannot serve prompts until the window resets;
        # rendering that as 'ok' would mislead the user (the bug these
        # tests guard against).
        It 'plan status is "limited 5h" when five_hour utilization is at 100%' {
            New-Slot -Name 'capped' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 28.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromHours(34))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'capped'
            $out | Should -Match '100%'
            # Status column reflects plan state, not HTTP state.
            $out | Should -Match '(?m)\blimited 5h\s*$'
            # And should NOT read as 'ok' anywhere on the data row.
            $out | Should -Not -Match '(?m)^\s+capped\b.*\bok\s*$'
        }

        It 'plan status is "limited 7d" when seven_day utilization is at 100%' {
            New-Slot -Name 'weeklycap' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 12.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 101.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(12))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match '(?m)\blimited 7d\s*$'
        }

        It 'plan status is "limited" when both buckets are at or above 100%' {
            New-Slot -Name 'double' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(10))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            # Exact word boundary so 'limited' does not also match 'limited 5h'.
            $out | Should -Match '(?m)\blimited\s*$'
            $out | Should -Not -Match 'limited 5h'
            $out | Should -Not -Match 'limited 7d'
        }

        It 'plan status is "near limit" when any bucket is at or above the warn threshold but under 100%' {
            New-Slot -Name 'warnrow' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 92.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day = [pscustomobject]@{ utilization = 11.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(50))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'near limit'
            $out | Should -Not -Match 'limited'
        }

        It 'plan status is plain "ok" when both buckets are below the warn threshold' {
            New-Slot -Name 'healthy' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 89.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day = [pscustomobject]@{ utilization =  3.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(70))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            # 89 < 90 warn threshold -> still 'ok'. Word-anchored so 'ok'
            # is not confused with 'ok (no plan data)'.
            $out | Should -Match '(?m)\bok\s*$'
            $out | Should -Not -Match 'near limit'
            $out | Should -Not -Match 'limited'
        }

        It '-Json emits plan_status alongside status for HTTP-ok rows' {
            New-Slot -Name 'capped' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 28.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromHours(34))) }
                }
            }

            $raw    = Invoke-UsageAction -Json
            $parsed = $raw | ConvertFrom-Json

            $parsed.capped.status      | Should -Be 'ok'
            $parsed.capped.plan_status | Should -Be 'limited 5h'
        }

        It '-Json omits plan_status for HTTP-failure rows' {
            New-Slot -Name 'dead' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Exception]::new('network down')
            }

            $raw    = Invoke-UsageAction -Json
            $parsed = $raw | ConvertFrom-Json

            $parsed.dead.status      | Should -Be 'error'
            # plan_status is only attached for status='ok' rows so scripts
            # don't have to disambiguate between "HTTP ok + near limit"
            # and "HTTP failed". When absent, the NoteProperty is missing.
            $parsed.dead.PSObject.Properties.Name | Should -Not -Contain 'plan_status'
        }

        It 'verbose view inserts a Status line between Account and the bucket rows for a limited slot' {
            New-Slot -Name 'alpha' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 28.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromHours(34))) }
                }
            }

            $out = Invoke-UsageAction -Name 'alpha' 6>&1 | Out-String

            # Status line uses the same label as the summary table plus a
            # short English rationale so the verbose screen can stand
            # alone.
            $out | Should -Match '(?m)^\s+Status:\s+limited 5h - no prompts until 5h window resets'

            # Bucket rows still render below the Status line. Renamed
            # from 'Session (5h)' / 'Weekly (all models)' to 'Session' /
            # 'Week' to match the table column headers and the
            # aggregate-bar labels above the table.
            $out | Should -Match 'Session\s+100%\s+Resets '
            $out | Should -Match 'Week\s+28%\s+Resets '
        }

        # When sca usage triggers a token refresh on the active slot,
        # the new tokens must propagate to .credentials.json so Claude
        # Code's next call uses the latest refresh_token. Pre-state-file
        # this happened automatically through the hardlink; now
        # Update-SlotTokens explicitly atomic-writes both endpoints when
        # the slot is the tracked active. Regression guard for the
        # correctness fix described in AGENTS.md.
        It 'refresh on active slot propagates new tokens to .credentials.json' {
            $slotPath = New-Slot -Name 'activeStale' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            # Seed state pointing at this slot, with .credentials.json
            # byte-equal so reconcile no-ops on entry.
            Copy-Item -LiteralPath $slotPath -Destination $script:CredFilePath -Force
            $hash = (Get-FileHash -LiteralPath $script:CredFilePath -Algorithm SHA256).Hash
            Update-ScaState -ActiveSlot 'activeStale' -LastSyncHash $hash | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{}
            }

            Invoke-UsageAction 6>$null

            # Both endpoints carry the new access token after the refresh.
            $credJson = Get-Content -LiteralPath $script:CredFilePath -Raw | ConvertFrom-Json
            $slotJson = Get-Content -LiteralPath $slotPath              -Raw | ConvertFrom-Json
            $credJson.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'
            $slotJson.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'

            # state.last_sync_hash updated so the next reconcile no-ops.
            (Read-ScaState).last_sync_hash |
                Should -Be (Get-FileHash -LiteralPath $script:CredFilePath -Algorithm SHA256).Hash
        }

        # When state.active_slot points at a slot whose sidecar is
        # missing (legacy install, lost sidecar from a failed save's
        # rollback, or a sidecar-less auto-save), Find-SlotByName
        # filters that slot out of Get-Slots and returns $null. The
        # naive guard `if ($activeSlot -and $activeSlot.Path -eq ...)`
        # would silently skip propagation, leaving .credentials.json
        # with the old refresh_token Anthropic just rotated away --
        # Claude Code's next refresh would then 4xx and force re-login.
        # Update-SlotTokens detects this case (active_slot set but
        # Find-SlotByName null AND the parsed slot-name from $SlotPath
        # equals state.active_slot) and emits a yellow advisory
        # pointing at `sca save` / `sca switch` for recovery, without
        # auto-propagating (sidecar absence is the visibility gate).
        #
        # Driven through Update-SlotTokens directly: Invoke-UsageAction
        # cannot reach the new branch because Get-UsageSnapshot ->
        # Get-Slots filters sidecar-less slots out before Get-SlotUsage
        # would call Update-SlotTokens, so the function is exercised
        # here as a unit.
        It 'refresh on sidecar-less active slot warns and does NOT propagate' {
            $slotPath = New-Slot -Name 'activeStale' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            # Delete the sidecar so Find-SlotByName('activeStale')
            # returns $null while state still tracks it as active.
            $sidecarPath = $slotPath -replace '\.json$', '.account.json'
            Remove-Item -LiteralPath $sidecarPath -Force

            # Mirror slot bytes to .credentials.json and seed state.
            Copy-Item -LiteralPath $slotPath -Destination $script:CredFilePath -Force
            $hash = (Get-FileHash -LiteralPath $script:CredFilePath -Algorithm SHA256).Hash
            Update-ScaState -ActiveSlot 'activeStale' -LastSyncHash $hash | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }

            # 6>&1 merges the Write-Color information stream into the
            # success stream alongside Update-SlotTokens' return value
            # (the new access token); Out-String stringifies both so a
            # single Should -Match can probe for the advisory wording.
            $out = Update-SlotTokens -SlotPath $slotPath 6>&1 | Out-String

            # Advisory fired with sidecar-specific wording and the
            # slot-name baked into the recovery command.
            $out | Should -Match 'identity sidecar is missing'
            $out | Should -Match 'sca save activeStale'

            # Slot file got the new tokens (rotation reached the slot
            # file via Update-SlotTokens' first atomic write).
            $slotJson = Get-Content -LiteralPath $slotPath -Raw | ConvertFrom-Json
            $slotJson.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'

            # .credentials.json STILL has the old token: the elseif
            # branch deliberately does not propagate.
            $credJson = Get-Content -LiteralPath $script:CredFilePath -Raw | ConvertFrom-Json
            $credJson.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-OLD'

            # state.last_sync_hash unchanged so the next reconcile
            # still hash-match-noops (no spurious cross-account swap
            # detection until the user runs `sca save` / `sca switch`).
            (Read-ScaState).last_sync_hash | Should -Be $hash
        }

        # Pin the name-comparison guard inside the new elseif: when
        # the tracked active slot is sidecar-hidden BUT we are
        # refreshing some OTHER slot, the advisory must NOT fire
        # (otherwise every refresh on any slot would print a
        # false-positive warning while a hidden active exists, and the
        # advisory text "Token refreshed in slot '<active>'" would be
        # factually wrong about which slot was just refreshed).
        It 'refresh on unrelated slot when active is sidecar-hidden does NOT print sidecar advisory' {
            $activeSlot   = New-Slot -Name 'active'   -AccessToken 'sk-ant-oat-ACTIVE'
            $inactiveSlot = New-Slot -Name 'inactive' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            # Hide the active slot's sidecar so Find-SlotByName('active')
            # returns $null and the elseif branch fires.
            $activeSidecar = $activeSlot -replace '\.json$', '.account.json'
            Remove-Item -LiteralPath $activeSidecar -Force

            Copy-Item -LiteralPath $activeSlot -Destination $script:CredFilePath -Force
            $hash = (Get-FileHash -LiteralPath $script:CredFilePath -Algorithm SHA256).Hash
            Update-ScaState -ActiveSlot 'active' -LastSyncHash $hash | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }

            $beforeCred = Get-Content -LiteralPath $script:CredFilePath -Raw
            $out = Update-SlotTokens -SlotPath $inactiveSlot 6>&1 | Out-String
            $afterCred = Get-Content -LiteralPath $script:CredFilePath -Raw

            # .credentials.json untouched: refresh hit 'inactive', and
            # the elseif's name comparison ($parsed.Name -eq
            # state.active_slot) rejects the false-positive case.
            $afterCred | Should -Be $beforeCred
            $out | Should -Not -Match 'identity sidecar is missing'
        }

        # Refresh on a slot that is NOT the tracked active slot must
        # only write to the slot file, leaving .credentials.json alone.
        # Without this guard, sca usage on inactive slots would clobber
        # .credentials.json with the wrong account's tokens.
        It 'refresh on inactive slot leaves .credentials.json untouched' {
            $activeSlot   = New-Slot -Name 'active'   -AccessToken 'sk-ant-oat-ACTIVE'
            $inactiveSlot = New-Slot -Name 'inactive' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            Copy-Item -LiteralPath $activeSlot -Destination $script:CredFilePath -Force
            $hash = (Get-FileHash -LiteralPath $script:CredFilePath -Algorithm SHA256).Hash
            Update-ScaState -ActiveSlot 'active' -LastSyncHash $hash | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{}
            }

            $beforeCred = Get-Content -LiteralPath $script:CredFilePath -Raw
            Invoke-UsageAction -Name 'inactive' 6>$null
            $afterCred  = Get-Content -LiteralPath $script:CredFilePath -Raw

            # .credentials.json untouched (still active's tokens).
            $afterCred | Should -Be $beforeCred
            # Inactive slot got the new tokens.
            $inactiveJson = Get-Content -LiteralPath $inactiveSlot -Raw | ConvertFrom-Json
            $inactiveJson.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'
        }

        It 'named-slot usage: verbose view shows only Session and Week buckets' {
            New-Slot -Name 'alpha' | Out-Null
            New-Slot -Name 'bravo' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    # Buckets we render:
                    five_hour        = [pscustomobject]@{ utilization = 25.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day        = [pscustomobject]@{ utilization = 17.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(48))) }
                    # Buckets we MUST NOT render (scope decision: limits only = session + weekly):
                    seven_day_opus   = [pscustomobject]@{ utilization = 8.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromDays(6))) }
                    seven_day_sonnet = [pscustomobject]@{ utilization = 0.0;  resets_at = $null }
                    extra_usage      = [pscustomobject]@{ is_enabled = $false; monthly_limit = $null; used_credits = $null; utilization = $null; currency = $null }
                }
            }

            $out = Invoke-UsageAction -Name 'alpha' 6>&1 | Out-String

            # Targeted slot only.
            $out | Should -Match "Slot 'alpha'"
            $out | Should -Not -Match "Slot 'bravo'"

            # The two rendered buckets; labels match the table column
            # headers and the aggregate-bar labels.
            $out | Should -Match '(?m)^\s+Session\s+\d'
            $out | Should -Match '(?m)^\s+Week\s+\d'
            $out | Should -Match 'Resets '

            # Explicitly absent: labels for buckets we deliberately stopped
            # rendering. Protects against accidental regression if a future
            # refactor reintroduces a generic bucket loop.
            $out | Should -Not -Match 'Weekly \(Opus only\)'
            $out | Should -Not -Match 'Weekly \(Sonnet only\)'
            $out | Should -Not -Match 'Extra usage'
            # Raw API keys also absent (we use labels, not keys).
            $out | Should -Not -Match '(?m)^\s+five_hour\b'
            $out | Should -Not -Match '(?m)^\s+seven_day\b'

            # Unofficial-endpoint footer removed.
            $out | Should -Not -Match 'unofficial endpoint'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'named-slot usage throws on missing slot' {
            New-Slot -Name 'alpha' | Out-Null
            { Invoke-UsageAction -Name 'missing' 6>$null } | Should -Throw -ExpectedMessage "*Slot 'missing' not found*"
        }

        # --- reconcile prelude ---
        #
        # Invoke-UsageAction calls Invoke-Reconcile before gathering the
        # snapshot. The detailed reconcile branches are covered by
        # tests/Invoke-Reconcile.Tests.ps1; here we only verify that the
        # post-reconcile state is what the table renders.

        It 'reconcile mirrors a refreshed .credentials.json into the tracked slot' {
            # Saved slot has stale tokens; .credentials.json carries new
            # tokens (simulating Claude Code refresh). Reconcile mirrors
            # active -> slot before Get-UsageSnapshot reads the slot.
            $slotPath = New-Slot -Name 'work' -AccessToken 'sk-ant-oat-OLD'
            $newPayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-NEW'
                    refreshToken     = 'sk-ant-ort-NEW'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $newPayload -NoNewline -Encoding utf8NoBOM

            # Seed state pointing at 'work' so reconcile mirrors there.
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE_HASH' | Out-Null

            # Identity must resolve to the tracked slot's own account, which is
            # what makes this a refresh rather than a swap. New-Slot writes the
            # sidecar email as "<name>@test.local". Without this, reconcile
            # cannot attribute the new bytes and declines to write at all.
            Set-SandboxClaudeJson -Email 'work@test.local'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                if ($Headers['Authorization'] -ne 'Bearer sk-ant-oat-NEW') {
                    throw "expected new token in Authorization header, got '$($Headers['Authorization'])'"
                }
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Slot file now byte-equal to .credentials.json (mirrored).
            Get-Content -LiteralPath $slotPath -Raw | Should -Be $newPayload
            $out | Should -Match '(?m)^\s+\*\s+work\s'
        }

        It 'reconcile auto-saves an unknown active credential under a fresh name' {
            # No saved slots, .credentials.json present with novel tokens.
            # Identity comes from ~/.claude.json (post-v2.1.0 probe), so
            # set that up too; without it the auto-save would write a
            # sidecar-less invisible slot and the table assertion below
            # wouldn't find a row.
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-LONER'
                    refreshToken     = 'sk-ant-ort-LONER'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'pro'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $payload -NoNewline -Encoding utf8NoBOM
            Set-SandboxClaudeJson -Email 'loner@example.com'

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 2.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(4))) }
                    seven_day = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(150))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match '\[Sync\] Auto-saved unknown active credentials'
            $out | Should -Match '(?m)^\s+\*\s+auto-\d{8}T\d{6}Z\s'
            $out | Should -Match '\b2%'
            $out | Should -Not -Match '<active>'
            $out | Should -Not -Match 'not hardlinked'
        }

        It '-Json mode suppresses reconcile advisory text from stdout' {
            # The auto-save branch normally prints a yellow advisory; in
            # -Json mode the JSON output must remain parseable.
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-JSON'
                    refreshToken     = 'sk-ant-ort-JSON'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $payload -NoNewline -Encoding utf8NoBOM
            Set-SandboxClaudeJson -Email 'json-test@example.com'

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 9.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                }
            }

            $raw = Invoke-UsageAction -Json
            { $raw | ConvertFrom-Json } | Should -Not -Throw
            $raw | Should -Not -Match '\[Sync\]'
        }

        # --- Get-UsageSnapshot / Format-UsageFrame / -Watch guards ---
        #
        # The watch loop itself (sleeps + key reads) is not unit-tested;
        # instead we exercise the three seams it is built on:
        #   1. Get-UsageSnapshot returns the data shape the loop consumes.
        #   2. Format-UsageFrame renders a frame + optional footer.
        #   3. Invoke-UsageAction -Watch refuses bad surfaces (redirected
        #      output, combined with -Json).

        It 'Get-UsageSnapshot returns Results + NoSlots flags' {
            New-Slot -Name 'alpha' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 7.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
            }

            $snap = Get-UsageSnapshot
            $snap                    | Should -Not -BeNullOrEmpty
            $snap.NoSlots            | Should -Be $false
            @($snap.Results).Count   | Should -Be 1
            @($snap.Results)[0].Name | Should -Be 'alpha'
        }

        It 'Get-UsageSnapshot reports NoSlots when the directory is empty' {
            $snap = Get-UsageSnapshot
            $snap.NoSlots          | Should -Be $true
            @($snap.Results).Count | Should -Be 0
        }

        It 'Get-UsageSnapshot sets HasRateLimited when a row is rate-limited' {
            $slotPath = New-Slot -Name 'beta'
            # Pre-seed a STALE cache entry so the 429 path returns
            # rate-limited immediately (no 5s retry sleep, served stale).
            $Script:SlotUsageCache[$slotPath] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 3.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $snap = Get-UsageSnapshot
            $snap.HasRateLimited | Should -BeTrue
            # Stale data was served, which the row itself records; the
            # snapshot carries no parallel flag for it.
            @($snap.Results)[0].IsCachedFallback | Should -BeTrue
        }

        # HasRateLimited is the only per-row condition the snapshot summarises,
        # because Invoke-UsageWatch's early-repoll decision is the only caller
        # that wants a boolean. Every other consumer needs the affected slot
        # names and partitions Results itself.
        It 'Get-UsageSnapshot summarises only HasRateLimited' {
            New-Slot -Name 'beta' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Threading.Tasks.TaskCanceledException]::new('The request was canceled due to the configured HttpClient.Timeout of 12 seconds elapsing.')
            }

            $snap = Get-UsageSnapshot
            @($snap.Results)[0].Status           | Should -Be 'error'
            @($snap.Results)[0].IsCachedFallback | Should -BeFalse
            $snap.HasRateLimited                 | Should -BeFalse

            $snap.PSObject.Properties.Name | Should -Not -Contain 'HasError'
            $snap.PSObject.Properties.Name | Should -Not -Contain 'HasCacheFallback'
        }

        # Regression guard for the blind spot that hid this for two releases:
        # Format-UsageTable's 'error <code>' arm reads $Row.HttpStatus, but
        # Get-UsageSnapshot did not project it, so the arm was unreachable in
        # every real code path while its unit test passed against a hand-built
        # row that already carried the field.
        It 'Get-UsageSnapshot projects HttpStatus onto the row' {
            New-Slot -Name 'beta' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 529 }
                $inner = [System.Exception]::new('Response status code does not indicate success: 529.')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $snap = Get-UsageSnapshot
            $row  = @($snap.Results)[0]
            $row.Status     | Should -Be 'error'
            $row.HttpStatus | Should -Be 529

            # And the label the projection exists to enable actually renders.
            $out = Format-UsageTable -Results @($row) 6>&1 | Out-String
            $out | Should -Match 'error 529'
            $out | Should -Not -Match 'does not indicate success'
        }

        It 'Get-UsageSnapshot projects FallbackReason onto the row' {
            $slotPath = New-Slot -Name 'beta'
            $Script:SlotUsageCache[$slotPath] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 4.0; resets_at = $null } }
                Timestamp = [DateTime]::UtcNow
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Threading.Tasks.TaskCanceledException]::new('timeout')
            }

            $row = @((Get-UsageSnapshot).Results)[0]
            $row.Status         | Should -Be 'ok'
            $row.FallbackReason | Should -Be 'network'
        }

        It 'Format-UsageFrame prints the footer under the table when -Footer is provided' {
            $snap = [pscustomobject]@{
                Results = @([pscustomobject]@{ Name = 'alpha'; IsActive = $false; Status = 'ok';
                    Data = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) } }
                    Error = $null; Email = $null })
                NoSlots          = $false
            }

            $out = Format-UsageFrame -Snapshot $snap -Footer 'HELLO-FROM-FOOTER' 6>&1 | Out-String

            $out | Should -Match 'alpha'
            $out | Should -Match 'HELLO-FROM-FOOTER'
            # Footer sits after the data row.
            ($out.IndexOf('alpha')) | Should -BeLessThan ($out.IndexOf('HELLO-FROM-FOOTER'))
        }

        It 'Format-UsageTable renders bucket percentages for a rate-limited row that carries cached data' {
            # A rate-limited row served from the (possibly stale) cache
            # fallback carries last-known Data; its numbers must show so the
            # row is not misread as a dead/unused slot.
            $rows = @([pscustomobject]@{ Name = 'cached'; IsActive = $true; Status = 'rate-limited'; Email = 'a@x.org'
                Data = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 42.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 73.0; resets_at = $null }
                }
                Error = $null; IsCachedFallback = $true })

            $out = Format-UsageTable -Results $rows 6>&1 | Out-String

            $out | Should -Match '\b42%'
            $out | Should -Match '\b73%'
            $out | Should -Match '(?m)^\s*\*?\s*cached\b.*\brate-limited\s*$'
        }

        It 'Format-UsageFrame names the slot for a no-cache rate-limited row' {
            $snap = [pscustomobject]@{
                Results = @([pscustomobject]@{ Name = 'throttled'; IsActive = $true; Status = 'rate-limited';
                    Data = $null; Error = $null; Email = $null; IsCachedFallback = $false })
                NoSlots          = $false
                HasRateLimited   = $true
            }

            $out = Format-UsageFrame -Snapshot $snap 6>&1 | Out-String

            # The em-dash data cells stay (no data to show), but the advisory
            # names the throttled slot and states the condition without
            # promising recovery (the renderer is shared with one-shot).
            $out | Should -Match "'throttled' is currently rate-limited or at a plan limit\."
            # The cached-data wording must NOT fire (no cache here).
            $out | Should -Not -Match 'last known usage'
        }

        It 'Format-UsageFrame prefers the cached-data advisory over the no-cache one when data was served' {
            $snap = [pscustomobject]@{
                Results = @([pscustomobject]@{ Name = 'cached'; IsActive = $true; Status = 'rate-limited';
                    Data = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = $null } }
                    Error = $null; Email = $null; IsCachedFallback = $true })
                NoSlots          = $false
                HasRateLimited   = $true
            }

            $out = Format-UsageFrame -Snapshot $snap 6>&1 | Out-String

            $out | Should -Match "'cached' is currently rate-limited or at a plan limit; showing last known usage\."
        }

        It 'Format-UsageFrame renders the advisory in the footer block, leading the [Monitor]/[Watch] lines' {
            $snap = [pscustomobject]@{
                Results = @([pscustomobject]@{ Name = 'throttled'; IsActive = $true; Status = 'rate-limited';
                    Data = $null; Error = $null; Email = $null; IsCachedFallback = $false })
                NoSlots          = $false
                HasRateLimited   = $true
            }

            $out = Format-UsageFrame -Snapshot $snap -Footer "[Watch] Last poll at 07:56:48" 6>&1 | Out-String

            # Advisory moved out from under the table and into the footer
            # block, leading the [Watch] line (and, when present, [Monitor]).
            # 'throttled' appears first in the table row, then again in the
            # advisory; the advisory-only phrase anchors the ordering check.
            ($out.IndexOf('throttled')) | Should -BeLessThan ($out.IndexOf('currently rate-limited'))
            ($out.IndexOf('currently rate-limited')) | Should -BeLessThan ($out.IndexOf('[Watch]'))
        }

        It 'Invoke-UsageAction -Watch -Json throws (mutually exclusive)' {
            { Invoke-UsageAction -Watch -Json 6>$null } |
                Should -Throw -ExpectedMessage '*-Watch and -Json cannot be combined*'
        }

        It 'Invoke-UsageAction -Watch throws when stdout is redirected (interactive guard)' {
            # Pester cannot truly redirect the outer console, but we can
            # fake [Console]::IsOutputRedirected by defining a local
            # override. Use the script's defensive: we expect the check
            # to run before any loop / HTTP, so the throw should be
            # deterministic. To simulate, we temporarily alias Console's
            # static property via a wrapper: not feasible without PSCustom
            # refactor, so instead we assert the *loop itself does not run*
            # by setting -Interval high and confirming the guard fires
            # before any HTTP call. The cleanest check is to rely on the
            # happy-path assertion elsewhere and skip the redirected test
            # when [Console]::IsOutputRedirected is false (the Pester
            # subprocess runs with stdout redirected, so IsOutputRedirected
            # returns $true and the guard fires naturally).
            if (-not [Console]::IsOutputRedirected) {
                Set-ItResult -Skipped -Because 'Console stdout is not redirected in this host; guard cannot be exercised here.'
                return
            }
            { Invoke-UsageAction -Watch 6>$null } |
                Should -Throw -ExpectedMessage '*-Watch requires an interactive terminal*'
        }
    }

    Context 'Test-Is429' {
        It 'returns true for the test-mock pscustomobject Response shim' {
            $ex = [System.Exception]::new('429 Too Many Requests')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 429 })
            Test-Is429 $ex | Should -BeTrue
        }

        It 'returns true for the real System.Net.HttpStatusCode enum value' {
            # PS7's Invoke-RestMethod surfaces 429 via HttpResponseException
            # whose Response.StatusCode is an [HttpStatusCode] enum. Casting
            # that enum to [int] yields 429; Test-Is429 must accept it.
            $ex = [System.Exception]::new('rate limited')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::TooManyRequests })
            Test-Is429 $ex | Should -BeTrue
        }

        It 'returns false for non-429 status codes' {
            foreach ($code in 400, 401, 403, 500, 503) {
                $ex = [System.Exception]::new("status $code")
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $code })
                Test-Is429 $ex | Should -BeFalse -Because "code $code is not 429"
            }
        }

        It 'returns false when the exception has no Response member (network errors)' {
            $ex = [System.Net.WebException]::new('The operation has timed out.')
            Test-Is429 $ex | Should -BeFalse
        }

        It 'returns false for null / empty inputs' {
            Test-Is429 $null | Should -BeFalse
            $ex = [System.Exception]::new('plain exception')
            Test-Is429 $ex | Should -BeFalse
        }
    }

    Context 'Format-StatusErrorTail' {
        It 'collapses internal whitespace runs into a single space' {
            Format-StatusErrorTail "line1`r`nline2`tline3" | Should -Be 'line1 line2 line3'
        }

        It 'trims leading and trailing whitespace' {
            Format-StatusErrorTail "   hello world   " | Should -Be 'hello world'
        }

        It 'truncates messages longer than the cap and appends ellipsis dots' {
            $long = 'A' * 100
            $out  = Format-StatusErrorTail -Message $long -Max 60
            $out.Length    | Should -Be 63          # 60 + '...'
            $out           | Should -Match '\.\.\.$'
            $out.Substring(0, 60) | Should -Be ('A' * 60)
        }

        It 'returns the trimmed message untouched when it fits within the cap' {
            $msg = 'short message'
            Format-StatusErrorTail -Message $msg -Max 60 | Should -Be $msg
        }

        It 'returns empty string for null / empty input (no exception)' {
            Format-StatusErrorTail $null | Should -Be ''
            Format-StatusErrorTail ''    | Should -Be ''
        }

        It 'defaults -Max to the full-line width, not the mid-sentence width' {
            # Renderers that own a whole line call this without -Max; only
            # Invoke-SaveAction's parenthesised reason narrows it.
            $msg = 'B' * ($Script:AdvisoryReasonMaxWidth - 1)
            Format-StatusErrorTail -Message $msg | Should -Be $msg

            $out = Format-StatusErrorTail -Message ('B' * ($Script:AdvisoryReasonMaxWidth + 50))
            $out.Length | Should -Be ($Script:AdvisoryReasonMaxWidth + 3)
        }
    }

    Context 'Format-AggregateBars' {
        # Builds a per-slot result row matching the shape Get-UsageSnapshot
        # emits. Keeping it here (not in the outer Invoke-UsageAction
        # BeforeAll) avoids visibility surprises if either Context is
        # later moved or split into a separate file.
        BeforeAll {
            function New-OkRow {
                Param (
                    [string] $Name,
                    [bool]   $IsActive = $false,
                    $FiveUtil  = 'unset',
                    $SevenUtil = 'unset'
                )
                # Sentinel 'unset' distinguishes "bucket missing entirely"
                # (-> $null Data.<bucket>) from "bucket present, util=null"
                # (-> object with utilization=$null). Format-AggregateBars
                # treats both as 0% used; we exercise the missing-bucket
                # path here.
                $five  = $null
                $seven = $null
                if ($FiveUtil  -ne 'unset') { $five  = [pscustomobject]@{ utilization = [double]$FiveUtil;  resets_at = $null } }
                if ($SevenUtil -ne 'unset') { $seven = [pscustomobject]@{ utilization = [double]$SevenUtil; resets_at = $null } }
                $data = [pscustomobject]@{ five_hour = $five; seven_day = $seven }
                return [pscustomobject]@{
                    Name     = $Name
                    IsActive = $IsActive
                    Status   = 'ok'
                    Data     = $data
                    Error    = $null
                    Email    = $null
                }
            }
        }

        It 'returns silently when Results is empty' {
            $out = Format-AggregateBars -Results @() -TotalLineWidth 70 6>&1 | Out-String
            $out.Trim() | Should -BeNullOrEmpty
        }

        It 'returns silently when no HTTP-ok rows are present' {
            $rows = @(
                [pscustomobject]@{ Name='a'; IsActive=$false; Status='expired';  Data=$null; Error='x';  Email=$null }
                [pscustomobject]@{ Name='b'; IsActive=$false; Status='no-oauth'; Data=$null; Error=$null; Email=$null }
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out.Trim() | Should -BeNullOrEmpty
        }

        It 'single ok slot at 30% / 40% util renders 30% / 40% used' {
            $rows = @( New-OkRow -Name 'a' -FiveUtil 30 -SevenUtil 40 )
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+30%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+40%\s*$'
        }

        It 'two ok slots aggregate as Sigma-used over N*100 (Session 50%, Week 25%)' {
            # 5h: (10+90)/200 = 50% used.
            # 7d: ( 0+50)/200 = 25% used.
            $rows = @(
                (New-OkRow -Name 'a' -FiveUtil 10 -SevenUtil  0)
                (New-OkRow -Name 'b' -FiveUtil 90 -SevenUtil 50)
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+50%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+25%\s*$'
        }

        It 'null/missing buckets count as 0% used' {
            # 5h: (10 + 0)/200 = 5% used.
            # 7d: ( 0 + 50)/200 = 25% used.
            $rows = @(
                (New-OkRow -Name 'a' -FiveUtil 10)              # SevenUtil missing -> 0 used
                (New-OkRow -Name 'b' -SevenUtil 50)             # FiveUtil missing -> 0 used
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+5%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+25%\s*$'
        }

        It 'HTTP-failure rows are excluded from the aggregate' {
            # Only the ok row contributes to N. 1-slot pool, 5h=20% used.
            $rows = @(
                (New-OkRow -Name 'good' -FiveUtil 20 -SevenUtil 30)
                [pscustomobject]@{ Name='bad'; IsActive=$false; Status='error'; Data=$null; Error='boom'; Email=$null }
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+20%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+30%\s*$'
        }



        It 'utilization above 100 is clamped to 100' {
            # 7d=150% gets clamped to 100% used.
            $rows = @( (New-OkRow -Name 'a' -FiveUtil 0 -SevenUtil 150) )
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+100%\s*$'
        }

        It 'each rendered bar line equals TotalLineWidth (fits to table edge)' {
            $rows = @( (New-OkRow -Name 'a' -FiveUtil 50 -SevenUtil 50) )
            $w    = 70
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth $w 6>&1 | Out-String
            $bars = @($out -split "`r?`n" | Where-Object { $_ -match '\[' })
            $bars.Count | Should -Be 2
            foreach ($line in $bars) { $line.Length | Should -Be $w }
        }

        It 'bar width clamps to 8 when TotalLineWidth is below floor (line is 25 chars regardless)' {
            $rows = @( (New-OkRow -Name 'a' -FiveUtil 50 -SevenUtil 50) )
            # 17 fixed + 8 floor = 25. Caller's TotalLineWidth=10 cannot
            # shrink the bar further; we render an "ugly but informative"
            # line instead of a zero-width bracket pair.
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth 10 6>&1 | Out-String
            $bars = @($out -split "`r?`n" | Where-Object { $_ -match '\[' })
            foreach ($line in $bars) { $line.Length | Should -Be 25 }
        }

        It 'emits one trailing blank line after each bar (4 lines total per render)' {
            $rows = @( (New-OkRow -Name 'a' -FiveUtil 25 -SevenUtil 75) )
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            # Out-String appends a trailing newline. Splitting on `r?`n
            # gives: <Session line>, <blank>, <Week line>, <blank>, ''.
            $lines = $out -split "`r?`n"
            ($lines | Where-Object { $_ -match '\[' }).Count       | Should -Be 2
            # Trailing empty string + 2 inter-line blanks = 3 empty entries.
            ($lines | Where-Object { $_ -eq '' }).Count            | Should -BeGreaterOrEqual 3
        }

    }

    Context 'Get-PoolMeanUtilization' {
        # Pure-helper unit tests for the pool-mean utilization math.
        # Get-PoolMeanUtilization is shared by Format-AggregateBars (the
        # bar above the table) and Format-WatchTitle -Aggregate (the
        # monitor terminal title). Pinning the math here means a
        # change to one site cannot silently drift from the other; the
        # Format-AggregateBars Context above pins the rendering side.
        BeforeAll {
            function New-OkRow {
                Param (
                    [string] $Name,
                    [bool]   $IsActive = $false,
                    $FiveUtil  = 'unset',
                    $SevenUtil = 'unset'
                )
                # Sentinel 'unset' distinguishes "bucket missing entirely"
                # from "bucket present, util=null". Matches the factory
                # in the Format-AggregateBars Context above; redeclared
                # locally so the file can be split later without coupling.
                $five  = $null
                $seven = $null
                if ($FiveUtil  -ne 'unset') { $five  = [pscustomobject]@{ utilization = [double]$FiveUtil;  resets_at = $null } }
                if ($SevenUtil -ne 'unset') { $seven = [pscustomobject]@{ utilization = [double]$SevenUtil; resets_at = $null } }
                $data = [pscustomobject]@{ five_hour = $five; seven_day = $seven }
                return [pscustomobject]@{
                    Name     = $Name
                    IsActive = $IsActive
                    Status   = 'ok'
                    Data     = $data
                    Error    = $null
                    Email    = $null
                }
            }
        }

        It 'returns $null for null Results (empty input)' {
            Get-PoolMeanUtilization -Results $null -BucketKey 'five_hour' | Should -BeNullOrEmpty
        }

        It 'returns $null for empty Results array' {
            Get-PoolMeanUtilization -Results @() -BucketKey 'five_hour' | Should -BeNullOrEmpty
        }

        It 'returns $null when zero HTTP-ok rows (all rows are HTTP-failure)' {
            $rows = @(
                [pscustomobject]@{ Name='a'; IsActive=$false; Status='expired';  Data=$null; Error='x';  Email=$null }
                [pscustomobject]@{ Name='b'; IsActive=$false; Status='no-oauth'; Data=$null; Error=$null; Email=$null }
            )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour'  | Should -BeNullOrEmpty
            Get-PoolMeanUtilization -Results $rows -BucketKey 'seven_day' | Should -BeNullOrEmpty
        }

        It 'returns the row util for a single-row pool (N=1 degenerate)' {
            $rows = @( New-OkRow -Name 'a' -FiveUtil 37 -SevenUtil 42 )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour'  | Should -Be 37
            Get-PoolMeanUtilization -Results $rows -BucketKey 'seven_day' | Should -Be 42
        }

        It 'returns the mean across N HTTP-ok rows' {
            # 5h mean: (40+60+80)/3 = 60. 7d mean: (50+70+90)/3 = 70.
            $rows = @(
                (New-OkRow -Name 'a' -FiveUtil 40 -SevenUtil 50)
                (New-OkRow -Name 'b' -FiveUtil 60 -SevenUtil 70)
                (New-OkRow -Name 'c' -FiveUtil 80 -SevenUtil 90)
            )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour'  | Should -Be 60
            Get-PoolMeanUtilization -Results $rows -BucketKey 'seven_day' | Should -Be 70
        }

        It 'rounds to nearest integer (banker''s rounding via [math]::Round)' {
            # (33+34)/2 = 33.5. [math]::Round uses banker's rounding by default
            # (round half to even), so 33.5 -> 34. Pin the exact behavior so
            # a refactor to AwayFromZero would surface here.
            $rows = @(
                (New-OkRow -Name 'a' -FiveUtil 33 -SevenUtil 0)
                (New-OkRow -Name 'b' -FiveUtil 34 -SevenUtil 0)
            )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour' | Should -Be 34
        }

        It 'null/missing buckets count as 0 (N stays N, not N-1)' {
            # Two ok rows, one row missing five_hour. Mean = (0 + 60) / 2 = 30,
            # NOT 60 (which would be N-1 denominator).
            $rows = @(
                (New-OkRow -Name 'a' -SevenUtil 0)                # FiveUtil missing -> 0
                (New-OkRow -Name 'b' -FiveUtil 60 -SevenUtil 0)
            )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour' | Should -Be 30
        }

        It 'utilization above 100 is clamped to 100' {
            # 5h: (150 -> 100) + 50 / 2 = 75
            $rows = @(
                (New-OkRow -Name 'a' -FiveUtil 150 -SevenUtil 0)
                (New-OkRow -Name 'b' -FiveUtil  50 -SevenUtil 0)
            )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour' | Should -Be 75
        }

        It 'utilization below 0 is clamped to 0' {
            # 5h: (-30 -> 0) + 60 / 2 = 30
            $rows = @(
                (New-OkRow -Name 'a' -FiveUtil -30 -SevenUtil 0)
                (New-OkRow -Name 'b' -FiveUtil  60 -SevenUtil 0)
            )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour' | Should -Be 30
        }

        It 'HTTP-failure rows are excluded from the mean' {
            # Only the ok row counts. Mean = 20 / 1 = 20.
            $rows = @(
                (New-OkRow -Name 'good' -FiveUtil 20 -SevenUtil 0)
                [pscustomobject]@{ Name='bad'; IsActive=$false; Status='error'; Data=$null; Error='boom'; Email=$null }
            )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour' | Should -Be 20
        }

        # A cached row can sit on screen long enough for its 5h window to roll.
        # Select-LiveBuckets drops such a bucket at New-UsageResult, so it
        # reaches the bars as missing and counts 0, the same as it counts for
        # rotation and keep-warm. The row is built through New-UsageResult
        # rather than by hand precisely because that is where the rule runs:
        # a hand-built row with a rolled bucket is not one production can emit.
        It 'counts a bucket whose window has already reset as 0' {
            $past   = [DateTimeOffset]::UtcNow.AddHours(-1)
            $future = [DateTimeOffset]::UtcNow.AddHours(2)
            $rolled = New-UsageResult -Status 'error' -CachedReason 'network' -Data ([pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = $past.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
                seven_day = $null
            })
            $rows = @(
                [pscustomobject]@{
                    Name = 'rolled'; IsActive = $false; Status = 'error'; Error = $null; Email = $null
                    IsCachedFallback = $true
                    Data = $rolled.Data
                }
                [pscustomobject]@{
                    Name = 'live'; IsActive = $true; Status = 'ok'; Error = $null; Email = $null
                    IsCachedFallback = $false
                    Data = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = 40.0; resets_at = $future.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
                        seven_day = $null
                    }
                }
            )

            # (0 + 40) / 2 = 20, not (100 + 40) / 2 = 70.
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour' | Should -Be 20
        }

        It 'still counts a bucket whose window has not reset yet' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2)
            $rows = @(
                [pscustomobject]@{
                    Name = 'hot'; IsActive = $true; Status = 'ok'; Error = $null; Email = $null
                    IsCachedFallback = $false
                    Data = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = 90.0; resets_at = $future.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
                        seven_day = $null
                    }
                }
            )
            Get-PoolMeanUtilization -Results $rows -BucketKey 'five_hour' | Should -Be 90
        }
    }

    Context 'Get-AggregateBarColor' {
        # Pure-helper unit tests for the aggregate bar color thresholds.
        # Runs the threshold boundaries explicitly so a future tweak of
        # $Script:AggregateRedPct / $Script:AggregateYellowPct shows up
        # here as a failing test rather than a silent visual change.
        It 'returns Green below AggregateYellowPct (50%)' {
            Get-AggregateBarColor -UsedPct  0 | Should -Be 'Green'
            Get-AggregateBarColor -UsedPct 49 | Should -Be 'Green'
        }

        It 'returns Yellow between AggregateYellowPct (50%) and AggregateRedPct-1 (89%)' {
            Get-AggregateBarColor -UsedPct 50 | Should -Be 'Yellow'
            Get-AggregateBarColor -UsedPct 89 | Should -Be 'Yellow'
        }

        It 'returns Red at and above AggregateRedPct (90%)' {
            Get-AggregateBarColor -UsedPct  90 | Should -Be 'Red'
            Get-AggregateBarColor -UsedPct 100 | Should -Be 'Red'
        }
    }

    Context 'Format-UsageTable -IncludeAggregateBars integration' {
        # Reuses the New-OkRow factory from the Format-AggregateBars
        # context above but runs in its own Context scope; redeclare
        # locally so the file can be split later without coupling.
        BeforeAll {
            function New-OkRow {
                Param (
                    [string] $Name,
                    [bool]   $IsActive = $false,
                    $FiveUtil  = 30,
                    $SevenUtil = 40
                )
                return [pscustomobject]@{
                    Name     = $Name
                    IsActive = $IsActive
                    Status   = 'ok'
                    Data     = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = [double]$FiveUtil;  resets_at = $null }
                        seven_day = [pscustomobject]@{ utilization = [double]$SevenUtil; resets_at = $null }
                    }
                    Error    = $null
                    Email    = $null
                }
            }

            # 60 chars, enough to push the table past 80 columns on its own.
            $script:WideName = 'slot-' + ('x' * 55)

            # The column-header line is the width yardstick for the bar-clamp
            # tests below: its Status field is exactly the 6-char header
            # literal, so its length equals the $totalLineWidth the bars are
            # derived from.
            function Get-HeaderLineLength {
                Param ([string[]] $Lines)
                return @($Lines | Where-Object { $_ -match '^\s+Slot\s+Account\s+Session\s+Week\s+Status\s*$' })[0].Length
            }
        }

        It 'renders bar lines between [Usage] header and column header when -IncludeAggregateBars is set' {
            $rows = @( (New-OkRow -Name 'alpha') )
            $out  = Format-UsageTable -Results $rows -IncludeAggregateBars 6>&1 | Out-String

            $out | Should -Match '\[Usage\] Plan usage'
            $out | Should -Match '(?m)^\s+Session\s*\['
            $out | Should -Match '(?m)^\s+Week\s*\['

            # Order: header < Session bar < Week bar < column header.
            $iHeader  = $out.IndexOf('[Usage] Plan usage')
            $iSession = $out.IndexOf('Session [')
            $iWeek    = $out.IndexOf('Week    [')
            $iSlotCol = ($out -split "`r?`n" | ForEach-Object { if ($_ -match '^\s+Slot\s+Account') { $_ } } | Select-Object -First 1)
            $iSlotIdx = $out.IndexOf($iSlotCol)
            $iHeader  | Should -BeLessThan $iSession
            $iSession | Should -BeLessThan $iWeek
            $iWeek    | Should -BeLessThan $iSlotIdx
        }

        It 'omits bar lines when -IncludeAggregateBars is not set (regression guard for verbose-fallback callers)' {
            # Format-UsageVerbose -> Format-UsageTable (no switch) for non-ok
            # rows. The bars are a pool-level summary; rendering them on a
            # single failed-row drill-down would be off-topic.
            $rows = @( (New-OkRow -Name 'alpha') )
            $out  = Format-UsageTable -Results $rows 6>&1 | Out-String
            $out | Should -Not -Match '(?m)^\s+Session\s*\['
            $out | Should -Not -Match '(?m)^\s+Week\s*\['
        }

        It 'renamed table column headers: "Session" / "Week" replace "5h" / "7d"' {
            $rows = @( (New-OkRow -Name 'alpha') )
            $out  = Format-UsageTable -Results $rows 6>&1 | Out-String
            # New literals present; old literals absent in header line.
            $out | Should -Match '(?m)^\s+Slot\s+Account\s+Session\s+Week\s+Status\s*$'
            $out | Should -Not -Match '(?m)^\s+Slot\s+Account\s+5h\s+7d\s+Status\s*$'
        }

        # The bars fit to the table, and the table is content-sized, so it can
        # be wider than the terminal. An unclamped bar then wraps, which reads
        # as a rendering bug rather than as an overflowing table.
        It 'clamps the bar lines to the terminal width when the table is wider' {
            Mock Get-ConsoleWidth -MockWith { 80 }
            $out   = Format-UsageTable -Results @((New-OkRow -Name $script:WideName)) -IncludeAggregateBars 6>&1 | Out-String
            $lines = @($out -split "`r?`n")

            # Guard: the table really is wider than the terminal here.
            (Get-HeaderLineLength -Lines $lines) | Should -BeGreaterThan 80

            $barLines = @($lines | Where-Object { $_ -match '^\s+(Session|Week)\s*\[' })
            $barLines.Count | Should -Be 2
            foreach ($line in $barLines) { $line.Length | Should -Be 79 }

            # The table itself stays content-sized; only the derived bar width
            # is clamped.
            @($lines | Where-Object { $_ -match [regex]::Escape($script:WideName) }).Count | Should -BeGreaterThan 0
        }

        It 'leaves the fit-to-table bar width alone when the terminal width is unknown' {
            Mock Get-ConsoleWidth -MockWith { 0 }
            $out   = Format-UsageTable -Results @((New-OkRow -Name $script:WideName)) -IncludeAggregateBars 6>&1 | Out-String
            $lines = @($out -split "`r?`n")

            $headerLen = Get-HeaderLineLength -Lines $lines
            $headerLen | Should -BeGreaterThan 80
            $barLines  = @($lines | Where-Object { $_ -match '^\s+(Session|Week)\s*\[' })
            foreach ($line in $barLines) { $line.Length | Should -Be $headerLen }
        }
    }

    Context 'Format-ResetDelta' {
        It 'returns em-dash for null / empty / 0' {
            Format-ResetDelta $null  | Should -Be '—'
            Format-ResetDelta ''     | Should -Be '—'
            # Legacy-API integer 0 should also not explode (PowerShell coerces
            # 0 -eq '' to $true, so the early return fires).
            Format-ResetDelta 0      | Should -Be '—'
        }

        It 'returns em-dash for malformed input rather than throwing' {
            Format-ResetDelta 'not a date at all' | Should -Be '—'
        }

        It 'returns "now" for past ISO timestamps' {
            $past = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $past | Should -Be 'now'
        }

        It 'returns "in <m>m" for sub-hour ISO deltas' {
            $future = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^\(29|30\)m$'
        }

        It 'returns "in <h>h <m>m" for 1-23 hour ISO deltas (minute precision kept)' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2).AddMinutes(14).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^\(2h 1[34]m\)$'
        }

        It 'returns "in <h>h" (integer total hours) for >=24h ISO deltas' {
            $future = [DateTimeOffset]::UtcNow.AddHours(42).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^\(4[12]h\)$'
        }

        It 'returns "in <h>h" for multi-day ISO deltas (no days unit)' {
            $future = [DateTimeOffset]::UtcNow.AddDays(4).AddHours(7).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            # 4d 7h = 103h; test elapsed time may trim a minute so 102 or 103.
            Format-ResetDelta $future | Should -Match '^\(10[23]h\)$'
            # And definitely not the old "Xd Yh" format.
            Format-ResetDelta $future | Should -Not -Match 'd '
        }

        It 'accepts a pre-parsed DateTimeOffset value too (defensive)' {
            $future = [DateTimeOffset]::UtcNow.AddMinutes(45)
            Format-ResetDelta $future | Should -Match '^\(4[45]m\)$'
        }
    }

    Context 'Format-ResetAbsolute' {
        # NOTE: Windows local tz names contain spaces (e.g. "W. Europe Standard
        # Time"), so every regex tail allows .+ rather than \S+. Test names
        # also avoid `<`, `>`, and `|` because those characters seem to trip
        # Pester 5's error-report pipeline into treating fragments as commands
        # (observed: "The term 'pm' is not recognized").
        It 'returns em-dash for null / empty / malformed input' {
            Format-ResetAbsolute $null   | Should -Be '—'
            Format-ResetAbsolute ''      | Should -Be '—'
            Format-ResetAbsolute 'nope'  | Should -Be '—'
        }

        It 'same-day ISO renders hour:minute am or pm and the local tz name' {
            # Pick a timestamp 3 hours ahead. Near local midnight this may
            # cross to the next day; the assertions branch on which side we
            # land to keep the test deterministic regardless of wall time.
            $future  = [DateTimeOffset]::Now.AddHours(3)
            $sameDay = $future.LocalDateTime.Date -eq [DateTime]::Now.Date
            $iso     = $future.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            $out = Format-ResetAbsolute $iso
            if ($sameDay) {
                # Resets 7:50pm W. Europe Standard Time
                $out | Should -Match '^Resets \d{1,2}:\d{2}(am|pm) .+$'
                $out | Should -Not -Match ','
            } else {
                # Different-day form when 3h from now crosses midnight.
                $out | Should -Match '^Resets \w{3} \d{1,2}, '
            }
        }

        It 'multi-day ISO renders Mon d, then time and local tz name' {
            $future = [DateTimeOffset]::Now.AddHours(48)
            $iso    = $future.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            # Resets Apr 26, 7:05pm W. Europe Standard Time
            Format-ResetAbsolute $iso | Should -Match '^Resets \w{3} \d{1,2}, \d{1,2}(:\d{2})?(am|pm) .+$'
        }

        It 'drops the :00 suffix on on-the-hour different-day times' {
            # 9:00am tomorrow local exercises the minute-zero short form.
            $tomorrow9am = [DateTime]::Today.AddDays(1).AddHours(9)
            $dto  = [DateTimeOffset]$tomorrow9am
            $iso  = $dto.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $out  = Format-ResetAbsolute $iso

            # Resets Apr 25, 9am W. Europe Standard Time
            $out | Should -Match '^Resets \w{3} \d{1,2}, 9am .+$'
        }
    }

    Context 'Get-SlotProfile' {
        # Reuses the New-Slot BeforeAll helper from the Invoke-UsageAction
        # context so slot files have the exact claudeAiOauth shape the
        # helper expects. Profile caching was removed along with the
        # sidecar scheme; Get-SlotProfile is now a pure HTTP helper used
        # by Invoke-SaveAction to embed the email in the slot filename.
        BeforeAll {
            function New-ProfileSlot {
                Param (
                    [string] $Name,
                    [string] $AccessToken = 'sk-ant-oat-profile',
                    $ExpiresAt
                )
                if ($null -eq $ExpiresAt) { $ExpiresAt = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds() }
                $payload = @{
                    claudeAiOauth = @{
                        accessToken      = $AccessToken
                        refreshToken     = 'sk-ant-ort-profile'
                        expiresAt        = $ExpiresAt
                        scopes           = @('user:inference','user:profile')
                        subscriptionType = 'team'
                        rateLimitTier    = 'default_claude_max_5x'
                    }
                } | ConvertTo-Json -Depth 10 -Compress
                $path = Join-Path $script:SandboxHome '.claude' | Join-Path -ChildPath ".credentials.$Name.json"
                $dir  = Split-Path -Parent $path
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM
                return $path
            }
        }

        It 'happy path: 200 response returns the email' {
            $slot = New-ProfileSlot -Name 'happy'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'alice@example.com'; uuid = 'acct-uuid' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'ok'
            $res.Email  | Should -Be 'alice@example.com'

            # No caching: a second call fires another HTTP request. This
            # is by design; email is now encoded in the slot filename at
            # save time, so Get-SlotProfile is only called at save time.
            Get-SlotProfile -SlotPath $slot | Out-Null
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It '401 response returns unauthorized' {
            $slot = New-ProfileSlot -Name 'revoked'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 401 }
                $inner = [System.Exception]::new('Unauthorized')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            (Get-SlotProfile -SlotPath $slot).Status | Should -Be 'unauthorized'
        }

        It 'network timeout returns error' {
            $slot = New-ProfileSlot -Name 'offline'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                throw [System.Net.WebException]::new('The operation has timed out.')
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'error'
            $res.Error  | Should -Match 'timed out'
        }

        It 'slot without claudeAiOauth returns no-oauth and makes zero HTTP calls' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            if (-not (Test-Path -LiteralPath $credDir)) { New-Item -ItemType Directory -Path $credDir -Force | Out-Null }
            $slot = Join-Path $credDir '.credentials.apikey.json'
            Set-Content -LiteralPath $slot -Value '{"apiKey":"sk-ant-api..."}' -NoNewline -Encoding utf8NoBOM

            (Get-SlotProfile -SlotPath $slot).Status | Should -Be 'no-oauth'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It 'expired token: refresh succeeds then profile call uses the new token' {
            $slot = New-ProfileSlot -Name 'stale' `
                                    -AccessToken 'sk-ant-oat-OLD' `
                                    -ExpiresAt   ([DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds())

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                if ($Headers['Authorization'] -ne 'Bearer sk-ant-oat-NEW') {
                    throw "refresh did not propagate to profile call: got '$($Headers['Authorization'])'"
                }
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'bob@example.com'; uuid = 'acct-uuid' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'ok'
            $res.Email  | Should -Be 'bob@example.com'

            $after = Get-Content -LiteralPath $slot -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'
        }

        # -NoRefresh is what lets the identity guard probe .credentials.json
        # while a live client may be mid-request on those exact tokens: a
        # refresh would rotate the refresh token out from under it to answer a
        # question. The inverse of the test above, on the same fixture.
        It '-NoRefresh reports expired instead of rotating an expired token' {
            $slot = New-ProfileSlot -Name 'norefresh' `
                                    -AccessToken 'sk-ant-oat-OLD' `
                                    -ExpiresAt   ([DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds())
            Mock Update-SlotTokens { throw '-NoRefresh must not rotate tokens' }

            $res = Get-SlotProfile -SlotPath $slot -NoRefresh

            $res.Status    | Should -Be 'expired'
            $res.Error     | Should -Match 'NoRefresh'
            # Transport=$false: nothing was attempted, so a retry cannot differ.
            $res.Transport | Should -BeFalse
            Should -Invoke Update-SlotTokens -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/profile'
            }
            # The slot file is left byte-identical; nothing was rewritten.
            (Get-Content -LiteralPath $slot -Raw | ConvertFrom-Json).claudeAiOauth.accessToken |
                Should -Be 'sk-ant-oat-OLD'
        }

        It '-NoRefresh still answers normally while the token is valid' {
            $slot = New-ProfileSlot -Name 'norefresh-ok'
            Mock Update-SlotTokens { throw '-NoRefresh must not rotate tokens' }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'carol@example.com'; uuid = 'acct-uuid-carol' }
                    organization = [pscustomobject]@{ uuid = 'org-uuid' }
                }
            }

            $res = Get-SlotProfile -SlotPath $slot -NoRefresh

            $res.Status      | Should -Be 'ok'
            $res.Email       | Should -Be 'carol@example.com'
            $res.AccountUuid | Should -Be 'acct-uuid-carol'
            Should -Invoke Update-SlotTokens -Times 0 -Exactly
        }

        It 'refresh 429 surfaces as rate-limited (not expired)' {
            $slot = New-ProfileSlot -Name 'rl' -ExpiresAt ([DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds())
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }
            (Get-SlotProfile -SlotPath $slot).Status | Should -Be 'rate-limited'
        }

        It 'refresh failure (non-429) surfaces as expired with the underlying error' {
            $slot = New-ProfileSlot -Name 'exp' -ExpiresAt ([DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds())
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Exception]::new('refresh_token invalid')
            }
            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'expired'
            $res.Error  | Should -Match 'refresh_token invalid'
        }

        It 'profile endpoint 429 surfaces as rate-limited' {
            $slot = New-ProfileSlot -Name 'pl-rl'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }
            (Get-SlotProfile -SlotPath $slot).Status | Should -Be 'rate-limited'
        }

        It 'returns error when profile response is missing account.email' {
            $slot = New-ProfileSlot -Name 'noemail'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{ organization = [pscustomobject]@{ name = 'x' } }
            }
            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'error'
            $res.Error  | Should -Match 'missing account.email'
        }
    }

    Context 'Format-UsageVerbose (uncovered branches)' {
        # Format-UsageVerbose is exercised indirectly by `sca usage <name>`
        # integration tests, but several decision branches are not hit:
        # the active-marker, the Account line, the non-ok fallback table,
        # the empty-response advisory, and the null-reset em-dash.

        It "appends ' (active)' to the header when Result.IsActive is true" {
            $row = [pscustomobject]@{
                Name     = 'work'
                IsActive = $true
                Status   = 'ok'
                Data     = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 2.0; resets_at = $null }
                }
                Error    = $null
                Email    = $null
            }
            $out = Format-UsageVerbose -Result $row 6>&1 | Out-String
            $out | Should -Match "Slot 'work' \(active\)"
        }

        It "renders an 'Account:' line when Result.Email is set" {
            $row = [pscustomobject]@{
                Name     = 'work'
                IsActive = $false
                Status   = 'ok'
                Data     = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 2.0; resets_at = $null }
                }
                Error    = $null
                Email    = 'alice@example.com'
            }
            $out = Format-UsageVerbose -Result $row 6>&1 | Out-String
            $out | Should -Match 'Account: alice@example\.com'
        }

        It 'delegates to Format-UsageTable for non-ok rows (fallback)' {
            # When the row's Status is anything other than 'ok',
            # Format-UsageVerbose drops out to a single-row table render
            # so the user sees the status label without per-bucket detail.
            $row = [pscustomobject]@{
                Name     = 'dead'
                IsActive = $false
                Status   = 'expired'
                Data     = $null
                Error    = 'refresh_token invalid'
                Email    = $null
            }
            $out = Format-UsageVerbose -Result $row 6>&1 | Out-String
            $out | Should -Match "Slot 'dead'"
            # The fallback render uses Format-UsageTable, which renders the
            # bare 'expired' label. The reason comes from Format-UsageAdvisory,
            # which Format-UsageFrame (not this function) renders.
            $out | Should -Match '(?m)^\s+dead\b.*\bexpired\s*$'
            $out | Should -Not -Match 'refresh_token invalid'
            # No Session/Week bucket rows in the fallback path.
            $out | Should -Not -Match '^\s+Session\s'
        }

        It "prints '(empty response)' when Status is ok but Data is null" {
            $row = [pscustomobject]@{
                Name     = 'empty'
                IsActive = $false
                Status   = 'ok'
                Data     = $null
                Error    = $null
                Email    = $null
            }
            $out = Format-UsageVerbose -Result $row 6>&1 | Out-String
            $out | Should -Match '\(empty response\)'
        }

        It 'renders em-dash for a bucket whose resets_at is null' {
            $row = [pscustomobject]@{
                Name     = 'partial'
                IsActive = $false
                Status   = 'ok'
                Data     = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 4.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 5.0; resets_at = $null }
                }
                Error    = $null
                Email    = $null
            }
            $out = Format-UsageVerbose -Result $row 6>&1 | Out-String
            # The bucket cell renders the percent + em-dash for the
            # null reset (vs 'Resets <time>' when set).
            $out | Should -Match 'Session\s+\d+%\s+—'
            $out | Should -Match 'Week\s+\d+%\s+—'
        }
    }

    Context 'Get-SlotUsage (wraps Get-SlotOAuth failures)' {
        # When Get-SlotOAuth throws (e.g. corrupt slot file), Get-SlotUsage
        # must catch and surface a Status='error' record rather than
        # bubbling the exception up to Invoke-UsageAction.
        It 'returns Status=error when the slot file is corrupt JSON' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.broken.json'
            Set-Content -LiteralPath $slot -Value 'not-json{' -NoNewline

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status | Should -Be 'error'
            $r.Error  | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Get-SlotUsage (429 retry-after-sleep on first-time cache miss)' {
        # Documented behavior (see source ~line 2160): on usage-endpoint
        # 429, if the slot has NO cache entry at all (first poll ever
        # for this slot, hit by 429), wait 5s and retry once. Mock
        # Start-Sleep so the test is fast.
        BeforeEach {
            $script:CredDirPath = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()

            $script:sleepCount = 0
            Mock Start-Sleep -MockWith { $script:sleepCount++ }
        }

        It '429 then ok-on-retry: Status=ok and Start-Sleep was called once with 5 seconds' {
            $slot = Join-Path $script:CredDirPath '.credentials.first429.json'
            $payload = @{ claudeAiOauth = @{
                accessToken = 'AT'; refreshToken = 'RT'; expiresAt = $script:FutureMs
            } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            $script:usageCall = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $script:usageCall++
                if ($script:usageCall -eq 1) {
                    $resp  = [pscustomobject]@{ StatusCode = 429 }
                    $inner = [System.Exception]::new('Too Many Requests')
                    $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                    throw $inner
                }
                # Second call (after retry sleep) succeeds.
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = $null }
                }
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status | Should -Be 'ok'
            $r.Data.five_hour.utilization | Should -Be 5.0
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
            $script:usageCall | Should -Be 2
        }

        It '429 then 429-again-on-retry: Status=rate-limited' {
            $slot = Join-Path $script:CredDirPath '.credentials.tworetry.json'
            $payload = @{ claudeAiOauth = @{
                accessToken = 'AT'; refreshToken = 'RT'; expiresAt = $script:FutureMs
            } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status | Should -Be 'rate-limited'
        }

        # The retry is a second, independent request. Labelling whatever it
        # returns 'rate-limited' hid the failure class that matters most here:
        # a 4xx from a drifted endpoint after a Claude Code upgrade came out
        # wearing the label of the one failure that clears on its own, with no
        # status and no message for the advisory to print.
        It '429 then 404-on-retry: Status=error carrying the real code' {
            $slot = Join-Path $script:CredDirPath '.credentials.retrydrift.json'
            $payload = @{ claudeAiOauth = @{
                accessToken = 'AT'; refreshToken = 'RT'; expiresAt = $script:FutureMs
            } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            $script:usageCall = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $script:usageCall++
                $code  = if ($script:usageCall -eq 1) { 429 } else { 404 }
                $resp  = [pscustomobject]@{ StatusCode = $code }
                $inner = [System.Exception]::new("HTTP $code from the usage endpoint")
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status     | Should -Be 'error'
            $r.HttpStatus | Should -Be 404
            $r.Error      | Should -Match '404'
        }

        It '429 then 401-on-retry: Status=unauthorized' {
            $slot = Join-Path $script:CredDirPath '.credentials.retryauth.json'
            $payload = @{ claudeAiOauth = @{
                accessToken = 'AT'; refreshToken = 'RT'; expiresAt = $script:FutureMs
            } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            $script:usageCall = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $script:usageCall++
                $code  = if ($script:usageCall -eq 1) { 429 } else { 401 }
                $resp  = [pscustomobject]@{ StatusCode = $code }
                $inner = [System.Exception]::new("HTTP $code")
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            (Get-SlotUsage -SlotPath $slot).Status | Should -Be 'unauthorized'
        }

        It '429 with a STALE cache entry: Status=rate-limited; last-known data kept; no retry sleep' {
            $slot = Join-Path $script:CredDirPath '.credentials.staleC.json'
            $payload = @{ claudeAiOauth = @{
                accessToken = 'AT'; refreshToken = 'RT'; expiresAt = $script:FutureMs
            } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            # Pre-populate a stale cache entry so the function knows the
            # slot has been seen before; the retry path should NOT fire.
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 1.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status | Should -Be 'rate-limited'
            # Stale cache is now served (marked) so the row keeps its
            # last-known numbers instead of collapsing to em-dashes.
            $r.IsCachedFallback           | Should -BeTrue
            $r.Data.five_hour.utilization | Should -Be 1
            # No 5s retry sleep because the slot was already seen.
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    Context 'Get-SlotUsage (network / timeout resilience)' {
        # A codeless transport failure (the HttpClient.Timeout case)
        # used to return Status='error' immediately, discarding a perfectly
        # good cached reading and wiping the row's numbers for a whole poll
        # interval. It now runs the same fallback ladder as the 429 arm.
        BeforeEach {
            $script:CredDirPath = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
            Mock Start-Sleep -MockWith { }

            function New-TimeoutSlot {
                Param ([string] $Name)
                $slot = Join-Path $script:CredDirPath ".credentials.$Name.json"
                $payload = @{ claudeAiOauth = @{
                    accessToken = 'AT'; refreshToken = 'RT'; expiresAt = $script:FutureMs
                } } | ConvertTo-Json -Compress
                Set-Content -LiteralPath $slot -Value $payload -NoNewline
                return $slot
            }

            # The real message PS7 raises for -TimeoutSec: a TaskCanceledException
            # carrying NO .Response, which is what made $status $null and sent the
            # row down the generic arm.
            $script:TimeoutMessage = 'The request was canceled due to the configured HttpClient.Timeout of 12 seconds elapsing.'

            # A coded failure carrying a .Response, for the arms that branch on
            # the status rather than on the exception type.
            function New-CodedWebException {
                Param ([int] $StatusCode)
                $resp = [pscustomobject]@{ StatusCode = $StatusCode }
                $ex   = [System.Exception]::new("Response status code does not indicate success: $StatusCode.")
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                return $ex
            }
        }

        It 'serves a FRESH cache as ok, tagged as a network fallback' {
            $slot = New-TimeoutSlot 'netfresh'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 22.0; resets_at = $null } }
                Timestamp = [DateTime]::UtcNow
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Threading.Tasks.TaskCanceledException]::new($script:TimeoutMessage)
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status                     | Should -Be 'ok'
            $r.IsCachedFallback           | Should -BeTrue
            $r.FallbackReason             | Should -Be 'network'
            $r.Data.five_hour.utilization | Should -Be 22.0
        }

        It 'serves a STALE cache as error but keeps the numbers and the message' {
            $slot = New-TimeoutSlot 'netstale'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 49.0; resets_at = $null } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Threading.Tasks.TaskCanceledException]::new($script:TimeoutMessage)
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status                     | Should -Be 'error'
            $r.IsCachedFallback           | Should -BeTrue
            $r.FallbackReason             | Should -Be 'network'
            $r.Data.five_hour.utilization | Should -Be 49.0
            $r.Error                      | Should -Match 'HttpClient.Timeout'
        }

        It 'retries once with NO sleep when nothing is cached, and succeeds' {
            $slot = New-TimeoutSlot 'netretry'
            $script:usageCall = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $script:usageCall++
                if ($script:usageCall -eq 1) { throw (New-CodedWebException -StatusCode 529) }
                return [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 7.0; resets_at = $null } }
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status                     | Should -Be 'ok'
            $r.Data.five_hour.utilization | Should -Be 7.0
            $script:usageCall             | Should -Be 2
            # The first attempt already waited; an extra sleep would only
            # freeze the frame.
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'caches the successful retry so the next failure can fall back' {
            $slot = New-TimeoutSlot 'netretrycache'
            $script:usageCall = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $script:usageCall++
                if ($script:usageCall -eq 1) { throw (New-CodedWebException -StatusCode 529) }
                return [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 8.0; resets_at = $null } }
            }

            Get-SlotUsage -SlotPath $slot | Out-Null
            $Script:SlotUsageCache.ContainsKey($slot)          | Should -BeTrue
            $Script:SlotUsageCache[$slot].Data.five_hour.utilization | Should -Be 8.0
        }

        It 'returns error with the message when the retry also fails and nothing is cached' {
            $slot = New-TimeoutSlot 'netdead'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Net.Http.HttpRequestException]::new('No such host is known.')
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status     | Should -Be 'error'
            $r.Error      | Should -Match 'No such host'
            $r.HttpStatus | Should -BeNullOrEmpty
            $r.Data       | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        # Get-UsageSnapshot walks slots serially and nothing is cached on the
        # first poll of a watch, so this arm sets that poll's wall clock. A
        # timeout has already burned the full UsageTimeoutSec, making it both
        # the most expensive class to repeat and the least likely to differ:
        # retrying it doubled every slot's contribution to the first frame.
        It 'does NOT retry a timeout, and still reports it' {
            $slot = New-TimeoutSlot 'noretrytimeout'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Threading.Tasks.TaskCanceledException]::new($script:TimeoutMessage)
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status     | Should -Be 'error'
            $r.Error      | Should -Match 'HttpClient.Timeout'
            $r.HttpStatus | Should -BeNullOrEmpty
            $r.Data       | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        # 401 / 403 / 429 have their own arms; any other 4xx describes the
        # request, so the server rejects it identically the second time.
        It 'does NOT retry a non-retriable 4xx, and still reports its code' {
            $slot = New-TimeoutSlot 'noretry404'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw (New-CodedWebException -StatusCode 404)
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status     | Should -Be 'error'
            $r.HttpStatus | Should -Be 404
            $r.Error      | Should -Match '404'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        # The failure AGENTS.md names as the one thing only a live `sca usage`
        # can catch: the endpoint drifts after a Claude Code upgrade and starts
        # answering 4xx. Served from cache it renders as 'ok' with
        # fresh-looking numbers for the whole TTL, under -Watch and monitor
        # alike, which is exactly the report that would not reach the user.
        It 'does NOT serve a fresh cache after a non-retriable 4xx' {
            $slot = New-TimeoutSlot 'drift404'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 21.0; resets_at = $null } }
                Timestamp = [DateTime]::UtcNow
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw (New-CodedWebException -StatusCode 404)
            }

            $r = Get-SlotUsage -SlotPath $slot

            $r.Status           | Should -Be 'error'
            $r.HttpStatus       | Should -Be 404
            $r.IsCachedFallback | Should -BeFalse
            $r.Data             | Should -BeNullOrEmpty
        }

        # The other side of the same gate: a 5xx says nothing about the request,
        # so the cached reading is still the best answer available.
        It 'still serves a fresh cache after a 5xx' {
            $slot = New-TimeoutSlot 'overloaded529'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 21.0; resets_at = $null } }
                Timestamp = [DateTime]::UtcNow
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw (New-CodedWebException -StatusCode 529)
            }

            $r = Get-SlotUsage -SlotPath $slot

            $r.Status                     | Should -Be 'ok'
            $r.IsCachedFallback           | Should -BeTrue
            $r.Data.five_hour.utilization | Should -Be 21.0
            # The reason survives onto the fresh row so the advisory can say
            # why the numbers are not live.
            $r.Error                      | Should -Match '529'
            $r.HttpStatus                 | Should -Be 529
        }

        # A timeout is not a throttle. Stamping RateLimitedUntil would make the
        # next poll short-circuit to 'rate-limited' for RateLimitBackoffSec and
        # stop probing live for a fault that may already be gone.
        It 'does NOT stamp a rate-limit backoff' {
            $slot = New-TimeoutSlot 'nobackoff'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 10.0; resets_at = $null } }
                Timestamp = [DateTime]::UtcNow
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Threading.Tasks.TaskCanceledException]::new($script:TimeoutMessage)
            }

            Get-SlotUsage -SlotPath $slot | Out-Null
            $Script:SlotUsageCache[$slot].RateLimitedUntil | Should -BeNullOrEmpty
        }

        It 'carries HttpStatus through the stale fallback for a coded 5xx' {
            $slot = New-TimeoutSlot 'net529'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 33.0; resets_at = $null } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 529 }
                $inner = [System.Exception]::new('Response status code does not indicate success: 529.')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status     | Should -Be 'error'
            $r.HttpStatus | Should -Be 529
            $r.Data.five_hour.utilization | Should -Be 33.0
        }
    }

    Context 'Get-SlotUsage (rate-limit backoff)' {
        # After a 429, RateLimitedUntil is stamped on the cache entry so the
        # NEXT poll short-circuits to cache without any token/usage HTTP --
        # the loop stops re-tripping a hot limiter every poll. A successful
        # read clears the stamp; Clear-SlotRateLimitBackoff drops it for the
        # warmup verify read.
        BeforeEach {
            $script:CredDirPath = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
            $script:boSlot = Join-Path $script:CredDirPath '.credentials.bo.json'
            $payload = @{ claudeAiOauth = @{ accessToken='AT'; refreshToken='RT'; expiresAt=$script:FutureMs } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:boSlot -Value $payload -NoNewline
            Mock Start-Sleep -MockWith { }
        }

        It 'stamps RateLimitedUntil on the existing cache entry after a usage 429' {
            $Script:SlotUsageCache[$script:boSlot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 1.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))   # stale
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp = [pscustomobject]@{ StatusCode = 429 }; $e = [System.Exception]::new('429'); $e | Add-Member -NotePropertyName Response -NotePropertyValue $resp; throw $e
            }

            Get-SlotUsage -SlotPath $script:boSlot | Out-Null

            $Script:SlotUsageCache[$script:boSlot].RateLimitedUntil | Should -BeGreaterThan ([DateTime]::UtcNow)
        }

        It 'short-circuits to cache with ZERO HTTP while inside the backoff window' {
            $script:rmCount = 0
            Mock Invoke-RestMethod -MockWith { $script:rmCount++; throw 'HTTP must not be called during backoff' }
            $Script:SlotUsageCache[$script:boSlot] = @{
                Data             = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 7.0 } }
                Timestamp        = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(120)
            }

            $r = Get-SlotUsage -SlotPath $script:boSlot

            $r.Status                     | Should -Be 'rate-limited'
            $r.IsCachedFallback           | Should -BeTrue
            $r.Data.five_hour.utilization | Should -Be 7
            $script:rmCount               | Should -Be 0
        }

        It 'a successful read clears any backoff stamp' {
            $Script:SlotUsageCache[$script:boSlot] = @{
                Data             = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 1.0 } }
                Timestamp        = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(-1)   # expired: no short-circuit
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 9.0; resets_at = $null } }
            }

            $r = Get-SlotUsage -SlotPath $script:boSlot

            $r.Status | Should -Be 'ok'
            $Script:SlotUsageCache[$script:boSlot].ContainsKey('RateLimitedUntil') | Should -BeFalse
        }

        It 'Clear-SlotRateLimitBackoff drops the stamp but keeps cached Data' {
            $Script:SlotUsageCache[$script:boSlot] = @{
                Data = 'D'; Timestamp = [DateTime]::UtcNow; RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(120)
            }
            Clear-SlotRateLimitBackoff -SlotPath $script:boSlot
            $Script:SlotUsageCache[$script:boSlot].ContainsKey('RateLimitedUntil') | Should -BeFalse
            $Script:SlotUsageCache[$script:boSlot].Data                            | Should -Be 'D'
        }

        It 'Set-SlotRateLimitBackoff creates a throttle-only entry when the slot has none' {
            # The slots that most need the backoff are the ones that never read
            # successfully, because they were throttled from the first poll.
            # Stamping only pre-existing entries excluded exactly those, so each
            # poll re-ran the three-attempt refresh ladder against an endpoint
            # already refusing.
            Set-SlotRateLimitBackoff -SlotPath $script:boSlot

            $Script:SlotUsageCache.ContainsKey($script:boSlot)     | Should -BeTrue
            $Script:SlotUsageCache[$script:boSlot].Data            | Should -BeNullOrEmpty
            $Script:SlotUsageCache[$script:boSlot].RateLimitedUntil | Should -BeGreaterThan ([DateTime]::UtcNow)
        }

        It 'short-circuits with ZERO HTTP on a throttle-only entry, claiming no cached numbers' {
            # The em-dash row must not also claim "showing last known usage":
            # IsCachedFallback is what routes it to that advisory.
            $script:rmCount2 = 0
            Mock Invoke-RestMethod -MockWith { $script:rmCount2++; throw 'HTTP must not be called during backoff' }
            $Script:SlotUsageCache[$script:boSlot] = @{
                Data             = $null
                Timestamp        = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(120)
            }

            $r = Get-SlotUsage -SlotPath $script:boSlot

            $r.Status           | Should -Be 'rate-limited'
            $r.Data             | Should -BeNullOrEmpty
            $r.IsCachedFallback | Should -BeFalse
            $script:rmCount2    | Should -Be 0
        }

        It 'a token-endpoint 429 on an uncached slot silences the NEXT poll entirely' {
            # End to end for the defect: first poll burns the refresh ladder,
            # second poll must make no request at all.
            $expired = [DateTimeOffset]::UtcNow.AddHours(-2).ToUnixTimeMilliseconds()
            $payload = @{ claudeAiOauth = @{ accessToken='AT'; refreshToken='RT'; expiresAt=$expired } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:boSlot -Value $payload -NoNewline
            $Script:SlotUsageCache.Remove($script:boSlot)

            $script:tokCount = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:tokCount++
                $resp = [pscustomobject]@{ StatusCode = 429 }
                $e = [System.Exception]::new('429'); $e | Add-Member -NotePropertyName Response -NotePropertyValue $resp; throw $e
            }

            $first = Get-SlotUsage -SlotPath $script:boSlot
            $after = $script:tokCount
            $second = Get-SlotUsage -SlotPath $script:boSlot

            $first.Status  | Should -Be 'rate-limited'
            $second.Status | Should -Be 'rate-limited'
            $after         | Should -BeGreaterThan 0
            # The whole point: the second poll adds no traffic.
            $script:tokCount | Should -Be $after
        }
    }

    Context 'Get-SlotUsage (generic HTTP error surfaces the status code)' {
        # A non-401/403/429 HTTP failure (e.g. 529 Overloaded, 5xx) must
        # surface Status='error' WITH the numeric HttpStatus so the table
        # can render a short 'error <code>' label instead of the verbose
        # .NET 'Response status code does not indicate success' message.
        BeforeEach {
            $script:CredDirPath = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
        }

        It 'returns Status=error and HttpStatus=529 on an HTTP 529 from the usage endpoint' {
            $slot = Join-Path $script:CredDirPath '.credentials.overloaded.json'
            $payload = @{ claudeAiOauth = @{
                accessToken = 'AT'; refreshToken = 'RT'; expiresAt = $script:FutureMs
            } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 529 }
                $inner = [System.Exception]::new('Response status code does not indicate success: 529 (<none>).')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status     | Should -Be 'error'
            $r.HttpStatus | Should -Be 529
            $r.Error      | Should -Not -BeNullOrEmpty
        }

        It 'leaves HttpStatus null for a codeless network/timeout error' {
            $slot = Join-Path $script:CredDirPath '.credentials.timeout.json'
            $payload = @{ claudeAiOauth = @{
                accessToken = 'AT'; refreshToken = 'RT'; expiresAt = $script:FutureMs
            } } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            # No Response member -> $status stays $null in the catch.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Net.WebException]::new('The operation has timed out.')
            }

            $r = Get-SlotUsage -SlotPath $slot
            $r.Status     | Should -Be 'error'
            $r.HttpStatus | Should -BeNullOrEmpty
            $r.Error      | Should -Match 'timed out'
        }
    }

    Context 'Format-UsageTable (error-status label)' {
        # The 'error' arm appends the numeric HttpStatus when the row carries
        # one and renders the bare label otherwise. No arm renders the
        # exception message: the Status cell is the last column and its width
        # also sizes the aggregate bars, so one long cell wraps both.
        It 'renders "error <code>" when the row carries an HttpStatus' {
            $row = [pscustomobject]@{
                Name       = 'slot-1'
                IsActive   = $false
                Status     = 'error'
                HttpStatus = 529
                Error      = 'Response status code does not indicate success: 529 (<none>).'
                Data       = $null
                Email      = $null
            }
            $out = Format-UsageTable -Results @($row) 6>&1 | Out-String
            $out | Should -Match 'error 529'
            # The verbose .NET sentence must not leak into the cell.
            $out | Should -Not -Match 'does not indicate success'
        }

        It 'falls back to the bare "error" label when the row has no HttpStatus' {
            $row = [pscustomobject]@{
                Name     = 'slot-1'
                IsActive = $false
                Status   = 'error'
                Error    = 'The operation has timed out.'
                Data     = $null
                Email    = $null
            }
            $out = Format-UsageTable -Results @($row) 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+slot-1\b.*\berror\s*$'
            $out | Should -Not -Match 'timed out'
        }

        # Every hard-failure label is a short fixed string. The parenthetical
        # remedies these used to carry ('no-oauth (api key or non-claude.ai
        # slot)' and friends) moved to Format-UsageAdvisory's reason lines.
        It 'renders hard-failure statuses as bare labels' -ForEach @(
            @{ Status = 'no-oauth';     Hint = 'api key' }
            @{ Status = 'expired';      Hint = 'sca switch' }
            @{ Status = 'unauthorized'; Hint = 'revoked'    }
        ) {
            $row = [pscustomobject]@{
                Name     = 'slot-1'
                IsActive = $false
                Status   = $Status
                Data     = $null
                Error    = $null
                Email    = $null
            }
            $out = Format-UsageTable -Results @($row) 6>&1 | Out-String
            $out | Should -Match "(?m)^\s+slot-1\b.*\b$([regex]::Escape($Status))\s*`$"
            $out | Should -Not -Match ([regex]::Escape($Hint))
        }
    }

    Context 'Get-CachedUsageOrNull' {
        # Direct unit tests for the per-process usage cache helper.
        # $Script:SlotUsageCache is re-initialized to @{} in each
        # BeforeEach via the dot-source in Common.ps1.

        It 'returns $null on cache miss' {
            (Get-CachedUsageOrNull -SlotPath 'missing/path.json') | Should -BeNullOrEmpty
        }

        It 'refuses a throttle-only entry rather than reporting ok with no Data' {
            # Set-SlotRateLimitBackoff creates these for slots that never read
            # successfully. Serving one would return Status='ok' with Data=$null,
            # which Get-RowMaxUtilization scores 0% and auto-rotation then reads
            # as a healthy idle slot: a throttled slot promoted to active
            # precisely because nothing could be read from it.
            $slot = 'D:/throttle-only/path.json'
            $Script:SlotUsageCache[$slot] = @{
                Data             = $null
                Timestamp        = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(120)
            }
            (Get-CachedUsageOrNull -SlotPath $slot)            | Should -BeNullOrEmpty
            (Get-CachedUsageOrNull -SlotPath $slot -AllowStale) | Should -BeNullOrEmpty
        }

        It 'returns $null on stale entries (older than UsageCacheTTL minutes)' {
            $slot = 'D:/some/path.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 9.0 } }
                # Force a timestamp far enough in the past to exceed TTL.
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }
            (Get-CachedUsageOrNull -SlotPath $slot) | Should -BeNullOrEmpty
        }

        It 'returns the cached data wrapped in an ok+fallback shape when fresh' {
            $slot = 'D:/fresh/path.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 17.0 } }
                Timestamp = [DateTime]::UtcNow
            }
            $r = Get-CachedUsageOrNull -SlotPath $slot
            $r                         | Should -Not -BeNullOrEmpty
            $r.Status                  | Should -Be 'ok'
            $r.IsCachedFallback        | Should -BeTrue
            $r.Data.five_hour.utilization | Should -Be 17
        }

        It '-AllowStale serves a stale entry as rate-limited+fallback (last-known numbers kept)' {
            $slot = 'D:/stale/path.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 88.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }
            # Without -AllowStale: still $null (default freshness policy).
            (Get-CachedUsageOrNull -SlotPath $slot) | Should -BeNullOrEmpty
            # With -AllowStale: data is served, but status stays rate-limited
            # so a stale reading is never mistaken for live data.
            $r = Get-CachedUsageOrNull -SlotPath $slot -AllowStale
            $r                            | Should -Not -BeNullOrEmpty
            $r.Status                     | Should -Be 'rate-limited'
            $r.IsCachedFallback           | Should -BeTrue
            $r.Data.five_hour.utilization | Should -Be 88
        }

        # -AllowStale exists so a row survives a BRIEF outage with its numbers
        # intact. Without a ceiling that argument kept applying at any age, and
        # the cost was not cosmetic: Get-AutoRotationDecision only reports
        # 'active-unknown' for an active row with NO Data, so an unbounded
        # entry left a permanently unreadable active slot being judged on a
        # days-old reading while the monitor reported itself armed.
        It '-AllowStale refuses an entry past UsageCacheMaxAgeMin' {
            $slot = 'D:/ancient/path.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 88.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheMaxAgeMin + 1))
            }
            (Get-CachedUsageOrNull -SlotPath $slot -AllowStale) | Should -BeNullOrEmpty
        }

        It '-AllowStale still serves an entry just inside the ceiling' {
            $slot = 'D:/elderly/path.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 88.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheMaxAgeMin - 1))
            }
            (Get-CachedUsageOrNull -SlotPath $slot -AllowStale).Data.five_hour.utilization | Should -Be 88
        }

        It 'an ancient entry leaves the active row reporting active-unknown' {
            # The end-to-end consequence of the ceiling: with no Data the
            # rotation engine says so instead of judging on an obsolete number.
            $row = [pscustomobject]@{ Name = 'a'; IsActive = $true; Status = 'error'; Data = $null }
            $decision = Get-AutoRotationDecision -Threshold 95 `
                -Snapshot ([pscustomobject]@{ Results = @($row); NoSlots = $false })
            $decision.Action       | Should -Be 'active-unknown'
            $decision.ActiveStatus | Should -Be 'error'
        }

        It '-AllowStale still returns $null on a true cache miss' {
            (Get-CachedUsageOrNull -SlotPath 'missing/path.json' -AllowStale) | Should -BeNullOrEmpty
        }

        It 'stamps FallbackReason on a fresh hit, defaulting to rate-limit' {
            $slot = 'reason/fresh.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 5.0 } }
                Timestamp = [DateTime]::UtcNow
            }
            (Get-CachedUsageOrNull -SlotPath $slot).FallbackReason                    | Should -Be 'rate-limit'
            (Get-CachedUsageOrNull -SlotPath $slot -Reason 'network').FallbackReason   | Should -Be 'network'
            # Freshness beats reason: a recent reading is served as live-quality.
            (Get-CachedUsageOrNull -SlotPath $slot -Reason 'network').Status           | Should -Be 'ok'
        }

        It '-Reason picks the stale status label' {
            $slot = 'reason/stale.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 5.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }
            (Get-CachedUsageOrNull -SlotPath $slot -AllowStale).Status                     | Should -Be 'rate-limited'
            (Get-CachedUsageOrNull -SlotPath $slot -AllowStale -Reason 'network').Status   | Should -Be 'error'
        }

        It 'stamps ErrorMessage / HttpStatus on both the stale and the fresh result' {
            $slot = 'reason/stamp.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 5.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }
            $r = Get-CachedUsageOrNull -SlotPath $slot -AllowStale -Reason 'network' -ErrorMessage 'boom' -HttpStatus 503
            $r.Error      | Should -Be 'boom'
            $r.HttpStatus | Should -Be 503

            # A fresh row keeps its live-quality 'ok', but the reason the live
            # read failed survives: without it, the commonest transient failure
            # of all (a cache under the TTL) produced "showing last known
            # usage" with nothing anywhere saying why.
            $Script:SlotUsageCache[$slot].Timestamp = [DateTime]::UtcNow
            $fresh = Get-CachedUsageOrNull -SlotPath $slot -Reason 'network' -ErrorMessage 'boom' -HttpStatus 503
            $fresh.Status     | Should -Be 'ok'
            $fresh.Error      | Should -Be 'boom'
            $fresh.HttpStatus | Should -Be 503
        }

        It 'rejects an unknown -Reason at bind time' {
            { Get-CachedUsageOrNull -SlotPath 'x' -Reason 'nonsense' } | Should -Throw
        }
    }

    Context 'Resolve-UsageFailureFallback' {
        # The shared ladder both catch arms of Get-SlotUsage run before
        # deciding whether to retry.
        It 'returns $null when nothing is cached, so the caller retries' {
            Resolve-UsageFailureFallback -SlotPath 'ladder/miss.json' -Reason 'network' |
                Should -BeNullOrEmpty
        }

        It 'prefers a fresh entry over the stale path' {
            $slot = 'ladder/fresh.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 12.0 } }
                Timestamp = [DateTime]::UtcNow
            }
            $r = Resolve-UsageFailureFallback -SlotPath $slot -Reason 'network' -ErrorMessage 'boom'
            $r.Status | Should -Be 'ok'
            # 'ok' for every consumer that gates on Status, but the reason
            # rides along for the advisory and the -Json row.
            $r.Error  | Should -Be 'boom'
        }

        It 'falls through to the stale entry, carrying the reason and message' {
            $slot = 'ladder/stale.json'
            $Script:SlotUsageCache[$slot] = @{
                Data      = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 12.0 } }
                Timestamp = [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            }
            $r = Resolve-UsageFailureFallback -SlotPath $slot -Reason 'network' -ErrorMessage 'boom' -HttpStatus 500
            $r.Status                     | Should -Be 'error'
            $r.FallbackReason             | Should -Be 'network'
            $r.Error                      | Should -Be 'boom'
            $r.HttpStatus                 | Should -Be 500
            $r.Data.five_hour.utilization | Should -Be 12.0
        }
    }

    Context 'Test-IsRetriableUsageFailure' {
        # The retry doubles a slot's contribution to a poll's wall clock and
        # Get-UsageSnapshot walks slots serially, so each failure class has to
        # earn the second attempt.

        It 'refuses a timeout by exception type, not by message text' {
            # -TimeoutSec surfaces as TaskCanceledException : OperationCanceledException.
            # Type-based so the check survives a localized message.
            $ex = [System.Threading.Tasks.TaskCanceledException]::new('any wording at all')
            Test-IsRetriableUsageFailure -Exception $ex -HttpStatus $null | Should -BeFalse
            # A timeout still has no status even when one is somehow present.
            Test-IsRetriableUsageFailure -Exception $ex -HttpStatus 503   | Should -BeFalse
        }

        It 'accepts a codeless transport failure' {
            # DNS / socket errors fail fast, so a second attempt is cheap and
            # does clear transient blips.
            $ex = [System.Net.Http.HttpRequestException]::new('No such host is known.')
            Test-IsRetriableUsageFailure -Exception $ex -HttpStatus $null | Should -BeTrue
        }

        It 'accepts a 5xx: <Case>' -ForEach @(
            @{ Case = '500'; Status = 500 }
            @{ Case = '529 Overloaded'; Status = 529 }
            @{ Case = '503'; Status = 503 }
        ) {
            $ex = [System.Exception]::new('server side')
            Test-IsRetriableUsageFailure -Exception $ex -HttpStatus $Status | Should -BeTrue
        }

        It 'refuses a 4xx the server will reject identically: <Case>' -ForEach @(
            @{ Case = '400'; Status = 400 }
            @{ Case = '404'; Status = 404 }
            @{ Case = '422'; Status = 422 }
        ) {
            $ex = [System.Exception]::new('request side')
            Test-IsRetriableUsageFailure -Exception $ex -HttpStatus $Status | Should -BeFalse
        }
    }

    Context 'Test-IsTransportFailure' {
        # Shared by the usage-endpoint retry gate and the token-endpoint cache
        # gate, so "the server rejected this request" has one definition.
        It 'treats a codeless HTTP failure as transport' {
            $ex = [System.Net.Http.HttpRequestException]::new('No such host is known.')
            Test-IsTransportFailure -HttpStatus $null -Exception $ex | Should -BeTrue
        }

        It 'treats a timeout cancellation as transport' {
            $ex = [System.Threading.Tasks.TaskCanceledException]::new('timeout')
            Test-IsTransportFailure -HttpStatus $null -Exception $ex | Should -BeTrue
        }

        # The missing status is what made this necessary: Update-SlotTokens
        # throws plain PowerShell errors for a refresh response missing
        # access_token / expires_in and for a failed credential write, and none
        # of them carry one. Read as transport, those served a dead slot from
        # cache under a healthy 'ok'; the write failure is the worst of the
        # three, because the server has already rotated the refresh token away.
        It 'treats a non-HTTP exception with no status as a hard failure' {
            $ex = [System.Management.Automation.RuntimeException]::new('OAuth refresh succeeded but response missing access_token.')
            Test-IsTransportFailure -HttpStatus $null -Exception $ex | Should -BeFalse
        }

        It 'treats an IO failure with no status as a hard failure' {
            $ex = [System.IO.IOException]::new('The process cannot access the file.')
            Test-IsTransportFailure -HttpStatus $null -Exception $ex | Should -BeFalse
        }

        It 'treats a 5xx as transport whatever the exception type: <Case>' -ForEach @(
            @{ Case = '500'; Status = 500 }
            @{ Case = '529'; Status = 529 }
        ) {
            $ex = [System.Exception]::new('server side')
            Test-IsTransportFailure -HttpStatus $Status -Exception $ex | Should -BeTrue
        }

        It 'treats a 4xx as a rejection, not transport: <Case>' -ForEach @(
            @{ Case = '400'; Status = 400 }
            @{ Case = '401'; Status = 401 }
            @{ Case = '429'; Status = 429 }
        ) {
            $ex = [System.Net.Http.HttpRequestException]::new('request side')
            Test-IsTransportFailure -HttpStatus $Status -Exception $ex | Should -BeFalse
        }
    }

    Context 'Get-SlotUsage token-refresh failure fallback' {
        # The token POST carries the largest budget of the three calls
        # ($Script:TokenTimeoutSec), so a transport blip is likeliest to land
        # there. Without the cache ladder one slow hourly refresh wiped the row
        # to em-dashes, printed the 'run sca switch' remedy for something
        # sca switch cannot fix, and turned the monitor's active row into
        # 'active-unknown', pausing rotation.

        BeforeEach {
            $script:TokSlot = Join-Path $script:SandboxHome '.claude/.credentials.tok(t@x.io).json'
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:TokSlot) -Force | Out-Null

            # An already-expired access token forces the refresh path.
            $expired = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
            Set-Content -LiteralPath $script:TokSlot -NoNewline -Encoding utf8NoBOM -Value (
                [pscustomobject]@{
                    claudeAiOauth = [pscustomobject]@{
                        accessToken = 'stale'; refreshToken = 'r'; expiresAt = $expired
                    }
                } | ConvertTo-Json -Depth 5)

            $Script:SlotUsageCache[$script:TokSlot] = @{
                Data      = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 42.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 7.0;  resets_at = $null }
                }
                Timestamp = [DateTime]::UtcNow
            }
        }

        It 'serves cached percentages when the refresh dies in transport' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Net.Http.HttpRequestException]::new('No such host is known.')
            }

            $r = Get-SlotUsage -SlotPath $script:TokSlot 6>$null

            $r.Status                     | Should -Be 'ok'
            $r.IsCachedFallback           | Should -BeTrue
            $r.Data.five_hour.utilization | Should -Be 42.0
        }

        It 'keeps the last-known percentages on a stale entry, labelled non-ok' {
            $Script:SlotUsageCache[$script:TokSlot].Timestamp =
                [DateTime]::UtcNow.AddMinutes(-($Script:UsageCacheTTL + 5))
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Net.Http.HttpRequestException]::new('connection reset')
            }

            $r = Get-SlotUsage -SlotPath $script:TokSlot 6>$null

            $r.Status                     | Should -Be 'error'
            $r.FallbackReason             | Should -Be 'network'
            $r.Data.five_hour.utilization | Should -Be 42.0
        }

        It 'still reports expired when the grant itself is rejected' {
            # invalid_grant means the refresh token is dead for good. Serving a
            # fresh cache as 'ok' would hide a slot that needs re-authentication.
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $resp = [pscustomobject]@{ StatusCode = 400 }
                $ex   = [System.Exception]::new('invalid_grant')
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp -PassThru | Out-Null
                throw $ex
            }

            $r = Get-SlotUsage -SlotPath $script:TokSlot 6>$null

            $r.Status           | Should -Be 'expired'
            $r.IsCachedFallback | Should -BeFalse
            $r.Data             | Should -BeNullOrEmpty
        }

        # Update-SlotTokens also throws for a refresh response it cannot use and
        # for a slot-file write that fails after the server rotated the token.
        # Neither carries an HTTP status, and both used to be read as a
        # transport blip and served from a fresh cache as a healthy 'ok'.
        It 'reports expired when the refresh response is unusable: <Case>' -ForEach @(
            @{ Case = 'no access_token'; Body = @{ expires_in = 3600 } }
            @{ Case = 'no expires_in';   Body = @{ access_token = 'AT' } }
        ) {
            $payload = $Body
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]$payload
            }

            $r = Get-SlotUsage -SlotPath $script:TokSlot 6>$null

            $r.Status           | Should -Be 'expired'
            $r.IsCachedFallback | Should -BeFalse
            $r.Data             | Should -BeNullOrEmpty
        }

        It 'reports expired when the rotated tokens cannot be written back to the slot' {
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{ access_token = 'AT'; refresh_token = 'RT'; expires_in = 3600 }
            }
            Mock Set-CredentialFileAtomic -MockWith { throw 'disk full' }

            $r = Get-SlotUsage -SlotPath $script:TokSlot 6>$null

            # The refresh token the server rotated to is gone, so this slot is
            # dead until the user re-authenticates. Reporting 'ok' off the cache
            # would also keep it a valid auto-rotation destination.
            $r.Status           | Should -Be 'expired'
            $r.IsCachedFallback | Should -BeFalse
            $r.Data             | Should -BeNullOrEmpty
        }
    }

    Context 'Invoke-UsageAction email rendering' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = ([DateTimeOffset]::UtcNow.AddHours(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture)) }
                    seven_day = [pscustomobject]@{ utilization = 2.0; resets_at = ([DateTimeOffset]::UtcNow.AddHours(50).ToString('o', [Globalization.CultureInfo]::InvariantCulture)) }
                }
            }
        }

        # Email now lives in the slot filename; Get-Slots parses it via
        # Get-SlotFileInfo and propagates .Email into the row objects.
        # These tests stage the filenames directly rather than running
        # Invoke-SaveAction, so they isolate the display path. Each
        # also drops a sidecar so Get-Slots includes the row (post-v2.1.0
        # contract).
        BeforeAll {
            function New-TestSidecar {
                Param ([string] $SlotPath, [string] $Email)
                $sidecarPath = $SlotPath -replace '\.json$', '.account.json'
                $sidecar = [ordered]@{
                    schema       = 1
                    captured_at  = '2026-04-26T00:00:00.000Z'
                    source       = 'test'
                    oauthAccount = [ordered]@{
                        accountUuid      = 'test-acct-uuid'
                        emailAddress     = if ($Email) { $Email } else { 'test@test.local' }
                        organizationUuid = 'test-org-uuid'
                        displayName      = if ($Email) { $Email } else { 'Test' }
                        organizationName = 'test-org'
                    }
                }
                Set-Content -LiteralPath $sidecarPath -Value ($sidecar | ConvertTo-Json -Depth 5) -NoNewline -Encoding utf8NoBOM
            }
        }

        It 'renders the email in the Account column when the slot name differs from the labeled email' {
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-alias'
                    refreshToken     = 'sk-ant-ort-alias'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                    rateLimitTier    = 'default_claude_max_5x'
                }
            } | ConvertTo-Json -Compress
            # Labeled filename directly; no save-time fetch involved.
            $labeled = '.credentials.work(ada.lovelace@arpa.net).json'
            $slotPath = Join-Path $script:CredDirPath $labeled
            Set-Content -LiteralPath $slotPath -Value $payload -NoNewline -Encoding utf8NoBOM
            New-TestSidecar -SlotPath $slotPath -Email 'ada.lovelace@arpa.net'

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Single-line row: slot name + email on the same line (the
            # Account column is the second column now). No more '└─'
            # continuation line anywhere.
            $out | Should -Match '(?m)^\s+work\s+ada\.lovelace@arpa\.net\b'
            $out | Should -Not -Match '└─'
            # Zero profile HTTP calls on the display path; email is from
            # the filename, not the endpoint.
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It 'renders "-" in the Account column when the slot name equals the embedded email' {
            # Slot name equals email -> save would have chosen the
            # unlabeled form. Stage that directly.
            $email = 'alice@example.com'
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-alice'
                    refreshToken     = 'sk-ant-ort-alice'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            $slotPath = Join-Path $script:CredDirPath ".credentials.$email.json"
            Set-Content -LiteralPath $slotPath -Value $payload -NoNewline -Encoding utf8NoBOM
            New-TestSidecar -SlotPath $slotPath -Email $email

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Slot name present, email NOT repeated in the Account cell
            # (dedup form). Account cell renders as the em-dash sentinel.
            $out | Should -Match "(?m)^\s+$([regex]::Escape($email))\s+—\s"
            $out | Should -Not -Match '└─'
        }

        It 'unlabeled slot (save-time profile fetch failed) renders "-" in the Account column' {
            # .credentials.pending.json (no parens suffix) -> email unknown.
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-pending'
                    refreshToken     = 'sk-ant-ort-pending'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            $slotPath = Join-Path $script:CredDirPath '.credentials.pending.json'
            Set-Content -LiteralPath $slotPath -Value $payload -NoNewline -Encoding utf8NoBOM
            # Sidecar must still have an emailAddress so Read-Sidecar
            # validates it (sidecar contract: emailAddress required).
            # The slot's filename-derived email stays $null though.
            New-TestSidecar -SlotPath $slotPath -Email 'pending@test.local'

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+pending\s+—\s'
            $out | Should -Not -Match '└─'
        }

        It 'middle-truncates long emails in the Account column (full email kept in -Json)' {
            # Craft an email longer than $Script:AccountColumnMaxWidth (32)
            # so the truncation path fires.
            $longEmail = 'extremely.long.local.part@extraordinarily-long-domain.example.com'
            $longEmail.Length | Should -BeGreaterThan $Script:AccountColumnMaxWidth

            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-long'
                    refreshToken     = 'sk-ant-ort-long'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            $labeled = ".credentials.longslot($longEmail).json"
            $slotPath = Join-Path $script:CredDirPath $labeled
            Set-Content -LiteralPath $slotPath -Value $payload -NoNewline -Encoding utf8NoBOM
            New-TestSidecar -SlotPath $slotPath -Email $longEmail

            $out = Invoke-UsageAction 6>&1 | Out-String

            # The rendered Account cell carries the ellipsis (U+2026) and
            # is no wider than AccountColumnMaxWidth. The untruncated
            # string is too long to appear verbatim.
            $out | Should -Match '…'
            $out | Should -Not -Match ([regex]::Escape($longEmail))

            # -Json must still carry the full untruncated email under
            # account.email for scripting consumers.
            $raw    = Invoke-UsageAction -Json
            $parsed = $raw | ConvertFrom-Json
            $parsed.longslot.account.email | Should -Be $longEmail
        }
    }

    Context 'anthropic-version header propagation' {
        # Defense-in-depth: assert that every authenticated request adds
        # the anthropic-version header so a future tightening at any
        # endpoint does not silently break the script. Mirrors the
        # constants-block decision documented in $Script:AnthropicApi-
        # Version's docstring.

        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
            $script:PastMs   = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
        }

        It 'Get-SlotUsage sends anthropic-version on /api/oauth/usage' {
            $payload = @{
                claudeAiOauth = @{ accessToken = 'sk-fresh'; refreshToken = 'rt-fresh'; expiresAt = $script:FutureMs }
            } | ConvertTo-Json -Depth 10 -Compress
            $path = Join-Path $script:CredDirPath '.credentials.usage-ver(u@test.local).json'
            Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM

            $script:capturedHeaders = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $script:capturedHeaders = $Headers
                return [pscustomobject]@{}
            }

            Get-SlotUsage -SlotPath $path | Out-Null

            $script:capturedHeaders['anthropic-version'] | Should -Be $Script:AnthropicApiVersion
        }

        It 'Get-SlotProfile sends anthropic-version on /api/oauth/profile' {
            $payload = @{
                claudeAiOauth = @{ accessToken = 'sk-fresh'; refreshToken = 'rt-fresh'; expiresAt = $script:FutureMs }
            } | ConvertTo-Json -Depth 10 -Compress
            $path = Join-Path $script:CredDirPath '.credentials.profile-ver(p@test.local).json'
            Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM

            $script:capturedHeaders = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                $script:capturedHeaders = $Headers
                return [pscustomobject]@{ account = [pscustomobject]@{ email = 'p@test.local' } }
            }

            Get-SlotProfile -SlotPath $path | Out-Null

            $script:capturedHeaders['anthropic-version'] | Should -Be $Script:AnthropicApiVersion
        }

        It 'Update-SlotTokens sends anthropic-version on /v1/oauth/token' {
            $payload = @{
                claudeAiOauth = @{ accessToken = 'sk-OLD'; refreshToken = 'rt-OLD'; expiresAt = $script:PastMs }
            } | ConvertTo-Json -Depth 10 -Compress
            $path = Join-Path $script:CredDirPath '.credentials.token-ver(t@test.local).json'
            Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM

            $script:capturedHeaders = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:capturedHeaders = $Headers
                return [pscustomobject]@{ access_token = 'sk-NEW'; refresh_token = 'rt-NEW'; expires_in = 3600 }
            }

            Update-SlotTokens -SlotPath $path | Out-Null

            $script:capturedHeaders['anthropic-version'] | Should -Be $Script:AnthropicApiVersion
        }
    }

    Context "warmup status labels render correctly in the table" {
        # The synthetic snapshot built by Invoke-UsageWatch's `-Warmup`
        # startup carries Status='warming-up' on every row initially;
        # Invoke-WarmAllSlots mutates each row's Status as it processes
        # the slot. All warmup status labels must render with the
        # correct space-separated form in the Status column AND map to
        # the documented color via Get-StatusColor.

        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
        }

        It 'Format-UsageTable renders warming-up rows with "warming up" in the Status column' {
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Email 'alpha@test.local' | Out-Null
            New-SlotPair -CredDir $script:CredDirPath -Name 'bravo' -Email 'bravo@test.local' | Out-Null

            $synth = @(Get-Slots) | ForEach-Object {
                [pscustomobject]@{
                    Name     = $_.Name
                    Email    = $_.Email
                    Path     = $_.Path
                    IsActive = $_.IsActive
                    Status   = 'warming-up'
                    Data     = $null
                }
            }

            $out = Format-UsageTable -Results $synth 6>&1 | Out-String

            # Each row carries the rendered label 'warming up'. Two
            # occurrences (one per slot row), surrounded by the
            # column boundary so we don't accidentally match a stray
            # word elsewhere in the table.
            ([regex]::Matches($out, '\bwarming up\b')).Count | Should -Be 2
            # Session / Week cells render as the no-data sentinel because
            # synthetic rows carry Data = $null.
            $out | Should -Match '—'
        }

        It "Format-UsageTable renders 'priming' in the Status column" {
            # Slot name deliberately does NOT contain the label
            # substring so the regex matches the Status column only,
            # not the Account column.
            New-SlotPair -CredDir $script:CredDirPath -Name 'alpha' -Email 'alpha@test.local' | Out-Null

            $synth = @(Get-Slots) | ForEach-Object {
                [pscustomobject]@{
                    Name     = $_.Name
                    Email    = $_.Email
                    Path     = $_.Path
                    IsActive = $_.IsActive
                    Status   = 'priming'
                    Data     = $null
                }
            }

            $out = Format-UsageTable -Results $synth 6>&1 | Out-String

            ([regex]::Matches($out, '\bpriming\b')).Count | Should -Be 1
        }

        It 'Get-StatusColor maps "warming up" to Yellow' {
            Get-StatusColor -Label 'warming up' -IsActive $false | Should -Be 'Yellow'
            Get-StatusColor -Label 'warming up' -IsActive $true  | Should -Be 'Yellow'
        }

        It 'Get-StatusColor maps "priming" to Yellow' {
            # 'priming' is transient like 'warming up' -> Yellow.
            Get-StatusColor -Label 'priming' -IsActive $false | Should -Be 'Yellow'
            Get-StatusColor -Label 'priming' -IsActive $true  | Should -Be 'Yellow'
        }
    }

    Context 'Invoke-WarmAllSlots' {
        # The orchestrator behind `sca warmup` and `-Warmup` startup.
        # Builds its own snapshot from Get-Slots (filtered by -Name), then
        # for each slot in alphabetical order: marks Status='priming' ->
        # Invoke-SlotSwap makes it active -> Invoke-SlotActivator runs
        # `claude -p` as that slot to open its 5h server-side session
        # window -> on ok, Invoke-Reconcile mirrors then Get-SlotUsage
        # reads live data -> copies result onto the row. Returns the
        # populated snapshot; the caller hands it off to the polling loop
        # as its first frame. A finally block restores the original active
        # slot captured before the loop.

        BeforeAll {
            function New-WarmupSlot {
                Param (
                    [string] $Name,
                    [string] $Email = "$Name@test.local",
                    [Nullable[long]] $ExpiresAt = $null
                )
                if ($null -eq $ExpiresAt) { $ExpiresAt = $script:FutureMs }
                $payload = @{
                    claudeAiOauth = @{
                        accessToken  = "sk-ant-oat-$Name"
                        refreshToken = "sk-ant-ort-$Name"
                        expiresAt    = $ExpiresAt
                    }
                } | ConvertTo-Json -Depth 10 -Compress
                return New-SlotPair -CredDir $script:CredDirPath -Name $Name -Email $Email -Content $payload
            }

            # Look up a row's Status by slot name.
            function Get-RowStatus {
                Param ($Snapshot, [string] $Name)
                return ($Snapshot.Results | Where-Object { $_.Name -eq $Name }).Status
            }

        }

        BeforeEach {
            $script:CredDirPath = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()

            # Default Invoke-SlotSwap mock: no-op success. Tests that
            # assert on swap behavior (call order, restore, failure
            # mid-loop) override this mock locally.
            Mock Invoke-SlotSwap -MockWith { }

            # Default activator mock: a successful 'claude -p' activation.
            # Tests that exercise failure outcomes override this locally.
            # Mocking the activator means no real claude process is ever
            # spawned by the orchestration tests.
            Mock Invoke-SlotActivator -MockWith { [pscustomobject]@{ Status = 'ok' } }

            # The mirror step after an ok activation calls Invoke-Reconcile;
            # the orchestration does not care about its internals, so stub it.
            Mock Invoke-Reconcile -MockWith { New-ReconcileResult }

            # Default /api/oauth/usage mock for the verify-after-activation
            # read: an ok activation triggers a Get-SlotUsage call so the
            # warmup frame shows live percentages. Returns small valid
            # buckets; tests that assert specific usage outcomes override
            # this locally (a later mock with the same Uri filter wins).
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq $Script:UsageEndpoint } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 1.0; resets_at = $null }
                }
            }
        }

        It 'returns $null when no slots are saved' {
            $script:repaints = 0
            Mock Invoke-SlotActivator -MockWith { throw 'should not be called' }

            $result = Invoke-WarmAllSlots -Name '' -Repaint { $script:repaints++ }

            $result          | Should -BeNullOrEmpty
            $script:repaints | Should -Be 0
        }

        It '-Name filter returns $null when no slot matches' {
            New-WarmupSlot -Name 'alpha' | Out-Null
            Invoke-WarmAllSlots -Name 'missing' -Repaint { } | Should -BeNullOrEmpty
        }

        It '-Name filter passes through Get-SafeName sanitization (narrows to the sanitized slot name)' {
            # Get-SafeName replaces invalid Windows chars with _. The
            # filter should still resolve to the sanitized slot name.
            New-WarmupSlot -Name 'work_slot' -Email 'w@test.local' | Out-Null

            $snap = Invoke-WarmAllSlots -Name 'work?slot' -Repaint { }

            $snap                 | Should -Not -BeNullOrEmpty
            $snap.Results.Count   | Should -Be 1
            $snap.Results[0].Name | Should -Be 'work_slot'
        }

        It '-Names restricts the pass to the given subset of slots' {
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null
            New-WarmupSlot -Name 'c' | Out-Null

            $snap = Invoke-WarmAllSlots -Names @('a', 'c') -Repaint { }

            @($snap.Results).Count          | Should -Be 2
            @($snap.Results.Name | Sort-Object) | Should -Be @('a', 'c')
            Should -Invoke Invoke-SlotActivator -Times 2 -Exactly
        }

        It '-Names takes precedence over -Name when both are supplied' {
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null

            $snap = Invoke-WarmAllSlots -Name 'b' -Names @('a') -Repaint { }

            @($snap.Results).Count   | Should -Be 1
            $snap.Results[0].Name    | Should -Be 'a'
        }

        It '-Names returns $null when no saved slot matches the subset' {
            New-WarmupSlot -Name 'a' | Out-Null
            Invoke-WarmAllSlots -Names @('nonexistent') -Repaint { } | Should -BeNullOrEmpty
        }

        It 'ok activation then verify-after populates live bucket data' {
            New-WarmupSlot -Name 'a' -ExpiresAt $script:FutureMs | Out-Null
            New-WarmupSlot -Name 'b' -ExpiresAt $script:FutureMs | Out-Null

            # Activator ok comes from the BeforeEach default; /api/oauth/usage
            # is mocked in BeforeEach (the verify-after-activation read).
            $script:repaints = 0
            $snap = Invoke-WarmAllSlots -Name '' -Repaint { $script:repaints++ }

            (Get-RowStatus $snap 'a') | Should -Be 'ok'
            (Get-RowStatus $snap 'b') | Should -Be 'ok'
            # After an ok activation the verify-after usage read populates
            # the row with live bucket data, so the first frame shows real
            # percentages instead of 'ok (no plan data)'.
            ($snap.Results | Where-Object Name -eq 'a').Data.five_hour.utilization | Should -Be 5
            ($snap.Results | Where-Object Name -eq 'b').Data.seven_day.utilization | Should -Be 1
            # Repaints: 1 (initial 'warming-up' frame) + 2 per slot
            # ('priming' + terminal) = 1 + 4 = 5.
            $script:repaints | Should -Be 5
        }

        It 'slot enumeration is alphabetical' {
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null
            New-WarmupSlot -Name 'c' | Out-Null

            # Capture activation order from the slot path passed to the
            # activator (the leaf name embeds the slot name).
            $script:order = @()
            Mock Invoke-SlotActivator -MockWith {
                Param ($SlotPath)
                if ($SlotPath -match '\.credentials\.([^(]+)\(') { $script:order += $Matches[1] }
                return [pscustomobject]@{ Status = 'ok' }
            }

            Invoke-WarmAllSlots -Name '' -Repaint { } | Out-Null

            $script:order | Should -Be @('a','b','c')
        }

        It 'activator rate-limited: row ends Status="rate-limited", no usage read' {
            New-WarmupSlot -Name 'limited' | Out-Null
            Mock Invoke-SlotActivator -MockWith { [pscustomobject]@{ Status = 'rate-limited' } }

            $snap = Invoke-WarmAllSlots -Name '' -Repaint { }

            (Get-RowStatus $snap 'limited') | Should -Be 'rate-limited'
            # A failed activation skips the verify-after usage read: the
            # activator's own outcome is the signal, and a usage call would
            # not add information (and would risk an extra refresh).
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq $Script:UsageEndpoint }
        }

        It 'verify-after: an ok activation triggers exactly one usage read per slot' {
            New-WarmupSlot -Name 'a' | Out-Null

            $snap = Invoke-WarmAllSlots -Name '' -Repaint { }

            (Get-RowStatus $snap 'a') | Should -Be 'ok'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq $Script:UsageEndpoint }
        }

        It 'an ok activation mirrors tokens (Invoke-Reconcile) before the usage read' {
            New-WarmupSlot -Name 'a' | Out-Null

            $snap = Invoke-WarmAllSlots -Name '' -Repaint { }

            (Get-RowStatus $snap 'a') | Should -Be 'ok'
            # The mirror runs once per ok activation so the slot file picks
            # up the token claude refreshed.
            Should -Invoke Invoke-Reconcile -Times 1 -Exactly
        }

        It 'activator no-oauth: row ends Status="no-oauth", no mirror or usage read' {
            New-WarmupSlot -Name 'apikey' | Out-Null
            Mock Invoke-SlotActivator -MockWith { [pscustomobject]@{ Status = 'no-oauth' } }

            $snap = Invoke-WarmAllSlots -Name '' -Repaint { }

            (Get-RowStatus $snap 'apikey') | Should -Be 'no-oauth'
            Should -Invoke Invoke-Reconcile -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq $Script:UsageEndpoint }
        }

        It 'Invoke-SlotActivator throws: row ends Status="error" with the exception message' {
            New-WarmupSlot -Name 'crash' | Out-Null

            Mock Invoke-SlotActivator -MockWith {
                throw [System.Exception]::new('synthetic Invoke-SlotActivator failure')
            }

            $snap = Invoke-WarmAllSlots -Name '' -Repaint { }

            (Get-RowStatus $snap 'crash') | Should -Be 'error'
            ($snap.Results | Where-Object Name -eq 'crash').Error | Should -Match 'synthetic'
        }

        It 'mixed outcomes: some slots ok, others rate-limited - all surface their real outcomes' {
            New-WarmupSlot -Name 'good' | Out-Null
            New-WarmupSlot -Name 'limited' | Out-Null

            Mock Invoke-SlotActivator -MockWith {
                Param ($SlotPath)
                if ($SlotPath -match 'limited') { return [pscustomobject]@{ Status = 'rate-limited' } }
                return [pscustomobject]@{ Status = 'ok' }
            }

            $snap = Invoke-WarmAllSlots -Name '' -Repaint { }

            (Get-RowStatus $snap 'good')    | Should -Be 'ok'
            (Get-RowStatus $snap 'limited') | Should -Be 'rate-limited'
        }

        # Swap-then-activate round-robin contract.

        It 'calls Invoke-SlotSwap once per slot in alphabetical order before each activation' {
            $script:swapNames = @()
            Mock Invoke-SlotSwap -MockWith {
                Param ($Slot)
                $script:swapNames += $Slot.Name
            }

            New-WarmupSlot -Name 'c' | Out-Null
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null

            Invoke-WarmAllSlots -Name '' -Repaint { } | Out-Null

            # First three entries: alphabetical round-robin. No state file
            # means no restore call after the loop; restore behavior has
            # its own test below.
            $script:swapNames[0..2] | Should -Be @('a', 'b', 'c')
        }

        It 'restores the original active slot via one final Invoke-SlotSwap after the loop' {
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null
            $statePath = Join-Path $script:CredDirPath '.sca-state.json'
            $stateBody = @{ schema = 1; active_slot = 'a'; last_sync_hash = 'deadbeef' } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $statePath -Value $stateBody -NoNewline -Encoding utf8NoBOM

            $script:swapNames = @()
            Mock Invoke-SlotSwap -MockWith {
                Param ($Slot)
                $script:swapNames += $Slot.Name
            }

            Invoke-WarmAllSlots -Name '' -Repaint { } | Out-Null

            # Expected call order: a (round-robin), b (round-robin), a (restore).
            $script:swapNames | Should -Be @('a', 'b', 'a')
        }

        It 'skips the final restore swap when no original active slot is captured' {
            # No state file written: Read-ScaState returns $null,
            # $origActive stays $null, the finally block silently skips
            # the restore. User ends on the last-primed slot.
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null

            $script:swapCount = 0
            Mock Invoke-SlotSwap -MockWith { Param ($Slot); $script:swapCount++ }

            Invoke-WarmAllSlots -Name '' -Repaint { } | Out-Null

            # 2 swaps (one per slot, no restore). If the restore fired
            # the count would be 3.
            $script:swapCount | Should -Be 2
        }

        It 'mid-loop Invoke-SlotSwap failure marks the row Status="error", continues with remaining slots, and still runs the restore' {
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null
            New-WarmupSlot -Name 'c' | Out-Null
            $statePath = Join-Path $script:CredDirPath '.sca-state.json'
            $stateBody = @{ schema = 1; active_slot = 'a'; last_sync_hash = 'deadbeef' } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $statePath -Value $stateBody -NoNewline -Encoding utf8NoBOM

            $script:swapNames = @()
            Mock Invoke-SlotSwap -MockWith {
                Param ($Slot)
                $script:swapNames += $Slot.Name
                if ($Slot.Name -eq 'b') {
                    throw [System.Exception]::new('synthetic swap failure on b')
                }
            }

            $snap = $null
            { $script:snap = Invoke-WarmAllSlots -Name '' -Repaint { } } | Should -Not -Throw
            $snap = $script:snap

            (Get-RowStatus $snap 'a') | Should -Be 'ok'
            (Get-RowStatus $snap 'b') | Should -Be 'error'
            ($snap.Results | Where-Object Name -eq 'b').Error | Should -Match 'synthetic'
            (Get-RowStatus $snap 'c') | Should -Be 'ok'

            # Call order: a (round-robin), b (round-robin, throws),
            # c (round-robin), a (restore).
            $script:swapNames | Should -Be @('a', 'b', 'c', 'a')
        }

        It 'restore-failure advisory names the actual active slot, not rows[-1], on a double swap failure' {
            # Double failure: the LAST round-robin swap (c) throws, so the
            # loop ends active on b (the last successful swap), and the
            # restore swap to the original active slot (a) also throws,
            # firing the advisory. The advisory must name b, not c
            # (rows[-1]).
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null
            New-WarmupSlot -Name 'c' | Out-Null
            $statePath = Join-Path $script:CredDirPath '.sca-state.json'
            $stateBody = @{ schema = 1; active_slot = 'a'; last_sync_hash = 'deadbeef' } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $statePath -Value $stateBody -NoNewline -Encoding utf8NoBOM

            $script:swapNames = @()
            Mock Invoke-SlotSwap -MockWith {
                Param ($Slot)
                $script:swapNames += $Slot.Name
                # Last round-robin slot fails.
                if ($Slot.Name -eq 'c') {
                    throw [System.Exception]::new('synthetic swap failure on c')
                }
                # Second call for 'a' is the restore; let the first
                # (round-robin) succeed so the loop progresses past a.
                if ($Slot.Name -eq 'a' -and (@($script:swapNames | Where-Object { $_ -eq 'a' }).Count -ge 2)) {
                    throw [System.Exception]::new('synthetic restore failure on a')
                }
            }
            Mock Write-Color -MockWith { }

            Invoke-WarmAllSlots -Name '' -Repaint { } | Out-Null

            # Call order: a (round-robin), b (round-robin), c (throws),
            # a (restore, throws).
            $script:swapNames | Should -Be @('a', 'b', 'c', 'a')
            Should -Invoke Write-Color -Times 1 -Exactly -ParameterFilter { $Message -match "active on 'b'" }
            Should -Invoke Write-Color -Times 0 -Exactly -ParameterFilter { $Message -match "active on 'c'" }
        }

        It 'restore-failure advisory names the last primed slot when every round-robin swap succeeded' {
            # Common case: all loop swaps succeed; only the restore fails.
            # The user is left on the last primed slot (c), and the
            # advisory names it.
            New-WarmupSlot -Name 'a' | Out-Null
            New-WarmupSlot -Name 'b' | Out-Null
            New-WarmupSlot -Name 'c' | Out-Null
            $statePath = Join-Path $script:CredDirPath '.sca-state.json'
            $stateBody = @{ schema = 1; active_slot = 'a'; last_sync_hash = 'deadbeef' } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $statePath -Value $stateBody -NoNewline -Encoding utf8NoBOM

            $script:swapNames = @()
            Mock Invoke-SlotSwap -MockWith {
                Param ($Slot)
                $script:swapNames += $Slot.Name
                # Only the restore (second 'a' call) fails.
                if ($Slot.Name -eq 'a' -and (@($script:swapNames | Where-Object { $_ -eq 'a' }).Count -ge 2)) {
                    throw [System.Exception]::new('synthetic restore failure on a')
                }
            }
            Mock Write-Color -MockWith { }

            Invoke-WarmAllSlots -Name '' -Repaint { } | Out-Null

            $script:swapNames | Should -Be @('a', 'b', 'c', 'a')
            Should -Invoke Write-Color -Times 1 -Exactly -ParameterFilter { $Message -match "active on 'c'" }
        }
    }

    Context 'Test-WarmEligible' {
        # Pure predicate behind Invoke-KeepWarmStep's cold-slot selection.
        # -Threshold 95 matches `sca monitor`'s default; the rows below sit
        # well under it unless a test says otherwise.
        BeforeEach { $script:Now = [DateTimeOffset]::UtcNow }

        It 'rate-limited is eligible regardless of data (recovery path)' {
            $row = [pscustomobject]@{ Status = 'rate-limited'; Data = $null }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeTrue
        }

        It 'ok with a FUTURE five_hour reset is not eligible (window open)' {
            $row = [pscustomobject]@{ Status = 'ok'; Data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ resets_at = $script:Now.AddHours(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture) } } }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeFalse
        }

        It 'ok with a PAST five_hour reset is eligible (window closed)' {
            $row = [pscustomobject]@{ Status = 'ok'; Data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ resets_at = $script:Now.AddMinutes(-5).ToString('o', [Globalization.CultureInfo]::InvariantCulture) } } }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeTrue
        }

        It 'ok with a null five_hour reset is eligible' {
            $row = [pscustomobject]@{ Status = 'ok'; Data = [pscustomobject]@{ five_hour = [pscustomobject]@{ resets_at = $null } } }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeTrue
        }

        It 'ok with no Data is eligible' {
            $row = [pscustomobject]@{ Status = 'ok'; Data = $null }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeTrue
        }

        It 'hard-fail statuses are not eligible' -TestCases @(
            @{ S = 'expired' }, @{ S = 'unauthorized' }, @{ S = 'no-oauth' }, @{ S = 'error' }
        ) {
            Param ($S)
            $row = [pscustomobject]@{ Status = $S; Data = $null }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeFalse
        }

        # Warming opens the 5h window, so a slot whose window is already
        # open and full has nothing to gain from a billable `claude -p`. The
        # at-limit check runs first so it also gates the rate-limited branch,
        # which is where an exhausted slot usually surfaces.
        It 'a rate-limited slot at or above threshold is NOT eligible' {
            $row = [pscustomobject]@{ Status = 'rate-limited'; Data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = $script:Now.AddMinutes(12).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
                seven_day = $null } }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeFalse
        }

        It 'an ok slot with a closed 5h window but an exhausted 7d cap is NOT eligible' {
            $row = [pscustomobject]@{ Status = 'ok'; Data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 0.0;  resets_at = $null }
                seven_day = [pscustomobject]@{ utilization = 98.0; resets_at = $script:Now.AddDays(3).ToString('o', [Globalization.CultureInfo]::InvariantCulture) } } }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeFalse
        }

        # Built through New-UsageResult so the row is what production emits:
        # Select-LiveBuckets has already dropped the rolled 5h bucket, which is
        # what takes the slot back under the at-limit gate.
        It 'a rate-limited slot becomes eligible again once its window has reset' {
            $result = New-UsageResult -Status 'rate-limited' -CachedReason 'rate-limit' -Now $script:Now -Data ([pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = $script:Now.AddMinutes(-5).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
                seven_day = $null })
            $row = [pscustomobject]@{ Status = 'rate-limited'; Data = $result.Data }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeTrue
        }

        It 'honours a lowered threshold' {
            $row = [pscustomobject]@{ Status = 'rate-limited'; Data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 60.0; resets_at = $script:Now.AddMinutes(12).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
                seven_day = $null } }
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 95 | Should -BeTrue
            Test-WarmEligible -Row $row -Now $script:Now -Threshold 50 | Should -BeFalse
        }
    }

    Context 'Invoke-KeepWarmStep' {
        # The per-poll keep-warm step for `sca monitor -KeepWarm`. Mirrors
        # Invoke-AutoRotationStep: decides which slots have a CLOSED 5h
        # window, re-warms them via Invoke-WarmAllSlots (mocked here), and
        # returns a latched footer string. Cold = Status='ok' AND
        # five_hour bucket missing / resets_at null or past. Non-ok rows
        # are skipped; a per-slot cooldown ($WarmupTimes map) bounds retries.

        BeforeAll {
            # Build a snapshot row exposing only the fields the step reads:
            # Name, Status, Data.five_hour.resets_at.
            function New-KwRow {
                Param (
                    [string] $Name,
                    [string] $Status = 'ok',
                    $FiveResetsAt    = $null,
                    [switch] $NoFiveBucket,
                    [switch] $NoData
                )
                $data = $null
                if ($Status -eq 'ok' -and -not $NoData) {
                    $five = if ($NoFiveBucket) { $null } else {
                        [pscustomobject]@{ utilization = 0.0; resets_at = $FiveResetsAt }
                    }
                    $data = [pscustomobject]@{ five_hour = $five; seven_day = $null }
                }
                return [pscustomobject]@{
                    Name = $Name; Status = $Status; Data = $data
                    IsActive = $false; Error = $null; Email = "$Name@test.local"
                }
            }

            function New-KwSnapshot {
                Param ([object[]] $Rows)
                return [pscustomobject]@{
                    Results          = @($Rows)
                    NoSlots          = (@($Rows).Count -eq 0)
                }
            }

            $script:Future = [DateTimeOffset]::UtcNow.AddHours(3).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $script:Past   = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }

        BeforeEach {
            # Default: no real claude process; no real warm pass.
            Mock Test-ClaudeRunning { $false }
            Mock Invoke-WarmAllSlots { }
        }

        It 'returns the current latch and does NOT warm when every window is open' {
            $snap = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $script:Future) )
            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch '[Warmup] Keeping all slots warm.'

            $out | Should -Be '[Warmup] Keeping all slots warm.'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
        }

        It 'returns the current latch when the snapshot has no slots' {
            $out = Invoke-KeepWarmStep -Snapshot (New-KwSnapshot @()) -WarmupTimes @{} -Threshold 95 -CurrentLatch '[Warmup] Keeping all slots warm.'
            $out | Should -Be '[Warmup] Keeping all slots warm.'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
        }

        It 'returns the current latch when Results is empty but NoSlots is false' {
            $snap = [pscustomobject]@{ Results = @(); NoSlots = $false }
            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch '[Warmup] Keeping all slots warm.'
            $out | Should -Be '[Warmup] Keeping all slots warm.'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
        }

        It 're-warms a slot whose five_hour.resets_at is null' {
            $times = @{}
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 -CurrentLatch '[Warmup] Keeping all slots warm.'

            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly -ParameterFilter { @($Names) -contains 'a' -and @($Names).Count -eq 1 }
            $out | Should -Match "^\[Warmup\] Re-warmed 'a' at \d{2}:\d{2}:\d{2}$"
            $times.ContainsKey('a') | Should -BeTrue
        }

        It 're-warms a slot whose five_hour.resets_at is in the past' {
            $snap = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $script:Past) )
            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch 'x'
            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly
            $out | Should -Match "^\[Warmup\] Re-warmed 'a' at"
        }

        It 're-warms an ok row whose Data is null (no plan data)' {
            $snap = New-KwSnapshot @( (New-KwRow -Name 'a' -NoData) )
            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch 'x' | Out-Null
            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly -ParameterFilter { @($Names) -contains 'a' }
        }

        It 're-warms an ok row whose five_hour bucket is missing' {
            $snap = New-KwSnapshot @( (New-KwRow -Name 'a' -NoFiveBucket) )
            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch 'x' | Out-Null
            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly -ParameterFilter { @($Names) -contains 'a' }
        }

        It 'skips hard-fail rows (expired / unauthorized / no-oauth / error)' {
            # A `claude -p` cannot fix these and would burn a billable call.
            $snap = New-KwSnapshot @(
                (New-KwRow -Name 'a' -Status 'expired'),
                (New-KwRow -Name 'b' -Status 'unauthorized'),
                (New-KwRow -Name 'c' -Status 'no-oauth'),
                (New-KwRow -Name 'd' -Status 'error')
            )
            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch '[Warmup] Keeping all slots warm.'
            $out | Should -Be '[Warmup] Keeping all slots warm.'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
        }

        It 're-warms a rate-limited slot (recoverable via claude -p)' {
            # The recovery path out of the "frozen on rate-limited until
            # restart" state: a real `claude -p` refreshes tokens through
            # Claude Code's own OAuth flow and reopens the 5h window.
            $snap = New-KwSnapshot @( (New-KwRow -Name 'b' -Status 'rate-limited') )
            $out  = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch '[Warmup] Keeping all slots warm.'
            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly -ParameterFilter { @($Names) -contains 'b' -and @($Names).Count -eq 1 }
            $out | Should -Match "^\[Warmup\] Re-warmed 'b' at"
        }

        It 'reports a throttled-but-cooling latch when rate-limited slots are all within cooldown' {
            $times = @{ 'b' = [DateTime]::Now }   # just attempted
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'b' -Status 'rate-limited') )
            $out   = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 -CooldownMin 5 -CurrentLatch '[Warmup] Keeping all slots warm.'
            $out | Should -Be '[Warmup] Rate-limited; will re-warm when cooldown clears.'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
        }

        It 'distinguishes an at-limit throttle from a cooldown, which it cannot clear' {
            # A throttled slot whose cached numbers are at or above -Threshold
            # is held off by Test-WarmEligible's at-limit gate, not by the
            # cooldown: warming re-opens a window that is already full. The
            # cooldown wording would promise a recovery that never arrives.
            $row = [pscustomobject]@{
                Name = 'burned'; Status = 'rate-limited'; IsActive = $false
                Error = $null;   Email  = 'burned@test.local'
                Data = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = $script:Future }
                    seven_day = $null
                }
            }
            $out = Invoke-KeepWarmStep -Snapshot (New-KwSnapshot @($row)) -WarmupTimes @{} `
                                       -Threshold 95 -CurrentLatch '[Warmup] Keeping all slots warm.'

            $out | Should -Be '[Warmup] Rate-limited at the rotation threshold; will re-warm after the next window reset.'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
        }

        It 'skips a cold slot still inside its cooldown window' {
            $times = @{ 'a' = [DateTime]::Now }   # just re-warmed
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 -CooldownMin 5 -CurrentLatch '[Warmup] Keeping all slots warm.'

            $out | Should -Be '[Warmup] Keeping all slots warm.'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
        }

        It 're-warms a cold slot once its cooldown has elapsed' {
            $times = @{ 'a' = [DateTime]::Now.AddMinutes(-10) }
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 -CooldownMin 5 -CurrentLatch 'x' | Out-Null
            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly
        }

        It 'refuses (without warming) when Claude Code is running' {
            Mock Test-ClaudeRunning { $true }
            $snap = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch 'x'

            $out | Should -Be '[Warmup] Re-warm refused! Claude Code is running.'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
        }

        # The round-robin overwrites .credentials.json once per slot, and this
        # step runs after the poll's reconcile AND after a full serial usage
        # pass, so a refresh landing in that window would be discarded here.
        # Same guard, same window, as Invoke-AutoRotationStep's.
        It 'refuses (without warming) when reconcile could not capture the active credentials' {
            Mock Invoke-Reconcile { New-ReconcileResult -Action 'noop' -Reason 'identity-unresolved' -Slot 'a' -Captured $false }
            $times = @{}
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 -CurrentLatch 'x'

            $out | Should -Match '^\[Warmup\] Re-warm refused! .*could not be captured'
            Should -Invoke Invoke-WarmAllSlots -Times 0 -Exactly
            # Not stamped: the slot was never attempted, so the next poll must
            # be free to retry it as soon as the capture succeeds.
            $times.ContainsKey('a') | Should -BeFalse
        }

        It 'reconciles before warming so the swap cannot discard a fresh refresh' {
            Mock Invoke-Reconcile { New-ReconcileResult -Action 'mirror' -Slot 'a' }
            $snap = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch 'x' | Out-Null

            Should -Invoke Invoke-Reconcile -Times 1 -Exactly
            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly
        }

        It 'surfaces a warm-path exception as "Re-warm failed!" and still stamps the attempt' {
            Mock Invoke-WarmAllSlots { throw [System.IO.IOException]::new('locked slot file') }
            $times = @{}
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 -CurrentLatch 'x'

            $out | Should -Match '^\[Warmup\] Re-warm failed! .*locked slot file'
            $times.ContainsKey('a') | Should -BeTrue
        }

        # One footer entry, and Format-UsageFooter splits the footer on
        # newlines to colour each line, so a multi-line exception would fork
        # this into several unprefixed ones.
        It 'collapses a multi-line warm-path exception onto one latch line' {
            Mock Invoke-WarmAllSlots { throw [System.IO.IOException]::new("first line`r`nsecond line") }
            $snap = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch 'x'

            @($out -split "`r?`n").Count | Should -Be 1
            $out | Should -Be '[Warmup] Re-warm failed! first line second line'
        }

        It 'lists multiple cold slots sorted and quoted, warming only the cold subset' {
            $snap = New-KwSnapshot @(
                (New-KwRow -Name 'b' -FiveResetsAt $null),
                (New-KwRow -Name 'a' -FiveResetsAt $script:Future),  # warm; excluded
                (New-KwRow -Name 'c' -FiveResetsAt $script:Past)
            )

            $out = Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 -CurrentLatch 'x'

            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly -ParameterFilter {
                @($Names).Count -eq 2 -and (@($Names) -contains 'b') -and (@($Names) -contains 'c')
            }
            $out | Should -Match "^\[Warmup\] Re-warmed 'b', 'c' at"
        }

        # A flat cooldown assumes the next attempt can differ. While the
        # account's token endpoint is throttled it cannot: `claude -p`
        # refreshes through that same endpoint, so every retry buys the same
        # answer at ~$0.004. A data-less throttled row also scores 0% in
        # Get-RowMaxUtilization, so the at-limit gate cannot hold it off
        # either, which left such a slot retried every cooldown forever.
        It 'counts a failed warm and stretches that slot cooldown' {
            Mock Invoke-WarmAllSlots {
                [pscustomobject]@{ Results = @([pscustomobject]@{ Name = 'b'; Status = 'rate-limited' }) }
            }
            $times = @{}; $fails = @{}
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'b' -Status 'rate-limited') )

            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 `
                                -CooldownMin 5 -WarmupFailures $fails -CurrentLatch 'x' | Out-Null

            $fails['b'] | Should -Be 1

            # 6 minutes on: past the flat 5, still inside the doubled 10.
            $times['b'] = [DateTime]::Now.AddMinutes(-6)
            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 `
                                -CooldownMin 5 -WarmupFailures $fails -CurrentLatch 'x' | Out-Null

            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly
        }

        It 'resets the failure count after a successful warm' {
            Mock Invoke-WarmAllSlots {
                [pscustomobject]@{ Results = @([pscustomobject]@{ Name = 'a'; Status = 'ok' }) }
            }
            $fails = @{ 'a' = 3 }
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 `
                                -CooldownMin 5 -WarmupFailures $fails -CurrentLatch 'x' | Out-Null

            $fails.ContainsKey('a') | Should -BeFalse
        }

        It 'counts every slot in the batch as failed when the warm pass throws' {
            Mock Invoke-WarmAllSlots { throw [System.IO.IOException]::new('locked slot file') }
            $fails = @{}
            $snap  = New-KwSnapshot @(
                (New-KwRow -Name 'a' -FiveResetsAt $null),
                (New-KwRow -Name 'b' -FiveResetsAt $null)
            )

            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes @{} -Threshold 95 `
                                -CooldownMin 5 -WarmupFailures $fails -CurrentLatch 'x' | Out-Null

            $fails['a'] | Should -Be 1
            $fails['b'] | Should -Be 1
        }

        It 'omitting -WarmupFailures keeps the flat-cooldown behaviour' {
            # Backward compatibility for one-shot callers and existing tests.
            $times = @{ 'a' = [DateTime]::Now.AddMinutes(-6) }
            $snap  = New-KwSnapshot @( (New-KwRow -Name 'a' -FiveResetsAt $null) )

            Invoke-KeepWarmStep -Snapshot $snap -WarmupTimes $times -Threshold 95 `
                                -CooldownMin 5 -CurrentLatch 'x' | Out-Null

            Should -Invoke Invoke-WarmAllSlots -Times 1 -Exactly
        }
    }

    Context 'Get-WarmupCooldownMinutes' {
        It 'returns the base cooldown when the slot has no failures' {
            Get-WarmupCooldownMinutes -BaseMin 5 -Failures 0 | Should -Be 5
        }

        It 'doubles once per consecutive failure' {
            Get-WarmupCooldownMinutes -BaseMin 5 -Failures 1 | Should -Be 10
            Get-WarmupCooldownMinutes -BaseMin 5 -Failures 2 | Should -Be 20
            Get-WarmupCooldownMinutes -BaseMin 5 -Failures 3 | Should -Be 40
        }

        It 'caps the doubling so a recovered slot is still noticed' {
            $cap = Get-WarmupCooldownMinutes -BaseMin 5 -Failures $Script:WarmupBackoffMaxDoublings
            Get-WarmupCooldownMinutes -BaseMin 5 -Failures 99 | Should -Be $cap
        }

        It 'keeps a zero base at zero, so the test override still disables the gate' {
            Get-WarmupCooldownMinutes -BaseMin 0 -Failures 4 | Should -Be 0
        }

        It 'treats a negative failure count as no failures' {
            Get-WarmupCooldownMinutes -BaseMin 5 -Failures -2 | Should -Be 5
        }
    }

    Context 'Invoke-SlotActivator' {
        # Direct tests for the activator used by Invoke-WarmAllSlots. It
        # shells out to `claude -p` (via Invoke-ClaudeActivatorProcess, the
        # mock seam) and maps the result to Get-SlotUsage's status
        # vocabulary. No real claude process is ever spawned: every test
        # mocks Invoke-ClaudeActivatorProcess.

        BeforeAll {
            # Build a slot file with an OAuth payload so the activator's
            # HasOAuth pre-check passes. Token values are deterministic.
            function New-ActivatorSlot {
                Param ([string] $Name)
                $payload = @{
                    claudeAiOauth = @{
                        accessToken  = "sk-ant-oat-$Name"
                        refreshToken = "sk-ant-ort-$Name"
                        expiresAt    = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
                    }
                } | ConvertTo-Json -Compress
                return New-SlotPair -CredDir $script:CredDirPath -Name $Name -Email "$Name@test.local" -Content $payload
            }

            # A successful `claude -p --output-format json` envelope.
            function New-ClaudeOkProc {
                Param ([string] $Result = 'Hi there!')
                $json = @{ type = 'result'; subtype = 'success'; is_error = $false; result = $Result } | ConvertTo-Json -Compress
                return [pscustomobject]@{ TimedOut = $false; ExitCode = 0; Stdout = $json; Stderr = '' }
            }

            # A failing envelope: optionally is_error in JSON, plus a
            # message in the result text and/or stderr to drive
            # classification.
            function New-ClaudeFailProc {
                Param (
                    [int]    $ExitCode = 1,
                    [string] $Result   = '',
                    [string] $Stderr   = '',
                    [bool]   $JsonErr  = $true
                )
                $stdout = ''
                if ($Result) {
                    $stdout = @{ type = 'result'; subtype = 'error'; is_error = $JsonErr; result = $Result } | ConvertTo-Json -Compress
                }
                return [pscustomobject]@{ TimedOut = $false; ExitCode = $ExitCode; Stdout = $stdout; Stderr = $Stderr }
            }
        }

        BeforeEach {
            $script:CredDirPath = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
        }

        It 'no-OAuth slot returns Status=no-oauth without running claude' {
            $path = New-SlotPair -CredDir $script:CredDirPath -Name 'apikey' -Email 'a@b.com' -Content '{"apiKey":"sk-ant-api-..."}'
            Mock Invoke-ClaudeActivatorProcess -MockWith { throw 'claude should not be spawned for a no-OAuth slot' }

            (Invoke-SlotActivator -SlotPath $path).Status | Should -Be 'no-oauth'
            Should -Invoke Invoke-ClaudeActivatorProcess -Times 0 -Exactly
        }

        It 'success envelope (exit 0, is_error false) returns Status=ok and passes the expected claude args' {
            $path = New-ActivatorSlot -Name 'fresh'
            $script:capturedArgs = $null
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                Param ($ClaudeArgs, $TimeoutSec)
                $script:capturedArgs = $ClaudeArgs
                return New-ClaudeOkProc
            }

            (Invoke-SlotActivator -SlotPath $path).Status | Should -Be 'ok'

            # Non-interactive print, safe-mode (OAuth kept, repo config off),
            # cheap model, JSON envelope, no session files.
            $script:capturedArgs | Should -Contain '-p'
            $script:capturedArgs | Should -Contain $Script:ActivatorPrompt
            $script:capturedArgs | Should -Contain '--safe-mode'
            $script:capturedArgs | Should -Contain '--output-format'
            $script:capturedArgs | Should -Contain 'json'
            $script:capturedArgs | Should -Contain '--no-session-persistence'
            ($script:capturedArgs -join ' ') | Should -Match ('--model\s+' + [regex]::Escape($Script:ActivatorModel))
        }

        It 'rate-limit text returns Status=rate-limited' {
            $path = New-ActivatorSlot -Name 'busy'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                New-ClaudeFailProc -ExitCode 1 -Stderr 'API Error: 429 rate_limit_error Rate limited. Please try again later.'
            }

            (Invoke-SlotActivator -SlotPath $path).Status | Should -Be 'rate-limited'
        }

        # Claude Code's own plan-limit sentences say neither 'rate limit' nor
        # '429', so they used to fall into the default arm and surface as a
        # hard 'error' on a plainly throttled slot.
        It 'plan-limit text returns Status=rate-limited with the reset time kept: <Case>' -ForEach @(
            @{ Case = 'session limit'; Message = "You've hit your session limit `u{00B7} resets 6:10pm (Europe/Berlin)" }
            @{ Case = 'weekly limit';  Message = "You've hit your weekly limit `u{00B7} resets Nov 4 at 9am"            }
            @{ Case = 'limit reached'; Message = 'Claude usage limit reached. Your limit will reset at 6pm.'             }
        ) {
            $path = New-ActivatorSlot -Name 'capped'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                New-ClaudeFailProc -ExitCode 1 -Result $Message
            }

            $r = Invoke-SlotActivator -SlotPath $path
            $r.Status | Should -Be 'rate-limited'
            # Error carries the whole sentence, uncut: Format-UsageAdvisory
            # renders it as the slot's reason line, and the reset time is the
            # only part the user can act on.
            $r.Error  | Should -Be $Message
        }

        It 'stores the reason raw, leaving the bound to the renderer' {
            # 3 of the 10 sites that stamp .Error used to truncate and 7 did
            # not, so a stored bound was never an invariant. Every display path
            # runs through Format-StatusErrorTail, so the row (and -Json) keeps
            # the full text.
            $path = New-ActivatorSlot -Name 'verbose'
            $long = 'Z' * ($Script:AdvisoryReasonMaxWidth * 3)
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                New-ClaudeFailProc -ExitCode 1 -Result $long
            }

            $r = Invoke-SlotActivator -SlotPath $path
            $r.Status | Should -Be 'error'
            $r.Error  | Should -Be $long
        }

        # A bare 'limit' is not a plan limit. Classifying these as
        # 'rate-limited' would hide them: a throttled row gets silently
        # re-probed on the next poll instead of reported to the user.
        It 'non-plan limit text stays Status=error: <Case>' -ForEach @(
            @{ Case = 'context window'; Message = 'Prompt is too long: context limit reached for this conversation.' }
            @{ Case = 'tool output';    Message = 'Tool result exceeds the maximum output limit reached by the tool.' }
        ) {
            $path = New-ActivatorSlot -Name 'oversized'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                New-ClaudeFailProc -ExitCode 1 -Result $Message
            }

            (Invoke-SlotActivator -SlotPath $path).Status | Should -Be 'error'
        }

        It 'auth/permission text returns Status=unauthorized' {
            $path = New-ActivatorSlot -Name 'revoked'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                New-ClaudeFailProc -ExitCode 1 -Stderr 'API Error: 401 authentication_error Invalid authentication credentials'
            }

            (Invoke-SlotActivator -SlotPath $path).Status | Should -Be 'unauthorized'
        }

        It 'expired/login text returns Status=expired with an error tail' {
            $path = New-ActivatorSlot -Name 'stale'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                New-ClaudeFailProc -ExitCode 1 -Result 'Invalid API key. Please run /login to authenticate.'
            }

            $r = Invoke-SlotActivator -SlotPath $path
            $r.Status | Should -Be 'expired'
            $r.Error  | Should -Match 'login'
        }

        It 'timeout returns Status=error mentioning the timeout' {
            $path = New-ActivatorSlot -Name 'slow'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                return [pscustomobject]@{ TimedOut = $true; ExitCode = $null; Stdout = ''; Stderr = '' }
            }

            $r = Invoke-SlotActivator -SlotPath $path
            $r.Status | Should -Be 'error'
            $r.Error  | Should -Match 'timed out'
        }

        It 'claude-not-found returns Status=error mentioning the missing CLI' {
            $path = New-ActivatorSlot -Name 'nocli'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                return [pscustomobject]@{ TimedOut = $false; ExitCode = $null; Stdout = ''; Stderr = 'claude-not-found' }
            }

            $r = Invoke-SlotActivator -SlotPath $path
            $r.Status | Should -Be 'error'
            $r.Error  | Should -Match 'not found'
        }

        It 'non-zero exit with unparseable stdout and no recognizable text returns Status=error' {
            $path = New-ActivatorSlot -Name 'flaky'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                return [pscustomobject]@{ TimedOut = $false; ExitCode = 2; Stdout = 'not json at all'; Stderr = 'segfault' }
            }

            (Invoke-SlotActivator -SlotPath $path).Status | Should -Be 'error'
        }

        It 'JSON error field (no result) drives classification' {
            $path = New-ActivatorSlot -Name 'fielderr'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                $json = @{ type = 'result'; is_error = $true; error = '403 forbidden' } | ConvertTo-Json -Compress
                return [pscustomobject]@{ TimedOut = $false; ExitCode = 1; Stdout = $json; Stderr = '' }
            }

            (Invoke-SlotActivator -SlotPath $path).Status | Should -Be 'unauthorized'
        }

        It 'empty output with non-zero exit falls back to an "exited with code" error' {
            $path = New-ActivatorSlot -Name 'silent'
            Mock Invoke-ClaudeActivatorProcess -MockWith {
                return [pscustomobject]@{ TimedOut = $false; ExitCode = 7; Stdout = ''; Stderr = '' }
            }

            $r = Invoke-SlotActivator -SlotPath $path
            $r.Status | Should -Be 'error'
            $r.Error  | Should -Match 'exited with code 7'
        }
    }

    Context 'Invoke-ClaudeActivatorProcess' {
        # The mockable process seam. Exercised here against a real stand-in
        # executable (the running pwsh) instead of `claude`, so the
        # Start-Process / capture / timeout / not-found branches are covered
        # without spawning Claude Code.

        BeforeEach {
            $script:CredDirPath = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:fakePwsh = (Get-Process -Id $PID).Path
        }

        It 'returns claude-not-found (null ExitCode) when the binary is absent' {
            Mock Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith { $null }

            $r = Invoke-ClaudeActivatorProcess -ClaudeArgs @('-p') -TimeoutSec 5

            $r.TimedOut | Should -BeFalse
            $r.ExitCode | Should -BeNullOrEmpty
            $r.Stderr   | Should -Be 'claude-not-found'
        }

        It 'captures stdout and a zero exit code from a successful run' {
            $src = $script:fakePwsh
            Mock Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith {
                [pscustomobject]@{ Name = 'claude'; Source = $src; CommandType = 'Application' }
            }

            $r = Invoke-ClaudeActivatorProcess -ClaudeArgs @('-NoProfile', '-Command', 'Write-Output ''ACTIVATOR_OK''') -TimeoutSec 30

            $r.TimedOut | Should -BeFalse
            $r.ExitCode | Should -Be 0
            $r.Stdout   | Should -Match 'ACTIVATOR_OK'
        }

        It 'kills and reports TimedOut when the process runs past the timeout' {
            $src = $script:fakePwsh
            Mock Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith {
                [pscustomobject]@{ Name = 'claude'; Source = $src; CommandType = 'Application' }
            }

            $r = Invoke-ClaudeActivatorProcess -ClaudeArgs @('-NoProfile', '-Command', 'Start-Sleep -Seconds 10') -TimeoutSec 1

            $r.TimedOut | Should -BeTrue
            $r.ExitCode | Should -BeNullOrEmpty
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
