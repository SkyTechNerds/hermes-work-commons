#!/bin/bash
# Review-Coverage: 1+ Approval, alle Comments resolved
REPO="${GITHUB_REPOSITORY:-${REPO_FULL:-}}"
PR_NUM="${PR_NUMBER:-${GITHUB_EVENT_PULL_REQUEST_NUMBER:-}}"

[ -z "$REPO" ] || [ -z "$PR_NUM" ] && {
  {
    echo "status=skip"
    echo "detail=Kein PR-Kontext"
  } >> "$GITHUB_OUTPUT"
  exit 0
}

APPROVALS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/reviews" --jq '[.[] | select(.state == "APPROVED")] | length' 2>/dev/null || echo 0)
UNRESOLVED=$(gh api "repos/${REPO}/pulls/${PR_NUM}/comments" --jq '[.[] | select(.position != null)] | length' 2>/dev/null || echo 0)
COMMENTERS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/reviews" --jq '[.[].user.login] | unique | length' 2>/dev/null || echo 0)

if [ "$APPROVALS" -eq 0 ]; then
  {
    echo "status=warn"
    echo "detail=Keine Approvals ($COMMENTERS Reviewer bisher)"
  } >> "$GITHUB_OUTPUT"
elif [ "$UNRESOLVED" -gt 0 ]; then
  {
    echo "status=warn"
    echo "detail=$UNRESOLVED unresolved review-comments"
  } >> "$GITHUB_OUTPUT"
else
  {
    echo "status=pass"
    echo "detail=$APPROVALS Approvals, alle Comments resolved"
  } >> "$GITHUB_OUTPUT"
fi