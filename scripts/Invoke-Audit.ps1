<#
.SYNOPSIS
  Auditoría técnica completa de un entorno vCenter (solo lectura) con informe formal HTML/MD.

.DESCRIPTION
  Orquesta tres fuentes y consolida sus hallazgos en un único modelo de auditoría:
    1. scripts/New-Report.ps1      inventario, capacidad, snapshots, configuración de VMs y clústeres,
                                   certificado de vCenter y licencias.
    2. scripts/Invoke-HostCheck.ps1 configuración de cada host vía esxcli (drift, red, storage, NTP,
                                   syslog, servicios, certificados de host).
    3. Controles de acceso          permisos con rol Administrador en la raíz del inventario.
  Asigna ID (AUD-001…), dominio, riesgo y referencia a cada hallazgo; calcula un indicador por
  dominio y genera auditoria.html (imprimible / PDF) y auditoria.md a partir de templates/audit.*,
  más raw/audit.json con el modelo consolidado. El seguimiento con Compare-Report.ps1 compara las
  corridas de inventario (inventario/raw/), no audit.json.

.EXAMPLE
  ./scripts/Invoke-Audit.ps1 -Env prod
  ./scripts/Invoke-Audit.ps1 -Env prod -Cluster CL-PROD-01 -Scope security
  ./scripts/Invoke-Audit.ps1 -FromRaw reports/prod/20261017-090000-auditoria
#>
param(
    [string]$Env,
    [string[]]$Cluster,
    [ValidateSet('full', 'security', 'capacity')][string]$Scope = 'full',
    [ValidateSet('html', 'md')][string[]]$Format = @('html', 'md'),
    [string]$FromRaw,
    [int]$MaxRootAdmins = 5,
    [switch]$SkipDeviceScan,   # se pasa a New-Report.ps1 (recomendado con miles de VMs)
    [string]$Version = '1.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/GovcJson.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Render.psm1') -Force -DisableNameChecking
$wrapper = Join-Path $PSScriptRoot 'govc.ps1'
$enc = { param($s) ConvertTo-HtmlText $s }

function P($obj, [string]$name, $default = $null) {
    if ($null -ne $obj -and $obj.PSObject.Properties[$name] -and $null -ne $obj.$name) { return $obj.$name }
    return $default
}
function Read-Json([string]$path, $default = @()) {
    if (Test-Path $path) { return (Get-Content $path -Raw | ConvertFrom-Json -DateKind String) } else { return $default }
}

# --- Taxonomía de auditoría -----------------------------------------------------
$domains = @('Disponibilidad', 'Capacidad', 'Configuración', 'Seguridad', 'Higiene')
$domainOf = @{
    'Hosts' = 'Disponibilidad'; 'Alarmas' = 'Disponibilidad'; 'Storage' = 'Disponibilidad'; 'Red física' = 'Disponibilidad'; 'Clúster' = 'Disponibilidad'
    'Almacenamiento' = 'Capacidad'; 'Capacidad' = 'Capacidad'
    'VMware Tools' = 'Configuración'; 'Drift VIBs/drivers' = 'Configuración'; 'Tiempo' = 'Configuración'; 'Diagnóstico' = 'Configuración'
    'Plataforma' = 'Configuración'; 'Configuración VM' = 'Configuración'; 'Licencias' = 'Configuración'
    'Seguridad' = 'Seguridad'; 'Logs' = 'Seguridad'; 'Certificados' = 'Seguridad'; 'Permisos' = 'Seguridad'
    'Snapshots' = 'Higiene'; 'Higiene' = 'Higiene'
}
$riskOf = @{
    'Hosts'              = 'Pérdida de gestión o de protección HA para las VMs del host.'
    'Alarmas'            = 'Condición activa reportada por vCenter; impacto según la alarma.'
    'Storage'            = 'Pérdida de acceso a LUN o de redundancia de ruta; posible indisponibilidad de VMs.'
    'Red física'         = 'Pérdida de redundancia o rendimiento de red; fallas en vMotion o almacenamiento IP.'
    'Clúster'            = 'Las VMs no se reinician automáticamente ante falla de un host, o la carga no se balancea.'
    'Almacenamiento'     = 'Si el datastore se llena, vSphere pausa las VMs que escriben en él.'
    'Capacidad'          = 'Contención de CPU o memoria; capacidad insuficiente para tolerar la falla de un host.'
    'VMware Tools'       = 'Sin apagado ordenado, sin quiesce para respaldos y sin métricas del sistema invitado.'
    'Drift VIBs/drivers' = 'Comportamiento inconsistente entre hosts; riesgo en vMotion, HA y soporte del fabricante.'
    'Tiempo'             = 'Desfase horario: afecta autenticación, certificados y correlación de eventos.'
    'Diagnóstico'        = 'Sin evidencia para el fabricante ante una falla grave del host.'
    'Plataforma'         = 'Heterogeneidad de hardware; restricciones de EVC y de balanceo.'
    'Configuración VM'   = 'Configuraciones que limitan rendimiento, movilidad o mantenimiento de las VMs.'
    'Licencias'          = 'Pérdida de funcionalidades al vencer la licencia.'
    'Seguridad'          = 'Mayor superficie de ataque sobre el hipervisor.'
    'Logs'               = 'Los eventos solo quedan en el host: se pierden ante falla y no llegan al monitoreo central.'
    'Certificados'       = 'Interrupción de conexiones y alertas de confianza al vencer el certificado.'
    'Permisos'           = 'Exceso de privilegios: mayor impacto ante credenciales comprometidas o errores.'
    'Snapshots'          = 'Degradación de rendimiento y consumo de espacio; consolidaciones prolongadas.'
    'Higiene'            = 'Consumo de recursos y licencias sin uso aparente.'
}
# Referencia temática (sin IDs de control): orienta la consulta a la guía oficial vigente.
$scg = 'VMware vSphere Security Configuration Guide'; $cis = 'CIS Benchmark para VMware ESXi'
$refOf = @{
    'Seguridad'    = "$scg · $cis — servicios de acceso (SSH / ESXi Shell)"
    'Logs'         = "$scg · $cis — registro remoto (syslog)"
    'Tiempo'       = "$scg · $cis — sincronización de tiempo (NTP)"
    'Certificados' = "$scg — gestión de certificados"
    'Permisos'     = "$scg — control de acceso y roles de vCenter"
    'Drift VIBs/drivers' = "$scg · $cis — nivel de aceptación e integridad de VIBs"
}
# --- Ejecución de las fuentes ---------------------------------------------------
if ($FromRaw) {
    $outDir = (Resolve-Path $FromRaw).Path
    $meta = Read-Json (Join-Path $outDir 'raw/meta-audit.json') $null
    if (-not $meta) { throw "No es una carpeta de auditoría: falta raw/meta-audit.json en $outDir" }
    $Env = $meta.env; $generated = [datetime]$meta.generated; $Cluster = @($meta.cluster | Where-Object { $_ })
    if (-not $PSBoundParameters.ContainsKey('Scope')) { $Scope = $meta.scope }
    & (Join-Path $PSScriptRoot 'New-Report.ps1') -FromRaw (Join-Path $outDir 'inventario') -Format html | Out-Null
    & (Join-Path $PSScriptRoot 'Invoke-HostCheck.ps1') -FromRaw (Join-Path $outDir 'hosts') -Format html | Out-Null
} else {
    if (-not $Env) { throw 'Indica -Env <entorno> o -FromRaw <carpeta>.' }
    $Env = $Env.ToLowerInvariant()
    $generated = Get-Date
    $outDir = Join-Path $root ("reports/{0}/{1:yyyyMMdd-HHmmss}-auditoria" -f $Env, $generated)
    New-Item -ItemType Directory -Force -Path (Join-Path $outDir 'raw') | Out-Null

    [Console]::Error.WriteLine('== 1/3 Inventario, capacidad y configuración ==')
    & (Join-Path $PSScriptRoot 'New-Report.ps1') -Env $Env -Type all -Format html -OutDir (Join-Path $outDir 'inventario') -SkipDeviceScan:$SkipDeviceScan | Out-Null
    [Console]::Error.WriteLine('== 2/3 Configuración de hosts (esxcli) ==')
    $hcArgs = @{ Env = $Env; Format = 'html'; OutDir = (Join-Path $outDir 'hosts') }
    if ($Cluster) { $hcArgs.Cluster = $Cluster }
    & (Join-Path $PSScriptRoot 'Invoke-HostCheck.ps1') @hcArgs | Out-Null

    [Console]::Error.WriteLine('== 3/3 Controles de acceso ==')
    $perm = @(); $roles = @()
    Import-Module (Join-Path $PSScriptRoot 'lib/GovcBatch.psm1') -Force
    $acc = Invoke-GovcBatch -Env $Env -Commands @(
        , @('permissions.ls', '-json', '/')
        , @('role.ls', '-json'))
    if ($acc[0].exitCode -eq 0 -and $acc[0].stdout) { $perm = @($acc[0].stdout | ConvertFrom-Json) }
    if ($acc[1].exitCode -eq 0 -and $acc[1].stdout) { $roles = @($acc[1].stdout | ConvertFrom-Json) }
    ConvertTo-Json -InputObject @{ permissions = $perm; roles = $roles; ok = ($perm.Count -gt 0) } -Depth 10 |
        Set-Content (Join-Path $outDir 'raw/vcenter-access.json') -Encoding utf8

    @{ env = $Env; generated = $generated.ToString('o'); scope = $Scope; cluster = @($Cluster); user = "$env:USERDOMAIN\$env:USERNAME"; version = $Version } |
        ConvertTo-Json | Set-Content (Join-Path $outDir 'raw/meta-audit.json') -Encoding utf8
}

$meta = Read-Json (Join-Path $outDir 'raw/meta-audit.json') $null
$scopeDomains = switch ($Scope) {
    'security' { @('Seguridad', 'Configuración') }
    'capacity' { @('Capacidad', 'Disponibilidad') }
    default    { $domains }
}
$scopeLabel = @{ full = 'Completa: disponibilidad, capacidad, configuración, seguridad e higiene'; security = 'Seguridad y configuración'; capacity = 'Capacidad y disponibilidad' }[$Scope]

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
        Add-ReportFinding $extra 'Advertencia' 'Permisos' 'Raíz del inventario' "$($adminPrincipals.Count) principales con rol Administrador (umbral: $MaxRootAdmins)" 'Revisar necesidad de cada asignación; aplicar mínimo privilegio con roles personalizados acotados.' "./scripts/govc.ps1 -Env $Env permissions.ls /" -Rule 'perm-root-admins'
    }
    if ($users.Count) {
        Add-ReportFinding $extra 'Info' 'Permisos' 'Raíz del inventario' "$($users.Count) usuario(s) individuales con rol Administrador (no grupos)" 'Preferir asignaciones a grupos del directorio para facilitar altas, bajas y revisiones de acceso.' "./scripts/govc.ps1 -Env $Env permissions.ls /" -Rule 'perm-root-users'
    }
} else {
    Add-ReportFinding $extra 'Info' 'Cobertura' 'Controles de acceso' 'No se pudo leer permissions.ls en la raíz' 'Verificar privilegios de lectura de permisos de la cuenta de servicio.' -Rule 'coverage-access'
}

# --- Consolidación ------------------------------------------------------------------
$sources = @(
    @{ name = 'Inventario y configuración'; dir = 'inventario'; report = 'inventario/reporte-all.html' }
    @{ name = 'Configuración de hosts';     dir = 'hosts';      report = 'hosts/hosts-check.html' }
)
$all = New-Object System.Collections.Generic.List[object]
foreach ($s in $sources) { foreach ($f in @(Read-Json (Join-Path $outDir "$($s.dir)/raw/findings.json"))) { $f | Add-Member source $s.name -Force; $all.Add($f) } }
foreach ($f in $extra) { $f | Add-Member source 'Controles de acceso' -Force; $all.Add($f) }

$sevOrder = @{ 'Crítico' = 0; 'Advertencia' = 1; 'Info' = 2 }
$sevCss = @{ 'Crítico' = 'crit'; 'Advertencia' = 'warn'; 'Info' = 'info' }
$coverage = @($all | Where-Object { $_.category -eq 'Cobertura' })
$scored = @($all | Where-Object { $_.category -ne 'Cobertura' } |
    ForEach-Object {
        $d = $domainOf[$_.category]; if (-not $d) { $d = 'Configuración' }
        $_ | Add-Member domain $d -Force
        $_ | Add-Member risk ($riskOf[$_.category] ?? '') -Force
        $_ | Add-Member reference ($refOf[$_.category] ?? '') -Force
        $_ } |
    Where-Object { $_.domain -in $scopeDomains } |
    Sort-Object { $sevOrder[$_.severity] }, { [array]::IndexOf($domains, $_.domain) }, category, object)
$i = 0; foreach ($f in $scored) { $i++; $f | Add-Member id ('AUD-{0:000}' -f $i) -Force }

$scores = [ordered]@{}
foreach ($d in $scopeDomains) {
    $fd = @($scored | Where-Object domain -eq $d)
    $c = @($fd | Where-Object severity -eq 'Crítico').Count; $w = @($fd | Where-Object severity -eq 'Advertencia').Count; $n = @($fd | Where-Object severity -eq 'Info').Count
    $scores[$d] = [pscustomobject]@{ score = [math]::Max(0, 100 - (15 * $c + 5 * $w + $n)); crit = $c; warn = $w; info = $n }
}
$counts = [ordered]@{ 'Crítico' = @($scored | Where-Object severity -eq 'Crítico').Count; 'Advertencia' = @($scored | Where-Object severity -eq 'Advertencia').Count; 'Info' = @($scored | Where-Object severity -eq 'Info').Count }

$invSum = Read-Json (Join-Path $outDir 'inventario/raw/summary.json') $null
$hostSum = Read-Json (Join-Path $outDir 'hosts/raw/summary.json') $null
$auditId = 'AUD-{0}-{1:yyyyMMdd-HHmm}' -f $Env.ToUpper(), $generated
$preparedBy = P $meta 'user' "$env:USERDOMAIN\$env:USERNAME"
$classification = 'Uso interno — Confidencial'
$stamp = $generated.ToString('yyyy-MM-dd HH:mm')
$clusterLabel = if ($Cluster) { " · clúster(es): $($Cluster -join ', ')" } else { '' }

# --- Textos ----------------------------------------------------------------------
$nVm = if ($invSum) { P $invSum 'VMs' 0 } else { 0 }
$nHost = if ($invSum) { P $invSum 'Hosts' 0 } else { 0 }
$nCl = if ($invSum) { P $invSum 'Clústeres' 0 } else { 0 }
$worst = @($scores.GetEnumerator() | Sort-Object { $_.Value.score } | Select-Object -First 2 | ForEach-Object { "$($_.Key) ($($_.Value.score))" })
$n = { param([int]$k, [string]$one, [string]$many) if ($k -eq 1) { "1 $one" } else { "$k $many" } }
$scopeText = @{ full = 'disponibilidad, capacidad, configuración, seguridad e higiene'; security = 'seguridad y configuración'; capacity = 'capacidad y disponibilidad' }[$Scope]
$nHostChecked = if ($hostSum) { [int](P $hostSum 'Hosts' 0) } else { 0 }
$hostScope = if ($Cluster) { " La revisión de configuración de hosts se limitó a $(& $n $nHostChecked 'host' 'hosts') $(if ($Cluster.Count -eq 1) { 'del clúster' } else { 'de los clústeres' }) $(& $enc ($Cluster -join ', '))." } else { '' }
$execText = @(
    "Se evaluó el entorno <strong>$(& $enc $Env.ToUpper())</strong> el $stamp, en los dominios de $scopeText. El inventario comprendió $(& $n $nVm 'máquina virtual' 'máquinas virtuales'), $(& $n $nHost 'host' 'hosts') y $(& $n $nCl 'clúster o recurso de cómputo' 'clústeres o recursos de cómputo').$hostScope"
    "Se identificaron <strong>$(& $n $counts['Crítico'] 'hallazgo crítico' 'hallazgos críticos')</strong>, $(& $n $counts['Advertencia'] 'advertencia' 'advertencias') y $(& $n $counts['Info'] 'observación informativa' 'observaciones informativas'). Los dominios con menor indicador son: $(& $enc ($worst -join ' y '))."
    $(if ($counts['Crítico']) { 'Se recomienda atender los hallazgos críticos de forma prioritaria, conforme al plan de remediación de la sección 4.' } else { 'No se identificaron hallazgos críticos. Se recomienda planificar la atención de las advertencias conforme al plan de remediación.' })
    $(if ($coverage.Count) { "La evaluación presenta $(& $n $coverage.Count 'limitación de cobertura' 'limitaciones de cobertura'), detalladas en la sección 2." })
) | Where-Object { $_ }

# --- HTML ----------------------------------------------------------------------------
$scoreClass = { param($v) if ($v -ge 85) { 'ok' } elseif ($v -ge 60) { 'warn' } else { 'crit' } }
$domainHtml = ($scores.GetEnumerator() | ForEach-Object { "<div class=""score $(& $scoreClass $_.Value.score)""><div class=""v"">$($_.Value.score)</div><div class=""l"">$(& $enc $_.Key)</div><div class=""l"">$($_.Value.crit) C · $($_.Value.warn) A · $($_.Value.info) I</div></div>" }) -join ''
$countHtml = ($counts.GetEnumerator() | ForEach-Object { "<span class=""count $($sevCss[$_.Key])"">$($_.Value) $(& $enc $_.Key)</span>" }) -join ''
$top = @($scored | Where-Object { $_.severity -ne 'Info' } | Select-Object -First 5)
$topHtml = if ($top.Count) {
    '<table class="t"><thead><tr><th>ID</th><th>Severidad</th><th>Dominio</th><th>Objeto</th><th>Riesgo</th></tr></thead><tbody>' +
    (($top | ForEach-Object { "<tr><td>$($_.id)</td><td><span class=""sev $($sevCss[$_.severity])"">$(& $enc $_.severity)</span></td><td>$(& $enc $_.domain)</td><td>$(& $enc $_.object)</td><td>$(& $enc $_.risk)</td></tr>" }) -join '') + '</tbody></table>'
} else { '<p class="muted">Sin hallazgos críticos ni advertencias.</p>' }

$covRows = if ($coverage.Count) { ($coverage | ForEach-Object { "<tr><td>$(& $enc $_.object)</td><td>$(& $enc $_.evidence)</td></tr>" }) -join '' } else { '<tr><td colspan="2" class="muted">Cobertura completa.</td></tr>' }
$methodHtml = @"
<p>La evaluación se realizó mediante consultas de <strong>solo lectura</strong> a vCenter con el cliente govc, a través del wrapper controlado del proyecto. No se ejecutaron cambios en la infraestructura. Cada consulta quedó registrada en la bitácora de auditoría.</p>
<table class="t"><thead><tr><th>Fuente</th><th>Método</th><th>Elementos evaluados</th></tr></thead><tbody>
<tr><td>Inventario y configuración</td><td>object.collect en bloque · about.cert · license.ls</td><td>VMs, hosts, clústeres (HA/DRS), datastores, alarmas, snapshots, configuración de VMs, certificado de vCenter, licencias</td></tr>
<tr><td>Configuración de hosts</td><td>host.esxcli (solo list/get) · host.service.ls · host.cert.info</td><td>VIBs y drivers, NIC físicas, paths de storage, NTP, syslog, coredump, plataforma, servicios SSH/Shell, certificados de host</td></tr>
<tr><td>Controles de acceso</td><td>permissions.ls · role.ls</td><td>Asignaciones con rol Administrador en la raíz del inventario</td></tr>
</tbody></table>
<h3>Cuenta y ventana</h3>
<p>Cuenta de servicio del perfil <code>$(& $enc $Env)</code> (Windows Credential Manager). Fotografía del estado al $stamp; los valores pueden variar después de esa fecha.</p>
<h3>Limitaciones</h3>
<ul>
<li>No se evalúan sistemas operativos invitados, aplicaciones, respaldos, red física fuera del host ni seguridad perimetral.</li>
<li>La sobresuscripción se mide sobre recursos asignados, no sobre consumo histórico.</li>
<li>Las referencias a guías de seguridad son temáticas y orientativas; deben contrastarse con la versión vigente de cada documento.</li>
</ul>
<h3>Cobertura</h3>
<table class="t"><thead><tr><th>Elemento</th><th>Limitación</th></tr></thead><tbody>$covRows</tbody></table>
"@

$matrixHtml = '<table class="t"><thead><tr><th>Dominio</th><th class="n">Crítico</th><th class="n">Advertencia</th><th class="n">Info</th><th class="n">Total</th><th class="n">Indicador</th></tr></thead><tbody>' +
    (($scores.GetEnumerator() | ForEach-Object { "<tr><td>$(& $enc $_.Key)</td><td class=""n"">$($_.Value.crit)</td><td class=""n"">$($_.Value.warn)</td><td class=""n"">$($_.Value.info)</td><td class=""n"">$($_.Value.crit + $_.Value.warn + $_.Value.info)</td><td class=""n""><strong>$($_.Value.score)</strong></td></tr>" }) -join '') +
    "<tr><td><strong>Total</strong></td><td class=""n""><strong>$($counts['Crítico'])</strong></td><td class=""n""><strong>$($counts['Advertencia'])</strong></td><td class=""n""><strong>$($counts['Info'])</strong></td><td class=""n""><strong>$($scored.Count)</strong></td><td></td></tr></tbody></table>"

$findHtml = if ($scored.Count) {
    ($scored | ForEach-Object {
        $refRow = if ($_.reference) { "<dt>Referencia</dt><dd>$(& $enc $_.reference)</dd>" } else { '' }
        $cmdRow = if ($_.command) { "<dt>Verificación</dt><dd><code>$(& $enc $_.command)</code></dd>" } else { '' }
        @"
<article class="finding $($sevCss[$_.severity])">
<header><span class="id">$($_.id)</span><span class="obj">$(& $enc $_.object)</span><span class="sev $($sevCss[$_.severity])">$(& $enc $_.severity)</span><span class="dom">$(& $enc $_.domain) · $(& $enc $_.category)</span></header>
<dl><dt>Evidencia</dt><dd>$(& $enc $_.evidence)</dd><dt>Riesgo</dt><dd>$(& $enc $_.risk)</dd><dt>Recomendación</dt><dd>$(& $enc $_.suggestion)</dd>$cmdRow$refRow<dt>Fuente</dt><dd>$(& $enc $_.source)</dd></dl>
</article>
"@ }) -join "`n"
} else { '<p class="muted">No se identificaron hallazgos en el alcance evaluado.</p>' }

$remHtml = '<table class="t"><thead><tr><th>ID</th><th>Sev.</th><th>Objeto</th><th>Acción recomendada</th><th>Responsable</th><th>Fecha compromiso</th><th>Estado</th></tr></thead><tbody>' +
    (($scored | Where-Object { $_.severity -ne 'Info' } | ForEach-Object { "<tr><td>$($_.id)</td><td><span class=""sev $($sevCss[$_.severity])"">$(& $enc $_.severity.Substring(0,1))</span></td><td>$(& $enc $_.object)</td><td>$(& $enc $_.suggestion)</td><td class=""blank""></td><td class=""blank""></td><td>Abierto</td></tr>" }) -join '') +
    '</tbody></table><p class="small muted">Las observaciones informativas se incluyen en la sección 3 y pueden atenderse en el ciclo regular de mantenimiento.</p>'

function KpiTable($obj, $title) {
    if (-not $obj) { return "<p class=""muted"">$(& $enc $title): sin datos.</p>" }
    "<h3>$(& $enc $title)</h3><table class=""t""><tbody>" + (($obj.PSObject.Properties | ForEach-Object { "<tr><td>$(& $enc $_.Name)</td><td class=""n"">$(& $enc $_.Value)</td></tr>" }) -join '') + '</tbody></table>'
}
$annexHtml = @(
    (KpiTable $invSum 'A. Resumen de inventario')
    (KpiTable $hostSum 'B. Resumen de la revisión de hosts')
    $(if ($adminPrincipals.Count) { '<h3>C. Principales con rol Administrador en la raíz</h3><table class="t"><thead><tr><th>Principal</th><th>Tipo</th><th>Propaga</th></tr></thead><tbody>' + (($adminPrincipals | ForEach-Object { "<tr><td>$(& $enc $_.principal)</td><td>$(if ($_.group) { 'Grupo' } else { 'Usuario' })</td><td>$(if ($_.propagate) { 'Sí' } else { 'No' })</td></tr>" }) -join '') + '</tbody></table><p class="small muted">Información sensible: nombres de cuentas con privilegios elevados.</p>' })
    '<h3>D. Reportes de detalle</h3><ul>' + (($sources | ForEach-Object { "<li><a href=""$($_.report)"">$(& $enc $_.name)</a> — <code>$(& $enc $_.report)</code></li>" }) -join '') + '</ul>'
    '<h3>E. Comandos de recolección</h3><table class="t"><tbody>' + ((@(
        'object.collect -json -type m|h|r|c|s / &lt;propiedades&gt;', 'object.collect -json / triggeredAlarmState', 'about.cert -json', 'license.ls -json',
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
    foreach ($k in $text.Keys) { $map[$k] = & $enc $text[$k] }
    $map += @{
        EXEC_SUMMARY = (($execText | ForEach-Object { "<p>$_</p>" }) -join ''); DOMAIN_SCORES = $domainHtml; SEVERITY_COUNTS = $countHtml
        TOP_RISKS = $topHtml; METHODOLOGY = $methodHtml; MATRIX = $matrixHtml; FINDINGS = $findHtml; REMEDIATION = $remHtml; ANNEXES = $annexHtml
    }
    $html = Expand-Template (Get-Content (Join-Path $root 'templates/audit.html') -Raw) $map
    $f = Join-Path $outDir 'auditoria.html'; Set-Content $f $html -Encoding utf8; $written += $f
}
if ('md' -in $Format) {
    $esc = { param($s) ("$s" -replace "`r?`n", ' ' -replace '([\\`*_\[\]<>|#])', '\$1') }
    $strip = { param($s) ($s -replace '<[^>]+>', '') }
    $md = Expand-Template (Get-Content (Join-Path $root 'templates/audit.md') -Raw) @{
        TITLE          = "Auditoría de la plataforma vSphere — $($Env.ToUpper())"; ENV = $Env.ToUpper(); SCOPE = $scopeLabel + $clusterLabel
        DATE           = $stamp; PREPARED_BY = (& $esc $preparedBy); AUDIT_ID = $auditId; VERSION = $Version; CLASSIFICATION = $classification
        EXEC_SUMMARY   = (($execText | ForEach-Object { [System.Net.WebUtility]::HtmlDecode((& $strip $_)) }) -join "`n`n")
        DOMAIN_SCORES  = ("| Dominio | Indicador | Crítico | Advertencia | Info |`n|---|---:|---:|---:|---:|`n" + (($scores.GetEnumerator() | ForEach-Object { "| $($_.Key) | $($_.Value.score) | $($_.Value.crit) | $($_.Value.warn) | $($_.Value.info) |" }) -join "`n"))
        FINDINGS       = $(if ($scored.Count) { ($scored | ForEach-Object { "### $($_.id) · $(& $esc $_.object)`n`n| | |`n|---|---|`n| Severidad | $($_.severity) |`n| Dominio | $($_.domain) · $($_.category) |`n| Evidencia | $(& $esc $_.evidence) |`n| Riesgo | $(& $esc $_.risk) |`n| Recomendación | $(& $esc $_.suggestion) |$(if ($_.command) { "`n| Verificación | $(Format-MdCode ("$($_.command)" -replace '\|', '\|')) |" })$(if ($_.reference) { "`n| Referencia | $(& $esc $_.reference) |" })" }) -join "`n`n" } else { 'No se identificaron hallazgos.' })
        REMEDIATION    = ("| ID | Severidad | Objeto | Acción | Responsable | Fecha | Estado |`n|---|---|---|---|---|---|---|`n" + (($scored | Where-Object { $_.severity -ne 'Info' } | ForEach-Object { "| $($_.id) | $($_.severity) | $(& $esc $_.object) | $(& $esc $_.suggestion) |  |  | Abierto |" }) -join "`n"))
        COVERAGE       = $(if ($coverage.Count) { ($coverage | ForEach-Object { "- $(& $esc $_.object): $(& $esc $_.evidence)" }) -join "`n" } else { 'Cobertura completa.' })
    }
    $f = Join-Path $outDir 'auditoria.md'; Set-Content $f $md -Encoding utf8; $written += $f
}

[ordered]@{ id = $auditId; env = $Env; generated = $generated.ToString('o'); scope = $Scope; cluster = @($Cluster); scores = $scores; counts = $counts; findings = $scored; coverage = $coverage } |
    ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'raw/audit.json') -Encoding utf8

[pscustomobject]@{ Auditoria = $auditId; Carpeta = $outDir; Archivos = $written; Criticos = $counts['Crítico']; Advertencias = $counts['Advertencia']; Indicadores = (($scores.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value.score)" }) -join ' · ') }
