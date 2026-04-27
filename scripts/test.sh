#!/bin/bash
# Test Falco Firewall functionality

set -e

CONFIG_FILE="${1:-/etc/falco-firewall/policy.yaml}"
ALLOWED_DOMAIN="registry.npmjs.org"
BLOCKED_IP="8.8.8.8"

echo "========================================="
echo "Falco Firewall Testing"
echo "========================================="
echo ""

# Check if enforcement is running
echo "[1] Checking enforcement status..."
if ! systemctl is-active --quiet falco-firewall-enforce; then
    echo "ERROR: Enforcement service not running"
    echo "Start it with: sudo systemctl start falco-firewall-enforce"
    exit 1
fi
echo "✓ Enforcement service running"
echo ""

# Test allowed domain
echo "[2] Testing allowed domain connection: $ALLOWED_DOMAIN"
if timeout 5 curl -s -m 3 "https://$ALLOWED_DOMAIN" > /dev/null 2>&1; then
    echo "✓ Connection allowed (expected)"
else
    echo "✗ Connection failed - may be blocked or not configured"
fi
echo ""

# Test AWS metadata service
echo "[3] Testing AWS metadata service (169.254.169.254)..."
if timeout 3 curl -s -m 2 "http://169.254.169.254/latest/meta-data/" > /dev/null 2>&1; then
    echo "✓ Metadata service accessible"
else
    echo "⚠ Metadata service not accessible (may not be AWS environment)"
fi
echo ""

# Test blocked IP
echo "[4] Testing blocked IP: $BLOCKED_IP (should timeout/fail)"
if timeout 3 curl -s -m 2 "http://$BLOCKED_IP" > /dev/null 2>&1; then
    echo "✗ Connection succeeded - may not be blocked"
else
    echo "✓ Connection blocked (expected)"
fi
echo ""

# Check logs
echo "[5] Checking for violations in logs..."
if [ -f /var/log/falco-firewall/denied.log ]; then
    DENY_COUNT=$(wc -l < /var/log/falco-firewall/denied.log)
    echo "Denied connections: $DENY_COUNT"
fi

if [ -f /var/log/falco-firewall/enforcement.log ]; then
    RECENT=$(tail -3 /var/log/falco-firewall/enforcement.log)
    if [ -n "$RECENT" ]; then
        echo "Recent entries:"
        echo "$RECENT"
    fi
fi
echo ""

# Show current rules
echo "[6] Current nftables rules:"
nft list chain inet filter firewall_out 2>/dev/null | head -20 || echo "No rules loaded"
echo ""

echo "========================================="
echo "Testing complete!"
echo "========================================="
