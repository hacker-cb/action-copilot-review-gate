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
| `wait-minutes` | `15` | How long to wait for the first genuine review before failing closed. The job's hard ceiling is derived from this, so there is no second timeout to keep in sync. |
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

What you gain: a fix reaches every repository by moving one tag, instead of a
synchronising pull request per repository — the gap that let a format change break the
gate everywhere at once.

## Development

```bash
bash tests/classify_test.sh   # review vs refusal, fixture by fixture
bash tests/gate_test.sh       # the whole loop, against a mock gh
```

The review fixtures are **real bodies** captured from live pull requests across four
repositories, including both formats and both kinds of refusal. That matters: this
suite exists because a hand-written fixture would have kept passing while production
broke. `tests/classify_test.sh` reads the marker and reviewer defaults out of
`action.yml`, so editing a default without a fixture to match fails the suite.

The repository gates itself with the action from the PR's own head (`uses: ./`), which
is the one check no fixture can stand in for: fixtures say what a review looked like
when captured, the self-gate says what one looks like today.

## Licence

MIT
