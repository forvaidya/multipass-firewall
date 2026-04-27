# AWS EC2 Deployment Guide

Deploy the three-layer firewall on EC2 in Mumbai region (ap-south-1) with full AWS service support.

## Prerequisites

- **EC2 Instance**: Ubuntu 24.04 LTS, t3.micro or larger
- **Subnet**: Public subnet (for internet access to ECR, S3, STS)
- **Security Group**: Allow outbound HTTPS (443), HTTP (80), DNS (53)
- **IAM Role**: EC2 instance role with permissions for ECR, S3, STS access
- **Region**: ap-south-1 (Mumbai)

## AWS Whitelisting

The firewall includes AWS services in ap-south-1:

### Domains (Layer 1 - CoreDNS)
```
*.dkr.ecr.ap-south-1.amazonaws.com    # ECR - Pull container images
s3.ap-south-1.amazonaws.com            # S3 - Bucket access
s3.amazonaws.com                       # S3 - Global endpoint
sts.ap-south-1.amazonaws.com           # STS - Session tokens
sts.amazonaws.com                      # STS - Global endpoint
```

### IPs (Layer 3 - nftables)
```
169.254.169.254          # EC2 Metadata Service (CRITICAL)
13.126.0.0/16            # AWS ap-south-1 services
13.127.0.0/16            # AWS ap-south-1 services
52.172.0.0/14            # AWS ap-south-1 services
52.136.0.0/13            # AWS ap-south-1 services
52.144.0.0/14            # AWS ap-south-1 services
52.152.0.0/15            # AWS ap-south-1 services
```

## Quick Start

### 1. Launch EC2 Instance

```bash
# Launch Ubuntu 24.04 in ap-south-1
aws ec2 run-instances \
  --image-id ami-0c94855ba95c574c8 \
  --instance-type t3.micro \
  --region ap-south-1 \
  --security-groups default \
  --subnet-id subnet-xxxxx
```

### 2. Connect to Instance

```bash
ssh -i your-key.pem ubuntu@<instance-public-ip>
```

### 3. Clone Firewall Repository

```bash
git clone <your-repo> multipass-firewall
cd multipass-firewall
```

### 4. Deploy Firewall

```bash
# Deploy with AWS support (ap-south-1)
sudo ./scripts/setup-aws-ec2.sh

# Or use configurable redirect for office/school environments
sudo ./scripts/setup-configurable-redirect.sh --environment office
```

The setup script installs:
- **Layer 1**: CoreDNS (domain filtering with AWS domains)
- **Layer 2**: eBPF (DNS resolver monitoring)
- **Layer 3**: nftables (IP whitelist including metadata service)

## Testing

### 1. Verify Metadata Service Access (CRITICAL)

```bash
# This MUST work - EC2 uses this for credentials
curl 169.254.169.254/latest/meta-data/
curl 169.254.169.254/latest/meta-data/iam/security-credentials/
```

**Expected output**: Instance metadata (availability-zone, instance-id, etc.)

### 2. Verify DNS is Working

```bash
# Should resolve to CoreDNS (127.0.0.1)
cat /etc/resolv.conf

# Test whitelisted domain
nslookup github.com 127.0.0.1
# Expected: normal resolution

# Test whitelisted AWS domain
nslookup s3.ap-south-1.amazonaws.com 127.0.0.1
# Expected: normal resolution

# Test non-whitelisted domain
nslookup pornhub.com 127.0.0.1
# Expected: redirects to github.com IP (140.82.113.4)
```

### 3. Verify CoreDNS is Running

```bash
sudo systemctl status coredns
sudo journalctl -u coredns -f

# Should see DNS queries being processed
```

### 4. Test ECR Access (if using container images)

```bash
# Login to ECR
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin 123456789.dkr.ecr.ap-south-1.amazonaws.com

# Expected: Login successful (will fail if firewall blocks ECR)
```

### 5. Test S3 Access

```bash
# List S3 buckets
aws s3 ls --region ap-south-1

# Download from S3
aws s3 cp s3://your-bucket/file.txt . --region ap-south-1
```

### 6. Test STS Access

```bash
# Get current caller identity (uses STS)
aws sts get-caller-identity --region ap-south-1

# Expected: Returns account ID, IAM user/role ARN
```

### 7. Verify Firewall Rules

```bash
# Check CoreDNS configuration
sudo cat /etc/coredns/Corefile

# Check nftables rules
sudo nft list ruleset

# Check DNS resolver logs
sudo journalctl -u coredns -n 20

# Check if unauthorized domains are blocked
sudo journalctl -u nftables -e
```

## Troubleshooting

### Metadata Service Timeout

**Problem**: `curl 169.254.169.254` times out

**Cause**: IP 169.254.169.254 not whitelisted in nftables

**Fix**:
```bash
# Verify it's in whitelist
sudo nft list ruleset | grep 169.254.169.254

# If missing, update /etc/nftables.conf and reload
sudo systemctl restart nftables
```

### DNS Resolution Failing

**Problem**: `nslookup` returns SERVFAIL or times out

**Cause**: CoreDNS not running or not configured

**Fix**:
```bash
# Check CoreDNS status
sudo systemctl status coredns

# Check logs
sudo journalctl -u coredns -f

# Restart
sudo systemctl restart coredns
```

### AWS Services Blocked

**Problem**: `aws s3 ls` fails, ECR login fails

**Cause**: AWS IP ranges not in nftables whitelist

**Fix**:
```bash
# Fetch latest AWS IP ranges
sudo ./scripts/fetch-aws-ips.sh

# Add to /etc/falco-firewall/redirect-config.yaml
sudo vim /etc/falco-firewall/redirect-config.yaml

# Regenerate and restart
sudo ./scripts/setup-aws-ec2.sh
```

### DNS Redirect Not Working

**Problem**: `nslookup pornhub.com 127.0.0.1` doesn't return redirect IP

**Cause**: CoreDNS rewrite rules not configured

**Fix**:
```bash
# Check Corefile
sudo cat /etc/coredns/Corefile

# Should have: rewrite name regex ^.*$ answer <redirect-ip>.

# Restart CoreDNS
sudo systemctl restart coredns
```

## AWS IP Ranges

AWS publishes IP ranges at: https://ip-ranges.amazonaws.com/ip-ranges.json

To get complete list for ap-south-1:

```bash
# Download and parse
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json | \
  jq '.prefixes[] | select(.region=="ap-south-1") | .ip_prefix' | sort | uniq

# Add to whitelist in config/redirect-config.yaml
```

Or use the provided script:

```bash
sudo ./scripts/fetch-aws-ips.sh
```

## Changing Redirect Target

If deploying to office/school environment:

```bash
sudo ./scripts/setup-configurable-redirect.sh --environment office

# Or custom:
sudo ./scripts/setup-configurable-redirect.sh --redirect-to "intranet.company.com"
```

## Monitoring

### Real-time DNS Queries

```bash
sudo journalctl -u coredns -f
```

### Real-time Firewall Blocks

```bash
sudo journalctl -u nftables -f
```

### Check Active Rules

```bash
# CoreDNS
sudo systemctl status coredns

# nftables
sudo nft list ruleset

# eBPF/Falco (if enabled)
sudo systemctl status falco
```

## Security Notes

### DO NOT

- ❌ Disable the metadata service whitelist (169.254.169.254)
- ❌ Add 0.0.0.0/0 to whitelist (defeats purpose)
- ❌ Run in private key mode without proper DNS

### DO

- ✅ Keep AWS IP ranges updated (`fetch-aws-ips.sh`)
- ✅ Monitor CoreDNS logs for redirect attempts
- ✅ Test metadata service after deployment
- ✅ Use IAM instance roles (not long-lived keys)

## Production Checklist

- [ ] Metadata service access verified (169.254.169.254)
- [ ] ECR domains whitelisted and tested
- [ ] S3 access verified with AWS CLI
- [ ] STS tokens working
- [ ] DNS resolver using CoreDNS (127.0.0.1)
- [ ] nftables rules loaded and active
- [ ] CoreDNS service set to auto-start
- [ ] Logs monitored (journalctl)
- [ ] Unauthorized domains return redirect IP

## Next Steps

After successful deployment on EC2:

1. **Automate deployment** - Use user data script
2. **Monitor in production** - Send logs to CloudWatch
3. **Update IP ranges** - Schedule periodic refresh of AWS IPs
4. **Test failover** - Verify behavior when services are unavailable
5. **Document changes** - Keep whitelist updated in your repo
