# Answer one question about a pull request: does Copilot still OWE it a review?
#
# Input:  the timeline array from `GET /repos/{owner}/{repo}/issues/{pr}/timeline`
#         (already flattened across pages by the caller).
# Output: exactly one line — `pending` or `absent`.
#
# One environment variable carries the configuration, one entry per line:
#   REVIEWERS — logins that count as Copilot, the same allowlist classify.jq
#               matches a review's author against
# and one that is a single value:
#   HEAD_SHA  — the pull request's current head commit. Only a review OF THAT
#               COMMIT answers a request for it: pushes and reviews overlap, and
#               a review of the previous head landing after the new head's
#               request answers nothing about the new one. Empty means "count any
#               review", which is what the filter did before the distinction
#               existed and is only reachable outside the head-aware gate — it
#               refuses to start without a head.
#
# This is what the head-aware gate consults instead of re-requesting on a timer.
# `pending` means a review is on its way and asking again would only produce a
# duplicate review of the same commit — the exact failure the manual
# `gh pr edit --add-reviewer` workaround is known for — while `absent` means
# nobody is going to review anything unless the gate asks.
#
# NOT `requested_reviewers` ON THE PULL REQUEST, which is the obvious field and
# the wrong one. GitHub takes Copilot off that list when it STARTS the review, not
# when it finishes: measured on this repository's own pull request #6, the request
# was filed at 14:07:32, `copilot_work_started` fired at 14:08:10, and the review
# landed at 14:11:44 — so for three and a half of those four minutes the field
# reads empty while the review is being written. A gate believing it would ask
# again on almost every run, which is precisely the duplicate this mode exists to
# prevent. The timeline keeps the request event itself, so it still says "asked
# for, not yet answered" through the whole of that window.
#
# The test is an ORDER, not a presence: the latest review request for Copilot has
# to come after Copilot's latest answer for this head. That is what makes it work
# for the second push as well as the first — the previous head's review is on the
# record forever, and only a request after it means anything. A
# `review_request_removed` after that request cancels it, which is Copilot
# declining rather than a review still coming.
#
# ORDER MEASURED BY POSITION, not by timestamp. The timeline arrives in
# chronological order, and its timestamps carry only seconds — so a refusal and
# the replacement request the gate makes on reading it can share one, and a
# strict `>` on equal timestamps reports "nothing outstanding" for a request that
# is plainly later in the list. Positions cannot tie. `-1` stands for "no such
# event", which is what makes "no review yet" and "no removal" fall out of the
# same comparison.
#
# THE REQUEST HAS TO BE FOR THIS HEAD, and a `review_requested` event names no
# commit — so the head's own `committed` event is the line it must fall after.
# Without that bound, a request left outstanding by the previous push reads as
# the current head's: the review that eventually answers it is of the old commit
# and correctly ignored below, so the state would stay `pending` forever and the
# gate would sit out its window without ever asking for the head it is gating.
# Position again, and the same reason: the timeline is in order, so "after the
# push" is "later in the list" — no clock, and nothing to compare across two
# fields that GitHub fills at different moments.
#
# THE ALLOWLIST HAS TO KEEP EVERY SPELLING. Copilot is `Copilot` on this surface —
# both as the requested reviewer and as the author of a `reviewed` event — while
# the reviews endpoint spells it `copilot-pull-request-reviewer[bot]`. The shipped
# default carries both. An allowlist narrowed to the review-author spelling makes
# this filter answer `absent` forever, and the gate then spends its whole
# re-request budget on requests that were already pending.
#
# `type == "Bot"` for the same reason classify.jq demands it: a human account
# whose login is on the list must not stand in for the bot. Every field is reached
# through `?` and `// ""` because a timeline carries events of many shapes — most
# have no `requested_reviewer` at all, and an entry from a deleted account arrives
# as a null. Aborting would read as "no answer" to the caller, which is a third
# state it handles separately, so this filter is never the thing that decides a
# request is absent by failing.

def entries($raw):
  $raw | ascii_downcase | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));

def is_copilot($who):
  ($who.type? // "") == "Bot"
  and ((($who.login? // "") | ascii_downcase) | IN(entries(env.REVIEWERS)[]));

# `f` and not `$f`: a `$`-parameter is a VALUE, evaluated once against whatever
# `.` is at the call site — here the whole array — so the filter would run against
# that instead of against each event, produce an empty stream, and take the call
# with it. Without the `$` it is a closure, applied per element as intended.
def last_index(f): [ to_entries[] | select(.value | f) | .key ] | last // -1;
def last_index_after($after; f):
  [ to_entries[] | select(.key > $after and (.value | f)) | .key ] | last // -1;

((env.HEAD_SHA // "") | ascii_downcase) as $head
# An ANSWER to a request for this head: a review of this head, whatever it says.
# A refusal is a review record like any other, which is how the gate gets to stop
# guessing which answer went with which request — and a review of some other
# commit is not an answer for this one, however recently it arrived.
| last_index(
    (.event? // "") == "reviewed"
    and is_copilot(.user? // {})
    and ($head == "" or (((.commit_id? // "") | ascii_downcase) == $head))) as $answered
# Where the head enters the timeline. `-1` when it is not there — an empty
# HEAD_SHA, or a commit the timeline does not carry — and every request then
# counts, which is the behaviour this filter had before the bound existed.
| last_index(
    (.event? // "") == "committed"
    and $head != ""
    and (((.sha? // "") | ascii_downcase) == $head)) as $pushed
| last_index_after($pushed;
    (.event? // "") == "review_requested"
    and is_copilot(.requested_reviewer? // {})) as $requested
| last_index_after($pushed;
    (.event? // "") == "review_request_removed"
    and is_copilot(.requested_reviewer? // {})) as $removed
| if $requested >= 0 and $requested > $answered and $requested > $removed
  then "pending"
  else "absent"
  end
