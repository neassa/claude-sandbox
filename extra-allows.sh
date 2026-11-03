#!/bin/bash
# extra-allows.sh — rendered by Ansible from extra-allows.sh.j2
# Adds extra IP ranges to the sandbox firewall allowlist.
# Called by entrypoint.sh after init-firewall.sh has run.
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
    # Prefer ipset (used by the current init-firewall.sh); fall back to a
    # direct iptables INSERT for compatibility with older script versions.
    ipset add allowed-domains "$ip" 2>/dev/null || \
      iptables -I OUTPUT -d "$ip" -j ACCEPT 2>/dev/null || true
    echo "  Allowed $domain -> $ip"
  done
}

echo "Applying extra firewall allowlist..."

# PyPI
allow_domain "pypi.org"
allow_domain "files.pythonhosted.org"

# Hugging Face
allow_domain "huggingface.co"
allow_domain "cdn-lfs.huggingface.co"

# Figma MCP server (remote)
allow_domain "mcp.figma.com"
allow_domain "www.figma.com"
allow_domain "figma.com"

# CF play ground
allow_domain "focus-test-playground-site.cip-ammcom.workers.dev"


echo "Extra allowlist applied."
# --- ALLOW ALL (disables default-deny firewall) ---
# Remove or comment out to re-enable firewall enforcement.
#iptables -I OUTPUT 1 -j ACCEPT
#echo "WARNING: Firewall disabled — all outbound traffic allowed."
