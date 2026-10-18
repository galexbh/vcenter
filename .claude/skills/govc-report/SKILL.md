---
name: govc-report
description: Genera reportes de vCenter en HTML, Markdown y CSV (inventario, snapshots, capacidad, salud) con scripts/New-Report.ps1, guardados en reports/ y nunca en git; fuente única de los umbrales. Úsala cuando pidan un reporte, inventario exportable, resumen para jefatura o un análisis repetible (también "vCenter report", "export inventory", "Excel/CSV report").
---

# Reportes de vCenter

## Generar

```powershell
./scripts/New-Report.ps1 -Env <entorno> [-Type all|inventory|snapshots|capacity|health] [-Format html,md,csv]
```

- Solo lectura: número fijo de consultas en un lote (object.collect de VMs, hosts, compute resources, clústeres, datastores y pools; alarmas; about.cert; license.ls), sin importar el tamaño del inventario.
- Salida: `reports/<env>/<yyyyMMdd-HHmmss>/reporte-<tipo>.{html,md}` y `raw/*.json` (datos normalizados + `meta.json`).
- Siempre escribe, para cualquier `-Type`: `raw/findings.json` (todos los hallazgos, ya ordenados por severidad; campos `severity`, `category`, `object`, `evidence`, `suggestion`, `command`, `rule`) y `raw/summary.json` (KPIs: VMs, encendidas, apagadas, plantillas, hosts, clústeres, datastores, snapshots, críticos, advertencias). Son la entrada de `/audit` y `/trend`.
- Chequeos además de capacidad y salud: consolidación pendiente, límites de CPU/RAM, ISO conectada, hardware virtual antiguo, HA/DRS, certificado de vCenter y licencias.
- `-Format csv`: un archivo por tabla (`reporte-<tipo>-<tabla>.csv`, incluye `resumen` y `hallazgos-y-sugerencias`), encabezados en español, UTF-8 con BOM, separador y decimales de la configuración regional de Windows (`-CsvDelimiter` para forzar otro). Los textos que empiezan con `= + - @` se prefijan con `'` para evitar inyección de fórmulas. Úsalo cuando pidan Excel, CSV o planilla.
- No tiene `-Cluster`: cubre todo el entorno; filtra por clúster al resumir.
- Re-render sin consultar vCenter (umbrales, tipo o formato distintos):
  `./scripts/New-Report.ps1 -FromRaw reports/<env>/<marca> -Type health -SnapshotWarnDays 3`

## Umbrales (fuente única)

Las demás skills y comandos citan reglas; los números viven aquí. Son práctica común, no norma: ajústalos a la política del equipo si la persona la indica; no inventes una política.

**New-Report.ps1**

| Parámetro | Defecto | Regla |
|---|---|---|
| `-SnapshotWarnDays` / `-SnapshotCritDays` | 7 / 30 | `snap-age` (objeto `VM / snapshot`): antigüedad ≥ umbral |
| `-DatastoreWarnPct` / `-DatastoreCritPct` | 80 / 90 | `ds-used`: uso ≥ umbral |
| (fijo) | 150 % | `ds-thin`: aprovisionado thin > 150 % de la capacidad |
| `-VcpuRatioWarn` / `-VcpuRatioCrit` | 4 / 6 | `cl-vcpu`: vCPU encendidas : pCores ≥ umbral |
| `-MemRatioWarn` | 1.0 | `cl-mem`: RAM asignada (VMs encendidas) / física > umbral |
| `-N1WarnPct` | 90 | `cl-n1-cpu` / `cl-n1-mem`: uso frente a la capacidad sin el host mayor ≥ 90 % adv.; > 100 % crít. (fijo) |
| `-HostMemWarnPct` | 85 | `host-mem`: memoria en uso del host ≥ umbral |
| (fijo) | > 0 | `vm-balloon`, `vm-swap` (adv.), `vm-compressed` (info): quickStats instantáneos |
| `-MinHwVersion` | 14 | `vm-hwversion`: hardware virtual inferior a `vmx-NN` |
| `-CertWarnDays` | 60 | `cert-vc`: días antes del vencimiento del certificado de vCenter |
| `-LicenseWarnDays` | 60 | `license`: días antes del vencimiento de licencias |
| `-MdMaxRows` | 200 | filas máximas por tabla en Markdown |
| `-CsvDelimiter` | separador de listas de Windows | separador de los CSV |
| `-SkipDeviceScan` | desactivado | no recolecta dispositivos de VM (omite `vm-iso`); recomendado con miles de VMs. Solo al recolectar, no con `-FromRaw` |

**Invoke-PerfCheck.ps1** (p95 en la ventana)

| Parámetro | Defecto | Regla |
|---|---|---|
| `-CpuReadyWarnPct` / `-CpuReadyCritPct` | 5 / 10 | `perf-cpu-ready`: CPU ready p95 por vCPU ≥ umbral |
| `-DsLatencyWarnMs` / `-DsLatencyCritMs` | 20 / 30 | `perf-ds-latency`: latencia p95 del peor host ≥ umbral |
| `-HostCpuWarnPct` / `-HostCpuCritPct` | 85 / 95 | `perf-host-cpu`: CPU del host p95 ≥ umbral |
| (fijo) | > 0 | `perf-net-drops`, `perf-balloon`, `perf-swap` |

**Otros:** `Invoke-HostCheck.ps1 -CertWarnDays` 60 (`cert-host-expiring`); `Invoke-Audit.ps1 -MaxRootAdmins` 5 (`perm-root-admins`).

## Después de generar

1. Resume desde `raw/summary.json` (KPIs) y `raw/findings.json` (ya ordenado: toma los primeros 5 relevantes, con su `suggestion` y `command`). Abre el `.md` solo para una sección concreta (p. ej. la tabla de capacidad o de snapshots); no leas el HTML.
2. Da la ruta completa de los archivos generados.
3. Sugerencias priorizadas con el criterio de la skill `govc-health`.
4. Recuerda que el reporte es de uso interno.

## Tendencias y auditoría

- Comparar con una corrida anterior: `./scripts/Compare-Report.ps1 -Env <env>` (`/trend`).
- Informe formal: skill `govc-audit` (`/audit`).

## Reportes a medida

Si piden algo que `New-Report.ps1` no cubre (p. ej. VMs por tag, uso por carpeta):
- Reutiliza `ConvertFrom-GovcCollect` y la misma estructura de salida en `reports/<env>/<marca>/`.
- Renderiza Markdown con tablas; HTML con `Write-GovcReport` de `scripts/lib/Render.psm1` (usa `templates/report.html`); hallazgos con `Add-ReportFinding -Rule <código>` y `Export-ReportFinding`.
- Nunca escribas reportes fuera de `reports/`.

## Prohibido

- `git add` de `reports/` (bloqueado por hook y pre-commit).
- Subir reportes a servicios externos (artifacts, Confluence, Jira, correo) salvo petición explícita; si la piden, advierte que contienen inventario interno y que debe validarse con Seguridad de la Información.
