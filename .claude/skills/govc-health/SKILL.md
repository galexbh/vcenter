---
name: govc-health
description: Criterios para evaluar la salud de vCenter y dar sugerencias priorizadas — snapshots, capacidad de datastores, sobresuscripción de CPU/RAM, holgura N+1, rendimiento (CPU ready, latencia), hosts, VMware Tools, alarmas y VMs apagadas. Úsala para /health, /capacity, /snapshot-audit, /perf o cuando pidan recomendaciones u optimización (también "health check", "capacity planning", "snapshot cleanup").
---

# Salud y sugerencias

## Flujo

1. Datos: `./scripts/New-Report.ps1 -Env <env> -Type health` (o `-FromRaw` si ya hay una corrida de hoy).
2. Lee `raw/summary.json` y `raw/findings.json` (ya ordenado por severidad).
3. Profundiza solo en los críticos con lecturas puntuales: usa el campo `command` del hallazgo.
4. Responde con el formato de abajo.

## Reglas y por qué importan

Los umbrales numéricos y su parámetro están en la skill `govc-report` (fuente única); aquí, el porqué y la acción. Advertencia/crítico = valor ≥ umbral salvo que se indique otra cosa.

| Área | Reglas | Por qué importa | Sugerencia típica |
|---|---|---|---|
| Snapshots | `snap-age` (objeto `VM / snapshot`) | El delta crece, degrada I/O, llena el datastore y alarga la consolidación; no es respaldo | Confirmar con el dueño; eliminar con cambio aprobado; revisar que el backup no los deje huérfanos |
| Datastores | `ds-used`, `ds-thin`, `ds-inaccessible` | Un datastore lleno pausa las VMs; el thin sobreaprovisionado puede llenarse de golpe | Limpiar snapshots/ISOs/huérfanas, Storage vMotion, ampliar LUN |
| CPU clúster | `cl-vcpu` | La sobresuscripción se traduce en CPU ready y latencia de aplicaciones | Medir con `/perf` (`perf-cpu-ready`); right-sizing de VMs sobredimensionadas |
| RAM clúster | `cl-mem`, `host-mem` | Ballooning, swap y falta de capacidad para failover | Revisar reservas HA (N+1), right-sizing, balanceo DRS |
| Holgura N+1 | `cl-n1-cpu`, `cl-n1-mem`, `cl-n1-single` | Si cae el host mayor, HA no podría reiniciar todas las VMs | Agregar capacidad o reducir carga; columnas *CPU N+1 %* / *RAM N+1 %* del reporte de capacidad |
| HA/DRS | `cl-ha`, `cl-ha-admission`, `cl-drs` | Sin HA o sin control de admisión no hay capacidad garantizada para failover | Evaluar habilitarlo (cambio aprobado) |
| Memoria de VMs | `vm-balloon`, `vm-swap`, `vm-compressed` | Presión de memoria en el host (valor instantáneo); el swap degrada mucho | Confirmar en una ventana con `/perf` (`perf-balloon`, `perf-swap`) |
| Resource pools / VMs | `rp-limit`, `vm-limits` | Un límite provoca contención aunque el host tenga recursos | Confirmar que el límite es intencional |
| Rendimiento | `perf-cpu-ready`, `perf-ds-latency`, `perf-host-cpu`, `perf-net-drops` | Contención y latencia aunque la capacidad asignada parezca suficiente | Redistribuir (DRS), right-sizing, revisar el arreglo con Storage |
| Cobertura | `coverage-perf-counters`, `coverage-perf-hosts`, `coverage-perf-error`, `coverage-devices` | Un contador sin datos (p. ej. drops con nivel de estadísticas 1 en 24h) **no** significa «sin problema» | Repetir con `-Window 1h` o declarar la limitación |
| Hosts | `host-state` | Host desconectado / sin respuesta: VMs sin HA ni gestión | Escalar a Infraestructura de inmediato |
| Hosts | `host-maint` | Capacidad reducida si el mantenimiento está fuera de ventana | Confirmar ventana y reintegrar |
| Tools | `tools-missing`, `tools-notrunning`, `tools-old` | Sin apagado ordenado, sin quiesce de backup, sin métricas de guest | Instalar/actualizar en ventana |
| Configuración VM | `vm-consolidate`, `vm-iso`, `vm-hwversion` | Discos sin consolidar crecen; una ISO conectada puede impedir vMotion; hardware antiguo limita funciones | Consolidar, desconectar ISO, planificar actualización |
| Certificados / licencias | `cert-vc`, `license` | Un vencimiento corta la gestión o el soporte | Planificar renovación |
| Alarmas | `alarm` (objeto `entidad / alarma`) | Según la alarma | Seguir runbook; el campo `command` del hallazgo |
| Higiene | `vm-off` | Consumen disco y licencias | Validar con dueños, dar de baja con cambio |
| Hosts (esxcli) | `vib-drift`, `nic-*`, `path-*`, `ntp-*`, `syslog-remote`, `coredump`, `cert-host-*` | vMotion/HA inconsistentes, pérdida de redundancia, logs sin SIEM, superficie de ataque | `/host-check` (skill `govc-esxcli`); cambios en hosts solo como propuesta |

Los ratios y umbrales son práctica común de la industria, no norma: si el equipo tiene una política propia, usa la suya (validar con Infraestructura/Arquitectura). Cambiar el nivel de estadísticas de vCenter (`metric.interval.change`) es una escritura: solo como propuesta.

## Formato de respuesta

```
## Salud de <ENV> — <fecha>
Resumen: X críticos, Y advertencias. <una frase con lo más urgente>

### Atender ya (críticos)
1. <objeto> — <evidencia>. Impacto: … Acción: … Revisar: `<comando>`

### Planificar (advertencias)
…

### Mejoras (info / optimización)
…

Reporte completo: <ruta md> · <ruta html>
```

- Propón comandos de **lectura** para revisar. Si sugieres una acción de cambio, escribe el comando como propuesta y aclara su clase (write/destructive) y lo que exige el `mode` del entorno (skill `govc-core`); en entornos productivos, cambio aprobado.
- No ejecutes acciones correctivas por iniciativa propia.
- Para cambios con riesgo material (capacidad, eliminación de datos, mantenimiento de hosts), cierra recomendando validación con Infraestructura/Arquitectura y Riesgo Tecnológico según corresponda.
