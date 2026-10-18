---
description: Análisis de capacidad — CPU/RAM por clúster, datastores y holgura para HA
argument-hint: "<entorno> [clúster]"
---

Argumentos: `$ARGUMENTS` (entorno obligatorio; clúster opcional). `New-Report.ps1` no tiene `-Cluster`: el clúster solo filtra el resumen y se pasa como `-Cluster` a `Invoke-PerfCheck.ps1`.

Sigue la skill `govc-health` (criterio y reglas; umbrales en `govc-report`):

1. Ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type capacity` (o `-FromRaw` si hay una corrida de hoy).
2. Resume desde `raw/findings.json` y las tablas *Capacidad por clúster* y *Datastores* de `reporte-capacity.md`, sin recalcular a mano:
   - vCPU:pCore, RAM asignada vs. física y holgura N+1 (columnas *CPU N+1 %* / *RAM N+1 %*). Reglas `cl-vcpu`, `cl-mem`, `cl-n1-cpu`, `cl-n1-mem`, `cl-n1-single`, `cl-ha-admission`.
   - Presión de memoria instantánea (`vm-balloon`, `vm-swap`, `vm-compressed`) y límites (`rp-limit`).
   - Datastores: top 5 por uso y GB libres; aprovisionado thin (`ds-thin`).
3. Si hay ratio vCPU:pCore alto o presión de memoria, ofrece medir en una ventana reutilizando el inventario del paso 1: `./scripts/Invoke-PerfCheck.ps1 -Env <entorno> -InventoryDir <carpeta del paso 1> [-Cluster '<clúster>'] [-Window 1h|24h|7d]` (detalle en `/perf`).
4. Entrega: tabla por clúster, riesgos y 3 recomendaciones (right-sizing, rebalanceo, ampliación). Usa el panel *Capacidad y holgura* (`raw/metrics.json`: `cl-n1`, `cl-fit`, `cl-vcpu`, `ds-used:*`). Prioriza: primero lo que no cabe con N+1 (más VMs expuestas primero), después datastores sobre el umbral. Antes de proponer ampliar, cuantifica lo recuperable: disco en VMs apagadas (`off-disk`) y, si hay revisión de rendimiento de 24h o 7d, vCPU y RAM recuperables (`perf-reclaim-vcpu`, `perf-reclaim-mem`, regla `perf-oversized`). Los ratios y umbrales son práctica común, no política interna; la ampliación (inversión) la decide Arquitectura.
5. Redacta el análisis (skill `govc-report`, *Análisis de Claude*) y regenera con `-FromRaw`.
