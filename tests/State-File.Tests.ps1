#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the state-file primitives in switch_claude_account.ps1:
# Set-CredentialFileAtomic, Read-ScaState, Write-ScaState, Update-ScaState.
#
# These four functions are the foundation the rest of the redesign sits on
# (atomic writes that survive an open Claude Code; state-file tracking that
# replaces the hardlink-based active-slot identification). They are tested
# in isolation here so a regression in the foundation surfaces with a small,
# targeted failure rather than indirectly via Invoke-* action tests.
#
# Per-test sandbox setup lives in tests/Common.ps1; see that file for the
# scoping rationale.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
    $script:OriginalHome        = $env:HOME
    $script:OriginalConfigDir   = $env:CLAUDE_CONFIG_DIR
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')

        # Every test in this file works inside the sandboxed .claude
        # directory, so create it once per test rather than repeating the
        # Join-Path / New-Item dance in every It block.
        $script:SandboxCredDir = Join-Path $script:SandboxHome '.claude'
        New-Item -ItemType Directory -Path $script:SandboxCredDir -Force | Out-Null
    }

    Context 'Set-CredentialFileAtomic' {
        It 'writes bytes to a non-existent destination' {
            $dest = Join-Path $script:SandboxCredDir 'new.txt'
            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](65,66,67))

            Test-Path -LiteralPath $dest | Should -BeTrue
            [System.IO.File]::ReadAllBytes($dest) | Should -Be ([byte[]](65,66,67))
        }

        It 'replaces an existing destination atomically' {
            $dest = Join-Path $script:SandboxCredDir 'existing.txt'
            Set-Content -LiteralPath $dest -Value 'OLD' -NoNewline

            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87))

            Get-Content -LiteralPath $dest -Raw | Should -Be 'NEW'
        }

        It 'cleans up the temp file after a successful write' {
            $dest = Join-Path $script:SandboxCredDir 'cleaned.txt'
            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](1,2,3))

            $leftovers = Get-ChildItem -LiteralPath $script:SandboxCredDir -Filter 'cleaned.txt.sca-tmp.*'
            $leftovers.Count | Should -Be 0
        }

        # The whole reason the script switched to atomic-rename writes:
        # Claude Code keeps .credentials.json open with FILE_SHARE_DELETE
        # while running, and only [System.IO.File]::Replace / ::Move
        # succeed against an open-but-share-delete handle. A regression
        # here would silently re-introduce the "close Claude Code first"
        # constraint we promised to remove.
        It 'succeeds while destination is open with FileShare::ReadWrite|Delete' {
            $dest = Join-Path $script:SandboxCredDir 'open.txt'
            Set-Content -LiteralPath $dest -Value 'OLD' -NoNewline

            $stream = [System.IO.File]::Open($dest, 'Open', 'Read', 'ReadWrite, Delete')
            try {
                { Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87)) } |
                    Should -Not -Throw
            }
            finally {
                $stream.Dispose()
            }

            Get-Content -LiteralPath $dest -Raw | Should -Be 'NEW'
        }

        # Regression guard for the inverse: if a reader holds the file
        # without granting FileShare::Delete, the atomic write must fail
        # cleanly rather than silently corrupting state. This shouldn't
        # happen in practice (Claude Code grants share-delete) but it
        # documents the contract we depend on.
        #
        # Windows-only by nature, not by convenience: FileShare is enforced by
        # the Win32 kernel. POSIX has no mandatory locking, so on Linux the
        # rename succeeds no matter what handles are open and there is no
        # failure to assert. The Linux counterpart below covers the same
        # ground from the other direction.
        It 'fails when destination is open without FileShare::Delete' -Skip:(-not $IsWindows) {
            $dest = Join-Path $script:SandboxCredDir 'locked.txt'
            Set-Content -LiteralPath $dest -Value 'OLD' -NoNewline

            $stream = [System.IO.File]::Open($dest, 'Open', 'Read', 'Read')
            try {
                { Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87)) } |
                    Should -Throw
            }
            finally {
                $stream.Dispose()
            }

            # Original content is preserved; no partial write reached disk.
            Get-Content -LiteralPath $dest -Raw | Should -Be 'OLD'
        }

        # The Unix half of the atomic-write contract. On Windows the test
        # above proves share-modes are honoured; here we prove the property
        # that actually matters on Linux, which the share-mode test cannot
        # express: rename(2) swaps the directory entry, so a reader holding
        # the old descriptor keeps seeing the old inode's bytes while the
        # path resolves to the new content. Without -Skip this would pass
        # vacuously on Windows (where the exclusive open blocks the write),
        # asserting nothing.
        It 'replaces the path while an open reader keeps the old inode' -Skip:$IsWindows {
            $dest = Join-Path $script:SandboxCredDir 'inode.txt'
            Set-Content -LiteralPath $dest -Value 'OLD' -NoNewline

            # FileShare::None: POSIX cannot enforce it, which is the point.
            $stream = [System.IO.File]::Open($dest, 'Open', 'Read', 'None')
            try {
                { Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87)) } |
                    Should -Not -Throw

                $buffer = [byte[]]::new(3)
                $read   = $stream.Read($buffer, 0, 3)
                [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read) | Should -Be 'OLD'
            }
            finally {
                $stream.Dispose()
            }

            Get-Content -LiteralPath $dest -Raw | Should -Be 'NEW'
        }

        # 0600, so a credential file is never group- or world-readable. The
        # temp file has to carry the mode from open(2) onward, because on Unix
        # ::Replace is a bare rename(2) and the destination inherits the source
        # inode's permissions: a 0644 temp silently downgrades Claude Code's
        # 0600 .credentials.json and exposes live refresh tokens.
        It 'writes credential-shaped files as 0600 on Unix' -Skip:$IsWindows {
            $dest = Join-Path $script:SandboxCredDir 'mode.json'

            # Pre-create world-readable so we prove the write tightens it
            # rather than merely inheriting an already-strict destination.
            Set-Content -LiteralPath $dest -Value 'OLD' -NoNewline
            [System.IO.File]::SetUnixFileMode($dest, 'UserRead, UserWrite, GroupRead, OtherRead')

            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87))

            [System.IO.File]::GetUnixFileMode($dest) |
                Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite')
        }

        It 'writes a brand-new credential-shaped file as 0600 on Unix' -Skip:$IsWindows {
            $dest = Join-Path $script:SandboxCredDir 'fresh.json'

            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87))

            [System.IO.File]::GetUnixFileMode($dest) |
                Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite')
        }

        It 'writes empty bytes' {
            $dest = Join-Path $script:SandboxCredDir 'empty.txt'
            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]]@())

            Test-Path -LiteralPath $dest | Should -BeTrue
            (Get-Item -LiteralPath $dest).Length | Should -Be 0
        }
    }

    Context 'Write-PrivateFileBytes' {
        It 'writes the bytes to a new path' {
            $dest = Join-Path $script:SandboxCredDir 'private.bin'
            Write-PrivateFileBytes -Path $dest -Bytes ([byte[]](78,69,87))

            [System.IO.File]::ReadAllBytes($dest) | Should -Be ([byte[]](78,69,87))
        }

        It 'writes an empty payload' {
            $dest = Join-Path $script:SandboxCredDir 'private-empty.bin'
            Write-PrivateFileBytes -Path $dest -Bytes ([byte[]]@())

            (Get-Item -LiteralPath $dest).Length | Should -Be 0
        }

        # CreateNew on both platforms. The caller passes a fresh GUID-suffixed
        # path, so an existing file means something else planted it; refusing
        # beats writing a credential into a file we do not own.
        It 'refuses an existing path rather than truncating it' {
            $dest = Join-Path $script:SandboxCredDir 'planted.bin'
            Set-Content -LiteralPath $dest -Value 'PLANTED' -NoNewline

            { Write-PrivateFileBytes -Path $dest -Bytes ([byte[]](78,69,87)) } |
                Should -Throw

            Get-Content -LiteralPath $dest -Raw | Should -Be 'PLANTED'
        }

        # The property the chmod-after-write shape could not provide: the mode
        # is carried by open(2), so the bytes are never readable by anyone but
        # the owner, not even for the duration of the write.
        It 'creates the file 0600 regardless of the process umask' -Skip:$IsWindows {
            $dest = Join-Path $script:SandboxCredDir 'private-mode.bin'
            Write-PrivateFileBytes -Path $dest -Bytes ([byte[]](78,69,87))

            [System.IO.File]::GetUnixFileMode($dest) |
                Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite')
        }

        # Set-CredentialFileAtomic's cleanup must not undo the refusal above.
        # The temp path is GUID-suffixed so a collision is not a realistic
        # worry, but a finally that deletes whatever it finds would destroy a
        # file this function deliberately declined to touch.
        It 'leaves a planted temp file intact when the atomic write refuses it' {
            $dest = Join-Path $script:SandboxCredDir 'atomic-target.json'
            Set-Content -LiteralPath $dest -Value 'ORIGINAL' -NoNewline

            Mock Write-PrivateFileBytes -MockWith { throw 'planted temp file already exists' }

            { Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87)) } |
                Should -Throw

            # The destination is untouched and no temp litter was created or
            # removed on our behalf.
            Get-Content -LiteralPath $dest -Raw | Should -Be 'ORIGINAL'
        }

        # The rename can fail on its own (a sharing violation that outlasts the
        # retries) after the temp file was written. That temp holds a complete
        # credential, so leaving it behind would be a readable copy nobody ever
        # deletes. Windows-only for the same reason as the locked-destination
        # test above: POSIX cannot make the rename fail this way.
        It 'removes its own temp file when the rename fails' -Skip:(-not $IsWindows) {
            $dest = Join-Path $script:SandboxCredDir 'rename-fails.json'
            Set-Content -LiteralPath $dest -Value 'ORIGINAL' -NoNewline
            Mock Start-Sleep -MockWith { }

            $stream = [System.IO.File]::Open($dest, 'Open', 'Read', 'Read')
            try {
                { Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87)) } | Should -Throw
            }
            finally { $stream.Dispose() }

            @(Get-ChildItem -LiteralPath $script:SandboxCredDir -Filter 'rename-fails.json.sca-tmp.*' -Force).Count |
                Should -Be 0
        }
    }

    Context 'New-CredentialDirectory' {
        It 'creates a missing directory' {
            $dir = Join-Path $TestDrive 'made-here'
            New-CredentialDirectory -Directory $dir
            Test-Path -LiteralPath $dir | Should -BeTrue
        }

        # Slot FILENAMES carry the account's email address, so a 0755 directory
        # leaks the account list even though every file inside it is 0600.
        It 'creates it 0700 on Unix' -Skip:$IsWindows {
            $dir = Join-Path $TestDrive 'made-private'
            New-CredentialDirectory -Directory $dir

            [System.IO.File]::GetUnixFileMode($dir) |
                Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }

        # Usually Claude Code's own ~/.claude. Re-permissioning another tool's
        # directory is not this tool's call to make.
        It 'leaves an existing directory and its mode alone' -Skip:$IsWindows {
            $dir = Join-Path $TestDrive 'pre-existing'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::SetUnixFileMode($dir, 'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')

            New-CredentialDirectory -Directory $dir

            [System.IO.File]::GetUnixFileMode($dir) |
                Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')
        }
    }

    Context 'Get-CredentialFilePaths' {
        # "What did sca write here", as opposed to Get-CredentialSlotFiles'
        # "what is a slot": the sidecars, the active credentials file and the
        # state file all carry the same secrecy requirement as a slot.
        It 'returns every credential-shaped file, sidecars included' {
            $slot = New-SlotPair -CredDir $script:SandboxCredDir -Name 'one' -Email 'o@x.io' -Content 'S'
            $cred = Join-Path $script:SandboxCredDir '.credentials.json'
            Set-Content -LiteralPath $cred -Value 'C' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.sca-state.json') -Value '{}' -NoNewline

            $paths = @(Get-CredentialFilePaths -Directory $script:SandboxCredDir)

            $paths.Count | Should -Be 4
            $paths       | Should -Contain $slot
            $paths       | Should -Contain ($slot -replace '\.json$', '.account.json')
            $paths       | Should -Contain $cred
        }

        # sca writes this file's oauthAccount block, but the file is Claude
        # Code's and lives outside the credentials directory. Choosing the mode
        # of a file we create and re-permissioning one another tool owns are
        # different acts; New-CredentialDirectory draws the same line for a
        # directory that already exists.
        It 'excludes ~/.claude.json' {
            $claudeJson = Join-Path $script:SandboxHome '.claude.json'
            Set-Content -LiteralPath $claudeJson -Value '{}' -NoNewline

            Get-CredentialFilePaths -Directory $script:SandboxCredDir |
                Should -Not -Contain $claudeJson
        }

        It 'skips the state file when it does not exist' {
            New-SlotPair -CredDir $script:SandboxCredDir -Name 'one' -Content 'S' | Out-Null

            Get-CredentialFilePaths -Directory $script:SandboxCredDir |
                Should -Not -Contain (Join-Path $script:SandboxCredDir '.sca-state.json')
        }

        It 'returns nothing for a missing or blank directory' {
            @(Get-CredentialFilePaths -Directory (Join-Path $TestDrive 'gone')).Count | Should -Be 0
            @(Get-CredentialFilePaths -Directory '').Count | Should -Be 0
        }
    }

    Context 'Test-UnixModeIsShared' {
        It 'is false for an owner-only mode' {
            Test-UnixModeIsShared -Mode ([System.IO.UnixFileMode]'UserRead, UserWrite') | Should -BeFalse
        }

        It 'is false for no mode at all' {
            Test-UnixModeIsShared -Mode ([System.IO.UnixFileMode]::None) | Should -BeFalse
        }

        It 'is true for <Case>' -ForEach @(
            @{ Case = '0644'; Mode = 'UserRead, UserWrite, GroupRead, OtherRead' }
            @{ Case = '0640'; Mode = 'UserRead, UserWrite, GroupRead' }
            @{ Case = '0604'; Mode = 'UserRead, UserWrite, OtherRead' }
            @{ Case = '0660'; Mode = 'UserRead, UserWrite, GroupRead, GroupWrite' }
        ) {
            Test-UnixModeIsShared -Mode ([System.IO.UnixFileMode]$Mode) | Should -BeTrue
        }
    }

    Context 'Repair-CredentialFileModes' {
        # Write-PrivateFileBytes fixes what this version writes. It cannot fix
        # the installed base: before 4.0.0 every atomic write handed the
        # destination the temp file's umask-default 0644, and `sca switch`
        # rewrites only .credentials.json, so upgrading healed exactly one file
        # while the release notes said the hole was closed.

        It 'is a no-op on Windows' -Skip:(-not $IsWindows) {
            Repair-CredentialFileModes -Directory $script:SandboxCredDir | Should -Be 0
        }

        It 'tightens every credential-shaped file an older version left readable' -Skip:$IsWindows {
            $loose = 'UserRead, UserWrite, GroupRead, OtherRead'
            $slot  = New-SlotPair -CredDir $script:SandboxCredDir -Name 'old' -Email 'o@x.io' -Content 'S'
            $side  = $slot -replace '\.json$', '.account.json'
            $cred  = Join-Path $script:SandboxCredDir '.credentials.json'
            $state = Join-Path $script:SandboxCredDir '.sca-state.json'
            Set-Content -LiteralPath $cred  -Value 'C' -NoNewline
            Set-Content -LiteralPath $state -Value '{}' -NoNewline
            foreach ($p in @($slot, $side, $cred, $state)) { [System.IO.File]::SetUnixFileMode($p, $loose) }

            Repair-CredentialFileModes -Directory $script:SandboxCredDir | Should -Be 4

            foreach ($p in @($slot, $side, $cred, $state)) {
                [System.IO.File]::GetUnixFileMode($p) |
                    Should -Be ([System.IO.UnixFileMode]'UserRead, UserWrite')
            }
        }

        It 'reports nothing to do when every file is already owner-only' -Skip:$IsWindows {
            New-SlotPair -CredDir $script:SandboxCredDir -Name 'tight' -Content 'S' | Out-Null
            Get-ChildItem -LiteralPath $script:SandboxCredDir -Force |
                ForEach-Object { [System.IO.File]::SetUnixFileMode($_.FullName, 'UserRead, UserWrite') }

            Repair-CredentialFileModes -Directory $script:SandboxCredDir | Should -Be 0
        }

        # Claude Code owns that file and rewrites it through its own atomic
        # rename, so repairing it would re-fire and re-announce after every
        # session rather than once. sca still writes its own bytes there at
        # 0600; choosing the mode of a write is not the same act as
        # re-permissioning another tool's file.
        It 'leaves ~/.claude.json alone' -Skip:$IsWindows {
            $claudeJson = Join-Path $script:SandboxHome '.claude.json'
            $loose      = [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead'
            Set-Content -LiteralPath $claudeJson -Value '{}' -NoNewline
            [System.IO.File]::SetUnixFileMode($claudeJson, $loose)

            Repair-CredentialFileModes -Directory $script:SandboxCredDir | Should -Be 0

            [System.IO.File]::GetUnixFileMode($claudeJson) | Should -Be $loose
        }

        # SetUnixFileMode is chmod(2), which follows the link and changes the
        # TARGET. Following one would have sca silently re-permission a file
        # outside the directory it believes it is repairing.
        It 'skips a symlink rather than chmod-ing its target' -Skip:$IsWindows {
            $target = Join-Path $TestDrive 'outside-target.json'
            $loose  = [System.IO.UnixFileMode]'UserRead, UserWrite, GroupRead, OtherRead'
            Set-Content -LiteralPath $target -Value 'T' -NoNewline
            [System.IO.File]::SetUnixFileMode($target, $loose)

            $link = Join-Path $script:SandboxCredDir '.credentials.linked(o@x.io).json'
            New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null

            Repair-CredentialFileModes -Directory $script:SandboxCredDir | Should -Be 0

            [System.IO.File]::GetUnixFileMode($target) | Should -Be $loose
        }

        It 'returns 0 for a directory that does not exist' -Skip:$IsWindows {
            Repair-CredentialFileModes -Directory (Join-Path $TestDrive 'nope') | Should -Be 0
        }
    }

    Context 'Write-ScaState' {
        It 'writes a schema-1 JSON file at $StateFile' {
            $state = [pscustomobject]@{
                schema         = 1
                active_slot    = 'work'
                last_sync_hash = 'abc123'
            }
            Write-ScaState -State $state

            Test-Path -LiteralPath $StateFile | Should -BeTrue
            $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $obj.schema         | Should -Be 1
            $obj.active_slot    | Should -Be 'work'
            $obj.last_sync_hash | Should -Be 'abc123'
        }

        It 'enforces schema=1 even when caller passes a different value' {
            $state = [pscustomobject]@{
                schema         = 99
                active_slot    = 'work'
                last_sync_hash = 'abc123'
            }
            Write-ScaState -State $state

            $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $obj.schema | Should -Be 1
        }

        It 'overwrites an existing state file atomically' {
            Write-ScaState -State ([pscustomobject]@{ schema=1; active_slot='one'; last_sync_hash='h1' })
            Write-ScaState -State ([pscustomobject]@{ schema=1; active_slot='two'; last_sync_hash='h2' })

            $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $obj.active_slot    | Should -Be 'two'
            $obj.last_sync_hash | Should -Be 'h2'
        }

        It 'persists null active_slot / last_sync_hash' {
            $state = [pscustomobject]@{ schema=1; active_slot=$null; last_sync_hash=$null }
            Write-ScaState -State $state

            $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $obj.active_slot    | Should -BeNullOrEmpty
            $obj.last_sync_hash | Should -BeNullOrEmpty
        }
    }

    Context 'Read-ScaState' {
        It 'returns null when no state file and no .credentials.json' {
            Read-ScaState | Should -BeNullOrEmpty
        }

        It 'returns a parsed state object when the file is schema 1' {
            $state = [pscustomobject]@{ schema=1; active_slot='work'; last_sync_hash='deadbeef' }
            Write-ScaState -State $state

            $r = Read-ScaState
            $r.schema         | Should -Be 1
            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'deadbeef'
        }

        # Read-ScaState's ternaries coerce empty / missing JSON values to
        # $null so callers never have to disambiguate '' vs $null when
        # checking active_slot / last_sync_hash. Write-ScaState happens
        # to write null literals, but a manually edited or partially
        # written state file can carry empty strings; pin the contract.
        It 'coerces empty active_slot / last_sync_hash to $null' {
            $raw = '{"schema":1,"active_slot":"","last_sync_hash":""}'
            Set-Content -LiteralPath $StateFile -Value $raw -NoNewline -Encoding utf8NoBOM

            $r = Read-ScaState
            $r.schema         | Should -Be 1
            $r.active_slot    | Should -BeNullOrEmpty
            $r.last_sync_hash | Should -BeNullOrEmpty
        }

        It 'returns null on schema mismatch' {
            $bad = '{"schema":2,"active_slot":"work","last_sync_hash":"abc"}'
            Set-Content -LiteralPath $StateFile -Value $bad -NoNewline -Encoding utf8NoBOM

            Read-ScaState | Should -BeNullOrEmpty
        }

        It 'returns null on corrupt JSON' {
            Set-Content -LiteralPath $StateFile -Value 'not-json{' -NoNewline -Encoding utf8NoBOM

            Read-ScaState | Should -BeNullOrEmpty
        }

        # Auto-migration: this is what makes the redesign upgrade-safe for
        # users coming from the hardlink-based version. With no state file
        # but a .credentials.json that hashes to a known slot, we should
        # bootstrap the state on first read and persist it so subsequent
        # reads are O(1).
        It 'auto-migrates when state file missing and .credentials.json hash matches a slot' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json')      -Value 'PAYLOAD' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.work.json') -Value 'PAYLOAD' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.other.json') -Value 'OTHER'   -NoNewline

            $r = Read-ScaState
            $r.active_slot | Should -Be 'work'

            # Persisted: state file exists after the migration call.
            Test-Path -LiteralPath $StateFile | Should -BeTrue
        }

        It 'parses labeled slot filenames during auto-migration' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json')                              -Value 'PAYLOAD' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.work(alice@example.com).json')      -Value 'PAYLOAD' -NoNewline

            (Read-ScaState).active_slot | Should -Be 'work'
        }

        It 'returns null when state file missing and no slot hash matches' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json')      -Value 'NOMATCH' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.work.json') -Value 'OTHER'   -NoNewline

            Read-ScaState | Should -BeNullOrEmpty
            # Crucially: the migration must NOT write a state file when there
            # is no match (otherwise we'd persist an active_slot=$null state
            # and lose the chance for a later auto-save to do the right
            # thing on first sca usage / sca switch invocation).
            Test-Path -LiteralPath $StateFile | Should -BeFalse
        }

        It 'returns null when state file missing and no slot files exist' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json') -Value 'PAYLOAD' -NoNewline

            Read-ScaState | Should -BeNullOrEmpty
            Test-Path -LiteralPath $StateFile | Should -BeFalse
        }

        # Regression guard for the auto-migration's Get-SHA256Hex failure
        # tolerance branch: when the credentials file cannot be hashed
        # (e.g. read fails), Read-ScaState must surface $null without
        # throwing rather than crashing the caller.
        It 'returns null when .credentials.json cannot be hashed (Get-SHA256Hex throws)' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json') -Value 'PAYLOAD' -NoNewline
            Mock Get-SHA256Hex -MockWith { throw [System.IO.IOException]::new('locked') }

            Read-ScaState | Should -BeNullOrEmpty
        }
    }

    Context 'Update-ScaState' {
        It 'creates a fresh state file when none exists' {
            $r = Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1'

            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'h1'
            Test-Path -LiteralPath $StateFile | Should -BeTrue
        }

        It 'preserves unchanged fields' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Update-ScaState -LastSyncHash 'h2'
            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'h2'
        }

        It 'updates active_slot only' {
            Update-ScaState -ActiveSlot 'one' -LastSyncHash 'h1' | Out-Null

            $r = Update-ScaState -ActiveSlot 'two'
            $r.active_slot    | Should -Be 'two'
            $r.last_sync_hash | Should -Be 'h1'
        }

        It 'clears active_slot via -ClearActiveSlot' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Update-ScaState -ClearActiveSlot
            $r.active_slot    | Should -BeNullOrEmpty
            $r.last_sync_hash | Should -Be 'h1'
        }

        # Defensive contract: -ClearActiveSlot wins over -ActiveSlot when
        # both are bound. Callers expressing "forget the active slot"
        # should not have it accidentally re-set by a stale -ActiveSlot
        # default in the same invocation.
        It '-ClearActiveSlot wins over -ActiveSlot when both are bound' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Update-ScaState -ActiveSlot 'other' -ClearActiveSlot
            $r.active_slot | Should -BeNullOrEmpty
        }

        It 'persists writes (round-trips through Read-ScaState)' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Read-ScaState
            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'h1'
        }

    }

    Context 'Legacy state-file tolerance (v2.3.0 - v2.4.0-draft compatibility)' {
        # State files written by 2.3.0 - 2.4.0-draft carry a
        # `last_warmup_at` field. v2.4.0 drops the cooldown machinery
        # but must still parse those files cleanly and silently drop
        # the field on the next state-mutating write.

        It 'Read tolerates a legacy state file carrying last_warmup_at and parses the rest' {
            $legacyJson = '{"schema":1,"active_slot":"work","last_sync_hash":"h-legacy","last_warmup_at":{"slot-1":1700000000000}}'
            Set-Content -LiteralPath $StateFile -Value $legacyJson -NoNewline -Encoding utf8NoBOM

            $r = Read-ScaState
            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'h-legacy'
            # The dropped field is not exposed on the returned object.
            ($r.PSObject.Properties.Match('last_warmup_at').Count) | Should -Be 0
        }

        It 'Next state-mutating write drops the legacy last_warmup_at field' {
            $legacyJson = '{"schema":1,"active_slot":"work","last_sync_hash":"h-legacy","last_warmup_at":{"slot-1":1700000000000}}'
            Set-Content -LiteralPath $StateFile -Value $legacyJson -NoNewline -Encoding utf8NoBOM

            Update-ScaState -ActiveSlot 'work2' -LastSyncHash 'h-new' | Out-Null

            $raw = Get-Content -LiteralPath $StateFile -Raw
            $raw | Should -Not -Match 'last_warmup_at'
        }
    }

    AfterAll {
        $env:USERPROFILE       = $script:OriginalUserProfile
        $global:PROFILE        = $script:OriginalProfile
        $env:HOME              = $script:OriginalHome
        $env:CLAUDE_CONFIG_DIR = $script:OriginalConfigDir
    }
}
