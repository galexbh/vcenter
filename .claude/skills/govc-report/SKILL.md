---
name: govc-report
description: Genera reportes de vCenter en HTML y Markdown (inventario, snapshots, capacidad, salud) con scripts/New-Report.ps1, guardados en reports/ y nunca en git. Úsala cuando pidan un reporte, inventario exportable, resumen para jefatura o un análisis repetible.
---

# Reportes de vCenter

## Generar

```powershell
./scripts/New-Report.ps1 -Env <entorno> [-Type all|inventory|snapshots|capacity|health] [-Format html,md]
```

- Solo lectura: número fijo de llamadas (object.collect para VMs, hosts, compute resources, clústeres y datastores; alarmas; about.cert; license.ls) sin importar el tamaño del inventario.
- Salida: `reports/<env>/<yyyyMMdd-HHmmss>/reporte-<tipo>.{html,md}` y `raw/*.json` (datos normalizados + `meta.json`).
- También `raw/findings.json` (hallazgos con código de regla) y `raw/summary.json` (indicadores): entrada de `/audit` y `/trend`.
- Chequeos incluidos además de capacidad y salud: consolidación pendiente, límites de CPU/RAM, ISO conectada, hardware virtual anterior a `-MinHwVersion` (14), HA/DRS de clústeres, certificado de vCenter (`-CertWarnDays`) y licencias (`-LicenseWarnDays`).
- `-Format csv`: un archivo por tabla (`reporte-<tipo>-<tabla>.csv`, incluye `resumen` y `hallazgos-y-sugerencias`), encabezados en español, UTF-8 con BOM, separador y decimales de la configuración regional de Windows (`-CsvDelimiter` para forzar otro). Los textos que empiezan con `= + - @` se prefijan con `'` para evitar inyección de fórmulas en Excel. Úsalo cuando pidan Excel, CSV o planilla.
- Re-render sin consultar vCenter (cambiar umbrales, otro tipo/formato):
  `./scripts/New-Report.ps1 -FromRaw reports/<env>/<marca> -Type health -SnapshotWarnDays 3`

## Umbrales (parámetros)

| Parámetro | Defecto | Regla |
|---|---|---|
| `-SnapshotWarnDays` / `-SnapshotCritDays` | 7 / 30 | antigüedad de snapshots |
| `-DatastoreWarnPct` / `-DatastoreCritPct` | 80 / 90 | uso del datastore |
| `-VcpuRatioWarn` / `-VcpuRatioCrit` | 4 / 6 | vCPU encendidas : pCores por clúster |
| `-MemRatioWarn` | 1.0 | RAM asignada (VMs encendidas) / RAM física |
| `-HostMemWarnPct` | 85 | memoria en uso por host |
| `-MdMaxRows` | 200 | filas máximas por tabla en Markdown |

Ajusta los umbrales a la política del equipo si la persona la indica; no inventes una política.

## Después de generar

1. Lee el `.md` generado (no el HTML) para resumir: KPIs, cantidad de críticos/advertencias y los 5 hallazgos más relevantes.
2. Da la ruta completa de ambos archivos.
3. Sugerencias priorizadas (ver skill `govc-health` para criterio).
4. Recuerda que el reporte es de uso interno.

## Tendencias y auditoría

- Comparar con una corrida anterior: `./scripts/Compare-Report.ps1 -Env <env>` (skill implícita en `/trend`).
- Informe formal: skill `govc-audit` (`/audit`).

## Reportes a medida

Si piden algo que `New-Report.ps1` no cubre (p. ej. VMs por tag, uso por carpeta):
- Reutiliza `ConvertFrom-GovcCollect` y la misma estructura de salida en `reports/<env>/<marca>/`.
- Renderiza Markdown con tablas; HTML con `Write-GovcReport` de `scripts/lib/Render.psm1` (usa `templates/report.html`); hallazgos con `Add-ReportFinding -Rule <código>` y `Export-ReportFinding`.
- Nunca escribas reportes fuera de `reports/`.

## Prohibido

- `git add` de `reports/` (bloqueado por hook y pre-commit).
- Subir reportes a servicios externos (artifacts, Confluence, Jira, correo) salvo petición explícita; si la piden, advierte que contienen inventario interno y que debe validarse con Seguridad de la Información.
