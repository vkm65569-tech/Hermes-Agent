# Hermes Agent on GitHub Actions (24/7, ₹0)

Hosts [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) on
GitHub's free runners. Uses the chaining pattern: each run lives ~5.5 hours
(6h job limit), then re-triggers itself via `workflow_dispatch`.

**Primary storage is Cloudflare R2** — all agent data (memory, skills, sessions,
cron jobs, config) and your workspace code are persisted on R2 via a FUSE mount.
The runner is just a compute host. Runner restarts cause **zero data loss**.

Encrypted GitHub Release snapshots serve as a **backup safety net** in case R2
ever has issues.

- **Ubuntu runner:** 4 CPU / 16 GB RAM / 14 GB SSD
- **Telegram gateway:** talk to Hermes 24/7 from your phone
- **Autonomous cron:** Hermes' built-in scheduler runs jobs (daily briefings,
  audits...) and delivers results to Telegram
- **Persistent workspace:** any code Hermes writes at `~/workspace/` survives
  runner restarts (saved to R2)
- **Cost:** ₹0 — unlimited free minutes on public repos + 10 GB free R2 storage

## Setup

1. **Create a public GitHub repo** (public = unlimited free minutes) and push
   this repo's contents into it.

2. **Set up Cloudflare R2** (free persistent storage):

   a. Create a free account at [dash.cloudflare.com](https://dash.cloudflare.com)
   b. Go to **R2 Object Storage** → **Create bucket** → name it `hermes-state`
   c. Go to **R2** → **Manage R2 API Tokens** → **Create API token**:
      - Permissions: **Object Read & Write**
      - Scope: Apply to the `hermes-state` bucket
      - Save the **Access Key ID** and **Secret Access Key** (shown only once!)
   d. Note your **Account ID** from the right sidebar on the Overview page

3. **Add secrets** (repo Settings → Secrets and variables → Actions):

   | Secret | Required | Purpose |
   |---|---|---|
   | `R2_ACCOUNT_ID` | Yes | Your Cloudflare Account ID |
   | `R2_ACCESS_KEY_ID` | Yes | R2 API token Access Key ID |
   | `R2_SECRET_ACCESS_KEY` | Yes | R2 API token Secret Access Key |
   | `R2_BUCKET_NAME` | Yes | Your R2 bucket name (e.g., `hermes-state`) |
   | `STATE_ENCRYPTION_KEY` | Yes | AES-256 key for release backups. Generate with `openssl rand -base64 32`. **Back it up.** |
   | `TELEGRAM_BOT_TOKEN` | Yes | Your bot token from [@BotFather](https://t.me/BotFather) |
   | `TELEGRAM_ALLOWED_USERS` | Yes | Comma-separated Telegram user IDs allowed to talk to the bot |
   | `TELEGRAM_HOME_CHANNEL` | No | Chat ID for cron delivery and restart notifications |
   | `OPENCODE_ZEN_API_KEY` | Yes* | **LLM access via OpenCode Zen** — get your key at [opencode.ai/auth](https://opencode.ai/auth) |
   | `EXA_API_KEY` / `FIRECRAWL_API_KEY` | No | Web search/extract tools |
   | `FAL_KEY` | No | Image generation |
   | `GH_PAT` | No | Fallback token (scope: `repo` + `workflow`) if self-triggering hits 403 on your org |

   *At least one LLM provider key is required. `OPENCODE_ZEN_API_KEY` is the recommended one.
   Alternatives: `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`/`GEMINI_API_KEY`,
   `NOUS_API_KEY`, `FIREWORKS_API_KEY`, `KIMI_API_KEY`, `HF_TOKEN`, `DEEPINFRA_API_KEY`.

4. **Add repo variables** (Settings → Secrets and variables → Actions → **Variables**)
   to use OpenCode Zen's free model:

   | Variable | Value |
   |---|---| 
   | `HERMES_PROVIDER` | `opencode-zen` |
   | `HERMES_MODEL` | `deepseek-v4-flash-free` |

5. **Run the workflow:** Actions tab → *Hermes Agent 24/7* → **Run workflow**.
   First run installs Hermes, mounts R2, restores/migrates state, and starts
   the gateway.

6. **Talk to Hermes on Telegram.** It also self-bootstraps a few cron jobs on
   first run.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  GitHub Actions Runner (ephemeral compute)            │
│                                                       │
│  LOCAL DISK (disposable):     R2 MOUNT (persistent):  │
│  ├─ hermes-agent/ (engine)   ├─ state.db (convos)    │
│  ├─ bin/ (binaries)          ├─ memories/ (brain)     │
│  ├─ venvs/ (python)          ├─ skills/ (learned)     │
│  ├─ .env (API keys)          ├─ sessions/ (chats)     │
│  ├─ auth/ (OAuth)            ├─ cron/ (schedules)     │
│  └─ logs/ (runtime)          ├─ config.yaml           │
│                              ├─ SOUL.md               │
│                              ├─ plugins/              │
│                              ├─ <anything_new> ✅     │
│                              └─ ~/workspace/ (code)   │
└──────────────┬───────────────────────────────────────┘
               │ rclone FUSE mount + rsync every 30s
               ▼
┌──────────────────────────────┐  ┌─────────────────────┐
│  Cloudflare R2 (primary)     │  │ GitHub Releases     │
│  10 GB free, ₹0 egress       │  │ (encrypted backup)  │
│  Zero data loss on restart   │  │ Keep last 3         │
└──────────────────────────────┘  └─────────────────────┘
```

### How it stays alive 24/7

```
schedule (every 6h, backup)  ┐
                             ├─> run ~5.5h: mount R2 → restore → install → gateway
workflow_dispatch (chained)  ┘
                                     │
                                     ▼
                   rsync ~/.hermes + ~/workspace → R2 (every 30s)
                   encrypted release backup (once at run end)
                                     │
                                     ▼
                        chain next run (if none queued)
```

### What gets saved (blacklist approach)

**Everything is saved by default.** Only clearly regenerable runtime junk is excluded:

| Excluded | Why | Regenerate with |
|---|---|---|
| `hermes-agent/`, `bin/`, `venvs/` | Hermes engine | `install.sh` |
| `.env`, `auth/` | Credentials | Written from GitHub Secrets |
| `logs/` | Runtime logs | Recreated each run |
| `node_modules/` | NPM deps | `npm install` |
| `.venv/`, `venv/` | Python venvs | `pip install` |
| `__pycache__/`, `*.pyc` | Python bytecode | Auto-created |
| `.next/`, `dist/`, `build/` | Build output | `npm run build` |
| `.cache/` | Tool caches | Auto-created |
| `.git/` (in workspace) | Git history | `git clone` |

**Everything else — including zip files, archives, images, PDFs, new unknown
files — is saved automatically.**

## Migration from release-only setup

On the **first run** with R2 configured, the workflow automatically:
1. Mounts R2 (empty bucket)
2. Detects R2 is empty → falls back to restoring from latest encrypted release
3. Pushes the restored data to R2 (migration)
4. From now on, R2 is the primary store — releases are just backups

**Your existing conversations, memory, skills, and cron jobs are preserved.**

## Gotchas

- **Keep the repo public** — private repos get 2,000 minutes/month, public
  ones are unlimited.
- Runs time out at 6h by design; the gateway is killed gracefully by SIGTERM
  and the next chained run takes over.
- R2 free tier is 10 GB — more than enough (typical usage < 1 GB).
- If R2 credentials are not set, the workflow falls back to release-only mode
  (original behavior) automatically.
- First run downloads ~1 GB (Python, Node, tooling) — subsequent runs restore
  state from R2 instantly.
- If you ever want to stop the bot: disable the workflow.

## Useful commands

```bash
hermes -z "one-shot prompt"            # scripted single prompt
hermes cron list                       # scheduled jobs
hermes send --to telegram "hello"      # send a message, no agent loop
hermes status --all                    # health check
```
