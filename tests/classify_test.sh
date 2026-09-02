#!/usr/bin/env bash
#
# Classification tests: run scripts/classify.jq over each fixture on its own and
# check the verdict against what the file name declares.
#
#   review-*.json    -> exactly one `review` line, which it earns only while
#                       HEAD_SHA is the commit it was left on — against any other
#                       head the same body is a `stale-review`, and which of the
#                       two clears the gate is `require-head-review`'s call
#   unable-*.json    -> exactly one `unable-to-review` line (Copilot's settled
#                       "there was nothing here to review"), which it earns only
#                       while HEAD_SHA is the commit it was left on
#   notreview-*.json -> exactly one `not-a-review` line (unrecognised: the gate
#                       keeps waiting and re-requests), which like the two above
#                       is the head's spelling — the same body about another
#                       commit is `stale-not-a-review`
#   ignored-*.json   -> no output at all (the author is not Copilot)
#
# The three review fixtures and every refusal fixture are REAL bodies, lifted
# from live pull requests across four repositories. That matters: this suite
# exists because Copilot silently changed its review format, and a fixture
# someone wrote by hand would have kept passing while production broke.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FIXTURES="$HERE/fixtures/reviews"

# The defaults are read out of action.yml so that editing one without a fixture
# to match fails this suite rather than shipping. Read as YAML rather than by
# grepping for the lines themselves: a `sed` keyed to each entry's exact text
# silently returns a SHORT list when a marker is added, and the suite would then
# pass while testing a set of markers the action does not actually ship.
# python3 with PyYAML is what ci.yml's contract check already requires.
read_default() { # read_default <input-name> — that input's default, verbatim
  python3 - "$ROOT/action.yml" "$1" <<'PY'
import sys, yaml
# `encoding='utf-8'`, not the locale's: action.yml carries a typographic
# apostrophe, and Python opens text in the locale encoding — on a machine
# whose locale is not UTF-8 this suite would die reading the defaults it
# exists to keep honest.
spec = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
# And out through the byte stream, for the same reason: stdout is encoded in
# the locale's charset too, so a marker carrying U+2019 dies on the way out
# of a run that read it perfectly well.
sys.stdout.buffer.write(spec['inputs'][sys.argv[2]]['default'].encode('utf-8'))
PY
}

REVIEWERS="$(read_default reviewers)"
MARKERS="$(read_default review-markers)"
UNABLE_MARKERS="$(read_default unable-to-review-markers)"

[ -n "$REVIEWERS" ] || { echo "FATAL: could not read the reviewers default out of action.yml"; exit 1; }
[ -n "$MARKERS" ] || { echo "FATAL: could not read the review-markers default out of action.yml"; exit 1; }
[ -n "$UNABLE_MARKERS" ] || { echo "FATAL: could not read the unable-to-review-markers default out of action.yml"; exit 1; }

# Taken from the fixture rather than written twice: both head-pinned classes are
# pinned to the head commit, so the suite's idea of "current head" IS that
# fixture's `commit_id`, and a fixture recaptured with another sha keeps working.
# Every fixture whose verdict depends on the head carries the SAME synthetic sha,
# so one value serves the whole corpus.
HEAD_SHA="$(jq -r '.commit_id // ""' "$FIXTURES/unable-no-files.json")"
[ -n "$HEAD_SHA" ] || { echo "FATAL: unable-no-files.json carries no commit_id to pin the settled class to"; exit 1; }
for f in "$FIXTURES"/review-*.json "$FIXTURES"/notreview-*.json; do
  [ "$(jq -r '.commit_id // ""' "$f")" = "$HEAD_SHA" ] \
    || { echo "FATAL: $(basename "$f") is not on the corpus head $HEAD_SHA"; exit 1; }
done

classify() { # classify [head-sha] — reviews array on stdin, one verdict line per review
  REVIEWERS="$REVIEWERS" MARKERS="$MARKERS" UNABLE_MARKERS="$UNABLE_MARKERS" \
  HEAD_SHA="${1-$HEAD_SHA}" \
    jq -r -f "$ROOT/scripts/classify.jq"
}

pass=0
fail=0

check() {
  local name="$1" expected="$2" got="$3" detail="$4"
  if [ "$got" = "$expected" ]; then
    printf '  ok    %-38s %s\n' "$name" "$expected"
    pass=$(( pass + 1 ))
  else
    printf '  FAIL  %-38s expected %-16s got %s\n' "$name" "$expected" "$got"
    [ -n "$detail" ] && printf '        %s\n' "$detail"
    fail=$(( fail + 1 ))
  fi
}

verdict() { # verdict — classifier output on stdin, reduced to one word
  local out lines
  out="$(cat)"
  lines="$(printf '%s' "$out" | grep -c . || true)"
  if [ "$lines" = 0 ]; then echo ignored; return; fi
  if [ "$lines" != 1 ]; then echo "$lines lines"; return; fi
  case "$out" in
    review)                   echo review ;;
    stale-review*)            echo stale-review ;;
    unable-to-review*)        echo unable-to-review ;;
    stale-unable-to-review*)  echo stale-unable-to-review ;;
    stale-not-a-review*)      echo stale-not-a-review ;;
    not-a-review*)            echo not-a-review ;;
    *)                        echo unrecognised ;;
  esac
}

echo "classify.jq — one fixture at a time"
for f in "$FIXTURES"/*.json; do
  name="$(basename "$f" .json)"
  case "$name" in
    review-*)    expected=review ;;
    unable-*)    expected=unable-to-review ;;
    notreview-*) expected=not-a-review ;;
    ignored-*)   expected=ignored ;;
    *) echo "  FAIL  $name — file name declares no expectation"; fail=$(( fail + 1 )); continue ;;
  esac

  # Each fixture is one review object; wrap it in the array the filter expects.
  # A jq failure must not read as "no review": capture the status explicitly.
  if out="$(jq -s '.' "$f" | classify 2>&1)"; then
    check "$name" "$expected" "$(printf '%s' "$out" | verdict)" \
      "$(printf '%s' "$out" | head -1 | cut -c1-100)"
  else
    check "$name" "$expected" "jq error" "$(printf '%s' "$out" | head -2)"
  fi
done

# The settled answer, under the OTHER apostrophe. Copilot mixes the ASCII and
# typographic forms inside a single body — `you've` sits beside `repository’s` in
# review-new-format-first — so a marker spanning the apostrophe in "wasn't" would
# match one spelling and miss the other. Derived from the real fixture rather
# than hand-written, so it stays that body and only the apostrophe moves.
echo
echo "classify.jq — the settled answer with a typographic apostrophe"
check "unable-no-files (’)" unable-to-review \
  "$(jq -s '[ .[] | .body |= gsub("\u0027"; "\u2019") ]' "$FIXTURES/unable-no-files.json" \
     | classify | verdict)" ""

# The transient failure the marker must NOT swallow. Same shape, "was unable"
# rather than "wasn't": a marker trimmed past the apostrophe would match both,
# and this list is the one that opens a merge rather than holding it.
echo
echo "classify.jq — a transient failure phrased around the same words"
check "\"was unable to review any files\"" not-a-review \
  "$(jq -s '[ .[] | .body = "Copilot was unable to review any files in this pull request due to an internal error." ]' \
       "$FIXTURES/unable-no-files.json" | classify | verdict)" ""

# A genuine review is split the same way, and it is the split `require-head-review`
# reads: `review` means Copilot read what is on the branch now, `stale-review`
# means it read something else. The detail on that line is the commit, not a body
# excerpt — the body of a real review says nothing about why it was not counted.
echo
echo "classify.jq — a genuine review against another head"
check "another head is a stale review" stale-review \
  "$(jq -s '.' "$FIXTURES/review-new-format-first.json" \
     | classify "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" | verdict)" ""
check "no head is a stale review too" stale-review \
  "$(jq -s '.' "$FIXTURES/review-new-format-first.json" | classify "" | verdict)" ""
check "and it names the commit" $'stale-review\t'"$HEAD_SHA" \
  "$(jq -s '.' "$FIXTURES/review-new-format-first.json" \
     | classify "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")" ""
# A review record with no commit at all — the field is absent on some responses,
# and reporting an empty string where the log promises a commit prints nothing.
check "a review with no commit says so" $'stale-review\t(no commit)' \
  "$(jq -s '[ .[] | del(.commit_id) ]' "$FIXTURES/review-new-format-first.json" | classify)" ""
# One line per review, whatever the field contains. The caller counts `^review$`
# lines, so a commit carrying a newline would print a second line — and a value
# ending in `review` is one the gate counts as a review of the head. GitHub
# generates this field, so nothing here is reachable today; the excerpt branch
# scrubs the same characters for the same reason, and a split protocol is not
# something an API value gets to decide.
check "a newline in the commit cannot forge a line" $'stale-review\tbbbb review' \
  "$(jq -s '[ .[] | .commit_id = "bbbb\nreview" ]' "$FIXTURES/review-new-format-first.json" \
     | classify "aaaa")" ""

# The unrecognised class is split the same way, and for one consumer: the gate's
# baseline. Neither spelling passes anything — but a refusal about the CURRENT
# head is proof that the review request it answers was consumed, while one about
# an earlier commit says nothing about the request outstanding now.
echo
echo "classify.jq — an unrecognised body against another head"
check "another head is a stale refusal" stale-not-a-review \
  "$(jq -s '.' "$FIXTURES/notreview-backend-error.json" \
     | classify "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" | verdict)" ""

# Pinned to the head commit: the same body about an older one settles nothing,
# because the author may have pushed real code since.
echo
echo "classify.jq — the settled answer against another head"
check "another head is stale" stale-unable-to-review \
  "$(jq -s '.' "$FIXTURES/unable-no-files.json" | classify "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" | verdict)" ""
check "no head is stale too" stale-unable-to-review \
  "$(jq -s '.' "$FIXTURES/unable-no-files.json" | classify "" | verdict)" ""

# Emptying the list turns the class off — the documented way back to the two-class
# behaviour this gate had before the settled answer had a class of its own.
check "empty marker list disables it" not-a-review \
  "$(jq -s '.' "$FIXTURES/unable-no-files.json" \
     | REVIEWERS="$REVIEWERS" MARKERS="$MARKERS" UNABLE_MARKERS="" HEAD_SHA="$HEAD_SHA" \
       jq -r -f "$ROOT/scripts/classify.jq" | verdict)" ""

# The excerpt, not just the class. The timeout dump is the only thing that says
# WHAT arrived, and a body of whitespace has to reach it as "(empty body)" — the
# dump trims leading whitespace, so a body reported as itself prints as a blank
# line exactly where the diagnosis was promised.
echo
echo "classify.jq — the excerpt a whitespace-only body reports"
check "empty body says so" $'not-a-review\t(empty body)' \
  "$(jq -s '.' "$FIXTURES/notreview-empty-body.json" | classify)" ""

# The whole corpus at once — the real shape of an API response, and the case
# where one bad row can abort the program and take every finding with it.
echo
echo "classify.jq — the whole corpus in one array"
all="$(jq -s '.' "$FIXTURES"/*.json | classify)"
count_fixtures() { # count_fixtures <prefix> — by glob, so a name never reaches a filter
  local prefix="$1" n=0 f
  for f in "$FIXTURES/$prefix"*.json; do [ -e "$f" ] && n=$(( n + 1 )); done
  echo "$n"
}
check "reviews recognised" "$(count_fixtures review-)" \
  "$(printf '%s\n' "$all" | grep -c '^review$' || true)" ""
check "settled answers held apart" "$(count_fixtures unable-)" \
  "$(printf '%s\n' "$all" | grep -c '^unable-to-review' || true)" ""
check "none of them stale" 0 \
  "$(printf '%s\n' "$all" | grep -c '^stale-unable-to-review' || true)" ""
check "no stale reviews either" 0 \
  "$(printf '%s\n' "$all" | grep -c '^stale-review' || true)" ""
check "refusals held" "$(count_fixtures notreview-)" \
  "$(printf '%s\n' "$all" | grep -c '^not-a-review' || true)" ""
check "none of those stale either" 0 \
  "$(printf '%s\n' "$all" | grep -c '^stale-not-a-review' || true)" ""

echo
echo "passed: $pass, failed: $fail"
[ "$fail" = 0 ]
