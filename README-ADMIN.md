# OpenClaw on Azure VM - Admin Reference

## VM Details
- **IP**: 20.124.104.149
- **User**: openclaw
- **Resource Group**: rg-openclaw
- **VM Name**: vm-openclaw
- **Size**: Standard_B2s (2 vCPU, 4 GB RAM)
- **OS**: Ubuntu 24.04 LTS

## Quick Commands

### SSH into VM
```bash
ssh openclaw@20.124.104.149
```

### Access Dashboard (via SSH tunnel)
```bash
ssh -N -L 18789:127.0.0.1:18789 openclaw@20.124.104.149
# Then open http://127.0.0.1:18789/ in browser
```

### Check Status
```bash
ssh openclaw@20.124.104.149 "openclaw status"
```

### View Logs (live)
```bash
ssh openclaw@20.124.104.149 "openclaw logs --follow"
```

### Restart Gateway
```bash
ssh openclaw@20.124.104.149 "systemctl --user restart openclaw-gateway"
```

## Telegram Bot
- **Bot**: @AkhilReddyDandaBot
- **Primary Model**: GPT-5.2-chat (azure-openai-responses/gpt-5.2-chat)
- **Fallback Model**: Anthropic Claude Sonnet 4.5 (anthropic/claude-sonnet-4-5-20250929)
- **Azure OpenAI Endpoint**: https://areddy-1626-resource.cognitiveservices.azure.com
- **Auto-Chat**: Owner-commanded autonomous messaging (see config/AGENTS.md)

## Monthly Cost Estimate
| Component | Cost |
|-----------|------|
| Azure B2s VM | ~$30 |
| OS Disk (30GB SSD) | ~$2.40 |
| Public IP | ~$3.65 |
| Azure OpenAI API (GPT-5.2-chat) | ~$5-25 |
| Azure GPT-4o-transcribe STT | ~$1 |
| **Total** | **~$42-62** |

## Nested Subagents

The orchestrator (GPT-5.2-chat) spawns specialized workers for multi-step tasks.

### Architecture

```
User (Telegram) → @AkhilReddyDandaBot
                     │
              ┌──────┴──────┐  (depth 0: main agent)
              │ Orchestrator │  model: GPT-5.2-chat
              └──────┬──────┘
         ┌───────────┼───────────┐
         ▼           ▼           ▼     (depth 1: workers)
   ┌──────────┐ ┌─────────┐ ┌──────────┐
   │Researcher│ │  Coder  │ │Summarizer│
   │(GPT-5.2) │ │(GPT-5.2)│ │(GPT-5.2) │
   └──────────┘ └─────────┘ └──────────┘
```

### Subagent Profiles

| Profile | Model | Tools | Use Case |
|---------|-------|-------|----------|
| `researcher` | Azure GPT-5.2-chat | web_search, web_fetch, read | Web search, fact-finding, reading docs |
| `coder` | Azure GPT-5.2-chat | exec, read, write | Writing/editing code, running tests |
| `summarizer` | Azure GPT-5.2-chat | read | Condensing results into summaries |

### Config Location

- **VM config**: `~/.openclaw/openclaw.json`
- **System prompt**: `~/.openclaw/agents/default/AGENTS.md`
- **Local copies**: `config/openclaw.json`, `config/AGENTS.md`

### Safety Limits

| Setting | Value | Purpose |
|---------|-------|---------|
| `subagents.maxConcurrent` | 5 | Global concurrency cap across all agents |
| `subagents.archiveAfterMinutes` | 60 | Auto-archives idle subagents |
| `allowAgents: []` on workers | — | Workers cannot spawn their own children |

**Per-spawn timeouts** are set via the `runTimeoutSeconds` parameter in `sessions_spawn` calls.

**Requires OpenClaw v2026.2.15+** — nested spawning is blocked on older versions.
Update with: `openclaw update` (NOT `npm update -g openclaw@latest`).

### Management Commands (Telegram)

```
/subagents list       — Show active/completed sub-agents
/subagents kill <id>  — Stop a specific sub-agent
/stop                 — Cascade stop to all children
```

### Deploy Config Changes

```powershell
.\deploy-subagents.ps1
```

Or bash:
```bash
bash deploy-subagents.sh
```

Both scripts use **safe merge deploy** — local config keys overwrite their VM counterparts, but VM-only keys (`botToken`, `plugins.entries`, `meta`, `wizard`) are preserved. See [Resilience & Auto-Recovery](#resilience--auto-recovery) below.

### Cost Impact

| Component | Cost per MTok |
|-----------|--------------|
| GPT-5.2-chat (all agents) | TBD (pricing not yet published) |

All agents use Azure GPT-5.2-chat as primary with Anthropic Claude Sonnet 4.5 as fallback.
Estimated additional cost with subagents: **~$5-15/month** depending on usage.

## Telegram DM Access Control

The bot uses **pairing mode** — unknown users do NOT get AI responses.

### How It Works

1. Unknown user messages the bot → receives a **pairing code** (e.g. `A7X-K2M`)
2. Their actual message is **ignored** — no AI response is sent
3. Akhil reviews pending requests and approves or ignores them
4. Only after approval can that user chat with the bot

Akhil's Telegram account (ID `7750772609`) is pre-approved via `allowFrom` and always works.

### Management Commands

```bash
# List pending pairing requests
ssh openclaw@20.124.104.149 "openclaw pairing list telegram"

# Approve a user by their pairing code
ssh openclaw@20.124.104.149 "openclaw pairing approve telegram <CODE>"

# Reject a pending request
ssh openclaw@20.124.104.149 "openclaw pairing reject telegram <CODE>"

# List all approved users
ssh openclaw@20.124.104.149 "openclaw pairing approved telegram"

# Revoke a previously approved user
ssh openclaw@20.124.104.149 "openclaw pairing revoke telegram <USER_ID>"
```

### Config Reference

In `config/openclaw.json` → `channels.telegram`:

| Setting | Value | Purpose |
|---------|-------|---------|
| `dmPolicy` | `"pairing"` | Unknown users get a code, no AI reply until approved |
| `allowFrom` | `["7750772609"]` | Pre-approved Telegram user IDs (Akhil) |
| `groupPolicy` | `"allowlist"` | Only allowlisted users can trigger bot in groups |
| `groupAllowFrom` | `["7750772609"]` | Users allowed to trigger bot in groups |
| `groups.*` | `requireMention: true` | Bot only responds when @mentioned in groups |

## WhatsApp DM Access Control

The bot uses **allowlist mode** on WhatsApp — unknown users are **silently ignored**. No pairing code, no auto-reply, nothing. Only pre-approved numbers get responses.

### How It Works

1. Unknown user messages the bot → **no response at all** (silently dropped)
2. Only numbers listed in `channels.whatsapp.allowFrom` can interact with the bot
3. Same allowlist applies to group interactions via `groupAllowFrom`

Akhil's WhatsApp number (`12249999944`) is pre-approved and always works.

### Adding a New User

1. Edit `config/openclaw.json` → `channels.whatsapp.allowFrom`, add the new number
2. If they should also work in groups, add to `groupAllowFrom` too
3. Deploy: `.\deploy-subagents.ps1`
4. Verify: `ssh openclaw@20.124.104.149 "openclaw status"` — should show WhatsApp enabled with no config errors

### Config Reference

In `config/openclaw.json` → `channels.whatsapp`:

| Setting | Value | Purpose |
|---------|-------|---------|
| `dmPolicy` | `"allowlist"` | Only allowlisted numbers get responses; everyone else is silently ignored |
| `allowFrom` | `["12249999944"]` | Pre-approved WhatsApp numbers (Akhil) |
| `groupPolicy` | `"allowlist"` | Only allowlisted users can trigger bot in groups |
| `groupAllowFrom` | `["12249999944"]` | Users allowed to trigger bot in groups |
| `groups.*` | `requireMention: true` | Bot only responds when @mentioned in groups |

### Why Allowlist Instead of Pairing?

Telegram uses `"pairing"` mode — unknown users get a code and can request access. WhatsApp uses `"allowlist"` because:
- WhatsApp exposes phone numbers, making spam bots more aggressive
- No need for a self-service onboarding flow on WhatsApp
- Simpler: either you're on the list or you're invisible to the bot

## Voice Message Transcription (STT)

Voice messages on WhatsApp and Telegram are automatically transcribed to text before reaching the agent.

### How It Works

1. User sends a voice note → channel delivers `.ogg` audio to OpenClaw
2. Media pipeline transcribes via the configured STT provider chain
3. Transcript replaces the message body as an `[Audio]` block
4. Agent receives and responds to the transcript as normal text

### STT Provider Chain

| Priority | Provider | Model | Cost |
|----------|----------|-------|------|
| 1 (primary) | Azure GPT-4o-transcribe via CLI curl | `gpt-4o-transcribe` deployment on `areddy-1384-resource` | $0.006/min |
| 2 (fallback) | Local whisper-cli | `ggml-base` | Free |

### Prerequisites

- `ffmpeg` installed on VM
- `whisper-cli` built from whisper.cpp at `/usr/local/bin/whisper-cli`
- `AZURE_STT_KEY` set in `~/.openclaw/.env`
- `AZURE_OPENAI_ENDPOINT` and `AZURE_OPENAI_API_KEY` set in `~/.openclaw/.env`
- Whisper model at `/home/openclaw/.local/share/whisper-models/ggml-base.bin`

### Troubleshooting

```bash
# Check audio config
ssh openclaw@20.124.104.149 "jq '.tools.media' ~/.openclaw/openclaw.json"

# Watch STT logs
ssh openclaw@20.124.104.149 "openclaw logs --follow"

# Test ffmpeg
ssh openclaw@20.124.104.149 "ffmpeg -version | head -1"

# Test whisper-cli
ssh openclaw@20.124.104.149 "whisper-cli --version"
```

### Monthly Cost Impact

~$1/month additional (Azure GPT-4o-transcribe at $0.006/min for typical usage).

## Resilience & Auto-Recovery

The gateway has three layers of protection against downtime:

### Layer 1: Crash Recovery (systemd)

The `openclaw-gateway` systemd service has `Restart=always` + `RestartSec=5`. If the process crashes, systemd restarts it automatically within 5 seconds.

### Layer 2: Safe Merge Deploy

Deploy scripts (`deploy-subagents.ps1` / `deploy-subagents.sh`) use `jq` deep-merge instead of SCP overwrite. This prevents deploy-induced outages caused by wiping VM-only keys.

**How it works:**
1. Local `config/openclaw.json` is uploaded as `~/.openclaw/openclaw.local.json`
2. `jq -s '.[0] * .[1]'` merges VM config (base) with local config (overlay)
3. Overlapping keys are overwritten by local values (desired)
4. VM-only keys (`botToken`, `plugins.entries`, `meta`, `wizard`) are preserved

A timestamped backup is created before every merge (e.g. `openclaw.json.bak.20260218_143000`).

### Layer 3: Health Check Timer

A systemd timer runs every 5 minutes and checks:
1. Is `openclaw-gateway` service active?
2. Does `openclaw status` exit cleanly?
3. Is Telegram channel OK (not SETUP/ERROR)?
4. Is WhatsApp channel OK (not ERROR/disconnected)?

If any check fails, the gateway is restarted automatically. After 3 consecutive failures, restarts stop to prevent loops — manual intervention is required.

**View health check logs:**
```bash
ssh openclaw@20.124.104.149 "journalctl --user -t openclaw-healthcheck -n 20"
```

**Check timer status:**
```bash
ssh openclaw@20.124.104.149 "systemctl --user list-timers openclaw-healthcheck.timer"
```

**Reset failure counter** (after fixing an issue manually):
```bash
ssh openclaw@20.124.104.149 "rm /tmp/openclaw-healthcheck-failures"
```

### Health Check Files

| File | Location on VM | Purpose |
|------|---------------|---------|
| `systemd/openclaw-healthcheck.sh` | `~/.openclaw/openclaw-healthcheck.sh` | Health check script |
| `systemd/openclaw-healthcheck.service` | `~/.config/systemd/user/openclaw-healthcheck.service` | Systemd oneshot unit |
| `systemd/openclaw-healthcheck.timer` | `~/.config/systemd/user/openclaw-healthcheck.timer` | 5-minute timer |

All three files are deployed automatically by the deploy scripts.
