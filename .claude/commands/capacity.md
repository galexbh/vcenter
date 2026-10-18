---
description: Análisis de capacidad — CPU/RAM por clúster, datastores y holgura para HA
argument-hint: "<entorno> [clúster]"
---

Argumentos: `$ARGUMENTS` (entorno obligatorio; clúster opcional).

1. Ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type capacity`.
2. Lee `reporte-capacity.md` (o `raw/findings.json`) y resume por clúster, sin recalcular a mano:
   - vCPU:pCore, RAM asignada vs. física y **holgura N+1** (columnas *CPU N+1 %* y *RAM N+1 %*: uso actual frente a lo que queda sin el host mayor; > 100 % = no cabe). Reglas `cl-n1-mem`, `cl-n1-cpu`, `cl-n1-single`, `cl-ha-admission`.
   - Presión de memoria instantánea (`vm-balloon`, `vm-swap`, `vm-compressed`) y resource pools con límite (`rp-limit`).
   - Datastores: top 5 por uso y GB libres; aprovisionado thin vs. capacidad.
3. Si hay un clúster con ratio vCPU:pCore alto o presión de memoria, ofrece medir CPU ready, latencia y ballooning/swap en una ventana: `./scripts/Invoke-PerfCheck.ps1 -Env <entorno> -Cluster '<clúster>' [-Window 1h|24h|7d]`. Contadores sin datos = cobertura (nivel de estadísticas), no «sin problema».
4. Entrega: tabla por clúster, riesgos y 3 recomendaciones (right-sizing, rebalanceo, ampliación). Aclara que los ratios y umbrales son práctica común, no política del banco, y que decisiones de inversión van con Infraestructura/Arquitectura.
