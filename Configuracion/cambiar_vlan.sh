#!/bin/bash

set -u
set -o pipefail

exec 200>/tmp/cambiar_vlan.lock
flock -w 60 200 || {
    echo "ERROR: otro proceso esta ejecutando un cambio de VLAN"
    exit 1
}

HOST="${1:-}"
VLAN="${2:-}"

YAML="/etc/faucet/faucet.yaml"
BACKUP="${YAML}.pre_cambio_r1"

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes"
SW_CORE1="192.168.100.7"
SW_ACC1="192.168.100.8"

# Validar el host y obtener la descripción exacta del puerto.
case "$HOST" in
    h1)
        DESC="h1 ens4 acceso dinamico"
        INTERFAZ_HOST="ens8"
        ;;
    h2)
        DESC="h2 ens4 acceso dinamico"
        INTERFAZ_HOST="ens9"
        ;;
    *)
        echo "ERROR: host no reconocido: $HOST"
        echo "Uso: $0 {h1|h2} VLAN"
        exit 1
        ;;
esac

# Asociar cada VLAN con la ACL correspondiente.
case "$VLAN" in
    vlan_cuarentena)
        ACL="acl_cuarentena"
        ;;
    vlan_alumnos)
        ACL="acl_alumnos"
        ;;
    vlan_docentes)
        ACL="acl_docentes"
        ;;
    vlan_administrativos)
        ACL="acl_administrativos"
        ;;
    vlan_invitados)
        ACL="acl_invitados"
        ;;
    *)
        echo "ERROR: VLAN no reconocida: $VLAN"
        exit 1
        ;;
esac

if [ ! -f "$YAML" ]; then
    echo "ERROR: no existe $YAML"
    exit 1
fi

cp "$YAML" "$BACKUP" || {
    echo "ERROR: no se pudo crear el respaldo del YAML"
    exit 1
}

# Actualizar native_vlan y acls_in dentro del bloque del host.
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

matches = [
    index for index, line in enumerate(lines)
    if line.strip() == target
]

if len(matches) != 1:
    raise SystemExit(
        f"ERROR: se esperó una coincidencia para {target}, "
        f"pero se encontraron {len(matches)}"
    )

description_index = matches[0]
description_indent = (
    len(lines[description_index])
    - len(lines[description_index].lstrip())
)

native_index = None
acl_index = None

for index in range(description_index + 1, len(lines)):
    stripped = lines[index].strip()

    if not stripped:
        continue

    current_indent = len(lines[index]) - len(lines[index].lstrip())

    # Final del bloque de la interfaz.
    if current_indent < description_indent:
        break

    if stripped.startswith("native_vlan:"):
        native_index = index
    elif stripped.startswith("acls_in:"):
        acl_index = index

if native_index is None:
    raise SystemExit("ERROR: no se encontró native_vlan en el bloque del host")

if acl_index is None:
    raise SystemExit("ERROR: no se encontró acls_in en el bloque del host")

indent = " " * description_indent
lines[native_index] = f"{indent}native_vlan: {new_vlan}"
lines[acl_index] = f"{indent}acls_in: [{new_acl}]"

path.write_text("\n".join(lines) + "\n")

print(f"Configuración actualizada:")
print(f"  host: {description}")
print(f"  VLAN: {new_vlan}")
print(f"  ACL:  {new_acl}")
PY

if [ $? -ne 0 ]; then
    echo "ERROR: no se pudo modificar el bloque de h1/h2"
    cp "$BACKUP" "$YAML"
    exit 1
fi

# Validar que los dos valores quedaron correctamente escritos.
BLOQUE=$(grep -A3 "description: \"${DESC}\"" "$YAML")

echo "$BLOQUE"

if ! echo "$BLOQUE" | grep -q "native_vlan: ${VLAN}"; then
    echo "ERROR: native_vlan no fue actualizado"
    cp "$BACKUP" "$YAML"
    exit 1
fi

if ! echo "$BLOQUE" | grep -q "acls_in: \[${ACL}\]"; then
    echo "ERROR: acls_in no fue actualizado"
    cp "$BACKUP" "$YAML"
    exit 1
fi

# Validar la configuración completa de Faucet.
source /home/ubuntu/faucet-venv/bin/activate

if ! /home/ubuntu/faucet-venv/bin/check_faucet_config \
    "$YAML" > /tmp/check_output.log 2>&1; then

    echo "ERROR: YAML inválido; restaurando configuración anterior"
    cat /tmp/check_output.log
    cp "$BACKUP" "$YAML"
    exit 1
fi

echo "Configuración Faucet válida"

# Recargar Faucet.
if ! pkill -HUP -f "ryu.conf"; then
    echo "ERROR: no se encontró el proceso Faucet asociado con ryu.conf"
    cp "$BACKUP" "$YAML"
    exit 1
fi

echo "SIGHUP enviado, esperando flows..."

for i in $(seq 1 15); do
    count=$(ssh $SSH_OPTS ubuntu@"$SW_CORE1" \
        "sudo ovs-ofctl -O OpenFlow13 dump-flows sw-core1 \
        2>/dev/null | grep -v OFPST | wc -l" 2>/dev/null)

    count=${count:-0}

    echo "  Intento $i: $count flows en sw-core1"

    if [ "$count" -gt 100 ] 2>/dev/null; then
        echo "  Faucet reinstaló los flows correctamente"
        break
    fi

    sleep 1
done

# Obtener dinámicamente los puertos OpenFlow.
H1_OFPORT=$(ssh $SSH_OPTS ubuntu@"$SW_ACC1" \
    "sudo ovs-vsctl get Interface ens8 ofport" 2>/dev/null \
    | tr -d '"[:space:]')

H2_OFPORT=$(ssh $SSH_OPTS ubuntu@"$SW_ACC1" \
    "sudo ovs-vsctl get Interface ens9 ofport" 2>/dev/null \
    | tr -d '"[:space:]')

PORTAL_OFPORT=$(ssh $SSH_OPTS ubuntu@"$SW_ACC1" \
    "sudo ovs-vsctl get Interface vlan999 ofport" 2>/dev/null \
    | tr -d '"[:space:]')

MAC_VLAN999=$(ssh $SSH_OPTS ubuntu@"$SW_ACC1" \
    "cat /sys/class/net/vlan999/address" 2>/dev/null \
    | tr -d '[:space:]')

for valor in "$H1_OFPORT" "$H2_OFPORT" "$PORTAL_OFPORT"; do
    if ! [[ "$valor" =~ ^[0-9]+$ ]] || [ "$valor" -le 0 ]; then
        echo "ERROR: número OpenFlow inválido: $valor"
        exit 1
    fi
done

echo "Puertos OpenFlow detectados:"
echo "  h1 ens8:   $H1_OFPORT"
echo "  h2 ens9:   $H2_OFPORT"
echo "  vlan999:   $PORTAL_OFPORT"
echo "  MAC portal: $MAC_VLAN999"

echo "Reinstalando flows del portal cautivo en sw-acc1..."

ssh $SSH_OPTS ubuntu@"$SW_ACC1" "
sudo ovs-ofctl -O OpenFlow13 --strict del-flows sw-acc1 \
'table=6,priority=8192,dl_vlan=999,dl_dst=${MAC_VLAN999}' \
2>/dev/null || true

sudo ovs-ofctl -O OpenFlow13 add-flow sw-acc1 \
'table=6,priority=8192,dl_vlan=999,dl_dst=${MAC_VLAN999},actions=pop_vlan,output:${PORTAL_OFPORT}'
" || {
    echo "ERROR: no se pudo reinstalar el flow unicast del portal"
    exit 1
}

ssh $SSH_OPTS ubuntu@"$SW_ACC1" "
sudo ovs-ofctl -O OpenFlow13 --strict del-flows sw-acc1 \
'table=6,priority=8240,dl_vlan=999,dl_dst=ff:ff:ff:ff:ff:ff' \
2>/dev/null || true

sudo ovs-ofctl -O OpenFlow13 add-flow sw-acc1 \
'table=6,priority=8240,dl_vlan=999,dl_dst=ff:ff:ff:ff:ff:ff,actions=pop_vlan,output:${H1_OFPORT},output:${H2_OFPORT},output:${PORTAL_OFPORT}'
" || {
    echo "ERROR: no se pudo reinstalar el flow broadcast del portal"
    exit 1
}

# Renovar IP en el host segun la VLAN asignada
case "$HOST" in
    h1) HOST_IP="192.168.100.10" ;;
    h2) HOST_IP="192.168.100.11" ;;
esac

echo "Renovando IP en $HOST ($HOST_IP)..."

ssh $SSH_OPTS ubuntu@"$HOST_IP" "
    sudo ip addr flush dev ens4
    sudo ip link set ens4 up
    sudo dhclient ens4 2>/dev/null \
        || sudo busybox udhcpc -i ens4 2>/dev/null \
        || true
    sleep 2
    echo 'IP actual:'
    ip addr show ens4 | grep 'inet '
" || {
    echo "ADVERTENCIA: no se pudo renovar la IP en $HOST (SSH fallo)"
    echo "Renovar manualmente: sudo ip addr flush dev ens4 && sudo dhclient ens4"
}

echo "Cambio completado:"
echo "  $HOST -> $VLAN"
echo "  ACL  -> $ACL"

exit 0