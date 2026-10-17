---
description: Resumen rápido de inventario de un entorno (VMs, hosts, clústeres, datastores)
argument-hint: "<entorno> [filtro de clúster o carpeta]"
---

Argumentos: `$ARGUMENTS` (primer valor = entorno; si falta, pregunta cuál).

Usa la skill `govc-core`. Solo lectura, sin generar archivos:

1. Con `object.collect -json -type <m|h|r|s> / …` + `ConvertFrom-GovcCollect` (una llamada por tipo) obtén:
   - VMs: total, encendidas, apagadas, plantillas; vCPU y RAM totales asignadas.
   - Hosts: total, por estado de conexión, en mantenimiento, versiones de ESXi.
   - Clústeres/compute resources: hosts y cores por clúster.
   - Datastores: capacidad, libre y % de uso (ordenado desc.).
2. Si hay filtro, limita a VMs cuyo host pertenezca a ese clúster, o usa `find <ruta> -type m`.
3. Presenta tablas compactas y 3 observaciones relevantes. Si piden exportarlo, usa `/report <entorno> inventory` (HTML/MD) o `/report <entorno> inventory csv` (Excel).
