# Classify every Copilot review on a pull request as a real review or not.
#
# Input:  the reviews array from `GET /repos/{owner}/{repo}/pulls/{pr}/reviews`
#         (already flattened across pages by the caller).
# Output: one line per Copilot review — either `review`, or `not-a-review<TAB><body excerpt>`.
#
# Two environment variables carry the configuration, one entry per line:
#   REVIEWERS — logins that count as Copilot
#   MARKERS   — body substrings that mark a body as a genuine review
#
# A review RECORD is not a review. When Copilot's backend fails it still posts a
# COMMENTED review whose entire body is an apology for not having reviewed:
#
#   "Copilot encountered an error and was unable to review this pull request.
#    You can try again by re-requesting a review."
#   "Copilot wasn't able to review any files in this pull request."
#
# Counting records cleared the gate on pull requests nobody had read. So this
# recognises what a review IS rather than blacklisting what a failure says: a
# POSITIVE marker is the fail-closed direction, because an unrecognised body
# keeps the gate waiting instead of passing it.
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

[ .[]
  | select(
      (.user.type? // "") == "Bot"
      and (((.user.login? // "") | ascii_downcase) | IN(entries(env.REVIEWERS)[]))
    )
]
| .[]
| ((.body? // "") | ascii_downcase) as $body
# `. as $m | $body | contains($m)` and NOT `$body | contains(.)` — inside `any`'s
# condition `.` is the marker, so piping to $body first makes `contains(.)` compare
# the body with itself, which is always true and passes every refusal through.
| if any(entries(env.MARKERS)[]; . as $m | $body | contains($m))
  then "review"
  else "not-a-review\t"
       + ((.body? // "")
          | .[0:160]
          | gsub("[\r\n]"; " ")
          | if test("[^ ]") then . else "(empty body)" end)
  end
