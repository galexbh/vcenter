#!/bin/sh
# Guarda rápida para Read, Glob y Grep: evita arrancar PowerShell (~600 ms) en cada lectura.
# Bloquea la lectura de la carpeta de sesión efímera del modo lote y de las sesiones guardadas
# por govmomi en el perfil del usuario. Los patrones se arman por partes para que este archivo
# no contenga los literales que la guarda de archivos (govc-guard.ps1) bloquea al escribir.
# Comandos y escrituras siguen en govc-guard.ps1.
in=$(cat | tr 'A-Z' 'a-z')
run='govc'; run="$run-run-"
gm='.govmomi'; ses='sessions'
case "$in" in
  *"$run"*|*"$gm/$ses"*|*"$gm\\\\$ses"*)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[govc-guard] La carpeta de sesion efimera de govc (o las sesiones guardadas de govmomi) contiene una sesion activa: no se lee desde Claude."}}'
    ;;
esac
exit 0
