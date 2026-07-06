#!/bin/bash

set -u
set -o pipefail

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"

SW_ACC1="192.168.100.8"
SW_CORE1="192.168.100.7"
SW_CORE2="192.168.100.9"
SW_SERV="192.168.100.14"

echo "=============================================="
echo " R2 - RESTAURAR RUTA NORMAL Y ENLACES R2"
echo "=============================================="
echo "NO se toca ens3."
echo ""

run_remote() {
    local ip="$1"
    local title="$2"
    local cmd="$3"

    echo ""
    echo "========== $title =========="
    ssh $SSH_OPTS ubuntu@"$ip" "$cmd"
}

run_remote "$SW_ACC1" "sw-acc1: levantar ruta normal y alternativa" '
sudo ip link set ens4 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-acc1 10 up

sudo ip link set ens6 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-acc1 5 up

sudo ovs-ofctl -O OpenFlow13 show sw-acc1 | grep -A5 -E "5\(ens6\)|10\(ens4\)"
'

run_remote "$SW_CORE1" "sw-core1: levantar enlaces principales" '
sudo ip link set ens4 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-core1 12 up

sudo ip link set ens7 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-core1 3 up

sudo ip link set ens6 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-core1 9 up

sudo ovs-ofctl -O OpenFlow13 show sw-core1 | grep -A5 -E "3\(ens7\)|9\(ens6\)|12\(ens4\)"
'

run_remote "$SW_CORE2" "sw-core2: levantar enlaces alternativos" '
sudo ip link set ens4 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-core2 1 up

sudo ip link set ens6 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-core2 3 up

sudo ip link set ens7 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-core2 4 up

sudo ovs-ofctl -O OpenFlow13 show sw-core2 | grep -A5 -E "1\(ens4\)|3\(ens6\)|4\(ens7\)"
'

run_remote "$SW_SERV" "sw-servidores: levantar entrada normal y failover" '
sudo ip link set ens4 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-servidores 1 up

sudo ip link set ens5 up
sudo ovs-ofctl -O OpenFlow13 mod-port sw-servidores 2 up

sudo ovs-ofctl -O OpenFlow13 show sw-servidores | grep -A5 -E "1\(ens4\)|2\(ens5\)"
'

echo ""
echo "========== Faucet =========="
curl -s http://localhost:9302/metrics | grep faucet_config_load_error || true
curl -s http://localhost:9302/metrics | grep "port_stack_state{" || true

echo ""
echo "Restauración terminada."
echo "Ruta normal esperada: h1/h2 -> sw-acc1 -> sw-core1 -> sw-servidores."
echo "Ruta alternativa también queda levantada: h1/h2 -> sw-acc1 -> sw-core2 -> sw-servidores."
echo ""
echo "Si deseas forzar recarga de Faucet manualmente:"
echo "  source ~/faucet-venv/bin/activate"
echo "  check_faucet_config /etc/faucet/faucet.yaml"
echo "  pkill -HUP -f 'ryu.conf'"