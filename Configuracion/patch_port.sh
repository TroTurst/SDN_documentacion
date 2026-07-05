#!/bin/bash

# Ruta del archivo a modificar
ARCHIVO="/home/ubuntu/faucet-venv/lib/python3.7/site-packages/faucet/port.py"

# Verificar si el archivo existe
if [ ! -f "$ARCHIVO" ]; then
    echo "Error: El archivo $ARCHIVO no existe."
    exit 1
fi

# Hacer una copia de seguridad por seguridad antes de modificar
cp "$ARCHIVO" "${ARCHIVO}.bak"

# Ejecutar el script de Python inline para realizar el reemplazo exacto
python3 - << 'EOF'
import sys

ruta_archivo = "/home/ubuntu/faucet-venv/lib/python3.7/site-packages/faucet/port.py"

# El bloque original que buscas reemplazar
bloque_original = """# last_seen_lldp_time = self.dyn_stack_probe_info.get('last_seen_lldp_time', None)
# OpenStack/KVM environment: LLDP cannot cross hypervisor.
# Always refresh last_seen_lldp_time so stack ports never time out."""

# El nuevo bloque con tu modificación (asegúrate de mantener la indentación correcta de Faucet)
bloque_nuevo = """self.dyn_stack_probe_info = {
    'last_seen_lldp_time': now,
    'stack_correct': True,
    'remote_dp_id': self.dyn_stack_probe_info.get('remote_dp_id', None),
    'remote_dp_name': self.dyn_stack_probe_info.get('remote_dp_name', 'virtual'),
    'remote_port_id': self.dyn_stack_probe_info.get('remote_port_id', 0),
    'remote_port_state': self.dyn_stack_probe_info.get('remote_port_state', 3)}
last_seen_lldp_time = now
if self.is_stack_none():
    self.stack_init()
    reason = 'new'
if True:"""

# Leer el contenido actual
with open(ruta_archivo, 'r') as f:
    contenido = f.read()

# Verificar si el bloque original existe en el archivo
if bloque_original in contenido:
    # Reemplazar el bloque
    nuevo_contenido = contenido.replace(bloque_original, bloque_nuevo)
    
    # Guardar los cambios
    with open(ruta_archivo, 'w') as f:
        f.write(nuevo_contenido)
    print("Modificación realizada con éxito.")
else:
    # Si no encuentra el original, verificamos si ya se había aplicado el parche
    if bloque_nuevo in contenido:
        print("El parche ya estaba aplicado.")
    else:
        print("Error: No se encontró el bloque original en el archivo. Verifica la indentación.")
EOF