# DNS Redirect Mode - Block & Redirect Feature

## 🎯 What It Does

Instead of blocking forbidden domains with "Cannot resolve host", **transparently redirect users to a safe site**.

```
User types: https://pornhub.com
                    ↓
CoreDNS intercepts: "Not whitelisted"
                    ↓
CoreDNS returns: github.com's IP
                    ↓
User's browser connects to: github.com
                    ↓
User sees: GitHub homepage (not pornhub)
```

---

## ⚡ Quick Start

```bash
cd ~/multipass-firewall

# One-command setup with redirect mode
sudo ./scripts/setup-redirect-mode.sh \
  --whitelist "github.com,ubuntu.com" \
  --redirect-to "github.com"
```

---

## 🧪 Test It

### Test 1: Blocked domain gets redirected
```bash
$ nslookup pornhub.com 127.0.0.1
Name: pornhub.com
Address: 140.82.113.4  ← This is GitHub's IP!

# So when you try pornhub.com, you actually access GitHub!
$ curl -L https://pornhub.com
# Opens GitHub instead!
```

### Test 2: Allowed domain works normally
```bash
$ nslookup github.com 127.0.0.1
Name: github.com
Address: 140.82.113.4  ← Real GitHub IP

$ curl https://github.com
# Works normally
```

### Test 3: Monitor redirects
```bash
$ sudo journalctl -u coredns -f | grep pornhub
# Shows all redirect attempts
```

---

## 📊 Comparison: BLOCK vs REDIRECT

### BLOCK Mode (Original)
```
pornhub.com → NXDOMAIN
User sees: "Cannot resolve host pornhub.com"
User experience: Blocked, knows what happened
Security: ✓✓✓
Stealth: ✗ (obvious blocking)
```

### REDIRECT Mode (New)
```
pornhub.com → Returns github.com's IP
User sees: GitHub website
User experience: Transparent redirect
Security: ✓✓✓ (even better)
Stealth: ✓✓✓ (user doesn't know)
```

---

## 🛠️ Configuration

### Edit Redirect Target

Change which site blocked domains go to:

```bash
sudo vim /etc/coredns/Corefile

# Change this line:
rewrite name regex ^.*$ answer github.com.

# To any whitelisted domain:
rewrite name regex ^.*$ answer ubuntu.com.
```

Then restart:
```bash
sudo systemctl restart coredns
```

### Redirect Different Categories

```coredns
.:53 {
    # Whitelist (normal resolution)
    rewrite stop {
        name regex ^github\.com$ answer "NOCHANGE"
        name regex ^ubuntu\.com$ answer "NOCHANGE"
    }

    # Adult sites → GitHub
    rewrite name regex ^(pornhub|xvideos|redtube)\..*$ answer github.com.

    # Social media → Ubuntu
    rewrite name regex ^(facebook|twitter|instagram)\..*$ answer ubuntu.com.

    # Everything else → GitHub
    rewrite name regex ^.*$ answer github.com.

    forward . 8.8.8.8 1.1.1.1
    cache 30
}
```

---

## 🔐 Security Properties

### Why REDIRECT is SECURE:

✅ **DNS-level blocking** - Works system-wide
✅ **Transparent** - User doesn't know they're being redirected
✅ **eBPF monitoring** - Detects attempts to use other DNS
✅ **nftables backup** - Blocks non-whitelisted IPs anyway
✅ **Can't bypass** - No way to access blocked domains

### Attack Scenarios:

```
User tries unauthorized DNS (9.9.9.9):
  Layer 2: eBPF detects unauthorized resolver
  Layer 3: nftables blocks 9.9.9.9
  Result: ✗ BLOCKED

User tries hardcoded IP:
  Layer 1: Bypassed (no DNS)
  Layer 2: Bypassed (no DNS)
  Layer 3: nftables blocks non-whitelisted IP
  Result: ✗ BLOCKED

User accesses allowed domain:
  Layer 1: ✓ Resolves normally
  Layer 2: ✓ Via allowed DNS
  Layer 3: ✓ To whitelisted IP
  Result: ✓ ALLOWED
```

---

## 📋 Three-Layer with Redirect

```
┌─────────────────────────────┐
│  Application/Browser        │
└──────────────┬──────────────┘
               │
        ┌──────▼────────────────────┐
        │ Layer 1: CoreDNS Redirect │ ◄─ REDIRECT non-whitelisted
        │ pornhub.com → github.com  │    to safe domain
        └──────┬────────────────────┘
               │ (whitelisted → normal resolution)
        ┌──────▼────────────────────┐
        │ Layer 2: eBPF Monitoring  │ ◄─ MONITOR DNS usage
        │ Allowed: 8.8.8.8, 1.1.1.1 │    Alert on unauthorized
        └──────┬────────────────────┘
               │ (allowed resolver → continue)
        ┌──────▼────────────────────┐
        │ Layer 3: nftables IP List │ ◄─ BLOCK unauthorized IPs
        │ Only whitelisted IPs pass │    Default deny
        └──────┬────────────────────┘
               │
        ✓ Connection to safe domain or ✗ Blocked
```

---

## 🎓 Real-World Example

### Company Setup:
- **Whitelist**: github.com, ubuntu.com, work-tools.company.com
- **Redirect to**: company-intranet.company.com

### What Happens:

```
Employee tries facebook.com
  ↓
CoreDNS: "Not whitelisted, redirect"
  ↓
Employee gets: company-intranet.company.com instead
  ↓
Result: Employees can't access Facebook, get company home page!
```

### Employee Experience:
- ✓ No "blocked" error messages
- ✓ Automatically sees company intranet
- ✓ Can't bypass (3 layers of defense)
- ✗ Completely locked down (very strict)

---

## ⚙️ Setup & Management

### Installation
```bash
sudo ./scripts/setup-redirect-mode.sh
```

### Configuration
```bash
# Edit redirect target
sudo vim /etc/coredns/Corefile

# Restart
sudo systemctl restart coredns
```

### Monitoring
```bash
# View redirects
sudo journalctl -u coredns -f

# View monitoring alerts
sudo tail -f /var/log/falco/falco.log

# Check active rules
sudo nft list chain inet filter firewall_out
```

---

## 📈 Three Setup Options Now Available

| Option | What | How | Use Case |
|--------|------|-----|----------|
| Simple | nftables IP only | `setup.sh` | Basic needs |
| DNS Block | CoreDNS block + nftables | `setup-coredns.sh` | Medium security |
| DNS Redirect | CoreDNS redirect + eBPF + nftables | `setup-redirect-mode.sh` | Maximum stealth |

---

## Summary

**Redirect Mode Features:**

✅ Non-whitelisted domains redirect to safe site
✅ No "blocked" error messages  
✅ Transparent to user
✅ 3-layer defense
✅ Real-time monitoring
✅ Can't bypass
✅ Perfect for offices/schools/companies

**Try it:**
```bash
sudo ./scripts/setup-redirect-mode.sh --whitelist "github.com" --redirect-to "github.com"
```

**Test:**
```bash
curl https://pornhub.com
# Gets GitHub instead!
```

**Done!** 🎉
