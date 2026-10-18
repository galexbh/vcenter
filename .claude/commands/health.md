---
description: Chequeo de salud con hallazgos priorizados y sugerencias accionables
argument-hint: "<entorno>"
---

Entorno: `$ARGUMENTS` (si falta, pregunta).

Sigue la skill `govc-health`:

1. Si existe una corrida de hoy en `reports/<entorno>/`, pregunta si reutilizarla (`-FromRaw`) o consultar de nuevo; si no, ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type health`.
2. Lee `raw/summary.json` y `raw/findings.json` (ya ordenado por severidad).
3. Confirma como máximo los 5 primeros críticos, con una lectura cada uno: usa el campo `command` del hallazgo (si está vacío, la lectura mínima equivalente).
4. Responde con el formato de la skill: Atender ya / Planificar / Mejoras, con comando de revisión por ítem.
5. No ejecutes correcciones. Ofrece preparar el plan de cambio para los que la persona elija.
