# Render de reportes HTML/Markdown a partir de un modelo común (KPIs + secciones de tabla).
# Usado por New-Report, Invoke-HostCheck, Invoke-PerfCheck, Invoke-Audit y Compare-Report.
# Todo texto que pueda venir de vCenter (incluidos indicadores, títulos y notas) se escapa.

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

function Expand-Template {
    <#
    .SYNOPSIS  Reemplaza {{MARCADORES}} en una sola pasada.
    .NOTES     El contenido insertado no se vuelve a procesar: un dato de vCenter que contenga
               "{{SECTIONS}}" se muestra literal en lugar de expandirse.
    #>
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][hashtable]$Map)
    [regex]::Replace($Template, '\{\{([A-Z_]+)\}\}', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $k = $m.Groups[1].Value
            if ($Map.ContainsKey($k)) { [string]$Map[$k] } else { $m.Value }
        })
}

function Format-MdCode {
    <# Código en línea para Markdown: el delimitador es más largo que la mayor racha de comillas invertidas del texto. #>
    param([string]$Text)
    $Text = $Text -replace '[\r\n]+', ' '
    $longest = 0
    foreach ($m in [regex]::Matches($Text, '`+')) { if ($m.Length -gt $longest) { $longest = $m.Length } }
    if (-not $longest) { return '`' + $Text + '`' }
    $d = '`' * ($longest + 1)
    return "$d $Text $d"
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
    $enc = [System.Net.WebUtility]
    # Los textos vienen de vCenter (nombres, anotaciones, eventos): se escapan para que no
    # puedan inyectar enlaces, HTML o formato en el Markdown.
    $mdEsc = { param($s) ("$s" -replace '[\r\n]+', ' ' -replace '([\\`*_\[\]<>|#])', '\$1') }
    $stamp = $Generated.ToString('yyyy-MM-dd HH:mm')
    $written = New-Object System.Collections.Generic.List[string]

    if ('html' -in $Format) {
        $kpiHtml = ($Kpis.GetEnumerator() | ForEach-Object { "<div class=""kpi""><span class=""v"">$($enc::HtmlEncode("$($_.Value)"))</span><span class=""l"">$($enc::HtmlEncode("$($_.Key)"))</span></div>" }) -join "`n"
        $sb = [System.Text.StringBuilder]::new()
        foreach ($s in $Sections) {
            $cols = @($s.columns | ForEach-Object { , ($_ -split ':', 2) })
            $note = if ($s.note) { "<p class=""note"">$($enc::HtmlEncode("$($s.note)"))</p>" } else { '' }
            [void]$sb.Append("<section><h2>$($enc::HtmlEncode("$($s.title)")) <small>($($s.rows.Count))</small></h2>$note<div class=""scroll""><table><thead><tr>")
            foreach ($c in $cols) { [void]$sb.Append('<th>').Append($enc::HtmlEncode($c[1])).Append('</th>') }
            [void]$sb.Append('</tr></thead><tbody>')
            if ($s.rows.Count) {
                foreach ($r in $s.rows) {
                    [void]$sb.Append('<tr>')
                    foreach ($c in $cols) {
                        $val = $r.($c[0]); $t = $enc::HtmlEncode("$val")
                        if ($c[0] -eq 'severity') { [void]$sb.Append("<td><span class=""sev $($script:SevClass["$val"])"">$t</span></td>") }
                        elseif ($c[0] -eq 'command' -and $val) { [void]$sb.Append("<td><code>$t</code></td>") }
                        else { [void]$sb.Append("<td>$t</td>") }
                    }
                    [void]$sb.Append("</tr>`n")
                }
            } else { [void]$sb.Append("<tr><td colspan=""$($cols.Count)"" class=""empty"">Sin elementos.</td></tr>") }
            [void]$sb.Append("</tbody></table></div></section>`n")
        }
        $html = Expand-Template (Get-Content (Join-Path $Root 'templates/report.html') -Raw) @{
            TITLE = $enc::HtmlEncode($Title); ENV = $enc::HtmlEncode($Env.ToUpper()); GENERATED = $stamp; SOURCE = $enc::HtmlEncode($Source)
            KPIS = $kpiHtml; SECTIONS = $sb.ToString()
        }
        $f = Join-Path $OutDir "$BaseName.html"; Set-Content -LiteralPath $f $html -Encoding utf8; $written.Add($f)
    }
    if ('md' -in $Format) {
        $kpiMd = "| Indicador | Valor |`n|---|---:|`n" + (($Kpis.GetEnumerator() | ForEach-Object { "| $(& $mdEsc $_.Key) | $(& $mdEsc $_.Value) |" }) -join "`n")
        $secMd = foreach ($s in $Sections) {
            $cols = @($s.columns | ForEach-Object { , ($_ -split ':', 2) })
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add("## $(& $mdEsc $s.title) ($($s.rows.Count))"); $lines.Add('')
            if ($s.note) { $lines.Add("_$(& $mdEsc $s.note)_"); $lines.Add('') }
            if ($s.rows.Count) {
                $lines.Add('| ' + (($cols | ForEach-Object { & $mdEsc $_[1] }) -join ' | ') + ' |')
                $lines.Add('|' + (($cols | ForEach-Object { '---' }) -join '|') + '|')
                foreach ($r in ($s.rows | Select-Object -First $MdMaxRows)) {
                    $cells = foreach ($c in $cols) { $v = $r.($c[0]); if ($c[0] -eq 'command' -and $v) { Format-MdCode ("$v" -replace '\|', '\|') } else { & $mdEsc $v } }
                    $lines.Add('| ' + ($cells -join ' | ') + ' |')
                }
                if ($s.rows.Count -gt $MdMaxRows) { $lines.Add(''); $lines.Add("_Se muestran $MdMaxRows de $($s.rows.Count) filas; ver el HTML para la lista completa._") }
            } else { $lines.Add('Sin elementos.') }
            $lines -join "`n"
        }
        $md = Expand-Template (Get-Content (Join-Path $Root 'templates/report.md') -Raw) @{
            TITLE = (& $mdEsc $Title); ENV = $Env.ToUpper(); GENERATED = $stamp; SOURCE = (& $mdEsc $Source); KPIS = $kpiMd; SECTIONS = ($secMd -join "`n`n")
        }
        $f = Join-Path $OutDir "$BaseName.md"; Set-Content -LiteralPath $f $md -Encoding utf8; $written.Add($f)
    }
    return , $written.ToArray()
}

function ConvertTo-HtmlText { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }

Export-ModuleMember -Function New-ReportTable, New-FindingList, Add-ReportFinding, Export-ReportFinding, Sort-ReportFinding, Get-FindingColumns, Write-GovcReport, ConvertTo-HtmlText, Expand-Template, Format-MdCode
