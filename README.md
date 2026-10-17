<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/src/assets/logo-dark.svg">
    <img src="docs/src/assets/logo-light.svg" alt="Plataforma vSphere · govc" width="120">
  </picture>
</p>

<h1 align="center">Plataforma vSphere · govc</h1>

<p align="center">
  <a href="https://galexbh.github.io/vcenter/">Documentación</a> ·
  <a href="#puesta-en-marcha">Puesta en marcha</a> ·
  <a href="#modelo-de-seguridad">Seguridad</a>
</p>

Kit para operar, analizar y auditar VMware vCenter con [`govc`](https://github.com/vmware/govmomi/tree/main/govc) desde Claude Code de forma controlada. Incluye consultas de inventario, reportes HTML y Markdown con hallazgos priorizados, análisis de tendencias, auditorías técnicas formales y provisión de máquinas virtuales con aprobación explícita.

Las credenciales se guardan solo en Windows Credential Manager. Cada operación pasa por un wrapper que aplica la política del entorno y la registra en una bitácora con integridad verificable.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/vista-reporte-oscuro.png">
    <img src=".github/assets/vista-reporte-claro.png" alt="Reporte de salud generado con datos de demostración: indicadores de inventario y hallazgos priorizados con el comando para revisarlos" width="860">
  </picture>
  <br>
  <sub>Reporte generado con el entorno de demostración (<code>task demo</code>); los datos son ficticios.</sub>
</p>

---

## Capacidades

| Área | Descripción |
|---|---|
| Consulta | Inventario completo con un número fijo de consultas en bloque (`object.collect`), sin depender del tamaño del entorno |
| Reportes | Inventario, snapshots, capacidad y salud en HTML, Markdown y CSV, con hallazgos clasificados por severidad |
| Diagnóstico de hosts | Revisión por `esxcli` de cada host de un clúster (VIBs, NIC, paths, NTP, syslog, coredump) y detección de diferencias |
| Auditoría | Informe formal imprimible con resumen ejecutivo, metodología, hallazgos `AUD-NNN`, plan de remediación y aprobación |
| Tendencias | Comparación entre corridas o auditorías sin volver a consultar vCenter |
| Provisión | Creación de VM desde plantilla con el flujo validar → planear → aprobar → ejecutar → verificar |

## Requisitos

- Windows con PowerShell 7.5 o superior (`pwsh`) y Git for Windows.
- Una cuenta de servicio de vCenter por entorno, con **rol mínimo**: de preferencia una de solo lectura para reportes y otra con privilegios de provisión limitados a carpetas y pools.
- Opcional: [Task](https://taskfile.dev) para los atajos de `Taskfile.yml`, y Node.js 24 para compilar la documentación en local.

## Puesta en marcha

```powershell
# 1. Clonar y activar el control pre-commit (bloquea reportes, bitácoras y secretos)
git clone https://github.com/galexbh/vcenter.git
cd vcenter
git config core.hooksPath .githooks

# 2. Instalar la versión estable más reciente de govc en tools/, con verificación SHA256
./scripts/Install-Govc.ps1                 # -WithVcsim agrega el simulador; -Version vX.Y.Z fija una versión

# 3. Definir los perfiles de entorno (archivo no versionado)
Copy-Item config/environments.example.json config/environments.json
#    Ajustar url, datacenter, mode (readonly | confirm | lab), caCerts, etc.

# 4. Registrar las credenciales (las ingresa la persona por consola)
./scripts/Set-GovcCredential.ps1 -Env lab
./scripts/Set-GovcCredential.ps1 -Env prod

# 5. Verificar guardas y conectividad
./scripts/Test-Guards.ps1
./scripts/govc.ps1 -Env lab about
```

Después, abre Claude Code en la carpeta del proyecto y usa los comandos de la sección siguiente.

## Comandos

| Comando | Propósito |
|---|---|
| `/env lab` | Verificar perfiles y conectividad |
| `/inventory prod` | Resumen de inventario en pantalla |
| `/report prod health` | Reporte HTML, Markdown o CSV en `reports/` (`all`, `inventory`, `snapshots`, `capacity`, `health`) |
| `/health prod` | Hallazgos priorizados con acciones sugeridas |
| `/capacity prod` | Capacidad por clúster y holgura ante la falla de un host |
| `/snapshot-audit prod 7` | Snapshots por antigüedad y plan de limpieza propuesto (no ejecuta) |
| `/host-check prod CL-PROD-01` | Revisión `esxcli` por host y detección de diferencias |
| `/trend prod` | Tendencias entre las dos últimas corridas |
| `/audit prod` | Auditoría técnica completa con informe formal |
| `/vm-create specs/app01.yaml` | Provisión de una VM con validación y aprobación |

## Atajos con Task

Fuera de Claude Code, las tareas habituales se ejecutan con [Task](https://taskfile.dev) (`winget install Task.Task`). `task` sin argumentos lista todas.

```powershell
task install                          # govc estable más reciente (-- -WithVcsim para el simulador)
task env ENV=lab                      # probar conexión
task health ENV=prod                  # también: inventory, capacity, snapshots
task report ENV=prod TYPE=all -- -Format csv
task host-check ENV=prod CLUSTER=CL-PROD-01
task audit ENV=prod SCOPE=security
task trend ENV=prod
task test                             # pruebas de guardas y de reportes
task docs                             # documentación en http://localhost:4321/vcenter/
```

Los parámetros adicionales de cada script van después de `--`. Las tareas solo cubren operaciones que no modifican vCenter: los cambios y la provisión siguen el flujo con validación y aprobación (`/vm-create`).

## Modelo de seguridad

| Capa | Función |
|---|---|
| `scripts/govc.ps1` | Único punto de entrada. Lee la credencial de Credential Manager en cada llamada, la expone solo durante la ejecución, no guarda sesiones en disco, aplica el modo del entorno y registra cada acción en `logs/` |
| `.claude/hooks/govc-guard.ps1` | Revisa cada comando de Claude antes de ejecutarlo. Bloquea el uso directo de govc, el manejo de secretos, las operaciones destructivas fuera de `lab` y las escrituras en `readonly`. Pide aprobación para escrituras y aprueba de forma automática solo las lecturas |
| `.claude/settings.json` | Impide a Claude editar guardas, bitácoras y configuración, y leer `~/.govmomi` |
| `.gitignore` y `.githooks/pre-commit` | `reports/`, `logs/`, `config/environments.json`, `tools/` y `specs/*.yaml` no se versionan nunca. Además, se escanea el diff en busca de credenciales |

**Modos de entorno**

| Modo | Lectura | Escritura | Operaciones destructivas |
|---|---|---|---|
| `readonly` | Libre | Bloqueada | Bloqueadas |
| `confirm` | Libre | Con aprobación | Solo una persona, en terminal interactiva |
| `lab` | Libre | Con aprobación | Con aprobación |

En `prod` y `dr`, las operaciones destructivas solo las ejecuta una persona en una terminal interactiva, escribiendo el nombre del entorno para confirmar y con un número de cambio aprobado.

## Pruebas

```powershell
./scripts/Test-Guards.ps1      # clasificación de operaciones y hook
./scripts/Test-Reports.ps1     # regresión de reportes, CSV, hosts, auditoría y tendencias
./scripts/Test-AuditLog.ps1    # integridad de la bitácora
```

### Sin vCenter real

- **Datos de demostración:** `./scripts/New-DemoData.ps1` crea un entorno ficticio `demo`. Los reportes se generan sin conexión con `-FromRaw reports/demo/<marca>`.
- **Simulador:**

  ```powershell
  ./scripts/Install-Govc.ps1 -WithVcsim
  ./tools/vcsim.exe -l 127.0.0.1:8989       # credenciales por defecto del simulador: user / pass
  ```

  Agrega un perfil `vcsim` (`url: https://127.0.0.1:8989/sdk`, `insecure: true`, `mode: lab`) y registra su credencial con `./scripts/Set-GovcCredential.ps1 -Env vcsim`.

## Estructura del proyecto

```text
.claude/        Skills, comandos, hook de control y permisos de Claude Code
.githooks/      Control pre-commit
.github/        Workflow de publicación de la documentación
config/         Perfiles de entorno (solo se versiona el ejemplo)
docs/           Documentación (Astro Starlight), publicada en GitHub Pages
scripts/        Wrapper, reportes, auditoría, pruebas y módulos (scripts/lib/)
specs/          Especificaciones de VM propias (no versionadas)
templates/      Plantillas de reporte, de auditoría y de especificación de VM
Taskfile.yml    Atajos de Task para reportes, pruebas, instalación y documentación
reports/ logs/  Salidas locales: reportes y bitácora (no versionadas)
```

## Documentación

El sitio se publica en https://galexbh.github.io/vcenter/. Cada cambio en `docs/` que llega a `main` lo compila y despliega el workflow `.github/workflows/docs.yml`.

Para trabajar en local: `task docs` (servidor en http://localhost:4321/vcenter/) o `task docs:build` (sitio estático en `docs/dist/`).

## Consideraciones

- Los reportes y la bitácora contienen inventario interno. Se quedan en `reports/` y `logs/`, y no deben publicarse en otros sistemas sin la validación de Seguridad de la Información.
- Los cambios en `prod` o `dr` necesitan un número de cambio aprobado y la validación del equipo dueño (Infraestructura o Seguridad).
- Las auditorías son técnicas y no constituyen una certificación de cumplimiento normativo. Sus resultados deben validarlos Auditoría Interna, Riesgo Tecnológico y Seguridad de la Información.
