sudo python3 << 'EOF'
import re

path = '/etc/suricata/suricata.yaml'
with open(path) as f:
    content = f.read()

# Cambiar interfaz af-packet
content = re.sub(
    r'(af-packet:\n\s*- interface:)\s*\S+',
    r'\1 ens6',
    content
)

# Cambiar interfaz pcap
content = re.sub(
    r'(pcap:\n\s*- interface:)\s*\S+',
    r'\1 ens6',
    content
)

with open(path, 'w') as f:
    f.write(content)
print("OK")
EOF