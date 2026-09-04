# CLAUDE.md

A composite GitHub Action that blocks a merge until GitHub Copilot has genuinely
reviewed a pull request. It publishes one status check, `copilot-review-gate`, which
a branch ruleset marks required; the work is a bash script and two `jq` filters, with
no build step and no dependencies beyond what a GitHub-hosted runner already ships
(`gh`, `jq`, GNU `timeout`).

`README.md` is the reference for behaviour and for every input. This file is the
short version plus the things that are easy to break without noticing.

## Layout

| path | what it owns |
| --- | --- |
| `action.yml` | the input contract, the step preflight, and the hard timeout ceiling |
| `scripts/gate.sh` | the polling loop, both modes, every verdict and the closing diagnosis |
| `scripts/classify.jq` | what each Copilot review IS — genuine, settled "nothing to review", or neither — and whether it is about the current head |
| `scripts/requested.jq` | whether Copilot still OWES this pull request a review of its head, read from the issue timeline |
| `tests/` | three suites, plus fixtures captured from live pull requests |

## Invariants — breaking one of these is a merge gate that stops gating

- **The check name `copilot-review-gate` is a public contract.** Consumers name it in
  their rulesets. It stays a *composite action*, never a reusable workflow, whose
  check would be named `<caller job> / copilot-review-gate` and would silently stop
  satisfying every ruleset that requires it.
- **Recognise what a review IS; never blacklist what a failure says.** A positive
  marker is the fail-closed direction: an unrecognised body keeps the gate waiting.
  The one exception is `unable-to-review-markers`, the only list that can *open* a
  merge rather than hold it — edit it with that in mind.
- **Nothing reaches the script through `${{ }}` interpolated into a `run:` body.**
  Every value arrives via `env:`, because the other form is a script-injection
  surface.
- **`action.yml`'s defaults are test input.** `tests/classify_test.sh` reads the
  reviewer allowlist and the markers out of the file, so a default edited without a
  fixture to match fails the suite rather than shipping.
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

**Fixtures are captures, not inventions.** The review bodies and the timeline came
from live pull requests, and that is the point rather than a convenience: this suite
exists because a hand-written fixture kept passing while production broke. When a new
case needs covering, capture it from a real pull request (`gh api .../reviews`,
`gh api .../issues/N/timeline`) instead of writing the shape you expect.

A fixture's name declares its verdict: `review-*`, `unable-*` (the settled "nothing to
review"), `notreview-*` (unrecognised), `ignored-*` (not Copilot).

CI also lints the workflows (`actionlint`), the shell (`shellcheck --severity=style`)
and asserts that `action.yml` keeps its contract.

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

This has been missed before: `v1` sat on `f3664f2` while two feature commits waited
behind it, so `require-head-review` existed on `master` and reached no consumer.
After merging anything user-visible, check `git tag -l` and where `v1` points before
calling the work done.

## Self-gating

The repository gates itself with the action from the pull request's own head
(`uses: ./`, not a released tag). A change that breaks the gate therefore cannot pass
its own gate — the one check no fixture can stand in for. What it exercises live is
the happy path; the refusal, re-request, settled-answer and closed-PR branches rest
on fixtures alone.
