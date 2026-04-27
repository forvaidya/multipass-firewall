#!/bin/bash
# Fetch AWS IP ranges for ap-south-1 and update whitelist
# Usage: sudo ./fetch-aws-ips.sh

set -e

REGION="ap-south-1"
OUTPUT_FILE="/tmp/aws-ips-${REGION}.txt"
CONFIG_FILE="/etc/falco-firewall/redirect-config.yaml"

echo "Fetching AWS IP ranges for region: $REGION"
echo "==========================================="

# Download AWS IP ranges
echo "Downloading from ip-ranges.amazonaws.com..."
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json -o /tmp/aws-ip-ranges.json

# Extract IPs for ap-south-1 (both EC2 and other services)
echo "Extracting IPs for $REGION..."
python3 << 'PYTHON'
import json
import sys

with open('/tmp/aws-ip-ranges.json') as f:
    data = json.load(f)

ips = set()

# Get service IPs for the region
for prefix in data['prefixes']:
    if prefix['region'] == 'ap-south-1':
        ips.add(prefix['ip_prefix'])
        print(f"  {prefix['ip_prefix']} - {prefix['service']}")

# IPv6 prefixes (optional)
for prefix in data['ipv6_prefixes']:
    if prefix['region'] == 'ap-south-1':
        print(f"  {prefix['ipv6_prefix']} - {prefix['service']} (IPv6)")

print(f"\nTotal IP ranges for ap-south-1: {len(ips)}")

with open('/tmp/aws-ips-ap-south-1.txt', 'w') as f:
    for ip in sorted(ips):
        f.write(f"    - \"{ip}\"\n")
PYTHON

echo ""
echo "IP ranges extracted to /tmp/aws-ips-ap-south-1.txt"
echo ""
echo "To add these to your whitelist:"
echo "  sudo cat /tmp/aws-ips-ap-south-1.txt"
echo ""
echo "Then add to /etc/falco-firewall/redirect-config.yaml under whitelist.ips"
echo ""

# Show summary
echo "Summary of AWS IP ranges:"
echo "==========================================="
wc -l /tmp/aws-ips-ap-south-1.txt
echo ""

# Show first 10 IPs
echo "First 10 IP ranges:"
head -10 /tmp/aws-ips-ap-south-1.txt

echo ""
echo "To apply to nftables (requires update):"
echo "  1. Edit /etc/falco-firewall/redirect-config.yaml"
echo "  2. Add AWS IPs from /tmp/aws-ips-ap-south-1.txt"
echo "  3. Run: sudo ./scripts/setup-configurable-redirect.sh --environment office"
echo ""
