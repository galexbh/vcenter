<#
.SYNOPSIS
  Guarda (o reemplaza) la credencial de un entorno en Windows Credential Manager.

.DESCRIPTION
  Lo ejecuta una PERSONA en su terminal (no Claude). Usa cmdkey con /pass sin valor,
  de modo que la contraseña se pide por consola y nunca queda en el historial ni en argumentos.
  Target: el 'credentialTarget' del perfil, o govc:<env> por defecto.

.EXAMPLE
  ./scripts/Set-GovcCredential.ps1 -Env lab
  ./scripts/Set-GovcCredential.ps1 -Env prod -UserName 'svc-govc-ro@vsphere.local'
#>
param(
    [Parameter(Mandatory)][string]$Env,
    [string]$UserName,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:CLAUDECODE) {
    throw 'Este script debe ejecutarlo una persona en su propia terminal, no Claude.'
}

$root = Split-Path -Parent $PSScriptRoot
$Env = $Env.ToLowerInvariant()
$target = "govc:$Env"
$cfgPath = Join-Path $root 'config/environments.json'
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $prop = $cfg.PSObject.Properties[$Env]
    if ($prop -and $prop.Value.PSObject.Properties['credentialTarget']) { $target = $prop.Value.credentialTarget }
}

if ($Remove) {
    cmdkey /delete:$target
    return
}

if (-not $UserName) { $UserName = Read-Host "Usuario para $target (ej. svc-govc@vsphere.local)" }
Write-Host "Se pedirá la contraseña de $UserName (no se mostrará)."
cmdkey /generic:$target /user:$UserName /pass
if ($LASTEXITCODE -eq 0) {
    Write-Host "Credencial guardada en '$target'. Prueba: ./scripts/govc.ps1 -Env $Env about"
}
