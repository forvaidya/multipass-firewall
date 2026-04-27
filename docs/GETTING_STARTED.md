# Getting Started with Falco Firewall

## 5-Minute Quick Start

### 1. Install

```bash
git clone https://github.com/your-org/multipass-firewall.git
cd multipass-firewall
sudo ./scripts/setup.sh
```

### 2. Configure

Edit allowed destinations:

```bash
sudo vim /etc/falco-firewall/policy.yaml
```

Add your domains/IPs under `allowed:`:

```yaml
allowed:
  domains:
    - domain: "api.example.com"
      protocol: tcp
      ports: [443]
    - domain: "*.s3.amazonaws.com"
      protocol: tcp
      ports: [443]

  ip_addresses:
    - "10.0.1.5/32:5432"
```

### 3. Start

```bash
sudo systemctl start falco-firewall-enforce
sudo systemctl status falco-firewall-enforce
```

### 4. Verify

```bash
# Check if rules are loaded
sudo nft list chain inet filter firewall_out

# Test a connection
curl https://api.example.com

# View logs
tail -f /var/log/falco-firewall/enforcement.log
```

## Detailed Setup

### Step 1: System Check

```bash
# Verify OS
cat /etc/os-release

# Check kernel version (need 5.8+)
uname -r

# Check for required tools
command -v nft curl pip3 python3

# Verify you have sudo access
sudo whoami
```

### Step 2: Clone Repository

```bash
# Via HTTPS
git clone https://github.com/your-org/multipass-firewall.git

# Or via SSH
git clone git@github.com:your-org/multipass-firewall.git

cd multipass-firewall
```

### Step 3: Review Configuration

Before installing, review the default policy:

```bash
cat config/policy.yaml
```

Key sections:
- `aws.regions`: Your AWS regions
- `allowed.aws_services`: Which AWS services to allow
- `allowed.domains`: External domains your app needs
- `allowed.ip_addresses`: Specific IPs to allow

### Step 4: Install

```bash
# Make script executable
chmod +x scripts/setup.sh

# Run installation
sudo ./scripts/setup.sh
```

The installer will:
- Install system dependencies (nftables, Falco, etc.)
- Install Python dependencies (PyYAML)
- Copy files to `/opt/falco-firewall` and `/etc/falco-firewall`
- Install systemd services
- Configure Falco rules

### Step 5: Customize Policy

```bash
sudo vim /etc/falco-firewall/policy.yaml
```

#### Example 1: Allow Docker Hub

```yaml
allowed:
  domains:
    - domain: "*.docker.io"
      protocol: tcp
      ports: [443]
    - domain: "docker.com"
      protocol: tcp
      ports: [443]
    - domain: "ghcr.io"
      protocol: tcp
      ports: [443]
```

#### Example 2: Allow Multiple AWS Services

```yaml
allowed:
  aws_services:
    - name: sns
      protocol: tcp
      ports: [443]
    - name: sqs
      protocol: tcp
      ports: [443]
    - name: s3
      protocol: tcp
      ports: [443]
    - name: kms
      protocol: tcp
      ports: [443]
```

#### Example 3: Allow Private Network

```yaml
allowed:
  ip_ranges:
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "192.168.0.0/16"
```

### Step 6: Start Services

```bash
# Enable at startup
sudo systemctl enable falco-firewall-enforce

# Start the service
sudo systemctl start falco-firewall-enforce

# Check it's running
sudo systemctl status falco-firewall-enforce

# Watch logs
sudo journalctl -u falco-firewall-enforce -f
```

### Step 7: Test

```bash
# Show current rules
sudo nft list chain inet filter firewall_out

# Test allowed connection
curl -v https://api.example.com

# Test blocked connection (should fail/timeout)
timeout 3 curl -v https://8.8.8.8:443 || true

# View violations
sudo tail /var/log/falco-firewall/denied.log
```

## Managing the Firewall

### View Status

```bash
make status
```

Or manually:

```bash
# Service status
sudo systemctl status falco-firewall-enforce

# Active rules
sudo nft list chain inet filter firewall_out

# Statistics
nft list chain inet filter firewall_out -a
```

### Reload Policy

After editing `/etc/falco-firewall/policy.yaml`:

```bash
# Reload (doesn't require restart)
sudo python3 /opt/falco-firewall/enforce.py reload

# Or via systemctl
sudo systemctl restart falco-firewall-enforce
```

### View Logs

```bash
# All logs
tail -f /var/log/falco-firewall/*.log

# Only denied connections
tail -f /var/log/falco-firewall/denied.log

# Only allowed (verbose)
tail -f /var/log/falco-firewall/allowed.log

# System logs
sudo journalctl -u falco-firewall-enforce -f
```

### Temporarily Disable

```bash
# Stop enforcement (keeps monitoring active)
sudo systemctl stop falco-firewall-enforce

# Disable blocking
sudo nft flush ruleset

# Re-enable
sudo systemctl start falco-firewall-enforce
```

## Common Tasks

### Add a New Domain

```yaml
# /etc/falco-firewall/policy.yaml
allowed:
  domains:
    - domain: "api.newservice.com"
      protocol: tcp
      ports: [443]
```

Then reload:
```bash
sudo python3 /opt/falco-firewall/enforce.py reload
```

### Block a Specific IP

```yaml
# /etc/falco-firewall/policy.yaml
deny:
  ip_ranges:
    - "192.0.2.1/32"  # Bad actor
```

### Whitelist a Process

```yaml
# Allow specific process to bypass firewall
exceptions:
  process_names:
    - "apt"        # Package manager
    - "snap"       # Snap packages
```

### Enable Debug Logging

```yaml
# /etc/falco-firewall/policy.yaml
global:
  log_level: DEBUG
```

Then:
```bash
sudo systemctl restart falco-firewall-enforce
tail -f /var/log/falco-firewall/enforcement.log
```

### Uninstall

```bash
# Stop services
sudo systemctl stop falco-firewall-enforce falco

# Remove everything
sudo ./scripts/cleanup.sh

# Verify rules are gone
sudo nft list ruleset
```

## Architecture Overview

### Detection Layer (Falco)

Falco monitors all outbound connections using eBPF and:
- Detects attempts to unauthorized destinations
- Alerts on suspicious patterns (data exfiltration, tunneling)
- Logs all activity for audit

### Enforcement Layer (nftables)

nftables enforces the policy at kernel level:
- Drops packets to non-whitelisted destinations
- Uses ingress/egress hooks for complete coverage
- Sub-microsecond latency (native kernel code)

### Policy Layer

Your `policy.yaml` defines:
- Allowed domains (auto-resolved to IPs)
- Allowed IP ranges (CIDR notation)
- AWS service endpoints (auto-discovered)
- Deny rules (explicit blocks)

### DNS Resolution

Dynamic resolver:
- Periodically resolves domains to IPs
- Caches results (configurable TTL)
- Updates firewall rules automatically

## Performance Considerations

- **CPU**: < 1% idle, ~0.1% per 100 connections
- **Memory**: ~50MB base, scales with policy size
- **Network**: Minimal impact (kernel-level enforcement)

## Security Considerations

1. **Principle of Least Privilege**: Only allow what's needed
2. **Deny by Default**: Everything not explicitly allowed is blocked
3. **Regular Audits**: Review logs and policy monthly
4. **Update Policy**: Add/remove domains as services change
5. **Monitor Violations**: Alert on unexpected blocks

## Next Steps

- 📖 Read [AWS_DEPLOYMENT.md](./AWS_DEPLOYMENT.md) for AWS setup
- 🔧 See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for issues
- 🏗️ Check [ARCHITECTURE.md](./ARCHITECTURE.md) for internals
- 📋 Review `/etc/falco-firewall/policy.yaml` for all options

## Getting Help

1. Check logs: `tail /var/log/falco-firewall/*.log`
2. Run tests: `make test`
3. Get status: `make status`
4. Read troubleshooting: `docs/TROUBLESHOOTING.md`
