# Conventions

Read when writing or reviewing code, a comment, a commit message or changelog text.

## Comments

Comments explain **why**, not **what**; the code already states what it does, and a
comment that restates it drifts out of sync.

- **Default to no comment.** Prefer a clearer name or a smaller function; comment only
  when the *reason* is non-obvious from the code.
- **One source of truth per rationale.** Document a non-obvious decision once at the
  authoritative place and reference it tersely from other call sites.
- **History lives in git.** The commit message and `git blame` carry change history,
  not comments. Do not write "previously X" or "the old behavior was Y".
- **No WHAT-comments.** Don't preface a line or block with prose that paraphrases it.
- **Length is a smell.** A why-comment over ~3 lines usually signals unclear code or
  naming; fix the code first.
- **Earn the exception.** A long comment is justified when it records something
  unrecoverable from the code: a platform or API fact, a reverse-engineered constant,
  a measured number, or a decision with a real cost if reversed. `Write-Color` and the
  unofficial-constants block are the reference examples.

## Punctuation

The em dash (`—`) is reserved for genuine emphatic interruption or a sudden break in
thought. For every other use, prefer the more specific mark (rewriting the sentence is
also fine), and do not strip a dash where it is the right mark: a comma for a short
aside tightly bound to the sentence; parentheses for a tangential aside; a colon to
introduce an explanation, list, or summary; a semicolon or period to join two related
independent clauses; a rewrite or period for a rhetorical "not X, Y" contrast; an en
dash (`–`) for a numeric or date range; a hyphen (`-`) for a compound modifier. The
rule is to stop using `—` as a default joiner where `:`, `;`, `,`, `(...)`, or a
period would be clearer.

## Spelling

English identifiers, comments and prose use **American** spelling: `behavior`, not
`behaviour`; `recognize`, not `recognise`; `canceled`, not `cancelled`. The rule
reaches code, comments, and every document in the repository.

It applies to anything you touch rather than as a sweep, so a file still carrying a
British form is not a precedent. Released `CHANGELOG.md` entries are the one
exemption: they are history, and rewriting them would change the record of what
shipped for no reader's benefit.

## PowerShell and CLI style

- **Full cmdlet names, never aliases.** `Get-ChildItem`, not `gci` or `ls`;
  `Where-Object`, not `?`. An alias is resolved against the caller's session, which a
  `-NoProfile` run and an interactive shell do not agree on.
- **Full parameter names, never a unique prefix.** `-Recurse`, not `-rec`. A prefix
  that is unique today stops being unique when a parameter is added.
- **`-LiteralPath`, not `-Path`, for every operation on a credential file, sidecar,
  state file or profile.** Slot names are sanitized by `Get-SafeName`, but the
  directory they sit in is not, and a PowerShell wildcard bracket anywhere in a parent
  path would otherwise be globbed. This is defense in depth behind the sanitizer, not
  a substitute for it (`docs/architecture.md` → *Name sanitization*).
- **CLI examples in `README.md` and in documentation spell out long-form options**
  where the tool offers them: `--message`, not `-m`. A short form stays acceptable
  where no long form exists (`git worktree add -b`) and for coreutils (`rm -rf`).

## Commit messages

Commits take the [Conventional Commits](https://www.conventionalcommits.org/) form,
`type(scope): imperative summary`, with the reasoning in the body and no
`Co-Authored-By` trailer.

Common Changelog, which `CHANGELOG.md` follows, argues against this convention in
[§4.2](https://common-changelog.org/#42-conventional-commits): the machine-readable
prefix has to be stripped again to produce a readable changelog line, so writing the
readable form once would serve both.

That argument is accepted and overridden. The prefixes carry a scope this project
actually uses when reading its own history. `usage`, `watch`, `reconcile` and
`monitor` are the subsystems of one large single-file script with no module boundaries
to name them, and `git log --oneline` is the only place that structure is visible.
The conversion cost §4.2 warns about is also not paid here, because `CHANGELOG.md` is
curated by hand at release time rather than generated from history. The decision is
reversible at any release; nothing reads the prefixes.

## Changelog

`CHANGELOG.md` follows [Common Changelog](https://common-changelog.org) with two
deliberate deviations. They share one reason: this is a single-maintainer repository
whose git history is public and reachable, so the changelog is written for a reader
deciding whether to upgrade, not as an index into commits.

| Deviation                                       | Spec                                              | Why                                                                                                                                                                                                                                          |
| ----------------------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No commit or pull-request reference on an entry | §2.4.2, "changes must reference relevant commits" | A reference exists to let a reader reach the reasoning. The reasoning is in the commit body, and `git log --grep` reaches it from any phrase in the entry. One on every entry would be maintenance with no reader.                           |
| An `Unreleased` section exists                  | §6.2                                              | The objection in §6.2 is that a contributor cannot add self-references to an unreleased entry. Having declined references, the objection does not apply, and an `Unreleased` section is how work in progress stays visible between releases. |

Everything else holds: the four categories in order (`Changed`, `Added`, `Removed`,
`Fixed`), imperative mood, `**BREAKING**` in bold on a breaking change, ISO dates,
a release link per version heading as a reference-link block at the foot of the file,
and no entry for a change a consumer cannot observe.

An entry is **one line**: what changed, not why. Around 100 characters, and past 200
it is either two changes or a sentence of reasoning that belongs in the commit. §3.6
sends the long form to "commits or other references", and declining the references
does not make the commits unreachable, which is what the old fourth deviation assumed.
Measured before it was dropped: where entries were long, the commits of that era
carried 550-650 characters of body each; where commit bodies were sparse, the entries
were already at 100.

A version heading may carry one **italic line** beneath it, for anything that makes
upgrading more than replacing the file: a new minimum version of something else, a
command that can now refuse, a migration that runs on first read. It is the first
thing a reader deciding whether to upgrade needs, and the one place a longer sentence
earns its room.

`CHANGELOG.md` is edited as a step of a release, not per pull request.
