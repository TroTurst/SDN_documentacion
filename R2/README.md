# R2 - Control de Acceso a Recursos Privilegiados en SDN

Este directorio contiene los archivos utilizados para implementar, probar y evidenciar el cumplimiento del requisito **R2: Restringir el acceso a recursos privilegiados solo a usuarios autorizados** dentro de una red SDN basada en Faucet y Open vSwitch.

La solución se enfoca en la gestión de políticas de acceso mediante ACLs, separando los permisos por rol de usuario y protegiendo recursos críticos internos como Administración, Investigación, Gestión Académica y Biblioteca Digital.

---

## Objetivo de R2

El objetivo principal de R2 es asegurar que cada tipo de usuario solo pueda acceder a los recursos internos que tiene autorizados.

Ejemplo de política esperada:

| Rol | Recursos permitidos | Recursos bloqueados |
|---|---|---|
| Alumnos | Biblioteca Digital | Administración, Investigación, Gestión Académica |
| Docentes | Biblioteca Digital, Investigación | Administración, Gestión Académica |
| Administrativos | Todos los recursos internos | Ninguno |
| Invitados | Ningún recurso interno | Todos los recursos internos |

---

## Estructura de archivos

### `acl_policy_manager_test.py`

Script principal para gestionar políticas ACL de forma interactiva.

Permite:

- Listar ACLs actuales.
- Crear nuevas secciones `acl_<rol>`.
- Agregar reglas `allow/drop`.
- Eliminar reglas específicas.
- Eliminar ACLs completas.
- Comparar una copia de prueba contra el archivo original.
- Reiniciar la copia de prueba desde el archivo original.

Este script trabaja en modo seguro usando una copia:

```bash
/home/ubuntu/acls_manager/acls_prueba.yaml