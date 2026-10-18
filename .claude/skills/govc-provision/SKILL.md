---
name: govc-provision
description: Provisión controlada de recursos en vCenter con govc — clonar VM desde plantilla o Content Library, ajustar CPU/RAM/discos/red, personalización de guest, tags, carpetas y snapshots previos a cambios. Flujo validar → planear → aprobar → ejecutar → verificar. Úsala para /vm-create o cualquier petición de crear/modificar recursos (también "provision VM", "clone VM", "create VM from template").
---

# Provisión segura

## Flujo obligatorio

1. **Especificación**: parte de un YAML basado en `templates/vm-spec.example.yaml` (guardado en `specs/`, gitignored) o de los datos que dé la persona. Faltantes críticos (entorno, nombre, origen) → pregunta una sola vez.
2. **Validación (solo lecturas)**, todas con `-json`:
   - El nombre **no existe**: `find / -type m -name <nombre>` debe venir vacío. Si existe, detente.
   - Origen existe y es plantilla: `vm.info -json <template>` (`config.template = true`) o `library.info <item>`.
   - Destinos existen: `ls <folder>`, `datastore.info <ds>` (y espacio libre suficiente), `ls /<DC>/network/<pg>`, `ls <pool>`.
   - Tags/categorías existen: `tags.ls -c <categoría>`.
   - Customization spec: `object.collect` no la lista; usa `vm.customize` solo con spec existente confirmada por la persona.
   - Consulta el `mode` del perfil (`/env`): en `readonly` no hay escrituras posibles; en `prod` (y cualquier entorno productivo) exige número de cambio en la spec (`change`).
3. **Plan**: muestra una tabla con lo que se creará y la lista **exacta** de comandos, en orden, cada uno con su clase (write/destructive). Indica capacidad que consumirá (vCPU, RAM, GB).
4. **Ejecución**: un comando por llamada; el hook pedirá aprobación en cada escritura. Si un paso falla, detente, informa y propone cómo revertir (no reviertas por tu cuenta en prod).
5. **Verificación**: `vm.info -json -r <nombre>` y `vm.ip -wait 5m <nombre>` si se encendió. Resume estado final vs. spec.

## Comandos de referencia

```powershell
# Clonar desde plantilla (apagada, sin encender)
./scripts/govc.ps1 -Env lab vm.clone -vm tpl-rhel9 -folder /DC-LAB/vm/Pruebas -ds DS-LAB-01 -pool /DC-LAB/host/CL-LAB-01/Resources -on=false lab-app01
# Desde Content Library
./scripts/govc.ps1 -Env lab library.deploy -folder /DC-LAB/vm/Pruebas -ds DS-LAB-01 /Plantillas/tpl-rhel9 lab-app01
# Hardware
./scripts/govc.ps1 -Env lab vm.change -vm lab-app01 -c 2 -m 4096
./scripts/govc.ps1 -Env lab vm.disk.create -vm lab-app01 -ds DS-LAB-01 -name lab-app01/data1 -size 50G -thick=false
# Red
./scripts/govc.ps1 -Env lab vm.network.change -vm lab-app01 -net "VM Network" ethernet-0
# Personalización (spec existente) / IP estática
./scripts/govc.ps1 -Env lab vm.customize -vm lab-app01 -name lab-app01 -ip 10.10.20.15 -netmask 255.255.255.0 -gateway 10.10.20.1 -dns-server 10.10.0.10
# Anotación y tags
./scripts/govc.ps1 -Env lab vm.change -vm lab-app01 -annotation "Dueño: Equipo Aplicaciones | Cambio: CHG-1234"
./scripts/govc.ps1 -Env lab tags.attach -c Ambiente Lab /DC-LAB/vm/Pruebas/lab-app01
# Encender (write; solo si la spec lo pide)
./scripts/govc.ps1 -Env lab vm.power -on lab-app01
# Snapshot previo a un cambio en VM existente
./scripts/govc.ps1 -Env prod snapshot.create -vm app01 -d "CHG-1234 previo a parche" pre-CHG-1234
```

Ajusta rutas a lo que devolvió la validación; nunca a los ejemplos.

## Otros recursos

| Recurso | Comando (write) |
|---|---|
| Carpeta | `folder.create /<DC>/vm/<carpeta>` |
| Resource pool | `pool.create -cpu.shares normal /<DC>/host/<cluster>/Resources/<pool>` |
| Categoría / tag | `tags.category.create -m=false <cat>` · `tags.create -c <cat> <tag>` |
| Portgroup DVS | `dvs.portgroup.add -dvs <dvs> -vlan <id> <pg>` (impacto de red: validar con Redes) |
| Convertir a plantilla | `vm.markastemplate <vm>` |

## Reglas

- Nunca sobrescribas ni reutilices un nombre existente; nunca uses `-force`.
- `... resolves to multiple instances, please specify`: pasa `-pool`, `-ds` o `-host` explícitos (el perfil puede no definirlos).
- `vm.markastemplate` requiere la VM apagada; apagar es destructivo: fuera de `lab` lo hace una persona en su terminal.
- Nada destructivo como parte de una provisión (si algo debe borrarse, la persona lo hace en su terminal).
- No enciendas VMs si la spec no lo pide.
- Portgroups y VLAN: la VLAN la asigna Redes; confírmala antes de crear el portgroup.
