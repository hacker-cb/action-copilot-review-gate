#!/usr/bin/env bash
#
# Classification tests: run scripts/classify.jq over each fixture on its own and
# check the verdict against what the file name declares.
#
#   review-*.json    -> exactly one `review` line
#   notreview-*.json -> exactly one `not-a-review` line
#   ignored-*.json   -> no output at all (the author is not Copilot)
#
# The three review fixtures and both refusal fixtures are REAL bodies, lifted
# from live pull requests across four repositories. That matters: this suite
# exists because Copilot silently changed its review format, and a fixture
# someone wrote by hand would have kept passing while production broke.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FIXTURES="$HERE/fixtures/reviews"

REVIEWERS="$(sed -n '/^      copilot/p' "$ROOT/action.yml" | sed 's/^      //')"
MARKERS="$(sed -n '/^      pull request overview$/p;/^      <summary>review details$/p' "$ROOT/action.yml" | sed 's/^      //')"

[ -n "$REVIEWERS" ] || { echo "FATAL: could not read the reviewers default out of action.yml"; exit 1; }
[ -n "$MARKERS" ] || { echo "FATAL: could not read the review-markers default out of action.yml"; exit 1; }

pass=0
fail=0

check() {
  local name="$1" expected="$2" got="$3" detail="$4"
  if [ "$got" = "$expected" ]; then
    printf '  ok    %-38s %s\n' "$name" "$expected"
    pass=$(( pass + 1 ))
  else
    printf '  FAIL  %-38s expected %-13s got %s\n' "$name" "$expected" "$got"
    [ -n "$detail" ] && printf '        %s\n' "$detail"
    fail=$(( fail + 1 ))
  fi
}

echo "classify.jq — one fixture at a time"
for f in "$FIXTURES"/*.json; do
  name="$(basename "$f" .json)"
  case "$name" in
    review-*)    expected=review ;;
    notreview-*) expected=not-a-review ;;
    ignored-*)   expected=ignored ;;
    *) echo "  FAIL  $name — file name declares no expectation"; fail=$(( fail + 1 )); continue ;;
  esac

  # Each fixture is one review object; wrap it in the array the filter expects.
  # A jq failure must not read as "no review": capture the status explicitly.
  if out="$(jq -s '.' "$f" \
      | REVIEWERS="$REVIEWERS" MARKERS="$MARKERS" jq -r -f "$ROOT/scripts/classify.jq" 2>&1)"; then
    lines="$(printf '%s' "$out" | grep -c . || true)"
    if [ "$lines" = 0 ]; then
      got=ignored
    elif [ "$lines" != 1 ]; then
      got="$lines lines"
    else
      case "$out" in
        review) got=review ;;
        not-a-review*) got=not-a-review ;;
        *) got="unrecognised" ;;
      esac
    fi
    check "$name" "$expected" "$got" "$(printf '%s' "$out" | head -1 | cut -c1-100)"
  else
    check "$name" "$expected" "jq error" "$(printf '%s' "$out" | head -2)"
  fi
done

# The whole corpus at once — the real shape of an API response, and the case
# where one bad row can abort the program and take every finding with it.
echo
echo "classify.jq — the whole corpus in one array"
all="$(jq -s '.' "$FIXTURES"/*.json \
  | REVIEWERS="$REVIEWERS" MARKERS="$MARKERS" jq -r -f "$ROOT/scripts/classify.jq")"
count_fixtures() { # count_fixtures <prefix> — by glob, so a name never reaches a filter
  local prefix="$1" n=0 f
  for f in "$FIXTURES/$prefix"*.json; do [ -e "$f" ] && n=$(( n + 1 )); done
  echo "$n"
}
expected_reviews="$(count_fixtures review-)"
expected_refusals="$(count_fixtures notreview-)"
check "reviews recognised" "$expected_reviews" "$(printf '%s\n' "$all" | grep -c '^review$' || true)" ""
check "refusals held" "$expected_refusals" "$(printf '%s\n' "$all" | grep -c '^not-a-review' || true)" ""

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
