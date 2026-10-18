<#
  PreToolUse hook (Bash | PowerShell | Monitor | Write | Edit | NotebookEdit) — guarda de seguridad
  para govc. Lo invoca .claude/hooks/pre-guard.sh solo cuando el texto puede ser relevante; las
  lecturas (Read | Glob | Grep) las revisa read-guard.sh (el bloque 0a se conserva para las pruebas).

  Decisiones (la más restrictiva gana):
    deny  → secretos en la línea de comandos, govc directo, destructivo fuera de lab,
            escritura en entorno readonly, entorno desconocido, git add -f / reports / logs,
            comandos codificados (-EncodedCommand), escritura o borrado en logs/,
            archivos escritos por Claude que accedan a Credential Manager o a la sesión de govc,
            y lecturas de la carpeta de sesión efímera del modo lote.
    ask   → escritura (y destructivo en lab), lotes (-Batch: el contenido está en un archivo),
            o argumentos no resolubles (variables).
    allow → solo lecturas vía scripts/govc.ps1 en el tool PowerShell, cuando todo el
            comando consiste en el wrapper + cmdlets de transformación seguros.
  Sin salida → flujo normal de permisos de Claude Code.
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Emit([string]$decision, [string]$reason) {
    @{ hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = $decision
            permissionDecisionReason = "[govc-guard] $reason"
        } } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

# Patrones de acceso a la bóveda. Se arman por partes para que este archivo (y su copia
# preparada para revisión) no contenga los literales que la propia guarda bloquea al escribir.
$vaultPattern = (@(
        ('Cred' + 'Read'), ('Cred' + 'Enumerate'), ('Cred' + 'Write'), ('adv' + 'api32'),
        ('Govc' + 'CredMan'), ('Get-Govc' + 'Credential'), ('Cred' + 'Man\.psm1'),
        ('Get-Stored' + 'Credential'), ('Password' + 'Vault'), ('GOVC_' + 'PASSWORD\s*=')
    ) -join '|')

# Sesión efímera del modo lote de govc.ps1: solo el wrapper la crea y la usa.
$sessionPattern = (@(('GOVMOMI' + '_HOME'), ('govc-run' + '-'), ('GOVC_PERSIST' + '_SESSION'), ('\.govmomi' + '[\\/]+sessions')) -join '|')

try {
    $in = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $tool = "$($in.tool_name)"

    # --- 0a. Lecturas de archivos: la carpeta de sesión efímera no es accesible ------
    if ($tool -in 'Read', 'Glob', 'Grep') {
        $ti = $in.tool_input
        $paths = @('file_path', 'path', 'pattern', 'glob' | ForEach-Object { if ($ti.PSObject.Properties[$_]) { "$($ti.$_)" } })
        if ($paths | Where-Object { $_ -match $sessionPattern }) {
            Emit 'deny' 'La carpeta de sesión efímera de govc (o ~/.govmomi/sessions) contiene una sesión activa: no se lee desde Claude.'
        }
        exit 0
    }

    # --- 0. Archivos que escribe Claude ------------------------------------------
    # El hook de comandos no ve lo que hay dentro de un script; aquí se revisa el contenido
    # antes de escribirlo, para que Claude no pueda crear un lector de credenciales y ejecutarlo.
    if ($tool -in 'Write', 'Edit', 'MultiEdit', 'NotebookEdit') {
        $ti = $in.tool_input
        $texts = New-Object System.Collections.Generic.List[string]
        foreach ($k in 'content', 'new_string', 'new_source') { if ($ti.PSObject.Properties[$k]) { $texts.Add("$($ti.$k)") } }
        if ($ti.PSObject.Properties['edits']) { foreach ($e in @($ti.edits)) { $texts.Add("$($e.new_string)") } }
        foreach ($t in $texts) {
            if ($t -match $vaultPattern) {
                Emit 'deny' "El contenido accede a Credential Manager o fija la contraseña ('$($Matches[0])'). Solo scripts/govc.ps1 puede hacerlo; si hace falta cambiarlo, prepáralo para que lo revise una persona."
            }
            if ($t -match $sessionPattern) {
                Emit 'deny' "El contenido manipula la sesión de govc ('$($Matches[0])'). Solo el modo -Batch de scripts/govc.ps1 gestiona sesiones; si hace falta cambiarlo, prepáralo para que lo revise una persona."
            }
        }
        exit 0
    }

    $cmd = "$($in.tool_input.command)"
    if (-not $cmd) { exit 0 }

    Import-Module (Join-Path $projectRoot 'scripts/lib/Classify.psm1') -Force

    # --- 1. Secretos -----------------------------------------------------------
    $secretPatterns = [ordered]@{
        ('GOVC_' + 'PASSWORD')                           = 'manipula la contraseña de govc'
        'GOVC_URL\s*=?\s*\S*://[^/@\s]+:[^/@\s]+@'       = 'credenciales embebidas en GOVC_URL'
        '(^|\s)-+password(\s|=|$)'                       = 'contraseña en argumentos'
        'cmdkey\b[^\r\n]*/pass:'                         = 'contraseña en argumentos de cmdkey'
        $vaultPattern                                    = 'acceso directo a Credential Manager'
        'Set-GovcCredential'                             = 'la credencial la debe guardar una persona en su terminal'
        $sessionPattern                                  = 'acceso o manipulación de la sesión de govc'
        '\bgovc(\.exe)?\s+env\b|govc\.ps1\b[^\r\n|;]*\senv(\s|$)' = '`govc env` imprime credenciales'
        '(pwsh|powershell)(\.exe)?\b[^\r\n]*\s-(e|ec|en|enc|enco|encodedcommand)\s+[A-Za-z0-9+/=]{16,}' = 'comando codificado (oculta lo que se ejecuta)'
        'FromBase64String[\s\S]*(Invoke-Expression|\biex\b)|(Invoke-Expression|\biex\b)[\s\S]*FromBase64String' = 'ejecución de código decodificado'
    }
    foreach ($pat in $secretPatterns.Keys) {
        if ($cmd -match $pat) { Emit 'deny' "Bloqueado: $($secretPatterns[$pat]). Usa scripts/govc.ps1, que lee Credential Manager." }
    }

    # --- 1b. Integridad de la auditoría -------------------------------------------
    $writeVerb = '(Remove-Item|\bri\b|\brm\b|\brmdir\b|\bdel\b|\berase\b|Clear-Content|\bclc\b|Set-Content|\bsc\b|Add-Content|\bac\b|Out-File|Move-Item|\bmv\b|\bmove\b|Rename-Item|\bren\b|New-Item|Copy-Item|\bcp\b|\bcopy\b|\btruncate\b|\bsed\s+-i|>{1,2})'
    if ($cmd -match ($writeVerb + '[^\r\n;|&]*(^|[\s\\/''"=])logs([\\/''"\s]|$)')) {
        Emit 'deny' 'logs/ es la bitácora de auditoría: Claude no puede modificarla, moverla ni borrarla. Para limpiarla, debe hacerlo una persona.'
    }

    # --- 2. Git: los reportes y logs nunca se versionan ------------------------
    if ($cmd -match '\bgit\b[^\r\n;|&]*\badd\b[^\r\n;|&]*(\s-f\b|\s--force\b)') {
        Emit 'deny' 'git add -f/--force puede saltarse .gitignore (reports/, logs/, config). No permitido.'
    }
    if ($cmd -match '\bgit\b[^\r\n;|&]*\b(add|commit|stash)\b[^\r\n;|&]*(reports|logs)[\\/]|environments\.json\b[^\r\n]*\bgit\b|\bgit\b[^\r\n;|&]*\badd\b[^\r\n;|&]*environments\.json') {
        Emit 'deny' 'reports/, logs/ y config/environments.json no se suben a git.'
    }

    # --- 3. Tokenizar y analizar invocaciones -----------------------------------
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$tokens, [ref]$errors)

    $sep = 'Pipe', 'Semi', 'NewLine', 'AndAnd', 'OrOr', 'EndOfInput', 'LCurly', 'RCurly', 'LParen', 'RParen', 'DollarParen', 'AtParen'
    $flat = New-Object System.Collections.Generic.List[object]
    function Add-Tokens($list) {
        foreach ($t in $list) {
            $flat.Add($t)
            if ($t -is [System.Management.Automation.Language.StringExpandableToken] -and $t.NestedTokens) { Add-Tokens $t.NestedTokens }
        }
    }
    Add-Tokens $tokens

    function TokText($t) {
        if ($t -is [System.Management.Automation.Language.StringToken]) { return $t.Value }
        return $t.Text
    }

    # GOVC_GUARD_CONFIG solo lo usa scripts/Test-Guards.ps1 (el entorno del hook lo fija Claude Code, no el comando).
    $cfgPath = if ($env:GOVC_GUARD_CONFIG) { $env:GOVC_GUARD_CONFIG } else { Join-Path $projectRoot 'config/environments.json' }
    $cfg = if (Test-Path $cfgPath) { Get-Content $cfgPath -Raw | ConvertFrom-Json } else { $null }

    $decisions = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]
    $foundWrapper = $false
    $atStart = $true

    for ($i = 0; $i -lt $flat.Count; $i++) {
        $t = $flat[$i]
        $kind = "$($t.Kind)"
        if ($sep -contains $kind) { $atStart = $true; continue }
        if ($kind -in 'Ampersand', 'Dot') { $atStart = $true; continue }   # & cmd / . cmd
        $text = TokText $t

        # govc directo en posición de comando
        if ($atStart -and $text -match '(^|[\\/])govc(\.exe)?$') {
            Emit 'deny' 'No ejecutes govc directamente: usa ./scripts/govc.ps1 -Env <entorno> <subcomando>.'
        }

        if ($text -match 'govc\.ps1$') {
            $foundWrapper = $true
            $args_ = New-Object System.Collections.Generic.List[string]
            $hasVar = $false
            for ($j = $i + 1; $j -lt $flat.Count; $j++) {
                $u = $flat[$j]
                if ($sep -contains "$($u.Kind)") { break }
                if ($u -is [System.Management.Automation.Language.VariableToken] -or
                    ($u -is [System.Management.Automation.Language.StringExpandableToken] -and $u.NestedTokens)) { $hasVar = $true }
                $args_.Add((TokText $u))
            }
            $i = $j - 1

            # Extraer -Env
            $envName = $null; $rest = @()
            if ($args_.Count -ge 1 -and $args_[0] -match '^-Env:(.+)$') {
                $envName = $Matches[1]; $rest = @($args_ | Select-Object -Skip 1)
            } elseif ($args_.Count -ge 2 -and $args_[0] -match '^-Env:?$') {
                $envName = $args_[1]; $rest = @($args_ | Select-Object -Skip 2)
            }
            if (-not $envName -or $envName.StartsWith('$')) {
                $decisions.Add('ask'); $reasons.Add('no se pudo determinar -Env (debe ser el primer argumento y literal)'); continue
            }
            $envName = $envName.ToLowerInvariant()
            $prof = if ($cfg) { $cfg.PSObject.Properties[$envName] } else { $null }
            if (-not $prof) { Emit 'deny' "Entorno '$envName' no está definido en config/environments.json." }
            $mode = if ($prof.Value.PSObject.Properties['mode']) { "$($prof.Value.mode)".ToLowerInvariant() } else { 'readonly' }

            if (@($rest).Count -and "$($rest[0])" -ieq '-Batch') {
                # El contenido del lote está en un archivo; el wrapper exige que todo sea lectura.
                $decisions.Add('ask'); $reasons.Add("Lote de lecturas en $envName/$mode (contenido en archivo; el wrapper rechaza cualquier no lectura)"); continue
            }
            $sub = Get-GovcSubcommand $rest
            if (-not $sub -or $sub.StartsWith('$')) {
                $decisions.Add('ask'); $reasons.Add("subcomando no literal en $envName"); continue
            }
            $class = Get-GovcOpClass $rest
            $label = "$envName/$mode → $sub ($class)"
            switch ($class) {
                'secret' { Emit 'deny' "$label expone credenciales o sesión." }
                'destructive' {
                    if ($mode -ne 'lab') { Emit 'deny' "${label}: destructivo fuera de lab. Debe ejecutarlo una persona en terminal interactiva con cambio aprobado." }
                    $decisions.Add('ask'); $reasons.Add("DESTRUCTIVO en lab: $label")
                }
                'write' {
                    if ($mode -eq 'readonly') { Emit 'deny' "${label}: el entorno es readonly." }
                    $decisions.Add('ask'); $reasons.Add("Cambio en vCenter: $label")
                }
                default {
                    if ($hasVar) { $decisions.Add('read-var') } else { $decisions.Add('read') }
                    $reasons.Add("Lectura: $label")
                }
            }
            $atStart = $true
            continue
        }
        $atStart = $false
    }

    if (-not $foundWrapper) { exit 0 }
    if ($decisions -contains 'ask') { Emit 'ask' (($reasons | Select-Object -Unique) -join '; ') }

    # --- 4. Auto-allow solo si el comando completo es seguro ------------------
    if ($tool -ne 'PowerShell' -or $errors.Count -gt 0) { exit 0 }
    $safeCmds = @(
        'ConvertFrom-Json', 'ConvertTo-Json', 'Select-Object', 'select', 'Where-Object', 'where', '?',
        'Sort-Object', 'sort', 'Group-Object', 'group', 'Measure-Object', 'measure', 'Format-Table', 'ft',
        'Format-List', 'fl', 'Out-String', 'Select-String', 'ForEach-Object', '%', 'foreach', 'ConvertFrom-GovcCollect'
    )
    # Import-Module solo del parser de object.collect, con ruta literal (y -Force opcional).
    $isGovcJsonImport = {
        param($n)
        if ($n.GetCommandName() -ne 'Import-Module') { return $false }
        $els = @($n.CommandElements | Select-Object -Skip 1)
        $prm = @($els | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
        $arg = @($els | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
        return ($arg.Count -eq 1 -and $arg[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $arg[0].Value -match '^\.[\\/]scripts[\\/]lib[\\/]GovcJson\.psm1$' -and -not @($prm | Where-Object { $_.ParameterName -ne 'Force' }).Count)
    }
    $unsafe = $ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.FileRedirectionAst]) -or
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -or
            ($n -is [System.Management.Automation.Language.CommandAst] -and
                -not (($n.GetCommandName() -match 'govc\.ps1$') -or ($safeCmds -contains $n.GetCommandName()) -or (& $isGovcJsonImport $n)))
        }, $true)
    if (@($unsafe).Count -eq 0) { Emit 'allow' (($reasons | Select-Object -Unique) -join '; ') }
    exit 0
} catch {
    Emit 'ask' "Error en el hook ($($_.Exception.Message)); revisa el comando manualmente."
}
