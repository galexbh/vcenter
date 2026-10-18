---
name: govc-core
description: Referencia para consultar y operar vCenter con govc a través del wrapper seguro scripts/govc.ps1 — rutas de inventario, consultas eficientes con object.collect/find, salida JSON, lotes de lectura y política por modo. Úsala antes de cualquier comando govc en este proyecto (también "run govc", "query vCenter", "list VMs").
---

# govc: uso seguro y eficiente

## Invocación

```powershell
./scripts/govc.ps1 -Env <entorno> <subcomando> [flags] [args]
```

- Tool **PowerShell**. `-Env` primero y literal. Escrituras: un comando por llamada, sin encadenar con `;` (regla 5 de CLAUDE.md); las lecturas pueden ir en tubería con cmdlets de transformación.
- El wrapper toma del perfil URL, CA (`caCerts`), `insecure`, datacenter, datastore, red, resource pool y carpeta por defecto; la credencial la resuelve él (ver regla 2 de CLAUDE.md). No hace falta `-dc` salvo para otro datacenter.
- **Se aprueban solas** las líneas compuestas solo por lecturas del wrapper y estos cmdlets: `ConvertFrom-Json`, `ConvertTo-Json`, `Select-Object`, `Where-Object`, `Sort-Object`, `Group-Object`, `Measure-Object`, `Format-Table`, `Format-List`, `Out-String`, `Select-String`, `ForEach-Object` (y sus alias `select`, `where`, `?`, `sort`, `group`, `measure`, `ft`, `fl`, `%`, `foreach`). Con el hook actualizado, también `ConvertFrom-GovcCollect` e `Import-Module ./scripts/lib/GovcJson.psm1` (ruta literal, `-Force` opcional). Cualquier otro comando, redirección a archivo o variable vuelve al flujo normal de permisos.

## Uso eficiente

- Usa `-json` y `ConvertFrom-Json`; no parsees texto.
- Inventario masivo: `object.collect -json -type <m|h|s|r|c> / <propiedades…>` (una llamada) en vez de `vm.info` por VM; parsea con `ConvertFrom-GovcCollect` (abajo).
- Filtra en el servidor: `find / -type m -runtime.powerState poweredOff`, `find / -type s -summary.type vsan`.
- Flags con punto (`-runtime.powerState`) funcionan sin comillas (el wrapper los recompone). Valores con comas o espacios: entre comillas.
- Re-analizar sin consultar vCenter: `-FromRaw reports/<env>/<marca>` (New-Report, Invoke-HostCheck, Invoke-PerfCheck, Invoke-Audit) y `Compare-Report.ps1` para tendencias.
- Varias lecturas en un script: `Invoke-GovcBatch` (lote, abajo). No gestiones sesiones de govc por tu cuenta.

## Varias lecturas: modo lote

```powershell
Import-Module ./scripts/lib/GovcBatch.psm1
$cmds = @(@('about'), @('object.collect', '-json', '-type', 'h', '/', 'name'))
$cmds += , @('object.collect', '-json', '-type', 's', '/', 'name', 'summary.freeSpace')   # la coma evita que se aplane
$res = Invoke-GovcBatch -Env <e> -Commands $cmds   # un objeto por comando: i, exitCode, stdout, stderr
```

- Una sola sesión, solo lecturas: el wrapper rechaza el lote completo si un comando no es lectura. Fuera de los scripts permitidos, un lote no se aprueba solo (el hook pide aprobación para `-Batch` porque el contenido va en un archivo).
- Si el perfil define `batchParallel` (> 1), el lote ejecuta esa cantidad de consultas en paralelo; por defecto 1 (secuencial).
- Para consultas interactivas sueltas, usa el wrapper normal. No intentes inspeccionar la sesión del lote: está bloqueado.

## Política por modo (scripts/lib/Classify.psm1 + `mode` del perfil)

| Clase | Ejemplos | `readonly` | `confirm` | `lab` |
|---|---|---|---|---|
| read | `about`, `ls`, `find`, `*.info`, `*.ls`, `*.tree`, `object.collect`, `events`, `tasks`, `metric.sample`, `host.esxcli … list` / `get` | auto | auto | auto |
| write | `vm.clone`, `vm.create`, `vm.change`, `vm.power -on`, `snapshot.create`, `tags.attach`, `folder.create`, desconocidos | bloqueado | aprobación | aprobación |
| destructive | `vm.destroy`, `vm.power -off/-s/-r/-reset/-suspend`, `snapshot.remove/revert`, `*.rm`, `host.maintenance.enter`, `host.esxcli` con verbo distinto de list/get, `object.destroy` | bloqueado | bloqueado (persona en su terminal, con cambio aprobado) | aprobación |
| secret | `env`, `vm.console`, `-debug`, `-password` | bloqueado | bloqueado | bloqueado |

Subcomando no reconocido = write (fail-safe). Consulta el `mode` con `/env`; no lo deduzcas del nombre del entorno.

## Rutas de inventario

```
/<DC>/vm/<carpeta>/<vm>          VMs y plantillas
/<DC>/host/<cluster>/<host>      hosts
/<DC>/host/<cluster>/Resources   resource pool raíz del clúster
/<DC>/datastore/<ds>             datastores
/<DC>/network/<portgroup>        redes
```
MOID directo: `Tipo:valor`, p. ej. `VirtualMachine:vm-123`, `Alarm:alarm-7`.

## Patrones

| Necesidad | Hazlo así | Evita |
|---|---|---|
| Propiedades de todas las VMs | `object.collect -json -type m / name runtime.powerState summary.config.numCpu` | bucle de `vm.info` |
| Detalle de una o varias VMs | `vm.info -json -r <vm1> <vm2>` (`-r` incluye recursos) | `vm.info` sin `-json`; una llamada por VM |
| Snapshots de una VM | `snapshot.tree -vm <vm> -D -i -s` | |
| Eventos recientes | `events -n 50 <ruta>` | `tasks` sin límite |
| Métricas puntuales | `metric.sample -n 12 -json <ruta-de-VM-o-host> cpu.usage.average mem.usage.average` | rutas de clúster, intervalos muy largos |
| Rendimiento en una ventana | `./scripts/Invoke-PerfCheck.ps1 -Env <e> [-Cluster <cl>] [-Window 1h\|24h\|7d]` (`/perf`) | bucles de `metric.sample` por VM |

Tipos de `-type`: `m` VM, `h` host, `s` datastore, `c` clúster, `r` compute resource, `n` red, `g` portgroup distribuido, `w` DVS, `p` resource pool, `f` carpeta, `d` datacenter, `a` vApp.

## Parseo de object.collect

`object.collect -json -type …` emite **varios documentos JSON concatenados**; los arreglos vienen como `{"_value":[…]}`. Usa:

```powershell
Import-Module ./scripts/lib/GovcJson.psm1
./scripts/govc.ps1 -Env <e> object.collect -json -type m / name runtime.powerState | ConvertFrom-GovcCollect
```
Cada objeto tiene `_type`, `_moref` y una propiedad por ruta (acceso con comillas: `$_.'runtime.powerState'`).

## Errores comunes

- `no such host`/`x509`: revisa `url` y `caCerts` del perfil; no actives `insecure` en entornos productivos.
- `NotAuthenticated`/`InvalidLogin`: credencial vencida o ausente → regla 2 de CLAUDE.md.
- `NoPermission`: la cuenta de servicio no tiene el privilegio; no intentes otra cuenta, repórtalo.
- Resultado vacío en `find`: revisa el datacenter del perfil o usa ruta absoluta.
