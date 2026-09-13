# Pull Requests

Read before opening a pull request or writing its description.

## What this governs

Nearly every pull request here takes `develop` into `main` and carries a release,
so the release shape below is the common case and the general rules are what it
builds on. A back-merge of `main` into `develop` is mechanical and exempt: it
restates what its own commits already say.

## The title

A release pull request is titled `Release vX.Y.Z`, naming the version its merge
will tag. Anything else takes the Conventional Commits form of its main change,
matching the commit style.

Nothing that needs to stay correctable belongs in the title. GitHub writes it
into the body of the merge commit, and what has entered the history cannot be
fixed; the description stays editable for as long as the repository exists.

## The body

English, and it answers two questions:

- **What** changed, specifically enough to skim: not "fix usage" but which
  behaviour or contract moved.
- **Why**, including the context you had as the author and the decisions the diff
  cannot show. Do not assume the reader knows the history.

This does not compete with the commit messages, which carry the same rationale
per change and are the durable record (`AGENTS.md` → *Code Comments*). The
description covers the whole branch and is read once, by a reviewer deciding
whether it may merge.

Three things are easy to omit and are the ones a reviewer needs most:

- **The shortcomings of the approach.** Every non-trivial change has them. Naming
  them is what separates a description from a sales pitch, and it points the
  review at where it is worth most.
- **Which feedback you want**, and on what. "Sanity-check the atomic rename" and
  "argue with the naming" ask for different reads.
- **What is not done**: an unrun gate, a deferred fix, a follow-up. A draft says
  so in its state; everything else says so in the body.

Write it to survive. A link to a CI run, an issue or an upstream thread rots,
or outlives the system it points at, so a link supplements the description and
never carries it.

There is deliberately **no `PULL_REQUEST_TEMPLATE`**, and none is to be added. A
template prompts for headings, and the headings are the part that legitimately
varies between a security fix, a platform port and a documentation change; what
does not vary is the substance above, which no template can check. A second copy
of this rule, prefilled into every pull request and answered with "N/A", would
rot the way the duplicated rules this repository has already deleted did.

## A release pull request

A release here can carry several versions at once, so its account is grouped by
**version**, newest first, one section per version and none left out. A reader
deciding whether to upgrade cares which version introduced a change, because the
version is what they can pin to.

It opens with an **overview** of two to four sentences: the work that carries the
release, and anything that makes upgrading more than replacing the file. A raised
`#Requires` floor, a changed environment variable, a moved file and a new minimum
for a dependency all belong there. The shortcomings, the feedback wanted and what
is not done stay as they are above, and they are what a release reviewer reads
first.

Each change is one line opening with a past-tense verb. A breaking change says so
in the line itself rather than leaving the reader to infer it from the version
number.

This does not reach `CHANGELOG.md`, which keeps its Common Changelog groups. The
overlap is deliberate: the file records what shipped, for whoever asks later what
a version contained; the description is read once, by a reviewer deciding whether
the release may merge.

## Sources

The two questions, the shortcomings and the link that carries nothing are
Google's
[Writing good CL descriptions](https://google.github.io/eng-practices/review/developer/cl-descriptions.html).
The feedback you ask for, the draft state and not assuming the reader knows the
history are GitHub's
[How to write the perfect pull request](https://github.blog/developer-skills/github/how-to-write-the-perfect-pull-request/).
