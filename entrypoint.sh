#!/bin/bash
set -e

# Let the container's network namespace and DNS resolver settle before
# init-firewall.sh runs its first `dig`. 2s
# is conservative but avoids spurious DNS failures on slow bridge init.
sleep 2

/usr/local/bin/init-firewall.sh
[ -x /usr/local/bin/extra-allows.sh ] && /usr/local/bin/extra-allows.sh

echo ""
echo "Sandbox ready. Run 'claude-refresh' if CDN IPs rotate mid-session."
echo ""

exec su dev -c "claude $(printf '%q ' "$@")"
