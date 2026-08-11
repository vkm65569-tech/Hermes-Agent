#!/usr/bin/env bash
# release-state.sh — Create an AES-256-CBC encrypted release snapshot of
# Hermes state + workspace as a backup safety net.
#
# With R2 persistence, this is a BACKUP (runs once at end of run),
# not the primary persistence mechanism.
#
# Reads data from:
#   1. R2 mount (/mnt/r2/hermes/ and /mnt/r2/workspace/) if available
#   2. Falls back to ~/.hermes/ if R2 is not mounted
#
# Required env vars: STATE_ENCRYPTION_KEY, GH_TOKEN, GITHUB_REPOSITORY
#
set -euo pipefail

MOUNT_POINT="/mnt/r2"
STATE_DIR="${HERMES_STATE_DIR:-hermes-state}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
RUN_ID="${GITHUB_RUN_ID:-local}"
MESSAGE="${1:-save}"

ts=$(date -u +%Y%m%dT%H%M%SZ)
tag="hermes-state-${RUN_ID}-${ts}"

mkdir -p "${STATE_DIR}"

# ── Determine source: R2 mount or local ~/.hermes ────────────────────────────
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null && [ -d "${MOUNT_POINT}/hermes" ]; then
  HERMES_SOURCE="${MOUNT_POINT}/hermes"
  WORKSPACE_SOURCE="${MOUNT_POINT}/workspace"
  echo "Backing up from R2 mount"
else
  HERMES_SOURCE="${HOME}/.hermes"
  WORKSPACE_SOURCE="${HOME}/workspace"
  echo "Backing up from local disk (R2 not mounted)"
fi

# ── Sync hermes data to staging dir ──────────────────────────────────────────
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
  "${HERMES_SOURCE}/" "${STATE_DIR}/hermes/"

# ── Sync workspace (source code only, exclude runtime junk) ──────────────────
if [ -d "${WORKSPACE_SOURCE}" ] && [ "$(ls -A "${WORKSPACE_SOURCE}" 2>/dev/null)" ]; then
  mkdir -p "${STATE_DIR}/workspace"
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
    "${WORKSPACE_SOURCE}/" "${STATE_DIR}/workspace/"
  echo "Workspace included in backup ($(du -sh "${STATE_DIR}/workspace" | cut -f1))"
fi

# ── Create encrypted archive ────────────────────────────────────────────────
archive="/tmp/${tag}.tar.gz"
enc="${archive}.enc"

tar -czf "${archive}" -C . "${STATE_DIR}"
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt \
  -pass env:STATE_ENCRYPTION_KEY \
  -in "${archive}" -out "${enc}"

# ── Upload as GitHub Release ────────────────────────────────────────────────
gh release create "${tag}" "${enc}" \
  --repo "${REPO}" \
  --title "Hermes state ${ts}" \
  --notes "Encrypted snapshot of hermes state + workspace (source code only) - ${MESSAGE}. Safety net backup (primary storage is R2)."

size=$(du -h "${enc}" | cut -f1)
rm -f "${archive}" "${enc}"
echo "Released encrypted snapshot ${tag} (${size})"
