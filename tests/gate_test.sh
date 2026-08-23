#!/usr/bin/env bash
#
# End-to-end tests for scripts/gate.sh, driven by the mock `gh` in tests/mock-bin.
#
# What each scenario is really asserting is the DIRECTION the gate fails in: an
# unreviewed PR must never pass, and a genuine review must never be held. The
# refusal-retry scenarios additionally cover the failure that the canonical gist
# shipped with — a transient re-request error retiring the refusal that triggered
# it, so the remaining budget went unspent and the gate sat out its whole window.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FIXTURES="$HERE/fixtures/reviews"
WORK="$HERE/.tmp"

REVIEWERS=$'copilot-pull-request-reviewer[bot]\ncopilot'
MARKERS=$'pull request overview\n<summary>review details'

rm -rf "$WORK"; mkdir -p "$WORK"
pass=0; fail=0

# Build a reviews array out of named fixtures: arr <n> <fixture> [<fixture>...]
arr() {
  local n="$1"; shift
  local files=()
  for f in "$@"; do files+=("$FIXTURES/$f.json"); done
  if [ "${#files[@]}" = 0 ]; then echo '[]' > "$MOCK_DIR/reviews.$n.json"
  else jq -s '.' "${files[@]}" > "$MOCK_DIR/reviews.$n.json"; fi
}

run_gate() { # run_gate <wait-seconds> <poll-seconds> [env assignments...]
  local wait="$1" poll="$2"; shift 2
  PATH="$HERE/mock-bin:$PATH" \
  MOCK_DIR="$MOCK_DIR" \
  REPO="acme/widget" PR="42" ACTION_PATH="$ROOT" \
  REVIEWERS="$REVIEWERS" MARKERS="$MARKERS" \
  WAIT_SECONDS="$wait" WAIT_LABEL="${wait}s" POLL_SECONDS="$poll" \
  MAX_REREQUESTS="${MAX_REREQUESTS:-2}" \
  "$@" \
  bash "$ROOT/scripts/gate.sh" > "$MOCK_DIR/out" 2>&1
}

expect() { # expect <label> <expected> <got>
  if [ "$3" = "$2" ]; then
    printf '    ok    %-30s %s\n' "$1" "$2"; pass=$(( pass + 1 ))
  else
    printf '    FAIL  %-30s expected %-12s got %s\n' "$1" "$2" "$3"; fail=$(( fail + 1 ))
    sed 's/^/          | /' "$MOCK_DIR/out" | head -14
  fi
}

scenario() { MOCK_DIR="$WORK/$1"; mkdir -p "$MOCK_DIR"; echo "  $1"; }
count()   { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
edits()   { count "$MOCK_DIR/calls.edit"; }
polls()   { count "$MOCK_DIR/calls.reviews"; }
status()  { local rc=0; run_gate "$@" || rc=$?; echo "$rc"; }

# ---------------------------------------------------------------- happy paths

scenario "a genuine review passes at once"
arr 1 review-new-format-first
expect "exit"        0 "$(status 3 1)"
expect "re-requests" 0 "$(edits)"

scenario "an old-format review still passes"
arr 1 review-old-format-heading
expect "exit" 0 "$(status 3 1)"

scenario "a re-review with no overview section passes"
arr 1 review-new-format-rereview
expect "exit" 0 "$(status 3 1)"

# ------------------------------------------------------- refusals and retries

scenario "one refusal buys exactly one re-request"
# The budget is spent on NEW refusals, not on elapsed time: having asked once for
# this refusal, the gate waits for an answer rather than nagging every poll.
arr 1 notreview-backend-error
expect "exit"        1 "$(status 3 1)"
expect "re-requests" 1 "$(edits)"

scenario "a second refusal buys a second re-request"
arr 1 notreview-backend-error
arr 2 notreview-backend-error notreview-no-files
expect "exit"        1 "$(status 4 1)"
expect "re-requests" 2 "$(edits)"

scenario "a refusal followed by a review passes"
arr 1 notreview-backend-error
arr 2 notreview-backend-error review-new-format-first
expect "exit"        0 "$(status 4 1)"
expect "re-requests" 1 "$(edits)"

scenario "a failed re-request is retried on the next poll"
# THIS is the regression the canonical gist carries: the first `gh pr edit` fails,
# and the refusal that triggered it must NOT be retired by that failure.
arr 1 notreview-backend-error
printf '1' > "$MOCK_DIR/edit.1.rc"   # first attempt fails ...
printf '0' > "$MOCK_DIR/edit.2.rc"   # ... the retry succeeds
expect "exit"                  1 "$(status 4 1)"
expect "attempts (1 failed)"   2 "$(edits)"
expect "error survives to log" found \
  "$(grep -q 'mock re-request failure' "$MOCK_DIR/out" && echo found || echo lost)"
expect "retry counted once"    1 \
  "$(grep -c 'Re-requested a Copilot review' "$MOCK_DIR/out" || true)"

scenario "a re-request that keeps failing is announced once"
arr 1 notreview-backend-error
for i in 1 2 3 4 5 6 7 8; do printf '1' > "$MOCK_DIR/edit.$i.rc"; done
expect "exit" 1 "$(status 3 1)"
expect "notices" 1 "$(grep -c 'will retry on the next poll' "$MOCK_DIR/out" || true)"

scenario "the no-files refusal is a refusal too"
arr 1 notreview-no-files
expect "exit" 1 "$(status 3 1)"

# ------------------------------------------------------------- nothing passes

scenario "no reviews at all fails closed"
arr 1
expect "exit"        1 "$(status 3 1)"
expect "re-requests" 0 "$(edits)"

scenario "impostors alone fail closed"
arr 1 ignored-sibling-copilot-bot ignored-human-quoting-marker ignored-deleted-account
expect "exit"        1 "$(status 3 1)"
expect "re-requests" 0 "$(edits)"

scenario "an unreachable API fails closed"
arr 1
printf '1' > "$MOCK_DIR/reviews.1.rc"
expect "exit" 1 "$(status 3 1)"
expect "stderr surfaced" found \
  "$(grep -q 'mock API failure' "$MOCK_DIR/out" && echo found || echo lost)"

scenario "a deleted account does not abort the filter"
# `"user": null` beside a real review: the review must still be found. Read
# without `?` and `// ""` this row kills the program, which reads as "no review".
arr 1 ignored-deleted-account review-new-format-first
expect "exit" 0 "$(status 3 1)"

# ------------------------------------------------------------- early exits

scenario "a draft PR passes without asking anyone"
arr 1
expect "exit"   0 "$(IS_DRAFT=true status 3 1)"
expect "polls"  0 "$(polls)"

scenario "a bot-authored PR passes without asking anyone"
arr 1
expect "exit"  0 "$(AUTHOR_TYPE=Bot AUTHOR='dependabot[bot]' status 3 1)"
expect "polls" 0 "$(polls)"

scenario "a PR closed mid-wait passes instead of going red"
arr 1
printf 'closed' > "$MOCK_DIR/state"
expect "exit" 0 "$(status 3 1)"

# ------------------------------------------------------------------ budget

scenario "max-rerequests is honoured"
arr 1 notreview-backend-error
expect "exit"        1 "$(MAX_REREQUESTS=1 status 4 1)"
expect "re-requests" 1 "$(edits)"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
