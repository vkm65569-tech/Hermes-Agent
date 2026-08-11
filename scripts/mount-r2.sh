#!/usr/bin/env bash
# mount-r2.sh — Mount Cloudflare R2 bucket as local filesystem via rclone FUSE.
#
# This script:
#   1. Installs rclone + fuse3 if missing
#   2. Writes rclone.conf from environment variables
#   3. Mounts R2 bucket at /mnt/r2 with write-back VFS cache
#   4. Restores data from R2 → ~/.hermes/ and ~/workspace/
#   5. If R2 is empty (first run), leaves restoration to the release-restore step
#
# Required env vars:
#   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME
#
set -euo pipefail

MOUNT_POINT="/mnt/r2"
HERMES_HOME="${HOME}/.hermes"
WORKSPACE="${HOME}/workspace"
RCLONE_LOG="/tmp/rclone-mount.log"

# ── 1. Validate required env vars ────────────────────────────────────────────
for var in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET_NAME; do
  if [ -z "${!var:-}" ]; then
    echo "⚠️  R2 secret '$var' is not set — skipping R2 mount (falling back to release-only mode)"
    exit 0
  fi
done

# ── 2. Install rclone + fuse3 ───────────────────────────────────────────────
if ! command -v rclone &>/dev/null; then
  echo "Installing rclone..."
  curl -fsSL https://rclone.org/install.sh | sudo bash
fi

if ! dpkg -s fuse3 &>/dev/null 2>&1; then
  echo "Installing fuse3..."
  sudo apt-get update -qq && sudo apt-get install -y -qq fuse3
fi

# ── 3. Write rclone config ──────────────────────────────────────────────────
mkdir -p "${HOME}/.config/rclone"
cat > "${HOME}/.config/rclone/rclone.conf" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
chmod 600 "${HOME}/.config/rclone/rclone.conf"
echo "rclone config written"

# ── 4. Create mount point & mount R2 ────────────────────────────────────────
sudo mkdir -p "${MOUNT_POINT}"
sudo chown "$(whoami)" "${MOUNT_POINT}"

# Unmount if already mounted (e.g. re-run)
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  fusermount -u "${MOUNT_POINT}" 2>/dev/null || true
  sleep 1
fi

echo "Mounting R2 bucket '${R2_BUCKET_NAME}' at ${MOUNT_POINT}..."
rclone mount "r2:${R2_BUCKET_NAME}" "${MOUNT_POINT}" \
  --vfs-cache-mode full \
  --vfs-write-back 5s \
  --vfs-cache-max-size 2G \
  --vfs-cache-max-age 1h \
  --dir-cache-time 30s \
  --buffer-size 32M \
  --transfers 4 \
  --allow-non-empty \
  --daemon \
  --log-file "${RCLONE_LOG}" \
  --log-level INFO

# Wait for mount to be ready (up to 15 seconds)
for i in $(seq 1 15); do
  if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    echo "R2 mounted successfully at ${MOUNT_POINT} (took ${i}s)"
    break
  fi
  sleep 1
done

if ! mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  echo "❌ R2 mount failed! Logs:"
  cat "${RCLONE_LOG}" | tail -30
  echo "Falling back to release-only mode"
  exit 0
fi

# ── 5. Test mount with a write/read ─────────────────────────────────────────
test_file="${MOUNT_POINT}/.mount-test-$(date +%s)"
echo "ok" > "${test_file}" 2>/dev/null || true
if [ -f "${test_file}" ]; then
  rm -f "${test_file}"
  echo "R2 mount read/write test: PASSED ✅"
else
  echo "⚠️  R2 mount read/write test: FAILED (read-only or permission issue)"
  echo "Falling back to release-only mode"
  fusermount -u "${MOUNT_POINT}" 2>/dev/null || true
  exit 0
fi

# ── 6. Create R2 directory structure if empty (first run) ────────────────────
mkdir -p "${MOUNT_POINT}/hermes"
mkdir -p "${MOUNT_POINT}/workspace"

# ── 7. Restore data from R2 → local dirs ────────────────────────────────────
mkdir -p "${HERMES_HOME}"
mkdir -p "${WORKSPACE}"

# Check if R2 has existing data (non-empty hermes/ dir)
r2_file_count=$(find "${MOUNT_POINT}/hermes" -maxdepth 1 -type f 2>/dev/null | wc -l || echo "0")
r2_dir_count=$(find "${MOUNT_POINT}/hermes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo "0")

if [ "$((r2_file_count + r2_dir_count))" -gt 0 ]; then
  echo "R2 has existing data (${r2_file_count} files, ${r2_dir_count} dirs) — restoring to ~/.hermes/"
  rsync -a --ignore-existing "${MOUNT_POINT}/hermes/" "${HERMES_HOME}/"
  echo "Hermes data restored from R2: $(du -sh "${HERMES_HOME}" | cut -f1)"

  if [ -d "${MOUNT_POINT}/workspace" ] && [ "$(ls -A "${MOUNT_POINT}/workspace" 2>/dev/null)" ]; then
    rsync -a --ignore-existing "${MOUNT_POINT}/workspace/" "${WORKSPACE}/"
    echo "Workspace restored from R2: $(du -sh "${WORKSPACE}" | cut -f1)"
  fi

  # Mark that we restored from R2 (so release restore can be skipped)
  touch "${HERMES_HOME}/.r2-restored"
  echo "R2_RESTORED=true" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
else
  echo "R2 is empty — this is either a first run or data needs to be migrated from releases"
  echo "R2_RESTORED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
fi

echo "R2 mount setup complete"
echo "  Mount point: ${MOUNT_POINT}"
echo "  Hermes data: ${MOUNT_POINT}/hermes/"
echo "  Workspace:   ${MOUNT_POINT}/workspace/"
