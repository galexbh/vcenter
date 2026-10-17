<#
.SYNOPSIS
  Instala govc (y opcionalmente vcsim) en tools/ con verificación SHA256.

.DESCRIPTION
  Descarga desde las releases oficiales de github.com/vmware/govmomi, valida el hash contra
  checksums.txt de la misma release y extrae en tools/. Por defecto instala la versión estable
  más alta. No usa la marca "latest" de GitHub: govmomi publica parches de ramas anteriores
  (p. ej. v0.55.2 después de v0.56.0) y esa marca apunta a la publicación más reciente.
  -Version fija una versión concreta.

.EXAMPLE
  ./scripts/Install-Govc.ps1
  ./scripts/Install-Govc.ps1 -WithVcsim       # simulador para pruebas locales
  ./scripts/Install-Govc.ps1 -Version v0.56.0 # versión fijada
#>
param(
    [ValidatePattern('^(latest|v\d+\.\d+\.\d+)$')][string]$Version = 'latest',
    [ValidateSet('x86_64', 'arm64')][string]$Arch = 'x86_64',
    [switch]$WithVcsim
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null

if ($Version -eq 'latest') {
    $releases = Invoke-RestMethod 'https://api.github.com/repos/vmware/govmomi/releases?per_page=30' -Headers @{ Accept = 'application/vnd.github+json' }
    $Version = $releases |
        Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name -match '^v\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.tag_name.Substring(1) } -Descending |
        Select-Object -First 1 -ExpandProperty tag_name
    if (-not $Version) { throw 'No se encontró una versión estable de govmomi' }
    Write-Host "Versión estable más alta: $Version"
}

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
