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

state() { # state — timeline on stdin, one word out
  REVIEWERS="$REVIEWERS" jq -r -f "$ROOT/scripts/requested.jq" 2>&1
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
# whether a request came AFTER it. Derived from the fixture's own review time.
newer="$(jq -r '[ .[] | select(.event == "reviewed") | .submitted_at ] | last' "$FIXTURE" \
  | sed 's/T.*/T23:59:59Z/')"
check "a request after the last review" pending \
  "$(jq --arg t "$newer" '. + [{ event: "review_requested", created_at: $t,
        requested_reviewer: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" | state)"
check "a request before it" absent "$(state < "$FIXTURE")"

echo
echo "requested.jq — a request that was withdrawn"
# Copilot declining, which is not a review still coming: the gate must be free to
# ask again rather than waiting out the window.
withdrawn="$(jq -r '[ .[] | select(.event == "review_requested") | .created_at ] | last' "$FIXTURE" \
  | sed 's/T.*/T23:59:59Z/')"
check "removal after the request" absent \
  "$(jq --arg t "$withdrawn" '[ .[] | select(.event != "reviewed") ]
      + [{ event: "review_request_removed", created_at: $t,
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
check "a request with no timestamp" absent \
  "$(echo '[{"event":"review_requested","requested_reviewer":{"login":"Copilot","type":"Bot"}}]' | state)"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
