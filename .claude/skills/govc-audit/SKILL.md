---
name: govc-audit
description: Auditoría técnica completa de un entorno vSphere con informe formal (resumen ejecutivo, metodología, hallazgos AUD-NNN, plan de remediación, aprobación) mediante scripts/Invoke-Audit.ps1, y seguimiento con Compare-Report.ps1. Úsala para /audit, auditorías, evidencias para comités, revisiones de seguridad o seguimiento de remediación.
---

# Auditoría técnica

## Ejecución

```powershell
./scripts/Invoke-Audit.ps1 -Env <entorno> [-Cluster <c>] [-Scope full|security|capacity] [-SkipDeviceScan]
./scripts/Invoke-Audit.ps1 -FromRaw reports/<env>/<marca>-auditoria [-Scope …]   # regenerar sin consultar
```

- Orquesta `New-Report.ps1` (inventario y configuración), `Invoke-HostCheck.ps1` (hosts por esxcli) y controles de acceso (`permissions.ls`, `role.ls`). Todo es lectura.
- Antes de ejecutar en un entorno grande, sugerir `-Cluster` (la revisión de hosts hace una consulta por host y chequeo). Con miles de VMs, sugerir también `-SkipDeviceScan` (no recolecta dispositivos de VM y omite el chequeo de ISO conectada).
- Salida: `reports/<env>/<marca>-auditoria/auditoria.{html,md}`, subcarpetas `inventario/` y `hosts/`, y `raw/audit.json`.

## Presentación del resultado

Leer `auditoria.md` (no el HTML) y responder con:

```
## Auditoría <ENV> — <fecha> (<ID>)
Alcance: … · Cobertura: <completa | n limitaciones>

Indicadores: Disponibilidad NN · Capacidad NN · Configuración NN · Seguridad NN · Higiene NN
Hallazgos: X críticos · Y advertencias · Z informativos

Principales riesgos
1. AUD-001 — <objeto>: <evidencia>. Riesgo: … Recomendación: …
…

Informe: <ruta auditoria.html> (Imprimir → Guardar como PDF, A4)
```

## Qué no afirmar

- El indicador **no** es una calificación de cumplimiento ni una certificación; es una herramienta de priorización.
- Las referencias a la *vSphere Security Configuration Guide* y al *CIS Benchmark* son **temáticas**: no citar números de control ni afirmar conformidad con una versión concreta.
- No declarar que el entorno «cumple» o «no cumple» una norma (CNBS, PCI, ISO u otra). Eso lo determinan Cumplimiento y Auditoría Interna.
- La ausencia de hallazgos no implica ausencia de riesgo fuera del alcance (sistemas invitados, aplicaciones, respaldos, red física).

## Seguimiento

```powershell
./scripts/Compare-Report.ps1 -Base <auditoría anterior> -Current <auditoría nueva>
```

Resumir: hallazgos resueltos, persistentes con cambio de severidad y nuevos.

## Confidencialidad

- El informe contiene inventario interno y, en el anexo C, **nombres de cuentas con rol Administrador**: tratarlo como información sensible.
- No publicar ni enviar el informe fuera del equipo autorizado salvo petición explícita; en ese caso, advertir que debe validarlo Seguridad de la Información.
- Cerrar recomendando la validación formal por Auditoría Interna, Riesgo Tecnológico y Seguridad de la Información.
