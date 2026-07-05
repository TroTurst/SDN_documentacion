<img width="994" height="430" alt="image" src="https://github.com/user-attachments/assets/4ee6d8d4-79fb-4157-9cb1-34732d057483" />###Primera version de como hacer uso de nuestra solucion

#Primero se arranca faucet en el nodo ctrl, en nuestro caso esta con puerto 5800 en nuestra red local

source ~/faucet-venv/bin/activate
FAUCET_CONFIG=/etc/faucet/faucet.yaml \
FAUCET_LOG=/home/ubuntu/faucet-venv/var/log/faucet/faucet.log \
FAUCET_EXCEPTION_LOG=/home/ubuntu/faucet-venv/var/log/faucet/faucet_exception.log \
FAUCET_PROMETHEUS_PORT=9302 \
FAUCET_EVENT_SOCK=/home/ubuntu/faucet-venv/var/run/faucet/faucet.sock \
faucet --ryu-config-file=/etc/faucet/ryu.conf &
sleep 3

Nota: Es importante es sleep porque asi no se te queda la terminal con puros logs (Los puedes ver luego haciendo un cat | head -10 a los logs)

Se verifica con 

ps aux | grep faucet | grep -v grep | wc -l

# Esperar a que los switches conecten
sleep 15
curl -s http://localhost:9302/metrics | grep "dp_status" | grep -v "^#"

# Levantar el portal
ssh ubuntu@192.168.100.4
sudo ip addr add 192.168.99.1/24 dev ens4 2>/dev/null || true
sudo ip link set ens4 up
sudo systemctl start dnsmasq
cd /home/ubuntu/portal && python3 app.py &

# 6.Levantar el DHCP
ssh ubuntu@192.168.100.8
sudo modprobe 8021q
for vlan in 100 200 300 400 500; do
  sudo ip link show dhcp-trunk.$vlan &>/dev/null 2>&1 || \
    sudo ip link add link dhcp-trunk name dhcp-trunk.$vlan type vlan id $vlan
  sudo ip link set dhcp-trunk.$vlan up
done
sudo ip addr add 10.100.0.2/20 dev dhcp-trunk.100 2>/dev/null || true
sudo ip addr add 10.200.0.2/22 dev dhcp-trunk.200 2>/dev/null || true
sudo ip addr add 10.30.0.2/24  dev dhcp-trunk.300 2>/dev/null || true
sudo ip addr add 10.40.0.2/24  dev dhcp-trunk.400 2>/dev/null || true
sudo ip addr add 10.50.0.2/26  dev dhcp-trunk.500 2>/dev/null || true
sudo systemctl restart dnsmasq
