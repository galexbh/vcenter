---
description: Auditoría técnica completa con informe formal imprimible (solo lectura)
argument-hint: "<entorno> [clúster] [full|security|capacity]"
---

Argumentos: `$ARGUMENTS` → entorno (obligatorio; si falta, pregunta), clúster opcional, alcance opcional (`full` por defecto).

Sigue la skill `govc-audit`:

1. Verifica el entorno con `./scripts/govc.ps1 -Env <entorno> about`. Si el entorno tiene muchos hosts y no se indicó clúster, sugiere limitar la revisión de hosts.
2. Ejecuta `./scripts/Invoke-Audit.ps1 -Env <entorno> [-Cluster <c>] [-Scope <alcance>]`.
3. Lee `auditoria.md` y presenta el resumen con el formato de la skill: indicadores, conteo por severidad, principales riesgos con ID y limitaciones de cobertura.
4. Entrega la ruta completa de `auditoria.html` e indica cómo guardarlo como PDF.
5. Si existe una auditoría anterior del mismo entorno, ofrece compararlas con `Compare-Report.ps1`.
6. Cierra recordando que el informe es un insumo técnico que validan Auditoría Interna, Riesgo Tecnológico y Seguridad de la Información.
