---
description: Muestra los entornos configurados y prueba la conexión a uno (solo lectura)
argument-hint: "[entorno]"
---

Entorno solicitado: `$ARGUMENTS`

1. Lee `config/environments.json` y muestra una tabla con entorno, URL (solo host), datacenter, modo (`readonly`/`confirm`/`lab`) y si `insecure` está activo. No muestres otros campos.
   - Si el archivo no existe, indica ejecutar `task setup` (o copiar `config/environments.example.json`) y ajustarlo, y termina.
2. Si se indicó un entorno, ejecuta `./scripts/govc.ps1 -Env <entorno> about` y resume versión/build del vCenter.
   - Si falla por credencial, indica a la persona que ejecute `task credential ENV=<entorno>` en su propia terminal, fuera de Claude Code (el script se niega a ejecutarse dentro de Claude Code, también con `!`).
   - Si falla por TLS, sugiere configurar `caCerts` en lugar de `insecure`.
3. Advierte si un entorno con nombre tipo prod/dr tiene `mode: lab` o `insecure: true`.
