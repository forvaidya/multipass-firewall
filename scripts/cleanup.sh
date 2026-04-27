#!/bin/bash
# Falco Firewall Cleanup Script
# Uninstall and remove all firewall rules

set -e

echo "========================================="
echo "Falco Firewall Cleanup"
echo "========================================="

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

echo "[1/5] Stopping services..."
systemctl stop falco-firewall-enforce || true
systemctl stop falco || true

echo "[2/5] Removing systemd services..."
rm -f /etc/systemd/system/falco-firewall*.service
systemctl daemon-reload

echo "[3/5] Removing firewall rules..."
nft flush ruleset || true

echo "[4/5] Removing installation files..."
rm -rf /opt/falco-firewall

echo "[5/5] Removing configuration..."
rm -rf /etc/falco-firewall
rm -f /etc/falco/rules.d/firewall-rules.yaml

echo ""
echo "✓ Cleanup complete!"
echo ""
