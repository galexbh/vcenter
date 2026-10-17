---
description: Análisis de capacidad — CPU/RAM por clúster, datastores y holgura para HA
argument-hint: "<entorno>"
---

Argumentos: `$ARGUMENTS` (entorno obligatorio).

1. Ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type capacity`.
2. Desde `raw/` del reporte calcula por clúster:
   - vCPU:pCore, RAM asignada vs. física, y **holgura N+1**: ¿cabe la RAM en uso si cae el host más grande?
   - Datastores: top 5 por uso y GB libres; aprovisionado thin vs. capacidad.
3. Si hay un clúster con ratio alto, ofrece medir CPU Ready: `./scripts/govc.ps1 -Env <entorno> metric.sample -n 12 -json <ruta-clúster> cpu.ready.summation`.
4. Entrega: tabla por clúster, riesgos y 3 recomendaciones (right-sizing, rebalanceo, ampliación). Aclara que los ratios son práctica común, no política del banco, y que decisiones de inversión van con Infraestructura/Arquitectura.
