---
description: Auditoría de snapshots por antigüedad con plan de limpieza propuesto (no ejecuta)
argument-hint: "<entorno> [días de advertencia, defecto 7]"
---

Argumentos: `$ARGUMENTS` → entorno (obligatorio), días (defecto 7).

1. Ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type snapshots -SnapshotWarnDays <días>`.
2. Presenta: total de snapshots, VMs afectadas, los más antiguos (VM, nombre, fecha, días, descripción).
3. Señala patrones: snapshots de backup huérfanos (nombres tipo `VEEAM`, `Commvault`, `_VCB`), cadenas profundas, snapshots sin descripción.
4. Propón un plan de limpieza en tabla (VM, snapshot, justificación, comando) con comandos `snapshot.remove` **solo como propuesta**: son destructivos; en prod/dr los ejecuta una persona en su terminal con cambio aprobado y confirmación del dueño de la VM.
