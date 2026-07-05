#!/usr/bin/env python3
"""

"""
import json
import subprocess
import time
import os
from datetime import datetime

EVE_LOG = "/var/log/suricata/eve.json"
NODO_CTRL = "192.168.100.5"
CTRL_PORT = "5800"
BLOCK_SCRIPT = "/home/ubuntu/block_ip.sh"

# Reglas
NUESTRAS_REGLAS = {
    9000001: "SYN SCAN",
    9000002: "ICMP FLOOD DDOS",
    9000003: "SYN FLOOD DDOS",
    9000004: "UDP FLOOD DDOS",
    9000005: "FLOW EXHAUSTION TCP",
    9000006: "FLOW EXHAUSTION UDP",
}

# IPs que nunca bloquear
WHITELIST = {
    "192.168.100.1", "192.168.100.2", "192.168.100.3",
    "192.168.100.4", "192.168.100.5", "192.168.100.6",
    "192.168.100.7", "192.168.100.8", "192.168.100.9",
    "192.168.100.10", "192.168.100.11", "192.168.100.14",
    "127.0.0.1",
}

ips_bloqueadas = set()

def log(msg):
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] {msg}", flush=True)

def bloquear_ip(ip, motivo):
    if ip in WHITELIST:
        log(f"WHITELIST — no bloqueo {ip}")
        return
    if ip in ips_bloqueadas:
        log(f"YA BLOQUEADA — {ip}")
        return

    log(f"BLOQUEANDO {ip} — motivo: {motivo}")
    try:
        r = subprocess.run(
            ["ssh", "-p", CTRL_PORT,
             "-o", "StrictHostKeyChecking=no",
             "-o", "BatchMode=yes",
             f"ubuntu@{NODO_CTRL}",
             f"sudo {BLOCK_SCRIPT} {ip} block"],
            capture_output=True, text=True, timeout=30
        )
        if r.returncode == 0:
            ips_bloqueadas.add(ip)
            log(f"BLOQUEADA OK — {ip}")
            log(f"  stdout: {r.stdout.strip()}")
        else:
            log(f"ERROR bloqueando {ip}: {r.stderr.strip()}")
    except Exception as e:
        log(f"EXCEPCION bloqueando {ip}: {e}")

def seguir_eve():
    log(f"Iniciando watcher — leyendo {EVE_LOG}")
    log(f"Reglas monitoreadas: {list(NUESTRAS_REGLAS.values())}")
    log(f"Controlador: {NODO_CTRL}:{CTRL_PORT}")

    while not os.path.exists(EVE_LOG):
        log("Esperando eve.json...")
        time.sleep(2)

    with open(EVE_LOG, "r") as f:
        f.seek(0, 2)
        log("Listo — esperando alertas en tiempo real")

        while True:
            linea = f.readline()
            if not linea:
                time.sleep(0.1)
                continue
            try:
                evento = json.loads(linea.strip())
                if evento.get("event_type") != "alert":
                    continue

                alert = evento.get("alert", {})
                sid = alert.get("signature_id", 0)
                src_ip = evento.get("src_ip", "")
                signature = alert.get("signature", "")

                if sid not in NUESTRAS_REGLAS:
                    continue

                log(f"ALERTA sid:{sid} | {signature} | src:{src_ip}")
                bloquear_ip(src_ip, signature)

            except json.JSONDecodeError:
                pass
            except Exception as e:
                log(f"Error: {e}")

if __name__ == "__main__":
    seguir_eve()