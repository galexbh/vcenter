<#
.SYNOPSIS
  Genera reportes HTML/Markdown/CSV de vCenter con hallazgos y sugerencias. Solo lectura.

.DESCRIPTION
  Recolecta inventario en bloque (una llamada object.collect por tipo de objeto) mediante
  scripts/govc.ps1, guarda el JSON normalizado en reports/<env>/<marca>/raw/ y renderiza las
  plantillas de templates/. Con -FromRaw re-renderiza sin volver a consultar vCenter.
  Escribe además raw/findings.json, raw/summary.json y raw/metrics.json (paneles), que usan Invoke-Audit.ps1 y
  Compare-Report.ps1. Los reportes quedan en reports/ (ignorado por git) y contienen
  información interna.

.EXAMPLE
  ./scripts/New-Report.ps1 -Env prod
  ./scripts/New-Report.ps1 -Env prod -Type snapshots -Format md -SnapshotWarnDays 3
  ./scripts/New-Report.ps1 -FromRaw reports/prod/20261016-0900 -Type health
  ./scripts/New-Report.ps1 -Env prod -Type inventory -Format csv          # un CSV por tabla, para Excel
#>
#Requires -Version 7.5
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$Env,
    [ValidateSet('all', 'inventory', 'snapshots', 'capacity', 'health')][string]$Type = 'all',
    [ValidateSet('html', 'md', 'csv')][string[]]$Format = @('html', 'md'),
    # Separador CSV. Por defecto, el separador de listas de Windows (el que usa Excel al abrir el archivo).
    [string]$CsvDelimiter,
    [string]$FromRaw,
    [string]$OutDir,
    [int]$SnapshotWarnDays = 7,
    [int]$SnapshotCritDays = 30,
    [int]$DatastoreWarnPct = 80,
    [int]$DatastoreCritPct = 90,
    [double]$VcpuRatioWarn = 4,
    [double]$VcpuRatioCrit = 6,
    [double]$MemRatioWarn = 1.0,
    [int]$HostMemWarnPct = 85,
    # Holgura N+1: % de la capacidad que queda tras perder el host mayor a partir del cual se advierte.
    [int]$N1WarnPct = 90,
    [int]$MinHwVersion = 14,
    [int]$CertWarnDays = 60,
    [int]$LicenseWarnDays = 60,
    # Omite config.hardware.device (solo se usa para detectar ISO conectada). Recomendado con miles de VMs:
    # con 5000 VMs ese dato multiplica por 10 el volumen recolectado (~65 MB) y suma ~1 GB de memoria.
    [switch]$SkipDeviceScan,
    [int]$MdMaxRows = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/GovcJson.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Render.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
# Lectura tolerante de propiedades (las rutas de vSphere contienen puntos).
Set-Alias -Name P -Value Get-Prop -Scope Script

# --- Recolección --------------------------------------------------------------
$queries = [ordered]@{
    vms        = @('m', 'name', 'runtime.powerState', 'runtime.host', 'summary.config.numCpu', 'summary.config.memorySizeMB',
                   'summary.config.guestFullName', 'summary.storage.committed', 'summary.storage.uncommitted',
                   'guest.toolsRunningStatus', 'guest.toolsVersionStatus2', 'guest.ipAddress', 'config.template',
                   'snapshot.rootSnapshotList', 'runtime.consolidationNeeded', 'config.version',
                   'config.cpuAllocation.limit', 'config.memoryAllocation.limit', 'config.hardware.device',
                   'summary.quickStats.balloonedMemory', 'summary.quickStats.swappedMemory', 'summary.quickStats.compressedMemory', 'datastore')
    hosts      = @('h', 'name', 'parent', 'summary.hardware.numCpuCores', 'summary.hardware.cpuMhz', 'summary.hardware.memorySize',
                   'summary.quickStats.overallCpuUsage', 'summary.quickStats.overallMemoryUsage', 'runtime.connectionState',
                   'runtime.inMaintenanceMode', 'summary.config.product.fullName')
    compute    = @('r', 'name', 'summary.numCpuCores', 'summary.totalMemory', 'summary.numHosts', 'summary.numEffectiveHosts')
    clusters   = @('c', 'name', 'configurationEx')
    # summary.url (ds:///vmfs/volumes/<uuid>/) permite traducir la instancia de las métricas de latencia al nombre.
    datastores = @('s', 'name', 'summary.capacity', 'summary.freeSpace', 'summary.uncommitted', 'summary.type', 'summary.accessible', 'summary.url')
    pools      = @('p', 'name', 'parent', 'config.cpuAllocation', 'config.memoryAllocation')
}

function Get-IsoDevices($devices) {
    # Reduce config.hardware.device a las unidades de CD/DVD con ISO de datastore (el resto no se guarda).
    @($devices | Where-Object {
            $b = P $_ 'backing'
            $b -and "$(P $b 'fileName' '')" -match '\.iso$'
        } | ForEach-Object {
            $c = P $_ 'connectable'
            [pscustomobject]@{ label = P (P $_ 'deviceInfo') 'label' 'CD/DVD'; fileName = $_.backing.fileName; connected = [bool](P $c 'connected' $false) }
        })
}

$ctx = Initialize-RunContext -Env $Env -FromRaw $FromRaw -OutDir $OutDir -Root $root -MetaFile 'meta.json'
$Env = $ctx.env; $outDir = $ctx.outDir; $rawDir = $ctx.rawDir; $generated = $ctx.generated; $meta = $ctx.meta
if ($ctx.fromRaw -and -not $PSBoundParameters.ContainsKey('Type') -and (P $meta 'type')) { $Type = "$($meta.type)" }
if ($ctx.fromRaw) {
    $data = @{}
    foreach ($k in @($queries.Keys) + 'alarms') { $data[$k] = Read-JsonFile (Join-Path $rawDir "$k.json") @() -AsArray }
    $vcenter = Read-JsonFile (Join-Path $rawDir 'vcenter.json') $null
} else {
    # Una sola sesión para toda la recolección (modo -Batch del wrapper: solo lecturas).
    Import-Module (Join-Path $PSScriptRoot 'lib/GovcBatch.psm1') -Force
    if ($SkipDeviceScan) { $queries.vms = @($queries.vms | Where-Object { $_ -ne 'config.hardware.device' }) }
    $keys = @($queries.Keys)
    $cmds = @(foreach ($k in $keys) { $q = $queries[$k]; , (@('object.collect', '-json', '-type', $q[0], '/') + @($q | Select-Object -Skip 1)) })
    $cmds += , @('object.collect', '-json', '/', 'triggeredAlarmState')
    $cmds += , @('about.cert', '-json')
    $cmds += , @('license.ls', '-json')
    [Console]::Error.WriteLine("Recolectando inventario ($($cmds.Count) consultas, una sesión)...")
    $res = Invoke-GovcBatch -Env $Env -Commands $cmds

    $data = @{}
    for ($i = 0; $i -lt $keys.Count; $i++) {
        if ($res[$i].exitCode -ne 0) { throw "Falló object.collect para $($keys[$i]): $(Get-GovcBatchError $res[$i])" }
        $data[$keys[$i]] = @($res[$i].stdout | ConvertFrom-GovcCollect)
    }
    foreach ($v in $data.vms) {
        $v | Add-Member -Force 'config.hardware.device' (Get-IsoDevices (P $v 'config.hardware.device' @()))
    }

    # Alarmas disparadas (agregadas en la carpeta raíz) + nombres de alarma (segundo lote).
    $ra = $res[$keys.Count]
    $alarmRaw = if ($ra.exitCode -eq 0) { $ra.stdout | ConvertFrom-GovcCollect } else { $null }
    $states = @(P $alarmRaw 'triggeredAlarmState' @())
    $names = @{}
    $alarmIds = @($states | ForEach-Object { $_.alarm.value } | Sort-Object -Unique)
    if ($alarmIds.Count) {
        $an = Invoke-GovcBatch -Env $Env -Commands @(foreach ($am in $alarmIds) { , @('object.collect', '-json', "Alarm:$am", 'info.name') })
        for ($i = 0; $i -lt $alarmIds.Count; $i++) {
            $n = if ($an[$i].exitCode -eq 0) { $an[$i].stdout | ConvertFrom-GovcCollect } else { $null }
            $names[$alarmIds[$i]] = P $n 'info.name' $alarmIds[$i]
        }
    }
    $data['alarms'] = @($states | ForEach-Object {
            [pscustomobject]@{
                alarm = $names[$_.alarm.value]; entityType = $_.entity.type; entity = $_.entity.value
                status = $_.overallStatus; time = $_.time; acknowledged = (P $_ 'acknowledged' $false)
            } })

    # Certificado de vCenter y licencias (sin claves de licencia).
    $rc = $res[$keys.Count + 1]; $rl = $res[$keys.Count + 2]
    $cert = if ($rc.exitCode -eq 0 -and $rc.stdout) { ConvertFrom-CertJson $rc.stdout } else { $null }
    $lics = @()
    if ($rl.exitCode -eq 0 -and $rl.stdout) {
        $lics = @($rl.stdout | ConvertFrom-Json -DateKind String | ForEach-Object { $_ } | ForEach-Object {
                $exp = @(P $_ 'properties' @()) | Where-Object { (P $_ 'key') -eq 'expirationDate' } | Select-Object -First 1
                [pscustomobject]@{ name = P $_ 'name' ''; edition = P $_ 'editionKey' ''; total = P $_ 'total' 0; used = P $_ 'used' 0; expiration = $(if ($exp) { "$($exp.value)" } else { '' }) } })
    }
    $vcenter = [pscustomobject]@{
        cert     = $cert
        licenses = $lics
    }
    Save-RawJson $vcenter (Join-Path $rawDir 'vcenter.json')
    foreach ($k in $data.Keys) { Save-RawJson @($data[$k]) (Join-Path $rawDir "$k.json") }
    Write-RunMeta (Join-Path $rawDir 'meta.json') $Env $generated @{ deviceScan = (-not $SkipDeviceScan); type = $Type }
}

# --- Modelo -------------------------------------------------------------------
$GB = 1GB
$now = $generated
$hostById = @{}; foreach ($h in $data.hosts) { $hostById[$h._moref] = $h }
$nameById = @{}
foreach ($set in 'vms', 'hosts', 'compute', 'datastores') { foreach ($o in $data[$set]) { $nameById[$o._moref] = $o.name } }

function Get-ClusterOfHost($hostId) {
    if (-not $hostId) { return $null }
    $h = $hostById[$hostId]; if (-not $h) { return $null }
    $par = P $h 'parent'; if ($par) { return $par.value } else { return $null }
}

$vms = foreach ($v in $data.vms) {
    # Una VM huérfana o inaccesible puede no tener host.
    $rh = P $v 'runtime.host'; $hostId = if ($rh) { P $rh 'value' } else { $null }
    $snaps = Get-SnapshotList (P $v 'snapshot.rootSnapshotList' @()) $now
    $hw = "$(P $v 'config.version' '')"
    [pscustomobject]@{
        id        = $v._moref
        name      = $v.name
        power     = P $v 'runtime.powerState' 'unknown'
        template  = [bool](P $v 'config.template' $false)
        host      = if ($hostId) { $nameById[$hostId] } else { '' }
        clusterId = Get-ClusterOfHost $hostId
        vcpu      = [int](P $v 'summary.config.numCpu' 0)
        memMB     = [int](P $v 'summary.config.memorySizeMB' 0)
        os        = P $v 'summary.config.guestFullName' ''
        ip        = P $v 'guest.ipAddress' ''
        usedGB    = [math]::Round([double](P $v 'summary.storage.committed' 0) / $GB, 1)
        tools     = P $v 'guest.toolsRunningStatus' ''
        toolsVer  = P $v 'guest.toolsVersionStatus2' ''
        snapshots = $snaps
        consolidate = [bool](P $v 'runtime.consolidationNeeded' $false)
        hwVersion = $hw
        hwNum     = $(if ($hw -match '(\d+)$') { [int]$Matches[1] } else { 0 })
        cpuLimit  = [long](P $v 'config.cpuAllocation.limit' -1)
        memLimit  = [long](P $v 'config.memoryAllocation.limit' -1)
        isos      = @(P $v 'config.hardware.device' @() | Where-Object { $_.connected })
        # quickStats: balloon y swap en MB, compresión en KB (valor instantáneo al recolectar).
        balloonMB = [long](P $v 'summary.quickStats.balloonedMemory' 0)
        swapMB    = [long](P $v 'summary.quickStats.swappedMemory' 0)
        compMB    = [math]::Round([double](P $v 'summary.quickStats.compressedMemory' 0) / 1024, 1)
        dsIds     = @(P $v 'datastore' @() | ForEach-Object { "$(P $_ 'value' '')" })
    }
}
$vms = @($vms | Sort-Object name)
$realVms = @($vms | Where-Object { -not $_.template })

$clusterCfg = @{}
foreach ($c in $data.clusters) {
    $cfg = P $c 'configurationEx'
    $das = P $cfg 'dasConfig'; $drs = P $cfg 'drsConfig'
    $clusterCfg[$c._moref] = [pscustomobject]@{
        ha = [bool](P $das 'enabled' $false); drs = [bool](P $drs 'enabled' $false); behavior = "$(P $drs 'defaultVmBehavior' '')"
        # $null si el dato no viene (no se infiere que esté desactivado).
        admission = P $das 'admissionControlEnabled'
    }
}

# Capacidad y uso por host (MHz / MB), base de la holgura N+1.
$hostCap = @{}
foreach ($h in $data.hosts) {
    $cores = [double](P $h 'summary.hardware.numCpuCores' 0); $mhz = [double](P $h 'summary.hardware.cpuMhz' 0)
    $hostCap[$h._moref] = [pscustomobject]@{
        clusterId = $(if ((P $h 'parent')) { $h.parent.value } else { $null })
        active    = ((P $h 'runtime.connectionState' '') -eq 'connected' -and -not [bool](P $h 'runtime.inMaintenanceMode' $false))
        cpuCap    = $cores * $mhz
        cpuUsed   = [double](P $h 'summary.quickStats.overallCpuUsage' 0)
        memCap    = [double](P $h 'summary.hardware.memorySize' 0) / 1MB
        memUsed   = [double](P $h 'summary.quickStats.overallMemoryUsage' 0)
    }
}
# Índices por clúster en una sola pasada (antes se recorrían todos los hosts y VMs por cada clúster).
$hostsByCl = @{}; $capByCl = @{}; $onByCl = @{}
foreach ($h in $data.hosts) { $par = P $h 'parent'; if ($par) { $k = $par.value; if (-not $hostsByCl[$k]) { $hostsByCl[$k] = New-Object System.Collections.Generic.List[object] }; $hostsByCl[$k].Add($h) } }
foreach ($hc in $hostCap.Values) { if ($hc.clusterId -and $hc.active) { if (-not $capByCl[$hc.clusterId]) { $capByCl[$hc.clusterId] = New-Object System.Collections.Generic.List[object] }; $capByCl[$hc.clusterId].Add($hc) } }
foreach ($v in $realVms) { if ($v.clusterId -and $v.power -eq 'poweredOn') { if (-not $onByCl[$v.clusterId]) { $onByCl[$v.clusterId] = New-Object System.Collections.Generic.List[object] }; $onByCl[$v.clusterId].Add($v) } }
function Get-N1($clusterId, [string]$res) {
    # Uso actual frente a la capacidad que queda al perder el host de mayor capacidad del clúster.
    $act = if ($capByCl[$clusterId]) { $capByCl[$clusterId].ToArray() } else { @() }
    if ($act.Count -lt 2) { return [pscustomobject]@{ hosts = $act.Count; pct = $null; used = 0; left = 0 } }
    $cap = (Get-Sum $act "${res}Cap"); $max = ($act | Measure-Object "${res}Cap" -Maximum).Maximum
    $used = (Get-Sum $act "${res}Used"); $left = $cap - $max
    [pscustomobject]@{ hosts = $act.Count; pct = $(if ($left -gt 0) { Get-Percent $used $left } else { $null }); used = $used; left = $left }
}

$clusters = foreach ($c in $data.compute) {
    $members = if ($hostsByCl[$c._moref]) { $hostsByCl[$c._moref].ToArray() } else { @() }
    $on = if ($onByCl[$c._moref]) { $onByCl[$c._moref].ToArray() } else { @() }
    $cores = [int](P $c 'summary.numCpuCores' 0)
    $memGB = [math]::Round([double](P $c 'summary.totalMemory' 0) / $GB, 1)
    $vcpu = (Get-Sum $on 'vcpu')
    $vmem = [math]::Round(((Get-Sum $on 'memMB')) / 1024, 1)
    $cc = $clusterCfg[$c._moref]
    $n1m = Get-N1 $c._moref 'mem'; $n1c = Get-N1 $c._moref 'cpu'
    [pscustomobject]@{
        id        = $c._moref
        name      = $c.name
        isCluster = [bool]$cc
        admission = $(if ($cc) { $cc.admission } else { $null })
        activeHosts = $n1m.hosts
        n1Mem     = $n1m
        n1Cpu     = $n1c
        n1MemPct  = $n1m.pct
        n1CpuPct  = $n1c.pct
        ha        = $(if ($cc) { if ($cc.ha) { 'Sí' } else { 'No' } } else { '—' })
        drs       = $(if ($cc) { if ($cc.drs) { if ($cc.behavior) { $cc.behavior } else { 'Sí' } } else { 'No' } } else { '—' })
        hosts     = $members.Count
        cores     = $cores
        memGB     = $memGB
        vmsOn     = $on.Count
        vcpu      = [int]$vcpu
        vcpuRatio = if ($cores) { [math]::Round($vcpu / $cores, 2) } else { 0 }
        vmemGB    = $vmem
        memRatio  = if ($memGB) { [math]::Round($vmem / $memGB, 2) } else { 0 }
        avgVmMB   = if ($on.Count) { [double]($on | Measure-Object memMB -Average).Average } else { 0 }
    }
}
$clusters = @($clusters | Sort-Object name)

$hosts = @($data.hosts | ForEach-Object {
        $cores = [int](P $_ 'summary.hardware.numCpuCores' 0); $mhz = [int](P $_ 'summary.hardware.cpuMhz' 0)
        $memMB = [double](P $_ 'summary.hardware.memorySize' 0) / 1MB
        [pscustomobject]@{
            id      = $_._moref
            name    = $_.name
            cluster = $(if ((P $_ 'parent')) { $nameById[$_.parent.value] } else { '' })
            state   = P $_ 'runtime.connectionState' ''
            maint   = [bool](P $_ 'runtime.inMaintenanceMode' $false)
            version = P $_ 'summary.config.product.fullName' ''
            cores   = $cores
            memGB   = [math]::Round($memMB / 1024, 1)
            cpuPct  = (Get-Percent (P $_ 'summary.quickStats.overallCpuUsage' 0) ($cores * $mhz)) ?? 0
            memPct  = (Get-Percent (P $_ 'summary.quickStats.overallMemoryUsage' 0) $memMB) ?? 0
        } } | Sort-Object name)

$datastores = @($data.datastores | ForEach-Object {
        $cap = [double](P $_ 'summary.capacity' 0); $free = [double](P $_ 'summary.freeSpace' 0); $unc = [double](P $_ 'summary.uncommitted' 0)
        [pscustomobject]@{
            id         = $_._moref
            name       = $_.name
            type       = P $_ 'summary.type' ''
            accessible = [bool](P $_ 'summary.accessible' $true)
            capGB      = [math]::Round($cap / $GB, 1)
            freeGB     = [math]::Round($free / $GB, 1)
            usedPct    = (Get-Percent ($cap - $free) $cap) ?? 0
            provPct    = (Get-Percent ($cap - $free + $unc) $cap) ?? 0
        } } | Sort-Object usedPct -Descending)

# Resource pools con límite (se excluye el pool raíz «Resources» de cada clúster o host).
$pools = @($data.pools | Where-Object { $_.name -ne 'Resources' } | ForEach-Object {
        $ca = P $_ 'config.cpuAllocation'; $ma = P $_ 'config.memoryAllocation'
        [pscustomobject]@{
            id         = $_._moref
            name       = $_.name
            parent     = $(if ((P $_ 'parent')) { $nameById[$_.parent.value] } else { '' })
            cpuLimit   = [long](P $ca 'limit' -1)
            cpuReserve = [long](P $ca 'reservation' 0)
            memLimit   = [long](P $ma 'limit' -1)
            memReserve = [long](P $ma 'reservation' 0)
        } } | Sort-Object name)

$snapRows = @($realVms | ForEach-Object { $vm = $_; $_.snapshots | ForEach-Object {
            [pscustomobject]@{ vm = $vm.name; vmId = $vm.id; name = $_.name; created = $(if ($_.created) { $_.created.LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '' }); ageDays = $_.ageDays; depth = $_.depth; description = $_.description } } } |
    Sort-Object ageDays -Descending)

# --- Hallazgos ------------------------------------------------------------------
$findings = New-FindingList
# La sugerencia sale del catálogo (templates/findings.psd1) por regla y severidad.
function Add-Finding($sev, $cat, $obj, $evidence, $command = '', $rule = '') {
    Add-ReportFinding -List $findings -Severity $sev -Category $cat -Object $obj -Evidence $evidence -Suggestion (Get-FindingText $rule $sev) -Command $command -Rule $rule
}
function Add-GroupFinding($sev, $cat, $hit, $label, $command, $rule) {
    Add-GroupedFinding -List $findings -Severity $sev -Category $cat -Items $hit -Label $label -Suggestion (Get-FindingText $rule $sev) -Command $command -Rule $rule
}
# Comandos de revisión: referencias Tipo:id (inequívocas, sin caracteres que escapar) y argumentos
# escapados por New-ReviewCommand; los nombres vienen de vCenter y nunca se interpolan sin escapar.
$rc = { param([string[]]$a) New-ReviewCommand -Env $Env -Arguments $a }

foreach ($d in $datastores) {
    if (-not $d.accessible) { Add-Finding 'Crítico' 'Almacenamiento' $d.name 'Datastore no accesible' (& $rc 'datastore.info', "Datastore:$($d.id)") 'ds-inaccessible' }
    elseif ($d.usedPct -ge $DatastoreCritPct) { Add-Finding 'Crítico' 'Almacenamiento' $d.name "Uso $($d.usedPct)% (libre $($d.freeGB) GB)" (& $rc 'datastore.info', "Datastore:$($d.id)") 'ds-used' }
    elseif ($d.usedPct -ge $DatastoreWarnPct) { Add-Finding 'Advertencia' 'Almacenamiento' $d.name "Uso $($d.usedPct)% (libre $($d.freeGB) GB)" (& $rc 'datastore.info', "Datastore:$($d.id)") 'ds-used' }
    if ($d.accessible -and $d.provPct -gt 150) { Add-Finding 'Advertencia' 'Almacenamiento' $d.name "Aprovisionado $($d.provPct)% de la capacidad (thin)" '' 'ds-thin' }
}
foreach ($s in $snapRows) {
    $cmd = & $rc 'snapshot.tree', '-vm', "VirtualMachine:$($s.vmId)", '-D', '-i'
    if ($s.ageDays -ge $SnapshotCritDays) { Add-Finding 'Crítico' 'Snapshots' "$($s.vm) / $($s.name)" "Snapshot '$($s.name)' con $($s.ageDays) días" $cmd 'snap-age' }
    elseif ($s.ageDays -ge $SnapshotWarnDays) { Add-Finding 'Advertencia' 'Snapshots' "$($s.vm) / $($s.name)" "Snapshot '$($s.name)' con $($s.ageDays) días" $cmd 'snap-age' }
}
foreach ($h in $hosts) {
    if ($h.state -ne 'connected') { Add-Finding 'Crítico' 'Hosts' $h.name "Estado: $($h.state)" (& $rc 'host.info', '-host', "HostSystem:$($h.id)") 'host-state' }
    elseif ($h.maint) { Add-Finding 'Info' 'Hosts' $h.name 'En modo mantenimiento' '' 'host-maint' }
    if ($h.memPct -ge $HostMemWarnPct) { Add-Finding 'Advertencia' 'Capacidad' $h.name "Memoria en uso $($h.memPct)%" '' 'host-mem' }
}
foreach ($c in $clusters | Where-Object { $_.cores -gt 0 }) {
    $perf = "./scripts/Invoke-PerfCheck.ps1 -Env $Env -Cluster $(Format-PsLiteral $c.name)"
    if ($c.vcpuRatio -ge $VcpuRatioCrit) { Add-Finding 'Crítico' 'Capacidad' $c.name "vCPU:pCore $($c.vcpuRatio):1" $perf 'cl-vcpu' }
    elseif ($c.vcpuRatio -ge $VcpuRatioWarn) { Add-Finding 'Advertencia' 'Capacidad' $c.name "vCPU:pCore $($c.vcpuRatio):1" $perf 'cl-vcpu' }
    if ($c.memRatio -gt $MemRatioWarn) { Add-Finding 'Advertencia' 'Capacidad' $c.name "RAM asignada/física $($c.memRatio)" '' 'cl-mem' }
}
foreach ($c in $clusters | Where-Object { $_.isCluster }) {
    # Holgura N+1 con el uso actual (quickStats): ¿la carga cabe si cae el host de mayor capacidad?
    if ($c.activeHosts -eq 1) {
        Add-Finding 'Info' 'Capacidad' $c.name 'Un solo host activo: sin tolerancia a la falla de un host' '' 'cl-n1-single'
    } elseif ($c.activeHosts -ge 2) {
        foreach ($r in @(@{ k = 'mem'; n = $c.n1Mem; label = 'Memoria'; fmt = { param($x) "$([math]::Round($x / 1024)) GB" } }, @{ k = 'cpu'; n = $c.n1Cpu; label = 'CPU'; fmt = { param($x) "$([math]::Round($x / 1000)) GHz" } })) {
            $n = $r.n; if ($null -eq $n.pct) { continue }
            $ev = "$($r.label) en uso $(& $r.fmt $n.used); sin el host mayor quedan $(& $r.fmt $n.left) ($($n.pct)% de uso) con $($n.hosts) hosts activos"
            if ($r.k -eq 'mem' -and $n.pct -gt 100 -and $c.avgVmMB -gt 0) { $ev += "; ~$([math]::Ceiling(($n.used - $n.left) / $c.avgVmMB)) VMs sin capacidad para reiniciarse" }
            if ($n.pct -gt 100) { Add-Finding 'Crítico' 'Capacidad' $c.name $ev '' "cl-n1-$($r.k)" }
            elseif ($n.pct -ge $N1WarnPct) { Add-Finding 'Advertencia' 'Capacidad' $c.name $ev '' "cl-n1-$($r.k)" }
        }
    }
    if ($c.ha -eq 'Sí' -and $c.admission -eq $false) { Add-Finding 'Advertencia' 'Clúster' $c.name 'HA activo con el control de admisión desactivado' (& $rc 'object.collect', '-s', "ClusterComputeResource:$($c.id)", 'configurationEx.dasConfig.admissionControlEnabled') 'cl-ha-admission' }
    if ($c.ha -eq 'No') { Add-Finding 'Crítico' 'Clúster' $c.name 'vSphere HA deshabilitado' (& $rc 'object.collect', '-s', "ClusterComputeResource:$($c.id)", 'configurationEx.dasConfig.enabled') 'cl-ha' }
    if ($c.drs -eq 'No') { Add-Finding 'Advertencia' 'Clúster' $c.name 'DRS deshabilitado' '' 'cl-drs' }
    elseif ($c.drs -eq 'manual') { Add-Finding 'Advertencia' 'Clúster' $c.name 'DRS en modo manual' '' 'cl-drs' }
}

$off = @($realVms | Where-Object power -eq 'poweredOff')
if ($off.Count) { Add-Finding 'Info' 'Higiene' "$($off.Count) VMs" "VMs apagadas: $((($off | Select-Object -First 10).name) -join ', ')$(if ($off.Count -gt 10) { '…' })" (& $rc 'find', '/', '-type', 'm', '-runtime.powerState', 'poweredOff') 'vm-off' }

$onVms = @($realVms | Where-Object power -eq 'poweredOn')
Add-GroupFinding 'Advertencia' 'VMware Tools' @($onVms | Where-Object { $_.toolsVer -eq 'guestToolsNotInstalled' }) 'VMware Tools no instalado' '' 'tools-missing'
Add-GroupFinding 'Advertencia' 'VMware Tools' @($onVms | Where-Object { $_.toolsVer -ne 'guestToolsNotInstalled' -and $_.tools -and $_.tools -ne 'guestToolsRunning' }) 'VMware Tools no está corriendo' '' 'tools-notrunning'
Add-GroupFinding 'Info' 'VMware Tools' @($onVms | Where-Object { $_.toolsVer -in 'guestToolsNeedUpgrade', 'guestToolsTooOld' }) 'VMware Tools desactualizado' '' 'tools-old'

# Configuración de VMs (sin llamadas extra: todo viene del mismo object.collect).
Add-GroupFinding 'Advertencia' 'Configuración VM' @($realVms | Where-Object consolidate) 'Consolidación de discos pendiente' '' 'vm-consolidate'
Add-GroupFinding 'Advertencia' 'Configuración VM' @($realVms | Where-Object { $_.cpuLimit -ge 0 -or $_.memLimit -ge 0 }) 'Límite de CPU o memoria configurado' '' 'vm-limits'

# Presión de memoria por VM (quickStats, instantáneo). Invoke-PerfCheck.ps1 lo mide en una ventana de tiempo.
Add-GroupFinding 'Advertencia' 'Capacidad' @($onVms | Where-Object { $_.balloonMB -gt 0 }) 'Memoria recuperada por balloon' '' 'vm-balloon'
Add-GroupFinding 'Advertencia' 'Capacidad' @($onVms | Where-Object { $_.swapMB -gt 0 }) 'Memoria en swap del hipervisor' '' 'vm-swap'
Add-GroupFinding 'Info' 'Capacidad' @($onVms | Where-Object { $_.compMB -gt 0 }) 'Memoria comprimida por el host' '' 'vm-compressed'
foreach ($p in $pools | Where-Object { $_.cpuLimit -ge 0 -or $_.memLimit -ge 0 }) {
    $lim = @($(if ($p.cpuLimit -ge 0) { "CPU $($p.cpuLimit) MHz" }), $(if ($p.memLimit -ge 0) { "memoria $($p.memLimit) MB" }) | Where-Object { $_ }) -join ', '
    Add-Finding 'Advertencia' 'Capacidad' $p.name "Resource pool con límite: $lim" (& $rc 'pool.info', "ResourcePool:$($p.id)") 'rp-limit'
}

$deviceScanned = if ($FromRaw) { [bool](P $meta 'deviceScan' $true) } else { -not $SkipDeviceScan }
if ($deviceScanned) {
    Add-GroupFinding 'Info' 'Configuración VM' @($realVms | Where-Object { $_.isos.Count }) 'CD/DVD conectado a ISO de datastore' '' 'vm-iso'
} else {
    # Se declara como limitación: la auditoría la muestra en «Cobertura» y no la puntúa.
    Add-Finding 'Info' 'Cobertura' 'Detección de ISO conectada' 'Omitida en esta corrida (-SkipDeviceScan)' '' 'coverage-devices'
}
Add-GroupFinding 'Info' 'Configuración VM' @($realVms | Where-Object { $_.hwNum -gt 0 -and $_.hwNum -lt $MinHwVersion }) "Hardware virtual anterior a vmx-$MinHwVersion" '' 'vm-hwversion'

foreach ($a in $data.alarms) {
    $sev = switch ($a.status) { 'red' { 'Crítico' } 'yellow' { 'Advertencia' } default { 'Info' } }
    $obj = if ($nameById[$a.entity]) { $nameById[$a.entity] } else { "$($a.entityType):$($a.entity)" }
    Add-Finding $sev 'Alarmas' "$obj / $($a.alarm)" "$($a.alarm) ($($a.status))$(if ($a.acknowledged) { ', reconocida' })" (& $rc 'events', '-n', '20', "$($a.entityType):$($a.entity)") 'alarm'
}

# Certificado de vCenter y licencias.
$certRow = $null; $licRows = @()
if ($vcenter) {
    if ($vcenter.cert -and $vcenter.cert.notAfter) {
        $na = ([datetimeoffset]::Parse("$($vcenter.cert.notAfter)", [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
        $left = [math]::Floor(($na - $now).TotalDays)
        $certRow = [pscustomobject]@{ item = 'Certificado de vCenter'; detail = $vcenter.cert.subject; expires = $na.ToString('yyyy-MM-dd'); days = $left }
        if ($left -lt 0) { Add-Finding 'Crítico' 'Certificados' 'vCenter' "Certificado vencido el $($na.ToString('yyyy-MM-dd'))" (& $rc 'about.cert') 'cert-vc' }
        elseif ($left -le $CertWarnDays) { Add-Finding 'Advertencia' 'Certificados' 'vCenter' "Certificado vence en $left días ($($na.ToString('yyyy-MM-dd')))" (& $rc 'about.cert') 'cert-vc' }
    }
    foreach ($l in @($vcenter.licenses)) {
        $exp = $null; if ($l.expiration) { try { $exp = ([datetimeoffset]::Parse("$($l.expiration)", [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { } }
        $left = if ($exp) { [math]::Floor(($exp - $now).TotalDays) } else { $null }
        $licRows += [pscustomobject]@{ item = $l.name; detail = "$($l.edition) · uso $($l.used)/$($l.total)"; expires = $(if ($exp) { $exp.ToString('yyyy-MM-dd') } else { 'sin vencimiento' }); days = $left }
        if ($null -ne $left -and $left -le $LicenseWarnDays) {
            $sev = if ($left -lt 0) { 'Crítico' } else { 'Advertencia' }
            Add-Finding $sev 'Licencias' $l.name "$(if ($left -lt 0) { 'Vencida' } else { "Vence en $left días" }) ($($exp.ToString('yyyy-MM-dd')))" (& $rc 'license.ls') 'license'
        }
    }
}

# VMs encendidas expuestas por entidad (VM, datastore, host, clúster), para el impacto de cada hallazgo.
$exposed = @{}
foreach ($v in $realVms) { $exposed[$v.name] = 1 }
if (@($onVms | Where-Object { $_.dsIds.Count }).Count) {
    $onByDs = @{}; foreach ($v in $onVms) { foreach ($id in $v.dsIds) { $onByDs[$id] = 1 + [int]$onByDs[$id] } }
    foreach ($d in $datastores) { $exposed[$d.name] = [int]$onByDs[$d.id] }
}
$onByHost = @{}; foreach ($v in $onVms) { if ($v.host) { $onByHost[$v.host] = 1 + [int]$onByHost[$v.host] } }
foreach ($h in $hosts) { $exposed[$h.name] = [int]$onByHost[$h.name] }
foreach ($c in $clusters) { $exposed[$c.name] = $c.vmsOn }
Set-FindingImpact $findings $exposed -SkipRules 'cert-vc', 'license', 'vm-off', 'rp-limit'

$sorted = Sort-ReportFinding $findings

# --- Secciones -------------------------------------------------------------------
$kpis = [ordered]@{
    'VMs'           = $realVms.Count
    'Encendidas'    = $onVms.Count
    'Apagadas'      = $off.Count
    'Plantillas'    = @($vms | Where-Object template).Count
    'Hosts'         = $hosts.Count
    'Clústeres'     = $clusters.Count
    'Datastores'    = $datastores.Count
    'Snapshots'     = $snapRows.Count
    'Críticos'      = @($sorted | Where-Object severity -eq 'Crítico').Count
    'Advertencias'  = @($sorted | Where-Object severity -eq 'Advertencia').Count
}

# --- Métricas (paneles) -----------------------------------------------------------
# Capacidad y holgura por clúster: uso físico (quickStats), uso tras perder el host mayor y VMs que aún caben.
$capCards = foreach ($c in @($clusters | Where-Object { $_.hosts -gt 0 })) {
    $act = if ($capByCl[$c.id]) { $capByCl[$c.id].ToArray() } else { @() }
    $cpuCap = [double](Get-Sum $act 'cpuCap'); $cpuUsed = [double](Get-Sum $act 'cpuUsed')
    $memCap = [double](Get-Sum $act 'memCap'); $memUsed = [double](Get-Sum $act 'memUsed')
    $cpuP = Get-Percent $cpuUsed $cpuCap; $memP = Get-Percent $memUsed $memCap
    New-PanelCard -Group $c.name -Key 'cl-cpu-used' -Label 'CPU en uso' -Value (Format-Percent $cpuP) -Number $cpuP -Pct $cpuP -Level (Get-MetricLevel $cpuP 70 85) -Note ('{0:0.#} de {1:0.#} GHz' -f ($cpuUsed / 1000), ($cpuCap / 1000))
    New-PanelCard -Group $c.name -Key 'cl-mem-used' -Label 'RAM en uso' -Value (Format-Percent $memP) -Number $memP -Pct $memP -Level (Get-MetricLevel $memP 75 90) -Note ('{0:0.#} de {1:0.#} GB' -f ($memUsed / 1024), ($memCap / 1024))
    if ($null -ne $c.n1MemPct) {
        $cpuN1 = if ($null -ne $c.n1CpuPct) { [double]$c.n1CpuPct } else { 0 }
        $n1 = [math]::Max([double]$c.n1MemPct, $cpuN1)
        $res = if ($cpuN1 -gt [double]$c.n1MemPct) { 'CPU' } else { 'RAM' }
        New-PanelCard -Group $c.name -Key 'cl-n1' -Label 'Uso si falla el host mayor' -Value (Format-Percent $n1) -Number $n1 -Pct $n1 -Level (Get-MetricLevel $n1 $N1WarnPct 100) `
            -Note $(if ($n1 -gt 100) { "No cabe ($res): HA no reinicia todo" } else { "Recurso limitante: $res" })
        # VMs que aún caben con N+1, por RAM, con el tamaño medio de las VMs encendidas del clúster.
        $avgMB = $c.avgVmMB
        if ($avgMB -gt 0) {
            $fit = [int][math]::Max(0, [math]::Floor(($c.n1Mem.left - $c.n1Mem.used) / $avgMB))
            New-PanelCard -Group $c.name -Key 'cl-fit' -Label 'VMs que aún caben (N+1)' -Value "$fit" -Number $fit -Level $(if ($fit -eq 0) { 'crit' } elseif ($fit -lt 3) { 'warn' } else { 'ok' }) `
                -Note $(if ($avgMB -ge 1024) { 'VM media de {0:0.#} GB de RAM' -f ($avgMB / 1024) } else { 'VM media de {0:0} MB de RAM' -f $avgMB })
        }
    } elseif ($c.activeHosts -eq 1) {
        New-PanelCard -Group $c.name -Key 'cl-n1' -Label 'Uso si falla el host mayor' -Value 'Sin N+1' -Level 'warn' -Note 'Un solo host activo'
    }
    $vr = [double]$c.vcpuRatio
    New-PanelCard -Group $c.name -Key 'cl-vcpu' -Label 'vCPU:pCore' -Value ('{0:0.##}:1' -f $vr) -Number $vr -Pct (100 * $vr / $VcpuRatioCrit) -Level (Get-MetricLevel $vr $VcpuRatioWarn $VcpuRatioCrit) `
        -Note "$($c.vcpu) vCPU en $($c.cores) cores"
}

# Datastores: totales y los más llenos, con los días hasta el 90 % según la corrida anterior del entorno.
# Historial: carpetas hermanas de la salida (reports/<env>/); dentro de una auditoría, las de la auditoría.
# Al menos una hora antes: dos corridas seguidas no muestran crecimiento útil.
$prev = Find-PreviousRun -OutDir $outDir -Env $Env -Before $generated -RawFile 'datastores.json' -SubDirs '', 'inventario' -MinGapHours 1
$prevAt = if ($prev) { $prev.at } else { $null }
$prevDs = @{}; if ($prev) { foreach ($x in (Read-JsonFile (Join-Path $prev.rawDir 'datastores.json') @() -AsArray)) { $prevDs["$(P $x '_moref' '')"] = $x } }
$daysTo90 = {
    param($d)
    $p = $prevDs[$d.id]; if (-not $p) { return $null }
    $usedPrev = ([double](P $p 'summary.capacity' 0) - [double](P $p 'summary.freeSpace' 0)) / $GB
    $usedNow = $d.capGB - $d.freeGB
    Get-DaysToPct -CapGB $d.capGB -UsedGB $usedNow -RatePerDay (($usedNow - $usedPrev) / [math]::Max(0.04, ($generated - $prevAt).TotalDays))
}
$okDs = @($datastores | Where-Object accessible)
$capTB = [math]::Round([double](Get-Sum $okDs 'capGB') / 1024, 2); $freeTB = [math]::Round([double](Get-Sum $okDs 'freeGB') / 1024, 2)
$dsUsedP = Get-Percent ($capTB - $freeTB) $capTB
$overN = @($okDs | Where-Object { $_.usedPct -ge $DatastoreWarnPct }).Count
$critN = @($okDs | Where-Object { $_.usedPct -ge $DatastoreCritPct }).Count
$dsCards = @(
    New-PanelCard -Key 'ds-total' -Label 'Almacenamiento en uso' -Value (Format-Percent $dsUsedP) -Number $dsUsedP -Pct $dsUsedP -Level (Get-MetricLevel $dsUsedP $DatastoreWarnPct $DatastoreCritPct) -Note ('{0:0.##} TB libres de {1:0.##} TB' -f $freeTB, $capTB)
    New-PanelCard -Key 'ds-over' -Label "Datastores ≥ $DatastoreWarnPct %" -Value "$overN de $($okDs.Count)" -Number $overN -Level $(if ($critN) { 'crit' } elseif ($overN) { 'warn' } else { 'ok' }) `
        -Note $(if (@($datastores).Count -ne $okDs.Count) { "$(@($datastores).Count - $okDs.Count) no accesibles" } else { '' })
    # Disco y recursos asignados a VMs apagadas: capacidad que se recupera dándolas de baja.
    $offGB = [math]::Round([double](Get-Sum $off 'usedGB'), 1)
    $offP = Get-Percent $offGB (($capTB - $freeTB) * 1024)
    New-PanelCard -Key 'off-disk' -Label 'Disco en VMs apagadas' -Value ('{0:0.#} GB' -f $offGB) -Number $offGB -Pct $offP -Level $(if ($offP -ge 10) { 'warn' } else { '' }) `
        -Note "$(Format-Percent $offP) del usado · $($off.Count) VMs, $((Get-Sum $off 'vcpu')) vCPU y $([math]::Round([double](Get-Sum $off 'memMB') / 1024, 1)) GB de RAM asignados"
    foreach ($d in @($okDs | Select-Object -First 5)) {
        $dd = & $daysTo90 $d
        $eta = if ($d.usedPct -ge 90) { ' · ya supera el 90 %' } elseif ($null -eq $dd) { '' } elseif ([double]::IsPositiveInfinity($dd)) { ' · sin crecimiento' } elseif ($dd -gt 3650) { ' · más de 10 años al 90 %' } else { " · 90 % en ~$dd días" }
        New-PanelCard -Group 'Más llenos' -Key "ds-used:$($d.id)" -Label $d.name -Value (Format-Percent $d.usedPct) -Number $d.usedPct -Pct $d.usedPct -Level (Get-MetricLevel $d.usedPct $DatastoreWarnPct $DatastoreCritPct) `
            -Note (('libre {0:0.#} GB' -f $d.freeGB) + $eta)
    }
)
$dsNote = if ($prevAt) { "Crecimiento calculado contra la corrida del $($prevAt.ToString('yyyy-MM-dd HH:mm'))." } else { 'Sin corrida anterior del entorno: los días hasta el 90 % aparecen desde la segunda corrida.' }

# Salud e higiene en %.
$toolsOk = @($onVms | Where-Object { $_.toolsVer -in 'guestToolsCurrent', 'guestToolsUnmanaged' }).Count
$toolsP = Get-Percent $toolsOk $onVms.Count
$hwKnown = @($realVms | Where-Object hwNum -gt 0); $hwOk = @($hwKnown | Where-Object hwNum -ge $MinHwVersion).Count
$hwP = Get-Percent $hwOk $hwKnown.Count
$onP = Get-Percent $onVms.Count $realVms.Count
$conn = @($hosts | Where-Object state -eq 'connected').Count; $connP = Get-Percent $conn $hosts.Count
$maintN = @($hosts | Where-Object maint).Count
$snapVms = @($snapRows | Select-Object -ExpandProperty vm -Unique).Count
$oldest = if ($snapRows.Count) { [int]$snapRows[0].ageDays } else { $null }
$healthCards = @(
    New-PanelCard -Key 'hosts-connected' -Label 'Hosts conectados' -Value (Format-Percent $connP) -Number $connP -Pct $connP -Level $(if ($null -eq $connP) { '' } elseif ($connP -lt 100) { 'crit' } else { 'ok' }) `
        -Note "$conn de $($hosts.Count)$(if ($maintN) { " · $maintN en mantenimiento" })"
    New-PanelCard -Key 'tools-current' -Label 'VMware Tools al día' -Value (Format-Percent $toolsP) -Number $toolsP -Pct $toolsP -Level (Get-MetricLevel $toolsP 90 75 -LowerIsWorse) -Note "$toolsOk de $($onVms.Count) VMs encendidas"
    New-PanelCard -Key 'hw-current' -Label "Hardware virtual ≥ vmx-$MinHwVersion" -Value (Format-Percent $hwP) -Number $hwP -Pct $hwP -Level (Get-MetricLevel $hwP 90 75 -LowerIsWorse) -Note "$hwOk de $($hwKnown.Count) VMs"
    New-PanelCard -Key 'vms-on' -Label 'VMs encendidas' -Value (Format-Percent $onP) -Number $onP -Pct $onP -Note "$($off.Count) apagadas"
    New-PanelCard -Key 'snap-vms' -Label 'VMs con snapshot' -Value "$snapVms" -Number $snapVms -Level $(if ($null -eq $oldest) { 'ok' } elseif ($oldest -ge $SnapshotCritDays) { 'crit' } elseif ($oldest -ge $SnapshotWarnDays) { 'warn' } else { 'ok' }) `
        -Note $(if ($null -ne $oldest) { "el más antiguo: $oldest días" } else { 'sin snapshots' })
)

$sections = New-Object System.Collections.Generic.List[object]
$want = { param($t) $Type -eq 'all' -or $Type -eq $t }

# Paneles primero: lo que se lee de un vistazo, antes de las tablas.
if (& $want 'health') { $sections.Add((New-ReportPanel 'Salud e higiene' $healthCards)) }
if (& $want 'capacity') {
    $sections.Add((New-ReportPanel 'Capacidad y holgura' $capCards 'Uso si falla el host mayor: carga actual frente a lo que queda sin ese host (más de 100 % = no cabe). VMs que aún caben: por RAM, manteniendo N+1.'))
    $sections.Add((New-ReportPanel 'Almacenamiento' $dsCards $dsNote))
}

if (& $want 'health') {
    $sections.Add((New-ReportTable 'Hallazgos y sugerencias' (Get-FindingColumns) $sorted (Get-NoteText 'review-commands')))
}
if (& $want 'capacity') {
    $sections.Add((New-ReportTable 'Capacidad por clúster' @('name:Clúster', 'ha:HA', 'drs:DRS', 'hosts:Hosts', 'cores:pCores', 'vcpu:vCPU (on)', 'vcpuRatio:vCPU:pCore', 'memGB:RAM física GB', 'vmemGB:RAM asignada GB', 'memRatio:Ratio RAM', 'n1CpuPct:CPU N+1 %', 'n1MemPct:RAM N+1 %') $clusters "N+1: uso actual frente a la capacidad que queda al perder el host mayor (más de 100 % = no cabe). Advertencia ≥ $N1WarnPct %."))
    if ($pools.Count) {
        $sections.Add((New-ReportTable 'Resource pools' @('name:Pool', 'parent:Padre', 'cpuLimit:Límite CPU MHz', 'cpuReserve:Reserva CPU MHz', 'memLimit:Límite RAM MB', 'memReserve:Reserva RAM MB') $pools 'Límite -1 = sin límite.'))
    }
    $sections.Add((New-ReportTable 'Datastores' @('name:Datastore', 'type:Tipo', 'capGB:Capacidad GB', 'freeGB:Libre GB', 'usedPct:Uso %', 'provPct:Aprovisionado %', 'accessible:Accesible') $datastores))
    $sections.Add((New-ReportTable 'Hosts' @('name:Host', 'cluster:Clúster', 'state:Estado', 'maint:Mantenimiento', 'cores:Cores', 'memGB:RAM GB', 'cpuPct:CPU %', 'memPct:RAM %', 'version:Versión') $hosts))
    if ($certRow -or $licRows.Count) {
        $sections.Add((New-ReportTable 'Certificado y licencias' @('item:Elemento', 'detail:Detalle', 'expires:Vence', 'days:Días restantes') (@($certRow) + $licRows | Where-Object { $_ }) "Umbrales: certificado $CertWarnDays días, licencias $LicenseWarnDays días."))
    }
}
if (& $want 'snapshots') {
    $sections.Add((New-ReportTable 'Snapshots' @('vm:VM', 'name:Snapshot', 'created:Creado', 'ageDays:Días', 'description:Descripción') $snapRows "Umbrales: advertencia ≥ $SnapshotWarnDays días, crítico ≥ $SnapshotCritDays días."))
}
if (& $want 'inventory') {
    $sections.Add((New-ReportTable 'Máquinas virtuales' @('name:VM', 'power:Estado', 'host:Host', 'vcpu:vCPU', 'memMB:RAM MB', 'usedGB:Disco GB', 'os:SO', 'ip:IP', 'tools:Tools', 'hwVersion:HW') $realVms))
}

# --- Salida -----------------------------------------------------------------------
Complete-Report -Root $root -OutDir $outDir -RawDir $rawDir -BaseName "reporte-$Type" -Title "Reporte vCenter — $($Env.ToUpper()) — $Type" `
    -Env $Env -Generated $generated -Kpis $kpis -Sorted $sorted -Sections $sections.ToArray() -Format $Format -MdMaxRows $MdMaxRows -CsvDelimiter $CsvDelimiter
