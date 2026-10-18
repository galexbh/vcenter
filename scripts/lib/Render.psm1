# Render de reportes HTML/Markdown a partir de un modelo común (KPIs + tablas + paneles de métricas).
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

function New-PanelCard {
    <#
    .SYNOPSIS  Métrica de un panel: valor ya formateado, % para la barra (opcional) y nivel ok/warn/crit.
    .PARAMETER Group  Agrupa tarjetas bajo un subtítulo (p. ej. el clúster).
    .PARAMETER Key    Id estable de la métrica (raw/metrics.json; lo usan la auditoría y la evolución).
    .PARAMETER Number Valor numérico sin formato, para comparar entre corridas.
    #>
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][AllowEmptyString()][string]$Value, $Pct = $null,
        [ValidateSet('', 'ok', 'warn', 'crit')][string]$Level = '', [string]$Note = '', [string]$Group = '', [string]$Key = '', $Number = $null)
    [pscustomobject]@{ key = $Key; group = $Group; label = $Label; value = $Value; number = $(if ($null -ne $Number) { [double]$Number } else { $null })
        pct = $(if ($null -ne $Pct) { [double]$Pct } else { $null }); level = $Level; note = $Note }
}

function Get-MetricLevel {
    <# Nivel de una métrica según umbrales; -LowerIsWorse para métricas donde menos es peor (holgura, % al día). #>
    param($Value, [double]$Warn, [double]$Crit, [switch]$LowerIsWorse)
    if ($null -eq $Value) { return '' }
    $v = [double]$Value
    if ($LowerIsWorse) { if ($v -le $Crit) { 'crit' } elseif ($v -le $Warn) { 'warn' } else { 'ok' } }
    else { if ($v -ge $Crit) { 'crit' } elseif ($v -ge $Warn) { 'warn' } else { 'ok' } }
}

function New-ReportPanel {
    <#
    .SYNOPSIS  Sección de métricas (tarjetas con barra). También expone columns/rows para el CSV.
    #>
    param([string]$Title, $Cards, [string]$Note = '')
    $list = @($Cards | Where-Object { $_ })
    [pscustomobject]@{ kind = 'panel'; title = $Title; cards = $list; note = $Note
        columns = @('group:Grupo', 'label:Métrica', 'value:Valor', 'note:Nota'); rows = $list }
}

function Format-TextBar {
    <# Barra de texto para Markdown: ████░░░░░░ (10 posiciones). #>
    param($Pct)
    if ($null -eq $Pct) { return '' }
    $n = [int][math]::Round([math]::Min(100, [math]::Max(0, [double]$Pct)) / 10)
    ('█' * $n) + ('░' * (10 - $n))
}

function ConvertTo-PanelHtml {
    <#
    .SYNOPSIS  Tarjetas en HTML. Solo números calculados llegan al atributo style; todo texto se escapa.
    .PARAMETER Bare  Solo las tarjetas, sin <section> ni título (para insertarlas en el informe de auditoría).
    #>
    param($Panel, [switch]$Bare)
    $enc = [System.Net.WebUtility]
    $sb = [System.Text.StringBuilder]::new()
    $note = if ($Panel.note) { "<p class=""note"">$($enc::HtmlEncode("$($Panel.note)"))</p>" } else { '' }
    if (-not $Bare) { [void]$sb.Append("<section class=""panel""><h2>$($enc::HtmlEncode("$($Panel.title)"))</h2>$note") }
    foreach ($g in @($Panel.cards | Group-Object group)) {
        if ($g.Name) { [void]$sb.Append("<h3 class=""pgroup"">$($enc::HtmlEncode($g.Name))</h3>") }
        [void]$sb.Append('<div class="cards">')
        foreach ($c in $g.Group) {
            $lv = if ($c.level) { " $($c.level)" } else { '' }
            [void]$sb.Append("<div class=""card$lv""><div class=""cl"">$($enc::HtmlEncode($c.label))</div><div class=""cv"">$($enc::HtmlEncode($c.value))</div>")
            if ($null -ne $c.pct) {
                $w = [int][math]::Round([math]::Min(100, [math]::Max(0, [double]$c.pct)))
                [void]$sb.Append("<div class=""bar"" role=""presentation""><span style=""width:$w%""></span></div>")
            }
            if ($c.note) { [void]$sb.Append("<div class=""cn"">$($enc::HtmlEncode($c.note))</div>") }
            [void]$sb.Append('</div>')
        }
        [void]$sb.Append('</div>')
    }
    if (-not $Bare) { [void]$sb.Append("</section>`n") } elseif ($note) { [void]$sb.Append($note) }
    $sb.ToString()
}

function ConvertTo-PanelMd {
    <# Panel en Markdown: tabla con valor y barra de texto. -Bare omite el título. #>
    param($Panel, [switch]$Bare)
    $mdEsc = { param($s) ("$s" -replace '[\r\n]+', ' ' -replace '([\\`*_\[\]<>|#])', '\$1') }
    $grouped = @($Panel.cards | Where-Object { $_.group }).Count -gt 0
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not $Bare) { $lines.Add("## $(& $mdEsc $Panel.title)"); $lines.Add('') }
    if ($Panel.note) { $lines.Add("_$(& $mdEsc $Panel.note)_"); $lines.Add('') }
    if (-not @($Panel.cards).Count) { $lines.Add('Sin datos.'); return $lines -join "`n" }
    $lines.Add("|$(if ($grouped) { ' Grupo |' }) Métrica | Valor | Nivel | Nota |")
    $lines.Add("|$(if ($grouped) { '---|' })---|---:|---|---|")
    $lvText = @{ ok = 'ok'; warn = 'atención'; crit = 'crítico' }
    foreach ($c in $Panel.cards) {
        $bar = Format-TextBar $c.pct
        $lv = if ($c.level) { $lvText[$c.level] } else { '' }
        $lines.Add("|$(if ($grouped) { " $(& $mdEsc $c.group) |" }) $(& $mdEsc $c.label) | $(& $mdEsc $c.value) | $(if ($bar) { "$bar " })$lv | $(& $mdEsc $c.note) |")
    }
    $lines -join "`n"
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
            if ($s.PSObject.Properties['kind'] -and $s.kind -eq 'panel') { [void]$sb.Append((ConvertTo-PanelHtml $s)); continue }
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
            if ($s.PSObject.Properties['kind'] -and $s.kind -eq 'panel') { ConvertTo-PanelMd $s; continue }
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

Export-ModuleMember -Function New-ReportTable, New-PanelCard, Get-MetricLevel, New-ReportPanel, Format-TextBar, ConvertTo-PanelHtml, ConvertTo-PanelMd, New-FindingList, Add-ReportFinding, Export-ReportFinding, Sort-ReportFinding, Get-FindingColumns, Write-GovcReport, ConvertTo-HtmlText, Expand-Template, Format-MdCode
