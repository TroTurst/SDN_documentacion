#!/bin/bash
set -u

IP="${1:-}"
ACTION="${2:-block}"

if [ -z "$IP" ]; then
    echo "Uso: $0 <IP> [block|unblock]"
    exit 1
fi

ACLS_YAML="/etc/faucet/acls.yaml"
BACKUP="${ACLS_YAML}.pre_block"
source /home/ubuntu/faucet-venv/bin/activate

cp "$ACLS_YAML" "$BACKUP"

sudo python3 << PYEOF
import sys
from ruamel.yaml import YAML

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096

ip = "${IP}"
action = "${ACTION}"
path = "${ACLS_YAML}"

with open(path) as f:
    data = yaml.load(f)

acls = data.get('acls', {})

if action == 'block':
    if 'acl_block_externa' not in acls:
        acls['acl_block_externa'] = [{'rule': {'actions': {'allow': 1}}}]
        print(f"[block_ip] acl_block_externa creada")

    rules = acls['acl_block_externa']

    for rule in rules:
        r = rule.get('rule', {})
        if r.get('ipv4_src') == f'{ip}/32':
            print(f"[block_ip] {ip} ya esta bloqueada")
            sys.exit(0)

    nueva_regla = {
        'rule': {
            'dl_type': 0x0800,
            'ipv4_src': f'{ip}/32',
            'actions': {'allow': 0}
        }
    }
    rules.insert(0, nueva_regla)
    print(f"[block_ip] Regla de bloqueo agregada para {ip}")

elif action == 'unblock':
    if 'acl_block_externa' not in acls:
        print(f"[block_ip] acl_block_externa no existe")
        sys.exit(0)

    rules = acls['acl_block_externa']
    antes = len(rules)
    acls['acl_block_externa'] = [
        r for r in rules
        if r.get('rule', {}).get('ipv4_src') != f'{ip}/32'
    ]
    despues = len(acls['acl_block_externa'])

    if antes == despues:
        print(f"[block_ip] {ip} no estaba bloqueada")
    else:
        print(f"[block_ip] Regla eliminada para {ip}")
else:
    print(f"[block_ip] Accion desconocida: {action}")
    sys.exit(1)

with open(path, 'w') as f:
    yaml.dump(data, f)
print(f"[block_ip] acls.yaml actualizado")
PYEOF

if [ $? -ne 0 ]; then
    echo "ERROR: fallo al modificar acls.yaml"
    cp "$BACKUP" "$ACLS_YAML"
    exit 1
fi

if ! /home/ubuntu/faucet-venv/bin/check_faucet_config \
    "/etc/faucet/faucet.yaml" > /tmp/check_block.log 2>&1; then
    echo "ERROR: YAML invalido"
    cat /tmp/check_block.log
    cp "$BACKUP" "$ACLS_YAML"
    exit 1
fi

pkill -HUP -f "ryu.conf"
echo "[block_ip] Faucet recargado — $IP ${ACTION}eada"
exit 0
SCRIPTEOF