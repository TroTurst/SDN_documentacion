#!/bin/bash

set -u

CSV="/tmp/r2_escalabilidad_sesiones_activas.csv"
DESTINO_IP="10.0.1.40"
DESTINO_PORT="80"
ADMIN_IP="10.0.1.10"
ADMIN_PORT="80"
HOLD_TIME="10"

if [ "$#" -ne 1 ]; then
    echo "Uso: $0 NUMERO_SESIONES"
    exit 1
fi

N="$1"

if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    echo "Cantidad inválida"
    exit 1
fi

python3 - "$N" "$CSV" "$DESTINO_IP" "$DESTINO_PORT" "$ADMIN_IP" "$ADMIN_PORT" "$HOLD_TIME" <<'PY'
import csv
import socket
import subprocess
import sys
import time
from datetime import datetime

n = int(sys.argv[1])
csv_path = sys.argv[2]
dst_ip = sys.argv[3]
dst_port = int(sys.argv[4])
admin_ip = sys.argv[5]
admin_port = int(sys.argv[6])
hold_time = int(sys.argv[7])

sockets = []
times = []

start_total = time.time()

for i in range(n):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)

    t0 = time.time()
    try:
        s.connect((dst_ip, dst_port))
        t1 = time.time()
        sockets.append(s)
        times.append((t1 - t0) * 1000)
    except Exception:
        s.close()

# Esperar para que las conexiones queden visibles como establecidas.
time.sleep(2)

cmd = (
    "ss -Htan state established "
    "| grep '" + dst_ip + ":" + str(dst_port) + "' "
    "| wc -l"
)

try:
    ss_established = int(
        subprocess.check_output(cmd, shell=True, text=True).strip()
    )
except Exception:
    ss_established = 0

# Control negativo hacia Administración.
try:
    s_admin = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s_admin.settimeout(2)
    s_admin.connect((admin_ip, admin_port))
    s_admin.close()
    admin_blocked = 0
except Exception:
    admin_blocked = 1

# Mantener sesiones activas.
time.sleep(hold_time)

for s in sockets:
    try:
        s.close()
    except Exception:
        pass

end_total = time.time()

established = len(sockets)
pct = (established / n) * 100 if n else 0
avg_ms = sum(times) / len(times) if times else 0
total_ms = (end_total - start_total) * 1000

header = [
    "fecha",
    "sesiones_solicitadas",
    "sesiones_establecidas",
    "establecidas_pct",
    "ss_established",
    "tiempo_prom_apertura_ms",
    "tiempo_total_ms",
    "admin_bloqueado"
]

row = [
    datetime.now().isoformat(timespec="seconds"),
    n,
    established,
    f"{pct:.2f}",
    ss_established,
    f"{avg_ms:.3f}",
    f"{total_ms:.3f}",
    admin_blocked
]

try:
    with open(csv_path, "r"):
        exists = True
except FileNotFoundError:
    exists = False

with open(csv_path, "a", newline="") as f:
    writer = csv.writer(f)
    if not exists:
        writer.writerow(header)
    writer.writerow(row)

print("=============== RESULTADO ===============")
print(f"Sesiones solicitadas:       {n}")
print(f"Sesiones establecidas:      {established}")
print(f"Porcentaje establecido:     {pct:.2f} %")
print(f"Sesiones vistas por ss:     {ss_established}")
print(f"Tiempo promedio apertura:   {avg_ms:.3f} ms")
print(f"Administración bloqueada:   {admin_blocked}")
print(f"CSV:                        {csv_path}")
print("=========================================")

sys.exit(0 if established == n and admin_blocked == 1 else 2)
PY
