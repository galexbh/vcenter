<#
.SYNOPSIS
  Wrapper seguro de govc. Único punto de entrada permitido para operar vCenter.

.DESCRIPTION
  En cada invocación:
    1. Carga el perfil del entorno desde config/environments.json.
    2. Clasifica la operación (read / write / destructive / secret) y aplica el modo del entorno.
       Flags que vuelcan tráfico o redirigen la conexión (-debug, -trace, -u, -k…) se bloquean.
    3. Registra antes de ejecutar las escrituras y destructivos (sin evidencia, no se ejecutan).
    4. Lee la credencial desde Windows Credential Manager (target govc:<env> por defecto).
    5. Ejecuta tools/govc.exe (nunca uno del PATH) con las variables del perfil solo en el entorno del
       proceso hijo; antes quita las GOVC_/GOVMOMI_ heredadas.
    6. Registra auditoría en logs/audit-<fecha>.jsonl (sin secretos), encadenada por hash.
  Modo lote (-Batch <archivo.json>): solo lecturas, una sesión efímera (un login), tiempo máximo por
  comando (batchTimeoutSec, 600 s) y, si el perfil define batchParallel > 1, hasta N comandos a la
  vez con la misma sesión (el primero abre la sesión; la bitácora se escribe en orden).

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

# Último hash escrito por este proceso: evita releer la bitácora en cada comando de un lote.
# Solo se usa si el archivo no cambió de largo desde nuestra escritura (si otro proceso agregó
# líneas, se recalcula desde el archivo). Se valida bajo el mutex.
$script:auditCache = $null
# Identidad real del proceso (no variables de entorno, que se pueden alterar).
$auditUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

function Write-Audit([string]$result, [int]$exitCode, [string[]]$cmdArgs = $rest, [string]$cls = $class, [string]$batchRef = '') {
    # Exclusión mutua entre procesos: leer el hash previo y agregar la línea es una operación atómica;
    # sin ella, dos wrappers simultáneos bifurcarían la cadena (falsa alarma en Test-AuditLog).
    # Devuelve $true si la línea quedó escrita.
    $logDir = Join-Path $root 'logs'
    $mtxName = 'Local\govc-audit-' + ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($logDir.ToLowerInvariant())))).Substring(0, 16)
    $mtx = [System.Threading.Mutex]::new($false, $mtxName)
    $locked = $false
    $ok = $false
    try {
        try { $locked = $mtx.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { [Console]::Error.WriteLine('govc.ps1: aviso, bitácora ocupada por más de 10 s; se registra sin exclusión.') }
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        $logFile = Join-Path $logDir ("audit-{0:yyyyMMdd}.jsonl" -f (Get-Date))
        $c = $script:auditCache
        $prev = if ($c -and $c.file -eq $logFile -and (Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -eq $c.length) { $c.hash } else { Get-LastAuditHash $logDir }
        $entry = [ordered]@{
            prev     = $prev
            ts       = (Get-Date).ToString('o')
            user     = $auditUser
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
        Add-Content -LiteralPath $logFile -Value $line -Encoding utf8
        $script:auditCache = [pscustomobject]@{
            file   = $logFile
            length = (Get-Item -LiteralPath $logFile).Length
            hash   = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($line)))).ToLowerInvariant()
        }
        $ok = $true
    } catch {
        $script:auditCache = $null
        [Console]::Error.WriteLine("govc.ps1: aviso, no se pudo escribir auditoría: $($_.Exception.Message)")
    } finally {
        if ($locked) { $mtx.ReleaseMutex() }
        $mtx.Dispose()
    }
    return $ok
}

if ($batch -and $bad.Count) {
    foreach ($b in $bad) { $null = Write-Audit "blocked-batch-$($b.class)" 3 $b.cmd $b.class $batchId }
    Fail "El lote solo admite lecturas; el comando $($bad[0].i + 1) ('$((Protect-GovcArgs $bad[0].cmd) -join ' ')') es $($bad[0].class)." 3
}
if ($class -eq 'secret') {
    $null = Write-Audit 'blocked-secret' 3
    Fail "'$sub' o sus flags exponen credenciales/sesión. No permitido desde el wrapper." 3
}
if ($mode -eq 'readonly' -and $class -ne 'read') {
    $null = Write-Audit 'blocked-readonly' 3
    Fail "Entorno '$envName' es readonly; '$sub' es $class." 3
}
if ($class -eq 'destructive' -and $mode -ne 'lab') {
    if ($nonInteractive) {
        $null = Write-Audit 'blocked-destructive' 3
        Fail "'$sub' es destructivo en '$envName'. Debe ejecutarlo una persona en una terminal interactiva, con cambio aprobado." 3
    }
    [Console]::Error.WriteLine("ATENCIÓN: operación DESTRUCTIVA en $($envName.ToUpper()): govc $((Protect-GovcArgs $rest) -join ' ')")
    $answer = Read-Host "Escribe el nombre del entorno ($envName) para confirmar"
    if ($answer -cne $envName) {
        $null = Write-Audit 'cancelled' 4
        Fail 'Cancelado.' 4
    }
}

# --- 4. Binario govc ----------------------------------------------------------
# Solo el binario instalado (y verificado) por Install-Govc.ps1; nunca uno encontrado en el PATH.
$govc = Join-Path $root 'tools/govc.exe'
if (-not (Test-Path -LiteralPath $govc)) { Fail 'govc no encontrado en tools/. Ejecuta ./scripts/Install-Govc.ps1 (o task install).' }

function New-GovcStartInfo([string[]]$argv) {
    # Las variables del perfil van solo al entorno del proceso hijo. Antes se quitan las GOVC_/GOVMOMI_
    # heredadas (de depuración o de otra sesión), para que no alteren la conexión ni el destino.
    $psi = [System.Diagnostics.ProcessStartInfo]::new($govc)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
    foreach ($k in @($psi.Environment.Keys)) { if ($k -match '^(GOVC|GOVMOMI)_') { [void]$psi.Environment.Remove($k) } }
    foreach ($k in $vars.Keys) { if ($null -ne $vars[$k]) { $psi.Environment[$k] = "$($vars[$k])" } }
    return $psi
}

function Test-RunInUse([string]$dir) {
    # Una carpeta de lote está en uso mientras su proceso mantiene abierto .lock en exclusiva.
    $f = Join-Path $dir '.lock'
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    try { $s = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None'); $s.Dispose(); return $false } catch { return $true }
}

# Escrituras y destructivos se registran ANTES de ejecutarse: sin evidencia en la bitácora no se ejecutan.
if (-not $batch -and $class -in 'write', 'destructive') {
    if (-not (Write-Audit 'started' -1)) { Fail 'No se pudo registrar la operación en la bitácora; no se ejecuta sin evidencia.' 2 }
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
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) -and -not (Test-RunInUse $_.FullName) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $runDir = Join-Path $tmp "govc-run-$batchId"
    New-Item -ItemType Directory -Path $runDir | Out-Null
    # Permisos exclusivos por SID (también funciona con cuentas de Entra ID, sin DOMINIO\usuario).
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $aclOut = & icacls $runDir /inheritance:r /grant:r "*${sid}:(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Falla cerrada: sin permisos exclusivos no se crea la sesión.
        Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
        $vars.Clear(); $cred = $null
        Fail "No se pudieron restringir los permisos de la carpeta temporal del lote: $($aclOut -join ' ')" 2
    }
    # Abierto en exclusiva durante todo el lote: la limpieza de otras corridas no toca esta carpeta.
    $lockStream = [IO.File]::Open((Join-Path $runDir '.lock'), 'Create', 'ReadWrite', 'None')
    $timeoutSec = [int](Opt 'batchTimeoutSec' 600)
    # Comandos simultáneos dentro del lote (misma sesión). 1 = en secuencia (por defecto).
    $parallel = [math]::Max(1, [int](Opt 'batchParallel' 1))
    $vars['GOVC_PERSIST_SESSION'] = 'true'
    $vars['GOVMOMI_HOME'] = $runDir

    function Start-GovcJob([int]$i, [string[]]$argv) {
        $proc = [System.Diagnostics.Process]::Start((New-GovcStartInfo $argv))
        [pscustomobject]@{
            i = $i; proc = $proc; sw = [Diagnostics.Stopwatch]::StartNew(); exit = $proc.WaitForExitAsync()
            out = $proc.StandardOutput.ReadToEndAsync(); err = $proc.StandardError.ReadToEndAsync()
        }
    }
    function Complete-GovcJob($j, [bool]$timedOut) {
        # Tiempo máximo por comando: un comando colgado (p. ej. vm.ip -wait) no retiene la sesión.
        if ($timedOut) {
            try { $j.proc.Kill($true) } catch { }
            $j.proc.WaitForExit()
            return [pscustomobject]@{ i = $j.i; exitCode = 124; stdout = ''; stderr = "govc.ps1: tiempo agotado tras $timeoutSec s" }
        }
        $j.proc.WaitForExit()   # asegura que terminó la lectura asíncrona
        [pscustomobject]@{ i = $j.i; exitCode = $j.proc.ExitCode; stdout = $j.out.Result; stderr = $j.err.Result }
    }
    function Invoke-GovcProcess([int]$i, [string[]]$argv) {
        $j = Start-GovcJob $i $argv
        Complete-GovcJob $j (-not $j.proc.WaitForExit($timeoutSec * 1000))
    }
    function Write-PendingAudit {
        # Bitácora en orden de índice y solo desde este hilo: la cadena de hashes queda igual que en secuencia.
        while ($script:logged -lt $batch.Count -and $null -ne $results[$script:logged]) {
            $r = $results[$script:logged]
            $null = Write-Audit ($(if ($r.exitCode -eq 0) { 'ok' } else { 'error' })) $r.exitCode $batch[$script:logged] 'read' $batchId
            $script:logged++
        }
    }

    $results = [object[]]::new($batch.Count)
    $script:logged = 0
    $running = New-Object System.Collections.Generic.List[object]
    try {
        # El primer comando corre solo y abre la sesión (un único login para todo el lote).
        $results[0] = Invoke-GovcProcess 0 $batch[0]
        Write-PendingAudit
        $width = 1
        if ($parallel -gt 1 -and $batch.Count -gt 2) {
            # En paralelo solo si la sesión quedó guardada; si no, cada proceso haría su propio login.
            if (Test-Path -LiteralPath (Join-Path $runDir 'sessions')) { $width = $parallel }
            else { [Console]::Error.WriteLine('govc.ps1: aviso, no se encontró la sesión del lote; se continúa en secuencia.') }
        }
        $next = 1
        while ($next -lt $batch.Count -or $running.Count) {
            while ($running.Count -lt $width -and $next -lt $batch.Count) { $running.Add((Start-GovcJob $next $batch[$next])); $next++ }
            [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($running | ForEach-Object { $_.exit }), 250)
            foreach ($j in $running.ToArray()) {
                $timedOut = -not $j.proc.HasExited -and $j.sw.Elapsed.TotalSeconds -ge $timeoutSec
                if ($j.proc.HasExited -or $timedOut) { $results[$j.i] = Complete-GovcJob $j $timedOut; [void]$running.Remove($j) }
            }
            Write-PendingAudit
        }
    } finally {
        foreach ($j in $running.ToArray()) { try { $j.proc.Kill($true) } catch { } }   # interrupción: sin procesos huérfanos
        try { $null = Invoke-GovcProcess -1 @('session.logout') } catch { }
        if ($lockStream) { $lockStream.Dispose() }
        Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
        $vars.Clear(); $cred = $null
    }
    ConvertTo-Json -InputObject $results -Depth 3 -Compress
    exit 0
}

# Modo normal: las variables van solo al entorno del proceso de govc (nunca al de PowerShell).
# stdout se emite línea a línea al pipeline (sirve para | ConvertFrom-Json) y stderr se copia a la consola.
$exitCode = 1
try {
    $psi = New-GovcStartInfo $rest
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
    $null = Write-Audit ($(if ($exitCode -eq 0) { 'ok' } else { 'error' })) $exitCode
}
exit $exitCode
