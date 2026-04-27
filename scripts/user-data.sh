#!/bin/bash
# EC2 User Data Script for Falco Firewall
# Fully automated - firewall ready on first boot
#
# Usage (in CloudFormation/Terraform):
#   UserData: |
#     #!/bin/bash
#     export WHITELIST_DOMAINS="api.example.com,registry.npmjs.org"
#     export WHITELIST_IPS="10.0.1.5,192.168.1.10"
#     curl -sSL https://raw.githubusercontent.com/your-org/multipass-firewall/main/scripts/user-data.sh | bash

set -e

# Configuration (can be set via environment variables)
WHITELIST_DOMAINS="${WHITELIST_DOMAINS:-}"
WHITELIST_IPS="${WHITELIST_IPS:-}"
GITHUB_REPO="${GITHUB_REPO:-https://github.com/your-org/multipass-firewall.git}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

echo "Starting Falco Firewall setup..."

# Update system
apt-get update
apt-get upgrade -y

# Install git first
apt-get install -y git curl

# Clone repository
cd /tmp
git clone --branch "$GITHUB_BRANCH" "$GITHUB_REPO" multipass-firewall
cd multipass-firewall

# Run setup with whitelist
echo "Installing firewall with whitelist..."
if [ -n "$WHITELIST_DOMAINS" ] || [ -n "$WHITELIST_IPS" ]; then
    sudo ./scripts/setup.sh \
        ${WHITELIST_DOMAINS:+--domains "$WHITELIST_DOMAINS"} \
        ${WHITELIST_IPS:+--ips "$WHITELIST_IPS"} \
        --auto
else
    sudo ./scripts/setup.sh --auto
fi

# Verify installation
echo "Verifying installation..."
systemctl status falco-firewall-enforce

# Show status
echo ""
echo "========================================="
echo "✓ Falco Firewall Ready!"
echo "========================================="
echo ""
echo "Current rules:"
nft list chain inet filter firewall_out | head -20

# Log completion
echo "User data script completed at $(date)" >> /var/log/user-data.log
