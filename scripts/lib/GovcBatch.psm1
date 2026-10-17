# Ejecución de varias lecturas govc con una sola sesión (modo -Batch de scripts/govc.ps1).
# El wrapper valida que todo el lote sea de lectura, abre una sesión efímera, la cierra y la borra.

Set-StrictMode -Version Latest

function Invoke-GovcBatch {
    <#
    .SYNOPSIS  Ejecuta un lote de comandos de lectura con un único login.
    .PARAMETER Commands  Arreglo de comandos; cada comando es un arreglo de argumentos de govc.
    .OUTPUTS   Un objeto por comando, en el mismo orden: { i, exitCode, stdout, stderr }.
    #>
    param(
        [Parameter(Mandatory)][string]$Env,
        [Parameter(Mandatory)][object[]]$Commands
    )
    $wrapper = Join-Path (Split-Path -Parent $PSScriptRoot) 'govc.ps1'
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Commands) { $list.Add([string[]]@($c | ForEach-Object { "$_" })) }
    $file = Join-Path ([IO.Path]::GetTempPath()) ("govc-batch-{0}.json" -f [guid]::NewGuid().ToString('N'))
    ConvertTo-Json -InputObject $list.ToArray() -Depth 4 | Set-Content -LiteralPath $file -Encoding utf8
    try {
        $out = & $wrapper -Env $Env -Batch $file
        $code = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) { throw "El lote fue rechazado o falló (exit $code)." }
    $res = @((@($out) -join "`n") | ConvertFrom-Json -DateKind String)
    if ($res.Count -ne $list.Count) { throw "El lote devolvió $($res.Count) resultados para $($list.Count) comandos." }
    return , $res
}

function Get-GovcBatchError {
    <# Mensaje de error legible de un resultado de lote (incluye fallas SOAP en JSON). #>
    param($Result)
    $text = "$($Result.stderr) $($Result.stdout)"
    $fault = [regex]::Match($text, '"String"\s*:\s*"([^"]+)"')
    if ($fault.Success) { return $fault.Groups[1].Value }
    return (($Result.stderr -replace '(?s)^.*?govc(\.exe)?:\s*', '') -replace '<.*$', '').Trim()
}

Export-ModuleMember -Function Invoke-GovcBatch, Get-GovcBatchError
