---
name: govc-core
description: Referencia para consultar y operar vCenter con govc a través del wrapper seguro scripts/govc.ps1 — rutas de inventario, consultas eficientes con object.collect/find, salida JSON y clasificación de operaciones. Úsala antes de cualquier comando govc en este proyecto.
---

# govc: uso seguro y eficiente

## Invocación

```powershell
./scripts/govc.ps1 -Env <entorno> <subcomando> [flags] [args]
```

- Tool **PowerShell**, un comando por llamada. `-Env` primero y literal.
- El wrapper inyecta `GOVC_URL`, usuario/contraseña (Credential Manager), `GOVC_TLS_CA_CERTS` (`caCerts`), `GOVC_INSECURE` (`insecure`), `GOVC_DATACENTER`, `GOVC_DATASTORE`, `GOVC_NETWORK`, `GOVC_RESOURCE_POOL`, `GOVC_FOLDER` desde el perfil. No hace falta `-dc` salvo para otro datacenter.
- Lecturas puras (wrapper + `ConvertFrom-Json`/`Select-Object`/`Where-Object`/`Sort-Object`/`Measure-Object`/`Format-*`) se aprueban solas. Cualquier otro comando en la misma línea vuelve al flujo normal de permisos.

## Varias lecturas: modo lote

Los scripts de reporte agrupan sus consultas con `Invoke-GovcBatch -Env <e> -Commands @(, @('about'), , @('object.collect','-json','-type','h','/','name'))` (`scripts/lib/GovcBatch.psm1`): una sola sesión, solo lecturas (el wrapper rechaza el lote si incluye algo que no sea lectura). Para consultas interactivas sueltas, usa el wrapper normal. No intentes gestionar ni inspeccionar sesiones de govc: está bloqueado.

## Clasificación (scripts/lib/Classify.psm1)

| Clase | Ejemplos | prod (confirm) | dr (readonly) | lab |
|---|---|---|---|---|
| read | `about`, `ls`, `find`, `*.info`, `*.ls`, `*.tree`, `object.collect`, `events`, `tasks`, `metric.sample`, `host.esxcli … list` / `get` | auto | auto | auto |
| write | `vm.clone`, `vm.create`, `vm.change`, `vm.power -on`, `snapshot.create`, `tags.attach`, `folder.create`, desconocidos | aprobación | bloqueado | aprobación |
| destructive | `vm.destroy`, `vm.power -off/-s/-r/-reset/-suspend`, `snapshot.remove/revert`, `*.rm`, `host.maintenance.enter`, `host.esxcli` con verbo distinto de list/get, `object.destroy` | bloqueado | bloqueado | aprobación |
| secret | `env`, `vm.console`, `-debug`, `-password` | bloqueado | bloqueado | bloqueado |

Subcomando no reconocido = write (fail-safe).

## Rutas de inventario

```
/<DC>/vm/<carpeta>/<vm>          VMs y plantillas
/<DC>/host/<cluster>/<host>      hosts
/<DC>/host/<cluster>/Resources   resource pool raíz del clúster
/<DC>/datastore/<ds>             datastores
/<DC>/network/<portgroup>        redes
```
MOID directo: `Tipo:valor`, p. ej. `VirtualMachine:vm-123`, `Alarm:alarm-7`.

## Patrones eficientes

| Necesidad | Hazlo así | Evita |
|---|---|---|
| Propiedades de todas las VMs | `object.collect -json -type m / name runtime.powerState summary.config.numCpu` | bucle de `vm.info` |
| Filtrar por estado | `find / -type m -runtime.powerState poweredOff` | traer todo y filtrar local |
| Datastores tipo vSAN | `find / -type s -summary.type vsan` | |
| Detalle de una VM | `vm.info -json -r <vm>` (`-r` incluye recursos) | `vm.info` sin `-json` |
| Snapshots de una VM | `snapshot.tree -vm <vm> -D -i -s` | |
| Eventos recientes | `events -n 50 <ruta>` | `tasks` sin límite |
| Métricas | `metric.sample -n 12 -json <ruta> cpu.usage.average mem.usage.average` | intervalos muy largos |
| Varias VMs | `vm.info -json vm1 vm2 vm3` (acepta varios) | una llamada por VM |

Tipos de `-type`: `m` VM, `h` host, `s` datastore, `c` clúster, `r` compute resource, `n` red, `g` portgroup distribuido, `w` DVS, `p` resource pool, `f` carpeta, `d` datacenter, `a` vApp.

## Parseo de object.collect

`object.collect -json -type …` emite **varios documentos JSON concatenados**; los arreglos vienen como `{"_value":[…]}`. Usa:

```powershell
Import-Module ./scripts/lib/GovcJson.psm1
./scripts/govc.ps1 -Env prod object.collect -json -type m / name runtime.powerState | ConvertFrom-GovcCollect
```
Cada objeto tiene `_type`, `_moref` y una propiedad por ruta (acceso con comillas: `$_.'runtime.powerState'`).

## Errores comunes

- `no such host`/`x509`: revisa `url` y `caCerts` del perfil; no actives `insecure` en prod.
- `NotAuthenticated`/`InvalidLogin`: la credencial de Credential Manager está vencida → la persona ejecuta `task credential ENV=<env>` en su propia terminal, fuera de Claude Code (el script se niega a ejecutarse dentro de Claude Code, también con `!`).
- `NoPermission`: la cuenta de servicio no tiene el privilegio; no intentes otra cuenta, repórtalo.
- Resultado vacío en `find`: revisa el datacenter del perfil o usa ruta absoluta.
