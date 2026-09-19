# Work plan: decompose `Invoke-UsageWatch`

**This is a work plan, not documentation. Delete it when the last phase lands.**
It describes work that has not happened yet, so it is exempt from the
"describe the current shape only" rule in `AGENTS.md`; nothing here is a second
copy of a fact the code already owns.

## Why

`Invoke-UsageWatch` is the worst function in the script on every axis at once:

| Metric | Value | Rank in file |
| --- | --- | --- |
| LOC | 346 | 1st |
| Cyclomatic complexity | 35 | 1st (CA1502 warns at 25) |
| Max nesting | 5 | 1st |
| Comment lines | 248 | 1st |
| Missed coverage commands | 112 | 1st, about half the file's entire gap |

The root cause is not length. It is **one `try` block**. Four terminal-state
locals (`$origCursor`, `$origEncoding`, `$origTitle`, `$enteredAlt`) are
captured at the top and consumed by a `finally` 260 lines below, so every
statement in between is trapped in that scope. Secondary cause: **seven mutable
locals** (`$snapshot`, `$lastPoll`, `$lastPollError`, `$lastAutoFooter`,
`$lastWarmupFooter`, `$warmupTimes`, `$warmupFailures`) are read and written
across the loop, so nothing can be lifted out while the state is loose
variables.

Fix those two and the function collapses.

## Hard constraint: six AST tests pin behaviour to this function's *name*

`tests/Helpers.Tests.ps1` contains six static tests that locate
`Invoke-UsageWatch` by name and assert over its AST. **Two of them disarm
themselves silently when code moves out**, because they are negative
assertions and "no X" is trivially true of an empty set.

| Test | Line | Assertion | On extraction |
| --- | --- | --- | --- |
| no `Write-Host` VT escapes | 796 | `$offending.Count \| Should -Be 0` | **silent pass** |
| no `ESC[2J` literal | 1234 | `Should -Not -Match` | **silent pass** |
| OSC 0 title + `$origTitle` restore | 822 | `Should -Match` | fails loudly |
| `6>$null` on reconcile / snapshot | 892 | guarded by `-BeGreaterOrEqual 1` | fails loudly |
| `$lastPoll` stamped after the poll | 1132 | guarded by `-BeGreaterOrEqual 1` | fails loudly |
| UTF-8 forced and restored | 1252 | `Should -Match` | fails loudly |

If the extraction is done before these are retargeted, the flicker fix and the
`ESC[2J` guard become unenforced while the suite stays green. **Phase 0 is not
optional and must land first.**

## Second constraint: the suite cannot prove this refactor

The loop is an infinite `Start-Sleep` loop requiring a TTY, which is why 112 of
its commands are uncovered and why the guards above are static rather than
behavioural. A green suite is necessary but **not sufficient** evidence here.
Every phase ends with a manual smoke test (below).

Mitigating technique: `tests/Helpers.Tests.ps1:878` already swaps
`[Console]::Out` for a `StringWriter` to capture VT output. That precedent
makes the extracted terminal functions genuinely testable, which is the main
coverage upside of this work.

## Target shape

```
Invoke-UsageWatch              ~35 LOC  CC ~8   guards + orchestration
├─ Enter-WatchTerminal         ~20 LOC  CC  3   → restore token
├─ Exit-WatchTerminal          ~20 LOC  CC  5   takes that token
├─ New-WatchSession            ~15 LOC  CC  3   the 7 locals as ONE object
├─ Invoke-WatchStartupWarm     ~45 LOC  CC  5   the -Warmup startup pass
├─ Invoke-WatchPoll            ~35 LOC  CC  5   reconcile→snapshot→title→rotate→warm
├─ Format-WatchFooter          ~20 LOC  CC  5   PURE
└─ Write-WatchFrame            ~20 LOC  CC  3   render + paint
```

The three entry guards (`-Warmup` + Claude running, `IsOutputRedirected`,
interval clamp) stay **inline** in `Invoke-UsageWatch`. They are the function's
contract and reading them at the entry point is the point; extracting them
hides it and buys 4 CC.

## Phases

Each phase is one commit, independently shippable, and leaves the suite green.
Value is front-loaded: stopping after Phase 1 already removes the core coupling
and takes CC 35 → ~25.

### Phase 0 — retarget the AST tests (blocking)

Introduce a single watch-family list in `tests/Helpers.Tests.ps1`:

```powershell
$script:WatchFamily = @('Invoke-UsageWatch')   # each phase appends to this
```

Rewrite all six tests to iterate the family instead of naming one function, and
add to the two negative tests the missing existence guard, so they cannot pass
on an empty set:

- `:796` — assert the family collectively contains at least one
  `Write-VTSequence` call before asserting no `Write-Host` carries `` `e[ ``.
- `:1234` — assert the family collectively contains at least one
  `ConvertTo-WatchFrameSequence` call before asserting no `` `e[2J ``.

`:1132` additionally needs its match loosened from `$n.Left.Extent.Text -eq
'$lastPoll'` to a suffix match, because Phase 2 renames it to
`$Session.LastPoll`.

Verification: suite green with the family still a single entry. No production
code changes in this phase.

### Phase 1 — terminal lifecycle

Extract `Enter-WatchTerminal` / `Exit-WatchTerminal`. The former returns
`[pscustomobject]@{ Cursor; Encoding; Title; EnteredAlt }`; the latter consumes
it. This alone dissolves the 260-line `try` and is behaviour-preserving by
construction.

Append both to `$script:WatchFamily`. Add unit tests using the
`[Console]::SetOut` technique: assert `Exit-WatchTerminal` emits OSC 0 then
`` `e[?25h`e[?1049l ``, in that order, and that it emits nothing at all when
`EnteredAlt` is false.

### Phase 2 — session state

Extract `New-WatchSession -Auto -Warmup`, returning one object carrying the
seven locals. Follow the existing convention: `Invoke-KeepWarmStep` already
mutates caller-supplied `$WarmupTimes` / `$WarmupFailures` hashtables, so a
mutable session bag is consistent rather than novel.

Update `:1132` per Phase 0's loosened match.

### Phase 3 — the poll step

Extract `Invoke-WatchPoll -Session -Name -Threshold -Auto -Warmup`: reconcile,
snapshot, title, auto-rotation, keep-warm, and the `catch` that parks the
message on `$Session.LastPollError`. It keeps the post-poll `$Session.LastPoll`
stamp, which must stay after the work, never from the pre-poll `$now`.

This is the only extracted unit that touches credentials, so it is the one that
gets a seam. Both High findings from the September review lived in this region.

Append to the family; `:892` and `:1132` now assert against it.

### Phase 4 — footer and frame

Extract `Format-WatchFooter` (pure) and `Write-WatchFrame`.

**`Format-WatchFooter` has two shapes**, which the signature must admit: the
startup-warm repaint emits only the two latches, while the loop also appends
`[Watch] Last poll at ...` and the failure tail. Signature:

```powershell
Format-WatchFooter -AutoLatch <string> -WarmLatch <string> `
                   [-LastPoll <DateTime>] [-LastPollError <string>]
```

`Write-WatchFrame` is a **DRY win, not just a move**: the
`Get-WatchFrameText` → `ConvertTo-WatchFrameSequence` → DEC 2026 envelope
sequence is currently written twice, once in the startup `-Repaint` closure and
once in the loop. Both call sites collapse onto it.

`Format-WatchFooter` is pure and is where the real coverage gain is: its four
branches are currently unreachable by any test.

### Phase 5 — startup warm

Extract `Invoke-WatchStartupWarm`, including the `Captured` refusal, the
`-Repaint` closure (now calling `Write-WatchFrame`), the early-repoll schedule
via `Get-EarlyRepollLastPoll`, and the cooldown-map seed.

Confirm `:1132` covers the early-repoll assignment in its new home.

## Verification, every phase

1. `pwsh -NoProfile -File tests/Invoke-Tests.ps1` — green, coverage gate held.
2. `pwsh -NoProfile -File tests/Measure-Complexity.ps1` — record the delta.
3. **Manual smoke test, required** (the suite cannot reach this code):
   - `sca usage -Watch` — frame paints, no flicker, no stray advisory line,
     title updates, Ctrl-C restores title, cursor, scrollback and encoding.
   - `sca usage -Watch -NoColor` — DEC envelope survives; this is the exact
     regression `:796` exists to prevent.
   - `sca monitor` — footer shows the `[Monitor]` latch; `▶` indicator renders.
   - `sca monitor -KeepWarm` — startup pass paints per slot, then polls.
     Billable, roughly $0.004 per slot.
   - Resize the terminal mid-watch; the frame self-heals within ~1 s.

## Expected outcome

| | Before | After |
| --- | --- | --- |
| `Invoke-UsageWatch` | 346 LOC / CC 35 / nest 5 | ~35 LOC / CC ~8 |
| Functions ≥ CC 25 | 1 (this one) | 0 |
| New testable units | — | +7, two of them pure |
| Duplicated frame-paint sequence | 2 sites | 1 |

## Risks

- **Coverage gate.** Phases 1 and 5 move currently-uncovered code into new
  functions that add command count. Net effect could be slightly negative until
  the Phase 1 and 4 unit tests land. If the 90% gate trips mid-sequence, land
  the tests in the same commit rather than lowering the gate.
- **Foreign edits.** This file has had three foreign commits during recent
  sessions. Re-run `git status --porcelain -u` and re-read before every phase;
  do not resume from a stale read.
- **Stopping early is fine.** Phases 0–1 carry most of the structural benefit.
  Phases 2–5 are refinement and can be deferred without leaving the code in a
  worse state than today.

---

[reviewed: YAGNI, DRY, Principle of Least Astonishment] dropped the guard
extraction, found the duplicated frame paint, split the two footer shapes
