# ============================================================
#  pacwin.psm1  -  Universal Package Layer for Windows
#  Abstraction over: winget | chocolatey | scoop
#  Compatible: PowerShell 5.1 + PowerShell 7+
#  v0.6.0 (Refactoring & Concurrency Rebrand)
# ============================================================

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Continue"

# Force UTF8 for better character rendering in PS 5.1
if ($PSVersionTable.PSVersion.Major -lt 6)
{
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}

# Resolve script root folder for dot-sourcing helper files
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = $PWD.Path }

# Fallback theme in case file is missing
$script:THEME = @{
    Primary   = "Red"
    Secondary = "Green"
    Success   = "Green"
    Warning   = "Yellow"
    Danger    = "Red"
    Dim       = "DarkGray"
    Version   = "0.6.0"

    Layout = @{
        TitleWidth = 68
        MinWidth   = 80
        Separator  = "━" * 68
        Spinner    = "|/-\"
        ColWidths  = @{
            Name    = 0.5
            ID      = 0.3
            Version = 0.2
        }
    }
}

# Load Theme configuration
$themePath = Join-Path $scriptDir "config/themes/default.ps1"
if (Test-Path $themePath) {
    . $themePath
}

# Load Centralized Error Handler
$errorHandlerPath = Join-Path $scriptDir "internal/helpers/ErrorHandler.ps1"
if (Test-Path $errorHandlerPath) {
    . $errorHandlerPath
}

# Load Concurrency Helper
$concurrencyPath = Join-Path $scriptDir "internal/helpers/Concurrency.ps1"
if (Test-Path $concurrencyPath) {
    . $concurrencyPath
}

# Precompiled Regexes for Performance (Fase 5.1)
$script:RegexPathValidate            = [regex]::new('^[a-zA-Z0-9\._\-@/\\:]+$', 'Compiled')
$script:RegexWingetSkip               = [regex]::new('^\s*$|^-|^[^\x00-\x7F]|%|[\d.]+\s+[KMG]B\s*/', 'Compiled')
$script:RegexWingetFallbackSkip       = [regex]::new('^\s*$|^-{3,}|[^\x00-\x7F]|%|[\d.]+\s+[KMG]B\s*/', 'Compiled')
$script:RegexScoopSkip                = [regex]::new('^\s*[-=]{3,}\s*$', 'Compiled')
$script:RegexScoopHeaderSkip          = [regex]::new('^\s*([Nn]ame\s+[Vv]ersion|[Nn]ombre\s+[Vv]ersi|^Results from)', 'Compiled')
$script:RegexScoopObject              = [regex]::new('^@{Name=([^;]+); Version=([^;]+); Source=([^;]+)', 'Compiled')
$script:RegexScoopParen               = [regex]::new('^\s*(\S+)\s+\(([^)]+)\)', 'Compiled')
$script:RegexScoopColumnSkip          = [regex]::new('^[Nn]ame$|^[Ss]ource$|^[Nn]ombre$|^[Oo]rigen$', 'Compiled')
$script:RegexScoopOutdatedSkip        = [regex]::new('^[-\s=]{3,}$', 'Compiled')
$script:RegexScoopOutdatedHeaderSkip  = [regex]::new('^\s*([Nn]ame\s+|^Results from|[Nn]ombre\s+)', 'Compiled')
$script:RegexScoopOutdatedArrow       = [regex]::new('^\s*(\S+)\s+\(([^)]+)\s*->\s*([^)]+)\)', 'Compiled')
$script:RegexScoopOutdatedNew         = [regex]::new('(\S+)\s+has\s+a\s+new\s+version', 'Compiled')
$script:RegexScoopOutdatedColon       = [regex]::new('^\s*(\S+)\s*:\s*(\S+)\s*->\s*(\S+)', 'Compiled')
$script:RegexScoopOutdatedSfsuSkip   = [regex]::new('^[Nn]ame|^[Cc]urrent|^[Aa]vailable|^[Nn]ombre', 'Compiled')


# Load Commands
$commandsDir = Join-Path $scriptDir "internal/commands"
if (Test-Path $commandsDir) {
    Get-ChildItem $commandsDir -Filter *.ps1 | ForEach-Object {
        . $_.FullName
    }
}

# Setup Command Dispatch Map
$script:CommandMap = [ordered]@{
    "^(search|-Ss)$"        = { param($ctx) _pw_cmd_search $ctx }
    "^(info|-Si)$"          = { param($ctx) _pw_cmd_info $ctx }
    "^(install|-S)$"        = { param($ctx) _pw_cmd_install $ctx }
    "^(uninstall|-R)$"      = { param($ctx) _pw_cmd_uninstall $ctx }
    "^(update|upgrade|-Syu)$" = { param($ctx) _pw_cmd_update $ctx }
    "^(outdated|-Qu)$"      = { param($ctx) _pw_cmd_outdated $ctx }
    "^(list|-Q)$"           = { param($ctx) _pw_cmd_list $ctx }
    "^(export)$"            = { param($ctx) _pw_cmd_export $ctx }
    "^(import)$"            = { param($ctx) _pw_cmd_import $ctx }
    "^(pin|hold)$"          = { param($ctx) _pw_cmd_pin $ctx }
    "^(unpin|unhold)$"      = { param($ctx) _pw_cmd_unpin $ctx }
    "^(doctor|check)$"      = { param($ctx) _pw_cmd_doctor $ctx }
    "^(sync|dupes|dedup)$"  = { param($ctx) _pw_cmd_sync $ctx }
    "^(status)$"            = { param($ctx) _pw_cmd_status $ctx }
    "^(version|-V|--version|--version|-v)$" = { param($ctx) _pw_cmd_version $ctx }
    "^(self-update)$"       = { param($ctx) _pw_cmd_self_update $ctx }
    "^(help|--help|-h)$"    = { param($ctx) _pw_cmd_help $ctx }
}

# TROPICAL_UI :: BRAND_PITAHAYA (High-Energy industrial)
# Primary: Red (ANSI) / #FF2400
# Secondary: Green (ANSI) / #2E8B57
# Success: Green
# Warning: Yellow
# Danger: Red
# Dim: DarkGray

#region -- Security & Validation -----------------------------

<#
.SYNOPSIS
    Sanitizes user input strings for safe shell execution.
.DESCRIPTION
    Removes potentially dangerous shell command injection characters. 
    Only preserves alphanumeric characters, dots, hyphens, and plus signs.
.PARAMETER inputStr
    The raw string input to sanitize.
.OUTPUTS
    System.String
    The sanitized string, or an empty string if null or whitespace.
.EXAMPLE
    _pw_sanitize "google chrome; rm -rf /"
    Returns: "googlechrome"
#>
function _pw_sanitize
{
    param([string]$inputStr)
    if ([string]::IsNullOrWhiteSpace($inputStr))
    { return ""
    }
    return $inputStr -replace "[^\w\.\-\+]", ""
}

<#
.SYNOPSIS
    Validates filesystem paths against unsafe characters.
.DESCRIPTION
    Ensures file paths only contain safe characters to prevent directory traversal
    or parameter injection. Allowed characters: alphanumeric, dot, underscore, hyphen,
    at, forward/backward slashes, and colon.
.PARAMETER pathInput
    The raw file path input to validate.
.OUTPUTS
    System.String
    The validated path string, or null if validation fails.
.EXAMPLE
    _pw_validate_path "C:\Users\User\app-config.json"
#>
function _pw_validate_path
{
    # Validates file paths: allowed characters are \ / : . - _ a-z A-Z 0-9
    param([string]$pathInput)
    if (-not $pathInput)
    { return $null
    }
    if ($script:RegexPathValidate.IsMatch($pathInput))
    {
        return $pathInput
    }
    _pw_color "  [!] PATH_RISK: '$pathInput'" Red
    return $null
}

#endregion

#region -- Helpers ------------------------------------------

function _pw_color
{
    param(
        [string]$text,
        [string]$color = "White",
        [switch]$NoNewline
    )
    if ($NoNewline)
    {
        Write-Host $text -ForegroundColor $color -NoNewline
    } else
    {
        Write-Host $text -ForegroundColor $color
    }
}

function _pw_header
{
    param($managers)

    _pw_color ""
    _pw_color "      .---.      " $script:THEME.Primary -NoNewline; _pw_color "██████╗  █████╗  ██████╗██╗    ██╗██╗███╗   ██╗" $script:THEME.Dim
    _pw_color "     /     \     " $script:THEME.Primary -NoNewline; _pw_color "██╔══██╗██╔══██╗██╔════╝██║    ██║██║████╗  ██║" $script:THEME.Dim
    _pw_color "    |  ■  ■ |    " $script:THEME.Primary -NoNewline; _pw_color "██████╔╝███████║██║     ██║ █╗ ██║██║██╔██╗ ██║" $script:THEME.Dim
    _pw_color "    |       |    " $script:THEME.Primary -NoNewline; _pw_color "██╔═══╝ ██╔══██║██║     ██║███╗██║██║██║╚██╗██║" $script:THEME.Dim
    _pw_color "    'vvvvvvv'    " $script:THEME.Primary -NoNewline; _pw_color "██║     ██║  ██║╚██████╗╚███╔███╔╝██║██║ ╚████║" $script:THEME.Dim
    _pw_color "    '       '    " $script:THEME.Primary -NoNewline; _pw_color "╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝" $script:THEME.Dim
    _pw_color ""
    _pw_color "  [ pacwin.ps1 ] // Powered by: Tropical // BUILD: STABLE" $script:THEME.Dim
    _pw_color ""

    if ($null -ne $managers)
    {
        # TUI_STATUS_BAR (PITAHAYA_DENSE)
        _pw_color "  " -NoNewline
        $keys = "winget", "choco", "scoop"
        for ($i = 0; $i -lt $keys.Count; $i++)
        {
            $k = $keys[$i]
            $indicator = if ($managers[$k]) { "ONLINE" } else { "OFFLINE" }
            $color = if ($managers[$k]) { $script:THEME.Success } else { $script:THEME.Dim }

            _pw_color "┌ " $script:THEME.Dim -NoNewline
            _pw_color "$($k.ToUpper())" White -NoNewline
            _pw_color " ┐" $script:THEME.Dim -NoNewline
            _pw_color "─" $script:THEME.Dim -NoNewline
            _pw_color "[" $script:THEME.Dim -NoNewline
            _pw_color "$indicator" $color -NoNewline
            _pw_color "]" $script:THEME.Dim -NoNewline

            if ($i -lt $keys.Count - 1) { _pw_color "  " -NoNewline }
        }
        _pw_color "  //  " $script:THEME.Dim -NoNewline
        _pw_color "v$($script:THEME.Version)" $script:THEME.Primary -NoNewline
        _pw_color "  //  " $script:THEME.Dim -NoNewline
        _pw_color "ENV: WINDOWS_X64" $script:THEME.Dim
    }

    _pw_sep
}
function _pw_sep
{
    $w = try
    { $Host.UI.RawUI.WindowSize.Width - 4
    } catch
    { $script:THEME.Layout.TitleWidth
    }
    if ($w -lt 40)
    { $w = $script:THEME.Layout.TitleWidth
    }
    _pw_color ("  " + ([string]$script:THEME.Layout.Separator[0] * $w)) $script:THEME.Primary
}

function _pw_last_exit_code
{
    if (Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue)
    {
        return $global:LASTEXITCODE
    }
    return 0
}


function _pw_exe
{
    param([string]$name)
    # Use -CommandType to bypass functions/aliases (like sfsu hook)
    $cmd = Get-Command $name -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd)
    { return $cmd.Source
    }
    return $null
}

$script:BinaryCache = @{}
function _pw_exe_cached
{
    param([string]$name)
    if (-not $script:BinaryCache.ContainsKey($name))
    {
        $script:BinaryCache[$name] = _pw_exe $name
    }
    return $script:BinaryCache[$name]
}

function _pw_is_admin
{
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#endregion

#region -- Manager Detection --------------------------------

function _pw_detect_managers
{
    $m = [ordered]@{}
    $wingetExe = _pw_exe_cached "winget"
    $chocoExe = _pw_exe_cached "choco"
    $scoopExe = _pw_exe_cached "scoop"
    $sfsuExe = _pw_exe_cached "sfsu"

    if ($wingetExe)
    { $m["winget"] = $wingetExe
    }
    if ($chocoExe)
    { $m["choco"] = $chocoExe
    }
    if ($scoopExe)
    { $m["scoop"] = $scoopExe
    }
    if ($sfsuExe)
    { $m["sfsu"] = $sfsuExe
    }
    return $m
}

function _pw_assert_managers
{
    param($managers)
    if ($managers.Count -eq 0)
    {
        _pw_color "  [!] No package manager detected." Red
        _pw_color "      Install winget, chocolatey, or scoop to use pacwin." Yellow
        return $false
    }
    return $true
}

function _pw_filter_manager
{
    param($managers, [string]$mgr)
    if (-not $mgr)
    { return $managers
    }
    if (-not $managers[$mgr])
    {
        _pw_color "  [!] Manager '$mgr' not available on this system." Red
        return $null
    }
    $sub = [ordered]@{}
    $sub[$mgr] = $managers[$mgr]
    return $sub
}

#endregion

#region -- Parsers ------------------------------------------

<#
.SYNOPSIS
    Parses winget query and search output.
.DESCRIPTION
    Parses tabular winget output into structured objects. Supports three variants:
    1. Segmented dashes: "--- ---- -----" (standard & most robust)
    2. Single long dashes separator: "----------------"
    3. Separator-less: Fallback whitespace-heuristic splitting

    Avoids parsing column header text directly to maintain localization-safety.
.PARAMETER lines
    String array output captured from a winget execution.
.OUTPUTS
    System.Collections.Generic.List[PSCustomObject]
    A list of objects containing Name, ID, Version, Source, and Manager properties.
.EXAMPLE
    $results = _pw_parse_winget_lines $wingetSearchOutput
#>
function _pw_find_winget_separator
{
    param([string[]]$lines)
    return $lines | Where-Object { $_ -match "^-{5,}" } | Select-Object -First 1
}

function _pw_extract_offsets_from_dashes
{
    param([string]$separatorLine)
    $matches = [regex]::Matches($separatorLine, "-+")
    if ($matches.Count -lt 2) { return $null }

    $nameOff    = $matches[0].Index
    $nameLen    = $matches[0].Length
    $idOff      = $matches[1].Index
    $idLen      = $matches[1].Length
    $versionOff = if ($matches.Count -ge 3) { $matches[2].Index } else { -1 }
    $versionLen = if ($matches.Count -ge 3) { $matches[2].Length } else { -1 }
    $sourceOff  = if ($matches.Count -ge 4) { $matches[3].Index } else { -1 }

    return @{
        nameOff    = $nameOff
        nameLen    = $nameLen
        idOff      = $idOff
        idLen      = $idLen
        versionOff = $versionOff
        versionLen = $versionLen
        sourceOff  = $sourceOff
    }
}

function _pw_extract_offsets_from_header
{
    param([string[]]$lines, [string]$separatorLine)
    $sepIdx = [array]::IndexOf($lines, $separatorLine)
    if ($sepIdx -le 0) { return $null }

    $headerLine = $lines[$sepIdx - 1]
    $parts = [regex]::Matches($headerLine, "\S+")
    if ($parts.Count -lt 2) { return $null }

    $nameOff = $parts[0].Index
    $idOff = $parts[1].Index
    $versionOff = if ($parts.Count -ge 3) { $parts[2].Index } else { -1 }
    $sourceOff = if ($parts.Count -ge 4) { $parts[3].Index } else { -1 }

    $nameLen = $idOff - $nameOff
    $idLen = if ($versionOff -gt 0) { $versionOff - $idOff } else { 100 }
    $versionLen = if ($sourceOff -gt 0) { $sourceOff - $versionOff } else { 100 }

    return @{
        nameOff    = $nameOff
        nameLen    = $nameLen
        idOff      = $idOff
        idLen      = $idLen
        versionOff = $versionOff
        versionLen = $versionLen
        sourceOff  = $sourceOff
    }
}

function _pw_winget_row_to_object
{
    param([string]$line, [hashtable]$offsets)

    $name = _pw_extract_column $line $offsets.nameOff $offsets.nameLen $null
    $id   = _pw_extract_column $line $offsets.idOff   $offsets.idLen   $null

    if (-not $name -or -not $id)
    { return $null
    }

    $versionOff = $offsets.versionOff
    $sourceOff  = $offsets.sourceOff
    $versionLen = $offsets.versionLen

    $vLen = if ($sourceOff -gt $versionOff -and $versionOff -gt 0)
    { $sourceOff - $versionOff
    } else
    { $versionLen
    }
    $ver  = _pw_extract_column $line $versionOff $vLen "?"

    return [PSCustomObject]@{
        Name    = $name
        ID      = $id
        Version = $ver
        Source  = "winget"
        Manager = "winget"
    }
}

function _pw_parse_winget_lines
{
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. Identify the header/separator structure
    $separatorLine = _pw_find_winget_separator $lines

    if (-not $separatorLine)
    {
        # Fallback: Heuristic split if no separator is found
        foreach ($line in $lines)
        {
            # Skip progress bars, empty lines, and header-like lines
            if ($script:RegexWingetFallbackSkip.IsMatch($line)) { continue }
            $parts = ($line.Trim() -split "\s{2,}").Where({ $_ -ne "" })
            if ($parts.Count -lt 2) { continue }

            $id = if ($parts.Count -ge 3) { $parts[1].Trim() } else { $parts[0].Trim() }
            $version = if ($parts.Count -ge 3) { $parts[2].Trim() } else { $parts[1].Trim() }

            $results.Add([PSCustomObject]@{
                Name    = $parts[0].Trim()
                ID      = $id
                Version = $version
                Source  = "winget"
                Manager = "winget"
            })
        }
        return $results
    }

    # 2. Extract offsets
    $offsets = _pw_extract_offsets_from_dashes $separatorLine
    if (-not $offsets)
    {
        $offsets = _pw_extract_offsets_from_header $lines $separatorLine
    }

    if (-not $offsets)
    {
        return $results
    }

    # 3. Parse data lines
    $dataStart = $false
    foreach ($line in $lines)
    {
        if ($line -eq $separatorLine)
        {
            $dataStart = $true
            continue
        }
        if (-not $dataStart -or $script:RegexWingetSkip.IsMatch($line))
        {
            continue
        }

        $obj = _pw_winget_row_to_object $line $offsets
        if ($obj)
        {
            $results.Add($obj)
        }
    }

    return ,$results
}

<#
.SYNOPSIS
    Parses Chocolatey pipe-delimited output.
.DESCRIPTION
    Parses Chocolatey search output when executed with `--limit-output`.
    Expects lines in the standard pipe format 'name|version'.
.PARAMETER lines
    String array output captured from a choco search command.
.OUTPUTS
    System.Collections.Generic.List[PSCustomObject]
.EXAMPLE
    $results = _pw_parse_choco_lines $chocoOutput
#>
function _pw_parse_choco_lines
{
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($line in $lines)
    {
        $parts = $line -split "\|"
        if ($parts.Count -ge 2 -and $parts[0].Trim() -ne "")
        {
            $results.Add([PSCustomObject]@{
                    Name    = $parts[0].Trim()
                    ID      = $parts[0].Trim()
                    Version = $parts[1].Trim()
                    Source  = "chocolatey"
                    Manager = "choco"
                })
        }
    }
    return ,$results
}

<#
.SYNOPSIS
    Parses Scoop search and list outputs.
.DESCRIPTION
    Parses output from Scoop search or list commands. Handles three formatting formats:
    1. Serialization syntax: '@{Name=...; Version=...; Source=...}'
    2. Parenthesis versioning: 'name (version) [source]' or 'name (version)'
    3. Columnar table style: 'Name Version Source'
.PARAMETER lines
    String array output captured from a scoop execution.
.OUTPUTS
    System.Collections.Generic.List[PSCustomObject]
.EXAMPLE
    $results = _pw_parse_scoop_lines $scoopOutput
#>
function _pw_parse_scoop_lines
{
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($line in $lines)
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Skip headers or separators (supports multi-language)
        if ($script:RegexScoopSkip.IsMatch($line) -or $script:RegexScoopHeaderSkip.IsMatch($line))
        {
            continue
        }

        # If we get a line that looks like a PSCustomObject string representation, try to handle it
        $mObj = $script:RegexScoopObject.Match($line)
        if ($mObj.Success)
        {
            $nameVal = $mObj.Groups[1].Value.Trim()
            $results.Add([PSCustomObject]@{
                    Name = $nameVal; ID = $nameVal
                    Version = $mObj.Groups[2].Value.Trim(); Source = "scoop"; Manager = "scoop"
                })
            continue
        }

        # Handle 'name (version) [source]' or 'name (version)' format
        $mParen = $script:RegexScoopParen.Match($line)
        if ($mParen.Success)
        {
            $nameVal = $mParen.Groups[1].Value
            $results.Add([PSCustomObject]@{
                    Name = $nameVal; ID = $nameVal
                    Version = $mParen.Groups[2].Value; Source = "scoop"; Manager = "scoop"
                })
            continue
        }

        # Handle columnar format: Name  Version  Source
        $parts = ($line.Trim() -split "\s{2,}").Where({ $_ -ne "" })
        if ($parts.Count -eq 0 -or $script:RegexScoopColumnSkip.IsMatch($parts[0]))
        { continue
        }

        $version = if ($parts.Count -ge 2) { $parts[1] } else { "?" }

        $results.Add([PSCustomObject]@{
                Name    = $parts[0]
                ID      = $parts[0]
                Version = $version
                Source  = "scoop"
                Manager = "scoop"
            })
    }
    return ,$results
}

<#
.SYNOPSIS
    Parses Scoop status or outdated app listings.
.DESCRIPTION
    Parses Scoop outdated results, matching four distinct output signatures:
    1. Parenthesized arrow: 'neovim (0.9.4 -> 0.9.5)'
    2. English notification text: 'neovim has a new version'
    3. Colon arrow: 'neovim: 0.9.4 -> 0.9.5'
    4. Tabular format (scoop status / sfsu outdated): 'Name Current Available'
.PARAMETER lines
    String array output from scoop status or sfsu outdated commands.
.OUTPUTS
    System.Collections.Generic.List[PSCustomObject]
.EXAMPLE
    $results = _pw_parse_scoop_outdated_lines $scoopStatusOutput
#>
function _pw_parse_scoop_outdated_lines
{
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($line in $lines)
    {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Skip headers and table separators (supports multi-language)
        if ($script:RegexScoopOutdatedSkip.IsMatch($line) -or $script:RegexScoopOutdatedHeaderSkip.IsMatch($line))
        { continue }

        # Format 1: "neovim (0.9.4 -> 0.9.5)"
        $mArrow = $script:RegexScoopOutdatedArrow.Match($line)
        if ($mArrow.Success)
        {
            $nameVal = $mArrow.Groups[1].Value
            $results.Add([PSCustomObject]@{
                Name    = $nameVal
                ID      = $nameVal
                Version = $mArrow.Groups[3].Value  # The new version
                Source  = "scoop"
                Manager = "scoop"
            })
            continue
        }

        # Format 2: "neovim has a new version" (English classic)
        $mNew = $script:RegexScoopOutdatedNew.Match($line)
        if ($mNew.Success)
        {
            $nameVal = $mNew.Groups[1].Value
            $results.Add([PSCustomObject]@{
                Name    = $nameVal
                ID      = $nameVal
                Version = "Later"
                Source  = "scoop"
                Manager = "scoop"
            })
            continue
        }

        # Format 3: "neovim: 0.9.4 -> 0.9.5"
        $mColon = $script:RegexScoopOutdatedColon.Match($line)
        if ($mColon.Success)
        {
            $nameVal = $mColon.Groups[1].Value
            $results.Add([PSCustomObject]@{
                Name    = $nameVal
                ID      = $nameVal
                Version = $mColon.Groups[3].Value
                Source  = "scoop"
                Manager = "scoop"
            })
            continue
        }

        # Format 4: Columnar format of 'sfsu outdated' or 'scoop status' table:
        # Name      Current      Available
        # ----      -------      ---------
        # neovim    0.9.4        0.9.5
        $parts = ($line.Trim() -split "\s{2,}").Where({ $_ -ne "" })
        if ($parts.Count -ge 2 -and -not $script:RegexScoopOutdatedSfsuSkip.IsMatch($parts[0]))
        {
            $newVer = if ($parts.Count -ge 3) { $parts[2] } else { $parts[1] }
            $results.Add([PSCustomObject]@{
                Name    = $parts[0]
                ID      = $parts[0]
                Version = $newVer
                Source  = "scoop"
                Manager = "scoop"
            })
        }
    }
    return ,$results
}

#endregion

#region -- Search Engine ------------------------------------

function _pw_get_search_scripts
{
    param($managers)
    $scripts = [ordered]@{}

    if ($managers["winget"])
    {
        $scripts["winget"] = {
            param($exe, $q)
            try
            {
                # Run search and capture both success and error streams
                $out = & $exe search --query $q --accept-source-agreements 2>&1
                return $out
            } catch
            {
                return @()
            }
        }
    }
    if ($managers["choco"])
    {
        $scripts["choco"] = {
            param($exe, $q)
            try
            {
                $out = & $exe search $q --limit-output 2>&1
                return $out
            } catch
            {
                return @()
            }
        }
    }
    if ($managers["scoop"])
    {
        $scripts["scoop"] = {
            param($exe, $q)
            try
            {
                # Check if sfsu is available for ultra-fast scoop search
                $sfsu = Get-Command sfsu -ErrorAction SilentlyContinue
                if ($sfsu)
                {
                    $out = & $sfsu.Source search $q 2>&1
                    return $out
                }
                $out = & $exe search $q 2>&1
                return $out
            } catch
            {
                return @()
            }
        }
    }
    return $scripts
}

function _pw_search_all
{
    param($managers, [string]$query, [int]$limit = 40, [int]$timeoutSeconds = 35)

    $scripts = _pw_get_search_scripts -managers $managers
    $poolCtx = New-PwTaskPool -Scripts $scripts -Managers $managers -Query $query

    Wait-PwTaskPool -PoolContext $poolCtx -TimeoutSeconds $timeoutSeconds

    $results = Receive-PwTaskPool -PoolContext $poolCtx

    if ($null -ne $results -and $results.Count -gt $limit)
    { return $results | Select-Object -First $limit
    }
    return $results
}

#endregion

#region -- Main Entry Point ---------------------------------

function _pw_parse_args
{
    param(
        [string]$Command,
        [string]$Query,
        [string[]]$Unbound
    )

    $allArgs = New-Object System.Collections.Generic.List[string]
    if ($Command)
    { [void]$allArgs.Add($Command)
    }
    if ($Query)
    { [void]$allArgs.Add($Query)
    }
    if ($Unbound)
    { foreach ($a in $Unbound)
        { [void]$allArgs.Add($a)
        }
    }

    if ($allArgs.Count -gt 0)
    {
        $flagIdx = -1
        $flagRegex = "^-(S|Ss|R|Q|Qu|Syu|Si|V|h|v)$|^--(help|version)$"

        for ($i = 0; $i -lt $allArgs.Count; $i++)
        {
            if ($allArgs[$i] -match $flagRegex)
            {
                $flagIdx = $i
                break
            }
        }

        if ($flagIdx -ne -1)
        {
            $foundFlag = $allArgs[$flagIdx]
            $allArgs.RemoveAt($flagIdx)
            $Command = $foundFlag
            $Query = if ($allArgs.Count -gt 0)
            { $allArgs[0]
            } else
            { $null
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Command))
    { $Command = "help"
    }

    return [PSCustomObject]@{
        Command = $Command
        Query   = $Query
    }
}

function _pw_check_admin_requirements
{
    param(
        [hashtable]$managers,
        [string]$Manager,
        [string]$Command
    )

    if (-not (_pw_is_admin))
    {
        if ($Manager -eq "choco" -or ($null -eq $Manager -and $managers["choco"]))
        {
            if ($Command -match "^(install|uninstall|update|upgrade|import|pin|unpin|hold|unhold|-S|-R|-Syu)")
            {
                _pw_color "  [!] Warning: You are running as a standard user." Yellow
                _pw_color "      Chocolatey (choco) usually requires Administrator privileges to perform this action." Yellow
                _pw_color ""
            }
        }
    }
}

function _pw_show_help
{
    _pw_color "  Core Commands" Cyan
    _pw_color "    search <q>        Find packages, pick # to install (-Ss)" White
    _pw_color "    search <q> -ni   Non-interactive: just list results" White
    _pw_color "    install <id>      Search and install a package (-S)" White
    _pw_color ""
    _pw_color "  Maintenance" Cyan
    _pw_color "    update [id]       Upgrade one or all packages (-Syu)" White
    _pw_color "    outdated          Show packages with newer versions (-Qu)" White
    _pw_color "    doctor            Check environment health" White
    _pw_color ""
    _pw_color "  Management" Cyan
    _pw_color "    list [filter]     Show installed packages (-Q)" White
    _pw_color "    hold [id]         Pin/unpin versions (prevents updates)" White
    _pw_color "    sync              Detect and fix duplicate installs" White
    _pw_color ""
    _pw_color "  System" Cyan
    _pw_color "    status            Show manager paths" White
    _pw_color "    self-update       Update pacwin script to latest" White
    _pw_color "    help              Show this menu" White
    _pw_color ""
    _pw_color "  Example:" Gray
    _pw_color "    pacwin search nodejs" White
}

function _pw_handle_update
{
    param(
        [hashtable]$targetManagers,
        [string]$Query,
        [string]$Manager
    )

    if (-not $Query)
    {
        _pw_do_update_all $targetManagers
        return
    }

    _pw_color "  Looking for update candidates for '$Query'..." Cyan
    if ($Manager)
    {
        _pw_do_update_single $Query $Manager
        return
    }

    _pw_color "  Searching in outdated packages..." Gray
    $outdated = _pw_do_outdated $targetManagers -Silent
    $targetMatches = @(@($outdated).Where({ $_.ID -eq $Query -or $_.Name -eq $Query }))

    if ($targetMatches.Count -eq 0)
    {
        _pw_color "  No outdated package found matching '$Query'. Trying direct update..." Gray
        foreach ($m in $targetManagers.Keys)
        {
            _pw_do_update_single $Query $m
        }
        return
    }

    if ($targetMatches.Count -eq 1)
    {
        _pw_do_update_single $targetMatches[0].ID $targetMatches[0].Manager
        return
    }

    _pw_color "  Multiple managers have updates for '$Query':" Yellow
    $pkg = _pw_pick_source $targetMatches
    if ($pkg)
    {
        _pw_do_update_single $pkg.ID $pkg.Manager
    }
}

<#
.SYNOPSIS
    Universal package management layer CLI for Windows.
.DESCRIPTION
    Unifies package search, installation, holding, sync, and system updates
    across winget, chocolatey, and scoop behind a clean developer terminal interface.
.PARAMETER Command
    The action shorthand (-S, -Ss, -R, doctor, hold, etc.) or full command.
.PARAMETER Query
    The package name, query term, or ID depending on the command context.
.PARAMETER Manager
    Filters execution to a single package manager ('winget', 'choco', 'scoop').
.PARAMETER Limit
    Max results to display for queries. Defaults to 40.
.PARAMETER Timeout
    Max duration in seconds to wait for async operations. Defaults to 35.
.PARAMETER NoHeader
    If set, suppresses printing the visual ASCII brand logo and status header.
.PARAMETER NoInteractive
    If set, executes in non-interactive scripting mode without user prompt picks.
.PARAMETER _pw_unbound
    Collects additional unbound parameters and processes shorthands.
.EXAMPLE
    pacwin search nodejs
.EXAMPLE
    pacwin -S neovim --manager scoop
.EXAMPLE
    pacwin doctor
#>
function pacwin
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [string]$Command,

        [Parameter(Position = 1)]
        [string]$Query,

        [Parameter()]
        [ValidateSet("winget", "choco", "scoop")]
        [string]$Manager,

        [Parameter()]
        [int]$Limit = 40,

        [Parameter()]
        [int]$Timeout = 35,

        [Parameter()]
        [switch]$NoHeader,

        [Parameter()]
        [switch]$NoInteractive,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$_pw_unbound
    )

    # Normalize command and query from input
    # Handle -ni / -NoInteractive from _pw_unbound (PowerShell may not bind it correctly in all cases)
    if ($_pw_unbound -contains "-ni" -or $_pw_unbound -contains "-NoInteractive")
    {
        $NoInteractive = $true
        $_pw_unbound = @($_pw_unbound | Where-Object { $_ -ne "-ni" -and $_ -ne "-NoInteractive" })
    }

    $parsed = _pw_parse_args -Command $Command -Query $Query -Unbound $_pw_unbound
    $Command = $parsed.Command
    $Query = $parsed.Query

    $managers = _pw_detect_managers
    $targetManagers = _pw_filter_manager $managers $Manager

    if (-not $NoHeader)
    { _pw_header $managers
    }
    if (-not (_pw_assert_managers $managers))
    { return
    }

    if (-not $targetManagers)
    { return
    }

    # Global Admin check for choco/winget operations
    _pw_check_admin_requirements -managers $managers -Manager $Manager -Command $Command

    if ($Query)
    {
        $Query = _pw_sanitize $Query
        if (-not $Query)
        { return
        }
    }

    $ctx = @{
        Command         = $Command
        Query           = $Query
        Manager         = $Manager
        Limit           = $Limit
        Timeout         = $Timeout
        NoInteractive   = $NoInteractive
        targetManagers  = $targetManagers
        managers        = $managers
    }

    $executed = $false
    foreach ($pattern in $script:CommandMap.Keys) {
        if ($Command -match $pattern) {
            $cmdBlock = $script:CommandMap[$pattern]
            & $cmdBlock $ctx
            $executed = $true
            break
        }
    }

    if (-not $executed) {
        _pw_color "  Unknown command '$Command'." Yellow
        _pw_color "  Type 'pacwin help' for the full command list." Gray
    }
}

#endregion

#region -- Renderer -----------------------------------------

$script:SRC_COLORS = @{
    "winget"     = "Cyan"
    "chocolatey" = "Yellow"
    "scoop"      = "Green"
}

<#
.SYNOPSIS
    Truncates a string to a maximum length, padding it if necessary.
.DESCRIPTION
    Pads the input string to the specified width if it's shorter. 
    If it's longer, truncates it to (max - 1) characters and appends a dot.
.PARAMETER str
    The string to process.
.PARAMETER max
    The target length.
.OUTPUTS
    System.String
.EXAMPLE
    _pw_truncate "example string" 10
#>
function _pw_truncate
{
    param([string]$str, [int]$max)
    if (-not $str)
    { return "".PadRight($max)
    }
    if ($str.Length -le $max)
    { return $str.PadRight($max)
    }
    return ($str.Substring(0, $max - 1) + ".")
}

<#
.SYNOPSIS
    Extracts a substring column from a tabular line.
.DESCRIPTION
    Safely extracts a column of text given an offset and length, checking bounds and
    returning a fallback value if the extracted text is empty or out of range.
.PARAMETER line
    The source line string.
.PARAMETER off
    The character offset where the column starts (0-indexed).
.PARAMETER len
    The maximum width of the column.
.PARAMETER fallback
    The value to return if the column is out of bounds or empty. Defaults to "?".
.OUTPUTS
    System.String
.EXAMPLE
    _pw_extract_column "Google Chrome  Google.Chrome" 15 13
#>
function _pw_extract_column
{
    param([string]$line, [int]$off, [int]$len, [string]$fallback = "?")
    if ($off -lt 0 -or $off -ge $line.Length)
    { return $fallback
    }
    $actualLen = [Math]::Min($len, $line.Length - $off)
    if ($actualLen -le 0)
    { return $fallback
    }
    $val = $line.Substring($off, $actualLen).Trim()
    if ($val)
    { return $val
    }
    return $fallback
}

function _pw_render_results
{
    param([object]$results, [string]$query = "", [switch]$NoIndex)

    $arr = @($results)
    if ($arr.Count -eq 0)
    {
        if ($query)
        { _pw_color "  No results for '$query'." Yellow
        }
        return
    }

    $termWidth = try
    { $Host.UI.RawUI.WindowSize.Width
    } catch
    { 100
    }
    if ($termWidth -lt 80)
    { $termWidth = 80
    }

    $idxW = if ($NoIndex)
    { 2
    } else
    { 8
    }
    $srcW = 12
    $remW = $termWidth - $idxW - $srcW - 4

    $nameW = [int]($remW * 0.5)
    $idW   = [int]($remW * 0.3)
    $verW  = $remW - $nameW - $idW

    _pw_color ""
    if (-not $NoIndex)
    {
        _pw_color ("  {0,-7} {1,-$($nameW-1)} {2,-$($idW-1)} {3,-$($verW-1)} {4}" -f "ENTRY", "NAME", "ID", "VERSION", "SOURCE") DarkGray
    } else
    {
        _pw_color ("  {0,-$($nameW-1)} {1,-$($idW-1)} {2,-$($verW-1)} {3}" -f "NAME", "ID", "VERSION", "SOURCE") DarkGray
    }
    _pw_sep

    $i = 1
    foreach ($r in $arr)
    {
        $col = if ($script:SRC_COLORS[$r.Source])
        { $script:SRC_COLORS[$r.Source]
        } else
        { "White"
        }
        $name = _pw_truncate $r.Name ($nameW - 2)
        $id = _pw_truncate $r.ID   ($idW - 2)
        $ver = _pw_truncate $r.Version ($verW - 2)

        if (-not $NoIndex)
        {
            # TropicalUI Row selection style
            _pw_color "  " -NoNewline
            _pw_color "│" DarkGray -NoNewline
            _pw_color (" {0,2} " -f $i) Cyan -NoNewline
            _pw_color "│ " DarkGray -NoNewline
        } else
        {
            _pw_color "  " DarkGray -NoNewline
        }
        _pw_color ("{0,-$nameW}{1,-$idW}{2,-$verW}" -f $name, $id, $ver) White -NoNewline
        _pw_color $r.Source $col
        $i++
    }
    _pw_color ""
}

#endregion

#region -- Pin / Hold ---------------------------------------

function _pw_do_pin
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$id,

        [Parameter(Mandatory=$true)]
        [string]$mgr,

        [switch]$Unpin
    )

    $action = if ($Unpin)
    { "Unpinning"
    } else
    { "Pinning"
    }
    _pw_color "  -> $action '$id' with $mgr ..." Cyan
    _pw_sep

    if (-not $PSCmdlet.ShouldProcess("$action $id with $mgr"))
    { return
    }

    switch ($mgr)
    {
        "winget"
        {
            if ($Unpin)
            { winget pin remove --id $id
            } else
            { winget pin add --id $id --accept-source-agreements
            }
        }
        "choco"
        {
            if ($Unpin)
            { choco pin remove --name $id
            } else
            { choco pin add --name $id
            }
        }
        "scoop"
        {
            if ($Unpin)
            { scoop unhold $id
            } else
            { scoop hold $id
            }
        }
    }
    _pw_handle_result $mgr (_pw_last_exit_code) @()
}

function _pw_do_pin_list
{
    param($managers)
    _pw_color "  Pinned / held packages:" Cyan
    _pw_sep
    if ($managers["winget"])
    {
        _pw_color "  -- winget -----------------------------" Cyan
        winget pin list
    }
    if ($managers["choco"])
    {
        _pw_color "  -- chocolatey -------------------------" Yellow
        choco pin list
    }
    if ($managers["scoop"])
    {
        _pw_color "  -- scoop ------------------------------" Green
        # Scoop doesn't have a direct list command; we check for .hold file
        $scoopDir = if ($env:SCOOP)
        { $env:SCOOP
        } else
        { "$HOME\scoop"
        }
        $apps = Get-ChildItem "$scoopDir\apps" -Directory -ErrorAction SilentlyContinue
        foreach ($app in $apps)
        {
            $holdFile = Join-Path $app.FullName "current\.hold"
            if (Test-Path $holdFile)
            {
                _pw_color "  * $($app.Name) [held]" Green
            }
        }
    }
}

#endregion

#region -- Export / Import ----------------------------------

function _pw_do_export
{
    param($managers, [string]$outPath)

    if (-not $outPath)
    {
        $outPath = Join-Path $HOME "pacwin-export-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
    }

    _pw_color "  Collecting installed packages..." Cyan
    $export = [ordered]@{ generated = (Get-Date -Format 'o'); packages = @() }

    if ($managers["winget"])
    {
        # winget export can be slow, we use --accept-source-agreements
        try
        {
            $rawJson = winget export - --accept-source-agreements 2>$null
            if ($rawJson)
            {
                $raw = $rawJson | ConvertFrom-Json
                if ($raw.Sources)
                {
                    foreach ($src in $raw.Sources)
                    {
                        foreach ($pkg in $src.Packages)
                        {
                            $export.packages += [ordered]@{
                                manager = "winget"; id = $pkg.PackageIdentifier
                            }
                        }
                    }
                }
            }
        } catch
        {
            _pw_color "  [!] Error exporting from winget: $_" Yellow
        }
    }
    if ($managers["choco"])
    {
        $raw = choco list --local-only --limit-output 2>$null
        foreach ($line in $raw)
        {
            $parts = $line -split "\|"
            if ($parts.Count -ge 1 -and $parts[0].Trim())
            {
                $export.packages += [ordered]@{
                    manager = "choco"; id = $parts[0].Trim()
                }
            }
        }
    }
    if ($managers["scoop"])
    {
        try
        {
            $rawJson = scoop export 2>$null
            if ($rawJson)
            {
                $raw = $rawJson | ConvertFrom-Json
                if ($raw.apps)
                {
                    foreach ($app in $raw.apps)
                    {
                        $export.packages += [ordered]@{
                            manager = "scoop"; id = $app.Name
                        }
                    }
                }
            }
        } catch
        {
            _pw_color "  [!] Error exporting from scoop: $_" Yellow
        }
    }

    $export | ConvertTo-Json -Depth 5 | Out-File $outPath -Encoding UTF8
    _pw_color "  [OK] Exported $($export.packages.Count) packages to:" Green
    _pw_color "       $outPath" DarkGray
}

function _pw_do_import
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory=$true)]
        $managers,

        [Parameter(Mandatory=$true)]
        [string]$inPath
    )

    if (-not $inPath -or -not (Test-Path $inPath))
    {
        _pw_color "  [!] File not found: '$inPath'" Red; return
    }

    $data = Get-Content $inPath -Raw | ConvertFrom-Json -ErrorAction Stop
    _pw_color "  Importing $($data.packages.Count) packages from export..." Cyan
    _pw_sep

    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($pkg in $data.packages)
    {
        if (-not $managers[$pkg.manager])
        {
            _pw_color "  [SKIP] $($pkg.id) - manager '$($pkg.manager)' not available." DarkGray
            continue
        }
        _pw_color "  -> $($pkg.manager): $($pkg.id)" Cyan

        if (-not $PSCmdlet.ShouldProcess("Install $($pkg.id) via $($pkg.manager)"))
        {
            continue
        }

        switch ($pkg.manager)
        {
            "winget"
            { winget install --id $pkg.id --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            }
            "choco"
            { choco install $pkg.id -y 2>&1 | Out-Null
            }
            "scoop"
            { scoop install $pkg.id 2>&1 | Out-Null
            }
        }
        if ((_pw_last_exit_code) -ne 0)
        { $failed.Add($pkg.id)
        }
    }

    _pw_sep
    if ($failed.Count -eq 0)
    {
        _pw_color "  [OK] All packages installed successfully." Green
    } else
    {
        _pw_color "  [!] Failed: $($failed -join ', ')" Red
    }
}

#endregion

#region -- Doctor -------------------------------------------

function _pw_doctor_check_admin
{
    param($managers)
    $issues = 0
    $isAdmin = _pw_is_admin
    _pw_color ("  Privileges   : {0}" -f $(if ($isAdmin)
            { "Administrator"
            } else
            { "User"
            })) $(if ($isAdmin)
        { "Green"
        } else
        { "Yellow"
        })
    if (-not $isAdmin -and $managers["choco"])
    {
        _pw_color "  [!] Warning: Chocolatey (choco) usually requires Administrator privileges." Yellow
        $issues++
    }
    return $issues
}

function _pw_doctor_check_psversion
{
    $issues = 0
    $psv = $PSVersionTable.PSVersion
    _pw_color ("  PS Version   : {0}" -f $psv) $(if ($psv.Major -ge 5)
        { "Green"
        } else
        { "Red"
        })
    if ($psv.Major -lt 5)
    { _pw_color "  [!] PowerShell 5.1+ required." Red; $issues++
    }
    return $issues
}

function _pw_doctor_check_managers
{
    foreach ($mgr in @("winget","choco","scoop","sfsu"))
    {
        $exe = _pw_exe_cached $mgr
        if ($exe)
        {
            $ver = try
            {
                switch ($mgr)
                {
                    "winget"
                    { (winget --version 2>$null) -replace "[^\d\.]",""
                    }
                    "choco"
                    { (choco --version 2>$null)
                    }
                    "scoop"
                    { (scoop --version 2>$null) | Select-Object -First 1
                    }
                    "sfsu"
                    { (sfsu --version 2>$null) | Select-Object -First 1
                    }
                }
            } catch
            { "Error"
            }
            _pw_color ("  {0,-12} : OK  {1}" -f $mgr, $ver) Green
        } else
        {
            _pw_color ("  {0,-12} : NOT FOUND" -f $mgr) DarkGray
        }
    }
    return 0
}

function _pw_doctor_check_connectivity
{
    $issues = 0
    _pw_color ""
    _pw_color "  Connectivity:" DarkGray
    $hosts = @("api.github.com","community.chocolatey.org","github.com")
    foreach ($h in $hosts)
    {
        $ok = Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue
        _pw_color ("  {0,-32} : {1}" -f $h, $(if ($ok)
                { "OK"
                } else
                { "UNREACHABLE"
                })) $(if ($ok)
            { "Green"
            } else
            { "Red"
            })
        if (-not $ok)
        { $issues++
        }
    }
    return $issues
}

function _pw_doctor_check_scoop_buckets
{
    param($managers)
    $issues = 0
    if ($managers["scoop"])
    {
        _pw_color ""
        _pw_color "  Scoop buckets:" DarkGray
        $buckets = scoop bucket list 2>$null
        foreach ($b in $buckets)
        {
            $name = ($b -split "\s+")[0]
            _pw_color "  Bucket: $name" DarkGray
        }
        # Check last update time of main bucket
        $scoopDir = if ($env:SCOOP)
        { $env:SCOOP
        } else
        { "$HOME\scoop"
        }
        $mainBucket = "$scoopDir\buckets\main"
        if (Test-Path $mainBucket)
        {
            $lastFetch = Get-Item "$mainBucket\.git\FETCH_HEAD" -ErrorAction SilentlyContinue
            if ($lastFetch)
            {
                $age = (Get-Date) - $lastFetch.LastWriteTime
                $ageStr = "{0}d {1}h" -f [int]$age.TotalDays, $age.Hours
                $stale = $age.TotalDays -gt 3
                _pw_color ("  main bucket age  : {0}" -f $ageStr) $(if ($stale)
                    { "Yellow"
                    } else
                    { "Green"
                    })
                if ($stale)
                {
                    _pw_color "  [!] Stale bucket. Run: scoop update" Yellow
                    $issues++
                }
            }
        }
    }
    return $issues
}

function _pw_do_doctor
{
    param($managers)

    _pw_color "  Running diagnostics..." Cyan
    _pw_sep
    $issues = 0

    $issues += _pw_doctor_check_admin $managers
    $issues += _pw_doctor_check_psversion
    $issues += _pw_doctor_check_managers
    $issues += _pw_doctor_check_connectivity
    $issues += _pw_doctor_check_scoop_buckets $managers

    _pw_sep
    if ($issues -eq 0)
    {
        _pw_color "  [OK] No issues detected." Green
    } else
    {
        _pw_color ("  [{0} issue(s) found]" -f $issues) Yellow
    }
}

#endregion

#region -- Self-Update ---------------------------------------



function _pw_self_update
{
    $repoBaseUrl = "https://raw.githubusercontent.com/julesklord/pacwin/main"
    $moduleName = "pacwin"

    _pw_color "  [i] Checking for pacwin updates..." Cyan

    # Detect module location
    $module = Get-Module $moduleName
    if (-not $module)
    {
        _pw_color "  [!] Module pacwin is not loaded in current session." Red
        return
    }

    $moduleDir = Split-Path $module.Path
    _pw_color "  Target Directory: $moduleDir" DarkGray

    # Scenario 1: Git repository
    if (Test-Path (Join-Path $moduleDir ".git"))
    {
        _pw_color "  [i] Git repository detected. Updating via 'git pull'..." Cyan
        $oldDir = Get-Location
        try
        {
            Set-Location $moduleDir
            $out = git pull 2>&1
            if ((_pw_last_exit_code) -eq 0)
            {
                _pw_color "  [v] Update successful via Git." Green
                _pw_color "  $out" Gray
            } else
            {
                _pw_color "  [!] Git pull failed: $out" Red
            }
        } finally
        {
            Set-Location $oldDir
        }
    }
    # Scenario 2: Standard installation
    else
    {
        _pw_color "  [i] Downloading latest version from GitHub..." Cyan
        $files = @("pacwin.psm1", "pacwin.psd1")
        $success = $true
        foreach ($f in $files)
        {
            $url = "$repoBaseUrl/$f"
            $dest = Join-Path $moduleDir $f
            try
            {
                Invoke-WebRequest -Uri $url -OutFile $dest -ErrorAction Stop -UseBasicParsing
                _pw_color "    [v] Updated $f" Gray
            } catch
            {
                _pw_color "    [!] Failed to update ${f}: $_" Red
                $success = $false
            }
        }
        if ($success)
        {
            _pw_color "`n  [SUCCESS] pacwin has been updated to the latest version." Green
        }
    }

    _pw_color "  To apply changes, please restart your terminal or run:" Gray
    _pw_color "  Import-Module $moduleName -Force" White
}

#endregion

#region -- Sync (duplicate detection) ----------------------

function _pw_do_sync
{
    param($managers)

    _pw_color "  Scanning for cross-manager duplicates..." Cyan
    _pw_sep

    $installed = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($managers["winget"])
    {
        $raw = winget list --accept-source-agreements 2>$null
        $lines = [System.Collections.Generic.List[string]]::new($raw.Count); foreach ($r in $raw)
        { $lines.Add([string]$r)
        }
        $parsed = _pw_parse_winget_lines $lines
        foreach ($p in $parsed)
        { $installed.Add($p)
        }
    }
    if ($managers["choco"])
    {
        $raw = choco list --local-only --limit-output 2>$null
        $parsed = _pw_parse_choco_lines $raw
        foreach ($p in $parsed)
        { $installed.Add($p)
        }
    }
    if ($managers["scoop"])
    {
        $sfsu = Get-Command sfsu -ErrorAction SilentlyContinue
        $raw = if ($sfsu)
        {
            & $sfsu.Source list 2>$null
        } else
        {
            & $managers["scoop"] list 2>$null
        }
        $parsed = _pw_parse_scoop_lines $raw
        foreach ($p in $parsed)
        { $installed.Add($p)
        }
    }

    # Normalize name (lowercase, no symbols) for grouping
    # But also consider IDs if they are identical
    $groups = $installed | Group-Object { $_.Name.ToLower() -replace "[\-_\. ]","" }
    $dupes  = $groups | Where-Object { $_.Count -gt 1 }

    if ($dupes.Count -eq 0)
    {
        _pw_color "  [OK] No duplicate packages detected." Green
        return
    }

    _pw_color ("  Found {0} potential duplicate(s):" -f $dupes.Count) Yellow
    _pw_color ""

    foreach ($dupe in $dupes)
    {
        _pw_color ("  Package: {0}" -f $dupe.Group[0].Name) White
        foreach ($pkg in $dupe.Group)
        {
            $col = if ($script:SRC_COLORS[$pkg.Source])
            { $script:SRC_COLORS[$pkg.Source]
            } else
            { "White"
            }
            _pw_color ("    [{0,-10}] ID: {1,-25} v{2}" -f $pkg.Source, $pkg.ID, $pkg.Version) $col
        }
        _pw_color "  Suggestion: keep one, run 'pacwin uninstall <id> -Manager <mgr>'" DarkGray
        _pw_color ""
    }
}

#endregion

#region -- Operations ---------------------------------------

function _pw_do_install
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory=$true)]
        $pkg
    )
    _pw_color ""
    _pw_color "  -> Installing: $($pkg.Name)  [$($pkg.Source)  v$($pkg.Version)]" Cyan
    _pw_sep

    if (-not $PSCmdlet.ShouldProcess("Installing $($pkg.Name) via $($pkg.Source)"))
    { return
    }

    $output = @()
    switch ($pkg.Manager)
    {
        "winget"
        { $output = winget install --id $pkg.ID --accept-package-agreements --accept-source-agreements 2>&1
        }
        "choco"
        { $output = choco install $pkg.ID -y 2>&1
        }
        "scoop"
        { $output = scoop install $pkg.ID 2>&1
        }
    }
    _pw_handle_result $pkg.Manager (_pw_last_exit_code) $output
}

function _pw_do_uninstall
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$name,

        [Parameter(Mandatory=$true)]
        [string]$mgr
    )
    _pw_color ""
    _pw_color "  -> Uninstalling '$name' with $mgr ..." Yellow
    _pw_sep

    if (-not $PSCmdlet.ShouldProcess("Uninstalling '$name' with $mgr"))
    { return
    }

    $output = @()
    switch ($mgr)
    {
        "winget"
        { $output = winget uninstall --id $name 2>&1
        }
        "choco"
        { $output = choco uninstall $name -y 2>&1
        }
        "scoop"
        { $output = scoop uninstall $name 2>&1
        }
    }
    _pw_handle_result $mgr (_pw_last_exit_code) $output
}

function _pw_do_update_single
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$id,

        [Parameter(Mandatory=$true)]
        [string]$mgr
    )
    _pw_color ""
    _pw_color "  -> Updating '$id' with $mgr ..." Cyan
    _pw_sep

    if (-not $PSCmdlet.ShouldProcess("Updating '$id' with $mgr"))
    { return
    }

    $output = @()
    switch ($mgr)
    {
        "winget"
        { $output = winget upgrade --id $id --accept-package-agreements --accept-source-agreements 2>&1
        }
        "choco"
        { $output = choco upgrade $id -y 2>&1
        }
        "scoop"
        { $output = scoop update $id 2>&1
        }
    }
    _pw_handle_result $mgr (_pw_last_exit_code) $output
}

function _pw_do_update_all
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory=$true)]
        $managers
    )

    _pw_color "  :: Synchronizing package databases..." Cyan
    if ($managers["scoop"])
    {
        _pw_color "  Updating scoop database..." Gray
        & $managers["scoop"] update | Out-Null
    }

    _pw_color "  :: Searching for outdated packages..." Cyan
    $outdated = _pw_do_outdated $managers -Silent
    if ($outdated.Count -eq 0)
    {
        _pw_color "  [OK] All packages are up to date." Green
        return
    }

    _pw_color "  Packages to upgrade ($($outdated.Count) total):" Yellow
    _pw_render_results $outdated

    _pw_color ""
    $confirmation = Read-Host "  :: Proceed with installation? [Y/n]"
    if ($confirmation -ne "" -and $confirmation -notmatch "^(y|Y)$")
    {
        _pw_color "  Aborted." Yellow
        return
    }

    _pw_color "  :: Starting full system upgrade..." Cyan
    if ($managers["winget"])
    {
        _pw_color "  -- winget -----------------------------" Cyan
        if ($PSCmdlet.ShouldProcess("winget upgrade --all"))
        {
            & $managers["winget"] upgrade --all --accept-package-agreements --accept-source-agreements
        }
    }
    if ($managers["choco"])
    {
        _pw_color "  -- chocolatey -------------------------" Yellow
        if ($PSCmdlet.ShouldProcess("choco upgrade all"))
        {
            & $managers["choco"] upgrade all -y
        }
    }
    if ($managers["scoop"])
    {
        _pw_color "  -- scoop ------------------------------" Green
        if ($PSCmdlet.ShouldProcess("scoop update *"))
        {
            & $managers["scoop"] update *
        }
    }
}

function _pw_do_outdated
{
    param($managers, [switch]$Silent)

    $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($managers["winget"])
    {
        if (-not $Silent)
        { _pw_color "  -- winget -----------------------------" Cyan
        }
        $out = winget upgrade --accept-source-agreements 2>$null
        $lines = [System.Collections.Generic.List[string]]::new($out.Count); foreach ($o in $out)
        { $lines.Add([string]$o)
        }
        $parsed = _pw_parse_winget_lines $lines
        foreach ($p in $parsed)
        { $allResults.Add($p)
        }
    }
    if ($managers["choco"])
    {
        if (-not $Silent)
        { _pw_color "  -- chocolatey -------------------------" Yellow
        }
        $out = choco outdated --limit-output 2>$null
        $parsed = _pw_parse_choco_lines $out
        foreach ($p in $parsed)
        { $allResults.Add($p)
        }
    }
    if ($managers["scoop"])
    {
        if (-not $Silent)
        { _pw_color "  -- scoop ------------------------------" Green
        }
        $sfsu = Get-Command sfsu -ErrorAction SilentlyContinue
        $out = if ($sfsu)
        {
            & $sfsu.Source outdated 2>$null
        } else
        {
            & $managers["scoop"] status 2>$null
        }

        $lines = [System.Collections.Generic.List[string]]::new($out.Count)
        foreach ($line in $out)
        {
            if ($line) { $lines.Add([string]$line) }
        }
        $parsed = _pw_parse_scoop_outdated_lines $lines
        foreach ($p in $parsed)
        {
            $allResults.Add($p)
        }
    }

    if ($Silent)
    { return $allResults
    }

    # Non-silent: render results via standard table
    if ($allResults.Count -eq 0)
    {
        _pw_color "  [OK] All packages are up to date." Green
    } else
    {
        _pw_color "  Outdated packages ($($allResults.Count) found):" Yellow
        _pw_render_results $allResults
    }
}

function _pw_do_list
{
    param($managers, [string]$filter)

    _pw_color "  Listing installed packages..." Cyan
    if ($filter)
    { _pw_color "  (Filter: '$filter')" DarkGray
    }

    if ($managers["winget"])
    {
        _pw_color "  -- winget -----------------------------" Cyan
        if ($filter)
        { winget list --query $filter
        } else
        { winget list
        }
    }
    if ($managers["choco"])
    {
        _pw_color "  -- chocolatey -------------------------" Yellow
        if ($filter)
        { choco list --local-only $filter
        } else
        { choco list --local-only
        }
    }
    if ($managers["scoop"])
    {
        _pw_color "  -- scoop ------------------------------" Green
        $sfsu = Get-Command sfsu -ErrorAction SilentlyContinue
        if ($sfsu)
        {
            if ($filter)
            { & $sfsu.Source list $filter
            } else
            { & $sfsu.Source list
            }
        } else
        {
            if ($filter)
            { & $managers["scoop"] list $filter
            } else
            { & $managers["scoop"] list
            }
        }
    }
}

function _pw_do_info
{
    param($managers, [string]$name)

    _pw_color "  Fetching information for '$name'..." Cyan

    if ($managers["winget"])
    {
        _pw_color "  -- winget -----------------------------" Cyan
        winget show --id $name --accept-source-agreements
    }
    if ($managers["choco"])
    {
        _pw_color "  -- chocolatey -------------------------" Yellow
        choco info $name
    }
    if ($managers["scoop"])
    {
        _pw_color "  -- scoop ------------------------------" Green
        scoop info $name
    }
}

function _pw_handle_result
{
    param(
        [string]$manager,
        [int]$exitCode,
        [string[]]$output
    )

    $result = _pw_handle_error -Manager $manager -ExitCode $exitCode -Message "" -Output $output

    if ($result.Success)
    {
        _pw_color "  [OK] Operation completed successfully. $($result.Message)" Green
    } else
    {
        _pw_color "  [FAILURE] The operation could not be completed." Red
        if ($result.Message)
        { _pw_color "  Detail: $($result.Message)" Yellow
        } else
        { _pw_color "  Check previous output for more details." DarkGray
        }
    }
}

#endregion

#region -- Source Picker ------------------------------------

function _pw_pick_source
{
    param([object]$candidates)
    $arr = @($candidates)
    if ($arr.Count -eq 1)
    { return $arr[0]
    }

    _pw_color "  [PROMPT] Multiple candidates found. Specify target index:" Cyan
    _pw_render_results $arr

    _pw_color "  >> ENTRY_INDEX (ENTER TO CANCEL): " Cyan -NoNewline
    $choice = Read-Host
    if ([string]::IsNullOrWhiteSpace($choice))
    { return $null
    }

    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $arr.Count)
    {
        _pw_color "  Invalid selection." Red; return $null
    }
    return $arr[$idx - 1]
}

#endregion

#region -- Tab Completion -----------------------------------

Register-ArgumentCompleter -CommandName pacwin -ParameterName Command -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    $cmds = @(
        'search','install','uninstall','update','outdated','list',
        'info','pin','unpin','export','import','doctor','status','help',
        'hold','unhold','check','sync','dupes','dedup','self-update','version',
        '-S','-Ss','-Syu','-R','-Q','-Qu','-Si','-V','-h','--help','--version'
    )
    foreach ($cmd in $cmds.Where({ $_ -like "$wordToComplete*" }))
    {
        [System.Management.Automation.CompletionResult]::new(
            $cmd,                                      # completionText
            $cmd,                                      # listItemText
            [System.Management.Automation.CompletionResultType]::ParameterValue,
            $cmd                                       # toolTip
        )
    }
}

Register-ArgumentCompleter -CommandName pacwin -ParameterName Manager -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    foreach ($mgr in @('winget','choco','scoop').Where({ $_ -like "$wordToComplete*" }))
    {
        [System.Management.Automation.CompletionResult]::new($mgr, $mgr,
            [System.Management.Automation.CompletionResultType]::ParameterValue, $mgr)
    }
}

# Tab completion for -NoInteractive flag
Register-ArgumentCompleter -CommandName pacwin -ParameterName NoInteractive -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    foreach ($opt in @('$true','$false','-ni','-NoInteractive').Where({ $_ -like "$wordToComplete*" }))
    {
        [System.Management.Automation.CompletionResult]::new($opt, $opt,
            [System.Management.Automation.CompletionResultType]::ParameterValue, $opt)
    }
}

# Completar -Query con paquetes instalados cuando el comando es uninstall/pin/update
Register-ArgumentCompleter -CommandName pacwin -ParameterName Query -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    $cmd = $fakeBoundParameters['Command']
    if ($cmd -notin @('uninstall','pin','unpin','update','info'))
    { return
    }
    # Intenta completar con winget list (rapido si existe)
    if (-not (Get-Command "winget" -ErrorAction SilentlyContinue))
    { return
    }

    $raw = winget list --query $wordToComplete 2>$null | Select-Object -Skip 3
    foreach ($line in $raw)
    {
        $parts = ($line -split "\s{2,}").Where({ $_ -ne "" })
        if ($parts.Count -ge 2 -and $parts[0] -notmatch "^-{3}")
        {
            $id = $parts[1]
            [System.Management.Automation.CompletionResult]::new($id, $id,
                [System.Management.Automation.CompletionResultType]::ParameterValue, $parts[0])
        }
    }
}

#endregion
