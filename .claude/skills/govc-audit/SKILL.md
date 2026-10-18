---
name: govc-audit
description: Auditoría técnica completa de un entorno vSphere con informe formal (resumen ejecutivo, metodología, hallazgos AUD-NNN, plan de remediación, aprobación) mediante scripts/Invoke-Audit.ps1, y seguimiento con Compare-Report.ps1. Úsala para /audit, auditorías, evidencias para comités, revisiones de seguridad o seguimiento de remediación (también "vSphere audit", "security review", "audit report").
---

# Auditoría técnica

## Ejecución

```powershell
./scripts/Invoke-Audit.ps1 -Env <entorno> [-Cluster <c>] [-Scope full|security|capacity|performance] [-PerfWindow 1h|24h|7d] [-SkipPerf] [-SkipDeviceScan]
./scripts/Invoke-Audit.ps1 -FromRaw reports/<env>/<marca>-auditoria [-Scope …]   # regenerar sin consultar (re-renderiza perf/ si existe)
```

- Orquesta, en 4 pasos, `New-Report.ps1` (inventario, configuración, holgura N+1), `Invoke-HostCheck.ps1` (hosts por esxcli), `Invoke-PerfCheck.ps1` (rendimiento en la ventana `-PerfWindow`, 24h por defecto; reutiliza el inventario) y controles de acceso (`permissions.ls`, `role.ls`). Todo es lectura.
- `-Scope performance` = Capacidad + Rendimiento. Si el paso de rendimiento falla o se omite (`-SkipPerf`), la auditoría sigue: el dominio Rendimiento **no se puntúa** y queda como cobertura (`coverage-perf`). No lo presentes como «sin problemas de rendimiento».
- Antes de ejecutar en un entorno grande, sugerir `-Cluster` (la revisión de hosts hace una consulta por host y chequeo). Con miles de VMs, sugerir también `-SkipDeviceScan`.
- Salida: `reports/<env>/<marca>-auditoria/auditoria.{html,md}`, subcarpetas `inventario/`, `hosts/` y `perf/`, y `raw/audit.json`.

## Lectura del resultado (mínima)

1. `raw/audit.json`: `id`, `scope`, `scores` (indicador y conteos por dominio), `counts` (por severidad), `metrics`, `evolution`, `coverage` y `findings` (ordenados por severidad y dominio; los principales riesgos son los de mayor `priority`, severidad × VMs expuestas `impact`, con su `id` AUD-NNN).
2. Si hace falta texto: `auditoria.md` solo hasta `## 3. Hallazgos detallados` (resumen ejecutivo, indicadores, alcance y limitaciones).
3. Redacta el análisis en `<auditoría>/raw/analysis.md` y regenera con `-FromRaw` (skill `govc-report`, *Análisis de Claude*): queda en el resumen ejecutivo.
4. No abras `auditoria.html` ni `raw/vcenter-access.json` para resumir: el **anexo D** (solo en el HTML) y ese archivo contienen nombres de cuentas con rol Administrador.

Formato de respuesta:

```
## Auditoría <ENV> — <fecha> (<ID>)
Alcance: … · Cobertura: <completa | n limitaciones>

Indicadores: Disponibilidad NN · Capacidad NN · Rendimiento NN (o «no evaluado») · Configuración NN · Seguridad NN · Higiene NN
Rendimiento: ventana <1h|24h|7d>, intervalo <s> (de perf/raw/summary.json)
Hallazgos: X críticos · Y advertencias · Z informativos
Métricas clave: N+1 peor clúster NN % · datastore más lleno NN % · Tools al día NN % (de raw/audit.json → metrics)
Evolución: +N nuevos · N resueltos · N persistentes vs <ID anterior> (o «primera auditoría»)

Principales riesgos
1. AUD-001 — <objeto>: <evidencia>. Riesgo: … Recomendación: …
…

Recomendación: los 3 primeros pasos, en orden, con el motivo y el comando de revisión.

Informe: <ruta auditoria.html> (Imprimir → Guardar como PDF, A4)
```

## Qué no afirmar

- El indicador **no** es una calificación de cumplimiento ni una certificación; es una herramienta de priorización.
- Las referencias a la *vSphere Security Configuration Guide* y al *CIS Benchmark* son **temáticas**: no citar números de control ni afirmar conformidad con una versión concreta.
- No declarar que el entorno «cumple» o «no cumple» una norma (CNBS, PCI, ISO u otra). Eso lo determinan Cumplimiento y Auditoría Interna.
- La ausencia de hallazgos no implica ausencia de riesgo fuera del alcance (sistemas invitados, aplicaciones, respaldos, red física).
- Los umbrales de rendimiento son práctica habitual, no normativos (valores en la skill `govc-report`); los contadores sin datos son cobertura, no ausencia de problemas.

## Seguimiento

```powershell
./scripts/Compare-Report.ps1 -Base <auditoría anterior> -Current <auditoría nueva>
```

- Compara solo la parte de inventario (`inventario/raw/`): cambios de VMs, clústeres, datastores, snapshots y hallazgos de inventario nuevos/resueltos, identificados por `rule` + `object`.
- **No** compara hallazgos de hosts (esxcli), rendimiento ni controles de acceso; para esos, contrasta manualmente los `findings` de ambos `raw/audit.json` por `rule` + `object`.
- Los números AUD-NNN se reasignan en cada auditoría: no son comparables entre informes; no digas «AUD-003 se resolvió» por coincidencia de número.

## Confidencialidad

- El informe contiene inventario interno y, en el anexo D del HTML, **nombres de cuentas con rol Administrador**: tratarlo como información sensible.
- No publicar ni enviar el informe fuera del equipo autorizado salvo petición explícita; en ese caso, advertir que debe validarlo Seguridad de la Información.
- Cerrar recomendando la validación formal por Auditoría Interna, Riesgo Tecnológico y Seguridad de la Información.
