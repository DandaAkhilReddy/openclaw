#!/usr/bin/env bash
# openclaw-healthcheck.sh — Health check for OpenClaw gateway
# Deployed to ~/.openclaw/openclaw-healthcheck.sh on the VM
# Triggered every 5 minutes by openclaw-healthcheck.timer
#
# Checks:
#   1. Is openclaw-gateway systemd service active?
#   2. Does `openclaw status` exit cleanly?
#   3. Is Telegram channel OK (not SETUP/ERROR/missing)?
#   4. Is WhatsApp channel OK (not ERROR/disconnected/missing)?
#
# If unhealthy → restart gateway (max 3 consecutive failures, then stop).
set -euo pipefail

TAG="openclaw-healthcheck"
FAIL_FILE="/tmp/openclaw-healthcheck-failures"
MAX_FAILURES=3

log() { logger -t "$TAG" "$1"; }

get_failures() {
    if [[ -f "$FAIL_FILE" ]]; then
        cat "$FAIL_FILE"
    else
        echo 0
    fi
}

set_failures() {
    echo "$1" > "$FAIL_FILE"
}

restart_gateway() {
    local failures
    failures=$(get_failures)
    failures=$((failures + 1))
    set_failures "$failures"

    if [[ "$failures" -gt "$MAX_FAILURES" ]]; then
        log "CRITICAL: $MAX_FAILURES consecutive failures reached. NOT restarting to prevent loops. Manual intervention required."
        log "CRITICAL: Run 'rm $FAIL_FILE' after fixing the issue, then restart: systemctl --user restart openclaw-gateway"
        return 1
    fi

    log "WARN: Restarting openclaw-gateway (attempt $failures/$MAX_FAILURES)..."
    systemctl --user restart openclaw-gateway
    sleep 10  # Give it time to reconnect channels
}

# Check 1: Is the systemd service active?
if ! systemctl --user is-active --quiet openclaw-gateway; then
    log "FAIL: openclaw-gateway service is not active"
    restart_gateway
    exit 0
fi

# Check 2: Does `openclaw status` exit cleanly?
STATUS_OUTPUT=$(openclaw status 2>&1) || {
    log "FAIL: 'openclaw status' exited with error"
    log "FAIL: Output: $STATUS_OUTPUT"
    restart_gateway
    exit 0
}

# Check 3: Telegram channel health
# Look for Telegram showing as anything other than OK/ON
if echo "$STATUS_OUTPUT" | grep -qi "telegram"; then
    if echo "$STATUS_OUTPUT" | grep -qi "telegram.*\(SETUP\|ERROR\|OFF\|disabled\)"; then
        log "FAIL: Telegram channel is not healthy"
        log "FAIL: Status: $(echo "$STATUS_OUTPUT" | grep -i telegram)"
        restart_gateway
        exit 0
    fi
else
    log "WARN: Telegram not found in status output (may not be configured)"
fi

# Check 4: WhatsApp channel health
if echo "$STATUS_OUTPUT" | grep -qi "whatsapp"; then
    if echo "$STATUS_OUTPUT" | grep -qi "whatsapp.*\(ERROR\|disconnected\|OFF\|disabled\)"; then
        log "FAIL: WhatsApp channel is not healthy"
        log "FAIL: Status: $(echo "$STATUS_OUTPUT" | grep -i whatsapp)"
        restart_gateway
        exit 0
    fi
else
    log "WARN: WhatsApp not found in status output (may not be configured)"
fi

# All checks passed — reset failure counter
set_failures 0
log "OK: Gateway healthy — all channels operational"
