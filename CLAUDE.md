# CLAUDE.md

A composite GitHub Action that blocks a merge until GitHub Copilot has genuinely
reviewed a pull request. The consumer's workflow runs it in a job, that job's name is
the status check, and a branch ruleset marks that check required. The work is a bash
script and two `jq` filters; at runtime the action needs nothing a GitHub-hosted
runner does not already ship (`gh`, `jq`, GNU `timeout`), though the test suites want
more — see [Tests](#tests).

`README.md` is the reference for behaviour and for every input. This file is the
short version plus the things that are easy to break without noticing.

## Layout

| path | what it owns |
| --- | --- |
| `action.yml` | the input contract, the step preflight, and the hard timeout ceiling |
| `scripts/gate.sh` | the polling loop, both modes, every verdict and the closing diagnosis |
| `scripts/classify.jq` | what each Copilot review IS — genuine, settled "nothing to review", or neither — and whether it is about the current head |
| `scripts/requested.jq` | whether Copilot still OWES this pull request a review of its head, read from the issue timeline |
| `tests/` | three suites, fixtures captured from live pull requests, and `mock-bin/` — the stand-in `gh` and `timeout` the loop runs against |
| `.github/workflows/copilot-review-gate.yml` | the self-gate, and the only place the check name `copilot-review-gate` actually lives |

## Invariants — breaking one of these is a merge gate that stops gating

- **The check name `copilot-review-gate` is a public contract, and nothing here
  enforces it.** The name comes from the job, not from this action — the string
  appears in `action.yml` and `scripts/` nowhere at all, only as the job id and
  `name:` in this repository's own gate workflow and in the README's usage snippet.
  So renaming that job passes every check in CI and silently stops satisfying the
  ruleset that required it. It also stays a *composite action*, never a reusable
  workflow, whose check would be named `<caller job> / copilot-review-gate` and would
  break the same contract a second way.
- **Recognise what a review IS; never blacklist what a failure says.** A positive
  marker is the fail-closed direction: an unrecognised body keeps the gate waiting.
  Both marker lists can nevertheless *open* a merge, by opposite routes, and that is
  what makes them the two to edit carefully: `unable-to-review-markers` ends the wait
  by design, while a `review-markers` entry wide enough to appear in a refusal body
  classifies that refusal as a genuine review — positive markers are tested first
  (`classify.jq`), so a marker that overreaches outranks the settled class and the
  refusal class alike.
- **Nothing reaches the script through `${{ }}` interpolated into a `run:` body.**
  Every value arrives via `env:`, because the other form is a script-injection
  surface.
- **`action.yml` is test input, not just configuration.** `tests/classify_test.sh`
  reads the reviewer allowlist and both marker lists out of it, `tests/requested_test.sh`
  reads the allowlist, `tests/gate_test.sh` extracts the step's whole `run:` body to
  exercise the preflight and the hard ceiling, and `.github/workflows/ci.yml` asserts
  the contract on top — including that `unable-to-review` still defaults to `pass` and
  `require-head-review` to `false`. A default edited without the matching fixture fails
  the suite rather than shipping, and the failure may land in a suite other than the
  one whose input you changed.
- **The reviewer list is an allowlist and demands `type: "Bot"`.** Several apps in the
  Copilot family carry a `copilot` prefix, and for a merge gate one false match costs
  a merge. Copilot also answers to a different login per API surface — the reviews
  endpoint says `copilot-pull-request-reviewer[bot]`, the timeline says `Copilot` —
  and `require-head-review` needs both.

## Tests

```bash
bash tests/classify_test.sh    # review vs settled answer vs refusal, fixture by fixture
bash tests/requested_test.sh   # is a Copilot review still outstanding, on a real timeline
bash tests/gate_test.sh        # the whole loop, against a mock gh
```

All three need `python3` with PyYAML, which is how they read `action.yml`; that is a
test-time dependency and not one the action itself carries.

**Fixtures are captures, not inventions.** The review bodies and the timeline came
from live pull requests, and that is the point rather than a convenience: this suite
exists because a hand-written fixture kept passing while production broke. When a new
case needs covering, capture the *body* from a real pull request
(`gh api .../reviews`, `gh api .../issues/N/timeline`) instead of writing the shape
you expect.

**One field is deliberately not the capture's own.** Two classes are pinned to the
head commit, so `tests/classify_test.sh` takes its idea of "current head" from
`unable-no-files.json`'s `commit_id` and then demands every other head-dependent
fixture carry that same synthetic sha — a fixture landed with the real one it was
captured with aborts the suite with `FATAL: … is not on the corpus head` before the
first assertion runs. Overwrite that field; keep everything else as captured.

In `tests/fixtures/reviews/` a fixture's name declares its verdict: `review-*`,
`unable-*` (the settled "nothing to review"), `notreview-*` (unrecognised),
`ignored-*` (not Copilot). The timeline fixtures are named for what they contain
instead — there is no verdict to declare.

CI also lints the workflows (`actionlint`), the shell (`shellcheck --severity=style`
over `scripts/gate.sh`, the suites and `tests/mock-bin/*`) and asserts that
`action.yml` keeps its contract.

The mocks are part of the contract too: a successful `--add-reviewer` in
`tests/mock-bin/gh` records the review-request event GitHub records, so the request
reads as outstanding on the next poll. Without that, a gate asking again every poll
would look correct to the suite — and duplicate reviews of one commit are the failure
`require-head-review` exists to avoid producing. A change to the re-request path
means a change to the mock.

## Conventions

- **Language per surface**, matching this repository's own history: commit messages
  and pull-request *titles* in English, conventional-commit prefixes (`feat:`,
  `fix:`, `docs:`); pull-request *bodies* in Russian; issue titles and bodies in
  English.
- **Branches**: `<type>/<slug>`, with the issue number where there is one —
  `feat/5-require-head-review`, `docs/pin-by-major-tag`.
- **Comments carry the reasoning, not the restatement.** The existing ones explain why
  a line is the way it is and what broke when it was not; match that register rather
  than annotating what the code plainly does.

## Releasing — `@v1` is a promise, and moving it is the release

`README.md` tells consumers that `@v1` is a **moving major tag** and that a fix
reaches them when the tag moves. That is the whole reason this ships as an action
instead of a vendored file, and it is an obligation on this repository: a merged fix
that nobody tagged has shipped to no one.

So a release is two steps, and neither is optional:

1. Cut the version tag — `v1.<minor>.<patch>`, semver against the previous one.
2. Move `v1` to it.

This is the step that gets skipped, and skipping it is invisible: nothing fails, the
work simply reaches nobody. It has already happened once at scale — `v1` and `v1.0.2`
both left on `f3664f2` while `05794b6` and `b6d47b0` sat on `master` behind them, so
`require-head-review` shipped to no consumer at all for as long as that held. Verify
rather than assume: `git tag -l` and `git rev-parse v1^{commit}` against
`origin/master` say whether the debt is open right now.

## Self-gating

The repository gates itself with the action from the pull request's own head
(`uses: ./`, not a released tag). A change that breaks the gate therefore cannot pass
its own gate — the one check no fixture can stand in for. What it exercises live is
the happy path; the refusal, re-request, settled-answer and closed-PR branches rest
on fixtures alone.
