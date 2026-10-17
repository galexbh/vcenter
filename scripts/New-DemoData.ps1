<#
.SYNOPSIS
  Genera un entorno de DEMOSTRACIÓN ficticio para ver o probar reportes sin consultar vCenter.

.DESCRIPTION
  Crea una carpeta con la misma estructura que deja Invoke-Audit.ps1 (raw/, inventario/raw/,
  hosts/raw/), con 2 clústeres, 7 hosts y ~40 VMs con hallazgos sembrados. Todos los nombres,
  IPs y cifras son inventados y se rotulan como entorno "demo". Luego se renderiza con:
    ./scripts/Invoke-Audit.ps1 -FromRaw <carpeta>
    ./scripts/New-Report.ps1  -FromRaw <carpeta>/inventario -Format html,md,csv
  -EdgeCases agrega casos límite usados por scripts/Test-Reports.ps1 (VM sin host, nombre que
  empieza con '=', textos con | [] < > y saltos de línea, marcadores de plantilla dentro de los
  datos ({{SECTIONS}}, {{ANNEXES}}, {{REMEDIATION}}), nombre de VM con comilla invertida (`) y
  chequeo de host con error en dos hosts).

.EXAMPLE
  ./scripts/New-DemoData.ps1
  ./scripts/New-DemoData.ps1 -OutDir $env:TEMP\demo -EdgeCases
#>
param(
    [string]$OutDir,
    [switch]$EdgeCases
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$AuditDir = if ($OutDir) { $OutDir } else { Join-Path $root ("reports/demo/{0:yyyyMMdd-HHmmss}-auditoria" -f (Get-Date)) }
$rnd = [Random]::new(20261017)
$now = Get-Date
$inv = Join-Path $AuditDir 'inventario/raw'; $hst = Join-Path $AuditDir 'hosts/raw'; $aud = Join-Path $AuditDir 'raw'
New-Item -ItemType Directory -Force -Path $inv, $hst, $aud | Out-Null
function Save($dir, $name, $obj, $depth = 12) { ConvertTo-Json -InputObject $obj -Depth $depth | Set-Content (Join-Path $dir "$name.json") -Encoding utf8 }
function Ref($type, $value) { [pscustomobject]@{ type = $type; value = $value } }
$GB = 1GB

# --- Clústeres y hosts -----------------------------------------------------------
$clusters = @(
    @{ id = 'domain-c10'; name = 'CL-PROD-01'; hosts = 4; ha = $true; drs = $true; behavior = 'fullyAutomated' }
    @{ id = 'domain-c20'; name = 'CL-PROD-02'; hosts = 3; ha = $false; drs = $true; behavior = 'manual' }
)
$hosts = @(); $hi = 0
foreach ($c in $clusters) {
    for ($i = 1; $i -le $c.hosts; $i++) {
        $hi++
        $hosts += [pscustomobject]@{
            _type = 'HostSystem'; _moref = "host-$($hi)0"; name = ('esx{0:00}.demo.local' -f $hi); parent = Ref 'ClusterComputeResource' $c.id
            'summary.hardware.numCpuCores' = 32; 'summary.hardware.cpuMhz' = 2600; 'summary.hardware.memorySize' = [long](512 * $GB)
            'summary.quickStats.overallCpuUsage' = 18000 + $rnd.Next(0, 30000); 'summary.quickStats.overallMemoryUsage' = 250000 + $rnd.Next(0, 200000)
            'runtime.connectionState' = 'connected'; 'runtime.inMaintenanceMode' = $false
            'summary.config.product.fullName' = 'VMware ESXi 8.0.3 build-24022510'
            cluster = $c.name
        }
    }
}
$hosts[3].'runtime.inMaintenanceMode' = $true                       # esx04 en mantenimiento
$hosts[5].'summary.quickStats.overallMemoryUsage' = 470000          # esx06 con RAM alta
$hosts[6].'summary.config.product.fullName' = 'VMware ESXi 8.0.2 build-22380479'

$compute = @($clusters | ForEach-Object {
        $n = $_.hosts
        [pscustomobject]@{ _type = 'ClusterComputeResource'; _moref = $_.id; name = $_.name; 'summary.numCpuCores' = 32 * $n; 'summary.totalMemory' = [long](512 * $GB * $n); 'summary.numHosts' = $n; 'summary.numEffectiveHosts' = $n }
    })
$clusterCfg = @($clusters | ForEach-Object {
        [pscustomobject]@{ _type = 'ClusterComputeResource'; _moref = $_.id; name = $_.name; configurationEx = [pscustomobject]@{ dasConfig = [pscustomobject]@{ enabled = $_.ha }; drsConfig = [pscustomobject]@{ enabled = $_.drs; defaultVmBehavior = $_.behavior } } }
    })

# --- VMs ---------------------------------------------------------------------------
$roles = @(
    @{ p = 'app-erp'; n = 6; cpu = 8; mem = 32768; os = 'Red Hat Enterprise Linux 9 (64-bit)'; disk = 180 }
    @{ p = 'db-core'; n = 4; cpu = 16; mem = 131072; os = 'Red Hat Enterprise Linux 8 (64-bit)'; disk = 900 }
    @{ p = 'web-banca'; n = 8; cpu = 4; mem = 16384; os = 'Ubuntu Linux (64-bit)'; disk = 60 }
    @{ p = 'win-ad'; n = 3; cpu = 4; mem = 16384; os = 'Microsoft Windows Server 2022 (64-bit)'; disk = 120 }
    @{ p = 'app-pagos'; n = 6; cpu = 8; mem = 32768; os = 'Red Hat Enterprise Linux 9 (64-bit)'; disk = 200 }
    @{ p = 'mon-obs'; n = 3; cpu = 8; mem = 32768; os = 'Ubuntu Linux (64-bit)'; disk = 500 }
    @{ p = 'win-app'; n = 6; cpu = 4; mem = 16384; os = 'Microsoft Windows Server 2019 (64-bit)'; disk = 150 }
    @{ p = 'test-qa'; n = 4; cpu = 2; mem = 8192; os = 'Ubuntu Linux (64-bit)'; disk = 40 }
)
$vms = @(); $vi = 0
foreach ($r in $roles) {
    for ($i = 1; $i -le $r.n; $i++) {
        $vi++
        $h = $hosts[$vi % $hosts.Count]; if ($h.'runtime.inMaintenanceMode') { $h = $hosts[0] }
        $vms += [pscustomobject]@{
            _type = 'VirtualMachine'; _moref = "vm-$(1000 + $vi)"; name = ('{0}{1:00}' -f $r.p, $i)
            'runtime.powerState' = 'poweredOn'; 'runtime.host' = Ref 'HostSystem' $h._moref
            'summary.config.numCpu' = $r.cpu; 'summary.config.memorySizeMB' = $r.mem; 'summary.config.guestFullName' = $r.os
            'summary.storage.committed' = [long](($r.disk + $rnd.Next(0, 40)) * $GB); 'summary.storage.uncommitted' = [long]($rnd.Next(0, 80) * $GB)
            'guest.toolsRunningStatus' = 'guestToolsRunning'; 'guest.toolsVersionStatus2' = 'guestToolsCurrent'
            'guest.ipAddress' = "10.20.$([int](10 + $vi / 50)).$((10 + $vi) % 250)"; 'config.template' = $false
            'snapshot.rootSnapshotList' = @(); 'runtime.consolidationNeeded' = $false; 'config.version' = 'vmx-20'
            'config.cpuAllocation.limit' = -1; 'config.memoryAllocation.limit' = -1; 'config.hardware.device' = @()
        }
    }
}
function Snap($name, $days, $desc, $children = @()) {
    [pscustomobject]@{ name = $name; createTime = $now.AddDays(-$days).AddHours(-3).ToString('o'); description = $desc; snapshot = Ref 'VirtualMachineSnapshot' "snapshot-$($rnd.Next(100,999))"; childSnapshotList = @($children) }
}
$byName = @{}; foreach ($v in $vms) { $byName[$v.name] = $v }
$byName['app-erp02'].'snapshot.rootSnapshotList' = @(Snap 'pre-update-CHG-0912' 47 'Antes de parche de ERP')
$byName['db-core01'].'snapshot.rootSnapshotList' = @(Snap 'VEEAM BACKUP TEMPORARY SNAPSHOT' 12 'Please do not delete this snapshot. It is being used by Veeam Backup.')
$byName['web-banca03'].'snapshot.rootSnapshotList' = @(Snap 'base' 21 '' @(Snap 'prueba-1' 15 '' @(Snap 'prueba-2' 9 '')))
$byName['app-pagos04'].'snapshot.rootSnapshotList' = @(Snap 'pre-CHG-1033' 2 'Respaldo previo a cambio aprobado')
$byName['app-pagos05'].'runtime.consolidationNeeded' = $true
$byName['db-core03'].'config.memoryAllocation.limit' = 65536
$byName['win-app02'].'config.hardware.device' = @([pscustomobject]@{ label = 'CD/DVD drive 1'; fileName = '[DS-PROD-ISO] iso/SW_DVD9_Win_Server_2019.iso'; connected = $true })
foreach ($n in 'win-app04', 'win-app05', 'win-ad03') { $byName[$n].'config.version' = 'vmx-13' }
$byName['win-app06'].'guest.toolsRunningStatus' = 'guestToolsNotRunning'
$byName['web-banca07'].'guest.toolsVersionStatus2' = 'guestToolsNeedUpgrade'
$byName['web-banca08'].'guest.toolsVersionStatus2' = 'guestToolsNeedUpgrade'
foreach ($n in 'test-qa03', 'test-qa04') { $byName[$n].'runtime.powerState' = 'poweredOff'; $byName[$n].'guest.toolsRunningStatus' = 'guestToolsNotRunning'; $byName[$n].'guest.ipAddress' = '' }
$tpl = $vms[0].PSObject.Copy(); $tpl._moref = 'vm-2001'; $tpl.name = 'tpl-rhel9-2026q3'; $tpl.'config.template' = $true; $tpl.'runtime.powerState' = 'poweredOff'
$vms += $tpl
$vms = @($vms | ForEach-Object { $_.PSObject.Properties.Remove('cluster'); $_ })
if ($EdgeCases) {
    # VM huérfana (sin host), nombre con fórmula y textos con caracteres de formato.
    $orphan = $vms[1].PSObject.Copy(); $orphan._moref = 'vm-3001'; $orphan.name = 'vm-huerfana01'; $orphan.PSObject.Properties.Remove('runtime.host')
    $orphan.'runtime.powerState' = 'poweredOff'; $orphan.'guest.toolsRunningStatus' = 'guestToolsNotRunning'
    $evil = $vms[2].PSObject.Copy(); $evil._moref = 'vm-3002'; $evil.name = '=HYPERLINK("http://x","clic")'
    $evil.'summary.config.guestFullName' = "SO | con [enlace](http://x) <script>alert(1)</script>`ny salto"
    $evil.'snapshot.rootSnapshotList' = @(Snap 'snap | raro [x]' 3 "descripción`ncon salto")
    # Marcadores de plantilla dentro de datos de vCenter: deben mostrarse literales, nunca expandirse.
    $marker = $vms[3].PSObject.Copy(); $marker._moref = 'vm-3003'; $marker.name = 'vm-{{ANNEXES}}-x'
    $marker.'summary.config.guestFullName' = 'SO {{SECTIONS}} {{REMEDIATION}}'; $marker.'runtime.consolidationNeeded' = $true
    $tick = $vms[4].PSObject.Copy(); $tick._moref = 'vm-3004'; $tick.name = 'vm-comilla`x'
    $tick.'snapshot.rootSnapshotList' = @(Snap 'snap-tick' 10 '')   # genera un hallazgo con comando que incluye el nombre
    $vms += $orphan, $evil, $marker, $tick
}
$hostsOut = @($hosts | ForEach-Object { $o = $_.PSObject.Copy(); $o.PSObject.Properties.Remove('cluster'); $o })

# --- Datastores, alarmas, vCenter ----------------------------------------------------
function DS($id, $name, $capTB, $usedPct, $uncTB, $type = 'VMFS') { [pscustomobject]@{ _type = 'Datastore'; _moref = $id; name = $name; 'summary.capacity' = [long]($capTB * 1TB); 'summary.freeSpace' = [long]($capTB * 1TB * (1 - $usedPct / 100)); 'summary.uncommitted' = [long]($uncTB * 1TB); 'summary.type' = $type; 'summary.accessible' = $true } }
$datastores = @(
    DS 'datastore-11' 'DS-PROD-01' 20 92.4 2
    DS 'datastore-12' 'DS-PROD-02' 20 83.1 14
    DS 'datastore-13' 'DS-PROD-03' 20 61.7 3
    DS 'datastore-14' 'DS-PROD-DB' 30 74.0 4
    DS 'datastore-15' 'DS-PROD-ISO' 2 38.5 0 'NFS41'
)
$alarms = @(
    [pscustomobject]@{ alarm = 'Datastore usage on disk'; entityType = 'Datastore'; entity = 'datastore-11'; status = 'red'; time = $now.AddHours(-6).ToString('o'); acknowledged = $false }
    [pscustomobject]@{ alarm = 'Host memory usage'; entityType = 'HostSystem'; entity = 'host-60'; status = 'yellow'; time = $now.AddHours(-2).ToString('o'); acknowledged = $true }
)
$vcenter = [pscustomobject]@{
    cert     = [pscustomobject]@{ subject = 'CN=vcenter-demo.demo.local, O=Demo'; issuer = 'CN=CA Interna Demo'; notAfter = $now.AddDays(45).ToUniversalTime().ToString('o'); status = 'good' }
    licenses = @(
        [pscustomobject]@{ name = 'VMware vSphere 8 Enterprise Plus'; edition = 'esx.enterprisePlus.cpuPackageCoreLimited'; total = 14; used = 14; expiration = '' }
        [pscustomobject]@{ name = 'VMware vCenter Server 8 Standard'; edition = 'vc.standard.instance'; total = 1; used = 1; expiration = $now.AddDays(38).ToUniversalTime().ToString('o') }
    )
}
$meta = [ordered]@{ env = 'demo'; generated = $now.ToString('o'); user = 'DEMO\usuario.demo' }
Save $inv 'meta' $meta; Save $inv 'vms' $vms; Save $inv 'hosts' $hostsOut; Save $inv 'compute' $compute; Save $inv 'clusters' $clusterCfg
Save $inv 'datastores' $datastores; Save $inv 'alarms' $alarms; Save $inv 'vcenter' $vcenter

# --- Revisión de hosts (esxcli) ---------------------------------------------------------
$hl = @($hosts | ForEach-Object { [pscustomobject]@{ name = $_.name; cluster = $_.cluster; state = 'connected' } })
function E($h, $rows) { [pscustomobject]@{ host = $h.name; cluster = $h.cluster; ok = $true; error = ''; rows = @($rows) } }
$baseVibs = @(
    @{ Name = 'esx-base'; Version = '8.0.3-0.0.24022510'; Vendor = 'VMware' }
    @{ Name = 'esx-ui'; Version = '2.14.0-22976461'; Vendor = 'VMware' }
    @{ Name = 'qedentv'; Version = '3.40.42.0-1OEM.800.1.0.20613240'; Vendor = 'QLC' }
    @{ Name = 'lsi-mr3'; Version = '7.726.02.00-1OEM.800.1.0.20613240'; Vendor = 'BCM' }
    @{ Name = 'vmware-fdm'; Version = '8.0.3-24022515'; Vendor = 'VMware' }
)
$vibs = @(foreach ($h in $hl) {
        $rows = foreach ($b in $baseVibs) { [pscustomobject]@{ Name = $b.Name; Version = $b.Version; Vendor = $b.Vendor; AcceptanceLevel = 'VMwareCertified' } }
        if ($h.name -eq 'esx07.demo.local') { $rows = @($rows | ForEach-Object { if ($_.Name -eq 'esx-base') { $_.Version = '8.0.2-0.0.22380479' }; if ($_.Name -eq 'qedentv') { $_.Version = '3.40.30.0-1OEM.800.1.0.20613240' }; $_ }) }
        if ($h.name -eq 'esx03.demo.local') { $rows = @($rows | Where-Object Name -ne 'vmware-fdm') }
        E $h $rows })
$nics = @(foreach ($h in $hl) {
        E $h @(
            [pscustomobject]@{ Name = 'vmnic0'; Driver = 'qedentv'; AdminStatus = 'Up'; LinkStatus = 'Up'; Speed = 25000; Duplex = 'Full'; MTU = 9000 }
            [pscustomobject]@{ Name = 'vmnic1'; Driver = 'qedentv'; AdminStatus = 'Up'; LinkStatus = $(if ($h.name -eq 'esx02.demo.local') { 'Down' } else { 'Up' }); Speed = 25000; Duplex = 'Full'; MTU = 9000 }
            [pscustomobject]@{ Name = 'vmnic2'; Driver = 'qedentv'; AdminStatus = 'Up'; LinkStatus = 'Up'; Speed = $(if ($h.name -eq 'esx06.demo.local') { 10000 } else { 25000 }); Duplex = 'Full'; MTU = $(if ($h.name -eq 'esx05.demo.local') { 1500 } else { 9000 }) }
        ) })
$paths = @(foreach ($h in $hl) {
        $rows = foreach ($lun in '0001', '0002', '0003', '0004') {
            foreach ($hba in 'vmhba1', 'vmhba2') {
                $state = if ($h.name -eq 'esx01.demo.local' -and $lun -eq '0002' -and $hba -eq 'vmhba2') { 'dead' } else { 'active' }
                [pscustomobject]@{ Device = "naa.60060e80123400000000$lun"; State = $state; Transport = 'fc'; RuntimeName = "${hba}:C0:T0:L$([int]$lun)" }
            }
        }
        $rows = @($rows) + [pscustomobject]@{ Device = 'naa.6006016000iscsi0099'; State = 'active'; Transport = 'iscsi'; RuntimeName = 'vmhba64:C0:T3:L0' }
        if ($h.cluster -ne 'CL-PROD-02') { $rows = @($rows | Where-Object Transport -ne 'iscsi') }
        $rows = @($rows) + [pscustomobject]@{ Device = 'mpx.vmhba0:C0:T0:L0'; State = 'active'; Transport = 'sas'; RuntimeName = 'vmhba0:C0:T0:L0' }
        E $h $rows })
$ntp = @(foreach ($h in $hl) { E $h @([pscustomobject]@{ Enabled = $(if ($h.name -eq 'esx07.demo.local') { 'false' } else { 'true' }); Server = $(if ($h.cluster -eq 'CL-PROD-02') { @('10.20.0.5') } else { @('10.20.0.5', '10.20.0.6') }) }) })
$syslog = @(foreach ($h in $hl) { E $h @([pscustomobject]@{ RemoteHost = $(if ($h.name -in 'esx05.demo.local', 'esx06.demo.local') { '<none>' } else { 'tcp://siem.demo.local:514' }) }) })
$coredump = @(foreach ($h in $hl) { E $h @([pscustomobject]@{ Enabled = $(if ($h.cluster -eq 'CL-PROD-02') { 'false' } else { 'true' }); NetworkServerIP = '10.20.0.40' }) })
$platform = @(foreach ($h in $hl) { E $h @([pscustomobject]@{ VendorName = 'Dell Inc.'; ProductName = $(if ($h.name -eq 'esx07.demo.local') { 'PowerEdge R650' } else { 'PowerEdge R750' }) }) })
$services = @(foreach ($h in $hl) { E $h @(
            [pscustomobject]@{ key = 'TSM-SSH'; running = ($h.name -eq 'esx02.demo.local'); policy = 'off' }
            [pscustomobject]@{ key = 'TSM'; running = ($h.name -eq 'esx06.demo.local'); policy = 'off' }) })
$certs = @(foreach ($h in $hl) {
        $days = switch ($h.name) { 'esx04.demo.local' { 21 } 'esx07.demo.local' { -5 } default { 300 + $rnd.Next(0, 200) } }
        E $h @([pscustomobject]@{ subject = "CN=$($h.name)"; issuer = 'CN=CA Interna Demo'; notAfter = $now.AddDays($days).ToUniversalTime().ToString('o'); status = 'good' }) })
if ($EdgeCases) {
    # Chequeo sin datos en dos hosts (cobertura): debe agruparse en un solo hallazgo.
    foreach ($e in $coredump) { if ($e.host -in 'esx01.demo.local', 'esx02.demo.local') { $e.ok = $false; $e.error = 'NoPermission: Permission to perform this operation was denied.'; $e.rows = @() } }
}
Save $hst 'esxcli-hosts' $hl
foreach ($k in 'vibs', 'nics', 'paths', 'ntp', 'syslog', 'coredump', 'platform', 'services', 'certs') { Save $hst "esxcli-$k" (Get-Variable $k -ValueOnly) }
Save $hst 'meta-hosts' ([ordered]@{ env = 'demo'; generated = $now.ToString('o'); user = 'DEMO\usuario.demo'; checks = @('vibs', 'nics', 'paths', 'ntp', 'syslog', 'coredump', 'platform', 'services', 'certs') })

# --- Controles de acceso y metadatos de auditoría ---------------------------------------
$perm = @(
    [pscustomobject]@{ principal = 'DEMO\GG-vSphere-Admins'; group = $true; roleId = -1; propagate = $true }
    [pscustomobject]@{ principal = 'VSPHERE.LOCAL\Administrator'; group = $false; roleId = -1; propagate = $true }
    [pscustomobject]@{ principal = 'DEMO\usuario.infra1'; group = $false; roleId = -1; propagate = $true }
    [pscustomobject]@{ principal = 'DEMO\usuario.infra2'; group = $false; roleId = -1; propagate = $true }
    [pscustomobject]@{ principal = 'DEMO\svc-backup'; group = $false; roleId = -1; propagate = $true }
    [pscustomobject]@{ principal = 'DEMO\svc-monitoreo'; group = $false; roleId = -1; propagate = $true }
    [pscustomobject]@{ principal = 'DEMO\GG-vSphere-Lectura'; group = $true; roleId = -2; propagate = $true }
)
$roleList = @([pscustomobject]@{ roleId = -1; name = 'Admin' }, [pscustomobject]@{ roleId = -2; name = 'ReadOnly' }, [pscustomobject]@{ roleId = -5; name = 'NoAccess' })
Save $aud 'vcenter-access' ([ordered]@{ permissions = $perm; roles = $roleList; ok = $true })
Save $aud 'meta-audit' ([ordered]@{ env = 'demo'; generated = $now.ToString('o'); scope = 'full'; cluster = @(); user = 'DEMO\usuario.demo'; version = '1.0' })
"Datos de demostración generados en $AuditDir"
