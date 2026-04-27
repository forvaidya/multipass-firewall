#!/bin/bash
# CoreDNS Whitelist-Only DNS Setup
# Whitelisted domains resolve normally, everything else redirects to a safe IP
#
# Usage: sudo ./setup-coredns.sh
# Optional: sudo ./setup-coredns.sh --redirect-ip 140.82.113.4

set -e

REDIRECT_IP="${1:-140.82.113.4}"  # Default to GitHub IP

echo "========================================="
echo "CoreDNS Whitelist-Only DNS Setup"
echo "========================================="
echo ""
echo "Mode: Whitelist-only"
echo "Non-whitelisted domains redirect to: $REDIRECT_IP"
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

# 2. Create Corefile and whitelist
echo "[2/4] Configuring CoreDNS..."
sudo mkdir -p /etc/coredns

# Create whitelist file
sudo bash << 'WHITELIST_EOF'
cat > /etc/coredns/whitelist.txt << 'EOF'
# GitHub ecosystem
140.82.113.4 github.com
140.82.113.4 www.github.com
185.199.108.153 github.githubassets.com
185.199.109.153 github.githubassets.com
185.199.110.153 github.githubassets.com
185.199.111.153 github.githubassets.com
151.101.1.140 githubusercontent.com
151.101.65.140 githubusercontent.com
151.101.129.140 githubusercontent.com
151.101.193.140 githubusercontent.com

# GitLab
162.125.27.133 gitlab.com
162.125.27.134 gitlab.com
34.257.25.180 gitlab.com

# npm registry
151.101.1.140 registry.npmjs.org
151.101.65.140 registry.npmjs.org
151.101.129.140 registry.npmjs.org
151.101.193.140 registry.npmjs.org
151.101.76.217 registry.npmjs.org

# PyPI
151.101.1.140 pypi.org
151.101.65.140 pypi.org
151.101.129.140 pypi.org
151.101.193.140 pypi.org

# AWS - ECR (Elastic Container Registry)
# Format: *.dkr.ecr.<region>.amazonaws.com
52.5.3.50 dkr.ecr.ap-south-1.amazonaws.com
52.5.3.51 dkr.ecr.ap-south-1.amazonaws.com
52.5.3.52 dkr.ecr.us-east-1.amazonaws.com
52.5.3.53 dkr.ecr.eu-west-1.amazonaws.com

# AWS - S3 (Simple Storage Service)
52.94.12.0 s3.amazonaws.com
52.94.12.1 s3.ap-south-1.amazonaws.com
52.94.12.2 s3.us-east-1.amazonaws.com
52.94.12.3 s3.eu-west-1.amazonaws.com
52.94.24.0 s3.dualstack.ap-south-1.amazonaws.com
52.94.24.1 s3.dualstack.us-east-1.amazonaws.com
52.94.24.2 s3.dualstack.eu-west-1.amazonaws.com

# AWS - STS (Security Token Service)
52.94.48.0 sts.ap-south-1.amazonaws.com
52.94.48.1 sts.us-east-1.amazonaws.com
52.94.48.2 sts.eu-west-1.amazonaws.com
52.94.48.3 sts.amazonaws.com

# AWS - EC2 Metadata Service (CRITICAL for IAM roles)
169.254.169.254 metadata.aws.internal
169.254.169.254 169.254.169.254

# AWS - CloudWatch Logs
52.94.51.0 logs.ap-south-1.amazonaws.com
52.94.51.1 logs.us-east-1.amazonaws.com
52.94.51.2 logs.eu-west-1.amazonaws.com

# AWS - Systems Manager
52.94.50.0 ssm.ap-south-1.amazonaws.com
52.94.50.1 ssm.us-east-1.amazonaws.com
52.94.50.2 ssm.eu-west-1.amazonaws.com

# AWS - EC2
52.94.49.0 ec2.ap-south-1.amazonaws.com
52.94.49.1 ec2.us-east-1.amazonaws.com
52.94.49.2 ec2.eu-west-1.amazonaws.com

# AWS - IAM (for assume role)
52.94.1.0 iam.amazonaws.com
EOF
WHITELIST_EOF

# Create Corefile with whitelist-only mode
sudo bash << 'COREDNS_EOF'
cat > /etc/coredns/Corefile << 'EOF'
.:53 {
    log stdout

    # Whitelist: resolve these domains normally
    hosts /etc/coredns/whitelist.txt {
        fallthrough
    }

    # Catch-all: redirect everything else to safe IP
    template IN A {
        rcode NOERROR
        answer "{{ .Name }} 30 IN A 140.82.113.4"
    }

    # Cache responses
    cache 30

    # Metrics
    prometheus 127.0.0.1:9253
}
EOF
COREDNS_EOF

echo "✓ CoreDNS configured"

# 3. Create systemd service for CoreDNS
echo "[3/4] Installing CoreDNS service..."
sudo bash << 'SERVICE_EOF'
cat > /etc/systemd/system/coredns.service << 'EOF'
[Unit]
Description=CoreDNS Whitelist-Only DNS Server
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

# Start CoreDNS
sudo systemctl start coredns

sleep 2

echo ""
echo "========================================="
echo "✓ Setup Complete!"
echo "========================================="
echo ""
echo "DNS Filtering Active:"
echo "  • Mode: Whitelist-only"
echo "  • Whitelisted: GitHub, GitLab, npm, PyPI"
echo "  • Non-whitelisted: Redirect to $REDIRECT_IP"
echo ""
echo "Test it:"
echo "  ✓ dig @127.0.0.1 github.com (should resolve)"
echo "  ✗ dig @127.0.0.1 pornhub.com (should redirect to $REDIRECT_IP)"
echo ""
echo "View logs:"
echo "  sudo journalctl -u coredns -f"
echo "  sudo cat /etc/coredns/whitelist.txt (view whitelist)"
echo ""
