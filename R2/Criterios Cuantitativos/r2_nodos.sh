#!/bin/bash

set -u

OVS_BR="sw-acc1"
LINUX_BR="br-r2"
OVS_IF="r2ovs0"
BR_IF="r2br0"
OFPORT="20"

PREFIX="r2n"
IP_BASE="10.100.14"
IP_INICIAL=100
MAX_NODOS=50

GATEWAY="10.100.0.1"
PERMITIDO="http://10.0.1.40"
BLOQUEADO="http://10.0.1.10"

CSV="/tmp/r2_escalabilidad_nodos.csv"

limpiar() {
    for ns in $(ip netns list | awk '$1 ~ /^r2n/ {print $1}'); do
        ip netns del "$ns" 2>/dev/null
    done

    ovs-vsctl --if-exists del-port "$OVS_BR" "$OVS_IF"
    ip link del "$OVS_IF" 2>/dev/null
    ip link del "$LINUX_BR" 2>/dev/null
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Ejecutar con sudo"
    exit 1
fi

ACCION="${1:-}"

if [ "$ACCION" = "cleanup" ]; then
    limpiar
    echo "Topología temporal eliminada"
    exit 0
fi

if [ "$ACCION" != "run" ]; then
    echo "Uso:"
    echo "  sudo $0 run NUMERO_NODOS"
    echo "  sudo $0 cleanup"
    exit 1
fi

N="${2:-}"

if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    echo "Cantidad inválida"
    exit 1
fi

if [ "$N" -lt 1 ] || [ "$N" -gt "$MAX_NODOS" ]; then
    echo "Use entre 1 y $MAX_NODOS nodos"
    exit 1
fi

echo "Recreando topología para $N nodos..."
limpiar

# Bridge Linux
ip link add "$LINUX_BR" type bridge
ip link set "$LINUX_BR" up

# Enlace bridge Linux <-> OVS
ip link add "$OVS_IF" type veth peer name "$BR_IF"
ip link set "$BR_IF" master "$LINUX_BR"
ip link set "$BR_IF" up
ip link set "$OVS_IF" up

ovs-vsctl add-port "$OVS_BR" "$OVS_IF" \
    -- set Interface "$OVS_IF" ofport_request="$OFPORT"

PUERTO_REAL=$(ovs-vsctl get Interface "$OVS_IF" ofport \
    | tr -d '"[:space:]')

if [ "$PUERTO_REAL" != "$OFPORT" ]; then
    echo "ERROR: OVS asignó OFPORT=$PUERTO_REAL"
    exit 1
fi

# Crear nodos
for i in $(seq 1 "$N"); do
    IDX=$(printf "%02d" "$i")
    NS="${PREFIX}${IDX}"
    HOST_IF="r2h${IDX}"
    NS_IF="r2p${IDX}"
    IP="${IP_BASE}.$((IP_INICIAL + i))/20"

    ip netns add "$NS"

    ip link add "$HOST_IF" type veth peer name "$NS_IF"
    ip link set "$HOST_IF" master "$LINUX_BR"
    ip link set "$HOST_IF" up

    ip link set "$NS_IF" netns "$NS"

    ip -n "$NS" link set lo up
    ip -n "$NS" link set "$NS_IF" name eth0
    ip -n "$NS" addr add "$IP" dev eth0
    ip -n "$NS" link set eth0 up
    ip -n "$NS" route add default via "$GATEWAY"
done

sleep 3

GATEWAY_OK=0
ALLOW_OK=0
DROP_OK=0
SUMA_TIEMPO=0

echo
echo "Probando $N nodos..."

for i in $(seq 1 "$N"); do
    IDX=$(printf "%02d" "$i")
    NS="${PREFIX}${IDX}"

    # Conectividad y aprendizaje
    if ip netns exec "$NS" \
        ping -c 1 -W 1 "$GATEWAY" >/dev/null 2>&1; then
        GATEWAY_OK=$((GATEWAY_OK + 1))
    fi

    # Acceso permitido
    RESULTADO=$(ip netns exec "$NS" \
        curl --noproxy "*" \
        -s -o /dev/null \
        -w "%{http_code} %{time_total}" \
        --connect-timeout 3 \
        --max-time 4 \
        "$PERMITIDO" 2>/dev/null)

    RC_ALLOW=$?
    HTTP=$(echo "$RESULTADO" | awk '{print $1}')
    TIEMPO=$(echo "$RESULTADO" | awk '{print $2}')

    if [ "$RC_ALLOW" -eq 0 ] && [ "$HTTP" = "200" ]; then
        ALLOW_OK=$((ALLOW_OK + 1))
        SUMA_TIEMPO=$(awk \
            -v a="$SUMA_TIEMPO" \
            -v b="${TIEMPO:-0}" \
            'BEGIN {printf "%.6f", a+b}')
    fi

    # Acceso bloqueado
    ip netns exec "$NS" \
        curl --noproxy "*" \
        -s -o /dev/null \
        --connect-timeout 2 \
        --max-time 2 \
        "$BLOQUEADO" >/dev/null 2>&1

    RC_DROP=$?

    # RC 28 = timeout, comportamiento esperado de la ACL DROP
    if [ "$RC_DROP" -eq 28 ]; then
        DROP_OK=$((DROP_OK + 1))
    fi
done

# Capturar flows después del tráfico
DUMP=$(mktemp)

ovs-ofctl -O OpenFlow13 dump-flows "$OVS_BR" > "$DUMP"

APRENDIDOS=0

for i in $(seq 1 "$N"); do
    IDX=$(printf "%02d" "$i")
    NS="${PREFIX}${IDX}"

    MAC=$(ip -n "$NS" -o link show eth0 \
        | awk '{print $17}')

    if grep -qi "table=6.*dl_dst=${MAC}" "$DUMP"; then
        APRENDIDOS=$((APRENDIDOS + 1))
    fi
done

ACL_FLOWS=$(grep "table=2" "$DUMP" \
    | grep -c "dl_vlan=100" 2>/dev/null)

rm -f "$DUMP"

if [ "$ALLOW_OK" -gt 0 ]; then
    LATENCIA_MS=$(awk \
        -v suma="$SUMA_TIEMPO" \
        -v cantidad="$ALLOW_OK" \
        'BEGIN {printf "%.3f", (suma/cantidad)*1000}')
else
    LATENCIA_MS="0"
fi

PORC_ALLOW=$(awk \
    -v ok="$ALLOW_OK" \
    -v total="$N" \
    'BEGIN {printf "%.2f", ok*100/total}')

PORC_DROP=$(awk \
    -v ok="$DROP_OK" \
    -v total="$N" \
    'BEGIN {printf "%.2f", ok*100/total}')

if [ ! -f "$CSV" ]; then
    echo \
"fecha,nodos,gateway_ok,allow_ok,drop_ok,allow_pct,drop_pct,latencia_ms,mac_aprendidas,acl_flows_vlan100" \
    > "$CSV"
fi

echo \
"$(date --iso-8601=seconds),$N,$GATEWAY_OK,$ALLOW_OK,$DROP_OK,$PORC_ALLOW,$PORC_DROP,$LATENCIA_MS,$APRENDIDOS,$ACL_FLOWS" \
>> "$CSV"

echo
echo "=============== RESULTADO ==============="
echo "Nodos evaluados:          $N"
echo "Gateway correcto:         $GATEWAY_OK/$N"
echo "Accesos permitidos:       $ALLOW_OK/$N ($PORC_ALLOW %)"
echo "Bloqueos correctos:       $DROP_OK/$N ($PORC_DROP %)"
echo "Latencia media permitida: $LATENCIA_MS ms"
echo "MAC aprendidas:           $APRENDIDOS/$N"
echo "Flows ACL VLAN 100:       $ACL_FLOWS"
echo "CSV:                      $CSV"
echo "========================================="
