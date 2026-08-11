#!/usr/bin/env bash
# unmount-r2.sh — Cleanly stop R2 sync daemon, flush all pending writes,
# and unmount the FUSE filesystem.
#
# This script is called:
#   1. By the trap handler when the gateway receives SIGTERM/SIGINT
#   2. By the "Final sync and unmount" workflow step (if: always())
#
set -uo pipefail

MOUNT_POINT="/mnt/r2"
HERMES_HOME="${HOME}/.hermes"
STOP_FLAG="${HERMES_HOME}/stop-r2-sync"
SYNC_LOG="/tmp/r2-sync.log"

echo "[r2-unmount] Starting clean shutdown..."

# ── 1. Signal the sync daemon to stop ────────────────────────────────────────
touch "${STOP_FLAG}" 2>/dev/null || true
echo "[r2-unmount] Stop flag set — waiting for sync daemon to finish..."

# Wait up to 15 seconds for the sync daemon to do its final sync and exit
for i in $(seq 1 15); do
  # Check if any sync-to-r2.sh processes are still running
  if ! pgrep -f "sync-to-r2.sh" >/dev/null 2>&1; then
    echo "[r2-unmount] Sync daemon stopped (waited ${i}s)"
    break
  fi
  sleep 1
done

# Force kill if still running
if pgrep -f "sync-to-r2.sh" >/dev/null 2>&1; then
  echo "[r2-unmount] Sync daemon still running — force killing"
  pkill -f "sync-to-r2.sh" 2>/dev/null || true
  sleep 1
fi

# ── 2. One more emergency sync (belt and suspenders) ─────────────────────────
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  echo "[r2-unmount] Running emergency final sync..."
  rsync -a --delete \
    --exclude 'hermes-agent' --exclude 'hermes-agent/' \
    --exclude 'bin' --exclude 'bin/' \
    --exclude 'venvs' --exclude 'venvs/' \
    --exclude '.env' --exclude '.env.example' \
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
    "${HERMES_HOME}/" "${MOUNT_POINT}/hermes/" 2>/dev/null || true

  if [ -d "${HOME}/workspace" ] && [ "$(ls -A "${HOME}/workspace" 2>/dev/null)" ]; then
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
      "${HOME}/workspace/" "${MOUNT_POINT}/workspace/" 2>/dev/null || true
  fi

  echo "[r2-unmount] Emergency sync complete"
fi

# ── 3. Flush rclone VFS write-back cache ─────────────────────────────────────
# rclone mount with --vfs-write-back may have pending uploads.
# Force flush by sending the VFS expire command via rclone rc (if available).
if command -v rclone &>/dev/null; then
  # Try to flush via rclone remote control (may not be available if rc not enabled)
  rclone rc vfs/queue-set-expiry expiry=0s 2>/dev/null && \
    echo "[r2-unmount] rclone VFS cache flush triggered" || true
  # Give it a few seconds to flush pending uploads
  sleep 3
fi

# ── 4. Unmount FUSE filesystem ───────────────────────────────────────────────
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  echo "[r2-unmount] Unmounting ${MOUNT_POINT}..."
  fusermount -u "${MOUNT_POINT}" 2>/dev/null || {
    echo "[r2-unmount] Graceful unmount failed — lazy unmount"
    fusermount -uz "${MOUNT_POINT}" 2>/dev/null || true
  }
  sleep 1

  if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    echo "[r2-unmount] ⚠️  Mount still active after unmount — killing rclone"
    pkill -f "rclone mount" 2>/dev/null || true
    sleep 2
    fusermount -uz "${MOUNT_POINT}" 2>/dev/null || true
  fi

  echo "[r2-unmount] Unmount complete"
else
  echo "[r2-unmount] Mount was not active (already unmounted or never mounted)"
fi

# ── 5. Log final status ─────────────────────────────────────────────────────
echo "[r2-unmount] Clean shutdown finished"
if [ -f "${SYNC_LOG}" ]; then
  echo "[r2-unmount] Sync log tail:"
  tail -5 "${SYNC_LOG}" 2>/dev/null || true
fi

# Clean up stop flag
rm -f "${STOP_FLAG}" 2>/dev/null || true
