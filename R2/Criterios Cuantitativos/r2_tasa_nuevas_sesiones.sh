#!/bin/bash

set -u

CSV="/tmp/r2_escalabilidad_tasa_sesiones.csv"
DST_IP="10.0.1.40"
DST_PORT="80"
ADMIN_IP="10.0.1.10"
ADMIN_PORT="80"
IFACE="ens4"

if [ "$#" -lt 1 ]; then
    echo "Uso: $0 TASA_SESIONES_POR_SEGUNDO [DURACION_SEGUNDOS]"
    exit 1
fi

RATE="$1"
DURATION="${2:-10}"

python3 - "$RATE" "$DURATION" "$CSV" "$DST_IP" "$DST_PORT" "$ADMIN_IP" "$ADMIN_PORT" "$IFACE" <<'PY'
import csv
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

rate = float(sys.argv[1])
duration = int(sys.argv[2])
csv_path = sys.argv[3]
dst_ip = sys.argv[4]
dst_port = int(sys.argv[5])
admin_ip = sys.argv[6]
admin_port = int(sys.argv[7])
iface = sys.argv[8]

total = int(rate * duration)
interval = 1.0 / rate if rate > 0 else 1.0

try:
    src_ip = subprocess.check_output(
        f"ip -4 -o addr show {iface} | awk '{{print $4}}' | cut -d/ -f1 | head -n1",
        shell=True,
        text=True
    ).strip()
except Exception:
    src_ip = ""

if not src_ip:
    print(f"No se encontró IP IPv4 en {iface}")
    sys.exit(1)

def one_request(scheduled_time):
    now = time.perf_counter()
    wait = scheduled_time - now
    if wait > 0:
        time.sleep(wait)

    t0 = time.perf_counter()
    ok = 0
    err = ""

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)

    try:
        s.bind((src_ip, 0))
        s.connect((dst_ip, dst_port))
        req = f"GET / HTTP/1.1\r\nHost: {dst_ip}\r\nConnection: close\r\n\r\n".encode()
        s.sendall(req)
        data = s.recv(128)
        if b"200" in data or b"HTTP/" in data:
            ok = 1
    except Exception as e:
        err = type(e).__name__
    finally:
        try:
            s.close()
        except Exception:
            pass

    t1 = time.perf_counter()
    return ok, (t1 - t0) * 1000, err

start = time.perf_counter()
scheduled_start = start + 0.5

max_workers = min(max(total, 1), 200)
results = []

with ThreadPoolExecutor(max_workers=max_workers) as ex:
    futures = []
    for i in range(total):
        futures.append(ex.submit(one_request, scheduled_start + i * interval))

    for f in as_completed(futures):
        results.append(f.result())

end = time.perf_counter()

successes = sum(1 for ok, _, _ in results if ok == 1)
errors = total - successes
latencies = [lat for ok, lat, _ in results if ok == 1]

success_pct = (successes / total) * 100 if total else 0
elapsed = end - scheduled_start
achieved_rate = successes / elapsed if elapsed > 0 else 0
avg_ms = sum(latencies) / len(latencies) if latencies else 0

if latencies:
    latencies_sorted = sorted(latencies)
    idx = max(int(len(latencies_sorted) * 0.95) - 1, 0)
    p95_ms = latencies_sorted[idx]
else:
    p95_ms = 0

# Control negativo hacia Administración.
admin_blocked = 0
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.bind((src_ip, 0))
    s.connect((admin_ip, admin_port))
    admin_blocked = 0
except Exception:
    admin_blocked = 1
finally:
    try:
        s.close()
    except Exception:
        pass

header = [
    "fecha",
    "tasa_objetivo_sps",
    "duracion_s",
    "intentos",
    "exitos",
    "errores",
    "exito_pct",
    "tasa_lograda_sps",
    "lat_prom_ms",
    "lat_p95_ms",
    "admin_bloqueado"
]

row = [
    datetime.now().isoformat(timespec="seconds"),
    f"{rate:.2f}",
    duration,
    total,
    successes,
    errors,
    f"{success_pct:.2f}",
    f"{achieved_rate:.2f}",
    f"{avg_ms:.3f}",
    f"{p95_ms:.3f}",
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
print(f"Tasa objetivo:          {rate:.2f} sesiones/s")
print(f"Duración:               {duration} s")
print(f"Intentos:               {total}")
print(f"Éxitos:                 {successes}")
print(f"Errores:                {errors}")
print(f"Éxito:                  {success_pct:.2f} %")
print(f"Tasa lograda:           {achieved_rate:.2f} sesiones/s")
print(f"Latencia promedio:      {avg_ms:.3f} ms")
print(f"Latencia p95:           {p95_ms:.3f} ms")
print(f"Administración bloqueada: {admin_blocked}")
print(f"CSV:                    {csv_path}")
print("=========================================")
PY
