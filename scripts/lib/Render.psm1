# Render de reportes HTML/Markdown a partir de un modelo común (KPIs + secciones de tabla).
# Usado por scripts/New-Report.ps1 y scripts/Invoke-HostCheck.ps1.

Set-StrictMode -Version Latest

$script:SevClass = @{ 'Crítico' = 'crit'; 'Advertencia' = 'warn'; 'Info' = 'info' }
$script:SevOrder = @{ 'Crítico' = 0; 'Advertencia' = 1; 'Info' = 2 }

function New-ReportTable {
    <# Sección de reporte. Columnas como 'propiedad:Encabezado'. #>
    param([string]$Title, [string[]]$Columns, $Rows, [string]$Note = '')
    [pscustomobject]@{ title = $Title; columns = $Columns; rows = @($Rows); note = $Note }
}

function New-FindingList { return , (New-Object System.Collections.Generic.List[object]) }

function Add-ReportFinding {
    <# Rule: código estable de la regla (p. ej. 'ds-used'); con Object identifica el hallazgo entre corridas. #>
    param($List, $Severity, $Category, $Object, $Evidence, $Suggestion, $Command = '', [string]$Rule = '')
    if (-not $Rule) { $Rule = ("$Category" -replace '[^\p{L}\p{N}]+', '-').ToLowerInvariant() }
    $List.Add([pscustomobject]@{ severity = $Severity; category = $Category; object = $Object; evidence = $Evidence; suggestion = $Suggestion; command = $Command; rule = $Rule })
}

function Export-ReportFinding {
    <# Guarda los hallazgos en JSON (entrada de auditoría y tendencias). #>
    param($List, [Parameter(Mandatory)][string]$Path)
    ConvertTo-Json -InputObject @($List) -Depth 6 | Set-Content $Path -Encoding utf8
}

function Sort-ReportFinding {
    param($List)
    return , @($List | Sort-Object { $script:SevOrder[$_.severity] }, category, object)
}

function Get-FindingColumns {
    return @('severity:Severidad', 'category:Categoría', 'object:Objeto', 'evidence:Evidencia', 'suggestion:Sugerencia', 'command:Comando para revisar')
}

function Write-GovcReport {
    <#
    .SYNOPSIS  Escribe el reporte en los formatos pedidos y devuelve las rutas generadas.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Env,
        [Parameter(Mandatory)][datetime]$Generated,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Kpis,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sections,
        [string[]]$Format = @('html', 'md'),
        [string]$Source = 'govc object.collect (solo lectura)',
        [int]$MdMaxRows = 200
    )
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    # Los textos vienen de vCenter (nombres, anotaciones, eventos): se escapan para que no
    # puedan inyectar enlaces, HTML o formato en el Markdown.
    $mdEsc = { param($s) ("$s" -replace "`r?`n", ' ' -replace '([\\`*_\[\]<>|#])', '\$1') }
    $stamp = $Generated.ToString('yyyy-MM-dd HH:mm')
    $written = @()

    if ('html' -in $Format) {
        $kpiHtml = ($Kpis.GetEnumerator() | ForEach-Object { "<div class=""kpi""><span class=""v"">$($_.Value)</span><span class=""l"">$(& $enc $_.Key)</span></div>" }) -join "`n"
        $secHtml = foreach ($s in $Sections) {
            $cols = $s.columns | ForEach-Object { , ($_ -split ':', 2) }
            $head = ($cols | ForEach-Object { "<th>$(& $enc $_[1])</th>" }) -join ''
            $body = if ($s.rows.Count) {
                ($s.rows | ForEach-Object { $r = $_
                        $cells = $cols | ForEach-Object {
                            $val = $r.($_[0])
                            if ($_[0] -eq 'severity') { "<td><span class=""sev $($script:SevClass[$val])"">$(& $enc $val)</span></td>" }
                            elseif ($_[0] -eq 'command' -and $val) { "<td><code>$(& $enc $val)</code></td>" }
                            else { "<td>$(& $enc $val)</td>" }
                        }
                        "<tr>$($cells -join '')</tr>" }) -join "`n"
            } else { "<tr><td colspan=""$($cols.Count)"" class=""empty"">Sin elementos.</td></tr>" }
            $note = if ($s.note) { "<p class=""note"">$(& $enc $s.note)</p>" } else { '' }
            "<section><h2>$(& $enc $s.title) <small>($($s.rows.Count))</small></h2>$note<div class=""scroll""><table><thead><tr>$head</tr></thead><tbody>$body</tbody></table></div></section>"
        }
        $html = (Get-Content (Join-Path $Root 'templates/report.html') -Raw).
            Replace('{{TITLE}}', (& $enc $Title)).Replace('{{ENV}}', (& $enc $Env.ToUpper())).
            Replace('{{GENERATED}}', $stamp).Replace('{{SOURCE}}', (& $enc $Source)).
            Replace('{{KPIS}}', $kpiHtml).Replace('{{SECTIONS}}', ($secHtml -join "`n"))
        $f = Join-Path $OutDir "$BaseName.html"; Set-Content $f $html -Encoding utf8; $written += $f
    }
    if ('md' -in $Format) {
        $kpiMd = "| Indicador | Valor |`n|---|---:|`n" + (($Kpis.GetEnumerator() | ForEach-Object { "| $($_.Key) | $($_.Value) |" }) -join "`n")
        $secMd = foreach ($s in $Sections) {
            $cols = $s.columns | ForEach-Object { , ($_ -split ':', 2) }
            $lines = @("## $($s.title) ($($s.rows.Count))", '')
            if ($s.note) { $lines += "_$($s.note)_", '' }
            if ($s.rows.Count) {
                $lines += '| ' + (($cols | ForEach-Object { $_[1] }) -join ' | ') + ' |'
                $lines += '|' + (($cols | ForEach-Object { '---' }) -join '|') + '|'
                foreach ($r in ($s.rows | Select-Object -First $MdMaxRows)) {
                    $lines += '| ' + (($cols | ForEach-Object { $v = $r.($_[0]); if ($_[0] -eq 'command' -and $v) { "``$v``" } else { & $mdEsc $v } }) -join ' | ') + ' |'
                }
                if ($s.rows.Count -gt $MdMaxRows) { $lines += '', "_Se muestran $MdMaxRows de $($s.rows.Count) filas; ver el HTML para la lista completa._" }
            } else { $lines += 'Sin elementos.' }
            $lines -join "`n"
        }
        $md = (Get-Content (Join-Path $Root 'templates/report.md') -Raw).
            Replace('{{TITLE}}', $Title).Replace('{{ENV}}', $Env.ToUpper()).Replace('{{GENERATED}}', $stamp).
            Replace('{{SOURCE}}', $Source).Replace('{{KPIS}}', $kpiMd).Replace('{{SECTIONS}}', ($secMd -join "`n`n"))
        $f = Join-Path $OutDir "$BaseName.md"; Set-Content $f $md -Encoding utf8; $written += $f
    }
    return , $written
}

function ConvertTo-HtmlText { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }

Export-ModuleMember -Function New-ReportTable, New-FindingList, Add-ReportFinding, Export-ReportFinding, Sort-ReportFinding, Get-FindingColumns, Write-GovcReport, ConvertTo-HtmlText
