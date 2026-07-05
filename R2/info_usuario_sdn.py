#!/usr/bin/env python3

import subprocess
import ipaddress
import socket
import argparse
from datetime import datetime

INTERFAZ_DATOS = "ens4"
INTERFAZ_GESTION = "ens3"

VLANES = [
    {
        "nombre": "vlan_alumnos",
        "rol": "Alumno",
        "red": "10.100.0.0/20",
        "gateway": "10.100.0.1",
        "descripcion": "Usuario estudiante con acceso limitado a servicios internos."
    },
    {
        "nombre": "vlan_docentes",
        "rol": "Docente",
        "red": "10.200.0.0/22",
        "gateway": "10.200.0.1",
        "descripcion": "Usuario docente con acceso a Investigación y Biblioteca Digital."
    },
    {
        "nombre": "vlan_administrativos",
        "rol": "Administrativo",
        "red": "10.30.0.0/24",
        "gateway": "10.30.0.1",
        "descripcion": "Usuario administrativo con acceso a servicios internos."
    },
    {
        "nombre": "vlan_invitados",
        "rol": "Invitado",
        "red": "10.40.0.0/24",
        "gateway": "10.40.0.1",
        "descripcion": "Usuario invitado sin acceso a servidores internos."
    },
    {
        "nombre": "vlan_cuarentena",
        "rol": "Cuarentena",
        "red": "192.168.99.0/24",
        "gateway": "192.168.99.1",
        "descripcion": "Host aislado o restringido por política de seguridad."
    },
]

SERVICIOS = [
    {
        "nombre": "Administración",
        "ip": "10.0.1.10",
        "puertos": [80, 443],
        "descripcion": "Servicio administrativo interno."
    },
    {
        "nombre": "Investigación",
        "ip": "10.0.1.20",
        "puertos": [80, 443],
        "descripcion": "Servicio de investigación."
    },
    {
        "nombre": "Gestión Académica",
        "ip": "10.0.1.30",
        "puertos": [80, 443],
        "descripcion": "Servicio de gestión académica."
    },
    {
        "nombre": "Biblioteca Digital",
        "ip": "10.0.1.40",
        "puertos": [80, 443],
        "descripcion": "Servicio de biblioteca digital."
    },
]

# Política esperada según las ACLs usadas en R2.
POLITICA = {
    "vlan_alumnos": {
        "10.0.1.10": [],
        "10.0.1.20": [],
        "10.0.1.30": [],
        "10.0.1.40": [80, 443],
    },
    "vlan_docentes": {
        "10.0.1.10": [],
        "10.0.1.20": [80, 443],
        "10.0.1.30": [],
        "10.0.1.40": [80, 443],
    },
    "vlan_administrativos": {
        "10.0.1.10": [80, 443],
        "10.0.1.20": [80, 443],
        "10.0.1.30": [80, 443],
        "10.0.1.40": [80, 443],
    },
    "vlan_invitados": {
        "10.0.1.10": [],
        "10.0.1.20": [],
        "10.0.1.30": [],
        "10.0.1.40": [],
    },
    "vlan_cuarentena": {
        "10.0.1.10": [],
        "10.0.1.20": [],
        "10.0.1.30": [],
        "10.0.1.40": [],
    },
}

def ejecutar(comando):
    try:
        resultado = subprocess.run(
            comando,
            shell=True,
            text=True,
            capture_output=True,
            timeout=5
        )
        return resultado.stdout.strip()
    except Exception:
        return ""

def obtener_hostname():
    salida = ejecutar("hostname")
    return salida if salida else "desconocido"

def obtener_ip_interfaz(interfaz):
    salida = ejecutar(f"ip -4 -o addr show dev {interfaz}")
    if not salida:
        return None

    partes = salida.split()
    for i, parte in enumerate(partes):
        if parte == "inet" and i + 1 < len(partes):
            return partes[i + 1]

    return None

def obtener_mac_interfaz(interfaz):
    salida = ejecutar(f"cat /sys/class/net/{interfaz}/address 2>/dev/null")
    return salida if salida else "-"

def obtener_gateway(interfaz):
    salida = ejecutar(f"ip route | grep '^default' | grep 'dev {interfaz}' | head -n 1")
    if not salida:
        return None

    partes = salida.split()
    if "via" in partes:
        idx = partes.index("via")
        if idx + 1 < len(partes):
            return partes[idx + 1]

    return None

def obtener_redes():
    return ejecutar("ip route")

def identificar_vlan(ip_cidr):
    if not ip_cidr:
        return None

    ip = ipaddress.ip_interface(ip_cidr).ip

    for vlan in VLANES:
        red = ipaddress.ip_network(vlan["red"])
        if ip in red:
            return vlan

    return None

def probar_tcp(ip, puerto, timeout):
    try:
        with socket.create_connection((ip, puerto), timeout=timeout):
            return True
    except Exception:
        return False

def imprimir_tabla(columnas, filas):
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
        description="Muestra información del usuario SDN según su IP/VLAN actual."
    )
    parser.add_argument(
        "--test",
        action="store_true",
        help="Realiza pruebas TCP de conectividad hacia servicios permitidos. No modifica configuración."
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=2.0,
        help="Timeout para pruebas TCP. Por defecto: 2 segundos."
    )

    args = parser.parse_args()

    hostname = obtener_hostname()
    ip_datos = obtener_ip_interfaz(INTERFAZ_DATOS)
    ip_gestion = obtener_ip_interfaz(INTERFAZ_GESTION)
    mac_datos = obtener_mac_interfaz(INTERFAZ_DATOS)
    gateway_actual = obtener_gateway(INTERFAZ_DATOS)
    vlan = identificar_vlan(ip_datos)

    print("")
    print("===================================================")
    print(" REPORTE LOCAL DEL USUARIO SDN")
    print("===================================================")
    print(f"Fecha/hora:       {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Host:             {hostname}")
    print(f"Modo:             SOLO LECTURA")
    print("")

    print("[INTERFACES]")
    print(f"Gestión {INTERFAZ_GESTION}:  {ip_gestion if ip_gestion else 'sin IP'}")
    print(f"Datos   {INTERFAZ_DATOS}:  {ip_datos if ip_datos else 'sin IP'}")
    print(f"MAC datos:        {mac_datos}")
    print("")

    if not ip_datos:
        print("No se encontró IP en ens4. El host no parece tener VLAN de usuario activa.")
        print("Revisa DHCP o renueva IP con: sudo dhclient -v ens4")
        return

    if not vlan:
        print("[ROL / VLAN]")
        print("No se pudo identificar la VLAN a partir de la IP actual.")
        print(f"IP detectada: {ip_datos}")
        return

    print("[ROL / VLAN DETECTADA]")
    print(f"Rol:              {vlan['rol']}")
    print(f"VLAN:             {vlan['nombre']}")
    print(f"Red esperada:     {vlan['red']}")
    print(f"Gateway esperado: {vlan['gateway']}")
    print(f"Gateway actual:   {gateway_actual if gateway_actual else 'no encontrado'}")
    print(f"Descripción:      {vlan['descripcion']}")

    if gateway_actual and gateway_actual != vlan["gateway"]:
        print("")
        print("ADVERTENCIA:")
        print("El gateway actual no coincide con el gateway esperado para esta VLAN.")

    print("")
    print("[SERVICIOS INTERNOS SEGÚN POLÍTICA]")
    filas = []
    politica_vlan = POLITICA.get(vlan["nombre"], {})

    for servicio in SERVICIOS:
        permitidos = politica_vlan.get(servicio["ip"], [])

        if permitidos:
            acceso = "PERMITIDO " + "/".join(str(p) for p in permitidos)
        else:
            acceso = "BLOQUEADO"

        estado = "-"

        if args.test:
            if 80 in permitidos:
                ok = probar_tcp(servicio["ip"], 80, args.timeout)
                estado = "CONECTA TCP/80" if ok else "NO CONECTA TCP/80"
            else:
                estado = "no probado"

        filas.append([
            servicio["nombre"],
            servicio["ip"],
            acceso,
            estado,
        ])

    imprimir_tabla(
        ["Servicio", "IP", "Acceso esperado", "Prueba real"],
        filas
    )

    print("")
    print("[RUTAS DEL HOST]")
    print(obtener_redes())

    print("")
    print("Nota:")
    print("- Este reporte se basa en la IP actual de ens4.")
    print("- No cambia VLANs, no edita ACLs y no toca ens3.")
    print("- Sin --test solo muestra la política esperada.")
    print("- Con --test intenta conexiones TCP de prueba, pero no modifica la red.")
    print("")

if __name__ == "__main__":
    main()