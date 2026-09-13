#Requires -Version 7.4

<#
.SYNOPSIS
    Render the colored ANSI examples in README.md as static SVG images via
    `charmbracelet/freeze`.

.DESCRIPTION
    The README.md embeds four ANSI terminal blocks that demonstrate
    `sca usage`, `sca usage -Watch`, `sca usage <name>`, and `sca monitor`
    output. Plain
    code-fences cannot show the colors that the live tool emits, so this
    script splices ANSI SGR escapes into the README's literal text and
    pipes the result to `freeze` to produce SVGs.

    Important: the input here is HAND-AUTHORED ANSI matching the README
    text byte-for-byte. It does NOT call `Format-UsageFrame` or any other
    function in switch_claude_account.ps1. If you change the README's
    example numbers / emails / column widths, edit the corresponding
    here-string below and re-run this script. If you change the script's
    color rules (Write-Color, Get-StatusColor, Get-AggregateBarColor),
    update the SGR escapes here so the rendered images stay in lockstep
    with reality.

    Why hand-authored: the README's existing block 1 (-Watch) shows a Week
    bar of 62% but the per-row Week percentages sum to 55% over 5*100%, so
    no fixture data can produce the exact bar shown. Treating the README
    text as the source of truth and colorising it is simpler than
    reverse-engineering inputs that round-trip through the real renderer.

    One deliberate divergence from the README's pre-image ASCII: the bar's
    empty portion is rendered with `▓` (medium shade block, U+2593) rather
    than spaces. That matches what `Format-AggregateBars` actually emits
    (see Format-AggregateBars in switch_claude_account.ps1 around line 2516)
    and gives the rendered SVG a visible progress-bar look instead of a
    huge invisible gap between the fill and the closing bracket. Bar
    widths and percentages are unchanged from the README.

    Why truecolor SGR (`ESC[38;2;R;G;Bm`) instead of named ANSI (`ESC[33m`,
    `ESC[92m`, ...):

    `freeze` interprets named SGR codes through its own hardcoded RGB map
    (the `ansiPalette` map in `freeze/ansi.go`), which uses the vivid
    charm palette (e.g. BrightGreen = #00D787, a turquoise). That does
    NOT match what users see in the default Windows Terminal "Campbell"
    scheme (e.g. BrightGreen = #16C60C, a pure green). Since the SVGs are
    documentation of what `sca usage` looks like in the terminal, they
    should match the modal user's view, not freeze's house style.

    `freeze` does, however, honor truecolor SGR sequences and writes the
    R;G;B values through verbatim as `fill="#RRGGBB"` (see the `case 38:
    case 2:` branch in `freeze/ansi.go`). So we sidestep the hardcoded
    palette by emitting Campbell hexes directly via truecolor.

    Color map (logical name -> Campbell hex -> where it shows):
        DarkYellow -> #C19C00  headers, bar percent label
        DarkGray   -> #767676  footer, Account label
        Green      -> #16C60C  active rows, ok status, green bars
        Yellow     -> #F9F1A5  yellow bars, near-limit rows
        Red        -> #E74856  red bars, limited rows
        Gray       -> #CCCCCC  inactive ok rows

    Logical name = the value passed to `Write-Color` in
    switch_claude_account.ps1 around line 858. The mapping there from
    logical name to `$PSStyle` SGR (DarkYellow -> 33, Green -> 92, ...)
    is a runtime artifact of how Windows Terminal renders those SGRs as
    Campbell hexes; here we burn the hexes in directly so the SVGs are
    independent of any terminal palette.

.PARAMETER OutputDir
    Where to write the rendered SVGs. Default: <repo>/docs/images.

.PARAMETER KeepAnsi
    Keep the intermediate .ansi text files for debugging.

.EXAMPLE
    pwsh -NoProfile -File tools/Render-ReadmeImages.ps1

    Regenerate all three SVGs into docs/images/.

.NOTES
    Requires `freeze` on PATH. Install with:
        winget install charmbracelet.freeze
        scoop install freeze
#>

[CmdletBinding()]
param(
    [string] $OutputDir = (Join-Path $PSScriptRoot '..\docs\images'),
    [switch] $KeepAnsi
)

$ErrorActionPreference = 'Stop'

# --- Pre-flight: locate freeze ---------------------------------------------
$freezeCmd = Get-Command freeze -ErrorAction SilentlyContinue
if (-not $freezeCmd) {
    # Fall back to the well-known winget install location since the PATH
    # update from `winget install charmbracelet.freeze` requires a shell
    # restart on Windows. Guarded on $IsWindows because $env:LOCALAPPDATA is
    # null elsewhere, and Join-Path would fail the binder under
    # ErrorActionPreference = 'Stop' before reaching the useful error below.
    $found = if ($IsWindows) {
        $wingetGlob = Join-Path $env:LOCALAPPDATA `
            'Microsoft\WinGet\Packages\charmbracelet.freeze_Microsoft.Winget.Source_*\freeze_*_Windows_x86_64\freeze.exe'
        Get-ChildItem -Path $wingetGlob -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($found) {
        $freezeExe = $found.FullName
    } else {
        throw @"
freeze not found on PATH.
Install with:  winget install charmbracelet.freeze
            or brew install charmbracelet/tap/freeze
            or scoop install freeze
"@
    }
} else {
    $freezeExe = $freezeCmd.Source
}

Write-Host "Using freeze: $freezeExe" -ForegroundColor DarkGray

# --- Resolve directories ----------------------------------------------------
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
$OutputDir = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path $repoRoot $OutputDir
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$tmpRoot = Join-Path $repoRoot '.tmp/render'
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

# --- ANSI SGR helpers -------------------------------------------------------
# Truecolor SGR (`ESC[38;2;R;G;Bm`) targeting Microsoft's Campbell palette
# (Windows Terminal default) so the rendered SVGs match what users see in
# default `pwsh.exe`, not freeze's hardcoded charm palette. See
# .DESCRIPTION above for rationale.
$ESC = [char]27
$RESET  = "$ESC[0m"
$DKYEL  = "$ESC[38;2;193;156;0m"    # #C19C00  Campbell Yellow      (DarkYellow)
$DKGRY  = "$ESC[38;2;118;118;118m"  # #767676  Campbell Brt Black   (DarkGray)
$GREEN  = "$ESC[38;2;22;198;12m"    # #16C60C  Campbell Brt Green   (Green)
$YELLO  = "$ESC[38;2;249;241;165m"  # #F9F1A5  Campbell Brt Yellow  (Yellow)
$RED    = "$ESC[38;2;231;72;86m"    # #E74856  Campbell Brt Red     (Red)
$GRAY   = "$ESC[38;2;204;204;204m"  # #CCCCCC  Campbell White       (Gray)

# --- Block 1: usage -Watch (README ~lines 17-33) ---------------------------
# Multi-slot watch frame with 5 rows; bars at 22% (green) / 62% (yellow);
# trailing [Watch] footer in DarkGray.
$watchLines = @(
    "$DKYEL[Usage] Plan usage$RESET",
    "",
    "$GREEN  Session [█████████████▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓]  22%$RESET",
    "",
    "$YELLO  Week    [███████████████████████████████████▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓]  62%$RESET",
    "",
    "    Slot         Account                Session        Week         Status",
    "    -----------  ---------------------  -------------  -----------  ------",
    "$GREEN  * work         alex@acme.io            18% (2h 11m)   42% (102h)  ok$RESET",
    "$GRAY    personal     alex.dev@gmail.com       3% (4h 02m)    7% (146h)  ok$RESET",
    "$GRAY    dev          alex@startup.dev         9% (3h 41m)   34% (118h)  ok$RESET",
    "$YELLO    client-acme  ada.lovelace@arpa.net   71% (1h 04m)   92% (41h)   near limit$RESET",
    "$RED    legacy       team@example.com        12% (3h 18m)  100% (12h)   limited 7d$RESET",
    "",
    "$DKGRY[Watch] Last poll: 14:32:07$RESET"
)

# --- Block 2: usage one-shot (README ~lines 140-151) -----------------------
# Two-slot table with bars at 10% / 24% (both green).
$tableLines = @(
    "$DKYEL[Usage] Plan usage$RESET",
    "",
    "$GREEN  Session [█████▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓]  10%$RESET",
    "",
    "$GREEN  Week    [████████████▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓]  24%$RESET",
    "",
    "    Slot      Account             Session        Week         Status",
    "    --------  ------------------  -------------  -----------  ------",
    "$GREEN  * work      alex@acme.io         18% (2h 11m)   42% (102h)  ok$RESET",
    "$GRAY    personal  alex.dev@gmail.com    3% (4h 02m)    7% (146h)  ok$RESET"
)

# --- Block 3: usage <name> verbose (README ~lines 167-172) -----------------
# Single-slot drill-down with absolute reset times. The Status line is
# whole-line colored to match Format-UsageVerbose's color application.
$verboseLines = @(
    "$DKYEL[Usage] Slot 'work' (active)$RESET",
    "$DKGRY  Account: alex@acme.io$RESET",
    "$GREEN  Status:  ok$RESET",
    "  Session     18%  Resets 7:50pm Europe/Berlin",
    "  Week        42%  Resets Apr 28, 9am Europe/Berlin"
)

# --- Block 4: monitor ------------------------------------------------------
# Same five-row watch frame as Block 1, plus the two auto-rotation artifacts:
#
#   1. Right-aligned header indicator '▶ switching slot at 95%'. Glyph
#      in Gray (white-ish, high-contrast lozenge); text in DarkGray
#      (matches footer ambient-metadata weight). See Format-UsageTable in
#      switch_claude_account.ps1 around line 2779-2810 for the runtime's
#      three-segment Write-Color composition we are imitating here.
#
#      Pad count math (right-edge alignment): widest body row in the
#      watch frame is 78 cols (e.g. the 'legacy' row). Header
#      '[Usage] Plan usage' = 18 chars. Indicator '▶ switching slot at
#      95%' = 23 chars ('▶' = 1 by .Length, matching the runtime which
#      also uses .Length for its width math). Pad = 78 - 18 - 23 = 37.
#      Result: indicator's right edge lines up with the right edge of
#      the table's Status column.
#
#   2. Extra blank line under the header (the '$AutoThreshold -gt 0'
#      branch in Format-UsageTable, switch_claude_account.ps1:2816-2818)
#      to balance the visually busier right-aligned indicator.
#
#   3. Latched '[Monitor] Rotated from "<from>" to "<to>" at HH:mm:ss'
#      footer line above the '[Watch] Last poll' line. Wording matches
#      Invoke-AutoRotationStep at switch_claude_account.ps1:3607.
#      Narrative: the active slot in the table (marked with '*') is
#      the rotation DESTINATION; the rotation SOURCE is the row at
#      100% utilization. With the body rows below 'work' is active
#      (the destination) and 'legacy' is at the 100% Week limit (the
#      source).
#
# Body rows identical to $watchLines so the two SVGs diff visually as
# auto-mode-on vs. auto-mode-off with no other deltas.
$autoHeaderPad   = ' ' * 37
$autoGlyph       = "$([char]0x25B6)"
$watchAutoLines = @(
    "$DKYEL[Usage] Plan usage$RESET$autoHeaderPad$GRAY$autoGlyph$RESET$DKGRY switching slot at 95%$RESET",
    "",
    "",
    "$GREEN  Session [█████████████▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓]  22%$RESET",
    "",
    "$YELLO  Week    [███████████████████████████████████▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓]  62%$RESET",
    "",
    "    Slot         Account                Session        Week         Status",
    "    -----------  ---------------------  -------------  -----------  ------",
    "$GREEN  * work         alex@acme.io            18% (2h 11m)   42% (102h)  ok$RESET",
    "$GRAY    personal     alex.dev@gmail.com       3% (4h 02m)    7% (146h)  ok$RESET",
    "$GRAY    dev          alex@startup.dev         9% (3h 41m)   34% (118h)  ok$RESET",
    "$YELLO    client-acme  ada.lovelace@arpa.net   71% (1h 04m)   92% (41h)   near limit$RESET",
    "$RED    legacy       team@example.com        12% (3h 18m)  100% (12h)   limited 7d$RESET",
    "",
    "$DKGRY[Monitor] Rotated from `"legacy`" to `"work`" at 14:31:58$RESET",
    "$DKGRY[Watch] Last poll at 14:32:07$RESET"
)

$scenarios = @(
    [pscustomobject]@{ Name = 'usage-watch';      Lines = $watchLines     },
    [pscustomobject]@{ Name = 'usage-table';      Lines = $tableLines     },
    [pscustomobject]@{ Name = 'usage-verbose';    Lines = $verboseLines   },
    [pscustomobject]@{ Name = 'monitor';          Lines = $watchAutoLines }
)

# --- Render -----------------------------------------------------------------
# freeze flags rationale:
#   --language ansi      : interpret SGR codes in input
#   --window             : macOS-style traffic-light chrome (per user preference)
#   --background #0C0C0C : Campbell terminal background; pairs with the Campbell
#                          truecolor palette burned into the SGR helpers above
#   --padding 30         : breathing room inside the window
#   --margin 0           : flush panel edge so the SVG fills the README
#                          column with no transparent gutter; README pins
#                          rendering at 1x via <img width="720">
#   --width 720          : forced canvas width (px) shared by all three
#                          renders so they scale identically when the README
#                          displays them. Without this, freeze auto-sizes
#                          each canvas to its longest line, which gives
#                          usage-verbose (51 chars) a much smaller intrinsic
#                          width than usage-watch (74 chars) and the README
#                          would render its monospace text ~46% larger.
#                          720px is one px above the watch panel's auto-size
#                          width so the widest content still fits without
#                          cropping. The shorter blocks (table, verbose)
#                          gain empty dark space on the right; that's the
#                          deliberate cost of uniform on-screen sizing.
#
#                          README contract: the five <img> refs in README.md
#                          (monitor.svg is referenced twice) cap rendering at
#                          this width (width="720" HTML attribute, 1x
#                          intrinsic). If you change --width here in either
#                          direction, change the five width
#                          values in README.md to match: width below --width
#                          crops the panel; width above --width re-introduces
#                          blurry upscaling of the embedded monospace text.
#                          Keep the two numbers equal.
#   --font.size 14       : default; readable in README at GitHub's render width
#   --line-height 1.4    : avoids cramped vertical spacing
# Font defaults to JetBrains Mono and is embedded as a base64 woff2 in the
# SVG, so the rendered output is pixel-identical regardless of the
# viewer's installed fonts. Adds ~300 KB per SVG, acceptable for README
# assets.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($s in $scenarios) {
    $ansiPath = Join-Path $tmpRoot ("{0}.ansi" -f $s.Name)
    $svgPath  = Join-Path $OutputDir ("{0}.svg"  -f $s.Name)
    $body     = ($s.Lines -join "`n")

    [System.IO.File]::WriteAllText($ansiPath, $body, $utf8NoBom)

    Write-Host "Rendering $($s.Name) -> $svgPath" -ForegroundColor Cyan
    & $freezeExe `
        --language    ansi `
        --window `
        --background  '#0C0C0C' `
        --padding     30 `
        --margin      0 `
        --width       720 `
        --font.size   14 `
        --line-height 1.4 `
        --output      $svgPath `
        $ansiPath
    if ($LASTEXITCODE -ne 0) {
        throw "freeze failed for $($s.Name) (exit $LASTEXITCODE)"
    }
}

# --- Cleanup ----------------------------------------------------------------
if (-not $KeepAnsi) {
    Remove-Item -Recurse -Force -LiteralPath $tmpRoot -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Done. SVGs in: $OutputDir" -ForegroundColor Green
