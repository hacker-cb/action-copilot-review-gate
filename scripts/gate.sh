#!/usr/bin/env bash
#
# Wait until GitHub Copilot has genuinely reviewed the pull request, then pass.
# Anything else — no review, or a review record that is not a review — keeps the
# gate waiting and finally fails it, blocking the merge.
#
# The gate checks "Copilot has reviewed this PR" (any commit), NOT the current
# head commit: Copilot's "Review new pushes" does not reliably re-review every
# push — in particular a push that only applies Copilot's own suggestions gets no
# fresh review — so gating on the exact head SHA would dead-lock the common
# "apply the review feedback, then push" case. Gating on first-review-seen closes
# the real race (auto-merge landing before Copilot's review) without
# false-blocking later pushes.
#
# Everything arrives through the environment; see action.yml for the contract.

set -euo pipefail

: "${REPO:?REPO is required}"
: "${PR:?PR is required}"
: "${ACTION_PATH:?ACTION_PATH is required}"
# Seconds, not minutes: the wait window is the one number this script reasons
# about, and minute granularity would make a test wait a real minute to observe a
# timeout. action.yml converts its `wait-minutes` input into this; WAIT_LABEL is
# only how the window is spelled in the log.
: "${WAIT_SECONDS:=900}"
: "${WAIT_LABEL:=${WAIT_SECONDS}s}"
: "${MAX_REREQUESTS:=2}"
: "${POLL_SECONDS:=30}"
: "${IS_DRAFT:=false}"
: "${AUTHOR:=}"
: "${AUTHOR_TYPE:=}"
: "${REVIEWERS:?REVIEWERS is required}"
: "${MARKERS:?MARKERS is required}"

# Copilot does not review drafts or bot-authored PRs (e.g. Dependabot), so
# requiring its review there would deadlock. Pass the gate at once. Bots are
# detected by GitHub's account type rather than a login-suffix glob.
if [ "$IS_DRAFT" = "true" ]; then
  echo "Draft PR: Copilot review not expected — gate passes."
  exit 0
fi
if [ "$AUTHOR_TYPE" = "Bot" ]; then
  echo "Bot author '$AUTHOR': Copilot does not review — gate passes."
  exit 0
fi

# Two separate error logs, because they have opposite lifetimes and one used to
# eat the other: the poll's stderr is truncated every iteration (only the last
# failure is interesting), while a re-request failure must survive until the
# timeout prints it. Sharing one file meant a successful poll erased the very
# error the timeout message promised to show.
api_err="$(mktemp)"
req_err="$(mktemp)"
seen_bodies="$(mktemp)"
trap 'rm -f "$api_err" "$req_err" "$seen_bodies"' EXIT

# Fetch every review on the PR as one flattened JSON array.
# --paginate with no --jq gives one array per page; `jq -s add` joins them, so
# classification sees the whole set rather than the first hundred. gh's stderr is
# captured rather than discarded, so a persistent API failure is surfaced at the
# timeout instead of masquerading as "no review yet".
fetch_reviews() {
  gh api --paginate "repos/$REPO/pulls/$PR/reviews?per_page=100" 2>"$api_err" \
    | jq -s 'add // []' 2>/dev/null
}

reported=0        # refusals already announced in the log
answered=0        # refusals a re-request was actually SENT for
rerequested=0     # successful re-requests, against MAX_REREQUESTS
failed_notice=0   # whether the current run of request failures was announced

deadline=$(( SECONDS + WAIT_SECONDS ))
echo "Waiting up to $WAIT_LABEL for a Copilot review of PR #$PR ..."

# A do-while: classify FIRST, then decide whether there is time left to poll
# again. A plain `while [ $SECONDS -lt $deadline ]` would skip the body entirely
# when the window is zero, and report a timeout without ever having looked.
while :; do
  polled=0
  kinds=""
  if raw="$(fetch_reviews)" && [ -n "$raw" ]; then
    if kinds="$(printf '%s' "$raw" \
        | REVIEWERS="$REVIEWERS" MARKERS="$MARKERS" \
          jq -r -f "$ACTION_PATH/scripts/classify.jq" 2>>"$api_err")"; then
      polled=1
    else
      kinds=""
    fi
  fi

  reviewed=$(printf '%s\n' "$kinds" | grep -c '^review$' || true)
  refused=$(printf '%s\n' "$kinds" | grep -c '^not-a-review' || true)

  # Only when this poll actually answered. A transient API failure leaves kinds
  # empty, and overwriting here would erase the error replies earlier polls
  # recorded — the timeout would then print no hint that Copilot had answered.
  if [ "$polled" = 1 ]; then
    printf '%s\n' "$kinds" | grep '^not-a-review' > "$seen_bodies" || true
  fi

  if [ "${reviewed:-0}" -gt 0 ]; then
    echo "Copilot has reviewed PR #$PR — gate passes."
    exit 0
  fi

  # Announce a refusal only when the count moves, or a 15-minute wait prints the
  # same line thirty times and buries the one that matters.
  if [ "${refused:-0}" -gt "${reported:-0}" ]; then
    echo "Copilot answered $refused time(s) without reviewing."
    reported=$refused
  fi

  # Ask again. That reply is what Copilot sends when its backend failed, and it
  # does not retry on its own — its own review fires no workflow, so nothing else
  # will. Waiting out the window without asking is just a slower way to fail.
  #
  # `answered` advances only on a SUCCESSFUL request. Advancing it beside the
  # announcement above — which is what the canonical gist did — meant one
  # transient `gh pr edit` failure retired the refusal that triggered it: no
  # further reply was coming, so the guard never opened again and the remaining
  # budget went unspent while the gate sat out the whole window.
  if [ "${refused:-0}" -gt "${answered:-0}" ] && [ "${rerequested:-0}" -lt "$MAX_REREQUESTS" ]; then
    if gh pr edit "$PR" --repo "$REPO" --add-reviewer "@copilot" >/dev/null 2>>"$req_err"; then
      rerequested=$(( rerequested + 1 ))
      answered=$refused
      failed_notice=0
      echo "Re-requested a Copilot review ($rerequested of $MAX_REREQUESTS) — still waiting."
    elif [ "$failed_notice" = 0 ]; then
      # Not fatal, and not final: the next poll tries again. Announced once per
      # run of failures so a persistent one does not flood the log.
      echo "Could not re-request the review — will retry on the next poll (API error shown at timeout)."
      failed_notice=1
    fi
  fi

  [ "$SECONDS" -lt "$deadline" ] || break
  sleep "$POLL_SECONDS"
done

# The PR may have closed or merged while this run was waiting; `if:` would only
# have caught the state at start. A red check on something already landed is
# noise, not a verdict. An unreachable API leaves this empty and the run fails
# closed as before.
state_now="$(gh api "repos/$REPO/pulls/$PR" --jq '.state' 2>/dev/null || true)"
if [ "$state_now" = "closed" ]; then
  echo "PR #$PR closed while this run was waiting — nothing left to gate."
  exit 0
fi

# fail-closed: no review in the window (or the API stayed unreachable) blocks the
# merge. Surface everything that might explain it.
echo "::error::Copilot has not reviewed PR #$PR within the timeout (or the GitHub API was unavailable) — gate blocks the merge."
if [ -s "$seen_bodies" ]; then
  # What DID arrive. Either Copilot kept failing — re-request the review — or its
  # review format changed and the `review-markers` input needs a new entry; these
  # bodies say which.
  echo "Copilot posted the following, none of which is a review:"
  sed 's/^not-a-review\t/  /' "$seen_bodies"
  echo "Markers a body is matched against (any one is enough):"
  printf '%s\n' "$MARKERS" | sed '/^[[:space:]]*$/d; s/^/  /'
fi
echo "Re-requests sent: $rerequested of $MAX_REREQUESTS allowed."
if [ -s "$req_err" ]; then
  echo "Re-request errors:"
  cat "$req_err"
fi
if [ -s "$api_err" ]; then
  echo "Last reviews-API stderr:"
  cat "$api_err"
fi
exit 1
