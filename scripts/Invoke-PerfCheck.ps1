<#
.SYNOPSIS
  Revisión de rendimiento: CPU ready, latencia de datastores, CPU de hosts, ballooning, swap y
  caídas de red en una ventana de tiempo. Solo lectura.

.DESCRIPTION
  Consulta las métricas de vCenter con `metric.sample` (modo lote, una sesión) para hosts y VMs
  (incluido el uso de CPU y la RAM activa de cada VM, para el right-sizing en 24h y 7d)
  encendidas, y guarda solo agregados por entidad y contador (promedio, p95 y máximo) en
  raw/perf-*.json. Con -FromRaw recalcula los hallazgos con otros umbrales sin volver a consultar.
  Ventanas:
    1h  → intervalo de 20 s (tiempo real, desde los hosts; siempre disponible)
    24h → intervalo de 300 s (histórico de vCenter)
    7d  → intervalo de 1800 s (histórico de vCenter)
  Los contadores que vCenter no conserva en el nivel de estadísticas del intervalo no traen datos:
  se declaran como cobertura, no como "sin problema". Salida en reports/<env>/<marca>/perf-check.{html,md}.

.EXAMPLE
  ./scripts/Invoke-PerfCheck.ps1 -Env prod
  ./scripts/Invoke-PerfCheck.ps1 -Env prod -Cluster CL-PROD-01 -Window 1h
  ./scripts/Invoke-PerfCheck.ps1 -FromRaw reports/prod/20261018-090000 -DsLatencyWarnMs 15
#>
#Requires -Version 7.5
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$Env,
    [string[]]$Cluster,
    [ValidateSet('1h', '24h', '7d')][string]$Window = '24h',
    [ValidateSet('html', 'md', 'csv')][string[]]$Format = @('html', 'md'),
    [string]$FromRaw,
    [string]$OutDir,
    # Carpeta de un inventario ya recolectado (New-Report.ps1): evita volver a consultar hosts, VMs y datastores.
    [string]$InventoryDir,
    [double]$CpuReadyWarnPct = 5,
    [double]$CpuReadyCritPct = 10,
    [double]$DsLatencyWarnMs = 20,
    [double]$DsLatencyCritMs = 30,
    [double]$HostCpuWarnPct = 85,
    [double]$HostCpuCritPct = 95,
    # Right-sizing (ventanas 24h y 7d): CPU p95 y RAM activa p95 por debajo de estos % de lo asignado.
    [double]$RightSizeCpuPct = 30,
    [double]$RightSizeMemPct = 40,
    [int]$MdMaxRows = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/GovcJson.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Render.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Set-Alias -Name P -Value Get-Prop -Scope Script

$windows = @{ '1h' = @{ i = 20; n = 180 }; '24h' = @{ i = 300; n = 288 }; '7d' = @{ i = 1800; n = 336 } }
# Contadores por consulta. Las agregadas usan -instance= (instancia vacía = total de la entidad).
$hostAggCounters = @('cpu.usage.average', 'mem.vmmemctl.average', 'mem.swapinRate.average', 'net.droppedRx.summation', 'net.droppedTx.summation')
$hostDsCounters = @('datastore.totalReadLatency.average', 'datastore.totalWriteLatency.average')
$vmCounters = @('cpu.ready.summation', 'mem.vmmemctl.average', 'mem.swapinRate.average', 'cpu.usage.average', 'mem.active.average')
$chunkSize = 50

function Q($obj, [string[]]$names, $default = $null) {
    # Primera propiedad existente entre variantes de nombre (la salida JSON de govc cambia de mayúsculas entre versiones).
    Get-FirstProp $obj $names $default -AllowEmpty
}
function Get-Stats([double[]]$values, [double]$scale = 1.0) {
    # Promedio, p95 y máximo (con escala opcional); los valores negativos (-1 = sin muestra) se descartan.
    # Sin pipeline: con miles de VMs hay millones de muestras.
    $v = [System.Collections.Generic.List[double]]::new($values.Count)
    $sum = 0.0
    foreach ($x in $values) { if ($x -ge 0) { $y = $x * $scale; $v.Add($y); $sum += $y } }
    if (-not $v.Count) { return $null }
    $v.Sort()
    $idx = [math]::Max(0, [math]::Ceiling(0.95 * $v.Count) - 1)
    [pscustomobject]@{ avg = [math]::Round($sum / $v.Count, 2); p95 = [math]::Round($v[$idx], 2); max = [math]::Round($v[$v.Count - 1], 2); n = $v.Count }
}
function Get-DsUuid([string]$url) {
    # ds:///vmfs/volumes/<uuid>/ → <uuid>
    if ($url -match 'volumes/([^/]+)/?$') { return $Matches[1] }
    return $null
}
function ConvertFrom-IntervalInfo([string]$Text) {
    <# metric.interval.info imprime texto aunque reciba -json (govc 0.56): bloques "ID: 300 … Level: 1". #>
    foreach ($blk in ($Text -split '(?m)^(?=\s*ID:)')) {
        if ($blk -match '(?m)^\s*ID:\s*(\d+)') {
            $period = [int]$Matches[1]
            $lv = if ($blk -match '(?m)^\s*Level:\s*(\d+)') { [int]$Matches[1] } else { $null }
            [pscustomobject]@{ period = $period; level = $lv }
        }
    }
}
function ConvertFrom-MetricSample([string]$Text, [string]$Kind = '') {
    <#
    .SYNOPSIS  metric.sample -json → filas {kind, entity, counter, instance, values[], valid}.
    .NOTES     Tolera variantes de forma y mayúsculas. 'valid' = muestras ≥ 0 (calculado una vez aquí).
    #>
    if (-not $Text.Trim()) { return }
    # -NoEnumerate: un arreglo de un solo elemento no se desenvuelve.
    $o = $Text | ConvertFrom-Json -Depth 30 -NoEnumerate
    $list = if ($o -is [array]) { $o } else { Q $o @('sample', 'Sample', 'samples', 'Samples') @() }
    foreach ($em in @($list)) {
        $ent = Q $em @('entity', 'Entity')
        $id = "$(Q $ent @('value', 'Value') '')"
        foreach ($s in @(Q $em @('value', 'Value') @())) {
            [double[]]$vals = @(Q $s @('value', 'Value') @())
            $valid = 0; foreach ($x in $vals) { if ($x -ge 0) { $valid++ } }
            [pscustomobject]@{
                kind     = $Kind
                entity   = $id
                counter  = "$(Q $s @('name', 'Name') '')"
                instance = "$(Q $s @('instance', 'Instance') '')"
                values   = $vals
                valid    = $valid
            }
        }
    }
}

# --- Recolección --------------------------------------------------------------------
$ctx = Initialize-RunContext -Env $Env -FromRaw $FromRaw -OutDir $OutDir -Root $root -MetaFile 'meta-perf.json'
$Env = $ctx.env; $outDir = $ctx.outDir; $rawDir = $ctx.rawDir; $generated = $ctx.generated
if ($ctx.fromRaw) {
    $meta = $ctx.meta; $Window = $meta.window
    $load = { param($n) Read-JsonFile (Join-Path $rawDir "$n.json") @() -AsArray }
    $hostPerf = & $load 'perf-host'; $vmPerf = & $load 'perf-vm'; $dsPerf = & $load 'perf-datastore'; $errors = & $load 'perf-errors'
} else {
    Import-Module (Join-Path $PSScriptRoot 'lib/GovcBatch.psm1') -Force
    $win = $windows[$Window]

    # Primer lote: niveles de los intervalos y, si no hay inventario previo, hosts/VMs/datastores.
    $invRaw = if ($InventoryDir) { Join-Path $InventoryDir 'raw' } else { $null }
    $useInv = $invRaw -and (Test-Path (Join-Path $invRaw 'hosts.json')) -and (Test-Path (Join-Path $invRaw 'vms.json'))
    $cmds = @(, @('metric.interval.info', '-json'))
    if (-not $useInv) {
        $cmds += , @('object.collect', '-json', '-type', 'h', '/', 'name', 'parent', 'runtime.connectionState', 'runtime.inMaintenanceMode')
        $cmds += , @('object.collect', '-json', '-type', 'm', '/', 'name', 'runtime.powerState', 'runtime.host', 'summary.config.numCpu', 'summary.config.memorySizeMB', 'config.template')
        $cmds += , @('object.collect', '-json', '-type', 'r', '/', 'name')
        $cmds += , @('object.collect', '-json', '-type', 's', '/', 'name', 'summary.url')
    }
    [Console]::Error.WriteLine('Listando entidades e intervalos de estadísticas...')
    $r1 = Invoke-GovcBatch -Env $Env -Commands $cmds
    $levels = if ($r1[0].exitCode -eq 0) { @(ConvertFrom-IntervalInfo "$($r1[0].stdout)") } else { @() }
    if ($useInv) {
        $rd = { param($n) $f = Join-Path $invRaw "$n.json"; if (Test-Path $f) { @(Get-Content $f -Raw | ConvertFrom-Json -DateKind String) } else { @() } }
        $hRaw = & $rd 'hosts'; $vRaw = & $rd 'vms'; $cRaw = & $rd 'compute'; $sRaw = & $rd 'datastores'
    } else {
        foreach ($k in 1..4) { if ($r1[$k].exitCode -ne 0) { throw "Falló la consulta de inventario: $(Get-GovcBatchError $r1[$k])" } }
        $hRaw = @($r1[1].stdout | ConvertFrom-GovcCollect); $vRaw = @($r1[2].stdout | ConvertFrom-GovcCollect)
        $cRaw = @($r1[3].stdout | ConvertFrom-GovcCollect); $sRaw = @($r1[4].stdout | ConvertFrom-GovcCollect)
    }
    $crName = @{}; foreach ($c in $cRaw) { $crName[$c._moref] = $c.name }
    $dsName = @{}; foreach ($s in $sRaw) { $u = Get-DsUuid "$(P $s 'summary.url' '')"; if ($u) { $dsName[$u] = $s.name } }

    $hostInfo = @{}
    foreach ($h in $hRaw) {
        $cl = if ((P $h 'parent')) { $crName[$h.parent.value] } else { '' }
        $hostInfo[$h._moref] = [pscustomobject]@{
            id = $h._moref; name = $h.name; cluster = $cl
            state = P $h 'runtime.connectionState' ''; maint = [bool](P $h 'runtime.inMaintenanceMode' $false)
        }
    }
    $hostSel = @($hostInfo.Values | Where-Object { -not $Cluster -or $_.cluster -in $Cluster } | Sort-Object cluster, name)
    if (-not $hostSel.Count) { throw 'Ningún host coincide con el filtro.' }
    $hostOk = @($hostSel | Where-Object state -eq 'connected')
    $selIds = @{}; foreach ($h in $hostSel) { $selIds[$h.id] = $true }
    $vmInfo = @{}
    foreach ($v in $vRaw | Where-Object { (P $_ 'runtime.powerState') -eq 'poweredOn' -and -not [bool](P $_ 'config.template' $false) }) {
        $rh = P $v 'runtime.host'; $hid = if ($rh) { P $rh 'value' } else { $null }
        if (-not $hid -or -not $selIds[$hid]) { continue }
        $hi = $hostInfo[$hid]
        if ($hi.state -ne 'connected') { continue }
        $vmInfo[$v._moref] = [pscustomobject]@{ id = $v._moref; name = $v.name; host = $hi.name; cluster = $hi.cluster; vcpu = [int](P $v 'summary.config.numCpu' 1); memMB = [int](P $v 'summary.config.memorySizeMB' 0) }
    }

    # Segundo lote: muestras por trozos (límite de consultas de vCenter y largo de la línea de comandos).
    $sampleArgs = @('metric.sample', '-json', '-i', "$($win.i)", '-n', "$($win.n)")
    $jobs = New-Object System.Collections.Generic.List[object]
    function Split-Chunk([string[]]$ids) {
        # Siempre una lista de trozos: con un solo trozo, PowerShell desenvolvería el arreglo y se
        # haría una consulta por entidad en lugar de una por trozo.
        $out = New-Object System.Collections.Generic.List[object]
        for ($k = 0; $k -lt $ids.Count; $k += $chunkSize) { $out.Add([string[]]$ids[$k..([math]::Min($k + $chunkSize, $ids.Count) - 1)]) }
        return , $out.ToArray()
    }
    foreach ($ch in (Split-Chunk @($hostOk | ForEach-Object { "HostSystem:$($_.id)" }))) {
        $jobs.Add([pscustomobject]@{ kind = 'host'; ids = $ch; argv = $sampleArgs + @('-instance=') + $ch + $hostAggCounters })
        $jobs.Add([pscustomobject]@{ kind = 'hostds'; ids = $ch; argv = $sampleArgs + @('-instance=*') + $ch + $hostDsCounters })
    }
    foreach ($ch in (Split-Chunk @($vmInfo.Keys | Sort-Object | ForEach-Object { "VirtualMachine:$_" }))) {
        $jobs.Add([pscustomobject]@{ kind = 'vm'; ids = $ch; argv = $sampleArgs + @('-instance=') + $ch + $vmCounters })
    }
    [Console]::Error.WriteLine("Consultando métricas ($Window, intervalo $($win.i) s): $($hostOk.Count) hosts y $($vmInfo.Count) VMs en $($jobs.Count) consultas, una sesión...")
    $out = if ($jobs.Count) { Invoke-GovcBatch -Env $Env -Commands @(foreach ($j in $jobs) { , $j.argv }) } else { @() }

    $series = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -lt $jobs.Count; $k++) {
        $r = $out[$k]
        if ($r.exitCode -ne 0) { $errors.Add([pscustomobject]@{ kind = $jobs[$k].kind; entities = $jobs[$k].ids.Count; error = (Get-GovcBatchError $r) }); continue }
        try { foreach ($row in @(ConvertFrom-MetricSample "$($r.stdout)" $jobs[$k].kind)) { $series.Add($row) } }
        catch { $errors.Add([pscustomobject]@{ kind = $jobs[$k].kind; entities = $jobs[$k].ids.Count; error = "salida no reconocida: $($_.Exception.Message)" }) }
    }
    # Índice por tipo|entidad|contador|instancia (evita recorrer todas las series por cada VM).
    $idx = @{}; foreach ($s in $series) { $key = "$($s.kind)|$($s.entity)|$($s.counter)|$($s.instance)"; if (-not $idx.ContainsKey($key)) { $idx[$key] = $s } }
    $find = { param($kind, $id, $counter, $inst = '') $idx["$kind|$id|$counter|$inst"] }
    $statsOf = { param($s, $scale = 1.0) if ($s -and $s.valid) { Get-Stats $s.values $scale } else { $null } }

    $hostPerf = @(foreach ($h in $hostSel) {
            $ok = $h.state -eq 'connected'
            $rx = & $find 'host' $h.id 'net.droppedRx.summation'; $tx = & $find 'host' $h.id 'net.droppedTx.summation'
            $sum = { param($s) if ($s) { $v = @($s.values | Where-Object { $_ -ge 0 }); if ($v.Count) { [long](Get-Sum $v) } else { $null } } else { $null } }
            [pscustomobject]@{
                name = $h.name; cluster = $h.cluster; ok = $ok; error = $(if ($ok) { '' } else { "host $($h.state)" })
                cpuPct = & $statsOf (& $find 'host' $h.id 'cpu.usage.average') 0.01           # centésimas de %
                balloonMB = & $statsOf (& $find 'host' $h.id 'mem.vmmemctl.average') (1 / 1024)
                swapinKBps = & $statsOf (& $find 'host' $h.id 'mem.swapinRate.average')
                dropsRx = & $sum $rx; dropsTx = & $sum $tx
            } })
    $vmPerf = @(foreach ($v in $vmInfo.Values | Sort-Object name) {
            # cpu.ready.summation: ms listos-sin-CPU por intervalo, sumados entre vCPUs → % por vCPU.
            $scale = 100 / ($win.i * 1000) / [math]::Max(1, $v.vcpu)
            [pscustomobject]@{
                name = $v.name; cluster = $v.cluster; host = $v.host; vcpu = $v.vcpu; memMB = $v.memMB
                readyPct = & $statsOf (& $find 'vm' $v.id 'cpu.ready.summation') $scale
                cpuUsagePct = & $statsOf (& $find 'vm' $v.id 'cpu.usage.average') 0.01        # centésimas de %
                memActiveMB = & $statsOf (& $find 'vm' $v.id 'mem.active.average') (1 / 1024)
                balloonMB = & $statsOf (& $find 'vm' $v.id 'mem.vmmemctl.average') (1 / 1024)
                swapinKBps = & $statsOf (& $find 'vm' $v.id 'mem.swapinRate.average')
            } })
    # Instancia = UUID del datastore. Se ignoran '*' y las series vacías (p. ej. el simulador vcsim no publica latencias).
    $dsPerf = @(foreach ($g in @($series | Where-Object { $_.kind -eq 'hostds' -and $_.instance -and $_.instance -ne '*' -and $_.valid -gt 0 } | Group-Object entity, instance)) {
            $f = $g.Group[0]; $h = $hostInfo[$f.entity]
            $rd = $g.Group | Where-Object counter -eq 'datastore.totalReadLatency.average' | Select-Object -First 1
            $wr = $g.Group | Where-Object counter -eq 'datastore.totalWriteLatency.average' | Select-Object -First 1
            [pscustomobject]@{
                datastore = $(if ($dsName[$f.instance]) { $dsName[$f.instance] } else { $f.instance }); host = $(if ($h) { $h.name } else { $f.entity }); cluster = $(if ($h) { $h.cluster } else { '' })
                readMs = & $statsOf $rd; writeMs = & $statsOf $wr
            } })

    # Contadores sin ningún dato en la ventana (nivel de estadísticas del intervalo u otra causa).
    $present = @{}; foreach ($s in $series) { if ($s.valid -gt 0) { $present["$($s.kind)|$($s.counter)"] = $true } }
    $expected = @($hostAggCounters | ForEach-Object { "host|$_" }) + @($hostDsCounters | ForEach-Object { "hostds|$_" }) + @($vmCounters | ForEach-Object { "vm|$_" })
    $kindsRun = @($jobs.kind | Sort-Object -Unique)
    $kindLabel = @{ host = 'hosts'; hostds = 'hosts'; vm = 'VMs' }
    $missing = @($expected | Where-Object { ($_ -split '\|')[0] -in $kindsRun -and -not $present[$_] } |
        ForEach-Object { $k, $c = $_ -split '\|'; "$c ($($kindLabel[$k]))" } | Sort-Object -Unique)
    $lvl = @($levels | Where-Object { $_.period -eq $win.i } | Select-Object -First 1)
    $extra = [ordered]@{ window = $Window; interval = $win.i; samples = $win.n; intervalLevel = $(if ($lvl) { $lvl[0].level } else { $null }); cluster = @($Cluster); missing = $missing }
    Write-RunMeta (Join-Path $rawDir 'meta-perf.json') $Env $generated $extra
    $meta = [pscustomobject]$extra
    Save-RawJson $hostPerf (Join-Path $rawDir 'perf-host.json')
    Save-RawJson $vmPerf (Join-Path $rawDir 'perf-vm.json')
    Save-RawJson $dsPerf (Join-Path $rawDir 'perf-datastore.json')
    Save-RawJson $errors (Join-Path $rawDir 'perf-errors.json')
}

# --- Análisis ---------------------------------------------------------------------------
$findings = New-FindingList
$review = "./scripts/Invoke-PerfCheck.ps1 -Env $Env -Window 1h"
$intervalS = [int](P $meta 'interval' 0)
$nOrNull = { param($s, $k) if ($s -and $null -ne (P $s $k)) { [double]$s.$k } else { $null } }
function Add-Group($sev, $hit, $label, $rule) {
    Add-GroupedFinding -List $findings -Severity $sev -Category 'Rendimiento' -Items $hit -Label $label -Suggestion (Get-FindingText $rule $sev) -Command $review -Rule $rule
}

# CPU ready por vCPU (p95).
$ready = @($vmPerf | ForEach-Object { $p = & $nOrNull $_.readyPct 'p95'; if ($null -ne $p) { [pscustomobject]@{ name = $_.name; p95 = $p; text = "$($_.name) ($p %)" } } } | Sort-Object p95 -Descending)
Add-Group 'Crítico' @($ready | Where-Object { $_.p95 -ge $CpuReadyCritPct }) "CPU ready p95 ≥ $CpuReadyCritPct % por vCPU" 'perf-cpu-ready'
Add-Group 'Advertencia' @($ready | Where-Object { $_.p95 -ge $CpuReadyWarnPct -and $_.p95 -lt $CpuReadyCritPct }) "CPU ready p95 ≥ $CpuReadyWarnPct % por vCPU" 'perf-cpu-ready'

# Ballooning y swap de VMs en la ventana.
$bal = @($vmPerf | ForEach-Object { $m = & $nOrNull $_.balloonMB 'max'; if ($m -gt 0) { [pscustomobject]@{ name = $_.name; text = "$($_.name) (máx. $([math]::Round($m)) MB)" } } })
Add-Group 'Advertencia' $bal 'Ballooning en la ventana' 'perf-balloon'
$swSust = @($vmPerf | ForEach-Object { $p = & $nOrNull $_.swapinKBps 'p95'; if ($p -gt 0) { [pscustomobject]@{ name = $_.name; text = "$($_.name) (p95 $p KB/s)" } } })
$swPeak = @($vmPerf | ForEach-Object { $p = & $nOrNull $_.swapinKBps 'p95'; $m = & $nOrNull $_.swapinKBps 'max'; if ($m -gt 0 -and -not ($p -gt 0)) { [pscustomobject]@{ name = $_.name; text = "$($_.name) (máx. $m KB/s)" } } })
Add-Group 'Advertencia' $swSust 'Swap-in sostenido del hipervisor' 'perf-swap'
Add-Group 'Info' $swPeak 'Swap-in puntual del hipervisor' 'perf-swap'

# Right-sizing: VMs sobredimensionadas según su uso p95 en la ventana. Con 1h la muestra no es representativa.
# CPU: objetivo p95 ≤ 60 % con las vCPU sugeridas. RAM: el doble de la activa p95 (mem.active subestima el uso real).
$canSize = $Window -ne '1h'
$hasUsage = @($vmPerf | Where-Object { $null -ne (P $_ 'cpuUsagePct') -or $null -ne (P $_ 'memActiveMB') }).Count -gt 0
$sizing = @(if ($canSize) {
        foreach ($v in $vmPerf) {
            $cpu = & $nOrNull (P $v 'cpuUsagePct') 'p95'; $act = & $nOrNull (P $v 'memActiveMB') 'p95'
            $vc = [int]$v.vcpu; $mem = [double](P $v 'memMB' 0)
            $vcNew = if ($null -ne $cpu -and $vc -ge 2 -and $cpu -lt $RightSizeCpuPct) { [int][math]::Max(1, [math]::Ceiling($vc * $cpu / 60)) } else { $vc }
            $memNew = if ($null -ne $act -and $mem -ge 4096 -and $act -lt $mem * $RightSizeMemPct / 100) { [math]::Max(2048, [math]::Ceiling($act * 2 / 1024) * 1024) } else { $mem }
            if ($vcNew -lt $vc -or $memNew -lt $mem) {
                $gb = { param($mb) [math]::Round($mb / 1024, 1) }
                [pscustomobject]@{
                    name = $v.name; cluster = $v.cluster; host = $v.host; vcpu = $vc; cpuP95 = $cpu; vcpuNew = $vcNew
                    memGB = & $gb $mem; actGB = $(if ($null -ne $act) { & $gb $act } else { $null }); memNewGB = & $gb $memNew
                    vcpuFree = $vc - $vcNew; memFreeGB = & $gb ($mem - $memNew)
                    text = "$($v.name) ($vc→$vcNew vCPU, $(& $gb $mem)→$(& $gb $memNew) GB)"
                }
            }
        } })
$sizing = @($sizing | Sort-Object { $_.vcpuFree * 4 + $_.memFreeGB } -Descending)
Add-GroupedFinding -List $findings -Severity 'Info' -Category 'Capacidad' -Items $sizing -Label "Uso p95 bajo en la ventana $Window" -Suggestion (Get-FindingText 'perf-oversized') -Command $review -Rule 'perf-oversized'

# CPU de hosts (p95) y caídas de red.
foreach ($h in $hostPerf | Where-Object ok) {
    $p = & $nOrNull $h.cpuPct 'p95'
    if ($null -ne $p) {
        $ev = "CPU p95 $p % (promedio $(& $nOrNull $h.cpuPct 'avg') %, máx. $(& $nOrNull $h.cpuPct 'max') %)"
        if ($p -ge $HostCpuCritPct) { Add-ReportFinding -Rule 'perf-host-cpu' $findings 'Crítico' 'Rendimiento' $h.name $ev (Get-FindingText 'perf-host-cpu' 'Crítico') $review }
        elseif ($p -ge $HostCpuWarnPct) { Add-ReportFinding -Rule 'perf-host-cpu' $findings 'Advertencia' 'Rendimiento' $h.name $ev (Get-FindingText 'perf-host-cpu' 'Advertencia') $review }
    }
    $drops = [long](P $h 'dropsRx' 0) + [long](P $h 'dropsTx' 0)
    if ($drops -gt 0) { Add-ReportFinding -Rule 'perf-net-drops' $findings 'Advertencia' 'Rendimiento' $h.name "Paquetes descartados en la ventana: recepción $([long](P $h 'dropsRx' 0)), transmisión $([long](P $h 'dropsTx' 0))" (Get-FindingText 'perf-net-drops') $review }
}

# Latencia por datastore: peor host (p95 de lectura o escritura).
$dsRows = @(@(foreach ($g in ($dsPerf | Group-Object datastore)) {
        $rows = @($g.Group | ForEach-Object {
                $r = & $nOrNull $_.readMs 'p95'; $w2 = & $nOrNull $_.writeMs 'p95'
                [pscustomobject]@{ host = $_.host; cluster = $_.cluster; read = $r; write = $w2; worst = [math]::Max([double]$(if ($null -ne $r) { $r } else { 0 }), [double]$(if ($null -ne $w2) { $w2 } else { 0 })); max = [math]::Max([double](& $nOrNull $_.readMs 'max'), [double](& $nOrNull $_.writeMs 'max')) } })
        $top = $rows | Sort-Object worst -Descending | Select-Object -First 1
        [pscustomobject]@{ datastore = $g.Name; host = $top.host; cluster = $top.cluster; readP95 = $top.read; writeP95 = $top.write; worstP95 = $top.worst; maxMs = ($rows | Measure-Object max -Maximum).Maximum; hosts = $rows.Count }
    }) | Sort-Object worstP95 -Descending)
foreach ($d in $dsRows) {
    $ev = "Latencia p95 $($d.worstP95) ms (lectura $($d.readP95) / escritura $($d.writeP95) ms) en $($d.host); máx. $($d.maxMs) ms"
    if ($d.worstP95 -ge $DsLatencyCritMs) { Add-ReportFinding -Rule 'perf-ds-latency' $findings 'Crítico' 'Rendimiento' $d.datastore $ev (Get-FindingText 'perf-ds-latency' 'Crítico') $review }
    elseif ($d.worstP95 -ge $DsLatencyWarnMs) { Add-ReportFinding -Rule 'perf-ds-latency' $findings 'Advertencia' 'Rendimiento' $d.datastore $ev (Get-FindingText 'perf-ds-latency' 'Advertencia') $review }
}

# Cobertura: contadores sin datos, hosts sin consulta y consultas con error.
$missingNow = @(P $meta 'missing' @())
if ($missingNow.Count) {
    $lv = P $meta 'intervalLevel'
    Add-ReportFinding -Rule 'coverage-perf-counters' $findings 'Info' 'Cobertura' 'Contadores de rendimiento' "Sin datos en la ventana $Window (intervalo $intervalS s$(if ($null -ne $lv) { ", nivel de estadísticas $lv" })): $($missingNow -join ', ')" (Get-FindingText 'coverage-perf-counters')
}
$down = @($hostPerf | Where-Object { -not $_.ok })
if ($down.Count) { Add-ReportFinding -Rule 'coverage-perf-hosts' $findings 'Info' 'Cobertura' $(if ($down.Count -eq 1) { $down[0].name } else { "$($down.Count) hosts" }) "Hosts sin métricas: $((($down | ForEach-Object { "$($_.name) ($($_.error))" })) -join ', ')" (Get-FindingText 'coverage-perf-hosts') }
foreach ($g in @($errors | Group-Object { ("$($_.error)" -replace '<.*$', '').Trim() })) {
    $n = Get-Sum $g.Group 'entities'
    Add-ReportFinding -Rule 'coverage-perf-error' $findings 'Info' 'Cobertura' "$n entidades" "Consulta de métricas fallida ($((@($g.Group.kind | Sort-Object -Unique)) -join ', ')): $($g.Name)" (Get-FindingText 'coverage-perf-error')
}

# VMs expuestas en hallazgos de host: VMs evaluadas en ese host.
$exposed = @{}; foreach ($v in $vmPerf) { if ($v.host) { $exposed["$($v.host)"] = 1 + [int]$exposed["$($v.host)"] } }
Set-FindingImpact $findings $exposed

$sorted = Sort-ReportFinding $findings

# --- Secciones ----------------------------------------------------------------------------
$fmt = { param($s, $k) $v = & $nOrNull $s $k; if ($null -ne $v) { $v } else { '' } }
# Panel de rendimiento: lo peor de la ventana y cuántos superan cada umbral. La barra llega al 100 % en el umbral crítico.
$hostCpu = @($hostPerf | Where-Object ok | ForEach-Object { $p = & $nOrNull $_.cpuPct 'p95'; if ($null -ne $p) { [pscustomobject]@{ name = $_.name; p95 = $p } } } | Sort-Object p95 -Descending)
$perfCards = New-Object System.Collections.Generic.List[object]
$worstCard = {
    param($key, $label, $rows, $prop, $unit, $warn, $crit, $what, $nameProp = 'name')
    if (-not @($rows).Count) { $perfCards.Add((New-PanelCard -Key $key -Label $label -Value '—' -Note 'sin datos en la ventana')); return }
    $top = @($rows)[0]; $v = [double]$top.$prop
    $over = @($rows | Where-Object { [double]$_.$prop -ge $warn }).Count
    $perfCards.Add((New-PanelCard -Key $key -Label $label -Value ('{0:0.#} {1}' -f $v, $unit) -Number $v -Pct (100 * $v / $crit) -Level (Get-MetricLevel $v $warn $crit) `
                -Note "$($top.$nameProp) · $over de $(@($rows).Count) $what ≥ $warn $unit"))
}
& $worstCard 'perf-ready-worst' 'CPU ready p95 (peor VM)' $ready 'p95' '%' $CpuReadyWarnPct $CpuReadyCritPct 'VMs'
& $worstCard 'perf-ds-worst' 'Latencia p95 (peor datastore)' $dsRows 'worstP95' 'ms' $DsLatencyWarnMs $DsLatencyCritMs 'datastores' 'datastore'
& $worstCard 'perf-host-worst' 'CPU p95 (peor host)' $hostCpu 'p95' '%' $HostCpuWarnPct $HostCpuCritPct 'hosts'
$memHit = @(@($bal) + @($swSust) | Where-Object { $_ } | Select-Object -ExpandProperty name -Unique).Count
$perfCards.Add((New-PanelCard -Key 'perf-mem-pressure' -Label 'VMs con balloon o swap sostenido' -Value "$memHit" -Number $memHit -Level $(if ($memHit) { 'warn' } else { 'ok' }) -Note "de $($vmPerf.Count) VMs evaluadas"))
foreach ($t in @(
        @{ g = 'Más CPU ready (p95)'; rows = $ready; prop = 'p95'; unit = '%'; warn = $CpuReadyWarnPct; crit = $CpuReadyCritPct }
        @{ g = 'Más latencia (p95)'; rows = $dsRows; prop = 'worstP95'; unit = 'ms'; warn = $DsLatencyWarnMs; crit = $DsLatencyCritMs; nameProp = 'datastore' }
        @{ g = 'Más CPU de host (p95)'; rows = $hostCpu; prop = 'p95'; unit = '%'; warn = $HostCpuWarnPct; crit = $HostCpuCritPct })) {
    foreach ($r in @($t.rows | Select-Object -First 5)) {
        $v = [double]$r.($t.prop); $np = $t['nameProp'] ?? 'name'
        $perfCards.Add((New-PanelCard -Group $t.g -Label $r.$np -Value ('{0:0.#} {1}' -f $v, $t.unit) -Number $v -Pct (100 * $v / $t.crit) -Level (Get-MetricLevel $v $t.warn $t.crit) `
                    -Note $(if ($np -eq 'datastore') { "peor host: $($r.host)" } else { '' })))
    }
}
# Panel de capacidad recuperable (right-sizing).
$reclaimCards = if (-not $canSize) { @(New-PanelCard -Key 'perf-reclaim-vcpu' -Label 'vCPU recuperables' -Value '—' -Note 'requiere ventana 24h o 7d') }
elseif (-not $hasUsage) { @(New-PanelCard -Key 'perf-reclaim-vcpu' -Label 'vCPU recuperables' -Value '—' -Note 'sin datos de uso en esta corrida') }
else {
    $vcTotal = [double](Get-Sum $vmPerf 'vcpu'); $memTotal = (Get-Sum $vmPerf 'memMB') / 1024
    $vcFree = [int](Get-Sum $sizing 'vcpuFree'); $memFree = [math]::Round([double](Get-Sum $sizing 'memFreeGB'), 1)
    $vcP = Get-Percent $vcFree $vcTotal; $memP = Get-Percent $memFree $memTotal
    @(
        New-PanelCard -Key 'perf-reclaim-vcpu' -Label 'vCPU recuperables' -Value "$vcFree" -Number $vcFree -Pct $vcP -Note "$(Format-Percent $vcP) de $vcTotal vCPU evaluadas"
        New-PanelCard -Key 'perf-reclaim-mem' -Label 'RAM recuperable' -Value ('{0:0.#} GB' -f $memFree) -Number $memFree -Pct $memP -Note "$(Format-Percent $memP) de $([math]::Round($memTotal)) GB asignados"
        New-PanelCard -Key 'perf-oversized' -Label 'VMs sobredimensionadas' -Value "$($sizing.Count)" -Number $sizing.Count -Note "de $($vmPerf.Count) VMs evaluadas"
        foreach ($s in @($sizing | Select-Object -First 5)) {
            New-PanelCard -Group 'Más recuperables' -Label $s.name -Value "−$($s.vcpuFree) vCPU · −$($s.memFreeGB) GB" `
                -Note "CPU p95 $(if ($null -ne $s.cpuP95) { "$($s.cpuP95) %" } else { '—' }) · RAM activa $(if ($null -ne $s.actGB) { "$($s.actGB) GB" } else { '—' })"
        }
    )
}
$sections = New-Object System.Collections.Generic.List[object]
$sections.Add((New-ReportPanel 'Rendimiento' $perfCards.ToArray() "Ventana $Window. La barra llega al 100 % en el umbral crítico de cada métrica."))
$sections.Add((New-ReportPanel 'Capacidad recuperable' $reclaimCards "Right-sizing con el uso p95 de la ventana: CPU p95 < $RightSizeCpuPct % y RAM activa p95 < $RightSizeMemPct % de lo asignado. Cambiar vCPU o RAM requiere reinicio."))
$sections.Add((New-ReportTable 'Hallazgos y sugerencias' (Get-FindingColumns) $sorted (Get-NoteText 'perf-table' -Vars @{ window = $Window })))
if ($sizing.Count) {
    $sections.Add((New-ReportTable 'Right-sizing' @('name:VM', 'cluster:Clúster', 'vcpu:vCPU', 'cpuP95:CPU p95 %', 'vcpuNew:vCPU sugeridas', 'memGB:RAM GB', 'actGB:RAM activa p95 GB', 'memNewGB:RAM sugerida GB') $sizing 'vCPU sugeridas para un p95 ≤ 60 %; RAM sugerida = 2 × activa p95 (mínimo 2 GB).'))
}
$sections.Add((New-ReportTable 'Hosts' @('cluster:Clúster', 'name:Host', 'cpuAvg:CPU prom. %', 'cpuP95:CPU p95 %', 'cpuMax:CPU máx. %', 'balloon:Balloon máx. MB', 'drops:Paquetes descartados') @($hostPerf | Where-Object ok | ForEach-Object {
                [pscustomobject]@{ cluster = $_.cluster; name = $_.name; cpuAvg = & $fmt $_.cpuPct 'avg'; cpuP95 = & $fmt $_.cpuPct 'p95'; cpuMax = & $fmt $_.cpuPct 'max'; balloon = & $fmt $_.balloonMB 'max'; drops = $(if ($null -ne (P $_ 'dropsRx') -or $null -ne (P $_ 'dropsTx')) { [long](P $_ 'dropsRx' 0) + [long](P $_ 'dropsTx' 0) } else { '' }) } }) "Umbrales de CPU: advertencia ≥ $HostCpuWarnPct %, crítico ≥ $HostCpuCritPct % (p95)."))
$sections.Add((New-ReportTable 'Latencia por datastore' @('datastore:Datastore', 'host:Peor host', 'readP95:Lectura p95 ms', 'writeP95:Escritura p95 ms', 'maxMs:Máx. ms', 'hosts:Hosts') $dsRows "Umbrales: advertencia ≥ $DsLatencyWarnMs ms, crítico ≥ $DsLatencyCritMs ms (p95 del peor host)."))
$sections.Add((New-ReportTable 'VMs con más CPU ready' @('name:VM', 'cluster:Clúster', 'host:Host', 'vcpu:vCPU', 'avg:Ready prom. %', 'p95:Ready p95 %', 'max:Ready máx. %') @($vmPerf | Where-Object { $null -ne (& $nOrNull $_.readyPct 'p95') } | Sort-Object { [double]$_.readyPct.p95 } -Descending | Select-Object -First 25 | ForEach-Object {
                [pscustomobject]@{ name = $_.name; cluster = $_.cluster; host = $_.host; vcpu = $_.vcpu; avg = & $fmt $_.readyPct 'avg'; p95 = & $fmt $_.readyPct 'p95'; max = & $fmt $_.readyPct 'max' } }) "Porcentaje por vCPU. Umbrales: advertencia ≥ $CpuReadyWarnPct %, crítico ≥ $CpuReadyCritPct % (p95)."))
$sections.Add((New-ReportTable 'VMs con ballooning o swap' @('name:VM', 'cluster:Clúster', 'host:Host', 'balloon:Balloon máx. MB', 'swapP95:Swap-in p95 KB/s', 'swapMax:Swap-in máx. KB/s') @($vmPerf | Where-Object { (& $nOrNull $_.balloonMB 'max') -gt 0 -or (& $nOrNull $_.swapinKBps 'max') -gt 0 } | ForEach-Object {
                [pscustomobject]@{ name = $_.name; cluster = $_.cluster; host = $_.host; balloon = & $fmt $_.balloonMB 'max'; swapP95 = & $fmt $_.swapinKBps 'p95'; swapMax = & $fmt $_.swapinKBps 'max' } })))

$kpis = [ordered]@{
    'Ventana'       = $Window
    'Intervalo (s)' = $intervalS
    'Hosts'         = @($hostPerf | Where-Object ok).Count
    'VMs evaluadas' = $vmPerf.Count
}
Add-SeverityKpis $kpis $sorted -Coverage
Complete-Report -Root $root -OutDir $outDir -RawDir $rawDir -BaseName 'perf-check' -Title "Revisión de rendimiento — $($Env.ToUpper()) — $Window" `
    -Env $Env -Generated $generated -Kpis $kpis -Sorted $sorted -Sections $sections.ToArray() -Format $Format -MdMaxRows $MdMaxRows `
    -Source 'govc metric.sample (solo lectura)'
