# Plan Maestro de Mejora de Calidad de Código — pacwin

Documento generado: `2026-06-08`  
Versión objetivo: `v0.5.0`

---

## Resumen Ejecutivo

Este plan maestro detalla la implementación estructurada de las mejoras de calidad de código identificadas en la auditoría del módulo PowerShell **pacwin**. El plan está organizado en 5 fases que priorizan la estabilidad, la legibilidad y la mantenibilidad del código, sin romper la compatibilidad existente con PowerShell 5.1 y 7+.

---

## Fase 1: Cimientos (Foundation) — Semana 1

### 1.1 Extraer constantes UI y formateo

**Racional**: Eliminar números mágicos y valores hardcodeados, facilitar mantenimiento y temas futuros.

**Archivos a crear/modificar**:
- `config/themes/pitahaya.ps1` (nuevo): Paleta de colores y dimensiones UI
- Modificar `pacwin.psm1`: Importar y usar las constantes

**Entregable**:
```powershell
# themes/pitahaya.ps1 (ejemplo temático)
$script:THEME = @{
    Primary   = "Red"      # #FF2400 → ANSI Red
    Secondary = "Green"    # #2E8B57 → ANSI Green
    Success   = "Green"
    Warning   = "Yellow"
    Danger    = "Red"
    Dim       = "DarkGray"
    Version   = "0.5.0"

    Layout = @{
        TitleWidth = 68
        MinWidth   = 80
        Separator  = "━" * 68
        Spinner    = "|/-\"
        ColWidths  = @{
            Name    = 0.5  # Porcentaje del ancho disponible
            ID      = 0.3
            Version = 0.2
        }
    }
}
```

### 1.2 Unificar manejo de errores

**Racional**: Inconsistencias entre managers generan confusión. Un solo punto de reporte de errores.

**Archivos a crear**:
- `internal/helpers/ErrorHandler.ps1` — Función `_pw_handle_error` unificada

**Entregable**:
```powershell
function _pw_handle_error {
    param(
        [string]$Manager,
        [int]$ExitCode,
        [string]$Message,
        [string[]]$Output
    )
    $mapping = $script:ErrorCodes[$Manager]
    $msg = if ($mapping.Contains($ExitCode.ToString())) { $mapping[$ExitCode.ToString()] } else { $Message }
    return [PSCustomObject]@{
        Manager  = $Manager
        Success  = $ExitCode -eq 0
        Code     = $ExitCode
        Message  = $msg
        Output   = $Output
    }
}
```

### 1.3 Cachear binarios detectados

**Racional**: `_pw_exe` se llama múltiples veces sin necesidad.

**Entregable**:
```powershell
$script:BinaryCache = @{}
function _pw_exe_cached {
    param([string]$name)
    if (-not $script:BinaryCache.ContainsKey($name)) {
        $script:BinaryCache[$name] = _pw_exe $name
    }
    return $script:BinaryCache[$name]
}
```

---

## Fase 2: Documentación — Semana 2

### 2.1 Añadir comment-based help a todas las funciones

**Racional**: PowerShell genera `Get-Help` automáticamente. Cada función pública/compleja debe tenerlo.

**Patrón a aplicar**:
```powershell
<#
.SYNOPSIS
    Sanitizes user input for safe shell execution.

.DESCRIPTION
    Removes potentially dangerous characters from user input to prevent
    command injection. Preserves alphanumeric characters, dots, hyphens, and plus signs.

.PARAMETER inputStr
    The string to sanitize.

.OUTPUTS
    System.String
    The sanitized string, or empty if input is null/whitespace.

.EXAMPLE
    _pw_sanitize "google chrome"
    Returns: "googlechrome"
#>
function _pw_sanitize { ... }
```

### 2.2 Documentar parsers con ejemplos de formato

**Racional**: Los parsers dependen de formatos cambiantes de winget/choco/scoop. Documentar qué produce cada manager.

**Entregable** (ejemplo para `_pw_parse_winget_lines`):
```powershell
<#
.DESCRIPTION
    Parses winget table output. Supports three separator variants:

    1. Segmented dashes: "--- ---- -----" (most reliable)
    2. Single long separator: "----------------"
    3. No separator: Heuristic whitespace split (fallback)

    NOTE: Winget uses localized headers, so we avoid parsing header text.
#>
```

---

## Fase 3: Refactorización — Semana 3-4

### 3.1 Descomponer `_pw_parse_winget_lines`

**Racional**: ~100 líneas con lógica anidada compleja. Separar en helpers específicos.

**Estructura propuesta**:
```
_pw_parse_winget_lines (entry point)
├── _pw_find_winget_separator        # Detecta tipo de separador
├── _pw_extract_offsets_from_dashes  # Calcula columnas
├── _pw_extract_offsets_from_header  # Fallback sin separador
└── _pw_winget_row_to_object         # Convierte línea a PSCustomObject
```

### 3.2 Decomposition del dispatcher `pacwin` (pattern Command)

**Racional**: `switch -Regex` actual es monolítico y difícil de testear. Reemplazar con tabla de comandos.

**Estrategia**:
```powershell
$CommandMap = @{
    'search'  = { param($ctx) _pw_cmd_search @ctx }
    'install' = { param($ctx) _pw_cmd_install @ctx }
    'update'  = { param($ctx) _pw_cmd_update @ctx }
    # ... etc
}

# En pacwin:
$cmdBlock = $CommandMap[$normalizedCmd]
if ($cmdBlock) {
    & $cmdBlock @{ managers=$targetManagers; query=$Query; ... }
}
```

### 3.3 Extraer lógica de concurrencia

**Racional**: El manejo de RunspacePool es complejo y mezclado con UI.

**Archivo nuevo**: `internal/helpers/Concurrency.ps1`
- `New-PwTaskPool` — Crea pool de runspaces
- `Wait-PwTaskPool` — Espera con spinner
- `Receive-PwTaskPool` — Colecta resultados

---

## Fase 4: Testing — Semana 5

### 4.1 Añadir integration tests

**Escenarios a cubrir**:
- Manager no detectado → falla con mensaje claro
- Timeout de búsqueda → resultados parciales
- Input vacío → manejo sin excepción
- Self-update con respuesta HTTP 404
- Export/import roundtrip

### 4.2 Tests de edge cases para parsers

**Nuevos casos**:
```powershell
# Parser winget con columnas truncadas
It "Handles truncated winget output gracefully"
# Scoop sin privilegios
It "Handles scoop bucket permission errors"
# Choco con caracteres unicode en nombre
It "Handles unicode package names in choco"
```

---

## Fase 5: Optimización — Semana 6

### 5.1 Precompilación de regex

**Racional**: Los parsers usan `$regex.Matches()` repetidamente sin caching.

**Entregable**:
```powershell
$script:WingetProgressRegex = [regex]::new('^\d+%\s*\[', [System.Text.RegularExpressions.RegexOptions]::Compiled)
# Usar en lugar de -match inline
```

### 5.2 Reducir alocación de objetos en hot paths

**Racional**: `$results.Add()` en bucles grandes crea presión en GC.

**Mejoras**:
- Reusar `List<T>` donde sea posible
- Usar `[ref]` para retornos en lugar de objetos intermedios
- Considerar `[PSTypeName('PacwinResult')]` para type safety

---

## Orden de Prioridad Sugerido

| Fase | Prioridad | Impacto | Riesgo de Regresión |
|------|-----------|---------|---------------------|
| 1.1 Constantes UI | Alta | Medio | Bajo |
| 1.2 Unificación errores | Alta | Alto | Medio |
| 1.3 Cache binarios | Baja | Medio | Bajo |
| 2.1 Comment-help | Media | Bajo | Nulo |
| 3.1 Parser refactor | Alta | Alto | Alto |
| 3.2 Command pattern | Media | Medio | Alto |
| 3.3 Concurrencia | Baja | Medio | Alto |
| 4.1 Integration tests | Media | Alto | Nulo |
| 5.1 Regex compilados | Baja | Medio | Bajo |

---

## Archivos del Plan (Checklist Detallada)

### Nuevos archivos:
- [x] `themes/default.ps1` → Paleta y constantes visual
- [x] `internal/helpers/ErrorHandler.ps1` → Manejo centralizado
- [x] `internal/helpers/Concurrency.ps1` → Patrón RunspacePool
- [x] `internal/commands/*.ps1` → Cada comando como módulo separado
- [x] `docs/architecture/commands.md` → Documentación técnica

### Modificaciones `pacwin.psm1`:
- [x] Extraer `$script:ErrorCodes` → `ErrorHandler.ps1`
- [x] Extraer colores → `themes/default.ps1`
- [x] Refactorizar `_pw_parse_winget_lines` (dividir en helpers)
- [x] Refactorizar switch de `pacwin` → Command pattern
- [x] Unificar `_pw_handle_result` with `ErrorHandler`

### Fase 4: Testing
- [x] Integración de integration tests (Fase 4.1)
- [x] Casos de prueba de edge cases para parsers (Fase 4.2)

### Fase 5: Optimización
- [x] Precompilación de regex (Fase 5.1)
- [x] Reducir alocación de objetos en hot paths (Fase 5.2)

---

## Notas de Implementación

1. **Compatibilidad**: Todas las fases mantienen compatibilidad con PowerShell 5.1 y 7+.
2. **Tests existentes**: Ejecutar `Invoke-Pester` antes y después de cada fase para verificar que no se rompan tests actuales.
3. **Rollback plan**: Si un refactoring introduce regresión, hacer revert inmediato y documentar el problema.
4. **Documentación**: Actualizar `CHANGELOG.md` y `README.md` al completar cada fase.
