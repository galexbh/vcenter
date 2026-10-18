---
name: govc-esxcli
description: Diagnóstico a nivel de host ESXi con esxcli vía govc (host.esxcli) — VIBs y drivers, NIC físicas, paths de storage, NTP, syslog, coredump, plataforma — y comparación entre hosts para detectar drift. Úsala para /host-check o cuando pregunten por configuración interna de un host que vCenter no muestra (también "esxcli host check", "ESXi host drift", "host configuration").
---

# esxcli vía govc

`host.esxcli -host <h>` ejecuta esxcli en el host **a través de vCenter** (su sesión y permisos), sin SSH ni root del host. Contexto y catálogo de lecturas por área: [lecturas.md](lecturas.md).

## Regla 1: primero vCenter

Si vCenter ya lo sabe, usa govc nativo: una sola llamada para todos los hosts, sin cargar a cada uno.

| Necesidad | govc nativo | esxcli solo para el detalle |
|---|---|---|
| Servicios (SSH, Shell, NTP) | `host.service.ls -host h` | — |
| Hora / NTP | `host.date.info -host h` | `system ntp get` |
| vmknics / portgroups | `host.vnic.info -host h`, `host.portgroup.info -host h` | `network ip interface ipv4 get` |
| Opciones avanzadas | `host.option.ls -host h <clave>` | — |
| Storage | `host.storage.info -host h` | `storage core path list`, `storage nmp device list` |
| Certificado | `host.cert.info -host h` | — |
| Inventario masivo de hosts | `object.collect -json -type h / …` | — |
| VIBs, drivers, firmware | — | `software vib list`, `network nic get -n vmnic0` |
| NIC físicas | — | `network nic list` |
| Syslog / coredump | — | `system syslog config get`, `system coredump network get`, `system coredump partition get` |
| Plataforma | — | `hardware platform get` |

## Sintaxis

```powershell
./scripts/govc.ps1 -Env <e> host.esxcli -json -host <host> network nic list
```

- Flags de govc (`-json`, `-host`) **antes** del comando esxcli; las opciones de esxcli (`-n`, `-d`) después.
- La salida JSON trae `values: [{Campo: [valor]}]`: cada valor es un arreglo, normalmente de un elemento.

## Clasificación (según el `mode` del perfil)

| Verbo esxcli | Clase | `readonly` / `confirm` | `lab` |
|---|---|---|---|
| `list`, `get` | read | automático | automático |
| cualquier otro (`set`, `add`, `remove`, `install`, `update`, `enable`, `disable`, `load`, `unload`…) o sin verbo reconocible | destructive | bloqueado: lo hace una persona con cambio aprobado | aprobación |
| `system settings encryption …`, `system account` (excepto list) | secret | bloqueado | bloqueado |

## Ronda por clúster

```powershell
./scripts/Invoke-HostCheck.ps1 -Env <e> -Cluster <clúster>                 # todos los chequeos
./scripts/Invoke-HostCheck.ps1 -Env <e> -Hosts <host> -Checks nics, paths
./scripts/Invoke-HostCheck.ps1 -FromRaw reports/<env>/<marca>              # re-render sin consultar
```

Chequeos: `vibs`, `nics`, `paths`, `ntp`, `syslog`, `coredump`, `platform`, `services`, `certs` (certificados de host con `host.cert.info`; umbral `-CertWarnDays`, 60 por defecto). Hace una consulta por host y chequeo, agrupadas en lotes de lectura; en clústeres grandes, filtra por clúster. Los hosts no conectados o sin permisos aparecen como hallazgo de **Cobertura**, no como error.

## Reglas

- Nunca propongas habilitar SSH para "ver mejor": todo lo de lectura se puede hacer por vCenter.
- Cambios en un host (VIB, firewall, NTP, syslog, mantenimiento) son **destructive**: escríbelos como propuesta, con impacto y rollback, para que los ejecute una persona con cambio aprobado. Indica el orden recomendado (primero lo que reduce riesgo: SSH detenido, syslog remoto, NTP) y la verificación posterior.
- Si una lectura falla con `NoPermission`, repórtalo: la cuenta de servicio puede necesitar privilegios de lectura de configuración de host. No cambies de cuenta.
