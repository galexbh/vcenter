---
description: Chequeo de salud con hallazgos priorizados y sugerencias accionables
argument-hint: "<entorno>"
---

Entorno: `$ARGUMENTS` (si falta, pregunta).

Sigue la skill `govc-health`:

1. Si existe una corrida de hoy en `reports/<entorno>/`, pregunta si reutilizarla (`-FromRaw`) o consultar de nuevo; si no, ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type health`.
2. Para cada hallazgo crítico, ejecuta como máximo una lectura puntual para confirmar (el comando sugerido del hallazgo).
3. Responde con el formato de la skill: Atender ya / Planificar / Mejoras, con comando de revisión por ítem.
4. No ejecutes correcciones. Ofrece preparar el plan de cambio para los que la persona elija.
