# copilot-review-gate

Make a GitHub Copilot code review a **required** merge gate.

Copilot's review is advisory: it lands as a `COMMENTED` review, counts toward no
approval requirement, and emits no stable status check of its own. With auto-merge
on, a fast CI run therefore merges the pull request before Copilot has posted
anything. This action publishes a status check that stays pending until Copilot has
genuinely reviewed the PR — mark it required, and auto-merge has to wait.

**A review record is not a review.** When Copilot's backend fails it still posts a
`COMMENTED` review whose entire body is an apology for not having reviewed. Counting
records cleared the gate on pull requests nobody had read. This action recognises what
a review *is* — a positive marker — so an unrecognised body keeps the gate **waiting**
rather than opening it, and re-requests the review, which nothing else does.

**A settled "nothing to review" is not a pending one either.** Copilot's other
non-review — "wasn't able to review any files in this pull request" — is its final
answer for that diff, not a backend hiccup a retry can fix. It gets a class of its
own, and by default it passes the gate: see
[When Copilot has nothing to review](#when-copilot-has-nothing-to-review).

## Usage

Add one workflow to your repository:

```yaml
# .github/workflows/copilot-review-gate.yml
name: Copilot review gate

on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review, converted_to_draft]

permissions:
  pull-requests: write

concurrency:
  group: copilot-gate-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  copilot-review-gate:
    name: copilot-review-gate
    runs-on: ubuntu-latest
    steps:
      - uses: hacker-cb/action-copilot-review-gate@v1
```

Then two settings, both in your branch ruleset:

1. Enable **Automatically request Copilot code review** (`review_on_push: true`), so
   Copilot is asked on every PR. Without it nothing requests the first review and the
   gate waits for something that is never coming.
2. Add **`copilot-review-gate`** (source: GitHub Actions) to the branch's **required
   status checks**. Until you do, the gate runs but gates nothing.

Do **not** put `copilot-pull-request-reviewer` in required status checks instead. It
is a dynamic check that is not emitted on every PR — bots, drafts, some pushes — so
requiring it hangs those PRs at "Expected" forever. Require this action's own stable
context.

**Land the workflow on your default branch first.** A `pull_request` workflow runs
from the PR head, so any PR opened before the file exists lacks the job entirely and
would hang forever on the newly required check.

### Versions

`@v1` is the form to use. It is a **moving major tag**: a fix here reaches you when
the tag moves, which is the whole reason this ships as an action instead of a file
you vendor — the gap that let one format change break the gate in several
repositories at once. Dependabot raises the major when one ships; nothing else is
needed to stay current.

Pinning to a commit SHA also works, and some supply-chain policies require it for
a check that is **required** — a moving tag is, by definition, something whose
target can change without a pull request in your repository. The cost is that
fixes to this gate then wait for a Dependabot PR rather than arriving on their
own, and a gate that is a release behind is a gate that fails in the way the
release fixed. Pick the one your policy actually asks for; where it does not ask,
take `@v1`.

### With options

Every input has a working default; set one only when you mean to.

```yaml
      - uses: hacker-cb/action-copilot-review-gate@v1
        with:
          wait-minutes: 20
          max-rerequests: 3
```

| Input | Default | What it does |
|---|---|---|
| `github-token` | `${{ github.token }}` | Reads the PR's reviews and re-requests one. Needs `pull-requests: write`. |
| `wait-minutes` | `15` | How long to wait for the first genuine review before failing closed. The action wraps its own script in `timeout` at this value plus one poll interval plus a two-minute grace — see [Timeouts](#timeouts) for what that ceiling does and does not cover. |
| `max-rerequests` | `2` | How many times to ask Copilot again after it answers without reviewing. Only successful requests count. |
| `poll-seconds` | `30` | Seconds between polls of the reviews API. Lands in the hard ceiling too, because the loop sleeps after testing its deadline. |
| `reviewers` | two logins | Logins that count as Copilot, one per line. An allowlist, never a prefix. |
| `review-markers` | two markers | Body substrings that mark a review as genuine, one per line; any one is enough. |
| `unable-to-review` | `pass` | What a settled "nothing to review" answer does to the gate — `pass` or `fail`. See [below](#when-copilot-has-nothing-to-review). |
| `unable-to-review-markers` | two markers | Body substrings that mark that settled answer, one per line. Empty turns the class off. |

## What the gate actually checks

It gates on **"Copilot has reviewed this PR"** (any commit), not on the current head
commit. Copilot's "Review new pushes" does not reliably re-review every push — in
particular a push that only applies Copilot's own suggestions gets no fresh review —
so gating on the exact head SHA would dead-lock the common "apply the feedback, then
push" case. Gating on first-review-seen closes the real race without false-blocking
later pushes.

Four cases pass without a review, because requiring one would deadlock: a **draft**
PR, a **bot-authored** PR (Dependabot and friends — Copilot does not review either),
a PR that was **closed or merged while the gate was waiting**, and a PR Copilot
answered it had **nothing reviewable in** *at the current head* — the one of the four
you can switch off.

Every verdict the gate reaches writes a one-line summary line, so a gate that passed
*without* a review says so on the run page rather than only in a log someone has to
scroll. Two things that are not verdicts report in the log alone: the step's preflight
— no pull request in the event, a missing `gh`/`jq`/`timeout`, a non-numeric input,
the hard ceiling firing — which runs before the gate script at all, and that script's
own required-variable guards, which fire only when the plumbing between the two is
broken.

The `pull-requests: write` scope buys exactly one operation — adding Copilot back as a
reviewer after it answered without reviewing. The job never checks out your code,
never comments, never merges. On a PR from a fork GitHub issues a read-only token
regardless of what the workflow declares, so the scope grants a fork nothing.

## Timeouts

The action puts a deadline around the script it runs: `timeout` at `wait-minutes`
plus one `poll-seconds` interval plus a two-minute grace, escalating to `SIGKILL`
ten seconds later if the process ignores the termination signal. Every number comes
from the inputs, so there is nothing to keep in sync — and the script's own window
is what fires first, printing the bodies it saw next to the markers it matched them
against before anything kills it.

The poll interval is in that sum because the loop tests its deadline *before*
sleeping: the last sleep starts inside the window and one more poll follows it, so
the script runs up to a full `poll-seconds` past its own window. Left out, a
`poll-seconds: 300` would have the ceiling fire first and report a hang where the
script was merely between polls.

Escalation arrived in `v1.0.1`; `v1.0.0` terminates a hung gate without ever
killing it. `@v1` already carries it — a SHA pinned at or below that release does
not.

That ceiling is the **step's**, not the job's. A composite action cannot set
`timeout-minutes` — only the workflow calling it can — so the ceiling begins when the
step does and covers nothing before that. A runner that stalls checking out your
repository or fetching this action never reaches the step, and what is left is
GitHub's default of **360 minutes**, with your required check pending throughout.

Whether that gap is worth a job-level `timeout-minutes` is your call. It is not a
duplicate of the ceiling above, and it is the only thing covering the gap — but keep
it well clear of the ceiling itself: a backstop that fires first replaces the gate's
diagnosis with a bare cancellation, which tells you nothing about why Copilot never
reviewed. This repository's own gate workflow sets 25 minutes against a
ceiling of 17.5 — the defaults, 15 min plus a 30-second poll plus the grace.

## What the gate does not protect

With `on: pull_request`, GitHub takes the workflow definition from the pull request's
**head** commit. A pull request that edits the gate's own workflow therefore runs its
edited version — including one that passes trivially — while the required check
reports the same green name as always. That is true of every `pull_request` check;
what makes it worth more here is that this one is the check standing between a branch
and its ruleset.

Forks are not outside this. The read-only token GitHub issues them stops API
writes, not check runs: a fork's `pull_request` run executes the fork's copy of the
workflow, so once such a run is allowed to start it can report `copilot-review-gate`
green with the gate replaced by `run: true`. What decides whether it starts is the
approval setting for fork workflow runs (Settings → Actions → *Fork pull request
workflows from outside collaborators*), which by default asks for approval only from
first-time contributors.

The defence is not a narrower token scope in the workflow. It is not letting the
workflow change without a review of its own:

- **CODEOWNERS** covering `.github/workflows/**`, with "require review from Code
  Owners" in the branch ruleset **and stale approvals dismissed when new commits
  are pushed** — without that pairing, an approval given for a harmless workflow
  edit still stands over the commit that guts the gate.
- A **push ruleset** with a file-path restriction on `.github/workflows/` covers
  branches in your own repository. A fork pushes to its own, so this one does not
  stand in for the rule above where fork pull requests are accepted.

`pull_request_target` is the other answer, and a real one: it takes the workflow
definition from the base branch, so a pull request cannot run its own edit of the
gate. It is not what this README recommends, because it carries a trap of its own —
the job runs against the base branch with the token the workflow declares, fork pull
requests included, so checking out the pull request's code under it hands a fork
your repository. This action checks nothing out, which is what makes the swap
thinkable at all; it has not been exercised in the field, so treat it as an option
to verify rather than a recommendation to follow.

## When Copilot has nothing to review

Some legitimate pull requests have no reviewable diff — an empty-file deletion, a
pure rename, a binary-only or lockfile-only change. Copilot answers those promptly
and deterministically:

> Copilot wasn't able to review any files in this pull request.

That is not the backend apology above. It is Copilot's **final** answer for this
diff: the same diff gets the same reply, so re-requesting is a provable no-op, and
a gate that keeps waiting blocks a merge nothing can unblock. In practice that
means an admin bypass — exactly the muscle this gate exists to keep people from
building. So the gate recognises the answer as its own class and, by default,
**passes** on it, ending the wait at once instead of spending the window and the
re-request budget on it.

**For this diff is the whole of it.** The reviews endpoint returns every review a
pull request ever collected, so an answer given to an empty diff is still sitting
there after the author pushes real code — and a gate reading it would open before
Copilot had read a line. The class is therefore pinned to the pull request's
**current head commit**. The same body against an older one settles nothing: the
gate says so in the log and goes back to waiting and re-requesting, which is what
gets Copilot to answer for the commit that is actually there. That pinning is this
class only; a genuine review still counts on any commit, for the reason above.

**One case deserves `fail` rather than the default.** Copilot answers the same
sentence when every changed file was hidden from it by **content exclusion**, or
when none of the changed file types is one it supports. There the diff is ordinary
code that simply nobody read, and head-pinning does not help — the answer *is* for
the current head. The gate cannot tell that apart from an empty diff, so a
repository with content-exclusion rules should set `unable-to-review: fail` and let
a human look.

Repositories that would rather force a human to look — that case included — set:

```yaml
      - uses: hacker-cb/action-copilot-review-gate@v1
        with:
          unable-to-review: fail
```

which keeps the check red — and says why, immediately, instead of after the full
`wait-minutes`.

Both directions print the body they matched and write the verdict to the job
summary, so a pull request that merged on this answer is legible after the fact.

This is the one list that can **open** a merge rather than hold it, so its markers
are the ones to edit carefully. The defaults keep `wasn't`, which is what tells the
settled answer apart from a transient failure phrased around "was unable to review
any files" — and carry it twice, once per apostrophe, because Copilot mixes the
ASCII and typographic forms inside a single body. A body no marker covers stays
unrecognised and the gate waits, as before — the safe direction. Emptying
`unable-to-review-markers` turns the class off entirely and restores that two-class
behaviour.

## When Copilot changes its review format

It has, and it will again. In August 2026 the review moved from a
`## Pull request overview` heading to a `<details><summary>` block, and later reviews
on the same PR dropped that section entirely, keeping only `Review details`. A gate
matching the old heading alone stops recognising real reviews — and because the marker
is positive, it fails **closed**: merges block rather than a PR sneaking through
unreviewed. That is the direction a merge gate is allowed to break in, but it still
blocks you, so:

- The timeout message prints the bodies it actually saw, next to **both** marker
  lists it matched them against. The log tells you what changed, and which list
  wants the entry.
- Add the new marker to `review-markers` — **add**, don't replace, so PRs mid-flight
  under the old format keep passing. A reworded "nothing to review" answer goes to
  `unable-to-review-markers` the same way; until it does, such a body is simply
  unrecognised and the gate waits, which is the safe direction.
- Both current formats are covered by the defaults, so an upgrade is usually all you
  need.

## Migrating from the vendored gist

Earlier this lived as a gist vendored byte-for-byte into each repository. Replace the
whole vendored file with the workflow at the top of this README. The check keeps its
name, `copilot-review-gate`, so **required status checks need no change** — that is
why this ships as a composite action rather than a reusable workflow, whose check
would be named `<caller job> / copilot-review-gate` and would silently stop satisfying
your ruleset.

The gist itself now carries only that wrapper and a pointer here; its older revisions
remain in its history and are not a working gate against today's Copilot.

What you gain: a fix ships once, here, instead of as a synchronising pull request per
repository — the gap that let one format change break the gate everywhere at once. On
`@v1` it reaches you as soon as the tag moves ([Versions](#versions)).

## Development

```bash
bash tests/classify_test.sh   # review vs settled answer vs refusal, fixture by fixture
bash tests/gate_test.sh       # the whole loop, against a mock gh
```

The review fixtures are **real bodies** captured from live pull requests across four
repositories, including both formats and both kinds of non-review. That matters: this
suite exists because a hand-written fixture would have kept passing while production
broke. A fixture's name declares its verdict — `review-*`, `unable-*` (the settled
"nothing to review"), `notreview-*` (unrecognised), `ignored-*` (not Copilot) — and
`tests/classify_test.sh` reads the marker and reviewer defaults out of `action.yml`,
so editing a default without a fixture to match fails the suite.

One envelope field is not captured. The settled class is pinned to the head commit,
and the capture did not keep the `commit_id` it came with, so that fixture carries a
synthetic one and both suites take their idea of "current head" from that field
rather than repeating it. What the pinning depends on — that a review's `commit_id`
is the branch commit it was left on, not a merge ref — is not something the fixture
can show; it was checked against this repository's own pull requests, where
[#1](https://github.com/hacker-cb/action-copilot-review-gate/pull/1) carries one
Copilot review on an earlier commit and a second on the head, which is exactly the
case the pinning exists for.

The closing scenarios of `tests/gate_test.sh` cover the hard ceiling and the step's
own input validation, which live in `action.yml` rather than in the script — they
read that step's `run:` body out of the file (python3 with PyYAML, the dependency
CI's contract check already uses) and run it against a mock `timeout`.

The repository gates itself with the action from the PR's own head (`uses: ./`), which
is the one check no fixture can stand in for: fixtures say what a review looked like
when captured, the self-gate says what one looks like today. What it exercises live is
the happy path — a review arrives, the gate passes; the refusal, re-request,
settled-answer and closed-PR branches rest on fixtures alone.

## Licence

MIT
