rom flask import Flask, request, render_template_string, redirect
import sqlite3
import subprocess
import os
import signal

app = Flask(__name__)

VLAN_MAP = {
    'alumno':          100,
    'docente':         200,
    'administrativo':  300,
    'invitado':        400,
}

MAC_H1 = 'fa:16:3e:31:07:f0'
MAC_H2 = None  

# el html ( despues lo podemos mejorar)
LOGIN_HTML = '''
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Portal Cautivo - SDN-SecCampus PUCP</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background: #f0f2f5;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            margin: 0;
        }
        .card {
            background: white;
            padding: 40px;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            width: 360px;
        }
        h2 {
            color: #003366;
            text-align: center;
            margin-bottom: 8px;
        }
        .subtitle {
            text-align: center;
            color: #666;
            font-size: 14px;
            margin-bottom: 24px;
        }
        input {
            width: 100%;
            padding: 10px;
            margin: 8px 0;
            border: 1px solid #ddd;
            border-radius: 4px;
            box-sizing: border-box;
            font-size: 14px;
        }
        button {
            width: 100%;
            padding: 12px;
            background: #003366;
            color: white;
            border: none;
            border-radius: 4px;
            font-size: 16px;
            cursor: pointer;
            margin-top: 16px;
        }
        button:hover { background: #004488; }
        .error {
            background: #ffebee;
            color: #c62828;
            padding: 10px;
            border-radius: 4px;
            margin-bottom: 16px;
            font-size: 14px;
        }
        .success {
            background: #e8f5e9;
            color: #2e7d32;
            padding: 10px;
            border-radius: 4px;
            margin-bottom: 16px;
            font-size: 14px;
        }
    </style>
</head>
<body>
    <div class="card">
        <h2>SDN-SecCampus</h2>
        <p class="subtitle">Red Universitaria PUCP</p>
        {% if error %}
        <div class="error">{{ error }}</div>
        {% endif %}
        {% if success %}
        <div class="success">{{ success }}</div>
        {% endif %}
        <form method="POST" action="/login">
            <input type="text" name="usuario" placeholder="Usuario" required>
            <input type="password" name="password" placeholder="Contraseña" required>
            <button type="submit">Ingresar</button>
        </form>
    </div>
</body>
</html>
'''

def obtener_mac(ip):
    """Obtener MAC del cliente via tabla ARP del sistema"""
    try:
        resultado = subprocess.run(
            ['arp', '-n', ip],
            capture_output=True, text=True, timeout=3
        )
        for linea in resultado.stdout.split('\n'):
            if ip in linea and 'ether' in linea:
                partes = linea.split()
                for i, p in enumerate(partes):
                    if p == 'ether':
                        return partes[i+1]
    except Exception as e:
        print(f"Error obteniendo MAC: {e}")
    return None


def modificar_vlan_faucet(mac, vlan):
    vlan_names = {
        100: 'vlan_alumnos',
        200: 'vlan_docentes',
        300: 'vlan_administrativos',
        400: 'vlan_invitados',
    }
    vlan_name = vlan_names.get(vlan, 'vlan_cuarentena')

    try:
        if mac == MAC_H1:
            host = 'h1'
        else:
            host = 'h2'

        resultado = subprocess.run(
            ['ssh', '-p', '5800',
             '-o', 'StrictHostKeyChecking=no',
             '-o', 'BatchMode=yes',
             'ubuntu@192.168.100.5',
             f'/home/ubuntu/cambiar_vlan.sh {host} {vlan_name}'],
            capture_output=True, text=True, timeout=10
        )
        print(f"Script resultado: {resultado.returncode} stdout:{resultado.stdout} stderr:{resultado.stderr}")
        return resultado.returncode == 0

    except Exception as e:
        print(f"Error: {e}")
        return False


@app.route('/', defaults={'path': ''})
@app.route('/<path:path>')
def portal(path):
    return render_template_string(LOGIN_HTML, error=None, success=None)

@app.route('/login', methods=['POST'])
def login():
    usuario = request.form.get('usuario', '').strip()
    password = request.form.get('password', '').strip()
    ip_cliente = request.remote_addr

    if not usuario or not password:
        return render_template_string(LOGIN_HTML,
            error="Por favor ingrese usuario y contraseña.",
            success=None)

    # go a sqlite
    try:
        conn = sqlite3.connect('/home/ubuntu/portal/usuarios.db')
        cur = conn.cursor()
        cur.execute(
            "SELECT rol FROM usuarios WHERE usuario=? AND password=?",
            (usuario, password)
        )
        resultado = cur.fetchone()
        conn.close()
    except Exception as e:
        return render_template_string(LOGIN_HTML,
            error=f"Error de base de datos: {e}",
            success=None)

    if not resultado:
        return render_template_string(LOGIN_HTML,
            error="Usuario o contraseña incorrectos.",
            success=None)

    rol = resultado[0]
    vlan = VLAN_MAP.get(rol, 400)

    print(f"[AUTH] Usuario: {usuario} | Rol: {rol} | IP: {ip_cliente} | VLAN: {vlan}")

    # se consgiue la MAC del cliente
    mac = obtener_mac(ip_cliente)
    print(f"[AUTH] MAC del cliente: {mac}")

    if mac:
        exito = modificar_vlan_faucet(mac, vlan)
        if exito:
            return render_template_string(LOGIN_HTML,
                error=None,
                success=f"Bienvenido {usuario}. Rol: {rol}. Conectando a la red...")

    return render_template_string(LOGIN_HTML,
        error=None,
        success=f"Bienvenido {usuario}. Rol: {rol}. Acceso concedido.")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)