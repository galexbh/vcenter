#!/bin/sh
# Filtro rápido delante de govc-guard.ps1 (Bash, PowerShell, Monitor, Write, Edit, NotebookEdit).
# Arrancar PowerShell cuesta ~0,6 s por llamada. Toda decisión de govc-guard.ps1 (deny, ask o allow)
# exige que el texto contenga alguna de las palabras de abajo; si no aparece ninguna, la guarda
# saldría sin decidir, y aquí se sale igual sin arrancar PowerShell. La comilla invertida se incluye
# porque PowerShell elimina escapes (g`ovc) antes de que la guarda lea el texto.
# Test-Guards.ps1 comprueba que ambos caminos den la misma decisión en todos los casos.
# Los literales sensibles se arman por partes (la guarda de archivos los bloquea al escribir).
in=$(cat)
lc=$(printf '%s' "$in" | tr 'A-Z' 'a-z')
api='adv'; api="${api}api"
relevant=0
case "$lc" in
  *govc*|*govmomi*|*password*|*cred*|*vault*|*"$api"*|*cmdkey*|*pwsh*|*powershell*|*base64*|*logs*|*git*|*environments*|*'`'*)
    relevant=1 ;;
esac
[ "$relevant" -eq 0 ] && exit 0
printf '%s' "$in" | pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$CLAUDE_PROJECT_DIR/.claude/hooks/govc-guard.ps1"
exit $?
