# Scripts de criterios cuantitativos R2

Este directorio contiene los scripts usados para validar la escalabilidad de la solución **R2: restringir el acceso a recursos privilegiados solo a usuarios autorizados**.

Las pruebas se realizaron sobre la topología SDN con **Faucet/OVS**, considerando a `h2` como usuario autenticado en la **VLAN de alumnos** y a **Biblioteca Digital** como recurso permitido (`10.0.1.40:80`). El recurso **Administración** (`10.0.1.10:80`) se usa como destino no autorizado para validar que el bloqueo de R2 se conserve durante las pruebas.

## Scripts incluidos

| Script | Criterio evaluado | Archivo de resultados |
|---|---|---|
| `r2_nodos.sh` | Escalabilidad respecto al número de nodos | `/tmp/r2_escalabilidad_nodos.csv` |
| `r2_recursos.sh` | Escalabilidad respecto al número de recursos críticos | `/tmp/r2_escalabilidad_recursos.csv` |
| `r2_sesiones_activas.sh` | Escalabilidad respecto al número total de sesiones activas | `/tmp/r2_escalabilidad_sesiones_activas.csv` |
| `r2_tasa_nuevas_sesiones.sh` | Escalabilidad respecto a la tasa de nuevas sesiones | `/tmp/r2_escalabilidad_tasa_sesiones.csv` |

---

# 1. Escalabilidad respecto al número de nodos

## Script usado

`r2_nodos.sh`

## Objetivo

Evaluar si la política R2 mantiene el control de acceso correcto cuando aumenta el número de nodos conectados a la red.

## Descripción del funcionamiento

El script crea un bridge Linux que agrupa hasta 50 namespaces con IP/MAC únicas y los conecta al Open vSwitch mediante un puerto temporal. Luego valida que todos tengan conectividad, accedan a Biblioteca Digital y queden bloqueados hacia Administración. También inspecciona flujos OVS para contar MACs aprendidas y ACLs genéricas, guardando las métricas en `r2_escalabilidad_nodos.csv`.

## Niveles de prueba

| Nivel | Nodos simulados | Rol/VLAN | Recurso permitido | Recurso bloqueado |
|---:|---:|---|---|---|
| 1 | 1 | Alumno / VLAN 100 | `10.0.1.40:80` | `10.0.1.10:80` |
| 2 | 5 | Alumno / VLAN 100 | `10.0.1.40:80` | `10.0.1.10:80` |
| 3 | 10 | Alumno / VLAN 100 | `10.0.1.40:80` | `10.0.1.10:80` |
| 4 | 20 | Alumno / VLAN 100 | `10.0.1.40:80` | `10.0.1.10:80` |
| 5 | 50 | Alumno / VLAN 100 | `10.0.1.40:80` | `10.0.1.10:80` |

## Ejecución

```bash
sudo ./r2_nodos.sh run 1
sudo ./r2_nodos.sh run 5
sudo ./r2_nodos.sh run 10
sudo ./r2_nodos.sh run 20
sudo ./r2_nodos.sh run 50
```

Ver resultados:

```bash
column -s, -t /tmp/r2_escalabilidad_nodos.csv
```

## Evidencia esperada

El número de MACs aprendidas debe crecer según el número de nodos simulados, mientras que las reglas ACL de la VLAN 100 deben mantenerse constantes. Esto demuestra que la política R2 escala por rol/VLAN y no por usuario individual.

---

# 2. Escalabilidad respecto al número de recursos críticos

## Script usado

`r2_recursos.sh`

## Objetivo

Evaluar si la solución R2 puede aumentar la cantidad de recursos críticos protegidos sin generar errores de configuración ni fallos en la instalación de reglas OpenFlow.

## Descripción del funcionamiento

El script prepara recursos críticos sintéticos agregando IPs secundarias al namespace de Biblioteca y ajusta dinámicamente `acl_alumnos` para permitir cada nuevo recurso antes del DROP general hacia `10.0.1.0/24`. Luego valida la configuración con `check_faucet_config`, recarga Faucet, espera la instalación de flows en `sw-acc1` y prueba desde `h2` que los recursos permitidos sean accesibles y que Administración continúe bloqueada. Finalmente registra reglas ACL, flows R2, tiempos de validación/recarga y resultados funcionales en `r2_escalabilidad_recursos.csv`.

## Niveles de prueba

| Nivel | Recursos reales | Recursos sintéticos | Total |
|---:|---:|---:|---:|
| 1 | 4 | 0 | 4 |
| 2 | 4 | 4 | 8 |
| 3 | 4 | 12 | 16 |
| 4 | 4 | 28 | 32 |

Los recursos adicionales usan IPs desde `10.0.1.50` en adelante. Cada IP adicional representa un endpoint crítico lógico diferente, protegido mediante una regla ACL individual.

## Ejecución

```bash
sudo ./r2_recursos.sh run 4
sudo ./r2_recursos.sh run 8
sudo ./r2_recursos.sh run 16
sudo ./r2_recursos.sh run 32
```

Ver resultados:

```bash
column -s, -t /tmp/r2_escalabilidad_recursos.csv
```

Restaurar configuración original:

```bash
sudo ./r2_recursos.sh restore
```

## Evidencia OpenFlow

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1"
```

## Evidencia esperada

Al aumentar los recursos sintéticos, las reglas de `acl_alumnos` y los flows R2 instalados en `sw-acc1` deben crecer de forma controlada. Esto demuestra que Faucet acepta la expansión de la política y traduce las nuevas reglas ACL a OpenFlow.

---

# 3. Escalabilidad respecto al número total de sesiones activas

## Script usado

`r2_sesiones_activas.sh`

## Objetivo

Evaluar si la política R2 soporta múltiples sesiones TCP activas simultáneas hacia un recurso permitido sin crear reglas ACL adicionales por cada conexión.

## Descripción del funcionamiento

El script abre múltiples conexiones TCP desde `h2` hacia Biblioteca Digital (`10.0.1.40:80`) y las mantiene activas durante algunos segundos. Luego cuenta cuántas sesiones fueron establecidas correctamente, valida que Administración siga bloqueada y guarda las métricas en `r2_escalabilidad_sesiones_activas.csv`.

La evidencia OpenFlow se obtiene en `sw-acc1`, verificando que el flow permitido hacia Biblioteca reciba tráfico y que el número de reglas ACL no aumente por cada sesión activa.

## Niveles de prueba

| Nivel | Sesiones activas solicitadas | Recurso destino |
|---:|---:|---|
| 1 | 1 | `10.0.1.40:80` |
| 2 | 10 | `10.0.1.40:80` |
| 3 | 25 | `10.0.1.40:80` |
| 4 | 50 | `10.0.1.40:80` |
| 5 | 100 | `10.0.1.40:80` |

## Ejecución

```bash
sudo ./r2_sesiones_activas.sh 1
sudo ./r2_sesiones_activas.sh 10
sudo ./r2_sesiones_activas.sh 25
sudo ./r2_sesiones_activas.sh 50
sudo ./r2_sesiones_activas.sh 100
```

Ver resultados:

```bash
column -s, -t /tmp/r2_escalabilidad_sesiones_activas.csv
```

## Evidencia OpenFlow

Flow permitido hacia Biblioteca Digital:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1.40" \
  | grep "tp_dst=80"
```

DROP general hacia recursos no autorizados:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1.0/24" \
  | grep "actions=drop"
```

Conteo de flows R2 de la VLAN de alumnos:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1" \
  | wc -l
```

## Resultado obtenido

En las pruebas realizadas, se establecieron correctamente 1, 10, 25, 50 y 100 sesiones activas simultáneas hacia Biblioteca Digital, con 100 % de éxito en todos los niveles. Además, Administración continuó bloqueada en todos los escenarios.

El flow permitido hacia `10.0.1.40:80` registró tráfico y el conteo total de flows R2 para la VLAN 100 permaneció constante. Esto confirma que una misma regla ACL puede manejar múltiples sesiones activas sin generar reglas individuales por conexión.

---

# 4. Escalabilidad respecto a la tasa de nuevas sesiones

## Script usado

`r2_tasa_nuevas_sesiones.sh`

## Objetivo

Evaluar si la política R2 soporta una mayor tasa de creación de conexiones nuevas hacia un recurso permitido sin crear reglas ACL adicionales por cada sesión.

## Descripción del funcionamiento

El script genera conexiones HTTP nuevas desde `h2` hacia Biblioteca Digital a una tasa controlada de sesiones por segundo. A diferencia del criterio de sesiones activas, aquí las conexiones no se mantienen abiertas, sino que se crean, reciben respuesta y se cierran rápidamente.

Por cada nivel, el script registra intentos, éxitos, errores, tasa lograda, latencia promedio, latencia p95 y validación del bloqueo hacia Administración. Finalmente guarda las métricas en `r2_escalabilidad_tasa_sesiones.csv`.

## Niveles de prueba

| Nivel | Tasa de nuevas sesiones | Duración | Recurso destino |
|---:|---:|---:|---|
| 1 | 1 sesión/s | 10 s | `10.0.1.40:80` |
| 2 | 10 sesiones/s | 10 s | `10.0.1.40:80` |
| 3 | 25 sesiones/s | 10 s | `10.0.1.40:80` |
| 4 | 50 sesiones/s | 10 s | `10.0.1.40:80` |
| 5 | 100 sesiones/s | 10 s | `10.0.1.40:80` |

## Ejecución

```bash
sudo ./r2_tasa_nuevas_sesiones.sh 1 10
sudo ./r2_tasa_nuevas_sesiones.sh 10 10
sudo ./r2_tasa_nuevas_sesiones.sh 25 10
sudo ./r2_tasa_nuevas_sesiones.sh 50 10
sudo ./r2_tasa_nuevas_sesiones.sh 100 10
```

Ver resultados:

```bash
column -s, -t /tmp/r2_escalabilidad_tasa_sesiones.csv
```

## Evidencia OpenFlow

Flow permitido hacia Biblioteca Digital:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1.40" \
  | grep "tp_dst=80"
```

DROP general hacia recursos no autorizados:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1.0/24" \
  | grep "actions=drop"
```

Conteo de flows R2 de la VLAN de alumnos:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1" \
  | wc -l
```

## Resultado obtenido

En las pruebas realizadas, se generaron tasas de 1, 10, 25, 50 y 100 nuevas sesiones por segundo durante 10 segundos. En todos los niveles se obtuvo 100 % de éxito, sin errores: 10/10, 100/100, 250/250, 500/500 y 1000/1000 conexiones exitosas respectivamente.

La tasa lograda fue cercana a la tasa objetivo en todos los casos. Además, Administración continuó bloqueada en todos los escenarios. El flow permitido hacia `10.0.1.40:80` aumentó sus contadores de tráfico, mientras que el número de flows R2 de la VLAN 100 permaneció constante.

Esto demuestra que aumentar la tasa de nuevas sesiones no genera reglas ACL adicionales y que la política por rol/VLAN puede procesar múltiples conexiones nuevas sin depender de reglas individuales por sesión.

---

# Comandos generales de verificación

## Verificar que Faucet no tenga error de configuración

En `nodo-ctrl`:

```bash
curl -s http://localhost:9302/metrics \
  | grep faucet_config_load_error
```

Resultado esperado:

```text
faucet_config_load_error 0.0
```

## Verificar flow permitido hacia Biblioteca

En `sw-acc1`:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1.40" \
  | grep "tp_dst=80"
```

## Verificar DROP general hacia recursos no autorizados

En `sw-acc1`:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1.0/24" \
  | grep "actions=drop"
```

## Contar flows R2 de la VLAN de alumnos

En `sw-acc1`:

```bash
sudo ovs-ofctl -O OpenFlow13 dump-flows sw-acc1 \
  | grep "table=2" \
  | grep "dl_vlan=100" \
  | grep "nw_dst=10.0.1" \
  | wc -l
```

---

# Resumen general

Los cuatro scripts permiten demostrar que la solución R2 escala en las siguientes dimensiones:

1. Número de nodos conectados.
2. Número de recursos críticos protegidos.
3. Número total de sesiones activas simultáneas.
4. Tasa de creación de nuevas sesiones.

En las pruebas realizadas, la política R2 se mantuvo basada en rol/VLAN y no en reglas individuales por usuario o por sesión. Por ello, el crecimiento de nodos, sesiones activas y nuevas sesiones no incrementó la complejidad de las ACL. En cambio, el crecimiento del número de recursos críticos sí generó nuevas reglas específicas, lo cual es esperado porque cada recurso protegido requiere una decisión ACL explícita.
