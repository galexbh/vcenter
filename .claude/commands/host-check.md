---
description: Ronda de técnicos — revisa por esxcli cada host de un clúster y detecta drift (solo lectura)
argument-hint: "<entorno> [clúster|host…] [chequeos]"
---

Argumentos: `$ARGUMENTS` → entorno (obligatorio; si falta, pregunta), clúster(es) u host(s) opcionales, chequeos opcionales (`vibs,nics,paths,ntp,syslog,coredump,platform,services,certs`).

Sigue la skill `govc-esxcli`:

1. Si no hay filtro y el entorno tiene muchos hosts, sugiere limitar a un clúster (una llamada por host y chequeo).
2. Ejecuta `./scripts/Invoke-HostCheck.ps1 -Env <entorno> [-Cluster <c>] [-Hosts <h>] [-Checks <lista>]`.
3. Lee el `hosts-check.md` generado y resume:
   - Críticos (paths muertos) y advertencias agrupadas: drift de VIBs/drivers, red física, NTP, syslog, SSH/Shell.
   - Hosts sin cobertura y su causa.
4. Para cada grupo, da la acción sugerida y el comando de revisión. Los cambios en hosts son destructivos: solo propuestas, con cambio aprobado.
5. Redacta el análisis (skill `govc-report`, *Análisis de Claude*) y regenera con `-FromRaw`.
6. Entrega las rutas completas del reporte (uso interno, no se versiona).
