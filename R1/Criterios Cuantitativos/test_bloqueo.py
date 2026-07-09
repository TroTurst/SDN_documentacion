#!/usr/bin/env python3
import os, time, urllib.request, urllib.parse

PORTAL_IP   = "192.168.99.1"
IFACE       = "ens4"
TOTAL       = 200
USUARIO     = "atacante"
PASSWORD    = "password_incorrecta"
BASE_IP     = "192.168.99"
START_OCTET = 10

bloqueados = errores = 0

print(f"[*] Iniciando prueba — {TOTAL} intentos con credenciales inválidas")
print("=" * 60)

for i in range(TOTAL):
    octet = START_OCTET + (i % 90)
    ip_src = f"{BASE_IP}.{octet}"
    os.system(f"sudo ip addr add {ip_src}/24 dev {IFACE} 2>/dev/null")
    time.sleep(0.05)

    try:
        data = urllib.parse.urlencode({
            "usuario": USUARIO, "password": PASSWORD
        }).encode()
        req = urllib.request.Request(
            f"http://{PORTAL_IP}/login", data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"}
        )
        with urllib.request.urlopen(req, timeout=5) as r:
            body = r.read().decode()
        if "incorrectos" in body or "error" in body.lower():
            bloqueados += 1
            if i % 20 == 0:
                print(f"  [{i+1:03d}/{TOTAL}] BLOQUEADO  IP:{ip_src}")
        else:
            errores += 1
            print(f"  [{i+1:03d}/{TOTAL}] INESPERADO IP:{ip_src}")
    except Exception as e:
        errores += 1
        if i % 20 == 0:
            print(f"  [{i+1:03d}/{TOTAL}] ERROR      IP:{ip_src} → {e}")
    finally:
        os.system(f"sudo ip addr del {ip_src}/24 dev {IFACE} 2>/dev/null")
    time.sleep(0.05)

print()
print("=" * 60)
print(f"Total intentos          : {TOTAL}")
print(f"Bloqueados correctamente: {bloqueados}")
print(f"Resultados inesperados  : {errores}")
print(f"Tasa de bloqueo         : {bloqueados/TOTAL*100:.1f}%")
print("=" * 60)
