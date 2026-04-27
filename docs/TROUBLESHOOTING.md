# Troubleshooting Guide

## Common Issues

### 1. Service Won't Start

**Error**: `systemctl start falco-firewall-enforce` fails

**Solutions**:
- Check logs: `journalctl -u falco-firewall-enforce -n 50`
- Verify policy file syntax: `python3 -m yaml config/policy.yaml`
- Check permissions: `ls -la /etc/falco-firewall/`
- Ensure Python dependencies: `pip3 install PyYAML`

### 2. No Rules Applied

**Error**: `nft list ruleset` shows no firewall rules

**Solutions**:
- Check if nftables is installed: `nft --version`
- Verify kernel supports nftables: `uname -r` (need 5.8+)
- Check if enforcement daemon is running: `systemctl status falco-firewall-enforce`
- Manual rule application: `sudo python3 src/enforce.py reload`

### 3. Legitimate Traffic Getting Blocked

**Symptoms**: Applications fail to connect even though domains are allowed

**Root Causes**:
- Domain not in policy → Add to `config/policy.yaml`
- DNS caching issue → Check resolver cache
- Port mismatch → Verify ports in policy match application needs
- IP changed → AWS service IPs can change (use domain matching)

**Solutions**:
1. Check blocked connections: `tail /var/log/falco-firewall/denied.log`
2. Add missing domain to policy:
   ```yaml
   domains:
     - domain: "example.com"
       protocol: tcp
       ports: [443]
   ```
3. Reload policy: `make reload`
4. Verify with: `curl -v https://example.com`

### 4. AWS Metadata Service Access Issues

**Error**: `169.254.169.254` connection failing

**Solutions**:
- Metadata service is auto-allowed for all instances
- Check if running in EC2: `curl http://169.254.169.254/latest/meta-data/`
- If on non-AWS, disable metadata in policy:
  ```yaml
  aws:
    metadata_service_enabled: false
  ```

### 5. DNS Resolution Failures

**Error**: Domains not resolving to IPs

**Solutions**:
- Check if DNS is in allowed list:
  ```yaml
  ip_addresses:
    - "8.8.8.8:53"  # or your DNS server
  ```
- Verify DNS connectivity: `nslookup example.com`
- Check resolver cache: `grep "DNS" /var/log/falco-firewall/enforcement.log`

### 6. Performance Issues

**Symptoms**: High CPU/memory usage

**Solutions**:
- Reduce policy check interval: `performance.policy_check_interval`
- Optimize connection map size: `performance.connection_map_size`
- Review DNS cache TTL: `global.dns_cache_ttl`
- Monitor: `top -p $(pgrep -f enforce.py)`

### 7. Falco Not Detecting Violations

**Error**: No alerts for blocked connections

**Solutions**:
- Check Falco is running: `systemctl status falco`
- Verify rules loaded: `cat /etc/falco/rules.d/firewall-rules.yaml`
- Check Falco logs: `tail -f /var/log/falco/falco.log`
- Ensure detection rule macros are populated

## Debug Mode

Enable debug logging:

```bash
# Edit policy
sed -i 's/log_level: INFO/log_level: DEBUG/' /etc/falco-firewall/policy.yaml

# Restart
sudo systemctl restart falco-firewall-enforce

# Watch logs
tail -f /var/log/falco-firewall/enforcement.log
```

## Kernel Debugging

Check eBPF/nftables status:

```bash
# Verify nftables kernel support
cat /proc/net/nf_conntrack_max

# Check loaded eBPF programs
bpftool prog list

# Monitor nftables
nft monitor

# Check kernel logs
dmesg | grep -i nftables
```

## Manual Testing

Test without enforcement (detection only):

```yaml
global:
  enforcement_enabled: false
```

Test specific domain:

```bash
# Resolve domain
dig @8.8.8.8 example.com

# Try connection
curl -v https://example.com

# Check if allowed
grep "example.com" /var/log/falco-firewall/enforcement.log
```

## Reset Everything

```bash
# Stop services
sudo systemctl stop falco-firewall-enforce falco

# Clear rules
sudo nft flush ruleset

# Clear cache
sudo rm -rf /var/lib/falco-firewall/*

# Clear logs
sudo rm -f /var/log/falco-firewall/*

# Restart
sudo systemctl start falco-firewall-enforce falco
```

## Getting Help

Gather debug info:

```bash
./scripts/status.sh > debug.txt
journalctl -u falco-firewall-enforce -n 100 >> debug.txt
nft list ruleset >> debug.txt
python3 src/enforce.py status >> debug.txt
```

Then include `debug.txt` when reporting issues.
