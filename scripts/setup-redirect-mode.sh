#!/bin/bash
# Three-Layer Firewall with DNS REDIRECT MODE
# Non-whitelisted domains get redirected to a safe site instead of being blocked
# Usage: sudo ./setup-redirect-mode.sh --whitelist "github.com,ubuntu.com" --redirect-to "github.com"

set -e

WHITELIST_DOMAINS="${1:-github.com,ubuntu.com,registry.npmjs.org,pypi.org}"
WHITELIST_IPS="${2:-140.82.113.4,185.125.190.81,104.16.8.34,151.101.0.223}"
REDIRECT_TO="${3:-github.com}"
ALLOWED_DNS="8.8.8.8 1.1.1.1"

echo "========================================="
echo "Three-Layer Firewall with DNS REDIRECT"
echo "========================================="
echo ""
echo "Layer 1 (CoreDNS): Domain Redirect"
echo "  Whitelist: $WHITELIST_DOMAINS"
echo "  Redirect to: $REDIRECT_TO"
echo ""
echo "Layer 2 (eBPF): DNS Resolver Monitoring"
echo "  Allowed DNS: $ALLOWED_DNS"
echo ""
echo "Layer 3 (nftables): IP Whitelist"
echo "  IPs: $WHITELIST_IPS"
echo ""

# ============================================
# LAYER 1: CoreDNS with REDIRECT Mode
# ============================================

echo "[Layer 1/3] Installing CoreDNS with REDIRECT mode..."

if ! command -v coredns &> /dev/null; then
    COREDNS_VERSION="1.10.1"
    ARCH=$(uname -m | sed 's/aarch64/arm64/')
    cd /tmp
    curl -sL "https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/coredns_${COREDNS_VERSION}_linux_${ARCH}.tgz" | tar xz
    sudo mv coredns /usr/local/bin/
    cd -
fi

# Create CoreDNS configuration with REDIRECT mode
sudo mkdir -p /etc/coredns
sudo bash << 'COREDNS_SETUP'
cat > /etc/coredns/Corefile << 'COREFILE'
.:53 {
    log stdout

    # LAYER 1: Domain Redirect Mode
    # Whitelisted domains resolve normally
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

# Get redirect target IP (resolve it first)
REDIRECT_IP=$(dig +short "$REDIRECT_TO" @8.8.8.8 | tail -1 || echo "140.82.113.4")

sudo bash -c 'cat >> /etc/coredns/Corefile << '"'"'COREFILE'"'"'
    }

    # Non-whitelisted domains → REDIRECT to safe site
    # Any query that didn't match above gets redirected
    rewrite name regex ^.*$ answer '"'"'$REDIRECT_IP'"'"'.

    # Forward whitelisted to public DNS
    forward . 8.8.8.8 1.1.1.1

    # Cache
    cache 30

    # Metrics
    prometheus 127.0.0.1:9253
}
COREFILE'

echo "✓ CoreDNS configured (REDIRECT mode to $REDIRECT_TO)"

# Create CoreDNS service
sudo bash << 'SERVICE'
cat > /etc/systemd/system/coredns.service << 'EOF'
[Unit]
Description=CoreDNS with DNS Redirect (Layer 1)
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

sudo mkdir -p /etc/falco/rules.d/

sudo bash << 'EBPF_RULES'
cat > /etc/falco/rules.d/dns-redirect-monitoring.yaml << 'RULES'
# LAYER 2: eBPF DNS Resolver Monitoring (Redirect Mode)

- rule: DNS Query Monitoring (Redirect Mode)
  desc: Monitor all DNS queries in redirect mode
  condition: >
    outbound and
    fd.stype = "ipv4" and
    fd.l4proto = "udp" and
    fd.dport = 53
  output: >
    DNS Query (Redirect Mode)
    (process=%proc.name pid=%proc.pid)
    (resolver=%fd.dip)
  priority: DEBUG
  tags: [dns, redirect]

- rule: DNS Query via Unauthorized Resolver (Redirect Mode)
  desc: ALERT - Unauthorized DNS resolver in redirect mode
  condition: >
    outbound and
    fd.stype = "ipv4" and
    fd.l4proto = "udp" and
    fd.dport = 53 and
    fd.dip not in (8.8.8.8, 1.1.1.1, 127.0.0.1)
  output: >
    SECURITY ALERT - Unauthorized DNS Resolver Attempt!
    (process=%proc.name pid=%proc.pid user=%user.name)
    (attempted_resolver=%fd.dip)
    (will be blocked by Layer 3 nftables)
  priority: WARNING
  tags: [dns, security, unauthorized]

RULES
EBPF_RULES

echo "✓ eBPF DNS monitoring rules installed"

# ============================================
# LAYER 3: nftables IP Whitelisting
# ============================================

echo "[Layer 3/3] Setting up nftables IP whitelisting..."

sudo apt-get install -y nftables > /dev/null 2>&1

# Generate nftables rules
sudo bash << 'NFTABLES_SETUP'
cat > /etc/nftables.conf << 'NFTABLES'
#!/usr/bin/env nft -f
# LAYER 3: nftables IP Whitelisting (Redirect Mode Backup)

table inet filter {
    chain firewall_out {
        type filter hook output priority filter; policy drop;

        # Layer 3: IP Whitelisting - Backup for redirect mode

        # Allow DNS to whitelisted resolvers
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

        # Reject everything else
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

sudo bash << 'DNS_CONFIG'
cat > /etc/resolv.conf << 'EOF'
# CoreDNS with REDIRECT mode
nameserver 127.0.0.1

# Fallback
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Make immutable
chattr +i /etc/resolv.conf 2>/dev/null || true
DNS_CONFIG

echo "✓ System DNS configured"

# ============================================
# Start Services
# ============================================

echo "[Services] Starting three-layer firewall (redirect mode)..."

sudo systemctl start coredns
sudo systemctl start nftables

sleep 2

# ============================================
# Verification
# ============================================

echo ""
echo "========================================="
echo "✓ Three-Layer Firewall (REDIRECT MODE) Ready!"
echo "========================================="
echo ""

echo "📊 Layers Active:"
echo ""
echo "Layer 1 (CoreDNS): Domain Redirect"
echo "  Status: $(sudo systemctl is-active coredns)"
echo "  Whitelist: $WHITELIST_DOMAINS"
echo "  Non-whitelisted domains → Redirect to $REDIRECT_TO"
echo "  Example: pornhub.com → $REDIRECT_IP (will open $REDIRECT_TO)"
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
echo "🧪 Testing REDIRECT MODE:"
echo "========================================="
echo ""
echo "Test 1: Check what IP blocked domain resolves to"
echo "  nslookup pornhub.com 127.0.0.1"
echo "  Expected: Should return $REDIRECT_IP (points to $REDIRECT_TO)"
echo ""
echo "Test 2: Try accessing blocked domain in browser"
echo "  Open: https://pornhub.com"
echo "  Expected: Browser redirects to https://$REDIRECT_TO"
echo "  (You'll see HTTPS warning due to certificate mismatch, but data flows)"
echo ""
echo "Test 3: Try accessing allowed domain"
echo "  curl https://github.com"
echo "  Expected: Works normally"
echo ""
echo "Test 4: Monitor redirects"
echo "  sudo journalctl -u coredns -f | grep redirect"
echo ""

echo "========================================="
echo "🎯 HOW REDIRECT MODE WORKS:"
echo "========================================="
echo ""
echo "1. User tries: curl https://pornhub.com"
echo "2. Browser queries DNS: What is pornhub.com?"
echo "3. CoreDNS intercepts: \"Not whitelisted, redirect!\""
echo "4. CoreDNS responds: pornhub.com = $REDIRECT_IP"
echo "5. Browser connects to: $REDIRECT_IP (which is $REDIRECT_TO)"
echo "6. User sees: GitHub website instead of pornhub.com!"
echo ""
echo "Result: User gets redirected transparently, can't access bad site"
echo ""
echo "========================================="
echo "✅ REDIRECT MODE ACTIVE!"
echo "========================================="
