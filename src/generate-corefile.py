#!/usr/bin/env python3
"""
Generate CoreDNS Corefile from redirect configuration
Supports dynamic redirect targets for different environments
"""

import yaml
import sys
import argparse
from pathlib import Path

def load_config(config_file):
    """Load redirect configuration"""
    try:
        with open(config_file, 'r') as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        print(f"Error: Config file not found: {config_file}", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"Error parsing config: {e}", file=sys.stderr)
        sys.exit(1)

def resolve_ip(config, target_domain):
    """Get IP address for redirect target"""
    # Check if it's in targets
    if 'targets' in config and target_domain in config['targets']:
        return config['targets'][target_domain]['ip']

    # Check if it's an IP directly
    if '.' in target_domain and target_domain.count('.') == 3:
        return target_domain

    # Default: try to resolve (would need DNS lookup in real scenario)
    return "140.82.113.4"  # Default to GitHub

def generate_corefile(config, environment=None, output_file=None):
    """Generate CoreDNS Corefile from config"""

    # Select environment or use default
    if environment and 'environments' in config and environment in config['environments']:
        env_config = config['environments'][environment]
        default_target = env_config.get('default_target', config['redirect']['default_target'])
        print(f"Using environment: {environment}", file=sys.stderr)
    else:
        default_target = config['redirect']['default_target']

    # Resolve IP for default target
    default_ip = resolve_ip(config, default_target)

    # Get whitelisted domains
    whitelist_domains = config['redirect'].get('whitelist', {}).get('domains', [])
    if 'whitelist' in config and 'domains' in config['whitelist']:
        whitelist_domains = config['whitelist']['domains']

    # Start generating Corefile
    corefile = """.:53 {
    log stdout

    # LAYER 1: CoreDNS Redirect Mode
    # Whitelisted domains resolve normally
    rewrite stop {
"""

    # Add whitelisted domains
    for domain in whitelist_domains:
        domain_escaped = domain.replace('.', '\\.')
        corefile += f'        name regex ^(.*\\.)?{domain_escaped}$ answer "NOCHANGE"\n'

    corefile += "    }\n\n"

    # Add category-based redirects if enabled
    if config['redirect'].get('categories'):
        categories = config['redirect']['categories']
        for category, settings in categories.items():
            pattern = settings.get('pattern', '')
            redirect_target = settings.get('redirect_to', default_target)
            redirect_ip = resolve_ip(config, redirect_target)
            description = settings.get('description', category)

            if pattern:
                corefile += f'    # {description}\n'
                corefile += f'    rewrite name regex {pattern} answer {redirect_ip}.\n\n'

    # Default redirect for everything else
    corefile += f"""    # Default redirect for non-whitelisted domains
    rewrite name regex ^.*$ answer {default_ip}.

    # Forward whitelisted domains
    forward . 8.8.8.8 1.1.1.1

    # Cache responses
    cache 30

    # Prometheus metrics
    prometheus 127.0.0.1:9253
}}
"""

    # Output
    if output_file:
        with open(output_file, 'w') as f:
            f.write(corefile)
        print(f"✓ Generated: {output_file}", file=sys.stderr)
    else:
        print(corefile)

    # Print summary
    print(f"\n=== Configuration Summary ===", file=sys.stderr)
    print(f"Whitelisted domains: {', '.join(whitelist_domains)}", file=sys.stderr)
    print(f"Default redirect target: {default_target} ({default_ip})", file=sys.stderr)
    if config['redirect'].get('categories'):
        print(f"Categories: {', '.join(config['redirect']['categories'].keys())}", file=sys.stderr)

def main():
    parser = argparse.ArgumentParser(
        description='Generate CoreDNS Corefile from redirect configuration'
    )
    parser.add_argument(
        '--config',
        default='/etc/falco-firewall/redirect-config.yaml',
        help='Path to redirect config file'
    )
    parser.add_argument(
        '--environment',
        choices=['office', 'school', 'home', 'development'],
        help='Environment (uses predefined settings)'
    )
    parser.add_argument(
        '--redirect-to',
        help='Override default redirect target'
    )
    parser.add_argument(
        '--output',
        help='Output file (default: stdout)'
    )

    args = parser.parse_args()

    # Load config
    config = load_config(args.config)

    # Override redirect target if specified
    if args.redirect_to:
        config['redirect']['default_target'] = args.redirect_to

    # Generate Corefile
    generate_corefile(config, args.environment, args.output)

if __name__ == '__main__':
    main()
