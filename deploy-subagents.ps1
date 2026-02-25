# deploy-subagents.ps1 — Update OpenClaw and push nested subagent config
# Usage: .\deploy-subagents.ps1
#
# Uses jq deep-merge on the VM so VM-only keys (botToken, plugins.entries,
# meta, wizard) are preserved while local config keys overwrite their VM counterparts.
$ErrorActionPreference = "Stop"

# Require Azure credentials as environment variables (never hardcode secrets)
foreach ($var in @("AZURE_OPENAI_API_KEY", "AZURE_OPENAI_ENDPOINT", "AZURE_STT_KEY")) {
    if (-not [System.Environment]::GetEnvironmentVariable($var)) {
        Write-Error "Missing required env var: $var. Set it before running this script."
        exit 1
    }
}

$VM = "openclaw@20.124.104.149"
$KEY = "$env:USERPROFILE\.ssh\id_rsa"
$ConfigDir = "$PSScriptRoot\config"
$SystemdDir = "$PSScriptRoot\systemd"

# Step 1: Update OpenClaw to latest version
Write-Host "==> Updating OpenClaw on VM..."
ssh -i $KEY $VM "sudo npm update -g openclaw"

# Step 2: Ensure jq is available on the VM
Write-Host "==> Ensuring jq is installed on VM..."
ssh -i $KEY $VM "command -v jq >/dev/null || sudo apt-get install -y jq"

# Step 3: Backup current config with timestamp
Write-Host "==> Backing up current config on VM..."
$Timestamp = ssh -i $KEY $VM "date +%Y%m%d_%H%M%S"
ssh -i $KEY $VM "cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak.$Timestamp"

# Step 4: Upload local config as merge source (NOT as the final config)
Write-Host "==> Uploading local config for merge..."
scp -i $KEY "$ConfigDir\openclaw.json" "${VM}:~/.openclaw/openclaw.local.json"

# Step 5: Deep merge — local wins for overlapping keys, VM-only keys preserved
#   jq -s '.[0] * .[1]' merges two objects recursively:
#     - VM-only keys (botToken, plugins.entries, meta, wizard) → preserved
#     - Keys in both (model, dmPolicy, etc.) → overwritten by local (.[1])
Write-Host "==> Merging config (VM-only keys preserved, local keys applied)..."
ssh -i $KEY $VM "jq -s '.[0] * .[1]' ~/.openclaw/openclaw.json ~/.openclaw/openclaw.local.json > ~/.openclaw/openclaw.merged.json && mv ~/.openclaw/openclaw.merged.json ~/.openclaw/openclaw.json && chmod 600 ~/.openclaw/openclaw.json && rm ~/.openclaw/openclaw.local.json"

# Step 6: Sync gateway token from merged config into systemd service file
Write-Host "==> Syncing gateway token into systemd service..."
@'
TOKEN=$(jq -r '.gateway.auth.token' ~/.openclaw/openclaw.json)
if grep -q 'OPENCLAW_GATEWAY_TOKEN' ~/.config/systemd/user/openclaw-gateway.service 2>/dev/null; then
  sed -i "s|OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=$TOKEN|" ~/.config/systemd/user/openclaw-gateway.service
  systemctl --user daemon-reload
  echo "Token synced."
else
  echo "No OPENCLAW_GATEWAY_TOKEN found in service file, skipping."
fi
'@ | ssh -i $KEY $VM "tr -d '\r' | bash"

# Step 7: Set up agent directories and upload AGENTS.md
Write-Host "==> Ensuring agents directory exists..."
ssh -i $KEY $VM "mkdir -p ~/.openclaw/agents/default"

Write-Host "==> Uploading AGENTS.md..."
scp -i $KEY "$ConfigDir\AGENTS.md" "${VM}:~/.openclaw/agents/default/AGENTS.md"

# Step 8: Deploy health check files
Write-Host "==> Deploying health check system..."
scp -i $KEY "$SystemdDir\openclaw-healthcheck.sh" "${VM}:~/.openclaw/openclaw-healthcheck.sh"
ssh -i $KEY $VM "chmod +x ~/.openclaw/openclaw-healthcheck.sh"

ssh -i $KEY $VM "mkdir -p ~/.config/systemd/user"
scp -i $KEY "$SystemdDir\openclaw-healthcheck.service" "${VM}:~/.config/systemd/user/openclaw-healthcheck.service"
scp -i $KEY "$SystemdDir\openclaw-healthcheck.timer" "${VM}:~/.config/systemd/user/openclaw-healthcheck.timer"

ssh -i $KEY $VM "systemctl --user daemon-reload"
ssh -i $KEY $VM "systemctl --user enable --now openclaw-healthcheck.timer"

# Step 9: Add Azure OpenAI env vars to systemd override (idempotent)
Write-Host "==> Ensuring Azure OpenAI env vars in systemd override..."
@'
OVERRIDE=~/.config/systemd/user/openclaw-gateway.service.d/override.conf
mkdir -p ~/.config/systemd/user/openclaw-gateway.service.d
touch "$OVERRIDE"
if ! grep -q 'AZURE_OPENAI_API_KEY' "$OVERRIDE"; then
  echo "Environment=AZURE_OPENAI_API_KEY=$AZURE_OPENAI_API_KEY" >> "$OVERRIDE"
  echo "Added AZURE_OPENAI_API_KEY to override."
else
  echo "AZURE_OPENAI_API_KEY already in override."
fi
if ! grep -q 'AZURE_OPENAI_ENDPOINT' "$OVERRIDE"; then
  echo 'Environment=AZURE_OPENAI_ENDPOINT=https://areddy-1384-resource.cognitiveservices.azure.com' >> "$OVERRIDE"
  echo "Added AZURE_OPENAI_ENDPOINT to override."
else
  echo "AZURE_OPENAI_ENDPOINT already in override."
fi
systemctl --user daemon-reload
echo "Systemd override updated and reloaded."
'@ | ssh -i $KEY $VM "tr -d '\r' | bash"

# Step 10: Update ~/.openclaw/.env with Azure vars (idempotent)
Write-Host "==> Ensuring Azure env vars in ~/.openclaw/.env..."
@'
ENV=~/.openclaw/.env
touch "$ENV"
grep -q 'AZURE_OPENAI_API_KEY' "$ENV" && sed -i '/^AZURE_OPENAI_API_KEY=/d' "$ENV"
grep -q 'AZURE_OPENAI_ENDPOINT' "$ENV" && sed -i '/^AZURE_OPENAI_ENDPOINT=/d' "$ENV"
grep -q 'AZURE_STT_KEY' "$ENV" && sed -i '/^AZURE_STT_KEY=/d' "$ENV"
echo "AZURE_OPENAI_API_KEY=$AZURE_OPENAI_API_KEY" >> "$ENV"
echo "AZURE_OPENAI_ENDPOINT=$AZURE_OPENAI_ENDPOINT" >> "$ENV"
echo "AZURE_STT_KEY=$AZURE_STT_KEY" >> "$ENV"
chmod 600 "$ENV"
echo ".env updated."
'@ | ssh -i $KEY $VM "tr -d '\r' | bash"

# Step 11: Ensure loginctl linger is enabled (required for user timers to run without login)
Write-Host "==> Ensuring loginctl linger is enabled..."
ssh -i $KEY $VM 'loginctl enable-linger $(whoami) 2>/dev/null || true'

# Step 12: Restart gateway
Write-Host "==> Restarting openclaw-gateway..."
ssh -i $KEY $VM "systemctl --user restart openclaw-gateway"

# Step 13: Verify
Write-Host "==> Waiting for gateway to start..."
Start-Sleep -Seconds 5
Write-Host "==> Verifying gateway status..."
ssh -i $KEY $VM "openclaw status"

Write-Host ""
Write-Host "==> Verifying health check timer..."
ssh -i $KEY $VM "systemctl --user list-timers openclaw-healthcheck.timer --no-pager"

Write-Host ""
Write-Host "Done! Test by sending a multi-part task to @AkhilReddyDandaBot on Telegram."
Write-Host ""
Write-Host "Test messages:"
Write-Host '  Simple:        "What time is it?"'
Write-Host '  Orchestration: "Research the latest Node.js 22 features, write a sample Express app using them, and give me a summary"'
Write-Host '  Management:    /subagents list'
