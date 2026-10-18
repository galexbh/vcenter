---
description: Revisión de rendimiento en una ventana — CPU ready, latencia de datastores, CPU de hosts, ballooning, swap y drops (solo lectura)
argument-hint: "<entorno> [clúster] [1h|24h|7d]"
---

Argumentos: `$ARGUMENTS` → entorno (obligatorio; si falta, pregunta), clúster opcional, ventana opcional (`24h` por defecto).

Sigue la skill `govc-health` (umbrales en `govc-report`):

1. Si hay una corrida de inventario de hoy en `reports/<entorno>/` (con `raw/hosts.json` y `raw/vms.json`), reutilízala para no volver a listar entidades:
   `./scripts/Invoke-PerfCheck.ps1 -Env <entorno> -InventoryDir <carpeta> [-Cluster '<clúster>'] [-Window <ventana>]`
   Si no, `./scripts/Invoke-PerfCheck.ps1 -Env <entorno> [-Cluster '<clúster>'] [-Window <ventana>]`.
   Para recalcular con otros umbrales sin consultar vCenter: `./scripts/Invoke-PerfCheck.ps1 -FromRaw <carpeta de una revisión anterior> [-CpuReadyWarnPct …]` (conserva la ventana y el alcance originales).
2. Resume desde `raw/summary.json` (ventana, intervalo, hosts, VMs evaluadas, conteos) y `raw/findings.json` (ya ordenado) de la carpeta generada; abre `perf-check.md` solo para una tabla concreta.
   - Reglas: `perf-cpu-ready`, `perf-ds-latency`, `perf-host-cpu`, `perf-balloon`, `perf-swap`, `perf-net-drops`.
   - Cobertura (`coverage-perf-counters`, `coverage-perf-hosts`, `coverage-perf-error`): un contador sin datos es una limitación (nivel de estadísticas del intervalo), **no** «sin problema». Sugiere `-Window 1h` (tiempo real) para cubrirlo.
3. Entrega: hallazgos priorizados con objeto, evidencia (p95/máx.), acción y comando de revisión; ruta de la carpeta.
4. Aclara que los umbrales son práctica común a validar con Infraestructura, no política del banco. Cambiar el nivel de estadísticas es una escritura: solo como propuesta.
