#!/usr/bin/env bash
# sync-to-r2.sh — Background daemon that continuously syncs ~/.hermes/ and
# ~/workspace/ to the R2 FUSE mount, excluding only regenerable runtime junk.
#
# Design: BLACKLIST approach — everything is synced by default.
# Only explicitly listed regenerable artifacts are excluded.
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
    echo "[r2-sync] ⚠️  R2 mount lost at ${MOUNT_POINT} — skipping sync" >> "${SYNC_LOG}"
    continue
  fi

  sync_count=$((sync_count + 1))
  ts=$(date -u +%H:%M:%S)

  # ── Sync ~/.hermes/ → R2 (exclude only engine/runtime dirs) ──────────
  # NOTE: ~/.hermes/work/ contains project repos (AutoSiteAgents, PainScout)
  # which have their own node_modules/, .git/, etc. — exclude those too.
  rsync -a --delete \
    --exclude 'hermes-agent' \
    --exclude 'hermes-agent/' \
    --exclude 'bin' \
    --exclude 'bin/' \
    --exclude 'venvs' \
    --exclude 'venvs/' \
    --exclude 'auth' \
    --exclude 'auth/' \
    --exclude 'auth.json' \
    --exclude 'auth.lock' \
    --exclude 'logs' \
    --exclude 'logs/' \
    --exclude 'whatsapp' \
    --exclude 'whatsapp/' \
    --exclude 'stop-r2-sync' \
    --exclude 'stop-heartbeat' \
    --exclude 'ticker_heartbeat' \
    --exclude 'gateway.pid' \
    --exclude 'gateway.lock' \
    --exclude '*.pyc' \
    --exclude '__pycache__' \
    --exclude '__pycache__/' \
    --exclude 'node_modules' \
    --exclude '.venv' \
    --exclude 'venv' \
    --exclude '.next' \
    --exclude 'dist' \
    --exclude 'build' \
    --exclude '.cache' \
    --exclude '.git' \
    --exclude 'target' \
    --exclude '.cargo/registry' \
    --exclude 'coverage' \
    --exclude '.nyc_output' \
    "${HERMES_HOME}/" "${MOUNT_POINT}/hermes/" 2>>"${SYNC_LOG}" || true

  # ── Sync ~/workspace/ → R2 (exclude only regenerable build artifacts) ─
  if [ -d "${WORKSPACE}" ] && [ "$(ls -A "${WORKSPACE}" 2>/dev/null)" ]; then
    rsync -a --delete \
      --exclude 'node_modules' \
      --exclude 'node_modules/' \
      --exclude '.venv' \
      --exclude '.venv/' \
      --exclude 'venv' \
      --exclude 'venv/' \
      --exclude '__pycache__' \
      --exclude '__pycache__/' \
      --exclude '*.pyc' \
      --exclude '*.pyo' \
      --exclude '.next' \
      --exclude '.next/' \
      --exclude 'dist' \
      --exclude 'dist/' \
      --exclude 'build' \
      --exclude 'build/' \
      --exclude '.cache' \
      --exclude '.cache/' \
      --exclude '.git' \
      --exclude '.git/' \
      --exclude 'coverage' \
      --exclude 'coverage/' \
      --exclude '.nyc_output' \
      --exclude '.nyc_output/' \
      --exclude 'target' \
      --exclude 'target/' \
      --exclude '.cargo/registry' \
      --exclude '.npm' \
      --exclude '.npm/' \
      --exclude '.pnpm-store' \
      --exclude '.pnpm-store/' \
      --exclude '.yarn/cache' \
      --exclude '.turbo' \
      --exclude '.turbo/' \
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

# ── Final sync (same as above but logged more verbosely) ────────────────────
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  rsync -a --delete \
    --exclude 'hermes-agent' --exclude 'hermes-agent/' \
    --exclude 'bin' --exclude 'bin/' \
    --exclude 'venvs' --exclude 'venvs/' \
    --exclude 'auth' --exclude 'auth/' \
    --exclude 'auth.json' --exclude 'auth.lock' \
    --exclude 'logs' --exclude 'logs/' \
    --exclude 'whatsapp' --exclude 'whatsapp/' \
    --exclude 'stop-r2-sync' --exclude 'stop-heartbeat' \
    --exclude 'ticker_heartbeat' --exclude 'gateway.pid' --exclude 'gateway.lock' \
    --exclude '*.pyc' --exclude '__pycache__' --exclude '__pycache__/' \
    --exclude 'node_modules' --exclude '.venv' --exclude 'venv' \
    --exclude '.next' --exclude 'dist' --exclude 'build' \
    --exclude '.cache' --exclude '.git' --exclude 'target' \
    --exclude '.cargo/registry' --exclude 'coverage' --exclude '.nyc_output' \
    "${HERMES_HOME}/" "${MOUNT_POINT}/hermes/" 2>>"${SYNC_LOG}" || true

  if [ -d "${WORKSPACE}" ] && [ "$(ls -A "${WORKSPACE}" 2>/dev/null)" ]; then
    rsync -a --delete \
      --exclude 'node_modules' --exclude 'node_modules/' \
      --exclude '.venv' --exclude '.venv/' \
      --exclude 'venv' --exclude 'venv/' \
      --exclude '__pycache__' --exclude '__pycache__/' \
      --exclude '*.pyc' --exclude '*.pyo' \
      --exclude '.next' --exclude '.next/' \
      --exclude 'dist' --exclude 'dist/' \
      --exclude 'build' --exclude 'build/' \
      --exclude '.cache' --exclude '.cache/' \
      --exclude '.git' --exclude '.git/' \
      --exclude 'coverage' --exclude 'coverage/' \
      --exclude '.nyc_output' --exclude '.nyc_output/' \
      --exclude 'target' --exclude 'target/' \
      --exclude '.cargo/registry' \
      --exclude '.npm' --exclude '.npm/' \
      --exclude '.pnpm-store' --exclude '.pnpm-store/' \
      --exclude '.yarn/cache' --exclude '.turbo' --exclude '.turbo/' \
      "${WORKSPACE}/" "${MOUNT_POINT}/workspace/" 2>>"${SYNC_LOG}" || true
  fi

  echo "[r2-sync] Final sync complete" | tee -a "${SYNC_LOG}"
else
  echo "[r2-sync] ⚠️  Mount not available for final sync" | tee -a "${SYNC_LOG}"
fi

echo "[r2-sync] Daemon stopped after ${sync_count} sync cycles" | tee -a "${SYNC_LOG}"
