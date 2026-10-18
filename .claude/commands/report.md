---
description: Genera reporte HTML/Markdown/CSV en reports/ (all, inventory, snapshots, capacity, health)
argument-hint: "<entorno> [all|inventory|snapshots|capacity|health] [html|md|csv]"
---

Argumentos: `$ARGUMENTS` → entorno (obligatorio; si falta, pregunta), tipo (defecto `all`), formato (defecto `html` y `md`; `csv` genera un archivo por tabla para Excel). Si piden «Excel», «CSV» o «planilla», usa `csv` (puede combinarse: `-Format html,md,csv`).

Sigue la skill `govc-report`:

1. Ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type <tipo> [-Format <formato>]`.
2. Resume desde `raw/summary.json` (KPIs) y `raw/findings.json` (ya ordenado por severidad): conteo de críticos/advertencias y los 5 hallazgos principales con su acción sugerida. Abre el `.md` solo si necesitas una sección concreta; no lo leas completo.
3. Entrega las rutas completas de los archivos.
4. Recuerda: uso interno, no versionar ni compartir fuera del equipo autorizado.
