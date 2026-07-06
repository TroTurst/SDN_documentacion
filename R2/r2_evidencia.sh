#!/bin/bash

set -u
set -o pipefail

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"

H1="192.168.100.10"
H2="192.168.100.11"
SW_ACC1="192.168.100.8"
SW_CORE1="192.168.100.7"
SW_CORE2="192.168.100.9"
SW_SERV="192.168.100.14"

HOST="${1:-h2}"
DESTINO="${2:-10.0.1.40}"

mkdir -p /home/ubuntu/R2_logs
LOG="/home/ubuntu/R2_logs/r2_evidencia_$(date +%Y%m%d_%H%M%S)_${HOST}.log"

exec > >(tee "$LOG") 2>&1

section() {
    echo ""
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

run_remote() {
    local ip="$1"
    local title="$2"
    local cmd="$3"

    section "$title"
    ssh $SSH_OPTS ubuntu@"$ip" "$cmd" || echo "[ERROR] No se pudo ejecutar en $ip"
}

case "$HOST" in
    h1)
        HOST_IP="$H1"
        IN_PORT="2"
        ;;
    h2)
        HOST_IP="$H2"
        IN_PORT="7"
        ;;
    *)
        echo "Uso: $0 {h1|h2} [IP_DESTINO]"
        echo "Ejemplo: $0 h2 10.0.1.40"
        exit 1
        ;;
esac

section "R2 - EVIDENCIA GENERAL"
echo "Fecha:        $(date)"
echo "Host prueba:  $HOST"
echo "Host IP mgmt: $HOST_IP"
echo "Destino:      $DESTINO"
echo "Log:          $LOG"
echo ""
echo "Nota: este script es de solo lectura. No cambia VLANs, ACLs ni puertos."

section "CONTROLADOR FAUCET"
echo "--- faucet_config_load_error ---"
curl -s http://localhost:9302/metrics | grep faucet_config_load_error || true

echo ""
echo "--- dp_status ---"
curl -s http://localhost:9302/metrics | grep "dp_status" | grep -v "^#" || true

echo ""
echo "--- port_stack_state ---"
curl -s http://localhost:9302/metrics | grep "port_stack_state{" || true

section "HOST $HOST - IP, RUTA Y REPORTE LOCAL"
ssh $SSH_OPTS ubuntu@"$HOST_IP" '
echo "--- hostname ---"
hostname

echo ""
echo "--- IP ens4 ---"
ip -4 -br addr show ens4 || true

echo ""
echo "--- MAC ens4 ---"
cat /sys/class/net/ens4/address 2>/dev/null || true

echo ""
echo "--- rutas ---"
ip route || true

echo ""
echo "--- info_usuario_sdn.py, si existe ---"
if [ -x /home/ubuntu/info_usuario_sdn.py ]; then
    /home/ubuntu/info_usuario_sdn.py
else
    echo "No existe /home/ubuntu/info_usuario_sdn.py"
fi
' || echo "[ERROR] No se pudo consultar $HOST"

section "PRUEBAS CURL DESDE $HOST"
ssh $SSH_OPTS ubuntu@"$HOST_IP" "
echo '--- Acceso a Biblioteca Digital 10.0.1.40 ---'
curl --noproxy '*' --interface ens4 -v --connect-timeout 8 http://10.0.1.40 2>&1 || true

echo ''
echo '--- Acceso a Administración 10.0.1.10 ---'
curl --noproxy '*' --interface ens4 -v --connect-timeout 4 http://10.0.1.10 2>&1 || true

echo ''
echo '--- Acceso a Investigación 10.0.1.20 ---'
curl --noproxy '*' --interface ens4 -v --connect-timeout 4 http://10.0.1.20 2>&1 || true

echo ''
echo '--- Acceso a Gestión Académica 10.0.1.30 ---'
curl --noproxy '*' --interface ens4 -v --connect-timeout 4 http://10.0.1.30 2>&1 || true
" || echo "[ERROR] No se pudo hacer curl desde $HOST"

run_remote "$SW_ACC1" "SW-ACC1 - PUERTOS R2" '
echo "--- Puertos principales ---"
sudo ovs-ofctl -O OpenFlow13 show sw-acc1 | grep -A5 -E "2\(ens8\)|7\(ens9\)|5\(ens6\)|10\(ens4\)"

echo ""
echo "--- Contadores port 2, 7, 5, 10 ---"
sudo ovs-ofctl -O OpenFlow13 dump-ports sw-acc1 2
sudo ovs-ofctl -O OpenFlow13 dump-ports sw-acc1 7
sudo ovs-ofctl -O OpenFlow13 dump-ports sw-acc1 5
sudo ovs-ofctl -O OpenFlow13 dump-ports sw-acc1 10

echo ""
echo "--- Flows relevantes ---"
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 | grep -E "in_port=2|in_port=7|nw_dst=10.0.1.40|dl_vlan=100|dl_vlan=200|dl_vlan=900|output:10|output:5|actions=drop" || true
'

run_remote "$SW_CORE1" "SW-CORE1 - PUERTOS R2" '
sudo ovs-ofctl -O OpenFlow13 show sw-core1 | grep -A5 -E "3\(ens7\)|9\(ens6\)|12\(ens4\)"
'

run_remote "$SW_CORE2" "SW-CORE2 - PUERTOS R2" '
sudo ovs-ofctl -O OpenFlow13 show sw-core2 | grep -A5 -E "1\(ens4\)|3\(ens6\)|4\(ens7\)"
'

run_remote "$SW_SERV" "SW-SERVIDORES - PUERTOS Y SERVICIOS" '
echo "--- Puertos hacia core1/core2 y namespaces ---"
sudo ovs-ofctl -O OpenFlow13 show sw-servidores | grep -A5 -E "1\(ens4\)|2\(ens5\)|5\(administracion\)|6\(investigacion\)|7\(gest_acad\)|8\(bib_digital\)"

echo ""
echo "--- info_servidores_sdn.py, si existe ---"
if [ -x /home/ubuntu/info_servidores_sdn.py ]; then
    sudo /home/ubuntu/info_servidores_sdn.py
else
    echo "No existe /home/ubuntu/info_servidores_sdn.py"
fi

echo ""
echo "--- Namespaces ---"
ip netns list || true

echo ""
echo "--- IPs namespaces ---"
sudo ip netns exec ns_adm ip -4 -br addr 2>/dev/null || true
sudo ip netns exec ns_inv ip -4 -br addr 2>/dev/null || true
sudo ip netns exec ns_ges ip -4 -br addr 2>/dev/null || true
sudo ip netns exec ns_bib ip -4 -br addr 2>/dev/null || true

echo ""
echo "--- Servicios HTTP escuchando ---"
sudo ip netns exec ns_adm ss -ltnp 2>/dev/null | grep ":80" || true
sudo ip netns exec ns_inv ss -ltnp 2>/dev/null | grep ":80" || true
sudo ip netns exec ns_ges ss -ltnp 2>/dev/null | grep ":80" || true
sudo ip netns exec ns_bib ss -ltnp 2>/dev/null | grep ":80" || true

echo ""
echo "--- Prueba local a Biblioteca ---"
sudo ip netns exec ns_bib curl -s --max-time 3 http://10.0.1.40 2>/dev/null || true
'

section "OFPTRACE EN SW-ACC1"

SRC_CIDR=$(ssh $SSH_OPTS ubuntu@"$HOST_IP" "ip -4 -o addr show dev ens4 | awk '{print \$4}' | head -1" 2>/dev/null || true)
SRC_IP="${SRC_CIDR%%/*}"
SRC_MAC=$(ssh $SSH_OPTS ubuntu@"$HOST_IP" "cat /sys/class/net/ens4/address 2>/dev/null" 2>/dev/null || true)

GW_MAC=""

if [[ "$SRC_IP" == 10.100.* ]]; then
    GW_MAC="0e:00:00:00:01:00"
elif [[ "$SRC_IP" == 10.200.* ]]; then
    GW_MAC="0e:00:00:00:02:00"
elif [[ "$SRC_IP" == 10.30.* ]]; then
    GW_MAC="0e:00:00:00:03:00"
elif [[ "$SRC_IP" == 10.40.* ]]; then
    GW_MAC="0e:00:00:00:04:00"
elif [[ "$SRC_IP" == 192.168.99.* ]]; then
    GW_MAC="0e:00:00:00:09:99"
fi

echo "Host:    $HOST"
echo "in_port: $IN_PORT"
echo "SRC IP:  ${SRC_IP:-NO_DETECTADA}"
echo "SRC MAC: ${SRC_MAC:-NO_DETECTADA}"
echo "GW MAC:  ${GW_MAC:-NO_DETECTADA}"

if [ -n "${SRC_IP:-}" ] && [ -n "${SRC_MAC:-}" ] && [ -n "${GW_MAC:-}" ]; then
    TRACE_CMD="sudo ovs-appctl ofproto/trace sw-acc1 'in_port=${IN_PORT},tcp,dl_src=${SRC_MAC},dl_dst=${GW_MAC},nw_src=${SRC_IP},nw_dst=${DESTINO},nw_ttl=64,tp_src=40000,tp_dst=80'"

    echo ""
    echo "--- Comando trace ---"
    echo "$TRACE_CMD"

    echo ""
    echo "--- Resultado trace ---"
    ssh $SSH_OPTS ubuntu@"$SW_ACC1" "$TRACE_CMD" || true
else
    echo "No se ejecutó trace porque faltan IP/MAC/GW."
fi

section "RESUMEN"
echo "Archivo generado:"
echo "$LOG"
echo ""
echo "Interpretación rápida:"
echo "- output:10 = ruta normal por sw-core1."
echo "- output:5  = ruta alternativa por sw-core2."
echo "- Si el trace muestra output:10 con sw-acc1 OF10 abajo, el failover no está recalculando bien."
echo "- Si el trace muestra output:5, el tráfico está tomando la ruta alternativa."