# vCenter + govc + Claude Code

Kit para operar vCenter con `govc` desde Claude Code: consultas, reportes HTML/Markdown con sugerencias, plantillas y provisión con aprobación, con credenciales en Windows Credential Manager y guardas por entorno.

## Documentación

Sitio completo en `docs/` (Astro Starlight):

```powershell
cd docs
npm install
npm run dev      # http://localhost:4321
npm run build    # sitio estático en docs/dist/
```

## Requisitos

- Windows con PowerShell 7.5+ (`pwsh`) y Git for Windows.
- Cuenta de servicio de vCenter por entorno con **rol mínimo** (ideal: una de solo lectura para reportes y otra con privilegios de provisión acotados a carpetas/pools).

## Puesta en marcha

```powershell
# 1. govc fijado (v0.56.0) con verificación SHA256 → tools/
./scripts/Install-Govc.ps1            # -WithVcsim agrega el simulador para pruebas

# 2. Perfiles de entorno (archivo no versionado)
Copy-Item config/environments.example.json config/environments.json
#    editar url, datacenter, mode (readonly|confirm|lab), caCerts…

# 3. Credenciales (las ingresa la persona; se piden por consola)
./scripts/Set-GovcCredential.ps1 -Env lab
./scripts/Set-GovcCredential.ps1 -Env prod

# 4. Git: activar el pre-commit que bloquea reportes/logs/secretos
git init
git config core.hooksPath .githooks

# 5. Verificar guardas y conexión
./scripts/Test-Guards.ps1
./scripts/govc.ps1 -Env lab about
```

Luego abrir Claude Code en esta carpeta y usar `/env lab`, `/inventory prod`, `/report prod health`, `/health prod`, `/capacity prod`, `/snapshot-audit prod 7`, `/host-check prod CL-PROD-01`, `/trend prod`, `/audit prod` o `/vm-create specs/app01.yaml`. Guía completa en `docs/` (`npm run dev`).

## Modelo de seguridad

| Capa | Qué hace |
|---|---|
| `scripts/govc.ps1` | Único punto de entrada. Lee la credencial de Credential Manager en cada llamada, la expone solo durante la ejecución, no persiste sesión en disco, aplica el modo del entorno y audita en `logs/` |
| `.claude/hooks/govc-guard.ps1` | Antes de cada comando de Claude: bloquea govc directo, secretos, destructivos fuera de lab y escrituras en readonly; pide aprobación para escrituras; aprueba solo lecturas puras |
| `.claude/settings.json` | Impide a Claude editar guardas, logs y settings, y leer `~/.govmomi` |
| `.gitignore` + `.githooks/pre-commit` | `reports/`, `logs/`, `config/environments.json`, `tools/` y `specs/*.yaml` nunca se versionan; escaneo de credenciales en el diff |

Los destructivos en `prod`/`dr` solo los puede ejecutar una persona en terminal interactiva, escribiendo el nombre del entorno para confirmar.

## Probar sin vCenter real

```powershell
./scripts/Install-Govc.ps1 -WithVcsim
./tools/vcsim.exe -l 127.0.0.1:8989        # usuario/clave por defecto del simulador: user / pass
```
Agrega un perfil `vcsim` (`url: https://127.0.0.1:8989/sdk`, `insecure: true`, `mode: lab`) y su credencial con `Set-GovcCredential.ps1 -Env vcsim`.
