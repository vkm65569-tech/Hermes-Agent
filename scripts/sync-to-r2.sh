#!/usr/bin/env bash
# sync-to-r2.sh — Background daemon that continuously syncs ~/.hermes/ and
# ~/workspace/ to the encrypted HuggingFace bucket via FUSE mount.
#
# Design: SAVE EVERYTHING. Only the Hermes engine (reinstalled on each run)
# and runtime signal files are excluded for performance.
#
# Usage:
#   bash scripts/sync-to-r2.sh &          # start background daemon
#   touch ~/.hermes/stop-r2-sync           # signal it to stop
#
set -uo pipefail

MOUNT_POINT="/mnt/r2"
HERMES_HOME="${HOME}/.hermes"
WORKSPACE="${HOME}/workspace"
SYNC_INTERVAL="${SYNC_INTERVAL:-30}"  # seconds between syncs
STOP_FLAG="${HERMES_HOME}/stop-r2-sync"
SYNC_LOG="/tmp/r2-sync.log"

# Clean previous stop flag
rm -f "${STOP_FLAG}"

echo "[r2-sync] Starting background sync daemon (interval: ${SYNC_INTERVAL}s)" | tee -a "${SYNC_LOG}"
echo "[r2-sync] PID: $$" | tee -a "${SYNC_LOG}"

sync_count=0

while [ ! -f "${STOP_FLAG}" ]; do
  sleep "${SYNC_INTERVAL}"

  # Check if stop was requested during sleep
  [ -f "${STOP_FLAG}" ] && break

  # Check mount is still healthy
  if ! mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    echo "[r2-sync] ⚠️  Mount lost at ${MOUNT_POINT} — skipping sync" >> "${SYNC_LOG}"
    continue
  fi

  sync_count=$((sync_count + 1))
  ts=$(date -u +%H:%M:%S)

  # ── Sync ~/.hermes/ → bucket (exclude only engine + runtime signals) ──
  rsync -a --delete \
    --exclude 'hermes-agent' --exclude 'hermes-agent/' \
    --exclude 'bin' --exclude 'bin/' \
    --exclude 'venvs' --exclude 'venvs/' \
    --exclude 'stop-r2-sync' --exclude 'stop-heartbeat' \
    --exclude 'ticker_heartbeat' --exclude 'gateway.pid' --exclude 'gateway.lock' \
    "${HERMES_HOME}/" "${MOUNT_POINT}/hermes/" 2>>"${SYNC_LOG}" || true

  # ── Sync ~/workspace/ → bucket (save everything) ──────────────────────
  if [ -d "${WORKSPACE}" ] && [ "$(ls -A "${WORKSPACE}" 2>/dev/null)" ]; then
    rsync -a --delete \
      "${WORKSPACE}/" "${MOUNT_POINT}/workspace/" 2>>"${SYNC_LOG}" || true
  fi

  # Log every 10th sync (avoid log spam)
  if [ $((sync_count % 10)) -eq 0 ]; then
    hermes_size=$(du -sh "${MOUNT_POINT}/hermes" 2>/dev/null | cut -f1 || echo "?")
    workspace_size=$(du -sh "${MOUNT_POINT}/workspace" 2>/dev/null | cut -f1 || echo "?")
    echo "[r2-sync] ${ts} sync #${sync_count} — hermes: ${hermes_size}, workspace: ${workspace_size}" >> "${SYNC_LOG}"
  fi
done

echo "[r2-sync] Received stop signal — running final sync..." | tee -a "${SYNC_LOG}"

# ── Final sync (same excludes, logged more verbosely) ───────────────────────
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  rsync -a --delete \
    --exclude 'hermes-agent' --exclude 'hermes-agent/' \
    --exclude 'bin' --exclude 'bin/' \
    --exclude 'venvs' --exclude 'venvs/' \
    --exclude 'stop-r2-sync' --exclude 'stop-heartbeat' \
    --exclude 'ticker_heartbeat' --exclude 'gateway.pid' --exclude 'gateway.lock' \
    "${HERMES_HOME}/" "${MOUNT_POINT}/hermes/" 2>>"${SYNC_LOG}" || true

  if [ -d "${WORKSPACE}" ] && [ "$(ls -A "${WORKSPACE}" 2>/dev/null)" ]; then
    rsync -a --delete \
      "${WORKSPACE}/" "${MOUNT_POINT}/workspace/" 2>>"${SYNC_LOG}" || true
  fi

  echo "[r2-sync] Final sync complete" | tee -a "${SYNC_LOG}"
else
  echo "[r2-sync] ⚠️  Mount not available for final sync" | tee -a "${SYNC_LOG}"
fi

echo "[r2-sync] Daemon stopped after ${sync_count} sync cycles" | tee -a "${SYNC_LOG}"
