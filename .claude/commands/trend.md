---
description: Tendencias entre corridas — cambios de inventario, crecimiento de datastores y evolución de hallazgos (sin consultar vCenter)
argument-hint: "<entorno> | <carpeta base> <carpeta actual>"
---

Argumentos: `$ARGUMENTS` → un entorno (compara las dos corridas más recientes) o dos carpetas de `reports/`.

1. Ejecuta `./scripts/Compare-Report.ps1 -Env <entorno>` o `-Base <a> -Current <b>`.
   - Si hay menos de dos corridas, ofrece generar una con `/report <entorno>` e indica que la tendencia requiere al menos dos.
2. Lee `tendencia.md` y resume:
   - Datastores con fecha estimada de llegada al 90 % (destacar ≤ 30 días) y su ritmo en GB/día.
   - VMs nuevas, eliminadas y con cambios de recursos; variación de vCPU/RAM por clúster.
   - Snapshots nuevos.
   - Hallazgos nuevos y resueltos.
3. Aclara que la proyección es lineal con dos puntos, y que con menos de 7 días entre corridas es poco confiable.
4. Entrega las rutas del reporte. Para tendencias consistentes, sugiere programar `New-Report.ps1` semanalmente.
