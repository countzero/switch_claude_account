#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the small pure-helper functions in
# switch_claude_account.ps1: Get-SafeName, Get-ProfileEncoding, Get-Slots,
# Get-SlotFileInfo, Show-Help.
#
# Per-test sandbox setup lives in tests/Common.ps1; see that file for the
# scoping rationale. Each top-level Describe must wrap a BeforeEach (Pester 5
# forbids BeforeEach at file root), so all Contexts in this file nest under
# one outer Describe named 'switch_claude_account', same name as the other
# split files so test FullName paths stay stable.

BeforeAll {
    # Capture the pre-suite values of the two globals BeforeEach mutates so
    # we can restore them in AfterAll. Without this, running Invoke-Pester
    # directly in an interactive shell (as the README suggests) would leave
    # the session's $env:USERPROFILE pointing at a deleted $TestDrive path
    # and $PROFILE as a PSCustomObject stub, which breaks later commands.
    # Running via the subprocess `pwsh -NoProfile -File tests/Invoke-Tests.ps1`
    # was already safe because the mutations died with the subprocess.
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
    $script:OriginalHome        = $env:HOME
    $script:OriginalConfigDir   = $env:CLAUDE_CONFIG_DIR
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Get-SafeName' {
        # NOTE: we use Raw (not Input) as the hashtable key because $Input
        # is a PowerShell automatic variable (pipeline enumerator) and gets
        # overwritten inside test scriptblocks, yielding empty strings.
        It 'rejects: <Case>' -ForEach @(
            @{ Case = 'empty';      Raw = '';        Pattern = 'Name required' }
            @{ Case = 'whitespace'; Raw = '   ';     Pattern = 'Name required' }
            @{ Case = 'dot';        Raw = '.';       Pattern = 'invalid filename' }
            @{ Case = 'dotdot';     Raw = '..';      Pattern = 'invalid filename' }
            @{ Case = 'dotdotdot';  Raw = '...';     Pattern = 'invalid filename' }
            @{ Case = 'CON';        Raw = 'CON';     Pattern = 'reserved Windows device' }
            @{ Case = 'con lower';  Raw = 'con';     Pattern = 'reserved Windows device' }
            @{ Case = 'CON.bak';    Raw = 'con.bak'; Pattern = 'reserved Windows device' }
            @{ Case = 'LPT3';       Raw = 'lpt3';    Pattern = 'reserved Windows device' }
            @{ Case = 'COM9';       Raw = 'COM9';    Pattern = 'reserved Windows device' }
            @{ Case = 'NUL';        Raw = 'NUL';     Pattern = 'reserved Windows device' }
        ) {
            { Get-SafeName $Raw } | Should -Throw -ExpectedMessage "*$Pattern*"
        }

        It 'sanitizes: <Case>' -ForEach @(
            @{ Case = 'space';          Raw = 'my personal'; Expected = 'my_personal' }
            @{ Case = 'forward slash';  Raw = 'foo/bar';     Expected = 'foo_bar' }
            @{ Case = 'backslash';      Raw = 'foo\bar';     Expected = 'foo_bar' }
            @{ Case = 'colon';          Raw = 'a:b';         Expected = 'a_b' }
            @{ Case = 'angle brackets'; Raw = 'a<b>c';       Expected = 'a_b_c' }
            @{ Case = 'pipe';           Raw = 'a|b';         Expected = 'a_b' }
            @{ Case = 'trailing dot';   Raw = 'foo.';        Expected = 'foo' }
            @{ Case = 'many dots';      Raw = 'foo...';      Expected = 'foo' }
            # Brackets are valid on the Windows filesystem but are PowerShell
            # wildcard chars; leaving them in slot names would cause -Path
            # operations to match unintended files (silent wrong-slot or
            # data-loss bug).
            @{ Case = 'open bracket';   Raw = 'foo[bar';     Expected = 'foo_bar' }
            @{ Case = 'close bracket';  Raw = 'foo]bar';     Expected = 'foo_bar' }
            @{ Case = 'both brackets';  Raw = 'foo[bar]';    Expected = 'foo_bar_' }
            # Parens are sanitized because the slot filename encodes the
            # OAuth email as `.credentials.<slot>(<email>).json`. Leaving
            # parens in user-provided slot names would produce ambiguous
            # filenames that the Get-SlotFileInfo parser cannot split
            # correctly.
            @{ Case = 'open paren';     Raw = 'foo(bar';     Expected = 'foo_bar' }
            @{ Case = 'close paren';    Raw = 'foo)bar';     Expected = 'foo_bar' }
            @{ Case = 'both parens';    Raw = 'foo(bar)';    Expected = 'foo_bar_' }
        ) {
            # Information stream 6 carries the "Sanitized to:" Write-Host notice;
            # redirect it to $null so it does not bleed into the return value.
            Get-SafeName $Raw 6>$null | Should -Be $Expected
        }

        It 'accepts already-safe name unchanged' {
            Get-SafeName 'work' 6>$null | Should -Be 'work'
        }

        It 'accepts names that only prefix-match a reserved device name' {
            Get-SafeName 'CONCERT' 6>$null | Should -Be 'CONCERT'
            Get-SafeName 'COM10'   6>$null | Should -Be 'COM10'
            Get-SafeName 'LPT0'    6>$null | Should -Be 'LPT0'
        }
    }

    Context 'Get-ProfileEncoding' {
        It '<Case>' -ForEach @(
            @{ Case = 'UTF-8 BOM';    Bytes = [byte[]](0xEF,0xBB,0xBF,0x61); Expected = 'utf8BOM' }
            @{ Case = 'UTF-16 LE';    Bytes = [byte[]](0xFF,0xFE,0x61,0x00); Expected = 'unicode' }
            @{ Case = 'UTF-16 BE';    Bytes = [byte[]](0xFE,0xFF,0x00,0x61); Expected = 'bigendianunicode' }
            @{ Case = 'no BOM';       Bytes = [byte[]](0x61,0x62,0x63,0x64); Expected = 'utf8NoBOM' }
            @{ Case = 'short no BOM'; Bytes = [byte[]](0x61);                Expected = 'utf8NoBOM' }
        ) {
            $path = Join-Path $TestDrive 'enc.bin'
            [System.IO.File]::WriteAllBytes($path, $Bytes)
            Get-ProfileEncoding $path | Should -Be $Expected
        }

        It 'returns utf8NoBOM when file does not exist' {
            $missing = Join-Path $TestDrive 'does-not-exist.ps1'
            Get-ProfileEncoding $missing | Should -Be 'utf8NoBOM'
        }
    }

    Context 'Get-Slots' {
        # Regression: a slot file whose literal name contains [ or ] must be
        # hashed correctly during the auto-migration path in Read-ScaState
        # (which runs when no state file exists yet). Before the -LiteralPath
        # fix, Get-FileHash -Path wildcard-expanded the path and silently
        # mis-identified which slot was active (or threw).
        It 'marks a literal bracket slot as active when its hash matches .credentials.json' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'fooa'     -Content 'A'  | Out-Null
            New-SlotPair -CredDir $credDir -Name 'foo[bar]' -Content 'BR' | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.json') -Value 'BR' -NoNewline

            $active = @(Get-Slots | Where-Object { $_.IsActive })

            $active.Count    | Should -Be 1
            $active[0].Name  | Should -Be 'foo[bar]'
        }

        # Labeled filename support: Get-Slots parses the parenthesized
        # email out of the filename and exposes it as .Email on each
        # slot object. The slot Name is the portion before the parens,
        # so the user-visible slot name stays the same whether the file
        # is labeled or not.
        It 'parses labeled filenames into (Name, Email) pairs' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'work' -Email 'alice@example.com' -Content 'W' | Out-Null
            New-SlotPair -CredDir $credDir -Name 'solo' -Content 'S' | Out-Null

            $slots = @(Get-Slots)
            $bySlotName = @{}
            foreach ($s in $slots) { $bySlotName[$s.Name] = $s }

            $bySlotName.ContainsKey('work') | Should -BeTrue
            $bySlotName['work'].Email       | Should -Be 'alice@example.com'
            $bySlotName.ContainsKey('solo') | Should -BeTrue
            $bySlotName['solo'].Email       | Should -BeNullOrEmpty
        }

        # New: verify Get-Slots filters out slots without sidecars.
        It 'hides slot files that have no sidecar (post-v2.1.0 contract)' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            # Bare slot file, no sidecar; invisible by design.
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.legacy.json') -Value 'L' -NoNewline
            # Properly paired slot; visible.
            New-SlotPair -CredDir $credDir -Name 'modern' -Content 'M' | Out-Null

            $names = @(Get-Slots | ForEach-Object Name)
            $names | Should -Be @('modern')
            $names | Should -Not -Contain 'legacy'
        }

        # New: sidecar files themselves must not be enumerated as slots.
        It 'does not enumerate .account.json sidecar files as slot credentials' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'work' -Content 'W' | Out-Null

            $names = @(Get-Slots | ForEach-Object Name)
            $names | Should -Be @('work')
            # No phantom slot whose name ends in '.account' (would mean
            # the sidecar leaked into Get-SlotFileInfo's parser).
            $names | ForEach-Object { $_ | Should -Not -Match '\.account$' }
        }
    }

    Context 'Get-SlotFileInfo' {
        # Parses a .credentials.*.json filename into a (Name, Email)
        # tuple. The grammar is:
        #   .credentials.<slot>.json                -> unlabeled
        #   .credentials.<slot>(<email>).json       -> labeled; the parens
        #                                              must contain '@' to
        #                                              be treated as an email
        # NOTE: The hashtable key is deliberately `SlotName`, not `Name`.
        # The script-under-test declares a top-level `[String] $Name`
        # parameter; dot-sourcing binds that into script scope, and a
        # hashtable key named `Name` would shadow it inside the `It`
        # block (same class of issue the `Get-SafeName` suite flags for
        # `Input` with `Raw`).
        It '<Case>' -ForEach @(
            @{ Case = 'unlabeled plain slot';           File = '.credentials.work.json';                                 SlotName = 'work';                  Email = $null }
            @{ Case = 'labeled: simple email';          File = '.credentials.work(alice@example.com).json';              SlotName = 'work';                  Email = 'alice@example.com' }
            @{ Case = 'labeled: dotted local-part';     File = '.credentials.work(ada.lovelace@arpa.net).json';         SlotName = 'work';                  Email = 'ada.lovelace@arpa.net' }
            @{ Case = 'dotted slot name + labeled';     File = '.credentials.work.backup(alice@example.com).json';       SlotName = 'work.backup';           Email = 'alice@example.com' }
            @{ Case = 'slot name is an email';          File = '.credentials.ada.lovelace@arpa.net.json';               SlotName = 'ada.lovelace@arpa.net'; Email = $null }
            @{ Case = 'dotted slot name, unlabeled';    File = '.credentials.work.backup.json';                          SlotName = 'work.backup';           Email = $null }
            @{ Case = 'parens without @ in name';       File = '.credentials.work(v2).json';                             SlotName = 'work(v2)';              Email = $null }
            @{ Case = 'slot is email + paren email';    File = '.credentials.alice@work.com(alice@personal.com).json';   SlotName = 'alice@work.com';        Email = 'alice@personal.com' }
        ) {
            $parsed = Get-SlotFileInfo -FileName $File
            $parsed.Name  | Should -Be $SlotName
            if ($null -eq $Email) {
                $parsed.Email | Should -BeNullOrEmpty
            } else {
                $parsed.Email | Should -Be $Email
            }
        }

        It 'returns $null for filenames that do not match the .credentials.*.json convention' {
            Get-SlotFileInfo -FileName 'not-credentials.json' | Should -BeNullOrEmpty
            Get-SlotFileInfo -FileName '.credentials.json'    | Should -BeNullOrEmpty
        }
    }

    Context 'Show-Help' {
        It 'prints the ACTIONS header and lists the slot/operation actions' {
            $out = Show-Help 6>&1 | Out-String

            $out | Should -Match 'ACTIONS'
            $out | Should -Match 'save <name>'
            $out | Should -Match 'switch \[name\]'
            $out | Should -Match 'list'
            $out | Should -Match 'remove <name>'
            $out | Should -Match 'usage \[name\]'
            $out | Should -Match 'monitor'
            $out | Should -Match 'warmup \[name\]'
            $out | Should -Match 'install'
            $out | Should -Match 'uninstall'
        }

        It 'documents the monitor options (-Threshold / -KeepWarm)' {
            $out = Show-Help 6>&1 | Out-String
            $out | Should -Match 'OPTIONS'
            $out | Should -Match '-Threshold'
            $out | Should -Match '-KeepWarm'
        }

        It 'documents the -NoColor option under the GLOBAL options group' {
            $out = Show-Help 6>&1 | Out-String
            $out | Should -Match 'GLOBAL'
            $out | Should -Match '-NoColor'
        }

        # Help moved -h / -Help into the GLOBAL options group (no standalone
        # 'help' action line in the displayed help).
        It 'documents -h / -Help in the options instead of an ACTIONS entry' {
            $out = Show-Help 6>&1 | Out-String
            $out | Should -Match '-h, -Help'
        }

        # Help is written with the canonical 'sca' invocation (matching every
        # other user-facing message in the script), not a conditional path.
        It 'shows the sca invocation in USAGE' {
            $out = Show-Help 6>&1 | Out-String
            $out | Should -Match 'sca <action>'
        }

        It 'groups the actions under MANAGEMENT and OPERATIONS' {
            $out = Show-Help 6>&1 | Out-String
            $out | Should -Match 'MANAGEMENT'
            $out | Should -Match 'OPERATIONS'
        }

        It 'documents the -Version option' {
            $out = Show-Help 6>&1 | Out-String
            $out | Should -Match '-Version'
        }
    }

    Context '-Version flag' {
        # Verifies the Invoke-Main short-circuit that prints
        # $Script:ScriptVersion and returns before any action body runs.
        # Same dynamic-scope pattern as the 'No-color mode' context: assign
        # Param() variables in the It body, call Invoke-Main, capture
        # information stream 6.
        #
        # Each test also asserts the printed output matches the literal
        # version shape (\d+\.\d+\.\d+). The shape pin is non-negotiable:
        # the Param() block declares [switch] $Version, which previously
        # shadowed the $Script:Version constant. Under that collision, both
        # sides of `Should -Be $Script:ScriptVersion` could silently degrade
        # to the same boolean and the equality assertion would still pass.
        # The regex makes that failure mode impossible to miss.

        It 'prints $Script:ScriptVersion and returns before any action runs' {
            # We do NOT assign $Action; setting it to '' or $null in dynamic
            # scope re-triggers the [ValidateSet] on the script's Param()
            # ($Action has no '' member). Letting Invoke-Main read the
            # parameter's bind-time default exercises the empty-Action path.
            $Version = $true
            $out = (Invoke-Main 6>&1 | Out-String).Trim()
            $out | Should -Be $Script:ScriptVersion
            $out | Should -Match '^\d+\.\d+\.\d+$'
        }

        It 'wins over -Help when both are bound' {
            $Version = $true
            $Help    = $true
            $out = (Invoke-Main 6>&1 | Out-String).Trim()
            $out | Should -Be $Script:ScriptVersion
            $out | Should -Match '^\d+\.\d+\.\d+$'
            $out | Should -Not -Match 'ACTIONS'
        }

        It 'wins over a positional Action (does not dispatch the action)' {
            Mock Invoke-UsageAction { throw 'should not be called' }
            $Version = $true
            $Action  = 'usage'
            $out = (Invoke-Main 6>&1 | Out-String).Trim()
            $out | Should -Be $Script:ScriptVersion
            $out | Should -Match '^\d+\.\d+\.\d+$'
            Should -Invoke Invoke-UsageAction -Times 0
        }

        # Inversion guard: forgetting to bump $Script:ScriptVersion when
        # adding a release section to CHANGELOG.md is exactly the failure
        # mode this constant exists to prevent. Cross-check at test time so
        # CI rejects the bad commit before tag creation.
        It 'matches the most recent CHANGELOG.md release header' {
            $repoRoot  = Resolve-Path (Join-Path $PSScriptRoot '..')
            $changelog = Get-Content -LiteralPath (Join-Path $repoRoot 'CHANGELOG.md') -Raw
            $m = [regex]::Match($changelog, '##\s+\[(\d+\.\d+\.\d+)\]\s+-\s+\d{4}-\d{2}-\d{2}')
            $m.Success           | Should -BeTrue
            $Script:ScriptVersion | Should -Be $m.Groups[1].Value
        }
    }

    Context 'monitor dispatch and flag-misuse guards' {
        # Invoke-Main routes the `monitor` action to Invoke-MonitorAction and
        # rejects the switch flags that belong to the other live verb
        # (-Watch / -Json on monitor; -KeepWarm anywhere but monitor). Same
        # dynamic-scope pattern as the '-Version flag' context: assign the
        # Param() variables in the It body and let Invoke-Main read them.

        It 'routes the monitor action to Invoke-MonitorAction' {
            Mock Invoke-MonitorAction { }
            $Action = 'monitor'
            Invoke-Main
            Should -Invoke Invoke-MonitorAction -Times 1 -Exactly
        }

        It 'rejects -Watch on monitor with a pointer to usage -Watch' {
            $Action = 'monitor'
            $Watch  = $true
            { Invoke-Main 6>$null } | Should -Throw -ExpectedMessage "*sca usage -Watch*"
        }

        It 'rejects -Json on monitor' {
            $Action = 'monitor'
            $Json   = $true
            { Invoke-Main 6>$null } | Should -Throw -ExpectedMessage "*monitor*"
        }

        It 'rejects -KeepWarm on a non-monitor action' {
            Mock Invoke-UsageAction { }
            $Action   = 'usage'
            $KeepWarm  = $true
            { Invoke-Main 6>$null } | Should -Throw -ExpectedMessage "*-KeepWarm applies only*"
            Should -Invoke Invoke-UsageAction -Times 0
        }
    }

    Context 'Format-WatchTitle' {
        # Pure string-builder for the OSC 0 watch-mode terminal title.
        # The title carries the active slot's two utilization numbers +
        # brand suffix, optionally prefixed with '[!]' (any bucket >=
        # UtilLimitPct) or '[~]' (any bucket >= UtilWarnPct). Source
        # row is the active slot (IsActive=true) by default, or the
        # -Name match when -Name is set. These tests pin the format
        # string, the active-slot selection rule, and the prefix tier
        # thresholds so a future refactor cannot silently re-introduce
        # pool-mean averaging or drop the alarm prefix.

        # Build a minimal Get-UsageSnapshot-shaped object for a list of
        # rows. Each row hashtable accepts: Name, Status, IsActive,
        # FiveUtil, SevenUtil (any field omitted defaults to slot-x /
        # ok / $false / null / null).
        function script:New-FakeSnapshot {
            Param ([object[]] $Rows)
            $results = foreach ($r in $Rows) {
                $five  = if ($r.ContainsKey('FiveUtil'))  { $r.FiveUtil }  else { $null }
                $seven = if ($r.ContainsKey('SevenUtil')) { $r.SevenUtil } else { $null }
                [pscustomobject]@{
                    Name     = if ($r.ContainsKey('Name'))     { $r.Name }              else { 'slot-x' }
                    Status   = if ($r.ContainsKey('Status'))   { $r.Status }            else { 'ok' }
                    IsActive = if ($r.ContainsKey('IsActive')) { [bool]$r.IsActive }    else { $false }
                    Email    = $null
                    Data     = if ($null -eq $five -and $null -eq $seven) {
                                   $null
                               } else {
                                   [pscustomobject]@{
                                       five_hour = if ($null -ne $five)  { [pscustomobject]@{ utilization = $five  } } else { $null }
                                       seven_day = if ($null -ne $seven) { [pscustomobject]@{ utilization = $seven } } else { $null }
                                   }
                               }
                    Error            = $null
                    IsCachedFallback = $false
                }
            }
            return [pscustomobject]@{
                Results          = @($results)
                NoSlots          = $false
            }
        }

        # --- Source row selection -------------------------------------

        It 'renders the active slot in multi-slot watch (no -Name)' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 10; SevenUtil = 20 }
                @{ Name = 'b'; FiveUtil = 50; SevenUtil = 60; IsActive = $true }
                @{ Name = 'c'; FiveUtil = 80; SevenUtil = 70 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '50% | 60% | Switch Claude Account'
        }

        It '-Name overrides IsActive (renders named slot regardless of which is active)' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 10; SevenUtil = 20; IsActive = $true }
                @{ Name = 'b'; FiveUtil = 70; SevenUtil = 80 }
            )
            Format-WatchTitle -Name 'b' -Snapshot $snap |
                Should -Be '70% | 80% | Switch Claude Account'
        }

        It 'falls back to bare suffix when no row is active and -Name unset' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 10; SevenUtil = 20 }
                @{ Name = 'b'; FiveUtil = 30; SevenUtil = 40 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        It 'falls back to bare suffix when -Name does not match any row' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 10; SevenUtil = 20; IsActive = $true }
            )
            Format-WatchTitle -Name 'nonexistent' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        # --- Number rendering -----------------------------------------

        It 'renders both buckets present' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 34; SevenUtil = 42; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '34% | 42% | Switch Claude Account'
        }

        It 'rounds fractional utilization to nearest integer' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 33.6; SevenUtil = 41.4; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '34% | 41% | Switch Claude Account'
        }

        It 'renders em-dash for null buckets (mixed null)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = 42; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '— | 42% | Switch Claude Account'
        }

        It 'renders em-dashes when both buckets null (active row, no usable utilization)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = $null; IsActive = $true })
            # Distinguishes "active row exists but cold" from "no usable
            # row at all" (the latter collapses to bare suffix).
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '— | — | Switch Claude Account'
        }

        # --- Bare-suffix fallbacks ------------------------------------

        It 'returns bare suffix for empty snapshot (no slots saved)' {
            $empty = [pscustomobject]@{ Results = @(); NoSlots = $true }
            Format-WatchTitle -Name '' -Snapshot $empty |
                Should -Be 'Switch Claude Account'
        }

        # Distinct from the NoSlots=true case above: the snapshot was
        # built successfully (NoSlots=false), but its Results array is
        # empty. Defensive branch in Format-WatchTitle; reachable in
        # principle if Get-UsageSnapshot is ever changed to seed the
        # shape before populating rows.
        It 'returns bare suffix when Results is empty but NoSlots is false' {
            $empty = [pscustomobject]@{ Results = @(); NoSlots = $false }
            Format-WatchTitle -Name '' -Snapshot $empty |
                Should -Be 'Switch Claude Account'
        }

        It 'returns bare suffix when all rows are HTTP-failure with no data (active row included)' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = 'expired'; IsActive = $true }
                @{ Name = 'b'; Status = 'error'   }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        It 'returns bare suffix when the active row is <Status> with no data' -ForEach @(
            @{ Status = 'expired'      }
            @{ Status = 'unauthorized' }
            @{ Status = 'error'        }
            @{ Status = 'no-oauth'     }
            @{ Status = 'rate-limited' }
        ) {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = $Status; IsActive = $true }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        # The title is judged on the same predicate as the aggregate bars
        # (Test-RowIsMeasurable), not on Status: a row served from the cache
        # fallback paints numbers in the table and still counts toward
        # rotation, so blanking the title for it dropped the alarm signal
        # during exactly the failure the fallback exists to survive.
        It 'renders the numbers of a non-ok active row that carries data: <Status>' -ForEach @(
            @{ Status = 'rate-limited' }
            @{ Status = 'error'        }
        ) {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = $Status; FiveUtil = 50; SevenUtil = 50; IsActive = $true }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '50% | 50% | Switch Claude Account'
        }

        It 'still fires the alarm prefix for a cached at-limit active row' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = 'error'; FiveUtil = 100; SevenUtil = 20; IsActive = $true }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 100% | 20% | Switch Claude Account'
        }

        It 'returns bare suffix when -Name matches a row that is not ok and has no data' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = 'expired' }
            )
            Format-WatchTitle -Name 'a' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        It 'ignores non-active rows (does not pool-mean across slots)' {
            # Regression guard: a previous version pool-meaned across all
            # HTTP-ok rows, which averaged a burned slot's 100% down to
            # noise in multi-slot watches. The new contract reads the
            # active slot's numbers directly.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 100; SevenUtil = 100 }
                @{ Name = 'b'; FiveUtil = 10;  SevenUtil = 10; IsActive = $true }
                @{ Name = 'c'; FiveUtil = 100; SevenUtil = 100 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '10% | 10% | Switch Claude Account'
        }

        # --- [!] / [~] alarm prefix tiers -----------------------------

        It 'prepends [!] when 5h bucket is at UtilLimitPct (100)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 100; SevenUtil = 50; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 100% | 50% | Switch Claude Account'
        }

        It 'prepends [!] when 7d bucket is at UtilLimitPct (100)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 50; SevenUtil = 100; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 50% | 100% | Switch Claude Account'
        }

        It 'prepends [!] when both buckets are at UtilLimitPct' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 100; SevenUtil = 100; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 100% | 100% | Switch Claude Account'
        }

        It '[!] wins over [~] when one bucket is at limit and the other near' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 100; SevenUtil = 95; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 100% | 95% | Switch Claude Account'
        }

        It 'prepends [~] when 5h bucket is at exactly UtilWarnPct (90)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 90; SevenUtil = 50; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[~] 90% | 50% | Switch Claude Account'
        }

        It 'prepends [~] when 7d bucket is at UtilWarnPct (above default)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 50; SevenUtil = 92; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[~] 50% | 92% | Switch Claude Account'
        }

        It 'no prefix when both buckets are just below UtilWarnPct (89)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 89; SevenUtil = 89; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '89% | 89% | Switch Claude Account'
        }

        It 'no prefix when both buckets are well below UtilWarnPct' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 30; SevenUtil = 40; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '30% | 40% | Switch Claude Account'
        }

        It 'null buckets do not trigger any prefix' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = $null; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '— | — | Switch Claude Account'
        }

        It 'one bucket null + the other at limit still fires [!]' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = 100; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] — | 100% | Switch Claude Account'
        }

        # --- Defense-in-depth -----------------------------------------

        It 'strips control bytes from the assembled title' {
            # Slot names already pass Get-SafeName, but the strip is
            # defense-in-depth against an OSC envelope breakout via a
            # tampered sidecar email or future caller path.
            $rows  = @([pscustomobject]@{
                Name = "x`e]0;EVIL`a"; Status = 'ok'; IsActive = $true; Email = $null
                Data = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 10 }
                    seven_day = [pscustomobject]@{ utilization = 20 }
                }
                Error = $null; IsCachedFallback = $false
            })
            $snap = [pscustomobject]@{ Results = $rows; NoSlots = $false }
            $title = Format-WatchTitle -Name '' -Snapshot $snap
            $title | Should -Not -Match "`e"
            $title | Should -Not -Match "`a"
            $title | Should -Be '10% | 20% | Switch Claude Account'
        }

        # --- -Aggregate mode (wired to -Auto by Invoke-UsageWatch) ----
        # In aggregate mode both percentages are the pool mean across
        # HTTP-ok rows, alarm thresholds swap to
        # $Script:AggregateRedPct (90) / $Script:AggregateYellowPct (50),
        # and -Name is ignored. The pool-mean math itself is tested
        # under Get-PoolMeanUtilization in Invoke-UsageAction.Tests.ps1;
        # these tests pin the rendering behavior on top of it.

        It '-Aggregate renders pool mean across all HTTP-ok rows (active flag ignored)' {
            # Regression contrast: without -Aggregate the same snapshot
            # renders the active row (10% | 10%, see "ignores non-active
            # rows" test above). With -Aggregate it averages all three:
            # 5h mean = (100+10+100)/3 = 70, 7d mean = (100+10+100)/3 = 70.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 100; SevenUtil = 100 }
                @{ Name = 'b'; FiveUtil = 10;  SevenUtil = 10; IsActive = $true }
                @{ Name = 'c'; FiveUtil = 100; SevenUtil = 100 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 70% | 70% | Switch Claude Account'
        }

        It '-Aggregate excludes HTTP-failure rows with no data from the mean' {
            # 2 ok rows + 1 expired. Mean = (40+60)/2 = 50. An 'expired' row
            # never carries Data in production (Get-SlotUsage's expired arm has
            # nothing to attach), so omitting the utilizations is the shape
            # that arm actually produces.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 40; SevenUtil = 40 }
                @{ Name = 'b'; FiveUtil = 60; SevenUtil = 60; IsActive = $true }
                @{ Name = 'c'; Status = 'expired' }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 50% | 50% | Switch Claude Account'
        }

        It '-Aggregate counts a non-ok row that carries cached data' {
            # The cache-fallback ladder produces 'error' / 'rate-limited' rows
            # carrying last-known percentages. Format-UsageTable prints those
            # numbers and Get-RowMaxUtilization rotates on them, so the pool
            # mean has to see them too or the bars contradict the table right
            # beneath them. Mean = (40+100)/2 = 70.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 40;  SevenUtil = 40; IsActive = $true }
                @{ Name = 'b'; Status = 'error'; FiveUtil = 100; SevenUtil = 100 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 70% | 70% | Switch Claude Account'
        }

        It '-Aggregate counts null buckets as 0 (denominator stays N)' {
            # 2 ok rows, one with null five_hour. 5h mean = (0+60)/2 = 30
            # (NOT 60, which would be N-1).
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = $null; SevenUtil = 20; IsActive = $true }
                @{ Name = 'b'; FiveUtil = 60;    SevenUtil = 20 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '30% | 20% | Switch Claude Account'
        }

        It '-Aggregate ignores -Name (aggregation is pool-wide by definition)' {
            # The non-aggregate test "renders the active slot" pins that
            # -Name='b' overrides IsActive. Under -Aggregate, -Name has
            # no effect: output equals the no-Name aggregate.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 20; SevenUtil = 20 }
                @{ Name = 'b'; FiveUtil = 80; SevenUtil = 80; IsActive = $true }
            )
            $noName   = Format-WatchTitle -Name ''  -Snapshot $snap -Aggregate
            $withName = Format-WatchTitle -Name 'b' -Snapshot $snap -Aggregate
            $withName | Should -Be $noName
            $noName   | Should -Be '[~] 50% | 50% | Switch Claude Account'
        }

        It '-Aggregate returns bare suffix when no row carries usable data' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = 'expired'; IsActive = $true }
                @{ Name = 'b'; Status = 'error' }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be 'Switch Claude Account'
        }

        It '-Aggregate returns bare suffix for empty snapshot' {
            $empty = [pscustomobject]@{ Results = @(); NoSlots = $true }
            Format-WatchTitle -Name '' -Snapshot $empty -Aggregate |
                Should -Be 'Switch Claude Account'
        }

        # Alarm prefix tier swap: AggregateYellowPct (50) / AggregateRedPct (90).

        It '-Aggregate prepends [!] when pool mean is at AggregateRedPct (90)' {
            # Single row at 90/50 -> pool mean = 90/50.
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 90; SevenUtil = 50; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[!] 90% | 50% | Switch Claude Account'
        }

        It '-Aggregate prepends [~] when pool mean is at AggregateYellowPct (50)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 50; SevenUtil = 49; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 50% | 49% | Switch Claude Account'
        }

        It '-Aggregate no prefix when pool mean is below AggregateYellowPct (49)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 49; SevenUtil = 49; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '49% | 49% | Switch Claude Account'
        }

        It '-Aggregate [!] wins over [~] when one bucket is at Red and the other at Yellow' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 90; SevenUtil = 50; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[!] 90% | 50% | Switch Claude Account'
        }

        It '-Aggregate does NOT fire on per-slot UtilWarnPct (default-mode threshold) below AggregateYellowPct' {
            # Default mode at 30/40 with active=true would render no prefix.
            # Aggregate mode at the same row (N=1) also renders no prefix
            # because both buckets are below AggregateYellowPct (50). This
            # test is the inverse-axis check: confirm the threshold pair
            # actually swapped, not just that the default thresholds got
            # left in.
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 89; SevenUtil = 89; IsActive = $true })
            # Default mode -> 89/89 is below UtilWarnPct (90), no prefix.
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '89% | 89% | Switch Claude Account'
            # Aggregate mode -> 89 is at/above AggregateYellowPct (50), [~]
            # prefix fires. Pins the threshold swap.
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 89% | 89% | Switch Claude Account'
        }
    }

    Context 'Watch-mode VT control rendering' {
        # Regression guard for `sca usage -Watch -NoColor` flicker.
        #
        # Background: -NoColor sets $PSStyle.OutputRendering='PlainText',
        # which routes every Write-Host string through PowerShell's
        # StringDecorated.AnsiRegex filter. That regex matches DEC private
        # modes (\x1b\[\?\d+[hl]) and strips them -- so when watch-mode
        # VT controls (DEC 2026 sync envelope, alt-buffer toggle, cursor
        # hide/show) go through Write-Host, the entire flicker-free
        # rendering envelope vanishes and -Watch -NoColor flickers.
        #
        # Fix: Write-VTSequence uses [Console]::Out.Write which bypasses
        # StringDecorated entirely. Two assertions pin the contract:
        # one static (no Write-Host VT escapes in Invoke-UsageWatch),
        # one behavioral (Write-VTSequence preserves DEC modes verbatim).

        It 'Invoke-UsageWatch routes all VT control sequences through Write-VTSequence (no Write-Host VT escapes)' {
            # AST-based static check: pin the call sites without a brittle
            # line-range. A future accidental `Write-Host "`e[?...h"`
            # reintroduction in the watch loop fails this test.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-UsageWatch'
            }, $true) | Select-Object -First 1

            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-UsageWatch must exist'

            $bodyLines = $func.Extent.Text -split "`r?`n"
            $offending = @($bodyLines | Where-Object {
                $_ -match '\bWrite-Host\b' -and $_ -match '`e\['
            })
            $offending.Count | Should -Be 0 -Because (
                'VT control sequences in the watch lifecycle must go through ' +
                'Write-VTSequence (which uses [Console]::Out.Write to bypass ' +
                'StringDecorated.AnsiRegex). Routing them through Write-Host ' +
                're-enables PSStyle.OutputRendering=PlainText stripping of DEC ' +
                'private modes, which causes -Watch -NoColor to flicker.')
        }

        It 'Invoke-UsageWatch emits an OSC 0 title set inside the loop and restores the captured title in finally' {
            # Pin the contract that watch mode (a) updates the terminal
            # title on each successful poll and (b) restores the
            # pre-watch title on exit. The static check guards against
            # accidental removal during a future refactor; without
            # title-set the background-window UX regresses, without
            # title-restore the watch leaks its title into the user's
            # post-Ctrl-C shell session.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-UsageWatch'
            }, $true) | Select-Object -First 1
            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-UsageWatch must exist'

            $body = $func.Extent.Text

            # OSC 0 sequence: ESC ] 0 ; <title> BEL. Match the literal
            # `e]0; opener; the renderer interpolation and BEL terminator
            # vary across edits but the opener is invariant.
            $body | Should -Match '`e\]0;' -Because (
                'Invoke-UsageWatch must emit an OSC 0 (\e]0;<title>\a) ' +
                'sequence so the terminal-title shows live usage when ' +
                'the watch window is in the background.')

            # The captured pre-watch title must be restored on exit.
            $body | Should -Match '\$origTitle' -Because (
                'Invoke-UsageWatch must capture and restore the pre-watch ' +
                'terminal title; without restore the watch-mode title ' +
                'persists into the user post-Ctrl-C shell session.')
        }

        It 'Write-VTSequence preserves DEC 2026 envelope verbatim under OutputRendering=PlainText' {
            # Two-part contract check, scoped to the exact sequence the
            # fix depends on (DEC 2026 sync-envelope opener). Broader
            # assertions across all DEC modes would over-couple to
            # PowerShell's internal StringDecorated regex.

            # Part 1: confirm StringDecorated DOES strip the envelope
            # under PlainText (the regression hazard). Common.ps1 already
            # sets OutputRendering=PlainText for the test session.
            # The class lives in System.Management.Automation.Internal
            # (public class, internal-namespaced) and is the same filter
            # PowerShell's host UI applies to every Write-Host string.
            $sd = [System.Management.Automation.Internal.StringDecorated]::new("`e[?2026h")
            $sd.ToString() | Should -BeNullOrEmpty -Because (
                'StringDecorated.AnsiRegex strips DEC private modes under ' +
                'PlainText; this is why VT control sequences must NOT go ' +
                'through Write-Host in -Watch -NoColor mode.')

            # Part 2: confirm Write-VTSequence does NOT go through that
            # filter. Capture by swapping Console.Out for a StringWriter.
            # The finally restores Console.Out BEFORE Pester's assertion
            # output, so the test harness is unaffected.
            $origOut = [Console]::Out
            $sw      = [System.IO.StringWriter]::new()
            try {
                [Console]::SetOut($sw)
                Write-VTSequence "`e[?2026h"
            } finally {
                [Console]::SetOut($origOut)
            }
            $sw.ToString() | Should -Be "`e[?2026h" -Because (
                'Write-VTSequence must preserve DEC private modes verbatim ' +
                'regardless of OutputRendering; otherwise -Watch -NoColor ' +
                'loses its DEC 2026 sync envelope and flickers.')
        }

        It 'Invoke-UsageWatch suppresses the information stream on every nested action whose advisories would flash on screen' {
            # AST-based static check for the sub-frame flash bug:
            #
            # The polling loop calls three things inside its `if ($dueForPoll)`
            # branch that may emit Write-Color advisories on their unhappy
            # paths:
            #   1. Invoke-Reconcile        -> [Sync] auto-save / identity-change
            #   2. Get-UsageSnapshot       -> [Sync] token-propagation-failed
            #                                  / sidecar-orphaned (via
            #                                  Update-SlotTokens inside
            #                                  Get-SlotUsage)
            #   3. Invoke-AutoRotationStep -> [Switch] ~/.claude.json write
            #                                  failed (via Invoke-SlotSwap
            #                                  inside its 'rotate' arm; the
            #                                  inner site already wraps the
            #                                  swap in 6>$null)
            #
            # All three print straight to the alt buffer, OUTSIDE the
            # captured frame; without 6>$null suppression the in-place
            # repaint (no ESC[2J) never overwrites them and the user is
            # left with a stray advisory line they cannot dismiss. The
            # outer-most call sites for #1 and #2 must therefore carry
            # 6>$null; #3's inner site is asserted separately by the
            # Invoke-AutoRotationStep tests.
            #
            # Static check rather than behavioral because Invoke-UsageWatch
            # is an infinite loop and hard to drive in a unit test.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-UsageWatch'
            }, $true) | Select-Object -First 1
            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-UsageWatch must exist'

            # Walk the AST for actual CommandAst nodes (function calls)
            # rather than regex-scanning the function body. Regex on
            # body text matches comment mentions like
            # `# (matches Get-UsageSnapshot).` which are not invocations
            # and would produce false positives. CommandAst.GetCommandName()
            # returns the bound command name for real invocations only.
            $allCommands = $func.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst]
            }, $true)

            $reconcileInvocations = @($allCommands | Where-Object {
                $_.GetCommandName() -eq 'Invoke-Reconcile'
            })
            $reconcileInvocations.Count | Should -BeGreaterOrEqual 1 -Because (
                'watch loop reconciles before reading slot bytes; expected at least one invocation')

            foreach ($cmd in $reconcileInvocations) {
                # CommandAst's Parent walks up to the enclosing pipeline;
                # the redirection `6>$null` is held on the PipelineAst's
                # Redirections collection. We pull the pipeline that
                # immediately contains the command and check for the
                # information-stream redirection.
                $pipeline = $cmd.Parent
                $pipeline | Should -BeOfType ([System.Management.Automation.Language.PipelineAst]) -Because (
                    'every command sits inside a pipeline in PowerShell AST')

                $hasInfoSuppression = $pipeline.PipelineElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandAst] -and
                    $_.GetCommandName() -eq 'Invoke-Reconcile'
                } | ForEach-Object {
                    @($_.Redirections | Where-Object {
                        $_ -is [System.Management.Automation.Language.MergingRedirectionAst] -or
                        $_ -is [System.Management.Automation.Language.FileRedirectionAst]
                    } | Where-Object {
                        # FromStream = Information (stream 6), redirected
                        # to $null. PowerShell models `6>$null` as a
                        # FileRedirectionAst with FromStream=Information
                        # and Location='$null' (variable).
                        $_.FromStream -eq [System.Management.Automation.Language.RedirectionStream]::Information
                    }).Count -gt 0
                }
                $hasInfoSuppression | Should -BeTrue -Because (
                    'every Invoke-Reconcile inside Invoke-UsageWatch must ' +
                    'suppress information stream (6>$null); without it the ' +
                    "[Sync] auto-save / identity-change advisories print " +
                    'to the alt buffer outside the captured frame, where ' +
                    'the in-place repaint (no ESC[2J) never clears them.')
            }

            $snapshotInvocations = @($allCommands | Where-Object {
                $_.GetCommandName() -eq 'Get-UsageSnapshot'
            })
            $snapshotInvocations.Count | Should -BeGreaterOrEqual 1 -Because (
                'watch loop must poll usage data; expected at least one invocation')

            foreach ($cmd in $snapshotInvocations) {
                $pipeline = $cmd.Parent
                $hasInfoSuppression = $pipeline.PipelineElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandAst] -and
                    $_.GetCommandName() -eq 'Get-UsageSnapshot'
                } | ForEach-Object {
                    @($_.Redirections | Where-Object {
                        $_ -is [System.Management.Automation.Language.FileRedirectionAst] -and
                        $_.FromStream -eq [System.Management.Automation.Language.RedirectionStream]::Information
                    }).Count -gt 0
                }
                $hasInfoSuppression | Should -BeTrue -Because (
                    'every Get-UsageSnapshot inside Invoke-UsageWatch must ' +
                    'suppress information stream (6>$null); Update-SlotTokens ' +
                    "(called via Get-SlotUsage) writes [Sync] yellow advisories " +
                    'on its two unhappy paths and those would print to the ' +
                    'alt buffer outside the captured frame, lingering past ' +
                    'the in-place repaint (no ESC[2J clears them).')
            }
        }

        It 'every function calling Invoke-RestMethod sets $ProgressPreference = SilentlyContinue' {
            # Regression guard for the PowerShell built-in 'Web request'
            # progress activity (Write-Progress / stream 4) flashing
            # between watch frames.
            #
            # Background: Invoke-WebRequest / Invoke-RestMethod emit a
            # progress activity by default with rotating status messages
            # ("Waiting for response...", "Reading web response (NNN
            # bytes)"). The host UI paints this directly to the alt
            # buffer, bypassing the DEC 2026 byte-stream sync envelope
            # around each watch frame. Without function-scoped
            # $ProgressPreference = 'SilentlyContinue', it flashes for
            # the duration of every HTTP call inside the watch loop's
            # hot path.
            #
            # Fix: each function that calls Invoke-RestMethod sets
            # $ProgressPreference = 'SilentlyContinue' at the top of
            # its body. PowerShell's preference-variable scope chain
            # masks the parent value for the function's duration only;
            # no try/finally needed.
            #
            # Generalized contract (vs. naming the three current
            # functions explicitly): every function whose body contains
            # an Invoke-RestMethod call must suppress the progress
            # activity. A future maintainer who adds a fourth HTTP-
            # calling function will fail this test until they include
            # the suppression line.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)

            $allFuncs = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)

            # Filter to functions that actually invoke a web cmdlet in
            # their body. Word-boundary match avoids false positives on
            # docstring mentions like 'Invoke-RestMethod' in a comment;
            # the comment-only case would still be a false positive,
            # but commented-out HTTP calls inside a function are a
            # pathological case not worth defending against.
            $httpFuncs = @($allFuncs | Where-Object {
                $_.Extent.Text -match '\bInvoke-RestMethod\b'
            })
            $httpFuncs.Count | Should -BeGreaterOrEqual 1 -Because (
                'the script must contain at least one HTTP-calling function ' +
                '(Update-SlotTokens / Get-SlotUsage / Get-SlotProfile)')

            foreach ($fn in $httpFuncs) {
                $fn.Extent.Text | Should -Match (
                    "\`$ProgressPreference\s*=\s*'SilentlyContinue'") -Because (
                    "function '$($fn.Name)' calls Invoke-RestMethod and " +
                    "must set `$ProgressPreference = 'SilentlyContinue' " +
                    "(function-scoped) so PowerShell's built-in 'Web " +
                    "request' progress activity does not flash in the " +
                    'alt buffer between watch frames.')
            }
        }

        It 'Invoke-AutoRotationStep suppresses Invoke-SlotSwap information stream' {
            # Sibling assertion to the Invoke-UsageWatch suppression
            # check above: the rotate arm of Invoke-AutoRotationStep calls
            # Invoke-SlotSwap, which can emit [Switch] yellow advisories
            # when ~/.claude.json's oauthAccount update fails. Auto-mode
            # owns its own footer line; the inner advisory would flash
            # sub-frame on every rotation failure.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-AutoRotationStep'
            }, $true) | Select-Object -First 1
            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-AutoRotationStep must exist'

            $body = $func.Extent.Text
            $swapCalls = [regex]::Matches($body, 'Invoke-SlotSwap[^\r\n]*')
            $swapCalls.Count | Should -BeGreaterOrEqual 1 -Because 'rotate arm must swap'
            foreach ($m in $swapCalls) {
                $m.Value | Should -Match '6>\$null' -Because (
                    'Invoke-SlotSwap inside Invoke-AutoRotationStep must ' +
                    'suppress information stream; the [Switch] advisory ' +
                    'on ~/.claude.json write failure would print outside ' +
                    'the captured frame and linger past the in-place repaint.')
            }
        }

        It 'Invoke-KeepWarmStep suppresses Invoke-WarmAllSlots information stream' {
            # Sibling assertion to the Invoke-AutoRotationStep check above:
            # the re-warm arm of Invoke-KeepWarmStep calls Invoke-WarmAllSlots,
            # whose nested Invoke-SlotSwap / Invoke-Reconcile / Get-SlotUsage
            # emit yellow advisories (e.g. [Warmup] restore-failure, [Sync]
            # token-propagation). Keep-warm owns its own footer line; the
            # inner advisory would print outside the captured frame and
            # linger past the in-place repaint (no ESC[2J clears it).
            #
            # Walk CommandAst nodes (real invocations) rather than regexing
            # the body text, so a comment mentioning Invoke-WarmAllSlots is
            # not mistaken for a call site missing its 6>$null.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-KeepWarmStep'
            }, $true) | Select-Object -First 1
            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-KeepWarmStep must exist'

            $warmInvocations = @($func.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst]
            }, $true) | Where-Object { $_.GetCommandName() -eq 'Invoke-WarmAllSlots' })
            $warmInvocations.Count | Should -BeGreaterOrEqual 1 -Because 're-warm arm must call Invoke-WarmAllSlots'

            foreach ($cmd in $warmInvocations) {
                $hasInfoSuppression = @($cmd.Redirections | Where-Object {
                    $_ -is [System.Management.Automation.Language.FileRedirectionAst] -and
                    $_.FromStream -eq [System.Management.Automation.Language.RedirectionStream]::Information
                }).Count -gt 0
                $hasInfoSuppression | Should -BeTrue -Because (
                    'Invoke-WarmAllSlots inside Invoke-KeepWarmStep must ' +
                    'suppress information stream (6>$null); its nested ' +
                    'advisories would print outside the captured frame and ' +
                    'linger past the in-place repaint (no ESC[2J).')
            }
        }

        It 'Invoke-UsageWatch stamps $lastPoll after the poll, never from the pre-poll $now' {
            # The loop is an infinite Start-Sleep loop and cannot be driven
            # directly, so this guards the shape instead. $lastPoll = $now uses
            # the timestamp captured BEFORE the HTTP work, which pre-credits the
            # interval with the poll's own duration: a poll slower than
            # -Interval then makes the next iteration due immediately and the
            # loop polls back-to-back with no delay, hammering an endpoint whose
            # limiter trips after a handful of calls in a few seconds.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-UsageWatch'
            }, $true) | Select-Object -First 1
            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-UsageWatch must exist'

            $assignments = @($func.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$lastPoll'
            }, $true))
            $assignments.Count | Should -BeGreaterOrEqual 1

            foreach ($a in $assignments) {
                $a.Right.Extent.Text | Should -Not -Be '$now' -Because (
                    'the poll interval must be measured from when the poll ' +
                    'finished, not from the timestamp captured before it ran')
            }
        }
    }

    Context 'Watch-mode frame capture and in-place repaint' {
        # Unit coverage for the two helpers that make the watch loop's
        # single-write, no-clear repaint work (the flicker fix): the loop is
        # an infinite Start-Sleep loop and stays untested, but these helpers
        # are pure enough to drive directly.

        It 'ConvertTo-WatchFrameSequence homes the cursor and ends with erase-below' {
            $seq = ConvertTo-WatchFrameSequence "line1`nline2"
            $seq.StartsWith("`e[H")  | Should -BeTrue -Because 'frame must re-home, not scroll'
            $seq.EndsWith("`e[0J")   | Should -BeTrue -Because 'trailing erase-below drops rows left by a taller previous frame'
        }

        It 'ConvertTo-WatchFrameSequence never full-clears (no ESC[2J)' {
            # The core of the flicker fix: a clear-then-redraw blanks to black
            # and -- when DEC 2026 is unavailable or the machine is loaded --
            # the user sees "black -> row for row". In-place overwrite must
            # never emit ESC[2J.
            $seq = ConvertTo-WatchFrameSequence "a`nb`nc"
            $seq.Contains("`e[2J") | Should -BeFalse
        }

        It 'ConvertTo-WatchFrameSequence appends one ESC[K (erase-to-EOL) per line' {
            # Per-line erase-to-EOL is what lets a line that shrank between
            # frames overwrite its stale tail in place without a full clear.
            $seq = ConvertTo-WatchFrameSequence "aaa`nbbb`nccc"
            ([regex]::Matches($seq, [regex]::Escape("`e[K"))).Count |
                Should -Be 3
        }

        It 'ConvertTo-WatchFrameSequence tolerates empty input' {
            ConvertTo-WatchFrameSequence '' | Should -Be "`e[H`e[K`e[0J"
        }

        It 'Get-WatchFrameText keeps a -NoNewline segment chain on one line' {
            # The -Auto header is built from several `Write-* -NoNewline`
            # segments plus a terminating newline; the capture must rejoin
            # them as a single line, not split per segment.
            Get-WatchFrameText { Write-Host 'A' -NoNewline; Write-Host 'B' } |
                Should -Be "AB`n"
            Get-WatchFrameText { Write-Host 'A'; Write-Host 'B' } |
                Should -Be "A`nB`n"
        }

        It 'Get-WatchFrameText strips SGR under OutputRendering=PlainText (-NoColor)' {
            # Common.ps1 sets PlainText for the session. The captured
            # .Message carries raw SGR that [Console]::Out.Write would not
            # strip, so Get-WatchFrameText must drop it itself in PlainText.
            $text = Get-WatchFrameText { Write-Color 'X' 'Red' }
            $text | Should -Be "X`n"
            $text.Contains("`e[") | Should -BeFalse
        }

        It 'Get-WatchFrameText preserves SGR when OutputRendering is not PlainText' {
            $prev = $PSStyle.OutputRendering
            try {
                $PSStyle.OutputRendering = 'Ansi'
                $text = Get-WatchFrameText { Write-Color 'X' 'Red' }
                $text.Contains("`e[") | Should -BeTrue -Because 'color frames keep their SGR for [Console]::Out.Write'
            } finally {
                $PSStyle.OutputRendering = $prev
            }
        }

        It 'Get-WatchFrameText round-trips a stray non-Write-Host success object as text' {
            # Defensive branch: a renderer that leaks a pipeline object must
            # not crash the capture (no .MessageData on a bare string).
            $text = Get-WatchFrameText { 'leaked'; Write-Host 'B' }
            $text | Should -Be "leaked`nB`n"
        }

        It 'Invoke-UsageWatch never full-clears the screen (no ESC[2J literal)' {
            # AST guard for the flicker fix: a future edit that reintroduces
            # a clear-then-redraw fails here. Prose mentions of "ESC[2J" use
            # the spelled-out form, so the backtick-e literal match ignores
            # them.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-UsageWatch'
            }, $true) | Select-Object -First 1
            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-UsageWatch must exist'
            $func.Extent.Text | Should -Not -Match '`e\[2J' -Because (
                'the watch repaints in place (home + per-line ESC[K + trailing ' +
                'ESC[0J); an ESC[2J reintroduces the black -> row-by-row flash.')
        }

        It 'Invoke-UsageWatch forces UTF-8 console output encoding and restores it (glyph regression)' {
            # Regression guard: the frame body is painted via [Console]::Out
            # .Write, which encodes through [Console]::OutputEncoding. On a
            # legacy OEM codepage (e.g. CP850) the bar / play / ellipsis
            # glyphs become '?'. The watch must force UTF-8 and restore the
            # original on exit.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-UsageWatch'
            }, $true) | Select-Object -First 1
            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-UsageWatch must exist'
            $body = $func.Extent.Text
            $body | Should -Match 'OutputEncoding\s*=\s*\[System\.Text\.UTF8Encoding\]' -Because (
                'frame glyphs degrade to "?" unless [Console]::Out writes UTF-8')
            $body | Should -Match '\$origEncoding' -Because (
                'the pre-watch console encoding must be captured and restored on exit')
        }
    }

    Context 'No-color mode' {
        # Verifies the $PSStyle.OutputRendering toggle wired into Invoke-Main.
        # The toggle is the production no-color mechanism: every colored
        # call site goes through `Write-Color` which emits inline ANSI SGR
        # codes; PowerShell's WriteImpl -> GetOutputString filter then
        # strips those SGR codes when OutputRendering=PlainText. So the
        # only thing these tests need to verify is that the toggle is
        # set during dispatch and restored on exit.
        #
        # Common.ps1 sets $PSStyle.OutputRendering='PlainText' globally
        # for tests so existing string-match assertions work against
        # ANSI-stripped output. The tests here override that to 'Host'
        # in their bodies so the toggle test can distinguish "toggled to
        # PlainText" from "was PlainText all along," then restore via
        # try/finally so subsequent tests see the BeforeEach baseline.
        #
        # We mock Invoke-ListAction so the action body becomes a single
        # capture line that records $PSStyle.OutputRendering DURING
        # dispatch. Pester 5's dynamic scoping makes the in-It $NoColor
        # / $Action assignments visible to Invoke-Main (which is defined
        # at the dot-sourced script scope and reads its parameters via
        # the parent scope chain).
        BeforeEach {
            $script:capturedRendering = $null
            Mock Invoke-ListAction { $script:capturedRendering = $PSStyle.OutputRendering }
            # Defensive: ensure NO_COLOR is unset at the start of every
            # test so leakage from a prior test (e.g. the env-var case)
            # does not bleed through.
            if (Test-Path Env:\NO_COLOR) { Remove-Item Env:\NO_COLOR }
        }

        It 'sets OutputRendering=PlainText during dispatch when -NoColor is bound, and restores on exit' {
            $PSStyle.OutputRendering = 'Host'
            try {
                $NoColor = $true
                $Action  = 'list'

                Invoke-Main

                $script:capturedRendering | Should -Be 'PlainText'
                $PSStyle.OutputRendering  | Should -Be 'Host'
            }
            finally {
                $PSStyle.OutputRendering = 'PlainText'
            }
        }

        It 'sets OutputRendering=PlainText during dispatch when $env:NO_COLOR is set, and restores on exit' {
            $PSStyle.OutputRendering = 'Host'
            $env:NO_COLOR = '1'
            try {
                $Action = 'list'
                Invoke-Main

                $script:capturedRendering | Should -Be 'PlainText'
                $PSStyle.OutputRendering  | Should -Be 'Host'
            }
            finally {
                Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue
                $PSStyle.OutputRendering = 'PlainText'
            }
        }

        It 'leaves OutputRendering untouched when neither -NoColor nor $env:NO_COLOR is set' {
            $PSStyle.OutputRendering = 'Host'
            try {
                $Action = 'list'

                Invoke-Main

                $script:capturedRendering | Should -Be 'Host'
                $PSStyle.OutputRendering  | Should -Be 'Host'
            }
            finally {
                $PSStyle.OutputRendering = 'PlainText'
            }
        }
    }

    Context 'ConvertTo-ScaJsonString' {
        # Note: the function's `if ($null -eq $Value) { return 'null' }`
        # branch is defensive-dead. PowerShell binds $null to a [string]
        # parameter as '', so external callers cannot exercise it; the
        # one internal caller in Set-OAuthAccountInClaudeJson short-
        # circuits before calling. We do NOT test that branch.

        It 'escapes embedded double-quotes, backslashes, and control characters' {
            ConvertTo-ScaJsonString -Value 'a "b" \ c' | Should -Be '"a \"b\" \\ c"'
            ConvertTo-ScaJsonString -Value "line1`nline2`tend" | Should -Be '"line1\nline2\tend"'
        }

        It 'wraps a plain string in double quotes' {
            ConvertTo-ScaJsonString -Value 'hello' | Should -Be '"hello"'
        }

        It 'returns an empty JSON string for empty input (binding null collapses to "")' {
            ConvertTo-ScaJsonString -Value '' | Should -Be '""'
        }
    }

    Context 'ConvertTo-DateTimeOffsetOrNull' {
        It 'returns $null for null and empty input' {
            ConvertTo-DateTimeOffsetOrNull -Value $null | Should -BeNullOrEmpty
            ConvertTo-DateTimeOffsetOrNull -Value ''    | Should -BeNullOrEmpty
        }

        It 'returns $null for unparseable strings rather than throwing' {
            ConvertTo-DateTimeOffsetOrNull -Value 'not-a-date' | Should -BeNullOrEmpty
        }

        It 'returns the value unchanged for a DateTimeOffset input' {
            $dto = [DateTimeOffset]::new(2026, 4, 26, 12, 0, 0, [TimeSpan]::Zero)
            (ConvertTo-DateTimeOffsetOrNull -Value $dto) | Should -Be $dto
        }

        It 'casts a [DateTime] input to [DateTimeOffset]' {
            # The local time zone is environment-dependent, so we only
            # assert the cast succeeded and the type is correct.
            $dt = [DateTime]::new(2026, 4, 26, 12, 0, 0, [DateTimeKind]::Utc)
            $r = ConvertTo-DateTimeOffsetOrNull -Value $dt
            $r | Should -BeOfType ([DateTimeOffset])
        }

        It 'parses an ISO-8601 string' {
            $iso = '2026-04-26T12:00:00.000Z'
            $r = ConvertTo-DateTimeOffsetOrNull -Value $iso
            $r | Should -BeOfType ([DateTimeOffset])
            $r.UtcDateTime | Should -Be ([DateTime]::new(2026, 4, 26, 12, 0, 0, [DateTimeKind]::Utc))
        }
    }

    Context 'Format-UtilCell / Format-Truncate / Format-AccountCell / Format-BucketCell' {
        # Direct unit tests for the pure cell-formatters; closes a
        # coverage gap previously left by exercising them only through
        # full Invoke-UsageAction renders.

        It 'Format-UtilCell renders em-dash for $null utilization' {
            (Format-UtilCell -Utilization $null) | Should -Be '   —'
        }

        It 'Format-UtilCell renders a right-justified integer percent' {
            (Format-UtilCell -Utilization 7)    | Should -Be '  7%'
            (Format-UtilCell -Utilization 99.4) | Should -Be ' 99%'
        }

        It 'Format-Truncate returns em-dash for $null / empty input' {
            (Format-Truncate -Text $null -Max 32) | Should -Be '—'
            (Format-Truncate -Text ''   -Max 32)  | Should -Be '—'
        }

        It 'Format-Truncate returns a single ellipsis when -Max is 1' {
            (Format-Truncate -Text 'abcdef' -Max 1) | Should -Be '…'
        }

        It 'Format-Truncate leaves a fitting string unchanged' {
            (Format-Truncate -Text 'short' -Max 32) | Should -Be 'short'
        }

        It 'Format-Truncate middle-truncates with the ellipsis between head and tail' {
            $r = Format-Truncate -Text 'one.two.three.four.five.six.seven.eight' -Max 12
            $r.Length | Should -Be 12
            $r       | Should -Match '…'
        }

        It 'Format-AccountCell returns em-dash for null / empty email' {
            (Format-AccountCell -SlotName 'work' -Email $null) | Should -Be '—'
            (Format-AccountCell -SlotName 'work' -Email '')    | Should -Be '—'
        }

        It 'Format-AccountCell returns em-dash when slot name equals email (case-insensitive dedup)' {
            (Format-AccountCell -SlotName 'alice@example.com' -Email 'alice@example.com') | Should -Be '—'
            (Format-AccountCell -SlotName 'Alice@Example.Com' -Email 'alice@example.com') | Should -Be '—'
        }

        It 'Format-AccountCell returns the email when slot name differs' {
            (Format-AccountCell -SlotName 'work' -Email 'alice@example.com') | Should -Be 'alice@example.com'
        }

        It 'Format-BucketCell renders em-dash for null utilization' {
            (Format-BucketCell -Utilization $null -ResetsAt $null) | Should -Be '   —'
        }

        It 'Format-BucketCell renders only the percent when ResetsAt is null / empty' {
            (Format-BucketCell -Utilization 9 -ResetsAt $null) | Should -Be '  9%'
            (Format-BucketCell -Utilization 9 -ResetsAt '')    | Should -Be '  9%'
        }

        It 'Format-BucketCell renders "percent (delta)" when ResetsAt is set' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2).AddMinutes(14).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            (Format-BucketCell -Utilization 31 -ResetsAt $future) | Should -Match '^ 31% \(2h 1[34]m\)$'
        }
    }

    Context 'Get-StatusColor (uncovered branches)' {
        It 'returns DarkGray for the no-oauth label' {
            (Get-StatusColor -Label 'no-oauth' -IsActive $false) | Should -Be 'DarkGray'
        }

        It 'returns Yellow for the rate-limited label' {
            (Get-StatusColor -Label 'rate-limited' -IsActive $false) | Should -Be 'Yellow'
        }

        It 'returns Gray for unknown labels (default arm)' {
            (Get-StatusColor -Label 'something-new' -IsActive $false) | Should -Be 'Gray'
            (Get-StatusColor -Label ''             -IsActive $false) | Should -Be 'Gray'
        }
    }

    Context 'Get-StatusRationale' {
        It '<Case>' -ForEach @(
            @{ Case = 'limited 5h';        Label = 'limited 5h';        Expected = 'no prompts until 5h window resets' }
            @{ Case = 'limited 7d';        Label = 'limited 7d';        Expected = 'no prompts until 7d window resets' }
            @{ Case = 'limited (both)';    Label = 'limited';           Expected = 'no prompts until both 5h and 7d windows reset' }
            @{ Case = 'ok (no plan data)'; Label = 'ok (no plan data)'; Expected = 'HTTP ok but response carried no bucket data' }
            # Hard-failure statuses. Keyed on the raw Status value, because
            # Format-UsageAdvisory's reason lines are where these remedies
            # render now that the Status column carries only a bare label.
            @{ Case = 'expired';           Label = 'expired';           Expected = 'token refresh failed; run sca switch, then /login if it persists' }
            @{ Case = 'unauthorized';      Label = 'unauthorized';      Expected = 'token revoked; run sca switch then /login' }
            @{ Case = 'no-oauth';          Label = 'no-oauth';          Expected = 'api key or non-claude.ai slot' }
        ) {
            (Get-StatusRationale -Label $Label) | Should -Be $Expected
        }

        It "returns Script:UtilWarnPct-templated rationale for 'near limit'" {
            $out = Get-StatusRationale -Label 'near limit'
            $out | Should -Match '^at or above \d+%'
            $out | Should -Match 'at least one bucket$'
        }

        It 'returns $null for labels with no rationale' {
            (Get-StatusRationale -Label 'ok')    | Should -BeNullOrEmpty
            # 'error' and 'rate-limited' stay absent on purpose: such a row
            # carries a real message, which the advisory prints instead of a
            # canned remedy.
            (Get-StatusRationale -Label 'error')        | Should -BeNullOrEmpty
            (Get-StatusRationale -Label 'rate-limited') | Should -BeNullOrEmpty
            (Get-StatusRationale -Label '')      | Should -BeNullOrEmpty
        }
    }

    Context 'Format-SlotNameList' {
        It 'returns $null for an empty or all-blank list' {
            (Format-SlotNameList -Names @())            | Should -BeNullOrEmpty
            (Format-SlotNameList -Names @($null, ''))   | Should -BeNullOrEmpty
        }

        It 'single-quotes and comma-joins up to 3 names' {
            (Format-SlotNameList -Names @('a'))           | Should -Be "'a'"
            (Format-SlotNameList -Names @('a','b'))       | Should -Be "'a', 'b'"
            (Format-SlotNameList -Names @('a','b','c'))   | Should -Be "'a', 'b', 'c'"
        }

        It 'collapses past 3 names to the "and N more" form' {
            (Format-SlotNameList -Names @('a','b','c','d'))         | Should -Be "'a', 'b', 'c' and 1 more"
            (Format-SlotNameList -Names @('a','b','c','d','e'))     | Should -Be "'a', 'b', 'c' and 2 more"
        }
    }

    Context 'Format-UsageAdvisory' {
        BeforeAll {
            # Rows only. The advisory partitions Results itself, so there is
            # no snapshot-level condition flag for a fixture to set (and a
            # fixture that set one would let a regression pass by satisfying
            # the flag instead of the rows).
            function New-RlSnapshot {
                Param ($Results)
                [pscustomobject]@{
                    Results = @($Results); NoSlots = $false; HasRateLimited = $false
                }
            }
            function New-RlRow {
                Param (
                    [string] $Name,
                    [string] $Status = 'rate-limited',
                    [bool]   $Cached = $false,
                    [string] $Reason = 'rate-limit',
                    # A throttled row that HAS numbers was read successfully at
                    # some point, which is what separates the "rate-limited or
                    # at a plan limit" condition from the unverified one.
                    [switch] $WithData
                )
                $fallbackReason = if ($Cached) { $Reason } else { $null }
                $data = if ($WithData) {
                    [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 12.0 }; seven_day = $null }
                } else { $null }
                [pscustomobject]@{
                    Name             = $Name
                    Status           = $Status
                    IsCachedFallback = $Cached
                    FallbackReason   = $fallbackReason
                    Data             = $data
                    Error            = $null
                    Email            = $null
                    IsActive         = $false
                }
            }
        }

        It 'returns $null when every row read cleanly' {
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'a' -Status 'ok'))
            Format-UsageAdvisory -Snapshot $snap | Should -BeNullOrEmpty
        }

        It 'returns $null for a null snapshot' {
            Format-UsageAdvisory -Snapshot $null | Should -BeNullOrEmpty
        }

        It 'returns $null for an empty Results set' {
            Format-UsageAdvisory -Snapshot (New-RlSnapshot -Results @()) |
                Should -BeNullOrEmpty
        }

        It 'no-cache, one slot: names it with "is" and no last-known clause' {
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'slot-1' -WithData))
            Format-UsageAdvisory -Snapshot $snap |
                Should -Be "[Usage] 'slot-1' is currently rate-limited or at a plan limit."
        }

        It 'no-cache, multiple slots: names them with "are"' {
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'slot-1' -WithData), (New-RlRow -Name 'slot-3' -WithData))
            Format-UsageAdvisory -Snapshot $snap |
                Should -Be "[Usage] 'slot-1', 'slot-3' are currently rate-limited or at a plan limit."
        }

        It 'no-cache, >3 slots: collapses to "and N more" with plural verb' {
            $rows = @('a','b','c','d') | ForEach-Object { New-RlRow -Name $_ -WithData }
            $snap = New-RlSnapshot -Results $rows
            Format-UsageAdvisory -Snapshot $snap |
                Should -Be "[Usage] 'a', 'b', 'c' and 1 more are currently rate-limited or at a plan limit."
        }

        # sca's own token request can be refused before the server looks at the
        # grant, so a throttled row it has never read could equally be a revoked
        # login. Claiming the former sent the user off to wait out something
        # that never clears.
        It 'throttled row it has never read: names the check instead of guessing' {
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'slot-1'))
            $out  = Format-UsageAdvisory -Snapshot $snap
            $out | Should -Be "[Usage] 'slot-1' could not be read, and sca cannot tell a throttle from an expired login; run 'sca warmup <slot>' to check."
            $out | Should -Not -Match 'currently rate-limited or at a plan limit'
        }

        It 'cache branch: names the cached slot and adds the last-known clause' {
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'cached' -Cached $true))
            Format-UsageAdvisory -Snapshot $snap |
                Should -Be "[Usage] 'cached' is currently rate-limited or at a plan limit; showing last known usage."
        }

        # The cache branch used to win outright, so a hard failure could
        # hide behind a "showing last known usage" note. Both conditions now get
        # their own line and no row is named twice.
        It 'emits one line per condition instead of letting the cache branch win' {
            $rows = @(
                (New-RlRow -Name 'cached'  -Cached $true),
                (New-RlRow -Name 'nocache' -Cached $false)
            )
            $snap  = New-RlSnapshot -Results $rows
            $lines = @((Format-UsageAdvisory -Snapshot $snap) -split "`n")

            $lines.Count | Should -Be 2
            ($lines -join "`n") | Should -Match "'cached'"
            ($lines -join "`n") | Should -Match "'nocache'"
            @($lines | Where-Object { $_ -match 'showing last known usage' }).Count | Should -Be 1
        }

        It 'words a network fallback as a failed live read, not a rate limit' {
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'slot-1' -Status 'error' -Cached $true -Reason 'network'))
            $out  = Format-UsageAdvisory -Snapshot $snap
            $out | Should -Be "[Usage] 'slot-1' could not be read live; showing last known usage."
            $out | Should -Not -Match 'rate-limited'
        }

        It 'names a hard error row with no cached data' {
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'slot-1' -Status 'error'))
            Format-UsageAdvisory -Snapshot $snap |
                Should -Be "[Usage] 'slot-1' could not be read; usage unknown."
        }

        It 'reports a cached row once, under its fallback line only' {
            # A stale network fallback carries Status='error' AND
            # IsCachedFallback, so it matches two buckets by status alone.
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'slot-1' -Status 'error' -Cached $true -Reason 'network'))
            $lines = @((Format-UsageAdvisory -Snapshot $snap) -split "`n")
            $lines.Count | Should -Be 1
            $lines[0]    | Should -Match 'showing last known usage'
        }

        It 'orders no-data failures above cache fallbacks' {
            $rows = @(
                (New-RlRow -Name 'cached' -Status 'error' -Cached $true -Reason 'network'),
                (New-RlRow -Name 'dead'   -Status 'error')
            )
            $snap  = New-RlSnapshot -Results $rows
            $lines = @((Format-UsageAdvisory -Snapshot $snap) -split "`n")
            $lines[0] | Should -Match "'dead'"
            $lines[1] | Should -Match "'cached'"
        }

        It 'treats a cached row with no FallbackReason as a rate limit' {
            # The backoff short-circuit in Get-SlotUsage builds its result
            # inline; older callers/fixtures carry no reason at all.
            $row = [pscustomobject]@{ Name = 'slot-1'; Status = 'rate-limited'; IsCachedFallback = $true
                Data = $null; Error = $null; Email = $null; IsActive = $false }
            $snap = New-RlSnapshot -Results @($row)
            Format-UsageAdvisory -Snapshot $snap | Should -Match 'rate-limited or at a plan limit; showing last known usage'
        }

        # --- per-slot reason lines ---
        #
        # The Status column carries only a short label, so the detail it used
        # to inline (a 60-char exception tail, cut mid-word) lands here.

        It "prints the row's own message as its reason line" {
            $row  = New-RlRow -Name 'slot-1' -Status 'error'
            $row.Error = 'The operation has timed out.'
            $snap  = New-RlSnapshot -Results @($row)
            $lines = @((Format-UsageAdvisory -Snapshot $snap) -split "`n")

            $lines.Count | Should -Be 2
            $lines[0]    | Should -Match 'could not be read'
            $lines[1]    | Should -Be '[Usage] slot-1: The operation has timed out.'
        }

        It 'collapses a multi-line message onto one reason line and bounds its length' {
            $row  = New-RlRow -Name 'slot-1' -Status 'error'
            $row.Error = "first line`r`nsecond line " + ('X' * ($Script:AdvisoryReasonMaxWidth * 2))
            $snap  = New-RlSnapshot -Results @($row)
            $lines = @((Format-UsageAdvisory -Snapshot $snap) -split "`n")

            $lines.Count | Should -Be 2
            $lines[1] | Should -Match '^\[Usage\] slot-1: first line second line X+\.\.\.$'
            $lines[1].Length | Should -BeLessThan ($Script:AdvisoryReasonMaxWidth + 30)
        }

        It 'falls back to the canned remedy for a hard failure with no message: <Case>' -ForEach @(
            @{ Case = 'expired';      Status = 'expired';      Expected = 'token refresh failed; run sca switch, then /login if it persists' }
            @{ Case = 'unauthorized'; Status = 'unauthorized'; Expected = 'token revoked; run sca switch then /login' }
            @{ Case = 'no-oauth';     Status = 'no-oauth';     Expected = 'api key or non-claude.ai slot' }
        ) {
            $snap = New-RlSnapshot -Results @((New-RlRow -Name 'slot-1' -Status $Status))
            # These statuses match no condition bucket, so the reason line is
            # the whole advisory.
            Format-UsageAdvisory -Snapshot $snap | Should -Be "[Usage] 'slot-1': $Expected"
        }

        # A remedy is a per-status constant, so repeating it once per slot said
        # nothing new and burned the shared 3-line cap on identical text.
        It 'names every slot sharing a remedy on one line' {
            $rows = @('a','b') | ForEach-Object { New-RlRow -Name $_ -Status 'no-oauth' }
            $snap = New-RlSnapshot -Results $rows

            Format-UsageAdvisory -Snapshot $snap |
                Should -Be "[Usage] 'a', 'b': api key or non-claude.ai slot"
        }

        It 'groups per status, worst first, not into one combined line' {
            $rows = @(
                (New-RlRow -Name 'a' -Status 'no-oauth'),
                (New-RlRow -Name 'b' -Status 'expired'),
                (New-RlRow -Name 'c' -Status 'no-oauth')
            )
            $lines = @((Format-UsageAdvisory -Snapshot (New-RlSnapshot -Results $rows)) -split "`n")

            $lines.Count | Should -Be 2
            # Fixed worst-first status order, matching the condition lines
            # above, rather than whichever status the caller listed first.
            $lines[0] | Should -Be "[Usage] 'b': token refresh failed; run sca switch, then /login if it persists"
            $lines[1] | Should -Be "[Usage] 'a', 'c': api key or non-claude.ai slot"
        }

        It 'stays silent for a rate-limited row with no message (the condition line already says it)' {
            $snap  = New-RlSnapshot -Results @((New-RlRow -Name 'slot-1' -WithData))
            $lines = @((Format-UsageAdvisory -Snapshot $snap) -split "`n")
            $lines.Count | Should -Be 1
            $lines[0]    | Should -Match 'currently rate-limited or at a plan limit'
        }

        It 'caps the reason block at 3 lines so a wide failing pool cannot push the table off screen' {
            $rows = @('a','b','c','d','e') | ForEach-Object {
                $r = New-RlRow -Name $_ -Status 'error'
                $r.Error = "boom $_"
                $r
            }
            $snap  = New-RlSnapshot -Results $rows
            $lines = @((Format-UsageAdvisory -Snapshot $snap) -split "`n")

            # 1 condition line + 3 reason lines.
            $lines.Count | Should -Be 4
            @($lines | Where-Object { $_ -match '^\[Usage\] \w: boom' }).Count | Should -Be 3
            # The condition line still accounts for every affected slot.
            $lines[0] | Should -Match "and 2 more"
        }

        # The fresh-cache path is the commonest transient failure there is (a
        # cache under the TTL), and it used to arrive with its message stripped:
        # the frame said "showing last known usage" and nothing anywhere said
        # why, on the one row still painting numbers.
        It 'explains a fresh cache fallback, which keeps its ok status' {
            $row = New-RlRow -Name 'blip' -Status 'ok' -Cached $true -Reason 'network'
            $row.Error = 'The operation has timed out.'
            $lines = @((Format-UsageAdvisory -Snapshot (New-RlSnapshot -Results @($row))) -split "`n")

            $lines.Count | Should -Be 2
            $lines[0]    | Should -Be "[Usage] 'blip' could not be read live; showing last known usage."
            $lines[1]    | Should -Be '[Usage] blip: The operation has timed out.'
        }

        # Cached rows still have their numbers on screen, so they are the least
        # urgent thing in the block. Unsorted they could take the whole cap from
        # rows that have nothing left to show.
        It 'gives the 3-message cap to hard failures before cache fallbacks' {
            $rows = @()
            foreach ($n in @('cached-1', 'cached-2', 'cached-3')) {
                $r = New-RlRow -Name $n -Status 'ok' -Cached $true -Reason 'network'
                $r.Error = "blip $n"
                $rows += $r
            }
            foreach ($n in @('dead-1', 'dead-2')) {
                $r = New-RlRow -Name $n -Status 'error'
                $r.Error = "boom $n"
                $rows += $r
            }
            $lines = @((Format-UsageAdvisory -Snapshot (New-RlSnapshot -Results $rows)) -split "`n")

            @($lines | Where-Object { $_ -match 'boom ' }).Count | Should -Be 2
            @($lines | Where-Object { $_ -match 'blip ' }).Count | Should -Be 1
        }

        It 'reports both the transport errors and the grouped remedy' {
            # A row-ordered shared cap emitted three 'no-oauth' notices (a
            # permanent config fact) and dropped both transport errors.
            $rows = @(
                (New-RlRow -Name 'a-apikey' -Status 'no-oauth'),
                (New-RlRow -Name 'b-apikey' -Status 'no-oauth'),
                (New-RlRow -Name 'c-apikey' -Status 'no-oauth')
            )
            foreach ($n in @('y-dead', 'z-dead')) {
                $r = New-RlRow -Name $n -Status 'error'
                $r.Error = "boom $n"
                $rows += $r
            }
            $snap  = New-RlSnapshot -Results $rows
            $lines = @((Format-UsageAdvisory -Snapshot $snap) -split "`n")

            # 1 condition line (errors only; no-oauth matches no bucket)
            # + 1 grouped remedy + 2 messages. Remedies precede the per-slot
            # messages because they are the group that must survive
            # $Script:AdvisoryMaxLines; see Format-UsageAdvisory.
            $lines.Count | Should -Be 4
            $lines[1] | Should -Be "[Usage] 'a-apikey', 'b-apikey', 'c-apikey': api key or non-claude.ai slot"
            $lines[2] | Should -Be '[Usage] y-dead: boom y-dead'
            $lines[3] | Should -Be '[Usage] z-dead: boom z-dead'
        }

        # Every production path that yields 'expired' stamps an Error
        # (Resolve-SlotAccessToken, Invoke-SlotActivator), so a remedy pass
        # keyed on "carries no message" never fired for it, and the message
        # cap could then drop the slot's only line. 'expired' has no condition
        # line, so that left nothing on screen at all.
        It 'falls back to the remedy for an expired slot whose message the cap dropped' {
            $rows = @('a-dead','b-dead','c-dead') | ForEach-Object {
                $r = New-RlRow -Name $_ -Status 'error'
                $r.Error = "boom $_"
                $r
            }
            $late = New-RlRow -Name 'z-expired' -Status 'expired'
            $late.Error = 'refresh returned 400'
            $rows += $late

            $lines = @((Format-UsageAdvisory -Snapshot (New-RlSnapshot -Results $rows)) -split "`n")

            # 1 condition line + 1 grouped remedy + 3 capped messages.
            $lines.Count | Should -Be 5
            @($lines | Where-Object { $_ -match 'z-expired' }).Count | Should -Be 1
            $lines[1] | Should -Be "[Usage] 'z-expired': token refresh failed; run sca switch, then /login if it persists"
        }

        It 'prefers the message over the remedy when the slot fits inside the cap' {
            $row = New-RlRow -Name 'slot-1' -Status 'expired'
            $row.Error = 'refresh returned 400'

            $lines = @((Format-UsageAdvisory -Snapshot (New-RlSnapshot -Results @($row))) -split "`n")

            $lines.Count | Should -Be 1
            $lines[0]    | Should -Be '[Usage] slot-1: refresh returned 400'
        }

        # The regression the shared cap caused: 'expired' / 'unauthorized' /
        # 'no-oauth' have no condition line, so once three messages filled the
        # cap the slot the user actually has to act on vanished from the frame
        # entirely, leaving only a bare label in the Status column.
        It 'keeps the remedy visible behind a full message cap' {
            $rows = @()
            foreach ($n in @('d1','d2','d3','d4')) {
                $r = New-RlRow -Name $n -Status 'error'
                $r.Error = "boom $n"
                $rows += $r
            }
            $rows += (New-RlRow -Name 'revoked' -Status 'unauthorized')

            $lines = @((Format-UsageAdvisory -Snapshot (New-RlSnapshot -Results $rows)) -split "`n")

            # 1 condition line + the remedy + 3 capped messages.
            $lines.Count | Should -Be 5
            @($lines | Where-Object { $_ -match ': boom ' }).Count | Should -Be 3
            $lines[1] | Should -Be "[Usage] 'revoked': token revoked; run sca switch then /login"
        }

        # The block is painted inside a watch frame addressed with ESC[H plus
        # per-line erase, which stops being in-place the moment the frame is
        # taller than the terminal. Ten lines of advisory, several wrapping at
        # $Script:AdvisoryReasonMaxWidth, is enough to push the table off a
        # 24-row screen on its own.
        It 'never exceeds AdvisoryMaxLines, and drops only per-slot detail' {
            # Five distinct conditions (one slot each) so every condition line
            # fires, plus three hard-failure statuses for three remedies, plus
            # enough messages to overflow.
            $rows = @()
            $e = New-RlRow -Name 'bare-err' -Status 'error';        $e.Error = 'boom bare-err';   $rows += $e
            $l = New-RlRow -Name 'bare-lim' -Status 'rate-limited' -WithData; $rows += $l
            $u = New-RlRow -Name 'unverif'  -Status 'rate-limited'; $rows += $u
            $n = New-RlRow -Name 'cach-net' -Status 'error';        $n.Error = 'boom cach-net'
            $n.IsCachedFallback = $true; $n.FallbackReason = 'network';  $rows += $n
            $c = New-RlRow -Name 'cach-lim' -Status 'rate-limited'
            $c.IsCachedFallback = $true; $c.FallbackReason = 'rate-limit'; $rows += $c
            $x = New-RlRow -Name 'gone-exp' -Status 'expired';      $x.Error = 'boom gone-exp'; $rows += $x
            $rows += (New-RlRow -Name 'gone-401' -Status 'unauthorized')
            $rows += (New-RlRow -Name 'gone-key' -Status 'no-oauth')

            $lines = @((Format-UsageAdvisory -Snapshot (New-RlSnapshot -Results $rows)) -split "`n")

            $lines.Count | Should -BeLessOrEqual $Script:AdvisoryMaxLines

            # Coverage survives the cap: all five condition lines and all three
            # remedies are present, so no failing slot goes unmentioned.
            @($lines | Where-Object { $_ -match 'could not be read; usage unknown' }).Count      | Should -Be 1
            @($lines | Where-Object { $_ -match 'currently rate-limited or at a plan limit\.' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match "run 'sca warmup <slot>' to check" }).Count      | Should -Be 1
            @($lines | Where-Object { $_ -match 'could not be read live; showing last known usage' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -match 'plan limit; showing last known usage' }).Count            | Should -Be 1
            $lines | Should -Contain "[Usage] 'gone-exp': token refresh failed; run sca switch, then /login if it persists"
            $lines | Should -Contain "[Usage] 'gone-401': token revoked; run sca switch then /login"
            $lines | Should -Contain "[Usage] 'gone-key': api key or non-claude.ai slot"

            # gone-exp is the case the remedy budget is reserved for: it
            # carries a message, so a reason-first budget would drop that
            # message to the cap AND its remedy to $reported, leaving the one
            # failure class that never clears on its own with no line at all.
            @($lines | Where-Object { $_ -match 'gone-exp' }).Count | Should -Be 1
        }

        It 'ok rows never produce a reason line' {
            $row = New-RlRow -Name 'slot-1' -Status 'ok'
            $snap = New-RlSnapshot -Results @($row)
            Format-UsageAdvisory -Snapshot $snap | Should -BeNullOrEmpty
        }
    }

    Context 'Get-ConsoleWidth' {
        It 'returns a non-negative integer without throwing in a console-less host' {
            # Pester runs with no attached console, so [Console]::WindowWidth
            # throws here; the helper exists to swallow that and hand callers
            # a 0 they can branch on.
            $w = Get-ConsoleWidth
            $w | Should -BeOfType [int]
            $w | Should -BeGreaterOrEqual 0
        }
    }

    Context 'Get-EarlyRepollLastPoll' {
        It 'rewinds by (Interval - DelaySec) so the next poll fires ~DelaySec out' {
            # The watch loop polls when (now - lastPoll) >= Interval. With
            # Interval 60 / DelaySec 10 the result must sit 50s before $Now
            # so the next poll lands ~10s from $Now, not ~50s.
            $now = [DateTime]::new(2025, 1, 1, 12, 0, 0)
            $res = Get-EarlyRepollLastPoll -Now $now -Interval 60 -DelaySec 10
            ($now - $res).TotalSeconds | Should -Be 50
        }

        It 'clamps at 0 when DelaySec >= Interval so lastPoll is never pushed into the future' {
            $now = [DateTime]::new(2025, 1, 1, 12, 0, 0)
            $res = Get-EarlyRepollLastPoll -Now $now -Interval 5 -DelaySec 10
            $res | Should -Be $now
        }
    }

    Context 'Read-Sidecar' {
        # Pure-helper file-IO tests; sandbox uses $TestDrive directly to
        # avoid pulling in the full credential-dir scaffolding.
        It 'returns $null when the sidecar file is missing' {
            $slot = Join-Path $TestDrive '.credentials.missing.json'
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns $null when the sidecar JSON is corrupt' {
            $slot     = Join-Path $TestDrive '.credentials.corrupt.json'
            $sidecar  = $slot -replace '\.json$', '.account.json'
            Set-Content -LiteralPath $sidecar -Value 'not-json{' -NoNewline -Encoding utf8NoBOM
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns $null when the sidecar schema is not 1' {
            $slot    = Join-Path $TestDrive '.credentials.badschema.json'
            $sidecar = $slot -replace '\.json$', '.account.json'
            $payload = '{"schema":2,"oauthAccount":{"emailAddress":"a@b.com"}}'
            Set-Content -LiteralPath $sidecar -Value $payload -NoNewline -Encoding utf8NoBOM
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns $null when oauthAccount is missing' {
            $slot    = Join-Path $TestDrive '.credentials.nooauth.json'
            $sidecar = $slot -replace '\.json$', '.account.json'
            Set-Content -LiteralPath $sidecar -Value '{"schema":1}' -NoNewline -Encoding utf8NoBOM
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns $null when oauthAccount.emailAddress is blank' {
            $slot    = Join-Path $TestDrive '.credentials.noemail.json'
            $sidecar = $slot -replace '\.json$', '.account.json'
            $payload = '{"schema":1,"oauthAccount":{"emailAddress":""}}'
            Set-Content -LiteralPath $sidecar -Value $payload -NoNewline -Encoding utf8NoBOM
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns a parsed pscustomobject for a well-formed sidecar' {
            $slot    = Join-Path $TestDrive '.credentials.ok.json'
            $sidecar = $slot -replace '\.json$', '.account.json'
            $payload = '{"schema":1,"captured_at":"2026-04-26T00:00:00Z","source":"test","oauthAccount":{"emailAddress":"alice@example.com","accountUuid":"u1"}}'
            Set-Content -LiteralPath $sidecar -Value $payload -NoNewline -Encoding utf8NoBOM

            $obj = Read-Sidecar -SlotPath $slot
            $obj                              | Should -Not -BeNullOrEmpty
            $obj.schema                       | Should -Be 1
            $obj.oauthAccount.emailAddress    | Should -Be 'alice@example.com'
        }
    }

    Context 'Get-OAuthAccountFromClaudeJson (uncovered branches)' {
        # Tests sandbox $env:USERPROFILE per BeforeEach (Common.ps1), so
        # $ClaudeJsonPath resolves under $TestDrive automatically.
        It 'returns $null when ~/.claude.json is missing' {
            Get-OAuthAccountFromClaudeJson | Should -BeNullOrEmpty
        }

        It 'returns $null when ~/.claude.json is corrupt' {
            Set-Content -LiteralPath $ClaudeJsonPath -Value 'not-json{' -NoNewline -Encoding utf8NoBOM
            Get-OAuthAccountFromClaudeJson | Should -BeNullOrEmpty
        }

        It 'returns $null when ~/.claude.json has no oauthAccount key' {
            Set-Content -LiteralPath $ClaudeJsonPath -Value '{"numStartups":1}' -NoNewline -Encoding utf8NoBOM
            Get-OAuthAccountFromClaudeJson | Should -BeNullOrEmpty
        }

        It 'returns $null when oauthAccount.emailAddress is empty / whitespace' {
            Set-Content -LiteralPath $ClaudeJsonPath -Value '{"oauthAccount":{"emailAddress":"  "}}' -NoNewline -Encoding utf8NoBOM
            Get-OAuthAccountFromClaudeJson | Should -BeNullOrEmpty
        }

        It 'defaults missing optional fields (accountUuid, etc.) to $null' {
            # emailAddress is the only mandatory non-null field; the other
            # four are populated only when present, otherwise null.
            $payload = '{"oauthAccount":{"emailAddress":"a@b.com"}}'
            Set-Content -LiteralPath $ClaudeJsonPath -Value $payload -NoNewline -Encoding utf8NoBOM

            $r = Get-OAuthAccountFromClaudeJson
            $r                  | Should -Not -BeNullOrEmpty
            $r.emailAddress     | Should -Be 'a@b.com'
            $r.accountUuid      | Should -BeNullOrEmpty
            $r.organizationUuid | Should -BeNullOrEmpty
            $r.displayName      | Should -BeNullOrEmpty
            $r.organizationName | Should -BeNullOrEmpty
        }
    }

    Context 'Set-OAuthAccountInClaudeJson (uncovered failure modes)' {
        It 'throws when ~/.claude.json has no oauthAccount block' {
            Set-Content -LiteralPath $ClaudeJsonPath -Value '{"numStartups":1}' -NoNewline -Encoding utf8NoBOM
            $oa = [pscustomobject]@{ emailAddress = 'a@b.com' }
            { Set-OAuthAccountInClaudeJson -OAuthAccount $oa } |
                Should -Throw -ExpectedMessage '*no oauthAccount block*'
        }

        It 'throws when the oauthAccount block has unbalanced braces' {
            # Truncate the file so the brace counter walks off the end
            # without closing depth. Surfaces as 'unbalanced braces'.
            $payload = '{"oauthAccount":{ "emailAddress":"a@b.com"'
            Set-Content -LiteralPath $ClaudeJsonPath -Value $payload -NoNewline -Encoding utf8NoBOM
            $oa = [pscustomobject]@{ emailAddress = 'c@d.com' }
            { Set-OAuthAccountInClaudeJson -OAuthAccount $oa } |
                Should -Throw -ExpectedMessage '*unbalanced braces*'
        }
    }

    Context 'Get-NextSlotName (single-slot active no-op)' {
        It "prints the 'Only one slot' advisory and returns null when one active slot exists" {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'only' -Content 'X' | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.json') -Value 'X' -NoNewline

            $out = Get-NextSlotName 6>&1 | Out-String
            $out | Should -Match 'Only one slot'
            # Function writes the advisory and returns $null; capture via
            # a second call with the stream redirected.
            Get-NextSlotName 6>$null | Should -BeNullOrEmpty
        }

        It 'returns the first slot (no rotation cursor) when no slot is currently active' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'a' -Content 'A' | Out-Null
            New-SlotPair -CredDir $credDir -Name 'b' -Content 'B' | Out-Null
            # .credentials.json bytes don't match either slot -> no IsActive flag.
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.json') -Value 'UNKNOWN' -NoNewline

            $r = Get-NextSlotName 6>$null
            $r.To.Name        | Should -Be 'a'
            $r.HasActiveSlot  | Should -BeFalse
        }
    }

    Context 'Update-SlotTokens (uncovered failure modes)' {
        # Direct unit tests for Update-SlotTokens' guard clauses and
        # advisory paths. The happy path is exercised through Invoke-
        # UsageAction; here we hit the throws and the
        # propagation-to-credentials.json failure branch.

        It 'throws when the slot file has no OAuth material to refresh' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.apikey.json'
            Set-Content -LiteralPath $slot -Value '{"apiKey":"sk-ant-api..."}' -NoNewline

            { Update-SlotTokens -SlotPath $slot } |
                Should -Throw -ExpectedMessage '*no OAuth material to refresh*'
        }

        # The client always sends `scope` on a refresh:
        #   {grant_type, refresh_token, client_id, scope: w.join(" ")}
        # (claude.exe 2.1.278). Omitting it was a silent divergence from the
        # one request shape this unofficial endpoint is known to accept.
        It 'sends the slot own scopes as a space-joined scope field' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.scoped.json'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'old'
                    refreshToken = 'rt'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                    scopes       = @('user:inference', 'user:profile')
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            $script:sentBody = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:sentBody = $Body
                return [pscustomobject]@{ access_token = 'new'; expires_in = 3600 }
            }

            Update-SlotTokens -SlotPath $slot | Out-Null

            $parsed = $script:sentBody | ConvertFrom-Json
            $parsed.grant_type | Should -Be 'refresh_token'
            $parsed.scope      | Should -Be 'user:inference user:profile'
        }

        It 'omits scope entirely when the slot records none' {
            # The client substitutes a default list there; guessing it would be
            # inventing a value this script cannot verify.
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.unscoped.json'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'old'
                    refreshToken = 'rt'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            $script:sentBody2 = $null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:sentBody2 = $Body
                return [pscustomobject]@{ access_token = 'new'; expires_in = 3600 }
            }

            Update-SlotTokens -SlotPath $slot | Out-Null

            ($script:sentBody2 | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'scope'
        }

        It 'throws when refresh response is missing access_token' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.stale.json'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'old'
                    refreshToken = 'rt'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                # No access_token; expires_in only.
                return [pscustomobject]@{ expires_in = 3600 }
            }

            { Update-SlotTokens -SlotPath $slot } |
                Should -Throw -ExpectedMessage '*missing access_token*'
        }

        It 'throws when refresh response is missing expires_in' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.stale.json'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'old'
                    refreshToken = 'rt'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{ access_token = 'new' }
            }

            { Update-SlotTokens -SlotPath $slot } |
                Should -Throw -ExpectedMessage '*missing expires_in*'
        }

        It 'falls back to the old refresh token when response omits refresh_token (RFC 6749)' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.norotate.json'
            $oldRt = 'sk-ant-ort-KEEPME'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'old-at'
                    refreshToken = $oldRt
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                # access_token + expires_in but no refresh_token field.
                return [pscustomobject]@{
                    access_token = 'new-at'
                    expires_in   = 3600
                }
            }

            Update-SlotTokens -SlotPath $slot 6>$null | Out-Null

            $after = Get-Content -LiteralPath $slot -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken  | Should -Be 'new-at'
            # Old refresh token preserved per RFC 6749 fallback.
            $after.claudeAiOauth.refreshToken | Should -Be $oldRt
        }

        It 'emits a yellow advisory when propagation to .credentials.json fails' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'

            # Build a labeled slot pair with stale tokens, plus a
            # matching .credentials.json mirror, and seed state.
            $slot = New-SlotPair -CredDir $credDir -Name 'active' -Email 'a@b.com' -Content (@{
                claudeAiOauth = @{
                    accessToken  = 'OLD'
                    refreshToken = 'RT'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress)
            Copy-Item -LiteralPath $slot -Destination $credFile -Force
            $hash = (Get-FileHash -LiteralPath $credFile -Algorithm SHA256).Hash
            Update-ScaState -ActiveSlot 'active' -LastSyncHash $hash | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{ access_token = 'NEW'; refresh_token = 'NEW-RT'; expires_in = 3600 }
            }

            # Force the second atomic write (the propagation to
            # .credentials.json) to fail. The first call writes the
            # slot; the second call writes .credentials.json.
            $script:writeCount = 0
            Mock Set-CredentialFileAtomic -MockWith {
                $script:writeCount++
                if ($script:writeCount -ge 2) {
                    throw [System.IO.IOException]::new('propagation denied')
                }
                # Fall back to the real implementation for the first call
                # so the slot file actually gets updated.
                [System.IO.File]::WriteAllBytes($Path, $Bytes)
            }

            $out = Update-SlotTokens -SlotPath $slot 6>&1 | Out-String

            $out | Should -Match "Token refreshed in slot 'active'"
            $out | Should -Match 'propagation to \.credentials\.json failed'
            $out | Should -Match 'propagation denied'
        }
    }

    Context 'Update-SlotTokens (429 retry behavior)' {
        # Retry-with-backoff around /v1/oauth/token. The endpoint's
        # per-token rate limiter unlocks within seconds, so a 429
        # on the first attempt should not stick; we retry up to
        # $Script:TokenRefreshRetryMax times before giving up.
        # Common.ps1 zeroes $Script:TokenRefreshRetryDelayMs so the
        # tests do not consume real wall-clock time inside Start-Sleep.

        BeforeEach {
            $script:credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:credDir -Force | Out-Null
            $script:slot = Join-Path $script:credDir '.credentials.retry.json'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'OLD'
                    refreshToken = 'RT'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:slot -Value $payload -NoNewline
        }

        It '429 then 200 on retry: succeeds, slot file updated, two token-endpoint calls' {
            $script:attempts = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:attempts++
                if ($script:attempts -eq 1) {
                    $resp  = [pscustomobject]@{ StatusCode = 429 }
                    $inner = [System.Exception]::new('429 Too Many Requests')
                    $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                    throw $inner
                }
                return [pscustomobject]@{
                    access_token  = 'NEW'
                    refresh_token = 'NEW-RT'
                    expires_in    = 3600
                }
            }

            { Update-SlotTokens -SlotPath $script:slot 6>$null } | Should -Not -Throw

            $script:attempts | Should -Be 2
            $after = Get-Content -LiteralPath $script:slot -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken  | Should -Be 'NEW'
            $after.claudeAiOauth.refreshToken | Should -Be 'NEW-RT'
        }

        It 'persistent 429 across all attempts: throws (no infinite loop); RetryMax attempts made' {
            $script:attempts = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:attempts++
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('429 Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            { Update-SlotTokens -SlotPath $script:slot 6>$null } |
                Should -Throw -ExpectedMessage '*429*'

            # Exactly RetryMax (default 3) attempts were made before
            # giving up. Defends against off-by-one in the retry loop.
            $script:attempts | Should -Be $Script:TokenRefreshRetryMax
        }

        It 'non-429 failure on first attempt: throws immediately (no retry)' {
            $script:attempts = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:attempts++
                throw [System.Exception]::new('refresh_token invalid')
            }

            { Update-SlotTokens -SlotPath $script:slot 6>$null } |
                Should -Throw -ExpectedMessage '*refresh_token invalid*'

            # No retry for non-429 (avoids hammering a deterministic 4xx).
            $script:attempts | Should -Be 1
        }

        # The ladder assumes a per-token limiter that unlocks in seconds. The
        # 429s measured on 2026-09-19 come from Cloudflare's edge and are keyed
        # to the origin, so once one slot has drawn one, attempts 2 and 3 for
        # every later slot in the same run are pure tally against the address.
        It 'collapses to a single attempt once another slot holds a live backoff stamp' {
            $Script:SlotUsageCache['X:\another-slot.json'] = @{
                Data             = $null
                Timestamp        = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(120)
            }
            $script:attempts = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:attempts++
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('429 Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            # Still surfaces the real 429 rather than falling out of the loop
            # with $resp unset and reporting a bogus 'missing access_token'.
            { Update-SlotTokens -SlotPath $script:slot 6>$null } |
                Should -Throw -ExpectedMessage '*429*'

            $script:attempts | Should -Be 1
        }

        It 'uses the full ladder again once the other slot stamp has expired' {
            $Script:SlotUsageCache['X:\another-slot.json'] = @{
                Data             = $null
                Timestamp        = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(-1)   # expired
            }
            $script:attempts = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:attempts++
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('429 Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            { Update-SlotTokens -SlotPath $script:slot 6>$null } | Should -Throw

            $script:attempts | Should -Be $Script:TokenRefreshRetryMax
        }

        It 'still collapses when the live stamp belongs to the slot being refreshed' {
            # Reachable on a watch tick whose backoff expired between the
            # short-circuit check and this refresh.
            $Script:SlotUsageCache[$script:slot] = @{
                Data             = $null
                Timestamp        = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(120)
            }
            $script:attempts = 0
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $script:attempts++
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('429 Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            { Update-SlotTokens -SlotPath $script:slot 6>$null } | Should -Throw
            $script:attempts | Should -Be 1
        }
    }

    Context 'Test-TokenEndpointThrottled' {
        It 'is false when the cache is empty' {
            Test-TokenEndpointThrottled | Should -BeFalse
        }

        It 'is false when entries carry no backoff stamp' {
            $Script:SlotUsageCache['X:\a.json'] = @{ Data = 'D'; Timestamp = [DateTime]::UtcNow }
            Test-TokenEndpointThrottled | Should -BeFalse
        }

        It 'is true while any single entry is inside its window' {
            $Script:SlotUsageCache['X:\a.json'] = @{ Data = 'D'; Timestamp = [DateTime]::UtcNow }
            $Script:SlotUsageCache['X:\b.json'] = @{
                Data = $null; Timestamp = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(120)
            }
            Test-TokenEndpointThrottled | Should -BeTrue
        }

        It 'is false once every window has passed' {
            $Script:SlotUsageCache['X:\b.json'] = @{
                Data = $null; Timestamp = [DateTime]::UtcNow
                RateLimitedUntil = [DateTime]::UtcNow.AddSeconds(-1)
            }
            Test-TokenEndpointThrottled | Should -BeFalse
        }
    }

    Context 'New-AutoSaveSlot (sidecar-write failure advisory)' {
        # Direct test for the New-AutoSaveSlot helper's catch path:
        # when Write-Sidecar throws, the function must NOT throw; it
        # emits a yellow advisory and the slot tokens file remains on
        # disk (Get-Slots will hide it, user can clean up by name).

        It 'emits a yellow advisory and keeps the tokens file when sidecar write fails' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null

            $bytes = [System.Text.Encoding]::UTF8.GetBytes('AUTOBYTES')
            $oa = [pscustomobject]@{
                accountUuid      = 'u'
                emailAddress     = 'auto@example.com'
                organizationUuid = $null
                displayName      = $null
                organizationName = $null
            }

            Mock Write-Sidecar -MockWith { throw [System.Exception]::new('disk full') }

            $out = New-AutoSaveSlot -Bytes $bytes `
                                    -Email 'auto@example.com' `
                                    -OAuthAccount $oa `
                                    -SourceLabel 'test' `
                                    -LastSyncHash 'H1' 6>&1 | Out-String

            $out | Should -Match 'Auto-save sidecar write failed'
            $out | Should -Match 'disk full'

            # Tokens file landed on disk despite the sidecar failure.
            $tokenFiles = @(Get-ChildItem -LiteralPath $credDir -Filter '.credentials.auto-*.json' -Force |
                Where-Object { $_.Name -notlike '*.account.json' })
            $tokenFiles.Count | Should -Be 1
            [System.IO.File]::ReadAllBytes($tokenFiles[0].FullName) | Should -Be $bytes
        }
    }

    Context 'Write-Color (uncovered branches)' {
        # Common.ps1 forces OutputRendering=PlainText so the SGR codes
        # Write-Color emits are stripped by PowerShell's host filter
        # before we see them. We can still verify the function does not
        # throw on each color name (covers the switch arms) and that
        # NoNewline is honored.

        It 'emits without throwing for every named color (covers BrightCyan branch)' {
            foreach ($c in 'Yellow','DarkYellow','Green','Red','Cyan','Gray','DarkGray') {
                { Write-Color "test" $c 6>$null } | Should -Not -Throw
            }
        }

        It 'tolerates an unknown color name via the default branch' {
            { Write-Color "test" 'not-a-color' 6>$null } | Should -Not -Throw
        }

        It '-NoNewline switch is honored (single Write-Host call without a newline)' {
            # Capture stream 6 and verify the emitted line carries the
            # message text. PlainText stripping leaves the text intact.
            $out = Write-Color 'sentinel-no-newline' 'Cyan' -NoNewline 6>&1 | Out-String
            $out | Should -Match 'sentinel-no-newline'
        }
    }

    Context 'Get-CredentialSlotFiles' {
        # The -Force flag this helper exists to centralize is invisible on
        # Windows and load-bearing on Unix, so assert the exclusions (which
        # hold everywhere) plus the dotfile visibility itself.

        It 'returns slot files and excludes .credentials.json and sidecars' {
            New-SlotPair -CredDir $CredDir -Name 'alpha' -Content 'A' | Out-Null
            New-SlotPair -CredDir $CredDir -Name 'beta'  -Content 'B' | Out-Null
            Set-Content -LiteralPath $CredFile -Value 'ACTIVE' -NoNewline

            $names = @(Get-CredentialSlotFiles | ForEach-Object { $_.Name } | Sort-Object)

            $names.Count | Should -Be 2
            $names | Should -Not -Contain '.credentials.json'
            @($names | Where-Object { $_ -like '*.account.json' }).Count | Should -Be 0
        }

        It 'finds dotfiles that a -Force-less enumeration would hide' {
            New-SlotPair -CredDir $CredDir -Name 'gamma' -Content 'G' | Out-Null

            # The regression this guards: without -Force, .NET's Hidden
            # attribute on dot-prefixed names makes this come back empty on
            # Linux and macOS while still passing on Windows.
            @(Get-CredentialSlotFiles).Count | Should -Be 1
        }

        It 'honors -Directory for a location other than $CredDir' {
            $other = Join-Path $TestDrive 'other-config'
            New-Item -ItemType Directory -Path $other -Force | Out-Null
            New-SlotPair -CredDir $other -Name 'elsewhere' -Content 'E' | Out-Null

            @(Get-CredentialSlotFiles -Directory $other).Count | Should -Be 1
            @(Get-CredentialSlotFiles).Count                   | Should -Be 0
        }

        It 'returns nothing for a directory that does not exist' {
            @(Get-CredentialSlotFiles -Directory (Join-Path $TestDrive 'no-such-dir')).Count |
                Should -Be 0
        }
    }

    Context 'Resolve-ScaConfigDir' {
        # A relative CLAUDE_CONFIG_DIR has to be bound to a base exactly once.
        # PowerShell's provider cmdlets resolve against $PWD while the script's
        # .NET calls resolve against [Environment]::CurrentDirectory, which
        # PowerShell never syncs to Set-Location, so an unbound relative value
        # made `sca save` enumerate one directory and write into another.

        It 'returns null for an unset value' {
            Resolve-ScaConfigDir -Value $null | Should -BeNullOrEmpty
        }

        It 'returns null for a blank value' {
            Resolve-ScaConfigDir -Value '   ' | Should -BeNullOrEmpty
        }

        It 'binds a relative value to the base directory' {
            $base = Join-Path $TestDrive 'base'
            Resolve-ScaConfigDir -Value 'claude-cfg' -BaseDir $base |
                Should -Be (Join-Path $base 'claude-cfg')
        }

        It 'resolves a relative segment against the base' {
            $base = Join-Path $TestDrive 'base'
            Resolve-ScaConfigDir -Value (Join-Path 'sub' (Join-Path '..' 'cfg')) -BaseDir $base |
                Should -Be (Join-Path $base 'cfg')
        }

        It 'leaves an absolute value rooted where it was' {
            $abs = Join-Path $TestDrive 'absolute-cfg'
            Resolve-ScaConfigDir -Value $abs -BaseDir (Join-Path $TestDrive 'elsewhere') |
                Should -Be $abs
        }

        # Claude Code treats a leading ~ as a literal cwd-relative directory
        # (anthropics/claude-code#78988), so expanding it here would aim sca at
        # a different directory than the process it mirrors.
        It 'does not expand a leading tilde' {
            $base = Join-Path $TestDrive 'base'
            Resolve-ScaConfigDir -Value (Join-Path '~' 'cfg') -BaseDir $base |
                Should -Be (Join-Path $base (Join-Path '~' 'cfg'))
        }

        It 'hands an unusable value back verbatim rather than throwing at load time' {
            # A base that is not rooted makes GetFullPath throw; `sca help` and
            # `sca -Version` still have to work so they can say what is wrong.
            Resolve-ScaConfigDir -Value 'cfg' -BaseDir 'not-a-rooted-base' | Should -Be 'cfg'
        }

        # End to end: the script's own load-time binding, from the environment
        # variable through to every derived path.
        It 'leaves no relative path in $CredDir when the variable is relative' {
            $env:CLAUDE_CONFIG_DIR = 'rel-cfg'
            Push-Location -LiteralPath $TestDrive
            try {
                . $script:ScriptPath
                $expected = Join-Path $TestDrive 'rel-cfg'
                $CredDir        | Should -Be $expected
                $CredFile       | Should -Be (Join-Path $expected '.credentials.json')
                $StateFile      | Should -Be (Join-Path $expected '.sca-state.json')
                $ClaudeJsonPath | Should -Be (Join-Path $expected '.claude.json')
            }
            finally {
                Pop-Location
                $env:CLAUDE_CONFIG_DIR = $null
            }
        }
    }

    Context 'Get-ConfigDirAdvisory' {
        # Driven by argument rather than by $env:CLAUDE_CONFIG_DIR, because
        # $ScaConfigDir / $CredDir / $ScaHomeDir are bound once when
        # Common.ps1 dot-sources the script: re-setting the environment
        # variable afterwards would not be observed.

        It 'returns null when CLAUDE_CONFIG_DIR is unset' {
            Get-ConfigDirAdvisory -ConfigDir $null | Should -BeNullOrEmpty
        }

        It 'returns null when CLAUDE_CONFIG_DIR is set but blank' {
            Get-ConfigDirAdvisory -ConfigDir '   ' | Should -BeNullOrEmpty
        }

        It 'returns null when CLAUDE_CONFIG_DIR points at the default directory' {
            $default = Join-Path $script:SandboxHome '.claude'

            Get-ConfigDirAdvisory -ConfigDir $default `
                                  -HomeDir   $script:SandboxHome `
                                  -ActiveDir $default | Should -BeNullOrEmpty
        }

        It 'returns null when the value differs only by a redundant path segment' {
            $roundabout = Join-Path $script:SandboxHome (Join-Path 'sub' (Join-Path '..' '.claude'))

            Get-ConfigDirAdvisory -ConfigDir $roundabout `
                                  -HomeDir   $script:SandboxHome `
                                  -ActiveDir $roundabout | Should -BeNullOrEmpty
        }

        # GetFullPath PRESERVES a trailing separator, so a plain string compare
        # read 'x/.claude/' and 'x/.claude' as different directories. The
        # advisory that followed named the SAME directory as the one in use and
        # as the one holding slots "not in use", on every invocation, forever.
        It 'returns null when the value differs only by a trailing separator' {
            $default  = Join-Path $script:SandboxHome '.claude'
            $trailing = $default + [System.IO.Path]::DirectorySeparatorChar
            New-SlotPair -CredDir $default -Name 'would-be-misreported' -Content 'A' | Out-Null

            Get-ConfigDirAdvisory -ConfigDir $trailing `
                                  -HomeDir   $script:SandboxHome `
                                  -ActiveDir $trailing | Should -BeNullOrEmpty
        }

        It 'returns null when the value differs only by separator style' -Skip:(-not $IsWindows) {
            $default = Join-Path $script:SandboxHome '.claude'
            $slashed = $default -replace '\\', '/'
            New-SlotPair -CredDir $default -Name 'would-be-misreported' -Content 'A' | Out-Null

            Get-ConfigDirAdvisory -ConfigDir $slashed `
                                  -HomeDir   $script:SandboxHome `
                                  -ActiveDir $slashed | Should -BeNullOrEmpty
        }

        # Resolve-ScaConfigDir has always guarded this; Get-ConfigDirAdvisory
        # did not, and GetFullPath validates its base BEFORE the path, so an
        # Env:\ location threw on two absolute arguments. The catch failed open
        # into the orphan check, producing the same self-contradicting line.
        It 'compares correctly from a non-filesystem provider location' {
            $default = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $default -Name 'would-be-misreported' -Content 'A' | Out-Null

            Push-Location Env:\
            try {
                Get-ConfigDirAdvisory -ConfigDir $default `
                                      -HomeDir   $script:SandboxHome `
                                      -ActiveDir $default | Should -BeNullOrEmpty
            }
            finally { Pop-Location }
        }

        It 'names the directory in use when relocated and slots are stranded' {
            $defaultDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $defaultDir -Name 'left-behind' -Content 'A' | Out-Null

            $relocated = Join-Path $TestDrive 'relocated'

            $advisory = Get-ConfigDirAdvisory -ConfigDir $relocated `
                                              -HomeDir   $script:SandboxHome `
                                              -ActiveDir $relocated

            $advisory | Should -Match 'CLAUDE_CONFIG_DIR is set'
            $advisory | Should -BeLike "*$relocated*"
        }

        It 'counts the slots left behind in the default directory' {
            $defaultDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $defaultDir -Name 'left-a' -Content 'A' | Out-Null
            New-SlotPair -CredDir $defaultDir -Name 'left-b' -Content 'B' | Out-Null

            $relocated = Join-Path $TestDrive 'relocated-count'

            Get-ConfigDirAdvisory -ConfigDir $relocated `
                                  -HomeDir   $script:SandboxHome `
                                  -ActiveDir $relocated | Should -Match '2 slot\(s\)'
        }

        It 'stays silent when the default directory holds no slots' {
            # Setting the variable is a permanent configuration, so an
            # unconditional line would print on every invocation forever. With
            # nothing stranded there is nothing being hidden from the user.
            $relocated = Join-Path $TestDrive 'relocated-empty'

            Get-ConfigDirAdvisory -ConfigDir $relocated `
                                  -HomeDir   $script:SandboxHome `
                                  -ActiveDir $relocated | Should -BeNullOrEmpty
        }

        It 'fails open and still advises when the path cannot be normalized' {
            # An embedded NUL makes GetFullPath throw. The advisory is the
            # safe outcome: better a redundant line than a silent relocation.
            # Needs a stranded slot, since that is what the advisory reports.
            $defaultDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $defaultDir -Name 'stranded' -Content 'A' | Out-Null

            Get-ConfigDirAdvisory -ConfigDir "bad`0path" `
                                  -HomeDir   $script:SandboxHome `
                                  -ActiveDir "bad`0path" | Should -Match 'CLAUDE_CONFIG_DIR is set'
        }

        It 'resolves a relative value against $PWD, not the process start directory' {
            # [IO.Path]::GetFullPath(path) resolves against
            # [Environment]::CurrentDirectory, which PowerShell never syncs to
            # Set-Location. Every other consumer of $CredDir goes through the
            # provider and lands on $PWD, so a relative CLAUDE_CONFIG_DIR must
            # be compared the same way or the "already the default" arm
            # misfires against a directory sca never reads.
            $defaultDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $defaultDir -Name 'stranded' -Content 'A' | Out-Null

            Push-Location -LiteralPath $script:SandboxHome
            try {
                # '.claude' relative to $PWD IS the default directory, so the
                # advisory must be silent. Resolved against the process start
                # directory it would not be, and the advisory would fire.
                Get-ConfigDirAdvisory -ConfigDir '.claude' `
                                      -HomeDir   $script:SandboxHome `
                                      -ActiveDir '.claude' | Should -BeNullOrEmpty
            }
            finally { Pop-Location }
        }

        # An unresolvable home on Unix (a container, a systemd unit) leaves
        # $ScaHomeDir null, which a [String] parameter binds as ''. Join-Path
        # rejects that, and the throw would abort the whole invocation over an
        # advisory line even though $CredDir came from CLAUDE_CONFIG_DIR and
        # never needed the home directory. With no default directory there is
        # also nowhere for a slot to be stranded, so the answer is silence.
        It 'returns null without a resolvable home directory: <Case>' -ForEach @(
            @{ Case = 'empty string'; HomeDir = '' }
            @{ Case = 'null';         HomeDir = $null }
            @{ Case = 'whitespace';   HomeDir = '   ' }
        ) {
            $relocated = Join-Path $TestDrive 'relocated-no-home'

            # A throw here IS the regression: Join-Path rejects the empty
            # string, and the call site in Invoke-Main is not wrapped.
            { Get-ConfigDirAdvisory -ConfigDir $relocated `
                                    -HomeDir   $HomeDir `
                                    -ActiveDir $relocated } | Should -Not -Throw

            Get-ConfigDirAdvisory -ConfigDir $relocated `
                                  -HomeDir   $HomeDir `
                                  -ActiveDir $relocated | Should -BeNullOrEmpty
        }

        It 'reads the script-scope values when called without arguments' {
            # Common.ps1 clears CLAUDE_CONFIG_DIR, so the default-bound call
            # must be silent. Covers the production call site in Invoke-Main.
            Get-ConfigDirAdvisory | Should -BeNullOrEmpty
        }
    }

    Context 'Test-SamePath / Get-PathResolutionBase' {
        It 'ignores a trailing separator' {
            $sep = [System.IO.Path]::DirectorySeparatorChar
            Test-SamePath -Left (Join-Path $TestDrive 'a') -Right ((Join-Path $TestDrive 'a') + $sep) |
                Should -BeTrue
        }

        It 'still distinguishes genuinely different directories' {
            Test-SamePath -Left (Join-Path $TestDrive 'a') -Right (Join-Path $TestDrive 'b') |
                Should -BeFalse
        }

        It 'normalises relative segments' {
            Test-SamePath -Left (Join-Path $TestDrive 'a') `
                          -Right (Join-Path $TestDrive (Join-Path 'sub' (Join-Path '..' 'a'))) |
                Should -BeTrue
        }

        It 'is case-insensitive on Windows and case-sensitive elsewhere' {
            $expected = [bool]$IsWindows
            Test-SamePath -Left (Join-Path $TestDrive 'Case') -Right (Join-Path $TestDrive 'case') |
                Should -Be $expected
        }

        It 'falls back off a non-filesystem location instead of throwing' {
            Push-Location Env:\
            try {
                $PWD.ProviderPath | Should -Not -Be ([Environment]::CurrentDirectory)
                Get-PathResolutionBase | Should -Be ([Environment]::CurrentDirectory)
                { Test-SamePath -Left 'rel-a' -Right 'rel-a' } | Should -Not -Throw
                Test-SamePath -Left 'rel-a' -Right 'rel-a' | Should -BeTrue
            }
            finally { Pop-Location }
        }
    }

    Context 'Assert-CredentialDir' {
        # $CredDir is blank only when neither the platform's home variable nor
        # CLAUDE_CONFIG_DIR is set. The directory arrives as a parameter
        # because it binds once at load time, so the suite drives the branches
        # by argument.

        It 'throws naming both variables when no directory resolved: <Case>' -ForEach @(
            @{ Case = 'null';       Directory = $null }
            @{ Case = 'empty';      Directory = '' }
            @{ Case = 'whitespace'; Directory = '   ' }
        ) {
            { Assert-CredentialDir -Directory $Directory } |
                Should -Throw -ExpectedMessage '*CLAUDE_CONFIG_DIR*'
        }

        It 'names the home variable the running platform actually reads' {
            $expected = if ($IsWindows) { 'USERPROFILE' } else { 'HOME' }
            { Assert-CredentialDir -Directory '' } |
                Should -Throw -ExpectedMessage "*`$env:$expected*"
        }

        It 'does not throw for a resolved directory' {
            { Assert-CredentialDir -Directory $TestDrive } | Should -Not -Throw
        }

        It 'defaults to the script-scope directory, which the sandbox always resolves' {
            { Assert-CredentialDir } | Should -Not -Throw
        }
    }

    Context 'Show-Help FILES block' {
        It 'prints the paths this invocation actually uses' {
            $out = Show-Help 6>&1 | Out-String
            $out | Should -Match ([regex]::Escape($CredFile))
            $out | Should -Match ([regex]::Escape($StateFile))
        }

        # The home ENVIRONMENT VARIABLE is not the only source of a home
        # directory: .NET falls back to the passwd entry on Unix and to the
        # shell folder API on Windows, and PowerShell binds $HOME from that.
        # Node's os.homedir() does the same, so `claude` keeps working with
        # HOME unset; consulting only $env:HOME would have made `sca` refuse
        # in an environment where the process it mirrors is running fine.
        #
        # Out of process because $ScaHomeDir binds when the script is
        # dot-sourced, and dot-sourced (not invoked) so no action runs and
        # nothing is created in the tester's real home.
        It 'falls back to the session home when the home variable is unset' {
            $homeVar = if ($IsWindows) { 'USERPROFILE' } else { 'HOME' }
            $out = pwsh -NoProfile -Command "
                Remove-Item -Path Env:$homeVar -ErrorAction SilentlyContinue
                Remove-Item -Path Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
                . '$script:ScriptPath'
                `$CredDir
            " 2>&1 | Out-String

            $out | Should -Not -Match 'Cannot bind argument'
            $out.Trim() | Should -Not -BeNullOrEmpty
            $out.Trim() | Should -BeLike "*$([System.IO.Path]::DirectorySeparatorChar).claude"
        }

        # Help is where the user finds out which variable to set, so it has to
        # render in the environment that cannot resolve one. With the $HOME
        # fallback in place that environment is no longer reachable by removing
        # an environment variable (a healthy machine always answers), so the
        # unresolved rendering is driven directly instead. `sca help` used to
        # die on Join-Path's binder before printing a line.
        It 'renders the FILES block with no resolvable home directory' {
            $CredDir   = $null
            $CredFile  = $null
            $StateFile = $null

            $out = Show-Help 6>&1 | Out-String

            $out | Should -Match 'Switch Claude Account - manage multiple Claude Code logins'
            @([regex]::Matches($out, 'unresolved: set HOME or CLAUDE_CONFIG_DIR')).Count |
                Should -Be 3
        }

        # The counterpart: every other action has to refuse, and name both
        # variables rather than surfacing a parameter-binder error.
        It 'refuses an action with no resolvable credentials directory, naming both variables' {
            $homeVar = if ($IsWindows) { 'USERPROFILE' } else { 'HOME' }

            { Assert-CredentialDir -Directory '' } |
                Should -Throw -ExpectedMessage "*No credentials directory*"
            { Assert-CredentialDir -Directory '' } |
                Should -Throw -ExpectedMessage "*$homeVar*"
            { Assert-CredentialDir -Directory '' } |
                Should -Throw -ExpectedMessage '*CLAUDE_CONFIG_DIR*'
        }
    }

    Context 'Test-SameOAuthAccount' {
        # Two records of one account can disagree about the email: Claude Code
        # fills ~/.claude.json's emailAddress from the profile response on one
        # login path and from the access token's embedded account_email on
        # another. Both paths agree on the uuid, so the uuid decides wherever
        # both sides carry one.
        It 'answers on the uuid when both sides carry one: <Case>' -ForEach @(
            @{ Case = 'same uuid, same email';  LUuid = 'u1'; LMail = 'a@x'; RUuid = 'u1'; RMail = 'a@x'; Expected = $true }
            @{ Case = 'same uuid, other email'; LUuid = 'u1'; LMail = 'a@x'; RUuid = 'u1'; RMail = 'b@x'; Expected = $true }
            @{ Case = 'other uuid, same email'; LUuid = 'u1'; LMail = 'a@x'; RUuid = 'u2'; RMail = 'a@x'; Expected = $false }
            @{ Case = 'uuid case differs';      LUuid = 'U1'; LMail = 'a@x'; RUuid = 'u1'; RMail = 'b@x'; Expected = $true }
        ) {
            $left  = [pscustomobject]@{ accountUuid = $LUuid; emailAddress = $LMail }
            $right = [pscustomobject]@{ accountUuid = $RUuid; emailAddress = $RMail }
            Test-SameOAuthAccount -Left $left -Right $right | Should -Be $Expected
        }

        # Read-Sidecar requires an email but not a uuid, so a sidecar written
        # before uuid capture has only the email to offer.
        It 'falls back to the email when either side has no uuid: <Case>' -ForEach @(
            @{ Case = 'left has none';  LUuid = $null; RUuid = 'u1'; LMail = 'a@x'; RMail = 'a@x'; Expected = $true }
            @{ Case = 'right has none'; LUuid = 'u1';  RUuid = '';   LMail = 'a@x'; RMail = 'a@x'; Expected = $true }
            @{ Case = 'neither has';    LUuid = $null; RUuid = $null; LMail = 'a@x'; RMail = 'b@x'; Expected = $false }
        ) {
            $left  = [pscustomobject]@{ accountUuid = $LUuid; emailAddress = $LMail }
            $right = [pscustomobject]@{ accountUuid = $RUuid; emailAddress = $RMail }
            Test-SameOAuthAccount -Left $left -Right $right | Should -Be $Expected
        }

        # No evidence is not sameness. Answering $true here would let an empty
        # record mirror one account's tokens over another's slot, which is the
        # degeneration Read-Sidecar's email requirement exists to prevent.
        It 'answers false when a side is absent or carries neither field: <Case>' -ForEach @(
            @{ Case = 'left null';   Left = $null;                                             Right = [pscustomobject]@{ accountUuid = 'u'; emailAddress = 'a@x' } }
            @{ Case = 'right null';  Left = [pscustomobject]@{ accountUuid = 'u'; emailAddress = 'a@x' }; Right = $null }
            @{ Case = 'both empty';  Left = [pscustomobject]@{ accountUuid = ''; emailAddress = '' };     Right = [pscustomobject]@{ accountUuid = ''; emailAddress = '' } }
        ) {
            Test-SameOAuthAccount -Left $Left -Right $Right | Should -BeFalse
        }
    }

    Context 'Test-ClaudeNodeProcess' {
        # The npm package runs as 'node', so Test-ClaudeRunning's name probe
        # misses it entirely and the ~/.claude.json write would go ahead
        # against a live in-memory cache. Mocking Get-Process does not reach a
        # dot-sourced function, which is why the pattern lives here instead.

        It 'matches the npm package entry point behind the claude shim' {
            $procs = @(
                [pscustomobject]@{ ProcessName = 'bash'; CommandLine = '-bash' },
                [pscustomobject]@{ ProcessName = 'node'; CommandLine = 'node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js' }
            )
            Test-ClaudeNodeProcess -Processes $procs | Should -BeTrue
        }

        # Over-matching only refuses a safe action; under-matching races
        # Claude Code. But a directory name is not a running Claude Code, and
        # this repo's own checkout would otherwise lock out `sca save`.
        It 'ignores a command line that merely mentions claude: <Case>' -ForEach @(
            @{ Case = 'repo path';   CommandLine = 'code /home/ada/switch_claude_account' }
            @{ Case = 'bare word';   CommandLine = 'less /home/ada/notes-about-claude.md' }
            @{ Case = 'no cli.js';   CommandLine = 'node /home/ada/claude-code/index.js' }
            @{ Case = 'null';        CommandLine = $null }
        ) {
            $procs = @([pscustomobject]@{ ProcessName = 'x'; CommandLine = $CommandLine })
            Test-ClaudeNodeProcess -Processes $procs | Should -BeFalse
        }

        It 'reports nothing for an empty or null process list: <Case>' -ForEach @(
            @{ Case = 'null';  Processes = $null }
            @{ Case = 'empty'; Processes = @() }
        ) {
            Test-ClaudeNodeProcess -Processes $Processes | Should -BeFalse
        }
    }

    AfterAll {
        # Restore the two globals BeforeEach mutated so this suite leaves
        # the caller's session clean. Pester runs AfterAll even if tests
        # throw, so this covers the mid-suite-failure case too.
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
