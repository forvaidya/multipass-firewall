#!/bin/bash
# Install development tools on firewall-test instance
# Sequence: git -> aws-cli -> gh -> docker (with group fix)
# Run as: ./install-tools.sh or bash install-tools.sh

set -e

echo "=== Installing Development Tools ==="

# Update package manager
echo "[1/7] Updating package manager..."
sudo apt-get update

# 0. Install zip utilities
echo "[2/7] Installing zip utilities..."
sudo apt-get install -y zip unzip

# 1. Install Git
echo "[3/7] Installing Git..."
sudo apt-get install -y git

# 2. Install AWS CLI v2
echo "[4/7] Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip

# 3. Install GitHub CLI
echo "[5/7] Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/trusted.gpg.d/github.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/github.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

# 4. Install Docker
echo "[6/7] Installing Docker..."
sudo apt-get install -y docker.io

# 5. Install docker-compose
echo "[7/8] Installing docker-compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# 6. Fix docker group permissions
echo "[8/8] Fixing docker group permissions..."
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
