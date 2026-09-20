# Themes

Read this to pick a color theme, or to see what `SCA_THEME` changes before setting it.

<p align="center">
  <img src="images/themes.svg" alt="Eleven stacked panels, one per theme, each labelled with its SCA_THEME name and showing the full sca monitor view in that theme: pool-aggregate Session and Week bars, a five-row slot table with ok, near-limit and limited rows, and the Monitor and Watch footer lines, painted on that theme's own background" width="720">
</p>

Each panel is the whole `sca monitor` view rendered in one theme, on the background that theme paints in the full-screen views, so what you see is what you get rather than a swatch you have to imagine applied.

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

So: if you like how your terminal already looks, `default` is the right answer and no image can show you that. The ten named themes below are absolute 24-bit color and render exactly as pictured.

## The ten named themes

Nine are the [base16](https://github.com/tinted-theming/schemes) scheme of the same name, dark variant, so a palette you already know from your editor reads the same here. `claude` is the exception and has no upstream: it is an original palette in the same seven-slot shape, keyed to the warm accent and near-black of the Claude Code interface this tool manages logins for.

| Theme        | Background | Heading   | Warning   | Success   | Danger    | Muted     |
| ------------ | ---------- | --------- | --------- | --------- | --------- | --------- |
| `claude`     | `#1F1E1D`  | `#D97757` | `#D9A441` | `#7D9663` | `#C9485F` | `#6C6A66` |
| `dracula`    | `#282A36`  | `#BD93F9` | `#F1FA8C` | `#50FA7B` | `#FF5555` | `#6272A4` |
| `everforest` | `#2D353B`  | `#7FBBB3` | `#DBBC7F` | `#A7C080` | `#E67E80` | `#859289` |
| `flexoki`    | `#100F0F`  | `#4385BE` | `#D0A215` | `#879A39` | `#D14D41` | `#575653` |
| `gruvbox`    | `#282828`  | `#83A598` | `#FABD2F` | `#B8BB26` | `#FB4934` | `#665C54` |
| `kanagawa`   | `#1F1F28`  | `#7E9CD8` | `#C0A36E` | `#76946A` | `#C34043` | `#54546D` |
| `material`   | `#263238`  | `#82AAFF` | `#FFCB6B` | `#C3E88D` | `#F07178` | `#546E7A` |
| `monokai`    | `#272822`  | `#66D9EF` | `#F4BF75` | `#A6E22E` | `#F92672` | `#75715E` |
| `nord`       | `#2E3440`  | `#81A1C1` | `#EBCB8B` | `#A3BE8C` | `#BF616A` | `#4C566A` |
| `onedark`    | `#282C34`  | `#61AFEF` | `#E5C07B` | `#98C379` | `#E06C75` | `#545862` |

The mapping onto those columns is one fixed rule, applied to every theme alike: `Heading` `base0D`, `Warning` `base0A`, `Success` `base0B`, `Danger` `base08`, `Muted` `base03`, `Background` `base00`, plus `base05` for the body text.

Two constraints hold across all of them, and the test suite enforces both. `Danger` has to read as red and `Success` as green, because a status table is scanned rather than read: a theme whose slots put orange where red belongs would make a limited slot look merely busy. That rule is why `github` is missing despite having a perfectly good base16 port. `claude` meets it too, but only just, and by design: its accent sits at hue 15, so a true red at hue 0 would land within 15° of the heading and the two would blur at a glance. Its `Danger` is pulled to hue 349 to hold them 26° apart, which is why that column reads slightly crimson rather than scarlet.

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

`pwsh -NoProfile -File tools/Render-ReadmeImages.ps1` re-renders every SVG in `docs/images/`, this one included. The panels are generated from the script's own scheme table and share their scene with `monitor.svg`, so adding a theme and re-running is enough. The hex table above is the one part maintained by hand, and needs the new row adding.
