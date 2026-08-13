#!/usr/bin/env bash
# mount-r2.sh — Mount HuggingFace public bucket as encrypted local filesystem
#               via rclone FUSE + rclone crypt (zero-knowledge encryption).
#
# This script:
#   1. Installs rclone + fuse3 if missing
#   2. Writes rclone.conf with HF S3 remote + crypt overlay
#   3. Mounts the encrypted bucket at /mnt/r2 (decrypted view)
#   4. Restores data from bucket → ~/.hermes/ and ~/workspace/
#   5. If bucket is empty (first run), leaves restoration to release-restore step
#
# Required env vars:
#   HF_S3_ACCESS_KEY, HF_S3_SECRET_KEY, HF_BUCKET_NAME,
#   HF_CRYPT_PASSWORD, HF_CRYPT_SALT
#
set -euo pipefail

MOUNT_POINT="/mnt/r2"
HERMES_HOME="${HOME}/.hermes"
WORKSPACE="${HOME}/workspace"
RCLONE_LOG="/tmp/rclone-mount.log"

# ── 1. Validate required env vars ────────────────────────────────────────────
for var in HF_S3_ACCESS_KEY HF_S3_SECRET_KEY HF_BUCKET_NAME HF_CRYPT_PASSWORD HF_CRYPT_SALT; do
  if [ -z "${!var:-}" ]; then
    echo "⚠️  HuggingFace secret '$var' is not set — skipping mount (falling back to release-only mode)"
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

# ── 3. Obscure crypt passwords (rclone requires obscured form) ──────────────
echo "Generating obscured crypt credentials..."
CRYPT_PASS_OBSCURED=$(rclone obscure "${HF_CRYPT_PASSWORD}")
CRYPT_SALT_OBSCURED=$(rclone obscure "${HF_CRYPT_SALT}")

# ── 4. Write rclone config (HF S3 + crypt overlay) ─────────────────────────
mkdir -p "${HOME}/.config/rclone"
cat > "${HOME}/.config/rclone/rclone.conf" <<EOF
[hf]
type = s3
provider = Other
access_key_id = ${HF_S3_ACCESS_KEY}
secret_access_key = ${HF_S3_SECRET_KEY}
endpoint = https://s3.hf.co
region = us-east-1
no_check_bucket = true

[hf-crypt]
type = crypt
remote = hf:${HF_BUCKET_NAME}/hermes-storage
filename_encryption = standard
directory_name_encryption = true
password = ${CRYPT_PASS_OBSCURED}
password2 = ${CRYPT_SALT_OBSCURED}
EOF
chmod 600 "${HOME}/.config/rclone/rclone.conf"
echo "rclone config written (HuggingFace S3 + crypt encryption)"

# ── 5. Create mount point & mount encrypted bucket ──────────────────────────
sudo mkdir -p "${MOUNT_POINT}"
sudo chown "$(whoami)" "${MOUNT_POINT}"

# Unmount if already mounted (e.g. re-run)
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  fusermount -u "${MOUNT_POINT}" 2>/dev/null || true
  sleep 1
fi

echo "Mounting HuggingFace encrypted bucket at ${MOUNT_POINT}..."
rclone mount "hf-crypt:" "${MOUNT_POINT}" \
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
    echo "Encrypted bucket mounted successfully at ${MOUNT_POINT} (took ${i}s)"
    break
  fi
  sleep 1
done

if ! mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  echo "❌ Mount failed! Logs:"
  cat "${RCLONE_LOG}" | tail -30
  echo "Falling back to release-only mode"
  exit 0
fi

# ── 6. Test mount with a write/read ─────────────────────────────────────────
test_file="${MOUNT_POINT}/.mount-test-$(date +%s)"
echo "ok" > "${test_file}" 2>/dev/null || true
if [ -f "${test_file}" ]; then
  rm -f "${test_file}"
  echo "Encrypted mount read/write test: PASSED ✅"
else
  echo "⚠️  Encrypted mount read/write test: FAILED (read-only or permission issue)"
  echo "Falling back to release-only mode"
  fusermount -u "${MOUNT_POINT}" 2>/dev/null || true
  exit 0
fi

# ── 7. Create directory structure if empty (first run) ───────────────────────
mkdir -p "${MOUNT_POINT}/hermes"
mkdir -p "${MOUNT_POINT}/workspace"

# ── 8. Restore data from bucket → local dirs ────────────────────────────────
mkdir -p "${HERMES_HOME}"
mkdir -p "${WORKSPACE}"

# Check if bucket has existing data (non-empty hermes/ dir)
r2_file_count=$(find "${MOUNT_POINT}/hermes" -maxdepth 1 -type f 2>/dev/null | wc -l || echo "0")
r2_dir_count=$(find "${MOUNT_POINT}/hermes" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo "0")

if [ "$((r2_file_count + r2_dir_count))" -gt 0 ]; then
  echo "Bucket has existing data (${r2_file_count} files, ${r2_dir_count} dirs) — restoring to ~/.hermes/"
  rsync -a --ignore-existing "${MOUNT_POINT}/hermes/" "${HERMES_HOME}/"
  echo "Hermes data restored from bucket: $(du -sh "${HERMES_HOME}" | cut -f1)"

  if [ -d "${MOUNT_POINT}/workspace" ] && [ "$(ls -A "${MOUNT_POINT}/workspace" 2>/dev/null)" ]; then
    rsync -a --ignore-existing "${MOUNT_POINT}/workspace/" "${WORKSPACE}/"
    echo "Workspace restored from bucket: $(du -sh "${WORKSPACE}" | cut -f1)"
  fi

  # Mark that we restored from bucket (so release restore can be skipped)
  touch "${HERMES_HOME}/.r2-restored"
  echo "R2_RESTORED=true" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
else
  echo "Bucket is empty — this is either a first run or data needs to be migrated from releases"
  echo "R2_RESTORED=false" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
fi

echo "Encrypted mount setup complete"
echo "  Mount point: ${MOUNT_POINT} (decrypted view)"
echo "  HuggingFace bucket: ${HF_BUCKET_NAME}/hermes-storage (encrypted)"
echo "  Hermes data: ${MOUNT_POINT}/hermes/"
echo "  Workspace:   ${MOUNT_POINT}/workspace/"
