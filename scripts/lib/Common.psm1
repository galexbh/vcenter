# Utilidades compartidas por los scripts de reportes (New-Report, Invoke-HostCheck, Invoke-PerfCheck,
# Invoke-Audit, Compare-Report): lectura tolerante de datos de vCenter, contexto de corrida, guardado
# de datos crudos, hallazgos agrupados, cierre del reporte y CSV.
# Protegido: incluye el escape de textos de vCenter dentro de los comandos sugeridos.

Set-StrictMode -Version Latest

$script:SevRank = @{ 'Crítico' = 0; 'Advertencia' = 1; 'Info' = 2 }

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
    if ($AsArray) { return , @($o) }
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

function ConvertTo-MdText {
    <# Escapa texto de vCenter para Markdown (sin enlaces, HTML ni formato inyectado; sin saltos de línea). #>
    param($Text)
    ("$Text" -replace '[\r\n]+', ' ' -replace '([\\`*_\[\]<>|#])', '\$1')
}

# --- Hallazgos --------------------------------------------------------------------------------

function Get-SeverityRank { param([string]$Severity) $r = $script:SevRank[$Severity]; if ($null -eq $r) { 9 } else { $r } }

function Add-GroupedFinding {
    <#
    .SYNOPSIS  Un hallazgo agregado por condición (evita cientos de filas repetidas).
    .PARAMETER Items  Objetos con 'name' (y opcionalmente 'text', que se muestra en la evidencia).
    #>
    param($List, [string]$Severity, [string]$Category, $Items, [string]$Label, [string]$Suggestion, [string]$Command = '', [string]$Rule, [string]$Noun = 'VMs', [int]$Max = 15)
    $hit = @($Items)
    if (-not $hit.Count) { return }
    $show = ($hit | Select-Object -First $Max | ForEach-Object { if ($_.PSObject.Properties['text'] -and $_.text) { $_.text } else { $_.name } }) -join ', '
    $obj = if ($hit.Count -eq 1) { $hit[0].name } else { "$($hit.Count) $Noun" }
    Add-ReportFinding -List $List -Severity $Severity -Category $Category -Object $obj -Evidence "${Label}: $show$(if ($hit.Count -gt $Max) { '…' })" -Suggestion $Suggestion -Command $Command -Rule $Rule
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
    $slug = {
        param($t)
        $n = $t.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
        ($n.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    }
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
    foreach ($s in $all) {
        $cols = @($s.columns | ForEach-Object { , ($_ -split ':', 2) })
        $f = Join-Path $OutDir ("$BaseName-{0}.csv" -f (& $slug $s.title))
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add((($cols | ForEach-Object { & $q $_[1] }) -join $sep))
        foreach ($r in @($s.rows)) { $lines.Add((($cols | ForEach-Object { & $q (& $cell $r.($_[0])) }) -join $sep)) }
        [IO.File]::WriteAllLines($f, $lines, [Text.UTF8Encoding]::new($true))
        $written.Add($f)
    }
    return , $written.ToArray()
}

function Complete-Report {
    <#
    .SYNOPSIS  Cierre común: findings.json + summary.json, HTML/MD (y CSV si se pide). Devuelve el resumen de salida.
    #>
    param(
        [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$RawDir,
        [Parameter(Mandatory)][string]$BaseName, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Env,
        [Parameter(Mandatory)][datetime]$Generated, [Parameter(Mandatory)][System.Collections.IDictionary]$Kpis,
        [AllowEmptyCollection()]$Sorted = @(), [AllowEmptyCollection()][object[]]$Sections = @(),
        [string[]]$Format = @('html', 'md'), [int]$MdMaxRows = 200, [string]$Source = 'govc object.collect (solo lectura)', [string]$CsvDelimiter
    )
    Export-ReportFinding $Sorted (Join-Path $RawDir 'findings.json')
    $Kpis | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RawDir 'summary.json') -Encoding utf8
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
    ConvertFrom-CertJson, Get-SnapshotList, Format-PsLiteral, New-ReviewCommand, ConvertTo-MdText, Get-SeverityRank,
    Add-GroupedFinding, Add-CoverageByError, Add-SeverityKpis, Export-GovcCsv, Complete-Report
