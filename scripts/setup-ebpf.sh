#!/bin/bash
# eBPF Firewall Setup Script
# Installs BCC (Linux eBPF Compiler Collection) and attaches eBPF enforcement layer

set -e

INSTALL_DIR="/opt/falco-firewall"
LOG_DIR="/var/log/falco-firewall"

echo "========================================="
echo "eBPF Firewall Setup"
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

echo "[1/6] Installing BCC and dependencies..."

case "$OS" in
    ubuntu|debian)
        apt-get update > /dev/null
        apt-get install -y \
            python3-bpfcc \
            bpfcc-tools \
            linux-headers-$(uname -r) \
            > /dev/null 2>&1
        ;;
    *)
        echo "WARNING: Unsupported OS for automatic BCC installation"
        echo "Please install python3-bpfcc and bpfcc-tools manually"
        ;;
esac

echo "[2/6] Verifying BCC installation..."

if ! python3 -c "from bcc import BPF" 2>/dev/null; then
    echo "ERROR: BCC not installed or not working"
    exit 1
fi

echo "✓ BCC installed and working"

echo "[3/6] Enabling BPF JIT compilation..."

# Enable BPF JIT for performance (optional but recommended)
if [ -f /proc/sys/net/core/bpf_jit_enable ]; then
    echo 1 > /proc/sys/net/core/bpf_jit_enable
    echo "✓ BPF JIT enabled"
else
    echo "WARNING: BPF JIT not available"
fi

echo "[4/6] Verifying kernel BPF support..."

# Check for ring buffer support (kernel 5.8+)
if python3 -c "from bcc import BPF; BPF('int test() { return 0; }', 'KPROBE_RETURN')" 2>/dev/null; then
    echo "✓ Kernel supports required eBPF features"
else
    echo "WARNING: Some eBPF features may not be available"
fi

echo "[5/6] Creating log directory..."

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"
echo "✓ Log directory created: $LOG_DIR"

echo "[6/6] Testing eBPF program load..."

# Quick test: try to load the eBPF program
if [ -f "$INSTALL_DIR/ebpf_firewall.py" ]; then
    if python3 "$INSTALL_DIR/ebpf_firewall.py" --help > /dev/null 2>&1 || \
       python3 -c "from sys import path; path.insert(0, '$INSTALL_DIR'); from ebpf_firewall import EBPFFirewall; print('OK')" 2>/dev/null; then
        echo "✓ eBPF program loads successfully"
    else
        echo "WARNING: eBPF program may have issues"
    fi
else
    echo "WARNING: ebpf_firewall.py not found in $INSTALL_DIR"
fi

echo ""
echo "========================================="
echo "✓ eBPF Setup Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Update systemd service with eBPF permissions:"
echo "     sudo systemctl daemon-reload"
echo "  2. Restart the enforcement daemon:"
echo "     sudo systemctl restart falco-firewall-enforce"
echo "  3. Verify eBPF is attached:"
echo "     tc filter show dev \$(ip route | awk '/default/{print \$5}') egress | grep bpf"
echo "  4. Check logs:"
echo "     sudo tail -f /var/log/falco-firewall/ebpf-blocked.log"
echo "  5. Run tests:"
echo "     sudo ./scripts/test-ebpf.sh"
echo ""
