---
name: govc-esxcli
description: Diagnóstico a nivel de host ESXi con esxcli vía govc (host.esxcli) — VIBs y drivers, NIC físicas, paths de storage, NTP, syslog, coredump, plataforma — y comparación entre hosts para detectar drift. Úsala para /host-check o cuando pregunten por configuración interna de un host que vCenter no muestra.
---

# esxcli vía govc: el técnico de cada piso

**Analogía:** govc es la administración del edificio (ve todos los pisos, mueve gente entre pisos). esxcli es el técnico de un piso: conoce el cableado, las tuberías y cada enchufe, pero solo de su piso. `govc host.esxcli -host <h>` llama al técnico **a través de la administración**: usa la sesión y los permisos de vCenter, sin SSH ni root del host.

## Regla 1: primero la administración

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
./scripts/govc.ps1 -Env prod host.esxcli -json -host esx01.local network nic list
```

- Flags de govc (`-json`, `-host`) **antes** del comando esxcli; las opciones de esxcli (`-n`, `-d`) después.
- La salida JSON trae `values: [{Campo: [valor]}]`: cada valor es un arreglo, normalmente de un elemento.

## Clasificación

| Verbo esxcli | Clase | prod / dr | lab |
|---|---|---|---|
| `list`, `get` | read | automático | automático |
| cualquier otro (`set`, `add`, `remove`, `install`, `update`, `enable`, `disable`, `load`, `unload`…) | destructive | bloqueado: lo hace una persona con cambio aprobado | aprobación |
| `system settings encryption …`, `system account` (excepto list) | secret | bloqueado | bloqueado |
| sin verbo reconocible | destructive | bloqueado | aprobación |

## Lecturas útiles por área

| Área | Comandos |
|---|---|
| Red | `network nic list` · `network nic get -n vmnic0` · `network nic stats get -n vmnic0` · `network vswitch standard list` · `network ip interface list` · `network ip interface ipv4 get` · `network ip route ipv4 list` · `network firewall get` · `network firewall ruleset list` |
| Storage | `storage core path list` · `storage core device list` · `storage nmp device list` · `storage core adapter list` · `storage vmfs extent list` · `storage filesystem list` · `iscsi adapter list` |
| Software | `software vib list` · `software vib get -n <vib>` · `software profile get` · `system version get` |
| Sistema | `system ntp get` · `system time get` · `system syslog config get` · `system coredump network get` · `system coredump partition get` · `system maintenanceMode get` · `system hostname get` · `system account list` · `system permission list` |
| Hardware | `hardware platform get` · `hardware cpu global get` · `hardware memory get` · `hardware pci list` |
| vSAN | `vsan cluster get` · `vsan network list` · `vsan storage list` |

Los nombres de campos cambian entre versiones de ESXi; si un campo no aparece, revisa la salida cruda antes de concluir.

## Ronda por clúster

```powershell
./scripts/Invoke-HostCheck.ps1 -Env prod -Cluster CL-PROD-01            # todos los chequeos
./scripts/Invoke-HostCheck.ps1 -Env prod -Hosts esx01.local -Checks nics, paths
./scripts/Invoke-HostCheck.ps1 -FromRaw reports/prod/<marca>            # re-render sin consultar
```

Chequeos: `vibs`, `nics`, `paths`, `ntp`, `syslog`, `coredump`, `platform`, `services`, `certs` (certificados de host con `host.cert.info`; umbral `-CertWarnDays`, 60 por defecto). Corre en secuencia, una llamada por host y chequeo; en clústeres grandes, filtra por clúster. Los hosts no conectados o sin permisos aparecen como hallazgo de **Cobertura**, no como error.

## Reglas

- Nunca propongas habilitar SSH para "ver mejor": todo lo de lectura se puede hacer por vCenter.
- Cambios en un host (VIB, firewall, NTP, syslog, mantenimiento) son **destructive**: escríbelos como propuesta, con impacto y rollback, para que los ejecute una persona con cambio aprobado. Recomienda validar con Infraestructura y, si tocan logs, SSH o firewall, con Seguridad de la Información.
- Si una lectura falla con `NoPermission`, repórtalo: la cuenta de servicio puede necesitar privilegios de lectura de configuración de host. No cambies de cuenta.
