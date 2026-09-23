# Architecture

Read when changing how a credential, slot, sidecar or state file is resolved or written.

This document carries the contracts and the reasoning. What a user sees of the same
mechanics is `README.md` → *Platform Notes*, and each section below points at its
counterpart there.

## The four artifacts

| File | Owner | What it holds |
| ---------------------------------------- | ----------- | --------------------------------------------------------- |
| `.credentials.json` | Claude Code | The active login's OAuth tokens |
| `.credentials.<name>(<email>).json` | `sca` | One saved slot's tokens, byte-equal to the active file |
| `.credentials.<name>(<email>).account.json` | `sca` | That slot's identity sidecar: uuid, email, org, display name |
| `.sca-state.json` | `sca` | `{ schema, active_slot, last_sync_hash }` |
| `~/.claude.json` | Claude Code | Claude Code's config, whose `oauthAccount` block is the "Email:" in `/status` |

The first four sit in `$CredDir`; where the fifth sits is *Claude Code's config* below.

## Resolving the credentials directory

`$CredDir` is resolved once at the top of the script: `$env:CLAUDE_CONFIG_DIR` when
set, else `<home>/.claude`, else **`$null`** when neither is set. Every path derived
from it is left `$null` rather than throwing at load time, so `help` and `-Version`
still work, and `Assert-CredentialDir` refuses the other actions.

Home is the platform's environment variable (`$env:USERPROFILE` / `$env:HOME`)
**first**, then the `$HOME` automatic variable. The environment leads because `$HOME`
binds at session start and never re-reads it, so the test sandbox could not redirect
it; `$HOME` is kept as the fallback because it is the only getpwuid path available, and
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
open, `warmup` and `monitor -KeepWarm` included. `save` alone refuses.
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

### Color roles and theming

Callers of `Write-Color` name a semantic **role**, never a color: `Heading`, `Warning`,
`Success`, `Danger`, `Muted`, `Neutral`. What each means is the palette convention on
`Write-Color` itself; an unknown role and an explicit `$null` both render uncolored,
which is how `Invoke-ListAction` marks an inactive row. That indirection is the whole
point: a palette swap touches no call site.

`$Script:ThemePalettes` maps role to SGR per theme and `$env:SCA_THEME` picks one,
resolved once per run by `Resolve-ThemePalette` in `Invoke-Main`. Every theme but
`default` is generated by `New-ThemePalette` from a row of `$Script:Base16Schemes`, so
a theme is data and the role-to-slot rule is stated exactly once. Precedence is
`-NoColor` > `$env:NO_COLOR` > `$env:SCA_THEME` > default. `NO_COLOR` outranks a theme
rather than conflicting with it, because naming a theme says *which* colors, not
*whether*; `PlainText` strips truecolor `ESC[38;2;R;G;Bm` by the same regex that strips
a named `ESC[33m`, so no-color mode needs no theme-specific handling. An unknown name
falls back quietly with a `Write-Verbose`: a typo lives in a shell profile, so warning
would print on every invocation for as long as it sits there.

Three constraints are deliberate and should not be "fixed":

- **The default palette is palette-relative.** It spells roles as `$PSStyle`'s named
  foregrounds, which emit ANSI 30-37/90-97 and let the terminal decide what they look
  like. The tool therefore already follows the user's own terminal theme, and stays
  legible on any background. A named theme burns in truecolor and overrides that, which
  is why one is never selected automatically.
- **Background is chrome, not a role.** A theme may declare `Background` + `Foreground`,
  and `Get-WatchChrome` applies them only inside the alternate screen. Everywhere else
  output is line-oriented into the user's scrollback, where a background would leave
  ragged colored bars in their history for good.
- **No truecolor capability detection.** `COLORTERM` and `TERM` are both unset in a
  Windows truecolor terminal, so a probe would answer wrong on the primary platform.
  Setting `SCA_THEME` is the user's own assertion that their terminal can render it.

### The base16 mapping

`New-ThemePalette` builds every named theme from seven slots by one rule: `Heading`
`base0D`, `Warning` `base0A`, `Success` `base0B`, `Danger` `base08`, `Muted` `base03`,
`Background` `base00`, `Foreground` `base05`. `Muted` takes `base03` ("Comments") and
not `base04` ("status bars") despite a status table being what it renders, because
`base04` sits close enough to `base05` to stop reading as de-emphasized.

base16 slots carry **syntax-highlighting** meaning, which usually but not always
coincides with the ANSI meaning a status table needs. Where it does not, the scheme is
unusable regardless of how it looks: github's port puts orange in `base08` and pale
blue in `base0B`, so `Danger` would render orange and `Success` blue and a glance at
the table would misread which slots are healthy. github is therefore absent despite
having an upstream, and the suite hue-checks both slots on every scheme so a theme
added later cannot reintroduce it.

### Alt-screen chrome

`Background` and `Foreground` travel together: painting a canvas without pinning a
foreground leaves a light-terminal user reading dark default text on a dark background.
Inside the frame the pair becomes the effective default, which is the second reason
`Neutral` stays out of the palette: it inherits the chrome foreground there and the
terminal's foreground in scrollback, and both are right.

`ConvertTo-WatchFrameSequence` weaves chrome in at three points, because a background is
screen state rather than a property of a string: once after `ESC[H`; re-asserted after
every `ESC[0m`, since `Write-Color` ends each run with a full reset that clears
background along with foreground; and before each `ESC[K` and the trailing `ESC[0J` so
the erases fill with it. Consecutive identical runs are collapsed, a repeated SGR being
a no-op, so a 1 Hz repaint carries no redundant bytes. `Enter-WatchTerminal` fills once
on entry to avoid a flash of the terminal background before the first frame; that fill
uses `ESC[0J`, never `ESC[2J`, which the watch-family guard forbids.

Chrome reaches cells, and a window is not a whole number of them: the pixel remainder
along the right and bottom edges keeps the terminal's own background and seams against the
canvas. `Get-WatchBackgroundOsc` moves that default with OSC 11 (hence the raw
`BackgroundRgb` beside the formatted `Background` SGR) and `Exit-WatchTerminal` restores
it with OSC 111. Windows Terminal declined to paint the gutter from the adjacent cells
(microsoft/terminal#19860, closed as not-planned), so this is the only lever available.

Three properties of that pair are load-bearing. Its guard **derives** from
`Get-WatchChrome` instead of restating the conditions, because gutter and canvas must
agree in every case and one predicate is the only guarantee of that. The reset is
**conditional** on `BackgroundSet`, recorded at entry: under `default` sca never moves the
background, and resetting anyway would discard one the *user* set before launching. And it
is written **before** `ESC[?1049l`, where it shows for one frame in the gutter alone;
after the leave it would flash the theme background across the restored scrollback.

### The frame inset

`$Script:FramePadColumns` / `$Script:FramePadRows` lift the frame two columns and one row
off the window edge. `Write-WatchFrame` owns them, raising the pair for one paint and
dropping it in a `finally`, so scrollback renderers see 0 and stay flush left: an indent
there would be noise and would break copy-paste.

`Get-RenderWidth` is the width a renderer may lay out in. It exists because the `-Auto`
indicator and the aggregate-bar clamp right-align against the width: doing that against
the raw terminal and *then* indenting would push them an inset past the edge and wrap
them. Split from `Get-ConsoleWidth` so one function stays honest about the terminal and
the other answers what fits; unknown (`0`) propagates unchanged. Ambient rather than a
parameter because the consumers sit at opposite ends of the render, and threading it would
put a presentation argument on `Format-UsageFrame`, `Format-UsageTable` and
`Write-UsageTableHeader`, all reached from non-watch callers that must pass 0.

Two caveats are deliberate. Erases filling with the current background is
`back_color_erase`, implemented by Windows Terminal, conhost, iTerm2, kitty, Alacritty,
VTE and WezTerm but not universal; where it is missing the written cells still carry the
background and only the erased tail does not, so the frame degrades to a ragged right
edge rather than breaking. And the `PlainText` check in `Get-WatchChrome` cannot be
dropped as redundant: chrome reaches the terminal through `Write-VTSequence` →
`[Console]::Out.Write`, which bypasses the `StringDecorated` filter that gives every
`Write-Color` path no-color mode for free.

`Neutral` is absent from every truecolor theme on purpose. It marks a steady-state row
carrying no verdict, so it has to stay readable on a light *and* a dark background; any
fixed hex loses one of the two, and falling through to uncolored is correct on both.

`tools/Render-ReadmeImages.ps1` hardcodes the Campbell hexes that Windows Terminal
renders the **default** theme as. It is not a theme entry and the README images are
rendered with `SCA_THEME` unset.

User-facing form: `README.md` → *Theming*.

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
