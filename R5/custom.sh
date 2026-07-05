sudo tee /etc/suricata/rules/custom/sdn-seccampus.rules << 'EOF'
#  ATAQUE 1: SYN Scan 
# muchos paquetes SYN sin ACK desde la misma IP
alert tcp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SecCampus SYN SCAN detectado"; \
  flags:S,12; \
  threshold: type both, track by_src, count 20, seconds 3; \
  classtype:attempted-recon; \
  sid:9000001; rev:1;)

#  ATAQUE 2: DDoS ICMP Flood 
# Detecta flood de ICMP desde una sola IP
alert icmp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SecCampus ICMP FLOOD DDoS detectado"; \
  itype:8; \
  threshold: type both, track by_src, count 100, seconds 5; \
  classtype:attempted-dos; \
  sid:9000002; rev:1;)

# Detecta flood TCP SYN de alto volumen (DDoS)
alert tcp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SecCampus TCP SYN FLOOD DDoS detectado"; \
  flags:S,12; \
  threshold: type both, track by_src, count 200, seconds 5; \
  classtype:attempted-dos; \
  sid:9000003; rev:1;)

# Detecta flood UDP
alert udp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SecCampus UDP FLOOD DDoS detectado"; \
  threshold: type both, track by_src, count 200, seconds 5; \
  classtype:attempted-dos; \
  sid:9000004; rev:1;)

#  ATAQUE 3: Flow Exhaustion
# Detecta muchos paquetes con puertos destino distintos
alert tcp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SecCampus FLOW EXHAUSTION TCP detectado"; \
  flags:S,12; \
  threshold: type threshold, track by_src, count 500, seconds 10; \
  classtype:attempted-dos; \
  sid:9000005; rev:1;)

alert udp $EXTERNAL_NET any -> $HOME_NET any \
  (msg:"SDN-SecCampus FLOW EXHAUSTION UDP detectado"; \
  threshold: type threshold, track by_src, count 500, seconds 10; \
  classtype:attempted-dos; \
  sid:9000006; rev:1;)
EOF


sudo tee -a /etc/suricata/suricata.yaml << 'EOF'

rule-files:
  - /etc/suricata/rules/custom/sdn-seccampus.rules
EOF