#!/usr/bin/env python3
"""
Falco Firewall Enforcement Daemon
Manages policy enforcement via nftables and eBPF
"""

import os
import sys
import logging
import json
import socket
import subprocess
import threading
import time
import signal
from pathlib import Path
from typing import Dict, List, Set, Tuple, Optional
from dataclasses import dataclass, asdict
from datetime import datetime, timedelta
import yaml

try:
    from ebpf_firewall import EBPFFirewall
    EBPF_AVAILABLE = True
except ImportError:
    EBPF_AVAILABLE = False

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/falco-firewall/enforcement.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


@dataclass
class Destination:
    """Represents an allowed destination"""
    type: str  # 'ip', 'domain', 'ip_range'
    value: str  # IP, domain, or CIDR
    ports: List[int]
    protocol: str = 'tcp'
    description: str = ''


class DNSResolver:
    """Manages DNS resolution with caching"""

    def __init__(self, cache_ttl: int = 3600):
        self.cache_ttl = cache_ttl
        self.cache: Dict[str, Tuple[List[str], datetime]] = {}

    def resolve(self, domain: str) -> List[str]:
        """Resolve domain to list of IPs with caching"""
        # Check cache
        if domain in self.cache:
            ips, expiry = self.cache[domain]
            if datetime.now() < expiry:
                logger.debug(f"Cache hit for {domain}: {ips}")
                return ips

        try:
            ips = []
            results = socket.getaddrinfo(domain, None, socket.AF_INET)
            ips = list(set(ip[4][0] for ip in results))

            # Cache result
            self.cache[domain] = (ips, datetime.now() + timedelta(seconds=self.cache_ttl))
            logger.info(f"Resolved {domain} -> {ips}")
            return ips
        except socket.gaierror as e:
            logger.error(f"Failed to resolve {domain}: {e}")
            return []

    def invalidate(self, domain: str):
        """Invalidate cache entry"""
        if domain in self.cache:
            del self.cache[domain]
            logger.debug(f"Invalidated cache for {domain}")


class PolicyManager:
    """Manages firewall policy from YAML"""

    def __init__(self, policy_file: str):
        self.policy_file = policy_file
        self.policy = {}
        self.destinations: List[Destination] = []
        self.resolver = DNSResolver()
        self.load_policy()

    def load_policy(self):
        """Load and parse policy file"""
        try:
            with open(self.policy_file, 'r') as f:
                self.policy = yaml.safe_load(f)
            logger.info(f"Loaded policy from {self.policy_file}")
            self._build_destinations()
        except Exception as e:
            logger.error(f"Failed to load policy: {e}")
            raise

    def _build_destinations(self):
        """Build destinations from policy"""
        self.destinations = []
        allowed = self.policy.get('allowed', {})

        # Process explicit IPs
        for ip_cidr in (allowed.get('ip_addresses') or []):
            ip, port = self._parse_ip_port(ip_cidr)
            if ip:
                self.destinations.append(Destination(
                    type='ip',
                    value=ip,
                    ports=[port] if port else [80, 443],
                    protocol='tcp'
                ))

        # Process IP ranges
        for cidr in (allowed.get('ip_ranges') or []):
            self.destinations.append(Destination(
                type='ip_range',
                value=cidr,
                ports=[80, 443],
                protocol='tcp'
            ))

        # Process domains
        for domain_entry in (allowed.get('domains') or []):
            if isinstance(domain_entry, dict):
                domain = domain_entry.get('domain')
                ports = domain_entry.get('ports', [80, 443])
            else:
                domain = domain_entry
                ports = [80, 443]

            if domain:
                # Resolve and add IPs
                ips = self.resolver.resolve(domain)
                for ip in ips:
                    self.destinations.append(Destination(
                        type='domain',
                        value=ip,
                        ports=ports,
                        protocol='tcp',
                        description=f"Domain: {domain}"
                    ))

        # Process AWS services
        self._process_aws_services(allowed.get('aws_services') or [])

        logger.info(f"Built {len(self.destinations)} allowed destinations")

    def _parse_ip_port(self, ip_port: str) -> Tuple[str, Optional[int]]:
        """Parse IP:port or IP/CIDR:port format"""
        if ':' in ip_port:
            ip_part, port_part = ip_port.rsplit(':', 1)
            try:
                return ip_part, int(port_part)
            except ValueError:
                return ip_port, None
        return ip_port, None

    def _process_aws_services(self, services: List[Dict]):
        """Process AWS service endpoints"""
        region = self.policy.get('aws', {}).get('regions', ['us-east-1'])[0]

        for service in services:
            service_name = service.get('name')
            ports = service.get('ports', [443])

            # Common AWS service endpoints
            aws_endpoints = {
                'sns': f'{service_name}.{region}.amazonaws.com',
                'sqs': f'{service_name}.{region}.amazonaws.com',
                's3': f's3.{region}.amazonaws.com',
                'dynamodb': f'{service_name}.{region}.amazonaws.com',
                'kms': f'{service_name}.{region}.amazonaws.com',
                'logs': f'logs.{region}.amazonaws.com',
                'cloudwatch': f'monitoring.{region}.amazonaws.com',
                'ec2': f'ec2.{region}.amazonaws.com',
                'sts': f'sts.amazonaws.com',
                'secretsmanager': f'{service_name}.{region}.amazonaws.com',
            }

            if service_name in aws_endpoints:
                domain = aws_endpoints[service_name]
                ips = self.resolver.resolve(domain)
                for ip in ips:
                    self.destinations.append(Destination(
                        type='aws',
                        value=ip,
                        ports=ports,
                        protocol='tcp',
                        description=f"AWS: {service_name}"
                    ))

    def get_allowed_ips(self) -> Set[str]:
        """Get set of allowed IPs"""
        return set(d.value for d in self.destinations if d.type in ('ip', 'domain', 'aws'))

    def get_firewall_rules(self) -> List[str]:
        """Generate nftables rules from policy"""
        rules = []
        allowed_ips = self.get_allowed_ips()

        for ip in allowed_ips:
            rules.append(f"  ip daddr {ip} accept")

        # Allow AWS metadata service
        rules.append("  ip daddr 169.254.169.254 tcp dport 80 accept")
        rules.append("  ip daddr 169.254.169.254 tcp dport 443 accept")

        # Deny all else
        rules.append("  reject")

        return rules


class NFTablesManager:
    """Manages nftables firewall rules"""

    def __init__(self):
        self.chain_name = "firewall_out"
        self.table_name = "filter"

    def create_rules(self, destinations: List[Destination]) -> str:
        """Generate nftables rule script"""
        script = f"""
#!/usr/bin/env nft -f
# Auto-generated by Falco Firewall Enforcement

table inet {self.table_name} {{
  chain {self.chain_name} {{
    type filter hook output priority filter; policy drop;

"""

        # Add rules for each destination
        seen_rules = set()
        for dest in destinations:
            port_str = ",".join(map(str, dest.ports))
            rule = f"    ip daddr {dest.value} {dest.protocol} dport {{{port_str}}} accept"

            if rule not in seen_rules:
                script += rule + "\n"
                seen_rules.add(rule)

        # AWS Metadata Service (always allow)
        script += """
    # AWS Metadata Service
    ip daddr 169.254.169.254 tcp dport 80 accept
    ip daddr 169.254.169.254 tcp dport 443 accept

    # Allow DNS for resolution (any destination, UDP port 53)
    udp dport 53 accept

    # Allow loopback
    ip daddr 127.0.0.1 accept
"""

        script += "    reject with icmp type host-unreachable\n"
        script += "  }\n}\n"

        return script

    def apply_rules(self, script: str) -> bool:
        """Apply nftables rules"""
        try:
            result = subprocess.run(
                ['nft', '-f', '-'],
                input=script.encode(),
                capture_output=True,
                check=True
            )
            logger.info("Applied nftables rules")
            return True
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to apply nftables rules: {e.stderr.decode()}")
            return False

    def show_rules(self) -> str:
        """Show current nftables rules"""
        try:
            result = subprocess.run(
                ['nft', 'list', 'chain', 'inet', self.table_name, self.chain_name],
                capture_output=True,
                text=True,
                check=True
            )
            return result.stdout
        except subprocess.CalledProcessError:
            return "Rules not yet applied"


class EnforcementDaemon:
    """Main firewall enforcement daemon"""

    def __init__(self, policy_file: str, check_interval: int = 10):
        self.policy_file = policy_file
        self.check_interval = check_interval
        self.running = True
        self.policy_manager = PolicyManager(policy_file)
        self.nftables = NFTablesManager()
        self.ebpf = None
        self.ebpf_enabled = False

        # Initialize eBPF if available
        if EBPF_AVAILABLE:
            try:
                iface = self._detect_primary_interface()
                if iface:
                    log_file = '/var/log/falco-firewall/ebpf-blocked.log'
                    map_size = self.policy_manager.policy.get('performance', {}).get(
                        'connection_map_size', 1024)
                    self.ebpf = EBPFFirewall(
                        interface=iface,
                        log_file=log_file,
                        map_size=map_size
                    )
                    self.ebpf_enabled = True
                    logger.info("eBPF enforcement layer enabled")
            except Exception as e:
                logger.warning(f"eBPF initialization failed, continuing without eBPF: {e}")

        # Register signal handlers
        signal.signal(signal.SIGHUP, self._on_reload_signal)
        signal.signal(signal.SIGTERM, self._on_shutdown_signal)
        signal.signal(signal.SIGINT, self._on_shutdown_signal)

        self._apply_rules()

    def _detect_primary_interface(self) -> Optional[str]:
        """Detect the primary network interface from default route"""
        try:
            result = subprocess.run(
                ['ip', 'route', 'show', 'default'],
                capture_output=True,
                text=True,
                check=False
            )
            # Parse 'default via ... dev eth0 ...'
            parts = result.stdout.split()
            if 'dev' in parts:
                idx = parts.index('dev')
                if idx + 1 < len(parts):
                    return parts[idx + 1]
        except Exception as e:
            logger.warning(f"Failed to detect primary interface: {e}")
        return None

    def _on_reload_signal(self, signum, frame):
        """Handle SIGHUP for policy reload"""
        logger.info("Received SIGHUP, reloading policy")
        try:
            self.policy_manager.load_policy()
            self._apply_rules()
        except Exception as e:
            logger.error(f"Error reloading policy: {e}")

    def _on_shutdown_signal(self, signum, frame):
        """Handle SIGTERM/SIGINT for graceful shutdown"""
        logger.info(f"Received signal {signum}, shutting down")
        self.stop()

    def _apply_rules(self):
        """Apply firewall rules to both nftables and eBPF"""
        # Apply nftables rules
        script = self.nftables.create_rules(self.policy_manager.destinations)
        self.nftables.apply_rules(script)

        # Update eBPF map with allowed IPs
        if self.ebpf_enabled and self.ebpf:
            try:
                allowed_ips = self.policy_manager.get_allowed_ips()
                self.ebpf.update_allowlist(allowed_ips)
            except Exception as e:
                logger.error(f"Failed to update eBPF allowlist: {e}")

    def run(self):
        """Run enforcement daemon"""
        logger.info("Starting Falco Firewall Enforcement Daemon")

        # Reload policy periodically
        while self.running:
            try:
                time.sleep(self.check_interval)
                self.policy_manager.load_policy()
                self._apply_rules()
            except Exception as e:
                logger.error(f"Error in enforcement loop: {e}")

    def stop(self):
        """Stop daemon"""
        logger.info("Stopping Falco Firewall Enforcement Daemon")
        self.running = False

        # Detach eBPF
        if self.ebpf_enabled and self.ebpf:
            try:
                self.ebpf.detach()
            except Exception as e:
                logger.warning(f"Error detaching eBPF: {e}")

    def show_status(self):
        """Show current status"""
        print("\n=== Falco Firewall Status ===\n")
        print(f"Policy File: {self.policy_file}")
        print(f"Allowed Destinations: {len(self.policy_manager.destinations)}")
        print(f"Allowed IPs: {len(self.policy_manager.get_allowed_ips())}")
        print("\n=== nftables Rules ===\n")
        print(self.nftables.show_rules())


def main():
    """Main entry point"""
    policy_file = '/etc/falco-firewall/policy.yaml'

    # Parse arguments
    if len(sys.argv) > 1:
        if sys.argv[1] == 'status':
            daemon = EnforcementDaemon(policy_file)
            daemon.show_status()
            return
        elif sys.argv[1] == 'reload':
            daemon = EnforcementDaemon(policy_file)
            daemon._apply_rules()
            logger.info("Policy reloaded")
            return

    # Run daemon
    daemon = EnforcementDaemon(policy_file)

    def signal_handler(sig, frame):
        daemon.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        daemon.run()
    except KeyboardInterrupt:
        daemon.stop()


if __name__ == '__main__':
    main()
