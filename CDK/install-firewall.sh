#!/bin/bash
# Install Falco Firewall on firewall-test instance
# Run as: ./install-firewall.sh or bash install-firewall.sh

set -e

echo "=== Installing Falco Firewall ==="

# Clone firewall repo if not exists
echo "[F1/F3] Cloning firewall repository..."
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

# Clean up problematic apt sources
echo "[F2/F3] Cleaning up apt sources..."
sudo rm -f /etc/apt/sources.list.d/falcosecurity.list 2>/dev/null || true
sudo apt-get update

# Run firewall setup
echo "[F3/F3] Running firewall setup..."
sudo ./scripts/setup.sh --auto

echo ""
echo "=== Firewall Installation Complete ==="
echo "✅ Falco Firewall installed successfully!"
echo ""
echo "Monitor firewall:"
echo "  tail -f /var/log/falco-firewall/firewall.log"
echo ""
echo "Check status:"
echo "  sudo systemctl status falco-firewall falco-enforcement"
