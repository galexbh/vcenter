# Clasificación de subcomandos govc: read | write | destructive | secret
# Compartido por scripts/govc.ps1 (wrapper) y .claude/hooks/govc-guard.ps1 (hook).
# Regla fail-safe: todo lo que no esté reconocido como lectura se trata como write.

Set-StrictMode -Version Latest

# Subcomandos que exponen o manipulan credenciales: nunca permitidos vía Claude.
$script:SecretCommands = @('env', 'session.login', 'sso.service.ls', 'vm.console')

# Lectura explícita (además de los sufijos .info / .ls / .tree).
$script:ReadCommands = @(
    'about', 'about.cert', 'ls', 'find', 'tree', 'events', 'tasks', 'logs', 'logs.ls',
    'object.collect', 'collect', 'version', 'fields.info', 'datastore.disk.info',
    'metric.ls', 'metric.info', 'metric.sample', 'metric.interval.info',
    'vm.ip', 'vm.question', 'host.date.info', 'host.esxcli.model',
    'option.ls', 'permissions.ls', 'role.ls', 'role.usage', 'sso.user.ls',
    'tags.ls', 'tags.info', 'tags.attached.ls', 'tags.category.ls', 'tags.category.info',
    'library.ls', 'library.info', 'license.ls', 'license.assigned.ls',
    'cluster.rule.ls', 'cluster.group.ls', 'cluster.override.info',
    'session.ls', 'extension.info', 'disk.ls', 'volume.ls', 'namespace.ls'
)

# Destructivos explícitos (además del patrón de verbos de abajo).
$script:DestructiveCommands = @(
    'host.maintenance.enter', 'host.shutdown', 'host.disconnect', 'host.reboot',
    'snapshot.revert', 'vm.unregister', 'object.destroy', 'datastore.rm',
    'vm.disk.detach', 'device.remove'
)
$script:DestructiveVerb = '(^|\.)(destroy|rm|remove|delete|unregister|shutdown|reboot|revert|disconnect|detach|erase|purge)$'

# host.esxcli: "el técnico del piso". Solo los verbos list/get son lectura.
$script:EsxcliReadVerbs = @('list', 'get')
# Flags de govc (no de esxcli) que llevan valor como argumento separado.
$script:GovcValueFlags = @('-host', '-dc', '-cert', '-key', '-tls-ca-certs', '-tls-known-hosts', '-vim-version', '-vim-namespace')
# Namespaces esxcli cuyo contenido es sensible aunque sea lectura (p. ej. claves de recuperación).
$script:EsxcliSecretNamespaces = @('system settings encryption')

function Get-EsxcliClass {
    <#
    .SYNOPSIS  Clasifica `host.esxcli` por el verbo del comando esxcli.
    .NOTES     Tras host.esxcli se saltan los flags de govc; las palabras posicionales hasta el
               primer flag de esxcli forman "namespace… verbo". Sin verbo claro → destructive.
    #>
    param([string[]]$Arguments)

    $i = [array]::IndexOf(@($Arguments | ForEach-Object { "$_".ToLowerInvariant() }), 'host.esxcli')
    $govcFlags = New-Object System.Collections.Generic.List[string]
    $words = New-Object System.Collections.Generic.List[string]
    for ($j = $i + 1; $j -lt $Arguments.Count; $j++) {
        $a = "$($Arguments[$j])"
        if ($a.StartsWith('-')) {
            if ($words.Count) { break }                 # empiezan las opciones de esxcli
            $govcFlags.Add($a.ToLowerInvariant())
            if ($script:GovcValueFlags -contains $a.ToLowerInvariant()) { $j++ }
            continue
        }
        $words.Add($a.ToLowerInvariant())
    }

    # Flags de govc previos al subcomando o propios de host.esxcli.
    $pre = @($Arguments | Select-Object -First ([math]::Max($i, 0)) | ForEach-Object { "$_".ToLowerInvariant() }) + $govcFlags
    if ($pre | Where-Object { $_ -match '^-+(password|debug|dump-cookie|trace|verbose)(=|$)' }) { return 'secret' }

    if ($words.Count -lt 2) { return 'destructive' }
    $path = $words -join ' '
    foreach ($ns in $script:EsxcliSecretNamespaces) { if ($path.StartsWith($ns)) { return 'secret' } }
    $verb = $words[$words.Count - 1]
    # Altas/cambios de cuentas llevan contraseña en los argumentos.
    if ($path.StartsWith('system account') -and $verb -notin $script:EsxcliReadVerbs) { return 'secret' }
    if ($script:EsxcliReadVerbs -contains $verb) { return 'read' }
    return 'destructive'
}

function Get-GovcSubcommand {
    <# Devuelve el primer argumento que no es flag (el subcomando govc). #>
    param([string[]]$Arguments)
    foreach ($a in $Arguments) {
        if ($a -and -not $a.StartsWith('-')) { return $a.ToLowerInvariant() }
    }
    return $null
}

function Get-GovcOpClass {
    <#
    .SYNOPSIS  Clasifica una invocación govc.
    .OUTPUTS   'read' | 'write' | 'destructive' | 'secret'
    #>
    param([string[]]$Arguments)

    $sub = Get-GovcSubcommand $Arguments
    if (-not $sub) { return 'read' }   # `govc` sin args solo muestra ayuda
    if ($sub -eq 'host.esxcli') { return Get-EsxcliClass $Arguments }

    $flags = @($Arguments | Where-Object { $_ -and $_.StartsWith('-') } | ForEach-Object { $_.ToLowerInvariant() })

    # Cualquier credencial en línea de comandos o modo debug (vuelca SOAP con sesión) se trata como secreto.
    if ($flags | Where-Object { $_ -match '^-+(password|p|debug|dump-cookie)(=|$)' }) { return 'secret' }
    if ($script:SecretCommands -contains $sub) { return 'secret' }

    if ($sub -eq 'vm.power') {
        # Solo encender es write; apagar/reiniciar/suspender interrumpe servicio.
        $onlyOn = ($flags | Where-Object { $_ -match '^-+on(=true)?$' }) -and
                  -not ($flags | Where-Object { $_ -match '^-+(off|reset|s|r|suspend|shutdown|reboot)(=true)?$' })
        if ($onlyOn) { return 'write' } else { return 'destructive' }
    }
    if ($sub -eq 'snapshot.remove' -or $sub -eq 'vm.destroy') { return 'destructive' }
    if ($script:DestructiveCommands -contains $sub) { return 'destructive' }
    if ($sub -match $script:DestructiveVerb) { return 'destructive' }

    # vm.change y similares pueden ser cualquier cosa: write (requiere aprobación).
    if ($script:ReadCommands -contains $sub) { return 'read' }
    if ($sub -match '\.(info|ls|tree)$') { return 'read' }

    return 'write'
}

function Protect-GovcArgs {
    <# Enmascara valores sensibles para logs de auditoría. #>
    param([string[]]$Arguments)
    $out = New-Object System.Collections.Generic.List[string]
    $maskNext = $false
    foreach ($a in $Arguments) {
        if ($maskNext) { $out.Add('***'); $maskNext = $false; continue }
        if ($a -match '^-+(password|p)$') { $out.Add($a); $maskNext = $true; continue }
        $a = $a -replace '^(-+(password|p)=).*', '$1***'
        $a = $a -replace '(://[^:/@\s]+:)[^@\s]+@', '$1***@'
        $out.Add($a)
    }
    return , $out.ToArray()
}

Export-ModuleMember -Function Get-GovcSubcommand, Get-GovcOpClass, Protect-GovcArgs
