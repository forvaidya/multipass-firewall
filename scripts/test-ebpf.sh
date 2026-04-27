#!/bin/bash
# eBPF Firewall Test Suite

set -e

IFACE=$(ip route | awk '/default/{print $5}')
LOG_FILE="/var/log/falco-firewall/ebpf-blocked.log"

echo "========================================="
echo "eBPF Firewall Test Suite"
echo "========================================="
echo ""
echo "Interface: $IFACE"
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass_count=0
fail_count=0

test_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ PASS${NC}: $2"
        ((pass_count++))
    else
        echo -e "${RED}✗ FAIL${NC}: $2"
        ((fail_count++))
    fi
}

echo "[1/7] Verify eBPF program is loaded..."
if tc filter show dev "$IFACE" egress 2>/dev/null | grep -q bpf; then
    test_result 0 "eBPF TC classifier attached to $IFACE"
else
    test_result 1 "eBPF TC classifier not found on $IFACE"
fi

echo ""
echo "[2/7] Verify allowed_ips map is populated..."
if command -v bpftool &> /dev/null; then
    count=$(bpftool map dump name allowed_ips 2>/dev/null | wc -l || echo "0")
    if [ "$count" -gt 0 ]; then
        test_result 0 "allowed_ips map has $count entries"
    else
        test_result 1 "allowed_ips map is empty"
    fi
else
    echo -e "${YELLOW}⚠ SKIP${NC}: bpftool not available"
fi

echo ""
echo "[3/7] Test allowed destination (whitelist)..."
if dig @127.0.0.1 registry.npmjs.org +short 2>/dev/null | grep -q "140.82.113.4"; then
    test_result 0 "Whitelisted domain resolves correctly"
else
    test_result 1 "Whitelisted domain resolution failed"
fi

echo ""
echo "[4/7] Test allowed traffic passes through..."
if curl -s --connect-timeout 2 --max-time 3 https://github.com -o /dev/null 2>&1; then
    test_result 0 "Connection to whitelisted IP successful"
else
    test_result 1 "Connection to whitelisted IP failed"
fi

echo ""
echo "[5/7] Test blocked destination is dropped..."
# Try to connect to a non-whitelisted IP
if timeout 3 curl -s http://1.1.1.2 > /dev/null 2>&1; then
    test_result 1 "Non-whitelisted IP should be blocked"
else
    test_result 0 "Non-whitelisted IP was blocked (connection timeout/refused)"
fi

echo ""
echo "[6/7] Verify eBPF logs blocked attempts..."
if [ -f "$LOG_FILE" ]; then
    if grep -q "blocked" "$LOG_FILE" 2>/dev/null; then
        count=$(grep -c "blocked" "$LOG_FILE" 2>/dev/null || echo "0")
        test_result 0 "Found $count blocked events in log"
        echo "    Last entry:"
        tail -1 "$LOG_FILE" | python3 -m json.tool 2>/dev/null || tail -1 "$LOG_FILE"
    else
        test_result 1 "No blocked events found in log yet"
    fi
else
    test_result 1 "Log file not found: $LOG_FILE"
fi

echo ""
echo "[7/7] Verify nftables backup layer is active..."
if nft list chain inet filter firewall_out 2>/dev/null | grep -q "reject"; then
    test_result 0 "nftables safety net is active"
else
    test_result 1 "nftables rules not found"
fi

echo ""
echo "========================================="
echo "Test Results: ${GREEN}$pass_count passed${NC}, ${RED}$fail_count failed${NC}"
echo "========================================="
echo ""

if [ $fail_count -eq 0 ]; then
    echo "✓ All tests passed! eBPF enforcement is working."
    exit 0
else
    echo "✗ Some tests failed. Check the setup and logs."
    exit 1
fi
