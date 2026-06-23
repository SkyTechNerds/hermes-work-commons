#!/bin/bash
# Review-Coverage: 1+ Approval, alle Comments resolved
PR_DATA=$(gh api "repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}" --jq '{state: .state, comments: .review_comments, reviews: .review_comments_url}')
COMMENTS=$(echo "$PR_DATA" | jq '.comments // 0')
UNRESOLVED=$(gh api "repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/comments" --jq '[.[] | select(.position != null)] | length' 2>/dev/null || echo 0)
APPROVALS=$(gh api "repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/reviews" --jq '[.[] | select(.state == "APPROVED")] | length')

if [ "$APPROVALS" -eq 0 ]; then
  echo "status=warn" >> "$GITHUB_OUTPUT"
  echo "Keine Approvals"
elif [ "$UNRESOLVED" -gt 0 ]; then
  echo "status=warn" >> "$GITHUB_OUTPUT"
  echo "$UNRESOLVED unresolved review-comments"
else
  echo "status=pass" >> "$GITHUB_OUTPUT"
  echo "$APPROVALS Approvals, alle Comments resolved"
fi
