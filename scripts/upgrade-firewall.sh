#!/bin/bash
# Pull the latest init-firewall.sh from upstream Anthropic, reapply patches A and B.
# Run this manually when you want to sync with upstream changes.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

cp init-firewall.sh init-firewall.sh.previous 2>/dev/null || true

curl -fsSL -o init-firewall.sh \
  https://raw.githubusercontent.com/anthropics/claude-code/main/.devcontainer/init-firewall.sh

python3 <<'PY'
from pathlib import Path
p = Path("init-firewall.sh")
src = p.read_text()

old_a = '''ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi'''
new_a = '''ips=""
    for attempt in 1 2 3; do
        ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4 == "A" {print $5}' || true)
        if [ -n "$ips" ]; then break; fi
        if [ "$attempt" -lt 3 ]; then sleep $((attempt * 2)); fi
    done
    if [ -z "$ips" ]; then
        echo "WARNING: Failed to resolve $domain after 3 attempts - skipping"
        continue
    fi'''

if "WARNING: Failed to resolve" in src:
    print("Patch A: already applied")
elif old_a in src:
    src = src.replace(old_a, new_a)
    print("Patch A: applied")
else:
    raise SystemExit("Patch A: target block not found - upstream may have changed")

count = src.count("ipset add allowed-domains")
already = src.count("ipset add -exist allowed-domains")
if count > 0:
    src = src.replace("ipset add allowed-domains", "ipset add -exist allowed-domains")
    print(f"Patch B: applied ({count} call sites)")
elif already > 0:
    print(f"Patch B: already applied ({already} call sites)")
else:
    raise SystemExit("Patch B: target not found")

p.write_text(src)
PY

grep -q "WARNING: Failed to resolve"          init-firewall.sh
grep -q "ipset add -exist allowed-domains"     init-firewall.sh
echo "Both patches verified."

if [ -f init-firewall.sh.previous ]; then
    echo ""
    echo "=== Diff against previous ==="
    diff -u init-firewall.sh.previous init-firewall.sh || true
    rm init-firewall.sh.previous
fi
