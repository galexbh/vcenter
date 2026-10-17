<#
.SYNOPSIS
  Instala govc (y opcionalmente vcsim) en tools/ con versión fijada y verificación SHA256.

.DESCRIPTION
  Descarga desde las releases oficiales de github.com/vmware/govmomi, valida el hash contra
  checksums.txt de la misma release y extrae en tools/. Para actualizar, cambia $Version
  tras revisar el changelog (preferir releases con al menos 2 semanas de publicadas).

.EXAMPLE
  ./scripts/Install-Govc.ps1
  ./scripts/Install-Govc.ps1 -WithVcsim       # simulador para pruebas locales
#>
param(
    [string]$Version = 'v0.56.0',
    [ValidateSet('x86_64', 'arm64')][string]$Arch = 'x86_64',
    [switch]$WithVcsim
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null

$base = "https://github.com/vmware/govmomi/releases/download/$Version"
$tmp = Join-Path ([IO.Path]::GetTempPath()) "govmomi-$Version-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    $sumsFile = Join-Path $tmp 'checksums.txt'
    Invoke-WebRequest "$base/checksums.txt" -OutFile $sumsFile -UseBasicParsing
    $sums = @{}
    foreach ($line in Get-Content $sumsFile) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2) { $sums[$parts[1].Trim().TrimStart('*')] = $parts[0].ToLowerInvariant() }
    }

    $names = @('govc') + $(if ($WithVcsim) { 'vcsim' } else { @() })
    foreach ($n in $names) {
        $zip = "${n}_Windows_$Arch.zip"
        $zipPath = Join-Path $tmp $zip
        Write-Host "Descargando $zip ($Version)..."
        Invoke-WebRequest "$base/$zip" -OutFile $zipPath -UseBasicParsing

        $expected = $sums[$zip]
        if (-not $expected) { throw "No hay checksum para $zip en checksums.txt" }
        $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "SHA256 no coincide para $zip`n esperado: $expected`n obtenido: $actual" }
        Write-Host "  SHA256 OK"

        $out = Join-Path $tmp $n
        Expand-Archive $zipPath -DestinationPath $out -Force
        Copy-Item (Join-Path $out "$n.exe") (Join-Path $tools "$n.exe") -Force
    }

    & (Join-Path $tools 'govc.exe') version
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
