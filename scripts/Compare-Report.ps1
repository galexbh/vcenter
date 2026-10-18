<#
.SYNOPSIS
  Tendencias entre dos corridas: cambios de inventario, crecimiento de datastores y evolución de hallazgos.

.DESCRIPTION
  Compara los datos crudos (raw/) de dos ejecuciones de New-Report.ps1, o de dos auditorías
  (Invoke-Audit.ps1, carpeta inventario/), sin consultar vCenter. Reporta:
    - VMs nuevas, eliminadas, renombradas y con cambio de estado de energía.
    - Variación de vCPU y RAM asignadas (VMs encendidas) por clúster.
    - Crecimiento de datastores (GB/día) y días estimados hasta 90 % y 100 % (proyección lineal).
    - Snapshots nuevos y eliminados.
    - Hallazgos nuevos y resueltos (por regla y objeto).

.EXAMPLE
  ./scripts/Compare-Report.ps1 -Env prod                      # las dos corridas más recientes
  ./scripts/Compare-Report.ps1 -Base reports/prod/20261001-080000 -Current reports/prod/20261017-080000
#>
#Requires -Version 7.5
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$Env,
    [string]$Base,
    [string]$Current,
    [string]$OutDir,
    [ValidateSet('html', 'md', 'csv')][string[]]$Format = @('html', 'md'),
    [ValidateRange(1, 100000)][int]$MdMaxRows = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Render.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Set-Alias -Name P -Value Get-Prop -Scope Script
$inv = [Globalization.CultureInfo]::InvariantCulture
$fmt = { param([string]$f, $v) [string]::Format($inv, $f, $v) }
function Resolve-Run([string]$dir) {
    # Acepta una corrida de New-Report o una auditoría (subcarpeta inventario/).
    $d = (Resolve-Path $dir).Path
    if (Test-Path (Join-Path $d 'raw/vms.json')) { return $d }
    if (Test-Path (Join-Path $d 'inventario/raw/vms.json')) { return (Join-Path $d 'inventario') }
    throw "No hay datos de inventario (raw/vms.json) en $dir"
}
function Load-Run([string]$dir) {
    $raw = Join-Path $dir 'raw'
    $j = { param($n) Read-JsonFile (Join-Path $raw "$n.json") @() -AsArray }
    $meta = Get-Content -LiteralPath (Join-Path $raw 'meta.json') -Raw | ConvertFrom-Json
    Assert-EnvName "$($meta.env)"
    [pscustomobject]@{ dir = $dir; env = $meta.env; generated = [datetime]$meta.generated; vms = (& $j 'vms'); hosts = (& $j 'hosts'); compute = (& $j 'compute'); datastores = (& $j 'datastores'); findings = (& $j 'findings') }
}

if ($Env -and -not ($Base -and $Current)) {
    $runs = @(Get-ChildItem (Join-Path $root "reports/$($Env.ToLowerInvariant())") -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'tendencia' } |
        Where-Object { (Test-Path (Join-Path $_.FullName 'raw/vms.json')) -or (Test-Path (Join-Path $_.FullName 'inventario/raw/vms.json')) } |
        Sort-Object Name)
    if ($runs.Count -lt 2) { throw "Se necesitan al menos dos corridas con inventario en reports/$Env (hay $($runs.Count))." }
    $Base = $runs[-2].FullName; $Current = $runs[-1].FullName
}
if (-not ($Base -and $Current)) { throw 'Indica -Env <entorno>, o -Base y -Current.' }

$a = Load-Run (Resolve-Run $Base)
$b = Load-Run (Resolve-Run $Current)
if ($a.env -ne $b.env) { throw "Las corridas son de entornos distintos ($($a.env) / $($b.env))." }
if ($b.generated -le $a.generated) { $t = $a; $a = $b; $b = $t }   # base siempre la más antigua
$days = [math]::Round(($b.generated - $a.generated).TotalDays, 2)
$Env = $b.env
$rc = { param([string[]]$a) New-ReviewCommand -Env $Env -Arguments $a }

# --- VMs ---------------------------------------------------------------------------
$vmA = @{}; foreach ($v in $a.vms) { if (-not [bool](P $v 'config.template' $false)) { $vmA[$v._moref] = $v } }
$vmB = @{}; foreach ($v in $b.vms) { if (-not [bool](P $v 'config.template' $false)) { $vmB[$v._moref] = $v } }
$vmChanges = New-Object System.Collections.Generic.List[object]
foreach ($k in $vmB.Keys) {
    $v = $vmB[$k]
    if (-not $vmA.ContainsKey($k)) { $vmChanges.Add([pscustomobject]@{ change = 'Nueva'; vm = $v.name; detail = "$(P $v 'summary.config.numCpu' 0) vCPU · $(P $v 'summary.config.memorySizeMB' 0) MB · $(P $v 'runtime.powerState' '')" }); continue }
    $o = $vmA[$k]
    if ($o.name -ne $v.name) { $vmChanges.Add([pscustomobject]@{ change = 'Renombrada'; vm = $v.name; detail = "antes: $($o.name)" }) }
    if ((P $o 'runtime.powerState') -ne (P $v 'runtime.powerState')) { $vmChanges.Add([pscustomobject]@{ change = 'Estado'; vm = $v.name; detail = "$(P $o 'runtime.powerState') → $(P $v 'runtime.powerState')" }) }
    $dc = [int](P $v 'summary.config.numCpu' 0) - [int](P $o 'summary.config.numCpu' 0); $dm = [int](P $v 'summary.config.memorySizeMB' 0) - [int](P $o 'summary.config.memorySizeMB' 0)
    if ($dc -or $dm) { $vmChanges.Add([pscustomobject]@{ change = 'Recursos'; vm = $v.name; detail = "vCPU $(& $fmt '{0:+0;-0;0}' $dc) · RAM $(& $fmt '{0:+0;-0;0}' $dm) MB" }) }
}
foreach ($k in $vmA.Keys) { if (-not $vmB.ContainsKey($k)) { $vmChanges.Add([pscustomobject]@{ change = 'Eliminada'; vm = $vmA[$k].name; detail = '' }) } }
$order = @{ 'Nueva' = 0; 'Eliminada' = 1; 'Renombrada' = 2; 'Estado' = 3; 'Recursos' = 4 }
$vmChanges = @($vmChanges | Sort-Object { $order[$_.change] }, vm)

# --- Capacidad por clúster -----------------------------------------------------------
function Get-ClusterUse($run) {
    $hostParent = @{}; foreach ($h in $run.hosts) { $par = P $h 'parent'; if ($par) { $hostParent[$h._moref] = $par.value } }
    $name = @{}; foreach ($c in $run.compute) { $name[$c._moref] = $c.name }
    $res = @{}
    foreach ($v in $run.vms) {
        if ([bool](P $v 'config.template' $false) -or (P $v 'runtime.powerState') -ne 'poweredOn') { continue }
        $rh = P $v 'runtime.host'; $hid = if ($rh) { P $rh 'value' } else { $null }   # VM huérfana: sin host
        $cn = $name[$hostParent[$hid]]; if (-not $cn) { continue }
        if (-not $res[$cn]) { $res[$cn] = @{ vcpu = 0; mem = 0.0 } }
        $res[$cn].vcpu += [int](P $v 'summary.config.numCpu' 0); $res[$cn].mem += [double](P $v 'summary.config.memorySizeMB' 0) / 1024
    }
    return $res
}
$ca = Get-ClusterUse $a; $cb = Get-ClusterUse $b
$clusterRows = @(@($ca.Keys) + @($cb.Keys) | Sort-Object -Unique | ForEach-Object {
        $x = $ca[$_]; $y = $cb[$_]
        $v0 = if ($x) { $x.vcpu } else { 0 }; $v1 = if ($y) { $y.vcpu } else { 0 }
        $m0 = if ($x) { [math]::Round($x.mem, 1) } else { 0 }; $m1 = if ($y) { [math]::Round($y.mem, 1) } else { 0 }
        [pscustomobject]@{ cluster = $_; vcpuBase = $v0; vcpuNow = $v1; vcpuDelta = (& $fmt '{0:+0;-0;0}' ($v1 - $v0)); memBase = $m0; memNow = $m1; memDelta = (& $fmt '{0:+0.0;-0.0;0}' ($m1 - $m0)) } })

# --- Datastores ------------------------------------------------------------------------
$dsA = @{}; foreach ($d in $a.datastores) { $dsA[$d._moref] = $d }
$findings = New-FindingList
$dsRows = @(foreach ($d in $b.datastores) {
        $cap = [double](P $d 'summary.capacity' 0); if (-not $cap) { continue }
        $used1 = ($cap - [double](P $d 'summary.freeSpace' 0)) / 1GB
        $o = $dsA[$d._moref]
        $used0 = if ($o) { ([double](P $o 'summary.capacity' 0) - [double](P $o 'summary.freeSpace' 0)) / 1GB } else { $null }
        $rate = if ($null -ne $used0 -and $days -gt 0) { ($used1 - $used0) / $days } else { $null }
        $capGB = $cap / 1GB
        # Sin crecimiento (+∞) se muestra como «sin crecimiento», igual que sin dato de días.
        $days90 = Get-DaysToPct -CapGB $capGB -UsedGB $used1 -RatePerDay $rate -Pct 90; $days100 = Get-DaysToPct -CapGB $capGB -UsedGB $used1 -RatePerDay $rate -Pct 100
        $to90 = if ($null -ne $days90 -and -not [double]::IsPositiveInfinity($days90)) { $days90 } else { $null }
        $to100 = if ($null -ne $days100 -and -not [double]::IsPositiveInfinity($days100)) { $days100 } else { $null }
        if ($null -ne $to90 -and $to90 -le 30) {
            $sev = if ($to90 -le 7) { 'Crítico' } else { 'Advertencia' }
            Add-ReportFinding $findings $sev 'Almacenamiento' $d.name "Al ritmo actual ($([math]::Round($rate,1)) GB/día) llega al 90 % en ~$to90 días" (Get-FindingText 'ds-trend' $sev) (& $rc 'datastore.info', "Datastore:$($d._moref)") -Rule 'ds-trend'
        }
        [pscustomobject]@{
            name = $d.name; capGB = [math]::Round($capGB, 0); usedBase = $(if ($null -ne $used0) { [math]::Round($used0, 1) } else { 'nuevo' }); usedNow = [math]::Round($used1, 1)
            usedPct = Get-Percent $used1 $capGB; rate = $(if ($null -ne $rate) { [math]::Round($rate, 2) } else { '' })
            to90 = $(if ($null -ne $to90) { $to90 } elseif ($null -ne $rate) { 'sin crecimiento' } else { '' }); to100 = $(if ($null -ne $to100) { $to100 } else { '' })
        } })
$dsRows = @($dsRows | Sort-Object { if ($_.to90 -is [int] -or $_.to90 -is [double]) { [double]$_.to90 } else { [double]::MaxValue } }, name)

# --- Snapshots ----------------------------------------------------------------------------
function Get-Snaps($run) {
    $out = @{}
    foreach ($v in $run.vms) {
        foreach ($s in (Get-SnapshotList (P $v 'snapshot.rootSnapshotList' @()))) {
            $id = if ($s.moref) { $s.moref } else { $s.name }
            $out["$($v._moref)|$id"] = [pscustomobject]@{ vm = $v.name; name = $s.name; created = $(if ($s.created) { $s.created.LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '' }) }
        }
    }
    return $out
}
$sa = Get-Snaps $a; $sb = Get-Snaps $b
$snapRows = @(@(
    @($sb.Keys | Where-Object { -not $sa.ContainsKey($_) } | ForEach-Object { $sb[$_] | Select-Object @{ n = 'change'; e = { 'Nuevo' } }, vm, name, created })
    @($sa.Keys | Where-Object { -not $sb.ContainsKey($_) } | ForEach-Object { $sa[$_] | Select-Object @{ n = 'change'; e = { 'Eliminado' } }, vm, name, created })
) | Sort-Object change, vm)

# --- Hallazgos ------------------------------------------------------------------------------
# Clave regla|objeto. Las corridas anteriores a 1.8 usaban reglas con el nombre incluido
# (snap-age-<snapshot>, alarm-<alarma>, license-<edición>): se traducen a la forma actual.
$key = {
    param($f)
    $r = "$(P $f 'rule' (P $f 'category' ''))"; $o = "$($f.object)"
    if ($r -like 'snap-age-*' -and $o -notmatch ' / ') { return "snap-age|$o / $($r.Substring(9))" }
    if ($r -like 'alarm-*' -and $o -notmatch ' / ') { return "alarm|$o / $($r.Substring(6))" }
    if ($r -like 'license-*') { return "license|$o" }
    "$r|$o"
}
$fa = @{}; foreach ($f in $a.findings) { $fa[(& $key $f)] = $f }
$fb = @{}; foreach ($f in $b.findings) { $fb[(& $key $f)] = $f }
$findRows = @(@(
    @($fb.Keys | Where-Object { -not $fa.ContainsKey($_) } | ForEach-Object { $f = $fb[$_]; [pscustomobject]@{ change = 'Nuevo'; severity = $f.severity; category = $f.category; object = $f.object; evidence = $f.evidence } })
    @($fa.Keys | Where-Object { -not $fb.ContainsKey($_) } | ForEach-Object { $f = $fa[$_]; [pscustomobject]@{ change = 'Resuelto'; severity = $f.severity; category = $f.category; object = $f.object; evidence = $f.evidence } })
    @($fb.Keys | Where-Object { $fa.ContainsKey($_) -and $fa[$_].severity -ne $fb[$_].severity } | ForEach-Object { [pscustomobject]@{ change = "Severidad $($fa[$_].severity) → $($fb[$_].severity)"; severity = $fb[$_].severity; category = $fb[$_].category; object = $fb[$_].object; evidence = $fb[$_].evidence } })
) | Sort-Object change, category, object)
$hasFindings = ($a.findings.Count + $b.findings.Count) -gt 0

# --- Salida -----------------------------------------------------------------------------------
$generated = Get-Date
$outDir = if ($OutDir) { $OutDir } else { Join-Path $root ("reports/{0}/{1:yyyyMMdd-HHmmss}-tendencia" -f $Env, $generated) }
$rawDir = Join-Path $outDir 'raw'
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null
$sorted = Sort-ReportFinding $findings
Write-RunMeta (Join-Path $rawDir 'meta.json') $Env $generated ([ordered]@{ base = $a.dir; current = $b.dir; days = $days })

$note = "Base: $($a.generated.ToString('yyyy-MM-dd HH:mm')) · Actual: $($b.generated.ToString('yyyy-MM-dd HH:mm')) · Intervalo: $days días."
$projNote = 'Proyección lineal con dos puntos: es una estimación. ' + $(if ($days -lt 7) { 'Con menos de 7 días entre corridas la proyección es poco confiable.' } else { 'Conviene confirmarla con más corridas.' })
$sections = @(
    (New-ReportTable 'Alertas de tendencia' (Get-FindingColumns) $sorted $note)
    (New-ReportTable 'Crecimiento de datastores' @('name:Datastore', 'capGB:Capacidad GB', 'usedBase:Usado base GB', 'usedNow:Usado actual GB', 'usedPct:Uso %', 'rate:GB/día', 'to90:Días a 90 %', 'to100:Días a 100 %') $dsRows $projNote)
    (New-ReportTable 'Asignación por clúster (VMs encendidas)' @('cluster:Clúster', 'vcpuBase:vCPU base', 'vcpuNow:vCPU actual', 'vcpuDelta:Δ vCPU', 'memBase:RAM base GB', 'memNow:RAM actual GB', 'memDelta:Δ RAM GB') $clusterRows)
    (New-ReportTable 'Cambios en VMs' @('change:Cambio', 'vm:VM', 'detail:Detalle') $vmChanges)
    (New-ReportTable 'Snapshots' @('change:Cambio', 'vm:VM', 'name:Snapshot', 'created:Creado') $snapRows)
)
if ($hasFindings) { $sections += New-ReportTable 'Evolución de hallazgos' @('change:Cambio', 'severity:Severidad', 'category:Categoría', 'object:Objeto', 'evidence:Evidencia') $findRows 'Un hallazgo se identifica por su regla y objeto; los cambios en la evidencia (p. ej. un porcentaje) no cuentan como hallazgo nuevo.' }

$kpis = [ordered]@{
    'Días entre corridas' = $days
    'VMs nuevas'          = @($vmChanges | Where-Object change -eq 'Nueva').Count
    'VMs eliminadas'      = @($vmChanges | Where-Object change -eq 'Eliminada').Count
    'Snapshots nuevos'    = @($snapRows | Where-Object change -eq 'Nuevo').Count
    'Hallazgos nuevos'    = @($findRows | Where-Object change -eq 'Nuevo').Count
    'Hallazgos resueltos' = @($findRows | Where-Object change -eq 'Resuelto').Count
    'Alertas'             = $sorted.Count
}
$res = Complete-Report -Root $root -OutDir $outDir -RawDir $rawDir -BaseName 'tendencia' -Title "Tendencias — $($Env.ToUpper())" -Env $Env -Generated $generated `
    -Kpis $kpis -Sorted $sorted -Sections $sections -Format $Format -MdMaxRows $MdMaxRows -Source 'comparación de corridas (sin consultar vCenter)'

[pscustomobject]@{ Carpeta = $outDir; Archivos = $res.Archivos; Base = $a.dir; Actual = $b.dir; Dias = $days }
