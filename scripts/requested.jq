# Answer one question about a pull request: does Copilot still OWE it a review?
#
# Input:  the timeline array from `GET /repos/{owner}/{repo}/issues/{pr}/timeline`
#         (already flattened across pages by the caller).
# Output: exactly one line — `pending` or `absent`.
#
# One environment variable carries the configuration, one entry per line:
#   REVIEWERS — logins that count as Copilot, the same allowlist classify.jq
#               matches a review's author against
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
# to be newer than Copilot's latest review. That is what makes it work for the
# second push as well as the first — the previous head's review is on the record
# forever, and only the request that came after it means anything. A
# `review_request_removed` after that request cancels it, which is Copilot
# declining rather than a review still coming.
#
# Timestamps compare as strings because the API's own form is
# `YYYY-MM-DDTHH:MM:SSZ` — fixed width, UTC, zero-padded — so lexicographic order
# IS chronological order. `""` sorts below every real timestamp, which is what
# makes "no review yet" and "no removal" fall out of the same comparison.
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
def latest(f): [ .[] | f ] | map(select(. != null and . != "")) | sort | last // "";

. as $timeline
| ($timeline | latest(
    select((.event? // "") == "reviewed" and is_copilot(.user? // {})) | .submitted_at?)) as $reviewed
| ($timeline | latest(
    select((.event? // "") == "review_requested"
           and is_copilot(.requested_reviewer? // {})) | .created_at?)) as $requested
| ($timeline | latest(
    select((.event? // "") == "review_request_removed"
           and is_copilot(.requested_reviewer? // {})) | .created_at?)) as $removed
| if $requested != "" and $requested > $reviewed and $requested > $removed
  then "pending"
  else "absent"
  end
