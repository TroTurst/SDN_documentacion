#!/usr/bin/env python3
"""
acl_policy_manager.py

Gestor interactivo de ACLs para R2 en MODO COPIA SEGURA.

Archivo real protegido:
    /etc/faucet/acls.yaml

Archivo de prueba que modifica el script:
    /home/ubuntu/acls_manager/acls_prueba.yaml

Archivo Faucet usado solo para revisar referencias:
    /etc/faucet/faucet.yaml

IMPORTANTE:
- No modifica /etc/faucet/acls.yaml.
- No recarga Faucet.
- No toca interfaces.
- No toca ens3.
- Solo modifica la copia: /home/ubuntu/acls_manager/acls_prueba.yaml
"""

import re
import shutil
import subprocess
from pathlib import Path
from datetime import datetime

try:
    import yaml
except ImportError:
    print("ERROR: falta python3-yaml.")
    print("Instala con:")
    print("  sudo apt update && sudo apt install -y python3-yaml")
    raise SystemExit(1)


REAL_ACLS_PATH = Path("/etc/faucet/acls.yaml")
WORK_DIR = Path("/home/ubuntu/acls_manager")
ACLS_PATH = WORK_DIR / "acls_prueba.yaml"
FAUCET_PATH = Path("/etc/faucet/faucet.yaml")

INTERNAL_NET = "10.0.1.0/24"

PROTECTED_ACLS = {
    "acl_alumnos",
    "acl_docentes",
    "acl_administrativos",
    "acl_invitados",
    "acl_cuarentena",
}

SERVICE_TO_IP = {
    "administracion": "10.0.1.10/32",
    "investigacion": "10.0.1.20/32",
    "gestion": "10.0.1.30/32",
    "biblioteca": "10.0.1.40/32",
}

SERVICE_LABEL = {
    "administracion": "Administracion",
    "investigacion": "Investigacion",
    "gestion": "Gestion Academica",
    "biblioteca": "Biblioteca Digital",
}

PROTO_TO_NUMBER = {
    "tcp": 6,
    "udp": 17,
    "icmp": 1,
    "ip": None,
}

PROTO_NUMBER_TO_NAME = {
    6: "tcp",
    17: "udp",
    1: "icmp",
}


def run_cmd(cmd):
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def init_working_copy():
    WORK_DIR.mkdir(parents=True, exist_ok=True)

    if not REAL_ACLS_PATH.exists():
        print(f"ERROR: no existe el archivo original {REAL_ACLS_PATH}")
        raise SystemExit(1)

    if not ACLS_PATH.exists():
        shutil.copy2(REAL_ACLS_PATH, ACLS_PATH)
        print("\nCopia de trabajo creada desde el archivo original:")
        print(f"  Original: {REAL_ACLS_PATH}")
        print(f"  Copia:    {ACLS_PATH}")
    else:
        print("\nUsando copia de trabajo existente:")
        print(f"  {ACLS_PATH}")


def load_yaml(path: Path):
    if not path.exists():
        print(f"ERROR: no existe {path}")
        raise SystemExit(1)

    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    if data is None:
        data = {}

    if "acls" not in data:
        print(f"ERROR: {path} no contiene la seccion 'acls:'")
        raise SystemExit(1)

    if not isinstance(data["acls"], dict):
        print("ERROR: la seccion 'acls' no tiene formato valido.")
        raise SystemExit(1)

    return data


def save_yaml(path: Path, data):
    with path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(
            data,
            f,
            default_flow_style=False,
            sort_keys=False,
            allow_unicode=True,
            indent=2,
        )


def backup_file(path: Path):
    if not path.exists():
        return None

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = path.with_suffix(path.suffix + f".backup_r2_{stamp}")
    shutil.copy2(path, backup)
    return backup


def restore_backup(backup: Path, target: Path):
    if backup and backup.exists():
        shutil.copy2(backup, target)


def apply_and_validate(data, action_name):
    print("\nArchivo de trabajo usado:")
    print(f"  {ACLS_PATH}")

    print("\nArchivo original protegido:")
    print(f"  {REAL_ACLS_PATH}")

    backup = backup_file(ACLS_PATH)

    if backup:
        print(f"Backup de la copia creado: {backup}")
    else:
        print("No existia copia previa. Se creara una nueva.")

    try:
        save_yaml(ACLS_PATH, data)
        print(f"Cambios escritos SOLO en la copia: {ACLS_PATH}")
    except Exception as exc:
        print(f"ERROR escribiendo YAML: {exc}")
        restore_backup(backup, ACLS_PATH)
        print("Backup de la copia restaurado.")
        return False

    try:
        reloaded = load_yaml(ACLS_PATH)
        print("\nValidacion basica de YAML: OK")
        print(f"Total de ACLs en la copia: {len(reloaded.get('acls', {}))}")
    except Exception as exc:
        print(f"\nValidacion basica de YAML fallida: {exc}")
        restore_backup(backup, ACLS_PATH)
        print("Backup de la copia restaurado.")
        return False

    print("\n====================================================")
    print(f" {action_name} aplicado correctamente en la COPIA")
    print("====================================================")

    print("\nIMPORTANTE:")
    print("No se modifico /etc/faucet/acls.yaml")
    print("No se recargo Faucet")
    print("No se tocaron interfaces")
    print("No se toco ens3")

    print("\nPara comparar copia vs original:")
    print(f"  diff -u {REAL_ACLS_PATH} {ACLS_PATH}")

    return True


def normalize_name(name: str):
    name = name.strip().lower()
    name = name.replace(" ", "_")
    name = re.sub(r"[^a-z0-9_]", "", name)
    name = re.sub(r"_+", "_", name).strip("_")
    return name


def role_to_acl(role_name: str):
    role = normalize_name(role_name)
    return f"acl_{role}"


def acl_to_role(acl_name: str):
    if acl_name.startswith("acl_"):
        return acl_name[4:]
    return acl_name


def get_role_to_acl_from_yaml(data):
    result = {}

    for acl_name in data["acls"].keys():
        if acl_name.startswith("acl_"):
            result[acl_to_role(acl_name)] = acl_name

    return dict(sorted(result.items()))


def normalize_rule_entry(entry):
    if not isinstance(entry, dict):
        return {}

    if "rule" in entry and isinstance(entry["rule"], dict):
        return entry["rule"]

    return entry


def ask_option(title, options, allow_back=True):
    while True:
        print(title)

        if allow_back:
            print("  0) volver")

        for i, opt in enumerate(options, start=1):
            print(f"  {i}) {opt}")

        ans = input("> ").strip().lower()

        if allow_back and ans in ("0", "volver", "v"):
            return None

        if ans.isdigit():
            idx = int(ans)
            if 1 <= idx <= len(options):
                return options[idx - 1]

        if ans in options:
            return ans

        print("Opcion invalida. Intenta otra vez.\n")


def ask_port(proto):
    if proto not in ("tcp", "udp"):
        return None

    while True:
        raw = input("Puerto destino, ejemplo 80 o 443. Escribe 0 para volver: ").strip().lower()

        if raw in ("0", "volver", "v"):
            return "volver"

        if raw.isdigit():
            port = int(raw)
            if 1 <= port <= 65535:
                return port

        print("Puerto invalido. Debe estar entre 1 y 65535.")


def get_rule_action(rule):
    actions = rule.get("actions", {})
    if isinstance(actions, dict):
        return actions.get("allow", "-")
    return "-"


def get_rule_proto_name(rule):
    proto = rule.get("ip_proto", None)

    if proto is None:
        return "ip"

    return PROTO_NUMBER_TO_NAME.get(proto, str(proto))


def classify_rule(rule):
    allow = get_rule_action(rule)
    dst = str(rule.get("ipv4_dst", "-"))

    if dst == INTERNAL_NET and allow == 0:
        return "CRITICA: bloqueo general a recursos internos"

    if dst == INTERNAL_NET and allow == 1:
        return "CRITICA: permiso general a recursos internos"

    if dst == "-" and allow == 1:
        return "BASE: catch-all allow"

    if dst == "-" and allow == 0:
        return "BASE: catch-all drop"

    if dst.startswith("10.0.1."):
        return "RECURSO_CRITICO"

    if dst.startswith("192.168.99."):
        return "CUARENTENA"

    return "NORMAL"


def format_rule_line(idx, entry):
    rule = normalize_rule_entry(entry)
    dst = rule.get("ipv4_dst", "-")
    proto = get_rule_proto_name(rule)
    tcp_dst = rule.get("tcp_dst", "-")
    udp_dst = rule.get("udp_dst", "-")
    allow = get_rule_action(rule)
    clasif = classify_rule(rule)

    action_txt = "ALLOW" if allow == 1 else "DROP" if allow == 0 else str(allow)

    return (
        f"{idx:02d}) dst={dst}, proto={proto}, "
        f"tcp_dst={tcp_dst}, udp_dst={udp_dst}, action={action_txt} | {clasif}"
    )


def get_acl_rules(data, acl_name):
    if acl_name not in data["acls"]:
        print(f"ERROR: no existe {acl_name}")
        return None

    rules = data["acls"][acl_name]

    if rules is None:
        rules = []
        data["acls"][acl_name] = rules

    if not isinstance(rules, list):
        print(f"ERROR: {acl_name} no es una lista de reglas.")
        return None

    return rules


def build_default_acl_template(template):
    if template == "seguro":
        return [
            {
                "rule": {
                    "dl_type": 0x0800,
                    "ipv4_dst": INTERNAL_NET,
                    "actions": {"allow": 0},
                }
            },
            {
                "rule": {
                    "actions": {"allow": 1},
                }
            },
        ]

    if template == "admins":
        return [
            {
                "rule": {
                    "dl_type": 0x0800,
                    "ipv4_dst": INTERNAL_NET,
                    "actions": {"allow": 1},
                }
            },
            {
                "rule": {
                    "actions": {"allow": 1},
                }
            },
        ]

    return []


def build_rule(service_ip, proto, action, port):
    rule = {
        "dl_type": 0x0800,
        "ipv4_dst": service_ip,
        "actions": {
            "allow": 1 if action == "allow" else 0
        },
    }

    proto_num = PROTO_TO_NUMBER[proto]

    if proto_num is not None:
        rule["ip_proto"] = proto_num

    if proto == "tcp" and port is not None:
        rule["tcp_dst"] = port

    if proto == "udp" and port is not None:
        rule["udp_dst"] = port

    return {"rule": rule}


def rules_equal(a, b):
    return normalize_rule_entry(a) == normalize_rule_entry(b)


def find_general_block_index(rules):
    for idx, entry in enumerate(rules):
        rule = normalize_rule_entry(entry)
        actions = rule.get("actions", {})

        if (
            rule.get("ipv4_dst") == INTERNAL_NET
            and isinstance(actions, dict)
            and actions.get("allow") == 0
        ):
            return idx

    return None


def find_last_allow_all_index(rules):
    for idx in range(len(rules) - 1, -1, -1):
        rule = normalize_rule_entry(rules[idx])
        actions = rule.get("actions", {})

        if (
            isinstance(actions, dict)
            and actions.get("allow") == 1
            and "ipv4_dst" not in rule
        ):
            return idx

    return None


def rule_matches_filter(rule, filter_mode, filter_value=None):
    allow = get_rule_action(rule)
    dst = str(rule.get("ipv4_dst", "-"))
    proto_name = get_rule_proto_name(rule)

    if filter_mode == "todas":
        return True

    if filter_mode == "allow":
        return allow == 1

    if filter_mode == "drop":
        return allow == 0

    if filter_mode == "recursos_criticos":
        return dst.startswith("10.0.1.") or dst == INTERNAL_NET

    if filter_mode == "bloqueos_generales":
        return dst == INTERNAL_NET and allow == 0

    if filter_mode == "catch_all":
        return dst == "-"

    if filter_mode == "protocolo":
        return proto_name == filter_value

    if filter_mode == "servicio":
        return dst == SERVICE_TO_IP.get(filter_value)

    return True


def find_acl_references_in_faucet(acl_name):
    if not FAUCET_PATH.exists():
        return []

    refs = []

    try:
        with FAUCET_PATH.open("r", encoding="utf-8") as f:
            for lineno, line in enumerate(f, start=1):
                if acl_name in line:
                    refs.append((lineno, line.rstrip()))
    except PermissionError:
        print(f"No se pudo leer {FAUCET_PATH}. Ejecuta con sudo si quieres revisar referencias.")
        return []

    return refs


def print_single_acl(data, role, acl_name):
    rules = data["acls"].get(acl_name, [])

    if rules is None:
        rules = []

    print("\n====================================================")
    print(f" ACL seleccionada: {acl_name}")
    print("====================================================")
    print(f"Rol: {role}")
    print(f"Cantidad de reglas: {len(rules)}")

    for idx, entry in enumerate(rules, start=1):
        print("  " + format_rule_line(idx, entry))


def list_acls(data):
    role_to_acl = get_role_to_acl_from_yaml(data)

    if not role_to_acl:
        print("No existen ACLs tipo acl_<rol>.")
        return

    options = ["todas"] + list(role_to_acl.keys())

    selected = ask_option(
        "\nQue ACL deseas listar?",
        options,
        allow_back=True
    )

    if selected is None:
        print("Volviendo al menu principal.")
        return

    if selected == "todas":
        for role, acl_name in role_to_acl.items():
            print_single_acl(data, role, acl_name)
    else:
        acl_name = role_to_acl[selected]
        print_single_acl(data, selected, acl_name)


def create_acl(data):
    role = None
    step = 0

    while True:
        if step == 0:
            print("\n====================================================")
            print(" Crear nueva seccion acl_<rol>")
            print("====================================================")

            raw_role = input("Nombre del nuevo rol, ejemplo laboratorios. Escribe 0 para volver: ").strip()

            if raw_role.lower() in ("0", "volver", "v"):
                print("Volviendo al menu principal.")
                return False

            role = normalize_name(raw_role)

            if not role:
                print("Nombre invalido.")
                continue

            acl_name = role_to_acl(role)

            if acl_name in data["acls"]:
                print(f"La ACL {acl_name} ya existe.")
                return False

            step = 1

        elif step == 1:
            template = ask_option(
                "\nSelecciona plantilla inicial:",
                ["seguro", "admins", "vacio"],
                allow_back=True
            )

            if template is None:
                step = 0
                continue

            acl_name = role_to_acl(role)
            data["acls"][acl_name] = build_default_acl_template(template)

            print("\nSe generara esta seccion:")
            print(yaml.safe_dump(
                {acl_name: data["acls"][acl_name]},
                default_flow_style=False,
                sort_keys=False,
                allow_unicode=True,
            ))

            confirm = input("Crear esta ACL? [s/N]. Escribe 0 para volver: ").strip().lower()

            if confirm in ("0", "volver", "v"):
                del data["acls"][acl_name]
                step = 1
                continue

            if confirm != "s":
                del data["acls"][acl_name]
                print("Cancelado.")
                return False

            return True


def add_rule(data):
    print("\n====================================================")
    print(" Agregar regla allow/drop")
    print("====================================================")

    role_to_acl = get_role_to_acl_from_yaml(data)

    if not role_to_acl:
        print("No hay ACLs disponibles. Primero crea una ACL.")
        return False

    role = None
    service = None
    proto = None
    port = None
    action = None

    step = 0

    while True:
        if step == 0:
            role = ask_option(
                "\nSelecciona rol/ACL:",
                list(role_to_acl.keys()),
                allow_back=True
            )

            if role is None:
                print("Volviendo al menu principal.")
                return False

            step = 1

        elif step == 1:
            service = ask_option(
                "\nSelecciona recurso critico:",
                list(SERVICE_TO_IP.keys()),
                allow_back=True
            )

            if service is None:
                step = 0
                continue

            step = 2

        elif step == 2:
            proto = ask_option(
                "\nSelecciona protocolo:",
                list(PROTO_TO_NUMBER.keys()),
                allow_back=True
            )

            if proto is None:
                step = 1
                continue

            if proto in ("tcp", "udp"):
                step = 3
            else:
                port = None
                step = 4

        elif step == 3:
            port = ask_port(proto)

            if port == "volver":
                step = 2
                continue

            step = 4

        elif step == 4:
            action = ask_option(
                "\nSelecciona accion:",
                ["allow", "drop"],
                allow_back=True
            )

            if action is None:
                if proto in ("tcp", "udp"):
                    step = 3
                else:
                    step = 2
                continue

            step = 5

        elif step == 5:
            acl_name = role_to_acl[role]
            service_ip = SERVICE_TO_IP[service]
            service_label = SERVICE_LABEL[service]

            rules = get_acl_rules(data, acl_name)

            if rules is None:
                return False

            new_rule = build_rule(service_ip, proto, action, port)

            print("\n====================================================")
            print(" Resumen de regla")
            print("====================================================")
            print(f"Rol:        {role}")
            print(f"ACL:        {acl_name}")
            print(f"Servicio:   {service_label}")
            print(f"IP destino: {service_ip}")
            print(f"Protocolo:  {proto.upper()}")
            print(f"Puerto:     {port if port else '-'}")
            print(f"Accion:     {'PERMITIR' if action == 'allow' else 'DENEGAR'}")

            print("\nRegla generada:")
            print(yaml.safe_dump(
                new_rule,
                default_flow_style=False,
                sort_keys=False,
                allow_unicode=True,
            ))

            for existing in rules:
                if rules_equal(existing, new_rule):
                    print("La regla ya existe. No se realizaran cambios.")
                    return False

            idx = find_general_block_index(rules)

            if idx is None:
                print(f"No se encontro bloqueo general hacia {INTERNAL_NET}.")
                idx = find_last_allow_all_index(rules)

            if idx is None:
                print("No se encontro punto seguro. La regla ira al final.")
                idx = len(rules)
            else:
                print(f"La regla se insertara en la posicion {idx + 1}.")

            confirm = input("\nAplicar regla? [s/N]. Escribe 0 para volver: ").strip().lower()

            if confirm in ("0", "volver", "v"):
                step = 4
                continue

            if confirm != "s":
                print("Cancelado.")
                return False

            rules.insert(idx, new_rule)
            return True


def choose_rule_filter():
    mode = ask_option(
        "\nFiltro de reglas a mostrar:",
        [
            "todas",
            "allow",
            "drop",
            "recursos_criticos",
            "bloqueos_generales",
            "catch_all",
            "protocolo",
            "servicio",
        ],
        allow_back=True
    )

    if mode is None:
        return None, None

    if mode == "protocolo":
        proto = ask_option(
            "\nSelecciona protocolo para filtrar:",
            list(PROTO_TO_NUMBER.keys()),
            allow_back=True
        )
        if proto is None:
            return "BACK", None
        return mode, proto

    if mode == "servicio":
        service = ask_option(
            "\nSelecciona servicio para filtrar:",
            list(SERVICE_TO_IP.keys()),
            allow_back=True
        )
        if service is None:
            return "BACK", None
        return mode, service

    return mode, None


def delete_rule(data):
    print("\n====================================================")
    print(" Eliminar regla de una ACL")
    print("====================================================")

    role_to_acl = get_role_to_acl_from_yaml(data)

    if not role_to_acl:
        print("No hay ACLs disponibles.")
        return False

    step = 0
    role = None
    filter_mode = None
    filter_value = None

    while True:
        if step == 0:
            role = ask_option(
                "\nSelecciona rol/ACL:",
                list(role_to_acl.keys()),
                allow_back=True
            )

            if role is None:
                print("Volviendo al menu principal.")
                return False

            step = 1

        elif step == 1:
            filter_mode, filter_value = choose_rule_filter()

            if filter_mode is None:
                step = 0
                continue

            if filter_mode == "BACK":
                step = 1
                continue

            step = 2

        elif step == 2:
            acl_name = role_to_acl[role]
            rules = get_acl_rules(data, acl_name)

            if rules is None:
                return False

            matched = []
            for idx, entry in enumerate(rules, start=1):
                rule = normalize_rule_entry(entry)
                if rule_matches_filter(rule, filter_mode, filter_value):
                    matched.append((idx, entry))

            if not matched:
                print("\nNo hay reglas que coincidan con ese filtro.")
                back = input("Escribe 0 para cambiar filtro o cualquier tecla para cancelar: ").strip().lower()
                if back in ("0", "volver", "v"):
                    step = 1
                    continue
                return False

            print("\n====================================================")
            print(f" Reglas filtradas en {acl_name}")
            print("====================================================")
            print(f"Filtro: {filter_mode}" + (f" = {filter_value}" if filter_value else ""))

            for real_idx, entry in matched:
                print("  " + format_rule_line(real_idx, entry))

            raw = input("\nNumero REAL de regla a eliminar. Escribe 0 para volver: ").strip().lower()

            if raw in ("0", "volver", "v"):
                step = 1
                continue

            if not raw.isdigit():
                print("Numero invalido.")
                continue

            rule_num = int(raw)

            valid_nums = [x[0] for x in matched]
            if rule_num not in valid_nums:
                print("Ese numero no esta dentro de las reglas filtradas.")
                continue

            entry = rules[rule_num - 1]
            rule = normalize_rule_entry(entry)
            clasif = classify_rule(rule)

            print("\nRegla seleccionada:")
            print("  " + format_rule_line(rule_num, entry))
            print("\nYAML:")
            print(yaml.safe_dump(entry, default_flow_style=False, sort_keys=False, allow_unicode=True))

            if clasif.startswith("CRITICA") or clasif.startswith("BASE"):
                print("\nADVERTENCIA FUERTE:")
                print(f"Estas eliminando una regla marcada como: {clasif}")
                print("Esto puede cambiar el comportamiento de seguridad de la ACL.")
                confirm = input("Para confirmar escribe exactamente ELIMINAR: ").strip()
                if confirm != "ELIMINAR":
                    print("Eliminacion cancelada.")
                    return False
            else:
                confirm = input("Eliminar esta regla? [s/N]. Escribe 0 para volver: ").strip().lower()
                if confirm in ("0", "volver", "v"):
                    step = 2
                    continue
                if confirm != "s":
                    print("Cancelado.")
                    return False

            del rules[rule_num - 1]
            print("Regla eliminada en memoria. Se guardara en la copia.")
            return True


def delete_acl(data):
    print("\n====================================================")
    print(" Eliminar ACL completa")
    print("====================================================")

    role_to_acl = get_role_to_acl_from_yaml(data)

    if not role_to_acl:
        print("No hay ACLs disponibles.")
        return False

    role = ask_option(
        "\nSelecciona rol/ACL a eliminar:",
        list(role_to_acl.keys()),
        allow_back=True
    )

    if role is None:
        print("Volviendo al menu principal.")
        return False

    acl_name = role_to_acl[role]
    rules = data["acls"].get(acl_name, [])
    refs = find_acl_references_in_faucet(acl_name)

    print("\n====================================================")
    print(" Resumen de eliminacion")
    print("====================================================")
    print(f"Rol: {role}")
    print(f"ACL: {acl_name}")
    print(f"Cantidad de reglas: {len(rules) if isinstance(rules, list) else 'FORMATO NO LISTA'}")

    if acl_name in PROTECTED_ACLS:
        print("\nADVERTENCIA:")
        print("Esta ACL pertenece a los roles base del proyecto.")
        print("Aunque solo se eliminara en la copia, no conviene borrar roles base sin revisar.")

    if refs:
        print("\nADVERTENCIA:")
        print(f"La ACL {acl_name} aparece referenciada en {FAUCET_PATH}:")
        for lineno, line in refs[:10]:
            print(f"  linea {lineno}: {line}")
        if len(refs) > 10:
            print(f"  ... y {len(refs) - 10} referencias mas.")
        print("Si luego aplicas esta copia al archivo real, Faucet podria fallar si faucet.yaml la sigue usando.")
    else:
        print(f"\nNo se encontraron referencias textuales a {acl_name} en faucet.yaml.")

    print("\nACL que se eliminaria en la copia:")
    print(yaml.safe_dump({acl_name: data["acls"].get(acl_name)}, default_flow_style=False, sort_keys=False, allow_unicode=True))

    print("\nConfirmacion requerida:")
    print(f"Para eliminar escribe exactamente el nombre de la ACL: {acl_name}")
    confirm = input("> ").strip()

    if confirm != acl_name:
        print("Confirmacion incorrecta. Eliminacion cancelada.")
        return False

    if acl_name in PROTECTED_ACLS or refs:
        confirm2 = input("Doble confirmacion: escribe ELIMINAR para continuar: ").strip()
        if confirm2 != "ELIMINAR":
            print("Eliminacion cancelada.")
            return False

    del data["acls"][acl_name]
    print("ACL eliminada en memoria. Se guardara en la copia.")
    return True


def show_diff():
    print("\n====================================================")
    print(" Comparar original vs copia")
    print("====================================================")

    if not ACLS_PATH.exists():
        print(f"No existe la copia: {ACLS_PATH}")
        return

    rc, out, err = run_cmd(["diff", "-u", str(REAL_ACLS_PATH), str(ACLS_PATH)])

    if rc == 0:
        print("No hay diferencias entre el original y la copia.")
    else:
        if out:
            print(out)
        if err:
            print(err)


def reset_working_copy():
    print("\n====================================================")
    print(" Reiniciar copia desde original")
    print("====================================================")

    print("Esto borrara los cambios hechos en la copia de trabajo.")
    print(f"Original: {REAL_ACLS_PATH}")
    print(f"Copia:    {ACLS_PATH}")

    confirm = input("Escribe RESET para confirmar: ").strip()

    if confirm != "RESET":
        print("Operacion cancelada.")
        return

    backup = backup_file(ACLS_PATH) if ACLS_PATH.exists() else None

    if backup:
        print(f"Backup de la copia anterior creado: {backup}")

    shutil.copy2(REAL_ACLS_PATH, ACLS_PATH)
    print("Copia reiniciada desde el archivo original.")


def main():
    init_working_copy()

    while True:
        data = load_yaml(ACLS_PATH)

        print("\n====================================================")
        print(" ACL Policy Manager R2 - MODO COPIA SEGURA")
        print("====================================================")
        print(f"Archivo original: {REAL_ACLS_PATH}")
        print(f"Archivo copia:    {ACLS_PATH}")
        print(f"Archivo Faucet:   {FAUCET_PATH}")
        print("1) Listar ACLs actuales")
        print("2) Crear nueva seccion acl_<rol>")
        print("3) Agregar regla allow/drop")
        print("4) Eliminar regla de una ACL")
        print("5) Eliminar ACL completa")
        print("6) Comparar copia vs original")
        print("7) Reiniciar copia desde original")
        print("8) Salir")

        opt = input("> ").strip()

        if opt == "1":
            list_acls(data)

        elif opt == "2":
            changed = create_acl(data)
            if changed:
                apply_and_validate(data, "Nueva ACL")

        elif opt == "3":
            changed = add_rule(data)
            if changed:
                apply_and_validate(data, "Regla ACL")

        elif opt == "4":
            changed = delete_rule(data)
            if changed:
                apply_and_validate(data, "Eliminacion de regla")

        elif opt == "5":
            changed = delete_acl(data)
            if changed:
                apply_and_validate(data, "Eliminacion de ACL")

        elif opt == "6":
            show_diff()

        elif opt == "7":
            reset_working_copy()

        elif opt == "8":
            print("Saliendo.")
            break

        else:
            print("Opcion invalida.")


if __name__ == "__main__":
    main()