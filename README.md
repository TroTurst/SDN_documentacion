###Primera version de como hacer uso de nuestra solucion

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

