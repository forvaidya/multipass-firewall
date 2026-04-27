# Falco-Based Outbound Firewall

A production-ready outbound firewall using Falco for detection and eBPF/nftables for enforcement. Designed for AWS environments with support for metadata service and dynamic domain resolution.

## Architecture

```
┌─────────────────────────────────────────┐
│        Application Layer                 │
└─────────────────────┬───────────────────┘
                      │
        ┌─────────────┴──────────────┐
        │                            │
    ┌───▼────────┐         ┌────────▼────┐
    │   Falco    │         │   eBPF      │
    │ (Detection)│         │ (Enforcement)
    └───┬────────┘         └────────┬────┘
        │                           │
    ┌───▼──────────────────────────▼───┐
    │   Policy Engine                   │
    │  (Domains + IPs allowlist)        │
    └───────────────────────────────────┘
        │
    ┌───▼──────────────────────────────┐
    │   DNS Resolver (dynamic lookup)   │
    └───────────────────────────────────┘
```

## Features

- **Detection**: Falco monitors all outbound connections and alerts on policy violations
- **Enforcement**: eBPF/nftables blocks unauthorized outbound traffic at kernel level
- **AWS Support**: Pre-configured for AWS metadata service (169.254.169.254) and common AWS services
- **Dynamic Resolution**: Resolves domains to IPs and auto-updates firewall rules
- **Policy Management**: YAML-based configuration for allowed domains and IPs
- **Hot Reload**: Update policies without restarting services

## Quick Start

```bash
# 1. Clone and install
git clone <repo>
cd multipass-firewall
sudo ./scripts/setup.sh

# 2. Configure allowed domains/IPs
vim config/policy.yaml

# 3. Start the firewall
sudo systemctl start falco-firewall
sudo systemctl start falco-enforcement

# 4. Monitor
sudo systemctl status falco-firewall
tail -f /var/log/falco/firewall.log
```

## Configuration

See `config/policy.yaml` for details on specifying allowed domains and IP addresses.

## AWS Integration

The firewall automatically allows:
- AWS Metadata Service: `169.254.169.254:80/443`
- Common AWS services via domain patterns or IP ranges
- Custom service endpoints you add to the policy

## File Structure

```
├── config/
│   └── policy.yaml              # Allowed domains and IPs
├── falco/
│   └── rules.yaml               # Falco detection rules
├── ebpf/
│   ├── firewall.c               # eBPF enforcement program
│   └── Makefile
├── src/
│   ├── enforce.py               # Enforcement daemon
│   ├── resolver.py              # DNS resolver
│   └── policy_manager.py         # Policy management
├── scripts/
│   ├── setup.sh                 # Installation
│   └── cleanup.sh               # Uninstall
└── README.md                    # This file
```

## System Requirements

- Linux kernel 5.8+ (for eBPF TC support)
- Falco 0.35+
- Python 3.8+
- nftables/iptables
- Root/sudo access

## Monitoring

- **Falco Alerts**: Check `/var/log/falco/firewall.log`
- **Blocked Connections**: Check kernel logs `dmesg` or `journalctl`
- **Policy Status**: `sudo ./scripts/status.sh`

## Troubleshooting

See `docs/troubleshooting.md` for common issues and solutions.
