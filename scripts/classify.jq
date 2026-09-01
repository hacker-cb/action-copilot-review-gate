# Classify every Copilot review on a pull request as a real review, a settled
# "nothing here to review", or neither.
#
# Input:  the reviews array from `GET /repos/{owner}/{repo}/pulls/{pr}/reviews`
#         (already flattened across pages by the caller).
# Output: one line per Copilot review — `review`, or `<kind><TAB>body excerpt`
#         where kind is `unable-to-review`, `stale-unable-to-review`, or
#         `not-a-review`.
#
# Three environment variables carry the configuration, one entry per line:
#   REVIEWERS      — logins that count as Copilot
#   MARKERS        — body substrings that mark a body as a genuine review
#   UNABLE_MARKERS — body substrings that mark a body as Copilot's settled
#                    "there is nothing reviewable here"
# and one that is a single value:
#   HEAD_SHA       — the pull request's current head commit
#
# A review RECORD is not a review. When Copilot's backend fails it still posts a
# COMMENTED review whose entire body is an apology for not having reviewed:
#
#   "Copilot encountered an error and was unable to review this pull request.
#    You can try again by re-requesting a review."
#
# Counting records cleared the gate on pull requests nobody had read. So this
# recognises what a review IS rather than blacklisting what a failure says: a
# POSITIVE marker is the fail-closed direction, because an unrecognised body
# keeps the gate waiting instead of passing it.
#
# A NEGATIVE marker is the third class, and it is not a weaker positive one:
#
#   "Copilot wasn't able to review any files in this pull request."
#
# is Copilot's FINAL answer for this diff — an empty-file deletion, a pure
# rename, a lockfile-only change — where the apology above is a transient one a
# retry can still turn into a review. Re-requesting the first is worth the wait;
# re-requesting the second is deterministic futility, so it gets its own class
# and the caller decides what a settled "nothing to review" means for the merge.
# An UNRECOGNISED body stays in neither class and keeps the gate waiting, which
# is what makes a marker that stops matching fail closed rather than open.
#
# FOR THIS DIFF is the whole of it, and the reviews endpoint does not respect
# that on its own: it returns every review the pull request ever collected. A
# settled answer to an empty diff would otherwise still be sitting there after
# the author pushed real code, and the gate would open on it before Copilot had
# read a line. So the class is pinned to `commit_id == HEAD_SHA`; the same body
# against an older commit is `stale-unable-to-review`, which the gate treats the
# way it treats any unrecognised body — it waits, and it re-requests, which is
# exactly what gets Copilot to answer for the commit that is actually there.
# An absent HEAD_SHA leaves nothing to pin against, so nothing is settled and
# the gate keeps waiting: the safe direction, and the one a missing value in
# the plumbing must fail in.
#
# The reviewer test is an ALLOWLIST, never a `^copilot` prefix. Several apps in
# the Copilot family carry a login with that prefix, and for a merge gate one
# false match costs a merge. It also demands `type == "Bot"`, so a human quoting
# a marker in their own review body cannot clear the gate.
#
# Every field is reached through `?` and `// ""`: a review left by a deleted
# account arrives as `"user": null`, and one such row would otherwise abort the
# whole program — which reads as "no review yet", the one direction that must
# never happen silently.

def entries($raw):
  $raw | ascii_downcase | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));

def excerpt:
  (.body? // "")
  | .[0:160]
  | gsub("[\r\n]"; " ")
  # `[^[:space:]]` and not `[^ ]`: the newlines are gone by now but a TAB is not,
  # and a body of tabs would otherwise be reported as itself — which the timeout
  # dump, trimming leading whitespace, then prints as a blank line where it
  # promised to say what arrived.
  | if test("[^[:space:]]") then . else "(empty body)" end;

[ .[]
  | select(
      (.user.type? // "") == "Bot"
      and (((.user.login? // "") | ascii_downcase) | IN(entries(env.REVIEWERS)[]))
    )
]
| .[]
| ((.body? // "") | ascii_downcase) as $body
# Hex either way in practice, but downcased on both sides so the comparison
# cannot turn on a spelling neither end promises.
| ((.commit_id? // "") | ascii_downcase) as $commit
| ((env.HEAD_SHA // "") | ascii_downcase) as $head
# `. as $m | $body | contains($m)` and NOT `$body | contains(.)` — inside `any`'s
# condition `.` is the marker, so piping to $body first makes `contains(.)` compare
# the body with itself, which is always true and passes every refusal through.
| if any(entries(env.MARKERS)[]; . as $m | $body | contains($m))
  then "review"
# `// ""` and not `:?` upstream: an EMPTY list is a meaningful setting here — it
# turns the negative class off and restores the two-class behaviour this gate
# had before the class existed. A genuine review still outranks it either way,
# because this branch is only reached when no positive marker matched.
  elif any(entries(env.UNABLE_MARKERS // "")[]; . as $m | $body | contains($m))
  then (if $head != "" and $commit == $head
        then "unable-to-review\t"
        else "stale-unable-to-review\t"
        end) + excerpt
  else "not-a-review\t" + excerpt
  end
