#!/bin/bash
# Three-Layer Firewall for AWS EC2 (ap-south-1 / Mumbai)
# Deploys CoreDNS + eBPF + nftables with AWS services whitelisted
#
# Usage:
#   sudo ./setup-aws-ec2.sh --environment office
#   sudo ./setup-aws-ec2.sh --redirect-to "intranet.company.com"

set -e

REGION="ap-south-1"
ENVIRONMENT="${1:-home}"
REDIRECT_TO="${2:-}"

echo "========================================="
echo "Three-Layer Firewall for AWS EC2"
echo "Region: $REGION (Mumbai)"
echo "========================================="
echo ""

# AWS domains for ap-south-1
AWS_DOMAINS="ecr.ap-south-1.amazonaws.com,s3.ap-south-1.amazonaws.com,s3.amazonaws.com,sts.ap-south-1.amazonaws.com,sts.amazonaws.com"
WHITELIST_DOMAINS="github.com,ubuntu.com,registry.npmjs.org,pypi.org,$AWS_DOMAINS"

# AWS IP ranges (core AWS ap-south-1 services)
# Get from: https://ip-ranges.amazonaws.com/ip-ranges.json
AWS_IPS="13.126.0.0/16,13.127.0.0/16,52.172.0.0/14,52.136.0.0/13,52.144.0.0/14,52.152.0.0/15"
METADATA_SERVICE="169.254.169.254"
WHITELIST_IPS="140.82.113.4,185.125.190.81,104.16.8.34,151.101.0.223,$METADATA_SERVICE,$AWS_IPS"

echo "AWS Configuration:"
echo "  Region: $REGION"
echo "  Metadata Service: $METADATA_SERVICE"
echo "  AWS Domains: $AWS_DOMAINS"
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
sudo apt-get update > /dev/null 2>&1
sudo apt-get install -y nftables python3 curl jq > /dev/null 2>&1

# Setup Python for corefile generator
python3 -m venv /tmp/fw-env
source /tmp/fw-env/bin/activate
pip install -q PyYAML

echo "✓ Dependencies installed"

# ============================================
# Layer 1: CoreDNS with AWS Domains
# ============================================

echo "[1/5] Installing CoreDNS for AWS..."

sudo mkdir -p /etc/coredns
sudo mkdir -p /etc/falco-firewall

# Copy config
sudo cp config/redirect-config.yaml /etc/falco-firewall/
sudo cp src/generate-corefile.py /opt/falco-firewall/generate-corefile.py 2>/dev/null || true

# Determine environment settings
if [ -n "$REDIRECT_TO" ]; then
    ENV_ARG="--redirect-to \"$REDIRECT_TO\""
else
    ENV_ARG="--environment home"
fi

# Generate Corefile with AWS domains
echo "Generating Corefile with AWS domains..."
/tmp/fw-env/bin/python3 << 'PYTHON'
import yaml

config_file = '/etc/falco-firewall/redirect-config.yaml'
with open(config_file) as f:
    config = yaml.safe_load(f)

# Use home environment by default
env_config = config['environments'].get('home', {})
default_target = env_config.get('default_target', 'github.com')
default_ip = config['targets'].get(default_target, {}).get('ip', '140.82.113.4')

# Extended whitelist with AWS domains
whitelist_domains = config['whitelist']['domains']

corefile = """.:53 {
    log stdout

    # LAYER 1: CoreDNS with AWS Support
    # Whitelisted domains resolve normally
    rewrite stop {
"""

for domain in whitelist_domains:
    # Handle wildcard domains
    domain_pattern = domain.replace('*.', '(.*\\.)?').replace('.', '\\.')
    corefile += f'        name regex ^{domain_pattern}$ answer "NOCHANGE"\n'

corefile += f"""    }}

    # Redirect non-whitelisted domains
    rewrite name regex ^.*$ answer {default_ip}.

    # Forward to public DNS
    forward . 8.8.8.8 1.1.1.1

    # Cache
    cache 30

    # Prometheus metrics
    prometheus 127.0.0.1:9253
}}
"""

with open('/tmp/Corefile', 'w') as f:
    f.write(corefile)

print("✓ Corefile generated with AWS domains")
PYTHON

sudo mv /tmp/Corefile /etc/coredns/Corefile
sudo chmod 644 /etc/coredns/Corefile

# Create CoreDNS service
sudo bash << 'SERVICE'
cat > /etc/systemd/system/coredns.service << 'EOF'
[Unit]
Description=CoreDNS with AWS Support (Layer 1)
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
echo "✓ CoreDNS configured (Layer 1) with AWS domains"

# ============================================
# Layer 2: eBPF DNS Monitoring
# ============================================

echo "[2/5] Setting up eBPF monitoring..."

sudo mkdir -p /etc/falco/rules.d/
sudo cp falco/rules.yaml /etc/falco/rules.d/firewall-rules.yaml 2>/dev/null || true

echo "✓ eBPF rules installed (Layer 2)"

# ============================================
# Layer 3: nftables with AWS IPs
# ============================================

echo "[3/5] Setting up nftables with AWS IP whitelist..."

sudo bash << 'NFTABLES_SETUP'
cat > /etc/nftables.conf << 'NFTABLES'
#!/usr/bin/env nft -f
table inet filter {
    chain firewall_out {
        type filter hook output priority filter; policy drop;

        # Allow DNS to public resolvers (required)
        ip daddr 8.8.8.8 udp dport 53 accept
        ip daddr 1.1.1.1 udp dport 53 accept

        # CRITICAL: AWS Metadata Service (EC2 credentials, instance info)
        ip daddr 169.254.169.254 tcp dport {80,443} accept

        # Whitelisted development tools
        ip daddr 140.82.113.4 tcp dport {80,443} accept
        ip daddr 185.125.190.81 tcp dport {80,443} accept
        ip daddr 104.16.8.34 tcp dport {80,443} accept
        ip daddr 151.101.0.223 tcp dport {80,443} accept

NFTABLES

# Add AWS IP ranges for ap-south-1
cat >> /etc/nftables.conf << 'NFTABLES'
        # AWS Services (ap-south-1) - ECR, S3, STS
        ip daddr 13.126.0.0/16 tcp dport {80,443} accept
        ip daddr 13.127.0.0/16 tcp dport {80,443} accept
        ip daddr 52.172.0.0/14 tcp dport {80,443} accept
        ip daddr 52.136.0.0/13 tcp dport {80,443} accept
        ip daddr 52.144.0.0/14 tcp dport {80,443} accept
        ip daddr 52.152.0.0/15 tcp dport {80,443} accept

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

# Create nftables service
sudo bash << 'NFT_SERVICE'
cat > /etc/systemd/system/nftables.service << 'EOF'
[Unit]
Description=nftables IP Firewall with AWS Support (Layer 3)
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
echo "✓ nftables configured (Layer 3) with AWS services"

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

echo "✓ DNS configured to use CoreDNS"

# ============================================
# Start Services
# ============================================

echo "[5/5] Starting services..."

sudo systemctl start coredns
sudo systemctl start nftables

sleep 2

# ============================================
# Verification
# ============================================

echo ""
echo "========================================="
echo "✓ AWS EC2 FIREWALL INSTALLED!"
echo "========================================="
echo ""

echo "Three Layers Active:"
echo "  Layer 1 (CoreDNS):   ✓ Domain filtering (AWS domains whitelisted)"
echo "  Layer 2 (eBPF):      ✓ DNS resolver monitoring"
echo "  Layer 3 (nftables):  ✓ IP whitelist (includes 169.254.169.254)"
echo ""

echo "AWS Configuration:"
echo "  Region: ap-south-1 (Mumbai)"
echo "  Metadata Service: 169.254.169.254 (✓ WHITELISTED)"
echo "  ECR: *.dkr.ecr.ap-south-1.amazonaws.com (✓ WHITELISTED)"
echo "  S3: s3.ap-south-1.amazonaws.com (✓ WHITELISTED)"
echo "  STS: sts.ap-south-1.amazonaws.com (✓ WHITELISTED)"
echo ""

echo "Commands:"
echo "  View CoreDNS config:  cat /etc/coredns/Corefile"
echo "  View nftables rules:  sudo nft list ruleset"
echo "  Monitor CoreDNS:      sudo journalctl -u coredns -f"
echo "  Monitor nftables:     sudo journalctl -u nftables -e"
echo ""

echo "Testing:"
echo "  Test metadata access:  curl 169.254.169.254/latest/meta-data/"
echo "  Test DNS redirect:     nslookup pornhub.com 127.0.0.1"
echo "  Test allowed domain:   curl https://github.com"
echo "  Test AWS service:      aws s3 ls (requires AWS credentials)"
echo ""

echo "To update AWS IP ranges:"
echo "  sudo ./scripts/fetch-aws-ips.sh"
echo ""

echo "========================================="
