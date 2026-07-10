# README — Topología de la Solución SDN-SecCampus

## 1. Descripción general

Esta topología implementa una red de campus SDN basada en **Faucet + Open vSwitch**, orientada a tres capacidades principales:

- **R1 — Portal cautivo con autenticación por rol:** los usuarios inician en cuarentena y luego son ubicados dinámicamente en una VLAN según su rol.
- **R2 — Control de acceso a recursos privilegiados:** las ACLs por rol permiten o bloquean el acceso a los servicios internos.
- **R5 — Seguridad perimetral:** el tráfico externo es inspeccionado por Suricata y las IPs maliciosas pueden ser bloqueadas dinámicamente desde Faucet.

La arquitectura separa el **plano de control**, administrado por Faucet, del **plano de datos**, ejecutado por switches OpenFlow 1.3 implementados con Open vSwitch.

---


## 2. Zonas de red

| Zona | Componentes | Función |
|---|---|---|
| Acceso | `h1`, `h2`, `sw-acc1` | Entrada de usuarios y cambio dinámico de VLAN |
| Core | `sw-core1`, `sw-core2` | Transporte interno, stack y failover |
| Servidores | `sw-servidores`, namespaces | Alojamiento de recursos críticos |
| Perímetro | `sw-gateway`, `vm-atacante`, `vm-simulacion` | Entrada de tráfico externo y aplicación de bloqueos |
| Seguridad | `nodo-sec`, Suricata | Inspección IDS mediante tráfico espejado |
| Control | `nodo-ctrl`, Faucet | Administración SDN, VLANs, ACLs y routing |
| Autenticación | `nodo-auth`, portal cautivo | Login inicial y activación del cambio de VLAN |

---

## 3. VLANs principales

| VLAN | Nombre | Gateway Faucet | Uso | ACL asociada |
|---:|---|---|---|---|
| 100 | `vlan_alumnos` | `10.100.0.1/20` | Usuarios alumnos | `acl_alumnos` |
| 200 | `vlan_docentes` | `10.200.0.1/22` | Usuarios docentes | `acl_docentes` |
| 300 | `vlan_administrativos` | `10.30.0.1/24` | Usuarios administrativos | `acl_administrativos` |
| 400 | `vlan_invitados` | `10.40.0.1/24` | Usuarios invitados | `acl_invitados` |
| 500 | `vlan_superadmin` | `10.50.0.1/26` | Administración avanzada | Sin ACL de entrada en la configuración base |
| 900 | `vlan_servidores` | `10.0.1.1/24` | Recursos internos | No aplica ACL por rol en la VLAN |
| 910 | `vlan_externa` | No aplica | Tráfico externo | `acl_block_externa` en puertos de entrada |
| 920 | `vlan_buffer` | No aplica | Segmento auxiliar | No aplica |
| 999 | `vlan_cuarentena` | No enrutable en `router_campus` | Usuarios no autenticados | `acl_cuarentena` |

---

## 4. Router lógico de campus

Faucet define un router lógico llamado `router_campus`, encargado del routing inter-VLAN entre usuarios autenticados y servidores.

```text
router_campus:
  vlan_alumnos
  vlan_docentes
  vlan_administrativos
  vlan_invitados
  vlan_servidores
```

La VLAN de cuarentena no participa en este router. Por ello, un usuario no autenticado no puede enrutar hacia los servidores internos. Primero debe autenticarse, ser movido a una VLAN de rol y recibir una IP/gateway por DHCP.

---

## 5. Switches y función dentro de la topología

### 5.1 `sw-acc1` — Switch de acceso

`sw-acc1` conecta a los usuarios finales y permite el cambio dinámico de VLAN después de la autenticación.

| Puerto OF | Interfaz | Función |
|---:|---|---|
| 2 | `ens8` | Host `h1`, acceso dinámico |
| 7 | `ens9` | Host `h2`, acceso dinámico |
| 5 | `ens6` | Stack hacia `sw-core2` |
| 10 | `ens4` | Stack hacia `sw-core1` |
| 12 | `dhcp-trunk` | Trunk DHCP/DNS multi-VLAN |

---

### 5.2 `sw-core1` — Core principal

`sw-core1` funciona como ruta principal hacia la red de servidores.

| Puerto OF | Interfaz | Función |
|---:|---|---|
| 3 | `ens7` | Stack hacia `sw-servidores` |
| 9 | `ens6` | Stack hacia `sw-core2` |
| 12 | `ens4` | Stack hacia `sw-acc1` |
| 4 | `ens8` | Trunk de VLANs internas |
| 5 | `ens9` | Acceso hacia red de cuarentena / portal |

---

### 5.3 `sw-core2` — Core alternativo

`sw-core2` proporciona una ruta de respaldo hacia servidores cuando la ruta principal por `sw-core1` no está disponible.

| Puerto OF | Interfaz | Función |
|---:|---|---|
| 1 | `ens4` | Stack hacia `sw-acc1` |
| 3 | `ens6` | Stack hacia `sw-core1` |
| 4 | `ens7` | Stack hacia `sw-servidores` |
| 5 | `ens8` | Trunk de VLANs internas |
| 6 | `ens9` | Acceso hacia red de cuarentena / portal |

---

### 5.4 `sw-servidores` — Switch de servicios críticos

`sw-servidores` aloja los servicios internos mediante namespaces Linux conectados a puertos internos de OVS.

| Puerto OF | Interfaz | Servicio | IP |
|---:|---|---|---|
| 1 | `ens4` | Stack hacia `sw-core1` | — |
| 2 | `ens5` | Stack hacia `sw-core2` | — |
| 5 | `administracion` | Administración | `10.0.1.10` |
| 6 | `investigacion` | Investigación | `10.0.1.20` |
| 7 | `gest_acad` | Gestión Académica | `10.0.1.30` |
| 8 | `bib_digital` | Biblioteca Digital | `10.0.1.40` |

---

### 5.5 `sw-gateway` — Switch perimetral

`sw-gateway` conecta la red externa con la red SDN, aplica bloqueos dinámicos y entrega tráfico espejado hacia el IDS.

| Puerto OF | Interfaz | Función |
|---:|---|---|
| 1 | `ens9` | Salida hacia `nodo-sec`, reservado como `output_only` |
| 2 | `ens6` | Trunk de VLANs internas |
| 3 | `ens7` | Entrada externa con `acl_block_externa` |
| 4 | `ens5` | Entrada externa con `acl_block_externa` |
| 6 | `ens8` | Trunk de VLANs internas |

El port mirroring se implementa en Open vSwitch. Faucet reserva el puerto OF1 (`ens9`) como `output_only` para evitar que sea usado como puerto normal de forwarding.

---

## 6. Servicios internos protegidos

Los recursos de R2 se ejecutan como namespaces en `sw-servidores`.

| Recurso | Namespace | Puerto OVS | IP | Uso |
|---|---|---|---|---|
| Administración | `ns_adm` | `administracion` | `10.0.1.10` | Recurso privilegiado |
| Investigación | `ns_inv` | `investigacion` | `10.0.1.20` | Recurso académico restringido |
| Gestión Académica | `ns_ges` | `gest_acad` | `10.0.1.30` | Recurso privilegiado |
| Biblioteca Digital | `ns_bib` | `bib_digital` | `10.0.1.40` | Recurso permitido a alumnos/docentes |

---

## 7. Políticas de acceso R2

Las ACLs por rol definen qué usuarios pueden acceder a cada recurso.

| Rol | Biblioteca `10.0.1.40` | Investigación `10.0.1.20` | Administración `10.0.1.10` | Gestión `10.0.1.30` |
|---|---|---|---|---|
| Alumno | Permitido | Denegado | Denegado | Denegado |
| Docente | Permitido | Permitido | Denegado | Denegado |
| Administrativo | Permitido | Permitido | Permitido | Permitido |
| Invitado | Denegado | Denegado | Denegado | Denegado |

Estas decisiones se materializan en OpenFlow mediante Faucet. En el pipeline, las ACLs por rol se aplican antes del routing inter-VLAN.

---

## 8. Relación con R1 — Portal cautivo

En R1, los hosts `h1` y `h2` inician en `vlan_cuarentena`.

```text
host conecta
  → vlan_cuarentena
  → DHCP 192.168.99.x
  → portal cautivo
  → login
  → cambio dinámico de VLAN según rol
  → DHCP de la nueva VLAN
  → acceso según ACL del rol
```

El componente que decide el rol es el portal cautivo. El cambio de VLAN se automatiza mediante `cambiar_vlan.sh`, que modifica el puerto del usuario en la configuración de Faucet. DHCP no decide la política; solo entrega IP, máscara, DNS y gateway dentro de la VLAN ya asignada.

---

## 9. Relación con R5 — Seguridad perimetral

En R5, el tráfico externo entra por `sw-gateway`. Los puertos externos usan `vlan_externa` y tienen aplicada la ACL `acl_block_externa`.

```text
vm-atacante / vm-simulacion
  → sw-gateway
  → OVS Mirror hacia nodo-sec
  → Suricata
  → eve.json / fast.log
  → suricata_watcher.py
  → block_ip.sh
  → acls.yaml
  → Faucet
  → DROP en sw-gateway
```

Si Suricata detecta un ataque, el watcher ejecuta una acción de mitigación que modifica dinámicamente `acls.yaml`. Faucet valida la configuración y reinstala flows de bloqueo en `sw-gateway`.

---

## 10. Pipeline lógico de Faucet

El procesamiento de paquetes sigue el pipeline multi-tabla de Faucet.

```text
Paquete
  → Tabla 0: ACL externa / bloqueos R5
  → Tabla 1: procesamiento VLAN
  → Tabla 2: ACLs por rol R1/R2
  → Tabla 3: anti-spoofing y aprendizaje MAC
  → Tabla 4: routing IPv4 inter-VLAN
  → Tabla 5: VIPs Faucet / gateways virtuales
  → Tabla 6: unicast aprendido
  → Tabla 7: flood controlado
```

Esto permite que el tráfico sea filtrado por política antes de ser enrutado hacia otros segmentos.

---

## 11. Comandos básicos de verificación

Verificar switches conectados a Faucet:

```bash
curl -s http://localhost:9302/metrics | grep "dp_status" | grep -v "^#"
```

Verificar estado de enlaces stack:

```bash
curl -s http://localhost:9302/metrics | grep "port_stack_state" | grep -v "^#"
```

Verificar error de configuración Faucet:

```bash
curl -s http://localhost:9302/metrics | grep faucet_config_load_error
```

Ver flows ACL de alumnos en `sw-acc1`:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1"
```

Ver puerto reservado para mirror en `sw-gateway`:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-gateway | grep "in_port=1"
```

Ver configuración OVS Mirror:

```bash
sudo ovs-vsctl list Mirror | grep -E "name|tx_packets"
```

---

## 12. Observación sobre puertos OF

Los puertos observados en la topología corresponden a los puertos Open Flow asignados según faucet.yaml.
