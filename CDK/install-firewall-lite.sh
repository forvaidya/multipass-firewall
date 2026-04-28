#!/bin/bash
# Lightweight firewall setup using nftables + CoreDNS (no Falco)
# Run as: sudo bash install-firewall-lite.sh

set -e

echo "=== Lightweight Firewall Setup (nftables + CoreDNS) ==="

INSTALL_DIR="/opt/falco-firewall"
CONFIG_DIR="/etc/falco-firewall"
LOG_DIR="/var/log/falco-firewall"

# [F1/F5] Install dependencies
echo "[F1/F5] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y \
    nftables \
    python3 \
    python3-pip \
    curl \
    jq \
    wget

# Download CoreDNS binary (aarch64 for Graviton)
echo "Downloading CoreDNS..."
COREDNS_VERSION="1.10.1"
wget -q https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/coredns_${COREDNS_VERSION}_linux_arm64.tgz -O /tmp/coredns.tgz
tar -xzf /tmp/coredns.tgz -C /tmp/
sudo mv /tmp/coredns /usr/local/bin/
sudo chmod +x /usr/local/bin/coredns
rm -f /tmp/coredns.tgz

# [F2/F5] Create directories
echo "[F2/F5] Creating directories..."
sudo mkdir -p "$INSTALL_DIR"
sudo mkdir -p "$CONFIG_DIR"
sudo mkdir -p "$LOG_DIR"

# [F3/F5] Create configuration directories
echo "[F3/F5] Creating configuration..."
sudo mkdir -p "$CONFIG_DIR"

# Fix hostname resolution for sudo
echo "127.0.0.1 $(hostname)" | sudo tee -a /etc/hosts > /dev/null 2>&1 || true

# [F4/F5] Setup nftables rules (whitelist-only firewall)
echo "[F4/F5] Configuring nftables..."
sudo bash -c 'cat > /etc/nftables.conf << EOF
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
        ct state established,related accept
        ct state invalid drop
        iif lo accept
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
    }

    chain output {
        type filter hook output priority 0; policy drop;

        # Allow loopback
        oif lo accept

        # Allow established connections
        ct state established,related accept

        # Allow DNS (port 53) for CoreDNS
        tcp dport 53 accept
        udp dport 53 accept

        # Allow HTTPS (port 443)
        tcp dport 443 accept

        # Allow HTTP (port 80)
        tcp dport 80 accept

        # Allow ICMP (ping)
        ip protocol icmp accept

        # AWS metadata service
        ip daddr 169.254.169.254 accept

        # Add custom whitelisted IPs/domains here
        # ip daddr {10.0.0.0/8} accept
    }
}
EOF'

# Enable nftables
sudo systemctl enable nftables
sudo systemctl restart nftables

# [F5/F5] Setup CoreDNS
echo "[F5/F5] Configuring CoreDNS..."
sudo mkdir -p /etc/coredns
sudo bash -c 'cat > /etc/coredns/Corefile << EOF
.:53 {
    forward . 8.8.8.8 8.8.4.4
    log
    errors
}
EOF'

# Create CoreDNS systemd service
sudo bash -c 'cat > /etc/systemd/system/coredns.service << EOF
[Unit]
Description=CoreDNS
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF'

sudo systemctl daemon-reload
sudo systemctl enable coredns
sudo systemctl restart coredns

echo ""
echo "=== Lightweight Firewall Setup Complete ==="
echo "✅ nftables + CoreDNS configured!"
echo ""
echo "Status:"
echo "  sudo systemctl status nftables"
echo "  sudo systemctl status coredns"
echo ""
echo "Check rules:"
echo "  sudo nft list ruleset"
echo ""
echo "Update DNS in /etc/resolv.conf to use CoreDNS:"
echo "  echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf"
