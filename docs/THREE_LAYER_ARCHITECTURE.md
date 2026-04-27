# Three-Layer Firewall Architecture

## Defense in Depth: CoreDNS + eBPF + nftables

```
                    Application
                         │
        ┌────────────────┼────────────────┐
        │                │                │
   Layer 1          Layer 2            Layer 3
 (CoreDNS)          (eBPF)           (nftables)
   DNS             Monitoring        IP Filtering
 Whitelist         DNS Resolvers      Whitelist
 Domains           IP Tracking         IPs Only
   Only              Monitor            Only
```

---

## Layer 1: CoreDNS (Domain Whitelisting)

**Purpose:** Only whitelisted domains resolve

```yaml
Whitelisted Domains:
  ✓ github.com
  ✓ ubuntu.com
  ✓ registry.npmjs.org
  ✓ pypi.org

Blocked (Any other domain):
  ✗ pornhub.com → NXDOMAIN
  ✗ facebook.com → NXDOMAIN
  ✗ twitter.com → NXDOMAIN
  ✗ example.com → NXDOMAIN
```

**How it works:**
```
1. curl https://github.com
2. DNS Query: "What is github.com?"
3. CoreDNS: "Yes, I know → 140.82.113.4"
4. Return: IP address (allowed to proceed to Layer 2)

1. curl https://pornhub.com
2. DNS Query: "What is pornhub.com?"
3. CoreDNS: "I don't know (NXDOMAIN)"
4. Application fails immediately → BLOCKED
```

---

## Layer 2: eBPF (DNS Resolver Monitoring)

**Purpose:** Monitor which DNS resolvers are being used

```
Allowed DNS Resolvers:
  ✓ 1.1.1.1 (Cloudflare)     - PRIMARY
  ✓ 8.8.8.8 (Google)         - FALLBACK

Denied DNS Resolvers:
  ✗ 9.9.9.9 (Quad9)          - ALERT
  ✗ 208.67.222.222 (OpenDNS) - ALERT
  ✗ Any other resolver       - ALERT
```

**eBPF Monitoring:**
```
Detect DNS packets going to:
  → 1.1.1.1:53 ✓ (Allowed, log)
  → 8.8.8.8:53 ✓ (Allowed, log)
  → Any other   ✗ (Blocked, alert)
```

**Real-time Visibility:**
```
[DNS Query] github.com → Resolver: 1.1.1.1:53 → Log: "OK"
[DNS Query] ubuntu.com → Resolver: 8.8.8.8:53 → Log: "OK"
[DNS Query] blocked.com → Resolver: 9.9.9.9:53 → Alert: "Unauthorized DNS"
```

---

## Layer 3: nftables (IP Whitelisting)

**Purpose:** Only whitelisted IPs can be reached

```
Allowed IPs/Ranges:
  ✓ 140.82.113.4/32       (github.com)
  ✓ 185.125.190.81/32     (ubuntu.com)
  ✓ 104.16.8.34/32        (npmjs.org)
  ✓ 151.101.0.223/32      (pypi.org)
  ✓ 1.1.1.1:53            (Cloudflare DNS)
  ✓ 8.8.8.8:53            (Google DNS)
  ✓ 127.0.0.1             (Localhost)

Blocked (Default):
  ✗ 1.2.3.4               (Unknown IP)
  ✗ 9.9.9.9               (Unauthorized resolver)
  ✗ Everything else       (Default deny)
```

---

## Attack Scenarios & How They're Blocked

### Scenario 1: User tries to access pornhub.com
```
Attack Method: Direct domain access
curl https://pornhub.com

Defense:
Layer 1 (CoreDNS): ✓ BLOCKS
  → "What is pornhub.com?"
  → "I don't know (NXDOMAIN)"
  → Immediate failure

Result: ✗ BLOCKED (never gets to Layer 2 or 3)
```

### Scenario 2: User uses unauthorized DNS resolver
```
Attack Method: Configure system DNS to 9.9.9.9
$ nslookup github.com 9.9.9.9

Defense:
Layer 2 (eBPF): ✓ DETECTS & BLOCKS
  → eBPF sees: "DNS query to 9.9.9.9:53"
  → Alert: "Unauthorized DNS resolver detected"
  → nftables drops packet

Layer 3 (nftables): ✓ BLOCKS
  → 9.9.9.9:53 not in whitelist
  → Connection refused

Result: ✗ BLOCKED (detected at Layer 2, blocked at Layer 3)
```

### Scenario 3: User hardcodes IP address
```
Attack Method: Bypass DNS entirely
curl https://1.2.3.4 (attacker's IP)

Defense:
Layer 1 (CoreDNS): Bypassed (no DNS query)
Layer 2 (eBPF): Bypassed (no DNS query)
Layer 3 (nftables): ✓ BLOCKS
  → 1.2.3.4 not in IP whitelist
  → nftables drops packet

Result: ✗ BLOCKED (blocked at Layer 3)
```

### Scenario 4: User accesses allowed domain via allowed resolver
```
Normal Operation: curl https://github.com

Defense:
Layer 1 (CoreDNS): ✓ ALLOWS
  → "What is github.com?"
  → "Yes, 140.82.113.4"

Layer 2 (eBPF): ✓ ALLOWS
  → DNS resolver is 8.8.8.8:53 (whitelisted)
  → Log: "DNS query via 8.8.8.8"

Layer 3 (nftables): ✓ ALLOWS
  → 140.82.113.4:443 in whitelist
  → Connection succeeds

Result: ✓ ALLOWED (passes all 3 layers)
```

---

## Data Flow with All 3 Layers

```
┌─────────────────────────────────────────────────┐
│ User: curl https://github.com                   │
└──────────────┬──────────────────────────────────┘
               │
        ┌──────▼──────────────┐
        │ Layer 1: CoreDNS    │ Whitelist: github.com ✓
        │ Check domain        │ Return: 140.82.113.4
        └──────┬──────────────┘
               │ (if domain whitelisted)
        ┌──────▼──────────────────────┐
        │ Layer 2: eBPF               │ Monitor DNS resolver
        │ Which resolver was used?    │ Allowed: 8.8.8.8, 1.1.1.1
        │ Was it 8.8.8.8 or 1.1.1.1? │ Log: "8.8.8.8:53 ✓"
        └──────┬──────────────────────┘
               │ (if resolver whitelisted)
        ┌──────▼──────────────────────┐
        │ Layer 3: nftables           │ Whitelist: 140.82.113.4 ✓
        │ Check IP in whitelist       │ Allow: TCP/443
        └──────┬──────────────────────┘
               │
        ┌──────▼──────────────┐
        │ Connection Allowed  │ ✓ Successfully accessed github.com
        │ HTTP 200 OK         │
        └─────────────────────┘
```

---

## Implementation Details

### CoreDNS Configuration

```coredns
# /etc/coredns/Corefile
.:53 {
    # Layer 1: Whitelist domains only
    rewrite stop {
        name regex ^github\.com$ answer "NOCHANGE"
        name regex ^ubuntu\.com$ answer "NOCHANGE"
        name regex ^registry\.npmjs\.org$ answer "NOCHANGE"
        name regex ^pypi\.org$ answer "NOCHANGE"
    }

    # Block everything else
    rewrite name regex ^.*$ NXDOMAIN

    # Forward only whitelisted domains
    forward . 8.8.8.8 8.8.4.4

    # Cache
    cache 30

    # Metrics
    prometheus 127.0.0.1:9253
}
```

### eBPF Monitoring (Falco)

```yaml
# /etc/falco/rules.d/dns-monitoring.yaml
- rule: DNS Query via Authorized Resolver
  desc: Monitor DNS queries to 8.8.8.8 or 1.1.1.1
  condition: >
    outbound and
    fd.sport = 53 and
    fd.dip in (8.8.8.8, 1.1.1.1)
  output: >
    DNS Query (Authorized)
    (resolver=%fd.dip process=%proc.name pid=%proc.pid)
  priority: DEBUG

- rule: DNS Query via Unauthorized Resolver
  desc: ALERT - DNS query to non-whitelisted resolver
  condition: >
    outbound and
    fd.sport = 53 and
    fd.dip not in (8.8.8.8, 1.1.1.1, 127.0.0.1)
  output: >
    SECURITY ALERT - Unauthorized DNS Resolver!
    (resolver=%fd.dip process=%proc.name pid=%proc.pid)
  priority: WARNING
```

### nftables IP Whitelisting

```nftables
# /etc/nftables/firewall.nft
table inet filter {
    chain firewall_out {
        type filter hook output priority filter; policy drop;

        # Layer 3: Whitelist IPs only

        # Allow DNS to whitelisted resolvers
        ip daddr 8.8.8.8 udp dport 53 accept
        ip daddr 1.1.1.1 udp dport 53 accept

        # Allow whitelisted service IPs
        ip daddr 140.82.113.4 tcp dport 443 accept    # github.com
        ip daddr 185.125.190.81 tcp dport {80,443} accept # ubuntu.com
        ip daddr 104.16.8.34 tcp dport 443 accept     # npmjs.org
        ip daddr 151.101.0.223 tcp dport 443 accept   # pypi.org

        # Allow localhost
        ip daddr 127.0.0.1 accept

        # Reject everything else
        reject with icmp type host-unreachable
    }
}
```

---

## Summary: Three Layers

| Layer | Technology | Purpose | Action |
|-------|-----------|---------|--------|
| **1** | CoreDNS | Domain filtering | Returns NXDOMAIN for bad domains |
| **2** | eBPF | DNS resolver monitoring | Logs/alerts on unauthorized DNS |
| **3** | nftables | IP whitelisting | Drops packets to non-whitelisted IPs |

---

## Benefits

✅ **Domain Level:** Block at DNS (prevents resolution)
✅ **Resolver Level:** Monitor which DNS servers are used
✅ **IP Level:** Backup filter (defense in depth)
✅ **Transparent:** Users see DNS failures for blocked domains
✅ **Monitoring:** Full visibility into DNS usage
✅ **Security:** Three layers = maximum protection
✅ **Performance:** DNS blocking is fastest

---

## Testing All Layers

### Test 1: Layer 1 (Domain Blocking)
```bash
$ nslookup pornhub.com 127.0.0.1
** server can't find pornhub.com: NXDOMAIN
✓ Layer 1 BLOCKED
```

### Test 2: Layer 2 (Resolver Monitoring)
```bash
# Check eBPF logs
sudo tail -f /var/log/falco/falco.log | grep "DNS Query"
✓ Shows which resolver was used
```

### Test 3: Layer 3 (IP Whitelisting)
```bash
$ curl http://192.0.2.1  # Random non-whitelisted IP
curl: (7) Failed to connect
✓ Layer 3 BLOCKED
```

### Test 4: All Layers Pass
```bash
$ curl https://github.com
✓ Passes Domain check (Layer 1)
✓ Via allowed resolver (Layer 2)
✓ To whitelisted IP (Layer 3)
✓ SUCCESS
```
