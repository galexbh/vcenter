---
name: govc-health
description: Criterios para evaluar la salud de vCenter y dar sugerencias priorizadas — snapshots, capacidad de datastores, sobresuscripción de CPU/RAM, holgura N+1, rendimiento (CPU ready, latencia), hosts, VMware Tools, alarmas y VMs apagadas. Úsala para /health, /capacity, /snapshot-audit o cuando pidan recomendaciones u optimización.
---

# Salud y sugerencias

## Flujo

1. Datos: `./scripts/New-Report.ps1 -Env <env> -Type health` (genera HTML y MD; o `-FromRaw` si ya hay una corrida reciente de hoy).
2. Profundiza solo en los críticos con lecturas puntuales (comando sugerido en cada hallazgo).
3. Responde con la estructura de abajo.

## Reglas y por qué importan

| Área | Señal | Impacto | Sugerencia típica |
|---|---|---|---|
| Snapshots | > 7 días (adv), > 30 (crít) | Delta crece, degrada I/O, llena datastore, consolidación larga | Confirmar con dueño; eliminar con cambio aprobado; revisar que el backup no los deje huérfanos |
| Datastores | ≥ 80 % / ≥ 90 %; aprovisionado thin > 150 % | Llenado detiene VMs (pausa por falta de espacio) | Limpiar snapshots/ISOs/huérfanas, Storage vMotion, ampliar LUN |
| CPU clúster | vCPU:pCore ≥ 4 / ≥ 6 | CPU Ready alta, latencia de aplicaciones | Medir CPU ready con `./scripts/Invoke-PerfCheck.ps1 -Env <env> -Cluster '<cl>'`; right-sizing de VMs sobredimensionadas |
| RAM clúster | asignada/física > 1.0 | Ballooning, swap, falta de capacidad para failover HA | Revisar reservas HA (N+1), right-sizing |
| Holgura N+1 | `cl-n1-mem`/`cl-n1-cpu`: uso actual > 100 % (crít) o ≥ 90 % (adv) de lo que queda sin el host mayor; `cl-n1-single`: un solo host activo | HA no podría reiniciar todas las VMs si cae un host | Agregar capacidad, reducir carga; columnas *CPU N+1 %* / *RAM N+1 %* del reporte de capacidad |
| HA | `cl-ha-admission`: HA con control de admisión desactivado | Se encienden VMs sin capacidad garantizada para failover | Evaluar habilitarlo (cambio aprobado) |
| Memoria de VMs | `vm-balloon`/`vm-swap` (adv), `vm-compressed` (info): valor instantáneo de quickStats | Presión de memoria en el host; el swap degrada mucho | Confirmar en una ventana con `Invoke-PerfCheck.ps1` (`perf-balloon`, `perf-swap`) |
| Resource pools | `rp-limit`: pool (no el raíz `Resources`) con límite de CPU o RAM | Contención para todas sus VMs | Confirmar que el límite es intencional |
| Rendimiento (`Invoke-PerfCheck.ps1`) | CPU ready p95/vCPU ≥ 5 / ≥ 10 %; latencia p95 del peor host ≥ 20 / ≥ 30 ms; CPU host p95 ≥ 85 / ≥ 95 %; drops > 0 | Contención y latencia aunque la capacidad asignada parezca suficiente | Redistribuir (DRS), right-sizing, revisar arreglo con Storage. Contadores sin datos (`coverage-perf-counters`, p. ej. drops con nivel de estadísticas 1 en 24h) = cobertura, **no** «sin problema»; usar `-Window 1h` |
| Hosts | desconectado / no responde | VMs sin HA ni gestión | Escalar a Infraestructura de inmediato |
| Hosts | en mantenimiento fuera de ventana | Capacidad reducida | Confirmar ventana y reintegrar |
| Tools | no instalado / no corriendo / desactualizado | Sin apagado ordenado, sin quiesce de backup, sin métricas de guest | Instalar/actualizar en ventana |
| Alarmas | rojas / amarillas | Según la alarma | Seguir runbook; `events -n 20 <objeto>` |
| Higiene | VMs apagadas | Consumen disco y licencias | Validar con dueños, dar de baja con cambio |
| Hosts (esxcli) | Drift de VIBs/drivers, NIC sin link o con velocidad/MTU distinta, paths muertos o únicos, NTP/syslog ausentes, SSH encendido | vMotion/HA inconsistentes, pérdida de redundancia, logs sin SIEM, superficie de ataque | `/host-check` (skill `govc-esxcli`); cambios en hosts solo como propuesta |

Los ratios y umbrales de rendimiento son práctica común de la industria, no norma: si el equipo tiene una política propia, usa la suya (validar con Infraestructura/Arquitectura). Cambiar el nivel de estadísticas de vCenter (`metric.interval.change`) es una escritura: solo como propuesta.

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

- Propón comandos de **lectura** para revisar. Si sugieres una acción de cambio, escribe el comando como propuesta y aclara su clase (write/destructive) y que en prod requiere cambio aprobado.
- No ejecutes acciones correctivas por iniciativa propia.
- Para cambios con riesgo material (capacidad, eliminación de datos, mantenimiento de hosts), cierra recomendando validación con Infraestructura/Arquitectura y Riesgo Tecnológico según corresponda.
