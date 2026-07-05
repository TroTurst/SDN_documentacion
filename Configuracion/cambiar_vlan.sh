#!/bin/bash
set -u
set -o pipefail

exec 200>/tmp/cambiar_vlan.lock
flock -w 60 200 || { echo "ERROR: otro proceso corriendo"; exit 1; }

HOST="${1:-}"
VLAN="${2:-}"
YAML="/etc/faucet/faucet.yaml"
BACKUP="${YAML}.pre_cambio_r1"
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes"
SW_CORE1="192.168.100.7"
SW_ACC1="192.168.100.8"

case "$HOST" in
    h1) DESC="h1 ens4 acceso dinamico" ;;
    h2) DESC="h2 ens4 acceso dinamico" ;;
    *)  echo "ERROR: host no reconocido: $HOST"; exit 1 ;;
esac

case "$VLAN" in
    vlan_cuarentena)     ACL="acl_cuarentena" ;;
    vlan_alumnos)        ACL="acl_alumnos" ;;
    vlan_docentes)       ACL="acl_docentes" ;;
    vlan_administrativos) ACL="acl_administrativos" ;;
    vlan_invitados)      ACL="acl_invitados" ;;
    *) echo "ERROR: VLAN no reconocida: $VLAN"; exit 1 ;;
esac

cp "$YAML" "$BACKUP"

export YAML DESC VLAN ACL
python3 <<'PY'
from pathlib import Path
import os

path = Path(os.environ["YAML"])
description = os.environ["DESC"]
new_vlan = os.environ["VLAN"]
new_acl = os.environ["ACL"]

lines = path.read_text().splitlines()
target = f'description: "{description}"'
matches = [i for i, l in enumerate(lines) if l.strip() == target]

if len(matches) != 1:
    raise SystemExit(f"ERROR: {len(matches)} coincidencias para {target}")

desc_idx = matches[0]
indent = len(lines[desc_idx]) - len(lines[desc_idx].lstrip())
native_idx = acl_idx = None

for i in range(desc_idx + 1, len(lines)):
    stripped = lines[i].strip()
    if not stripped:
        continue
    curr_indent = len(lines[i]) - len(lines[i].lstrip())
    if curr_indent < indent:
        break
    if stripped.startswith("native_vlan:"):
        native_idx = i
    elif stripped.startswith("acls_in:"):
        acl_idx = i

if native_idx is None or acl_idx is None:
    raise SystemExit("ERROR: native_vlan o acls_in no encontrados")

sp = " " * indent
lines[native_idx] = f"{sp}native_vlan: {new_vlan}"
lines[acl_idx] = f"{sp}acls_in: [{new_acl}]"
path.write_text("\n".join(lines) + "\n")
print(f"OK: {description} -> {new_vlan} [{new_acl}]")
PY

[ $? -ne 0 ] && { cp "$BACKUP" "$YAML"; exit 1; }

source /home/ubuntu/faucet-venv/bin/activate
/home/ubuntu/faucet-venv/bin/check_faucet_config "$YAML" > /tmp/check.log 2>&1 || {
    echo "ERROR: YAML invalido"
    cp "$BACKUP" "$YAML"
    exit 1
}

pkill -HUP -f "ryu.conf" || { cp "$BACKUP" "$YAML"; exit 1; }
echo "SIGHUP enviado, esperando flows..."

for i in $(seq 1 15); do
    count=$(ssh $SSH_OPTS ubuntu@"$SW_CORE1" \
        "sudo ovs-ofctl -O OpenFlow13 dump-flows sw-core1 2>/dev/null \
        | grep -v OFPST | wc -l" 2>/dev/null)
    count=${count:-0}
    echo "  Intento $i: $count flows en sw-core1"
    [ "$count" -gt 100 ] && { echo "  Faucet reinstalo flows OK"; break; }
    sleep 1
done

H1_OFPORT=$(ssh $SSH_OPTS ubuntu@"$SW_ACC1" \
    "sudo ovs-vsctl get Interface ens8 ofport" 2>/dev/null | tr -d '"[:space:]')
H2_OFPORT=$(ssh $SSH_OPTS ubuntu@"$SW_ACC1" \
    "sudo ovs-vsctl get Interface ens9 ofport" 2>/dev/null | tr -d '"[:space:]')

echo "h1=$H1_OFPORT h2=$H2_OFPORT"

case "$HOST" in
    h1) HOST_IP="192.168.100.10" ;;
    h2) HOST_IP="192.168.100.11" ;;
esac

ssh $SSH_OPTS ubuntu@"$HOST_IP" "
    sudo dhclient -r ens4 2>/dev/null || true
    sudo ip addr flush dev ens4
    sudo ip link set ens4 up
    sudo dhclient ens4 2>/dev/null \
        || sudo busybox udhcpc -i ens4 2>/dev/null || true
    sleep 2
    echo 'IP actual:'
    ip addr show ens4 | grep 'inet '
" || echo "ADVERTENCIA: renovacion IP fallo — hacerlo manualmente"

echo "Completado: $HOST -> $VLAN [$ACL]"
exit 0