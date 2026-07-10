# SDN-SecCampus — README de Despliegue

---

## Descripción del proyecto

SDN-SecCampus es una red universitaria definida por software implementada sobre OpenStack/KVM usando Faucet como controlador SDN y Open vSwitch como plano de datos. El proyecto implementa tres requerimientos principales: portal cautivo con autenticación por rol (R1), control de acceso inter-VLAN a recursos privilegiados (R2), y seguridad perimetral con detección y mitigación automática de ataques (R5).

---

Acceso al entorno via jump host:
```
ssh ubuntu@10.20.11.170 -p <puerto>
```

---

## Prerrequisitos

- Acceso SSH al jump host 10.20.11.170
- Llaves SSH configuradas entre nodo-ctrl y todos los switches/hosts
- Python 3.7 en nodo-ctrl (entorno virtual Faucet en ~/faucet-venv)
- Python 3.x en nodo-sec, vm-atacante, vm-simulacion
- Open vSwitch 3.x en todos los switches
- Suricata 7.0.3 en nodo-sec

---

## 1. Despliegue de nodo-ctrl — Faucet

### 1.1 Verificar parche de LLDP

El entorno OpenStack bloquea los paquetes LLDP que Faucet necesita para el stack. El parche ya está aplicado en port.py pero verificar antes de arrancar:

```bash
ssh ubuntu@10.20.11.170 -p 5800

grep "OpenStack/KVM environment" \
  ~/faucet-venv/lib/python3.7/site-packages/faucet/port.py
# Debe aparecer el comentario del parche
```

### 1.2 Arrancar Faucet

```bash
ssh ubuntu@10.20.11.170 -p 5800
source ~/faucet-venv/bin/activate

# Verificar que no hay instancias previas
pkill -9 -f "faucet.faucet" 2>/dev/null
sleep 3

# Arrancar
FAUCET_CONFIG=/etc/faucet/faucet.yaml \
FAUCET_LOG=/home/ubuntu/faucet-venv/var/log/faucet/faucet.log \
FAUCET_EXCEPTION_LOG=/home/ubuntu/faucet-venv/var/log/faucet/faucet_exception.log \
FAUCET_PROMETHEUS_PORT=9302 \
FAUCET_EVENT_SOCK=/home/ubuntu/faucet-venv/var/run/faucet/faucet.sock \
faucet --ryu-config-file=/etc/faucet/ryu.conf &

sleep 15

# Verificar switches conectados y stack UP
curl -s http://localhost:9302/metrics | grep "dp_status" | grep -v "^#"
curl -s http://localhost:9302/metrics | grep "port_stack_state{" | grep -v "^#"
# Esperado: dp_status=1.0 en todos, port_stack_state=3.0 en todos
```

### 1.3 Verificar configuración

```bash
# Sin errores de configuración
curl -s http://localhost:9302/metrics | grep "faucet_config_load_error"
# Esperado: 0.0

# Reconectar switches si dp_status=0.0
for ip in 192.168.100.5 192.168.100.7 192.168.100.15 192.168.100.8 192.168.100.14; do
    ssh ubuntu@$ip "sudo ovs-vsctl set-controller \
        \$(sudo ovs-vsctl list-br | head -1) \
        tcp:192.168.100.5:6653" 2>/dev/null
done
```

---

## 2. Despliegue de R1 — Portal Cautivo

### 2.1 nodo-auth — Portal Flask y dnsmasq

```bash
ssh ubuntu@10.20.11.170 -p 5802

# Configurar interfaz de cuarentena
sudo ip addr add 192.168.99.1/24 dev ens4 2>/dev/null || true
sudo ip link set ens4 up

# Configurar redirección HTTP
sudo iptables -t nat -C PREROUTING -i ens4 -p tcp --dport 80 \
  -j REDIRECT --to-port 5000 2>/dev/null || \
sudo iptables -t nat -A PREROUTING -i ens4 -p tcp --dport 80 \
  -j REDIRECT --to-port 5000

# Arrancar dnsmasq
sudo systemctl start dnsmasq
sudo systemctl status dnsmasq | grep "active"

# Arrancar Flask
cd /home/ubuntu/portal
python3 app.py &
sleep 2
ss -tlnp | grep 5000
```

### 2.2 sw-acc1 — DHCP multi-VLAN

```bash
ssh ubuntu@10.20.11.170 -p 5811

sudo modprobe 8021q

for vlan in 100 200 300 400 500; do
    sudo ip link show dhcp-trunk.$vlan &>/dev/null 2>&1 || \
        sudo ip link add link dhcp-trunk name dhcp-trunk.$vlan \
        type vlan id $vlan
    sudo ip link set dhcp-trunk.$vlan up
done

sudo ip addr add 10.100.0.2/20 dev dhcp-trunk.100 2>/dev/null || true
sudo ip addr add 10.200.0.2/22 dev dhcp-trunk.200 2>/dev/null || true
sudo ip addr add 10.30.0.2/24  dev dhcp-trunk.300 2>/dev/null || true
sudo ip addr add 10.40.0.2/24  dev dhcp-trunk.400 2>/dev/null || true
sudo ip addr add 10.50.0.2/26  dev dhcp-trunk.500 2>/dev/null || true

sudo systemctl restart dnsmasq
```

### 2.3 Verificar R1

```bash
# Resetear h1 a cuarentena
ssh ubuntu@10.20.11.170 -p 5800
source ~/faucet-venv/bin/activate
/home/ubuntu/cambiar_vlan.sh h1 vlan_cuarentena

# Desde h1 verificar portal
ssh ubuntu@192.168.100.10
curl -s http://192.168.99.1/ | grep "SDN-SecCampus"
# Debe aparecer el título del portal
```

### 2.4 Usuarios disponibles

| Usuario | Contraseña | Rol | VLAN |
|---------|-----------|-----|------|
| alumno1 | pass123 | alumno | 100 |
| alumno2 | pass123 | alumno | 100 |
| docente1 | pass123 | docente | 200 |
| admin1 | pass123 | administrativo | 300 |
| invitado1 | pass123 | invitado | 400 |

---

## 3. Despliegue de R2 — Control de Acceso Inter-VLAN

### 3.1 sw-servidores — Servicios con namespaces

```bash
ssh ubuntu@10.20.11.170 -p 5805

# Recrear puertos OVS internal
for svc in administracion investigacion gest_acad bib_digital; do
    sudo ovs-vsctl --if-exists del-port sw-servidores $svc
done

sudo ovs-vsctl add-port sw-servidores administracion \
  -- set Interface administracion type=internal ofport_request=5
sudo ovs-vsctl add-port sw-servidores investigacion \
  -- set Interface investigacion type=internal ofport_request=6
sudo ovs-vsctl add-port sw-servidores gest_acad \
  -- set Interface gest_acad type=internal ofport_request=7
sudo ovs-vsctl add-port sw-servidores bib_digital \
  -- set Interface bib_digital type=internal ofport_request=8

# Crear namespaces
for ns in ns_adm ns_inv ns_ges ns_bib; do
    sudo ip netns add $ns 2>/dev/null || true
done

# Mover interfaces a namespaces
sudo ip link set administracion netns ns_adm
sudo ip link set investigacion netns ns_inv
sudo ip link set gest_acad netns ns_ges
sudo ip link set bib_digital netns ns_bib

# Configurar loopback
for ns in ns_adm ns_inv ns_ges ns_bib; do
    sudo ip netns exec $ns ip link set lo up
done

# Configurar MACs fijas
sudo ip netns exec ns_adm ip link set administracion address 36:43:bb:f5:c6:2b
sudo ip netns exec ns_inv ip link set investigacion address 36:4d:96:c4:95:70
sudo ip netns exec ns_ges ip link set gest_acad address e2:ea:20:67:66:5e
sudo ip netns exec ns_bib ip link set bib_digital address 32:10:14:85:6b:ca

# Levantar interfaces
sudo ip netns exec ns_adm ip link set administracion up
sudo ip netns exec ns_inv ip link set investigacion up
sudo ip netns exec ns_ges ip link set gest_acad up
sudo ip netns exec ns_bib ip link set bib_digital up

# Asignar IPs
sudo ip netns exec ns_adm ip addr add 10.0.1.10/24 dev administracion
sudo ip netns exec ns_inv ip addr add 10.0.1.20/24 dev investigacion
sudo ip netns exec ns_ges ip addr add 10.0.1.30/24 dev gest_acad
sudo ip netns exec ns_bib ip addr add 10.0.1.40/24 dev bib_digital

# Configurar rutas
sudo ip netns exec ns_adm ip route replace default via 10.0.1.1 dev administracion
sudo ip netns exec ns_inv ip route replace default via 10.0.1.1 dev investigacion
sudo ip netns exec ns_ges ip route replace default via 10.0.1.1 dev gest_acad
sudo ip netns exec ns_bib ip route replace default via 10.0.1.1 dev bib_digital

# Crear contenido web
sudo ip netns exec ns_adm bash -c \
    'mkdir -p /tmp/adm && echo "ADMINISTRACION 10.0.1.10" > /tmp/adm/index.html'
sudo ip netns exec ns_inv bash -c \
    'mkdir -p /tmp/inv && echo "INVESTIGACION 10.0.1.20" > /tmp/inv/index.html'
sudo ip netns exec ns_ges bash -c \
    'mkdir -p /tmp/ges && echo "GESTION ACADEMICA 10.0.1.30" > /tmp/ges/index.html'
sudo ip netns exec ns_bib bash -c \
    'mkdir -p /tmp/bib && echo "BIBLIOTECA DIGITAL 10.0.1.40" > /tmp/bib/index.html'

# Arrancar servidores HTTP
sudo ip netns exec ns_adm bash -c \
    'setsid python3 -m http.server 80 --bind 10.0.1.10 \
    --directory /tmp/adm > /tmp/ns_adm_http.log 2>&1 < /dev/null &'
sudo ip netns exec ns_inv bash -c \
    'setsid python3 -m http.server 80 --bind 10.0.1.20 \
    --directory /tmp/inv > /tmp/ns_inv_http.log 2>&1 < /dev/null &'
sudo ip netns exec ns_ges bash -c \
    'setsid python3 -m http.server 80 --bind 10.0.1.30 \
    --directory /tmp/ges > /tmp/ns_ges_http.log 2>&1 < /dev/null &'
sudo ip netns exec ns_bib bash -c \
    'setsid python3 -m http.server 80 --bind 10.0.1.40 \
    --directory /tmp/bib > /tmp/ns_bib_http.log 2>&1 < /dev/null &'

# Ping al gateway para que Faucet aprenda MACs
sudo ip netns exec ns_adm ping -c 3 10.0.1.1
sudo ip netns exec ns_inv ping -c 3 10.0.1.1
sudo ip netns exec ns_ges ping -c 3 10.0.1.1
sudo ip netns exec ns_bib ping -c 3 10.0.1.1
```

### 3.2 Verificar R2

```bash
# Desde h1 como alumno — debe acceder solo a biblioteca
ssh ubuntu@192.168.100.10
curl --noproxy "*" --connect-timeout 10 http://10.0.1.40
# Esperado: "BIBLIOTECA DIGITAL 10.0.1.40"

curl --noproxy "*" --connect-timeout 10 http://10.0.1.10
# Esperado: timeout (acceso denegado)
```

---

## 4. Despliegue de R5 — Seguridad Perimetral

### 4.1 sw-gateway — Verificar mirror OVS

```bash
ssh ubuntu@10.20.11.170

sudo ovs-vsctl list Mirror | grep -E "name|tx_packets"
```

Si el mirror no existe, crearlo:

```bash
sudo ovs-vsctl \
  -- --id=@ens5 get Port ens5 \
  -- --id=@ens7 get Port ens7 \
  -- --id=@ens9 get Port ens9 \
  -- --id=@m create Mirror name=mirror-sec \
       select-src-port=@ens5,@ens7 \
       select-dst-port=@ens5,@ens7 \
       output-port=@ens9 \
  -- set Bridge sw-gateway mirrors=@m

sudo ovs-vsctl list Mirror | grep "name"
```

### 4.2 vm-atacante — Verificar interfaz de datos

```bash
ssh ubuntu@10.20.11.170 -p 5880

sudo ip link set ens4 up
ip addr show ens4 | grep "inet "
# Debe mostrar 172.16.0.10/24

# Verificar scripts de ataque
ls /home/ubuntu/ataques/
# syn_scan.py  icmp_flood.py  udp_flood.py  flow_exhaustion.py
```

### 4.3 nodo-sec — Arrancar Suricata

```bash
ssh ubuntu@10.20.11.170 -p 5803

# Modo promiscuo
sudo ip link set ens6 promisc on

# Matar instancia anterior si existe
sudo kill $(cat /var/run/suricata.pid) 2>/dev/null
sleep 3

# Limpiar logs
sudo truncate -s 0 /var/log/suricata/fast.log
sudo truncate -s 0 /var/log/suricata/eve.json

# Arrancar Suricata
sudo suricata -c /etc/suricata/suricata.yaml \
  --af-packet=ens6 -D --pidfile /var/run/suricata.pid

sleep 5

# Verificar 1 solo thread activo
sudo suricatasc -c "dump-counters" 2>/dev/null | \
  grep -o '"W#[0-9]*-ens6"'
# Esperado: "W#01-ens6"
```

### 4.4 nodo-sec — Arrancar suricata_watcher.py

```bash
ssh ubuntu@10.20.11.170 -p 5803

# Matar instancia anterior
pkill -f suricata_watcher.py 2>/dev/null
sleep 2

# Verificar SSH hacia nodo-ctrl
ssh -p 5800 -o BatchMode=yes ubuntu@192.168.100.5 "echo SSH-OK"
# Debe responder SSH-OK sin pedir contraseña

# Arrancar watcher
nohup python3 /home/ubuntu/suricata_watcher.py \
  > /home/ubuntu/watcher.log 2>&1 &
echo $! > /home/ubuntu/watcher.pid

sleep 3
cat /home/ubuntu/watcher.log
# Esperado: "Listo — esperando alertas en tiempo real..."

# Verificar una sola instancia
ps aux | grep suricata_watcher | grep -v grep | wc -l
# Esperado: 1
```

### 4.5 Verificar R5 — Pipeline completo

```bash
# Lanzar ataque desde vm-atacante
ssh ubuntu@10.20.11.170 -p 5880
sudo python3 /home/ubuntu/ataques/syn_scan.py

# Verificar alerta detectada (nodo-sec)
ssh ubuntu@10.20.11.170 -p 5803
grep "SDN-SECCAMPUS SYN SCAN" /var/log/suricata/fast.log | head -1

# Verificar bloqueo aplicado (Gateway)
ssh ubuntu@10.20.11.170
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-gateway | grep "172.16.0.10"
# Esperado: priority=20480,ip,in_port=3,nw_src=172.16.0.10 actions=drop

# Desbloquear para siguiente prueba
ssh ubuntu@10.20.11.170 -p 5800
sudo /home/ubuntu/block_ip.sh 172.16.0.10 unblock
```

---

## 5. Verificación general del sistema

```bash
ssh ubuntu@10.20.11.170 -p 5800
source ~/faucet-venv/bin/activate

# Todos los switches conectados
curl -s http://localhost:9302/metrics | grep "dp_status" | grep -v "^#"

# Stack UP en todos los puertos
curl -s http://localhost:9302/metrics | grep "port_stack_state{" | grep -v "^#"

# Sin errores de configuración
curl -s http://localhost:9302/metrics | grep "faucet_config_load_error"

# Una sola instancia de Faucet
ps aux | grep faucet | grep -v grep | wc -l

# nodo-sec — Suricata corriendo
ssh ubuntu@10.20.11.170 -p 5803
sudo suricata --status

# nodo-sec — Watcher corriendo (1 instancia)
ps aux | grep suricata_watcher | grep -v grep | wc -l
```

---

## 6. Problemas comunes y soluciones

**Faucet no recarga tras SIGHUP**
```bash
# Verificar que no hay dos instancias
ps aux | grep faucet | grep -v grep
# Si hay más de 2 líneas, matar todo y reiniciar desde el paso 1.2
```

**Stack ports no suben a 3.0**
```bash
# Verificar que el parche está aplicado
grep "OpenStack/KVM" \
  ~/faucet-venv/lib/python3.7/site-packages/faucet/port.py
# Si no aparece, reaplicar parche y limpiar .pyc
```

**SSH entre nodos falla**
```bash
# Regenerar llave en el nodo origen
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
# Copiar al destino
ssh-copy-id -p <puerto> ubuntu@<ip_destino>
```

**Suricata no captura paquetes (decoder.pkts=0)**
```bash
# Activar modo promiscuo
sudo ip link set ens6 promisc on
# Reiniciar Suricata
sudo kill $(cat /var/run/suricata.pid)
sleep 3
sudo suricata -c /etc/suricata/suricata.yaml \
  --af-packet=ens6 -D --pidfile /var/run/suricata.pid
```

**block_ip.sh falla con YAML inválido**
```bash
# Restaurar backup manualmente
cp /etc/faucet/acls.yaml.pre_block /etc/faucet/acls.yaml
check_faucet_config /etc/faucet/faucet.yaml
pkill -HUP -f "ryu.conf"
```

**Dos instancias del watcher corriendo**
```bash
pkill -f suricata_watcher.py
sleep 2
# Reiniciar desde el paso 4.4
```

---

## 7. Orden de arranque recomendado

```
1. nodo-ctrl  → Faucet (paso 1.2)
2. sw-gateway → verificar mirror (paso 4.1)
3. nodo-auth  → portal cautivo (paso 2.1)
4. sw-acc1    → DHCP multi-VLAN (paso 2.2)
5. sw-servidores → namespaces y servicios (paso 3.1)
6. nodo-sec   → Suricata (paso 4.3)
7. nodo-sec   → watcher (paso 4.4)
8. vm-atacante → verificar interfaz (paso 4.2)
```
