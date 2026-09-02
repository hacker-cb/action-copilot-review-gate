#!/usr/bin/env bash
#
# Tests for scripts/requested.jq — the filter that decides whether Copilot still
# owes the pull request a review, which is what the head-aware gate consults
# instead of re-requesting on a timer.
#
# The fixture is a REAL timeline, captured from this repository's pull request #6,
# and it is the whole reason this suite exists: the obvious field for this question
# — the pull request's `requested_reviewers` — is empty for most of the wait,
# because GitHub clears it when Copilot STARTS reviewing rather than when it
# finishes. A filter written against that field passes every mock a suite can
# invent and then asks for a duplicate review on every real run. What the capture
# pins is the shape the answer actually arrives in.
#
# Everything derived from that fixture is derived, never re-typed: a recapture with
# other timestamps keeps working.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FIXTURE="$HERE/fixtures/timeline/requested-then-reviewed.json"

# The reviewer allowlist, read out of action.yml so that narrowing the shipped
# default without a fixture to match fails here rather than shipping — this filter
# depends on it carrying the spelling GitHub files a REQUEST under, which is not
# the one that authors the review.
REVIEWERS="$(python3 - "$ROOT/action.yml" <<'PY'
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
sys.stdout.buffer.write(spec['inputs']['reviewers']['default'].encode('utf-8'))
PY
)"
[ -n "$REVIEWERS" ] || { echo "FATAL: could not read the reviewers default out of action.yml"; exit 1; }

pass=0
fail=0

check() { # check <name> <expected> <got>
  if [ "$3" = "$2" ]; then
    printf '  ok    %-44s %s\n' "$1" "$2"; pass=$(( pass + 1 ))
  else
    printf '  FAIL  %-44s expected %-8s got %s\n' "$1" "$2" "$3"; fail=$(( fail + 1 ))
  fi
}

# The head every scenario is about, read off the fixture's own review so a
# recapture with another sha keeps working.
HEAD_SHA="$(jq -r '[ .[] | select(.event == "reviewed") | .commit_id ] | last // ""' "$FIXTURE")"
[ -n "$HEAD_SHA" ] || { echo "FATAL: the fixture carries no reviewed commit to pin to"; exit 1; }

state() { # state [head] — timeline on stdin, one word out
  REVIEWERS="$REVIEWERS" HEAD_SHA="${1-$HEAD_SHA}" \
    jq -r -f "$ROOT/scripts/requested.jq" 2>&1
}

echo "requested.jq — the captured timeline"
# The request is at 14:07:32 and the review at 14:11:44, so the capture as it
# stands is the answered state.
check "request answered by a review" absent "$(state < "$FIXTURE")"
# The same capture with the review taken out is the state the gate spends most of
# its wait in — and the state `requested_reviewers` cannot see.
check "request still outstanding" pending \
  "$(jq '[ .[] | select(.event != "reviewed") ]' "$FIXTURE" | state)"

echo
echo "requested.jq — it is an order, not a presence"
# The previous head's review stays on the record forever, so what decides is
# whether a request came AFTER it — appended to the list, which is where GitHub
# puts a later event and how this filter reads "after".
check "a request after the last review" pending \
  "$(jq '. + [{ event: "review_requested", created_at: "2026-09-03T00:00:00Z",
        requested_reviewer: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" | state)"
check "a request before it" absent "$(state < "$FIXTURE")"

echo
echo "requested.jq — a request that was withdrawn"
# Copilot declining, which is not a review still coming: the gate must be free to
# ask again rather than waiting out the window.
check "removal after the request" absent \
  "$(jq '[ .[] | select(.event != "reviewed") ]
      + [{ event: "review_request_removed", created_at: "2026-09-03T00:00:00Z",
           requested_reviewer: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" | state)"

echo
echo "requested.jq — who counts as Copilot"
# Same event, wrong actor. Each of these must read `absent`, or a human — or
# another bot in the Copilot family — could hold the gate's re-request back.
check "a human with the login" absent \
  "$(jq '[ .[] | select(.event == "review_requested") | .requested_reviewer.type = "User" ]' "$FIXTURE" | state)"
check "a sibling Copilot bot" absent \
  "$(jq '[ .[] | select(.event == "review_requested")
          | .requested_reviewer.login = "copilot-swe-agent[bot]" ]' "$FIXTURE" | state)"
# And the spelling that must keep working: this surface says `Copilot`, the
# reviews endpoint says `copilot-pull-request-reviewer[bot]`, and the allowlist
# read out of action.yml above has to cover both.
check "the request spelling still matches" pending \
  "$(jq '[ .[] | select(.event == "review_requested") ]' "$FIXTURE" | state)"

echo
echo "requested.jq — shapes that must not abort the filter"
# A timeline carries events of many kinds, and one bad row aborting the program
# would read as `unknown` to the gate — a state it handles, but by spending a
# request it did not need to spend.
check "an empty timeline"          absent "$(echo '[]' | state)"
check "unrelated events only"      absent "$(echo '[{"event":"labeled"},{"event":"committed"}]' | state)"
check "a null requested_reviewer"  absent \
  "$(echo '[{"event":"review_requested","created_at":"2026-01-01T00:00:00Z","requested_reviewer":null}]' | state)"
check "a review by a deleted user" absent \
  "$(echo '[{"event":"reviewed","submitted_at":"2026-01-01T00:00:00Z","user":null}]' | state)"
# Position, not timestamp: the event is in the list, so a request was made, and a
# missing `created_at` does not unmake it. Reading this as `absent` would have the
# gate ask again for a review already on its way.
check "a request with no timestamp" pending \
  "$(echo '[{"event":"review_requested","requested_reviewer":{"login":"Copilot","type":"Bot"}}]' | state)"

echo
echo "requested.jq — overlapping pushes, and the second-level clock"
# A review of the PREVIOUS head, submitted after the new head was requested.
# It answers nothing about the new head, so the request stays outstanding — and
# reading it as an answer is how a gate asks twice for one commit.
check "a review of another head answers nothing" pending \
  "$(jq '[ .[] | select(.event == "review_requested") ]
      + [{ event: "reviewed", submitted_at: "2026-01-02T00:00:00Z",
           commit_id: "1111111111111111111111111111111111111111",
           user: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" | state)"
# The same two events one second apart in the other order — an answer for THIS
# head — must read as answered.
check "a review of this head does" absent \
  "$(jq --arg h "$HEAD_SHA" '[ .[] | select(.event == "review_requested") ]
      + [{ event: "reviewed", submitted_at: "2026-01-02T00:00:00Z", commit_id: $h,
           user: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" | state)"
# Timeline timestamps carry only seconds, so a refusal and the request the gate
# makes on reading it can share one. Order in the list is what breaks the tie;
# a strict comparison on equal timestamps would report the later request as
# already answered and buy a duplicate at the next check.
check "same second, request last" pending \
  "$(jq --arg h "$HEAD_SHA" '[{ event: "reviewed", submitted_at: "2026-01-01T00:00:00Z",
        commit_id: $h, user: { login: "Copilot", type: "Bot" } },
      { event: "review_requested", created_at: "2026-01-01T00:00:00Z",
        requested_reviewer: { login: "Copilot", type: "Bot" } }]' -n | state)"
check "same second, review last" absent \
  "$(jq --arg h "$HEAD_SHA" '[{ event: "review_requested", created_at: "2026-01-01T00:00:00Z",
        requested_reviewer: { login: "Copilot", type: "Bot" } },
      { event: "reviewed", submitted_at: "2026-01-01T00:00:00Z",
        commit_id: $h, user: { login: "Copilot", type: "Bot" } }]' -n | state)"
# With no head to pin to, any review counts — the shape this filter had before
# the distinction existed, and unreachable from the head-aware gate, which
# refuses to start without a head.
check "no head counts any review" absent "$(state '' < "$FIXTURE")"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
