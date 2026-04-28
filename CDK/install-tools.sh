#!/bin/bash
# Install development tools on firewall-test instance
# Sequence: git -> aws-cli -> gh -> docker (with group fix)
# Run as: ./install-tools.sh or bash install-tools.sh

set -e

echo "=== Installing Development Tools ==="

# Update package manager
echo "[1/10] Updating package manager..."
sudo apt-get update

# 0. Install system dependencies and build tools
echo "[2/10] Installing system dependencies..."
sudo apt-get install -y \
    build-essential \
    linux-headers-$(uname -r) \
    nftables \
    curl \
    jq \
    zip \
    unzip \
    git \
    python3-pip \
    python3-dev

# 1. Install AWS CLI v2
echo "[3/10] Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip -o awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip

# 3. Install GitHub CLI
echo "[4/10] Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/trusted.gpg.d/github.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/github.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

# 4. Install Docker
echo "[5/10] Installing Docker..."
sudo apt-get install -y docker.io

# 5. Install docker-compose
echo "[6/10] Installing docker-compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# 6. Fix docker group permissions
echo "[7/10] Fixing docker group permissions..."
sudo usermod -aG docker ubuntu
sudo systemctl enable docker
sudo systemctl start docker

# Apply docker group membership immediately
newgrp docker << EOF
# Verify installations
echo ""
echo "=== Installation Summary ==="
git --version
aws --version
gh --version
docker --version
docker-compose --version
echo ""
echo "✅ All tools installed successfully!"
echo ""
echo "Note: Docker is now ready to use without sudo."
echo ""
echo "If you still get 'permission denied' error:"
echo "  - Run: newgrp docker"
echo "  - Or log out and back in"
EOF

# 7. Clone and install firewall
echo ""
echo "[8/10] Setting up firewall..."
if [ ! -d /home/ubuntu/multipass-firewall ]; then
    cd /home/ubuntu
    git clone https://github.com/forvaidya/multipass-firewall.git
    cd multipass-firewall
    echo "Firewall repository cloned"
else
    cd /home/ubuntu/multipass-firewall
    git pull origin main
    echo "Firewall repository updated"
fi

# Install firewall
echo "Running firewall setup..."
sudo ./scripts/setup.sh --auto

echo ""
echo "=== Firewall Setup Complete ==="
echo "Monitor firewall: tail -f /var/log/falco-firewall/firewall.log"
echo "Check status: sudo systemctl status falco-firewall falco-enforcement"
