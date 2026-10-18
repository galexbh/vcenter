---
description: Auditoría de snapshots por antigüedad con plan de limpieza propuesto (no ejecuta)
argument-hint: "<entorno> [días de advertencia, defecto 7]"
---

Argumentos: `$ARGUMENTS` → entorno (obligatorio), días (defecto 7).

Sigue la skill `govc-health` (umbrales en `govc-report`):

1. Si existe una corrida de hoy en `reports/<entorno>/`, ofrece reutilizarla: `./scripts/New-Report.ps1 -FromRaw <carpeta> -Type snapshots -SnapshotWarnDays <días>`. Si no, `./scripts/New-Report.ps1 -Env <entorno> -Type snapshots -SnapshotWarnDays <días>`.
2. Lee `raw/findings.json` (regla `snap-age`; objeto `VM / snapshot`) o la tabla *Snapshots* de `reporte-snapshots.md` (ordenada por días, descendente) y presenta: total de snapshots (`raw/summary.json`), VMs afectadas y los más antiguos (VM, nombre, fecha, días, descripción).
3. Señala patrones: snapshots de backup huérfanos (nombres tipo `VEEAM`, `Commvault`, `_VCB`), VMs con varios snapshots (cuenta por VM en la tabla) y snapshots sin descripción.
4. Propón un plan de limpieza en tabla (VM, snapshot, justificación, comando) con comandos `snapshot.remove` **solo como propuesta**: son destructivos; fuera de `lab` los ejecuta una persona en su terminal con cambio aprobado y confirmación del dueño de la VM.
