# esxcli: contexto y lecturas por área

**Analogía:** govc es la administración del edificio (ve todos los pisos, mueve gente entre pisos). esxcli es el técnico de un piso: conoce el cableado, las tuberías y cada enchufe, pero solo de su piso. `govc host.esxcli -host <h>` llama al técnico **a través de la administración**: usa la sesión y los permisos de vCenter, sin SSH ni root del host.

## Lecturas útiles por área

Todas con `./scripts/govc.ps1 -Env <e> host.esxcli -json -host <h> <comando>`; solo verbos `list`/`get`.

| Área | Comandos |
|---|---|
| Red | `network nic list` · `network nic get -n vmnic0` · `network nic stats get -n vmnic0` · `network vswitch standard list` · `network ip interface list` · `network ip interface ipv4 get` · `network ip route ipv4 list` · `network firewall get` · `network firewall ruleset list` |
| Storage | `storage core path list` · `storage core device list` · `storage nmp device list` · `storage core adapter list` · `storage vmfs extent list` · `storage filesystem list` · `iscsi adapter list` |
| Software | `software vib list` · `software vib get -n <vib>` · `software profile get` · `system version get` |
| Sistema | `system ntp get` · `system time get` · `system syslog config get` · `system coredump network get` · `system coredump partition get` · `system maintenanceMode get` · `system hostname get` · `system account list` · `system permission list` |
| Hardware | `hardware platform get` · `hardware cpu global get` · `hardware memory get` · `hardware pci list` |
| vSAN | `vsan cluster get` · `vsan network list` · `vsan storage list` |

Los nombres de campos cambian entre versiones de ESXi; si un campo no aparece, revisa la salida cruda antes de concluir.
