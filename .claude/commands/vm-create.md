---
description: Crea una VM desde plantilla con validación, plan y aprobación paso a paso
argument-hint: "<ruta spec.yaml> | <descripción libre>"
---

Entrada: `$ARGUMENTS`

Sigue estrictamente la skill `govc-provision`:

1. Si es una ruta, lee la spec. Si es texto libre, construye la spec a partir de `templates/vm-spec.example.yaml`, guárdala en `specs/<nombre>.yaml` y muéstrala.
2. Valida todo con lecturas (nombre libre, plantilla, datastore con espacio, red, carpeta, pool, tags). Reporta cualquier faltante y detente si hay bloqueantes.
3. Revisa el `mode` del perfil (`/env`): si es `readonly`, explica que no se puede crear y termina. En `prod` (o cualquier entorno productivo), exige `change` (número de cambio).
4. Presenta el plan (tabla + comandos exactos en orden + recursos consumidos) y espera confirmación explícita.
5. Ejecuta un comando por llamada; tras cada uno verifica el resultado antes de seguir.
6. Verifica con `vm.info -json -r` y entrega resumen final vs. spec.
