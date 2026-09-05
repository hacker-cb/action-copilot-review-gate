#!/usr/bin/env bash
#
# Wait until GitHub Copilot has genuinely reviewed the pull request, then pass.
# Anything else — no review, or a review record that is not a review — keeps the
# gate waiting and finally fails it, blocking the merge.
#
# The one exception is Copilot's SETTLED answer that there was nothing to review
# ("wasn't able to review any files") ON THE CURRENT HEAD: that is its final word
# on this diff rather than a review still coming, so it ends the wait at once —
# passing by default, failing where `unable-to-review: fail` asks for a human to
# look instead. The same answer against an older commit settles nothing (the
# author may have pushed real code since) and is treated as an unanswered
# review: the gate waits, and re-requests. scripts/classify.jq owns the classes
# and why they are separate.
#
# By default the gate checks "Copilot has reviewed this PR" (any commit), NOT the
# current head commit: Copilot's "Review new pushes" does not reliably re-review
# every push — in particular a push that only applies Copilot's own suggestions
# gets no fresh review — so gating on the exact head SHA would dead-lock the
# common "apply the review feedback, then push" case. Gating on first-review-seen
# closes the real race (auto-merge landing before Copilot's review) without
# false-blocking later pushes.
#
# `require-head-review: true` opts into the stricter reading: only a review of
# the head passes. It buys "merge on green" as a MECHANISM rather than as the
# discipline of whoever drives the merge — a review of the head lands 4-6 min
# after the push that made it, which is routinely after CI has gone green, so a
# gate happy with any review merges a head Copilot never looked at. What pays for
# the dead-lock the paragraph above describes is the re-request: instead of
# spending its budget on a timer, the head-aware gate asks again only when
# nothing is pending — which is exactly the push Copilot decided not to
# re-review — and waits when a request is already outstanding, so it never
# produces the duplicate reviews an unconditional `--add-reviewer` does.
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
# Defaulted rather than required, and the two are not the same claim: an EMPTY
# negative list is a meaningful setting — it turns the class off and restores the
# behaviour this gate had before it existed — so `:?` would refuse a
# configuration that is deliberately available.
: "${UNABLE_MARKERS=}"
# `=` and not `:=` — the default is for an UNSET variable only. A caller wiring
# this to `${{ vars.SOMETHING }}` that does not exist passes an empty string, and
# `:=` would rewrite that to `pass` before the check below ever saw it: a
# misconfigured repo would then silently take the fail-OPEN side of the one input
# whose whole purpose is choosing a side. Empty now reaches the check and stops
# the run, which is what every numeric input in action.yml already does with it.
: "${UNABLE_POLICY=pass}"
# The commit a settled "nothing to review" — and, under `require-head-review`, a
# genuine review — has to be about to count. Defaulted, not required, and empty
# means nothing is ever about the head, so a value lost in the plumbing keeps the
# gate waiting rather than opening it.
: "${HEAD_SHA=}"
# `=` and not `:=`, for the reason spelled out over UNABLE_POLICY: an empty value
# is what an unset `${{ vars.SOMETHING }}` hands over, and it must reach the check
# below rather than be rewritten into one of the two answers on the way.
: "${REQUIRE_HEAD_REVIEW=false}"
# How long the head-aware gate waits before deciding a review request is missing
# rather than merely young. Not a registration lag — where GitHub files the request
# it does so within seconds of the push — but the rate at which this gate reads a
# pull request at all: one timeline call per hold rather than one per poll. NOT an
# input: how often the gate reads is not a repository's choice, and action.yml
# passes it explicitly so that a value in the job's `env:` cannot reach in and
# turn the hold off.
#
# `=` and not `:=`, for the reason spelled out over UNABLE_POLICY: `:=` would
# rewrite an EMPTY value to 120 before the check below ever saw it, so the one
# thing that check exists for — a value that reached the script broken — would be
# the one thing it could not catch.
: "${HEAD_REQUEST_GRACE=120}"

# The check's own summary, in one line per outcome. The log says the same thing,
# but it scrolls, and a gate that PASSED without a review — a draft, a bot author,
# a settled "nothing to review" — is exactly the verdict someone re-reads long
# afterwards and wants legible at a glance. Absent outside Actions (the tests run
# this script directly), and an unwritable path is not worth failing a gate over.
#
# Defined above the first VERDICT this script can reach. What is above it is not
# one: the `:?` guards are broken plumbing, and the step's preflight in action.yml
# runs before this file at all. Both report in the log alone — see the README.
summarize() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  # The braces matter. Redirections are applied left to right, so on a path that
  # cannot be opened `printf >> "$f" 2>/dev/null` reports the failure to the
  # ORIGINAL stderr — the gate's log — before it ever installs the silencer.
  # Grouping puts the open inside what is being silenced.
  { printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; } 2>/dev/null || true
}

# Checked here rather than at the point of use, which a run only reaches after
# Copilot has answered: a typo'd policy would otherwise sit through the whole
# window before saying so, and "pass" is not a safe reading to fall back to for
# a value nobody recognised.
case "$UNABLE_POLICY" in
  pass|fail) ;;
  *) echo "::error::unable-to-review must be 'pass' or 'fail', got '$UNABLE_POLICY'."
     summarize "**Copilot review gate** — **failed**: \`unable-to-review\` must be \`pass\` or \`fail\`, got \`$UNABLE_POLICY\`."
     exit 1 ;;
esac

# Checked here for the same reason, and it is the input that decides what the gate
# is FOR: a typo would otherwise be read as `false` by every test below and the
# run would quietly deliver the default gate to a repository that asked for the
# strict one — passing a merge on a review of some older commit.
case "$REQUIRE_HEAD_REVIEW" in
  true|false) ;;
  *) echo "::error::require-head-review must be 'true' or 'false', got '$REQUIRE_HEAD_REVIEW'."
     summarize "**Copilot review gate** — **failed**: \`require-head-review\` must be \`true\` or \`false\`, got \`$REQUIRE_HEAD_REVIEW\`."
     exit 1 ;;
esac

# Copilot is not requested automatically on a draft or on a bot-authored PR (e.g.
# Dependabot), so waiting for a review there would deadlock on one that is not
# coming. Pass the gate at once. Asked explicitly it does review a bot's pull
# request, so where something in the repository asks, this passes without the
# review that would have arrived — the trade against hanging every Dependabot PR.
# Bots are detected by GitHub's account type rather than a login-suffix glob.
if [ "$IS_DRAFT" = "true" ]; then
  echo "Draft PR: Copilot review not expected — gate passes."
  summarize "**Copilot review gate** — passed: draft pull request, no Copilot review expected."
  exit 0
fi
if [ "$AUTHOR_TYPE" = "Bot" ]; then
  echo "Bot author '$AUTHOR': Copilot is not requested automatically — gate passes."
  summarize "**Copilot review gate** — passed: bot author \`$AUTHOR\`, which Copilot is not automatically requested on."
  exit 0
fi

# The head-aware mode's own preflight, and it belongs BELOW the two exits above
# rather than beside the policy check: neither a draft nor a bot-authored pull
# request reaches the wait at all, so a gate failing one of them over a missing
# head — or annotating every Dependabot run with a dead-lock that cannot happen
# there — would be reporting on a mode that never ran.
if [ "$REQUIRE_HEAD_REVIEW" = true ]; then
  # Without a head there is nothing for a review to be OF, so every review would
  # read as stale and the gate would sit out its whole window to say so. Said
  # here instead, at once, and said about the plumbing rather than about Copilot:
  # what is missing is the value this gate was supposed to be handed.
  if [ -z "$HEAD_SHA" ]; then
    echo "::error::require-head-review is on, but no head commit reached the gate — nothing can be matched against it. Check that \`github.event.pull_request.head.sha\` is present; this event may not be a \`pull_request\`."
    summarize "**Copilot review gate** — **failed**: \`require-head-review\` is on but no head commit reached the gate."
    exit 1
  fi
  # The one number action.yml's preflight does not validate, because it is not an
  # input — but the failure it has is the quiet one every input there is checked
  # against: a non-numeric value makes the `[ ... -ge ... ]` below return 2, which
  # `set -e` does not look at inside an `if`, and the whole re-request branch is
  # then switched off without a word. Under this mode that is the dead-lock.
  case "$HEAD_REQUEST_GRACE" in ''|*[!0-9]*)
    echo "::error::HEAD_REQUEST_GRACE must be a whole number of seconds, got '$HEAD_REQUEST_GRACE'."
    summarize "**Copilot review gate** — **failed**: \`HEAD_REQUEST_GRACE\` must be a whole number, got \`$HEAD_REQUEST_GRACE\`."
    exit 1 ;;
  esac
  # Not fatal, and deliberately not an error: a budget of zero is a legitimate
  # setting for the default gate, where Copilot's automatic request is the only
  # one that matters. Under `require-head-review` it removes the very mechanism
  # that keeps a push Copilot chose not to re-review from dead-locking the merge,
  # which is worth a line on the run page before it costs someone an admin bypass.
  if [ "$MAX_REREQUESTS" -lt 1 ]; then
    echo "::warning::require-head-review is on with max-rerequests: 0. A push Copilot does not re-review on its own — one that only applies its own suggestions, for instance — then has nothing to unblock it, and the gate will fail closed on a pull request nobody can merge without a bypass."
  fi
  # The same mechanism, switched off by a different number: the gate holds its
  # first read for HEAD_REQUEST_GRACE seconds, and a window no longer than that
  # hold ends before the read ever happens.
  if [ "$WAIT_SECONDS" -le "$HEAD_REQUEST_GRACE" ]; then
    echo "::warning::require-head-review is on with a wait window of ${WAIT_SECONDS}s, which is not longer than the ${HEAD_REQUEST_GRACE}s the gate waits before its first re-request — so it will never make one. Raise wait-minutes."
  fi
fi

# Three separate error logs, because they have different lifetimes and one used
# to eat the other: the poll's stderr is truncated every iteration (only the last
# failure is interesting), while a re-request failure must survive until the
# timeout prints it. Sharing one file meant a successful poll erased the very
# error the timeout message promised to show.
#
# The pull request read gets the third for exactly that reason. It happens
# between polls, so writing into the poll's log would have the next poll truncate
# it — and the timeout's "see the API stderr below" would then point at nothing,
# which is the failure this separation already exists to prevent.
api_err="$(mktemp)"
req_err="$(mktemp)"
pull_err="$(mktemp)"
seen_bodies="$(mktemp)"
trap 'rm -f "$api_err" "$req_err" "$pull_err" "$seen_bodies"' EXIT

# Fetch every review on the PR as one flattened JSON array.
# --paginate with no --jq gives one array per page; `jq -s add` joins them, so
# classification sees the whole set rather than the first hundred. gh's stderr is
# captured rather than discarded, so a persistent API failure is surfaced at the
# timeout instead of masquerading as "no review yet".
fetch_reviews() {
  gh api --paginate "repos/$REPO/pulls/$PR/reviews?per_page=100" 2>"$api_err" \
    | jq -s 'add // []' 2>/dev/null
}

# One poll's verdicts, one line per Copilot review. Non-zero when the poll did
# not answer at all — which is NOT the same as "no reviews", and the difference
# decides whether the caller may act on the silence.
classify_reviews() {
  local raw kinds
  raw="$(fetch_reviews)" || return 1
  [ -n "$raw" ] || return 1
  kinds="$(printf '%s' "$raw" \
    | REVIEWERS="$REVIEWERS" MARKERS="$MARKERS" UNABLE_MARKERS="$UNABLE_MARKERS" \
      HEAD_SHA="$HEAD_SHA" \
      jq -r -f "$ACTION_PATH/scripts/classify.jq" 2>>"$api_err")" || return 1
  printf '%s' "$kinds"
}

# Whether Copilot still OWES this pull request a review — `pending`, `absent`, or
# `unknown` when the timeline could not be read. Only the head-aware gate asks, at
# most once per HEAD_REQUEST_GRACE and not at all once the re-request budget is
# spent: on the default gate it would be an API call per poll to answer a question
# nothing there acts on.
#
# The TIMELINE, and not the pull request's `requested_reviewers`, which is the
# obvious field and the wrong one: GitHub clears it when Copilot starts the review
# rather than when it finishes, so it reads empty for most of the wait. Measured
# on this repository's pull request #6 — requested 14:07:32, work started 14:08:10,
# review posted 14:11:44. scripts/requested.jq carries the measurement and owns
# what counts as Copilot on this surface, where the bot has a third spelling again.
request_state() {
  local out
  if out="$(gh api --paginate "repos/$REPO/issues/$PR/timeline?per_page=100" 2>>"$pull_err" \
      | jq -s 'add // []' 2>>"$pull_err" \
      | REVIEWERS="$REVIEWERS" HEAD_SHA="$HEAD_SHA" \
        jq -r -f "$ACTION_PATH/scripts/requested.jq" 2>>"$pull_err")"; then
    case "$out" in
      pending|absent) printf '%s' "$out"; return 0 ;;
    esac
  fi
  # Never the third answer by accident: an unreadable timeline must not read as
  # "no request is pending", which is the reading that spends the budget.
  printf 'unknown'
}

# Ask Copilot again. Shared by both modes, because what differs between them is
# WHEN to ask and what to say afterwards — never how. Advances the budget and
# owns the failure notice; the caller owns the success line and its own
# bookkeeping. Non-zero means the request did not go through.
send_rerequest() {
  if gh pr edit "$PR" --repo "$REPO" --add-reviewer "@copilot" >/dev/null 2>>"$req_err"; then
    rerequested=$(( rerequested + 1 ))
    failed_notice=0
    return 0
  fi
  if [ "$failed_notice" = 0 ]; then
    # Not fatal, and not final: the next poll tries again. Announced once per
    # run of failures so a persistent one does not flood the log.
    echo "Could not re-request the review — will retry on the next poll (API error shown at timeout)."
    failed_notice=1
  fi
  return 1
}

reported=0        # refusals already announced in the log
stale_reported=0  # stale settled answers already announced
stale_review_reported=0  # reviews of an older commit already announced
answered=0        # refusals a re-request was actually SENT for
rerequested=0     # successful re-requests, against MAX_REREQUESTS
failed_notice=0   # whether the current run of request failures was announced
pending_reported=0  # whether the current run of "already requested" was announced
unknown_reported=0  # whether an unreadable request state was announced
# `$SECONDS`, not 0: bash imports SECONDS from the environment when a caller
# exported one, and the counter then starts at that value rather than at zero. A
# zero here would read as "the grace elapsed long ago" on the very first poll,
# collapsing the hold to nothing.
checked_at=$SECONDS # when the request state was last read, for HEAD_REQUEST_GRACE
request_state_seen=""  # the last answer request_state() gave, for the timeout

deadline=$(( SECONDS + WAIT_SECONDS ))
echo "Waiting up to $WAIT_LABEL for a Copilot review of PR #$PR ..."

# A do-while: classify FIRST, then decide whether there is time left to poll
# again. A plain `while [ $SECONDS -lt $deadline ]` would skip the body entirely
# when the window is zero, and report a timeout without ever having looked.
while :; do
  # The request state is read FIRST, and that order is the whole of what closes
  # the race: read after the reviews, a review landing between the two shows up
  # in neither — the poll predates it, and the field it cleared reads as
  # `absent`, so the gate asks for a review it already has. Read before them, the
  # reviews are always the newer of the two, and a review that lands in the gap
  # is simply found by this poll.
  #
  # Guarded by the budget and the debounce rather than by anything the poll says,
  # because both are answerable without it — which is also what keeps the read
  # lazy: at most one per HEAD_REQUEST_GRACE, and none at all once the budget is
  # spent or on the default gate, where nothing acts on the answer.
  state_fresh=0
  checked_before=$checked_at
  if [ "$REQUIRE_HEAD_REVIEW" = true ] \
     && [ "$SECONDS" -lt "$deadline" ] \
     && [ "${rerequested:-0}" -lt "$MAX_REREQUESTS" ] \
     && [ $(( SECONDS - checked_at )) -ge "$HEAD_REQUEST_GRACE" ]; then
    checked_at=$SECONDS
    request_state_seen="$(request_state)"
    [ "$request_state_seen" = unknown ] || unknown_reported=0
    state_fresh=1
  fi

  polled=0
  if kinds="$(classify_reviews)"; then polled=1; else kinds=""; fi
  # A state read the poll then made unusable does not get to start the debounce.
  # The branch below needs both halves, so one failed reviews call would
  # otherwise cost a full HEAD_REQUEST_GRACE — two minutes of not asking, bought
  # by an API hiccup rather than by anything about the request.
  if [ "$state_fresh" = 1 ] && [ "$polled" = 0 ]; then
    checked_at=$checked_before
  fi

  head_reviewed=$(printf '%s\n' "$kinds" | grep -c '^review$' || true)
  # `^stale-review` cannot match `^review$`, and neither matches
  # `^stale-unable-to-review`: every anchor here is load-bearing.
  stale_reviewed=$(printf '%s\n' "$kinds" | grep -c '^stale-review' || true)
  # WHICH of the two counts is the mode's whole difference. The default gate has
  # always passed on a review of any commit, and goes on doing so; the head-aware
  # one counts the head's alone. Everything else below — the settled answer, the
  # refusals, the timeout — is shared, because a gate that waits waits the same
  # way whatever it is waiting for.
  if [ "$REQUIRE_HEAD_REVIEW" = true ]; then
    reviewed=$head_reviewed
  else
    reviewed=$(( head_reviewed + stale_reviewed ))
  fi
  settled=$(printf '%s\n' "$kinds" | grep -c '^unable-to-review' || true)
  stale=$(printf '%s\n' "$kinds" | grep -c '^stale-unable-to-review' || true)
  # A settled answer about an older commit is exactly as informative about the
  # current one as a backend apology is — nothing — so it joins the refusals and
  # buys the same re-request, which is what gets Copilot to answer for the head
  # that is actually there. `^unable-to-review` does not match it: the anchor is
  # what keeps the two apart.
  # Split by head like every other class, and for one consumer: the timeout dump,
  # which says whether an unrecognised body was even about the commit being gated.
  # Either kind keeps the gate waiting, so `refused` — what the default gate
  # spends its budget on, and what the log counts — sums them exactly as it
  # always did.
  unrecognised=$(printf '%s\n' "$kinds" | grep -c '^not-a-review' || true)
  stale_unrecognised=$(printf '%s\n' "$kinds" | grep -c '^stale-not-a-review' || true)
  refused=$(( unrecognised + stale_unrecognised + stale ))

  # Only when this poll actually answered. A transient API failure leaves kinds
  # empty, and overwriting here would erase the error replies earlier polls
  # recorded — the timeout would then print no hint that Copilot had answered.
  if [ "$polled" = 1 ]; then
    printf '%s\n' "$kinds" \
      | grep -e '^not-a-review' -e '^stale-not-a-review' -e '^stale-unable-to-review' \
             -e '^stale-review' > "$seen_bodies" || true
  fi

  if [ "${reviewed:-0}" -gt 0 ]; then
    # The head is named only where it was actually required. On the default gate
    # the review that passed may well be of an older commit, and printing a head
    # beside it would claim something the gate never checked.
    if [ "$REQUIRE_HEAD_REVIEW" = true ]; then
      echo "Copilot has reviewed the current head of PR #$PR ($HEAD_SHA) — gate passes."
      summarize "**Copilot review gate** — passed: Copilot reviewed the current head of PR #$PR (\`$HEAD_SHA\`)."
    else
      echo "Copilot has reviewed PR #$PR — gate passes."
      summarize "**Copilot review gate** — passed: Copilot reviewed PR #$PR."
    fi
    exit 0
  fi

  # Checked AFTER a genuine review, so one arriving later — a push that finally
  # gave Copilot something to read — still outranks the settled answer this PR
  # collected earlier. Both directions end the wait here rather than sitting out
  # the window: "nothing to review" is Copilot's final word on this diff, so
  # neither another poll nor another re-request can change it.
  if [ "${settled:-0}" -gt 0 ]; then
    echo "Copilot answered that there is nothing to review in PR #$PR:"
    # `grep` then `sed`, and `[[:space:]]` rather than `\t`: BSD sed reads `\t`
    # in a BRE as a literal `t`, so the substitution simply would not fire — and
    # under `sed -n` that prints nothing at all rather than printing the line
    # unindented. The bodies are the whole point of this branch.
    printf '%s\n' "$kinds" | grep '^unable-to-review' \
      | sed 's/^unable-to-review[[:space:]]*/  /'
    if [ "$UNABLE_POLICY" = "pass" ]; then
      echo "That is a settled answer for this diff, not a review still coming — gate passes (unable-to-review: pass)."
      summarize "**Copilot review gate** — passed: Copilot answered that there was nothing to review in PR #$PR (\`unable-to-review: pass\`)."
      exit 0
    fi
    echo "::error::Copilot found nothing reviewable in PR #$PR and \`unable-to-review\` is set to \`fail\` — gate blocks the merge, so a human reviews it instead."
    summarize "**Copilot review gate** — **failed**: Copilot found nothing reviewable in PR #$PR and \`unable-to-review: fail\` asks for a human review."
    exit 1
  fi

  # Announce a refusal only when the count moves, or a 15-minute wait prints the
  # same line thirty times and buries the one that matters.
  if [ "${refused:-0}" -gt "${reported:-0}" ]; then
    echo "Copilot answered $refused time(s) without reviewing."
    reported=$refused
  fi
  # Said separately, because it reads as a contradiction otherwise: the gate has
  # a "nothing to review" answer in hand and is still waiting.
  if [ "${stale:-0}" -gt "${stale_reported:-0}" ]; then
    if [ -n "$HEAD_SHA" ]; then
      echo "Copilot's \"nothing to review\" answer on PR #$PR is not for the current head ($HEAD_SHA) — it settles an older commit, so the gate keeps waiting."
    else
      # No comparison happened at all, and blaming Copilot for that would send
      # the reader looking in the wrong place: what is missing is the head this
      # gate was supposed to be handed.
      echo "::warning::Copilot answered \"nothing to review\" on PR #$PR, but no head commit reached the gate, so nothing can be settled against it. Check that \`github.event.pull_request.head.sha\` is present — this event may not be a \`pull_request\`."
    fi
    stale_reported=$stale
  fi
  # Only under `require-head-review`: on the default gate a review of an older
  # commit is not news, it is the gate passing. Said with the commit, because
  # which commit it was tells the reader whether this is the ordinary "the review
  # of the last push has not landed yet" or a branch that was force-pushed away
  # from under a review that had already arrived.
  if [ "$REQUIRE_HEAD_REVIEW" = true ] && [ "${stale_reviewed:-0}" -gt "${stale_review_reported:-0}" ]; then
    echo "Copilot has reviewed PR #$PR, but not its current head ($HEAD_SHA) — the gate keeps waiting for a review of the head:"
    printf '%s\n' "$kinds" | grep '^stale-review' | sed 's/^stale-review[[:space:]]*/  reviewed instead: /'
    stale_review_reported=$stale_reviewed
  fi

  # Ask again. That reply is what Copilot sends when its backend failed, and it
  # does not retry on its own — its own review fires no workflow, so nothing else
  # will. Waiting out the window without asking is just a slower way to fail.
  # Only UNRECOGNISED bodies get here: the settled answer above already left, and
  # re-requesting it would be the provable no-op that motivated its own class.
  #
  # `answered` advances only on a SUCCESSFUL request. Advancing it beside the
  # announcement above — which is what the canonical gist did — meant one
  # transient `gh pr edit` failure retired the refusal that triggered it: no
  # further reply was coming, so the guard never opened again and the remaining
  # budget went unspent while the gate sat out the whole window.
  #
  # The head-aware gate asks a different question, so it takes a branch of its
  # own rather than a condition bolted onto this one. There, EVERY class that
  # reaches this point is the same absence — an unrecognised body, a settled
  # answer or a genuine review about an older commit, or no answer at all — and
  # counting them decides nothing. What decides whether asking again would help
  # is whether Copilot already owes this pull request a review.
  if [ "$REQUIRE_HEAD_REVIEW" = true ]; then
    # Both guards, and they answer different questions. `state_fresh` says the
    # state above was read on THIS poll — the budget or the debounce may have
    # skipped it, and acting on a state read minutes ago is acting on a request
    # that has since been answered. `polled` says the reviews were read at all:
    # with `kinds` empty every count is zero, so a head that HAS been reviewed
    # looks unreviewed and the state reads `absent` precisely because Copilot was
    # taken off it when it answered — asking there is the duplicate review this
    # mode exists to prevent.
    if [ "$state_fresh" = 1 ] && [ "$polled" = 1 ]; then
      # A pending request means a review is on its way, and every push measured
      # took 4-6 min to get one — so the gate waits rather than asking again.
      #
      # Nothing overrides that here, and nothing needs to. A refusal is a review
      # record like any other, so the timeline dates it against the request:
      # answered after the request, it makes `pending` false on its own and this
      # branch is not the one taken. That is what the request state being read
      # from the timeline buys — the earlier reading of this gate had to guess at
      # the order from counts, and guessed wrong on a re-run.
      if [ "$request_state_seen" = pending ]; then
        if [ "$pending_reported" = 0 ]; then
          echo "A Copilot review of PR #$PR is already requested and has not arrived yet — waiting rather than asking again."
          pending_reported=1
        fi
      # `absent`: nothing will review this head unless the gate asks — the push
      # Copilot chose not to re-review, or the request that went missing.
      # `unknown`: the timeline was unreachable, so a pending request cannot be
      # ruled IN. Asking anyway is the bounded mistake — `max-rerequests`
      # caps the duplicates, while not asking risks failing a merge over a request
      # nobody ever made.
      else
        if [ "$request_state_seen" = unknown ] && [ "$unknown_reported" = 0 ]; then
          echo "Could not read whether a Copilot review is already requested on PR #$PR — asking anyway, which the re-request budget bounds (API error shown at timeout)."
          unknown_reported=1
        fi
        # The deadline again, and not because the guard above was wrong: the two
        # API calls between them take time, and a request sent after the window
        # closed cannot be answered inside this run — it only leaves an orphan
        # review behind a gate that has already failed.
        # A failed request gives the debounce clock back: `checked_at` was set by
        # the state read above, so leaving it there would hold the next attempt
        # for another full HEAD_REQUEST_GRACE — on a short window, one transient
        # `gh pr edit` failure would spend the whole run without ever asking,
        # with the budget untouched.
        if [ "$SECONDS" -lt "$deadline" ] && send_rerequest; then
          pending_reported=0
          answered=$refused
          # The request now IS the pending one, and the closing diagnosis reads
          # this: left at `absent` it would tell whoever failed the merge that
          # nothing was ever asked for, one line under the gate saying it asked.
          request_state_seen=pending
          echo "Re-requested a Copilot review of head $HEAD_SHA ($rerequested of $MAX_REREQUESTS) — still waiting."
        else
          checked_at=$checked_before
        fi
      fi
    fi
  elif [ "${refused:-0}" -gt "${answered:-0}" ] && [ "${rerequested:-0}" -lt "$MAX_REREQUESTS" ]; then
    if send_rerequest; then
      answered=$refused
      echo "Re-requested a Copilot review ($rerequested of $MAX_REREQUESTS) — still waiting."
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
  summarize "**Copilot review gate** — passed: PR #$PR closed while the gate was waiting."
  exit 0
fi

# fail-closed: no review in the window (or the API stayed unreachable) blocks the
# merge. Surface everything that might explain it.
if [ "$REQUIRE_HEAD_REVIEW" = true ]; then
  echo "::error::Copilot has not reviewed the current head of PR #$PR ($HEAD_SHA) within the timeout (or the GitHub API was unavailable) — gate blocks the merge."
  summarize "**Copilot review gate** — **failed**: no Copilot review of PR #$PR's head \`$HEAD_SHA\` within $WAIT_LABEL."
else
  echo "::error::Copilot has not reviewed PR #$PR within the timeout (or the GitHub API was unavailable) — gate blocks the merge."
  summarize "**Copilot review gate** — **failed**: no Copilot review of PR #$PR within $WAIT_LABEL."
fi
if [ -s "$seen_bodies" ]; then
  # What DID arrive. Either Copilot kept failing — re-request the review — or its
  # review format changed and the `review-markers` input needs a new entry; these
  # bodies say which. A body that is really the settled "nothing to review" under
  # wording no marker covers lands here too, and `unable-to-review-markers` is
  # then the list wanting the new entry.
  #
  # Under `require-head-review` a genuine review can be in this list, so the
  # heading has to name what it was measured against: "none of which is a review"
  # over a line that IS one would send the reader to edit a marker list that
  # matched perfectly well.
  if [ "$REQUIRE_HEAD_REVIEW" = true ]; then
    echo "Copilot posted the following, none of which is a review of head $HEAD_SHA:"
  else
    echo "Copilot posted the following, none of which is a review:"
  fi
  # The marker on the stale ones says only that they were not counted. WHY they
  # were not — an older commit, or no head at all — was said once above, in a
  # branch that knows which of the two it was; repeating a guess here is how a
  # missing input ends up reading as Copilot's fault. The stale REVIEW carries
  # its commit rather than a body excerpt, so the marker reads into it: what
  # follows is what Copilot read instead of the head.
  # The "older commit" label is printed only under `require-head-review`, where a
  # head is guaranteed to exist — the preflight refuses the mode without one. On
  # the default gate HEAD_SHA may legitimately be empty, every refusal is then
  # classified stale for want of anything to compare against, and a label saying
  # "about an older commit" would blame Copilot for a comparison that never
  # happened. There the split means nothing, so neither does the label.
  if [ "$REQUIRE_HEAD_REVIEW" = true ]; then
    stale_refusal_label='  (about an older commit) '
  else
    stale_refusal_label='  '
  fi
  sed -e 's/^not-a-review[[:space:]]*/  /' \
      -e "s/^stale-not-a-review[[:space:]]*/$stale_refusal_label/" \
      -e 's/^stale-review[[:space:]]*/  (a genuine review, but of commit) /' \
      -e 's/^stale-unable-to-review[[:space:]]*/  (a "nothing to review" answer, not counted) /' "$seen_bodies"
  echo "Markers a body is matched against (any one is enough):"
  printf '%s\n' "$MARKERS" | sed '/^[[:space:]]*$/d; s/^/  /'
  # Only when there is a list to print: empty is the documented way to turn the
  # class off, and a heading over nothing reads as "configured, just no match".
  if printf '%s\n' "$UNABLE_MARKERS" | grep -q '[^[:space:]]'; then
    echo "Markers for a settled \"nothing to review\" answer, counted only against head ${HEAD_SHA:-unknown}:"
    printf '%s\n' "$UNABLE_MARKERS" | sed '/^[[:space:]]*$/d; s/^/  /'
  fi
fi
echo "Re-requests sent: $rerequested of $MAX_REREQUESTS allowed."
# One last read, because the state the loop left behind can be stale by exactly
# the thing worth reporting: with the budget spent the loop stops looking, and a
# successful send set `pending` on purpose — so an answer that arrived afterwards
# would still be reported as "a review is on its way, raise wait-minutes". One
# call, once, on a run that has already failed.
if [ "$REQUIRE_HEAD_REVIEW" = true ] && [ -n "$HEAD_SHA" ]; then
  request_state_seen="$(request_state)"
fi
# Which of the two head-aware failures this was, and they want opposite fixes: a
# review that was requested and had not landed says the window is too short,
# while one that was never pending says nothing was going to review this head —
# check that the ruleset's "Automatically request Copilot code review" is on, and
# that `max-rerequests` left the gate something to ask with.
if [ "$REQUIRE_HEAD_REVIEW" = true ] && [ -n "$request_state_seen" ]; then
  # The failed-request case first, because it is the one the state cannot show:
  # `absent` is equally what a gate that never managed to ask sees, and sending
  # that reader to the ruleset would have them fix a setting that was never the
  # problem. The errors themselves are printed further down.
  if [ "${rerequested:-0}" = 0 ] && [ -s "$req_err" ]; then
    echo "No Copilot review was pending, and every attempt to ask for one failed — the re-request errors below are what to read, not the ruleset."
  else
    case "$request_state_seen" in
      pending) echo "A Copilot review was still pending when the window closed — it was asked for and had not arrived; \`wait-minutes\` is the number to raise." ;;
      absent)  echo "No Copilot review was pending when the gate last looked, so nothing was going to review this head on its own — check that the branch ruleset has \"Automatically request Copilot code review\" enabled." ;;
      *)       echo "Whether a Copilot review was pending could not be read — see the API stderr below." ;;
    esac
  fi
fi
if [ -s "$req_err" ]; then
  echo "Re-request errors:"
  cat "$req_err"
fi
if [ -s "$api_err" ]; then
  echo "Last reviews-API stderr:"
  cat "$api_err"
fi
if [ -s "$pull_err" ]; then
  # Named apart from the reviews poll's, because they fail for different reasons
  # and only one of them is about this mode: a timeline the gate cannot read is
  # what turns every request check into `unknown`.
  echo "Timeline read errors:"
  cat "$pull_err"
fi
exit 1
