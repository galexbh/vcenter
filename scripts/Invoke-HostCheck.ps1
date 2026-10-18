<#
.SYNOPSIS
  "Ronda de técnicos": revisa la configuración de cada host y compara entre hosts (drift). Solo lectura.

.DESCRIPTION
  Una consulta object.collect trae la lista de hosts y, de paso, lo que vCenter ya conoce de cada
  uno: plataforma (fabricante/modelo), servicios (SSH, ESXi Shell, ntpd), NTP
  (config.dateTimeInfo) y certificado (config.certificate). Lo que solo sabe el host se pregunta
  por `host.esxcli` (vía vCenter, sin SSH): VIBs/drivers, NIC físicas, paths de storage, syslog
  remoto y coredump. Las consultas esxcli se ordenan alternando hosts para repartir la carga.
  Detecta drift de VIBs/drivers, NIC sin link o con velocidad/MTU distinta, paths muertos o sin
  redundancia, NTP, syslog remoto, coredump, SSH/Shell encendidos, diferencias de plataforma y
  vencimiento del certificado de cada host. Salida en reports/<env>/<marca>/hosts-check.{html,md,csv}.
  Matices frente a esxcli: NTP se evalúa por el servicio ntpd (en ejecución) y el certificado no
  trae el campo 'status'.

.EXAMPLE
  ./scripts/Invoke-HostCheck.ps1 -Env prod -Cluster CL-PROD-01
  ./scripts/Invoke-HostCheck.ps1 -Env prod -Hosts esx01.example.local, esx02.example.local -Checks nics, paths
  ./scripts/Invoke-HostCheck.ps1 -FromRaw reports/prod/20261016-100000
#>
#Requires -Version 7.5
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$Env,
    [string[]]$Cluster,
    [string[]]$Hosts,
    [ValidateSet('vibs', 'nics', 'paths', 'ntp', 'syslog', 'coredump', 'platform', 'services', 'certs')]
    [string[]]$Checks = @('vibs', 'nics', 'paths', 'ntp', 'syslog', 'coredump', 'platform', 'services', 'certs'),
    [ValidateSet('html', 'md', 'csv')][string[]]$Format = @('html', 'md'),
    [string]$FromRaw,
    [string]$OutDir,
    [ValidateRange(1, 3650)][int]$CertWarnDays = 60,
    [ValidateRange(1, 100000)][int]$MdMaxRows = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/GovcJson.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Render.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Set-Alias -Name P -Value Get-Prop -Scope Script
Set-Alias -Name F -Value Get-FirstProp -Scope Script

# Lo que solo sabe el host: se pregunta por esxcli. El resto sale del object.collect de hosts.
$esxcliCmd = [ordered]@{
    vibs     = @('software', 'vib', 'list')
    nics     = @('network', 'nic', 'list')
    paths    = @('storage', 'core', 'path', 'list')
    syslog   = @('system', 'syslog', 'config', 'get')
    coredump = @('system', 'coredump', 'network', 'get')
}
$hostProps = @('name', 'parent', 'runtime.connectionState', 'summary.hardware.vendor', 'summary.hardware.model',
    'config.service', 'config.dateTimeInfo.ntpConfig', 'config.certificate')

function ConvertFrom-EsxcliJson {
    <# Normaliza la salida JSON de host.esxcli: {values:[{Campo:[valor]}]} → objetos planos. #>
    param([string]$Text)
    $o = $Text | ConvertFrom-Json -DateKind String
    $values = if ($o.PSObject.Properties['values']) { $o.values } elseif ($o.PSObject.Properties['Values']) { $o.Values } else { @($o) }
    foreach ($v in @($values)) {
        $row = [ordered]@{}
        foreach ($p in $v.PSObject.Properties) {
            $val = $p.Value
            if ($val -is [array] -and $val.Count -eq 1) { $val = $val[0] }
            $row[$p.Name] = $val
        }
        [pscustomobject]$row
    }
}

function Get-HostCertRow($b64) {
    # config.certificate: PEM codificado en base64 (bytes). Sin 'status' (dato de host.cert.info).
    $t = "$(@($b64)[0])"
    if (-not $t) { return $null }
    try {
        $pem = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($t))
        $x = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($pem)
        [pscustomobject]@{ subject = $x.Subject; issuer = $x.Issuer; notAfter = $x.NotAfter.ToUniversalTime().ToString('o'); status = '' }
    } catch { $null }
}

function Get-VcenterRows([string]$check, $h) {
    # Filas con la misma forma que dejaban las consultas por host (compatibilidad con -FromRaw).
    switch ($check) {
        'platform' {
            $v = P $h 'summary.hardware.vendor'; $m = P $h 'summary.hardware.model'
            if (-not $v -and -not $m) { throw 'summary.hardware sin datos' }
            return , @([pscustomobject]@{ VendorName = "$v"; ProductName = "$m" })
        }
        'services' {
            $svc = @(P (P $h 'config.service') 'service' @())
            if (-not $svc.Count) { throw 'config.service sin datos' }
            return , @($svc | ForEach-Object { [pscustomobject]@{ key = "$(P $_ 'key' '')"; running = [bool](P $_ 'running' $false); policy = "$(P $_ 'policy' '')" } })
        }
        'ntp' {
            $cfg = P $h 'config.dateTimeInfo.ntpConfig'
            if ($null -eq $cfg) { throw 'config.dateTimeInfo no disponible' }
            $ntpd = @(P (P $h 'config.service') 'service' @()) | Where-Object { (P $_ 'key') -eq 'ntpd' } | Select-Object -First 1
            return , @([pscustomobject]@{ Enabled = $(if ($ntpd -and [bool](P $ntpd 'running' $false)) { 'true' } else { 'false' }); Server = @(P $cfg 'server' @()) })
        }
        'certs' {
            $r = Get-HostCertRow (P $h 'config.certificate')
            if (-not $r) { throw 'config.certificate sin datos' }
            return , @($r)
        }
    }
}

# --- Recolección --------------------------------------------------------------------
$ctx = Initialize-RunContext -Env $Env -FromRaw $FromRaw -OutDir $OutDir -Root $root -MetaFile 'meta-hosts.json'
$Env = $ctx.env; $outDir = $ctx.outDir; $rawDir = $ctx.rawDir; $generated = $ctx.generated
if ($ctx.fromRaw) {
    $hostList = Read-JsonFile (Join-Path $rawDir 'esxcli-hosts.json') @() -AsArray
    $results = @{}
    foreach ($c in $Checks) { $results[$c] = Read-JsonFile (Join-Path $rawDir "esxcli-$c.json") @() -AsArray }
} else {
    Import-Module (Join-Path $PSScriptRoot 'lib/GovcBatch.psm1') -Force
    [Console]::Error.WriteLine('Listando hosts y su configuración conocida por vCenter...')
    $inv = Invoke-GovcBatch -Env $Env -Commands @(
        , (@('object.collect', '-json', '-type', 'h', '/') + $hostProps)
        , @('object.collect', '-json', '-type', 'r', '/', 'name'))
    if ($inv[0].exitCode -ne 0) { throw "Falló object.collect de hosts: $(Get-GovcBatchError $inv[0])" }
    $hRaw = @($inv[0].stdout | ConvertFrom-GovcCollect)
    $crName = @{}; foreach ($c in @($inv[1].stdout | ConvertFrom-GovcCollect)) { $crName[$c._moref] = $c.name }

    $byName = @{}
    $hostList = @($hRaw | ForEach-Object {
            $byName[$_.name] = $_
            [pscustomobject]@{ id = $_._moref; name = $_.name; cluster = $crName[$_.parent.value]; state = P $_ 'runtime.connectionState' '' } } |
        Where-Object { (-not $Cluster -or $_.cluster -in $Cluster) -and (-not $Hosts -or $_.name -in $Hosts) } |
        Sort-Object cluster, name)
    if (-not $hostList.Count) { throw 'Ningún host coincide con el filtro.' }

    $results = @{}
    foreach ($c in $Checks) { $results[$c] = New-Object System.Collections.Generic.List[object] }
    $connected = @($hostList | Where-Object state -eq 'connected')
    foreach ($h in $hostList | Where-Object state -ne 'connected') {
        foreach ($c in $Checks) { $results[$c].Add([pscustomobject]@{ host = $h.name; cluster = $h.cluster; ok = $false; error = "host $($h.state)"; rows = @() }) }
    }
    # Chequeos que vCenter ya conoce: sin consultas adicionales.
    foreach ($c in @($Checks | Where-Object { -not $esxcliCmd.Contains($_) })) {
        foreach ($h in $connected) {
            $e = [pscustomobject]@{ host = $h.name; cluster = $h.cluster; ok = $true; error = ''; rows = @() }
            try { $e.rows = Get-VcenterRows $c $byName[$h.name] } catch { $e.ok = $false; $e.error = $_.Exception.Message }
            $results[$c].Add($e)
        }
    }
    # esxcli: ordenado por chequeo y luego por host, para alternar hosts (no concentra carga en un hostd).
    $jobs = @(foreach ($c in @($Checks | Where-Object { $esxcliCmd.Contains($_) })) {
            foreach ($h in $connected) { [pscustomobject]@{ host = $h; check = $c; argv = @('host.esxcli', '-json', '-host', $h.name) + $esxcliCmd[$c] } }
        })
    $out = @()
    if ($jobs.Count) {
        [Console]::Error.WriteLine("Consultando esxcli: $($connected.Count) hosts × $(@($jobs.check | Sort-Object -Unique).Count) chequeos ($($jobs.Count) consultas, una sesión)...")
        $out = Invoke-GovcBatch -Env $Env -Commands @(foreach ($j in $jobs) { , $j.argv })
    }
    for ($k = 0; $k -lt $jobs.Count; $k++) {
        $h = $jobs[$k].host; $c = $jobs[$k].check; $r = $out[$k]
        $code = $r.exitCode; $text = "$($r.stdout)"
        $entry = [pscustomobject]@{ host = $h.name; cluster = $h.cluster; ok = ($code -eq 0); error = $(if ($code) { Get-GovcBatchError $r } else { '' }); rows = @() }
        if ($code -eq 0 -and $text.Trim()) {
            try { $entry.rows = @(ConvertFrom-EsxcliJson $text) } catch { $entry.ok = $false; $entry.error = "salida no reconocida: $($_.Exception.Message)" }
        }
        $results[$c].Add($entry)
    }

    Save-RawJson $hostList (Join-Path $rawDir 'esxcli-hosts.json')
    foreach ($c in $Checks) { Save-RawJson $results[$c] (Join-Path $rawDir "esxcli-$c.json") }
    Write-RunMeta (Join-Path $rawDir 'meta-hosts.json') $Env $generated @{ checks = $Checks }
}

# --- Análisis ---------------------------------------------------------------------------
$findings = New-FindingList
$rc = { param([string[]]$a) New-ReviewCommand -Env $Env -Arguments $a }
$sections = New-Object System.Collections.Generic.List[object]
# Filas correctas por chequeo, calculadas una sola vez (antes se refiltraban en cada grupo).
$okBy = @{}; foreach ($c in $Checks) { $okBy[$c] = @($results[$c] | Where-Object ok) }
$yesNo = { param($b) if ($b) { 'Sí' } else { 'No' } }

# Hosts que no respondieron un chequeo (permisos, versión, host caído): un hallazgo por chequeo y causa.
foreach ($c in $Checks) {
    Add-CoverageByError -List $findings -Rule "coverage-$c" -Entries @($results[$c] | Where-Object { -not $_.ok }) -What "Chequeo '$c'" `
        -Suggestion 'Verificar estado de los hosts, la versión de ESXi o los privilegios de la cuenta de servicio sobre la configuración del host.'
}

if ('vibs' -in $Checks) {
    $hostsPerCl = @{}; foreach ($e in $okBy['vibs']) { $hostsPerCl["$($e.cluster)"] = 1 + [int]$hostsPerCl["$($e.cluster)"] }
    $vibRows = foreach ($e in $okBy['vibs']) { foreach ($r in @($e.rows)) { [pscustomobject]@{ cluster = $e.cluster; host = $e.host; name = F $r 'Name'; version = F $r 'Version'; vendor = F $r 'Vendor' } } }
    $drift = foreach ($g in @($vibRows | Group-Object cluster, name)) {
        $cl = $g.Group[0].cluster
        $versions = @($g.Group | Group-Object version)
        $missing = [int]$hostsPerCl["$cl"] - @($g.Group.host | Sort-Object -Unique).Count
        if ($versions.Count -gt 1 -or $missing -gt 0) {
            [pscustomobject]@{
                cluster  = $cl; name = $g.Group[0].name
                versions = ($versions | ForEach-Object { "$($_.Name) ($((($_.Group.host) | Sort-Object) -join ', '))" }) -join ' · '
                missing  = $missing
            }
        }
    }
    $drift = @($drift | Sort-Object cluster, name)
    foreach ($d in $drift) {
        $ev = if ($d.missing -gt 0) { "Falta en $($d.missing) host(s). Versiones: $($d.versions)" } else { "Versiones distintas: $($d.versions)" }
        Add-ReportFinding -Rule 'vib-drift' $findings 'Advertencia' 'Drift VIBs/drivers' "$($d.cluster) / $($d.name)" $ev 'Homologar con vLCM/baseline del clúster; versiones distintas pueden romper vMotion, HA o soporte del fabricante.' (& $rc 'host.esxcli', '-host', '<host>', 'software', 'vib', 'get', '-n', $d.name)
    }
    $sections.Add((New-ReportTable 'Drift de VIBs y drivers' @('cluster:Clúster', 'name:VIB', 'versions:Versiones (hosts)', 'missing:Hosts sin el VIB') $drift 'Solo se listan VIBs que no son idénticos en todos los hosts del clúster.'))
}

if ('nics' -in $Checks) {
    $nicRows = @($(foreach ($e in $okBy['nics']) { foreach ($r in @($e.rows)) {
                [pscustomobject]@{
                    cluster = $e.cluster; host = $e.host; nic = F $r 'Name'; driver = F $r 'Driver'
                    admin = F $r 'AdminStatus'; link = F $r @('LinkStatus', 'Link'); speed = F $r 'Speed'; duplex = F $r 'Duplex'; mtu = F $r 'MTU'
                } } }) | Sort-Object cluster, host, nic)
    foreach ($n in $nicRows | Where-Object { $_.admin -match '^up$' -and $_.link -notmatch '^up$' }) {
        Add-ReportFinding -Rule 'nic-nolink' $findings 'Advertencia' 'Red física' "$($n.host) / $($n.nic)" "NIC habilitada sin link (link: $($n.link))" 'Revisar cable/puerto del switch; si la NIC está en un vSwitch/DVS, hay pérdida de redundancia.' (& $rc 'host.esxcli', '-host', $n.host, 'network', 'nic', 'get', '-n', $n.nic)
    }
    foreach ($g in @($nicRows | Where-Object { $_.link -match '^up$' } | Group-Object cluster, nic)) {
        $speeds = @($g.Group | Group-Object speed)
        if ($speeds.Count -gt 1) {
            Add-ReportFinding -Rule 'nic-speed' $findings 'Advertencia' 'Red física' "$($g.Group[0].cluster) / $($g.Group[0].nic)" "Velocidad distinta entre hosts: $(($speeds | ForEach-Object { "$($_.Name) Mb ($(($_.Group.host) -join ', '))" }) -join ' · ')" 'Verificar negociación y configuración de puertos; afecta vMotion y balanceo.'
        }
        $mtus = @($g.Group | Group-Object mtu)
        if ($mtus.Count -gt 1) {
            Add-ReportFinding -Rule 'nic-mtu' $findings 'Advertencia' 'Red física' "$($g.Group[0].cluster) / $($g.Group[0].nic)" "MTU distinto entre hosts: $(($mtus | ForEach-Object { "$($_.Name) ($(($_.Group.host) -join ', '))" }) -join ' · ')" 'MTU inconsistente rompe jumbo frames (vMotion, iSCSI, vSAN).'
        }
    }
    $sections.Add((New-ReportTable 'NIC físicas' @('cluster:Clúster', 'host:Host', 'nic:NIC', 'driver:Driver', 'admin:Admin', 'link:Link', 'speed:Mb/s', 'duplex:Dúplex', 'mtu:MTU') $nicRows))
}

if ('paths' -in $Checks) {
    $shared = '^(fc|iscsi|fcoe|nvme(of)?|tcp|rdma)'
    $pathSummary = @(foreach ($e in $okBy['paths']) {
            # Una sola pasada por host: contadores y paths por dispositivo de transporte compartido.
            $devices = @{}; $perDev = @{}; $active = 0; $standby = 0; $dead = 0; $n = 0
            foreach ($row in @($e.rows)) {
                $n++
                $dev = F $row 'Device'; $state = "$(F $row 'State')".ToLowerInvariant(); $tr = "$(F $row 'Transport')".ToLowerInvariant()
                $devices[$dev] = $true
                switch ($state) { 'active' { $active++ } 'standby' { $standby++ } 'dead' { $dead++ } }
                if ($state -eq 'dead') {
                    Add-ReportFinding -Rule 'path-dead' $findings 'Crítico' 'Storage' "$($e.host) / $dev" "Path muerto: $(F $row 'RuntimeName') ($tr)" 'Revisar zoning/fabric, HBA o target; escalar a Storage.' (& $rc 'host.esxcli', '-host', $e.host, 'storage', 'core', 'path', 'list', '-d', $dev)
                }
                if ($tr -match $shared) {
                    if (-not $perDev[$dev]) { $perDev[$dev] = [pscustomobject]@{ count = 0; transport = $tr } }
                    $perDev[$dev].count++
                }
            }
            foreach ($dev in $perDev.Keys) {
                if ($perDev[$dev].count -eq 1) {
                    Add-ReportFinding -Rule 'path-single' $findings 'Advertencia' 'Storage' "$($e.host) / $dev" "Un solo path ($($perDev[$dev].transport))" 'Sin redundancia de ruta: un fallo de HBA/switch deja el LUN inaccesible.' (& $rc 'host.esxcli', '-host', $e.host, 'storage', 'nmp', 'device', 'list', '-d', $dev)
                }
            }
            [pscustomobject]@{ cluster = $e.cluster; host = $e.host; devices = $devices.Count; paths = $n; active = $active; standby = $standby; dead = $dead }
        })
    $sections.Add((New-ReportTable 'Paths de storage' @('cluster:Clúster', 'host:Host', 'devices:Dispositivos', 'paths:Paths', 'active:Activos', 'standby:Standby', 'dead:Muertos') $pathSummary))
}

$sysRows = @{}
function SysRow($e) { if (-not $sysRows[$e.host]) { $sysRows[$e.host] = [ordered]@{ cluster = $e.cluster; host = $e.host; ntp = ''; ntpServers = ''; syslog = ''; coredump = ''; platform = ''; ssh = ''; shell = '' } }; return $sysRows[$e.host] }

if ('ntp' -in $Checks) {
    $ntpRows = foreach ($e in $okBy['ntp']) {
        $r = @($e.rows)[0]; $enabled = "$(F $r 'Enabled')"; $servers = @(F $r @('Server', 'Servers') @()) -join ', '
        $s = SysRow $e; $s.ntp = $enabled; $s.ntpServers = $servers
        if ($enabled -notmatch '^true$') { Add-ReportFinding -Rule 'ntp-disabled' $findings 'Advertencia' 'Tiempo' $e.host 'NTP deshabilitado (servicio ntpd detenido)' 'Hora inconsistente afecta logs, Kerberos/AD, certificados y correlación de eventos.' (& $rc 'host.date.info', '-host', $e.host) }
        [pscustomobject]@{ cluster = $e.cluster; host = $e.host; servers = $servers }
    }
    foreach ($g in @($ntpRows | Group-Object cluster)) {
        $distinct = @($g.Group | Group-Object servers)
        if ($distinct.Count -gt 1) { Add-ReportFinding -Rule 'ntp-servers' $findings 'Advertencia' 'Tiempo' $g.Name "Servidores NTP distintos: $(($distinct | ForEach-Object { "[$($_.Name)] ($(($_.Group.host) -join ', '))" }) -join ' · ')" 'Homologar fuentes NTP en el clúster.' }
    }
}
if ('syslog' -in $Checks) {
    foreach ($e in $okBy['syslog']) {
        $r = @($e.rows)[0]; $remote = "$(F $r @('RemoteHost', 'Remotehost', 'LogHost'))"
        (SysRow $e).syslog = $remote
        if (-not $remote -or $remote -match '^<?none>?$') { Add-ReportFinding -Rule 'syslog-remote' $findings 'Advertencia' 'Logs' $e.host 'Sin syslog remoto' 'Los logs quedan solo en el host: se pierden ante falla y no llegan al SIEM. Validar con Seguridad de la Información.' (& $rc 'host.esxcli', '-host', $e.host, 'system', 'syslog', 'config', 'get') }
    }
}
if ('coredump' -in $Checks) {
    foreach ($e in $okBy['coredump']) {
        $r = @($e.rows)[0]; $en = "$(F $r 'Enabled')"
        (SysRow $e).coredump = if ($en -match '^true$') { "red $(F $r @('NetworkServerIP', 'NetworkServerIPv4'))" } else { 'red: no' }
        if ($en -notmatch '^true$') { Add-ReportFinding -Rule 'coredump' $findings 'Info' 'Diagnóstico' $e.host 'Coredump por red no configurado' 'Verificar que exista partición/archivo de coredump local; sin destino, un PSOD no deja evidencia para soporte.' (& $rc 'host.esxcli', '-host', $e.host, 'system', 'coredump', 'partition', 'get') }
    }
}
if ('platform' -in $Checks) {
    $plat = foreach ($e in $okBy['platform']) {
        $r = @($e.rows)[0]; $model = "$(F $r 'VendorName') $(F $r 'ProductName')".Trim()
        (SysRow $e).platform = $model
        [pscustomobject]@{ cluster = $e.cluster; host = $e.host; model = $model }
    }
    foreach ($g in @($plat | Group-Object cluster)) {
        $m = @($g.Group | Group-Object model)
        if ($m.Count -gt 1) { Add-ReportFinding -Rule 'platform-mixed' $findings 'Info' 'Plataforma' $g.Name "Modelos distintos: $(($m | ForEach-Object { "$($_.Name) ($(($_.Group.host) -join ', '))" }) -join ' · ')" 'Revisar compatibilidad EVC y homogeneidad para HA/DRS.' }
    }
}
if ('services' -in $Checks) {
    foreach ($e in $okBy['services']) {
        $svc = @($e.rows)
        foreach ($k in 'TSM-SSH', 'TSM') {
            $s = $svc | Where-Object { (P $_ 'key') -eq $k } | Select-Object -First 1
            $running = [bool](P $s 'running' $false)
            $label = if ($k -eq 'TSM-SSH') { 'SSH' } else { 'ESXi Shell' }
            $row = SysRow $e; if ($k -eq 'TSM-SSH') { $row.ssh = & $yesNo $running } else { $row.shell = & $yesNo $running }
            if ($running) { Add-ReportFinding -Rule "svc-$($k.ToLowerInvariant())" $findings 'Advertencia' 'Seguridad' $e.host "$label en ejecución (política: $(P $s 'policy' '?'))" "Mantener $label detenido salvo ventana de soporte; es superficie de ataque. Validar con Seguridad de la Información." (& $rc 'host.service.ls', '-host', $e.host) }
        }
    }
}
if ('certs' -in $Checks) {
    $certRows = @(foreach ($e in $okBy['certs']) {
            $r = @($e.rows)[0]; if (-not $r) { continue }
            $na = $null; try { $na = ([datetimeoffset]::Parse("$($r.notAfter)", [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { }
            $daysLeft = if ($na) { [math]::Floor(($na - $generated).TotalDays) } else { $null }
            if ($null -ne $daysLeft -and $daysLeft -lt 0) {
                Add-ReportFinding -Rule 'cert-host-expired' $findings 'Crítico' 'Certificados' $e.host "Certificado vencido el $($na.ToString('yyyy-MM-dd'))" 'Renovar el certificado del host (VMCA o CA interna) mediante cambio aprobado.' (& $rc 'host.cert.info', '-host', $e.host)
            } elseif ($null -ne $daysLeft -and $daysLeft -le $CertWarnDays) {
                Add-ReportFinding -Rule 'cert-host-expiring' $findings 'Advertencia' 'Certificados' $e.host "Certificado vence en $daysLeft días ($($na.ToString('yyyy-MM-dd')))" 'Planificar la renovación antes del vencimiento.' (& $rc 'host.cert.info', '-host', $e.host)
            }
            [pscustomobject]@{ cluster = $e.cluster; host = $e.host; subject = $r.subject; issuer = $r.issuer; notAfter = $(if ($na) { $na.ToString('yyyy-MM-dd') } else { '' }); days = $daysLeft; status = $r.status }
        })
    $sections.Add((New-ReportTable 'Certificados de host' @('cluster:Clúster', 'host:Host', 'subject:Sujeto', 'issuer:Emisor', 'notAfter:Vence', 'days:Días restantes', 'status:Estado') @($certRows | Sort-Object days, host) "Umbral de advertencia: $CertWarnDays días."))
}
if ($sysRows.Count) {
    $sections.Add((New-ReportTable 'Configuración del sistema' @('cluster:Clúster', 'host:Host', 'ntp:NTP', 'ntpServers:Servidores NTP', 'syslog:Syslog remoto', 'coredump:Coredump', 'platform:Plataforma', 'ssh:SSH', 'shell:Shell') (@($sysRows.Values | ForEach-Object { [pscustomobject]$_ } | Sort-Object cluster, host))))
}

$sorted = Sort-ReportFinding $findings
$sections.Insert(0, (New-ReportTable 'Hallazgos y sugerencias' (Get-FindingColumns) $sorted 'Consultas de solo lectura vía vCenter (object.collect y esxcli list/get). Los comandos son propuestas de revisión; ningún cambio se ejecutó.'))

$kpis = [ordered]@{
    'Hosts'     = $hostList.Count
    'Clústeres' = @($hostList.cluster | Sort-Object -Unique).Count
    'Chequeos'  = $Checks.Count
}
Add-SeverityKpis $kpis $sorted -Coverage
Complete-Report -Root $root -OutDir $outDir -RawDir $rawDir -BaseName 'hosts-check' -Title "Revisión de hosts — $($Env.ToUpper())" `
    -Env $Env -Generated $generated -Kpis $kpis -Sorted $sorted -Sections $sections.ToArray() -Format $Format -MdMaxRows $MdMaxRows `
    -Source 'govc object.collect + host.esxcli list/get (solo lectura)'
