#!/usr/bin/env python3

import subprocess
from datetime import datetime

BRIDGE = "sw-servidores"

SERVIDORES = [
    {
        "servicio": "Administración",
        "namespace": "ns_adm",
        "interfaz": "administracion",
        "ip": "10.0.1.10",
        "gateway": "10.0.1.1",
        "ofport": "5",
        "usuarios": "Administrativos",
        "bloqueados": "Alumnos, Docentes, Invitados, Cuarentena",
        "log": "/tmp/ns_adm_http.log",
    },
    {
        "servicio": "Investigación",
        "namespace": "ns_inv",
        "interfaz": "investigacion",
        "ip": "10.0.1.20",
        "gateway": "10.0.1.1",
        "ofport": "6",
        "usuarios": "Docentes, Administrativos",
        "bloqueados": "Alumnos, Invitados, Cuarentena",
        "log": "/tmp/ns_inv_http.log",
    },
    {
        "servicio": "Gestión Académica",
        "namespace": "ns_ges",
        "interfaz": "gest_acad",
        "ip": "10.0.1.30",
        "gateway": "10.0.1.1",
        "ofport": "7",
        "usuarios": "Administrativos",
        "bloqueados": "Alumnos, Docentes, Invitados, Cuarentena",
        "log": "/tmp/ns_ges_http.log",
    },
    {
        "servicio": "Biblioteca Digital",
        "namespace": "ns_bib",
        "interfaz": "bib_digital",
        "ip": "10.0.1.40",
        "gateway": "10.0.1.1",
        "ofport": "8",
        "usuarios": "Alumnos, Docentes, Administrativos",
        "bloqueados": "Invitados, Cuarentena",
        "log": "/tmp/ns_bib_http.log",
    },
]

ENLACES = [
    {
        "nombre": "Ruta normal",
        "interfaz": "ens4",
        "ofport": "1",
        "conecta": "sw-core1 ens7",
        "funcion": "Enlace principal hacia servidores internos",
    },
    {
        "nombre": "Ruta failover",
        "interfaz": "ens5",
        "ofport": "2",
        "conecta": "sw-core2 ens7",
        "funcion": "Enlace alternativo hacia servidores internos",
    },
    {
        "nombre": "Gestión",
        "interfaz": "ens3",
        "ofport": "-",
        "conecta": "Red 192.168.100.0/24",
        "funcion": "SSH/gestión; no debe tocarse",
    },
]

def run(cmd, timeout=5):
    try:
        r = subprocess.run(
            cmd,
            shell=True,
            text=True,
            capture_output=True,
            timeout=timeout
        )
        return r.stdout.strip()
    except Exception:
        return ""

def existe_namespace(ns):
    salida = run("ip netns list")
    return any(line.split()[0] == ns for line in salida.splitlines())

def ip_namespace(ns, interfaz):
    salida = run(f"sudo ip netns exec {ns} ip -4 -br addr show {interfaz}")
    if not salida:
        return "-"
    partes = salida.split()
    for p in partes:
        if "/" in p and p[0].isdigit():
            return p
    return "-"

def gateway_namespace(ns):
    salida = run(f"sudo ip netns exec {ns} ip route")
    for line in salida.splitlines():
        if line.startswith("default via"):
            partes = line.split()
            if len(partes) >= 3:
                return partes[2]
    return "-"

def http_activo(ns, ip):
    salida = run(f"sudo ip netns exec {ns} ss -ltnp")
    if f"{ip}:80" in salida or ":80" in salida:
        return "ACTIVO"
    return "NO ACTIVO"

def curl_local(ns, ip):
    salida = run(f"sudo ip netns exec {ns} curl -s --max-time 2 http://{ip}", timeout=4)
    if salida:
        return salida.replace("\n", " ")[:70]
    return "SIN RESPUESTA"

def estado_linux_interfaz(interfaz):
    salida = run(f"ip -br link show {interfaz}")
    if not salida:
        return "-"
    partes = salida.split()
    if len(partes) >= 2:
        return partes[1]
    return "-"

def estado_ovs_puerto(ofport, interfaz):
    if ofport == "-":
        return "-"
    salida = run(
        f"sudo ovs-ofctl -O OpenFlow13 show {BRIDGE} | "
        f"grep -A4 '{ofport}({interfaz})'"
    )
    if "state:      LIVE" in salida:
        return "LIVE"
    if "LINK_DOWN" in salida:
        return "LINK_DOWN"
    if "PORT_DOWN" in salida:
        return "PORT_DOWN"
    if salida:
        return "REVISAR"
    return "NO ENCONTRADO"

def imprimir_tabla(titulo, columnas, filas):
    print("")
    print("=" * len(titulo))
    print(titulo)
    print("=" * len(titulo))

    if not filas:
        print("Sin datos.")
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
    print("")
    print("===================================================")
    print(" REPORTE LOCAL - SW-SERVIDORES / SERVICIOS R2")
    print("===================================================")
    print(f"Fecha/hora: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("Modo:       SOLO LECTURA")
    print("Bridge OVS: sw-servidores")
    print("")

    print("Este script NO cambia VLANs, NO edita Faucet, NO reinicia servicios y NO toca ens3.")
    print("Solo consulta interfaces, namespaces, rutas, puertos OVS y servicios HTTP.")

    filas_enlaces = []
    for e in ENLACES:
        filas_enlaces.append([
            e["nombre"],
            e["interfaz"],
            e["ofport"],
            estado_linux_interfaz(e["interfaz"]),
            estado_ovs_puerto(e["ofport"], e["interfaz"]),
            e["conecta"],
            e["funcion"],
        ])

    imprimir_tabla(
        "INTERFACES Y ENLACES DE SW-SERVIDORES",
        ["Nombre", "Interfaz", "OF", "Linux", "OVS", "Conecta con", "Función"],
        filas_enlaces
    )

    filas_servicios = []
    for s in SERVIDORES:
        ns_ok = "SI" if existe_namespace(s["namespace"]) else "NO"
        ip_real = ip_namespace(s["namespace"], s["interfaz"]) if ns_ok == "SI" else "-"
        gw_real = gateway_namespace(s["namespace"]) if ns_ok == "SI" else "-"
        http = http_activo(s["namespace"], s["ip"]) if ns_ok == "SI" else "-"
        ovs = estado_ovs_puerto(s["ofport"], s["interfaz"])

        filas_servicios.append([
            s["servicio"],
            s["namespace"],
            s["interfaz"],
            s["ofport"],
            s["ip"],
            ip_real,
            gw_real,
            http,
            ovs,
        ])

    imprimir_tabla(
        "SERVICIOS INTERNOS / NAMESPACES",
        ["Servicio", "Namespace", "Interfaz", "OF", "IP esperada", "IP real", "Gateway", "HTTP", "OVS"],
        filas_servicios
    )

    filas_acceso = []
    for s in SERVIDORES:
        filas_acceso.append([
            s["servicio"],
            s["ip"],
            s["usuarios"],
            s["bloqueados"],
        ])

    imprimir_tabla(
        "ACCESO ESPERADO POR TIPO DE USUARIO",
        ["Servicio", "IP", "Usuarios con acceso", "Usuarios bloqueados"],
        filas_acceso
    )

    filas_prueba = []
    for s in SERVIDORES:
        if existe_namespace(s["namespace"]):
            resultado = curl_local(s["namespace"], s["ip"])
        else:
            resultado = "NAMESPACE NO EXISTE"

        filas_prueba.append([
            s["servicio"],
            s["ip"],
            resultado,
        ])

    imprimir_tabla(
        "PRUEBA LOCAL DE SERVICIOS DESDE SU NAMESPACE",
        ["Servicio", "IP", "Respuesta local"],
        filas_prueba
    )

    filas_logs = []
    for s in SERVIDORES:
        ultima = run(f"sudo tail -n 1 {s['log']} 2>/dev/null")
        if not ultima:
            ultima = "Sin log o servicio no consultado"
        filas_logs.append([
            s["servicio"],
            s["log"],
            ultima[:90],
        ])

    imprimir_tabla(
        "ÚLTIMA LÍNEA DE LOG HTTP",
        ["Servicio", "Archivo log", "Último registro"],
        filas_logs
    )

    print("")
    print("LECTURA RÁPIDA:")
    print("- ens4 / OF1 representa la entrada normal desde sw-core1.")
    print("- ens5 / OF2 representa la entrada alternativa desde sw-core2.")
    print("- administracion, investigacion, gest_acad y bib_digital son interfaces internas hacia namespaces.")
    print("- Si una IP real aparece como '-' o HTTP aparece como 'NO ACTIVO', el problema está en el namespace o servicio.")
    print("- Si OF1 u OF2 no están LIVE, hay problema en el enlace de entrada hacia servidores.")
    print("")

if __name__ == "__main__":
    main()