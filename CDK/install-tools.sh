#!/bin/bash
# Install development tools on firewall-test instance
# Run as: ./install-tools.sh or bash install-tools.sh

set -e

echo "=== Installing Development Tools ==="

# Update package manager
echo "[1/5] Updating package manager..."
sudo apt-get update

# Install Git
echo "[2/5] Installing Git..."
sudo apt-get install -y git

# Install Docker
echo "[3/5] Installing Docker..."
sudo apt-get install -y docker.io
sudo usermod -aG docker ubuntu
sudo systemctl enable docker
sudo systemctl start docker
echo "Docker group membership updated - you may need to log out and back in"

# Install GitHub CLI
echo "[4/5] Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/trusted.gpg.d/github.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/github.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

# Install docker-compose
echo "[5/5] Installing docker-compose..."
sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Install AWS CLI v2
echo "[6/6] Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip

# Verify installations
echo ""
echo "=== Installation Summary ==="
git --version
gh --version
docker --version
docker-compose --version
aws --version
echo ""
echo "✅ All tools installed successfully!"
echo ""
echo "Note: Docker group membership has been updated."
echo "Run 'newgrp docker' or log out and back in to use docker without sudo."
