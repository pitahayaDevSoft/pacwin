# RFC: Arquitectura Genérica de Gestores de Paquetes para pacwin

**Autor**: julesklord  
**Fecha**: 2026-06-08  
**Versión**: 0.1 (Request for Comments)  
**Estado**: Propuesta / Búsquando feedback

---

## 1. Resumen

Este documento propone una arquitectura que permita a **pacwin** registrar de forma dinámica y operar sobre cualquier gestor de paquetes sin necesidad de modificar el núcleo de la herramienta. 

Actualmente, pacwin soporta **winget**, **chocolatey** y **scoop**.Networks a future roadmap con nuevos gestores sofisticados como Meson y pipx. Este RFC define el modelo conceptual de `Provider` y el mecanismo de `Provider Registry`, diseñados para desacoplar el "cómo se ejecuta un comando" de la lógica de orquestación.

---

## 2. Motivación

El código actual utiliza `switch` y `if` hardcodeados para cada gestor:

```powershell
switch ($mgr) {
    "winget" { winget install --id $pkg.ID }
    "choco"  { choco install $pkg.ID -y }
    "scoop"  { scoop install $pkg.ID    }
}
```

**Problemas:**
- **Acoplamiento**: Agregar un nuevo gestor requiere tocar múltiples partes del script (`_pw_do_install`, `_pw_search_all`, `_pw_do_outdated`, etc.).
- **Complejidad escalonada**: Cada nueva fuente implica nuevos regex, validación de PATH y columnas de UI.
- **No testeable unitariamente**: No es posible simular un gestor sin mockear secciones enteras de código.

**Solución propuesta**: Abstraer cada gestor como un `Provider` con una interfaz declarativa que expone las capacidades y los comandos nativos.

---

## 3. Diseño Conceptual: El Modelo `Provider`

Cada gestor en el ecosistema Windows —y potencialmente futuros remotos— se modela como un `Provider` estandarizado. El objetivo es tratar a **winget** y a un gestor experimental como `vcpkg` de la misma manera, descargando la complejidad específica al objeto `Provider`.

### 3.1 Definición Formal del Contrato

```powershell
# Definición mínima de un Provider
class PacwinProvider {
    [string]$Name              # Identificador único (ej. "winget")
    [string]$DisplayName         # Nombre legible (ej. "WinGet")
    [string]$Binary            # Ejecutable base (ej. "winget.exe")
    [string[]]$Capabilities    # ["search", "install", "uninstall", "update", "outdated", "list", "info"]
    
    # Comandos para mapear la API de pacwin a la CLI del gestor
    [hashtable]$Commands       # @{ search = "search --query {0}"; install = "install --id {0}"; ... }
    
    # Parser para normalizar la salida del gestor a un objeto estándar
    [scriptblock]$Parser       # { param([string[]]$lines) ... -> [PacwinResult[]] }
    
    # Opciones de seguridad y entorno
    [hashtable]$Flags          # @{ RequiresAdmin = $true; AcceptSourceAgreements = $true; ... }
}
```

### 3.2 Ejemplo: Provider para `pipx` (Python Executables)

Este ejemplo demuestra cómo se vería un gestor "imposible" (no tradicional de Windows) dentro del modelo. `pipx` instala ejecutables Python aislados directamente en el PATH del usuario.

```powershell
$pacwin_provider_pipx = [PacwinProvider]@{
    Name         = "pipx"
    DisplayName  = "pipx (Python)"
    Binary       = "pipx"
    Capabilities = @("search", "install", "uninstall", "update", "list", "info")
    
    Commands     = @{
        search    = "runpip {0} --list"              # No tiene search nativo real
        install   = "install {0}"
        uninstall = "uninstall {0}"
        update    = "upgrade {0}"
        outdated  = "list --outdated"
        list      = "list --short"
        info      = "run {0} --help"
    }
    
    Parser       = {
        param([string[]]$rawLines)
        $parsed = [System.Collections.Generic.List[PacwinResult]]::new()
        switch -Regex ($rawLines) {
            "^pipx\s+(?<pkg>\S+)\s+(?<ver>[\d.]+)" {
                # List format: name version [dependencies]
                $parsed.Add([PacwinResult]@{ Name=$matches.pkg; ID=$matches.pkg; Version=$matches.ver; Source="pipx" })
            }
        }
        return $parsed
    }
    
    Flags        = @{
        RequiresAdmin          = $false   # pipx trabaja en user-space
        AcceptSourceAgreements = $true    # pipx no tiene agreements
        SupportsGlobalInstall  = $false   # pipx siempre es --user
    }
}
```

*Nota sobre `search`*: `pipx` carece de un comando nativo de búsqueda robusto. En ese caso, el `Provider` mapea `search` a `runpip`, o el registro del provider podría indicar que no soporta búsqueda, dejando que `pacwin` lo ignore o implemente un fallback genérico (ej. consultar PyPI/Warehouse).

### 3.3 Ejemplo: Provider para `vcpkg`

[vcpkg](https://vcpkg.io/) es el gestor de paquetes para C++ de Microsoft. Es un excelente candidato porque maneja librerías nativas en Windows, algo que ninguno de los tres gestores actuales hace bien.

```powershell
$pacwin_provider_vcpkg = [PacwinProvider]@{
    Name         = "vcpkg"
    DisplayName  = "vcpkg (C++)"
    Binary       = "vcpkg"
    Capabilities = @("search", "install", "uninstall", "update", "list", "info")
    
    Commands     = @{
        search    = "search {0} --x-full-desc"
        install   = "install {0} --triplet xtax64-windows"
        uninstall = "remove {0} --recurse"
        update    = "upgrade {0} --no-dry-run"
        outdated  = "list --x-full-desc" # Requiere post-parse para detectar versiones
        list      = "list"
        info      = "search {0} --x-full-desc --max-results 1"
    }
    
    Parser       = {
        param([string[]]$rawLines)
        $parsed = [System.Collections.Generic.List[PacwinResult]]::new()
        ForEach ($line in $rawLines) {
            # vcpkg search format: <name> <triplet> <version> <description>
            if ($line -match "^(?<name>\S+)\s+\w+\s+(?<ver>[\d.]+)\s+(?<desc>.*)$") {
                $parsed.Add([PacwinResult]@{ Name=$matches.name; ID=$matches.name; Version=$matches.ver; Description=$matches.desc; Source="vcpkg" })
            }
        }
        return $parsed
    }
    
    Flags        = @{
        RequiresAdmin          = $false # Normalmente funciona en user-space con --x-install-root
        AcceptSourceAgreements = $false # N/A para vcpkg
        NeedsTriplet           = $true # Flag especial de vcpkg
    }
}
```

**Impacto potencial**: Permitir a pacwin ser la interfaz unificada para librerías de C++ en Windows, algo que hoy ninguna herramienta gestiona satisfactoriamente.

---

## 4. Provider Registry: El Centro de Mando

El `Registry` es el componente que coordina la vida de los providers. Nunca interactúa directamente con las CLIs ni parsea salida; su única responsabilidad es **delegar y ensamblar**.

### 4.1 Código Propuesto

```powershell
class ProviderRegistry {
    # Almacena el estado
    [hashtable]$Registry = @{}          # Key: Name, Valor: Provider
    [hashtable]$DiscoveryPaths = @()    # Rutas donde buscar scripts de provider

    # Registra un nuevo provider (en runtime o al inicio)
    [void] Register([PacwinProvider]$Provider) {
        if ($this.Registry.ContainsKey($Provider.Name)) {
            Write-Warning "Provider '$($Provider.Name)' ya está registrado. Reemplazando..."
        }
        $this.Registry[$Provider.Name] = $Provider
    }

    # Detecta providers disponibles en el sistema
    [hashtable] Detect() {
        $detected = @{}
        ForEach ($kvp in $this.Registry.GetEnumerator()) {
            $provider = $kvp.Value
            $path = _pw_exe $provider.Binary
            if ($path) {
                $detected[$provider.Name] = $path
            }
        }
        return $detected
    }

    # Ejecuta un comando genérico delegando al provider correcto
    [object[]] InvokeCommand([string]$Action, [string[]]$Arguments, [string]$ProviderName) {
        if (-not $this.Registry.ContainsKey($ProviderName)) {
            throw "Provider '$ProviderName' no está registrado."
        }
        $p = $this.Registry[$ProviderName]
        if ($p.Capabilities -notcontains $Action) {
            throw "Provider '$ProviderName' no soporta la acción '$Action'."
        }
        $cmd = $p.Commands[$Action] -f $Arguments
        $raw = Invoke-Expression "$cmd" # Simplicidad conceptual
        return & $p.Parser $raw
    }
}
```

### 4.2 Flujo de Uso en `pacwin`

```powershell
# --- Al cargar el módulo ---
$global:PacwinProviders = [ProviderRegistry]::new()
$global:PacwinProviders.Register($pacwin_provider_winget)
$global:PacwinProviders.Register($pacwin_provider_choco)
$global:PacwinProviders.Register($pacwin_provider_scoop)
# NUEVOS: Se añaden sin tocar código core
# $global:PacwinProviders.Register($pacwin_provider_pipx)
# $global:PacwinProviders.Register($pacwin_provider_vcpkg)

# --- En una función de alto nivel (ej. _pw_do_install) ---
function _pw_do_install_generic {
    param([string]$Manager, [string]$PackageID)
    $result = $global:PacwinProviders.InvokeCommand("install", @($PackageID), $Manager)
    # El resultado ya está normalizado (Pelican), listo para renderizar o tuberías
    _pw_render_results $result
}
```

---

## 5. Nuevos Gestores Potenciales (Listado) con Justificación

A continuación una tabla de gestores que encajan en el modelo `Provider` y la razón de su inclusión:

| Gestor | Tecnología | Justificación | Capacidades Básicas |
| :--- | :--- | :--- | :--- |
| **vcpkg** | C++ / Build Systems | Dominio de las librerías nativas en Windows, crucial para desarrolladores de C++. Actualmente no hay un gestor unificado. | `search`, `install`, `update`, `list` |
| **pipx** | Python | Instalación de utilidades CLI de Python sin afectar el site-packages global. Ideal para dev tools. | `list`, `install`, `uninstall`, `update`, `outdated` |
| **npm** (global) | JavaScript / Node | `npm install -g` estándar para herramientas Node.js (prettier, typescript, etc.). | `search`, `install`, `uninstall`, `update`, `list`, `outdated` |
| **dotfiles/wingetpkg** | Custom | Repositorios propios de paquetes corporativos que aplican políticas específicas. | Variable según implementación |
| **Unity Hub / Editor** | Game Dev | Instalación de versiones del motor. Se mapearía a comandos discretos. | `install`, `list`, `update` |
| **Docker/Podman** | Contenedores | `docker pull` podría exponerse bajo un provider que busque imagbalances. (Opcional) | `search`, `install` |

### Alcance Terminado (Lista Simbólica)
1. `winget` (Nativo MS)
2. `choco` (Chocolatey)
3. `scoop` (Scoop)
4. `vcpkg` (C++)
5. `pipx` (Python Tools)
6. `npm` (JS Global)
7. `yarn` (JS Global)
8. `dotnet tool` (.NET Global Tools)
9. `cargo` (Rust toolchains / via rustup)
10. `composer` (PHP)
11. `gem` (Ruby)

### Consideraciones Críticas:
- **npm/pipx/dotnet**: Sus búsquedas locales son muy limitadas. Pacwin podría mostrar un *warning* indicando que la búsqueda se realiza por **nombre exacto** (mono-match) en lugar de usar un motor fuzzy local.
- **vcpkg**: Requiere manejo de `triplet` (x64-windows, x86-windows, etc.). El `Provider` podría exponer triplet por defecto o implementar un `Prompt` interactivo si se usa explícitamente con `pacwin install <pkg> -Manager vcpkg --triplet x64-windows`.

---

## 6. Adaptación al Código Legacy (`pacwin.psm1`) sin Romper

La introducción del `Provider` no requiere una reescritura masiva. Sigue la estrategia:

### Paso 1: Isolar Dependencia Directa
Abstraer `$_pw_do_install`, `$_pw_search_all`, etc., para que en lugar de `switch` con strings codificados, utilicen el `Registry`:

```powershell
# LEGADO:
switch ($pkg.Manager) {
    "winget" { winget install --id $pkg.ID }
    "choco"  { choco install $pkg.ID -y     }
    "scoop"  { scoop install $pkg.ID       }
}

# REFACTOR SIN ROMPER:
function _pw_execute_provider_action($ProviderName, $Action, $Args) {
    # Si el registry existe, usa el modelo nuevo.
    if ($global:PacwinProviders -and $global:PacwinProviders.Registry.ContainsKey($ProviderName)) {
        return $global:PacwinProviders.InvokeCommand($Action, @($Args), $ProviderName)
    }
    # Fallback al código legacy si el provider no está registrado
    switch ($ProviderName) { ... }
}
```

### Paso 2: Convertir Parsers Existentes a Bloques de Script
Refactorizar `_pw_parse_winget_lines`, etc., en un `scriptblock` asignado al `Provider.Winget.Parser`. El código original se vuelve un `stub` que apunta al bloque reutilizable.

### Paso 3: Unificar Campo `Source`
Establecer un diccionario estándar `PacwinResult` que todos los `Parser` deben devolver para asegurar que `Pacwin.Renderer` y `Pacwin.Picker` nunca se rompan.

---

## 7. Puntos de Decisión Pendientes

1. **Prioridad de Proveedores**: ¿Qué pasa si dos `Providers` (ej. `choco` y `scoop`) devuelven el mismo paquete? `pacwin` actualmente usa heurísticas básicas. ¿Ampliamos `PacwinResult` con un campo `Priority` o utilizamos un algoritmo configurable?
2. **Configuración de Proveedores**: ¿Dónde se almacenan los archivos de registro de providers personalizados? Enumerar `$env:PACWIN_HOME/providers/*.ps1` es una opción segura.
3. **Métodos Async vs Sync**: Actualmente `pacwin` usa `RunspacePool` para mantener una UI reactiva. El `ProviderRegistry` debe ofrecer métodos de invocación que permitan la ejecución concurrente sin bloquear el hilo principal, integrando `InvokeCommandAsync`.
4. **Exclusión de Proveedores por defecto**: ¿Permitimos a los usuarios desactivar proveedores para evitar ruido? Podríamos extender la clase `PacwinProvider` con un campo `[bool]Enabled`.
5. **Soporte a NuGet/PSGallery**: Aunque no son gestores de paquetes tradicionales para aplicaciones, `pacwin` podría evolucionar a un meta-gestor de recursos. ¿Incluirlos con un alcance reducido o reservarlos para una v0.6.0+?

---

## 8. Conclusión

El modelo `Provider` convierte a **pacwin** de un wrapper monolítico a una **plataforma meta-gestora extensible**. Facilita agregar nuevos gestores sin tocar la lógica de concurrencia, UI ni búsqueda. La inversión inicial en esta arquitectura es relativamente baja (un refactorizado del `switch` principal y creación de dos nuevas clases), pero abre la puerta a integración con el ecosistema completo de herramientas de desarrollo en Windows.