<#
.SYNOPSIS
  Genera reportes HTML/Markdown/CSV de vCenter con hallazgos y sugerencias. Solo lectura.

.DESCRIPTION
  Recolecta inventario en bloque (una llamada object.collect por tipo de objeto) mediante
  scripts/govc.ps1, guarda el JSON normalizado en reports/<env>/<marca>/raw/ y renderiza las
  plantillas de templates/. Con -FromRaw re-renderiza sin volver a consultar vCenter.
  Escribe además raw/findings.json y raw/summary.json, que usan Invoke-Audit.ps1 y
  Compare-Report.ps1. Los reportes quedan en reports/ (ignorado por git) y contienen
  información interna.

.EXAMPLE
  ./scripts/New-Report.ps1 -Env prod
  ./scripts/New-Report.ps1 -Env prod -Type snapshots -Format md -SnapshotWarnDays 3
  ./scripts/New-Report.ps1 -FromRaw reports/prod/20261016-0900 -Type health
  ./scripts/New-Report.ps1 -Env prod -Type inventory -Format csv          # un CSV por tabla, para Excel
#>
param(
    [string]$Env,
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
$wrapper = Join-Path $PSScriptRoot 'govc.ps1'

function P($obj, [string]$name, $default = $null) {
    # Lectura tolerante de propiedades (las rutas de vSphere contienen puntos).
    if ($null -ne $obj -and $obj.PSObject.Properties[$name] -and $null -ne $obj.$name) { return $obj.$name }
    return $default
}

function Get-CertSummary([string]$Text) {
    # about.cert / host.cert.info -json: campos de primer nivel en minúscula (los de la cadena van en mayúscula).
    $get = { param($k) $m = [regex]::Match($Text, '"' + $k + '"\s*:\s*"([^"]*)"'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
    $na = & $get 'notAfter'
    if (-not $na) { return $null }
    [pscustomobject]@{ subject = & $get 'subject'; issuer = & $get 'issuer'; notAfter = $na; status = & $get 'status' }
}

# --- Recolección --------------------------------------------------------------
$queries = [ordered]@{
    vms        = @('m', 'name', 'runtime.powerState', 'runtime.host', 'summary.config.numCpu', 'summary.config.memorySizeMB',
                   'summary.config.guestFullName', 'summary.storage.committed', 'summary.storage.uncommitted',
                   'guest.toolsRunningStatus', 'guest.toolsVersionStatus2', 'guest.ipAddress', 'config.template',
                   'snapshot.rootSnapshotList', 'runtime.consolidationNeeded', 'config.version',
                   'config.cpuAllocation.limit', 'config.memoryAllocation.limit', 'config.hardware.device',
                   'summary.quickStats.balloonedMemory', 'summary.quickStats.swappedMemory', 'summary.quickStats.compressedMemory')
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

if ($FromRaw) {
    $outDir = (Resolve-Path $FromRaw).Path
    $rawDir = Join-Path $outDir 'raw'
    $meta = Get-Content (Join-Path $rawDir 'meta.json') -Raw | ConvertFrom-Json
    $Env = $meta.env
    $data = @{}
    foreach ($k in @($queries.Keys) + 'alarms') {
        $f = Join-Path $rawDir "$k.json"
        $data[$k] = if (Test-Path $f) { @(Get-Content $f -Raw | ConvertFrom-Json -DateKind String) } else { @() }
    }
    $vcFile = Join-Path $rawDir 'vcenter.json'
    $vcenter = if (Test-Path $vcFile) { Get-Content $vcFile -Raw | ConvertFrom-Json -DateKind String } else { $null }
    $generated = [datetime]$meta.generated
} else {
    if (-not $Env) { throw 'Indica -Env <entorno> o -FromRaw <carpeta>.' }
    $Env = $Env.ToLowerInvariant()
    $generated = Get-Date
    $outDir = if ($OutDir) { $OutDir } else { Join-Path $root ("reports/{0}/{1:yyyyMMdd-HHmmss}" -f $Env, $generated) }
    $rawDir = Join-Path $outDir 'raw'
    New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

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
    # La salida incluye la clave pública como entero gigante (no parseable): se extraen solo los campos de primer nivel.
    $cert = if ($rc.exitCode -eq 0 -and $rc.stdout) { Get-CertSummary $rc.stdout } else { $null }
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
    ConvertTo-Json -InputObject $vcenter -Depth 6 | Set-Content (Join-Path $rawDir 'vcenter.json') -Encoding utf8

    foreach ($k in $data.Keys) { ConvertTo-Json -InputObject @($data[$k]) -Depth 12 | Set-Content (Join-Path $rawDir "$k.json") -Encoding utf8 }
    @{ env = $Env; generated = $generated.ToString('o'); user = "$env:USERDOMAIN\$env:USERNAME"; deviceScan = (-not $SkipDeviceScan) } |
        ConvertTo-Json | Set-Content (Join-Path $rawDir 'meta.json') -Encoding utf8
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
    $snaps = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    foreach ($s in @(P $v 'snapshot.rootSnapshotList' @())) { $stack.Push($s) }
    while ($stack.Count) {
        $s = $stack.Pop()
        $created = [datetimeoffset]::Parse($s.createTime)
        $snaps.Add([pscustomobject]@{ name = $s.name; created = $created; ageDays = [math]::Floor(($now - $created.LocalDateTime).TotalDays); description = $s.description })
        foreach ($c in @(P $s 'childSnapshotList' @())) { $stack.Push($c) }
    }
    $hw = "$(P $v 'config.version' '')"
    [pscustomobject]@{
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
function Get-N1($clusterId, [string]$res) {
    # Uso actual frente a la capacidad que queda al perder el host de mayor capacidad del clúster.
    $act = @($hostCap.Values | Where-Object { $_.clusterId -eq $clusterId -and $_.active })
    if ($act.Count -lt 2) { return [pscustomobject]@{ hosts = $act.Count; pct = $null; used = 0; left = 0 } }
    $cap = ($act | Measure-Object "${res}Cap" -Sum).Sum; $max = ($act | Measure-Object "${res}Cap" -Maximum).Maximum
    $used = ($act | Measure-Object "${res}Used" -Sum).Sum; $left = $cap - $max
    [pscustomobject]@{ hosts = $act.Count; pct = $(if ($left -gt 0) { [math]::Round(100 * $used / $left, 1) } else { $null }); used = $used; left = $left }
}

$clusters = foreach ($c in $data.compute) {
    $members = @($data.hosts | Where-Object { (P $_ 'parent') -and $_.parent.value -eq $c._moref })
    $on = @($realVms | Where-Object { $_.clusterId -eq $c._moref -and $_.power -eq 'poweredOn' })
    $cores = [int](P $c 'summary.numCpuCores' 0)
    $memGB = [math]::Round([double](P $c 'summary.totalMemory' 0) / $GB, 1)
    $vcpu = ($on | Measure-Object vcpu -Sum).Sum
    $vmem = [math]::Round((($on | Measure-Object memMB -Sum).Sum) / 1024, 1)
    $cc = $clusterCfg[$c._moref]
    $n1m = Get-N1 $c._moref 'mem'; $n1c = Get-N1 $c._moref 'cpu'
    [pscustomobject]@{
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
    }
}
$clusters = @($clusters | Sort-Object name)

$hosts = @($data.hosts | ForEach-Object {
        $cores = [int](P $_ 'summary.hardware.numCpuCores' 0); $mhz = [int](P $_ 'summary.hardware.cpuMhz' 0)
        $memMB = [double](P $_ 'summary.hardware.memorySize' 0) / 1MB
        [pscustomobject]@{
            name    = $_.name
            cluster = $(if ((P $_ 'parent')) { $nameById[$_.parent.value] } else { '' })
            state   = P $_ 'runtime.connectionState' ''
            maint   = [bool](P $_ 'runtime.inMaintenanceMode' $false)
            version = P $_ 'summary.config.product.fullName' ''
            cores   = $cores
            memGB   = [math]::Round($memMB / 1024, 1)
            cpuPct  = if ($cores * $mhz) { [math]::Round(100 * [double](P $_ 'summary.quickStats.overallCpuUsage' 0) / ($cores * $mhz), 1) } else { 0 }
            memPct  = if ($memMB) { [math]::Round(100 * [double](P $_ 'summary.quickStats.overallMemoryUsage' 0) / $memMB, 1) } else { 0 }
        } } | Sort-Object name)

$datastores = @($data.datastores | ForEach-Object {
        $cap = [double](P $_ 'summary.capacity' 0); $free = [double](P $_ 'summary.freeSpace' 0); $unc = [double](P $_ 'summary.uncommitted' 0)
        [pscustomobject]@{
            name       = $_.name
            type       = P $_ 'summary.type' ''
            accessible = [bool](P $_ 'summary.accessible' $true)
            capGB      = [math]::Round($cap / $GB, 1)
            freeGB     = [math]::Round($free / $GB, 1)
            usedPct    = if ($cap) { [math]::Round(100 * ($cap - $free) / $cap, 1) } else { 0 }
            provPct    = if ($cap) { [math]::Round(100 * ($cap - $free + $unc) / $cap, 1) } else { 0 }
        } } | Sort-Object usedPct -Descending)

# Resource pools con límite (se excluye el pool raíz «Resources» de cada clúster o host).
$pools = @($data.pools | Where-Object { $_.name -ne 'Resources' } | ForEach-Object {
        $ca = P $_ 'config.cpuAllocation'; $ma = P $_ 'config.memoryAllocation'
        [pscustomobject]@{
            name       = $_.name
            parent     = $(if ((P $_ 'parent')) { $nameById[$_.parent.value] } else { '' })
            cpuLimit   = [long](P $ca 'limit' -1)
            cpuReserve = [long](P $ca 'reservation' 0)
            memLimit   = [long](P $ma 'limit' -1)
            memReserve = [long](P $ma 'reservation' 0)
        } } | Sort-Object name)

$snapRows = @($realVms | ForEach-Object { $vm = $_; $_.snapshots | ForEach-Object {
            [pscustomobject]@{ vm = $vm.name; name = $_.name; created = $_.created.LocalDateTime.ToString('yyyy-MM-dd HH:mm'); ageDays = $_.ageDays; description = $_.description } } } |
    Sort-Object ageDays -Descending)

# --- Hallazgos ------------------------------------------------------------------
$findings = New-FindingList
function Add-Finding($sev, $cat, $obj, $evidence, $suggestion, $command = '', $rule = '') {
    Add-ReportFinding -List $findings -Severity $sev -Category $cat -Object $obj -Evidence $evidence -Suggestion $suggestion -Command $command -Rule $rule
}
function Add-GroupFinding($sev, $cat, $hit, $label, $tip, $command, $rule) {
    # Un hallazgo agregado por condición (evita cientos de filas repetidas).
    if (-not $hit.Count) { return }
    $list = (($hit | Select-Object -First 15).name) -join ', '
    $obj = if ($hit.Count -eq 1) { $hit[0].name } else { "$($hit.Count) VMs" }
    Add-Finding $sev $cat $obj "${label}: $list$(if ($hit.Count -gt 15) { '…' })" $tip $command $rule
}
$w = "./scripts/govc.ps1 -Env $Env"

foreach ($d in $datastores) {
    if (-not $d.accessible) { Add-Finding 'Crítico' 'Almacenamiento' $d.name 'Datastore no accesible' 'Revisar conectividad de almacenamiento/paths con el equipo de storage.' "$w datastore.info '$($d.name)'" 'ds-inaccessible' }
    elseif ($d.usedPct -ge $DatastoreCritPct) { Add-Finding 'Crítico' 'Almacenamiento' $d.name "Uso $($d.usedPct)% (libre $($d.freeGB) GB)" 'Liberar espacio (snapshots, ISOs, VMs huérfanas) o ampliar/migrar con Storage vMotion.' "$w datastore.info '$($d.name)'" 'ds-used' }
    elseif ($d.usedPct -ge $DatastoreWarnPct) { Add-Finding 'Advertencia' 'Almacenamiento' $d.name "Uso $($d.usedPct)% (libre $($d.freeGB) GB)" 'Planificar capacidad antes de llegar al umbral crítico.' "$w datastore.info '$($d.name)'" 'ds-used' }
    if ($d.accessible -and $d.provPct -gt 150) { Add-Finding 'Advertencia' 'Almacenamiento' $d.name "Aprovisionado $($d.provPct)% de la capacidad (thin)" 'Riesgo de llenado si los discos thin crecen; revisar sobreaprovisionamiento.' '' 'ds-thin' }
}
foreach ($s in $snapRows) {
    $cmd = "$w snapshot.tree -vm '$($s.vm)' -D -i"
    if ($s.ageDays -ge $SnapshotCritDays) { Add-Finding 'Crítico' 'Snapshots' $s.vm "Snapshot '$($s.name)' con $($s.ageDays) días" 'Validar con el dueño de la VM y consolidar/eliminar mediante cambio aprobado (degrada rendimiento y consume datastore).' $cmd "snap-age-$($s.name)" }
    elseif ($s.ageDays -ge $SnapshotWarnDays) { Add-Finding 'Advertencia' 'Snapshots' $s.vm "Snapshot '$($s.name)' con $($s.ageDays) días" 'Los snapshots no son respaldo; confirmar si aún se necesita.' $cmd "snap-age-$($s.name)" }
}
foreach ($h in $hosts) {
    if ($h.state -ne 'connected') { Add-Finding 'Crítico' 'Hosts' $h.name "Estado: $($h.state)" 'Revisar conectividad del host con vCenter (management network, servicios hostd/vpxa).' "$w host.info -host '$($h.name)'" 'host-state' }
    elseif ($h.maint) { Add-Finding 'Info' 'Hosts' $h.name 'En modo mantenimiento' 'Confirmar que corresponde a una ventana activa; si no, reintegrarlo al clúster.' '' 'host-maint' }
    if ($h.memPct -ge $HostMemWarnPct) { Add-Finding 'Advertencia' 'Capacidad' $h.name "Memoria en uso $($h.memPct)%" 'Revisar balanceo DRS o redistribuir cargas.' '' 'host-mem' }
}
foreach ($c in $clusters | Where-Object { $_.cores -gt 0 }) {
    $perf = "./scripts/Invoke-PerfCheck.ps1 -Env $Env -Cluster '$($c.name)'"
    if ($c.vcpuRatio -ge $VcpuRatioCrit) { Add-Finding 'Crítico' 'Capacidad' $c.name "vCPU:pCore $($c.vcpuRatio):1" 'Sobresuscripción de CPU alta; revisar CPU Ready y right-sizing de VMs.' $perf 'cl-vcpu' }
    elseif ($c.vcpuRatio -ge $VcpuRatioWarn) { Add-Finding 'Advertencia' 'Capacidad' $c.name "vCPU:pCore $($c.vcpuRatio):1" 'Monitorear CPU Ready; considerar right-sizing.' $perf 'cl-vcpu' }
    if ($c.memRatio -gt $MemRatioWarn) { Add-Finding 'Advertencia' 'Capacidad' $c.name "RAM asignada/física $($c.memRatio)" 'Sobrecompromiso de memoria; revisar ballooning/swap y reservas de HA.' '' 'cl-mem' }
}
foreach ($c in $clusters | Where-Object { $_.isCluster }) {
    # Holgura N+1 con el uso actual (quickStats): ¿la carga cabe si cae el host de mayor capacidad?
    if ($c.activeHosts -eq 1) {
        Add-Finding 'Info' 'Capacidad' $c.name 'Un solo host activo: sin tolerancia a la falla de un host' 'Confirmar que es intencional; con un solo host, HA no puede reiniciar VMs en otro.' '' 'cl-n1-single'
    } elseif ($c.activeHosts -ge 2) {
        foreach ($r in @(@{ k = 'mem'; n = $c.n1Mem; label = 'Memoria'; fmt = { param($x) "$([math]::Round($x / 1024)) GB" } }, @{ k = 'cpu'; n = $c.n1Cpu; label = 'CPU'; fmt = { param($x) "$([math]::Round($x / 1000)) GHz" } })) {
            $n = $r.n; if ($null -eq $n.pct) { continue }
            $ev = "$($r.label) en uso $(& $r.fmt $n.used); sin el host mayor quedan $(& $r.fmt $n.left) ($($n.pct)% de uso) con $($n.hosts) hosts activos"
            if ($n.pct -gt 100) { Add-Finding 'Crítico' 'Capacidad' $c.name $ev 'La carga actual no cabe si falla un host: HA no podría reiniciar todas las VMs. Agregar capacidad o reducir carga.' '' "cl-n1-$($r.k)" }
            elseif ($n.pct -ge $N1WarnPct) { Add-Finding 'Advertencia' 'Capacidad' $c.name $ev 'Holgura N+1 escasa; planificar capacidad antes de que la falla de un host deje VMs sin recursos.' '' "cl-n1-$($r.k)" }
        }
    }
    if ($c.ha -eq 'Sí' -and $c.admission -eq $false) { Add-Finding 'Advertencia' 'Clúster' $c.name 'HA activo con el control de admisión desactivado' 'Sin control de admisión, vSphere permite encender VMs aunque ya no haya capacidad para reiniciarlas ante una falla; evaluar habilitarlo (cambio aprobado).' "$w object.collect -json -type c / name configurationEx.dasConfig.admissionControlEnabled" 'cl-ha-admission' }
    if ($c.ha -eq 'No') { Add-Finding 'Crítico' 'Clúster' $c.name 'vSphere HA deshabilitado' 'Habilitar HA para que las VMs se reinicien ante la falla de un host (cambio aprobado).' "$w object.collect -s '$($c.name)' configurationEx.dasConfig.enabled" 'cl-ha' }
    if ($c.drs -eq 'No') { Add-Finding 'Advertencia' 'Clúster' $c.name 'DRS deshabilitado' 'Evaluar habilitar DRS para balanceo automático y mantenimiento sin interrupción.' '' 'cl-drs' }
    elseif ($c.drs -eq 'manual') { Add-Finding 'Advertencia' 'Clúster' $c.name 'DRS en modo manual' 'En modo manual DRS solo recomienda; considerar partiallyAutomated o fullyAutomated.' '' 'cl-drs' }
}

$off = @($realVms | Where-Object power -eq 'poweredOff')
if ($off.Count) { Add-Finding 'Info' 'Higiene' "$($off.Count) VMs" "VMs apagadas: $((($off | Select-Object -First 10).name) -join ', ')$(if ($off.Count -gt 10) { '…' })" 'Validar con dueños si pueden darse de baja (consumen almacenamiento y licencias).' "$w find / -type m -runtime.powerState poweredOff" 'vm-off' }

$onVms = @($realVms | Where-Object power -eq 'poweredOn')
Add-GroupFinding 'Advertencia' 'VMware Tools' @($onVms | Where-Object { $_.toolsVer -eq 'guestToolsNotInstalled' }) 'VMware Tools no instalado' 'Instalar open-vm-tools/VMware Tools (apagado ordenado, quiesce de backups, métricas).' '' 'tools-missing'
Add-GroupFinding 'Advertencia' 'VMware Tools' @($onVms | Where-Object { $_.toolsVer -ne 'guestToolsNotInstalled' -and $_.tools -and $_.tools -ne 'guestToolsRunning' }) 'VMware Tools no está corriendo' 'Verificar el servicio de VMware Tools en el guest.' '' 'tools-notrunning'
Add-GroupFinding 'Info' 'VMware Tools' @($onVms | Where-Object { $_.toolsVer -in 'guestToolsNeedUpgrade', 'guestToolsTooOld' }) 'VMware Tools desactualizado' 'Actualizar en la próxima ventana de mantenimiento.' '' 'tools-old'

# Configuración de VMs (sin llamadas extra: todo viene del mismo object.collect).
Add-GroupFinding 'Advertencia' 'Configuración VM' @($realVms | Where-Object consolidate) 'Consolidación de discos pendiente' 'Consolidar discos (Snapshots → Consolidar) en ventana; los delta sin consolidar degradan I/O y consumen espacio.' '' 'vm-consolidate'
Add-GroupFinding 'Advertencia' 'Configuración VM' @($realVms | Where-Object { $_.cpuLimit -ge 0 -or $_.memLimit -ge 0 }) 'Límite de CPU o memoria configurado' 'Los límites provocan contención aunque el host tenga recursos; revisar si son intencionales.' '' 'vm-limits'

# Presión de memoria por VM (quickStats, instantáneo). Invoke-PerfCheck.ps1 lo mide en una ventana de tiempo.
Add-GroupFinding 'Advertencia' 'Capacidad' @($onVms | Where-Object { $_.balloonMB -gt 0 }) 'Memoria recuperada por balloon' 'El host está reclamando memoria al guest: revisar la presión de memoria del host y el tamaño de la VM.' '' 'vm-balloon'
Add-GroupFinding 'Advertencia' 'Capacidad' @($onVms | Where-Object { $_.swapMB -gt 0 }) 'Memoria en swap del hipervisor' 'El swap del host degrada mucho el rendimiento: liberar memoria en el host o redistribuir cargas.' '' 'vm-swap'
Add-GroupFinding 'Info' 'Capacidad' @($onVms | Where-Object { $_.compMB -gt 0 }) 'Memoria comprimida por el host' 'Señal temprana de presión de memoria; revisar junto con balloon y swap.' '' 'vm-compressed'
foreach ($p in $pools | Where-Object { $_.cpuLimit -ge 0 -or $_.memLimit -ge 0 }) {
    $lim = @($(if ($p.cpuLimit -ge 0) { "CPU $($p.cpuLimit) MHz" }), $(if ($p.memLimit -ge 0) { "memoria $($p.memLimit) MB" }) | Where-Object { $_ }) -join ', '
    Add-Finding 'Advertencia' 'Capacidad' $p.name "Resource pool con límite: $lim" 'Un límite en el pool provoca contención para todas sus VMs aunque el clúster tenga recursos; confirmar que es intencional.' "$w pool.info '$($p.name)'" 'rp-limit'
}

$deviceScanned = if ($FromRaw) { [bool](P $meta 'deviceScan' $true) } else { -not $SkipDeviceScan }
if ($deviceScanned) {
    Add-GroupFinding 'Info' 'Configuración VM' @($realVms | Where-Object { $_.isos.Count }) 'CD/DVD conectado a ISO de datastore' 'Desconectar la ISO cuando no se use: impide vMotion/DRS hacia hosts sin acceso al datastore.' '' 'vm-iso'
} else {
    # Se declara como limitación: la auditoría la muestra en «Cobertura» y no la puntúa.
    Add-Finding 'Info' 'Cobertura' 'Detección de ISO conectada' 'Omitida en esta corrida (-SkipDeviceScan)' 'Ejecutar sin -SkipDeviceScan (o por clúster) para revisar unidades de CD/DVD con ISO conectada.' '' 'coverage-devices'
}
Add-GroupFinding 'Info' 'Configuración VM' @($realVms | Where-Object { $_.hwNum -gt 0 -and $_.hwNum -lt $MinHwVersion }) "Hardware virtual anterior a vmx-$MinHwVersion" 'Planificar actualización de hardware virtual (requiere reinicio y validación de compatibilidad).' '' 'vm-hwversion'

foreach ($a in $data.alarms) {
    $sev = switch ($a.status) { 'red' { 'Crítico' } 'yellow' { 'Advertencia' } default { 'Info' } }
    $obj = if ($nameById[$a.entity]) { $nameById[$a.entity] } else { "$($a.entityType):$($a.entity)" }
    Add-Finding $sev 'Alarmas' $obj "$($a.alarm) ($($a.status))$(if ($a.acknowledged) { ', reconocida' })" 'Atender según el runbook de la alarma.' "$w events -n 20 '$obj'" "alarm-$($a.alarm)"
}

# Certificado de vCenter y licencias.
$certRow = $null; $licRows = @()
if ($vcenter) {
    if ($vcenter.cert -and $vcenter.cert.notAfter) {
        $na = ([datetimeoffset]::Parse("$($vcenter.cert.notAfter)")).LocalDateTime
        $left = [math]::Floor(($na - $now).TotalDays)
        $certRow = [pscustomobject]@{ item = 'Certificado de vCenter'; detail = $vcenter.cert.subject; expires = $na.ToString('yyyy-MM-dd'); days = $left }
        if ($left -lt 0) { Add-Finding 'Crítico' 'Certificados' 'vCenter' "Certificado vencido el $($na.ToString('yyyy-MM-dd'))" 'Renovar el certificado de vCenter (VMCA o CA interna) mediante cambio aprobado.' "$w about.cert" 'cert-vc' }
        elseif ($left -le $CertWarnDays) { Add-Finding 'Advertencia' 'Certificados' 'vCenter' "Certificado vence en $left días ($($na.ToString('yyyy-MM-dd')))" 'Planificar la renovación antes del vencimiento.' "$w about.cert" 'cert-vc' }
    }
    foreach ($l in @($vcenter.licenses)) {
        $exp = $null; if ($l.expiration) { try { $exp = ([datetimeoffset]::Parse("$($l.expiration)")).LocalDateTime } catch { } }
        $left = if ($exp) { [math]::Floor(($exp - $now).TotalDays) } else { $null }
        $licRows += [pscustomobject]@{ item = $l.name; detail = "$($l.edition) · uso $($l.used)/$($l.total)"; expires = $(if ($exp) { $exp.ToString('yyyy-MM-dd') } else { 'sin vencimiento' }); days = $left }
        if ($null -ne $left -and $left -le $LicenseWarnDays) {
            $sev = if ($left -lt 0) { 'Crítico' } else { 'Advertencia' }
            Add-Finding $sev 'Licencias' $l.name "$(if ($left -lt 0) { 'Vencida' } else { "Vence en $left días" }) ($($exp.ToString('yyyy-MM-dd')))" 'Gestionar la renovación con el área de licenciamiento.' "$w license.ls" "license-$($l.edition)"
        }
    }
}

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

$sections = New-Object System.Collections.Generic.List[object]
$want = { param($t) $Type -eq 'all' -or $Type -eq $t }

if (& $want 'health') {
    $sections.Add((New-ReportTable 'Hallazgos y sugerencias' (Get-FindingColumns) $sorted 'Los comandos son propuestas de consulta; ningún cambio se ejecutó.'))
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
Export-ReportFinding $sorted (Join-Path $rawDir 'findings.json')
$kpis | ConvertTo-Json | Set-Content (Join-Path $rawDir 'summary.json') -Encoding utf8

$written = @()
$docFormats = @($Format | Where-Object { $_ -ne 'csv' })
if ($docFormats.Count) {
    $written += Write-GovcReport -Root $root -OutDir $outDir -BaseName "reporte-$Type" -Title "Reporte vCenter — $($Env.ToUpper()) — $Type" `
        -Env $Env -Generated $generated -Kpis $kpis -Sections $sections.ToArray() -Format $docFormats -MdMaxRows $MdMaxRows
}

if ('csv' -in $Format) {
    # Un CSV por tabla (encabezados en español), UTF-8 con BOM para que Excel respete los acentos.
    $sep = if ($CsvDelimiter) { $CsvDelimiter } else { (Get-Culture).TextInfo.ListSeparator }
    $culture = Get-Culture
    $slug = {
        param($t)
        $n = $t.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
        ($n.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    }
    $cell = {
        param($v)
        if ($null -eq $v) { return '' }
        if ($v -is [double] -or $v -is [decimal] -or $v -is [single]) { return $v.ToString($culture) }
        if ($v -is [int] -or $v -is [long]) { return "$v" }
        if ($v -is [bool]) { return $(if ($v) { 'Sí' } else { 'No' }) }
        if ($v -is [array]) { $v = ($v | ForEach-Object { "$_" }) -join ', ' }
        $t = "$v" -replace "`r?`n", ' '
        # Los textos vienen de vCenter: se neutraliza la inyección de fórmulas al abrir en Excel.
        if ($t -match '^[=+\-@\t]') { $t = "'" + $t }
        return $t
    }
    $csvSections = @(@{ title = 'Resumen'; columns = @('k:Indicador', 'v:Valor'); rows = @($kpis.GetEnumerator() | ForEach-Object { [pscustomobject]@{ k = $_.Key; v = $_.Value } }) }) + $sections.ToArray()
    foreach ($s in $csvSections) {
        $cols = @($s.columns | ForEach-Object { , ($_ -split ':', 2) })
        $f = Join-Path $outDir ("reporte-$Type-{0}.csv" -f (& $slug $s.title))
        $lines = New-Object System.Collections.Generic.List[string]
        $q = { param($x) '"' + ("$x" -replace '"', '""') + '"' }
        $lines.Add((($cols | ForEach-Object { & $q $_[1] }) -join $sep))
        foreach ($r in @($s.rows)) { $lines.Add((($cols | ForEach-Object { & $q (& $cell $r.($_[0])) }) -join $sep)) }
        [IO.File]::WriteAllLines($f, $lines, [Text.UTF8Encoding]::new($true))
        $written += $f
    }
}

[pscustomobject]@{
    Carpeta      = $outDir
    Archivos     = $written
    Criticos     = $kpis['Críticos']
    Advertencias = $kpis['Advertencias']
}
