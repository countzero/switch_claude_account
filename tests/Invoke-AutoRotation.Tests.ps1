#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the `sca monitor` auto-rotation helpers
# in switch_claude_account.ps1:
#
#   * Get-AutoRotationDecision  - pure: snapshot + threshold -> decision
#   * Get-RowMaxUtilization     - pure: row -> max(five_hour, seven_day)
#   * Format-AutoCooldownDelta  - pure: reset timestamp -> 'Xh Ym'
#   * Invoke-AutoRotationStep   - per-tick wrapper used by the watch loop
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

    # Select-LiveBuckets is the one place the "has this window rolled" question
    # is answered, and it answers it at New-UsageResult, before any consumer
    # sees the row. Every renderer and both decision paths therefore read the
    # same buckets; the tests below pin that they agree.
    Context 'Select-LiveBuckets' {
        BeforeAll {
            $script:LiveNow = [DateTimeOffset]::new(2026, 8, 4, 12, 0, 0, [TimeSpan]::Zero)
            function script:IsoAt { Param ($Offset) $script:LiveNow.Add($Offset).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
        }

        It 'passes null and bucket-less bodies straight through' {
            Select-LiveBuckets -Data $null -Now $script:LiveNow | Should -BeNullOrEmpty
            $empty = [pscustomobject]@{ extra_usage = [pscustomobject]@{ is_enabled = $false } }
            (Select-LiveBuckets -Data $empty -Now $script:LiveNow).extra_usage.is_enabled | Should -BeFalse
        }

        It 'removes a bucket whose resets_at has passed' {
            $data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (IsoAt ([TimeSpan]::FromHours(-1))) }
                seven_day = [pscustomobject]@{ utilization = 20.0;  resets_at = (IsoAt ([TimeSpan]::FromDays(3))) }
            }
            $live = Select-LiveBuckets -Data $data -Now $script:LiveNow

            # Absent, not null: a scripted `sca usage -Json` consumer testing
            # for the key sees what every renderer sees.
            $live.PSObject.Properties.Name | Should -Not -Contain 'five_hour'
            $live.seven_day.utilization | Should -Be 20.0
        }

        It 'removes a bucket exactly at the reset instant' {
            $data = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 50.0; resets_at = (IsoAt ([TimeSpan]::Zero)) } }
            (Select-LiveBuckets -Data $data -Now $script:LiveNow).PSObject.Properties.Name |
                Should -Not -Contain 'five_hour'
        }

        It 'keeps a bucket whose resets_at is still in the future' {
            $data = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (IsoAt ([TimeSpan]::FromMinutes(12))) } }
            (Select-LiveBuckets -Data $data -Now $script:LiveNow).five_hour.utilization | Should -Be 100.0
        }

        It 'keeps a bucket with no resets_at, and one it cannot parse' {
            $data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 77.0; resets_at = 'garbage' }
                seven_day = [pscustomobject]@{ utilization = 66.0; resets_at = $null }
            }
            $live = Select-LiveBuckets -Data $data -Now $script:LiveNow
            $live.five_hour.utilization | Should -Be 77.0
            $live.seven_day.utilization | Should -Be 66.0
        }

        It 'never mutates the cached body it was handed' {
            # $Script:SlotUsageCache holds what the server actually said; its
            # own Timestamp is what ages it. Mutating in place would corrupt
            # every later read of the same entry.
            $data = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (IsoAt ([TimeSpan]::FromHours(-1))) } }
            Select-LiveBuckets -Data $data -Now $script:LiveNow | Out-Null
            $data.five_hour.utilization | Should -Be 100.0
        }

        It 'is applied by New-UsageResult, so no consumer can see a rolled bucket' {
            $data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (IsoAt ([TimeSpan]::FromHours(-1))) }
                seven_day = [pscustomobject]@{ utilization = 20.0;  resets_at = (IsoAt ([TimeSpan]::FromDays(3))) }
            }
            $row = New-UsageResult -Status 'ok' -Data $data -Now $script:LiveNow
            $row.Data.PSObject.Properties.Name | Should -Not -Contain 'five_hour'
        }

        # The regression this whole change exists for: one row printed '100%
        # now' in the Session cell and 'limited 5h' in Status while the
        # aggregate bar above it read 0%, the terminal title read '[!] 100%',
        # and auto-rotation treated the slot as idle and refused to move.
        It 'leaves the cell, the status, the bar, the title and rotation agreeing' {
            $data = [pscustomobject]@{
                five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (IsoAt ([TimeSpan]::FromHours(-1))) }
                seven_day = [pscustomobject]@{ utilization = 20.0;  resets_at = (IsoAt ([TimeSpan]::FromDays(3))) }
            }
            $result = New-UsageResult -Status 'ok' -Data $data -CachedReason 'network' -Now $script:LiveNow
            $row    = [pscustomobject]@{
                Name = 'a'; IsActive = $true; Status = $result.Status; Data = $result.Data
                Error = $result.Error; Email = $null; HttpStatus = $null
                IsCachedFallback = $result.IsCachedFallback; FallbackReason = $result.FallbackReason
            }

            $table = Format-UsageTable -Results @($row) 6>&1 | Out-String

            # Session cell: em-dash, not '100% now'.
            $table | Should -Not -Match '100%'
            # Status: no longer 'limited 5h'.
            Get-PlanStatus $row.Data | Should -Be 'ok'
            # Bar and rotation: both read the surviving 7d bucket only.
            Get-PoolMeanUtilization -Results @($row) -BucketKey 'five_hour' | Should -Be 0
            Get-RowMaxUtilization -Row $row | Should -Be 20.0
            # Title: the 5h segment reads as no-data, not as an alarm.
            Format-WatchTitle -Snapshot ([pscustomobject]@{ Results = @($row); NoSlots = $false }) |
                Should -Not -Match '\[!\]'
        }
    }

    Context 'Get-RowMaxUtilization' {
        It 'returns max of two non-null utilizations' {
            $row = [pscustomobject]@{
                Status = 'ok'
                Data   = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 30.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 80.0; resets_at = $null }
                }
            }
            Get-RowMaxUtilization -Row $row | Should -Be 80.0
        }

        It 'treats null five_hour as 0 and returns seven_day' {
            $row = [pscustomobject]@{
                Status = 'ok'
                Data   = [pscustomobject]@{
                    five_hour = $null
                    seven_day = [pscustomobject]@{ utilization = 99.0; resets_at = $null }
                }
            }
            Get-RowMaxUtilization -Row $row | Should -Be 99.0
        }

        It 'treats both buckets null as 0' {
            $row = [pscustomobject]@{
                Status = 'ok'
                Data   = [pscustomobject]@{
                    five_hour = $null
                    seven_day = $null
                }
            }
            Get-RowMaxUtilization -Row $row | Should -Be 0.0
        }

        It 'returns 0 when the row carries no Data at all' {
            $row = [pscustomobject]@{ Status = 'error'; Data = $null }
            Get-RowMaxUtilization -Row $row | Should -Be 0.0
        }

        # This used to return 0 for ANY non-ok row
        # even when Data was present, which meant a single usage-endpoint
        # timeout on the active slot made it look 0%-utilized and silently
        # disarmed auto-rotation. Format-UsageTable already renders bucket
        # percentages from Data regardless of Status, so a row good enough to
        # show the user is now good enough to decide on.
        It 'judges a non-ok row on its cached Data' {
            foreach ($status in @('error', 'rate-limited', 'expired')) {
                $row = [pscustomobject]@{
                    Status = $status
                    Data   = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = 99.0; resets_at = $null }
                        seven_day = $null
                    }
                }
                Get-RowMaxUtilization -Row $row |
                    Should -Be 99.0 -Because "status '$status' still carries usable percentages"
            }
        }

        # The window-rolled rule lives in Select-LiveBuckets, one layer up, so
        # a rolled bucket is already absent by the time a row exists. Reading
        # resets_at again here is what let this function and the table
        # disagree; the Select-LiveBuckets Context owns those cases now.
        It 'reads resets_at nowhere, so a rolled bucket that reached it still counts' {
            $row = [pscustomobject]@{
                Status = 'ok'
                Data   = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = '2000-01-01T00:00:00Z' }
                    seven_day = $null
                }
            }
            Get-RowMaxUtilization -Row $row | Should -Be 100.0
        }
    }

    Context 'Get-BucketUtilizationOrZero' {
        It 'returns 0 for a null bucket' {
            Get-BucketUtilizationOrZero -Bucket $null | Should -Be 0.0
        }

        It 'returns 0 when utilization is null' {
            $b = [pscustomobject]@{ utilization = $null; resets_at = $null }
            Get-BucketUtilizationOrZero -Bucket $b | Should -Be 0.0
        }

        It 'returns the utilization regardless of resets_at' {
            $b = [pscustomobject]@{ utilization = 50.0; resets_at = '2000-01-01T00:00:00Z' }
            Get-BucketUtilizationOrZero -Bucket $b | Should -Be 50.0
        }
    }

    Context 'Format-AutoCooldownDelta' {
        It 'renders an under-1h future delta as "Xm"' {
            $reset = [DateTimeOffset]::UtcNow.AddMinutes(42).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $out = Format-AutoCooldownDelta $reset
            # Allow 41..42m slack for clock drift between test setup and helper call.
            $out | Should -Match '^(41|42)m$'
        }

        It 'renders a 1h..24h future delta as "Xh Ym"' {
            $reset = [DateTimeOffset]::UtcNow.AddMinutes(134).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $out = Format-AutoCooldownDelta $reset
            $out | Should -Match '^2h (13|14)m$'
        }

        It 'renders a >=24h future delta as integer "Xh"' {
            # Use a generous 42h + 1m offset so clock drift between test
            # setup and the helper call never makes the floored hours
            # tick down to 41. Format-AutoCooldownDelta floors total
            # hours, so 42:00.99 -> 42; the test asserts on the format
            # shape and the exact value 42h within that 1-minute window.
            $reset = [DateTimeOffset]::UtcNow.AddHours(42).AddMinutes(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-AutoCooldownDelta $reset | Should -Be '42h'
        }

        It 'returns "less than a minute" for a non-positive delta' {
            $reset = [DateTimeOffset]::UtcNow.AddSeconds(-30).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-AutoCooldownDelta $reset | Should -Be 'less than a minute'
        }

        It 'returns "unknown" for unparseable / null input' {
            Format-AutoCooldownDelta $null     | Should -Be 'unknown'
            Format-AutoCooldownDelta ''        | Should -Be 'unknown'
            Format-AutoCooldownDelta 'garbage' | Should -Be 'unknown'
        }
    }

    Context 'Get-AutoRotationDecision' {
        # Build a synthetic snapshot resembling Get-UsageSnapshot's output
        # shape without hitting the network or filesystem. Each row mirrors
        # the fields the pure decision logic reads: Name, IsActive, Status,
        # Data.five_hour.utilization / .resets_at, Data.seven_day.{same}.
        BeforeAll {
            function New-Row {
                Param (
                    [string] $Name,
                    [bool]   $IsActive = $false,
                    [string] $Status   = 'ok',
                    $FiveUtil          = 0.0,
                    $FiveResetsAt      = $null,
                    $SevenUtil         = 0.0,
                    $SevenResetsAt     = $null
                )

                $data = $null
                if ($Status -eq 'ok') {
                    $data = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = $FiveUtil;  resets_at = $FiveResetsAt }
                        seven_day = [pscustomobject]@{ utilization = $SevenUtil; resets_at = $SevenResetsAt }
                    }
                }

                return [pscustomobject]@{
                    Name     = $Name
                    IsActive = $IsActive
                    Status   = $Status
                    Data     = $data
                    Error    = $null
                    Email    = "$Name@test.local"
                }
            }

            function New-Snapshot {
                Param ([object[]] $Rows)
                return [pscustomobject]@{
                    Results          = @($Rows)
                    NoSlots          = ($null -eq $Rows -or $Rows.Count -eq 0)
                    HasRateLimited   = $false
                }
            }

            # Row carrying cached percentages under a non-ok status, i.e. what
            # Get-SlotUsage returns from the stale-cache fallback.
            function New-CachedRow {
                Param (
                    [string] $Name,
                    [bool]   $IsActive = $false,
                    [string] $Status   = 'error',
                    $FiveUtil          = 0.0,
                    $SevenUtil         = 0.0
                )
                return [pscustomobject]@{
                    Name             = $Name
                    IsActive         = $IsActive
                    Status           = $Status
                    Data             = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = $FiveUtil;  resets_at = $null }
                        seven_day = [pscustomobject]@{ utilization = $SevenUtil; resets_at = $null }
                    }
                    Error            = 'boom'
                    Email            = "$Name@test.local"
                    IsCachedFallback = $true
                    FallbackReason   = 'network'
                    HttpStatus       = $null
                }
            }
        }

        It 'returns noop when snapshot is empty (NoSlots)' {
            $snap = New-Snapshot @()
            $d = Get-AutoRotationDecision -Snapshot $snap -Threshold 100
            $d.Action | Should -Be 'noop'
        }

        It 'returns noop when no row is active' {
            $rows = @(
                (New-Row -Name 'a' -FiveUtil 50.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 50.0 -SevenUtil 50.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'noop'
        }

        It 'returns noop when active slot is below threshold' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 30.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 10.0 -SevenUtil 10.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action   | Should -Be 'noop'
            $d.FromName | Should -Be 'a'
        }

        It 'rotates to the next eligible peer in alphabetical wrap order' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 18.0 -SevenUtil 31.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action   | Should -Be 'rotate'
            $d.FromName | Should -Be 'a'
            $d.ToName   | Should -Be 'b'
        }

        It 'rotation wraps from last slot back to first' {
            $rows = @(
                (New-Row -Name 'a' -FiveUtil 20.0 -SevenUtil 20.0),
                (New-Row -Name 'b' -IsActive $true -FiveUtil 100.0 -SevenUtil 50.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'a'
        }

        It 'skips peers that are themselves at or above threshold' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 100.0 -SevenUtil 80.0),    # also limited; skip
                (New-Row -Name 'c' -FiveUtil 20.0  -SevenUtil 30.0)     # eligible
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'c'
        }

        It 'skips peers with non-ok HTTP status (expired)' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0),
                (New-Row -Name 'b' -Status 'expired'),
                (New-Row -Name 'c' -FiveUtil 20.0 -SevenUtil 30.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'c'
        }

        It 'returns no-eligible when all peers are also at or above threshold' {
            $futureA = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $futureB = [DateTimeOffset]::UtcNow.AddHours(3).ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -FiveResetsAt $futureA -SevenUtil 80.0),
                (New-Row -Name 'b' -FiveUtil 100.0 -FiveResetsAt $futureB -SevenUtil 90.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100

            $d.Action             | Should -Be 'no-eligible'
            $d.FromName           | Should -Be 'a'
            $d.SuggestionName     | Should -Be 'a'
            $d.SuggestionBucket   | Should -Be 'Session'
            $d.SuggestionResetsAt | Should -Not -BeNullOrEmpty
        }

        It 'no-eligible picks the soonest FUTURE reset across all slots and buckets' {
            $soon       = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $later      = [DateTimeOffset]::UtcNow.AddHours(5).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $past       = [DateTimeOffset]::UtcNow.AddMinutes(-30).ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            $rows = @(
                # Active 'a': past 5h reset (must be ignored), future 7d.
                (New-Row -Name 'a' -IsActive $true `
                    -FiveUtil 100.0  -FiveResetsAt $past `
                    -SevenUtil 100.0 -SevenResetsAt $later),
                # Peer 'b' also at threshold: its 5h reset is the soonest future reset overall.
                (New-Row -Name 'b' `
                    -FiveUtil 100.0  -FiveResetsAt $soon `
                    -SevenUtil 100.0 -SevenResetsAt $later)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100

            $d.Action           | Should -Be 'no-eligible'
            $d.SuggestionName   | Should -Be 'b'
            $d.SuggestionBucket | Should -Be 'Session'
        }

        It 'threshold uses max(5h, 7d): 5h=10, 7d=99, threshold=95 -> rotate' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 10.0 -SevenUtil 99.0),
                (New-Row -Name 'b' -FiveUtil 20.0 -SevenUtil 30.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 95
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'b'
        }

        It 'null bucket on active counts as 0% for max(util)' {
            # Active row's seven_day is missing; max(util) falls to five_hour=50.
            # Threshold 60 -> below -> noop.
            $row = [pscustomobject]@{
                Name     = 'a'
                IsActive = $true
                Status   = 'ok'
                Data     = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 50.0; resets_at = $null }
                    seven_day = $null
                }
                Email    = 'a@test.local'
            }
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot @($row)) -Threshold 60
            $d.Action | Should -Be 'noop'
        }

        It 'threshold 100 with active at exactly 100 triggers rotation (boundary inclusive)' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 10.0 -SevenUtil 10.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'rotate'
        }

        It 'single-slot pool at threshold -> no-eligible (cannot rotate to self)' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $rows = @(
                (New-Row -Name 'only' -IsActive $true -FiveUtil 100.0 -FiveResetsAt $future)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action         | Should -Be 'no-eligible'
            $d.SuggestionName | Should -Be 'only'
        }

        # A data-less non-ok active row used to fall into the
        # below-threshold 'noop' branch, which preserved the previous latch and
        # left the monitor silently unable to rotate for as long as the failure
        # lasted. It now reports instead.
        It 'returns active-unknown when the active row is non-ok with no Data' {
            foreach ($status in @('error', 'expired', 'unauthorized', 'no-oauth', 'rate-limited')) {
                $rows = @(
                    (New-Row -Name 'a' -IsActive $true -Status $status),
                    (New-Row -Name 'b' -FiveUtil 10.0 -SevenUtil 10.0)
                )
                $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 95
                $d.Action       | Should -Be 'active-unknown' -Because "status '$status' carries no usable data"
                $d.FromName     | Should -Be 'a'
                $d.ToName       | Should -BeNullOrEmpty
                $d.ActiveStatus | Should -Be $status
            }
        }

        It 'a missing active row stays noop, not active-unknown (state problem, not network)' {
            $rows = @(
                (New-Row -Name 'a' -Status 'error'),
                (New-Row -Name 'b' -Status 'error')
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 95
            $d.Action | Should -Be 'noop'
        }

        It 'rotates off a non-ok active row whose cached data is at threshold' {
            $rows = @(
                (New-CachedRow -Name 'a' -IsActive $true -FiveUtil 100.0 -SevenUtil 20.0),
                (New-Row -Name 'b' -FiveUtil 10.0 -SevenUtil 10.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 95
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'b'
        }

        It 'stays noop on a non-ok active row whose cached data is below threshold' {
            $rows = @(
                (New-CachedRow -Name 'a' -IsActive $true -FiveUtil 40.0 -SevenUtil 20.0),
                (New-Row -Name 'b' -FiveUtil 10.0 -SevenUtil 10.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 95
            $d.Action   | Should -Be 'noop'
            $d.FromName | Should -Be 'a'
        }

        # Cached data is good enough to decide to LEAVE a slot but not to
        # ENTER one: a peer we cannot verify may be throttled or broken.
        It 'never rotates INTO a non-ok peer even when its cached data looks free' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -FiveResetsAt $future),
                (New-CachedRow -Name 'b' -FiveUtil 5.0 -SevenUtil 5.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 95
            $d.Action | Should -Be 'no-eligible'
        }
    }

    Context 'Invoke-AutoRotationStep' {
        # The step wraps Get-AutoRotationDecision + Test-ClaudeRunning re-check
        # + Find-SlotByName + Invoke-SlotSwap. Tests mock the decision and the
        # swap so each branch can be exercised without filesystem state.
        BeforeAll {
            function New-EmptySnapshot {
                return [pscustomobject]@{
                    Results          = @()
                    NoSlots          = $true
                }
            }
        }

        It 'on noop preserves the current latch verbatim' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{ Action = 'noop' } }
            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'
            $out | Should -Be '[Monitor] Automatic slot switching is enabled.'
        }

        It 'on noop preserves a previously-latched Rotated line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{ Action = 'noop' } }
            $prev = '[Monitor] Rotated from "a" to "b" at 12:00:00'
            $out  = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch $prev
            $out | Should -Be $prev
        }

        # The whole point of the 'active-unknown' action: it must REPLACE a
        # latched 'Rotated ...' line, because preserving that line is what made
        # a blind monitor look like a working one.
        It 'on active-unknown reports the status and replaces a latched Rotated line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action       = 'active-unknown'
                FromName     = 'slot-1'
                ActiveStatus = 'error'
            } }
            $prev = '[Monitor] Rotated from "slot-2" to "slot-1" at 11:00:09'
            $out  = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 95 -CurrentLatch $prev

            $out | Should -Be '[Monitor] Active slot usage unknown (error); rotation paused.'
            $out | Should -Not -Be $prev
        }

        # The mirror image, and the reason 'noop' cannot simply pass the latch
        # through: once the read recovers, a latched "rotation paused" line
        # reports a blind monitor that is in fact armed, for the rest of the
        # watch or until an event that may never come.
        It 'on noop clears a latched rotation-paused line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{ Action = 'noop' } }
            $paused = '[Monitor] Active slot usage unknown (error); rotation paused.'

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 95 -CurrentLatch $paused

            $out | Should -Be '[Monitor] Automatic slot switching is enabled.'
        }

        It 'on active-unknown does not swap' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action       = 'active-unknown'
                FromName     = 'slot-1'
                ActiveStatus = 'rate-limited'
            } }
            Mock Invoke-SlotSwap { }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 95 -CurrentLatch 'x'

            Should -Invoke Invoke-SlotSwap -Times 0
            $out | Should -Be '[Monitor] Active slot usage unknown (rate-limited); rotation paused.'
        }

        It 'on rotate calls Invoke-SlotSwap and returns a quoted+timestamped Rotated line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Find-SlotByName  { return [pscustomobject]@{ Name = 'personal'; Path = 'x'; Sidecar = $null } }
            Mock Invoke-SlotSwap  { }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'

            Should -Invoke Invoke-SlotSwap -Times 1
            $out | Should -Match '^\[Monitor\] Rotated from "work" to "personal" at \d{2}:\d{2}:\d{2}$'
        }

        It 'on rotate with Claude Code running: refuses, does NOT call Invoke-SlotSwap' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Test-ClaudeRunning { $true }
            Mock Invoke-SlotSwap    { }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'

            Should -Invoke Invoke-SlotSwap -Times 0
            $out | Should -Be '[Monitor] Rotation refused! Claude Code is running.'
        }

        It 'on rotate when swap throws, returns Rotation failed!' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Find-SlotByName { return [pscustomobject]@{ Name = 'personal'; Path = 'x'; Sidecar = $null } }
            Mock Invoke-SlotSwap { throw [System.IO.IOException]::new('locked file') }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'
            $out | Should -Match '^\[Monitor\] Rotation failed! .*locked file'
        }

        # The latch becomes one footer entry and Format-UsageFooter splits the
        # footer on newlines to colour each line, so a multi-line exception
        # (socket errors span several) would fork this into unprefixed lines.
        It 'collapses a multi-line swap exception onto one latch line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Find-SlotByName { return [pscustomobject]@{ Name = 'personal'; Path = 'x'; Sidecar = $null } }
            Mock Invoke-SlotSwap { throw [System.IO.IOException]::new("first line`r`nsecond line") }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'

            @($out -split "`r?`n").Count | Should -Be 1
            $out | Should -Be '[Monitor] Rotation failed! first line second line'
        }

        It 'on rotate when slot lookup returns null, returns Rotation failed!' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Find-SlotByName { return $null }
            Mock Invoke-SlotSwap { }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'
            Should -Invoke Invoke-SlotSwap -Times 0
            $out | Should -Match '^\[Monitor\] Rotation failed! Slot ''personal'' not found'
        }

        It 'on no-eligible with a future reset, returns cooldown line with a delta' {
            $future = [DateTimeOffset]::UtcNow.AddMinutes(72).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action             = 'no-eligible'
                SuggestionResetsAt = $future
            } }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'
            $out | Should -Match '^\[Monitor\] No free slot available! Cooling down for 1h (11|12)m\.$'
        }

        It 'on no-eligible without any future reset, returns a generic line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action             = 'no-eligible'
                SuggestionResetsAt = $null
            } }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'
            $out | Should -Be '[Monitor] No free slot available! Waiting for the next poll.'
        }

        # Regression guard for the default arm: if Get-AutoRotationDecision
        # ever returns an Action value the switch does not recognise (a
        # contract bug in the decision helper, or a future Action we
        # forgot to handle), Invoke-AutoRotationStep must NOT crash; it
        # preserves the existing latch and lets the watch loop continue.
        It 'on unknown decision Action, preserves the current latch (default arm)' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action = 'something-unexpected'
            } }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Monitor] Automatic slot switching is enabled.'
            $out | Should -Be '[Monitor] Automatic slot switching is enabled.'
        }
    }

    # Regression guard for Get-AutoRotationDecision's "empty Results
    # after the @() cast" branch: NoSlots=false but Results is empty.
    # Difference from the NoSlots branch test above; both arms must
    # return the 'noop' decision struct.
    Context 'Get-AutoRotationDecision (empty Results not flagged NoSlots)' {
        It 'returns noop when Results is empty but NoSlots is false' {
            $snap = [pscustomobject]@{
                Results          = @()
                NoSlots          = $false
            }
            $d = Get-AutoRotationDecision -Snapshot $snap -Threshold 100
            $d.Action   | Should -Be 'noop'
            $d.FromName | Should -BeNullOrEmpty
            $d.ToName   | Should -BeNullOrEmpty
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
