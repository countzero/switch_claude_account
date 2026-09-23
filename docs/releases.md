# Releases

Read when tagging, publishing or verifying a release.

## Order of operations

| Step | What                                                                          | Owner                   |
| ---- | ----------------------------------------------------------------------------- | ----------------------- |
| 1    | Bump `$Script:ScriptVersion` and add the `CHANGELOG.md` entry, in one commit  | `docs/conventions.md`   |
| 2    | Open the release pull request, `develop` into `main`, titled `Release vX.Y.Z` | `docs/pull_requests.md` |
| 3    | Wait for all three CI legs, then merge                                        | here                    |
| 4    | Tag and publish from the merge commit                                         | here                    |
| 5    | Let the workflow attach the asset                                             | here                    |
| 6    | Verify                                                                        | here                    |

The version and the newest changelog heading are pinned to each other by a test, so a
bump that forgets one of the two fails the suite rather than reaching a tag.

## The tag sits on the merge commit

Every tag names the merge commit of its release pull request, never the `chore(release)`
commit on `develop`. The merge commit is the state `main` actually took; the release
commit is only an ancestor of it, so a tag there would point at something that was never
`main`'s tip and would leave the merge itself outside the release.

Pass the merge SHA to `--target` rather than `main`. `main` is a moving reference and a
back-merge or a hotfix landing between the merge and the publish would silently retarget
the tag.

## The body is two links

```markdown
- [Changelog](https://github.com/countzero/switch_claude_account/blob/main/CHANGELOG.md#430---2026-09-21)
- [Code Changes](https://github.com/countzero/switch_claude_account/compare/v4.2.0...v4.3.0)
```

No prose, and no summary of what shipped. That account already exists twice, in
`CHANGELOG.md` for whoever asks later what a version contained and in the pull request
for the reviewer who decided it could merge. A third copy is a third place to keep
correct, and the only one of the three that cannot be reviewed before it is published.

The release **name** is the tag, `v4.3.0`, not `Release v4.3.0`. The pull request carries
the long form; the release carries the short one.

The changelog anchor is GitHub's slug of the version heading: `## [4.3.0] - 2026-09-21`
lowercases, drops the brackets and periods and turns each space into a hyphen, giving
`#430---2026-09-21`. Two releases cut on one day still differ, because the version leads
the heading.

The compare link runs from the previous tag to this one. Write the **current** repository
name in it: every release up to v4.2.0 carried `windows_switch_claude_account` from before
the rename and reached the right page only through GitHub's redirect, while the changelog
link one line above already used the new name.

## Publishing

```powershell
git log -1 --format='%h %s' origin/main    # must be the release pull request's merge commit
$tag = 'v4.3.0'
$body = @'
- [Changelog](https://github.com/countzero/switch_claude_account/blob/main/CHANGELOG.md#430---2026-09-21)
- [Code Changes](https://github.com/countzero/switch_claude_account/compare/v4.2.0...v4.3.0)
'@
gh release create $tag --target (git rev-parse origin/main) --title $tag --notes $body
```

Type the body against the rules above; do not copy the previous release's and edit the
numbers in it. That copy is exactly how v4.2.0 shipped `v4.1.0...v4.3.0`, one of the two
versions having been updated and the other not.

## The asset attaches itself

`.github/workflows/release-assets.yml` fires on `release: published`, checks out the tag
and uploads `switch_claude_account.ps1` with `--clobber`. Never upload it by hand: a
manual copy is whatever was in the working tree, while the workflow's is the file at the
tag, which is what `README.md` → *Download* promises.

Two ways to publish and get no asset:

- **A prerelease** is skipped by the workflow's `if:` guard, and is excluded from
  `/releases/latest/` besides, so it ships with no download and does not supersede the
  previous release.
- **A draft** does not raise the event at all. The asset appears when the draft is
  published, not when it is created.

## Verify

Nothing here is inferable from the publish succeeding, and each check has caught or would
catch a distinct failure.

| Check                                                    | Command                                                              |
| -------------------------------------------------------- | -------------------------------------------------------------------- |
| The workflow ran and succeeded                           | `gh run list --workflow=release-assets.yml`                          |
| Not a draft, not a prerelease, asset present             | `gh release view vX.Y.Z --json isDraft,isPrerelease,assets`          |
| The tag is on the merge commit                           | `git fetch --tags; git log -1 --format='%h %s' vX.Y.Z`               |
| The asset is the file at the tag, not a stale checkout   | compare the asset `digest` against `git cat-file blob vX.Y.Z:<file>` |
| This release is what `/releases/latest/` serves          | `gh release view --json tagName`                                     |
| The compare link resolves and spans the intended commits | `gh api repos/<owner>/<repo>/compare/vA...vB`                        |
| The changelog anchor lands on the heading                | `git show origin/main:CHANGELOG.md`                                  |

The digest check is the one worth keeping. The workflow checks out the tag, so a release
published against the wrong target ships a plausible file for the wrong commit, and
nothing else in this list would notice.

## Editing a published release

The body stays editable and the rest does not, so a mistake in it is worth correcting
rather than living with. `gh release edit vX.Y.Z --notes-file <file>` leaves the tag, the
assets, the publish date and the latest pointer alone.

A compare link with the wrong upper bound is the case to watch, because it degrades: while
the named tag does not exist the link is merely broken, and the moment that version is cut
it starts resolving and showing a superset of what the release contained. Fix such a link
before the tag that completes it is created, or immediately after.
