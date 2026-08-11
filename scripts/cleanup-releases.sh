#!/usr/bin/env bash
# cleanup-releases.sh — Delete old Hermes state release snapshots,
# keeping only the newest N (default: 3) as backup safety net.
#
# Required env vars: GH_TOKEN, GITHUB_REPOSITORY
#
set -uo pipefail

KEEP="${1:-3}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"

echo "[cleanup] Cleaning up old Hermes state releases (keeping newest ${KEEP})..."

# List all hermes-state releases, sorted newest first
all_tags=$(gh release list --repo "${REPO}" --limit 100 \
  --json tagName,createdAt \
  --jq 'sort_by(.createdAt) | reverse | .[].tagName' 2>/dev/null || true)

# Filter only hermes-state tags
state_tags=""
count=0
for tag in $all_tags; do
  case "$tag" in
    hermes-state-*|hermes-delta-*|hermes-emergency-*)
      state_tags="${state_tags} ${tag}"
      count=$((count + 1))
      ;;
  esac
done

if [ "$count" -le "$KEEP" ]; then
  echo "[cleanup] Only ${count} state releases found — nothing to delete (keeping ${KEEP})"
  exit 0
fi

echo "[cleanup] Found ${count} state releases, deleting all but newest ${KEEP}..."

# Skip the first $KEEP tags, delete the rest
skip=0
deleted=0
for tag in $state_tags; do
  skip=$((skip + 1))
  if [ "$skip" -le "$KEEP" ]; then
    echo "[cleanup] KEEP: ${tag}"
    continue
  fi

  if gh release delete "${tag}" --repo "${REPO}" --yes --cleanup-tag 2>/dev/null; then
    echo "[cleanup] DELETED: ${tag}"
    deleted=$((deleted + 1))
  else
    echo "[cleanup] Failed to delete: ${tag}"
  fi

  # Rate limit: don't hammer the API
  sleep 0.5
done

echo "[cleanup] Done — deleted ${deleted} old releases, kept newest ${KEEP}"
