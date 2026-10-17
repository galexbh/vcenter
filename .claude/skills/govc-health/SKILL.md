---
name: govc-health
description: Criterios para evaluar la salud de vCenter y dar sugerencias priorizadas — snapshots, capacidad de datastores, sobresuscripción de CPU/RAM, hosts, VMware Tools, alarmas y VMs apagadas. Úsala para /health, /capacity, /snapshot-audit o cuando pidan recomendaciones u optimización.
---

# Salud y sugerencias

## Flujo

1. Datos: `./scripts/New-Report.ps1 -Env <env> -Type health -Format md` (o `-FromRaw` si ya hay una corrida reciente de hoy).
2. Profundiza solo en los críticos con lecturas puntuales (comando sugerido en cada hallazgo).
3. Responde con la estructura de abajo.

## Reglas y por qué importan

| Área | Señal | Impacto | Sugerencia típica |
|---|---|---|---|
| Snapshots | > 7 días (adv), > 30 (crít) | Delta crece, degrada I/O, llena datastore, consolidación larga | Confirmar con dueño; eliminar con cambio aprobado; revisar que el backup no los deje huérfanos |
| Datastores | ≥ 80 % / ≥ 90 %; aprovisionado thin > 150 % | Llenado detiene VMs (pausa por falta de espacio) | Limpiar snapshots/ISOs/huérfanas, Storage vMotion, ampliar LUN |
| CPU clúster | vCPU:pCore ≥ 4 / ≥ 6 | CPU Ready alta, latencia de aplicaciones | Medir `cpu.ready.summation`; right-sizing de VMs sobredimensionadas |
| RAM clúster | asignada/física > 1.0 | Ballooning, swap, falta de capacidad para failover HA | Revisar reservas HA (N+1), right-sizing |
| Hosts | desconectado / no responde | VMs sin HA ni gestión | Escalar a Infraestructura de inmediato |
| Hosts | en mantenimiento fuera de ventana | Capacidad reducida | Confirmar ventana y reintegrar |
| Tools | no instalado / no corriendo / desactualizado | Sin apagado ordenado, sin quiesce de backup, sin métricas de guest | Instalar/actualizar en ventana |
| Alarmas | rojas / amarillas | Según la alarma | Seguir runbook; `events -n 20 <objeto>` |
| Higiene | VMs apagadas | Consumen disco y licencias | Validar con dueños, dar de baja con cambio |
| Hosts (esxcli) | Drift de VIBs/drivers, NIC sin link o con velocidad/MTU distinta, paths muertos o únicos, NTP/syslog ausentes, SSH encendido | vMotion/HA inconsistentes, pérdida de redundancia, logs sin SIEM, superficie de ataque | `/host-check` (skill `govc-esxcli`); cambios en hosts solo como propuesta |

Los ratios son práctica común de la industria, no norma: si el equipo tiene una política propia, usa la suya.

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
