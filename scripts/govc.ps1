<#
.SYNOPSIS
  Wrapper seguro de govc. Único punto de entrada permitido para operar vCenter.

.DESCRIPTION
  En cada invocación:
    1. Carga el perfil del entorno desde config/environments.json.
    2. Clasifica la operación (read / write / destructive / secret) y aplica el modo del entorno.
    3. Lee la credencial desde Windows Credential Manager (target govc:<env> por defecto).
    4. Ejecuta govc con GOVC_* solo durante la ejecución y las limpia al terminar.
    5. Registra auditoría en logs/audit-<fecha>.jsonl (sin secretos).

.EXAMPLE
  ./scripts/govc.ps1 -Env lab about
  ./scripts/govc.ps1 -Env prod find / -type m -runtime.powerState poweredOff
  ./scripts/govc.ps1 -Env prod object.collect -json -type m / name runtime.powerState

.NOTES
  No usa bloque param() a propósito: los flags de govc (-json, -e, -vm…) no deben
  ser interpretados por PowerShell. El primer par de argumentos debe ser -Env <nombre>.
  Valores con comas o espacios deben ir entre comillas.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Classify.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/CredMan.psm1') -Force

function Fail([string]$msg, [int]$code = 2) {
    [Console]::Error.WriteLine("govc.ps1: $msg")
    exit $code
}

# --- 1. Argumentos -----------------------------------------------------------
$all = @($args | ForEach-Object { "$_" })
if ($all.Count -ge 1 -and $all[0] -match '^-Env:(.+)$') {
    $envName = $Matches[1]; $rest = @($all | Select-Object -Skip 1)
} elseif ($all.Count -ge 2 -and $all[0] -ieq '-Env') {
    $envName = $all[1]; $rest = @($all | Select-Object -Skip 2)
} else {
    Fail 'Uso: ./scripts/govc.ps1 -Env <prod|dr|lab|...> <subcomando govc> [args]'
}
$envName = $envName.ToLowerInvariant()

# PowerShell parte los flags con punto sin comillas (-runtime.powerState → '-runtime', '.powerState').
$merged = New-Object System.Collections.Generic.List[string]
foreach ($a in $rest) {
    if ($merged.Count -and $a -match '^\.[A-Za-z]' -and $merged[$merged.Count - 1] -match '^-[A-Za-z][\w.-]*$') {
        $merged[$merged.Count - 1] += $a
    } else { $merged.Add($a) }
}
$rest = $merged.ToArray()

# Modo lote: -Batch <archivo.json> con un arreglo de comandos (cada uno, arreglo de argumentos).
# Solo lectura: se ejecutan con una sesión efímera (un login), que se cierra y borra al terminar.
$batch = $null
if ($rest.Count -ge 1 -and $rest[0] -ieq '-Batch') {
    if ($rest.Count -lt 2 -or -not (Test-Path -LiteralPath $rest[1])) { Fail 'Uso: ./scripts/govc.ps1 -Env <entorno> -Batch <archivo.json>' }
    try { $parsed = Get-Content -LiteralPath $rest[1] -Raw | ConvertFrom-Json -NoEnumerate } catch { Fail "Lote inválido: $($_.Exception.Message)" }
    # Cada comando debe ser un arreglo plano de textos; cualquier anidación se rechaza (no se "aplana").
    foreach ($c in @($parsed)) {
        if ($c -isnot [array] -or @($c | Where-Object { $_ -isnot [string] }).Count) {
            Fail 'Lote inválido: cada comando debe ser un arreglo de textos, p. ej. [["about"],["ls","/"]].'
        }
    }
    $batch = @(foreach ($c in @($parsed)) { , [string[]]@($c) })
    if (-not $batch.Count -or @($batch | Where-Object { $_.Count -eq 0 }).Count) { Fail 'Lote vacío o con comandos vacíos.' }
    $batchId = [guid]::NewGuid().ToString('N').Substring(0, 12)
}

# --- 2. Perfil ---------------------------------------------------------------
$cfgPath = Join-Path $root 'config/environments.json'
if (-not (Test-Path $cfgPath)) {
    Fail "No existe config/environments.json. Copia config/environments.example.json y ajústalo."
}
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$profile_ = $cfg.PSObject.Properties[$envName]
if (-not $profile_) {
    Fail "Entorno '$envName' no definido. Disponibles: $(($cfg.PSObject.Properties.Name) -join ', ')"
}
$p = $profile_.Value
$mode = if ($p.PSObject.Properties['mode']) { "$($p.mode)".ToLowerInvariant() } else { 'readonly' }
if ($mode -notin 'readonly', 'confirm', 'lab') { Fail "Modo inválido '$mode' en '$envName' (readonly|confirm|lab)." }

function Opt([string]$name, $default = $null) {
    if ($p.PSObject.Properties[$name] -and "$($p.$name)" -ne '') { return $p.$name } else { return $default }
}

# --- 3. Clasificación y política --------------------------------------------
$byClaude = [bool]$env:CLAUDECODE
$nonInteractive = $byClaude -or [Console]::IsInputRedirected
if ($batch) {
    # Todo el lote debe ser lectura; se valida antes de leer la credencial.
    $bad = @(for ($i = 0; $i -lt $batch.Count; $i++) {
            $c = Get-GovcOpClass $batch[$i]
            if ($c -ne 'read') { [pscustomobject]@{ i = $i; class = $c; cmd = $batch[$i] } }
        })
    $class = if ($bad.Count) { $bad[0].class } else { 'read' }
    $sub = 'batch'
} else {
    $class = Get-GovcOpClass $rest
    $sub = Get-GovcSubcommand $rest
}

function Get-LastAuditHash([string]$logDir) {
    # Encadena con la última línea registrada (del archivo de hoy o del más reciente).
    $last = Get-ChildItem $logDir -Filter 'audit-*.jsonl' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $last) { return 'GENESIS' }
    $line = Get-Content $last.FullName -Tail 1 -Encoding utf8
    if (-not $line) { return 'GENESIS' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($line)
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Write-Audit([string]$result, [int]$exitCode, [string[]]$cmdArgs = $rest, [string]$cls = $class, [string]$batchRef = '') {
    # Exclusión mutua entre procesos: leer el hash previo y agregar la línea es una operación atómica;
    # sin ella, dos wrappers simultáneos bifurcarían la cadena (falsa alarma en Test-AuditLog).
    $logDir = Join-Path $root 'logs'
    $mtxName = 'Local\govc-audit-' + ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($logDir.ToLowerInvariant())))).Substring(0, 16)
    $mtx = [System.Threading.Mutex]::new($false, $mtxName)
    $locked = $false
    try {
        try { $locked = $mtx.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { [Console]::Error.WriteLine('govc.ps1: aviso, bitácora ocupada por más de 10 s; se registra sin exclusión.') }
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        $entry = [ordered]@{
            prev     = Get-LastAuditHash $logDir
            ts       = (Get-Date).ToString('o')
            user     = "$env:USERDOMAIN\$env:USERNAME"
            claude   = $byClaude
            env      = $envName
            mode     = $mode
            class    = $cls
            command  = (Protect-GovcArgs $cmdArgs) -join ' '
            result   = $result
            exitCode = $exitCode
        }
        if ($batchRef) { $entry['batch'] = $batchRef }
        $line = $entry | ConvertTo-Json -Compress
        Add-Content -Path (Join-Path $logDir ("audit-{0:yyyyMMdd}.jsonl" -f (Get-Date))) -Value $line -Encoding utf8
    } catch {
        [Console]::Error.WriteLine("govc.ps1: aviso, no se pudo escribir auditoría: $($_.Exception.Message)")
    } finally {
        if ($locked) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
}

if ($batch -and $bad.Count) {
    foreach ($b in $bad) { Write-Audit "blocked-batch-$($b.class)" 3 $b.cmd $b.class $batchId }
    Fail "El lote solo admite lecturas; el comando $($bad[0].i + 1) ('$((Protect-GovcArgs $bad[0].cmd) -join ' ')') es $($bad[0].class)." 3
}
if ($class -eq 'secret') {
    Write-Audit 'blocked-secret' 3
    Fail "'$sub' o sus flags exponen credenciales/sesión. No permitido desde el wrapper." 3
}
if ($mode -eq 'readonly' -and $class -ne 'read') {
    Write-Audit 'blocked-readonly' 3
    Fail "Entorno '$envName' es readonly; '$sub' es $class." 3
}
if ($class -eq 'destructive' -and $mode -ne 'lab') {
    if ($nonInteractive) {
        Write-Audit 'blocked-destructive' 3
        Fail "'$sub' es destructivo en '$envName'. Debe ejecutarlo una persona en una terminal interactiva, con cambio aprobado." 3
    }
    [Console]::Error.WriteLine("ATENCIÓN: operación DESTRUCTIVA en $($envName.ToUpper()): govc $((Protect-GovcArgs $rest) -join ' ')")
    $answer = Read-Host "Escribe el nombre del entorno ($envName) para confirmar"
    if ($answer -cne $envName) {
        Write-Audit 'cancelled' 4
        Fail 'Cancelado.' 4
    }
}

# --- 4. Binario govc ----------------------------------------------------------
$govc = Join-Path $root 'tools/govc.exe'
if (-not (Test-Path $govc)) {
    $cmd = Get-Command govc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Fail 'govc no encontrado. Ejecuta ./scripts/Install-Govc.ps1' }
    $govc = $cmd.Source
}

# --- 5. Credencial + ejecución ------------------------------------------------
$target = Opt 'credentialTarget' "govc:$envName"
$cred = Get-GovcCredential -Target $target

$vars = [ordered]@{
    GOVC_URL              = Opt 'url'
    GOVC_USERNAME         = $cred.UserName
    GOVC_PASSWORD         = $cred.GetNetworkCredential().Password
    GOVC_INSECURE         = if ((Opt 'insecure' $false) -eq $true) { '1' } else { $null }
    GOVC_TLS_CA_CERTS     = Opt 'caCerts'
    GOVC_DATACENTER       = Opt 'datacenter'
    GOVC_DATASTORE        = Opt 'datastore'
    GOVC_NETWORK          = Opt 'network'
    GOVC_RESOURCE_POOL    = Opt 'resourcePool'
    GOVC_FOLDER           = Opt 'folder'
    # Por defecto no se persiste la cookie de sesión en ~/.govmomi (evita secretos en disco).
    GOVC_PERSIST_SESSION  = if ((Opt 'persistSession' $false) -eq $true) { 'true' } else { 'false' }
}
if (-not $vars.GOVC_URL) { Fail "El perfil '$envName' no tiene 'url'." }

if ($batch) {
    # Sesión efímera: carpeta privada en %TEMP% (solo el usuario actual), un login para todo el lote,
    # logout explícito y borrado al terminar. Las variables solo viven en el entorno de cada proceso hijo.
    $tmp = [IO.Path]::GetTempPath()
    Get-ChildItem -LiteralPath $tmp -Directory -Filter 'govc-run-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $runDir = Join-Path $tmp "govc-run-$batchId"
    New-Item -ItemType Directory -Path $runDir | Out-Null
    $aclOut = & icacls $runDir /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Falla cerrada: sin permisos exclusivos no se crea la sesión.
        Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
        $vars.Clear(); $cred = $null
        Fail "No se pudieron restringir los permisos de la carpeta temporal del lote: $($aclOut -join ' ')" 2
    }
    $timeoutSec = [int](Opt 'batchTimeoutSec' 600)
    $vars['GOVC_PERSIST_SESSION'] = 'true'
    $vars['GOVMOMI_HOME'] = $runDir

    function Invoke-GovcProcess([string[]]$argv) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($govc)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
        foreach ($k in $vars.Keys) { if ($null -ne $vars[$k]) { $psi.Environment[$k] = "$($vars[$k])" } elseif ($psi.Environment.ContainsKey($k)) { [void]$psi.Environment.Remove($k) } }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync()
        # Tiempo máximo por comando: un comando colgado (p. ej. vm.ip -wait) no retiene la sesión.
        if (-not $proc.WaitForExit($timeoutSec * 1000)) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit()
            return [pscustomobject]@{ exitCode = 124; stdout = ''; stderr = "govc.ps1: tiempo agotado tras $timeoutSec s" }
        }
        $proc.WaitForExit()   # asegura que terminó la lectura asíncrona
        [pscustomobject]@{ exitCode = $proc.ExitCode; stdout = $o.Result; stderr = $e.Result }
    }

    $results = New-Object System.Collections.Generic.List[object]
    try {
        for ($i = 0; $i -lt $batch.Count; $i++) {
            $r = Invoke-GovcProcess $batch[$i]
            $results.Add([pscustomobject]@{ i = $i; exitCode = $r.exitCode; stdout = $r.stdout; stderr = $r.stderr })
            Write-Audit ($(if ($r.exitCode -eq 0) { 'ok' } else { 'error' })) $r.exitCode $batch[$i] 'read' $batchId
        }
    } finally {
        try { $null = Invoke-GovcProcess @('session.logout') } catch { }
        Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
        $vars.Clear(); $cred = $null
    }
    ConvertTo-Json -InputObject $results.ToArray() -Depth 3 -Compress
    exit 0
}

# Modo normal: las variables van solo al entorno del proceso de govc (nunca al de PowerShell).
# stdout se emite línea a línea al pipeline (sirve para | ConvertFrom-Json) y stderr se copia a la consola.
$exitCode = 1
try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new($govc)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($a in $rest) { $psi.ArgumentList.Add($a) }
    foreach ($k in $vars.Keys) { if ($null -ne $vars[$k]) { $psi.Environment[$k] = "$($vars[$k])" } elseif ($psi.Environment.ContainsKey($k)) { [void]$psi.Environment.Remove($k) } }
    $vars.Clear(); $cred = $null
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stderr = [Console]::OpenStandardError()
    $errCopy = $proc.StandardError.BaseStream.CopyToAsync($stderr)
    while ($null -ne ($line = $proc.StandardOutput.ReadLine())) { $line }
    $proc.WaitForExit()
    $errCopy.Wait(); $stderr.Flush()
    $exitCode = $proc.ExitCode
} finally {
    $vars.Clear(); $cred = $null; $psi = $null
    Write-Audit ($(if ($exitCode -eq 0) { 'ok' } else { 'error' })) $exitCode
}
exit $exitCode
