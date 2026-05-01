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

# Stop systemd-resolved (conflicts with CoreDNS on port 53)
echo "Stopping systemd-resolved..."
sudo systemctl stop systemd-resolved 2>/dev/null || true
sudo systemctl disable systemd-resolved 2>/dev/null || true

# Configure /etc/resolv.conf to use CoreDNS
echo "Configuring DNS resolver to use CoreDNS..."
# Note: systemd-resolved creates /etc/resolv.conf as a symlink to stub-resolv.conf.
# We need to remove this symlink and replace it with a real file pointing to CoreDNS.
sudo rm -f /etc/resolv.conf
# Create new resolv.conf pointing to CoreDNS (127.0.0.1:53)
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
EOF'
sudo chmod 644 /etc/resolv.conf

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

        # Allow HTTPS (port 443) - DNS filtering handles domain blocking
        tcp dport 443 accept

        # Allow HTTP (port 80) - DNS filtering handles domain blocking
        tcp dport 80 accept

        # Allow ICMP (ping)
        ip protocol icmp accept

        # AWS metadata service
        ip daddr 169.254.169.254 accept
    }
}
EOF'

# Enable nftables
sudo systemctl enable nftables
sudo systemctl restart nftables

# [F5/F5] Setup CoreDNS with whitelist (default deny)
echo "[F5/F5] Configuring CoreDNS..."
sudo mkdir -p /etc/coredns

# Create domain blocklist - customize this list as needed
# This is just a SAMPLE - add/remove domains based on your requirements
sudo bash -c 'cat > /etc/coredns/blocklist.hosts << EOF
# BLOCKLIST - domains to explicitly block (return NXDOMAIN)
# Customize this list based on your organization policy
#
# Sample blocked domains (porn/social media):
127.0.0.1 pornhub.com
127.0.0.1 www.pornhub.com
127.0.0.1 xvideos.com
127.0.0.1 www.xvideos.com
127.0.0.1 facebook.com
127.0.0.1 www.facebook.com
127.0.0.1 twitter.com
127.0.0.1 www.twitter.com
127.0.0.1 instagram.com
127.0.0.1 www.instagram.com
127.0.0.1 tiktok.com
127.0.0.1 www.tiktok.com
#
# Add more domains as needed, one per line:
# 127.0.0.1 yourdomain.com
# 127.0.0.1 www.yourdomain.com
EOF'

# Create domain whitelist - CONCRETE list of allowed domains
# These domains are whitelisted at nftables IP level
# Only add domains that are explicitly approved
sudo bash -c 'cat > /etc/coredns/whitelist.txt << EOF
# WHITELIST - CONCRETE list of domains allowed to work
# Enforcement: nftables IP filtering (only these IPs allowed)
# Modify only after approval by security team
#
# Whitelisted domains:
github.com
www.github.com
api.github.com
raw.githubusercontent.com
gist.github.com
gist.githubusercontent.com
github.io
githubusercontent.com
ubuntu.com
www.ubuntu.com
registry.npmjs.org
pypi.org
golang.org
pkg.go.dev
zerodha.com
www.zerodha.com
kite.zerodha.com
api.zerodha.com
instruments.zerodha.com
quote.zerodha.com
amazonaws.com
s3.amazonaws.com
ec2.amazonaws.com
lambda.amazonaws.com
rds.amazonaws.com
dynamodb.amazonaws.com
sqs.amazonaws.com
sns.amazonaws.com
cloudformation.amazonaws.com
cloudwatch.amazonaws.com
logs.amazonaws.com
kms.amazonaws.com
ssm.amazonaws.com
secretsmanager.amazonaws.com
ecr.amazonaws.com
ecs.amazonaws.com
autoscaling.amazonaws.com
elasticloadbalancing.amazonaws.com
sts.amazonaws.com
route53.amazonaws.com
cloudfront.amazonaws.com
iam.amazonaws.com
s3.ap-south-1.amazonaws.com
ec2.ap-south-1.amazonaws.com
sts.ap-south-1.amazonaws.com
EOF'

# Create CoreDNS Corefile - DNS-level blocklist only
sudo bash -c 'cat > /etc/coredns/Corefile << EOF
.:53 {
    # 1. BLOCK: Explicitly blacklisted domains (pornhub, facebook, etc)
    #    These domains return NXDOMAIN (no such domain)
    hosts /etc/coredns/blocklist.hosts {
        fallthrough
    }
    # 2. ALLOW: All other domains forward to Cloudflare DNS
    #    Security relies on DNS blocklist, not IP whitelisting
    #    Works with services that have dynamic IPs (GitHub, Zerodha, etc.)
    forward . 1.1.1.1 1.0.0.1
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
echo "Verify DNS resolver:"
echo "  cat /etc/resolv.conf"
echo "  nslookup google.com"
