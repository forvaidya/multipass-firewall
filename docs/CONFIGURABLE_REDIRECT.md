# Configurable DNS Redirect - Multiple Environments

Redirect non-whitelisted domains to **different safe sites depending on your environment**.

## 🎯 Use Cases

### Office Environment
```
Whitelisted: company.com, github.com
Redirect target: intranet.company.com
Result: Employees trying Facebook → See company intranet instead
```

### School Environment
```
Whitelisted: school.edu, github.com
Redirect target: school-portal.edu
Result: Students trying YouTube → See school portal instead
```

### Home Environment
```
Whitelisted: github.com, ubuntu.com
Redirect target: github.com
Result: Try Facebook → See GitHub instead
```

### Development Environment
```
Whitelisted: (anything)
Redirect target: localhost:8000
Result: Non-whitelisted → Local dev server
```

---

## 🚀 Quick Start

### Option 1: Use Predefined Environment

```bash
# Office setup - redirects to company intranet
sudo ./scripts/setup-configurable-redirect.sh --environment office

# School setup - redirects to school portal
sudo ./scripts/setup-configurable-redirect.sh --environment school

# Home setup - redirects to GitHub
sudo ./scripts/setup-configurable-redirect.sh --environment home
```

### Option 2: Custom Redirect Target

```bash
# Redirect all blocked domains to company intranet
sudo ./scripts/setup-configurable-redirect.sh --redirect-to "intranet.company.com"

# Redirect to local server
sudo ./scripts/setup-configurable-redirect.sh --redirect-to "192.168.1.50"

# Redirect with custom whitelist
sudo ./scripts/setup-configurable-redirect.sh \
  --redirect-to "intranet.company.com" \
  --whitelist "company.com,github.com,gmail.com"
```

---

## 📋 Configuration File

Edit `/etc/falco-firewall/redirect-config.yaml`:

```yaml
redirect:
  enabled: true
  default_target: "intranet.company.com"

environments:
  office:
    default_target: "intranet.company.com"
    categories:
      adult:
        redirect_to: "intranet.company.com"
      social_media:
        redirect_to: "intranet.company.com"

  school:
    default_target: "school-portal.edu"

  home:
    default_target: "github.com"

targets:
  intranet.company.com:
    ip: "10.0.1.100"
    type: "private"
```

---

## 🔄 Change Redirect Target

### Method 1: Edit Config File

```bash
# Edit redirect configuration
sudo vim /etc/falco-firewall/redirect-config.yaml

# Change:
# default_target: "github.com"
# To:
# default_target: "intranet.company.com"

# Regenerate CoreDNS config
sudo python3 /opt/falco-firewall/generate-corefile.py \
  --config /etc/falco-firewall/redirect-config.yaml \
  --redirect-to "intranet.company.com" \
  --output /etc/coredns/Corefile

# Restart CoreDNS
sudo systemctl restart coredns
```

### Method 2: Direct Command

```bash
# Regenerate with new target (doesn't modify config file)
sudo python3 /opt/falco-firewall/generate-corefile.py \
  --config /etc/falco-firewall/redirect-config.yaml \
  --redirect-to "intranet.company.com" \
  --output /etc/coredns/Corefile

# Apply
sudo systemctl restart coredns
```

---

## 🎓 Real-World Examples

### Example 1: Office with Company Intranet

**Setup:**
```bash
sudo ./scripts/setup-configurable-redirect.sh --environment office
```

**Config:**
```yaml
environments:
  office:
    default_target: "intranet.company.com"

whitelist:
  domains:
    - "company.com"
    - "github.com"
    - "google.com"
```

**What Happens:**
```
Employee 1: Tries facebook.com
  ↓
CoreDNS: "Not whitelisted, redirect!"
  ↓
Returns: intranet.company.com IP
  ↓
Employee sees: Company intranet
  ↓
Result: ✓ Can't access Facebook, sees company page!

Employee 2: Tries company.com
  ↓
CoreDNS: "Whitelisted!"
  ↓
Returns: Real company.com IP
  ↓
Employee sees: Company website normally
  ↓
Result: ✓ Works normally!
```

### Example 2: School with Portal

**Setup:**
```bash
sudo ./scripts/setup-configurable-redirect.sh --environment school
```

**What Happens:**
```
Student 1: Tries youtube.com
  ↓
CoreDNS: "Not whitelisted"
  ↓
Returns: school-portal.edu IP
  ↓
Student sees: School portal
  ↓
Result: YouTube redirected to school!

Student 2: Tries school.edu
  ↓
CoreDNS: "Whitelisted!"
  ↓
Returns: Real school.edu IP
  ↓
Student sees: School website
  ↓
Result: Works normally!
```

### Example 3: Home with GitHub

**Setup:**
```bash
sudo ./scripts/setup-configurable-redirect.sh --environment home
```

**What Happens:**
```
Any non-whitelisted domain → GitHub
Perfect for home use!
```

---

## 🛠️ Category-Based Redirects

Redirect different categories to different sites:

```yaml
redirect:
  categories:
    adult:
      pattern: "^(pornhub|xvideos)\\."
      redirect_to: "github.com"

    social_media:
      pattern: "^(facebook|twitter)\\."
      redirect_to: "intranet.company.com"

    gambling:
      pattern: "^(bet365|pokerstars)\\."
      redirect_to: "school-portal.edu"
```

**Result:**
- Adult sites → GitHub
- Social media → Company intranet
- Gambling → School portal
- Everything else → Default target

---

## 🔧 Advanced Configuration

### Custom Local Server

```bash
# Start local server
python3 -m http.server 8000 --directory /var/www/html

# Configure redirect
sudo ./scripts/setup-configurable-redirect.sh \
  --redirect-to "localhost:8000"

# Test
curl https://pornhub.com
# Actually connects to localhost:8000!
```

### Multiple Redirect Targets

```yaml
targets:
  github.com:
    ip: "140.82.113.4"
  intranet.company.com:
    ip: "10.0.1.100"
  school-portal.edu:
    ip: "192.168.1.50"
  localhost:
    ip: "127.0.0.1"

redirect:
  categories:
    adult: github.com
    social_media: intranet.company.com
    gaming: school-portal.edu
    default: github.com
```

---

## 📊 Environment Presets

| Environment | Default Target | Use Case |
|-------------|-----------------|----------|
| `office` | intranet.company.com | Corporate office |
| `school` | school-portal.edu | School/University |
| `home` | github.com | Home/Personal |
| `development` | localhost:8000 | Development |

### Switch Environments

```bash
# Currently on office, switch to school
sudo ./scripts/setup-configurable-redirect.sh --environment school

# Back to office
sudo ./scripts/setup-configurable-redirect.sh --environment office

# Custom
sudo ./scripts/setup-configurable-redirect.sh --redirect-to "my-custom-site.com"
```

---

## 🔄 Regenerate CoreDNS Config

After editing `/etc/falco-firewall/redirect-config.yaml`:

```bash
# Regenerate Corefile from config
sudo python3 /opt/falco-firewall/generate-corefile.py \
  --config /etc/falco-firewall/redirect-config.yaml \
  --environment office \
  --output /etc/coredns/Corefile

# Apply changes
sudo systemctl restart coredns

# Verify
sudo journalctl -u coredns -n 5
```

---

## 📈 Implementation Details

### How It Works:

1. **Load Config:** Read YAML configuration
2. **Select Environment:** Use environment-specific settings
3. **Resolve IPs:** Map target domains to IPs
4. **Generate Rules:** Create CoreDNS rewrite rules
5. **Apply:** Update Corefile and reload CoreDNS

### Code Flow:

```python
# generate-corefile.py
1. Load redirect-config.yaml
2. Select environment (office/school/home)
3. Get default_target and categories
4. Resolve IPs for each target
5. Generate Corefile with rewrite rules
6. Output to /etc/coredns/Corefile
7. CoreDNS reads and applies rules
```

---

## 🎯 Best Practices

✅ **Keep it simple** - Use one redirect target per environment
✅ **Test changes** - Use `nslookup` to verify redirects
✅ **Monitor logs** - Track redirect attempts
✅ **Update whitelist** - Keep allowed domains current
✅ **Use categories** - Different redirects for different content types

---

## 🚨 Troubleshooting

### Redirect not working

```bash
# Check CoreDNS Corefile
sudo cat /etc/coredns/Corefile

# Restart CoreDNS
sudo systemctl restart coredns

# Test DNS resolution
nslookup pornhub.com 127.0.0.1

# Check logs
sudo journalctl -u coredns -f
```

### Wrong redirect target

```bash
# Verify configuration
sudo cat /etc/falco-firewall/redirect-config.yaml

# Check what IP is being used
nslookup intranet.company.com 8.8.8.8

# Update Corefile
sudo python3 /opt/falco-firewall/generate-corefile.py \
  --config /etc/falco-firewall/redirect-config.yaml \
  --output /etc/coredns/Corefile

# Restart
sudo systemctl restart coredns
```

---

## Summary

**Configurable Redirect Features:**

✅ Multiple environment presets (office, school, home, dev)
✅ Custom redirect targets
✅ Category-based redirects
✅ Easy to change without re-installation
✅ Flexible configuration file
✅ Real-time updates

**Perfect for:**
- Offices (redirect to intranet)
- Schools (redirect to portal)
- Homes (redirect to safe site)
- Development (redirect to localhost)

**Try it:**
```bash
# Office setup
sudo ./scripts/setup-configurable-redirect.sh --environment office

# Or custom
sudo ./scripts/setup-configurable-redirect.sh --redirect-to "intranet.company.com"

# Test
nslookup facebook.com 127.0.0.1
# Returns intranet.company.com IP!
```
