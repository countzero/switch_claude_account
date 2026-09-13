---
name: pr-code-review
description: >
  Multi-pass PR code review. Use when reviewing pull request code changes for
  defects and design issues. Performs 3 review passes with escalating focus,
  deduplicates findings, and produces a severity-filtered summary with deep
  links to the relevant code on GitHub. This skill is read-only and advisory;
  it never writes comments, reviews, or any data to GitHub.
---

## Multi-Pass PR Code Review

This skill performs 3 iterative review passes over a pull request diff with
escalating focus: general defects, cross-file interactions, then absent
behavior. After all passes, a final summary deduplicates, validates, assigns
severity, and filters to Critical/High/Medium. The output includes clickable
deep links to the relevant code on GitHub so the developer or reviewer can
easily navigate to each finding.

### PR and Diff Resolution

1. Run `gh pr view --json number,baseRefName,state,isDraft`. This single call
   determines whether a PR exists and, if so, its state.
2. **If a PR exists:**
   - If the PR is closed or a draft, inform the user and stop.
   - Otherwise, use the PR's `baseRefName` as the base for the diff.
3. **If no PR exists** (the command fails):
   - Determine the default branch via
     `git symbolic-ref --quiet refs/remotes/origin/HEAD` and strip the
     `origin/` prefix. If that fails, fall back to `main`.
   - Inform the user: "No PR found. Diffing against `<base>`."
4. Get the diff via `git diff <base>...HEAD`.
5. Resolve the full HEAD SHA via `git rev-parse HEAD`.
6. Resolve the repository owner/name via `gh repo view --json owner,name`
   (fall back to parsing `git remote get-url origin` if `gh` is unavailable).
   Store the owner, repo name, full SHA, and PR number (or `null` when no
   PR exists) for constructing deep links in the output.

### Context Gathering

Do NOT read full files upfront. During each pass, if a diff hunk lacks
sufficient surrounding context to assess a potential defect, read the full
file at that point using the Read tool.

### Design Review (before passes)

After resolving the diff but before starting the defect passes, evaluate the
overall design of the change:

1. **Scope alignment:** Compare the diff against the commit messages and the
   PR description (when a PR exists). Flag if the change does more or less
   than those stated goals.
2. **Placement:** Do the changes live in the correct place? This repo's
   layout:
   - `switch_claude_account.ps1`: the entire application. Top-level
     dispatcher in `Invoke-Main`; each action body is an `Invoke-*Action`
     function. New actions go in their own `Invoke-<Action>Action` function
     with a one-line dispatch in `Invoke-Main`.
   - `tests/`: Pester 5 test suite, one file per action. Shared setup in
     `tests/Common.ps1`.
   - `AGENTS.md`: repo-global rules and orientation. Per-function rationale
     lives in a comment on that function, not in a separate document.
   - `README.md`: usage documentation.
   Flag changes that mix concerns inappropriately (e.g., credential logic
   embedded in profile management, or profile logic in credential actions),
   or that violate the reconcile rule documented in `AGENTS.md` (which
   actions must call `Invoke-Reconcile` first).
3. **Complexity:** Is any part of the change more complex than necessary?
   Flag over-engineering, unnecessary abstractions, or functionality that
   is not required by the stated goal.

Record design-level findings separately under `### Design` in the output,
before the severity tables. Design findings do not go through the severity
classification; they are qualitative observations for the author.

### Workflow and User Communication

Use the TodoWrite tool to create and track these steps:

1. Resolve PR, base branch, repo identity
2. Design review
3. Pass 1
4. Pass 2
5. Pass 3
6. Output summary

Mark each todo as `in_progress` when starting and `completed` when done.
After each pass, tell the user in one line how many new defects were found
(e.g., "Pass 1 complete: found 6 defects."). After the summary, output the
final severity tables directly in the conversation.

### Review Passes

Three passes over the full diff, each with a different focus. All passes
review the full diff. Findings are recorded **without severity**: just File,
Line(s), and Description.

Only flag defects in lines that are added or modified in this PR. Do not flag
issues in unchanged context lines, even if they appear in diff hunks.

Skip any finding that:
- Matches a finding from a previous pass (same file and overlapping line
  range).
- Describes the same logical issue as an existing finding but references a
  different location (e.g., a function definition vs. its call site). Two
  findings about the same root cause count as one; keep the one closest to
  the root cause.

**Pass 1: General scan**
Review the diff. Report all defects: bugs, logic errors, security issues, bad
practices, missing validation, incorrect error handling. For new or
significantly changed functions in `switch_claude_account.ps1`, check whether
corresponding test files in `tests/` cover the changed behavior; flag missing
test coverage as a finding. Also check the project-specific concerns listed
in the Project-Specific Review Checklist section below. Only flag defects in
lines that are added or modified in this PR.

**Pass 2: What was missed**
Review the diff again, assuming defects were missed on the first pass. Focus
on interactions between changed files, subtle logic errors, and implicit
assumptions in the code. Only flag defects in lines that are added or modified
in this PR.

**Pass 3: What the code does NOT do**
Assume there are still undiscovered defects. Focus on what is absent: missing
error handling, missing edge cases, missing input validation, missing null
checks, race conditions, resource leaks, and incorrect assumptions about
state. Only flag defects in lines that are added or modified in this PR.

Track findings internally across passes (in conversation context). The format
for each finding is: File, Line(s), Description.

### False Positive Exclusion List

Do NOT flag any of the following:

- Pre-existing issues not introduced in this PR's changes.
- Code that appears to be a bug but is actually correct.
- Pedantic nitpicks that a senior engineer would not flag.
- Issues that PSScriptAnalyzer or equivalent linters will catch.
- General code quality concerns unless explicitly required in README.md.
- Issues explicitly silenced in code (e.g., via a lint ignore comment).
- Code style or formatting concerns.
- Potential issues that depend on specific inputs or runtime state.

### Project-Specific Review Checklist

This is a PowerShell utility that manages credential files. Check for:

- **Name sanitization coverage:** Verify `Get-SafeName` is called on all code
  paths that accept user-supplied names (`save`, `switch`, `remove`). Flag any
  path where `$Name` is used directly without sanitization.
- **File lock handling:** `Copy-Item` and `Remove-Item` will fail if Claude
  Code holds the credentials file open on Windows. Flag if error messages are
  unclear or if there's no guidance for the user.
- **Credential leakage:** Flag any credential data logged, written to stdout,
  or exposed in error messages.
- **Consistent error handling:** `save`/`switch`/`remove` use `throw` for
  errors, while `list` uses `Write-Host`. Flag if new actions introduce
  inconsistent patterns.
- **Profile manipulation safety:** Flag if `Add-To-Profile` or
  `Remove-From-Profile` could corrupt the user's `$PROFILE` on unexpected
  input or partial writes.

### Final Summary

After Pass 3:

1. **Deduplicate:** Two findings are duplicates if they reference the same
   file and overlapping line ranges, or if they describe the same root cause
   at different locations. Keep the more detailed description.
2. **Re-examine:** For each remaining finding, verify it against the full file
   context. If the file was not already read during a pass, read it now using
   the Read tool. Remove any finding that cannot be confirmed after
   re-examination.
3. **Confidence filter:** Remove any finding where confidence is below 80%
   that it is a real defect. When in doubt, exclude.
4. **Assign severity** using these definitions:
   - **Critical:** Data loss, security breach, authentication bypass, crash
     in production, corruption of state.
   - **High:** Incorrect behavior under normal usage, unhandled error paths
     that will be hit, significant logic flaw.
   - **Medium:** Bad practice that could lead to bugs, missing validation for
     unlikely but possible inputs, minor logic issue.
5. **Filter:** Keep only Critical, High, and Medium.
6. **Compute report metadata:** files changed and additions/deletions via
   `git diff --shortstat <base>...HEAD`; current timestamp; severity counts.
7. **Output in conversation:** title (`# PR Review` + `## <branch> (vs <base>)`),
   metadata table (see Output Template), Design section, then one table per
   severity level following the Link Format rules. Omit a severity level if
   it has no defects. If all severity buckets are empty, print
   `No Critical/High/Medium findings.` in place of the severity tables.

No data is written to GitHub. The developer or reviewer uses the output to
manually create PR comments.

### Link Format

This section defines how links appear in the output tables. Follow these
rules exactly.

**Columns:** File, Description. The File column contains a markdown link. The
link label is the file path relative to the repository root with a leading
`/`, plus the line range in `:{start}-{end}` format (e.g.,
`/switch_claude_account.ps1:41-43`). The link URL is the full GitHub URL constructed
as described below.

**Line range:** Include 1 line of context before and after the finding. A
finding on line 42 links to lines 41-43. A finding spanning lines 42-45
links to lines 41-46. The label always uses `:{start}-{end}` regardless of
whether the URL uses `L` or `R` anchors.

**SHA-256 hash for PR links:** Compute the SHA-256 hex digest of each unique
file path. Prefer PowerShell (this is a Windows project):
`$hasher = [System.Security.Cryptography.SHA256]::Create(); $bytes = [System.Text.Encoding]::UTF8.GetBytes('{path}'); -join(($hasher.ComputeHash($bytes) | ForEach-Object ToString('x2')))`
Fallback if Node.js is available:
`node -e "process.stdout.write(require('crypto').createHash('sha256').update('{path}').digest('hex'))"`.

**When a PR exists:** Use PR deep links. The URL format is
`https://github.com/{owner}/{repo}/pull/{pr-number}/files#diff-{sha256}R{start}-R{end}`.

**When no PR exists (fallback):** Use blob links with the full HEAD SHA:
`https://github.com/{owner}/{repo}/blob/{full-sha}/{path}#L{start}-L{end}`.
Note: blob links use `L` (not `R`) for line anchors.

**Correct: markdown links with file path labels**

```markdown
| File                                                                                                                  | Description                    |
| --------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| [/switch_claude_account.ps1:41-43](https://github.com/owner/repo/pull/42/files#diff-a1b2c3d4e5f6a7b8c9d0e1f2a3R41-R43) | Name not sanitized before use  |
| [/switch_claude_account.ps1:41-43](https://github.com/owner/repo/blob/4a7c9e1f/switch_claude_account.ps1#L41-L43)      | Name not sanitized before use  |
```

**Wrong: do NOT use any of these formats**

```markdown
| https://github.com/owner/repo/pull/42/files#diff-a1b2c3d4e5f6a7b8c9d0e1f2a3R41-R43 | ...  |
| [https://github.com/...](https://github.com/...)                                   | ...  |
| [switch_claude_account.ps1:41-43](https://github.com/...)                          | ...  |
```

The first is wrong because it uses a raw URL instead of a markdown link. The
second is wrong because the label is a URL instead of a file path. The third
is wrong because it uses a filename only; the label must be the full path
from the repository root with a leading `/`.

**Full output template:**

```markdown
# PR Review

## <branch-or-head7> (vs <base>)

| Field     | Value                                                                                                                                                       |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Branch    | [`<branch>`](https://github.com/OWNER/REPO/tree/<branch>) → [`<base>`](https://github.com/OWNER/REPO/tree/<base>)                                           |
| HEAD      | [`<head7>`](https://github.com/OWNER/REPO/commit/<head7>)                                                                                                   |
| PR        | [#42](https://github.com/OWNER/REPO/pull/42) (or `none` when no PR is open)                                                                                 |
| Generated | YYYY-MM-DD HH:MM                                                                                                                                            |
| Diff      | 3 files · +120 · −45                                                                                                                                        |
| Findings  | 🔴 0 Critical · 🟠 1 High · 🟡 2 Medium                                                                                                                     |

### Design

- <Qualitative observation about scope, placement, or complexity>

### Critical

| File                                                                                                                  | Description                       |
| --------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| [/switch_claude_account.ps1:41-43](https://github.com/owner/repo/pull/42/files#diff-a1b2c3d4e5f6a7b8c9d0e1f2a3R41-R43) | Credentials leaked to stdout      |

### High

| File                                                                                                                  | Description                       |
| --------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| [/switch_claude_account.ps1:14-19](https://github.com/owner/repo/pull/42/files#diff-f6a7b8c9d0a1b2c3d4e5f6a7b8R14-R19) | Name not sanitized before file op |
```

**Metadata-row formatting rules:**

- **Branch:** link both branches to GitHub tree URLs:
  `https://github.com/<owner>/<repo>/tree/<branch-name>`. Multi-segment
  branch names (e.g. `feature/foo`) work without encoding because the
  `tree/` path accepts literal slashes; percent-encode any branch name that
  contains spaces or other reserved characters.
- **HEAD:** use the 7-char short SHA in both the link label and the URL
  (`/commit/<head7>`). GitHub redirects `/commit/<short>` to the full
  commit, so the link resolves identically.
- **PR:** the PR number when one exists, `none` otherwise.
- **Diff:** plain text. Format: `<files> files · +<additions> · −<deletions>`,
  with middle dots (` · `, U+00B7) as separators. Use the Unicode minus sign
  (U+2212, `−`) for the deletions count, not the ASCII hyphen-minus.
- **Findings:** `🔴 <n> Critical · 🟠 <n> High · 🟡 <n> Medium`. Severity
  glyphs replace coloured pills to keep the recipe free of custom CSS while
  staying scannable. Always show all three severities, even when zero.

### Constraints

- Do NOT modify source code.
- Do NOT post comments, reviews, or any data to GitHub. This skill is
  read-only and advisory.
- Do NOT report style or formatting issues (covered by linters).
- Do NOT report issues in test files unless they mask real defects in
  production code.
- Do NOT report issues in generated files, lock files, or changelog entries.
- File cells in output tables must use markdown link syntax with the file
  path as label; see the Link Format section.
