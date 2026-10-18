# Utilidades compartidas por los scripts de reportes (New-Report, Invoke-HostCheck, Invoke-PerfCheck,
# Invoke-Audit, Compare-Report): lectura tolerante de datos de vCenter, contexto de corrida, guardado
# de datos crudos, cálculos compartidos (porcentajes, días al X %, clave estable, corrida anterior),
# impacto y prioridad de los hallazgos, catálogo de textos, cierre del reporte y CSV.
# Protegido: incluye el escape de textos de vCenter dentro de los comandos sugeridos.

Set-StrictMode -Version Latest


# --- Lectura tolerante ----------------------------------------------------------------

function Get-Prop {
    <# Propiedad o valor por defecto (las rutas de vSphere contienen puntos: 'summary.capacity'). #>
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
    return $Default
}

function Get-FirstProp {
    <#
    .SYNOPSIS  Primera propiedad presente entre variantes de nombre (la salida de govc/esxcli cambia entre versiones).
    .PARAMETER AllowEmpty  Acepta '' como valor; sin él, un texto vacío cuenta como ausente.
    #>
    param($Object, [string[]]$Names, $Default = $null, [switch]$AllowEmpty)
    foreach ($n in $Names) {
        $v = Get-Prop $Object $n
        if ($null -ne $v -and ($AllowEmpty -or "$v" -ne '')) { return $v }
    }
    return $Default
}

function Read-JsonFile {
    <# JSON de disco o valor por defecto si no existe. Las fechas se conservan como texto. #>
    param([Parameter(Mandatory)][string]$Path, $Default = @(), [switch]$AsArray)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $o = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
    # Un '[]' guardado se lee como $null: sin el filtro, @($null) sería un arreglo con un elemento nulo.
    if ($AsArray) { return , @($o | Where-Object { $null -ne $_ }) }
    return $o
}

function Save-RawJson {
    <#
    .SYNOPSIS  Guarda datos crudos sin truncar.
    .NOTES     -Depth 100: con -Depth 12, una cadena de snapshots de más de ~5 niveles se guardaba como
               texto "@{…}" y -FromRaw fallaba. List[object] se convierte con ToArray() (PowerShell 7.6
               no serializa @(List) de objetos anidados).
    #>
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$InputObject, [Parameter(Mandatory)][string]$Path)
    $o = if ($InputObject -is [System.Collections.Generic.List[object]]) { $InputObject.ToArray() } else { $InputObject }
    ConvertTo-Json -InputObject $o -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
}

# --- Contexto de corrida ----------------------------------------------------------------

function Assert-EnvName {
    <# Nombre de entorno seguro para rutas y comandos (también el leído de meta.json). #>
    param([string]$Name)
    if ($Name -notmatch '^[a-z0-9][a-z0-9_-]*$') { throw "Nombre de entorno inválido: '$Name' (solo minúsculas, números, '-' y '_')." }
}

function Initialize-RunContext {
    <#
    .SYNOPSIS  Resuelve el origen de una corrida: en vivo (-Env) o datos ya recolectados (-FromRaw).
    .OUTPUTS   { env, outDir, rawDir, fromRaw, generated, meta }
    #>
    param(
        [string]$Env, [string]$FromRaw, [string]$OutDir,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$MetaFile,
        [string]$Suffix = ''
    )
    if ($Env -and $FromRaw) { throw 'Indica -Env <entorno> o -FromRaw <carpeta>, no ambos.' }
    if ($FromRaw) {
        $out = (Resolve-Path -LiteralPath $FromRaw).Path
        $raw = Join-Path $out 'raw'
        $mf = Join-Path $raw $MetaFile
        if (-not (Test-Path -LiteralPath $mf)) { throw "La carpeta no corresponde a este reporte: falta raw/$MetaFile en $out" }
        $meta = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
        $e = "$($meta.env)"
        Assert-EnvName $e
        return [pscustomobject]@{ env = $e; outDir = $out; rawDir = $raw; fromRaw = $true; generated = [datetime]$meta.generated; meta = $meta }
    }
    if (-not $Env) { throw 'Indica -Env <entorno> o -FromRaw <carpeta>.' }
    $e = $Env.ToLowerInvariant()
    Assert-EnvName $e
    $gen = Get-Date
    $out = if ($OutDir) { $OutDir } else { Join-Path $Root ("reports/{0}/{1:yyyyMMdd-HHmmss}{2}" -f $e, $gen, $Suffix) }
    $raw = Join-Path $out 'raw'
    New-Item -ItemType Directory -Force -Path $raw | Out-Null
    [pscustomobject]@{ env = $e; outDir = $out; rawDir = $raw; fromRaw = $false; generated = $gen; meta = $null }
}

function Get-RunUser { [Security.Principal.WindowsIdentity]::GetCurrent().Name }

function Write-RunMeta {
    <# Metadatos de la corrida (env, fecha, usuario + campos propios del reporte). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Env, [Parameter(Mandatory)][datetime]$Generated, [System.Collections.IDictionary]$Extra = @{})
    $m = [ordered]@{ env = $Env; generated = $Generated.ToString('o'); user = (Get-RunUser) }
    foreach ($k in $Extra.Keys) { $m[$k] = $Extra[$k] }
    Save-RawJson ([pscustomobject]$m) $Path
}

# --- Datos de vCenter ------------------------------------------------------------------------

function ConvertFrom-CertJson {
    <#
    .SYNOPSIS  about.cert / host.cert.info -json: sujeto, emisor, vencimiento y estado.
    .NOTES     La salida incluye la clave pública como entero gigante: se extraen solo los campos de
               primer nivel (en minúscula). Respeta comillas escapadas y \uXXXX (p. ej. "Atlántida").
    #>
    param([string]$Text)
    $get = {
        param($k)
        $m = [regex]::Match($Text, '"' + $k + '"\s*:\s*"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { [regex]::Unescape($m.Groups[1].Value) } else { '' }
    }
    $na = & $get 'notAfter'
    if (-not $na) { return $null }
    [pscustomobject]@{ subject = & $get 'subject'; issuer = & $get 'issuer'; notAfter = $na; status = & $get 'status' }
}

function Get-SnapshotList {
    <# Aplana snapshot.rootSnapshotList (árbol) en filas { name, created, ageDays, description, moref, depth }. #>
    param($RootList, [datetime]$Now = (Get-Date))
    $out = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    foreach ($s in @($RootList)) { if ($s) { $stack.Push(@($s, 1)) } }
    while ($stack.Count) {
        $node, $depth = $stack.Pop()
        $ct = Get-Prop $node 'createTime'
        $created = if ($ct) { [datetimeoffset]::Parse("$ct", [Globalization.CultureInfo]::InvariantCulture) } else { $null }
        $ref = Get-Prop $node 'snapshot'
        $out.Add([pscustomobject]@{
                name = "$(Get-Prop $node 'name' '')"; created = $created
                ageDays = $(if ($created) { [math]::Floor(($Now - $created.LocalDateTime).TotalDays) } else { 0 })
                description = "$(Get-Prop $node 'description' '')"; moref = "$(Get-Prop $ref 'value' '')"; depth = $depth
            })
        foreach ($c in @(Get-Prop $node 'childSnapshotList' @())) { if ($c) { $stack.Push(@($c, ($depth + 1))) } }
    }
    return , $out.ToArray()
}

# --- Comandos sugeridos y texto ----------------------------------------------------------------

function Format-PsLiteral {
    <# Texto como literal de PowerShell entre comillas simples (escapa ' y las comillas tipográficas). #>
    param([AllowEmptyString()][string]$Text)
    "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'"
}

function New-ReviewCommand {
    <#
    .SYNOPSIS  Comando de revisión con el wrapper. Cada argumento que no sea un token simple se cita.
    .NOTES     Los nombres vienen de vCenter (datos): nunca se interpolan sin escapar. Un nombre como
               O'Brien o con ; $ ` no rompe ni inyecta nada al pegar el comando.
    #>
    param([Parameter(Mandatory)][string]$Env, [Parameter(Mandatory)][string[]]$Arguments)
    $parts = foreach ($a in $Arguments) { if ($a -match '^[\w./:=*,@+-]+$') { $a } else { Format-PsLiteral $a } }
    "./scripts/govc.ps1 -Env $Env " + ($parts -join ' ')
}

# --- Cálculos compartidos ------------------------------------------------------------------------

function Get-Percent {
    <# 100·a/b redondeado a un decimal; $null si b es 0. #>
    param($Part, $Total)
    if ($Total) { [math]::Round(100 * [double]$Part / [double]$Total, 1) } else { $null }
}

function Get-Sum {
    <#
    .SYNOPSIS  Suma de una propiedad (o de los valores) de una colección; 0 si está vacía.
    .NOTES     (@() | Measure-Object x -Sum) devuelve $null y .Sum falla en StrictMode.
    #>
    param($Items, [string]$Property)
    $t = 0.0
    foreach ($i in $Items) { if ($null -ne $i) { $t += [double]$(if ($Property) { Get-Prop $i $Property 0 } else { $i }) } }
    $t
}

function Format-Percent { param($Value) if ($null -eq $Value) { '—' } else { '{0:0.#} %' -f [double]$Value } }

function Get-DaysToPct {
    <#
    .SYNOPSIS  Días hasta que un datastore llega al Pct % de uso al ritmo indicado.
    .OUTPUTS   $null sin ritmo conocido; +∞ si no crece; 0 si ya lo superó.
    #>
    param([double]$CapGB, [double]$UsedGB, $RatePerDay, [double]$Pct = 90)
    if ($null -eq $RatePerDay) { return $null }
    if ([double]$RatePerDay -le 0) { return [double]::PositiveInfinity }
    [math]::Max([double]0, [math]::Floor(($Pct / 100 * $CapGB - $UsedGB) / [double]$RatePerDay))
}

function Get-FindingKey {
    <# Clave estable de un hallazgo entre corridas: 12 hex del SHA-256 de 'regla|objeto' (o la ya guardada). #>
    param($Finding)
    $k = Get-Prop $Finding 'key'
    if ($k) { return "$k" }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$($Finding.rule)|$($Finding.object)"))).Substring(0, 12).ToLowerInvariant()
}

function Find-PreviousRun {
    <#
    .SYNOPSIS  Corrida anterior del mismo entorno entre las carpetas hermanas de la salida (reports/<env>/).
    .PARAMETER MetaFile  Archivo de raw/ con env y generated (meta.json, audit.json…).
    .PARAMETER RawFile   Archivo de raw/ que debe existir para que la corrida sirva.
    .PARAMETER SubDirs   Subcarpetas donde buscar raw/ dentro de cada corrida ('' = la propia; 'inventario' = la de una auditoría).
    .OUTPUTS   { at, rawDir } de la más reciente anterior a Before − MinGapHours, o $null.
    .NOTES     Dentro de una auditoría (la carpeta padre tiene raw/meta-audit.json) busca entre las auditorías.
    #>
    param([Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$Env, [Parameter(Mandatory)][datetime]$Before,
        [string]$MetaFile = 'meta.json', [Parameter(Mandatory)][string]$RawFile, [string[]]$SubDirs = @(''), [double]$MinGapHours = 0)
    $here = (Resolve-Path -LiteralPath $OutDir).Path
    $dir = Split-Path $here -Parent
    if (Test-Path -LiteralPath (Join-Path $dir 'raw/meta-audit.json')) { $dir = Split-Path $dir -Parent }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $null }
    $limit = $Before.AddHours(-$MinGapHours)
    $best = $null
    foreach ($d in Get-ChildItem -LiteralPath $dir -Directory) {
        foreach ($sub in $SubDirs) {
            $base = if ($sub) { Join-Path $d.FullName $sub } else { $d.FullName }
            if ($base -eq $here) { continue }
            $raw = Join-Path $base 'raw'
            $mf = Join-Path $raw $MetaFile
            if (-not (Test-Path -LiteralPath $mf) -or -not (Test-Path -LiteralPath (Join-Path $raw $RawFile))) { continue }
            $m = $null; try { $m = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json -DateKind String } catch { continue }
            if ("$(Get-Prop $m 'env' '')" -ne $Env -or -not (Get-Prop $m 'generated')) { continue }
            $at = [datetime]$m.generated
            if ($at -lt $limit -and (-not $best -or $at -gt $best.at)) { $best = [pscustomobject]@{ at = $at; rawDir = $raw } }
        }
    }
    $best
}

function Set-FindingImpact {
    <#
    .SYNOPSIS  Completa las VMs expuestas de los hallazgos sin dato a partir del objeto ('nombre' o 'nombre / detalle').
    .PARAMETER Map  nombre de entidad (host, clúster, datastore, VM) → VMs encendidas expuestas.
    #>
    param($Findings, [System.Collections.IDictionary]$Map, [string[]]$SkipRules = @())
    # Sin @(): PowerShell 7.6 no envuelve List[object] de objetos ("Argument types do not match").
    foreach ($f in $Findings) {
        if ($null -ne (Get-Prop $f 'impact') -or $f.category -eq 'Cobertura' -or $f.rule -in $SkipRules) { continue }
        $k = ("$($f.object)" -split ' / ', 2)[0]
        if ($Map.Contains($k)) { $f | Add-Member -Force impact ([int]$Map[$k]) }
    }
}

function Get-FindingScore {
    <# Prioridad de un hallazgo: peso de la severidad × (1 + ln(1 + VMs expuestas)). Info y Cobertura no puntúan. #>
    param($Finding)
    $w = @{ 'Crítico' = 100; 'Advertencia' = 30 }["$($Finding.severity)"]
    if (-not $w -or $Finding.category -eq 'Cobertura') { return 0 }
    $vm = [double](Get-Prop $Finding 'impact' 0)
    [math]::Round($w * (1 + [math]::Log(1 + $vm)), 2)
}

function Get-ReportPriority {
    <#
    .SYNOPSIS  Acciones prioritarias: críticos y advertencias agrupados por regla, ordenados por prioridad.
    .OUTPUTS   Filas { n, severity, action, why, impact, command } (columnas de Get-PriorityColumns).
    #>
    param($Findings, [int]$Max = 5)
    $groups = foreach ($g in @($Findings | Where-Object { (Get-FindingScore $_) -gt 0 } | Group-Object rule, severity)) {
        $items = @($g.Group | Sort-Object { [double](Get-Prop $_ 'impact' 0) } -Descending)
        $worst = $items[0]
        $objs = @($items | Select-Object -First 3 | ForEach-Object { "$($_.object)" }) -join ', '
        $impact = Get-Sum $items 'impact'
        [pscustomobject]@{
            score = Get-FindingScore ([pscustomobject]@{ severity = $worst.severity; category = $worst.category; impact = $impact })
            severity = $worst.severity; action = $worst.suggestion; impact = $(if ($impact) { [int]$impact } else { $null }); command = $worst.command
            why = "$($worst.category): $objs$(if ($items.Count -gt 3) { " y $($items.Count - 3) más" }) — $($worst.evidence)"
        }
    }
    $n = 0
    @($groups | Where-Object { $_ } | Sort-Object score -Descending | Select-Object -First $Max | ForEach-Object { $n++; $_ | Add-Member -Force n $n; $_ })
}

function Get-PriorityColumns { @('n:#', 'severity:Severidad', 'action:Acción', 'why:Motivo', 'impact:VMs expuestas', 'command:Comando para revisar') }

function Get-FindingFingerprint {
    <# Huella de un conjunto de hallazgos: 12 hex del SHA-256 de 'regla|objeto|severidad' ordenados (vigencia del análisis). #>
    param($Findings)
    $lines = @($Findings | Where-Object { $_ } | ForEach-Object { "$($_.rule)|$($_.object)|$($_.severity)" } | Sort-Object -CaseSensitive)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($lines -join "`n"))).Substring(0, 12).ToLowerInvariant()
}

function Get-ReportAnalysis {
    <#
    .SYNOPSIS  Análisis redactado por Claude (raw/analysis.md) como sección del reporte, o $null si no existe.
    .PARAMETER Fingerprint  Huella actual de los hallazgos; se compara con la línea '<!-- huella: … -->' del análisis.
    .NOTES     El texto se trata como datos: Render lo escapa y solo admite un subconjunto de Markdown.
    #>
    param([Parameter(Mandatory)][string]$RawDir, [string]$Fingerprint)
    $f = Join-Path $RawDir 'analysis.md'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $at = (Get-Item -LiteralPath $f).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    $text = Get-Content -LiteralPath $f -Raw
    $status = 'unverified'
    $m = [regex]::Match("$text", '^\s*<!--\s*huella:\s*([0-9a-fA-F]+)\s*-->[ \t]*\r?\n?')
    if ($m.Success) {
        $text = $text.Substring($m.Length)
        $status = if ($Fingerprint -and $m.Groups[1].Value.ToLowerInvariant() -eq $Fingerprint) { 'ok' } else { 'stale' }
    }
    New-ReportAnalysis -Title 'Análisis de Claude (IA)' -Text $text -Status $status `
        -Note "Redactado por Claude el $at a partir de los datos de esta corrida; revisar antes de usarlo como evidencia."
}

# --- Catálogo de textos (templates/findings.psd1) ---------------------------------------------

$script:CatalogPath = Join-Path $PSScriptRoot '../../templates/findings.psd1'
$script:Catalog = $null

function Get-FindingCatalog {
    <#
    .SYNOPSIS  Catálogo de sugerencias, riesgos y notas; se lee una vez por proceso.
    .NOTES     Import-PowerShellDataFile usa el lenguaje restringido: el archivo no puede ejecutar código.
    #>
    if ($null -eq $script:Catalog) {
        $script:Catalog = if (Test-Path -LiteralPath $script:CatalogPath) { Import-PowerShellDataFile -LiteralPath $script:CatalogPath } else { @{} }
        foreach ($k in 'Rules', 'Categories', 'Notes') { if (-not $script:Catalog.ContainsKey($k)) { $script:Catalog[$k] = @{} } }
    }
    $script:Catalog
}

function Expand-CatalogText {
    <# Reemplaza {nombre} como texto literal (nunca se evalúa). #>
    param([string]$Text, [System.Collections.IDictionary]$Vars)
    if (-not $Text -or -not $Vars) { return "$Text" }
    foreach ($k in $Vars.Keys) { $Text = $Text.Replace("{$k}", "$($Vars[$k])") }
    $Text
}

function Get-FindingText {
    <#
    .SYNOPSIS  Sugerencia de una regla del catálogo; por severidad si la entrada la distingue.
    .OUTPUTS   Texto, o '' si la regla no tiene entrada (Test-Reports lo detecta; el reporte no se cae).
    #>
    param([Parameter(Mandatory, Position = 0)][string]$Rule, [Parameter(Position = 1)][string]$Severity, [System.Collections.IDictionary]$Vars)
    $e = (Get-FindingCatalog).Rules[$Rule]
    if (-not $e) { return '' }
    $s = $e['Suggestion']
    if ($s -is [System.Collections.IDictionary]) { $s = $s[$Severity] }
    Expand-CatalogText "$s" $Vars
}

function Get-CategoryText {
    <# Riesgo o referencia de una categoría (informe de auditoría). #>
    param([Parameter(Mandatory, Position = 0)][string]$Category, [Parameter(Position = 1)][ValidateSet('Risk', 'Reference')][string]$Field = 'Risk')
    $e = (Get-FindingCatalog).Categories[$Category]
    if (-not $e) { return '' }
    "$($e[$Field])"
}

function Get-NoteText {
    <# Nota común del catálogo (umbrales, alcance de los comandos…). #>
    param([Parameter(Mandatory, Position = 0)][string]$Name, [System.Collections.IDictionary]$Vars)
    Expand-CatalogText "$((Get-FindingCatalog).Notes[$Name])" $Vars
}

function Add-GroupedFinding {
    <#
    .SYNOPSIS  Un hallazgo agregado por condición (evita cientos de filas repetidas).
    .PARAMETER Items  Objetos con 'name' (y opcionalmente 'text', que se muestra en la evidencia).
    .PARAMETER Impact VMs expuestas; por defecto, la cantidad de elementos (cada uno es una VM).
    #>
    param($List, [string]$Severity, [string]$Category, $Items, [string]$Label, [string]$Suggestion, [string]$Command = '', [string]$Rule, [string]$Noun = 'VMs', [int]$Max = 15, $Impact = -1)
    $hit = @($Items)
    if (-not $hit.Count) { return }
    $show = ($hit | Select-Object -First $Max | ForEach-Object { if ($_.PSObject.Properties['text'] -and $_.text) { $_.text } else { $_.name } }) -join ', '
    $obj = if ($hit.Count -eq 1) { $hit[0].name } else { "$($hit.Count) $Noun" }
    Add-ReportFinding -List $List -Severity $Severity -Category $Category -Object $obj -Evidence "${Label}: $show$(if ($hit.Count -gt $Max) { '…' })" -Suggestion $Suggestion -Command $Command -Rule $Rule `
        -Impact $(if ($Impact -is [int] -and $Impact -eq -1) { $hit.Count } else { $Impact })
}

function Add-CoverageByError {
    <# Cobertura agrupada: un hallazgo por causa de error, con la lista de entidades afectadas. #>
    param($List, [string]$Rule, $Entries, [string]$What, [string]$Suggestion, [string]$NameProperty = 'host', [string]$Noun = 'hosts')
    foreach ($g in @(@($Entries) | Where-Object { $_ } | Group-Object { ("$($_.error)" -replace '<.*$', '').Trim() })) {
        $names = @($g.Group | ForEach-Object { "$($_.$NameProperty)" } | Sort-Object)
        $obj = if ($names.Count -eq 1) { $names[0] } else { "$($names.Count) $Noun" }
        Add-ReportFinding -List $List -Severity 'Info' -Category 'Cobertura' -Object $obj -Evidence "$What no disponible en $($names -join ', '): $($g.Name)" -Suggestion $Suggestion -Rule $Rule
    }
}

function Add-SeverityKpis {
    <# Agrega Críticos / Advertencias (y opcionalmente Sin cobertura) a los indicadores. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Kpis, $Sorted, [switch]$Coverage)
    $Kpis['Críticos'] = @($Sorted | Where-Object severity -eq 'Crítico').Count
    $Kpis['Advertencias'] = @($Sorted | Where-Object severity -eq 'Advertencia').Count
    if ($Coverage) { $Kpis['Sin cobertura'] = @($Sorted | Where-Object category -eq 'Cobertura').Count }
}

# --- Cierre del reporte ------------------------------------------------------------------------

function Export-GovcCsv {
    <#
    .SYNOPSIS  Un CSV por tabla (encabezados en español), UTF-8 con BOM para que Excel respete los acentos.
    .NOTES     Los textos vienen de vCenter: se neutraliza la inyección de fórmulas al abrir en Excel
               (= + - @ tabulador y retorno de carro al inicio) y se quitan los saltos de línea.
    #>
    param(
        [Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Kpis, [AllowEmptyCollection()][object[]]$Sections = @(),
        [string]$Delimiter
    )
    $sep = if ($Delimiter) { $Delimiter } else { (Get-Culture).TextInfo.ListSeparator }
    $culture = Get-Culture
    $cell = {
        param($v)
        if ($null -eq $v) { return '' }
        if ($v -is [double] -or $v -is [decimal] -or $v -is [single]) { return $v.ToString($culture) }
        if ($v -is [int] -or $v -is [long]) { return "$v" }
        if ($v -is [bool]) { return $(if ($v) { 'Sí' } else { 'No' }) }
        if ($v -is [array]) { $v = ($v | ForEach-Object { "$_" }) -join ', ' }
        $t = "$v" -replace '[\r\n]+', ' '
        if ($t -match '^[=+\-@\t\r]') { $t = "'" + $t }
        return $t
    }
    $q = { param($x) '"' + ("$x" -replace '"', '""') + '"' }
    $all = @(@{ title = 'Resumen'; columns = @('k:Indicador', 'v:Valor'); rows = @($Kpis.GetEnumerator() | ForEach-Object { [pscustomobject]@{ k = $_.Key; v = $_.Value } }) }) + @($Sections)
    $written = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($all | Where-Object { @($_.columns).Count })) {
        $cols = @($s.columns | ForEach-Object { , ($_ -split ':', 2) })
        $f = Join-Path $OutDir ("$BaseName-{0}.csv" -f (Get-Slug $s.title))
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add((($cols | ForEach-Object { & $q $_[1] }) -join $sep))
        foreach ($r in @($s.rows)) { $lines.Add((($cols | ForEach-Object { & $q (& $cell (Get-CellValue $r $_[0])) }) -join $sep)) }
        [IO.File]::WriteAllLines($f, $lines, [Text.UTF8Encoding]::new($true))
        $written.Add($f)
    }
    return , $written.ToArray()
}

function Complete-Report {
    <#
    .SYNOPSIS  Cierre común: findings.json + summary.json + metrics.json, HTML/MD (y CSV si se pide). Devuelve el resumen de salida.
    .NOTES     Antepone las secciones «Prioridades» (siempre) y «Análisis de Claude» (si existe raw/analysis.md).
    #>
    param(
        [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$RawDir,
        [Parameter(Mandatory)][string]$BaseName, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Env,
        [Parameter(Mandatory)][datetime]$Generated, [Parameter(Mandatory)][System.Collections.IDictionary]$Kpis,
        [AllowEmptyCollection()]$Sorted = @(), [AllowEmptyCollection()][object[]]$Sections = @(),
        [string[]]$Format = @('html', 'md'), [int]$MdMaxRows = 200, [string]$Source = 'govc object.collect (solo lectura)', [string]$CsvDelimiter
    )
    Export-ReportFinding $Sorted (Join-Path $RawDir 'findings.json')
    # Huella de los hallazgos: Claude la registra en analysis.md y el reporte avisa si el análisis quedó viejo.
    $fingerprint = Get-FindingFingerprint $Sorted
    Set-Content -LiteralPath (Join-Path $RawDir 'fingerprint.txt') $fingerprint -Encoding utf8 -NoNewline
    $Kpis | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RawDir 'summary.json') -Encoding utf8
    # Métricas de los paneles con su valor numérico: las lee Claude, la auditoría y la evolución sin abrir el HTML.
    $metrics = @(foreach ($s in $Sections) { if ($s.PSObject.Properties['kind'] -and $s.kind -eq 'panel') {
                foreach ($c in $s.cards) { [pscustomobject]@{ panel = $s.title; key = $c.key; group = $c.group; label = $c.label; value = $c.value; number = $c.number; pct = $c.pct; level = $c.level; note = $c.note } } } })
    ConvertTo-Json -InputObject $metrics -Depth 4 | Set-Content -LiteralPath (Join-Path $RawDir 'metrics.json') -Encoding utf8
    $Sections = @(
        New-ReportTable 'Prioridades' (Get-PriorityColumns) (Get-ReportPriority $Sorted) 'Críticos y advertencias agrupados por regla, ordenados por severidad y VMs expuestas.'
        Get-ReportAnalysis -RawDir $RawDir -Fingerprint $fingerprint
    ) + @($Sections) | Where-Object { $_ }
    $written = New-Object System.Collections.Generic.List[string]
    $doc = @($Format | Where-Object { $_ -ne 'csv' })
    if ($doc.Count) {
        foreach ($f in (Write-GovcReport -Root $Root -OutDir $OutDir -BaseName $BaseName -Title $Title -Env $Env -Generated $Generated `
                    -Kpis $Kpis -Sections $Sections -Format $doc -MdMaxRows $MdMaxRows -Source $Source)) { $written.Add($f) }
    }
    if ('csv' -in $Format) { foreach ($f in (Export-GovcCsv -OutDir $OutDir -BaseName $BaseName -Kpis $Kpis -Sections $Sections -Delimiter $CsvDelimiter)) { $written.Add($f) } }
    [pscustomobject]@{ Carpeta = $OutDir; Archivos = $written.ToArray(); Criticos = $Kpis['Críticos']; Advertencias = $Kpis['Advertencias'] }
}

Export-ModuleMember -Function Get-Prop, Get-FirstProp, Read-JsonFile, Save-RawJson, Assert-EnvName, Initialize-RunContext, Get-RunUser, Write-RunMeta,
    ConvertFrom-CertJson, Get-SnapshotList, Format-PsLiteral, New-ReviewCommand,
    Get-Percent, Get-Sum, Format-Percent, Get-DaysToPct, Get-FindingKey, Find-PreviousRun, Set-FindingImpact, Get-FindingScore, Get-ReportPriority,
    Get-PriorityColumns, Get-FindingFingerprint, Get-ReportAnalysis, Get-FindingCatalog, Get-FindingText, Get-CategoryText, Get-NoteText, Add-GroupedFinding, Add-CoverageByError, Add-SeverityKpis, Export-GovcCsv, Complete-Report
