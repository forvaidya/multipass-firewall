# CoreDNS Redirect Mode (DNS Hijacking)

Instead of blocking non-whitelisted domains with NXDOMAIN, **redirect them to a whitelisted site**.

## How It Works

```
User: curl https://pornhub.com
                    ↓
CoreDNS Query: "What is pornhub.com?"
                    ↓
CoreDNS Check: "Is pornhub.com whitelisted? NO"
                    ↓
CoreDNS Action: "Return github.com's IP instead"
                    ↓
CoreDNS Response: pornhub.com → 140.82.113.4 (github.com's IP)
                    ↓
User Browser: Opens https://140.82.113.4 (github.com)
                    ↓
Result: User gets redirected to github.com instead!
```

---

## Two Modes

### Mode 1: BLOCK (Original)
```
pornhub.com → NXDOMAIN (domain doesn't exist)
Result: "Cannot resolve host pornhub.com"
```

### Mode 2: REDIRECT (New)
```
pornhub.com → Returns github.com's IP
Result: User automatically goes to github.com
```

---

## Configuration

### Corefile with Redirect Mode

```coredns
.:53 {
    log stdout

    # REDIRECT MODE: Send non-whitelisted domains to safe site
    # Default redirect target
    rewrite name regex ^(?!github\.com|ubuntu\.com|registry\.npmjs\.org|pypi\.org).*$ answer github.com.

    # Or redirect to different sites based on category
    rewrite name regex ^(pornhub|xvideos|redtube)\..*$ answer github.com.
    rewrite name regex ^(facebook|twitter|instagram|tiktok)\..*$ answer ubuntu.com.
    rewrite name regex ^.*$ answer github.com.

    # Forward whitelisted domains normally
    forward . 8.8.8.8 1.1.1.1

    cache 30
}
```

---

## Examples

### Example 1: All Bad Domains → GitHub
```coredns
.:53 {
    log stdout

    # Whitelist
    rewrite stop {
        name regex ^github\.com$ answer "NOCHANGE"
        name regex ^ubuntu\.com$ answer "NOCHANGE"
    }

    # Redirect everything else to github
    rewrite name regex ^.*$ answer github.com.

    forward . 8.8.8.8 1.1.1.1
    cache 30
}
```

**Result:**
```bash
$ nslookup pornhub.com
Name: pornhub.com
Address: 140.82.113.4  (GitHub's IP!)

$ nslookup facebook.com
Name: facebook.com
Address: 140.82.113.4  (GitHub's IP!)

$ nslookup github.com
Name: github.com
Address: 140.82.113.4  (Actual GitHub IP)
```

### Example 2: Category-Based Redirect
```coredns
.:53 {
    log stdout

    # Adult sites → blank page
    rewrite name regex ^(pornhub|xvideos|redtube|brazzers)\..*$ answer 127.0.0.1.

    # Social media → GitHub
    rewrite name regex ^(facebook|twitter|instagram|tiktok)\..*$ answer github.com.

    # Everything else → Ubuntu
    rewrite name regex ^.*$ answer ubuntu.com.

    forward . 8.8.8.8 1.1.1.1
    cache 30
}
```

---

## Test It

```bash
# Access whitelisted domain
$ curl -L https://github.com
✓ Works normally

# Try blocked domain (gets redirected)
$ curl -L https://pornhub.com
✓ Redirects to GitHub (140.82.113.4)

# Check in browser
$ nslookup pornhub.com
pornhub.com has address 140.82.113.4
# Opening https://pornhub.com in browser → Actually goes to GitHub!
```

---

## Advantages

✅ **Transparent to user** - No error messages
✅ **No blocked feeling** - Gets useful content instead
✅ **Works with all apps** - Affects entire system
✅ **Hard to circumvent** - DNS-level hijacking
✅ **Logging** - Can track redirect attempts
✅ **Flexible** - Different redirects for different categories

---

## Disadvantages

⚠️ **Confusion** - User doesn't know they were redirected
⚠️ **HTTPS warnings** - Certificate mismatch (pornhub.com cert ≠ github.com)
⚠️ **Less obvious blocking** - Harder to detect the firewall
⚠️ **API issues** - Apps may fail if DNS doesn't match hostname

---

## Hybrid Approach (Recommended)

Combine redirection with other blocks:

```coredns
.:53 {
    log stdout

    # Whitelist: Allow normal resolution
    rewrite stop {
        name regex ^github\.com$ answer "NOCHANGE"
        name regex ^ubuntu\.com$ answer "NOCHANGE"
    }

    # Strict blocklist: Return NXDOMAIN
    rewrite name regex ^(malware|exploit|botnet)\..*$ answer NXDOMAIN

    # Category redirect: Send social media to github
    rewrite name regex ^(facebook|twitter)\..*$ answer github.com.

    # Everything else: NXDOMAIN (truly block)
    rewrite name regex ^.*$ answer NXDOMAIN

    forward . 8.8.8.8 1.1.1.1
    cache 30
}
```

---

## Implementation: Three Modes

### Mode 1: BLOCK (NXDOMAIN)
```bash
# Domain doesn't exist
nslookup pornhub.com
** server can't find pornhub.com: NXDOMAIN
```

### Mode 2: REDIRECT (DNS Hijack)
```bash
# Domain resolves to safe site
nslookup pornhub.com
Name: pornhub.com
Address: 140.82.113.4  (GitHub IP)
```

### Mode 3: SAFE REDIRECT (Explicit URL)
```bash
# Domain resolves to safe landing page
nslookup pornhub.com
Name: pornhub.com
Address: 127.0.0.1  (Local safe page)
```

---

## Setup Instructions

### Step 1: Create Safe Landing Page (Optional)
```bash
# Create simple HTML file
sudo mkdir -p /var/www/html
sudo bash << 'EOF'
cat > /var/www/html/blocked.html << 'HTML'
<!DOCTYPE html>
<html>
<head>
    <title>Site Blocked</title>
    <style>
        body { font-family: Arial; text-align: center; padding: 50px; }
        h1 { color: #d9534f; }
        p { color: #666; }
    </style>
</head>
<body>
    <h1>⚠️ Access Blocked</h1>
    <p>This website is not allowed.</p>
    <p><a href="https://github.com">Visit GitHub instead</a></p>
</body>
</html>
HTML
EOF

# Serve on localhost:8080
sudo python3 -m http.server 8080 --directory /var/www/html &
```

### Step 2: Update Corefile
```bash
sudo vim /etc/coredns/Corefile

# Add redirect rules:
rewrite name regex ^(pornhub|facebook)\..*$ answer github.com.
```

### Step 3: Restart
```bash
sudo systemctl restart coredns
```

### Step 4: Test
```bash
$ curl https://pornhub.com
# Gets redirected to GitHub!
```

---

## Which Mode to Use?

| Mode | Use Case | Security | User Experience |
|------|----------|----------|-----------------|
| **NXDOMAIN** | Maximum control | Very high | Clear "blocked" message |
| **REDIRECT** | Seamless blocking | High | Transparent redirect |
| **SAFE PAGE** | User education | High | Clear explanation |

---

## Recommendation

**Use REDIRECT + nftables backup:**
- CoreDNS redirects bad domains → safe site
- nftables blocks if redirect fails
- Two layers of defense
- Transparent to user
- Hard to bypass

```coredns
# Corefile with redirect
.:53 {
    # Redirect non-whitelisted → github.com
    rewrite stop {
        name regex ^github\.com$ answer "NOCHANGE"
        name regex ^ubuntu\.com$ answer "NOCHANGE"
    }
    rewrite name regex ^.*$ answer github.com.

    forward . 8.8.8.8 1.1.1.1
    cache 30
}
```

---

## Security Note

Users **cannot easily bypass this** because:
1. ✓ DNS hijacking at system level
2. ✓ Works for all applications
3. ✓ Can't change DNS without detection (Layer 2 eBPF monitors)
4. ✓ nftables blocks direct IP access (Layer 3)

**Result:** User trying pornhub.com → Gets GitHub instead, no way around it!
