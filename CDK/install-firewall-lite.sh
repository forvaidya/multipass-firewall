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
    coredns \
    python3 \
    python3-pip \
    curl \
    jq

# [F2/F5] Create directories
echo "[F2/F5] Creating directories..."
sudo mkdir -p "$INSTALL_DIR"
sudo mkdir -p "$CONFIG_DIR"
sudo mkdir -p "$LOG_DIR"

# [F3/F5] Copy firewall repo files
echo "[F3/F5] Copying firewall configuration..."
if [ -d "/home/ubuntu/multipass-firewall" ]; then
    sudo cp -r /home/ubuntu/multipass-firewall/config/* "$CONFIG_DIR/" 2>/dev/null || true
    sudo cp -r /home/ubuntu/multipass-firewall/src/* "$INSTALL_DIR/" 2>/dev/null || true
fi

# [F4/F5] Setup nftables rules
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

        # DNS to CoreDNS
        ip protocol udp udp dport 53 accept
        ip protocol tcp tcp dport 53 accept

        # AWS metadata service
        ip daddr 169.254.169.254 accept

        # Add policy-based rules here
        # ip daddr {allowed-ips} accept
        # ip daddr . tcp dport {allowed-domains-ports} accept
    }
}
EOF'

# Enable nftables
sudo systemctl enable nftables
sudo systemctl restart nftables

# [F5/F5] Setup CoreDNS
echo "[F5/F5] Configuring CoreDNS..."
sudo bash -c 'cat > /etc/coredns/Corefile << EOF
.:53 {
    forward . 8.8.8.8 8.8.4.4
    log
    errors
}
EOF'

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
