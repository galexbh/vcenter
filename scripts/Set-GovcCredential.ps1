<#
.SYNOPSIS
  Guarda, reemplaza, lista o elimina la credencial de un entorno en Windows Credential Manager.

.DESCRIPTION
  Lo ejecuta una PERSONA en su terminal (no Claude). Usa cmdkey con /pass sin valor,
  de modo que la contraseña se pide por consola y nunca queda en el historial ni en argumentos.
  Target: el 'credentialTarget' del perfil, o govc:<env> por defecto.
  -List muestra, por perfil, el destino, si está registrada y el usuario (nunca la contraseña),
  más las entradas govc:* que no corresponden a ningún perfil.

.EXAMPLE
  ./scripts/Set-GovcCredential.ps1 -Env lab
  ./scripts/Set-GovcCredential.ps1 -Env prod -UserName 'svc-govc-ro@vsphere.local'
  ./scripts/Set-GovcCredential.ps1 -List
  ./scripts/Set-GovcCredential.ps1 -Env lab -Remove
#>
#Requires -Version 7.5
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Set')]
    [Parameter(Mandatory, ParameterSetName = 'Remove')][string]$Env,
    [Parameter(ParameterSetName = 'Set')][string]$UserName,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Remove,
    [Parameter(Mandatory, ParameterSetName = 'List')][switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:CLAUDECODE) {
    throw 'Este script debe ejecutarlo una persona en su propia terminal, no Claude.'
}

$root = Split-Path -Parent $PSScriptRoot
$cfgPath = Join-Path $root 'config/environments.json'
$cfg = if (Test-Path $cfgPath) { Get-Content $cfgPath -Raw | ConvertFrom-Json } else { $null }

function Get-Target([string]$name) {
    $prop = if ($cfg) { $cfg.PSObject.Properties[$name] } else { $null }
    if ($prop -and $prop.Value.PSObject.Properties['credentialTarget']) { return $prop.Value.credentialTarget }
    return "govc:$name"
}

if ($List) {
    # cmdkey imprime una línea "...target=<destino>" por entrada en cualquier idioma de Windows.
    $targets = [ordered]@{}
    if ($cfg) { foreach ($p in $cfg.PSObject.Properties) { $targets[(Get-Target $p.Name)] = $p.Name } }
    foreach ($m in [regex]::Matches((cmdkey /list:govc:* | Out-String), 'target=(\S+)')) {
        if (-not $targets.Contains($m.Groups[1].Value)) { $targets[$m.Groups[1].Value] = '(sin perfil)' }
    }
    if (-not $targets.Count) { Write-Host 'No hay perfiles en config/environments.json ni credenciales govc:* registradas.'; return }
    @(foreach ($t in $targets.Keys) {
            $out = cmdkey "/list:$t" | Out-String
            [pscustomobject]@{
                Entorno    = $targets[$t]
                Destino    = $t
                Registrada = $(if ($out -match 'target=') { 'Sí' } else { 'No' })
                Usuario    = [regex]::Match($out, '(?m)^\s*(Usuario|User)\s*:\s*(.+?)\s*$').Groups[2].Value
            }
        }) | Format-Table -AutoSize
    return
}

$Env = $Env.ToLowerInvariant()
$target = Get-Target $Env

if ($Remove) {
    cmdkey /delete:$target
    if ($LASTEXITCODE -ne 0) { throw "No se pudo eliminar la credencial '$target' (¿no existe?)." }
    return
}

if (-not $UserName) { $UserName = Read-Host "Usuario para $target (ej. svc-govc@vsphere.local)" }
Write-Host "Se pedirá la contraseña de $UserName (no se mostrará)."
cmdkey /generic:$target /user:$UserName /pass
if ($LASTEXITCODE -eq 0) {
    Write-Host "Credencial guardada en '$target'. Prueba: ./scripts/govc.ps1 -Env $Env about"
}
