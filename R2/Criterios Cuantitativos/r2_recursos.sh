#!/bin/bash

set -u
set -o pipefail

ACL="/etc/faucet/acls.yaml"
FAUCET="/etc/faucet/faucet.yaml"
BACKUP="/etc/faucet/acls.yaml.pre_r2_recursos"
CHECK="/home/ubuntu/faucet-venv/bin/check_faucet_config"
CSV="/tmp/r2_escalabilidad_recursos.csv"

SSH_OPTS="-i /home/ubuntu/.ssh/id_ed25519 -o UserKnownHostsFile=/home/ubuntu/.ssh/known_hosts -o StrictHostKeyChecking=no -o BatchMode=yes"

SW_SERV="ubuntu@192.168.100.14"
SW_SERV_PORT="22"

SW_ACC1="ubuntu@192.168.100.8"
H2="ubuntu@192.168.100.11"

PRIMERA_IP=50
ULTIMA_IP_LIMPIEZA=199
MAX_TOTAL=32
RECURSOS_REALES=4

error() {
    echo "ERROR: $*" >&2
    exit 1
}

verificar_root() {
    [ "$(id -u)" -eq 0 ] || error "Ejecutar con sudo"
}

preparar_servidores() {
    EXTRA="$1"

    ssh $SSH_OPTS -p "$SW_SERV_PORT" "$SW_SERV" \
        sudo bash -s -- "$EXTRA" <<'REMOTE'
set -e

EXTRA="$1"
PRIMERA=50
ULTIMA=199

ip netns list | grep -q "^ns_bib" || {
    echo "No existe ns_bib"
    exit 1
}

# Detener únicamente los procesos dentro de ns_bib.
for PID in $(ip netns pids ns_bib 2>/dev/null); do
    kill "$PID" 2>/dev/null || true
done

sleep 1

# Eliminar IPs de pruebas anteriores.
for HOST in $(seq "$PRIMERA" "$ULTIMA"); do
    ip netns exec ns_bib \
        ip addr del "10.0.1.${HOST}/24" \
        dev bib_digital 2>/dev/null || true
done

# Agregar recursos sintéticos.
if [ "$EXTRA" -gt 0 ]; then
    ULTIMO=$((PRIMERA + EXTRA - 1))

    for HOST in $(seq "$PRIMERA" "$ULTIMO"); do
        ip netns exec ns_bib \
            ip addr add "10.0.1.${HOST}/24" \
            dev bib_digital
    done
fi

ip netns exec ns_bib ip link set bib_digital up

# Un solo servidor escucha en la IP real y en todas las secundarias.
ip netns exec ns_bib bash -c \
    'setsid python3 -m http.server 80 \
     --bind 0.0.0.0 \
     --directory /tmp/bib \
     > /tmp/r2_recursos_http.log 2>&1 < /dev/null &'

sleep 2

# Confirmar que los servicios de control están activos.
ip netns exec ns_bib \
    curl -fsS --max-time 2 \
    http://10.0.1.40 >/dev/null

ip netns exec ns_adm \
    curl -fsS --max-time 2 \
    http://10.0.1.10 >/dev/null
REMOTE
}

modificar_acl() {
    EXTRA="$1"

    [ -f "$BACKUP" ] || cp "$ACL" "$BACKUP"

    export ACL EXTRA PRIMERA_IP ULTIMA_IP_LIMPIEZA

    python3 <<'PY'
import os
from ipaddress import ip_address
from ruamel.yaml import YAML

archivo = os.environ["ACL"]
extra = int(os.environ["EXTRA"])
primera = int(os.environ["PRIMERA_IP"])
ultima_limpieza = int(os.environ["ULTIMA_IP_LIMPIEZA"])

yaml = YAML()
yaml.preserve_quotes = True
yaml.indent(mapping=2, sequence=4, offset=2)

with open(archivo, "r") as f:
    datos = yaml.load(f)

reglas = datos["acls"]["acl_alumnos"]

def es_regla_sintetica(entrada):
    try:
        regla = entrada["rule"]

        destino = str(regla.get("ipv4_dst", "")).split("/")[0]
        direccion = ip_address(destino)

        partes = str(direccion).split(".")
        host = int(partes[3])

        return (
            partes[:3] == ["10", "0", "1"]
            and primera <= host <= ultima_limpieza
            and int(regla.get("tcp_dst", -1)) == 80
            and regla.get("actions", {}).get("allow") == 1
        )
    except Exception:
        return False

# Retirar reglas creadas en ejecuciones anteriores.
reglas_limpias = [
    entrada for entrada in reglas
    if not es_regla_sintetica(entrada)
]

# Localizar el DROP general de la red de servidores.
indice_drop = None

for indice, entrada in enumerate(reglas_limpias):
    regla = entrada.get("rule", {})

    if (
        str(regla.get("ipv4_dst", "")) == "10.0.1.0/24"
        and regla.get("actions", {}).get("allow") == 0
    ):
        indice_drop = indice
        break

if indice_drop is None:
    raise SystemExit(
        "No se encontró el DROP general de 10.0.1.0/24"
    )

nuevas = []

for host in range(primera, primera + extra):
    nuevas.append({
        "rule": {
            "dl_type": 0x0800,
            "ip_proto": 6,
            "ipv4_dst": f"10.0.1.{host}/32",
            "tcp_dst": 80,
            "actions": {
                "allow": 1
            }
        }
    })

datos["acls"]["acl_alumnos"] = (
    reglas_limpias[:indice_drop]
    + nuevas
    + reglas_limpias[indice_drop:]
)

temporal = archivo + ".r2tmp"

with open(temporal, "w") as f:
    yaml.dump(datos, f)

os.replace(temporal, archivo)

print(f"Reglas sintéticas insertadas: {extra}")
PY
}

contar_acl() {
    export ACL

    python3 <<'PY'
import os
from ruamel.yaml import YAML

yaml = YAML()

with open(os.environ["ACL"], "r") as f:
    datos = yaml.load(f)

print(len(datos["acls"]["acl_alumnos"]))
PY
}

probar_desde_h2() {
    EXTRA="$1"

    ssh $SSH_OPTS "$H2" bash -s -- "$EXTRA" <<'REMOTE'
EXTRA="$1"
OK=0
TOTAL=$((EXTRA + 1))

# h2 debe pertenecer a la VLAN de alumnos.
if ! ip -4 -o addr show ens4 | grep -q "inet 10\.100\."; then
    echo "ERROR_H2_NO_ES_ALUMNO"
    exit 2
fi

# Biblioteca real.
CODIGO=$(curl --noproxy "*" --interface ens4 \
    -s -o /dev/null \
    -w "%{http_code}" \
    --connect-timeout 3 \
    --max-time 4 \
    http://10.0.1.40)

[ "$CODIGO" = "200" ] && OK=$((OK + 1))

# Recursos sintéticos.
if [ "$EXTRA" -gt 0 ]; then
    ULTIMO=$((50 + EXTRA - 1))

    for HOST in $(seq 50 "$ULTIMO"); do
        CODIGO=$(curl --noproxy "*" --interface ens4 \
            -s -o /dev/null \
            -w "%{http_code}" \
            --connect-timeout 3 \
            --max-time 4 \
            "http://10.0.1.${HOST}")

        [ "$CODIGO" = "200" ] && OK=$((OK + 1))
    done
fi

# Control negativo: Administración debe continuar bloqueada.
curl --noproxy "*" --interface ens4 \
    -s -o /dev/null \
    --connect-timeout 2 \
    --max-time 2 \
    http://10.0.1.10

RC_DROP=$?

if [ "$RC_DROP" -ne 0 ]; then
    DROP_OK=1
else
    DROP_OK=0
fi

echo "$OK $TOTAL $DROP_OK"
REMOTE
}

esperar_flows() {
    EXTRA="$1"

    if [ "$EXTRA" -gt 0 ]; then
        DESTINO="10.0.1.$((50 + EXTRA - 1))"
    else
        DESTINO="10.0.1.40"
    fi

    for INTENTO in $(seq 1 40); do
        CONFIG_OK=$(curl -s \
            http://localhost:9302/metrics \
            | awk '/^faucet_config_load_error / {print $2}' \
            | tail -1)

        if [ "$CONFIG_OK" = "0.0" ]; then
            ssh $SSH_OPTS "$SW_ACC1" \
                "sudo ovs-ofctl -O OpenFlow13 \
                 dump-flows sw-acc1 \
                 | grep 'table=2' \
                 | grep 'dl_vlan=100' \
                 | grep 'nw_dst=${DESTINO}' \
                 | grep -q 'tp_dst=80'"

            if [ "$?" -eq 0 ]; then
                return 0
            fi
        fi

        sleep 0.25
    done

    return 1
}

restaurar_servidor() {
    ssh $SSH_OPTS -p "$SW_SERV_PORT" "$SW_SERV" \
        sudo bash -s <<'REMOTE'
set -e

for PID in $(ip netns pids ns_bib 2>/dev/null); do
    kill "$PID" 2>/dev/null || true
done

sleep 1

for HOST in $(seq 50 199); do
    ip netns exec ns_bib \
        ip addr del "10.0.1.${HOST}/24" \
        dev bib_digital 2>/dev/null || true
done

ip netns exec ns_bib bash -c \
    'setsid python3 -m http.server 80 \
     --bind 10.0.1.40 \
     --directory /tmp/bib \
     > /tmp/ns_bib_http.log 2>&1 < /dev/null &'

sleep 1

ip netns exec ns_bib \
    curl -fsS --max-time 2 \
    http://10.0.1.40 >/dev/null
REMOTE
}

ejecutar() {
    TOTAL="$1"

    [[ "$TOTAL" =~ ^[0-9]+$ ]] \
        || error "El número de recursos debe ser entero"

    [ "$TOTAL" -ge "$RECURSOS_REALES" ] \
        || error "El mínimo es 4 recursos"

    [ "$TOTAL" -le "$MAX_TOTAL" ] \
        || error "El máximo definido para la prueba es 32"

    EXTRA=$((TOTAL - RECURSOS_REALES))

    echo "=========================================="
    echo "Recursos reales:       $RECURSOS_REALES"
    echo "Recursos sintéticos:   $EXTRA"
    echo "Total evaluado:        $TOTAL"
    echo "=========================================="

    preparar_servidores "$EXTRA"

    modificar_acl "$EXTRA"

    INICIO_VALIDACION=$(date +%s%3N)

    if ! "$CHECK" "$FAUCET" \
        > /tmp/r2_recursos_check.log 2>&1; then

        echo "Configuración Faucet inválida"
        cat /tmp/r2_recursos_check.log

        cp "$BACKUP" "$ACL"
        exit 1
    fi

    FIN_VALIDACION=$(date +%s%3N)
    VALIDACION_MS=$((FIN_VALIDACION - INICIO_VALIDACION))

    INICIO_RECARGA=$(date +%s%3N)

    pkill -HUP -f "ryu.conf" \
        || error "No se pudo enviar SIGHUP a Faucet"

    if ! esperar_flows "$EXTRA"; then
        cp "$BACKUP" "$ACL"
        pkill -HUP -f "ryu.conf"

        error "Los flows esperados no aparecieron"
    fi

    FIN_RECARGA=$(date +%s%3N)
    RECARGA_MS=$((FIN_RECARGA - INICIO_RECARGA))

    RESULTADO=$(probar_desde_h2 "$EXTRA")

    if [ "$RESULTADO" = "ERROR_H2_NO_ES_ALUMNO" ]; then
        error "h2 no tiene dirección de vlan_alumnos"
    fi

    read -r ALLOW_OK ALLOW_TOTAL DROP_OK <<< "$RESULTADO"

    ACL_RULES=$(contar_acl)

    FLOWS_R2=$(ssh $SSH_OPTS "$SW_ACC1" \
        "sudo ovs-ofctl -O OpenFlow13 \
         dump-flows sw-acc1 \
         | grep 'table=2' \
         | grep 'dl_vlan=100' \
         | grep 'nw_dst=10.0.1' \
         | wc -l")

    PORCENTAJE=$(awk \
        -v ok="$ALLOW_OK" \
        -v total="$ALLOW_TOTAL" \
        'BEGIN {printf "%.2f", ok*100/total}')

    if [ ! -f "$CSV" ]; then
        echo \
"fecha,recursos_reales,recursos_sinteticos,recursos_totales,acl_rules,flows_r2,validacion_ms,recarga_ms,allow_ok,allow_total,allow_pct,drop_ok" \
        > "$CSV"
    fi

    echo \
"$(date --iso-8601=seconds),$RECURSOS_REALES,$EXTRA,$TOTAL,$ACL_RULES,$FLOWS_R2,$VALIDACION_MS,$RECARGA_MS,$ALLOW_OK,$ALLOW_TOTAL,$PORCENTAJE,$DROP_OK" \
        >> "$CSV"

    echo
    echo "=============== RESULTADO ==============="
    echo "Recursos totales:         $TOTAL"
    echo "Recursos sintéticos:      $EXTRA"
    echo "Reglas acl_alumnos:       $ACL_RULES"
    echo "Flows R2 VLAN 100:        $FLOWS_R2"
    echo "Validación Faucet:        $VALIDACION_MS ms"
    echo "Instalación de flows:     $RECARGA_MS ms"
    echo "Recursos permitidos:      $ALLOW_OK/$ALLOW_TOTAL"
    echo "Porcentaje correcto:      $PORCENTAJE %"
    echo "Administración bloqueada: $DROP_OK"
    echo "CSV:                      $CSV"
    echo "========================================="
}

restaurar() {
    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$ACL"

        "$CHECK" "$FAUCET" \
            > /tmp/r2_recursos_restore.log 2>&1 \
            || error "El backup no pasó check_faucet_config"

        pkill -HUP -f "ryu.conf"
        sleep 3
    fi

    restaurar_servidor

    echo "ACL y servicio Biblioteca restaurados"
}

verificar_root

ACCION="${1:-}"

case "$ACCION" in
    run)
        ejecutar "${2:-}"
        ;;
    restore)
        restaurar
        ;;
    *)
        echo "Uso:"
        echo "  sudo $0 run TOTAL_RECURSOS"
        echo "  sudo $0 restore"
        exit 1
        ;;
esac
