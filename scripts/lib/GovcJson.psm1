# Normalización de la salida JSON de `govc object.collect`.
#  - Con -type: flujo de objetos concatenados {kind, obj{type,value}, changeSet[{name,op,val}]}.
#  - Sin -type: arreglo [{name, op, val}].
#  - Arreglos de vSphere vienen envueltos como {"_value": [...]}.

Set-StrictMode -Version Latest

function Split-JsonStream {
    <# Divide texto con varios documentos JSON concatenados en documentos individuales. #>
    param([string]$Text)
    $reader = [Newtonsoft.Json.JsonTextReader]::new([IO.StringReader]::new($Text))
    $reader.SupportMultipleContent = $true
    $reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
    while ($reader.Read()) {
        if ($reader.TokenType -in 'StartObject', 'StartArray') {
            [Newtonsoft.Json.Linq.JToken]::ReadFrom($reader).ToString([Newtonsoft.Json.Formatting]::None)
        }
    }
}

function Expand-GovcValue {
    param($Value)
    if ($null -ne $Value -and $Value -is [pscustomobject] -and $Value.PSObject.Properties['_value'] -and @($Value.PSObject.Properties).Count -eq 1) {
        return , @($Value._value | Where-Object { $null -ne $_ })
    }
    return $Value
}

function ConvertFrom-GovcCollect {
    <#
    .SYNOPSIS  Convierte la salida de object.collect en objetos planos.
    .OUTPUTS   PSCustomObject con _type, _moref y una propiedad por cada ruta solicitada.
    #>
    param([Parameter(ValueFromPipeline)][string[]]$Lines)
    begin { $buf = New-Object System.Text.StringBuilder }
    process { foreach ($l in $Lines) { [void]$buf.AppendLine($l) } }
    end {
        $text = $buf.ToString()
        if (-not $text.Trim()) { return }
        foreach ($doc in (Split-JsonStream $text)) {
            $o = $doc | ConvertFrom-Json -DateKind String
            if ($o -is [array]) {
                $row = [ordered]@{}
                foreach ($c in $o) { $row[$c.name] = Expand-GovcValue $c.val }
                [pscustomobject]$row
                continue
            }
            if (-not $o.PSObject.Properties['obj']) { $o; continue }
            $row = [ordered]@{ _type = $o.obj.type; _moref = $o.obj.value }
            if ($o.PSObject.Properties['missingSet'] -and $o.missingSet) {
                foreach ($m in @($o.missingSet)) {
                    Write-Warning "object.collect: propiedad '$($m.path)' no disponible en $($o.obj.value)"
                }
            }
            if (-not $o.PSObject.Properties['changeSet']) { [pscustomobject]$row; continue }
            foreach ($c in @($o.changeSet)) { $row[$c.name] = Expand-GovcValue $c.val }
            [pscustomobject]$row
        }
    }
}

Export-ModuleMember -Function ConvertFrom-GovcCollect, Split-JsonStream
