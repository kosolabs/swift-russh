#!/bin/bash
# Holds a release PR's CI run until Package.swift pins the PR's own binary.
# Pin Binary builds the binary and pushes the pin commit, which CI tests in a
# new run; this run then cancels itself rather than reporting a failure.
set -euo pipefail

: "${TITLE:?}" "${PR:?}" "${SHA:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"
POLL_SECONDS=${POLL_SECONDS:-20}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-1800}
CANCEL_GRACE_SECONDS=${CANCEL_GRACE_SECONDS:-300}

version="${TITLE##* }"
if grep -q "releases/download/v$version/CRusshFFI.xcframework.zip" Package.swift; then
  echo "Package.swift is pinned to the v$version binary"
  exit 0
fi

echo "::notice::Waiting for Pin Binary to pin the v$version binary"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  head=$(gh pr view "$PR" -R "$GITHUB_REPOSITORY" --json headRefOid --jq .headRefOid)
  if [[ "$head" != "$SHA" ]]; then
    echo "::notice::Superseded by $head, which CI tests in its own run; cancelling this one"
    gh run cancel "$GITHUB_RUN_ID" -R "$GITHUB_REPOSITORY"
    sleep "$CANCEL_GRACE_SECONDS"
    exit 1
  fi

  pin=$(gh run list -R "$GITHUB_REPOSITORY" --workflow "Pin Binary" --commit "$SHA" \
    --json status,conclusion --jq '.[0] | select(.) | "\(.status)/\(.conclusion)"')
  case "$pin" in
    completed/success | completed/skipped | "") ;;
    completed/*)
      echo "::error::Pin Binary finished as ${pin#completed/} for $SHA, so the v$version binary was never pinned"
      exit 1
      ;;
  esac
  sleep "$POLL_SECONDS"
done

echo "::error::Pin Binary did not pin the v$version binary within $((TIMEOUT_SECONDS / 60)) minutes"
exit 1
