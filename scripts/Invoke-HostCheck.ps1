<#
.SYNOPSIS
  "Ronda de técnicos": consulta esxcli de solo lectura en cada host y compara entre hosts (drift).

.DESCRIPTION
  govc ve el edificio; esxcli conoce cada piso. Este script obtiene la lista de hosts con una
  llamada object.collect y luego pregunta lo mismo a cada host vía `host.esxcli` (por vCenter,
  sin SSH), en secuencia. Detecta: drift de VIBs/drivers, NIC sin link o con velocidad distinta,
  paths de storage muertos o sin redundancia, NTP, syslog remoto, coredump, SSH/Shell encendidos,
  diferencias de plataforma y vencimiento del certificado de cada host (chequeo certs, vía
  host.cert.info). Solo lectura. Salida en reports/<env>/<marca>/hosts-check.{html,md}.

.EXAMPLE
  ./scripts/Invoke-HostCheck.ps1 -Env prod -Cluster CL-PROD-01
  ./scripts/Invoke-HostCheck.ps1 -Env prod -Hosts esx01.example.local, esx02.example.local -Checks nics, paths
  ./scripts/Invoke-HostCheck.ps1 -FromRaw reports/prod/20261016-100000
#>
param(
    [string]$Env,
    [string[]]$Cluster,
    [string[]]$Hosts,
    [ValidateSet('vibs', 'nics', 'paths', 'ntp', 'syslog', 'coredump', 'platform', 'services', 'certs')]
    [string[]]$Checks = @('vibs', 'nics', 'paths', 'ntp', 'syslog', 'coredump', 'platform', 'services', 'certs'),
    [ValidateSet('html', 'md')][string[]]$Format = @('html', 'md'),
    [string]$FromRaw,
    [string]$OutDir,
    [int]$CertWarnDays = 60,
    [int]$MdMaxRows = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/GovcJson.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/Render.psm1') -Force -DisableNameChecking
$wrapper = Join-Path $PSScriptRoot 'govc.ps1'

# Qué se le pregunta a cada técnico. 'govc' = comando nativo cuando vCenter ya lo sabe.
$checkCmd = [ordered]@{
    vibs     = @('host.esxcli', 'software', 'vib', 'list')
    nics     = @('host.esxcli', 'network', 'nic', 'list')
    paths    = @('host.esxcli', 'storage', 'core', 'path', 'list')
    ntp      = @('host.esxcli', 'system', 'ntp', 'get')
    syslog   = @('host.esxcli', 'system', 'syslog', 'config', 'get')
    coredump = @('host.esxcli', 'system', 'coredump', 'network', 'get')
    platform = @('host.esxcli', 'hardware', 'platform', 'get')
    services = @('host.service.ls')
    certs    = @('host.cert.info')
}

function P($obj, [string]$name, $default = $null) {
    if ($null -ne $obj -and $obj.PSObject.Properties[$name] -and $null -ne $obj.$name) { return $obj.$name }
    return $default
}

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

function ConvertFrom-HostServiceJson {
    <# host.service.ls -json: busca los objetos de servicio (con 'key' y 'running') donde estén anidados. #>
    param([string]$Text)
    $stack = New-Object System.Collections.Stack
    $stack.Push(($Text | ConvertFrom-Json))
    while ($stack.Count) {
        $n = $stack.Pop()
        if ($n -is [array]) { foreach ($x in $n) { $stack.Push($x) }; continue }
        if ($n -isnot [pscustomobject]) { continue }
        if ($n.PSObject.Properties['key'] -and $n.PSObject.Properties['running']) {
            [pscustomobject]@{ key = $n.key; running = [bool]$n.running; policy = P $n 'policy' '' }
            continue
        }
        foreach ($p in $n.PSObject.Properties) { $stack.Push($p.Value) }
    }
}

function ConvertFrom-HostCertJson {
    <# host.cert.info -json: extrae sujeto, emisor, vencimiento y estado donde estén anidados. #>
    # La salida incluye la clave pública como entero gigante (no parseable): se extraen solo los
    # campos de primer nivel, que van en minúscula (los de la cadena de certificados, en mayúscula).
    param([string]$Text)
    $get = { param($k) $m = [regex]::Match($Text, '"' + $k + '"\s*:\s*"([^"]*)"'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
    $na = & $get 'notAfter'
    if (-not $na) { return }
    [pscustomobject]@{ subject = & $get 'subject'; issuer = & $get 'issuer'; notAfter = $na; status = & $get 'status' }
}

function F($row, [string[]]$names, $default = '') {
    # Primer campo existente entre variantes de nombre (cambian entre versiones de ESXi).
    foreach ($n in $names) { $v = P $row $n; if ($null -ne $v -and "$v" -ne '') { return $v } }
    return $default
}

# --- Recolección --------------------------------------------------------------------
if ($FromRaw) {
    $outDir = (Resolve-Path $FromRaw).Path
    $rawDir = Join-Path $outDir 'raw'
    $meta = Get-Content (Join-Path $rawDir 'meta-hosts.json') -Raw | ConvertFrom-Json
    $Env = $meta.env; $generated = [datetime]$meta.generated
    $hostList = @(Get-Content (Join-Path $rawDir 'esxcli-hosts.json') -Raw | ConvertFrom-Json)
    $results = @{}
    foreach ($c in $Checks) {
        $f = Join-Path $rawDir "esxcli-$c.json"
        $results[$c] = if (Test-Path $f) { @(Get-Content $f -Raw | ConvertFrom-Json -DateKind String) } else { @() }
    }
} else {
    if (-not $Env) { throw 'Indica -Env <entorno> o -FromRaw <carpeta>.' }
    $Env = $Env.ToLowerInvariant()
    $generated = Get-Date
    $outDir = if ($OutDir) { $OutDir } else { Join-Path $root ("reports/{0}/{1:yyyyMMdd-HHmmss}" -f $Env, $generated) }
    $rawDir = Join-Path $outDir 'raw'
    New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

    # Primer lote (una sesión): conocer el edificio, hosts + clúster.
    Import-Module (Join-Path $PSScriptRoot 'lib/GovcBatch.psm1') -Force
    [Console]::Error.WriteLine('Listando hosts...')
    $inv = Invoke-GovcBatch -Env $Env -Commands @(
        , @('object.collect', '-json', '-type', 'h', '/', 'name', 'parent', 'runtime.connectionState')
        , @('object.collect', '-json', '-type', 'r', '/', 'name'))
    if ($inv[0].exitCode -ne 0) { throw "Falló object.collect de hosts: $(Get-GovcBatchError $inv[0])" }
    $hRaw = @($inv[0].stdout | ConvertFrom-GovcCollect)
    $crName = @{}; foreach ($c in @($inv[1].stdout | ConvertFrom-GovcCollect)) { $crName[$c._moref] = $c.name }

    $hostList = @($hRaw | ForEach-Object {
            [pscustomobject]@{ name = $_.name; cluster = $crName[$_.parent.value]; state = P $_ 'runtime.connectionState' '' } } |
        Where-Object { (-not $Cluster -or $_.cluster -in $Cluster) -and (-not $Hosts -or $_.name -in $Hosts) } |
        Sort-Object cluster, name)
    if (-not $hostList.Count) { throw 'Ningún host coincide con el filtro.' }

    $results = @{}
    foreach ($c in $Checks) { $results[$c] = New-Object System.Collections.Generic.List[object] }

    # Segundo lote (una sesión): todos los chequeos de todos los hosts conectados.
    $jobs = @(foreach ($h in $hostList | Where-Object state -eq 'connected') {
            foreach ($c in $Checks) { $cmd = $checkCmd[$c]; [pscustomobject]@{ host = $h; check = $c; argv = @($cmd[0], '-json', '-host', $h.name) + @($cmd | Select-Object -Skip 1) } }
        })
    $out = @()
    if ($jobs.Count) {
        [Console]::Error.WriteLine("Consultando $(@($hostList | Where-Object state -eq 'connected').Count) hosts × $($Checks.Count) chequeos ($($jobs.Count) consultas, una sesión)...")
        $out = Invoke-GovcBatch -Env $Env -Commands @(foreach ($j in $jobs) { , $j.argv })
    }
    foreach ($h in $hostList | Where-Object state -ne 'connected') {
        foreach ($c in $Checks) { $results[$c].Add([pscustomobject]@{ host = $h.name; cluster = $h.cluster; ok = $false; error = "host $($h.state)"; rows = @() }) }
    }
    for ($k = 0; $k -lt $jobs.Count; $k++) {
        $h = $jobs[$k].host; $c = $jobs[$k].check; $r = $out[$k]
        $code = $r.exitCode; $text = "$($r.stdout)"
        $entry = [pscustomobject]@{ host = $h.name; cluster = $h.cluster; ok = ($code -eq 0); error = $(if ($code) { Get-GovcBatchError $r } else { '' }); rows = @() }
            if ($code -eq 0 -and $text.Trim()) {
                try {
                    $entry.rows = switch ($c) { 'services' { @(ConvertFrom-HostServiceJson $text) } 'certs' { @(ConvertFrom-HostCertJson $text) } default { @(ConvertFrom-EsxcliJson $text) } }
                } catch { $entry.ok = $false; $entry.error = "salida no reconocida: $($_.Exception.Message)" }
            }
            $results[$c].Add($entry)
    }

    ConvertTo-Json -InputObject $hostList -Depth 5 | Set-Content (Join-Path $rawDir 'esxcli-hosts.json') -Encoding utf8
    # .ToArray(): en PowerShell 7.6, ConvertTo-Json falla con @(List[object]) de objetos anidados.
    foreach ($c in $Checks) { ConvertTo-Json -InputObject $results[$c].ToArray() -Depth 12 | Set-Content (Join-Path $rawDir "esxcli-$c.json") -Encoding utf8 }
    @{ env = $Env; generated = $generated.ToString('o'); user = "$env:USERDOMAIN\$env:USERNAME"; checks = $Checks } |
        ConvertTo-Json | Set-Content (Join-Path $rawDir 'meta-hosts.json') -Encoding utf8
}

# --- Análisis ---------------------------------------------------------------------------
$findings = New-FindingList
$w = "./scripts/govc.ps1 -Env $Env"
$sections = New-Object System.Collections.Generic.List[object]
$ok = { param($c) @($results[$c] | Where-Object ok) }

# Hosts que no respondieron un chequeo (permisos, versión, host caído).
foreach ($c in $Checks) {
    # Un hallazgo por chequeo y causa, con la lista de hosts afectados.
    foreach ($g in @($results[$c] | Where-Object { -not $_.ok } | Group-Object { ($_.error -replace '<.*$', '').Trim() })) {
        $hl = @($g.Group.host | Sort-Object)
        $obj = if ($hl.Count -eq 1) { $hl[0] } else { "$($hl.Count) hosts" }
        Add-ReportFinding -Rule "coverage-$c" $findings 'Info' 'Cobertura' $obj "Chequeo '$c' no disponible en $($hl -join ', '): $($g.Name)" 'Verificar estado de los hosts, la versión de ESXi o los privilegios de la cuenta de servicio sobre la configuración del host.'
    }
}

if ('vibs' -in $Checks) {
    $vibRows = foreach ($e in (& $ok 'vibs')) { foreach ($r in $e.rows) { [pscustomobject]@{ cluster = $e.cluster; host = $e.host; name = F $r 'Name'; version = F $r 'Version'; vendor = F $r 'Vendor' } } }
    $drift = foreach ($g in ($vibRows | Group-Object cluster, name)) {
        $cl = $g.Group[0].cluster; $hostsInCl = @((& $ok 'vibs') | Where-Object cluster -eq $cl).Count
        $versions = @($g.Group | Group-Object version)
        $missing = $hostsInCl - @($g.Group.host | Sort-Object -Unique).Count
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
        Add-ReportFinding -Rule 'vib-drift' $findings 'Advertencia' 'Drift VIBs/drivers' "$($d.cluster) / $($d.name)" $ev 'Homologar con vLCM/baseline del clúster; versiones distintas pueden romper vMotion, HA o soporte del fabricante.' "$w host.esxcli -host <host> software vib get -n $($d.name)"
    }
    $sections.Add((New-ReportTable 'Drift de VIBs y drivers' @('cluster:Clúster', 'name:VIB', 'versions:Versiones (hosts)', 'missing:Hosts sin el VIB') $drift 'Solo se listan VIBs que no son idénticos en todos los hosts del clúster.'))
}

if ('nics' -in $Checks) {
    $nicRows = @($(foreach ($e in (& $ok 'nics')) { foreach ($r in $e.rows) {
                [pscustomobject]@{
                    cluster = $e.cluster; host = $e.host; nic = F $r 'Name'; driver = F $r 'Driver'
                    admin = F $r 'AdminStatus'; link = F $r @('LinkStatus', 'Link'); speed = F $r 'Speed'; duplex = F $r 'Duplex'; mtu = F $r 'MTU'
                } } }) | Sort-Object cluster, host, nic)
    foreach ($n in $nicRows | Where-Object { $_.admin -match '^up$' -and $_.link -notmatch '^up$' }) {
        Add-ReportFinding -Rule 'nic-nolink' $findings 'Advertencia' 'Red física' "$($n.host) / $($n.nic)" "NIC habilitada sin link (link: $($n.link))" 'Revisar cable/puerto del switch; si la NIC está en un vSwitch/DVS, hay pérdida de redundancia.' "$w host.esxcli -host $($n.host) network nic get -n $($n.nic)"
    }
    foreach ($g in ($nicRows | Where-Object { $_.link -match '^up$' } | Group-Object cluster, nic)) {
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
    $pathSummary = @(foreach ($e in (& $ok 'paths')) {
            $rows = @($e.rows | ForEach-Object { [pscustomobject]@{ device = F $_ 'Device'; state = "$(F $_ 'State')".ToLowerInvariant(); transport = "$(F $_ 'Transport')".ToLowerInvariant(); runtime = F $_ 'RuntimeName' } })
            foreach ($d in ($rows | Where-Object state -eq 'dead')) {
                Add-ReportFinding -Rule 'path-dead' $findings 'Crítico' 'Storage' "$($e.host) / $($d.device)" "Path muerto: $($d.runtime) ($($d.transport))" 'Revisar zoning/fabric, HBA o target; escalar a Storage.' "$w host.esxcli -host $($e.host) storage core path list -d $($d.device)"
            }
            foreach ($g in ($rows | Where-Object { $_.transport -match $shared } | Group-Object device)) {
                $active = @($g.Group | Where-Object state -eq 'active').Count
                if ($active -le 1 -and $g.Count -le 1) {
                    Add-ReportFinding -Rule 'path-single' $findings 'Advertencia' 'Storage' "$($e.host) / $($g.Name)" "Un solo path ($($g.Group[0].transport))" 'Sin redundancia de ruta: un fallo de HBA/switch deja el LUN inaccesible.' "$w host.esxcli -host $($e.host) storage nmp device list -d $($g.Name)"
                }
            }
            [pscustomobject]@{
                cluster = $e.cluster; host = $e.host; devices = @($rows.device | Sort-Object -Unique).Count; paths = $rows.Count
                active = @($rows | Where-Object state -eq 'active').Count; standby = @($rows | Where-Object state -eq 'standby').Count; dead = @($rows | Where-Object state -eq 'dead').Count
            } })
    $sections.Add((New-ReportTable 'Paths de storage' @('cluster:Clúster', 'host:Host', 'devices:Dispositivos', 'paths:Paths', 'active:Activos', 'standby:Standby', 'dead:Muertos') $pathSummary))
}

$sysRows = @{}
function SysRow($e) { if (-not $sysRows[$e.host]) { $sysRows[$e.host] = [ordered]@{ cluster = $e.cluster; host = $e.host; ntp = ''; ntpServers = ''; syslog = ''; coredump = ''; platform = ''; ssh = ''; shell = '' } }; return $sysRows[$e.host] }

if ('ntp' -in $Checks) {
    $ntpRows = foreach ($e in (& $ok 'ntp')) {
        $r = @($e.rows)[0]; $enabled = "$(F $r 'Enabled')"; $servers = @(F $r @('Server', 'Servers') @()) -join ', '
        $s = SysRow $e; $s.ntp = $enabled; $s.ntpServers = $servers
        if ($enabled -notmatch '^true$') { Add-ReportFinding -Rule 'ntp-disabled' $findings 'Advertencia' 'Tiempo' $e.host 'NTP deshabilitado' 'Hora inconsistente afecta logs, Kerberos/AD, certificados y correlación de eventos.' "$w host.date.info -host $($e.host)" }
        [pscustomobject]@{ cluster = $e.cluster; host = $e.host; servers = $servers }
    }
    foreach ($g in ($ntpRows | Group-Object cluster)) {
        $distinct = @($g.Group | Group-Object servers)
        if ($distinct.Count -gt 1) { Add-ReportFinding -Rule 'ntp-servers' $findings 'Advertencia' 'Tiempo' $g.Name "Servidores NTP distintos: $(($distinct | ForEach-Object { "[$($_.Name)] ($(($_.Group.host) -join ', '))" }) -join ' · ')" 'Homologar fuentes NTP en el clúster.' }
    }
}
if ('syslog' -in $Checks) {
    foreach ($e in (& $ok 'syslog')) {
        $r = @($e.rows)[0]; $remote = "$(F $r @('RemoteHost', 'Remotehost', 'LogHost'))"
        (SysRow $e).syslog = $remote
        if (-not $remote -or $remote -match '^<?none>?$') { Add-ReportFinding -Rule 'syslog-remote' $findings 'Advertencia' 'Logs' $e.host 'Sin syslog remoto' 'Los logs quedan solo en el host: se pierden ante falla y no llegan al SIEM. Validar con Seguridad de la Información.' "$w host.esxcli -host $($e.host) system syslog config get" }
    }
}
if ('coredump' -in $Checks) {
    foreach ($e in (& $ok 'coredump')) {
        $r = @($e.rows)[0]; $en = "$(F $r 'Enabled')"
        (SysRow $e).coredump = if ($en -match '^true$') { "red $(F $r @('NetworkServerIP', 'NetworkServerIPv4'))" } else { 'red: no' }
        if ($en -notmatch '^true$') { Add-ReportFinding -Rule 'coredump' $findings 'Info' 'Diagnóstico' $e.host 'Coredump por red no configurado' 'Verificar que exista partición/archivo de coredump local; sin destino, un PSOD no deja evidencia para soporte.' "$w host.esxcli -host $($e.host) system coredump partition get" }
    }
}
if ('platform' -in $Checks) {
    $plat = foreach ($e in (& $ok 'platform')) {
        $r = @($e.rows)[0]; $model = "$(F $r 'VendorName') $(F $r 'ProductName')".Trim()
        (SysRow $e).platform = $model
        [pscustomobject]@{ cluster = $e.cluster; host = $e.host; model = $model }
    }
    foreach ($g in ($plat | Group-Object cluster)) {
        $m = @($g.Group | Group-Object model)
        if ($m.Count -gt 1) { Add-ReportFinding -Rule 'platform-mixed' $findings 'Info' 'Plataforma' $g.Name "Modelos distintos: $(($m | ForEach-Object { "$($_.Name) ($(($_.Group.host) -join ', '))" }) -join ' · ')" 'Revisar compatibilidad EVC y homogeneidad para HA/DRS.' }
    }
}
if ('services' -in $Checks) {
    foreach ($e in (& $ok 'services')) {
        $svc = @($e.rows)
        foreach ($k in 'TSM-SSH', 'TSM') {
            $s = $svc | Where-Object { (P $_ 'key') -eq $k } | Select-Object -First 1
            $running = [bool](P $s 'running' $false)
            $label = if ($k -eq 'TSM-SSH') { 'SSH' } else { 'ESXi Shell' }
            $row = SysRow $e; if ($k -eq 'TSM-SSH') { $row.ssh = "$running" } else { $row.shell = "$running" }
            if ($running) { Add-ReportFinding -Rule "svc-$($k.ToLowerInvariant())" $findings 'Advertencia' 'Seguridad' $e.host "$label en ejecución (política: $(P $s 'policy' '?'))" "Mantener $label detenido salvo ventana de soporte; es superficie de ataque. Validar con Seguridad de la Información." "$w host.service.ls -host $($e.host)" }
        }
    }
}
if ('certs' -in $Checks) {
    $certRows = @(foreach ($e in (& $ok 'certs')) {
            $r = @($e.rows)[0]; if (-not $r) { continue }
            $na = $null; try { $na = ([datetimeoffset]::Parse("$($r.notAfter)")).LocalDateTime } catch { }
            $daysLeft = if ($na) { [math]::Floor(($na - $generated).TotalDays) } else { $null }
            if ($null -ne $daysLeft -and $daysLeft -lt 0) {
                Add-ReportFinding -Rule 'cert-host-expired' $findings 'Crítico' 'Certificados' $e.host "Certificado vencido el $($na.ToString('yyyy-MM-dd'))" 'Renovar el certificado del host (VMCA o CA interna) mediante cambio aprobado.' "$w host.cert.info -host $($e.host)"
            } elseif ($null -ne $daysLeft -and $daysLeft -le $CertWarnDays) {
                Add-ReportFinding -Rule 'cert-host-expiring' $findings 'Advertencia' 'Certificados' $e.host "Certificado vence en $daysLeft días ($($na.ToString('yyyy-MM-dd')))" 'Planificar la renovación antes del vencimiento.' "$w host.cert.info -host $($e.host)"
            }
            [pscustomobject]@{ cluster = $e.cluster; host = $e.host; subject = $r.subject; issuer = $r.issuer; notAfter = $(if ($na) { $na.ToString('yyyy-MM-dd') } else { '' }); days = $daysLeft; status = $r.status }
        })
    $sections.Add((New-ReportTable 'Certificados de host' @('cluster:Clúster', 'host:Host', 'subject:Sujeto', 'issuer:Emisor', 'notAfter:Vence', 'days:Días restantes', 'status:Estado') @($certRows | Sort-Object days, host) "Umbral de advertencia: $CertWarnDays días."))
}
if ($sysRows.Count) {
    $sections.Add((New-ReportTable 'Configuración del sistema' @('cluster:Clúster', 'host:Host', 'ntp:NTP', 'ntpServers:Servidores NTP', 'syslog:Syslog remoto', 'coredump:Coredump', 'platform:Plataforma', 'ssh:SSH', 'shell:Shell') (@($sysRows.Values | ForEach-Object { [pscustomobject]$_ } | Sort-Object cluster, host))))
}

$sorted = Sort-ReportFinding $findings
$sections.Insert(0, (New-ReportTable 'Hallazgos y sugerencias' (Get-FindingColumns) $sorted 'Consultas esxcli de solo lectura vía vCenter. Los comandos son propuestas de revisión; ningún cambio se ejecutó.'))

$kpis = [ordered]@{
    'Hosts'        = $hostList.Count
    'Clústeres'    = @($hostList.cluster | Sort-Object -Unique).Count
    'Chequeos'     = $Checks.Count
    'Críticos'     = @($sorted | Where-Object severity -eq 'Crítico').Count
    'Advertencias' = @($sorted | Where-Object severity -eq 'Advertencia').Count
    'Sin cobertura' = @($sorted | Where-Object category -eq 'Cobertura').Count
}
Export-ReportFinding $sorted (Join-Path $rawDir 'findings.json')
$kpis | ConvertTo-Json | Set-Content (Join-Path $rawDir 'summary.json') -Encoding utf8
$written = Write-GovcReport -Root $root -OutDir $outDir -BaseName 'hosts-check' -Title "Revisión de hosts (esxcli) — $($Env.ToUpper())" `
    -Env $Env -Generated $generated -Kpis $kpis -Sections $sections.ToArray() -Format $Format -MdMaxRows $MdMaxRows `
    -Source 'govc host.esxcli + host.service.ls (solo lectura)'

[pscustomobject]@{ Carpeta = $outDir; Archivos = $written; Criticos = $kpis['Críticos']; Advertencias = $kpis['Advertencias'] }
