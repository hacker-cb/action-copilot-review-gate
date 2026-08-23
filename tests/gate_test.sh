#!/usr/bin/env bash
#
# End-to-end tests for scripts/gate.sh, driven by the mock `gh` in tests/mock-bin,
# plus the hard ceiling around it — which lives in action.yml, so the last two
# scenarios run that step's own script against a mock `timeout`.
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
pass=0; fail=0; skipped=0

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

# The hard ceiling lives in action.yml, not in gate.sh, so the scenarios at the
# bottom drive the composite step's own script — read out of the file the way
# GitHub reads it rather than by eyeballing indentation, so a step rewritten
# around the `timeout` call is still the thing under test.
action_step_script() { # action_step_script <path> — write the step's `run:` body
  # The step is found by having a `run:`, not by its position: a step added ahead
  # of it would otherwise be extracted instead, silently testing nothing. python3
  # prints its own error, so the line below adds what it cannot know — that
  # PyYAML is the dependency ci.yml's contract check already requires.
  python3 - "$ROOT/action.yml" "$1" <<'PY' || { echo "FATAL: could not read the step's run: body out of action.yml (needs python3 with PyYAML)"; exit 1; }
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in spec['runs']['steps'] if 'run' in s]
if len(steps) != 1:
    sys.exit(f'action.yml has {len(steps)} run steps; this test assumes exactly one')
open(sys.argv[2], 'w').write(steps[0]['run'])
PY
}

run_step() { # run_step <wait-minutes> [poll-seconds] — the step's own script
  local step="$MOCK_DIR/step.sh"   # resolved here: the assignments below are the
                                   # forked process's environment, not this shell's
  PATH="$HERE/mock-bin:$PATH" \
  MOCK_DIR="$MOCK_DIR" \
  GITHUB_ACTION_PATH="$ROOT" \
  REPO="acme/widget" PR="42" \
  REVIEWERS="$REVIEWERS" MARKERS="$MARKERS" \
  WAIT_MINUTES_IN="$1" MAX_REREQUESTS="${MAX_REREQUESTS:-2}" POLL_SECONDS="${2:-30}" \
  bash "$step" > "$MOCK_DIR/out" 2>&1
}
step_status() { local rc=0; run_step "$@" || rc=$?; echo "$rc"; }
found()       { if grep -q "$1" "$MOCK_DIR/out"; then echo found; else echo lost; fi; }
# The duration `timeout` was asked for, from the LAST call: the preflight probe
# does not reach this log, but a scenario running the step twice does.
ceiling_window() {
  sed -n 's/.*[[:space:]]\([0-9][0-9]*s\)[[:space:]][[:space:]]*bash[[:space:]].*/\1/p' \
    "$MOCK_DIR/calls.timeout" 2>/dev/null | tail -1
}
# GNU coreutils' timeout, under either name — the escalation half of the ceiling
# scenario runs the real thing, and BSD/macOS without coreutils has neither.
gnu_timeout() {
  local c
  for c in timeout gtimeout; do
    if command -v "$c" >/dev/null 2>&1 && "$c" --version 2>/dev/null | grep -q coreutils; then
      command -v "$c"; return 0
    fi
  done
  return 1
}
skip() { printf '    skip  %-30s %s\n' "$1" "$2"; skipped=$(( skipped + 1 )); }

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

# ------------------------------------------------------------- the ceiling

scenario "the hard ceiling escalates to SIGKILL"
# Two halves, because with the escalation missing either one alone still passes:
# what the step ASKS `timeout` for, and what that request then does to a child
# that ignores TERM. Without `--kill-after` the second half is the whole bug —
# `timeout` signals once and then waits for the child indefinitely, so a ceiling
# of 17 minutes ends whenever the hung process feels like ending.
action_step_script "$MOCK_DIR/step.sh"
expect "step exit" 0 "$(step_status 15)"

# `|| true` throughout: a step that never reached `timeout`, or a flag that is
# absent, is this test's headline result — not a reason to abort the run under
# `set -e` before anything can be reported.
asked="$(cat "$MOCK_DIR/calls.timeout" 2>/dev/null || true)"
signal_flag="$(printf '%s\n' "$asked" | grep -o -- '--signal=[^[:space:]]*'     | head -1 || true)"
grace_flag="$(printf '%s\n' "$asked"  | grep -o -- '--kill-after=[^[:space:]]*' | head -1 || true)"
window="$(ceiling_window)"

# 15 min + the 30-second poll interval + the two-minute grace. The poll interval
# is in there because the loop sleeps AFTER testing its deadline, so the script
# runs that much past its own window and a ceiling without it would fire first.
expect "ceiling window"    1050s "$window"
expect "escalation armed"  armed "$([ -n "$grace_flag" ] && echo armed || echo absent)"

real_timeout="$(gnu_timeout || true)"
if [ -n "$grace_flag" ] && [ -n "$real_timeout" ]; then
  grace_seconds="${grace_flag##*=}"; grace_seconds="${grace_seconds%s}"
  # A child that ignores TERM. Bash passes an IGNORED disposition on to what it
  # starts, so the `sleep` ignores it too — which is why the group signal alone
  # does not end this, and why it is the shape a stuck `gh` would take.
  cat > "$MOCK_DIR/ignores-term.sh" <<'SH'
trap '' TERM
sleep 60 &
wait
SH
  # The real `timeout`, the flags the step asked for, and a window shortened so a
  # test need not sit out 17 minutes of them.
  started=$SECONDS
  rc=0
  # Through an inner shell, whose stderr is dropped: a shell announces a
  # signal-killed foreground child itself ("Killed: 9"), and here that line is
  # the scenario PASSING — not something a reader should have to scroll past.
  # `exit $?` is what keeps that shell around to absorb the message instead of
  # exec'ing itself away and leaving this one to print it.
  # shellcheck disable=SC2016  # `$@` and `$?` are for the inner shell, by design
  bash -c '"$0" "$@"; exit $?' "$real_timeout" \
    "$signal_flag" "$grace_flag" 1s bash "$MOCK_DIR/ignores-term.sh" 2>/dev/null || rc=$?
  elapsed=$(( SECONDS - started ))
  # 137 is 128 + SIGKILL: killed. 124 would mean terminated and then waited out —
  # the ceiling reporting a timeout only once the child was done anyway.
  expect "killed, not waited out" 137 "$rc"
  expect "killed inside the grace" within \
    "$([ "$elapsed" -le $(( grace_seconds + 5 )) ] && echo within || echo "${elapsed}s")"
elif [ -z "$grace_flag" ]; then
  expect "killed, not waited out"  137    "not run — nothing to escalate with"
  expect "killed inside the grace" within "not run — nothing to escalate with"
else
  # Not a pass and not a failure of this change: without GNU coreutils there is
  # no `timeout` here to escalate with. CI runs on ubuntu, where there is.
  skip "killed, not waited out"  "no GNU timeout on PATH"
  skip "killed inside the grace" "no GNU timeout on PATH"
fi

scenario "the ceiling says which way it ended"
# The step branches on the two statuses `timeout` reports, and 137 arrives only
# once the escalation exists — the branch that used to catch 124 alone would
# have exited silently on it.
action_step_script "$MOCK_DIR/step.sh"
printf '124' > "$MOCK_DIR/timeout.rc"
expect "terminated exit"    124   "$(step_status 15)"
expect "terminated message" found "$(found 'Terminated; failing closed')"
printf '137' > "$MOCK_DIR/timeout.rc"
expect "killed exit"        137   "$(step_status 15)"
expect "killed message"     found "$(found 'killed with SIGKILL')"

scenario "a timeout that cannot escalate is refused up front"
# busybox ships a `timeout` without `--kill-after`. Finding that out at the
# deadline means finding it out from a step that hung; the preflight probes the
# flag instead, and the gate never starts.
action_step_script "$MOCK_DIR/step.sh"
: > "$MOCK_DIR/no-kill-after"
expect "step exit"     1     "$(step_status 15)"
expect "diagnosis"     found "$(found 'does not accept')"
expect "gate not run"  0     "$(count "$MOCK_DIR/calls.timeout")"

scenario "the numeric inputs are validated before anything computes with them"
# Each fails quietly in its own way: the two that reach the ceiling's arithmetic
# expansion die there without an `::error::`, and a non-numeric max-rerequests
# reaches a `[ -lt ]` inside an `if`, where `set -e` does not look — the gate
# then never re-requests and reports "0 of abc allowed" as if that were a budget.
action_step_script "$MOCK_DIR/step.sh"
expect "poll non-numeric"   1     "$(step_status 15 abc)"
expect "poll diagnosis"     found "$(found 'poll-seconds must be a whole number')"
expect "poll zero"          1     "$(step_status 15 0)"
expect "budget non-numeric" 1     "$(MAX_REREQUESTS=abc step_status 15)"
expect "budget diagnosis"   found "$(found 'max-rerequests must be a whole number')"
expect "budget zero is fine" 0    "$(MAX_REREQUESTS=0 step_status 15)"

scenario "a leading zero is read as decimal, not octal"
# `08` dies in an arithmetic expansion ("value too great for base") and `030`
# evaluates there as 24 while `sleep` reads the same string as 30 — a ceiling and
# a loop running on different numbers.
action_step_script "$MOCK_DIR/step.sh"
expect "step exit" 0     "$(step_status 15 030)"
expect "ceiling"   1050s "$(ceiling_window)"
expect "step exit" 0     "$(step_status 15 08)"
expect "ceiling"   1028s "$(ceiling_window)"

echo
echo "passed: $pass, failed: $fail${skipped:+, skipped: $skipped}"
[ "$fail" = 0 ]
