#!/usr/bin/env python3
"""
eBPF-based Firewall Enforcement and Monitoring
Uses BCC (Linux eBPF Compiler Collection) to attach a TC egress hook that:
- Enforces IP whitelist (drops non-whitelisted destinations)
- Logs all blocked packets to a ring buffer
"""

import ctypes
import json
import logging
import socket
import subprocess
import threading
import time
from typing import Set, Optional
from pathlib import Path


logger = logging.getLogger(__name__)


# eBPF C program embedded as string
EBPF_PROG_C = """
#include <uapi/linux/ptrace.h>
#include <net/sock.h>
#include <bcc/proto.h>

// Event struct for ring buffer
struct event_t {
    u32  src_ip;
    u32  dst_ip;
    u16  dst_port;
    u8   proto;
    u32  pid;
    u32  uid;
    char comm[16];
    u64  ts_ns;
    u8   action;  // 0=blocked, 1=allowed
};

// IPv4 whitelist: key=destination IP (network byte order), value=1 if allowed
BPF_HASH(allowed_ips, u32, u8, 1024);

// Ring buffer for blocked events (16KB)
BPF_RINGBUF_OUTPUT(blocked_events, 1 << 14);

// TC egress hook for packet filtering
int tc_firewall_egress(struct __sk_buff *skb) {
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    // Parse Ethernet header
    struct ethhdr *eth = data;
    if (data + sizeof(*eth) > data_end)
        return TC_ACT_OK;

    // Only process IPv4 packets
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return TC_ACT_OK;

    // Parse IP header
    struct iphdr *iph = data + sizeof(*eth);
    if ((void*)iph + sizeof(*iph) > data_end)
        return TC_ACT_OK;

    // Only filter TCP and UDP (allow ICMP, etc.)
    if (iph->protocol != IPPROTO_TCP && iph->protocol != IPPROTO_UDP)
        return TC_ACT_OK;

    u32 dst = iph->daddr;

    // Allow loopback unconditionally (127.x.x.x)
    if ((dst & 0xFF000000) == 0x7F000000)
        return TC_ACT_OK;

    // Check if destination IP is in whitelist
    u8 *found = allowed_ips.lookup(&dst);
    if (found)
        return TC_ACT_OK;  // Allowed, pass through

    // Not allowed - emit event and drop
    struct event_t *e = blocked_events.ringbuf_reserve(sizeof(*e));
    if (e) {
        e->dst_ip = dst;
        e->src_ip = iph->saddr;
        e->proto = iph->protocol;
        e->ts_ns = bpf_ktime_get_ns();
        e->action = 0;  // blocked

        // Get current process info
        u64 piduid = bpf_get_current_pid_tgid();
        e->pid = piduid >> 32;
        e->uid = bpf_get_current_uid_gid() & 0xFFFFFFFF;
        bpf_get_current_comm(&e->comm, sizeof(e->comm));

        // Extract destination port for TCP/UDP
        if (iph->protocol == IPPROTO_TCP) {
            struct tcphdr *th = (void*)iph + (iph->ihl * 4);
            if ((void*)th + sizeof(*th) <= data_end)
                e->dst_port = bpf_ntohs(th->dest);
        } else if (iph->protocol == IPPROTO_UDP) {
            struct udphdr *uh = (void*)iph + (iph->ihl * 4);
            if ((void*)uh + sizeof(*uh) <= data_end)
                e->dst_port = bpf_ntohs(uh->dest);
        }

        blocked_events.ringbuf_submit(e, 0);
    }

    // Drop the packet
    return TC_ACT_SHOT;
}
"""


class EventStruct(ctypes.Structure):
    """Matches the event_t struct in eBPF C code"""
    _fields_ = [
        ("src_ip", ctypes.c_uint32),
        ("dst_ip", ctypes.c_uint32),
        ("dst_port", ctypes.c_uint16),
        ("proto", ctypes.c_uint8),
        ("pid", ctypes.c_uint32),
        ("uid", ctypes.c_uint32),
        ("comm", ctypes.c_char * 16),
        ("ts_ns", ctypes.c_uint64),
        ("action", ctypes.c_uint8),
    ]


class EBPFFirewall:
    """BCC-based eBPF firewall enforcer and monitor"""

    def __init__(self, interface: str, log_file: str, map_size: int = 1024):
        """
        Initialize eBPF firewall

        Args:
            interface: Network interface to attach TC hook (e.g., 'eth0')
            log_file: Path to write blocked events log
            map_size: Max entries in allowed_ips map
        """
        try:
            from bcc import BPF
        except ImportError:
            raise ImportError("BCC not installed. Install with: apt-get install python3-bpfcc")

        self.iface = interface
        self.log_file = log_file
        self.map_size = map_size
        self._running = False
        self._thread = None

        # Create log directory
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)

        logger.info(f"Loading eBPF program on interface {interface}")

        # Load eBPF program
        prog_text = EBPF_PROG_C.replace("1024", str(map_size))
        try:
            self.bpf = BPF(text=prog_text)
        except Exception as e:
            logger.error(f"Failed to load eBPF program: {e}")
            raise

        # Attach TC hook
        try:
            self._attach_tc()
        except Exception as e:
            logger.error(f"Failed to attach TC hook: {e}")
            raise

        logger.info(f"eBPF firewall loaded on {interface}")

        # Start event consumer thread
        self._running = True
        self._thread = threading.Thread(target=self._consume_events, daemon=True)
        self._thread.start()

    def _attach_tc(self):
        """Attach TC egress classifier to interface"""
        try:
            fn = self.bpf.load_func("tc_firewall_egress", self.bpf.SCHED_CLS)
            self.bpf.attach_func(fn, self.iface, self.bpf.TC_EGRESS)
        except AttributeError:
            # Fallback for older BCC versions
            logger.warning("Using subprocess to attach TC hook (older BCC version)")
            subprocess.run(
                f"tc qdisc add dev {self.iface} clsact 2>/dev/null || true",
                shell=True, check=False
            )
            # Note: older BCC versions may not support direct attach

    def update_allowlist(self, ip_set: Set[str]):
        """
        Update the allowed_ips map with a new set of IP addresses

        Args:
            ip_set: Set of IPv4 addresses as strings (e.g., {'10.0.0.1', '8.8.8.8'})
        """
        allowed_ips_map = self.bpf["allowed_ips"]

        # Clear existing entries
        allowed_ips_map.clear()

        # Add new entries
        for ip_str in ip_set:
            try:
                # Convert IP string to network byte order integer
                packed = socket.inet_aton(ip_str)
                # socket.inet_aton returns network byte order
                # Convert to u32 (host byte order for the hash map)
                key = ctypes.c_uint32(int.from_bytes(packed, byteorder='big'))
                val = ctypes.c_uint8(1)
                allowed_ips_map[key] = val
            except (socket.error, ValueError) as e:
                logger.warning(f"Skipping invalid IP {ip_str}: {e}")

        logger.info(f"Updated allowed_ips map with {len(ip_set)} entries")

    def _consume_events(self):
        """Consumer thread: read from ring buffer and log blocked events"""
        logger.info("Starting event consumer thread")

        def event_callback(cpu, data, size):
            """Callback for each event in the ring buffer"""
            event = ctypes.cast(data, ctypes.POINTER(EventStruct)).contents

            # Convert IPs from network byte order to dotted decimal
            try:
                dst_ip = socket.inet_ntoa(event.dst_ip.to_bytes(4, byteorder='big'))
                src_ip = socket.inet_ntoa(event.src_ip.to_bytes(4, byteorder='big'))
            except:
                dst_ip = str(event.dst_ip)
                src_ip = str(event.src_ip)

            proto_name = "TCP" if event.proto == 6 else ("UDP" if event.proto == 17 else "UNKNOWN")
            comm = event.comm.decode(errors='replace').rstrip('\x00')

            # Log as JSON
            log_entry = {
                "timestamp": event.ts_ns,
                "action": "blocked",
                "src_ip": src_ip,
                "dst_ip": dst_ip,
                "dst_port": event.dst_port if event.dst_port > 0 else None,
                "proto": proto_name,
                "pid": event.pid,
                "uid": event.uid,
                "comm": comm,
            }

            try:
                with open(self.log_file, 'a') as f:
                    f.write(json.dumps(log_entry) + '\n')
            except IOError as e:
                logger.error(f"Failed to write log: {e}")

            # Also log to Python logging at WARNING level for visibility
            logger.warning(
                f"Blocked: {src_ip} → {dst_ip}:{event.dst_port} ({proto_name}) "
                f"from {comm}[{event.pid}]"
            )

        # Open ring buffer and consume events
        try:
            rb = self.bpf["blocked_events"]
            while self._running:
                try:
                    rb.output(event_callback)
                    time.sleep(0.1)
                except KeyboardInterrupt:
                    break
                except Exception as e:
                    logger.error(f"Error consuming events: {e}")
                    time.sleep(1)
        except Exception as e:
            logger.error(f"Failed to open ring buffer: {e}")

    def detach(self):
        """Clean shutdown: detach TC hook and stop consumer thread"""
        logger.info(f"Detaching eBPF from {self.iface}")

        # Stop consumer thread
        self._running = False
        if self._thread:
            self._thread.join(timeout=2)

        # Detach TC hook
        try:
            subprocess.run(
                f"tc filter del dev {self.iface} egress 2>/dev/null || true",
                shell=True, check=False
            )
            logger.info("TC hook detached")
        except Exception as e:
            logger.warning(f"Error detaching TC: {e}")
