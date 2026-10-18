---
description: Resumen rápido de inventario de un entorno (VMs, hosts, clústeres, datastores)
argument-hint: "<entorno> [filtro de clúster o carpeta]"
---

Argumentos: `$ARGUMENTS` (primer valor = entorno; si falta, pregunta cuál).

Solo lectura. Sigue la skill `govc-report`:

1. Si existe una corrida de hoy en `reports/<entorno>/`, ofrece reutilizarla; si no, ejecuta `./scripts/New-Report.ps1 -Env <entorno> -Type inventory -Format md`.
2. Resume sin reconstruir datos a mano:
   - KPIs de `raw/summary.json`: VMs, encendidas, apagadas, plantillas, hosts, clústeres, datastores, snapshots, críticos y advertencias.
   - Tabla *Máquinas virtuales* de `reporte-inventory.md`: vCPU y RAM asignadas, SO, Tools y hardware (respeta el límite `-MdMaxRows`; si se truncó, dilo).
   - Hosts, clústeres y datastores (estado, versiones, % de uso): re-renderiza sin consultar vCenter con `./scripts/New-Report.ps1 -FromRaw <carpeta> -Type capacity -Format md` y lee esas tablas.
3. Filtro: `New-Report.ps1` no filtra por clúster ni carpeta; aplícalo al resumir (VMs cuyo host pertenece al clúster, según la tabla *Hosts*). Para una carpeta, una lectura puntual: `./scripts/govc.ps1 -Env <entorno> find <ruta> -type m`.
4. Presenta tablas compactas, 3 observaciones relevantes y la ruta de la carpeta. Para exportar: `/report <entorno> inventory` (HTML/MD) o `/report <entorno> inventory csv` (Excel).
