# Plan Maestro de Arquitectura Extensible — pacwin v0.5.1

Documento generado: `2026-06-08`  
Versión objetivo: `v0.5.1`  
Estado: Post-Refactoring / Pre-Extensión (Provider Model)

---

## Resumen Ejecutivo

Este plan maestro establece el camino para transformar a **pacwin** de un gestor monolítico de 3 proveedores a una **plataforma meta-gestora extensible** mediante el modelo `Provider`. Las mejoras de calidad del `master_plan.md` (v1) ya fueron implementadas exitosamente: temas centralizados, manejo de errores unificado, concurrencia extraída y patrón Command. Ahora el foco es **permitir que cualquier gestor de paquetes (actual o futuro) se registre dinámicamente sin modificar el núcleo**.

---

## Estado Actual de la Arquitectura (v0.5.0 - Post-Implementación)

### ✅ Componentes Implementados (Commit v0.5.0)

| Componente | Ubicación | Estado |
|-------------|-----------|--------|
| **Theme Engine** | `config/themes/default.ps1` | ✅ Activo — Paleta futura abstracta y dimensiones centralizadas |
| **Error Handler** | `internal/helpers/ErrorHandler.ps1` | ✅ Activo — Mapeo centralizado de códigos de error por proveedor |
| **Concurrency Engine** | `internal/helpers/Concurrency.ps1` | ✅ Activo — RunspacePool, spinner, timeout, cleanup |
| **Command Pattern** | `internal/commands/*.ps1` | ✅ Activo — Cada comando desacoplado en módulo propio |
| **Comment-Based Help** | Todo `pacwin.psm1` | ✅ Completo — Documentación por función indizada en `Get-Help` |
| **Security** | `_pw_sanitize`, `_pw_validate_path` | ✅ Sin cambios — Funciona con arquitectura nueva |

### 🎯 Punto de Inflexión

Actualmente, núcleo registra explícitamente winget/choco/scoop:

```powershell
# pacwin.psm1 (fragmento actual, lineas ~1700-1745)
function _pw_get_search_scripts {
    param($managers)
    $scripts = [ordered]@{}
    if ($managers["winget"]) { ... }
    if ($managers["choco"])  { ... }
    if ($managers["scoop"])  { ... }
    return $scripts
}
```

**Problema**: `_pw_get_search_scripts`, `_pw_doctor_check_managers`, `_pw_do_install` y similares **conocen los proveedores por nombre**. Agregar un cuarto proveedor requiere modificar estas funciones. El modelo `Provider` elimina este acoplamiento.

---

## Fase 1: Diseño del Modelo `Provider` — Semana 1

### 1.1 Definición de Clase/Contrato

Crear `internal/core/Provider.ps1` que defina la estructura de datos y el contrato que todo proveedor debe cumplir.

```powershell
class PacwinProvider {
    [string]$Name              # Identificador único del proveedor (ej. "winget")
    [string]$DisplayName       # Nombre legible (ej. "WinGet")
    [string]$Binary            # Ejecutable base
    [string[]]$Capabilities    # Acciones soportadas: search, install, uninstall, update, outdated, list, info, sync
    [hashtable]$Arguments      # Argumentos específicos por acción
    [scriptblock]$Parser       # Bloque de script para normalizar la salida de la CLI
    [hashtable]$Flags         # @{ RequiresAdmin = $true; AcceptSourceAgreements = $true }
}
```

### 1.2 Crear Instancias para Proveedores Actuales

Convertir las implementaciones actuales (winget/choco/scoop) en objetos `PacwinProvider` retrocompatibles. Esto demuestra que el modelo no rompe lo existente.

| Proveedor | Estado | Prioridad |
|-----------|--------|-----------|
| **winget** | 🔵 MVP | Alta — Implementación patrón |
| **chocolatey** | 🔵 MVP | Alta — Implementación patrón |
| **scoop** | 🔵 MVP | Alta — Implementación patrón (incl. fallback sfsu) |

### 1.3 Ejemplo: Conversión de winget a Provider

```powershell
# internal/providers/winget.ps1
$global:ProviderWinget = [Pacwininciple]
# ... línea de dependencias
class WingetProvider : PacwinProvider {
    WingetProvider() {
        $this.Name         = "winget"
        $this.DisplayName  = "WinGet"
        $this.Binary       = "winget.exe"
        $this.Capabilities = @("search","install","uninstall","update","outdated","list","info")
        $this.Arguments    = @{
            Search    = "search --query {0} --accept-source-agreements"
            Install   = "install --id {0} --accept-package-agreements --accept-source-agreements"
            Update    = "upgrade --id {0} --accept-package-agreements --accept-source-agreements"
            Uninstall = "uninstall --id {0}"
            Outdated  = "upgrade --accept-source-agreements"
            List      = "list --query {0} --accept-source-agreements"
            Info      = "show --id {0} --accept-source-agreements"
        }
        $this.Flags = @{ RequiresAdmin = $false; AcceptSourceAgreements = $true }
    }
    
    [object[]] Parse([string[]]$rawLines) { 
        # Extraer lógica de _pw_parse_winget_lines aquí como método
        return _pw_parse_winget_lines $rawLines 
    }
}
```

---

## Fase 2: Implementar el `ProviderRegistry` — Semana 2

### 2.1 Componente Registro

Crear `internal/core/ProviderRegistry.ps1`. Encargado de mantener un mapeo nombre→instancia y responder a consultas de capacidades.

```powershell
class ProviderRegistry {
    [hashtable]$Registry = @{}         # Key: string, Value: PacwinProvider
    [string[]]$BuiltinPaths = @()      # Rutas donde buscar proveedores predeterminados
    [string[]]$UserPaths = @()         # Rutas donde buscar proveedores de usuario

    [void] Register([PacwinProvider]$Provider) { ... }
    [PacwinProvider] Get([string]$Name) { ... }
    [PacwinProvider[]] GetAvailable() { ... }             # Filtra por detectabilidad en `$env:PATH`
    [PacwinProvider[]] GetByCapability([string]$Capability) { ... }
    [hashtable] DetectAll() { ... }                          # Retorna sólo los gestores presentes en el sistema
}
```

### 2.2 Integración con Concurrency Engine

Adaptar `Concurrency.ps1` para aceptar una lista de `PacwinProvider` en lugar de un `hashtable` de scripts diseccionados. El `ProviderRegistry` prepara los scripts, pero el concurrency engine los ejecuta.

```powershell
function New-PwSearchPool {
    # Antes: Recibía hashtable de scripts hardcodeados por nombre "winget", "choco", etc.
    # Ahora: Recibe [PacwinProvider[]], delega a $Provider.Arguments[Search]
}
```

---

## Fase 3: Comandos Core — Refactor Semántico — Semanas 3-4

### 3.1 Extracción de Hardcoding en Comandos

Actualmente cada comando en `internal/commands/*.ps1` conoce los proveedores por clave de hashtable:

```powershell
# internal/commands/install.ps1 (actual, simplificado)
function _pw_cmd_install {
    param($Context)
    $pkg = _pw_pick_source $results   # Conocimiento implícito de los 3 proveedores
    if ($pkg.Manager -eq "winget") { ... }
    if ($pkg.Manager -eq "choco")  { ... }
    if ($pkg.Manager -eq "scoop")  { ... }
}
```

**Refactor Propuesto**:

```powershell
function _pw_cmd_install {
    param($Context)
    $pkg = _pw_pick_source $results
    $provider = $registry.Get($pkg.Manager)
    $cmd = $provider.Arguments["Install"] -f $pkg.ID
    $raw = Invoke-Expression $cmd
    return $provider.Parse($raw)
}
```

### 3.2 Tabla de Impacto por Comando

| Comando | Estado Actual | Acción Requerida | Complejidad |
|---------|---------------|-----------------|-------------|
| `search` | Usa `$scripts["winget"]` | Usar `$registry.GetByCapability("search")` | Media |
| `install` | Switch por nombre | Derivar `--id` o `--name` del provider | Baja |
| `uninstall` | Switch por nombre | Usar `$provider.Arguments["Uninstall"]` | Baja |
| `update` | Switch por nombre con `--all` y `--id` | Usar `$provider.Arguments["Update"]` | Media |
| `outdated` | Parseadores por separado | Llamar `$provider.Parse()` | Media |
| `list` | Alias de `outdated` o list raw | Unificar a `$provider.Arguments["List"]` | Media |
| `info` | Switch por nombre | Usar `$provider.Arguments["Info"]` | Baja |
| `doctor` | Hardcodea `winget,choco,scoop,sfsu` | Iterar `$registry.GetAvailable()` | Baja |

---

## Fase 4: Proveedores Adicionales (Nuevos Gestores) — Semanas 4-6

Los proveedores adicionales son **candidatos válidos** para extender el alcance de pacwin hacia otros lenguajes y ecosistemas. Se priorizan por madurez de CLI en Windows y utilidad para desarrolladores.

| Proveedor | Dominio | Instalación | Priority | Notas |
|-----------|---------|-------------|----------|-------|
| **vcpkg** | C++ Libraries | Native / Bundled | 🔵 Alta | Herramienta oficial de MS. Completamente ausente en pacwin. Fuerte interés de devs nativos. |
| **pipx** | Python Executables | `pip install pipx` | 🔵 Alta | Ideal para herramientas CLI de Python sin tocar site-packages. |
| **npm** (global) | JavaScript / Node | Bundled con Node.js | 🔵 Alta | `npm install -g` es extremadamente común en Windows dev. |
| **yarn** (global) | JS / Alternative | `npm install -g yarn` | 🟡 Media | Compatibilidad con lockfiles. Poder ser redundante con npm si npm ya cubre todo. |
| **dotnet tool** | .NET Global Tools | Bundled con SDK | 🟡 Media | `dotnet tool install -g <pkg>`. Gestor nativo del ecosistema .NET. |
| **cargo** | Rust / Rustup | Vía rustup | 🟡 Media | `cargo install <crate>`. Requiere verbinst (MINGW) en Windows. |
| **composer** | PHP | Vía installer | 🔴 Baja | Menos común en flujos de Windows puro, más DevOps/Backend. |
| **gem** | Ruby | Vía RubyInstaller | 🔴 Baja | Nicho muy específico de Windows. |
| **brew** | Linux/Mac | N/A en Windows | ⚪ No Op | Core Homebrew abandonó soporte Windows nativo Formalmente. |
| **chocolatey GUI** | UI Overlay | N/A | ⚪ No Op | No ofrece ventaja CLI. |
| **portable** | Scripts standalone | Manual | 🔵 Considerar | Provider que apunte a directorios de `.portable/` o `.zip` con manifiesto JSON. |

### 4.1 Ingeniería de `Parse()` por Proveedor

La complejidad máxima está en la normalización de salida. Cada nuevo proveedor requiere un parser que devuelva `[PacwinResult[]]`. El contrato mínimo es:

```powershell
class PacwinResult {
    [string]$Name         # Nombre legible del paquete
    [string]$ID           # Identificador técnico (para instalar/desinstalar)
    [string]$Version      # Versión actual encontrada
    [string]$Description  # Breve descripción (opcional)
    [string]$Source       # Nombre del proveedor (mgr.Name)
    [string]$Manager      # Alias técnico (mgr.Name)
    [hashtable]$Metadata  # Datos extra específicos del proveedor
}
```

### 4.2 Retos Específicos por Proveedor Nuevo

| Proveedor | Reto Principal | Solución Propuesta |
|-----------|----------------|-------------------|
| **vcpkg** | Gestión de `triplet` (x64-windows, x86-windows) | Agregar campo `Triplet` al `$provider.Flags` y modificar `Arguments` para interpolar dinámicamente. O demandar `--triplet` explícito en la llamada al comando. |
| **pipx** | Carece de `search` nativo potente | Mapear `search` a `pipx runpip {0} --list` o ofrecer fallback a PyPI Search API si está disponible. |
| **npm** | Lista de global packages no es tabular | Usar `npm list -g --json --depth=0` para lectura estructurada; `ls-lint` para search. |
| **dotnet tool** | Diferenciar `global` vs `local` | Asumir `global` por defecto en `install`; agregar flag `--local` en futuras versiones. |

---

## Fase 5: Tests y Documentación de Extensibilidad — Semana 6

### 5.1 Tests de Registro y Dispatch

- [ ] Registrar provider mock en tiempo de ejecución y verificar que `registry.GetAvailable()` lo retorna.
- [ ] Simular un provider sin `--id` en `Arguments` y verificar que `_pw_cmd_install` interpola correctamente con `--name` o el token correspondiente.
- [ ] Test de integridad: un provider con `Capabilities=""` nunca se ejecuta.

### 5.2 Tests de Parse() para Nuevos Proveedores

| Escenario | Entrada Ejemplo | Resultado Esperado |
|-----------|-----------------|--------------------|
| vcpkg search | `"cpprestsdk  x64-windows  2.10.18"` | `Name=cpprestsdk`, `Version=2.10.18`, `Triplet=x64-windows` |
| npm list -g --json | `{"name":"prettier","version":"3.0.0"}` | `Name=prettier`, `Version=3.0.0`, `Source="npm"` |
| pipx list --short | `"pkgName==1.0.0"` | `Name=pkgName`, `Version=1.0.0` |
| scoop list (sfsu y nativo) | `"◎" + $line` | Via parse nativo ya probado en v0.4.x |

### 5.3 Guidelines para Contribuidores

Crear `docs/CONTRIBUTING_PROVIDERS.md` que defina:

1. Nombre del archivo: `internal/providers/{provider}.ps1`
2. Herencia de clase: `{Provider} : PacwinProvider`
3. Métodos obligatorios: `Parse([string[]]$lines) → [PacwinResult[]]`
4. Validación mínima: `.\otests\providers.Tests.ps1` siguiendo patrón `It "Registers and detects '$provider'" { ... }`
5. Modificar `pacwin.psd1` si es provider predeterminado; no modificar el core (`*.psm1`) para providers externos.

---

## Diagrama de Secuencia del Nuevo Flujo

```
Usuario
  │
  ├──(Input)→ pacwin.psm1
  │
  ├── Inicialización:
  │       Carga themes, helpers, registry
  │
  ├── Resolución de Comando:
  │       pacwin.psm1 → CommandMap → dispatch → internal/commands/*.ps1
  │
  ├── Consulta a Registro:
  │       internal/commands/search.ps1
  │            └──> ProviderRegistry.GetAvailable() → [Winget, Choco, Scoop, ...]
  │
  ├── Ejecución Concurrente (por cada provider disponible):
  │       internal/helpers/Concurrency.ps1 → ArgumentTemplate + provider.Binary
  │            └──> winget.exe, choco.exe, scoop.ps1, etc.
  │
  └── Parseo + Renderizado:
            provider.Parse(rawLines) → [PacwinResult]
                        └──> _pw_render_results(results)
```

---

## Timeline Resumido

| Semana | Foco | Entregables |
|--------|------|------------|
| 1 | Modelo `Provider`, clases, contratos | `internal/core/Provider.ps1`, `ProviderRegistry.ps1` |
| 2 | `ProviderRegistry` + Concurrency | Registro funcional, spinner adaptado |
| 3 | Refactor Comandos Core | `search.ps1`, `install.ps1`, `uninstall.ps1` sin hardcoding |
| 4 | `update.ps1`, `outdated.ps1`, `list.ps1` | Diseño de templates de argumentos por provider |
| 5 | Nuevos providers: vcpkg, pipx, npm | Implementación de `Parse()` y validación de tests |
| 6 | Documentación + Stabilización | `docs/CONTRIBUTING_PROVIDERS.md`, tests de integridad, rollback plan |

---

## Notas de Versionado

- **v0.5.0**: Refactoring de calidad (implementado).
- **v0.5.1**: Introducción del `ProviderRegistry` y proveedores nativos (winget/choco/scoop) bajo modelo.
- **v0.6.0**: Proveedores adicionales (vcpkg, pipx, npm) como **preview opt-in**.
- **v0.7.0**: Estabilización de providers externo y posible marketplace de scripts `pacwin-providers`.

*Este documento reemplaza al `master_plan.md` anterior como fuente de verdad para el desarrollo v0.5.1 en adelante.*
