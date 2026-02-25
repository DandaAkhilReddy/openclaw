#!/usr/bin/env bash
# deploy-subagents.sh — Push nested subagent config to the OpenClaw Azure VM
# Usage: bash deploy-subagents.sh
#
# Uses jq deep-merge so VM-only keys (botToken, plugins.entries, meta, wizard)
# are preserved while local config keys overwrite their VM counterparts.
set -euo pipefail

VM="openclaw@20.124.104.149"
KEY="/c/Users/akhil/.ssh/id_rsa"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
SYSTEMD_DIR="$SCRIPT_DIR/systemd"

SSH="ssh -i $KEY"
SCP="scp -i $KEY"

# Step 1: Ensure jq is available on the VM
echo "==> Ensuring jq is installed on VM..."
$SSH "$VM" "command -v jq >/dev/null || sudo apt-get install -y jq"

# Step 2: Backup current config with timestamp
echo "==> Backing up current config on VM..."
TIMESTAMP=$($SSH "$VM" "date +%Y%m%d_%H%M%S")
$SSH "$VM" "cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak.$TIMESTAMP"

# Step 3: Upload local config as merge source (NOT as the final config)
echo "==> Uploading local config for merge..."
$SCP "$CONFIG_DIR/openclaw.json" "$VM:~/.openclaw/openclaw.local.json"

# Step 4: Deep merge — local wins for overlapping keys, VM-only keys preserved
#   jq -s '.[0] * .[1]' merges two objects recursively:
#     - VM-only keys (botToken, plugins.entries, meta, wizard) → preserved
#     - Keys in both (model, dmPolicy, etc.) → overwritten by local (.[1])
echo "==> Merging config (VM-only keys preserved, local keys applied)..."
$SSH "$VM" 'jq -s ".[0] * .[1]" ~/.openclaw/openclaw.json ~/.openclaw/openclaw.local.json > ~/.openclaw/openclaw.merged.json && mv ~/.openclaw/openclaw.merged.json ~/.openclaw/openclaw.json && rm ~/.openclaw/openclaw.local.json'

# Step 5: Sync gateway token from merged config into systemd service file
echo "==> Syncing gateway token into systemd service..."
$SSH "$VM" 'TOKEN=$(jq -r ".gateway.auth.token" ~/.openclaw/openclaw.json); if grep -q "OPENCLAW_GATEWAY_TOKEN" ~/.config/systemd/user/openclaw-gateway.service 2>/dev/null; then sed -i "s|OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=$TOKEN|" ~/.config/systemd/user/openclaw-gateway.service; systemctl --user daemon-reload; echo "Token synced."; else echo "No OPENCLAW_GATEWAY_TOKEN found in service file, skipping."; fi'

# Step 6: Set up agent directories and upload AGENTS.md
echo "==> Ensuring agents directory exists..."
$SSH "$VM" "mkdir -p ~/.openclaw/agents/default"

echo "==> Uploading AGENTS.md..."
$SCP "$CONFIG_DIR/AGENTS.md" "$VM:~/.openclaw/agents/default/AGENTS.md"

# Step 7: Deploy health check files
echo "==> Deploying health check system..."
$SCP "$SYSTEMD_DIR/openclaw-healthcheck.sh" "$VM:~/.openclaw/openclaw-healthcheck.sh"
$SSH "$VM" "chmod +x ~/.openclaw/openclaw-healthcheck.sh"

$SSH "$VM" "mkdir -p ~/.config/systemd/user"
$SCP "$SYSTEMD_DIR/openclaw-healthcheck.service" "$VM:~/.config/systemd/user/openclaw-healthcheck.service"
$SCP "$SYSTEMD_DIR/openclaw-healthcheck.timer" "$VM:~/.config/systemd/user/openclaw-healthcheck.timer"

$SSH "$VM" "systemctl --user daemon-reload"
$SSH "$VM" "systemctl --user enable --now openclaw-healthcheck.timer"

# Step 8: Ensure loginctl linger is enabled (required for user timers to run without login)
echo "==> Ensuring loginctl linger is enabled..."
$SSH "$VM" "loginctl enable-linger \$(whoami) 2>/dev/null || true"

# Step 9: Restart gateway
echo "==> Restarting openclaw-gateway..."
$SSH "$VM" "systemctl --user restart openclaw-gateway"

# Step 10: Verify
echo "==> Verifying gateway status..."
sleep 5
$SSH "$VM" "openclaw status"

echo ""
echo "==> Verifying health check timer..."
$SSH "$VM" "systemctl --user list-timers openclaw-healthcheck.timer --no-pager"

echo ""
echo "Done! Test by sending a multi-part task to @AkhilReddyDandaBot on Telegram."
echo "Management commands:"
echo "  /subagents list   — Show active/completed sub-agents"
echo "  /subagents kill <id> — Stop a specific sub-agent"
echo "  /stop             — Cascade stop to all children"
