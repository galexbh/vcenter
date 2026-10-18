<#
.SYNOPSIS
  Auditoría técnica completa de un entorno vCenter (solo lectura) con informe formal HTML/MD.

.DESCRIPTION
  Orquesta cuatro fuentes y consolida sus hallazgos en un único modelo de auditoría:
    1. scripts/New-Report.ps1      inventario, capacidad (incluida la holgura N+1), snapshots,
                                   configuración de VMs y clústeres, certificado de vCenter y licencias.
    2. scripts/Invoke-HostCheck.ps1 configuración de cada host vía esxcli (drift, red, storage, NTP,
                                   syslog, servicios, certificados de host).
    3. scripts/Invoke-PerfCheck.ps1 rendimiento en una ventana (-PerfWindow, 24h por defecto): CPU ready,
                                   latencia de datastores, CPU de hosts, ballooning, swap. -SkipPerf la omite.
    4. Controles de acceso          permisos con rol Administrador en la raíz del inventario.
  Asigna ID (AUD-001…), dominio, riesgo y referencia a cada hallazgo; calcula un indicador por
  dominio y genera auditoria.html (imprimible / PDF) y auditoria.md a partir de templates/audit.*,
  más raw/audit.json con el modelo consolidado (incluye métricas clave, prioridad por hallazgo y la
  evolución frente a la auditoría anterior del mismo entorno). Si existe raw/analysis.md (redactado
  por Claude), se incluye en el resumen ejecutivo. El seguimiento con Compare-Report.ps1 compara las
  corridas de inventario (inventario/raw/), no audit.json.

.EXAMPLE
  ./scripts/Invoke-Audit.ps1 -Env prod
  ./scripts/Invoke-Audit.ps1 -Env prod -Cluster CL-PROD-01 -Scope security
  ./scripts/Invoke-Audit.ps1 -Env prod -Scope performance -PerfWindow 7d
  ./scripts/Invoke-Audit.ps1 -FromRaw reports/prod/20261017-090000-auditoria
#>
#Requires -Version 7.5
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$Env,
    [string[]]$Cluster,
    [ValidateSet('full', 'security', 'capacity', 'performance')][string]$Scope = 'full',
    [ValidateSet('1h', '24h', '7d')][string]$PerfWindow = '24h',
    [switch]$SkipPerf,         # omite la fuente de rendimiento (queda declarada como cobertura)
    [ValidateSet('html', 'md')][string[]]$Format = @('html', 'md'),
    [string]$FromRaw,
    [ValidateRange(0, 10000)][int]$MaxRootAdmins = 5,
    [switch]$SkipDeviceScan,   # se pasa a New-Report.ps1 (recomendado con miles de VMs)
    [string]$Version = '1.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/GovcJson.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Render.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Set-Alias -Name P -Value Get-Prop -Scope Script
Set-Alias -Name Read-Json -Value Read-JsonFile -Scope Script
$scripts = $PSScriptRoot

function Wait-SourceJob($Jobs) {
    # Espera las fuentes en paralelo; propaga la primera falla y nunca deja hilos vivos.
    $Jobs = @($Jobs | Where-Object { $_ })
    try {
        $null = $Jobs | Wait-Job
        foreach ($j in $Jobs) {
            if ($j.State -eq 'Failed') { throw "Falló '$($j.Name)': $($j.ChildJobs[0].JobStateInfo.Reason.Message)" }
            $null = Receive-Job $j -ErrorAction Stop
        }
    } finally {
        $Jobs | Stop-Job -ErrorAction SilentlyContinue
        $Jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

# --- Taxonomía de auditoría -----------------------------------------------------
$domains = @('Disponibilidad', 'Capacidad', 'Rendimiento', 'Configuración', 'Seguridad', 'Higiene')
$domainOf = @{
    'Hosts' = 'Disponibilidad'; 'Alarmas' = 'Disponibilidad'; 'Storage' = 'Disponibilidad'; 'Red física' = 'Disponibilidad'; 'Clúster' = 'Disponibilidad'
    'Almacenamiento' = 'Capacidad'; 'Capacidad' = 'Capacidad'
    'Rendimiento' = 'Rendimiento'
    'VMware Tools' = 'Configuración'; 'Drift VIBs/drivers' = 'Configuración'; 'Tiempo' = 'Configuración'; 'Diagnóstico' = 'Configuración'
    'Plataforma' = 'Configuración'; 'Configuración VM' = 'Configuración'; 'Licencias' = 'Configuración'
    'Seguridad' = 'Seguridad'; 'Logs' = 'Seguridad'; 'Certificados' = 'Seguridad'; 'Permisos' = 'Seguridad'
    'Snapshots' = 'Higiene'; 'Higiene' = 'Higiene'
}
# Riesgo y referencia por categoría: templates/findings.psd1 (Categories).
# --- Ejecución de las fuentes ---------------------------------------------------
$ctx = Initialize-RunContext -Env $Env -FromRaw $FromRaw -Root $root -MetaFile 'meta-audit.json' -Suffix '-auditoria'
$Env = $ctx.env; $outDir = $ctx.outDir; $generated = $ctx.generated
if ($ctx.fromRaw) {
    $meta = $ctx.meta; $Cluster = @($meta.cluster | Where-Object { $_ })
    if (-not $PSBoundParameters.ContainsKey('Scope')) { $Scope = $meta.scope }
    # Re-render en paralelo: solo CPU y cada fuente en su carpeta. Auditorías anteriores a la fuente de
    # rendimiento no tienen perf/: se declaran como cobertura más abajo.
    Wait-SourceJob @(
        Start-ThreadJob -Name 'inventario' { & (Join-Path $using:scripts 'New-Report.ps1') -FromRaw (Join-Path $using:outDir 'inventario') -Format html | Out-Null }
        Start-ThreadJob -Name 'hosts' { & (Join-Path $using:scripts 'Invoke-HostCheck.ps1') -FromRaw (Join-Path $using:outDir 'hosts') -Format html | Out-Null }
        if (Test-Path -LiteralPath (Join-Path $outDir 'perf/raw/meta-perf.json')) {
            Start-ThreadJob -Name 'rendimiento' { & (Join-Path $using:scripts 'Invoke-PerfCheck.ps1') -FromRaw (Join-Path $using:outDir 'perf') -Format html | Out-Null }
        })
} else {
    # 1) Controles de acceso primero, en este hilo: verifica la credencial antes de lanzar lo demás y
    #    carga una sola vez el tipo de Credential Manager para todo el proceso.
    [Console]::Error.WriteLine('== Controles de acceso ==')
    $perm = @(); $roles = @()
    Import-Module (Join-Path $PSScriptRoot 'lib/GovcBatch.psm1') -Force
    $acc = Invoke-GovcBatch -Env $Env -Commands @(@('permissions.ls', '-json', '/'), @('role.ls', '-json'))
    if ($acc[0].exitCode -eq 0 -and $acc[0].stdout) { $perm = @($acc[0].stdout | ConvertFrom-Json) }
    if ($acc[1].exitCode -eq 0 -and $acc[1].stdout) { $roles = @($acc[1].stdout | ConvertFrom-Json) }
    Save-RawJson ([pscustomobject]@{ permissions = $perm; roles = $roles; ok = ($perm.Count -gt 0) }) (Join-Path $ctx.rawDir 'vcenter-access.json')

    # 2) En paralelo: [inventario -> rendimiento] y revisión de hosts (no dependen entre sí).
    $perfLabel = if ($SkipPerf) { ' (rendimiento omitido)' } else { " (rendimiento $PerfWindow)" }
    [Console]::Error.WriteLine("== Inventario y rendimiento$perfLabel, en paralelo con la revisión de hosts ==")
    $invArgs = @{ Env = $Env; Type = 'all'; Format = 'html'; OutDir = (Join-Path $outDir 'inventario'); SkipDeviceScan = [bool]$SkipDeviceScan }
    $hcArgs = @{ Env = $Env; Format = 'html'; OutDir = (Join-Path $outDir 'hosts') }
    $pcArgs = @{ Env = $Env; Window = $PerfWindow; Format = 'html'; OutDir = (Join-Path $outDir 'perf'); InventoryDir = (Join-Path $outDir 'inventario') }
    if ($Cluster) { $hcArgs.Cluster = $Cluster; $pcArgs.Cluster = $Cluster }
    $skip = [bool]$SkipPerf
    $invJob = Start-ThreadJob -Name 'inventario+rendimiento' {
        $s = $using:scripts; $ia = $using:invArgs; $pa = $using:pcArgs
        & (Join-Path $s 'New-Report.ps1') @ia | Out-Null
        if ($using:skip) { return '' }
        # Una falla de rendimiento no detiene la auditoría: queda como cobertura.
        try { & (Join-Path $s 'Invoke-PerfCheck.ps1') @pa | Out-Null; '' } catch { "$($_.Exception.Message)" }
    }
    $hcJob = Start-ThreadJob -Name 'hosts' { $s = $using:scripts; $ha = $using:hcArgs; & (Join-Path $s 'Invoke-HostCheck.ps1') @ha | Out-Null }
    $perfError = ''
    try {
        $null = $invJob, $hcJob | Wait-Job
        foreach ($j in $invJob, $hcJob) { if ($j.State -eq 'Failed') { throw "Falló '$($j.Name)': $($j.ChildJobs[0].JobStateInfo.Reason.Message)" } }
        $perfError = "$(@(Receive-Job $invJob -ErrorAction Stop)[-1])"
        $null = Receive-Job $hcJob -ErrorAction Stop
    } finally {
        $invJob, $hcJob | Stop-Job -ErrorAction SilentlyContinue
        $invJob, $hcJob | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    if ($perfError) { [Console]::Error.WriteLine("Rendimiento no disponible: $perfError") }

    Write-RunMeta (Join-Path $ctx.rawDir 'meta-audit.json') $Env $generated ([ordered]@{
            scope = $Scope; cluster = @($Cluster); version = $Version
            perfWindow = $(if ($SkipPerf) { $null } else { $PerfWindow }); perfSkipped = [bool]$SkipPerf; perfError = $perfError })
}
$meta = Read-Json (Join-Path $outDir 'raw/meta-audit.json') $null
$scopeDomains = switch ($Scope) {
    'security'    { @('Seguridad', 'Configuración') }
    'capacity'    { @('Capacidad', 'Disponibilidad') }
    'performance' { @('Capacidad', 'Rendimiento') }
    default       { $domains }
}
$scopeLabel = @{ full = 'Completa: disponibilidad, capacidad, rendimiento, configuración, seguridad e higiene'; security = 'Seguridad y configuración'; capacity = 'Capacidad y disponibilidad'; performance = 'Capacidad y rendimiento' }[$Scope]
$perfMeta = Read-Json (Join-Path $outDir 'perf/raw/meta-perf.json') $null
# Sin datos de rendimiento el dominio no se puntúa (un 100 sugeriría que se evaluó); queda como cobertura.
$perfInScope = 'Rendimiento' -in $scopeDomains
if (-not $perfMeta) { $scopeDomains = @($scopeDomains | Where-Object { $_ -ne 'Rendimiento' }) }

# --- Controles de acceso: administradores en la raíz ------------------------------
$access = Read-Json (Join-Path $outDir 'raw/vcenter-access.json') $null
$extra = New-FindingList
$adminPrincipals = @()
if ($access -and $access.ok) {
    # Estructuras tolerantes: permisos como lista o anidados en 'permissions'.
    $plist = @($access.permissions | ForEach-Object { if ($_.PSObject.Properties['permissions']) { $_.permissions } else { $_ } } | ForEach-Object { $_ })
    $rlist = @($access.roles | ForEach-Object { if ($_.PSObject.Properties['roles']) { $_.roles } else { $_ } } | ForEach-Object { $_ })
    $adminRoleIds = @(-1) + @($rlist | Where-Object { (P $_ 'name') -eq 'Admin' } | ForEach-Object { P $_ 'roleId' })
    $adminPrincipals = @($plist | Where-Object { $adminRoleIds -contains [int](P $_ 'roleId' 0) } |
        ForEach-Object { [pscustomobject]@{ principal = P $_ 'principal' ''; group = [bool](P $_ 'group' $false); propagate = [bool](P $_ 'propagate' $false) } } |
        Sort-Object principal -Unique)
    $users = @($adminPrincipals | Where-Object { -not $_.group })
    if ($adminPrincipals.Count -gt $MaxRootAdmins) {
        Add-ReportFinding $extra 'Advertencia' 'Permisos' 'Raíz del inventario' "$($adminPrincipals.Count) principales con rol Administrador (umbral: $MaxRootAdmins)" (Get-FindingText 'perm-root-admins') "./scripts/govc.ps1 -Env $Env permissions.ls /" -Rule 'perm-root-admins'
    }
    if ($users.Count) {
        Add-ReportFinding $extra 'Info' 'Permisos' 'Raíz del inventario' "$($users.Count) usuario(s) individuales con rol Administrador (no grupos)" (Get-FindingText 'perm-root-users') "./scripts/govc.ps1 -Env $Env permissions.ls /" -Rule 'perm-root-users'
    }
} else {
    Add-ReportFinding $extra 'Info' 'Cobertura' 'Controles de acceso' 'No se pudo leer permissions.ls en la raíz' (Get-FindingText 'coverage-access') -Rule 'coverage-access'
}
if (-not $perfMeta -and $perfInScope) {
    $why = if (P $meta 'perfSkipped' $false) { 'Omitida en esta corrida (-SkipPerf)' } elseif (P $meta 'perfError' '') { "No disponible: $(P $meta 'perfError' '')" } else { 'Auditoría recolectada sin la fuente de rendimiento' }
    Add-ReportFinding $extra 'Info' 'Cobertura' 'Métricas de rendimiento' $why (Get-FindingText 'coverage-perf') -Rule 'coverage-perf'
}

# --- Consolidación ------------------------------------------------------------------
$sources = @(
    @{ name = 'Inventario y configuración'; dir = 'inventario'; report = 'inventario/reporte-all.html' }
    @{ name = 'Configuración de hosts';     dir = 'hosts';      report = 'hosts/hosts-check.html' }
    if ($perfMeta) { @{ name = 'Rendimiento'; dir = 'perf'; report = 'perf/perf-check.html' } }
)
$all = New-Object System.Collections.Generic.List[object]
foreach ($s in $sources) { foreach ($f in @(Read-Json (Join-Path $outDir "$($s.dir)/raw/findings.json"))) { $f | Add-Member source $s.name -Force; $all.Add($f) } }
foreach ($f in $extra) { $f | Add-Member source 'Controles de acceso' -Force; $all.Add($f) }

$coverage = @($all | Where-Object { $_.category -eq 'Cobertura' })
$scored = @($all | Where-Object { $_.category -ne 'Cobertura' } |
    ForEach-Object {
        $d = $domainOf[$_.category]; if (-not $d) { $d = 'Configuración' }
        $_ | Add-Member domain $d -Force
        $_ | Add-Member risk (Get-CategoryText $_.category Risk) -Force
        $_ | Add-Member reference (Get-CategoryText $_.category Reference) -Force
        $_ } |
    Where-Object { $_.domain -in $scopeDomains } |
    Sort-Object { Get-SeverityRank $_.severity }, { [array]::IndexOf($domains, $_.domain) }, category, object)
$i = 0; foreach ($f in $scored) {
    $i++; $f | Add-Member id ('AUD-{0:000}' -f $i) -Force
    # Clave estable (regla + objeto) para seguir un hallazgo entre auditorías; el AUD-NNN depende del orden.
    $f | Add-Member key (Get-FindingKey $f) -Force
    # Prioridad: severidad × VMs expuestas (orden de los principales riesgos y del plan de remediación).
    $f | Add-Member priority (Get-FindingScore $f) -Force
}

$scores = [ordered]@{}
foreach ($d in $scopeDomains) {
    $fd = @($scored | Where-Object domain -eq $d)
    $c = @($fd | Where-Object severity -eq 'Crítico').Count; $w = @($fd | Where-Object severity -eq 'Advertencia').Count; $n = @($fd | Where-Object severity -eq 'Info').Count
    $scores[$d] = [pscustomobject]@{ score = [math]::Max(0, 100 - (15 * $c + 5 * $w + $n)); crit = $c; warn = $w; info = $n }
}
$counts = [ordered]@{ 'Crítico' = @($scored | Where-Object severity -eq 'Crítico').Count; 'Advertencia' = @($scored | Where-Object severity -eq 'Advertencia').Count; 'Info' = @($scored | Where-Object severity -eq 'Info').Count }

# --- Métricas clave (de los paneles de cada fuente: raw/metrics.json) ------------------------
$metricsOf = @{}
foreach ($s in 'inventario', 'hosts', 'perf') { $metricsOf[$s] = @(Read-Json (Join-Path $outDir "$s/raw/metrics.json")) }
$pick = {
    # La métrica con ese id (o prefijo) con el peor valor: máximo, o mínimo con -Min.
    param([string]$Src, [string]$Key, [string]$Label, [switch]$Min, [switch]$Prefix)
    $rows = @($metricsOf[$Src] | Where-Object { $k = "$(P $_ 'key' '')"; $null -ne (P $_ 'number') -and $(if ($Prefix) { $k.StartsWith($Key) } else { $k -eq $Key }) })
    if (-not $rows.Count) { return }
    $r = @($rows | Sort-Object { [double]$_.number } -Descending:(-not $Min))[0]
    $where = (@((P $r 'group'), $(if ($Prefix) { P $r 'label' }), (P $r 'note')) | Where-Object { $_ -and $_ -ne 'Más llenos' }) -join ' · '
    New-PanelCard -Key $Key.TrimEnd(':') -Label $Label -Value "$(P $r 'value' '')" -Number $r.number -Pct (P $r 'pct') -Level "$(P $r 'level' '')" -Note $where
}
$keyCards = @(@(
    if ('Capacidad' -in $scopeDomains -or 'Disponibilidad' -in $scopeDomains) {
        & $pick inventario 'cl-n1' 'Uso si falla el host mayor (peor clúster)'
        & $pick inventario 'cl-fit' 'VMs que aún caben con N+1 (clúster más justo)' -Min
        & $pick inventario 'ds-used:' 'Datastore más lleno' -Prefix
        & $pick inventario 'ds-total' 'Almacenamiento en uso'
        & $pick inventario 'off-disk' 'Disco en VMs apagadas'
    }
    if ('Configuración' -in $scopeDomains) { & $pick inventario 'tools-current' 'VMware Tools al día' }
    & $pick hosts 'hc-coverage' 'Cobertura de la revisión de hosts'
    if ('Rendimiento' -in $scopeDomains) {
        & $pick perf 'perf-ready-worst' 'CPU ready p95 (peor VM)'
        & $pick perf 'perf-ds-worst' 'Latencia p95 (peor datastore)'
    }
    if ('Capacidad' -in $scopeDomains) {
        & $pick perf 'perf-reclaim-vcpu' 'vCPU recuperables (right-sizing)'
        & $pick perf 'perf-reclaim-mem' 'RAM recuperable (right-sizing)'
    }
) | Where-Object { $_ })
$keyPanel = New-ReportPanel 'Métricas clave' $keyCards

# --- Evolución frente a la auditoría anterior del mismo entorno ---------------------------------
# Historial: la auditoría hermana más reciente de esta carpeta (reports/<env>/), anterior a esta.
$prevRun = Find-PreviousRun -OutDir $outDir -Env $Env -Before $generated -MetaFile 'audit.json' -RawFile 'audit.json'
$prevAudit = if ($prevRun) { Read-Json (Join-Path $prevRun.rawDir 'audit.json') $null } else { $null }
$evolution = $null
if ($prevAudit) {
    $prevF = @{}; foreach ($f in @($prevAudit.findings)) { if ($f) { $prevF[(Get-FindingKey $f)] = $f } }
    $curK = @{}; foreach ($f in $scored) { $curK[$f.key] = $f }
    $new = @($scored | Where-Object { -not $prevF.ContainsKey($_.key) })
    $resolved = @($prevF.Keys | Where-Object { -not $curK.ContainsKey($_) } | ForEach-Object { $prevF[$_] })
    $persist = @($scored | Where-Object { $prevF.ContainsKey($_.key) })
    $domDelta = foreach ($d in $scopeDomains) {
        $before = if ($prevAudit.scores -and $prevAudit.scores.PSObject.Properties[$d]) { [int]$prevAudit.scores.$d.score } else { $null }
        [pscustomobject]@{ domain = $d; before = $before; now = $scores[$d].score; delta = $(if ($null -ne $before) { $scores[$d].score - $before } else { $null }) }
    }
    $evolution = [ordered]@{
        previous = "$($prevAudit.id)"; previousGenerated = "$($prevAudit.generated)"; previousScope = "$($prevAudit.scope)"
        new = $new.Count; resolved = $resolved.Count; persistent = $persist.Count
        domains = @($domDelta); newKeys = @($new | ForEach-Object { $_.key }); resolvedKeys = @($resolved | ForEach-Object { Get-FindingKey $_ })
    }
}
$arrow = { param($d) if ($null -eq $d) { '—' } elseif ($d -gt 0) { "↑ +$d" } elseif ($d -lt 0) { "↓ $d" } else { '= 0' } }
$evoCards = if ($evolution) {
    @(
        New-PanelCard -Key 'evo-new' -Label 'Hallazgos nuevos' -Value "$($evolution.new)" -Number $evolution.new -Level $(if (@($new | Where-Object severity -eq 'Crítico').Count) { 'crit' } elseif ($evolution.new) { 'warn' } else { 'ok' }) `
            -Note "$(@($new | Where-Object severity -eq 'Crítico').Count) críticos · $(@($new | Where-Object severity -eq 'Advertencia').Count) advertencias"
        New-PanelCard -Key 'evo-resolved' -Label 'Resueltos' -Value "$($evolution.resolved)" -Number $evolution.resolved -Level $(if ($evolution.resolved) { 'ok' } else { '' })
        New-PanelCard -Key 'evo-persistent' -Label 'Persistentes' -Value "$($evolution.persistent)" -Number $evolution.persistent -Level $(if (@($persist | Where-Object severity -eq 'Crítico').Count) { 'crit' } elseif ($evolution.persistent) { 'warn' } else { 'ok' }) `
            -Note "$(@($persist | Where-Object severity -eq 'Crítico').Count) críticos siguen abiertos"
        foreach ($x in $domDelta) {
            New-PanelCard -Group 'Indicador por dominio' -Key "evo-dom:$($x.domain)" -Label $x.domain -Value "$($x.now) ($(& $arrow $x.delta))" -Number $x.delta -Pct $x.now `
                -Level $(if ($null -eq $x.delta) { '' } elseif ($x.delta -lt 0) { 'crit' } elseif ($x.delta -gt 0) { 'ok' } else { '' }) -Note $(if ($null -ne $x.before) { "antes $($x.before)" } else { 'sin dato anterior' })
        }
    )
} else { @() }
$evoNote = if ($evolution) {
    $pa = ([datetime]$prevAudit.generated).ToString('yyyy-MM-dd HH:mm')
    "Comparado con $($evolution.previous) ($pa)$(if ($evolution.previousScope -and $evolution.previousScope -ne $Scope) { "; alcance anterior distinto ($($evolution.previousScope)): los nuevos y resueltos pueden deberse al cambio de alcance" }). Un hallazgo se sigue por regla y objeto."
} else { 'Primera auditoría del entorno: la evolución aparece desde la siguiente.' }
$evoPanel = New-ReportPanel 'Evolución' $evoCards $evoNote
$newTop = @(if ($evolution) { $new | Where-Object severity -ne 'Info' | Select-Object -First 10 })

$invSum = Read-Json (Join-Path $outDir 'inventario/raw/summary.json') $null
$hostSum = Read-Json (Join-Path $outDir 'hosts/raw/summary.json') $null
$auditId = 'AUD-{0}-{1:yyyyMMdd-HHmm}' -f $Env.ToUpper(), $generated
$preparedBy = P $meta 'user' "$env:USERDOMAIN\$env:USERNAME"
$classification = 'Uso interno — Confidencial'
$stamp = $generated.ToString('yyyy-MM-dd HH:mm')
# Con -Cluster se limitan la revisión de hosts y el rendimiento; el inventario y la capacidad son de todo vCenter.
$clusterLabel = if ($Cluster) { " · hosts y rendimiento del clúster(es): $($Cluster -join ', ') (inventario completo)" } else { '' }

# --- Textos ----------------------------------------------------------------------
$nVm = if ($invSum) { P $invSum 'VMs' 0 } else { 0 }
$nHost = if ($invSum) { P $invSum 'Hosts' 0 } else { 0 }
$nCl = if ($invSum) { P $invSum 'Clústeres' 0 } else { 0 }
$worst = @($scores.GetEnumerator() | Sort-Object { $_.Value.score } | Select-Object -First 2 | ForEach-Object { "$($_.Key) ($($_.Value.score))" })
$n = { param([int]$k, [string]$one, [string]$many) if ($k -eq 1) { "1 $one" } else { "$k $many" } }
$scopeText = @{ full = 'disponibilidad, capacidad, rendimiento, configuración, seguridad e higiene'; security = 'seguridad y configuración'; capacity = 'capacidad y disponibilidad'; performance = 'capacidad y rendimiento' }[$Scope]
$perfSum = Read-Json (Join-Path $outDir 'perf/raw/summary.json') $null
$perfWin = if ($perfMeta) { "$(P $perfMeta 'window' '')" } else { '' }
$perfLevel = if ($perfMeta) { P $perfMeta 'intervalLevel' } else { $null }
$perfText = if ($perfMeta -and 'Rendimiento' -in $scopeDomains) {
    " Las métricas de rendimiento cubren una ventana de $perfWin (intervalo de $(P $perfMeta 'interval' '?') s$(if ($null -ne $perfLevel) { ", nivel de estadísticas $perfLevel" })) sobre $(& $n ([int](P $perfSum 'Hosts' 0)) 'host' 'hosts') y $(& $n ([int](P $perfSum 'VMs evaluadas' 0)) 'VM encendida' 'VMs encendidas')."
} else { '' }
$nHostChecked = if ($hostSum) { [int](P $hostSum 'Hosts' 0) } else { 0 }
$hostScope = if ($Cluster) { " La revisión de configuración de hosts se limitó a $(& $n $nHostChecked 'host' 'hosts') $(if ($Cluster.Count -eq 1) { 'del clúster' } else { 'de los clústeres' }) $(ConvertTo-HtmlText ($Cluster -join ', '))." } else { '' }
$execText = @(
    "Se evaluó el entorno <strong>$(ConvertTo-HtmlText $Env.ToUpper())</strong> el $stamp, en los dominios de $scopeText. El inventario comprendió $(& $n $nVm 'máquina virtual' 'máquinas virtuales'), $(& $n $nHost 'host' 'hosts') y $(& $n $nCl 'clúster o recurso de cómputo' 'clústeres o recursos de cómputo').$hostScope$perfText"
    "Se identificaron <strong>$(& $n $counts['Crítico'] 'hallazgo crítico' 'hallazgos críticos')</strong>, $(& $n $counts['Advertencia'] 'advertencia' 'advertencias') y $(& $n $counts['Info'] 'observación informativa' 'observaciones informativas'). Los dominios con menor indicador son: $(ConvertTo-HtmlText ($worst -join ' y '))."
    $(if ($counts['Crítico']) { 'Se recomienda atender los hallazgos críticos de forma prioritaria, conforme al plan de remediación de la sección 4.' } else { 'No se identificaron hallazgos críticos. Se recomienda planificar la atención de las advertencias conforme al plan de remediación.' })
    $(if ($coverage.Count) { "La evaluación presenta $(& $n $coverage.Count 'limitación de cobertura' 'limitaciones de cobertura'), detalladas en la sección 2." })
) | Where-Object { $_ }

# --- HTML ----------------------------------------------------------------------------
$scoreClass = { param($v) if ($v -ge 85) { 'ok' } elseif ($v -ge 60) { 'warn' } else { 'crit' } }
$domainHtml = ($scores.GetEnumerator() | ForEach-Object { "<div class=""score $(& $scoreClass $_.Value.score)""><div class=""v"">$($_.Value.score)</div><div class=""l"">$(ConvertTo-HtmlText $_.Key)</div><div class=""l"">$($_.Value.crit) C · $($_.Value.warn) A · $($_.Value.info) I</div></div>" }) -join ''
$countHtml = ($counts.GetEnumerator() | ForEach-Object { "<span class=""count $(Get-SeverityClass $_.Key)"">$($_.Value) $(ConvertTo-HtmlText $_.Key)</span>" }) -join ''
$byPriority = @($scored | Where-Object { $_.priority -gt 0 } | Sort-Object priority -Descending)
$vmsOf = { param($f) $v = Get-Prop $f 'impact'; if ($null -ne $v) { "$v" } else { '—' } }
$top = @($byPriority | Select-Object -First 5)
$topHtml = if ($top.Count) {
    '<table class="t"><thead><tr><th>ID</th><th>Severidad</th><th>Dominio</th><th>Objeto</th><th class="n">VMs expuestas</th><th>Riesgo</th></tr></thead><tbody>' +
    (($top | ForEach-Object { "<tr><td><a class=""aud"" href=""#$($_.id.ToLowerInvariant())"">$($_.id)</a></td><td><span class=""sev $(Get-SeverityClass $_.severity)"">$(ConvertTo-HtmlText $_.severity)</span></td><td>$(ConvertTo-HtmlText $_.domain)</td><td>$(ConvertTo-HtmlText $_.object)</td><td class=""n"">$(& $vmsOf $_)</td><td>$(ConvertTo-HtmlText $_.risk)</td></tr>" }) -join '') + '</tbody></table>'
} else { '<p class="muted">Sin hallazgos críticos ni advertencias.</p>' }

# Huella de los hallazgos puntuados: vigencia del análisis de Claude (raw/analysis.md).
$fingerprint = Get-FindingFingerprint $scored
Set-Content -LiteralPath (Join-Path $outDir 'raw/fingerprint.txt') $fingerprint -Encoding utf8 -NoNewline
$analysis = Get-ReportAnalysis -RawDir (Join-Path $outDir 'raw') -Fingerprint $fingerprint
$analysisHtml = if ($analysis) { "<h3>$(ConvertTo-HtmlText $analysis.title)</h3><p class=""small muted"">$(ConvertTo-HtmlText $analysis.note)</p>$(ConvertTo-AnalysisNoticeHtml $analysis)<div class=""analysis"">$(ConvertTo-SafeHtml $analysis.text)</div>" } else { '' }
$keyHtml = if ($keyCards.Count) { ConvertTo-PanelHtml $keyPanel -Bare } else { '<p class="muted">Sin métricas disponibles.</p>' }
$evoHtml = (ConvertTo-PanelHtml $evoPanel -Bare) + $(if ($newTop.Count) {
        '<h3>Hallazgos nuevos (críticos y advertencias)</h3><table class="t"><thead><tr><th>ID</th><th>Severidad</th><th>Dominio</th><th>Objeto</th></tr></thead><tbody>' +
        (($newTop | ForEach-Object { "<tr><td><a class=""aud"" href=""#$($_.id.ToLowerInvariant())"">$($_.id)</a></td><td><span class=""sev $(Get-SeverityClass $_.severity)"">$(ConvertTo-HtmlText $_.severity)</span></td><td>$(ConvertTo-HtmlText $_.domain)</td><td>$(ConvertTo-HtmlText $_.object)</td></tr>" }) -join '') + '</tbody></table>' })
$covRows = if ($coverage.Count) { ($coverage | ForEach-Object { "<tr><td>$(ConvertTo-HtmlText $_.object)</td><td>$(ConvertTo-HtmlText $_.evidence)</td></tr>" }) -join '' } else { '<tr><td colspan="2" class="muted">Cobertura completa.</td></tr>' }
$methodHtml = @"
<p>La evaluación se realizó mediante consultas de <strong>solo lectura</strong> a vCenter con el cliente govc, a través del wrapper controlado del proyecto. No se ejecutaron cambios en la infraestructura. Cada consulta quedó registrada en la bitácora de auditoría.</p>
<table class="t"><thead><tr><th>Fuente</th><th>Método</th><th>Elementos evaluados</th></tr></thead><tbody>
<tr><td>Inventario y configuración</td><td>object.collect en bloque · about.cert · license.ls</td><td>VMs, hosts, clústeres (HA/DRS), datastores, alarmas, snapshots, configuración de VMs, certificado de vCenter, licencias</td></tr>
<tr><td>Configuración de hosts</td><td>host.esxcli (solo list/get) · host.service.ls · host.cert.info</td><td>VIBs y drivers, NIC físicas, paths de storage, NTP, syslog, coredump, plataforma, servicios SSH/Shell, certificados de host</td></tr>
$(if ($perfMeta) { "<tr><td>Rendimiento</td><td>metric.sample · metric.interval.info (ventana $(ConvertTo-HtmlText $perfWin), intervalo $(ConvertTo-HtmlText (P $perfMeta 'interval' '')) s$(if ($null -ne $perfLevel) { ", nivel de estadísticas $perfLevel" }))</td><td>CPU ready por vCPU, latencia de datastores por host, CPU de hosts, ballooning, swap y paquetes descartados (p95 y máximo en la ventana)</td></tr>" })
<tr><td>Controles de acceso</td><td>permissions.ls · role.ls</td><td>Asignaciones con rol Administrador en la raíz del inventario</td></tr>
</tbody></table>
<h3>Cuenta y ventana</h3>
<p>Cuenta de servicio del perfil <code>$(ConvertTo-HtmlText $Env)</code> (Windows Credential Manager). Fotografía del estado al $stamp; los valores pueden variar después de esa fecha.</p>
<h3>Limitaciones</h3>
<ul>
<li>No se evalúan sistemas operativos invitados, aplicaciones, respaldos, red física fuera del host ni seguridad perimetral.</li>
<li>La sobresuscripción y la holgura N+1 se miden sobre recursos asignados y el uso al momento de la recolección. $(if ($perfMeta) { "Las métricas de rendimiento cubren la ventana de $(ConvertTo-HtmlText $perfWin); lo que el nivel de estadísticas de vCenter no conserva se declara como cobertura." } else { 'No se evaluó el consumo en una ventana de tiempo.' })</li>
<li>$(ConvertTo-HtmlText (Get-NoteText 'thresholds'))</li>
<li>Las referencias a guías de seguridad son temáticas y orientativas; deben contrastarse con la versión vigente de cada documento.</li>
</ul>
<h3>Cobertura</h3>
<table class="t"><thead><tr><th>Elemento</th><th>Limitación</th></tr></thead><tbody>$covRows</tbody></table>
"@

$matrixHtml = '<table class="t"><thead><tr><th>Dominio</th><th class="n">Crítico</th><th class="n">Advertencia</th><th class="n">Info</th><th class="n">Total</th><th class="n">Indicador</th></tr></thead><tbody>' +
    (($scores.GetEnumerator() | ForEach-Object { "<tr><td>$(ConvertTo-HtmlText $_.Key)</td><td class=""n"">$($_.Value.crit)</td><td class=""n"">$($_.Value.warn)</td><td class=""n"">$($_.Value.info)</td><td class=""n"">$($_.Value.crit + $_.Value.warn + $_.Value.info)</td><td class=""n""><strong>$($_.Value.score)</strong></td></tr>" }) -join '') +
    "<tr><td><strong>Total</strong></td><td class=""n""><strong>$($counts['Crítico'])</strong></td><td class=""n""><strong>$($counts['Advertencia'])</strong></td><td class=""n""><strong>$($counts['Info'])</strong></td><td class=""n""><strong>$($scored.Count)</strong></td><td></td></tr></tbody></table>"

$findHtml = if ($scored.Count) {
    ($scored | ForEach-Object {
        $refRow = if ($_.reference) { "<dt>Referencia</dt><dd>$(ConvertTo-HtmlText $_.reference)</dd>" } else { '' }
        $cmdRow = if ($_.command) { "<dt>Verificación</dt><dd><code class=""cmd"">$(ConvertTo-HtmlText $_.command)</code></dd>" } else { '' }
        @"
<article class="finding $(Get-SeverityClass $_.severity)" id="$($_.id.ToLowerInvariant())">
<header><span class="id">$($_.id)</span><span class="obj">$(ConvertTo-HtmlText $_.object)</span><span class="sev $(Get-SeverityClass $_.severity)">$(ConvertTo-HtmlText $_.severity)</span><span class="dom">$(ConvertTo-HtmlText $_.domain) · $(ConvertTo-HtmlText $_.category)</span></header>
<dl><dt>Evidencia</dt><dd>$(ConvertTo-HtmlText $_.evidence)</dd>$(if ($null -ne (Get-Prop $_ 'impact')) { "<dt>VMs expuestas</dt><dd>$($_.impact)</dd>" })<dt>Riesgo</dt><dd>$(ConvertTo-HtmlText $_.risk)</dd><dt>Recomendación</dt><dd>$(ConvertTo-HtmlText $_.suggestion)</dd>$cmdRow$refRow<dt>Fuente</dt><dd>$(ConvertTo-HtmlText $_.source)</dd></dl>
</article>
"@ }) -join "`n"
} else { '<p class="muted">No se identificaron hallazgos en el alcance evaluado.</p>' }

$rank = 0
$remHtml = '<table class="t"><thead><tr><th class="n">Prioridad</th><th>ID</th><th>Sev.</th><th>Objeto</th><th class="n">VMs</th><th>Acción recomendada</th><th>Responsable</th><th>Fecha compromiso</th><th>Estado</th></tr></thead><tbody>' +
    (($byPriority | ForEach-Object { $rank++; "<tr><td class=""n"">$rank</td><td><a class=""aud"" href=""#$($_.id.ToLowerInvariant())"">$($_.id)</a></td><td><span class=""sev $(Get-SeverityClass $_.severity)"">$(ConvertTo-HtmlText $_.severity.Substring(0,1))</span></td><td>$(ConvertTo-HtmlText $_.object)</td><td class=""n"">$(& $vmsOf $_)</td><td>$(ConvertTo-HtmlText $_.suggestion)</td><td class=""blank""></td><td class=""blank""></td><td>Abierto</td></tr>" }) -join '') +
    '</tbody></table><p class="small muted">Las observaciones informativas se incluyen en la sección 3 y pueden atenderse en el ciclo regular de mantenimiento.</p>'

function KpiTable($obj, $title) {
    if (-not $obj) { return "<p class=""muted"">$(ConvertTo-HtmlText $title): sin datos.</p>" }
    "<h3>$(ConvertTo-HtmlText $title)</h3><table class=""t""><tbody>" + (($obj.PSObject.Properties | ForEach-Object { "<tr><td>$(ConvertTo-HtmlText $_.Name)</td><td class=""n"">$(ConvertTo-HtmlText $_.Value)</td></tr>" }) -join '') + '</tbody></table>'
}
$annexHtml = @(
    (KpiTable $invSum 'A. Resumen de inventario')
    (KpiTable $hostSum 'B. Resumen de la revisión de hosts')
    (KpiTable $perfSum 'C. Resumen de rendimiento')
    $(if ($adminPrincipals.Count) { '<h3>D. Principales con rol Administrador en la raíz</h3><table class="t"><thead><tr><th>Principal</th><th>Tipo</th><th>Propaga</th></tr></thead><tbody>' + (($adminPrincipals | ForEach-Object { "<tr><td>$(ConvertTo-HtmlText $_.principal)</td><td>$(if ($_.group) { 'Grupo' } else { 'Usuario' })</td><td>$(if ($_.propagate) { 'Sí' } else { 'No' })</td></tr>" }) -join '') + '</tbody></table><p class="small muted">Información sensible: nombres de cuentas con privilegios elevados.</p>' })
    '<h3>E. Reportes de detalle</h3><ul>' + (($sources | ForEach-Object { "<li><a href=""$($_.report)"">$(ConvertTo-HtmlText $_.name)</a> — <code>$(ConvertTo-HtmlText $_.report)</code></li>" }) -join '') + '</ul>'
    '<h3>F. Comandos de recolección</h3><table class="t"><tbody>' + ((@(
        'object.collect -json -type m|h|r|c|s|p / &lt;propiedades&gt;', 'object.collect -json / triggeredAlarmState', 'about.cert -json', 'license.ls -json',
        'metric.interval.info -json', 'metric.sample -json -i &lt;intervalo&gt; -n &lt;muestras&gt; -instance=&lt;…&gt; HostSystem:&lt;id&gt;|VirtualMachine:&lt;id&gt; … &lt;contadores&gt;',
        'host.esxcli -json -host &lt;h&gt; software vib list | network nic list | storage core path list | system ntp get | system syslog config get | system coredump network get | hardware platform get',
        'host.service.ls -json -host &lt;h&gt;', 'host.cert.info -json -host &lt;h&gt;', 'permissions.ls -json /', 'role.ls -json'
    ) | ForEach-Object { "<tr><td><code>$_</code></td></tr>" }) -join '') + '</tbody></table>'
) -join "`n"

$written = @()
if ('html' -in $Format) {
    # Una sola pasada (Expand-Template): un dato de vCenter con "{{ANNEXES}}" queda literal.
    $map = @{}
    $text = @{
        TITLE = "Auditoría de la plataforma vSphere — $($Env.ToUpper())"; SUBTITLE = $scopeLabel + $clusterLabel
        ENV = $Env.ToUpper(); SCOPE = $scopeLabel + $clusterLabel; DATE = $stamp; PREPARED_BY = $preparedBy
        AUDIT_ID = $auditId; VERSION = $Version; CLASSIFICATION = $classification
    }
    foreach ($k in $text.Keys) { $map[$k] = ConvertTo-HtmlText $text[$k] }
    $map += @{
        EXEC_SUMMARY = (($execText | ForEach-Object { "<p>$_</p>" }) -join ''); DOMAIN_SCORES = $domainHtml; SEVERITY_COUNTS = $countHtml
        TOP_RISKS = $topHtml; ANALYSIS = $analysisHtml; KEY_METRICS = $keyHtml; EVOLUTION = $evoHtml; METHODOLOGY = $methodHtml; MATRIX = $matrixHtml; FINDINGS = $findHtml; REMEDIATION = $remHtml; ANNEXES = $annexHtml
    }
    $app = Get-ReportScript
    $map += @{ APP_SCRIPT = $app.text; APP_HASH = $app.hash }
    $html = Expand-Template (Get-Content (Join-Path $root 'templates/audit.html') -Raw) $map
    $f = Join-Path $outDir 'auditoria.html'; Set-Content $f $html -Encoding utf8; $written += $f
}
if ('md' -in $Format) {
    $strip = { param($s) ($s -replace '<[^>]+>', '') }
    $md = Expand-Template (Get-Content (Join-Path $root 'templates/audit.md') -Raw) @{
        TITLE          = "Auditoría de la plataforma vSphere — $($Env.ToUpper())"; ENV = $Env.ToUpper(); SCOPE = $scopeLabel + $clusterLabel
        DATE           = $stamp; PREPARED_BY = (ConvertTo-MdText $preparedBy); AUDIT_ID = $auditId; VERSION = $Version; CLASSIFICATION = $classification
        EXEC_SUMMARY   = (($execText | ForEach-Object { [System.Net.WebUtility]::HtmlDecode((& $strip $_)) }) -join "`n`n")
        DOMAIN_SCORES  = ("| Dominio | Indicador | Crítico | Advertencia | Info |`n|---|---:|---:|---:|---:|`n" + (($scores.GetEnumerator() | ForEach-Object { "| $($_.Key) | $($_.Value.score) | $($_.Value.crit) | $($_.Value.warn) | $($_.Value.info) |" }) -join "`n"))
        FINDINGS       = $(if ($scored.Count) { ($scored | ForEach-Object { "### $($_.id) · $(ConvertTo-MdText $_.object)`n`n| | |`n|---|---|`n| Severidad | $($_.severity) |`n| Dominio | $($_.domain) · $($_.category) |`n| Evidencia | $(ConvertTo-MdText $_.evidence) |`n| Riesgo | $(ConvertTo-MdText $_.risk) |`n| Recomendación | $(ConvertTo-MdText $_.suggestion) |$(if ($_.command) { "`n| Verificación | $(Format-MdCode ("$($_.command)" -replace '\|', '\|')) |" })$(if ($_.reference) { "`n| Referencia | $(ConvertTo-MdText $_.reference) |" })" }) -join "`n`n" } else { 'No se identificaron hallazgos.' })
        REMEDIATION    = ("| Prioridad | ID | Severidad | Objeto | VMs | Acción | Responsable | Fecha | Estado |`n|---:|---|---|---|---:|---|---|---|---|`n" + (@($byPriority | ForEach-Object -Begin { $rk = 0 } -Process { $rk++; "| $rk | $($_.id) | $($_.severity) | $(ConvertTo-MdText $_.object) | $(& $vmsOf $_) | $(ConvertTo-MdText $_.suggestion) |  |  | Abierto |" }) -join "`n"))
        THRESHOLDS     = (Get-NoteText 'thresholds')
        ANALYSIS       = $(if ($analysis) { "$(ConvertTo-AnalysisMd $analysis '###')`n" } else { '' })
        KEY_METRICS    = $(if ($keyCards.Count) { ConvertTo-PanelMd $keyPanel -Bare } else { 'Sin métricas disponibles.' })
        EVOLUTION      = (ConvertTo-PanelMd $evoPanel -Bare) + $(if ($newTop.Count) { "`n`n**Hallazgos nuevos (críticos y advertencias)**`n`n| ID | Severidad | Dominio | Objeto |`n|---|---|---|---|`n" + (($newTop | ForEach-Object { "| $($_.id) | $($_.severity) | $($_.domain) | $(ConvertTo-MdText $_.object) |" }) -join "`n") })
        COVERAGE       = $(if ($coverage.Count) { ($coverage | ForEach-Object { "- $(ConvertTo-MdText $_.object): $(ConvertTo-MdText $_.evidence)" }) -join "`n" } else { 'Cobertura completa.' })
    }
    $f = Join-Path $outDir 'auditoria.md'; Set-Content $f $md -Encoding utf8; $written += $f
}

[ordered]@{ id = $auditId; env = $Env; generated = $generated.ToString('o'); scope = $Scope; cluster = @($Cluster); scores = $scores; counts = $counts; metrics = @($keyCards); evolution = $evolution; findings = $scored; coverage = $coverage } |
    ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'raw/audit.json') -Encoding utf8

[pscustomobject]@{ Auditoria = $auditId; Carpeta = $outDir; Archivos = $written; Criticos = $counts['Crítico']; Advertencias = $counts['Advertencia']; Indicadores = (($scores.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value.score)" }) -join ' · ') }
