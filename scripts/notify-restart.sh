#!/usr/bin/env bash
# notify-restart.sh — Send a Telegram notification when the Hermes runner
# restarts, reporting mount status, data integrity, and state info.
#
# Required env vars:
#   TELEGRAM_BOT_TOKEN, TELEGRAM_HOME_CHANNEL (or TELEGRAM_ALLOWED_USERS as fallback)
#
set -uo pipefail

MOUNT_POINT="/mnt/r2"
HERMES_HOME="${HOME}/.hermes"
WORKSPACE="${HOME}/workspace"

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_HOME_CHANNEL:-}"
RUN_ID="${GITHUB_RUN_ID:-unknown}"
REPO="${GITHUB_REPOSITORY:-unknown}"
RESTORED_FROM="${1:-unknown}"  # "r2", "release", or "fresh"

# Need at least BOT_TOKEN to send a notification
if [ -z "${BOT_TOKEN}" ]; then
  echo "[notify] No TELEGRAM_BOT_TOKEN set — skipping notification"
  exit 0
fi

# If no home channel, try using first allowed user ID
if [ -z "${CHAT_ID}" ]; then
  CHAT_ID=$(echo "${TELEGRAM_ALLOWED_USERS:-}" | cut -d',' -f1 | tr -d ' ')
fi

if [ -z "${CHAT_ID}" ]; then
  echo "[notify] No TELEGRAM_HOME_CHANNEL or TELEGRAM_ALLOWED_USERS set — skipping"
  exit 0
fi

# ── Gather status info ──────────────────────────────────────────────────────
r2_status="❌ Not mounted"
if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
  r2_status="✅ Mounted"
fi

hermes_size=$(du -sh "${HERMES_HOME}" 2>/dev/null | cut -f1 || echo "?")
workspace_size=$(du -sh "${WORKSPACE}" 2>/dev/null | cut -f1 || echo "0")

# Count skills
skill_count=0
if [ -d "${HERMES_HOME}/skills" ]; then
  skill_count=$(find "${HERMES_HOME}/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo "0")
fi

# Count cron jobs
cron_count=0
if [ -f "${HERMES_HOME}/cron/jobs.json" ]; then
  cron_count=$(grep -c '"id"' "${HERMES_HOME}/cron/jobs.json" 2>/dev/null || echo "0")
fi

# Count workspace projects
project_count=0
project_list=""
if [ -d "${WORKSPACE}" ] && [ "$(ls -A "${WORKSPACE}" 2>/dev/null)" ]; then
  project_count=$(find "${WORKSPACE}" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l || echo "0")
  project_list=$(find "${WORKSPACE}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//' || echo "")
fi

# state.db size
statedb_size="?"
if [ -f "${HERMES_HOME}/state.db" ]; then
  statedb_size=$(du -h "${HERMES_HOME}/state.db" 2>/dev/null | cut -f1 || echo "?")
fi

# Determine data loss assessment
data_loss="ZERO (R2 persistent)"
if [ "${RESTORED_FROM}" = "release" ]; then
  data_loss="Possible (restored from release backup)"
elif [ "${RESTORED_FROM}" = "fresh" ]; then
  data_loss="N/A (fresh start)"
fi

# ── Build message ───────────────────────────────────────────────────────────
message="🔄 *Hermes Runner Restarted*

├ Run: [#${RUN_ID}](https://github.com/${REPO}/actions/runs/${RUN_ID})
├ R2 Storage: ${r2_status}
├ Restored from: \`${RESTORED_FROM}\`
├ Data loss: ${data_loss}
│
├ 🧠 Brain: ${hermes_size} (state.db: ${statedb_size})
├ 🛠️ Skills: ${skill_count} | Cron jobs: ${cron_count}
├ 📁 Workspace: ${project_count} projects (${workspace_size})"

if [ -n "${project_list}" ]; then
  message="${message}
├ Projects: ${project_list}"
fi

message="${message}
│
└ ✅ Hermes is back online and ready!"

# ── Send Telegram message ───────────────────────────────────────────────────
response=$(curl -s -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d "chat_id=${CHAT_ID}" \
  -d "text=${message}" \
  -d "parse_mode=Markdown" \
  -d "disable_web_page_preview=true" 2>/dev/null || echo '{"ok":false}')

if echo "${response}" | grep -q '"ok":true'; then
  echo "[notify] Telegram notification sent successfully"
else
  echo "[notify] Telegram notification failed: ${response}"
fi
