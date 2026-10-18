---
description: Genera reporte HTML/Markdown/CSV en reports/ (all, inventory, snapshots, capacity, health)
argument-hint: "<entorno> [all|inventory|snapshots|capacity|health] [html|md|csv]"
---

Argumentos: `$ARGUMENTS` → entorno (obligatorio; si falta, pregunta), tipo (defecto `all`), formato (defecto `html` y `md`; `csv` genera un archivo por tabla para Excel). Si piden «Excel», «CSV» o «planilla», usa `csv` (puede combinarse: `-Format html,md,csv`).

Sigue la skill `govc-report`:

1. Ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type <tipo> [-Format <formato>]`.
2. Resume desde `raw/summary.json` (KPIs), `raw/metrics.json` y `raw/findings.json`: conteo de críticos/advertencias y las acciones de *Prioridades* (severidad × VMs expuestas). Abre el `.md` solo si necesitas una sección concreta; no lo leas completo.
3. Redacta el análisis (skill `govc-report`, *Análisis de Claude*) y regenera con `-FromRaw`.
4. Entrega las rutas completas de los archivos.
5. Recuerda: uso interno, no versionar ni compartir fuera del equipo autorizado.
