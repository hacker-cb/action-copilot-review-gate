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
      # Pinned by commit SHA, version in the comment — see Pinning below.
      - uses: hacker-cb/action-copilot-review-gate@6fc6eded7a975bbe2e5b9a8a1370ae3e003f9470 # v1.0.0
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

### Pinning

`@v1` is a **moving** tag: whatever it points at is what runs. For most actions that
is the convenient half of the trade — a fix reaches you by someone moving one tag.
Here it is sharper, because this action *is* the required check: a tag retargeted,
by accident or by whoever gets hold of the repository, changes what your gate accepts
with no pull request in your repository to review it.

So pin by commit SHA, with the version in a trailing comment — the form used in the
workflow above:

```yaml
      - uses: hacker-cb/action-copilot-review-gate@6fc6eded7a975bbe2e5b9a8a1370ae3e003f9470 # v1.0.0
```

The comment is not decoration: Dependabot reads it, bumps the SHA and rewrites the
comment, so an upgrade arrives as a pull request reviewed like any other — which is
what pinning buys rather than what it costs. Take the SHA from the release you mean
to run, on the [releases page](https://github.com/hacker-cb/action-copilot-review-gate/releases).

`@v1` stays defensible where the check is **not** required, or where you would rather
have fixes land on their own than review them.

### With options

Every input has a working default; set one only when you mean to.

```yaml
      - uses: hacker-cb/action-copilot-review-gate@6fc6eded7a975bbe2e5b9a8a1370ae3e003f9470 # v1.0.0
        with:
          wait-minutes: 20
          max-rerequests: 3
```

| Input | Default | What it does |
|---|---|---|
| `github-token` | `${{ github.token }}` | Reads the PR's reviews and re-requests one. Needs `pull-requests: write`. |
| `wait-minutes` | `15` | How long to wait for the first genuine review before failing closed. The action wraps its own script in `timeout` at this value plus a two-minute grace — see [Timeouts](#timeouts) for what that ceiling does and does not cover. |
| `max-rerequests` | `2` | How many times to ask Copilot again after it answers without reviewing. Only successful requests count. |
| `poll-seconds` | `30` | Seconds between polls of the reviews API. |
| `reviewers` | two logins | Logins that count as Copilot, one per line. An allowlist, never a prefix. |
| `review-markers` | two markers | Body substrings that mark a review as genuine, one per line; any one is enough. |

## What the gate actually checks

It gates on **"Copilot has reviewed this PR"** (any commit), not on the current head
commit. Copilot's "Review new pushes" does not reliably re-review every push — in
particular a push that only applies Copilot's own suggestions gets no fresh review —
so gating on the exact head SHA would dead-lock the common "apply the feedback, then
push" case. Gating on first-review-seen closes the real race without false-blocking
later pushes.

Three cases pass without a review, because requiring one would deadlock: a **draft**
PR, a **bot-authored** PR (Dependabot and friends — Copilot does not review either),
and a PR that was **closed or merged while the gate was waiting**.

The `pull-requests: write` scope buys exactly one operation — adding Copilot back as a
reviewer after it answered without reviewing. The job never checks out your code,
never comments, never merges. On a PR from a fork GitHub issues a read-only token
regardless of what the workflow declares, so the scope grants a fork nothing.

## Timeouts

The action puts a deadline around the script it runs: `timeout` at `wait-minutes`
plus a two-minute grace, escalating to `SIGKILL` ten seconds later if the process
ignores the termination signal. Both numbers come from `wait-minutes`, so there is
nothing to keep in sync — and the script's own window is what fires first, printing
the bodies it saw next to the markers it matched them against before anything kills
it.

That ceiling is the **step's**, not the job's. A composite action cannot set
`timeout-minutes` — only the workflow calling it can — so the ceiling begins when the
step does and covers nothing before that. A runner that stalls checking out your
repository or fetching this action never reaches the step, and what is left is
GitHub's default of **360 minutes**, with your required check pending throughout.

Whether that gap is worth a job-level `timeout-minutes` is your call. It is not a
duplicate of the ceiling above, and it is the only thing covering the gap — but keep
it well clear of `wait-minutes` + 2 min: a backstop that fires first replaces the
gate's diagnosis with a bare cancellation, which tells you nothing about why Copilot
never reviewed. This repository's own gate workflow sets 25 minutes against the
default 15-minute window.

## What the gate does not protect

With `on: pull_request`, GitHub takes the workflow definition from the pull request's
**head** commit. A pull request that edits the gate's own workflow therefore runs its
edited version — including one that passes trivially — while the required check
reports the same green name as always. That is true of every `pull_request` check;
what makes it worth more here is that this one is the check standing between a branch
and its ruleset.

A fork is not the exposure: GitHub issues fork pull requests a read-only token
whatever the workflow declares. A branch in your own repository is.

The defence is not a narrower token scope in the workflow. It is not letting the
workflow change without a review of its own:

- **CODEOWNERS** covering `.github/workflows/**`, with "require review from Code
  Owners" in the branch ruleset, or
- a **push ruleset** with a file-path restriction on `.github/workflows/`.

`pull_request_target` is the other answer, and a real one: it takes the workflow
definition from the base branch, so a pull request cannot run its own edit of the
gate. It is not what this README recommends, because it carries a trap of its own —
the job runs against the base branch with a write-capable token and access to
secrets, so checking out the pull request's code under it hands a fork your
repository. This action checks nothing out, which is what makes the swap thinkable at
all; it has not been exercised in the field, so treat it as an option to verify
rather than a recommendation to follow.

## When Copilot changes its review format

It has, and it will again. In August 2026 the review moved from a
`## Pull request overview` heading to a `<details><summary>` block, and later reviews
on the same PR dropped that section entirely, keeping only `Review details`. A gate
matching the old heading alone stops recognising real reviews — and because the marker
is positive, it fails **closed**: merges block rather than a PR sneaking through
unreviewed. That is the direction a merge gate is allowed to break in, but it still
blocks you, so:

- The timeout message prints the bodies it actually saw, next to the markers it
  matched them against. The log tells you what changed.
- Add the new marker to `review-markers` — **add**, don't replace, so PRs mid-flight
  under the old format keep passing.
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
repository — the gap that let one format change break the gate everywhere at once. It
reaches you by a moved tag if you track `@v1`, or as a Dependabot bump if you pin by
SHA ([Pinning](#pinning)).

## Development

```bash
bash tests/classify_test.sh   # review vs refusal, fixture by fixture
bash tests/gate_test.sh       # the whole loop, against a mock gh
```

The review fixtures are **real bodies** captured from live pull requests across four
repositories, including both formats and both kinds of refusal. That matters: this
suite exists because a hand-written fixture would have kept passing while production
broke. `tests/classify_test.sh` reads the marker and reviewer defaults out of
`action.yml`, so editing a default without a fixture to match fails the suite. The
last two scenarios of `tests/gate_test.sh` cover the hard ceiling, which lives in
`action.yml` rather than in the script — they read that step's `run:` body out of the
file (python3 with PyYAML, the dependency CI's contract check already uses) and run
it against a mock `timeout`.

The repository gates itself with the action from the PR's own head (`uses: ./`), which
is the one check no fixture can stand in for: fixtures say what a review looked like
when captured, the self-gate says what one looks like today. What it exercises live is
the happy path — a review arrives, the gate passes; the refusal, re-request and
closed-PR branches rest on fixtures alone.

## Licence

MIT
