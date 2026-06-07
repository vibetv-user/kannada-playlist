#!/bin/bash
# update_with_vpn.sh — connect NordVPN to India, rebuild the live Kannada playlist from an
# Indian vantage point, push to GitHub, then disconnect. Designed to run unattended from cron.
#
# Requirements that must be set up ONCE, interactively, beforehand:
#   * NordVPN logged in:      nordvpn login   (or: nordvpn login --token <TOKEN>)
#   * Git push credentials:   a credential helper / PAT so `git push` is non-interactive
#
# Exit codes: 0 ok, 2 VPN connect/geo failure, 3 builder failure.

set -uo pipefail

REPO="$HOME/kannada-playlist"
LOG="$REPO/update_with_vpn.log"
COUNTRY_TARGET="India"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Always try to disconnect on exit, however we leave.
cleanup() {
  log "Disconnecting NordVPN..."
  nordvpn disconnect >>"$LOG" 2>&1 || true
}
trap cleanup EXIT

cd "$REPO" || { echo "Repo $REPO missing" >&2; exit 1; }

log "=== Run start ==="

# --- 1. Connect to India ----------------------------------------------------
if ! nordvpn account >/dev/null 2>&1; then
  log "❌ NordVPN is not logged in. Run 'nordvpn login' once, then retry."
  exit 2
fi

log "Connecting to $COUNTRY_TARGET ..."
if ! nordvpn connect "$COUNTRY_TARGET" >>"$LOG" 2>&1; then
  log "❌ Failed to connect to $COUNTRY_TARGET."
  exit 2
fi

# Give the tunnel a moment, then verify the exit IP is registered to India.
# NordVPN India is "Virtual" (no physical India servers since 2022): routing DBs
# (ipinfo/Cloudflare) see the physical host, while ip-api/MaxMind — the family
# Indian streaming CDNs use — report the IP as IN. We treat ip-api as authoritative
# and log the routing-DB view for transparency.
sleep 5
country=$(curl -s --max-time 10 "http://ip-api.com/line/?fields=countryCode" 2>/dev/null | tr -d '[:space:]')
ip=$(curl -s --max-time 10 "http://ip-api.com/line/?fields=query" 2>/dev/null | tr -d '[:space:]')
routing_view=$(curl -s --max-time 10 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
log "Exit IP: ${ip:-unknown} (ip-api=${country:-unknown}, ipinfo-routing=${routing_view:-unknown})"
if [[ "$country" != "IN" ]]; then
  log "❌ ip-api exit country is '${country:-unknown}', not IN. Aborting before build."
  exit 2
fi
log "✅ Verified India-registered exit IP."

# --- 2. Run the builder (enforce Indian perspective) ------------------------
log "Running build_kannada.sh ..."
if REQUIRE_IN=1 ./build_kannada.sh >>"$LOG" 2>&1; then
  count=$(grep -c '^http' kannada.m3u 2>/dev/null || echo 0)
  log "✅ Builder finished — $count live Kannada channels."
else
  log "❌ Builder failed (see log above)."
  exit 3
fi

# --- 3. Commit & push to GitHub --------------------------------------------
if git diff --quiet -- kannada.m3u 2>/dev/null; then
  log "No change to kannada.m3u — nothing to push."
else
  git add kannada.m3u build_kannada.sh update_with_vpn.sh
  git commit -m "Daily refresh: $count live Kannada channels (geo-tested from India)" >>"$LOG" 2>&1
  if git push origin HEAD >>"$LOG" 2>&1; then
    log "✅ Pushed to GitHub."
  else
    log "⚠️  git push failed (credentials not set up non-interactively?). Commit is saved locally."
  fi
fi

log "=== Run end ==="
# cleanup() runs on exit and disconnects the VPN.
