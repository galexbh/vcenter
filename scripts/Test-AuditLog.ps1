<#
.SYNOPSIS
  Verifica la integridad de la bitácora de auditoría (logs/audit-*.jsonl).

.DESCRIPTION
  Cada línea que escribe scripts/govc.ps1 incluye 'prev': el SHA-256 de la línea anterior
  (encadenando también entre archivos). Si alguien edita, borra o inserta una línea, la
  cadena se rompe a partir de ese punto. Este script recorre los archivos en orden y reporta
  la primera ruptura. Es evidencia de manipulación, no prevención: para eso, enviar la
  bitácora a un repositorio central (SIEM) de solo escritura.

.EXAMPLE
  ./scripts/Test-AuditLog.ps1
  ./scripts/Test-AuditLog.ps1 -Path C:\copia\logs
#>
#Requires -Version 7.5
[CmdletBinding(PositionalBinding = $false)]
param([string]$Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $Path) { $Path = Join-Path $root 'logs' }
$files = @(Get-ChildItem $Path -Filter 'audit-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $files.Count) { Write-Host "Sin bitácoras en $Path."; exit 0 }

function Get-Hash([string]$line) {
    ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($line)))).ToLowerInvariant()
}

$expected = $null      # null = aún no se ha visto una línea encadenada
$prevHash = $null
$total = 0; $legacy = 0
foreach ($f in $files) {
    $n = 0
    # ReadAllLines (no ReadLines): no deja el archivo abierto si se sale al detectar una ruptura.
    foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
        $n++; $total++
        if (-not $line.Trim()) { continue }
        try { $o = $line | ConvertFrom-Json } catch {
            Write-Host "RUPTURA  $($f.Name):$n  línea no es JSON válido" -ForegroundColor Red; exit 1
        }
        if (-not $o.PSObject.Properties['prev']) {
            # Líneas anteriores a la cadena de hashes: solo se aceptan antes de la primera encadenada.
            if ($null -ne $expected) { Write-Host "RUPTURA  $($f.Name):$n  línea sin 'prev' después de iniciada la cadena" -ForegroundColor Red; exit 1 }
            $legacy++
        } elseif ($null -eq $expected) {
            # Primera línea encadenada: su 'prev' debe ser GENESIS o el hash de la línea previa (legada).
            if ($o.prev -ne 'GENESIS' -and $o.prev -ne $prevHash) { Write-Host "RUPTURA  $($f.Name):$n  inicio de cadena inconsistente" -ForegroundColor Red; exit 1 }
        } elseif ($o.prev -ne $expected) {
            Write-Host "RUPTURA  $($f.Name):$n  el hash no coincide con la línea anterior (editada, borrada o insertada)" -ForegroundColor Red
            Write-Host "         ts: $($o.ts)  comando: $($o.command)"
            exit 1
        }
        $prevHash = Get-Hash $line
        if ($o.PSObject.Properties['prev']) { $expected = $prevHash }
    }
}
Write-Host "Bitácora íntegra: $total líneas en $($files.Count) archivo(s)$(if ($legacy) { " ($legacy previas a la cadena)" })." -ForegroundColor Green
exit 0
