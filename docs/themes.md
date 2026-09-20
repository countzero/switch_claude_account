# Themes

Read this to pick a color theme, or to see what `SCA_THEME` changes before setting it. Every panel below is the whole `sca monitor` view rendered in that theme, on the background it paints in the full-screen views, so what you see is what you get.

Each theme has its own heading, so you can link straight to one: [`#claude`](#claude), [`#nord`](#nord), and so on.

## Choosing one

```powershell
$env:SCA_THEME = 'nord'          # PowerShell; add to $PROFILE to make it stick
```

```bash
export SCA_THEME=nord            # bash / zsh; add to ~/.bashrc or ~/.zshrc
```

The name is case-insensitive. An unrecognized one falls back to `default` without complaint, since a typo in a shell profile would otherwise print a warning on every command you run; add `-Verbose` to any action to see the miss and the valid names. `sca help` lists them too.

Ten of the eleven are absolute 24-bit color and render exactly as pictured. `default` is the exception, and the next section says why.

## The role mapping

Every theme is built from seven values by one fixed rule:

| Role         | base16 slot | Where you see it                                  |
| ------------ | ----------- | ------------------------------------------------- |
| `Heading`    | `base0D`    | `[Usage] Plan usage` and other section titles     |
| `Warning`    | `base0A`    | near-limit rows, advisories, the mid usage bar    |
| `Success`    | `base0B`    | the active slot, `ok` rows, the low usage bar     |
| `Danger`     | `base08`    | `limited` rows and the at-or-over-cap bar         |
| `Muted`      | `base03`    | the `[Watch]` / `[Monitor]` footers               |
| `Background` | `base00`    | the canvas, in `usage -Watch` and `monitor` only  |
| `Foreground` | `base05`    | body text inside a themed frame                   |

Two constraints hold across every theme, and the test suite enforces both. `Danger` must read as red and `Success` as green, because a status table is scanned rather than read: a theme that put orange where red belongs would make a limited slot look merely busy. That rule is why `github` is absent despite having a perfectly good base16 port, its slots carrying orange and pale blue.

`Muted` takes `base03` ("Comments") rather than `base04` ("status bars"), even though a status bar is literally what it renders. `base04` sits close enough to `base05` that the row stops reading as de-emphasized, and being dimmer than the body text is the whole job.

---

## default

The honest exception, and the only panel on this page that is a lie of convenience.

`default` carries no colors. It emits the standard ANSI codes (30–37 and 90–97) and lets **your terminal** decide what they look like, so it already matches whatever scheme you have configured, on a light background as readily as a dark one. It paints no background at all. The image below has to pick one interpretation to draw, and picks Windows Terminal's Campbell.

So if you like how your terminal already looks, `default` is the right answer and no image can show you that.

<img src="images/theme-default.svg" alt="The sca monitor view in the default theme: Session and Week bars, a five-row slot table and the Monitor and Watch footers, drawn in Windows Terminal's Campbell palette on the terminal's own background" width="720">

## claude

No upstream. An original palette in the same seven-slot shape, keyed to the warm accent and near-black of the Claude Code interface this tool manages logins for.

Its `Danger` is the one deliberate departure. The accent sits at hue 15, so a true red at hue 0 would land within 15° of the heading and the two would blur at a glance. `Danger` is pulled to hue 349 to hold them 26° apart, which is why that column reads slightly crimson rather than scarlet.

Background `#1F1E1D` · Heading `#D97757` · Warning `#D9A441` · Success `#7D9663` · Danger `#C9485F` · Muted `#6C6A66`

<img src="images/theme-claude.svg" alt="The sca monitor view in the claude theme: warm orange headings, amber near-limit rows, sage green ok rows and a crimson limited row on a near-black background" width="720">

## dracula

Background `#282A36` · Heading `#BD93F9` · Warning `#F1FA8C` · Success `#50FA7B` · Danger `#FF5555` · Muted `#6272A4`

<img src="images/theme-dracula.svg" alt="The sca monitor view in the dracula theme: purple headings, pale yellow near-limit rows, bright green ok rows and a coral limited row on a dark blue-grey background" width="720">

## everforest

Background `#2D353B` · Heading `#7FBBB3` · Warning `#DBBC7F` · Success `#A7C080` · Danger `#E67E80` · Muted `#859289`

<img src="images/theme-everforest.svg" alt="The sca monitor view in the everforest theme: muted teal headings, sand near-limit rows, soft green ok rows and a dusty red limited row on a desaturated green-grey background" width="720">

## flexoki

Background `#100F0F` · Heading `#4385BE` · Warning `#D0A215` · Success `#879A39` · Danger `#D14D41` · Muted `#575653`

<img src="images/theme-flexoki.svg" alt="The sca monitor view in the flexoki theme: steel blue headings, ochre near-limit rows, olive ok rows and a brick limited row on a near-black background" width="720">

## gruvbox

Background `#282828` · Heading `#83A598` · Warning `#FABD2F` · Success `#B8BB26` · Danger `#FB4934` · Muted `#665C54`

<img src="images/theme-gruvbox.svg" alt="The sca monitor view in the gruvbox theme: desaturated blue headings, warm yellow near-limit rows, olive-green ok rows and a bright red limited row on a warm dark grey background" width="720">

## kanagawa

Background `#1F1F28` · Heading `#7E9CD8` · Warning `#C0A36E` · Success `#76946A` · Danger `#C34043` · Muted `#54546D`

<img src="images/theme-kanagawa.svg" alt="The sca monitor view in the kanagawa theme: soft indigo headings, muted gold near-limit rows, moss green ok rows and a deep red limited row on a dark violet-grey background" width="720">

## material

Background `#263238` · Heading `#82AAFF` · Warning `#FFCB6B` · Success `#C3E88D` · Danger `#F07178` · Muted `#546E7A`

<img src="images/theme-material.svg" alt="The sca monitor view in the material theme: periwinkle blue headings, amber near-limit rows, light green ok rows and a salmon limited row on a blue-grey background" width="720">

## monokai

Background `#272822` · Heading `#66D9EF` · Warning `#F4BF75` · Success `#A6E22E` · Danger `#F92672` · Muted `#75715E`

<img src="images/theme-monokai.svg" alt="The sca monitor view in the monokai theme: cyan headings, sand near-limit rows, lime ok rows and a magenta-pink limited row on a warm near-black background" width="720">

## nord

Background `#2E3440` · Heading `#81A1C1` · Warning `#EBCB8B` · Success `#A3BE8C` · Danger `#BF616A` · Muted `#4C566A`

<img src="images/theme-nord.svg" alt="The sca monitor view in the nord theme: slate blue headings, pale gold near-limit rows, sage ok rows and a muted rose limited row on a cool dark blue background" width="720">

## onedark

Background `#282C34` · Heading `#61AFEF` · Warning `#E5C07B` · Success `#98C379` · Danger `#E06C75` · Muted `#545862`

<img src="images/theme-onedark.svg" alt="The sca monitor view in the onedark theme: bright blue headings, tan near-limit rows, green ok rows and a soft red limited row on a dark blue-grey background" width="720">

---

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

## Regenerating these images

`pwsh -NoProfile -File tools/Render-ReadmeImages.ps1` re-renders every SVG in `docs/images/`, these included. The panels are generated from the script's own scheme table and share their scene with `monitor.svg`, so adding a theme and re-running produces its image automatically; the heading, the hex line and the alt text on this page are the parts maintained by hand.

Unlike the four README images, the theme panels do not embed their font: it is 99.7% of a rendered file, and paying for it eleven times would cost about 4 MB to say something about color. They name a monospace fallback chain instead, which every viewer resolves and which cannot disturb a column-aligned layout.
