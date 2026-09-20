# Themes

Read this to pick a color theme, or to see what `SCA_THEME` changes before setting it.

<p align="center">
  <img src="images/themes.svg" alt="Ten rows, one per theme, each showing a sample sca row painted on that theme's own background: the theme name, a '[Usage] Plan usage' heading, 'near limit', 'ok', 'limited' and 'Last poll' each in the theme's warning, success, danger and muted colors" width="720">
</p>

Each row shows the same sample line rendered in one theme: the heading, then a warning, a success, a danger and a muted value, painted on the background that theme uses in the full-screen views.

## Choosing one

```powershell
$env:SCA_THEME = 'nord'          # PowerShell; add to $PROFILE to make it stick
```

```bash
export SCA_THEME=nord            # bash / zsh; add to ~/.bashrc or ~/.zshrc
```

The name is case-insensitive. An unrecognized one falls back to `default` without complaint, since a typo in a shell profile would otherwise print a warning on every command you run; add `-Verbose` to any action to see the miss and the valid names. `sca help` lists them too.

## `default` is the honest exception

The `default` row above is a lie of convenience, and the only one on the page.

`default` does not carry colors. It emits the standard ANSI codes (30–37 and 90–97) and lets **your terminal** decide what they look like, so it already matches whatever scheme you have configured, on a light background as readily as a dark one. The image has to pick one interpretation to draw, and picks Windows Terminal's Campbell.

So: if you like how your terminal already looks, `default` is the right answer and no image can show you that. The nine named themes below are absolute 24-bit color and render exactly as pictured.

## The nine named themes

All nine are the [base16](https://github.com/tinted-theming/schemes) scheme of the same name, dark variant, so a palette you already know from your editor reads the same here.

| Theme        | Background | Heading   | Warning   | Success   | Danger    | Muted     |
| ------------ | ---------- | --------- | --------- | --------- | --------- | --------- |
| `dracula`    | `#282A36`  | `#BD93F9` | `#F1FA8C` | `#50FA7B` | `#FF5555` | `#6272A4` |
| `everforest` | `#2D353B`  | `#7FBBB3` | `#DBBC7F` | `#A7C080` | `#E67E80` | `#859289` |
| `flexoki`    | `#100F0F`  | `#4385BE` | `#D0A215` | `#879A39` | `#D14D41` | `#575653` |
| `gruvbox`    | `#282828`  | `#83A598` | `#FABD2F` | `#B8BB26` | `#FB4934` | `#665C54` |
| `kanagawa`   | `#1F1F28`  | `#7E9CD8` | `#C0A36E` | `#76946A` | `#C34043` | `#54546D` |
| `material`   | `#263238`  | `#82AAFF` | `#FFCB6B` | `#C3E88D` | `#F07178` | `#546E7A` |
| `monokai`    | `#272822`  | `#66D9EF` | `#F4BF75` | `#A6E22E` | `#F92672` | `#75715E` |
| `nord`       | `#2E3440`  | `#81A1C1` | `#EBCB8B` | `#A3BE8C` | `#BF616A` | `#4C566A` |
| `onedark`    | `#282C34`  | `#61AFEF` | `#E5C07B` | `#98C379` | `#E06C75` | `#545862` |

The mapping from a base16 scheme to those columns is one fixed rule: `Heading` `base0D`, `Warning` `base0A`, `Success` `base0B`, `Danger` `base08`, `Muted` `base03`, `Background` `base00`, plus `base05` for the body text.

## What a theme does and does not touch

**The background only appears in the full-screen views**, `sca usage -Watch` and `sca monitor`. Those own the whole alternate screen and hand it back untouched on exit. Every other command prints into your scrollback, where a background would leave ragged colored bars in your shell history for good, so none is painted there.

**Layout never changes.** Every column lines up identically whichever theme is active.

**A theme needs 24-bit color**, which Windows Terminal, iTerm2, kitty, Alacritty, WezTerm and recent GNOME Terminal all have. Setting the variable is taken as your word that yours does; `sca` does not probe, because the usual probe (`COLORTERM`) is unset on Windows even where truecolor works perfectly.

## Turning color off

`-NoColor` or the standard [`NO_COLOR`](https://no-color.org) variable. Both outrank `SCA_THEME`, because naming a theme says *which* colors to use, not *whether* to use any.

```bash
export NO_COLOR=1
```

## Theming everything at once instead

If you would rather not theme each tool separately, set your terminal's own 16-color palette: Windows Terminal's *Color schemes*, or [`concfg`](https://github.com/lukesampson/concfg) for CMD and the legacy console. `default` uses the standard ANSI colors precisely so it inherits that work, and then `SCA_THEME` is something you never need to set.

## Regenerating the image

`pwsh -NoProfile -File tools/Render-ReadmeImages.ps1` re-renders every SVG in `docs/images/`, this one included. The rows are generated from the script's own scheme table, so adding a theme and re-running is enough; the hex table above is maintained by hand and needs the new row adding.
