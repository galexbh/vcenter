<#
.SYNOPSIS
  Pruebas de regresión de los reportes: New-Report, CSV, métricas, Invoke-HostCheck, Invoke-PerfCheck,
  Invoke-Audit (con evolución), catálogo de textos y Compare-Report, sobre datos demo generados con New-DemoData.ps1 -EdgeCases. No contacta vCenter.

.DESCRIPTION
  Trabaja en una carpeta temporal (%TEMP%\govc-tests-<guid>) que se elimina al terminar.
  Devuelve como código de salida el número de verificaciones fallidas. Ejecutar después de
  modificar cualquier script de reportes, plantilla o módulo de render.

.EXAMPLE
  ./scripts/Test-Reports.ps1
  ./scripts/Test-Reports.ps1 -Keep     # conserva la carpeta temporal para inspeccionarla
#>
#Requires -Version 7.5
[CmdletBinding(PositionalBinding = $false)]
param([switch]$Keep)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$S = $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("govc-tests-" + [guid]::NewGuid().ToString('N'))
$fail = 0; $pass = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; Write-Host "FALLA  $name$(if ($detail) { " → $detail" })" -ForegroundColor Red }
}
function Json([string]$path) { Get-Content $path -Raw | ConvertFrom-Json -DateKind String }
function Rules($findings) { @($findings | ForEach-Object { $_.rule }) }
function HasRule($findings, [string]$rule, [string]$sev = '', [string]$object = '*') {
    [bool](@($findings | Where-Object { $_.rule -like $rule -and $_.object -like $object -and (-not $sev -or $_.severity -eq $sev) }).Count)
}
function Quiet([scriptblock]$sb) {
    # Descarta errores y advertencias, salvo las de JSON truncado: esas son una falla (se perderían datos).
    foreach ($o in @(& $sb 2>$null 3>&1)) {
        if ($o -is [System.Management.Automation.WarningRecord]) { if ("$o" -match 'trunc') { $script:fail++; Write-Host "FALLA  advertencia de truncado: $o" -ForegroundColor Red } }
        elseif ($o -isnot [System.Management.Automation.ErrorRecord]) { $o }
    }
}
Import-Module (Join-Path $S 'lib/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $S 'lib/Render.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $S 'lib/GovcJson.psm1') -Force
Import-Module (Join-Path $S 'lib/GovcBatch.psm1') -Force

try {
    # --- Datos ---------------------------------------------------------------------
    $audit = Join-Path $work 'audit'
    & "$S/New-DemoData.ps1" -OutDir $audit -EdgeCases | Out-Null
    $rep = Join-Path $work 'reporte'
    New-Item -ItemType Directory -Force (Join-Path $rep 'raw') | Out-Null
    foreach ($f in [IO.Directory]::GetFiles((Join-Path $audit 'inventario/raw'))) { [IO.File]::Copy($f, (Join-Path $rep "raw/$([IO.Path]::GetFileName($f))")) }
    $rawVms = @(Json (Join-Path $rep 'raw/vms.json'))

    # --- 1. New-Report ------------------------------------------------------------------
    $r = Quiet { & "$S/New-Report.ps1" -FromRaw $rep -Format html, md, csv }
    Check 'New-Report: termina sin error' ($null -ne $r)
    $nf = @(Json (Join-Path $rep 'raw/findings.json'))
    $expected = @(
        @('ds-used', 'Crítico'), @('ds-thin', 'Advertencia'), @('cl-ha', 'Crítico'), @('cl-drs', 'Advertencia'),
        @('vm-consolidate', 'Advertencia'), @('vm-limits', 'Advertencia'), @('vm-iso', 'Info'), @('vm-hwversion', 'Info'),
        @('cert-vc', 'Advertencia'), @('license', 'Advertencia'), @('tools-notrunning', 'Advertencia'), @('tools-old', 'Info'),
        @('vm-off', 'Info'), @('host-maint', 'Info'), @('host-mem', 'Advertencia'), @('alarm', 'Crítico'),
        @('cl-n1-mem', 'Crítico'), @('cl-ha-admission', 'Advertencia'), @('vm-balloon', 'Advertencia'), @('vm-swap', 'Advertencia'),
        @('vm-compressed', 'Info'), @('rp-limit', 'Advertencia')
    )
    foreach ($e in $expected) { Check "New-Report: regla $($e[0]) ($($e[1]))" (HasRule $nf $e[0] $e[1]) }
    # Reglas fijas con el nombre en el objeto: dos snapshots con el mismo nombre ya no se confunden.
    Check 'New-Report: snapshot crítico por VM y nombre' (HasRule $nf 'snap-age' 'Crítico' 'app-erp02 / pre-update-CHG-0912')
    Check 'New-Report: snapshot de Veeam por VM y nombre' (HasRule $nf 'snap-age' 'Advertencia' 'db-core01 / VEEAM*')
    Check 'New-Report: alarma por entidad y nombre' (HasRule $nf 'alarm' 'Crítico' 'DS-PROD-01 / Datastore usage on disk')
    # Cadena de 8 snapshots (antes se truncaba al guardar con -Depth 12).
    Check 'New-Report: cadena de 8 snapshots completa' (@($nf | Where-Object { $_.rule -eq 'snap-age' -and $_.object -like 'vm-cadena-larga / nivel-*' }).Count -eq 8)
    # Comandos sugeridos con referencias Tipo:id: los nombres de vCenter nunca se interpolan.
    Check 'New-Report: comandos sin nombres de VM con comillas' (-not @($nf | Where-Object { "$($_.command)" -match "O'Brien" }).Count)
    Check 'New-Report: comando de snapshot por referencia' (@($nf | Where-Object { $_.object -eq "vm-O'Brien-$([char]0x2019)x / snap-quote" -and $_.command -match 'VirtualMachine:vm-3005' }).Count -eq 1)
    # N+1: CL-PROD-01 cabe sin su host mayor (sin hallazgo); el pool raíz «Resources» no se evalúa.
    Check 'New-Report: N+1 solo en el clúster sin holgura' (-not @($nf | Where-Object { $_.rule -like 'cl-n1-*' -and $_.object -eq 'CL-PROD-01' }).Count)
    Check 'New-Report: rp-limit no evalúa el pool raíz' (-not @($nf | Where-Object { $_.rule -eq 'rp-limit' -and $_.object -eq 'Resources' }).Count)
    Check 'New-Report: todos los hallazgos tienen regla' (-not @($nf | Where-Object { -not $_.rule }).Count)
    $sum = Json (Join-Path $rep 'raw/summary.json')
    $realVms = @($rawVms | Where-Object { -not $_.'config.template' })
    Check 'KPI VMs' ($sum.VMs -eq $realVms.Count) "$($sum.VMs) vs $($realVms.Count)"
    Check 'KPI Plantillas' ($sum.Plantillas -eq 1)
    Check 'KPI Hosts' ($sum.Hosts -eq 7)
    Check 'KPI Datastores' ($sum.Datastores -eq 5)
    Check 'KPI Críticos = hallazgos críticos' ($sum.'Críticos' -eq @($nf | Where-Object severity -eq 'Crítico').Count)

    $html = Get-Content (Join-Path $rep 'reporte-all.html') -Raw
    $md = Get-Content (Join-Path $rep 'reporte-all.md') -Raw
    # Paneles de métricas (raw/metrics.json) con valores conocidos de los datos demo.
    $mt = @(Json (Join-Path $rep 'raw/metrics.json'))
    $metric = { param($rows, $key, $group = '*') @($rows | Where-Object { $_.key -eq $key -and "$($_.group)" -like $group }) | Select-Object -First 1 }
    Check 'Métricas: N+1 de CL-PROD-02 > 100 %' ((& $metric $mt 'cl-n1' 'CL-PROD-02').number -gt 100)
    Check 'Métricas: VMs que aún caben en CL-PROD-01 > 0' ((& $metric $mt 'cl-fit' 'CL-PROD-01').number -gt 0)
    Check 'Métricas: VMs que aún caben en CL-PROD-02 = 0' ((& $metric $mt 'cl-fit' 'CL-PROD-02').number -eq 0)
    $onRaw = @($realVms | Where-Object { $_.'runtime.powerState' -eq 'poweredOn' })
    $toolsCalc = [math]::Round(100 * @($onRaw | Where-Object { $_.'guest.toolsVersionStatus2' -in 'guestToolsCurrent', 'guestToolsUnmanaged' }).Count / $onRaw.Count, 1)
    Check 'Métricas: % de Tools al día' ((& $metric $mt 'tools-current').number -eq $toolsCalc) "$((& $metric $mt 'tools-current').number) vs $toolsCalc"
    Check 'Métricas: sin corrida anterior no hay días al 90 %' (-not @($mt | Where-Object { "$($_.note)" -match '90 % en' }).Count)
    Check 'HTML: paneles con tarjetas y barras' ($html -match 'class="cards"' -and $html -match '<span style="width:\d+%">')
    Check 'HTML: ancho de barra entre 0 y 100' (-not @([regex]::Matches($html, 'style="width:(\d+)%"') | Where-Object { [int]$_.Groups[1].Value -gt 100 }).Count)
    Check 'MD: paneles con barra de texto' ($md -match '## Capacidad y holgura' -and $md -match '█')
    Check 'CSV: panel exportado' (Test-Path (Join-Path $rep 'reporte-all-capacidad-y-holgura.csv'))
    # Días hasta el 90 %: corrida hermana de hace 10 días con DS-PROD-02 100 GB más libre (10 GB/día).
    $hist = Join-Path $work 'historial-anterior'
    New-Item -ItemType Directory -Force (Join-Path $hist 'raw') | Out-Null
    $hm = Json (Join-Path $rep 'raw/meta.json'); $hm.generated = ([datetime]$hm.generated).AddDays(-10).ToString('o')
    $hm | ConvertTo-Json | Set-Content (Join-Path $hist 'raw/meta.json') -Encoding utf8
    $hd = @(Json (Join-Path $rep 'raw/datastores.json'))
    $ds2 = $hd | Where-Object name -eq 'DS-PROD-02'; $ds2.'summary.freeSpace' = [long]$ds2.'summary.freeSpace' + 100GB
    ConvertTo-Json -InputObject $hd -Depth 100 | Set-Content (Join-Path $hist 'raw/datastores.json') -Encoding utf8
    Quiet { & "$S/New-Report.ps1" -FromRaw $rep -Type capacity -Format md } | Out-Null
    $now2 = @(Json (Join-Path $rep 'raw/datastores.json')) | Where-Object name -eq 'DS-PROD-02'
    $capG = [double]$now2.'summary.capacity' / 1GB; $usedG = $capG - [double]$now2.'summary.freeSpace' / 1GB
    $exp90 = [math]::Floor((0.9 * $capG - [math]::Round($usedG, 1)) / 10)
    $d2 = @(Json (Join-Path $rep 'raw/metrics.json')) | Where-Object label -eq 'DS-PROD-02'
    Check 'Métricas: días hasta el 90 % según la corrida anterior' ("$($d2.note)" -match '90 % en ~(\d+) días' -and [math]::Abs([int]$Matches[1] - $exp90) -le 1) "$($d2.note) (esperado ~$exp90)"
    Remove-Item -LiteralPath $hist -Recurse -Force
    Quiet { & "$S/New-Report.ps1" -FromRaw $rep -Format html, md, csv } | Out-Null
    # Los datos demo contienen {{SECTIONS}}/{{ANNEXES}}/{{REMEDIATION}} a propósito: deben quedar literales.
    $tplMarkers = '\{\{(TITLE|ENV|GENERATED|SOURCE|KPIS)\}\}'
    Check 'HTML: marcadores de plantilla reemplazados' ($html -notmatch $tplMarkers)
    Check 'MD: marcadores de plantilla reemplazados' ($md -notmatch $tplMarkers)
    Check 'HTML: marcador en datos no se expande (una sola tabla de VMs)' (([regex]::Matches($html, '<h2>M(á|&#225;)quinas virtuales')).Count -eq 1)
    Check 'HTML: marcador en datos se muestra literal' ($html -match 'SO \{\{SECTIONS\}\} \{\{REMEDIATION\}\}')
    Check 'MD: marcador en datos se muestra literal' ($md -match 'vm\\?-\{\{ANNEXES\}\}\\?-x')
    # Código en Markdown: el delimitador supera la mayor racha de comillas invertidas del texto.
    Check 'MD: código sin comillas invertidas' ((Format-MdCode 'a b') -eq '`a b`')
    Check 'MD: código con una comilla invertida' ((Format-MdCode 'a`b') -eq '`` a`b ``')
    Check 'MD: código con racha de dos comillas invertidas' ((Format-MdCode 'a``b') -eq '``` a``b ```')
    # Literales de PowerShell: comilla simple y comillas tipográficas escapadas (no rompen ni inyectan al pegar).
    Check 'Comando: literal con comilla simple' ((Format-PsLiteral "O'Brien") -eq "'O''Brien'")
    Check 'Comando: literal con comilla tipográfica' ((Format-PsLiteral ("a" + [char]0x2019 + "b")) -eq ("'a" + [char]0x2019 + [char]0x2019 + "b'"))
    Check 'Comando: token simple sin comillas, texto riesgoso entre comillas' ((New-ReviewCommand -Env demo -Arguments @('vm.info', 'VirtualMachine:vm-1', 'a;b c')) -eq "./scripts/govc.ps1 -Env demo vm.info VirtualMachine:vm-1 'a;b c'")
    # Certificados: comillas escapadas y \uXXXX (nombres con tilde).
    $ct = ConvertFrom-CertJson '{"subject":"CN=Atl\u00e1ntida \"Q\"","issuer":"CN=CA","notAfter":"2030-01-01T00:00:00Z","status":"good","PublicKey":12345678901234567890123}'
    Check 'Certificado: escapes y \u decodificados' ($ct.subject -eq 'CN=Atlántida "Q"' -and $ct.notAfter -eq '2030-01-01T00:00:00Z') "$($ct.subject)"
    # object.collect: flujo de documentos JSON (forma real de govc) → objetos con _moref y propiedades.
    $oc = @(ConvertFrom-GovcCollect ('{"kind":"enter","obj":{"type":"Datastore","value":"datastore-1"},"changeSet":[{"name":"name","op":"assign","val":"DS1"},{"name":"summary.capacity","op":"assign","val":100}]}' + "`n" + '{"kind":"enter","obj":{"type":"Datastore","value":"datastore-2"},"changeSet":[{"name":"name","op":"assign","val":"DS2"}]}'))
    Check 'object.collect: flujo de documentos' ($oc.Count -eq 2 -and $oc[0]._moref -eq 'datastore-1' -and $oc[0].'summary.capacity' -eq 100 -and $oc[1].name -eq 'DS2')
    # Errores del lote: mensaje legible desde una falla SOAP o desde stderr.
    Check 'Lote: error SOAP legible' ((Get-GovcBatchError ([pscustomobject]@{ stderr = ''; stdout = '{"Fault":{"String":"NoPermission"}}' })) -eq 'NoPermission')
    Check 'Lote: error de stderr limpio' ((Get-GovcBatchError ([pscustomobject]@{ stderr = 'govc: ServerFaultCode: no encontrado <detalle>'; stdout = '' })) -eq 'ServerFaultCode: no encontrado')
    # Guardado sin truncar: un árbol de 12 niveles vuelve completo.
    $deepObj = $null; foreach ($lvl in 12..1) { $deepObj = [pscustomobject]@{ n = $lvl; c = @($(if ($deepObj) { $deepObj })) } }
    $deepFile = Join-Path $work 'profundo.json'; Save-RawJson $deepObj $deepFile
    $back = Get-Content $deepFile -Raw | ConvertFrom-Json -Depth 200; $lvlN = 1; while ($back.c.Count) { $back = $back.c[0]; $lvlN++ }
    Check 'Save-RawJson: 12 niveles sin truncar' ($lvlN -eq 12) "$lvlN niveles"
    Check 'HTML: codifica <script> de vCenter' (($html -notmatch '<script>alert') -and ($html -match '&lt;script&gt;alert'))
    Check 'HTML: incluye selector de tema' ($html -match 'id="theme-toggle"')
    # CSP: cada script en línea debe estar autorizado por su hash; nada más puede ejecutarse.
    foreach ($tpl in @(@('reporte', $html), @('plantilla de auditoría', (Get-Content (Join-Path $root 'templates/audit.html') -Raw)))) {
        $csp = [regex]::Match($tpl[1], 'http-equiv="Content-Security-Policy" content="([^"]+)"').Groups[1].Value
        # El navegador calcula el hash sobre el texto con saltos de línea normalizados a LF.
        $scripts = [regex]::Matches(($tpl[1] -replace "`r`n", "`n"), '<script>([\s\S]*?)</script>') | ForEach-Object { $_.Groups[1].Value }
        $okHashes = $csp -and ($csp -match "default-src 'none'") -and @($scripts).Count -and -not @($scripts | Where-Object {
                $h = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_)))
                $csp -notmatch [regex]::Escape("'sha256-$h'") }).Count
        Check "CSP en $($tpl[0]): default-src 'none' y hashes de scripts válidos" $okHashes
    }
    Check 'MD: escapa | y [ de vCenter' ($md -match 'SO \\\| con \\\[enlace\\\]')
    Check 'MD: no contiene <script> literal' ($md -notmatch '<script>')
    Check 'MD: sin filas vacías' ($md -notmatch '(?m)^\|(\s*\|)+\s*$')
    Check 'Reporte incluye la VM sin host' ($md -match 'vm-huerfana01')
    # -SkipDeviceScan: la detección de ISO se declara como cobertura (no desaparece en silencio).
    $skip = Join-Path $work 'skip'
    New-Item -ItemType Directory -Force (Join-Path $skip 'raw') | Out-Null
    foreach ($f in [IO.Directory]::GetFiles((Join-Path $rep 'raw'))) { [IO.File]::Copy($f, (Join-Path $skip "raw/$([IO.Path]::GetFileName($f))")) }
    $sm = Json (Join-Path $skip 'raw/meta.json'); $sm | Add-Member deviceScan $false -Force
    $sm | ConvertTo-Json | Set-Content (Join-Path $skip 'raw/meta.json') -Encoding utf8
    Quiet { & "$S/New-Report.ps1" -FromRaw $skip -Format md } | Out-Null
    $sf = @(Json (Join-Path $skip 'raw/findings.json'))
    Check 'SkipDeviceScan: declara cobertura y no evalúa ISO' ((HasRule $sf 'coverage-devices' 'Info') -and -not (HasRule $sf 'vm-iso'))

    # --- 2. CSV -----------------------------------------------------------------------------
    $sep = (Get-Culture).TextInfo.ListSeparator
    $vmCsv = Join-Path $rep 'reporte-all-maquinas-virtuales.csv'
    Check 'CSV: archivo de VMs existe' (Test-Path $vmCsv)
    $bytes = [IO.File]::ReadAllBytes($vmCsv)
    Check 'CSV: BOM UTF-8' ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $lines = [IO.File]::ReadAllLines($vmCsv)
    Check 'CSV: separador regional' ($lines[0] -eq ('"VM"' + $sep + '"Estado"' + $sep) -or $lines[0].StartsWith('"VM"' + $sep))
    Check "CSV: neutraliza fórmulas ('=)" ([bool]($lines | Where-Object { $_.StartsWith('"''=HYPERLINK') }))
    Check 'CSV: escapa comillas internas' ([bool]($lines | Where-Object { $_ -match '""http://x""' }))
    $rows = @(Import-Csv $vmCsv -Delimiter $sep)
    Check 'CSV: filas de VMs = KPI' ($rows.Count -eq $sum.VMs) "$($rows.Count) vs $($sum.VMs)"
    Check 'CSV: un archivo por tabla' (@(Get-ChildItem $rep -Filter 'reporte-all-*.csv').Count -ge 7)

    # --- 3. Invoke-HostCheck --------------------------------------------------------------------
    $hdir = Join-Path $audit 'hosts'
    $h = Quiet { & "$S/Invoke-HostCheck.ps1" -FromRaw $hdir -Format md }
    Check 'HostCheck: termina sin error' ($null -ne $h)
    $hf = @(Json (Join-Path $hdir 'raw/findings.json'))
    $hostRules = @(
        @('path-dead', 'Crítico'), @('path-single', 'Advertencia'), @('vib-drift', 'Advertencia'), @('nic-nolink', 'Advertencia'),
        @('nic-speed', 'Advertencia'), @('nic-mtu', 'Advertencia'), @('ntp-disabled', 'Advertencia'), @('syslog-remote', 'Advertencia'),
        @('svc-tsm-ssh', 'Advertencia'), @('svc-tsm', 'Advertencia'), @('cert-host-expired', 'Crítico'), @('cert-host-expiring', 'Advertencia'),
        @('coredump', 'Info'), @('platform-mixed', 'Info')
    )
    foreach ($e in $hostRules) { Check "HostCheck: regla $($e[0]) ($($e[1]))" (HasRule $hf $e[0] $e[1]) }
    Check 'HostCheck: no marca discos locales (mpx) como un solo path' (-not @($hf | Where-Object { $_.rule -eq 'path-single' -and $_.object -match 'mpx\.' }).Count)
    $hm3 = @(Json (Join-Path $hdir 'raw/metrics.json'))
    Check 'HostCheck: panel de cobertura (un % por chequeo)' (@($hm3 | Where-Object { "$($_.key)" -like 'hc-check:*' }).Count -eq 9 -and $null -ne ($hm3 | Where-Object key -eq 'hc-coverage').number)
    $cov = @($hf | Where-Object rule -eq 'coverage-coredump')
    Check 'HostCheck: cobertura agrupada por chequeo' ($cov.Count -eq 1 -and $cov[0].object -eq '2 hosts') "$($cov.Count) hallazgos"

    # --- 3b. Invoke-PerfCheck -------------------------------------------------------------------
    $pdir = Join-Path $audit 'perf'
    $pc = Quiet { & "$S/Invoke-PerfCheck.ps1" -FromRaw $pdir -Format html, md }
    Check 'PerfCheck: termina sin error' ($null -ne $pc)
    $pf = @(Json (Join-Path $pdir 'raw/findings.json'))
    $perfRules = @(
        @('perf-cpu-ready', 'Crítico'), @('perf-cpu-ready', 'Advertencia'), @('perf-ds-latency', 'Crítico'), @('perf-ds-latency', 'Advertencia'),
        @('perf-host-cpu', 'Crítico'), @('perf-balloon', 'Advertencia'), @('perf-swap', 'Advertencia'), @('perf-swap', 'Info'),
        @('coverage-perf-counters', 'Info'), @('coverage-perf-hosts', 'Info'), @('coverage-perf-error', 'Info')
    )
    foreach ($e in $perfRules) { Check "PerfCheck: regla $($e[0]) ($($e[1]))" (HasRule $pf $e[0] $e[1]) }
    Check 'PerfCheck: hallazgos en categoría Rendimiento o Cobertura' (-not @($pf | Where-Object { $_.category -notin 'Rendimiento', 'Cobertura' }).Count)
    Check 'PerfCheck: latencia por datastore (un hallazgo por datastore)' (@($pf | Where-Object { $_.rule -eq 'perf-ds-latency' -and $_.object -eq 'DS-PROD-01' }).Count -eq 1)
    $pm3 = @(Json (Join-Path $pdir 'raw/metrics.json'))
    $worstDs = $pm3 | Where-Object key -eq 'perf-ds-worst'
    Check 'PerfCheck: peor latencia p95 = 35,2 ms en DS-PROD-01' ($worstDs.number -eq 35.2 -and "$($worstDs.note)" -like 'DS-PROD-01*') "$($worstDs.number) $($worstDs.note)"
    Check 'PerfCheck: top 5 por métrica' (@($pm3 | Where-Object group -eq 'Más CPU ready (p95)').Count -eq 5)
    Check 'PerfCheck: host sin métricas no se evalúa' (-not @($pf | Where-Object { $_.rule -eq 'perf-host-cpu' -and $_.object -eq 'esx07.demo.local' }).Count)
    # -FromRaw recalcula con otros umbrales sin volver a consultar.
    Quiet { & "$S/Invoke-PerfCheck.ps1" -FromRaw $pdir -Format md -DsLatencyWarnMs 40 -DsLatencyCritMs 50 } | Out-Null
    Check 'PerfCheck: -FromRaw aplica umbrales nuevos' (-not (HasRule @(Json (Join-Path $pdir 'raw/findings.json')) 'perf-ds-latency'))
    Quiet { & "$S/Invoke-PerfCheck.ps1" -FromRaw $pdir -Format html, md } | Out-Null
    # Funciones internas: estadísticas sin valores -1 y formatos de salida de metric.sample.
    $past = [System.Management.Automation.Language.Parser]::ParseFile("$S/Invoke-PerfCheck.ps1", [ref]$null, [ref]$null)
    foreach ($fn in $past.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Q', 'Get-Stats', 'ConvertFrom-MetricSample', 'ConvertFrom-IntervalInfo' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
    $iv = @(ConvertFrom-IntervalInfo "ID:                   300`n  Enabled:            true`n  Level:              1`nID:                   1800`n  Level:              2")
    Check 'PerfCheck: niveles leídos del texto de metric.interval.info' ($iv.Count -eq 2 -and $iv[0].period -eq 300 -and $iv[0].level -eq 1 -and $iv[1].level -eq 2)
    $sc = Get-Stats @(100, -1, 300) 0.5
    Check 'PerfCheck: estadísticas con escala' ($sc.n -eq 2 -and $sc.max -eq 150 -and $sc.avg -eq 100)
    $st = Get-Stats @(-1, 10, 20, -1, 30, 40)
    Check 'PerfCheck: estadísticas descartan -1' ($st.n -eq 4 -and $st.avg -eq 25 -and $st.max -eq 40) ($st | ConvertTo-Json -Compress)
    Check 'PerfCheck: serie solo con -1 = sin datos' ($null -eq (Get-Stats @(-1, -1)))
    $msA = @(ConvertFrom-MetricSample '{"sample":[{"entity":{"type":"HostSystem","value":"host-10"},"value":[{"name":"cpu.usage.average","instance":"","value":[1,2]},{"name":"datastore.totalReadLatency.average","instance":"uuid-1","value":[3]}]}]}')
    $msB = @(ConvertFrom-MetricSample '[{"Entity":{"Type":"VirtualMachine","Value":"vm-1"},"Value":[{"Name":"cpu.ready.summation","Instance":"","Value":[200,400]}]}]')
    Check 'PerfCheck: interpreta metric.sample con objeto raíz' ($msA.Count -eq 2 -and $msA[1].instance -eq 'uuid-1' -and $msA[0].entity -eq 'host-10')
    Check 'PerfCheck: interpreta metric.sample como arreglo y en mayúsculas' ($msB.Count -eq 1 -and $msB[0].counter -eq 'cpu.ready.summation' -and ($msB[0].values -join ',') -eq '200,400')

    # --- 4. Invoke-Audit --------------------------------------------------------------------------
    $a = Quiet { & "$S/Invoke-Audit.ps1" -FromRaw $audit -Format html, md }
    Check 'Audit: termina sin error' ($null -ne $a)
    $aj = Json (Join-Path $audit 'raw/audit.json')
    $ids = @($aj.findings | ForEach-Object { $_.id })
    Check 'Audit: IDs consecutivos AUD-001…' (($ids -join ',') -eq ((1..$ids.Count | ForEach-Object { 'AUD-{0:000}' -f $_ }) -join ','))
    Check 'Audit: clave estable de 12 hex por hallazgo' (-not @($aj.findings | Where-Object { "$($_.key)" -notmatch '^[0-9a-f]{12}$' }).Count)
    $okScores = $true
    foreach ($p in $aj.scores.PSObject.Properties) {
        $v = $p.Value; $calc = [math]::Max(0, 100 - (15 * $v.crit + 5 * $v.warn + $v.info))
        $cnt = @($aj.findings | Where-Object domain -eq $p.Name)
        if ($v.score -ne $calc -or ($v.crit + $v.warn + $v.info) -ne $cnt.Count) { $okScores = $false }
    }
    Check 'Audit: indicadores según la fórmula' $okScores
    Check 'Audit: todo hallazgo con dominio y riesgo' (-not @($aj.findings | Where-Object { -not $_.domain -or -not $_.risk }).Count)
    Check 'Audit: cobertura fuera del puntaje' (@($aj.coverage).Count -ge 1 -and -not @($aj.findings | Where-Object category -eq 'Cobertura').Count)
    $ah = Get-Content (Join-Path $audit 'auditoria.html') -Raw
    foreach ($sec in 'Resumen ejecutivo', 'Alcance y metodología', 'Hallazgos detallados', 'Plan de remediación', 'Anexos', 'Revisión y aprobación') {
        Check "Audit HTML: sección '$sec'" ($ah -match [regex]::Escape($sec))
    }
    Check 'Audit HTML: marcadores de plantilla reemplazados' ($ah -notmatch '\{\{(TITLE|SUBTITLE|ENV|SCOPE|DATE|PREPARED_BY|AUDIT_ID|VERSION|EXEC_SUMMARY|DOMAIN_SCORES|SEVERITY_COUNTS|TOP_RISKS|METHODOLOGY|MATRIX|FINDINGS)\}\}')
    Check 'Audit HTML: marcador en datos no se expande (una sola sección de anexos)' (([regex]::Matches($ah, '<h3>A\. Resumen de inventario')).Count -eq 1)
    Check 'Audit HTML: marcador en datos se muestra literal' ($ah -match 'vm-\{\{ANNEXES\}\}-x')
    $amd = Get-Content (Join-Path $audit 'auditoria.md') -Raw
    Check 'Audit MD: marcador en datos no se expande (un solo plan de remediación)' (([regex]::Matches($amd, '\| ID \| Severidad \| Objeto \| Acción')).Count -eq 1)
    Check 'Audit HTML: codifica contenido de vCenter' ($ah -notmatch '<script>alert')
    Check 'Audit: métricas clave en audit.json' (@($aj.metrics | Where-Object key -eq 'cl-n1').Count -eq 1 -and @($aj.metrics).Count -ge 6)
    Check 'Audit: primera auditoría sin evolución' ($null -eq $aj.evolution -and $ah -match [regex]::Escape([System.Net.WebUtility]::HtmlEncode('Primera auditoría del entorno')))
    Check 'Audit HTML: firma de Arquitectura' ($ah -match '<div class="role">Revisado por</div><div>Arquitectura</div>')
    # Evolución: auditoría hermana de hace 7 días con un hallazgo menos, uno ya resuelto y Disponibilidad +10.
    $prevA = Join-Path $work 'auditoria-anterior'
    New-Item -ItemType Directory -Force (Join-Path $prevA 'raw') | Out-Null
    $pa = Json (Join-Path $audit 'raw/audit.json')
    $pa.generated = ([datetime]$pa.generated).AddDays(-7).ToString('o')
    $gone1 = $pa.findings[0]
    $pa.findings = @(@($pa.findings | Select-Object -Skip 1) + [pscustomobject]@{ id = 'AUD-999'; key = 'ffffffffffff'; rule = 'ds-used'; object = 'DS-RETIRADO'; severity = 'Advertencia'; domain = 'Capacidad' })
    $pa.scores.Disponibilidad.score = [int]$pa.scores.Disponibilidad.score + 10
    $pa | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $prevA 'raw/audit.json') -Encoding utf8
    Quiet { & "$S/Invoke-Audit.ps1" -FromRaw $audit -Format html, md } | Out-Null
    $ej = (Json (Join-Path $audit 'raw/audit.json')).evolution
    Check 'Evolución: nuevos, resueltos y persistentes' ($ej -and $ej.new -eq 1 -and $ej.resolved -eq 1 -and $ej.persistent -eq (@($aj.findings).Count - 1) -and @($ej.newKeys) -contains $gone1.key) "$($ej | ConvertTo-Json -Compress -Depth 2)"
    Check 'Evolución: delta por dominio' ((@($ej.domains | Where-Object domain -eq 'Disponibilidad')[0]).delta -eq -10)
    $eh = Get-Content (Join-Path $audit 'auditoria.html') -Raw
    Check 'Audit HTML: panel de evolución' ($eh -match 'Comparado con AUD-' -and $eh -match '↓ -10')
    Remove-Item -LiteralPath $prevA -Recurse -Force
    Quiet { & "$S/Invoke-Audit.ps1" -FromRaw $audit -Format html, md } | Out-Null

    # --- 4b. Catálogo de textos y política de menciones ------------------------------------------------
    $cat = Get-FindingCatalog
    $allF = @($nf) + @($hf) + @($pf) + @($aj.findings) + @($aj.coverage)
    Check 'Catálogo: todo hallazgo tiene sugerencia' (-not @($allF | Where-Object { -not "$($_.suggestion)".Trim() }).Count) (@($allF | Where-Object { -not "$($_.suggestion)".Trim() } | ForEach-Object { "$($_.rule)/$($_.severity)" }) -join ', ')
    $srcText = (@('New-Report.ps1', 'Invoke-HostCheck.ps1', 'Invoke-PerfCheck.ps1', 'Invoke-Audit.ps1') | ForEach-Object { Get-Content (Join-Path $S $_) -Raw }) -join "`n"
    $emitted = @($allF | ForEach-Object { $_.rule } | Sort-Object -Unique)
    $unused = @($cat.Rules.Keys | Where-Object { $srcText -notmatch [regex]::Escape("'$_'") -and $_ -notin $emitted -and -not ($_ -like 'cl-n1-*' -and $srcText -match 'cl-n1-\$\(') })
    Check 'Catálogo: sin entradas sin uso' (-not $unused.Count) ($unused -join ', ')
    $texts = foreach ($k in $cat.Rules.Keys) { $sg = $cat.Rules[$k].Suggestion; if ($sg -is [System.Collections.IDictionary]) { foreach ($sv in $sg.Keys) { [pscustomobject]@{ rule = $k; text = "$($sg[$sv])"; sev = $sv } } } else { [pscustomobject]@{ rule = $k; text = "$sg"; sev = '' } } }
    Check 'Catálogo: ningún texto vacío' (-not @($texts | Where-Object { -not $_.text.Trim() }).Count)
    Check 'Catálogo: severidades válidas' (-not @($texts | Where-Object { $_.sev -and $_.sev -notin 'Crítico', 'Advertencia', 'Info' }).Count)
    Check 'Catálogo: riesgo para cada categoría puntuada' (-not @($aj.findings | ForEach-Object { $_.category } | Sort-Object -Unique | Where-Object { -not (Get-CategoryText $_) }).Count)
    Check 'Catálogo: marcadores reemplazados como texto literal' ((Get-FindingText 'svc' -Vars @{ label = '$(Get-Date)' }) -match [regex]::Escape('Detener $(Get-Date) y'))
    Check 'Catálogo: regla inexistente = texto vacío' ((Get-FindingText 'no-existe') -eq '')
    $areas = '(?i)infraestructura|arquitectura|seguridad de la informaci|storage(?! vmotion)|dueño|redes\b|licenciamiento|validar con|validación del|escalar|equipo de'
    $allowed = @{ 'path-dead' = 'storage'; 'snap-age' = 'dueño'; 'vm-off' = 'dueño' }
    $bad = @($texts | Where-Object { $_.text -match $areas -and -not ($allowed[$_.rule] -and $Matches[0].ToLowerInvariant() -eq $allowed[$_.rule]) } | ForEach-Object { "$($_.rule): $($Matches[0])" })
    $bad += @($cat.Notes.Keys | Where-Object { "$($cat.Notes[$_])" -match $areas } | ForEach-Object { "nota $_" })
    Check 'Menciones: solo path-dead (Storage), snap-age y vm-off (dueño)' (-not $bad.Count) ($bad -join '; ')
    $tplText = (@('templates/report.html', 'templates/report.md', 'templates/audit.md') | ForEach-Object { Get-Content (Join-Path $root $_) -Raw }) -join "`n"
    Check 'Menciones: scripts y plantillas sin derivar a Infraestructura' (($srcText + $tplText) -cnotmatch '[Vv]alidar con|[Ee]scalar a|validación del área|Infraestructura')
    Quiet { & "$S/Invoke-Audit.ps1" -FromRaw $audit -Scope security -Format md } | Out-Null
    $sj = Json (Join-Path $audit 'raw/audit.json')
    $domSec = @($sj.findings | ForEach-Object { $_.domain } | Sort-Object -Unique)
    Check 'Audit -Scope security: solo Seguridad y Configuración' (-not @($domSec | Where-Object { $_ -notin 'Seguridad', 'Configuración' }).Count) ($domSec -join ', ')
    Check 'Audit: dominio Rendimiento puntuado con hallazgos' ($aj.scores.PSObject.Properties['Rendimiento'] -and @($aj.findings | Where-Object domain -eq 'Rendimiento').Count -gt 0)
    Check 'Audit HTML: fuente de rendimiento en la metodología' ($ah -match '<td>Rendimiento</td><td>metric\.sample')
    Quiet { & "$S/Invoke-Audit.ps1" -FromRaw $audit -Scope performance -Format md } | Out-Null
    $pj = Json (Join-Path $audit 'raw/audit.json')
    $domPerf = @($pj.scores.PSObject.Properties.Name)
    Check 'Audit -Scope performance: solo Capacidad y Rendimiento' ((($domPerf | Sort-Object) -join ',') -eq 'Capacidad,Rendimiento') ($domPerf -join ', ')
    # Auditoría sin perf/ (anterior a la fuente de rendimiento): el dominio no se puntúa y se declara como cobertura.
    $old = Join-Path $work 'audit-sin-perf'
    Copy-Item -LiteralPath $audit -Destination $old -Recurse
    Remove-Item -LiteralPath (Join-Path $old 'perf') -Recurse -Force
    $oa = Quiet { & "$S/Invoke-Audit.ps1" -FromRaw $old -Format html }
    $oj = Json (Join-Path $old 'raw/audit.json')
    Check 'Audit sin perf/: termina sin error' ($null -ne $oa)
    Check 'Audit sin perf/: Rendimiento no puntuado y declarado como cobertura' (-not $oj.scores.PSObject.Properties['Rendimiento'] -and @($oj.coverage | Where-Object rule -eq 'coverage-perf').Count -eq 1)

    # --- 5. Compare-Report ---------------------------------------------------------------------------
    $base = Join-Path $work 'base'
    New-Item -ItemType Directory -Force (Join-Path $base 'raw') | Out-Null
    foreach ($f in [IO.Directory]::GetFiles((Join-Path $rep 'raw'))) { [IO.File]::Copy($f, (Join-Path $base "raw/$([IO.Path]::GetFileName($f))")) }
    $m = Json (Join-Path $base 'raw/meta.json'); $m.generated = ([datetime]$m.generated).AddDays(-10).ToString('o')
    $m | ConvertTo-Json | Set-Content (Join-Path $base 'raw/meta.json') -Encoding utf8
    $bv = @(Json (Join-Path $base 'raw/vms.json'))
    $gone = $bv[0].PSObject.Copy(); $gone._moref = 'vm-9999'; $gone.name = 'app-retirada01'
    $bv = @($bv | Select-Object -Skip 1) + $gone
    ($bv | Where-Object name -eq 'web-banca01').name = 'web-banca-anterior'
    ConvertTo-Json -InputObject $bv -Depth 100 | Set-Content (Join-Path $base 'raw/vms.json') -Encoding utf8
    $bd = @(Json (Join-Path $base 'raw/datastores.json')); $bd[0].'summary.freeSpace' = [long]$bd[0].'summary.freeSpace' + 200GB
    ConvertTo-Json -InputObject $bd -Depth 100 | Set-Content (Join-Path $base 'raw/datastores.json') -Encoding utf8
    # La base simula una corrida anterior a 1.8: reglas con el nombre incluido (snap-age-<snapshot>, objeto = VM).
    $bf = @(Json (Join-Path $base 'raw/findings.json') | ForEach-Object {
            if ($_.rule -eq 'snap-age' -and $_.object -match '^(.+) / (.+)$') { $_.rule = "snap-age-$($Matches[2])"; $_.object = $Matches[1] }
            $_ }) + [pscustomobject]@{ severity = 'Advertencia'; category = 'Snapshots'; object = 'app-retirada01'; evidence = 'x'; suggestion = ''; command = ''; rule = 'snap-age-x' }
    ConvertTo-Json -InputObject $bf -Depth 100 | Set-Content (Join-Path $base 'raw/findings.json') -Encoding utf8
    $tdir = Join-Path $work 'tendencia'
    $c = Quiet { & "$S/Compare-Report.ps1" -Base $base -Current $rep -OutDir $tdir -Format md }
    Check 'Compare: termina sin error' ($null -ne $c)
    $tmd = Get-Content (Join-Path $tdir 'tendencia.md') -Raw
    Check 'Compare: VM nueva' ($tmd -match '\| Nueva \| app\\-erp01 \||\| Nueva \| app-erp01 \|')
    Check 'Compare: VM eliminada' ($tmd -match '\| Eliminada \| app\\?-retirada01')
    Check 'Compare: VM renombrada' ($tmd -match 'Renombrada \| web\\?-banca01 \| antes: web\\?-banca\\?-anterior')
    Check 'Compare: hallazgo resuelto' ($tmd -match '\| Resuelto \|')
    Check 'Compare: claves anteriores a 1.8 traducidas (snapshots sin cambios no aparecen)' ($tmd -notmatch 'pre\\?-update\\?-CHG\\?-0912')
    Check 'Compare: crecimiento de datastore (20 GB/día)' ($tmd -match '\| DS\\?-PROD\\?-01 \|[^\r\n]*\| 20 \|')
    Check 'Compare: sin filas vacías' ($tmd -notmatch '(?m)^\|(\s*\|)+\s*$')
    Check 'Compare: snapshots sin cambios = 0 filas' ($tmd -match '## Snapshots \(0\)')

    # --- 5b. Test-AuditLog: cadena íntegra y ruptura detectada ----------------------------------------
    $logT = Join-Path $work 'logs-test'; New-Item -ItemType Directory -Force $logT | Out-Null
    $prevH = 'GENESIS'; $lines = foreach ($k in 1..3) {
        $l = ([ordered]@{ prev = $prevH; ts = "2026-10-1$($k)T00:00:00Z"; command = "about $k"; result = 'ok' } | ConvertTo-Json -Compress)
        $prevH = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($l)))).ToLowerInvariant(); $l }
    $logF = Join-Path $logT 'audit-20261018.jsonl'; [IO.File]::WriteAllLines($logF, [string[]]$lines)
    $null = & pwsh -NoProfile -NonInteractive -File "$S/Test-AuditLog.ps1" -Path $logT; $okCode = $LASTEXITCODE
    [IO.File]::WriteAllLines($logF, [string[]]@($lines[0], ($lines[1] -replace 'about 2', 'about X'), $lines[2]))
    $null = & pwsh -NoProfile -NonInteractive -File "$S/Test-AuditLog.ps1" -Path $logT; $badCode = $LASTEXITCODE
    Check 'Test-AuditLog: cadena íntegra (exit 0)' ($okCode -eq 0) "exit $okCode"
    Check 'Test-AuditLog: línea editada detectada (exit 1)' ($badCode -eq 1) "exit $badCode"

    # --- 6. Lote del wrapper: rechaza escrituras antes de leer la credencial ----------------------------
    $wrapperText = Get-Content "$S/govc.ps1" -Raw
    $cfg = Join-Path $root 'config/environments.json'
    if ($wrapperText -match '-Batch' -and (Test-Path $cfg)) {
        $envName = ((Get-Content $cfg -Raw | ConvertFrom-Json).PSObject.Properties | Select-Object -First 1).Name
        $bfile = Join-Path $work 'lote.json'
        # En un proceso aparte: el wrapper escribe sus mensajes directamente en stderr.
        $run = { param($file) $o = & pwsh -NoProfile -NonInteractive -File "$S/govc.ps1" -Env $envName -Batch $file 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ code = $LASTEXITCODE; text = ($o -join ' ') } }
        Set-Content $bfile '[["about"],["vm.destroy","app01"]]' -Encoding utf8
        $r1 = & $run $bfile
        Check 'Lote: rechaza un comando no lectura (exit 3)' ($r1.code -eq 3) "exit $($r1.code)"
        Check 'Lote: identifica la clase destructive' ($r1.text -match 'es destructive') $r1.text
        Set-Content $bfile '[[["about"]],[["ls","/"]]]' -Encoding utf8
        $r2 = & $run $bfile
        Check 'Lote: rechaza formato anidado (exit 2)' ($r2.code -eq 2) "exit $($r2.code)"
    } else {
        Write-Host 'Aviso: prueba del lote omitida (requiere el modo -Batch y config/environments.json).' -ForegroundColor Yellow
    }
} catch {
    $fail++
    Write-Host "FALLA  excepción: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ($_.ScriptStackTrace -split "`n" | Select-Object -First 3 | Out-String)
} finally {
    if ($Keep) { Write-Host "Carpeta de pruebas conservada: $work" }
    elseif (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

$color = if ($fail) { 'Red' } else { 'Green' }
Write-Host "`n$pass correctas, $fail fallidas" -ForegroundColor $color
exit $fail
