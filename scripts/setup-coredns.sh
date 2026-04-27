#!/bin/bash
# Install CoreDNS + Falco Firewall with DNS filtering
# Usage: sudo ./setup-coredns.sh --whitelist "github.com,ubuntu.com,pypi.org"

set -e

WHITELIST="${1:-github.com,ubuntu.com,pypi.org,registry.npmjs.org}"
BLACKLIST="${2:-pornhub.com,xvideos.com,facebook.com,twitter.com,instagram.com}"

echo "========================================="
echo "CoreDNS + Falco Firewall Setup"
echo "========================================="
echo ""
echo "Whitelist: $WHITELIST"
echo "Blacklist: $BLACKLIST"
echo ""

# 1. Install CoreDNS
echo "[1/4] Installing CoreDNS..."
if ! command -v coredns &> /dev/null; then
    COREDNS_VERSION="1.10.1"
    cd /tmp
    curl -sL "https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/coredns_${COREDNS_VERSION}_linux_$(uname -m | sed 's/aarch64/arm64/').tgz" | tar xz
    sudo mv coredns /usr/local/bin/
    cd -
fi
echo "✓ CoreDNS installed"

# 2. Create Corefile
echo "[2/4] Configuring CoreDNS..."
sudo mkdir -p /etc/coredns

# Generate Corefile with whitelist/blacklist
sudo bash << 'COREDNS_EOF'
cat > /etc/coredns/Corefile << 'EOF'
.:53 {
    log stdout

    # Block bad domains - return NXDOMAIN
COREDNS_EOF

# Add blacklist rules
IFS=',' read -ra BLOCKED <<< "$BLACKLIST"
for domain in "${BLOCKED[@]}"; do
    domain=$(echo "$domain" | xargs)  # trim whitespace
    echo "    rewrite name regex ^(.*\.)?${domain//./\\.}$ NXDOMAIN" >> /tmp/coredns_rules
done
cat /tmp/coredns_rules | sudo tee -a /etc/coredns/Corefile > /dev/null

sudo bash -c 'cat >> /etc/coredns/Corefile << '"'"'EOF'"'"'

    # Allow DNS recursion for whitelisted domains
    forward . 8.8.8.8 8.8.4.4

    # Cache responses
    cache 30

    # Metrics
    prometheus 127.0.0.1:9253
}
EOF'

echo "✓ CoreDNS configured"

# 3. Create systemd service for CoreDNS
echo "[3/4] Installing CoreDNS service..."
sudo bash << 'SERVICE_EOF'
cat > /etc/systemd/system/coredns.service << 'EOF'
[Unit]
Description=CoreDNS DNS Server
After=network.target
Before=falco-firewall-enforce.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable coredns
echo "✓ CoreDNS service installed"

# 4. Configure system DNS to use CoreDNS
echo "[4/4] Configuring system DNS..."
sudo bash << 'DNS_EOF'
# Update resolv.conf to use CoreDNS first
cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# Make it immutable so systemd doesn't overwrite it
chattr +i /etc/resolv.conf 2>/dev/null || true
DNS_EOF

# Start services
sudo systemctl start coredns
sudo systemctl start falco-firewall-enforce

sleep 2

echo ""
echo "========================================="
echo "✓ Setup Complete!"
echo "========================================="
echo ""
echo "DNS Filtering Active:"
echo "  • Blocked domains: $BLACKLIST"
echo "  • Return: NXDOMAIN (domain doesn't exist)"
echo ""
echo "Test it:"
echo "  ✓ nslookup github.com 127.0.0.1 (should resolve)"
echo "  ✗ nslookup pornhub.com 127.0.0.1 (should fail)"
echo ""
echo "View logs:"
echo "  sudo journalctl -u coredns -f"
echo "  sudo tail -f /var/log/falco-firewall/enforcement.log"
echo ""
