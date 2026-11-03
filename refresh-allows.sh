#!/bin/bash
# refresh-allows.sh — rendered by Ansible from refresh-allows.sh.j2
# Re-resolves CDN-prone domains and re-applies firewall rules mid-session.
# Run inside the container when CDN IP addresses rotate.
set -euo pipefail

allow_domain() {
  local domain="$1"
  local ips
  ips=""
  for attempt in 1 2 3; do
    ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}' || true)
    if [ -n "$ips" ]; then break; fi
    if [ "$attempt" -lt 3 ]; then sleep $((attempt * 2)); fi
  done

  if [ -z "$ips" ]; then
    echo "WARNING: Failed to resolve $domain after 3 attempts - skipping"
    return
  fi

  for ip in $ips; do
    ipset add allowed-domains "$ip" 2>/dev/null || \
      iptables -I OUTPUT -d "$ip" -j ACCEPT 2>/dev/null || true
    echo "  Refreshed $domain -> $ip"
  done
}

echo "Refreshing firewall allowlist..."

# Re-apply the full extra allowlist in case new IPs were provisioned.
[ -x /usr/local/bin/extra-allows.sh ] && /usr/local/bin/extra-allows.sh

# CDN-prone domains that rotate IPs frequently.
CDN_DOMAINS=(
  # Anthropic / Claude Code API
  "api.anthropic.com"
  "sentry.io"
  "statsig.anthropic.com"
  "statsig.com"
  # npm / node CDN
  "registry.npmjs.org"
  "cdn.npmjs.com"
  # GitHub
  "github.com"
  "api.github.com"
  "objects.githubusercontent.com"
  "raw.githubusercontent.com"
  "codeload.github.com"
  # AWS S3 / CloudFront (Claude assets)
  "s3.amazonaws.com"
)

for domain in "${CDN_DOMAINS[@]}"; do
  allow_domain "$domain"
done

echo "Refresh complete."
