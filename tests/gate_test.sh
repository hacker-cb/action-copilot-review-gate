#!/usr/bin/env bash
#
# End-to-end tests for scripts/gate.sh, driven by the mock `gh` in tests/mock-bin,
# plus the hard ceiling and the numeric-input validation around it — those live in
# action.yml, so the closing scenarios run that step's own script against a mock
# `timeout`.
#
# What each scenario is really asserting is the DIRECTION the gate fails in: an
# unreviewed PR must never pass, and a genuine review must never be held. The
# refusal-retry scenarios additionally cover the failure that the canonical gist
# shipped with — a transient re-request error retiring the refusal that triggered
# it, so the remaining budget went unspent and the gate sat out its whole window.
#
# The settled-answer scenarios cover the third class: Copilot's final "there was
# nothing here to review", which must END the wait rather than join the refusals
# that keep it going — in whichever direction `unable-to-review` points, and only
# while it is about the head the gate was handed. The same answer about an older
# commit has to fall back among the refusals, or a pull request that once had
# nothing to review would clear the gate forever after.
#
# The head-aware scenarios cover `require-head-review`, where the direction to
# assert is the one the default gate deliberately does not: a review of an older
# commit must NOT pass. They also cover what pays for that strictness — the gate
# asks again only when GitHub has no review request outstanding, so a scenario
# with one pending must spend no budget at all, and the mock puts the reviewer
# back after a successful request precisely so a spending loop would show up here.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FIXTURES="$HERE/fixtures/reviews"
WORK="$HERE/.tmp"

REVIEWERS=$'copilot-pull-request-reviewer[bot]\ncopilot'
MARKERS=$'pull request overview\n<summary>review details'
# HEAD_REQUEST_GRACE is defaulted to 0 in run_gate rather than here: it is a
# debounce on how often the issue timeline is read, not a lag to wait out, and a
# suite honouring it would sit out two minutes per head-aware scenario. The one
# scenario that asserts the debounce sets it explicitly.
#
# Held in a _DEFAULT and not in UNABLE_MARKERS itself: one scenario sets that to
# the empty string to assert the class can be turned off, and a `${VAR:-...}`
# fallback inside run_gate would quietly hand the marker back.
# The typographic apostrophe is embedded, not written as `\u2019`: bash only reads
# that escape from 4.2 on, and macOS still ships 3.2 — where the marker would
# silently become the literal `wasn\u2019t` and the suite would run against a list
# action.yml does not ship.
UNABLE_MARKERS_DEFAULT=$'wasn\'t able to review any files\nwasn’t able to review any files'
# The head the settled class is pinned to — read off the fixture, so a recapture
# with another sha does not need a second edit here.
HEAD_SHA_DEFAULT="$(jq -r '.commit_id // ""' "$FIXTURES/unable-no-files.json")"
[ -n "$HEAD_SHA_DEFAULT" ] || { echo "FATAL: unable-no-files.json carries no commit_id"; exit 1; }

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
  UNABLE_MARKERS="${UNABLE_MARKERS-$UNABLE_MARKERS_DEFAULT}" \
  UNABLE_POLICY="${UNABLE_POLICY-pass}" \
  HEAD_SHA="${HEAD_SHA-$HEAD_SHA_DEFAULT}" \
  REQUIRE_HEAD_REVIEW="${REQUIRE_HEAD_REVIEW-false}" \
  HEAD_REQUEST_GRACE="${HEAD_REQUEST_GRACE-0}" \
  GITHUB_STEP_SUMMARY="${SUMMARY_FILE-}" \
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
# Reads of the timeline — the head-aware gate's request-state check. It reads at
# most once per debounce and never once the budget is spent, so a bounded count is
# an assertion in its own right, and on the default gate it is always zero.
state_reads() { count "$MOCK_DIR/calls.timeline"; }
# An outstanding Copilot review request, in the shape the live API returns it:
# the timeline event, with no Copilot review after it. `requested_reviewers` is
# NOT that shape — GitHub clears it when Copilot starts reviewing rather than when
# it finishes, which is why the gate reads the timeline instead.
pending() {
  jq -n '[{ event: "review_requested",
            created_at: "2026-01-01T00:00:00Z",
            requested_reviewer: { login: "Copilot", type: "Bot" } }]' \
    > "$MOCK_DIR/timeline.json"
}
# The same request, already answered: Copilot reviewed AFTER it was asked, so
# nothing is outstanding. A refusal is a review record like any other, which is
# how the timeline dates one against the request that produced it.
answered_request() {
  # The review carries the head it was left on, because only a review OF THE HEAD
  # answers a request for it: a review of the previous head landing after the new
  # head's request answers nothing about the new one.
  jq -n --arg head "${HEAD_SHA-$HEAD_SHA_DEFAULT}" \
     '[{ event: "review_requested",
         created_at: "2026-01-01T00:00:00Z",
         requested_reviewer: { login: "Copilot", type: "Bot" } },
       { event: "reviewed",
         submitted_at: "2026-01-01T00:05:00Z",
         commit_id: $head,
         user: { login: "Copilot", type: "Bot" } }]' \
    > "$MOCK_DIR/timeline.json"
}
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
# Explicit on both sides — action.yml carries a typographic apostrophe, and
# Python's text mode follows the locale rather than the file.
spec = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
steps = [s for s in spec['runs']['steps'] if 'run' in s]
if len(steps) != 1:
    sys.exit(f'action.yml has {len(steps)} run steps; this test assumes exactly one')
open(sys.argv[2], 'w', encoding='utf-8').write(steps[0]['run'])
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
arr 2 notreview-backend-error notreview-empty-body
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

# --------------------------------------------- the settled "nothing to review"

scenario "a settled 'nothing to review' ends the wait"
# Copilot's final word on this diff. Passing is the default — the alternative
# blocks a merge nothing can unblock — but what matters as much is that it is
# TERMINAL: one poll, no re-request, no sitting out a window on an answer that
# cannot change.
arr 1 unable-no-files
expect "exit"        0     "$(status 3 1)"
expect "re-requests" 0     "$(edits)"
expect "polls"       1     "$(polls)"
expect "says why"    found "$(found 'nothing to review')"

scenario "a repo can ask for a human instead"
arr 1 unable-no-files
expect "exit"        1     "$(UNABLE_POLICY=fail status 3 1)"
expect "re-requests" 0     "$(edits)"
expect "polls"       1     "$(polls)"
expect "diagnosis"   found "$(found 'nothing reviewable')"

scenario "a settled answer stops the re-requests"
# The refusal buys its one re-request; the settled answer that follows ends the
# run instead of spending the rest of the budget on a reply that cannot change.
arr 1 notreview-backend-error
arr 2 notreview-backend-error unable-no-files
expect "exit"        0 "$(status 4 1)"
expect "re-requests" 1 "$(edits)"

scenario "a real review outranks a settled answer"
# A push that finally gave Copilot something to read. The genuine review is
# tested first, so it decides — and the log says which of the two it was.
arr 1 unable-no-files review-new-format-first
expect "exit"   0     "$(status 3 1)"
expect "reason" found "$(found 'has reviewed')"

scenario "a settled answer about an older commit settles nothing"
# The regression both reviewers found: the reviews endpoint returns every review
# the PR ever collected, so a "nothing to review" answer to an empty diff sits
# there after the author pushes real code. Pinned to the head, it stops deciding.
arr 1 unable-no-files
expect "exit"        1     "$(HEAD_SHA=1234567812345678123456781234567812345678 status 3 1)"
expect "re-requests" 1     "$(edits)"
expect "says why"    found "$(found 'not for the current head')"

scenario "a stale settled answer still yields to a real review"
arr 1 unable-no-files
arr 2 unable-no-files review-new-format-first
expect "exit"   0     "$(HEAD_SHA=1234567812345678123456781234567812345678 status 4 1)"
expect "reason" found "$(found 'has reviewed')"

scenario "no head at all settles nothing either"
# HEAD_SHA lost in the plumbing must keep the gate waiting, never open it — and
# say that it was the plumbing, not Copilot: no comparison happened at all.
arr 1 unable-no-files
expect "exit"        1     "$(HEAD_SHA='' status 3 1)"
expect "re-requests" 1     "$(edits)"
expect "blames the input" found "$(found 'no head commit reached the gate')"
expect "not Copilot"      lost  "$(found 'settles an older commit')"

scenario "an empty marker list restores the old behaviour"
# The documented way back to the two-class gate: the same body becomes an
# unrecognised one, which waits and re-requests exactly as it did before.
arr 1 unable-no-files
expect "exit"        1 "$(UNABLE_MARKERS='' status 3 1)"
expect "re-requests" 1 "$(edits)"

scenario "an unrecognised policy is refused before the wait"
# Not at the point of use, which a run only reaches once Copilot has answered:
# a typo'd policy would otherwise sit out the whole window before saying so.
arr 1
expect "exit"      1     "$(UNABLE_POLICY=maybe status 3 1)"
expect "polls"     0     "$(polls)"
expect "diagnosis" found "$(found 'unable-to-review must be')"

scenario "an explicitly empty policy is refused too"
# What `${{ vars.SOMETHING }}` hands over when SOMETHING does not exist. Defaulted
# with `:=` it would have become `pass` — the fail-OPEN side — without a word.
arr 1 unable-no-files
expect "exit"      1     "$(UNABLE_POLICY='' status 3 1)"
expect "polls"     0     "$(polls)"
expect "diagnosis" found "$(found 'unable-to-review must be')"

# ------------------------------------------------------- the head-aware mode

scenario "head mode passes on a review of the head"
arr 1 review-new-format-first
expect "exit"        0     "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "re-requests" 0     "$(edits)"
# ONE read, which is the price of the ordering: the state is read before the
# reviews, so a poll that turns out to carry the review has already paid for it.
# One per debounce and none at all on the default gate is what "lazy" means here
# — a gate reading it every poll would be the thing worth catching.
expect "state reads" 1     "$(state_reads)"
expect "names the head" found "$(found 'reviewed the current head')"

scenario "head mode holds a review of an older commit"
# The whole point of the mode, and the direction the default gate deliberately
# fails in the other way round: Copilot HAS reviewed this pull request, just not
# the code that is on it now.
arr 1 review-new-format-first
expect "exit"        1     "$(REQUIRE_HEAD_REVIEW=true HEAD_SHA=1234567812345678123456781234567812345678 status 3 1)"
expect "says why"    found "$(found 'not its current head')"
expect "names the commit it read" found "$(found 'reviewed instead:')"
expect "dump marks it a review"   found "$(found 'a genuine review, but of commit')"
# ONE request, not one per poll: the mock puts Copilot back on
# `requested_reviewers` after a successful one, exactly as GitHub does, and the
# gate must then stop asking.
expect "re-requests" 1     "$(edits)"

scenario "the default gate still passes on a review of an older commit"
# The compatibility assertion: everything above must change nothing here, or a
# repository that upgrades without setting the input gets the strict gate by
# surprise — on a moving major tag, without a pull request of its own.
arr 1 review-new-format-first
expect "exit"        0 "$(HEAD_SHA=1234567812345678123456781234567812345678 status 3 1)"
expect "re-requests" 0 "$(edits)"
# Zero, and this one stays zero: the default gate acts on nothing the timeline
# says, so reading it would be a call bought for no question.
expect "state reads" 0 "$(state_reads)"

scenario "a review of the head outranks the stale one before it"
# The ordinary shape of a pull request under this mode: the previous push's
# review is still on the record when the current push's arrives.
scenario_head="1111111111111111111111111111111111111111"
jq -s "[ (.[0] | .commit_id = \"$scenario_head\"), .[1] ]" \
  "$FIXTURES/review-old-format-heading.json" "$FIXTURES/review-new-format-first.json" \
  > "$MOCK_DIR/reviews.1.json"
expect "exit"        0 "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "re-requests" 0 "$(edits)"

scenario "a pending request buys no re-request"
# The failure the mode exists to avoid producing: asking again for a review that
# is already on its way is what yields two reviews of one commit, and one of them
# landing after the merge.
arr 1
pending
expect "exit"        1     "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "re-requests" 0     "$(edits)"
expect "says why"    found "$(found 'already requested')"
expect "timeout diagnosis" found "$(found 'still pending when the window closed')"

scenario "nothing pending buys one"
# The other half: the push Copilot did not re-review on its own — the case the
# default gate refuses to require a review for, because nothing would ask.
arr 1
expect "exit"        1     "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "re-requests" 1     "$(edits)"
expect "names the head" found "$(found 'Re-requested a Copilot review of head')"

scenario "the grace debounces the first re-request"
# The debounce is what keeps the gate from re-reading the issue timeline on every
# poll; the scenario below asserts that the first such read waits it out.
arr 1
expect "exit"        1    "$(REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE=30 status 3 1)"
expect "re-requests" 0    "$(edits)"
expect "asked nothing" lost "$(found 'Re-requested')"

scenario "and lets go once it expires"
# The other half, without which the scenario above cannot tell a working debounce
# from a branch that never opens at all: the same wait, long enough to outlast a
# grace, must produce exactly one request.
arr 1
expect "exit"        1     "$(REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE=2 status 6 1)"
expect "re-requests" 1     "$(edits)"
expect "asked once"  found "$(found 'Re-requested a Copilot review of head')"

scenario "a pending request is not re-read every poll"
# The read is lazy, and the debounce is what keeps it that way: measured from the
# last REQUEST, a pending state never moves the clock, so the branch re-opens
# every poll and spends a second API call per poll on an answer that cannot have
# changed. Measured from the last READ, seven polls buy two or three reads plus
# the closing state check. Bounded rather than exact, because the clock is
# whole seconds and a busy machine rounds differently.
arr 1
pending
expect "exit"        1  "$(REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE=3 status 7 1)"
expect "re-requests" 0  "$(edits)"
expect "state reads bounded" ok \
  "$([ "$(state_reads)" -le 3 ] && echo ok || echo "$(state_reads) reads")"

scenario "a refusal answered after the request frees the gate to ask"
# A refusal is a review record like any other, so the timeline dates it against
# the request: answered after it, the request is no longer outstanding and the
# gate is free to ask again — without any count-based guess about which answer
# went with which request.
arr 1 notreview-backend-error
answered_request
expect "exit"        1 "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "re-requests" 1 "$(edits)"

scenario "and a request made after the refusal holds it"
# The other order, which is what a re-run of a job that already answered that
# refusal looks like: the request is the newer of the two, so a review is on its
# way and asking again would only duplicate it. The gate that guessed from counts
# instead of dates got exactly this case wrong.
arr 1 notreview-backend-error
pending
expect "exit"        1 "$(REQUIRE_HEAD_REVIEW=true status 6 1)"
expect "re-requests" 0 "$(edits)"

scenario "a poll the API refused buys no re-request"
# `kinds` is empty when the poll fails, so a head that HAS been reviewed looks
# unreviewed — and the request state says `absent` precisely because Copilot was
# taken off it when it answered. Asking there is the duplicate review this mode
# exists to prevent.
arr 1 review-new-format-first
printf '1' > "$MOCK_DIR/reviews.1.rc"
expect "exit"        1 "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "re-requests" 0 "$(edits)"

scenario "the request state is read before the reviews"
# Not an implementation detail — it is what closes the race. Read the other way
# round, a review landing between the two is in neither: the poll predates it,
# and the field it cleared reads as `absent`, so the gate asks for a review it
# already has. Read in this order the reviews are always the newer of the two,
# and such a review is simply found by the poll that follows.
arr 1
expect "exit"        1 "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "first call"  timeline "$(head -1 "$MOCK_DIR/calls.order")"
expect "second call" reviews "$(sed -n 2p "$MOCK_DIR/calls.order")"

scenario "an unreadable timeline does not read as 'nothing pending'"
# It reads as UNKNOWN, and the gate asks anyway — bounded by the budget. Not
# asking would risk failing a merge over a request that had genuinely gone
# missing, which is the one case a re-request is for.
arr 1
printf '1' > "$MOCK_DIR/timeline.1.rc"
expect "exit"        1     "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
# The BUDGET is what bounds it, and nothing else: while the state stays
# unreadable every poll is another "cannot rule a request in", so the gate spends
# the whole allowance and then stops. Two duplicate reviews at worst, against a
# merge failed over a request that had gone missing.
expect "re-requests" 2     "$(edits)"
expect "says so"     found "$(found 'Could not read whether')"
# Announced once per run of failures, not once per poll: a 15-minute wait would
# otherwise print this line thirty times.
expect "said once"   1     "$(grep -c 'Could not read whether' "$MOCK_DIR/out" || true)"
# The line promises an API error below it. The reviews poll truncates its own log
# every iteration, so a shared file would have the next poll erase exactly what
# was promised — the read gets a log of its own.
expect "stderr survives" found "$(found 'Timeline read errors')"

scenario "a head-mode timeout says nothing was ever pending"
# The two head-mode timeouts want opposite fixes, and the closing line is what
# tells them apart. This is the one where no request was outstanding at all:
# `wait-minutes` would not have helped, and the ruleset setting that requests the
# first review is what to look at.
arr 1
printf '1' > "$MOCK_DIR/reviews.1.rc"
expect "exit"      1     "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "diagnosis" found "$(found 'nothing was going to review this head')"
expect "not the other one" lost "$(found 'still pending when the window closed')"

scenario "a timeout after the gate's own request says the other thing"
# With the budget spent there is no later read, so the state the diagnosis prints
# is whatever the last one left. Left at `absent` it tells whoever failed the
# merge that nothing was ever asked for — one line under the gate saying it asked.
arr 1
expect "exit"        1     "$(MAX_REREQUESTS=1 REQUIRE_HEAD_REVIEW=true status 4 1)"
expect "re-requests" 1     "$(edits)"
expect "diagnosis"   found "$(found 'still pending when the window closed')"
expect "not the other one" lost "$(found 'nothing was going to review this head')"

scenario "the default gate does not label a refusal as older"
# With no head to compare against, every refusal classifies stale — and a label
# reading "about an older commit" would blame Copilot for a comparison that never
# happened. The split has no meaning on this gate, so neither does the label.
arr 1 notreview-backend-error
expect "exit"        1     "$(HEAD_SHA='' status 3 1)"
expect "no false label" lost "$(found 'about an older commit')"
expect "body still shown" found "$(found 'Copilot encountered an error')"

scenario "a failed poll does not cost a whole debounce"
# The branch needs both the state and the poll, so a state read that the poll
# then makes unusable must not start the debounce clock: one API hiccup would
# otherwise buy two minutes of not asking.
arr 1
printf '1' > "$MOCK_DIR/reviews.1.rc"
printf '0' > "$MOCK_DIR/reviews.2.rc"
expect "exit"        1 "$(REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE=3 status 5 1)"
expect "re-requests" 1 "$(edits)"

scenario "a request nobody could send does not blame the ruleset"
# `absent` is also what a gate that never managed to ask sees. Sent to the
# ruleset, the reader fixes a setting that was never the problem.
arr 1
printf '1' > "$MOCK_DIR/edit.1.rc"
expect "exit"       1     "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "names the errors" found "$(found 'every attempt to ask for one failed')"
expect "not the ruleset"  lost  "$(found 'check that the branch ruleset')"

scenario "the closing diagnosis reads the state itself"
# The loop stops looking once the budget is spent — and never looks at all when
# there is none — while a successful send leaves `pending` set on purpose. Either
# way the value the diagnosis would inherit is stale by exactly the thing worth
# reporting, so it takes one read of its own. Here the loop makes none, and the
# closing line still knows a review was outstanding.
arr 1
pending
expect "exit"        1     "$(MAX_REREQUESTS=0 REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "state reads" 1     "$(state_reads)"
expect "diagnosis"   found "$(found 'still pending when the window closed')"

scenario "a settled 'nothing to review' passes in head mode too"
# It is already pinned to the head, so it IS an answer about the head — the same
# final word, and re-requesting it stays the provable no-op it always was.
arr 1 unable-no-files
expect "exit"        0 "$(REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "re-requests" 0 "$(edits)"
expect "state reads" 1 "$(state_reads)"

scenario "head mode refuses without a head commit"
# Every review would read as stale, so the gate would sit out its whole window to
# report a value that was missing before it started.
arr 1 review-new-format-first
expect "exit"      1     "$(REQUIRE_HEAD_REVIEW=true HEAD_SHA='' status 3 1)"
expect "polls"     0     "$(polls)"
expect "diagnosis" found "$(found 'require-head-review is on, but no head commit')"

scenario "an unrecognised require-head-review is refused before the wait"
# Read as `false` it would deliver the default gate to a repository that asked
# for the strict one — a silent downgrade of the thing being configured.
arr 1
expect "exit"      1     "$(REQUIRE_HEAD_REVIEW=maybe status 3 1)"
expect "polls"     0     "$(polls)"
expect "diagnosis" found "$(found 'require-head-review must be')"
expect "empty too" 1     "$(REQUIRE_HEAD_REVIEW='' status 3 1)"

scenario "head mode leaves the draft and bot exits alone"
# The preflight below them, not beside the policy check: neither of these reaches
# the wait, so failing one over a missing head — or annotating every Dependabot
# run with a dead-lock that cannot happen there — reports on a mode that never ran.
arr 1
expect "draft exit"   0    "$(IS_DRAFT=true REQUIRE_HEAD_REVIEW=true HEAD_SHA='' status 3 1)"
expect "no warning"   lost "$(found 'max-rerequests: 0')"
expect "bot exit"     0    "$(AUTHOR_TYPE=Bot AUTHOR='dependabot[bot]' MAX_REREQUESTS=0 REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "still none"   lost "$(found 'max-rerequests: 0')"

scenario "a window shorter than the grace is called out"
# The debounce holds the first request for HEAD_REQUEST_GRACE seconds, so a
# window no longer than that ends before the hold does and the mode's whole
# unblocking mechanism is unreachable.
arr 1
expect "exit"  1     "$(REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE=30 status 3 1)"
expect "warns" found "$(found 'never make one')"

scenario "nothing is asked for once the window is over"
# The loop is a do-while, so the last poll runs after the sleep that crossed the
# deadline. A request sent there cannot be answered inside this run — it just
# leaves a review underway for a gate that has already failed, which is the
# orphan review this mode exists to stop producing.
arr 1
expect "exit"        1 "$(REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE=2 status 2 1)"
expect "re-requests" 0 "$(edits)"

scenario "an inherited SECONDS does not skip the debounce"
# bash imports SECONDS from the environment, so a caller that exported one starts
# the counter high — and a debounce anchored at zero then reads as long expired
# on the first poll, collapsing the debounce to nothing.
arr 1
expect "exit"        1 "$(SECONDS=100000 REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE=120 status 3 1)"
expect "re-requests" 0 "$(edits)"
# One, and it is the closing diagnosis's own read: the LOOP never looked, which
# is the assertion — a debounce that had skipped would have read inside it and
# spent a request off the back of that read.
expect "state reads" 1 "$(state_reads)"

scenario "a non-numeric grace is refused before the wait"
# The one number action.yml's preflight does not validate, because it is not an
# input — and its failure is the quiet one: `[ -ge ]` returns 2, `set -e` does not
# look inside an `if`, and the whole re-request branch switches off in silence.
arr 1
expect "exit"      1     "$(REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE=abc status 3 1)"
expect "polls"     0     "$(polls)"
expect "diagnosis" found "$(found 'HEAD_REQUEST_GRACE must be')"
# And empty, which `:=` would have rewritten to the default before the check ran
# — leaving the one value that reached the script broken as the one it could not
# catch. Same reason `unable-to-review` is defaulted with `=`.
expect "empty too" 1     "$(REQUIRE_HEAD_REVIEW=true HEAD_REQUEST_GRACE='' status 3 1)"

scenario "head mode warns when it has no budget to ask with"
# Not an error — a budget of zero is legitimate on the default gate — but under
# this mode it removes the mechanism that keeps an un-re-reviewed push from
# dead-locking the merge.
arr 1
expect "exit" 1     "$(MAX_REREQUESTS=0 REQUIRE_HEAD_REVIEW=true status 3 1)"
expect "warns" found "$(found 'max-rerequests: 0')"

# ------------------------------------------------------------- the summary

scenario "a passing verdict reaches the check summary"
# `$GITHUB_STEP_SUMMARY` is what the run page shows beside the check. The log
# says the same thing and scrolls; a gate that passed WITHOUT a review is
# precisely the verdict someone re-reads long afterwards.
#
# Asked for by SUMMARY_FILE, never by inheriting the variable itself: under
# Actions it is set for every step, so run_gate passing it through would have
# each of these two dozen gate runs append a verdict to CI's own job summary —
# a run page full of gate verdicts from a test step.
arr 1 unable-no-files
expect "exit"            0 "$(SUMMARY_FILE="$MOCK_DIR/summary.md" status 3 1)"
expect "summary written" found \
  "$(grep -q 'nothing to review' "$MOCK_DIR/summary.md" && echo found || echo lost)"

scenario "a failing verdict reaches it too"
arr 1
expect "exit"            1 "$(SUMMARY_FILE="$MOCK_DIR/summary.md" status 3 1)"
expect "summary written" found \
  "$(grep -q 'no Copilot review' "$MOCK_DIR/summary.md" && echo found || echo lost)"

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
expect "diagnosis"     found "$(found 'hard ceiling needs')"
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
summary="passed: $pass, failed: $fail"
# A numeric test, not `${skipped:+…}`: "0" is a non-empty string, so that
# form appends ", skipped: 0" to every clean run it was meant to leave alone.
[ "$skipped" = 0 ] || summary="$summary, skipped: $skipped"
echo "$summary"
[ "$fail" = 0 ]
