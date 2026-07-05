#!/bin/bash

set -u
set -o pipefail

YAML="/etc/faucet/faucet.yaml"
ACLS="/etc/faucet/acls.yaml"
PYTHON="/home/ubuntu/faucet-venv/bin/python3"

if [ ! -x "$PYTHON" ]; then
    PYTHON="python3"
fi

if [ ! -r "$YAML" ]; then
    echo "ERROR: no se puede leer $YAML"
    echo "Ejecuta con sudo:"
    echo "  sudo /home/ubuntu/mostrar_politicas_sdn.sh"
    exit 1
fi

if [ ! -r "$ACLS" ]; then
    echo "ERROR: no se puede leer $ACLS"
    echo "Ejecuta con sudo:"
    echo "  sudo /home/ubuntu/mostrar_politicas_sdn.sh"
    exit 1
fi

"$PYTHON" - "$YAML" "$ACLS" <<'PY'
import sys
import ipaddress
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: falta el modulo PyYAML.")
    print("Prueba ejecutando dentro del entorno faucet-venv o instala python3-yaml.")
    sys.exit(1)

faucet_path = Path(sys.argv[1])
acls_path = Path(sys.argv[2])

with faucet_path.open() as f:
    faucet = yaml.safe_load(f)

with acls_path.open() as f:
    acl_file = yaml.safe_load(f)

vlans = faucet.get("vlans", {})
dps = faucet.get("dps", {})
routers = faucet.get("routers", {})
acls = acl_file.get("acls", {})

SERVICIOS = [
    ("Administracion", "10.0.1.10", "administracion"),
    ("Investigacion", "10.0.1.20", "investigacion"),
    ("Gestion Academica", "10.0.1.30", "gest_acad"),
    ("Biblioteca Digital", "10.0.1.40", "bib_digital"),
]

VLANES_USUARIOS = [
    "vlan_alumnos",
    "vlan_docentes",
    "vlan_administrativos",
    "vlan_invitados",
    "vlan_cuarentena",
]

# Como vlan_cuarentena no tiene faucet_vips en el YAML,
# se usa la red esperada del laboratorio.
REDES_FALLBACK = {
    "vlan_cuarentena": "192.168.99.0/24"
}

def lista(valor):
    if valor is None:
        return []
    if isinstance(valor, list):
        return valor
    return [valor]

def texto(valor):
    if valor is None:
        return "-"
    if isinstance(valor, list):
        return ", ".join(str(x) for x in valor)
    return str(valor)

def tabla(titulo, columnas, filas):
    print("")
    print("=" * len(titulo))
    print(titulo)
    print("=" * len(titulo))

    if not filas:
        print("Sin datos.")
        return

    anchos = []
    for i, col in enumerate(columnas):
        maximo = len(col)
        for fila in filas:
            maximo = max(maximo, len(str(fila[i])))
        anchos.append(maximo)

    encabezado = "  ".join(col.ljust(anchos[i]) for i, col in enumerate(columnas))
    separador = "  ".join("-" * anchos[i] for i in range(len(columnas)))

    print(encabezado)
    print(separador)

    for fila in filas:
        print("  ".join(str(fila[i]).ljust(anchos[i]) for i in range(len(columnas))))

def int_auto(valor):
    if isinstance(valor, int):
        return valor
    if isinstance(valor, str):
        return int(valor, 0)
    return int(valor)

def red_de_vlan(nombre_vlan):
    datos = vlans.get(nombre_vlan, {})
    vips = lista(datos.get("faucet_vips"))

    if vips:
        try:
            interfaz = ipaddress.ip_interface(str(vips[0]))
            return interfaz.network
        except Exception:
            return None

    if nombre_vlan in REDES_FALLBACK:
        return ipaddress.ip_network(REDES_FALLBACK[nombre_vlan], strict=False)

    return None

def ip_origen_representativa(nombre_vlan):
    red = red_de_vlan(nombre_vlan)
    if red is None:
        return None

    hosts = list(red.hosts())
    if len(hosts) >= 10:
        return hosts[9]
    if hosts:
        return hosts[-1]
    return None

def acl_de_vlan(nombre_vlan):
    datos = vlans.get(nombre_vlan, {})
    acls_in = lista(datos.get("acls_in"))
    if acls_in:
        return acls_in[0]
    return "-"

def accion_allow(rule):
    acciones = rule.get("actions", {})
    return int(acciones.get("allow", 0)) == 1

def regla_coincide(rule, vlan_origen, ip_destino, puerto_tcp):
    # Evaluamos tráfico IPv4 TCP desde una VLAN de usuario hacia un servidor.
    src_ip = ip_origen_representativa(vlan_origen)
    dst_ip = ipaddress.ip_address(ip_destino)

    if "dl_type" in rule:
        try:
            if int_auto(rule["dl_type"]) != 0x0800:
                return False
        except Exception:
            return False

    if "ip_proto" in rule:
        try:
            if int(rule["ip_proto"]) != 6:
                return False
        except Exception:
            return False

    # Si la regla habla de UDP, no aplica para este analisis TCP.
    if "udp_dst" in rule:
        return False

    if "tcp_dst" in rule:
        try:
            if int(rule["tcp_dst"]) != int(puerto_tcp):
                return False
        except Exception:
            return False

    if "ipv4_dst" in rule:
        try:
            red_dst = ipaddress.ip_network(str(rule["ipv4_dst"]), strict=False)
            if dst_ip not in red_dst:
                return False
        except Exception:
            return False

    if "ipv4_src" in rule:
        if src_ip is None:
            return False
        try:
            red_src = ipaddress.ip_network(str(rule["ipv4_src"]), strict=False)
            if src_ip not in red_src:
                return False
        except Exception:
            return False

    return True

def permitido_por_acl(nombre_vlan, nombre_acl, ip_destino, puerto_tcp):
    if nombre_acl == "-" or nombre_acl not in acls:
        return None

    reglas = acls.get(nombre_acl, [])

    for item in reglas:
        rule = item.get("rule", item)
        if regla_coincide(rule, nombre_vlan, ip_destino, puerto_tcp):
            return accion_allow(rule)

    return False

def resumen_acceso(nombre_vlan, ip_destino):
    nombre_acl = acl_de_vlan(nombre_vlan)

    r80 = permitido_por_acl(nombre_vlan, nombre_acl, ip_destino, 80)
    r443 = permitido_por_acl(nombre_vlan, nombre_acl, ip_destino, 443)

    if r80 is None and r443 is None:
        return "SIN ACL"

    if r80 and r443:
        return "SI 80/443"
    if r80 and not r443:
        return "SI 80"
    if r443 and not r80:
        return "SI 443"
    return "NO"

print("")
print("======================================================")
print(" REPORTE SDN / FAUCET - POLITICAS Y MATRIZ DE ACCESO")
print("======================================================")
print("")
print("Modo: SOLO LECTURA")
print(f"Archivo Faucet: {faucet_path}")
print(f"Archivo ACLs:   {acls_path}")

# VLANs
filas_vlan = []
for nombre, datos in sorted(vlans.items(), key=lambda x: x[1].get("vid", 99999)):
    filas_vlan.append([
        nombre,
        datos.get("vid", "-"),
        texto(datos.get("faucet_vips")),
        datos.get("faucet_mac", "-"),
        texto(datos.get("acls_in")),
    ])

tabla(
    "VLANs, GATEWAYS Y ACLs",
    ["VLAN", "VID", "Gateway / VIP", "MAC Faucet", "ACL VLAN"],
    filas_vlan
)

# Router
filas_router = []
for nombre, datos in routers.items():
    filas_router.append([
        nombre,
        texto(datos.get("vlans"))
    ])

tabla(
    "ROUTERS FAUCET",
    ["Router", "VLANs enrutadas"],
    filas_router
)

# Usuarios dinamicos de sw-acc1
filas_hosts = []
swacc = dps.get("sw-acc1", {})
interfaces = swacc.get("interfaces", {})

for puerto, datos in sorted(interfaces.items(), key=lambda x: int(x[0])):
    desc = str(datos.get("description", ""))
    if "acceso dinamico" in desc:
        host = "h1" if "h1" in desc else "h2" if "h2" in desc else "-"
        filas_hosts.append([
            host,
            "sw-acc1",
            puerto,
            datos.get("name", "-"),
            datos.get("native_vlan", "-"),
            texto(datos.get("acls_in")),
            desc,
        ])

tabla(
    "USUARIOS DINAMICOS SEGUN YAML",
    ["Host", "Switch", "Puerto OF", "Interfaz", "VLAN actual", "ACL aplicada", "Descripcion"],
    filas_hosts
)

# Servicios internos
filas_servicios = []
swserv = dps.get("sw-servidores", {})
interfaces_serv = swserv.get("interfaces", {})

for servicio, ip, interfaz in SERVICIOS:
    puerto_of = "-"
    vlan = "-"
    descripcion = "-"

    for puerto, datos in interfaces_serv.items():
        if datos.get("name") == interfaz:
            puerto_of = puerto
            vlan = datos.get("native_vlan", "-")
            descripcion = datos.get("description", "-")
            break

    filas_servicios.append([
        servicio,
        ip,
        "sw-servidores",
        puerto_of,
        interfaz,
        vlan,
        descripcion,
    ])

tabla(
    "SERVICIOS INTERNOS",
    ["Servicio", "IP", "Switch", "Puerto OF", "Interfaz", "VLAN", "Descripcion"],
    filas_servicios
)

# Matriz de acceso
filas_matriz = []
for vlan in VLANES_USUARIOS:
    fila = [
        vlan,
        acl_de_vlan(vlan)
    ]

    for servicio, ip, interfaz in SERVICIOS:
        fila.append(resumen_acceso(vlan, ip))

    filas_matriz.append(fila)

tabla(
    "MATRIZ DE ACCESO LOGICA HACIA SERVIDORES",
    [
        "VLAN / Rol",
        "ACL",
        "Administracion",
        "Investigacion",
        "Gestion Acad.",
        "Biblioteca",
    ],
    filas_matriz
)

# Resumen por usuario actual
filas_resumen = []
for fila_host in filas_hosts:
    host = fila_host[0]
    vlan_actual = fila_host[4]
    acl_actual = fila_host[5]

    accesos = []
    for servicio, ip, interfaz in SERVICIOS:
        accesos.append(f"{servicio}: {resumen_acceso(vlan_actual, ip)}")

    filas_resumen.append([
        host,
        vlan_actual,
        acl_actual,
        " | ".join(accesos)
    ])

tabla(
    "RESUMEN DE ACCESO DE h1/h2 SEGUN SU VLAN ACTUAL",
    ["Host", "VLAN actual", "ACL", "Accesos esperados"],
    filas_resumen
)

# Observaciones automaticas
observaciones = []

for nombre_acl, reglas in acls.items():
    for idx, item in enumerate(reglas, start=1):
        rule = item.get("rule", item)
        allow = accion_allow(rule)

        if nombre_acl == "acl_cuarentena" and allow:
            if "ipv4_src" in rule and "ipv4_dst" not in rule and "tcp_dst" not in rule and "udp_dst" not in rule:
                observaciones.append(
                    f"acl_cuarentena regla {idx}: permite trafico IPv4 por origen {rule.get('ipv4_src')} sin restringir destino."
                )

            if "tcp_dst" in rule and int(rule.get("tcp_dst")) == 80 and "ipv4_dst" not in rule:
                observaciones.append(
                    f"acl_cuarentena regla {idx}: permite TCP/80 sin restringir destino. Esto podria permitir HTTP hacia mas destinos de los esperados."
                )

if observaciones:
    print("")
    print("========================")
    print("OBSERVACIONES IMPORTANTES")
    print("========================")
    for obs in observaciones:
        print(f"- {obs}")

print("")
print("Nota:")
print("- Esta matriz representa la politica configurada en YAML/ACL.")
print("- No prueba si el servicio HTTP esta encendido.")
print("- No prueba conectividad real con curl.")
print("- Para validar operacion real, complementar con pruebas desde h1/h2.")
print("")
PY