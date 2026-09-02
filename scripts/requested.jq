# Answer one question about a pull request: is a Copilot review REQUEST still
# outstanding on it?
#
# Input:  the pull request object from `GET /repos/{owner}/{repo}/pulls/{pr}`.
# Output: exactly one line — `pending` or `absent`.
#
# One environment variable carries the configuration, one entry per line:
#   REVIEWERS — logins that count as Copilot, the same allowlist classify.jq
#               matches a review's author against
#
# This is what the head-aware gate consults instead of re-requesting on a timer.
# GitHub takes a reviewer off `requested_reviewers` the moment they answer, so
# the field is a live "Copilot owes this pull request a review" flag: `pending`
# means one is on its way and asking again would only produce a duplicate review
# of the same commit — the exact failure the manual `gh pr edit --add-reviewer`
# workaround produces — while `absent` means nobody is going to review anything
# unless the gate asks.
#
# THE SAME ALLOWLIST, AND IT HAS TO STAY BOTH SPELLINGS. Copilot appears here
# under the login `Copilot`, not the `copilot-pull-request-reviewer[bot]` that
# authors the review, and the shipped default carries both for exactly that
# reason. An allowlist narrowed to the review-author spelling alone makes this
# filter answer `absent` forever, and the gate then spends its whole re-request
# budget on requests that were already pending.
#
# `type == "Bot"` for the same reason classify.jq demands it: a human account
# whose login is on the list must not be able to stand in for the bot.
#
# Two different guards, against two different shapes. `[]?` is the load-bearing
# one: `requested_reviewers` is absent outright on some responses, and iterating
# a missing key aborts the program. `// ""` covers an entry that is itself null,
# where the lookup succeeds and yields null. Aborting would read as "no answer"
# to the caller, which is a third state it handles separately — so this filter is
# never the thing that decides a request is absent by failing.

def entries($raw):
  $raw | ascii_downcase | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));

if any(.requested_reviewers[]?;
       (.type? // "") == "Bot"
       and (((.login? // "") | ascii_downcase) | IN(entries(env.REVIEWERS)[])))
then "pending"
else "absent"
end
