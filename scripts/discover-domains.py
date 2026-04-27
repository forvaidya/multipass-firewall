#!/usr/bin/env python3
"""
DNS Domain Discovery Tool
Analyzes CoreDNS logs to identify blocked domains and suggest whitelist additions
"""

import subprocess
import re
import sys
from collections import defaultdict
from datetime import datetime

# Read whitelist
WHITELIST_FILE = "/etc/coredns/whitelist.txt"
COREFILE = "/etc/coredns/Corefile"

def get_whitelisted_domains():
    """Extract whitelisted domains from whitelist.txt"""
    whitelisted = set()
    try:
        with open(WHITELIST_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    # Extract domain from "IP domain" format
                    parts = line.split()
                    if len(parts) >= 2:
                        whitelisted.add(parts[1])
    except FileNotFoundError:
        print(f"Warning: {WHITELIST_FILE} not found")
    return whitelisted

def get_recent_queries(minutes=5):
    """Get recent DNS queries from CoreDNS logs"""
    try:
        # Get logs from the last N minutes
        cmd = f"journalctl -u coredns -n 1000 --no-pager 2>/dev/null | tail -200"
        output = subprocess.check_output(cmd, shell=True, text=True)

        queries = defaultdict(int)
        # Parse CoreDNS log format: look for query lines
        # Example: coredns[PID]: example.com A
        for line in output.split('\n'):
            if 'IN A' in line or 'IN AAAA' in line or 'IN MX' in line:
                # Extract domain names
                parts = line.split()
                for part in parts:
                    if '.' in part and not part.startswith('[') and not part.startswith('{'):
                        # Simple heuristic: if it looks like a domain
                        if re.match(r'^[\w\-\.]+\.[a-zA-Z]{2,}$', part):
                            domain = part.rstrip('.')
                            if domain and not domain[0].isdigit():
                                queries[domain] += 1

        return queries
    except subprocess.CalledProcessError:
        print("Error reading CoreDNS logs")
        return {}

def categorize_domains(queries, whitelisted):
    """Categorize domains as blocked or allowed"""
    blocked = {}
    allowed = {}

    for domain, count in queries.items():
        # Check if domain or parent domain is whitelisted
        is_whitelisted = False

        # Check exact match
        if domain in whitelisted:
            is_whitelisted = True
        else:
            # Check parent domains (e.g., api.github.com matches *.github.com)
            parts = domain.split('.')
            for i in range(1, len(parts)):
                parent = '.'.join(parts[i:])
                if parent in whitelisted:
                    is_whitelisted = True
                    break

        if is_whitelisted:
            allowed[domain] = count
        else:
            blocked[domain] = count

    return blocked, allowed

def suggest_additions(blocked, whitelisted, threshold=3):
    """Suggest domains to add to whitelist based on frequency"""
    suggestions = {}

    for domain, count in blocked.items():
        if count >= threshold:
            # Extract base domain for grouping
            parts = domain.split('.')
            if len(parts) >= 2:
                base = '.'.join(parts[-2:])  # e.g., github.com from api.github.com
                if base not in whitelisted:
                    suggestions[domain] = count

    return suggestions

def display_report(blocked, allowed, suggestions, whitelisted):
    """Display discovery report"""
    print("\n" + "="*60)
    print(f"DNS Discovery Report - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

    print(f"\n📊 Statistics:")
    print(f"  Whitelisted domains: {len(whitelisted)}")
    print(f"  Unique queries: {len(blocked) + len(allowed)}")
    print(f"  Blocked domains: {len(blocked)}")
    print(f"  Allowed domains: {len(allowed)}")

    if suggestions:
        print(f"\n✓ Suggested additions ({len(suggestions)} domains):")
        print("  (Domains queried frequently but not whitelisted)")
        for domain in sorted(suggestions.keys(), key=lambda x: suggestions[x], reverse=True):
            count = suggestions[domain]
            print(f"    • {domain} (queried {count}x)")
    else:
        print(f"\n✓ No new suggestions at this time")

    if allowed:
        print(f"\n✓ Recently allowed domains (sample):")
        for domain in sorted(allowed.keys(), key=lambda x: allowed[x], reverse=True)[:10]:
            count = allowed[domain]
            print(f"    • {domain} ({count}x)")

    if blocked:
        print(f"\n✗ Blocked domains (top 10):")
        for domain in sorted(blocked.keys(), key=lambda x: blocked[x], reverse=True)[:10]:
            count = blocked[domain]
            print(f"    • {domain} (blocked {count}x)")

    print("\n" + "="*60)

def add_to_whitelist(domain, ip="140.82.113.4"):
    """Add domain to whitelist (requires confirmation)"""
    try:
        response = input(f"\nAdd '{domain}' to whitelist? (y/n): ").strip().lower()
        if response == 'y':
            with open(WHITELIST_FILE, 'a') as f:
                f.write(f"{ip} {domain}\n")
            print(f"✓ Added {domain} to whitelist")
            return True
    except Exception as e:
        print(f"Error adding domain: {e}")
    return False

def main():
    print("🔍 Scanning CoreDNS logs for domain queries...")

    # Get current whitelist
    whitelisted = get_whitelisted_domains()
    print(f"📋 Current whitelist: {len(whitelisted)} domains")

    # Get recent queries
    queries = get_recent_queries()
    if not queries:
        print("No recent queries found. Try accessing some websites first.")
        return

    print(f"📊 Found {len(queries)} unique domain queries")

    # Categorize
    blocked, allowed = categorize_domains(queries, whitelisted)

    # Get suggestions
    suggestions = suggest_additions(blocked, whitelisted, threshold=2)

    # Display report
    display_report(blocked, allowed, suggestions, whitelisted)

    # Offer to add suggestions
    if suggestions and len(sys.argv) > 1 and sys.argv[1] == '--interactive':
        print("\nInteractive mode: Add domains one by one")
        for domain in sorted(suggestions.keys(), key=lambda x: suggestions[x], reverse=True):
            if add_to_whitelist(domain):
                print("Restarting CoreDNS...")
                subprocess.run(["sudo", "systemctl", "restart", "coredns"], check=False)

if __name__ == "__main__":
    main()
