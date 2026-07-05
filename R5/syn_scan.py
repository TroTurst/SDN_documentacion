#!/usr/bin/env python3
from scapy.all import *
iface = "ens4"
src = "172.16.0.10"
target = "10.100.0.1"
print(f"[*] SYN Scan: {src} -> {target}")
pkts = [Ether()/IP(src=src, dst=target)/TCP(sport=RandShort(), dport=p, flags="S")
        for p in range(1, 200)]
sendp(pkts, iface=iface, verbose=False, inter=0.01)
print(f"[+] Enviados {len(pkts)} paquetes SYN")