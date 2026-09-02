#!/usr/bin/env bash
#
# Tests for scripts/requested.jq — the filter that decides whether Copilot still
# owes the pull request a review OF ITS CURRENT HEAD, which is what the head-aware
# gate consults instead of re-requesting on a timer.
#
# The fixture is a REAL timeline, captured from this repository's own pull request
# #6: four rounds of push -> request -> review, with the commits, logins and
# timestamps GitHub actually produced. That capture is the point rather than a
# convenience. The obvious field for this question — the pull request's
# `requested_reviewers` — is empty for most of the wait, because GitHub clears it
# when Copilot STARTS reviewing rather than when it finishes; a filter written
# against it passes every mock a suite can invent and then asks for a duplicate
# review on every real run, which is exactly what happened before this capture
# existed.
#
# Everything below is derived from the fixture, never re-typed: a recapture keeps
# working, and a scenario cannot quietly drift from the shape the API sends.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FIXTURE="$HERE/fixtures/timeline/pushes-requests-reviews.json"

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

# The fixture's last push — the head every scenario is about unless it says
# otherwise — and the one before it, for the overlapping-push cases.
HEAD="$(jq -r '[ .[] | select(.event == "committed") ] | last | .sha' "$FIXTURE")"
PREV="$(jq -r '[ .[] | select(.event == "committed") ] | .[-2] | .sha' "$FIXTURE")"
if [ -z "$HEAD" ] || [ -z "$PREV" ]; then
  echo "FATAL: the fixture needs at least two pushes"; exit 1
fi
# Where the last round's request sits, so every cut point below is derived too.
LAST_REQ="$(jq '[ to_entries[] | select(.value.event == "review_requested") | .key ] | last' "$FIXTURE")"
MID=$(( LAST_REQ + 1 ))   # the timeline as of "requested, not yet reviewed"
OTHER=1111111111111111111111111111111111111111

pass=0
fail=0

check() { # check <name> <expected> <got>
  if [ "$3" = "$2" ]; then
    printf '  ok    %-46s %s\n' "$1" "$2"; pass=$(( pass + 1 ))
  else
    printf '  FAIL  %-46s expected %-8s got %s\n' "$1" "$2" "$3"; fail=$(( fail + 1 ))
  fi
}

state() { # state [head] — timeline on stdin, one word out
  REVIEWERS="$REVIEWERS" HEAD_SHA="${1-$HEAD}" \
    jq -r -f "$ROOT/scripts/requested.jq" 2>&1
}

# The fixture as captured ends on an answered request; this cuts it short so a
# scenario can stand in the middle of a round instead.
mid_round() { jq --argjson n "$MID" '.[0:$n]' "$FIXTURE"; }

echo "requested.jq — the captured timeline"
check "the last round, answered"   absent  "$(state < "$FIXTURE")"
check "the last round, mid-review" pending "$(mid_round | state)"

echo
echo "requested.jq — the bound that makes it about THIS head"
# A `review_requested` event names no commit, so the head's own `committed` event
# is the line it has to fall after. Without that bound the previous push's
# outstanding request reads as this head's — and since the review that answers it
# is of the old commit and correctly ignored, the state would stay `pending`
# forever while the gate sat out its window without ever asking.
check "a new push with no request yet" absent \
  "$(jq '. + [{ event: "committed", sha: "cafebabecafebabecafebabecafebabecafebabe",
                committer: { date: "2026-09-02T15:10:00Z" } }]' "$FIXTURE" \
     | state cafebabecafebabecafebabecafebabecafebabe)"
check "and once its request lands"     pending \
  "$(jq '. + [{ event: "committed", sha: "cafebabecafebabecafebabecafebabecafebabe",
                committer: { date: "2026-09-02T15:10:00Z" } },
              { event: "review_requested", created_at: "2026-09-02T15:10:03Z",
                requested_reviewer: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" \
     | state cafebabecafebabecafebabecafebabecafebabe)"

# A rebase or an amend records `head_ref_force_pushed` INSTEAD of a `committed`
# for the rewritten head, so a bound reading only the latter finds nothing, lets
# every historical request count, and hands the gate a `pending` it can never
# clear — the dead-lock again, by a different route.
check "a force-pushed head with no request" absent \
  "$(jq '. + [{ event: "head_ref_force_pushed", created_at: "2026-09-02T15:20:00Z" }]' "$FIXTURE" \
     | state cafebabecafebabecafebabecafebabecafebabe)"
check "and once its request lands"          pending \
  "$(jq '. + [{ event: "head_ref_force_pushed", created_at: "2026-09-02T15:20:00Z" },
              { event: "review_requested", created_at: "2026-09-02T15:20:05Z",
                requested_reviewer: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" \
     | state cafebabecafebabecafebabecafebabecafebabe)"

echo
echo "requested.jq — an answer is a review OF THE HEAD"
# Pushes and reviews overlap: a review of the previous head can be submitted after
# the new head was requested, and it answers nothing about the new one. Reading it
# as an answer is how a gate asks twice for one commit.
check "a review of another head answers nothing" pending \
  "$(jq --arg prev "$PREV" --argjson n "$MID" '(.[0:$n])
      + [{ event: "reviewed", submitted_at: "2026-09-02T15:00:00Z", commit_id: $prev,
           user: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" | state)"
check "a review of this head does"              absent "$(state < "$FIXTURE")"

echo
echo "requested.jq — a request that was withdrawn"
# Copilot declining, which is not a review still coming: the gate must be free to
# ask again rather than waiting out the window.
check "removal after the request" absent \
  "$(jq --argjson n "$MID" '(.[0:$n])
      + [{ event: "review_request_removed", created_at: "2026-09-02T15:00:00Z",
           requested_reviewer: { login: "Copilot", type: "Bot" } }]' "$FIXTURE" | state)"

echo
echo "requested.jq — the second-level clock"
# Timeline timestamps carry no sub-second part, so a refusal and the request the
# gate makes on reading it can share one. Order in the list breaks the tie; a
# comparison on timestamps alone would report the later request as answered and
# buy a duplicate review at the next check.
tie() { # tie <first-event> <second-event> — a push, then those two, same second
  jq -n --arg head "$OTHER" --arg a "$1" --arg b "$2" '
    def ev($kind): if $kind == "reviewed"
      then { event: "reviewed", submitted_at: "2026-09-02T16:00:05Z",
             commit_id: $head, user: { login: "Copilot", type: "Bot" } }
      else { event: "review_requested", created_at: "2026-09-02T16:00:05Z",
             requested_reviewer: { login: "Copilot", type: "Bot" } } end;
    [ { event: "committed", sha: $head, committer: { date: "2026-09-02T16:00:00Z" } },
      ev($a), ev($b) ]'
}
check "same second, request last" pending "$(tie reviewed requested | state "$OTHER")"
check "same second, review last"  absent  "$(tie requested reviewed | state "$OTHER")"

echo
echo "requested.jq — who counts as Copilot"
# Same event, wrong actor. Each must read `absent`, or a human — or another bot in
# the Copilot family — could hold the gate's re-request back indefinitely.
check "a human with the login" absent \
  "$(mid_round | jq 'map(if .event == "review_requested"
        then .requested_reviewer.type = "User" else . end)' | state)"
check "a sibling Copilot bot"  absent \
  "$(mid_round | jq 'map(if .event == "review_requested"
        then .requested_reviewer.login = "copilot-swe-agent[bot]" else . end)' | state)"
# And the spelling that must keep working: this surface says `Copilot`, the
# reviews endpoint says `copilot-pull-request-reviewer[bot]`, and the allowlist
# read out of action.yml above has to cover both.
check "the request spelling still matches" pending "$(mid_round | state)"

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
# missing `created_at` does not unmake it.
check "a request with no timestamp" pending \
  "$(echo '[{"event":"review_requested","requested_reviewer":{"login":"Copilot","type":"Bot"}}]' | state '')"
# With no head to bound against, every request counts and any review answers —
# the shape this filter had before the head entered it, and unreachable from the
# head-aware gate, which refuses to start without a head.
check "no head at all"              absent "$(state '' < "$FIXTURE")"

echo
echo "passed: $pass, failed: $fail  (fixture: $(jq 'length' "$FIXTURE") events, $(jq '[ .[] | select(.event == "committed") ] | length' "$FIXTURE") pushes)"
[ "$fail" = 0 ]
