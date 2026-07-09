#!/bin/bash
get_ip() {
    ip addr show ens4 | grep "inet " | awk '{print $2}' | cut -d/ -f1
}

IP_ACTUAL=$(get_ip)
echo "[*] IP actual: $IP_ACTUAL"

if [[ ! "$IP_ACTUAL" =~ ^192\.168\.99\. ]]; then
    echo "[!] h1 no está en cuarentena"
    exit 1
fi

echo "[*] Login como alumno1..."
T_INICIO=$(date +%s%3N)

curl -s -o /dev/null \
  -X POST http://192.168.99.1/login \
  -d "usuario=alumno1&password=pass123" \
  --max-time 60

T_PORTAL=$(date +%s%3N)
MS_PORTAL=$((T_PORTAL - T_INICIO))
echo "  Respuesta portal     : ${MS_PORTAL} ms"
echo "  Esperando nueva IP..."

for i in $(seq 1 60); do
    IP=$(get_ip)
    if [[ ! "$IP" =~ ^192\.168\.99\. ]] && [[ -n "$IP" ]]; then
        T_FIN=$(date +%s%3N)
        MS_TOTAL=$((T_FIN - T_INICIO))
        echo "  Nueva IP             : $IP"
        echo "==========================================="
        echo "  Latencia portal      : ${MS_PORTAL} ms"
        echo "  Tiempo total login   : ${MS_TOTAL} ms"
        echo "==========================================="
        exit 0
    fi
    sleep 1
done
echo "[!] IP no cambió en 60s"
