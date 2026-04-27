# CoreDNS-Based DNS Filtering Firewall

## Overview

Use CoreDNS as a local DNS server to filter domains **before** they're resolved. This is more effective than IP-level blocking.

```
Application → CoreDNS (127.0.0.1:53) → Filter bad domains
                                      → Return NXDOMAIN for blocked
                                      → Resolve allowed domains
                                      → nftables (IP-level backup)
```

## Installation

### Step 1: Install CoreDNS

```bash
sudo apt-get update
sudo apt-get install -y coredns

# Or download latest binary
curl -L https://github.com/coredns/coredns/releases/download/v1.10.1/coredns_1.10.1_linux_amd64.tgz | tar xz
sudo mv coredns /usr/local/bin/
```

### Step 2: Create Corefile Configuration

Save as `/etc/coredns/Corefile`:

```
.:53 {
    # Log all queries
    log

    # Block bad domains - return NXDOMAIN
    rewrite name regex ^(pornhub|xvideos|redtube|brazzers)\..*$ NXDOMAIN

    # Whitelist approach: Only resolve these domains
    # rewrite name regex ^(github|ubuntu|pypi|registry\.npm)\..*$ {
    #     answer "github.com 3600 IN A 140.82.113.4"
    # }

    # Forward to public DNS for everything else
    forward . 8.8.8.8 8.8.4.4

    # Cache responses
    cache 30

    # Enable prometheus metrics (optional)
    prometheus 127.0.0.1:9253
}
```

### Step 3: Configure System to Use CoreDNS

#### Option A: Update /etc/resolv.conf

```bash
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF'

# Make it persistent
sudo chattr +i /etc/resolv.conf
```

#### Option B: Update systemd-resolved

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d/
sudo bash -c 'cat > /etc/systemd/resolved.conf.d/coredns.conf << EOF
[Resolve]
DNS=127.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
EOF'

sudo systemctl restart systemd-resolved
```

### Step 4: Start CoreDNS

```bash
# As systemd service
sudo bash -c 'cat > /etc/systemd/system/coredns.service << EOF
[Unit]
Description=CoreDNS
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF'

sudo systemctl daemon-reload
sudo systemctl enable coredns
sudo systemctl start coredns
```

## Testing

### Test 1: Blocked Domain (pornhub.com)

```bash
$ nslookup pornhub.com 127.0.0.1
Server:         127.0.0.1
Address:        127.0.0.1#53

** server can't find pornhub.com: NXDOMAIN
```

✓ **Success** - Domain blocked at DNS level!

### Test 2: Allowed Domain (github.com)

```bash
$ nslookup github.com 127.0.0.1
Server:         127.0.0.1
Address:        127.0.0.1#53

Name:   github.com
Address: 140.82.113.4
```

✓ **Success** - Domain resolved!

### Test 3: Curl to Blocked Domain

```bash
$ curl https://pornhub.com
curl: (6) Could not resolve host: pornhub.com
```

✓ **Perfect** - Curl fails at DNS resolution, doesn't even try to connect!

## Configuration Examples

### Example 1: Block Multiple Categories

```coredns
.:53 {
    log

    # Block adult sites
    rewrite name regex ^(pornhub|xvideos|redtube|xnxx|brazzers)\..*$ NXDOMAIN

    # Block social media
    rewrite name regex ^(facebook|twitter|instagram|tiktok)\..*$ NXDOMAIN

    # Block gambling
    rewrite name regex ^(bet365|pokerstars|draft[kk]ings)\..*$ NXDOMAIN

    forward . 8.8.8.8 8.8.4.4
    cache 30
}
```

### Example 2: Whitelist Only (Most Restrictive)

```coredns
.:53 {
    log

    # Only these domains can be resolved
    rewrite name exact github.com A 140.82.113.4
    rewrite name exact ubuntu.com A 185.125.190.81
    rewrite name exact registry.npmjs.org A 104.16.8.34

    # Everything else: NXDOMAIN
    rewrite name regex ^.*$ NXDOMAIN

    cache 30
}
```

### Example 3: Whitelist Patterns (Recommended)

```coredns
.:53 {
    log

    # Whitelist domains matching patterns
    rewrite stop {
        name regex ^(.*\.)?github\.com$ answer "NOCHANGE"
        name regex ^(.*\.)?ubuntu\.com$ answer "NOCHANGE"
        name regex ^(.*\.)?npmjs\.org$ answer "NOCHANGE"
    }

    # Block everything else
    rewrite name regex ^.*$ NXDOMAIN

    forward . 8.8.8.8 8.8.4.4
    cache 30
}
```

## Advanced: Dynamic Blocklist

### Fetch blocklist from URL

```coredns
.:53 {
    log

    # Use hosts plugin to load blocklist
    hosts /etc/coredns/blocklist.txt {
        reload 1h
        fallthrough
    }

    forward . 8.8.8.8 8.8.4.4
    cache 30
}
```

Then `/etc/coredns/blocklist.txt`:

```
0.0.0.0 pornhub.com
0.0.0.0 xvideos.com
0.0.0.0 facebook.com
0.0.0.0 twitter.com
```

## Monitoring

### View CoreDNS Logs

```bash
sudo journalctl -u coredns -f
```

### Check DNS Queries

```bash
# Install dnstap (optional)
# See all DNS queries in real-time
sudo tail -f /var/log/coredns.log
```

### Prometheus Metrics

```bash
# CoreDNS exposes metrics at 127.0.0.1:9253/metrics
curl http://127.0.0.1:9253/metrics | grep coredns_dns
```

## Integration with Falco Firewall

Combining CoreDNS + nftables gives you:

1. **DNS Level** (CoreDNS)
   - Blocks domains → returns NXDOMAIN
   - Prevents resolution for bad sites
   - User sees "can't resolve" error

2. **IP Level** (nftables)
   - Blocks IPs not in whitelist
   - Catches any domain that slipped through
   - Backup layer of defense

## Advantages

✅ **DNS-level blocking** - Most efficient
✅ **Immediate feedback** - "Cannot resolve" error
✅ **No IP exposure** - Blocked domains don't resolve to IPs
✅ **Works system-wide** - All apps use CoreDNS
✅ **Transparent** - Users see DNS failures
✅ **Easier debugging** - DNS logs show what was blocked
✅ **Multiple layers** - Defense in depth with nftables

## Disadvantages

⚠️ Need to maintain blocklist/whitelist
⚠️ CoreDNS adds small latency (negligible)
⚠️ Needs local root access to bind port 53

## Best Practice

Use **whitelist approach** (only allow specific domains):

```coredns
# Only these domains work
github.com
ubuntu.com
registry.npmjs.org
pypi.org

# Everything else blocked
```

This is more secure than blacklist (blocking bad domains) because:
- Unknown domains are automatically blocked
- You explicitly approve each domain
- New malicious sites are blocked by default
