#!/bin/bash
# Three-Layer Firewall with CONFIGURABLE DNS Redirect
# Redirect target can be: github.com, intranet.company.com, etc.
#
# Usage:
#   sudo ./setup-configurable-redirect.sh --environment office
#   sudo ./setup-configurable-redirect.sh --redirect-to "intranet.company.com"
#   sudo ./setup-configurable-redirect.sh --redirect-to "192.168.1.50"

set -e

# Parse arguments
ENVIRONMENT=""
REDIRECT_TO=""
WHITELIST_DOMAINS="github.com,ubuntu.com,registry.npmjs.org,pypi.org"
WHITELIST_IPS="140.82.113.4,185.125.190.81,104.16.8.34,151.101.0.223"

while [[ $# -gt 0 ]]; do
    case $1 in
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --redirect-to)
            REDIRECT_TO="$2"
            shift 2
            ;;
        --whitelist)
            WHITELIST_DOMAINS="$2"
            shift 2
            ;;
        --ips)
            WHITELIST_IPS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--environment office|school|home] [--redirect-to target.com] [--whitelist domains] [--ips ips]"
            exit 1
            ;;
    esac
done

echo "========================================="
echo "Three-Layer Firewall"
echo "CONFIGURABLE DNS Redirect Mode"
echo "========================================="
echo ""

if [ -n "$ENVIRONMENT" ]; then
    echo "Environment: $ENVIRONMENT"
    echo "Using environment-specific settings"
elif [ -n "$REDIRECT_TO" ]; then
    echo "Redirect target: $REDIRECT_TO"
else
    ENVIRONMENT="home"
    REDIRECT_TO="github.com"
    echo "No environment specified, using default: home → github.com"
fi

echo ""

# ============================================
# Install Dependencies
# ============================================

echo "[0/5] Installing dependencies..."
if ! command -v coredns &> /dev/null; then
    COREDNS_VERSION="1.10.1"
    ARCH=$(uname -m | sed 's/aarch64/arm64/')
    cd /tmp
    curl -sL "https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/coredns_${COREDNS_VERSION}_linux_${ARCH}.tgz" | tar xz
    sudo mv coredns /usr/local/bin/
    cd -
fi
sudo apt-get install -y nftables python3-venv > /dev/null 2>&1

# Setup Python for corefile generator
python3 -m venv /tmp/fw-env
source /tmp/fw-env/bin/activate
pip install -q PyYAML

echo "✓ Dependencies installed"

# ============================================
# Layer 1: CoreDNS with Config-Based Redirect
# ============================================

echo "[1/5] Installing CoreDNS..."

sudo mkdir -p /etc/coredns
sudo mkdir -p /etc/falco-firewall

# Copy redirect config to system
sudo cp config/redirect-config.yaml /etc/falco-firewall/
sudo cp src/generate-corefile.py /opt/falco-firewall/generate-corefile.py 2>/dev/null || \
    sudo cp src/generate-corefile.py /usr/local/bin/generate-corefile.py

# Generate Corefile from config
if [ -n "$ENVIRONMENT" ]; then
    echo "Generating Corefile for environment: $ENVIRONMENT"
    /tmp/fw-env/bin/python3 /etc/falco-firewall/../src/generate-corefile.py \
        --config /etc/falco-firewall/redirect-config.yaml \
        --environment "$ENVIRONMENT" \
        --output /tmp/Corefile 2>/dev/null || \
    python3 << 'PYTHON'
import yaml

config_file = '/etc/falco-firewall/redirect-config.yaml'
with open(config_file) as f:
    config = yaml.safe_load(f)

env_config = config['environments'].get(os.environ.get('ENVIRONMENT', 'home'), {})
default_target = env_config.get('default_target', 'github.com')
default_ip = config['targets'].get(default_target, {}).get('ip', '140.82.113.4')

corefile = f""".:53 {{
    log stdout
    rewrite stop {{
"""

for domain in config['whitelist']['domains']:
    corefile += f'        name regex ^(.*\\.)?{domain.replace(".", "\\\.")}$ answer "NOCHANGE"\n'

corefile += f"""    }}
    rewrite name regex ^.*$ answer {default_ip}.
    forward . 8.8.8.8 1.1.1.1
    cache 30
    prometheus 127.0.0.1:9253
}}
"""

with open('/etc/coredns/Corefile', 'w') as f:
    f.write(corefile)
PYTHON
elif [ -n "$REDIRECT_TO" ]; then
    echo "Generating Corefile with redirect: $REDIRECT_TO"
    # Resolve IP for redirect target
    REDIRECT_IP=$(dig +short "$REDIRECT_TO" @8.8.8.8 2>/dev/null | tail -1 || echo "140.82.113.4")

    sudo bash << COREFILE_SETUP
cat > /etc/coredns/Corefile << 'COREFILE'
.:53 {
    log stdout

    # Whitelisted domains
    rewrite stop {
COREFILE_SETUP

    IFS=',' read -ra DOMAINS <<< "$WHITELIST_DOMAINS"
    for domain in "${DOMAINS[@]}"; do
        domain=$(echo "$domain" | xargs)
        domain_escaped=$(echo "$domain" | sed 's/\./\\./g')
        echo "        name regex ^(.*\.)?${domain_escaped}$ answer \"NOCHANGE\"" | sudo tee -a /etc/coredns/Corefile > /dev/null
    done

    sudo bash << COREFILE_SETUP2
cat >> /etc/coredns/Corefile << 'COREFILE'
    }

    # Redirect non-whitelisted to: $REDIRECT_TO ($REDIRECT_IP)
    rewrite name regex ^.*$ answer $REDIRECT_IP.

    forward . 8.8.8.8 1.1.1.1
    cache 30
    prometheus 127.0.0.1:9253
}
COREFILE
COREFILE_SETUP2
fi

# Create CoreDNS service
sudo bash << 'SERVICE'
cat > /etc/systemd/system/coredns.service << 'EOF'
[Unit]
Description=CoreDNS with Configurable Redirect (Layer 1)
After=network.target

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
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable coredns
echo "✓ CoreDNS configured (Layer 1)"

# ============================================
# Layer 2: eBPF (Falco)
# ============================================

echo "[2/5] Setting up eBPF monitoring..."

sudo mkdir -p /etc/falco/rules.d/
sudo cp falco/rules.yaml /etc/falco/rules.d/firewall-rules.yaml 2>/dev/null || true

echo "✓ eBPF rules installed (Layer 2)"

# ============================================
# Layer 3: nftables
# ============================================

echo "[3/5] Setting up nftables..."

sudo bash << 'NFTABLES_SETUP'
cat > /etc/nftables.conf << 'NFTABLES'
#!/usr/bin/env nft -f
table inet filter {
    chain firewall_out {
        type filter hook output priority filter; policy drop;

        # Allow DNS to whitelisted resolvers
        ip daddr 8.8.8.8 udp dport 53 accept
        ip daddr 1.1.1.1 udp dport 53 accept

NFTABLES

IFS=',' read -ra IPS <<< "$WHITELIST_IPS"
for ip in "${IPS[@]}"; do
    ip=$(echo "$ip" | xargs)
    echo "        ip daddr $ip tcp dport {80,443} accept" >> /etc/nftables.conf
done

sudo bash -c 'cat >> /etc/nftables.conf << '"'"'NFTABLES'"'"'

        # Allow localhost
        ip daddr 127.0.0.1 accept

        # Reject everything else
        reject with icmp type host-unreachable
    }
}
NFTABLES

chmod +x /etc/nftables.conf
NFTABLES_SETUP

sudo nft -f /etc/nftables.conf

sudo bash << 'NFT_SERVICE'
cat > /etc/systemd/system/nftables.service << 'EOF'
[Unit]
Description=nftables IP Firewall (Layer 3)
Before=network-pre.target
After=coredns.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables.conf
ExecStop=/usr/sbin/nft flush ruleset
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
NFT_SERVICE

sudo systemctl daemon-reload
sudo systemctl enable nftables
echo "✓ nftables configured (Layer 3)"

# ============================================
# Configure System DNS
# ============================================

echo "[4/5] Configuring system DNS..."

sudo bash << 'DNS_CONFIG'
cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true
DNS_CONFIG

echo "✓ DNS configured"

# ============================================
# Start Services
# ============================================

echo "[5/5] Starting services..."

sudo systemctl start coredns
sudo systemctl start nftables

sleep 2

# ============================================
# Summary
# ============================================

echo ""
echo "========================================="
echo "✓ CONFIGURABLE FIREWALL INSTALLED!"
echo "========================================="
echo ""

if [ -n "$ENVIRONMENT" ]; then
    echo "Environment: $ENVIRONMENT"
elif [ -n "$REDIRECT_TO" ]; then
    echo "Redirect target: $REDIRECT_TO"
fi

echo ""
echo "Three Layers Active:"
echo "  Layer 1 (CoreDNS):   ✓ Domain redirect"
echo "  Layer 2 (eBPF):      ✓ DNS monitoring"
echo "  Layer 3 (nftables):  ✓ IP whitelist"
echo ""

echo "Configuration Location:"
echo "  /etc/falco-firewall/redirect-config.yaml"
echo ""

echo "Commands:"
echo "  View config:     cat /etc/falco-firewall/redirect-config.yaml"
echo "  Edit config:     sudo vim /etc/falco-firewall/redirect-config.yaml"
echo "  Regenerate:      sudo /opt/falco-firewall/generate-corefile.py --environment office"
echo "  Restart CoreDNS: sudo systemctl restart coredns"
echo "  View logs:       sudo journalctl -u coredns -f"
echo ""

echo "Test:"
echo "  nslookup pornhub.com 127.0.0.1"
echo "  (should return redirect target IP)"
echo ""

echo "========================================="
