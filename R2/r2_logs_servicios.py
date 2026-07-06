#!/usr/bin/env python3

import re
import argparse
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
import ipaddress

LOGS = [
    {
        "servicio": "Administración",
        "ip_servicio": "10.0.1.10",
        "namespace": "ns_adm",
        "archivo": "/tmp/ns_adm_http.log",
    },
    {
        "servicio": "Investigación",
        "ip_servicio": "10.0.1.20",
        "namespace": "ns_inv",
        "archivo": "/tmp/ns_inv_http.log",
    },
    {
        "servicio": "Gestión Académica",
        "ip_servicio": "10.0.1.30",
        "namespace": "ns_ges",
        "archivo": "/tmp/ns_ges_http.log",
    },
    {
        "servicio": "Biblioteca Digital",
        "ip_servicio": "10.0.1.40",
        "namespace": "ns_bib",
        "archivo": "/tmp/ns_bib_http.log",
    },
]

REDES_USUARIOS = [
    ("Alumno", "vlan_alumnos", ipaddress.ip_network("10.100.0.0/20")),
    ("Docente", "vlan_docentes", ipaddress.ip_network("10.200.0.0/22")),
    ("Administrativo", "vlan_administrativos", ipaddress.ip_network("10.30.0.0/24")),
    ("Invitado", "vlan_invitados", ipaddress.ip_network("10.40.0.0/24")),
    ("Cuarentena", "vlan_cuarentena", ipaddress.ip_network("192.168.99.0/24")),
]

PATRON_LOG = re.compile(
    r'(?P<ip>\d+\.\d+\.\d+\.\d+)\s+-\s+-\s+'
    r'\[(?P<hora>[^\]]+)\]\s+'
    r'"(?P<metodo>[A-Z]+)\s+(?P<ruta>[^ ]+)\s+HTTP/[^"]+"\s+'
    r'(?P<codigo>\d{3})'
)

def identificar_usuario(ip_texto):
    try:
        ip = ipaddress.ip_address(ip_texto)
    except ValueError:
        return "Desconocido", "-"

    for rol, vlan, red in REDES_USUARIOS:
        if ip in red:
            return rol, vlan

    return "Externo/Desconocido", "-"

def interpretar_codigo(codigo):
    if codigo.startswith("2"):
        return "OK"
    if codigo.startswith("3"):
        return "REDIRECCIÓN"
    if codigo.startswith("4"):
        return "ERROR CLIENTE"
    if codigo.startswith("5"):
        return "ERROR SERVIDOR"
    return "REVISAR"

def parsear_hora(hora_raw):
    """
    Convierte la hora del log HTTP a hora peruana.

    Los logs de Python http.server suelen venir como:
    05/Jul/2026 20:01:29

    Se interpreta como UTC y se convierte a America/Lima.
    Perú normalmente está en UTC-5.
    """
    try:
        partes = hora_raw.split()
        fecha_hora = partes[0] + " " + partes[1]

        dt_utc = datetime.strptime(fecha_hora, "%d/%b/%Y %H:%M:%S")
        dt_utc = dt_utc.replace(tzinfo=ZoneInfo("UTC"))

        dt_peru = dt_utc.astimezone(ZoneInfo("America/Lima"))

        return dt_peru.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return hora_raw

def leer_eventos(limite):
    eventos = []

    for item in LOGS:
        ruta = Path(item["archivo"])

        if not ruta.exists():
            continue

        try:
            lineas = ruta.read_text(errors="ignore").splitlines()
        except PermissionError:
            print(f"ADVERTENCIA: no se pudo leer {item['archivo']}. Ejecuta con sudo.")
            continue

        for linea in lineas:
            match = PATRON_LOG.search(linea)
            if not match:
                continue

            ip_origen = match.group("ip")
            rol, vlan = identificar_usuario(ip_origen)
            codigo = match.group("codigo")

            eventos.append({
                "hora_peru": parsear_hora(match.group("hora")),
                "usuario": rol,
                "vlan": vlan,
                "ip_origen": ip_origen,
                "servicio": item["servicio"],
                "ip_servicio": item["ip_servicio"],
                "namespace": item["namespace"],
                "metodo": match.group("metodo"),
                "ruta": match.group("ruta"),
                "codigo": codigo,
                "resultado": interpretar_codigo(codigo),
            })

    eventos.sort(key=lambda x: x["hora_peru"])

    if limite and len(eventos) > limite:
        eventos = eventos[-limite:]

    return eventos

def imprimir_tabla(columnas, filas):
    if not filas:
        print("No hay conexiones registradas todavía.")
        return

    anchos = []

    for i, col in enumerate(columnas):
        ancho = len(col)
        for fila in filas:
            ancho = max(ancho, len(str(fila[i])))
        anchos.append(ancho)

    print("  ".join(columnas[i].ljust(anchos[i]) for i in range(len(columnas))))
    print("  ".join("-" * anchos[i] for i in range(len(columnas))))

    for fila in filas:
        print("  ".join(str(fila[i]).ljust(anchos[i]) for i in range(len(fila))))

def main():
    parser = argparse.ArgumentParser(
        description="Muestra logs amigables de conexiones a servicios internos R2 en hora peruana."
    )
    parser.add_argument(
        "-n", "--ultimos",
        type=int,
        default=30,
        help="Cantidad de eventos recientes a mostrar. Por defecto: 30."
    )
    parser.add_argument(
        "--servicio",
        choices=["administracion", "investigacion", "gestion", "biblioteca"],
        help="Filtra por servicio."
    )
    args = parser.parse_args()

    eventos = leer_eventos(args.ultimos)

    if args.servicio:
        filtro = {
            "administracion": "Administración",
            "investigacion": "Investigación",
            "gestion": "Gestión Académica",
            "biblioteca": "Biblioteca Digital",
        }[args.servicio]

        eventos = [e for e in eventos if e["servicio"] == filtro]

    print("")
    print("======================================================")
    print(" R2 - LOGS AMIGABLES DE SERVICIOS INTERNOS")
    print("======================================================")
    print("Modo: SOLO LECTURA")
    print("Fuente: /tmp/ns_*_http.log")
    print("Zona horaria mostrada: Perú / America-Lima")
    print("")

    filas = []

    for e in eventos:
        filas.append([
            e["hora_peru"],
            e["usuario"],
            e["vlan"],
            e["ip_origen"],
            e["servicio"],
            e["ip_servicio"],
            e["metodo"],
            e["codigo"],
            e["resultado"],
        ])

    imprimir_tabla(
        [
            "Hora Perú",
            "Usuario",
            "VLAN",
            "IP origen",
            "Servicio",
            "IP servicio",
            "Método",
            "HTTP",
            "Resultado",
        ],
        filas
    )

    print("")
    print("Resumen de lectura:")
    print("- Usuario se infiere por la IP origen.")
    print("- 10.100.0.0/20 = Alumno.")
    print("- 10.200.0.0/22 = Docente.")
    print("- 10.30.0.0/24 = Administrativo.")
    print("- 10.40.0.0/24 = Invitado.")
    print("- 192.168.99.0/24 = Cuarentena.")
    print("- Las horas del log se interpretan como UTC y se muestran en hora peruana.")
    print("")
    print("Nota: este script no modifica namespaces, servicios, VLANs ni Faucet.")
    print("")

if __name__ == "__main__":
    main()
