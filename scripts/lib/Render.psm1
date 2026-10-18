# Render de reportes HTML/Markdown a partir de un modelo común (KPIs + tablas + paneles de métricas + análisis).
# Usado por New-Report, Invoke-HostCheck, Invoke-PerfCheck, Invoke-Audit y Compare-Report.
# Todo texto que pueda venir de vCenter (incluidos indicadores, títulos y notas) se escapa.
# Capa base: no depende de Common.psm1 (Common sí usa este módulo).

Set-StrictMode -Version Latest

$script:SevClass = @{ 'Crítico' = 'crit'; 'Advertencia' = 'warn'; 'Info' = 'info' }
$script:SevOrder = @{ 'Crítico' = 0; 'Advertencia' = 1; 'Info' = 2 }

# --- Severidad, texto y celdas ---------------------------------------------------------------

function Get-SeverityRank { param([string]$Severity) $r = $script:SevOrder[$Severity]; if ($null -eq $r) { 9 } else { $r } }
function Get-SeverityClass { param([string]$Severity) "$($script:SevClass[$Severity])" }

function ConvertTo-MdText {
    <# Escapa texto de vCenter para Markdown (sin enlaces, HTML ni formato inyectado; sin saltos de línea). #>
    param($Text)
    ("$Text" -replace '[\r\n]+', ' ' -replace '([\\`*_\[\]<>|#])', '\$1')
}

function ConvertTo-HtmlText { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }

function Get-CellValue {
    <# Valor de una columna; $null si la fila no tiene la propiedad (datos de versiones anteriores, StrictMode). #>
    param($Row, [string]$Name)
    if ($null -eq $Row) { return $null }
    $p = $Row.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Get-BarPct { param($Pct) [int][math]::Round([math]::Min(100, [math]::Max(0, [double]$Pct))) }

# --- Modelo de secciones -----------------------------------------------------------------------

function New-ReportTable {
    <# Sección de reporte. Columnas como 'propiedad:Encabezado'. #>
    param([string]$Title, [string[]]$Columns, $Rows, [string]$Note = '')
    [pscustomobject]@{ title = $Title; columns = $Columns; rows = @($Rows | Where-Object { $null -ne $_ }); note = $Note }
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
    <# Sección de métricas (tarjetas con barra). También expone columns/rows para el CSV. #>
    param([string]$Title, $Cards, [string]$Note = '')
    $list = @($Cards | Where-Object { $_ })
    [pscustomobject]@{ kind = 'panel'; title = $Title; cards = $list; note = $Note
        columns = @('group:Grupo', 'label:Métrica', 'value:Valor', 'note:Nota'); rows = $list }
}

function New-ReportAnalysis {
    <# Sección de texto redactado (análisis de Claude). Sin columnas: el CSV no la exporta. #>
    param([string]$Title, [string]$Text, [string]$Note = '')
    [pscustomobject]@{ kind = 'analysis'; title = $Title; text = $Text; note = $Note; columns = @(); rows = @() }
}

function Format-TextBar {
    <# Barra de texto para Markdown: ████░░░░░░ (10 posiciones). #>
    param($Pct)
    if ($null -eq $Pct) { return '' }
    $n = [int][math]::Round((Get-BarPct $Pct) / 10)
    ('█' * $n) + ('░' * (10 - $n))
}

function ConvertTo-PanelHtml {
    <#
    .SYNOPSIS  Tarjetas en HTML. Solo números calculados llegan al atributo style; todo texto se escapa.
    .PARAMETER Bare  Solo las tarjetas, sin <section> ni título (para insertarlas en el informe de auditoría).
    #>
    param($Panel, [switch]$Bare)
    $sb = [System.Text.StringBuilder]::new()
    $note = if ($Panel.note) { "<p class=""note"">$(ConvertTo-HtmlText $Panel.note)</p>" } else { '' }
    if (-not $Bare) { [void]$sb.Append("<section class=""panel""><h2>$(ConvertTo-HtmlText $Panel.title)</h2>$note") }
    # Grupos en el orden en que aparecen (Group-Object los ordenaría alfabéticamente).
    $groups = [ordered]@{}
    foreach ($c in $Panel.cards) { $k = "$($c.group)"; if (-not $groups.Contains($k)) { $groups[$k] = New-Object System.Collections.Generic.List[object] }; $groups[$k].Add($c) }
    foreach ($name in $groups.Keys) {
        if ($name) { [void]$sb.Append("<h3 class=""pgroup"">$(ConvertTo-HtmlText $name)</h3>") }
        [void]$sb.Append('<div class="cards">')
        foreach ($c in $groups[$name]) {
            $lv = if ($c.level) { " $($c.level)" } else { '' }
            [void]$sb.Append("<div class=""card$lv""><div class=""cl"">$(ConvertTo-HtmlText $c.label)</div><div class=""cv"">$(ConvertTo-HtmlText $c.value)</div>")
            if ($null -ne $c.pct) { [void]$sb.Append("<div class=""bar"" role=""presentation""><span style=""width:$(Get-BarPct $c.pct)%""></span></div>") }
            if ($c.note) { [void]$sb.Append("<div class=""cn"">$(ConvertTo-HtmlText $c.note)</div>") }
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
    $grouped = @($Panel.cards | Where-Object { $_.group }).Count -gt 0
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not $Bare) { $lines.Add("## $(ConvertTo-MdText $Panel.title)"); $lines.Add('') }
    if ($Panel.note) { $lines.Add("_$(ConvertTo-MdText $Panel.note)_"); $lines.Add('') }
    if (-not @($Panel.cards).Count) { $lines.Add('Sin datos.'); return $lines -join "`n" }
    $lines.Add("|$(if ($grouped) { ' Grupo |' }) Métrica | Valor | Nivel | Nota |")
    $lines.Add("|$(if ($grouped) { '---|' })---|---:|---|---|")
    $lvText = @{ ok = 'ok'; warn = 'atención'; crit = 'crítico' }
    foreach ($c in $Panel.cards) {
        $bar = Format-TextBar $c.pct
        $lv = if ($c.level) { $lvText[$c.level] } else { '' }
        $lines.Add("|$(if ($grouped) { " $(ConvertTo-MdText $c.group) |" }) $(ConvertTo-MdText $c.label) | $(ConvertTo-MdText $c.value) | $(if ($bar) { "$bar " })$lv | $(ConvertTo-MdText $c.note) |")
    }
    $lines -join "`n"
}

# --- Texto redactado: subconjunto seguro de Markdown ----------------------------------------------

$script:AnalysisMaxChars = 20000

function Limit-AnalysisText {
    param([string]$Text)
    $t = "$Text" -replace "`r", ''
    if ($t.Length -gt $script:AnalysisMaxChars) { $t = $t.Substring(0, $script:AnalysisMaxChars) + "`n`n(Texto truncado.)" }
    $t
}

function ConvertTo-SafeInlineHtml {
    <# Escapa y luego aplica `código`, **negrita** y *cursiva* (nunca enlaces ni HTML). #>
    param([string]$Text)
    $parts = [regex]::Split($Text, '(`[^`]+`)')
    (@(foreach ($p in $parts) {
                if ($p -match '^`([^`]+)`$') { "<code>$(ConvertTo-HtmlText $Matches[1])</code>" }
                else { [regex]::Replace([regex]::Replace((ConvertTo-HtmlText $p), '\*\*(.+?)\*\*', '<strong>$1</strong>'), '\*([^*\s](?:[^*]*[^*\s])?)\*', '<em>$1</em>') }
            })) -join ''
}

function ConvertTo-SafeHtml {
    <#
    .SYNOPSIS  Markdown restringido a HTML: párrafos, listas (- y 1.), títulos (como h3), **negrita**, *cursiva* y `código`.
    .NOTES     Todo se escapa antes de dar formato: un nombre de vCenter con <script> o [enlace](x) queda literal.
    #>
    param([string]$Text)
    # Bloques consecutivos del mismo tipo (párrafo, ul, ol) se unen; una línea en blanco los separa.
    $blocks = New-Object System.Collections.Generic.List[object]
    $joinable = $false
    foreach ($line in ((Limit-AnalysisText $Text) -split "`n")) {
        if ($line -match '^\s*$') { $joinable = $false; continue }
        if ($line -match '^\s*#{1,6}\s+(.+)$') { $type = 'h3' }
        elseif ($line -match '^\s*[-*]\s+(.+)$') { $type = 'ul' }
        elseif ($line -match '^\s*\d+[.)]\s+(.+)$') { $type = 'ol' }
        else { $type = 'p'; $null = $line -match '^\s*(.+?)\s*$' }
        $text = $Matches[1]
        $last = if ($blocks.Count) { $blocks[$blocks.Count - 1] } else { $null }
        if ($joinable -and $type -ne 'h3' -and $last.type -eq $type) { $last.items.Add($text) }
        else { $blocks.Add([pscustomobject]@{ type = $type; items = [System.Collections.Generic.List[string]]@($text) }) }
        $joinable = $type -ne 'h3'
    }
    (@(foreach ($b in $blocks) {
                switch ($b.type) {
                    'h3' { "<h3>$(ConvertTo-SafeInlineHtml $b.items[0])</h3>" }
                    'p' { "<p>$(ConvertTo-SafeInlineHtml ($b.items -join ' '))</p>" }
                    default { "<$($b.type)>" + (($b.items | ForEach-Object { "<li>$(ConvertTo-SafeInlineHtml $_)</li>" }) -join '') + "</$($b.type)>" }
                }
            })) -join ''
}

function ConvertTo-SafeMd {
    <# Markdown restringido: sin HTML ni enlaces; los títulos bajan a ###. #>
    param([string]$Text)
    ((Limit-AnalysisText $Text) -split "`n" | ForEach-Object {
            $l = $_ -replace '<', '&lt;' -replace '>', '&gt;' -replace '([\[\]])', '\$1'
            $l -replace '^\s*#{1,6}\s+', '### '
        }) -join "`n"
}

# --- Hallazgos ----------------------------------------------------------------------------------

function New-FindingList { return , (New-Object System.Collections.Generic.List[object]) }

function Add-ReportFinding {
    <#
    .SYNOPSIS  Rule: código estable de la regla (p. ej. 'ds-used'); con Object identifica el hallazgo entre corridas.
    .PARAMETER Impact  VMs expuestas al riesgo ($null si no aplica o no se conoce).
    #>
    param($List, $Severity, $Category, $Object, $Evidence, $Suggestion, $Command = '', [string]$Rule = '', $Impact = $null)
    if (-not $Rule) { $Rule = ("$Category" -replace '[^\p{L}\p{N}]+', '-').ToLowerInvariant() }
    $List.Add([pscustomobject]@{ severity = $Severity; category = $Category; object = $Object; evidence = $Evidence; suggestion = $Suggestion; command = $Command; rule = $Rule
            impact = $(if ($null -ne $Impact) { [int]$Impact } else { $null }) })
}

function Export-ReportFinding {
    <# Guarda los hallazgos en JSON (entrada de auditoría y tendencias). #>
    param($List, [Parameter(Mandatory)][string]$Path)
    ConvertTo-Json -InputObject @($List) -Depth 6 | Set-Content $Path -Encoding utf8
}

function Sort-ReportFinding {
    param($List)
    return , @($List | Sort-Object { Get-SeverityRank $_.severity }, category, object)
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
    return @('severity:Severidad', 'category:Categoría', 'object:Objeto', 'impact:VMs expuestas', 'evidence:Evidencia', 'suggestion:Sugerencia', 'command:Comando para revisar')
}

# --- Documento -----------------------------------------------------------------------------------

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
    $stamp = $Generated.ToString('yyyy-MM-dd HH:mm')
    $written = New-Object System.Collections.Generic.List[string]
    $kindOf = { param($s) if ($s.PSObject.Properties['kind']) { $s.kind } else { 'table' } }

    if ('html' -in $Format) {
        $kpiHtml = ($Kpis.GetEnumerator() | ForEach-Object { "<div class=""kpi""><span class=""v"">$(ConvertTo-HtmlText $_.Value)</span><span class=""l"">$(ConvertTo-HtmlText $_.Key)</span></div>" }) -join "`n"
        $sb = [System.Text.StringBuilder]::new()
        foreach ($s in $Sections) {
            $kind = & $kindOf $s
            if ($kind -eq 'panel') { [void]$sb.Append((ConvertTo-PanelHtml $s)); continue }
            if ($kind -eq 'analysis') {
                $note = if ($s.note) { "<p class=""note"">$(ConvertTo-HtmlText $s.note)</p>" } else { '' }
                [void]$sb.Append("<section class=""analysis""><h2>$(ConvertTo-HtmlText $s.title)</h2>$note$(ConvertTo-SafeHtml $s.text)</section>`n"); continue
            }
            $cols = @($s.columns | ForEach-Object { , ($_ -split ':', 2) })
            $note = if ($s.note) { "<p class=""note"">$(ConvertTo-HtmlText $s.note)</p>" } else { '' }
            [void]$sb.Append("<section><h2>$(ConvertTo-HtmlText $s.title) <small>($($s.rows.Count))</small></h2>$note<div class=""scroll""><table><thead><tr>")
            foreach ($c in $cols) { [void]$sb.Append('<th>').Append((ConvertTo-HtmlText $c[1])).Append('</th>') }
            [void]$sb.Append('</tr></thead><tbody>')
            if ($s.rows.Count) {
                foreach ($r in $s.rows) {
                    [void]$sb.Append('<tr>')
                    foreach ($c in $cols) {
                        $val = Get-CellValue $r $c[0]; $t = ConvertTo-HtmlText $val
                        if ($c[0] -eq 'severity') { [void]$sb.Append("<td><span class=""sev $(Get-SeverityClass "$val")"">$t</span></td>") }
                        elseif ($c[0] -eq 'command' -and $val) { [void]$sb.Append("<td><code>$t</code></td>") }
                        else { [void]$sb.Append("<td>$t</td>") }
                    }
                    [void]$sb.Append("</tr>`n")
                }
            } else { [void]$sb.Append("<tr><td colspan=""$($cols.Count)"" class=""empty"">Sin elementos.</td></tr>") }
            [void]$sb.Append("</tbody></table></div></section>`n")
        }
        $html = Expand-Template (Get-Content (Join-Path $Root 'templates/report.html') -Raw) @{
            TITLE = (ConvertTo-HtmlText $Title); ENV = (ConvertTo-HtmlText $Env.ToUpper()); GENERATED = $stamp; SOURCE = (ConvertTo-HtmlText $Source)
            KPIS = $kpiHtml; SECTIONS = $sb.ToString()
        }
        $f = Join-Path $OutDir "$BaseName.html"; Set-Content -LiteralPath $f $html -Encoding utf8; $written.Add($f)
    }
    if ('md' -in $Format) {
        $kpiMd = "| Indicador | Valor |`n|---|---:|`n" + (($Kpis.GetEnumerator() | ForEach-Object { "| $(ConvertTo-MdText $_.Key) | $(ConvertTo-MdText $_.Value) |" }) -join "`n")
        $secMd = foreach ($s in $Sections) {
            $kind = & $kindOf $s
            if ($kind -eq 'panel') { ConvertTo-PanelMd $s; continue }
            if ($kind -eq 'analysis') { "## $(ConvertTo-MdText $s.title)`n`n$(if ($s.note) { "_$(ConvertTo-MdText $s.note)_`n`n" })$(ConvertTo-SafeMd $s.text)"; continue }
            $cols = @($s.columns | ForEach-Object { , ($_ -split ':', 2) })
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add("## $(ConvertTo-MdText $s.title) ($($s.rows.Count))"); $lines.Add('')
            if ($s.note) { $lines.Add("_$(ConvertTo-MdText $s.note)_"); $lines.Add('') }
            if ($s.rows.Count) {
                $lines.Add('| ' + (($cols | ForEach-Object { ConvertTo-MdText $_[1] }) -join ' | ') + ' |')
                $lines.Add('|' + (($cols | ForEach-Object { '---' }) -join '|') + '|')
                foreach ($r in ($s.rows | Select-Object -First $MdMaxRows)) {
                    $cells = foreach ($c in $cols) { $v = Get-CellValue $r $c[0]; if ($c[0] -eq 'command' -and $v) { Format-MdCode ("$v" -replace '\|', '\|') } else { ConvertTo-MdText $v } }
                    $lines.Add('| ' + ($cells -join ' | ') + ' |')
                }
                if ($s.rows.Count -gt $MdMaxRows) { $lines.Add(''); $lines.Add("_Se muestran $MdMaxRows de $($s.rows.Count) filas; ver el HTML para la lista completa._") }
            } else { $lines.Add('Sin elementos.') }
            $lines -join "`n"
        }
        $md = Expand-Template (Get-Content (Join-Path $Root 'templates/report.md') -Raw) @{
            TITLE = (ConvertTo-MdText $Title); ENV = $Env.ToUpper(); GENERATED = $stamp; SOURCE = (ConvertTo-MdText $Source); KPIS = $kpiMd; SECTIONS = ($secMd -join "`n`n")
        }
        $f = Join-Path $OutDir "$BaseName.md"; Set-Content -LiteralPath $f $md -Encoding utf8; $written.Add($f)
    }
    return , $written.ToArray()
}

Export-ModuleMember -Function Get-SeverityRank, Get-SeverityClass, ConvertTo-MdText, ConvertTo-HtmlText, Get-CellValue,
    New-ReportTable, New-PanelCard, Get-MetricLevel, New-ReportPanel, New-ReportAnalysis, Format-TextBar, ConvertTo-PanelHtml, ConvertTo-PanelMd,
    ConvertTo-SafeHtml, ConvertTo-SafeMd, New-FindingList, Add-ReportFinding, Export-ReportFinding, Sort-ReportFinding, Get-FindingColumns,
    Write-GovcReport, Expand-Template, Format-MdCode
