<#
.SYNOPSIS
  Pruebas de regresión de los reportes: New-Report, CSV, métricas, Invoke-HostCheck, Invoke-PerfCheck,
  Invoke-Audit (con evolución), impacto y prioridades, right-sizing, análisis de Claude, catálogo de textos,
  ausencia de helpers duplicados y Compare-Report, sobre datos demo generados con New-DemoData.ps1 -EdgeCases. No contacta vCenter.

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
function Test-CspHashes([string]$Html) {
    # Cada script en línea autorizado por su hash; el navegador lo calcula sobre el texto con LF.
    $csp = [regex]::Match($Html, 'http-equiv="Content-Security-Policy" content="([^"]+)"').Groups[1].Value
    $scripts = @([regex]::Matches(($Html -replace "`r`n", "`n"), '<script>([\s\S]*?)</script>') | ForEach-Object { $_.Groups[1].Value })
    $csp -and ($csp -match "default-src 'none'") -and $scripts.Count -and -not @($scripts | Where-Object {
            $h = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($_)))
            $csp -notmatch [regex]::Escape("'sha256-$h'") }).Count
}
function Get-BrokenLinks([string]$Html) {
    # Enlaces internos (#id) sin elemento destino.
    $ids = @{}; foreach ($m in [regex]::Matches($Html, ' id="([^"]+)"')) { $ids[$m.Groups[1].Value] = 1 }
    @([regex]::Matches($Html, 'href="#([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { -not $ids.ContainsKey($_) } | Sort-Object -Unique)
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
    # VMs expuestas (impacto) con valores conocidos de los datos demo.
    $rawHosts = @(Json (Join-Path $rep 'raw/hosts.json'))
    $onRawVms = @($realVms | Where-Object { $_.'runtime.powerState' -eq 'poweredOn' })
    $ds01Vms = @($onRawVms | Where-Object { @($_.datastore | ForEach-Object { $_.value }) -contains 'datastore-11' }).Count
    $cl02Hosts = @($rawHosts | Where-Object { $_.parent.value -eq 'domain-c20' } | ForEach-Object { $_._moref })
    $cl02Vms = @($onRawVms | Where-Object { $_.PSObject.Properties['runtime.host'] -and $_.'runtime.host'.value -in $cl02Hosts }).Count
    $fDs = $nf | Where-Object { $_.rule -eq 'ds-used' -and $_.object -eq 'DS-PROD-01' }
    $fN1 = $nf | Where-Object { $_.rule -eq 'cl-n1-mem' -and $_.object -eq 'CL-PROD-02' }
    Check 'Impacto: VMs encendidas de DS-PROD-01' ($fDs.impact -eq $ds01Vms -and $ds01Vms -gt 0) "$($fDs.impact) vs $ds01Vms"
    Check 'Impacto: VMs encendidas de CL-PROD-02 (N+1)' ($fN1.impact -eq $cl02Vms -and $cl02Vms -gt 0) "$($fN1.impact) vs $cl02Vms"
    Check 'Impacto: N+1 estima las VMs sin capacidad para reiniciarse' ("$($fN1.evidence)" -match '~\d+ VMs sin capacidad para reiniciarse')
    Check 'Impacto: snapshot = 1 VM; certificado sin dato' ((@($nf | Where-Object rule -eq 'snap-age')[0].impact -eq 1) -and $null -eq ($nf | Where-Object rule -eq 'cert-vc').impact)
    Check 'HTML: columna VMs expuestas' ($html -match '<th class="n">VMs expuestas</th>')
    # Prioridades: primera sección; el crítico con más VMs va antes que el crítico con una.
    Check 'HTML: Prioridades es la primera sección' (([regex]::Match($html, '<h2>([^<]+)')).Groups[1].Value -match '^Prioridades')
    $pr = @(Get-ReportPriority @(
            [pscustomobject]@{ severity = 'Crítico'; category = 'A'; object = 'uno'; evidence = 'e'; suggestion = 's1'; command = ''; rule = 'r1'; impact = 1 }
            [pscustomobject]@{ severity = 'Crítico'; category = 'A'; object = 'cuarenta'; evidence = 'e'; suggestion = 's2'; command = ''; rule = 'r2'; impact = 40 }
            [pscustomobject]@{ severity = 'Info'; category = 'A'; object = 'info'; evidence = 'e'; suggestion = 's3'; command = ''; rule = 'r3'; impact = 900 }))
    Check 'Prioridades: el crítico con más VMs primero; Info no entra' ($pr.Count -eq 2 -and $pr[0].action -eq 's2' -and $pr[0].n -eq 1 -and $pr[1].action -eq 's1')
    Check 'Prioridades: agrupa por regla (DS-PROD-01 con su alarma aparte)' (@(Get-ReportPriority $nf 50 | Where-Object { $_.why -like 'Almacenamiento:*DS-PROD-01*' }).Count -ge 1)
    # Disco en VMs apagadas = suma del disco usado de las VMs apagadas.
    $offExp = [math]::Round((@($realVms | Where-Object { $_.'runtime.powerState' -eq 'poweredOff' } | ForEach-Object { [math]::Round([double]$_.'summary.storage.committed' / 1GB, 1) }) | Measure-Object -Sum).Sum, 1)
    Check 'Métricas: disco en VMs apagadas' ([math]::Abs((& $metric $mt 'off-disk').number - $offExp) -lt 0.2) "$((& $metric $mt 'off-disk').number) vs $offExp"
    # Cálculos compartidos.
    Check 'Get-DaysToPct: ritmo, sin crecimiento, sin dato y ya superado' ((Get-DaysToPct 1000 800 10) -eq 10 -and [double]::IsPositiveInfinity((Get-DaysToPct 1000 800 0)) -and $null -eq (Get-DaysToPct 1000 800 $null) -and (Get-DaysToPct 1000 950 5) -eq 0)
    # Colecciones vacías (vcsim: sin alarmas, sin críticos): sin elementos nulos ni errores en StrictMode.
    $emptyF = Join-Path $work 'vacio.json'; Set-Content $emptyF '[]' -Encoding utf8
    $emptyArr = Read-JsonFile $emptyF @() -AsArray
    Check 'Vacíos: [] se lee como arreglo vacío, sin prioridades ni filas nulas' ($emptyArr.Count -eq 0 -and @(Get-ReportPriority @()).Count -eq 0 -and (New-ReportTable 't' @('a:A') $null).rows.Count -eq 0 -and (Get-Sum @() 'x') -eq 0)
    Check 'Get-Percent / Format-Percent' ((Get-Percent 1 3) -eq 33.3 -and $null -eq (Get-Percent 1 0) -and (Format-Percent $null) -eq '—')
    # Formato anterior (sin 'impact'): se renderiza y se exporta sin error en StrictMode.
    $oldRow = [pscustomobject]@{ severity = 'Info'; category = 'c'; object = 'o'; evidence = 'e'; suggestion = 's'; command = ''; rule = 'r' }
    $oldDir = Join-Path $work 'formato-anterior'; New-Item -ItemType Directory -Force $oldDir | Out-Null
    $oldOk = $true
    try {
        $null = Write-GovcReport -Root $root -OutDir $oldDir -BaseName 'x' -Title 't' -Env 'demo' -Generated (Get-Date) -Kpis ([ordered]@{ a = 1 }) -Sections @(New-ReportTable 'Hallazgos' (Get-FindingColumns) @($oldRow))
        $null = Export-GovcCsv -OutDir $oldDir -BaseName 'x' -Kpis ([ordered]@{ a = 1 }) -Sections @(New-ReportTable 'Hallazgos' (Get-FindingColumns) @($oldRow))
    } catch { $oldOk = $false }
    Check 'Formato anterior sin impact: render y CSV sin error' $oldOk
    # Análisis de Claude: subconjunto seguro de Markdown (sin HTML ni enlaces).
    Set-Content (Join-Path $rep 'raw/analysis.md') "# Diagnóstico`n`nTexto **clave**, *nota* y ``cmd <x>``. <script>alert(2)</script> [enlace](http://x)`n`n- uno`n- dos" -Encoding utf8
    Quiet { & "$S/New-Report.ps1" -FromRaw $rep -Format html, md } | Out-Null
    $ah2 = Get-Content (Join-Path $rep 'reporte-all.html') -Raw; $am2 = Get-Content (Join-Path $rep 'reporte-all.md') -Raw
    Check 'Análisis: sección después de Prioridades' ($ah2 -match '<h2>Prioridades[\s\S]*?<section class="analysis" id="sec-analisis-de-claude-ia"><h2>An')
    # IA: resumen arriba y vigencia por huella.
    Check 'IA: resumen de Claude arriba, con enlace al análisis' ($ah2 -match '<aside class="ai-summary"' -and $ah2 -match 'href="#sec-analisis-de-claude-ia">Ver an')
    Check 'IA: sin huella, vigencia no verificable' ($ah2 -match 'class="ai-unverified"' -and $ah2 -notmatch 'class="ai-stale"')
    $fpNow = (Get-Content (Join-Path $rep 'raw/fingerprint.txt') -Raw).Trim()
    Check 'IA: huella = Get-FindingFingerprint de los hallazgos' ($fpNow -eq (Get-FindingFingerprint @(Json (Join-Path $rep 'raw/findings.json'))) -and $fpNow -match '^[0-9a-f]{12}$')
    Set-Content (Join-Path $rep 'raw/analysis.md') "<!-- huella: $fpNow -->`n## Diagnóstico`n`nTodo en orden." -Encoding utf8
    Quiet { & "$S/New-Report.ps1" -FromRaw $rep -Format html } | Out-Null
    $ah4 = Get-Content (Join-Path $rep 'reporte-all.html') -Raw
    Check 'IA: huella vigente, sin aviso y sin la línea de huella visible' ($ah4 -notmatch 'class="ai-(stale|unverified)"' -and $ah4 -notmatch 'huella:' -and (Get-Content (Join-Path $rep 'raw/fingerprint.txt') -Raw).Trim() -eq $fpNow)
    Set-Content (Join-Path $rep 'raw/analysis.md') "<!-- huella: 000000000000 -->`n## Diagnóstico`n`nViejo." -Encoding utf8
    Quiet { & "$S/New-Report.ps1" -FromRaw $rep -Format html, md } | Out-Null
    Check 'IA: huella distinta, análisis desactualizado (HTML y MD)' ((Get-Content (Join-Path $rep 'reporte-all.html') -Raw) -match 'class="ai-stale"' -and (Get-Content (Join-Path $rep 'reporte-all.md') -Raw) -match 'desactualizado')
    $fpA = Get-FindingFingerprint @([pscustomobject]@{ rule = 'r'; object = 'o'; severity = 'Crítico' }, [pscustomobject]@{ rule = 'r2'; object = 'o'; severity = 'Info' })
    $fpB = Get-FindingFingerprint @([pscustomobject]@{ rule = 'r2'; object = 'o'; severity = 'Info' }, [pscustomobject]@{ rule = 'r'; object = 'o'; severity = 'Crítico' })
    $fpC = Get-FindingFingerprint @([pscustomobject]@{ rule = 'r'; object = 'o'; severity = 'Advertencia' }, [pscustomobject]@{ rule = 'r2'; object = 'o'; severity = 'Info' })
    Check 'IA: la huella no depende del orden y cambia si cambia un hallazgo' ($fpA -eq $fpB -and $fpA -ne $fpC)
    Check 'Análisis: formato permitido (h3, strong, code, ul)' ($ah2 -match '<h3>Diagn' -and $ah2 -match '<strong>clave</strong>' -and $ah2 -match '<em>nota</em>' -and $ah2 -match '<code>cmd &lt;x&gt;</code>' -and $ah2 -match '<ul><li>uno</li><li>dos</li></ul>')
    Check 'Análisis: sin HTML ni enlaces inyectados' ($ah2 -notmatch '<script>alert\(2\)' -and $ah2 -notmatch '<a href="http://x' -and $am2 -notmatch '<script>alert\(2\)' -and $am2 -match '\\\[enlace\\\]')
    Check 'Análisis: títulos en Markdown como ###' ($am2 -match '(?m)^### Diagn')
    Remove-Item -LiteralPath (Join-Path $rep 'raw/analysis.md')
    # -FromRaw sin -Type usa el tipo guardado en meta.json.
    $typed = Join-Path $work 'tipo-capacidad'
    New-Item -ItemType Directory -Force (Join-Path $typed 'raw') | Out-Null
    foreach ($f in [IO.Directory]::GetFiles((Join-Path $rep 'raw'))) { [IO.File]::Copy($f, (Join-Path $typed "raw/$([IO.Path]::GetFileName($f))")) }
    $tm = Json (Join-Path $typed 'raw/meta.json'); $tm.type = 'capacity'; $tm | ConvertTo-Json | Set-Content (Join-Path $typed 'raw/meta.json') -Encoding utf8
    Quiet { & "$S/New-Report.ps1" -FromRaw $typed -Format md } | Out-Null
    Check '-FromRaw sin -Type respeta el tipo original' ((Test-Path (Join-Path $typed 'reporte-capacity.md')) -and -not (Test-Path (Join-Path $typed 'reporte-all.md')))
    Remove-Item -LiteralPath $typed -Recurse -Force
    Quiet { & "$S/New-Report.ps1" -FromRaw $rep -Format html, md, csv } | Out-Null
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
    # CSP: cada script en línea (tema y script compartido) autorizado por su hash; nada más puede ejecutarse.
    Check 'CSP en el reporte: default-src none y hashes de los 3 scripts válidos' ((Test-CspHashes $html) -and ([regex]::Matches($html, '<script>')).Count -eq 3)
    # --- UX: navegación, tablas e interacción ---------------------------------------------------
    $js = Get-Content (Join-Path $root 'templates/report.js') -Raw
    $forbidden = @('innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function', 'fetch(', 'XMLHttpRequest', 'import(', 'http:', 'https:', 'localStorage', 'sessionStorage', '</script') | Where-Object { $js.Contains($_) }
    Check 'report.js: sin red, sin HTML dinámico ni almacenamiento' (-not @($forbidden).Count) ($forbidden -join ', ')
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $null = & node --check (Join-Path $root 'templates/report.js') 2>&1
        Check 'report.js: sintaxis válida (node --check)' ($LASTEXITCODE -eq 0)
    }
    $app = Get-ReportScript
    Check 'Script compartido incluido una vez con su hash' ($html.Contains($app.text) -and $html.Contains("'sha256-$($app.hash)'"))
    Check 'Índice: enlaces internos con destino' (-not @(Get-BrokenLinks $html).Count) ((Get-BrokenLinks $html) -join ', ')
    Check 'Índice: una entrada por sección' (([regex]::Matches(([regex]::Match($html, '<nav class="toc"[\s\S]*?</nav>')).Value, '<a href="#sec-')).Count -eq ([regex]::Matches($html, ' id="sec-')).Count)
    $nfCmd = @($nf | Where-Object { $_.command }).Count
    $findTbl = [regex]::Match($html, '<details class="sec" id="sec-hallazgos-y-sugerencias"[\s\S]*?</details>').Value
    Check 'Tablas: filtro, severidad por fila y comandos copiables' ($html -match '<table data-filter>' -and ([regex]::Matches($findTbl, '<tr data-sev="(crit|warn|info)"')).Count -eq $nf.Count -and ([regex]::Matches($findTbl, '<code class="cmd">')).Count -eq $nfCmd) "$nfCmd comandos"
    Check 'Tablas: números a la derecha y vacías con —' ($html -match '<th class="n">VMs expuestas</th>' -and $html -match '<td class="n">\d+</td>' -and $html -match '<td class="empty-cell">—</td>')
    Check 'KPIs: Críticos enlaza y filtra la sección de hallazgos' ($html -match '<a class="kpi crit" href="#sec-hallazgos-y-sugerencias" data-sev="crit">')
    $uxDir = Join-Path $work 'ux'; New-Item -ItemType Directory -Force $uxDir | Out-Null
    $many = @(1..150 | ForEach-Object { [pscustomobject]@{ a = "fila $_"; b = $_ } }); $few = @($many | Select-Object -First 10)
    $null = Write-GovcReport -Root $root -OutDir $uxDir -BaseName 'ux' -Title 't' -Env 'prod' -Generated (Get-Date) -Kpis ([ordered]@{ x = 1 }) -Format html `
        -Sections @((New-ReportTable 'Grande' @('a:A', 'b:B') $many), (New-ReportTable 'Chica' @('a:A', 'b:B') $few))
    $ux = Get-Content (Join-Path $uxDir 'ux.html') -Raw
    Check 'Plegables: más de 100 filas cerrada, 10 abierta' ($ux -match '<details class="sec" id="sec-grande">' -and $ux -match '<details class="sec" id="sec-chica" open>')
    Check 'Insignia: prod en rojo, demo neutra' ($ux -match 'class="env env-prod"' -and $html -match 'class="env ">')
    # Navegador real (opcional): el script corre con la CSP aplicada y agrega barra, chips y Copiar.
    $browser = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($browser) {
        $dom = & $browser --headless=new --disable-gpu --user-data-dir="$(Join-Path $work 'browser')" --dump-dom ([uri](Join-Path $rep 'reporte-all.html')).AbsoluteUri 2>$null | Out-String
        Check 'Navegador: el script corre con la CSP (barra, chips y Copiar)' ($dom -match 'class="tbl-tools"' -and $dom -match 'class="chip' -and $dom -match 'class="copy"')
    } else { Write-Host 'Aviso: prueba en navegador omitida (sin Edge ni Chrome).' -ForegroundColor Yellow }
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
    $hh = @(Json (Join-Path $hdir 'raw/esxcli-hosts.json'))
    $pd = $hf | Where-Object rule -eq 'path-dead' | Select-Object -First 1
    Check 'HostCheck: impacto = VMs encendidas del host' ($pd.impact -eq ($hh | Where-Object name -eq 'esx01.demo.local').vmCount -and $pd.impact -gt 0) "$($pd.impact)"
    Check 'HostCheck: drift de clúster = VMs de sus hosts' ((@($hf | Where-Object { $_.rule -eq 'vib-drift' -and $_.object -like 'CL-PROD-02 / *' })[0].impact) -eq (($hh | Where-Object cluster -eq 'CL-PROD-02' | Measure-Object vmCount -Sum).Sum))
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
    Check 'PerfCheck: hallazgos en categoría Rendimiento, Capacidad (right-sizing) o Cobertura' (-not @($pf | Where-Object { $_.category -notin 'Rendimiento', 'Capacidad', 'Cobertura' }).Count)
    Check 'PerfCheck: latencia por datastore (un hallazgo por datastore)' (@($pf | Where-Object { $_.rule -eq 'perf-ds-latency' -and $_.object -eq 'DS-PROD-01' }).Count -eq 1)
    $pm3 = @(Json (Join-Path $pdir 'raw/metrics.json'))
    $worstDs = $pm3 | Where-Object key -eq 'perf-ds-worst'
    Check 'PerfCheck: peor latencia p95 = 35,2 ms en DS-PROD-01' ($worstDs.number -eq 35.2 -and "$($worstDs.note)" -like 'DS-PROD-01*') "$($worstDs.number) $($worstDs.note)"
    $ph = Get-Content (Join-Path $pdir 'perf-check.html') -Raw
    Check 'Paneles: grupos en el orden definido (no alfabético)' ($ph.IndexOf((ConvertTo-HtmlText 'Más CPU ready (p95)')) -ge 0 -and $ph.IndexOf((ConvertTo-HtmlText 'Más CPU ready (p95)')) -lt $ph.IndexOf((ConvertTo-HtmlText 'Más CPU de host (p95)')))
    Check 'PerfCheck: top 5 por métrica' (@($pm3 | Where-Object group -eq 'Más CPU ready (p95)').Count -eq 5)
    $ov = $pf | Where-Object rule -eq 'perf-oversized'
    Check 'Right-sizing: mon-obs sobredimensionadas (8→2 vCPU, 32→8 GB)' ($ov -and $ov.category -eq 'Capacidad' -and $ov.impact -eq 3 -and "$($ov.evidence)" -match 'mon-obs01 \(8→2 vCPU, 32→8 GB\)') "$($ov.evidence)"
    Check 'Right-sizing: capacidad recuperable en el panel' ((($pm3 | Where-Object key -eq 'perf-reclaim-vcpu').number -eq 18) -and (($pm3 | Where-Object key -eq 'perf-reclaim-mem').number -eq 72))
    $p1h = Join-Path $work 'perf-1h'; Copy-Item -LiteralPath $pdir -Destination $p1h -Recurse
    $pm1 = Json (Join-Path $p1h 'raw/meta-perf.json'); $pm1.window = '1h'; $pm1 | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $p1h 'raw/meta-perf.json') -Encoding utf8
    Quiet { & "$S/Invoke-PerfCheck.ps1" -FromRaw $p1h -Format md } | Out-Null
    Check 'Right-sizing: omitido con ventana 1h' (-not (HasRule @(Json (Join-Path $p1h 'raw/findings.json')) 'perf-oversized') -and "$((@(Json (Join-Path $p1h 'raw/metrics.json')) | Where-Object key -eq 'perf-reclaim-vcpu').note)" -match '24h o 7d')
    Remove-Item -LiteralPath $p1h -Recurse -Force
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
    Check 'Audit MD: marcador en datos no se expande (un solo plan de remediación)' (([regex]::Matches($amd, '\| Prioridad \| ID \| Severidad \| Objeto \| VMs \| Acción')).Count -eq 1)
    Check 'Audit HTML: codifica contenido de vCenter' ($ah -notmatch '<script>alert')
    Check 'Audit HTML: CSP con los hashes de sus scripts' (Test-CspHashes $ah)
    Check 'Audit HTML: enlaces internos (Contenido y AUD-NNN) con destino' (-not @(Get-BrokenLinks $ah).Count -and $ah -match '<a class="aud" href="#aud-001">AUD-001</a>' -and $ah -match '<article class="finding \w+" id="aud-001">') ((Get-BrokenLinks $ah) -join ', ')
    Check 'Audit: métricas clave en audit.json' (@($aj.metrics | Where-Object key -eq 'cl-n1').Count -eq 1 -and @($aj.metrics).Count -ge 6)
    Check 'Audit: primera auditoría sin evolución' ($null -eq $aj.evolution -and $ah -match [regex]::Escape([System.Net.WebUtility]::HtmlEncode('Primera auditoría del entorno')))
    Check 'Audit HTML: firma de Arquitectura' ($ah -match '<div class="role">Revisado por</div><div>Arquitectura</div>')
    $pri = @($aj.findings | Where-Object { $_.priority -gt 0 } | Sort-Object priority -Descending)
    Check 'Audit: prioridad por hallazgo y principales riesgos en ese orden' ($pri.Count -and $ah -match ('>' + [regex]::Escape($pri[0].id) + '</a></td>') -and ([regex]::Match($ah, 'Principales riesgos[\s\S]*?>(AUD-\d+)</a></td>')).Groups[1].Value -eq $pri[0].id)
    Check 'Audit: plan de remediación con prioridad y VMs' ($ah -match '<th class="n">Prioridad</th>' -and $amd -match '\| Prioridad \| ID \|')
    Check 'Get-FindingKey: igual a la clave de audit.json' ((Get-FindingKey ([pscustomobject]@{ rule = $aj.findings[0].rule; object = $aj.findings[0].object })) -eq $aj.findings[0].key)
    Set-Content (Join-Path $audit 'raw/analysis.md') "## Diagnóstico`n`nTexto de prueba <b>x</b>." -Encoding utf8
    Quiet { & "$S/Invoke-Audit.ps1" -FromRaw $audit -Format html, md } | Out-Null
    $ah3 = Get-Content (Join-Path $audit 'auditoria.html') -Raw
    Check 'Audit: análisis de Claude en el resumen ejecutivo, escapado' ($ah3 -match '<div class="analysis"><h3>Diagn' -and $ah3 -match '&lt;b&gt;x&lt;/b&gt;' -and (Get-Content (Join-Path $audit 'auditoria.md') -Raw) -match '### An')
    Remove-Item -LiteralPath (Join-Path $audit 'raw/analysis.md')
    Quiet { & "$S/Invoke-Audit.ps1" -FromRaw $audit -Format html, md } | Out-Null
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
    $srcText = (@('New-Report.ps1', 'Invoke-HostCheck.ps1', 'Invoke-PerfCheck.ps1', 'Invoke-Audit.ps1', 'Compare-Report.ps1') | ForEach-Object { Get-Content (Join-Path $S $_) -Raw }) -join "`n"
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
    $allowed = @{ 'path-dead' = 'storage'; 'snap-age' = 'dueño'; 'vm-off' = 'dueño'; 'perf-oversized' = 'dueño' }
    $bad = @($texts | Where-Object { $_.text -match $areas -and -not ($allowed[$_.rule] -and $Matches[0].ToLowerInvariant() -eq $allowed[$_.rule]) } | ForEach-Object { "$($_.rule): $($Matches[0])" })
    $bad += @($cat.Notes.Keys | Where-Object { "$($cat.Notes[$_])" -match $areas } | ForEach-Object { "nota $_" })
    Check 'Menciones: solo path-dead (Storage) y snap-age, vm-off, perf-oversized (dueño)' (-not $bad.Count) ($bad -join '; ')
    # Sin duplicados: los helpers consolidados en lib/ no se vuelven a definir en los scripts.
    $libText = (Get-ChildItem (Join-Path $S 'lib') -Filter *.psm1 | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    $dupPatterns = '\$(pctOf|fmtPct|keyOf|sevCss|sevOrder|mdEsc|esc|enc|slug)\s*=', 'SHA256\]::HashData\(\[Text\.Encoding\]::UTF8\.GetBytes\("\$\(\$\w+\.rule\)', '0\.9 \* \$', 'Round\(100 \* ', 'Measure-Object [^)]*-Sum\)\.Sum'
    $dups = @(foreach ($pt in $dupPatterns) { if ($srcText -match $pt) { $Matches[0] } })
    Check 'Sin duplicados: helpers locales consolidados en lib/' (-not $dups.Count) ($dups -join '; ')
    Check 'Sin duplicados: una sola definición por función en lib/' (-not @([regex]::Matches($libText, '(?m)^function ([\w-]+)') | Group-Object { $_.Groups[1].Value } | Where-Object Count -gt 1).Count)
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
    Set-Content (Join-Path $tdir 'raw/analysis.md') "## Diagnóstico`n`nDS-PROD-01 crece 20 GB/día." -Encoding utf8
    Quiet { & "$S/Compare-Report.ps1" -Base $base -Current $rep -OutDir $tdir -Format md } | Out-Null
    Check 'Compare: incluye el análisis de Claude (/trend)' ((Get-Content (Join-Path $tdir 'tendencia.md') -Raw) -match '## An[áa]lisis de Claude')
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
