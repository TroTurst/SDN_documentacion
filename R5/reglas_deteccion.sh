sudo tee /var/lib/suricata/rules/sdn-seccampus.rules << 'EOF'
# ── ATAQUE 1: SYN Scan ──────────────────────────────────────────────────────
alert tcp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SECCAMPUS SYN SCAN"; \
  flags:S,12; \
  threshold: type both, track by_src, count 10, seconds 5; \
  classtype:attempted-recon; \
  sid:9000001; rev:2;)

# ── ATAQUE 2: DDoS ICMP Flood ────────────────────────────────────────────────
alert icmp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SECCAMPUS ICMP FLOOD DDOS"; \
  itype:8; \
  threshold: type both, track by_src, count 20, seconds 3; \
  classtype:attempted-dos; \
  sid:9000002; rev:2;)

# ── ATAQUE 2: DDoS SYN Flood ─────────────────────────────────────────────────
alert tcp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SECCAMPUS SYN FLOOD DDOS"; \
  flags:S,12; \
  threshold: type both, track by_src, count 50, seconds 3; \
  classtype:attempted-dos; \
  sid:9000003; rev:2;)

# ── ATAQUE 2: DDoS UDP Flood ─────────────────────────────────────────────────
alert udp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SECCAMPUS UDP FLOOD DDOS"; \
  threshold: type both, track by_src, count 50, seconds 3; \
  classtype:attempted-dos; \
  sid:9000004; rev:2;)

# ── ATAQUE 3: Flow Exhaustion ────────────────────────────────────────────────
alert tcp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SECCAMPUS FLOW EXHAUSTION TCP"; \
  flags:S,12; \
  threshold: type threshold, track by_src, count 100, seconds 5; \
  classtype:attempted-dos; \
  sid:9000005; rev:2;)

alert udp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SECCAMPUS FLOW EXHAUSTION UDP"; \
  threshold: type threshold, track by_src, count 100, seconds 5; \
  classtype:attempted-dos; \
  sid:9000006; rev:2;)

# ── REGLA TEST (eliminar en produccion) ──────────────────────────────────────
alert tcp any any -> $HOME_NET any \
  (msg:"SDN-SECCAMPUS TEST SYN"; \
  flags:S; \
  sid:9000099; rev:1;)
EOF