#!/bin/bash
# Falco Firewall Setup Script
# Usage: sudo ./setup.sh [--domains "domain1.com,domain2.com"] [--ips "1.2.3.4,5.6.7.8"] [--auto]
# Example: sudo ./setup.sh --domains "api.example.com,registry.npm.com" --ips "10.0.1.5,192.168.1.10" --auto

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/falco-firewall"
CONFIG_DIR="/etc/falco-firewall"
LOG_DIR="/var/log/falco-firewall"
STATE_DIR="/var/lib/falco-firewall"

# Variables for whitelist
ALLOWED_DOMAINS=""
ALLOWED_IPS=""
AUTO_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domains)
            ALLOWED_DOMAINS="$2"
            shift 2
            ;;
        --ips)
            ALLOWED_IPS="$2"
            shift 2
            ;;
        --auto)
            AUTO_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--domains 'domain1,domain2'] [--ips 'ip1,ip2'] [--auto]"
            exit 1
            ;;
    esac
done

echo "========================================="
echo "Falco Firewall Setup"
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

# If not in auto mode, prompt for whitelist
if [ "$AUTO_MODE" = false ] && [ -z "$ALLOWED_DOMAINS" ] && [ -z "$ALLOWED_IPS" ]; then
    echo "Configure your firewall whitelist:"
    echo ""
    read -p "Enter allowed domains (comma-separated, or press Enter to skip): " ALLOWED_DOMAINS
    read -p "Enter allowed IPs/CIDRs (comma-separated, or press Enter to skip): " ALLOWED_IPS
    echo ""
fi

echo "[1/9] Checking prerequisites..."

# Check for required tools
for cmd in curl python3 pip3; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: Required tool not found: $cmd"
        exit 1
    fi
done

echo "[2/9] Installing system dependencies..."

case "$OS" in
    ubuntu|debian)
        apt-get update
        apt-get install -y \
            linux-headers-$(uname -r) \
            build-essential \
            nftables \
            curl \
            jq \
            git
        ;;
    amzn|rhel|centos)
        yum groupinstall -y "Development Tools"
        yum install -y \
            kernel-devel-$(uname -r) \
            nftables \
            jq \
            curl \
            git
        ;;
    *)
        echo "WARNING: Unsupported OS, trying apt-get..."
        apt-get update
        apt-get install -y nftables curl jq git
        ;;
esac

echo "[3/9] Installing Falco..."

# Install Falco from official repo
if ! command -v falco &> /dev/null; then
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        curl -s https://falco.org/repo/falcosecurity-3672BA8F.asc | apt-key add - || true
        echo "deb https://download.falco.org/packages/deb stable main" | tee /etc/apt/sources.list.d/falcosecurity.list
        apt-get update
        apt-get install -y falco
    elif [[ "$OS" == "amzn" || "$OS" == "rhel" || "$OS" == "centos" ]]; then
        rpm --import https://falco.org/repo/falcosecurity-3672BA8F.asc || true
        cat > /etc/yum.repos.d/falcosecurity.repo << EOF
[falcosecurity]
name=Falcosecurity
baseurl=https://download.falco.org/packages/rpm/\$releasever/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://falco.org/repo/falcosecurity-3672BA8F.asc
EOF
        yum install -y falco
    fi
fi

echo "[4/9] Creating installation directories..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$STATE_DIR"

echo "[5/9] Copying files..."

# Copy source files
cp -r "$SCRIPT_DIR"/src/* "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR"/config/* "$CONFIG_DIR/"
cp -r "$SCRIPT_DIR"/falco/* "$CONFIG_DIR/"

# Make scripts executable
chmod +x "$INSTALL_DIR"/*.py
chmod +x "$INSTALL_DIR"/*.sh

echo "[6/9] Installing Python dependencies..."

pip3 install -q PyYAML

echo "[7/9] Generating policy from whitelist..."

# Generate policy.yaml if whitelist was provided
if [ -n "$ALLOWED_DOMAINS" ] || [ -n "$ALLOWED_IPS" ]; then
    python3 << 'PYTHON_SCRIPT'
import sys
import yaml
import os

# Load base policy
config_dir = os.environ.get('CONFIG_DIR', '/etc/falco-firewall')
with open(f'{config_dir}/policy.yaml', 'r') as f:
    policy = yaml.safe_load(f)

# Parse whitelist inputs
domains_str = os.environ.get('ALLOWED_DOMAINS', '')
ips_str = os.environ.get('ALLOWED_IPS', '')

# Initialize allowed section
if 'allowed' not in policy:
    policy['allowed'] = {}

# Add domains
if domains_str:
    domain_list = [d.strip() for d in domains_str.split(',') if d.strip()]
    policy['allowed']['domains'] = [
        {'domain': d, 'protocol': 'tcp', 'ports': [443]}
        for d in domain_list
    ]
    print(f"Added {len(domain_list)} domains to whitelist")

# Add IPs
if ips_str:
    ip_list = [ip.strip() for ip in ips_str.split(',') if ip.strip()]
    policy['allowed']['ip_addresses'] = ip_list
    print(f"Added {len(ip_list)} IPs to whitelist")

# Write updated policy
with open(f'{config_dir}/policy.yaml', 'w') as f:
    yaml.dump(policy, f, default_flow_style=False)
PYTHON_SCRIPT
fi

echo "[8/9] Installing systemd services..."

# Copy systemd service files
mkdir -p /etc/systemd/system
cp "$SCRIPT_DIR"/systemd/*.service /etc/systemd/system/

# Update paths in service files
sed -i "s|/opt/falco-firewall|$INSTALL_DIR|g" /etc/systemd/system/falco-firewall*.service

# Reload systemd
systemctl daemon-reload

echo "[9/9] Configuring Falco..."

# Copy Falco rules
cp "$CONFIG_DIR/rules.yaml" /etc/falco/rules.d/firewall-rules.yaml

# Restart Falco
systemctl restart falco

# Start enforcement
systemctl enable falco-firewall-enforce
systemctl start falco-firewall-enforce

echo ""
echo "========================================="
echo "✓ Installation complete!"
echo "========================================="
echo ""

if [ -n "$ALLOWED_DOMAINS" ] || [ -n "$ALLOWED_IPS" ]; then
    echo "✓ Whitelist configured:"
    [ -n "$ALLOWED_DOMAINS" ] && echo "  Domains: $ALLOWED_DOMAINS"
    [ -n "$ALLOWED_IPS" ] && echo "  IPs: $ALLOWED_IPS"
    echo ""
fi

echo "Quick commands:"
echo "  Status:    sudo systemctl status falco-firewall-enforce"
echo "  Logs:      sudo journalctl -u falco-firewall-enforce -f"
echo "  Edit:      sudo vim $CONFIG_DIR/policy.yaml"
echo "  Reload:    sudo systemctl restart falco-firewall-enforce"
echo ""
echo "View firewall rules:"
echo "  sudo nft list chain inet filter firewall_out"
echo ""
