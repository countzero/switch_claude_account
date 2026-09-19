# Documentation

Read before adding or moving a paragraph in `AGENTS.md`, `docs/`, a skill or the README.

## Scope

This guideline governs the hand-written documents of the repository: `AGENTS.md`,
which is loaded whole into every agent session; the reference documents under `docs/`;
the skills under `.claude/skills/`; and `README.md`. It does not govern `CHANGELOG.md`,
which is curated at release time and is history by design
(`docs/conventions.md` → *Changelog*), or the generated SVGs under `docs/images/`.

## Where a piece of information lives

Every piece of information has exactly one home, chosen by its **kind**, not by its
topic. This table is the routing rule for a new paragraph.

| Kind of information | Home |
| ------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| A rule an agent must follow in every session | `AGENTS.md`: one invariant per area, one or two sentences, ending in a pointer |
| The contract or the reasoning behind one subsystem | the reference document of that subsystem, listed in `AGENTS.md` → *Reference* |
| How one function works, and why it is written that way | a comment on that function |
| A fact about someone else's binary | `docs/claude-code-internals.md`, under its own admission rule |
| What a user of `sca` sees or does | `README.md` |
| An inventory that changes on its own: the action list, the PowerShell floor, a file list | Nowhere. Point at the source: the `ValidateSet`, `sca help`, `#Requires` |
| The history of this repository | git, never a document |
| A second statement of a rule that already has a home | a pointer: `` `docs/<file>.md` → *Section* `` |

Two refinements the table cannot carry:

- **A procedure keeps its commands, and a contract keeps its values.** The command a
  procedure needs and a measured constant together with the reason it has that value
  are content of the document that owns the procedure or the contract, written once.
  What stays out is the value nobody reasons about, which a reader looks up in the
  file that sets it.
- **An invariant is not a summary.** `AGENTS.md` names the rule and where it lives;
  the exceptions, the mechanics and the reasoning stay in the reference document. When
  a bullet in `AGENTS.md` grows a sub-list, the sub-list is the contract and belongs
  in the reference document.

## Size budgets

Measured in bytes with `(Get-Item <file>).Length`. Bytes rather than lines because
the lines in these files run past 300 characters, so a line count measures nothing and
a long paragraph joined onto one line reads as a saving. The target is where a split
is planned; the limit is what no pull request may push a document over. Both are
checked by a person in review; there is deliberately no CI gate.

| Kind of document | Target | Limit |
| -------------------------------------- | ------------ | ----------------------------- |
| `AGENTS.md`, loaded into every session | about 12,000 | 18,500 (roughly 4,600 tokens) |
| A reference document under `docs/` | about 12,000 | 24,000 (roughly 6,000 tokens) |

The target matters more than the limit. `AGENTS.md` sat at 18,484 bytes against an
18,500-byte ceiling, which is a file that cannot accept a new rule without an
unplanned split, and the split is then made under pressure by whoever needed the
space. A target leaves the next rule somewhere to go.

## One home per rule

A rule is stated once. Everywhere else it appears as a pointer in the form
`` `docs/<file>.md` → *Section* ``, which names the document and the heading. Section
names are therefore an interface: a section that is pointed at is a heading, not a
bold paragraph lead, and renaming or moving one means re-pointing every caller:

```powershell
Select-String -Path AGENTS.md, README.md, docs/*.md, .claude/skills/*/SKILL.md -Pattern 'Section name' -SimpleMatch
```

`AGENTS.md` and `README.md` describe the same mechanics for different readers, which
is the pair most prone to a second copy: `CLAUDE_CONFIG_DIR`, the 0600 and 0700 file
modes, the state-file schema, name sanitization and the execution policy all once
existed in both, with the reasoning written twice in different words. The split is by
reader, not by topic. `README.md` says what happens; `docs/architecture.md` says what
the contract is and which function owns it, and points at the README section once. The
pointers run one way only, so the two cannot loop.

## Changing a document

- An addition names, in the pull request description, what it replaces, or why
  nothing did.
- Behavior that is taken back loses its prose in the same pull request; a document
  never describes what the code no longer does.
- Whoever touches a paragraph strips the stale forms in it: a British spelling, a
  history sentence, a second copy.
- A verbatim move of a section and a pointer-only edit are mechanical. They do not
  oblige a rewrite of the moved text, and the pull request says which clean-ups it
  leaves for the next content change.

## Shape of a document

- One H1, then one sentence saying who reads the document when, identical to its cell
  in `AGENTS.md` → *Reference*.
- snake_case or kebab-case file names, named after the task the reader is doing.
- American spelling in headings and prose (`docs/conventions.md` → *Spelling*).
- Markdown tables padded so every cell in a column has the same width.
- The em dash rule applies to documents as it does to code comments
  (`docs/conventions.md` → *Punctuation*).

## Documents are rendered, not parsed

A check may **render** an artifact and compare it byte for byte with the committed
file; it may not **read facts out of a document**.
`tools/Render-ReadmeImages.ps1` is the shape that works: the script is the source, the
SVGs under `docs/images/` are its rendering, and a regression is a byte difference. A
check that parsed prose would make formatting an unwritten contract, and one that
parsed a document it also writes would make that document its own input.

A fact a check depends on therefore lives in a file meant for machines, and the
document points at it. The size budgets above follow the same logic: a person reads
them in review, and the `Select-String` recipes here are review aids, never a gate.

## Review checklist

A pull request that touches a document is checked for:

1. **Sizes**: `AGENTS.md` under 18,500 bytes, every reference document under 24,000,
   and none pushed past its target without a split being planned.
2. **One home**: nothing stated that another document already states, and in
   particular nothing restated between `AGENTS.md`, `README.md` and a reference
   document.
3. **Nothing derivable**: no action list, no version number, no file inventory.
4. **Nothing historical**: no sentence about what the code used to do.
5. **Pointers resolve**: every `→ *Section*` names an existing heading, and every
   heading that was renamed or moved has had its callers re-pointed.
6. **Shape**: the opening sentence matches the document's cell in
   `AGENTS.md` → *Reference*.
