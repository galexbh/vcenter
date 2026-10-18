---
description: Auditoría técnica completa con informe formal imprimible (solo lectura)
argument-hint: "<entorno> [clúster] [full|security|capacity|performance] [1h|24h|7d]"
---

Argumentos: `$ARGUMENTS` → entorno (obligatorio; si falta, pregunta), clúster opcional, alcance opcional (`full` por defecto), ventana de rendimiento opcional (`24h` por defecto).

Sigue la skill `govc-audit`:

1. Verifica el entorno con `./scripts/govc.ps1 -Env <entorno> about`. Si el entorno tiene muchos hosts y no se indicó clúster, sugiere limitar la revisión de hosts.
2. Ejecuta `./scripts/Invoke-Audit.ps1 -Env <entorno> [-Cluster <c>] [-Scope <alcance>] [-PerfWindow <ventana>]`.
3. Lee `raw/audit.json` (`scores`, `counts`, `coverage` y los 5 primeros `findings`) o `auditoria.md` solo hasta `## 3. Hallazgos detallados`. No abras `auditoria.html` ni `raw/vcenter-access.json`: el anexo D lista cuentas con rol Administrador.
4. Presenta el resumen con el formato de la skill: indicadores, conteo por severidad, principales riesgos con ID y limitaciones de cobertura (incluido Rendimiento no evaluado, si aplica).
5. Entrega la ruta completa de `auditoria.html` e indica cómo guardarlo como PDF.
6. Si existe una auditoría anterior del mismo entorno, ofrece compararlas con `Compare-Report.ps1`, aclarando su alcance: solo inventario y sus hallazgos (por regla + objeto); los AUD-NNN no son comparables entre auditorías.
7. Cierra recordando que el informe es un insumo técnico que validan Auditoría Interna, Riesgo Tecnológico y Seguridad de la Información.
