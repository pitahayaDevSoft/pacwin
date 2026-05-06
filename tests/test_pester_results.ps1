# ============================================================
#  pacwin.psm1  —  Universal Package Layer for Windows
#  Abstraction over: winget | chocolatey | scoop
#  Compatible: PowerShell 5.1 + PowerShell 7+
#  v1.1.1
# ============================================================

Set-StrictMode -Off
# Retirado SilentlyContinue global para permitir debugging y reporte de errores real.
$ErrorActionPreference = "Continue"

#region ── Security & Validation ─────────────────────────────

function _pw_sanitize {
    param([string]$inputStr)
    if ([string]::IsNullOrWhiteSpace($inputStr)) { return "" }
    return $inputStr -replace "[^\w\.\-\+]", ""
}

#endregion

#region ── Helpers ──────────────────────────────────────────

function _pw_color {
    param(
        [string]$text,
        [string]$color = "White",
        [switch]$NoNewline
    )
    if ($NoNewline) {
        Write-Host $text -ForegroundColor $color -NoNewline
    }
    else {
        Write-Host $text -ForegroundColor $color
    }
}

function _pw_header {
    _pw_color ""
    _pw_color "  ╔══════════════════════════════════════╗" Cyan
    _pw_color "  ║   pacwin  —  universal pkg layer     ║" Cyan
    _pw_color "  ╚══════════════════════════════════════╝" Cyan
    _pw_color ""
}

function _pw_sep { _pw_color ("  " + ("─" * 68)) DarkGray }

# Resuelve ruta absoluta del ejecutable.
# Los jobs de PS5.1 no heredan PATH del proceso padre,
# así que necesitamos pasar el exe path explícitamente.
function _pw_exe {
    param([string]$name)
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

#endregion

#region ── Manager Detection ────────────────────────────────

function _pw_detect_managers {
    $m = [ordered]@{}
    $wingetExe = _pw_exe "winget"
    $chocoExe = _pw_exe "choco"
    $scoopExe = _pw_exe "scoop"
    if ($wingetExe) { $m["winget"] = $wingetExe }
    if ($chocoExe) { $m["choco"] = $chocoExe }
    if ($scoopExe) { $m["scoop"] = $scoopExe }
    return $m
}

function _pw_assert_managers {
    param($managers)
    if ($managers.Count -eq 0) {
        _pw_color "  [!] No se detectó ningún gestor de paquetes." Red
        _pw_color "      Instala winget, chocolatey o scoop para usar pacwin." Yellow
        return $false
    }
    return $true
}

function _pw_filter_manager {
    # Devuelve un sub-hash con solo el gestor pedido, o error
    param($managers, [string]$mgr)
    if (-not $mgr) { return $managers }
    if (-not $managers[$mgr]) {
        _pw_color "  [!] Gestor '$mgr' no disponible en este sistema." Red
        return $null
    }
    $sub = [ordered]@{}
    $sub[$mgr] = $managers[$mgr]
    return $sub
}

#endregion

#region ── Parsers ──────────────────────────────────────────

function _pw_parse_winget_lines {
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Buscar línea de header para calcular offsets exactos de columna
    $headerLine = $lines | Where-Object { $_ -match "^Name\s+Id\s+Version" } | Select-Object -First 1

    if (-not $headerLine) {
        # Fallback: split por ≥2 espacios
        foreach ($line in $lines) {
            if ($line -match "^\s*$|^-{3,}|^Name\s") { continue }
            $parts = ($line -split "\s{2,}").Where({ $_ -ne "" })
            if ($parts.Count -ge 2) {
                $results.Add([PSCustomObject]@{
                        Name    = $parts[0].Trim()
                        ID      = if ($parts.Count -ge 3) { $parts[1].Trim() } else { $parts[0].Trim() }
                        Version = if ($parts.Count -ge 3) { $parts[2].Trim() } else { $parts[1].Trim() }
                        Source  = "winget"
                        Manager = "winget"
                    })
            }
        }
        return $results
    }

    $nameOff = $headerLine.IndexOf("Name")
    $idOff = $headerLine.IndexOf("Id")
    $versionOff = $headerLine.IndexOf("Version")
    $sourceOff = $headerLine.IndexOf("Source")

    $dataStart = $false
    foreach ($line in $lines) {
        if ($line -match "^-{3,}") { $dataStart = $true; continue }
        if (-not $dataStart -or $line -match "^\s*$") { continue }
        $len = $line.Length
        if ($len -le $nameOff) { continue }

        try {
            $vEnd = if ($sourceOff -gt 0) { $sourceOff } else { $len }
            $name = $line.Substring($nameOff, [Math]::Min($idOff - $nameOff, $len - $nameOff)).Trim()
            $id = if ($len -gt $idOff) { $line.Substring($idOff, [Math]::Min($versionOff - $idOff, $len - $idOff)).Trim() } else { "" }
            $ver = if ($len -gt $versionOff) { $line.Substring($versionOff, [Math]::Min($vEnd - $versionOff, $len - $versionOff)).Trim() } else { "?" }
            if ($name -and $id) {
                $results.Add([PSCustomObject]@{
                        Name    = $name
                        ID      = $id
                        Version = if ($ver) { $ver } else { "?" }
                        Source  = "winget"
                        Manager = "winget"
                    })
            }
        }
        catch { continue }
    }
    return $results
}


function _pw_parse_choco_lines {
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($line in $lines) {
        $parts = $line -split "\|"
        if ($parts.Count -ge 2 -and $parts[0].Trim() -ne "") {
            $results.Add([PSCustomObject]@{
                    Name    = $parts[0].Trim()
                    ID      = $parts[0].Trim()
                    Version = $parts[1].Trim()
                    Source  = "chocolatey"
                    Manager = "choco"
                })
        }
    }
    return $results
}

function _pw_parse_scoop_lines {
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $inResults = $false
    foreach ($line in $lines) {
        if ($line -match "^Results from") { $inResults = $true; continue }
        if (-not $inResults -or $line -match "^\s*$|^-{3,}") { continue }

        # Formato moderno:  "  nombre (versión) [bucket]"
        if ($line -match "^\s+(\S+)\s+\(([^)]+)\)") {
            $results.Add([PSCustomObject]@{
                    Name = $Matches[1]; ID = $Matches[1]
                    Version = $Matches[2]; Source = "scoop"; Manager = "scoop"
                })
            continue
        }
        # Formato legacy: columnas por espacios múltiples
        $parts = ($line.Trim() -split "\s{2,}").Where({ $_ -ne "" })
        if ($parts.Count -ge 1 -and $parts[0] -notmatch "^[Nn]ame$|^Source$") {
            $results.Add([PSCustomObject]@{
                    Name = $parts[0]; ID = $parts[0]
                    Version = if ($parts.Count -ge 2) { $parts[1] } else { "?" }
                    Source = "scoop"; Manager = "scoop"
                })
        }
    }
    return $results
}

#endregion

#region ── Search Engine — Jobs con exePath explícito ────────

function _pw_search_all {
    param($managers, [string]$query, [int]$limit = 40)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $jobs = @{}

    if ($managers["winget"]) {
        $exe = $managers["winget"]
        $jobs["winget"] = Start-Job -ScriptBlock {
            param($exe, $q)
            try { & $exe search --query $q --accept-source-agreements 2>$null } catch { @() }
        } -ArgumentList $exe, $query
    }
    if ($managers["choco"]) {
        $exe = $managers["choco"]
        $jobs["choco"] = Start-Job -ScriptBlock {
            param($exe, $q)
            try { & $exe search $q --limit-output 2>$null } catch { @() }
        } -ArgumentList $exe, $query
    }
    if ($managers["scoop"]) {
        $exe = $managers["scoop"]
        $jobs["scoop"] = Start-Job -ScriptBlock {
            param($exe, $q)
            try { & $exe search $q 2>$null } catch { @() }
        } -ArgumentList $exe, $query
    }

    foreach ($key in $jobs.Keys) {
        $job = $jobs[$key]
        $finished = $job | Wait-Job -Timeout 25
        if ($finished) {
            $raw = Receive-Job $job -ErrorAction SilentlyContinue
            if ($raw -is [array]) {
                $lines = [System.Collections.Generic.List[string]]::new($raw.Count)
            } else {
                $lines = [System.Collections.Generic.List[string]]::new()
            }
            foreach ($r in $raw) { $lines.Add([string]$r) }
            switch ($key) {
                "winget" { $parsed = _pw_parse_winget_lines $lines }
                "choco" { $parsed = _pw_parse_choco_lines  $lines }
                "scoop" { $parsed = _pw_parse_scoop_lines  $lines }
            }
            foreach ($r in $parsed) { $results.Add($r) }
        }
        else {
            _pw_color "  [!] Timeout buscando en $key — omitiendo." DarkGray
            $job | Stop-Job
        }
        Remove-Job $job -Force
    }

    if ($results.Count -gt $limit) { return $results | Select-Object -First $limit }
    return $results
}

#endregion

#region ── Main Entry Point ─────────────────────────────────

function pacwin {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Command,

        [Parameter(Position = 1)]
        [string]$Query,

        [Parameter()]
        [ValidateSet("winget", "choco", "scoop")]
        [string]$Manager,

        [Parameter()]
        [int]$Limit = 40
    )

    _pw_header
    $managers = _pw_detect_managers
    if (-not (_pw_assert_managers $managers)) { return }

    $targetManagers = _pw_filter_manager $managers $Manager
    if (-not $targetManagers) { return }

    # Sanitizar query si existe
    if ($Query) {
        $Query = _pw_sanitize $Query
        if (-not $Query) { return }
    }

    switch -Regex ($Command) {
        "^(search|-S)$" {
            if (-not $Query) { _pw_color "  [!] Falta término de búsqueda." Yellow; return }
            _pw_color "  Buscando '$Query'..." Cyan
            $results = _pw_search_all $targetManagers $Query $Limit
            _pw_render_results $results $Query
        }

        "^(info|-Si)$" {
            if (-not $Query) { _pw_color "  [!] Falta nombre del paquete." Yellow; return }
            _pw_do_info $targetManagers $Query
        }

        "^(install|-S)$" {
            if (-not $Query) { _pw_color "  [!] Falta nombre del paquete." Yellow; return }
            _pw_color "  Buscando candidatos para '$Query'..." Cyan
            $results = _pw_search_all $targetManagers $Query $Limit
            
            if ($results.Count -eq 0) {
                _pw_color "  No se encontraron paquetes para '$Query'." Yellow
                return
            }

            $pkg = _pw_pick_source $results
            if ($pkg) { _pw_do_install $pkg }
        }

        "^(uninstall|-R)$" {
            if (-not $Query) { _pw_color "  [!] Falta nombre del paquete a desinstalar." Yellow; return }
            # Si no se especifica manager, preguntar? Por ahora requiere -Manager o usa el primero
            if (-not $Manager) {
                _pw_color "  [!] Especifica un gestor con -Manager (winget|choco|scoop)" Yellow
                return
            }
            _pw_do_uninstall $Query $Manager
        }

        "^(update|upgrade|-Syu)$" {
            if ($Query) {
                # Update específico (solo implementado en helpers básicos por ahora)
                _pw_color "  Actualización individual no implementada aún para todos los gestores." Yellow
            }
            else {
                _pw_do_update_all $targetManagers
            }
        }

        "^(outdated|-Qu)$" {
            _pw_do_outdated $targetManagers
        }

        "^(list|-Q)$" {
            _pw_do_list $targetManagers $Query
        }

        "^(status)$" {
            _pw_color "  Gestores detectados:" Cyan
            $managers.Keys | ForEach-Object {
                _pw_color "  • $_ " Cyan -NoNewline
                _pw_color "-> $($managers[$_])" DarkGray
            }
        }

        "^(help|--help|-h)$" {
            _pw_color "  Uso:" Yellow
            _pw_color "    pacwin search <query>      (o pacwin -S <query>)" White
            _pw_color "    pacwin install <query>     (o pacwin -S <query>)" White
            _pw_color "    pacwin uninstall <name>    (o pacwin -R <name>)" White
            _pw_color "    pacwin update              (o pacwin -Syu)" White
            _pw_color "    pacwin outdated            (o pacwin -Qu)" White
            _pw_color "    pacwin list [filtro]       (o pacwin -Q [filtro])" White
            _pw_color "    pacwin status" White
        }

        Default {
            _pw_color "  Comando '$Command' no reconocido. Usa 'pacwin help'." Yellow
        }
    }
}

#endregion
#region ── Renderer ─────────────────────────────────────────

$script:SRC_COLORS = @{
    "winget"     = "Cyan"
    "chocolatey" = "Yellow"
    "scoop"      = "Green"
}

function _pw_truncate {
    param([string]$str, [int]$max)
    if (-not $str) { return "".PadRight($max) }
    if ($str.Length -le $max) { return $str.PadRight($max) }
    return ($str.Substring(0, $max - 1) + "…")
}

function _pw_render_results {
    param([object]$results, [string]$query = "", [switch]$NoIndex)

    $arr = @($results)
    if ($arr.Count -eq 0) {
        if ($query) { _pw_color "  Sin resultados para '$query'." Yellow }
        return
    }

    _pw_color ""
    if (-not $NoIndex) {
        _pw_color ("  {0,-4} {1,-36} {2,-24} {3,-14} {4}" -f "#", "Nombre", "ID", "Versión", "Fuente") DarkGray
    }
    else {
        _pw_color ("  {0,-36} {1,-24} {2,-14} {3}" -f "Nombre", "ID", "Versión", "Fuente") DarkGray
    }
    _pw_sep

    $i = 1
    foreach ($r in $arr) {
        $col = if ($script:SRC_COLORS[$r.Source]) { $script:SRC_COLORS[$r.Source] } else { "White" }
        $name = _pw_truncate $r.Name 34
        $id = _pw_truncate $r.ID   22
        $ver = _pw_truncate $r.Version 12

        if (-not $NoIndex) {
            _pw_color ("  [{0,-2}] " -f $i) DarkGray -NoNewline
        }
        else {
            _pw_color "  " DarkGray -NoNewline
        }
        _pw_color ("{0,-36}{1,-24}{2,-14}" -f $name, $id, $ver) White -NoNewline
        _pw_color $r.Source $col
        $i++
    }
    _pw_color ""
}

#endregion

#region ── Operations ────────────────────────────────────────

function _pw_do_install {
    param([PSCustomObject]$pkg)
    _pw_color ""
    _pw_color "  → Instalando: $($pkg.Name)  [$($pkg.Source)  v$($pkg.Version)]" Cyan
    _pw_sep
    
    $output = @()
    switch ($pkg.Manager) {
        "winget" { $output = winget install --id $pkg.ID --accept-package-agreements --accept-source-agreements 2>&1 }
        "choco" { $output = choco install $pkg.ID -y 2>&1 }
        "scoop" { $output = scoop install $pkg.ID 2>&1 }
    }
    _pw_handle_result $pkg.Manager $LASTEXITCODE $output
}

function _pw_do_uninstall {
    param([string]$name, [string]$mgr)
    _pw_color ""
    _pw_color "  → Desinstalando '$name' con $mgr ..." Yellow
    _pw_sep
    
    $output = @()
    switch ($mgr) {
        "winget" { $output = winget uninstall --name $name 2>&1 }
        "choco" { $output = choco uninstall $name -y 2>&1 }
        "scoop" { $output = scoop uninstall $name 2>&1 }
    }
    _pw_handle_result $mgr $LASTEXITCODE $output
}

function _pw_do_update_all {
    param($managers)
    if ($managers["winget"]) {
        _pw_color "  ── winget ─────────────────────────────" Cyan
        winget upgrade --all --accept-package-agreements --accept-source-agreements
    }
    if ($managers["choco"]) {
        _pw_color "  ── chocolatey ─────────────────────────" Yellow
        choco upgrade all -y
    }
    if ($managers["scoop"]) {
        _pw_color "  ── scoop ──────────────────────────────" Green
        scoop update *
    }
}

function _pw_do_outdated {
    param($managers)
    if ($managers["winget"]) {
        _pw_color "  ── winget ─────────────────────────────" Cyan
        winget upgrade --accept-source-agreements 2>$null
    }
    if ($managers["choco"]) {
        _pw_color "  ── chocolatey ─────────────────────────" Yellow
        choco outdated 2>$null
    }
    if ($managers["scoop"]) {
        _pw_color "  ── scoop ──────────────────────────────" Green
        scoop status 2>$null
    }
}

function _pw_do_list {
    param($managers, [string]$filter)
    
    _pw_color "  Listando paquetes instalados..." Cyan
    if ($filter) { _pw_color "  (Filtro: '$filter')" DarkGray }

    if ($managers["winget"]) {
        _pw_color "  ── winget ─────────────────────────────" Cyan
        if ($filter) { winget list --query $filter } else { winget list }
    }
    if ($managers["choco"]) {
        _pw_color "  ── chocolatey ─────────────────────────" Yellow
        if ($filter) { choco list -l $filter } else { choco list -l }
    }
    if ($managers["scoop"]) {
        _pw_color "  ── scoop ──────────────────────────────" Green
        if ($filter) { scoop list $filter } else { scoop list }
    }
}

function _pw_do_info {
    param($managers, [string]$name)
    
    _pw_color "  Obteniendo información de '$name'..." Cyan

    if ($managers["winget"]) {
        _pw_color "  ── winget ─────────────────────────────" Cyan
        winget show --id $name --accept-source-agreements
    }
    if ($managers["choco"]) {
        _pw_color "  ── chocolatey ─────────────────────────" Yellow
        choco info $name
    }
    if ($managers["scoop"]) {
        _pw_color "  ── scoop ──────────────────────────────" Green
        scoop info $name
    }
}

function _pw_handle_result {
    param(
        [string]$manager,
        [int]$exitCode,
        [string[]]$output
    )

    $outputText = $output -join "`n"
    $success = $false
    $msg = ""

    # Lógica específica por gestor
    switch ($manager) {
        "winget" {
            if ($exitCode -eq 0) { $success = $true }
            elseif ($exitCode -eq -1978335186) { $msg = "Requiere reinicio para completar." } # 0x8A15002E
            else { $msg = "Error de Winget (Código: $exitCode)." }
        }
        "choco" {
            if ($exitCode -eq 0 -or $exitCode -eq 1641 -or $exitCode -eq 3010) { 
                $success = $true 
                if ($exitCode -ne 0) { $msg = "Éxito (Requiere reinicio)." }
            }
            else { $msg = "Error de Chocolatey (Código: $exitCode)." }
        }
        "scoop" {
            # Scoop es poco fiable con exitCode, validamos texto
            if ($outputText -match "installed successfully|already installed") {
                $success = $true
            }
            elseif ($outputText -match "Couldn't find manifest|Access denied") {
                $success = $false
                $msg = "Error de Scoop: " + ($output | Select-String "Error:" | Select-Object -First 1)
            }
            else {
                $success = ($exitCode -eq 0)
            }
        }
    }

    if ($success) {
        _pw_color "  [OK] Operación completada con éxito. $msg" Green
    }
    else {
        _pw_color "  [FALLO] La operación no pudo completarse." Red
        if ($msg) { _pw_color "  Detalle: $msg" Yellow }
        else { _pw_color "  Revisa la salida anterior para más detalles." DarkGray }
    }
}

#endregion

#region ── Source Picker ────────────────────────────────────

function _pw_pick_source {
    param([object]$candidates)
    $arr = @($candidates)
    if ($arr.Count -eq 1) { return $arr[0] }

    _pw_color "  Paquete disponible en múltiples fuentes — elige una:" Yellow
    _pw_render_results $arr

    $choice = Read-Host "  Fuente (número, Enter=cancelar)"
    if ([string]::IsNullOrWhiteSpace($choice)) { return $null }

    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $arr.Count) {
        _pw_color "  Selección inválida." Red; return $null
    }
    return $arr[$idx - 1]
}

#endregion

