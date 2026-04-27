#!/bin/bash
# Unified Firewall Setup Script
# Installs and configures all three layers:
# - Layer 1: CoreDNS (DNS whitelist filtering)
# - Layer 2: eBPF TC (enforcement + monitoring)
# - Layer 3: nftables (safety net backup)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/falco-firewall"
CONFIG_DIR="/etc/falco-firewall"
LOG_DIR="/var/log/falco-firewall"
STATE_DIR="/var/lib/falco-firewall"

echo "========================================="
echo "Unified Firewall Setup"
echo "Three-Layer Protection:"
echo "  Layer 1: CoreDNS (DNS filtering)"
echo "  Layer 2: eBPF (enforcement + monitoring)"
echo "  Layer 3: nftables (backup safety net)"
echo "========================================="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "ERROR: Cannot detect OS"
    exit 1
fi

echo "[0/5] Creating directories..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR"
echo "✓ Directories created"

echo ""
echo "[1/5] Installing Layer 1 - CoreDNS..."
if [ -x "$SCRIPT_DIR/scripts/setup-coredns.sh" ]; then
    "$SCRIPT_DIR/scripts/setup-coredns.sh"
    echo "✓ CoreDNS installed"
else
    echo "ERROR: setup-coredns.sh not found"
    exit 1
fi

echo ""
echo "[2/5] Installing Layer 2 - eBPF..."
if [ -x "$SCRIPT_DIR/scripts/setup-ebpf.sh" ]; then
    "$SCRIPT_DIR/scripts/setup-ebpf.sh"
    echo "✓ eBPF installed"
else
    echo "WARNING: setup-ebpf.sh not found, skipping eBPF"
fi

echo ""
echo "[3/5] Copying application files..."
cp -r "$SCRIPT_DIR/src"/* "$INSTALL_DIR/" 2>/dev/null || true
cp -r "$SCRIPT_DIR/config"/* "$CONFIG_DIR/" 2>/dev/null || true
cp -r "$SCRIPT_DIR/falco"/* "$CONFIG_DIR/" 2>/dev/null || true
chmod +x "$INSTALL_DIR"/*.py 2>/dev/null || true
echo "✓ Files copied to $INSTALL_DIR"

echo ""
echo "[4/5] Installing systemd services..."
mkdir -p /etc/systemd/system
cp "$SCRIPT_DIR/systemd"/*.service /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload
systemctl enable falco-firewall-enforce 2>/dev/null || true
systemctl enable coredns 2>/dev/null || true
echo "✓ Systemd services installed"

echo ""
echo "[5/5] Starting services..."
systemctl start coredns
sleep 2
systemctl start falco-firewall-enforce
sleep 2
echo "✓ Services started"

echo ""
echo "========================================="
echo "✓ Firewall Setup Complete!"
echo "========================================="
echo ""

# Run quick verification
echo "Verifying installation..."
echo ""

# Check CoreDNS
if systemctl is-active --quiet coredns; then
    echo "✓ CoreDNS is running"
else
    echo "✗ CoreDNS not running"
fi

# Check eBPF
IFACE=$(ip route | awk '/default/{print $5}')
if tc filter show dev "$IFACE" egress 2>/dev/null | grep -q bpf; then
    echo "✓ eBPF is attached"
else
    echo "⚠ eBPF not attached yet (may be loading)"
fi

# Check enforcement daemon
if systemctl is-active --quiet falco-firewall-enforce; then
    echo "✓ Enforcement daemon is running"
else
    echo "✗ Enforcement daemon not running"
fi

echo ""
echo "Quick tests:"
echo "  • DNS test: dig @127.0.0.1 github.com"
echo "  • eBPF test: sudo ./scripts/test-ebpf.sh"
echo "  • Status: sudo systemctl status falco-firewall-enforce"
echo "  • Logs: sudo journalctl -u falco-firewall-enforce -f"
echo "  • eBPF logs: sudo tail -f /var/log/falco-firewall/ebpf-blocked.log"
echo ""
echo "Edit whitelist: sudo vim /etc/falco-firewall/policy.yaml"
echo "Reload policy: sudo systemctl kill -s SIGHUP falco-firewall-enforce"
echo ""
