#!/bin/bash
# Show firewall status and statistics

echo "========================================="
echo "Falco Firewall Status"
echo "========================================="
echo ""

echo "=== Service Status ==="
systemctl status falco-firewall-enforce --no-pager || echo "Service not running"
echo ""

echo "=== nftables Rules ==="
nft list ruleset | grep -A 50 "firewall_out" || echo "No rules loaded"
echo ""

echo "=== Recent Violations (last 20 lines) ==="
tail -20 /var/log/falco-firewall/enforcement.log 2>/dev/null || echo "No log file yet"
echo ""

echo "=== Denied Connections (last 10) ==="
tail -10 /var/log/falco-firewall/denied.log 2>/dev/null || echo "No denials yet"
echo ""

echo "=== Allowed Destinations ==="
python3 /opt/falco-firewall/enforce.py status 2>/dev/null || echo "Unable to get status"
