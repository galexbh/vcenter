<#
.SYNOPSIS
  Pruebas de las guardas: clasificación de subcomandos y decisiones del hook PreToolUse.
  Usa config/environments.example.json (lab=lab, dr=readonly, prod=confirm). No contacta vCenter.

  Las cadenas sensibles de los casos se arman por partes para que este archivo no contenga
  los literales que la guarda de archivos bloquea.

.PARAMETER HookPath
  Hook alternativo a probar (p. ej. una versión preparada para revisión antes de instalarla).

.EXAMPLE
  ./scripts/Test-Guards.ps1
  ./scripts/Test-Guards.ps1 -HookPath <ruta>\.claude\hooks\govc-guard.ps1
  ./scripts/Test-Guards.ps1 -Strict      # un grupo de casos omitido (hook antiguo, sin sh) cuenta como falla
#>
#Requires -Version 7.5
[CmdletBinding(PositionalBinding = $false)]
param([string]$HookPath, [switch]$Strict)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib/Classify.psm1') -Force
$hook = if ($HookPath) { (Resolve-Path $HookPath).Path } else { Join-Path $root '.claude/hooks/govc-guard.ps1' }
$pw = 'GOVC_' + 'PASSWORD'
$vaultCall = 'Get-Govc' + 'Credential'
$vaultMod = 'Cred' + 'Man.psm1'
$vaultApi = 'Cred' + 'Read'
$fail = 0; $pass = 0

function Check($name, $expected, $actual) {
    if ($expected -eq $actual) { $script:pass++ }
    else { $script:fail++; Write-Host "FALLA  $name → esperado '$expected', obtenido '$actual'" -ForegroundColor Red }
}
function Skip([string]$msg) {
    # Con -Strict, un grupo omitido es una falla (p. ej. en CI o antes de instalar guardas nuevas).
    if ($Strict) { $script:fail++; Write-Host "FALLA  omitido: $msg" -ForegroundColor Red } else { Write-Host "Aviso: $msg" -ForegroundColor Yellow }
}

# --- Clasificación ---------------------------------------------------------------
$classCases = @(
    @('about', 'read'), @('ls /DC0/vm', 'read'), @('vm.info -json app01', 'read'), @('object.collect -json -type m / name', 'read'),
    @('find / -type m', 'read'), @('find / -p -type m', 'read'), @('snapshot.tree -vm app01', 'read'), @('datastore.ls -ds DS1', 'read'), @('events -n 10 app01', 'read'),
    @('vm.clone -vm tpl app02', 'write'), @('vm.change -vm app01 -c 4', 'write'), @('vm.power -on app01', 'write'),
    @('snapshot.create -vm app01 pre', 'write'), @('tags.attach Lab app01', 'write'), @('nuevo.comando', 'write'),
    @('vm.power -off app01', 'destructive'), @('vm.power -s app01', 'destructive'), @('vm.power -r app01', 'destructive'),
    @('vm.power -on -off app01', 'destructive'), @('vm.destroy app01', 'destructive'), @('snapshot.remove -vm app01 *', 'destructive'),
    @('snapshot.revert -vm app01 pre', 'destructive'), @('datastore.rm -ds DS1 iso/x.iso', 'destructive'),
    @('host.maintenance.enter esx01', 'destructive'), @('object.destroy /DC0/vm/f', 'destructive'), @('tags.rm Lab', 'destructive'),
    @('vm.unregister app01', 'destructive'),
    # host.esxcli: el técnico del piso — list/get son lectura, el resto modifica el host
    @('host.esxcli -host h network nic list', 'read'), @('host.esxcli -host h -json storage core path list', 'read'),
    @('host.esxcli -host h system ntp get', 'read'), @('host.esxcli -json -host=h software vib list', 'read'),
    @('host.esxcli -host h storage core path list -p vmhba0:C0:T0:L0', 'read'), @('host.esxcli -host h system account list', 'read'),
    @('host.esxcli -host h software vib install -d depot.zip', 'destructive'), @('host.esxcli -host h system maintenanceMode set -e true', 'destructive'),
    @('host.esxcli -host h network firewall set --enabled false', 'destructive'), @('host.esxcli -host h', 'destructive'),
    @('host.esxcli -host h list', 'destructive'),
    @('host.esxcli -host h system settings encryption recovery list', 'secret'), @('host.esxcli -host h system account add -i u -p x', 'secret'),
    @('host.esxcli -debug -host h network nic list', 'secret'), @('host.service.ls -host h', 'read'),
    @('env', 'secret'), @('about -debug', 'secret'), @('vm.info -password=x app', 'secret'), @('vm.console app01', 'secret'),
    # Métricas (Invoke-PerfCheck.ps1): las consultas son lectura; cambiar intervalos o niveles no lo es.
    @('metric.sample -json -i 300 -n 288 -instance= HostSystem:host-10 cpu.usage.average', 'read'), @('metric.interval.info -json', 'read'),
    @('metric.info - cpu.ready.summation', 'read'), @('metric.ls HostSystem:host-10', 'read'),
    @('metric.interval.change -i 300 -level 2', 'write'), @('metric.reset cpu.ready.summation', 'write'), @('metric.change -level 2 cpu.ready.summation', 'write'),
    @('metric.sample -debug HostSystem:host-10 cpu.usage.average', 'secret'),
    # Flags que vuelcan tráfico o redirigen la conexión (la credencial iría a otro endpoint).
    @('about -trace', 'secret'), @('about -verbose', 'secret'), @('about -u https://otro/sdk', 'secret'), @('ls -k /', 'secret'),
    @('about -persist-session=true', 'secret'), @('object.collect -tls-ca-certs x.pem / name', 'secret'), @('host.esxcli -host h -trace network nic list', 'secret'),
    # guest.*: credenciales del SO invitado (-l usuario:clave); vm.question -answer cambia la VM.
    @('guest.ls -l root:x -vm a /', 'secret'), @('vm.question -vm a', 'read'), @('vm.question -vm a -answer 1', 'write'), @('ls -l /DC0/vm', 'read')
)
foreach ($c in $classCases) { Check "class: $($c[0])" $c[1] (Get-GovcOpClass ($c[0] -split ' ')) }

# --- Enmascarado en la bitácora --------------------------------------------------------
$maskCases = @(
    @('find / -p -type m', 'find / -p -type m'), @('ls -l /DC0', 'ls -l /DC0'),
    @('guest.ls -l root:secreto -vm a /', 'guest.ls -l *** -vm a /'),
    @('host.esxcli -host h system account add -i u -p secreto', 'host.esxcli -host h system account add -i u -p ***'),
    @('vm.info -password=x app', 'vm.info -password=*** app')
)
foreach ($c in $maskCases) { Check "mask: $($c[0])" $c[1] ((Protect-GovcArgs ($c[0] -split ' ')) -join ' ') }

# --- Hook ------------------------------------------------------------------------
$sh = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.Source }
if (-not $sh -and (Test-Path 'C:\Program Files\Git\bin\sh.exe')) { $sh = 'C:\Program Files\Git\bin\sh.exe' }
$preGuard = Join-Path (Split-Path -Parent $hook) 'pre-guard.sh'
$projDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $hook))

function Invoke-HookCases($cases, [string]$via) {
    # Ejecuta los casos en paralelo. via = 'hook' (govc-guard.ps1) | 'pre' (pre-guard.sh → govc-guard.ps1).
    $hookPath = $hook; $pre = $preGuard; $shPath = $sh
    $res = $cases | ForEach-Object -ThrottleLimit 8 -Parallel {
        $c = $_
        $ti = if ($c.input -is [hashtable]) { $c.input } else { @{ command = $c.input } }
        $payload = @{ tool_name = $c.tool; tool_input = $ti } | ConvertTo-Json -Compress -Depth 5
        $out = if ($using:via -eq 'pre') { $payload | & $using:shPath $using:pre } else { $payload | pwsh -NoProfile -NonInteractive -File $using:hookPath }
        $d = if (-not $out) { 'none' } else { (($out | Out-String) | ConvertFrom-Json).hookSpecificOutput.permissionDecision }
        [pscustomobject]@{ i = $c.i; decision = $d }
    }
    $map = @{}; foreach ($r in $res) { $map[$r.i] = $r.decision }
    return $map
}

$W = './scripts/govc.ps1'
# Rutas sensibles armadas por partes (la guarda de archivos bloquea sus literales).
$gmd = '.govmomi'; $gse = 'sessions'
$cases = New-Object System.Collections.Generic.List[object]
function Add-Case($tool, $inputValue, $expected) { $cases.Add([pscustomobject]@{ i = $cases.Count; tool = $tool; input = $inputValue; expected = $expected }) }
foreach ($c in @(
    # lecturas
    @('PowerShell', "$W -Env prod about", 'allow'),
    @('PowerShell', "$W -Env prod object.collect -json -type m / name | ConvertFrom-Json | Select-Object -First 5", 'allow'),
    @('PowerShell', "$W -Env:dr ls /", 'allow'),
    @('PowerShell', "$W -Env prod about; Remove-Item x", 'none'),
    @('PowerShell', "$W -Env prod about > out.txt", 'none'),
    @('Bash', "pwsh -File $W -Env prod about", 'none'),
    @('PowerShell', "Get-ChildItem", 'none'),
    # escrituras
    @('PowerShell', "$W -Env prod vm.clone -vm tpl app02", 'ask'),
    @('PowerShell', "$W -Env lab vm.power -on app01", 'ask'),
    @('PowerShell', "$W -Env dr vm.clone -vm tpl app02", 'deny'),
    @('PowerShell', "$W -Env `$e about", 'ask'),
    @('PowerShell', "$W -Env prod `$sub", 'ask'),
    # destructivos
    @('PowerShell', "$W -Env prod vm.destroy app01", 'deny'),
    @('PowerShell', "$W -Env dr vm.power -off app01", 'deny'),
    @('PowerShell', "$W -Env lab vm.destroy app01", 'ask'),
    @('PowerShell', "$W -Env lab about; $W -Env prod snapshot.remove -vm a x", 'deny'),
    @('Bash', "pwsh -File $W -Env prod vm.destroy app01", 'deny'),
    # esxcli vía govc
    @('PowerShell', "$W -Env prod host.esxcli -host esx01 -json network nic list", 'allow'),
    @('PowerShell', "$W -Env dr host.esxcli -host esx01 system syslog config get", 'allow'),
    @('PowerShell', "$W -Env prod host.esxcli -host esx01 software vib install -d x.zip", 'deny'),
    @('PowerShell', "$W -Env lab host.esxcli -host esx01 software vib install -d x.zip", 'ask'),
    @('PowerShell', "$W -Env prod host.esxcli -host esx01 system settings encryption recovery list", 'deny'),
    # entorno desconocido / govc directo / secretos
    @('PowerShell', "$W -Env qa about", 'deny'),
    @('PowerShell', "govc ls /", 'deny'),
    @('PowerShell', "& ./tools/govc.exe about", 'deny'),
    @('Bash', "./tools/govc.exe about", 'deny'),
    @('Monitor', "./tools/govc.exe events -f", 'deny'),
    @('PowerShell', "`$env:$pw = 'x'", 'deny'),
    @('Bash', "GOVC_URL=https://u:p@vc/sdk govc about", 'deny'),
    @('PowerShell', "$W -Env lab env", 'deny'),
    @('PowerShell', "$W -Env lab about -debug", 'deny'),
    @('PowerShell', "$W -Env prod about -trace", 'deny'),
    @('PowerShell', "$W -Env prod about -u https://otro/sdk", 'deny'),
    @('PowerShell', "cmdkey /generic:govc:prod /user:a /pass:secreto", 'deny'),
    @('PowerShell', "Import-Module ./scripts/lib/$vaultMod; $vaultCall govc:prod", 'deny'),
    @('PowerShell', "Get-Content ~/$gmd/$gse/abc", 'deny'),
    # git
    @('Bash', "git add -f reports/prod/x.html", 'deny'),
    @('PowerShell', "git add reports/prod/x.md", 'deny'),
    @('Bash', "git add logs/audit.jsonl", 'deny'),
    @('Bash', "git add config/environments.json", 'deny'),
    @('Bash', "git add scripts/New-Report.ps1", 'none'),
    # sin nada relevante: el filtro rápido ni siquiera arranca PowerShell
    @('Bash', "ls -la docs", 'none'),
    @('PowerShell', "Get-Date", 'none'),
    @('Write', @{ file_path = 'notes.md'; content = 'Reporte de capacidad de prod' }, 'none')
)) { Add-Case $c[0] $c[1] $c[2] }

$hookText = Get-Content $hook -Raw
if ($hookText -match 'ConvertFrom-GovcCollect') {
    Add-Case 'PowerShell' "Import-Module ./scripts/lib/GovcJson.psm1; $W -Env prod object.collect -json -type h / name | ConvertFrom-GovcCollect" 'allow'
    Add-Case 'PowerShell' "Import-Module ./scripts/lib/GovcJson.psm1 -Force; $W -Env prod object.collect -json -type h / name | ConvertFrom-GovcCollect | Select-Object name" 'allow'
    Add-Case 'PowerShell' "Import-Module ./otro.psm1; $W -Env prod about" 'none'
} else { Skip 'el hook instalado no reconoce ConvertFrom-GovcCollect / Import-Module de GovcJson (1.8); casos omitidos.' }

# --- Hook v1.2: archivos, bitácora y comandos codificados ----------------------------
# Se detectan por capacidad: con un hook anterior estos casos se omiten (no fallan, salvo -Strict).
if ($hookText -match "'Write', 'Edit'") {
    foreach ($c in @(
        @('Write', @{ file_path = 'x.ps1'; content = "[X]::$vaultApi('govc:prod')" }, 'deny'),
        @('Edit', @{ file_path = 'scripts/a.ps1'; old_string = 'a'; new_string = "$vaultCall -Target govc:prod" }, 'deny'),
        @('MultiEdit', @{ file_path = 'scripts/a.ps1'; edits = @(@{ old_string = 'a'; new_string = "`$env:$pw = 'x'" }) }, 'deny'),
        @('Edit', @{ file_path = 'scripts/New-Report.ps1'; old_string = 'a'; new_string = 'b' }, 'none'),
        @('PowerShell', 'Remove-Item logs/audit-20261017.jsonl', 'deny'),
        @('PowerShell', "'x' | Out-File logs\a.jsonl", 'deny'),
        @('PowerShell', 'Clear-Content .\logs\audit-20261017.jsonl', 'deny'),
        @('Bash', 'rm -rf logs', 'deny'),
        @('Bash', 'echo x >> logs/audit-20261017.jsonl', 'deny'),
        @('PowerShell', 'Get-Content logs/audit-20261017.jsonl -Tail 5', 'none'),
        @('PowerShell', "$W -Env prod logs", 'allow'),
        @('PowerShell', 'pwsh -EncodedCommand SQBFAFgAIAAoAE4AZQB3AC0ATwBiAGoAZQBjAHQA', 'deny'),
        @('PowerShell', "iex ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('ZWNobyBo')))", 'deny')
    )) { Add-Case $c[0] $c[1] $c[2] }
    if ($hookText -match 'sessionPattern') {
        $gh = 'GOVMOMI' + '_HOME'; $gr = 'govc-run' + '-abc123'; $gp = 'GOVC_PERSIST' + '_SESSION'
        foreach ($c in @(
            @('PowerShell', "$W -Env prod -Batch lote.json", 'ask'),
            @('PowerShell', "$W -Env dr -Batch lote.json", 'ask'),
            @('PowerShell', "`$env:$gh = 'C:\x'", 'deny'),
            @('PowerShell', "Get-ChildItem `$env:TEMP\$gr\$gse", 'deny'),
            @('Bash', "cat /tmp/$gr/$gse/x", 'deny'),
            @('Write', @{ file_path = 'x.ps1'; content = "`$env:$gp = 'true'" }, 'deny'),
            @('Edit', @{ file_path = 'x.ps1'; old_string = 'a'; new_string = "`$env:$gh = 'C:\s'" }, 'deny'),
            @('Read', @{ file_path = "C:\Users\u\AppData\Local\Temp\$gr\$gse\abc" }, 'deny'),
            @('Glob', @{ pattern = "**/$gr/**" }, 'deny'),
            @('Read', @{ file_path = 'C:\Users\u\Documents\Github\vcenter\README.md' }, 'none')
        )) { Add-Case $c[0] $c[1] $c[2] }
    }
} else { Skip 'el hook instalado no incluye los controles v1.2 (archivos, bitácora); casos omitidos.' }

# Un solo valor para todo el proceso (los hilos lo comparten); se restaura el valor anterior al final.
$prevCfg = $env:GOVC_GUARD_CONFIG; $prevProj = $env:CLAUDE_PROJECT_DIR
$env:GOVC_GUARD_CONFIG = Join-Path $root 'config/environments.example.json'
$env:CLAUDE_PROJECT_DIR = $projDir
try {
    $direct = Invoke-HookCases $cases.ToArray() 'hook'
    foreach ($c in $cases) {
        $label = if ($c.input -is [hashtable]) { "$($c.tool) $($c.input['file_path'] ?? $c.input['pattern'])" } else { $c.input }
        Check "hook[$($c.tool)]: $label" $c.expected $direct[$c.i]
    }
    # Filtro rápido: misma decisión que la guarda completa en todos los casos de los tools que cubre.
    if ((Test-Path $preGuard) -and $sh) {
        $preCases = @($cases | Where-Object { $_.tool -in 'Bash', 'PowerShell', 'Monitor', 'Write', 'Edit', 'NotebookEdit' })
        $viaPre = Invoke-HookCases $preCases 'pre'
        foreach ($c in $preCases) {
            $label = if ($c.input -is [hashtable]) { "$($c.tool) $($c.input['file_path'])" } else { $c.input }
            Check "pre-guard = hook[$($c.tool)]: $label" $direct[$c.i] $viaPre[$c.i]
        }
    } else { Skip 'pre-guard.sh o sh no disponibles; equivalencia del filtro rápido omitida.' }
} finally {
    if ($null -eq $prevCfg) { Remove-Item Env:GOVC_GUARD_CONFIG -ErrorAction SilentlyContinue } else { $env:GOVC_GUARD_CONFIG = $prevCfg }
    if ($null -eq $prevProj) { Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $prevProj }
}

# --- Guarda rápida de lecturas (read-guard.sh) -----------------------------------------
$readGuard = Join-Path (Split-Path -Parent $hook) 'read-guard.sh'
if ((Test-Path $readGuard) -and $sh) {
    $rr = 'govc' + '-run-abc'; $gm = '.govmomi'; $se = 'sessions'
    $readCases = @(
        @(@{ tool_name = 'Read'; tool_input = @{ file_path = 'C:\Users\u\Documents\Github\vcenter\README.md' } }, 'none'),
        @(@{ tool_name = 'Read'; tool_input = @{ file_path = "C:\Users\u\AppData\Local\Temp\$rr\x" } }, 'deny'),
        @(@{ tool_name = 'Glob'; tool_input = @{ pattern = "**/$($rr.ToUpper())/**" } }, 'deny'),
        @(@{ tool_name = 'Read'; tool_input = @{ file_path = "C:\Users\u\$gm\$se\abc" } }, 'deny'),
        @(@{ tool_name = 'Grep'; tool_input = @{ pattern = 'x'; path = "/c/Users/u/$gm/$se" } }, 'deny')
    )
    foreach ($c in $readCases) {
        $out = ($c[0] | ConvertTo-Json -Compress -Depth 4) | & $sh $readGuard
        $d = if ("$out" -match '"permissionDecision":"deny"') { 'deny' } else { 'none' }
        Check "read-guard[$($c[0].tool_name)]: $($c[0].tool_input.Values | Select-Object -First 1)" $c[1] $d
    }
} else {
    Skip 'read-guard.sh o sh no disponibles; casos de lectura rápida omitidos.'
}

$color = if ($fail) { 'Red' } else { 'Green' }
Write-Host "`n$pass correctas, $fail fallidas" -ForegroundColor $color
exit $fail
