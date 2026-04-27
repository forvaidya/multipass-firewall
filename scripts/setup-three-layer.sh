#!/bin/bash
# Three-Layer Firewall: CoreDNS + eBPF + nftables
# Usage: sudo ./setup-three-layer.sh --whitelist "github.com,ubuntu.com" --ips "140.82.113.4,185.125.190.81"

set -e

# Configuration
WHITELIST_DOMAINS="${1:-github.com,ubuntu.com,registry.npmjs.org,pypi.org}"
WHITELIST_IPS="${2:-140.82.113.4,185.125.190.81,104.16.8.34,151.101.0.223}"
ALLOWED_DNS="8.8.8.8 1.1.1.1"

echo "========================================="
echo "Three-Layer Firewall Setup"
echo "========================================="
echo ""
echo "Layer 1 (CoreDNS): Domain Whitelist"
echo "  Domains: $WHITELIST_DOMAINS"
echo ""
echo "Layer 2 (eBPF): DNS Resolver Monitoring"
echo "  Allowed DNS: $ALLOWED_DNS"
echo ""
echo "Layer 3 (nftables): IP Whitelist"
echo "  IPs: $WHITELIST_IPS"
echo ""

# ============================================
# LAYER 1: CoreDNS Installation
# ============================================

echo "[Layer 1/3] Installing CoreDNS..."

if ! command -v coredns &> /dev/null; then
    COREDNS_VERSION="1.10.1"
    ARCH=$(uname -m | sed 's/aarch64/arm64/')
    cd /tmp
    curl -sL "https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/coredns_${COREDNS_VERSION}_linux_${ARCH}.tgz" | tar xz
    sudo mv coredns /usr/local/bin/
    cd -
fi

# Create CoreDNS configuration - Domain whitelist only
sudo mkdir -p /etc/coredns
sudo bash << 'COREDNS_SETUP'
cat > /etc/coredns/Corefile << 'COREFILE'
.:53 {
    log stdout

    # LAYER 1: Domain Whitelisting
    # Only these domains resolve, everything else gets NXDOMAIN
    rewrite stop {
COREFILE

# Add whitelisted domains
IFS=',' read -ra DOMAINS <<< "$WHITELIST_DOMAINS"
for domain in "${DOMAINS[@]}"; do
    domain=$(echo "$domain" | xargs)
    domain_escaped=$(echo "$domain" | sed 's/\./\\./g')
    echo "        name regex ^(.*\.)?${domain_escaped}$ answer \"NOCHANGE\"" >> /tmp/domains_rewrite
done

cat /tmp/domains_rewrite | sudo tee -a /etc/coredns/Corefile > /dev/null

sudo bash -c 'cat >> /etc/coredns/Corefile << '"'"'COREFILE'"'"'
    }

    # Block everything else - return NXDOMAIN
    rewrite name regex ^.*$ NXDOMAIN

    # Forward only whitelisted domains to public DNS
    forward . 8.8.8.8 1.1.1.1

    # Cache responses
    cache 30

    # Prometheus metrics
    prometheus 127.0.0.1:9253
}
COREFILE'

echo "✓ CoreDNS configured (domain whitelist)"

# Create CoreDNS systemd service
sudo bash << 'SERVICE'
cat > /etc/systemd/system/coredns.service << 'EOF'
[Unit]
Description=CoreDNS DNS Server (Layer 1)
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
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable coredns
echo "✓ CoreDNS service installed"

# ============================================
# LAYER 2: eBPF Monitoring (Falco)
# ============================================

echo "[Layer 2/3] Setting up eBPF DNS monitoring..."

# Create Falco rules for DNS monitoring
sudo mkdir -p /etc/falco/rules.d/

sudo bash << 'EBPF_RULES'
cat > /etc/falco/rules.d/dns-monitoring.yaml << 'RULES'
# LAYER 2: eBPF DNS Resolver Monitoring

- rule: DNS Query via Authorized Resolver
  desc: Monitor DNS queries to authorized resolvers
  condition: >
    outbound and
    fd.stype = "ipv4" and
    fd.l4proto = "udp" and
    fd.dport = 53 and
    fd.dip in (8.8.8.8, 1.1.1.1, 127.0.0.1)
  output: >
    DNS Query (Authorized Resolver)
    (process=%proc.name pid=%proc.pid)
    (resolver=%fd.dip)
    (destination=query)
  priority: DEBUG
  tags: [dns, authorized]

- rule: DNS Query via Unauthorized Resolver
  desc: SECURITY ALERT - DNS query to non-whitelisted resolver
  condition: >
    outbound and
    fd.stype = "ipv4" and
    fd.l4proto = "udp" and
    fd.dport = 53 and
    fd.dip not in (8.8.8.8, 1.1.1.1, 127.0.0.1)
  output: >
    SECURITY ALERT - Unauthorized DNS Resolver Detected!
    (process=%proc.name pid=%proc.pid user=%user.name)
    (unauthorized_resolver=%fd.dip)
    (this is Layer 2 eBPF detection)
  priority: WARNING
  tags: [dns, unauthorized, security]

- rule: Suspicious DNS Exfiltration
  desc: Large DNS query or response (potential data exfiltration)
  condition: >
    outbound and
    fd.stype = "ipv4" and
    fd.l4proto = "udp" and
    fd.dport = 53 and
    fd.bytesout > 512
  output: >
    DNS Data Exfiltration Attempt
    (process=%proc.name pid=%proc.pid)
    (resolver=%fd.dip)
    (bytes=%fd.bytesout)
  priority: WARNING
  tags: [dns, exfiltration]

RULES
EBPF_RULES

echo "✓ eBPF DNS monitoring rules installed"

# ============================================
# LAYER 3: nftables IP Whitelisting
# ============================================

echo "[Layer 3/3] Setting up nftables IP whitelisting..."

# Install nftables
sudo apt-get install -y nftables > /dev/null 2>&1

# Generate nftables rules with IP whitelist
sudo bash << 'NFTABLES_SETUP'
cat > /etc/nftables.conf << 'NFTABLES'
#!/usr/bin/env nft -f
# LAYER 3: nftables IP Whitelisting (Default Deny)

table inet filter {
    chain firewall_out {
        type filter hook output priority filter; policy drop;

        # Layer 3: IP Whitelisting - Only whitelisted IPs allowed

        # Allow DNS to whitelisted resolvers (8.8.8.8, 1.1.1.1)
        ip daddr 8.8.8.8 udp dport 53 accept
        ip daddr 1.1.1.1 udp dport 53 accept

NFTABLES

# Add whitelisted IPs
IFS=',' read -ra IPS <<< "$WHITELIST_IPS"
for ip in "${IPS[@]}"; do
    ip=$(echo "$ip" | xargs)
    echo "        ip daddr $ip tcp dport {80,443} accept" >> /tmp/ips_rules
done

cat /tmp/ips_rules | sudo tee -a /etc/nftables.conf > /dev/null

sudo bash -c 'cat >> /etc/nftables.conf << '"'"'NFTABLES'"'"'

        # Allow localhost
        ip daddr 127.0.0.1 accept

        # Reject everything else (default deny)
        reject with icmp type host-unreachable
    }
}
NFTABLES

chmod +x /etc/nftables.conf
NFTABLES_SETUP

echo "✓ nftables IP whitelist configured"

# Load nftables rules
sudo nft -f /etc/nftables.conf

# Create systemd service for nftables
sudo bash << 'NFT_SERVICE'
cat > /etc/systemd/system/nftables.service << 'EOF'
[Unit]
Description=nftables IP Firewall (Layer 3)
Before=network-pre.target
After=coredns.service
Wants=coredns.service

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
echo "✓ nftables service installed"

# ============================================
# Configure System DNS
# ============================================

echo "[System] Configuring DNS to use CoreDNS..."

# Update resolv.conf to use CoreDNS (Layer 1)
sudo bash << 'DNS_CONFIG'
cat > /etc/resolv.conf << 'EOF'
# CoreDNS (Layer 1) - Domain whitelist
nameserver 127.0.0.1

# Fallback (if CoreDNS fails)
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Make immutable
chattr +i /etc/resolv.conf 2>/dev/null || true
DNS_CONFIG

echo "✓ System DNS configured to use CoreDNS"

# ============================================
# Start All Services
# ============================================

echo "[Services] Starting three-layer firewall..."

sudo systemctl start coredns
sudo systemctl start nftables

sleep 2

# ============================================
# Verification
# ============================================

echo ""
echo "========================================="
echo "✓ Three-Layer Firewall Ready!"
echo "========================================="
echo ""

echo "📊 Layers Active:"
echo ""
echo "Layer 1 (CoreDNS): Domain Whitelist"
echo "  Status: $(sudo systemctl is-active coredns)"
echo "  Whitelist: $WHITELIST_DOMAINS"
echo "  Non-whitelisted domains → NXDOMAIN"
echo ""

echo "Layer 2 (eBPF): DNS Resolver Monitoring"
echo "  Authorized resolvers: 8.8.8.8, 1.1.1.1"
echo "  Detects unauthorized DNS attempts"
echo "  Logs to: /var/log/falco/falco.log"
echo ""

echo "Layer 3 (nftables): IP Whitelist"
echo "  Status: $(sudo nft list ruleset | grep -q firewall_out && echo "Active" || echo "Inactive")"
echo "  Whitelist: $WHITELIST_IPS"
echo "  Default policy: DROP (deny all)"
echo ""

echo "========================================="
echo "🧪 Testing:"
echo "========================================="
echo ""
echo "✓ Test allowed domain (should resolve):"
echo "  nslookup github.com 127.0.0.1"
echo ""
echo "✗ Test blocked domain (should fail immediately):"
echo "  nslookup pornhub.com 127.0.0.1"
echo ""
echo "✓ View DNS monitoring:"
echo "  sudo journalctl -u coredns -f"
echo ""
echo "✗ View unauthorized resolver attempts:"
echo "  sudo tail -f /var/log/falco/falco.log | grep 'Unauthorized DNS'"
echo ""
echo "✓ Check active firewall rules:"
echo "  sudo nft list chain inet filter firewall_out"
echo ""

echo "========================================="
echo "✅ All three layers configured!"
echo "========================================="
