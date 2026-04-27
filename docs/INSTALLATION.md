# Falco Firewall Installation Guide

## Quick Install (Interactive)

```bash
git clone https://github.com/your-org/multipass-firewall.git
cd multipass-firewall
sudo ./scripts/setup.sh
```

The script will prompt you for:
- Allowed domains (comma-separated)
- Allowed IPs/CIDRs (comma-separated)

---

## Automated Install (Command Line)

Specify whitelist via command-line arguments:

```bash
sudo ./scripts/setup.sh \
  --domains "api.example.com,registry.npmjs.org,pypi.org" \
  --ips "10.0.1.5,192.168.1.10" \
  --auto
```

**Options**:
- `--domains "domain1,domain2,..."` - Comma-separated list of allowed domains
- `--ips "ip1/cidr1,ip2/cidr2,..."` - Comma-separated list of allowed IPs/CIDRs
- `--auto` - Non-interactive mode (no prompts)

---

## User Data (EC2 Automatic)

### Option 1: Inline Script

Create EC2 instance with this user data:

```bash
#!/bin/bash
export WHITELIST_DOMAINS="api.example.com,registry.npmjs.org"
export WHITELIST_IPS="10.0.1.5,192.168.1.10"
curl -sSL https://raw.githubusercontent.com/your-org/multipass-firewall/main/scripts/user-data.sh | bash
```

### Option 2: From S3

Store your custom user data in S3:

```bash
#!/bin/bash
aws s3 cp s3://your-bucket/firewall-init.sh /tmp/
bash /tmp/firewall-init.sh
```

Example `firewall-init.sh`:
```bash
#!/bin/bash
set -e

# Clone and setup
cd /tmp
git clone https://github.com/your-org/multipass-firewall.git
cd multipass-firewall

# Run with your whitelist
sudo ./scripts/setup.sh \
  --domains "api.myapp.com,registry.npmjs.org,pypi.org" \
  --ips "10.0.1.5" \
  --auto

# Verify
sudo systemctl status falco-firewall-enforce
```

### Option 3: CloudFormation/Terraform

**Terraform example**:

```hcl
resource "aws_instance" "firewall" {
  ami           = "ami-0c55b159cbfafe1f0"  # Ubuntu 22.04
  instance_type = "t4g.medium"             # Graviton ARM

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    whitelist_domains = "api.example.com,registry.npmjs.org,pypi.org"
    whitelist_ips     = "10.0.1.5,192.168.1.10"
  }))

  tags = {
    Name = "falco-firewall"
  }
}
```

**CloudFormation example**:

```yaml
FirewallInstance:
  Type: AWS::EC2::Instance
  Properties:
    ImageId: ami-0c55b159cbfafe1f0
    InstanceType: t4g.medium
    UserData: !Sub |
      #!/bin/bash
      export WHITELIST_DOMAINS="api.example.com,registry.npmjs.org"
      export WHITELIST_IPS="10.0.1.5"
      curl -sSL https://raw.githubusercontent.com/your-org/multipass-firewall/main/scripts/user-data.sh | bash
```

---

## Installation Steps Breakdown

When you run the setup script, it:

1. **[1/9] Check Prerequisites** - Verifies Python3, pip3, curl installed
2. **[2/9] Install Dependencies** - nftables, Falco, build tools
3. **[3/9] Install Falco** - Runtime security monitoring
4. **[4/9] Create Directories** - `/opt/falco-firewall`, `/etc/falco-firewall`, etc.
5. **[5/9] Copy Files** - Enforcement scripts, rules, configurations
6. **[6/9] Install Python Deps** - PyYAML library
7. **[7/9] Generate Policy** - Creates `policy.yaml` with your whitelist
8. **[8/9] Install Services** - systemd services for Falco
9. **[9/9] Configure Falco** - Loads rules and starts enforcement

---

## Verify Installation

After setup completes:

```bash
# Check service running
sudo systemctl status falco-firewall-enforce

# View rules
sudo nft list chain inet filter firewall_out

# Check logs
sudo journalctl -u falco-firewall-enforce -f

# Test a connection
curl https://api.example.com  # Should work
timeout 2 curl https://8.8.8.8:443  # Should timeout
```

---

## Examples

### Example 1: Node.js App

```bash
sudo ./scripts/setup.sh \
  --domains "registry.npmjs.org,github.com,api.github.com" \
  --ips "8.8.8.8,8.8.4.4" \
  --auto
```

### Example 2: Python App

```bash
sudo ./scripts/setup.sh \
  --domains "pypi.org,files.pythonhosted.org,github.com" \
  --auto
```

### Example 3: AWS Services Only

```bash
# Edit policy after install to enable AWS services
sudo vim /etc/falco-firewall/policy.yaml

# Then enable SNS, SQS, S3, etc. under allowed.aws_services
# And reload
sudo systemctl restart falco-firewall-enforce
```

### Example 4: Custom Services

```bash
sudo ./scripts/setup.sh \
  --domains "api.internal.company.com,db.internal.company.com,logs.internal.company.com" \
  --ips "10.0.1.0/24,172.16.0.0/12" \
  --auto
```

---

## Post-Installation

### Edit Policy Anytime

```bash
sudo vim /etc/falco-firewall/policy.yaml
```

Add more domains/IPs:
```yaml
allowed:
  domains:
    - domain: "new-api.example.com"
      protocol: tcp
      ports: [443]

  ip_addresses:
    - "10.1.1.5/32:443"
```

### Reload Rules

```bash
sudo systemctl restart falco-firewall-enforce
```

### Check Current Rules

```bash
sudo nft list chain inet filter firewall_out
```

### View All Logs

```bash
tail -f /var/log/falco-firewall/*.log
```

---

## Troubleshooting Installation

**Service won't start:**
```bash
sudo journalctl -u falco-firewall-enforce -n 50
```

**nftables not installed:**
```bash
sudo apt-get install nftables
```

**Policy parse error:**
```bash
python3 -m yaml /etc/falco-firewall/policy.yaml
```

**Falco not running:**
```bash
sudo systemctl status falco
sudo journalctl -u falco -n 20
```

---

## Uninstall

```bash
sudo ./scripts/cleanup.sh
```

This removes:
- All services
- Firewall rules
- Configuration files
- Installation directory
