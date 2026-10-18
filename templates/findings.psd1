# Catálogo de textos de los hallazgos (sugerencias, riesgos y notas).
#
# Los scripts calculan la evidencia; aquí está QUÉ HACER. Se lee con Import-PowerShellDataFile
# (lenguaje restringido: solo datos, nada se ejecuta). Para ajustar el tono basta editar este archivo.
#
# Pautas:
#   - Acción en imperativo + motivo breve + "cambio aprobado" si la acción modifica la plataforma.
#   - Sin "validar con…" ni "escalar a…": el equipo que ejecuta el proyecto es el que decide.
#   - Otra área solo si cambia la acción (Test-Reports lo controla): Storage en path-dead y el dueño
#     de la VM en snap-age, vm-off (antes de eliminar) y perf-oversized (antes de reducir recursos).
#   - Marcadores {nombre}: se reemplazan como texto literal (nunca se evalúan).
#   - Suggestion puede ser un texto o una tabla por severidad (Crítico / Advertencia / Info).
@{
    Rules = @{
        # --- Inventario, capacidad y configuración (New-Report.ps1) -------------------------
        'ds-inaccessible'  = @{ Suggestion = 'Restablecer el acceso al datastore (paths, LUN o NFS) de inmediato; las VMs que escriben en él están en riesgo.' }
        'ds-used'          = @{ Suggestion = @{
                'Crítico'     = 'Liberar espacio ya (snapshots viejos, ISOs, VMs huérfanas) o mover VMs con Storage vMotion; al llenarse, vSphere pausa las VMs que escriben en él.'
                'Advertencia' = 'Planificar liberación o ampliación antes de llegar al umbral crítico.'
            } }
        'ds-trend'         = @{ Suggestion = @{
                'Crítico'     = 'Liberar espacio o mover VMs esta semana: al ritmo actual el datastore llega al 90 % en días.'
                'Advertencia' = 'Planificar liberación o ampliación antes de la fecha estimada.'
            } }
        'ds-thin'          = @{ Suggestion = 'Limitar el sobreaprovisionamiento: si los discos thin crecen, el datastore se llena; mover VMs o ampliar.' }
        'snap-age'         = @{ Suggestion = @{
                'Crítico'     = 'Eliminar o consolidar el snapshot (cambio aprobado) tras confirmar con el dueño de la VM; degrada I/O y consume datastore.'
                'Advertencia' = 'Eliminar el snapshot si ya no se usa (confirmar con el dueño de la VM); no es un respaldo.'
            } }
        'host-state'       = @{ Suggestion = 'Atender de inmediato: revisar red de gestión y servicios hostd/vpxa; si el hardware no responde, abrir caso con el fabricante.' }
        'host-maint'       = @{ Suggestion = 'Si no hay ventana activa, sacar el host de mantenimiento y reintegrarlo al clúster.' }
        'host-mem'         = @{ Suggestion = 'Redistribuir carga con DRS o vMotion; con memoria alta el host pasa a balloon y swap.' }
        'cl-vcpu'          = @{ Suggestion = @{
                'Crítico'     = 'Medir CPU ready (Invoke-PerfCheck) y reducir vCPU sobredimensionadas; si el ready supera el 5 %, agregar capacidad.'
                'Advertencia' = 'Medir CPU ready antes de seguir asignando vCPU en este clúster.'
            } }
        'cl-mem'           = @{ Suggestion = 'Revisar ballooning y swap (Invoke-PerfCheck) y ajustar la RAM de las VMs más sobredimensionadas.' }
        'cl-n1-mem'        = @{ Suggestion = @{
                'Crítico'     = 'Agregar un host o reducir carga: si falla el host mayor, HA no puede reiniciar todas las VMs.'
                'Advertencia' = 'No sumar carga al clúster sin capacidad adicional; queda poco margen ante la falla de un host.'
            } }
        'cl-n1-cpu'        = @{ Suggestion = @{
                'Crítico'     = 'Agregar un host o reducir carga: sin el host mayor, la CPU disponible no alcanza para la carga actual.'
                'Advertencia' = 'No sumar carga al clúster sin capacidad adicional; queda poco margen de CPU ante la falla de un host.'
            } }
        'cl-n1-single'     = @{ Suggestion = 'Agregar un segundo host si las VMs requieren alta disponibilidad; con uno solo, HA no tiene dónde reiniciarlas.' }
        'cl-ha-admission'  = @{ Suggestion = 'Habilitar el control de admisión (cambio aprobado): sin él se encienden VMs aunque ya no haya capacidad para reiniciarlas ante una falla.' }
        'cl-ha'            = @{ Suggestion = 'Habilitar vSphere HA (cambio aprobado) para que las VMs se reinicien ante la falla de un host.' }
        'cl-drs'           = @{ Suggestion = 'Pasar DRS a partiallyAutomated o fullyAutomated (cambio aprobado) para balanceo automático y mantenimientos sin interrupción.' }
        'vm-off'           = @{ Suggestion = 'Dar de baja las que ya no se usen, tras confirmarlo con su dueño; consumen almacenamiento y licencias.' }
        'tools-missing'    = @{ Suggestion = 'Instalar VMware Tools u open-vm-tools: sin ellas no hay apagado ordenado, quiesce de respaldos ni métricas del guest.' }
        'tools-notrunning' = @{ Suggestion = 'Arrancar el servicio de VMware Tools en el guest y dejarlo en inicio automático.' }
        'tools-old'        = @{ Suggestion = 'Actualizar VMware Tools en la próxima ventana de mantenimiento.' }
        'vm-consolidate'   = @{ Suggestion = 'Consolidar los discos en una ventana (Snapshots → Consolidar); los delta sin consolidar degradan I/O y consumen espacio.' }
        'vm-limits'        = @{ Suggestion = 'Quitar los límites de CPU o memoria salvo que sean intencionales; provocan contención aunque el host tenga recursos.' }
        'vm-balloon'       = @{ Suggestion = 'Reducir la presión de memoria del host (vMotion o DRS) y revisar el tamaño de la VM.' }
        'vm-swap'          = @{ Suggestion = 'Liberar memoria en el host o mover la VM: el swap del hipervisor degrada mucho el rendimiento.' }
        'vm-compressed'    = @{ Suggestion = 'Vigilar la memoria del host: la compresión anticipa balloon y swap.' }
        'rp-limit'         = @{ Suggestion = 'Quitar el límite del resource pool salvo que sea intencional; limita a todas sus VMs aunque el clúster tenga recursos.' }
        'vm-iso'           = @{ Suggestion = 'Desconectar la ISO cuando no se use: impide vMotion y DRS hacia hosts sin acceso a ese datastore.' }
        'coverage-devices' = @{ Suggestion = 'Ejecutar sin -SkipDeviceScan (o por clúster) para revisar las ISO conectadas.' }
        'vm-hwversion'     = @{ Suggestion = 'Actualizar el hardware virtual en la próxima ventana (requiere reinicio; probar antes la compatibilidad del SO).' }
        'alarm'            = @{ Suggestion = 'Atender la condición según el runbook de la alarma y reconocerla una vez resuelta.' }
        'cert-vc'          = @{ Suggestion = @{
                'Crítico'     = 'Renovar el certificado de vCenter ya (cambio aprobado): las conexiones y las integraciones fallan.'
                'Advertencia' = 'Programar la renovación del certificado de vCenter antes del vencimiento.'
            } }
        'license'          = @{ Suggestion = @{
                'Crítico'     = 'Renovar la licencia ya: se pierden funcionalidades.'
                'Advertencia' = 'Gestionar la renovación de la licencia antes del vencimiento.'
            } }

        # --- Revisión de hosts (Invoke-HostCheck.ps1) ------------------------------------------
        'coverage-check'     = @{ Suggestion = 'Revisar el estado del host, la versión de ESXi o los privilegios de la cuenta de servicio sobre la configuración del host.' }
        'vib-drift'          = @{ Suggestion = 'Homologar con la imagen o baseline del clúster (vLCM); versiones distintas rompen vMotion, HA o el soporte del fabricante.' }
        'nic-nolink'         = @{ Suggestion = 'Revisar cable y puerto del switch: si la NIC está en un vSwitch o DVS, hoy no hay redundancia.' }
        'nic-speed'          = @{ Suggestion = 'Igualar la negociación de puertos entre hosts; afecta vMotion y el balanceo.' }
        'nic-mtu'            = @{ Suggestion = 'Igualar el MTU entre hosts: un MTU distinto rompe jumbo frames (vMotion, iSCSI, vSAN).' }
        'path-dead'          = @{ Suggestion = 'Revisar zoning, HBA y target con Storage; mientras tanto, el LUN depende de los paths restantes.' }
        'path-single'        = @{ Suggestion = 'Agregar un segundo path: con uno solo, una falla de HBA o switch deja el LUN inaccesible.' }
        'ntp-disabled'       = @{ Suggestion = 'Iniciar ntpd con política on: la hora inconsistente afecta logs, Kerberos/AD, certificados y la correlación de eventos.' }
        'ntp-servers'        = @{ Suggestion = 'Usar las mismas fuentes NTP en todos los hosts del clúster.' }
        'syslog-remote'      = @{ Suggestion = 'Configurar syslog remoto hacia el SIEM: sin él, los logs se pierden ante una falla del host.' }
        'coredump'           = @{ Suggestion = 'Configurar un destino de coredump (red o partición local): sin él, un PSOD no deja evidencia para el fabricante.' }
        'platform-mixed'     = @{ Suggestion = 'Confirmar el modo EVC del clúster para que vMotion y DRS funcionen entre modelos distintos.' }
        'svc'                = @{ Suggestion = 'Detener {label} y dejar la política en off; habilitarlo solo durante una ventana de soporte.' }
        'cert-host-expired'  = @{ Suggestion = 'Renovar el certificado del host ya (cambio aprobado): vCenter puede perder la conexión con el host.' }
        'cert-host-expiring' = @{ Suggestion = 'Programar la renovación del certificado del host antes del vencimiento.' }

        # --- Rendimiento (Invoke-PerfCheck.ps1) -------------------------------------------------
        'perf-cpu-ready'         = @{ Suggestion = @{
                'Crítico'     = 'Reducir vCPU sobredimensionadas o mover la VM a un host con menos carga; la VM espera para ejecutarse.'
                'Advertencia' = 'No sumar vCPU a estas VMs y vigilar la tendencia; la contención es moderada.'
            } }
        'perf-balloon'           = @{ Suggestion = 'Reducir la presión de memoria del host (vMotion o DRS); el host está recuperando memoria del guest.' }
        'perf-swap'              = @{ Suggestion = @{
                'Advertencia' = 'Liberar memoria en el host o mover la VM: el swap sostenido degrada mucho el rendimiento.'
                'Info'        = 'Revisar si el pico coincide con arranques, vMotion o respaldos; si se repite, tratarlo como sostenido.'
            } }
        'perf-host-cpu'          = @{ Suggestion = @{
                'Crítico'     = 'Redistribuir carga (DRS o vMotion) o agregar capacidad: el host estuvo saturado durante la ventana.'
                'Advertencia' = 'Redistribuir carga antes de que suba el CPU ready de sus VMs.'
            } }
        'perf-net-drops'         = @{ Suggestion = 'Revisar saturación de uplinks y el tamaño de los anillos de la NIC; ampliar uplinks o redistribuir tráfico.' }
        'perf-ds-latency'        = @{ Suggestion = @{
                'Crítico'     = 'Mover las VMs más demandantes y revisar la carga del arreglo, los paths y las colas (queue depth).'
                'Advertencia' = 'Identificar las VMs más demandantes del datastore y repartirlas antes de que llegue a crítico.'
            } }
        'perf-oversized'         = @{ Suggestion = 'Reducir vCPU y RAM a lo sugerido en la próxima ventana (requiere reinicio; confirmar con el dueño de la VM): la capacidad recuperada evita ampliar el clúster.' }
        'coverage-perf-counters' = @{ Suggestion = 'Usar -Window 1h (tiempo real) o subir el nivel de estadísticas del intervalo a 2 (escritura con cambio aprobado; aumenta el tamaño de la base de datos de vCenter).' }
        'coverage-perf-hosts'    = @{ Suggestion = 'Restablecer la conexión de esos hosts con vCenter y repetir la revisión.' }
        'coverage-perf-error'    = @{ Suggestion = 'Dar a la cuenta de servicio el privilegio de lectura de estadísticas de rendimiento y repetir la revisión.' }

        # --- Auditoría (Invoke-Audit.ps1) --------------------------------------------------------
        'perm-root-admins' = @{ Suggestion = 'Reducir las asignaciones con rol Administrador en la raíz y usar roles personalizados acotados (mínimo privilegio).' }
        'perm-root-users'  = @{ Suggestion = 'Reemplazar las asignaciones a usuarios individuales por grupos del directorio.' }
        'coverage-access'  = @{ Suggestion = 'Dar a la cuenta de servicio permiso de lectura de permisos y roles, y repetir la auditoría.' }
        'coverage-perf'    = @{ Suggestion = 'Ejecutar la auditoría con la fuente de rendimiento (o Invoke-PerfCheck) para evaluar latencia y contención.' }
    }

    # Riesgo y referencia por categoría (informe de auditoría).
    Categories = @{
        'Hosts'              = @{ Risk = 'Pérdida de gestión o de protección HA para las VMs del host.' }
        'Alarmas'            = @{ Risk = 'Condición activa reportada por vCenter; impacto según la alarma.' }
        'Storage'            = @{ Risk = 'Pérdida de acceso a LUN o de redundancia de ruta; posible indisponibilidad de VMs.' }
        'Red física'         = @{ Risk = 'Pérdida de redundancia o rendimiento de red; fallas en vMotion o almacenamiento IP.' }
        'Clúster'            = @{ Risk = 'Las VMs no se reinician automáticamente ante falla de un host, o la carga no se balancea.' }
        'Almacenamiento'     = @{ Risk = 'Si el datastore se llena, vSphere pausa las VMs que escriben en él.' }
        'Capacidad'          = @{ Risk = 'Contención de CPU o memoria; capacidad insuficiente para tolerar la falla de un host.' }
        'Rendimiento'        = @{ Risk = 'Latencia o contención que degradan el servicio aunque la capacidad asignada parezca suficiente.' }
        'VMware Tools'       = @{ Risk = 'Sin apagado ordenado, sin quiesce para respaldos y sin métricas del sistema invitado.' }
        'Drift VIBs/drivers' = @{ Risk = 'Comportamiento inconsistente entre hosts; riesgo en vMotion, HA y soporte del fabricante.'; Reference = 'VMware vSphere Security Configuration Guide · CIS Benchmark para VMware ESXi — nivel de aceptación e integridad de VIBs' }
        'Tiempo'             = @{ Risk = 'Desfase horario: afecta autenticación, certificados y correlación de eventos.'; Reference = 'VMware vSphere Security Configuration Guide · CIS Benchmark para VMware ESXi — sincronización de tiempo (NTP)' }
        'Diagnóstico'        = @{ Risk = 'Sin evidencia para el fabricante ante una falla grave del host.' }
        'Plataforma'         = @{ Risk = 'Heterogeneidad de hardware; restricciones de EVC y de balanceo.' }
        'Configuración VM'   = @{ Risk = 'Configuraciones que limitan rendimiento, movilidad o mantenimiento de las VMs.' }
        'Licencias'          = @{ Risk = 'Pérdida de funcionalidades al vencer la licencia.' }
        'Seguridad'          = @{ Risk = 'Mayor superficie de ataque sobre el hipervisor.'; Reference = 'VMware vSphere Security Configuration Guide · CIS Benchmark para VMware ESXi — servicios de acceso (SSH / ESXi Shell)' }
        'Logs'               = @{ Risk = 'Los eventos solo quedan en el host: se pierden ante falla y no llegan al monitoreo central.'; Reference = 'VMware vSphere Security Configuration Guide · CIS Benchmark para VMware ESXi — registro remoto (syslog)' }
        'Certificados'       = @{ Risk = 'Interrupción de conexiones y alertas de confianza al vencer el certificado.'; Reference = 'VMware vSphere Security Configuration Guide — gestión de certificados' }
        'Permisos'           = @{ Risk = 'Exceso de privilegios: mayor impacto ante credenciales comprometidas o errores.'; Reference = 'VMware vSphere Security Configuration Guide — control de acceso y roles de vCenter' }
        'Snapshots'          = @{ Risk = 'Degradación de rendimiento y consumo de espacio; consolidaciones prolongadas.' }
        'Higiene'            = @{ Risk = 'Consumo de recursos y licencias sin uso aparente.' }
    }

    # Textos comunes.
    Notes = @{
        'thresholds'      = 'Los umbrales son de práctica habitual, no normativos: ajustarlos a la política interna de capacidad con los parámetros de cada script.'
        'perf-table'      = 'Métricas de solo lectura (metric.sample), ventana {window}. Umbrales ajustables con -CpuReadyWarnPct, -DsLatencyWarnMs y -HostCpuWarnPct.'
        'review-commands' = 'Los comandos son consultas de revisión; ningún cambio se ejecutó.'
    }
}
