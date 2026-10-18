<#
.SYNOPSIS
  Pruebas de regresión de los reportes: New-Report, CSV, Invoke-HostCheck, Invoke-Audit y
  Compare-Report, sobre datos demo generados con New-DemoData.ps1 -EdgeCases. No contacta vCenter.

.DESCRIPTION
  Trabaja en una carpeta temporal (%TEMP%\govc-tests-<guid>) que se elimina al terminar.
  Devuelve como código de salida el número de verificaciones fallidas. Ejecutar después de
  modificar cualquier script de reportes, plantilla o módulo de render.

.EXAMPLE
  ./scripts/Test-Reports.ps1
  ./scripts/Test-Reports.ps1 -Keep     # conserva la carpeta temporal para inspeccionarla
#>
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
function HasRule($findings, [string]$rule, [string]$sev = '') {
    [bool](@($findings | Where-Object { $_.rule -like $rule -and (-not $sev -or $_.severity -eq $sev) }).Count)
}
function Quiet([scriptblock]$sb) { & $sb 2>$null 3>$null | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } }

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
        @('cert-vc', 'Advertencia'), @('license-*', 'Advertencia'), @('tools-notrunning', 'Advertencia'), @('tools-old', 'Info'),
        @('vm-off', 'Info'), @('host-maint', 'Info'), @('host-mem', 'Advertencia'), @('snap-age-pre-update-CHG-0912', 'Crítico'),
        @('snap-age-VEEAM*', 'Advertencia'), @('alarm-*', 'Crítico'),
        @('cl-n1-mem', 'Crítico'), @('cl-ha-admission', 'Advertencia'), @('vm-balloon', 'Advertencia'), @('vm-swap', 'Advertencia'),
        @('vm-compressed', 'Info'), @('rp-limit', 'Advertencia')
    )
    foreach ($e in $expected) { Check "New-Report: regla $($e[0]) ($($e[1]))" (HasRule $nf $e[0] $e[1]) }
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
    # Los datos demo contienen {{SECTIONS}}/{{ANNEXES}}/{{REMEDIATION}} a propósito: deben quedar literales.
    $tplMarkers = '\{\{(TITLE|ENV|GENERATED|SOURCE|KPIS)\}\}'
    Check 'HTML: marcadores de plantilla reemplazados' ($html -notmatch $tplMarkers)
    Check 'MD: marcadores de plantilla reemplazados' ($md -notmatch $tplMarkers)
    Check 'HTML: marcador en datos no se expande (una sola tabla de VMs)' (([regex]::Matches($html, '<h2>M(á|&#225;)quinas virtuales')).Count -eq 1)
    Check 'HTML: marcador en datos se muestra literal' ($html -match 'SO \{\{SECTIONS\}\} \{\{REMEDIATION\}\}')
    Check 'MD: marcador en datos se muestra literal' ($md -match 'vm\\?-\{\{ANNEXES\}\}\\?-x')
    # Un nombre con comilla invertida dentro de un comando exige un delimitador doble (`` … ``).
    Check 'MD: comando con comilla invertida bien delimitado' ($md -match ([regex]::Escape('`` ./scripts/govc.ps1 -Env demo snapshot.tree -vm ''vm-comilla`x'' -D -i ``')))
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
    Check 'PerfCheck: host sin métricas no se evalúa' (-not @($pf | Where-Object { $_.rule -eq 'perf-host-cpu' -and $_.object -eq 'esx07.demo.local' }).Count)
    # -FromRaw recalcula con otros umbrales sin volver a consultar.
    Quiet { & "$S/Invoke-PerfCheck.ps1" -FromRaw $pdir -Format md -DsLatencyWarnMs 40 -DsLatencyCritMs 50 } | Out-Null
    Check 'PerfCheck: -FromRaw aplica umbrales nuevos' (-not (HasRule @(Json (Join-Path $pdir 'raw/findings.json')) 'perf-ds-latency'))
    Quiet { & "$S/Invoke-PerfCheck.ps1" -FromRaw $pdir -Format html, md } | Out-Null
    # Funciones internas: estadísticas sin valores -1 y formatos de salida de metric.sample.
    $past = [System.Management.Automation.Language.Parser]::ParseFile("$S/Invoke-PerfCheck.ps1", [ref]$null, [ref]$null)
    foreach ($fn in $past.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'P', 'Q', 'Get-Stats', 'ConvertFrom-MetricSample' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
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
    ConvertTo-Json -InputObject $bv -Depth 12 | Set-Content (Join-Path $base 'raw/vms.json') -Encoding utf8
    $bd = @(Json (Join-Path $base 'raw/datastores.json')); $bd[0].'summary.freeSpace' = [long]$bd[0].'summary.freeSpace' + 200GB
    ConvertTo-Json -InputObject $bd -Depth 12 | Set-Content (Join-Path $base 'raw/datastores.json') -Encoding utf8
    $bf = @(Json (Join-Path $base 'raw/findings.json')) + [pscustomobject]@{ severity = 'Advertencia'; category = 'Snapshots'; object = 'app-retirada01'; evidence = 'x'; suggestion = ''; command = ''; rule = 'snap-age-x' }
    ConvertTo-Json -InputObject $bf -Depth 6 | Set-Content (Join-Path $base 'raw/findings.json') -Encoding utf8
    $tdir = Join-Path $work 'tendencia'
    $c = Quiet { & "$S/Compare-Report.ps1" -Base $base -Current $rep -OutDir $tdir -Format md }
    Check 'Compare: termina sin error' ($null -ne $c)
    $tmd = Get-Content (Join-Path $tdir 'tendencia.md') -Raw
    Check 'Compare: VM nueva' ($tmd -match '\| Nueva \| app\\-erp01 \||\| Nueva \| app-erp01 \|')
    Check 'Compare: VM eliminada' ($tmd -match '\| Eliminada \| app\\?-retirada01')
    Check 'Compare: VM renombrada' ($tmd -match 'Renombrada \| web\\?-banca01 \| antes: web\\?-banca\\?-anterior')
    Check 'Compare: hallazgo resuelto' ($tmd -match '\| Resuelto \|')
    Check 'Compare: crecimiento de datastore (20 GB/día)' ($tmd -match '\| DS\\?-PROD\\?-01 \|[^\r\n]*\| 20 \|')
    Check 'Compare: sin filas vacías' ($tmd -notmatch '(?m)^\|(\s*\|)+\s*$')
    Check 'Compare: snapshots sin cambios = 0 filas' ($tmd -match '## Snapshots \(0\)')

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
