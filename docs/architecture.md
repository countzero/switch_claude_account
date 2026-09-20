# Architecture

Read when changing how a credential, slot, sidecar or state file is resolved or written.

This document carries the contracts and the reasoning. What a user sees of the same
mechanics is `README.md` → *Platform Notes*, and each section below points at its
counterpart there; the pointers run one way only, so the two cannot loop.

## The four artifacts

| File | Owner | What it holds |
| ---------------------------------------- | ----------- | --------------------------------------------------------- |
| `.credentials.json` | Claude Code | The active login's OAuth tokens |
| `.credentials.<name>(<email>).json` | `sca` | One saved slot's tokens, byte-equal to the active file |
| `.credentials.<name>(<email>).account.json` | `sca` | That slot's identity sidecar: uuid, email, org, display name |
| `.sca-state.json` | `sca` | `{ schema, active_slot, last_sync_hash }` |
| `~/.claude.json` | Claude Code | Claude Code's config, whose `oauthAccount` block is the "Email:" in `/status` |

The first four sit in `$CredDir`. The fifth is a sibling of that directory by default
and moves inside it when `CLAUDE_CONFIG_DIR` is set.

## Resolving the credentials directory

`$CredDir` is resolved once at the top of the script: `$env:CLAUDE_CONFIG_DIR` when
set, else `<home>/.claude`, else **`$null`** when neither is set. Every path derived
from it is left `$null` rather than throwing at load time, so `help` and `-Version`
still work, and `Assert-CredentialDir` refuses the other actions.

Home is the platform's environment variable (`$env:USERPROFILE` / `$env:HOME`)
**first**, then the `$HOME` automatic variable. The environment leads because `$HOME`
binds at session start and never re-reads it, so the test sandbox could not redirect
it; `$HOME` is kept as the fallback because it is the only getpwuid path we have, and
`claude` keeps working without the variable.

### `CLAUDE_CONFIG_DIR` has no `~` expansion

Because Claude Code does none (anthropics/claude-code#78988). A relative value is
bound to `$PWD` once at load by `Resolve-ScaConfigDir`, which keeps the parity (a
`claude` launched in the same directory resolves it the same way) while removing the
split between provider cmdlets resolving against `$PWD` and .NET resolving against
`[Environment]::CurrentDirectory`.

`Get-ConfigDirAdvisory` prints one line when the relocation strands slots in the
default directory, and stays silent otherwise, because the variable is a permanent
setting and an unconditional line would train the user to ignore it.

User-facing form: `README.md` → *File locations and `CLAUDE_CONFIG_DIR`*.

## Active credentials and the atomic write

`.credentials.json` is written by Claude Code via atomic rename on every OAuth
refresh. `sca` writes it through the same primitive (`Set-CredentialFileAtomic`) so
the file is byte-equal to the tracked slot file after every `sca save` / `sca switch`
/ reconcile pass.

`Set-CredentialFileAtomic`'s `MoveFileEx` semantics are why a write survives the
`FILE_SHARE_DELETE` handle Claude Code holds open on the file. Do not hand-roll a
write to any credential-shaped path: `Write-PrivateFileBytes` owns the create and
`Set-CredentialFileAtomic` owns the move, and both are load-bearing.

## Claude Code's config

`$ClaudeJsonPath` is `<home>/.claude.json` by default, a **sibling** of `.claude/`
rather than a file inside it, but it moves inside `CLAUDE_CONFIG_DIR` when that is set
(verified against Claude Code 2.1.263). Its top-level `oauthAccount` block is what
`/status` displays as "Email:". `sca` reads it at save time and writes the destination
slot's captured block back on `sca switch`; see `Get-OAuthAccountFromClaudeJson` /
`Set-OAuthAccountInClaudeJson`.

## The state file

`$CredDir/.sca-state.json`, schema v1: `{ schema, active_slot, last_sync_hash }`.
Single source of truth for "which slot is active." See `Read-ScaState` /
`Update-ScaState`.

User-facing form: `README.md` → *State file*.

## Slot files and the identity sidecar

A slot is `.credentials.<name>(<email>).json` plus a paired
`.credentials.<name>(<email>).account.json` identity sidecar. **Slots without a valid
sidecar are hidden from `list` / `usage` / rotation and refused by `switch`**; re-run
`sca save <name>` while that slot is active to recapture it. Details on `Get-Slots`
and `Invoke-SaveAction`.

Enumerate them **only** via `Get-CredentialSlotFiles`, which centralizes the `-Force`
that dotfiles need on Unix and the sidecar exclusion.

## File modes

Every credential-shaped file is created 0600 by `open(2)` itself, in
`Write-PrivateFileBytes`, before any byte is written. On Unix `::Replace` is a bare
`rename(2)`, so the destination inherits the temp file's mode; a chmod after the write
would leave the tokens world-readable for its duration, and not setting the mode at
all silently downgrades Claude Code's 0600 to 0644.

`Repair-CredentialFileModes` (Unix only, from `Invoke-Main`) tightens only files `sca`
itself creates, skipping symlinks and `~/.claude.json`. `New-CredentialDirectory`
creates a missing `$CredDir` 0700 and never re-permissions an existing one. Neither
re-permissions another tool's file, which leaves the email-in-filenames exposure open
wherever Claude Code created `~/.claude` first.

User-facing form: `README.md` → *File permissions (Linux and macOS)*.

## Platform behavior

### Hot-swapping a live client

Claude Code >= 2.1.274 polls `~/.claude.json` at 1 s and re-`stat`s
`.credentials.json` on every refresh check, so every action but `save` runs with it
open, `warmup` and `monitor -KeepWarm` included. `save` alone still refuses.
`Test-ClaudeRunning` owns the evidence and that one exception.

### POSIX has no mandatory locking

`FileShare` is a Win32 concept, so on Linux and macOS `::Replace` succeeds regardless
of open handles and a reader keeps the old inode. Share-mode tests are therefore
`-Skip:(-not $IsWindows)`, paired with a Unix test asserting the inode property
instead.

### Console APIs

`System.Console` is not uniformly portable, and the watch engine is the only consumer
that depends on the difference. `[Console]::CursorVisible`'s **getter** carries
`[SupportedOSPlatform("windows")]` and throws `PlatformNotSupportedException` on Linux
and macOS; only its setter is attributed portable. Off an attached console neither
half holds: with stdout redirected on Windows the getter throws `IOException` and the
setter `SetValueInvocationException`. `[Console]::WindowWidth` throws in hosts with no
console at all, and `[Console]::OutputEncoding` carries no platform attribute and is
the one that is safe to read anywhere.

Every one of them is therefore wrapped at its call site, and a failed capture is
recorded as `$null` rather than a default. That distinction is load-bearing in
`Exit-WatchTerminal`: writing a `$null` capture back through the setter would coerce
to `$false` and leave the user's cursor hidden after the watch exits. The visible
restore rides on the `ESC[?25h` in the alt-buffer leave instead, so the console API is
only ever belt-and-suspenders for the .NET-side state.

Verification is by execution, not inspection. `Enter-WatchTerminal` and
`Exit-WatchTerminal` are unit-tested with `[Console]::Out` swapped for a
`StringWriter`, which means the suite runs them under redirected output on all three
CI legs: the conditions that break them are the conditions the tests run in. A static
assertion that a guard is present would have passed against code that never executed.

### Token expiry

OAuth tokens refresh after roughly an hour of inactivity. Without a daemon a slot file
is at most one Claude-Code refresh behind; the next reconciling action captures it.
Harmless, because the slot's previous refresh token stays valid until rotated again.

### Name sanitization

`Get-SafeName` replaces invalid filename characters, parentheses, PowerShell wildcard
brackets, and spaces with `_`, strips trailing dots, and rejects reserved device
names. Windows-strict on **every** platform on purpose, via a hardcoded character
class rather than `GetInvalidFileNameChars()`, so one slot name yields one filename
everywhere. The reason for each class is on the function; every credential-file
operation also passes `-LiteralPath` as defense in depth
(`docs/conventions.md` → *PowerShell and CLI style*).

User-facing form: `README.md` → *Name sanitization*.

### Execution policy

A first-run concern for a user rather than a constraint on the code.
`README.md` → *Execution policy (Windows)* owns it.

## Requirements and install target

PowerShell 7.4+ (`#Requires -Version 7.4`), the lowest LTS carrying
`FileStreamOptions.UnixCreateMode` (.NET 7). 7.2 and 7.3 are both EOL. The install
target is `$PROFILE.CurrentUserAllHosts` (`~/.config/powershell/profile.ps1` on Linux
and macOS alike), and the aliases go into a marker-delimited block
(`# === Switch Claude Account ===`) that `Add-To-Profile` / `Remove-From-Profile` read
back; keep the markers intact when touching either.
