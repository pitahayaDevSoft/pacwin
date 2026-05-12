# ============================================================
#  pacwin.psm1  -  Universal Package Layer for Windows
#  Abstraction over: winget | chocolatey | scoop
#  Compatible: PowerShell 5.1 + PowerShell 7+
#  v0.3.1 (Major Refactor & Optimizations)
# ============================================================

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Continue"

# Force UTF8 for better character rendering in PS 5.1
if ($PSVersionTable.PSVersion.Major -lt 6)
{
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}

#region -- Security & Validation -----------------------------

function _pw_sanitize
{
    param([string]$inputStr)
    if ([string]::IsNullOrWhiteSpace($inputStr))
    { return ""
    }
    return $inputStr -replace "[^\w\.\-\+]", ""
}

function _pw_validate_path
{
    # Validates file paths: allowed characters are \ / : . - _ a-z A-Z 0-9
    param([string]$pathInput)
    if (-not $pathInput)
    { return $null
    }
    if ($pathInput -match '^[a-zA-Z0-9\._\-@/\\:]+$')
    {
        return $pathInput
    }
    _pw_color "  [!] Path input detected as a potential security risk: '$pathInput'" Red
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
    _pw_color "  >> " Cyan -NoNewline
    _pw_color "pacwin" White -NoNewline
    _pw_color " v0.3.1" DarkGray -NoNewline
    _pw_color "  --  " DarkGray -NoNewline
    _pw_color "universal package layer" DarkGray

    if ($null -ne $managers)
    {
        _pw_color "  [" DarkGray -NoNewline
        $keys = "winget", "choco", "scoop"
        for ($i = 0; $i -lt $keys.Count; $i++)
        {
            $k = $keys[$i]
            _pw_color " $k " Gray -NoNewline
            if ($managers[$k])
            {
                _pw_color "+" Green -NoNewline
            } else
            {
                _pw_color "-" Red -NoNewline
            }
            if ($i -lt $keys.Count - 1)
            { _pw_color " |" DarkGray -NoNewline
            }
        }
        _pw_color " ]" DarkGray
    }

    _pw_color ("  " + ("=" * 48)) DarkGray
}

function _pw_sep
{
    $w = try
    { $Host.UI.RawUI.WindowSize.Width - 4
    } catch
    { 68
    }
    if ($w -lt 40)
    { $w = 68
    }
    _pw_color ("  " + ("-" * $w)) DarkGray
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
    $wingetExe = _pw_exe "winget"
    $chocoExe = _pw_exe "choco"
    $scoopExe = _pw_exe "scoop"
    if ($wingetExe)
    { $m["winget"] = $wingetExe
    }
    if ($chocoExe)
    { $m["choco"] = $chocoExe
    }
    if ($scoopExe)
    { $m["scoop"] = $scoopExe
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

function _pw_parse_winget_lines
{
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. Identify the header/separator structure
    $separatorLine = $lines | Where-Object { $_ -match "^-{5,}" } | Select-Object -First 1

    if (-not $separatorLine)
    {
        # Fallback: Heuristic split if no separator is found
        foreach ($line in $lines)
        {
            # Skip progress bars, empty lines, and header-like lines
            if ($line -match "^\s*$|^-{3,}|[^\x00-\x7F]|%|[\d.]+\s+[KMG]B\s*/")
            { continue
            }
            $parts = ($line.Trim() -split "\s{2,}").Where({ $_ -ne "" })
            if ($parts.Count -ge 2)
            {
                $results.Add([PSCustomObject]@{
                        Name    = $parts[0].Trim()
                        ID      = $(if ($parts.Count -ge 3)
                            { $parts[1].Trim()
                            } else
                            { $parts[0].Trim()
                            })
                        Version = $(if ($parts.Count -ge 3)
                            { $parts[2].Trim()
                            } else
                            { $parts[1].Trim()
                            })
                        Source  = "winget"
                        Manager = "winget"
                    })
            }
        }
        return $results
    }

    # 2. Extract offsets from the separator line (e.g., "--- --- ---" or "------------")
    # Matches groups of dashes to find where columns start and end
    $matches = [regex]::Matches($separatorLine, "-+")

    if ($matches.Count -ge 2)
    {
        # Segmented separator (best case)
        $nameOff    = $matches[0].Index
        $nameLen    = $matches[0].Length
        $idOff      = $matches[1].Index
        $idLen      = $matches[1].Length
        $versionOff = if ($matches.Count -ge 3)
        { $matches[2].Index
        } else
        { -1
        }
        $versionLen = if ($matches.Count -ge 3)
        { $matches[2].Length
        } else
        { -1
        }
        $sourceOff  = if ($matches.Count -ge 4)
        { $matches[3].Index
        } else
        { -1
        }
    } else
    {
        # Single long separator (fallback to heuristic parsing for all lines)
        # We try to use the header line above the separator if possible
        $sepIdx = [array]::IndexOf($lines, $separatorLine)
        if ($sepIdx -gt 0)
        {
            $headerLine = $lines[$sepIdx - 1]
            # Use gaps in the header line to guess columns
            # This is still better than fixed English headers
            $parts = [regex]::Matches($headerLine, "\S+")
            if ($parts.Count -ge 2)
            {
                $nameOff = $parts[0].Index
                $idOff = $parts[1].Index
                $versionOff = if ($parts.Count -ge 3)
                { $parts[2].Index
                } else
                { -1
                }
                $sourceOff = if ($parts.Count -ge 4)
                { $parts[3].Index
                } else
                { -1
                }

                # Lengths are determined by the distance to the next column
                $nameLen = $idOff - $nameOff
                $idLen = if ($versionOff -gt 0)
                { $versionOff - $idOff
                } else
                { 100
                }
                $versionLen = if ($sourceOff -gt 0)
                { $sourceOff - $versionOff
                } else
                { 100
                }
            } else
            { return $results
            }
        } else
        { return $results
        }
    }

    $dataStart = $false
    foreach ($line in $lines)
    {
        if ($line -eq $separatorLine)
        { $dataStart = $true; continue
        }
        if (-not $dataStart -or $line -match "^\s*$|^-|^[^\x00-\x7F]|%|[\d.]+\s+[KMG]B\s*/")
        { continue
        }

        $name = _pw_extract_column $line $nameOff $nameLen $null
        $id   = _pw_extract_column $line $idOff   $idLen   $null

        if (-not $name -or -not $id)
        { continue
        }

        $vLen = if ($sourceOff -gt $versionOff -and $versionOff -gt 0)
        { $sourceOff - $versionOff
        } else
        { $versionLen
        }
        $ver  = _pw_extract_column $line $versionOff $vLen "?"

        $results.Add([PSCustomObject]@{
                Name    = $name
                ID      = $id
                Version = $ver
                Source  = "winget"
                Manager = "winget"
            })
    }
    return ,$results
}

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

function _pw_parse_scoop_lines
{
    param([string[]]$lines)
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $inResults = $false
    foreach ($line in $lines)
    {
        if ($line -match "^Results from")
        { $inResults = $true; continue
        }
        if (-not $inResults -or $line -match "^\s*$|^-{3,}")
        { continue
        }

        if ($line -match "^\s+(\S+)\s+\(([^)]+)\)")
        {
            $results.Add([PSCustomObject]@{
                    Name = $Matches[1]; ID = $Matches[1]
                    Version = $Matches[2]; Source = "scoop"; Manager = "scoop"
                })
            continue
        }
        $parts = ($line.Trim() -split "\s{2,}").Where({ $_ -ne "" })
        if ($parts.Count -ge 1 -and $parts[0] -notmatch "^[Nn]ame$|^Source$")
        {
            $results.Add([PSCustomObject]@{
                    Name = $parts[0]; ID = $parts[0]
                    Version = $(if ($parts.Count -ge 2)
                        { $parts[1]
                        } else
                        { "?"
                        })
                    Source = "scoop"; Manager = "scoop"
                })
        }
    }
    return ,$results
}

#endregion

#region -- Search Engine ------------------------------------

function _pw_search_all
{
    param($managers, [string]$query, [int]$limit = 40, [int]$timeoutSeconds = 25)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $scripts = [ordered]@{}
    $timeoutMs = $timeoutSeconds * 1000
    $waitLimit = [int]($timeoutMs / 100)

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
                $out = & $exe search $q 2>&1
                return $out
            } catch
            {
                return @()
            }
        }
    }

    # Unified concurrency approach for all PS versions
    # This allows us to control the UI (spinner) while waiting for background tasks
    $rsPool = [runspacefactory]::CreateRunspacePool(1, $scripts.Count)
    $rsPool.Open()
    $tasks = New-Object System.Collections.Generic.List[Object]

    foreach ($key in $scripts.Keys)
    {
        $ps = [powershell]::Create().AddScript($scripts[$key]).AddArgument($managers[$key]).AddArgument($query)
        $ps.RunspacePool = $rsPool
        $tasks.Add(@{ Key = $key; PowerShell = $ps; AsyncResult = $ps.BeginInvoke(); Finished = $false })
    }

    $spinner = "|/-\"
    $spinIdx = 0
    $startTime = [DateTime]::Now
    $timeoutMs = $timeoutSeconds * 1000

    # UI Loop: Show real-time progress for each manager
    while ($true)
    {
        $allFinished = $true
        Write-Host -NoNewline "`r    "

        foreach ($t in $tasks)
        {
            if ($t.AsyncResult.IsCompleted)
            {
                $t.Finished = $true
                Write-Host -NoNewline "[" -ForegroundColor DarkGray
                Write-Host -NoNewline "v" -ForegroundColor Green
                Write-Host -NoNewline "] $($t.Key)  " -ForegroundColor DarkGray
            } else
            {
                $allFinished = $false
                $char = $spinner[$spinIdx % 4]
                Write-Host -NoNewline "[" -ForegroundColor DarkGray
                Write-Host -NoNewline "$char" -ForegroundColor Yellow
                Write-Host -NoNewline "] $($t.Key)  " -ForegroundColor DarkGray
            }
        }

        if ($allFinished)
        { break
        }

        # Check timeout
        if (([DateTime]::Now - $startTime).TotalMilliseconds -gt $timeoutMs)
        {
            Write-Host "" # New line
            _pw_color "  [!] Search partially timed out ($timeoutSeconds s). Results may be incomplete." DarkGray
            break
        }

        Start-Sleep -Milliseconds 150
        $spinIdx++
    }
    Write-Host "" # End the spinner line

    # Collect and parse results
    foreach ($t in $tasks)
    {
        try
        {
            if ($t.AsyncResult.IsCompleted)
            {
                $raw = $t.PowerShell.EndInvoke($t.AsyncResult)
                $lines = [System.Collections.Generic.List[string]]::new($raw.Count); foreach ($r in $raw)
                { $lines.Add([string]$r)
                }
                $parsed = @()
                switch ($t.Key)
                {
                    "winget"
                    { $parsed = _pw_parse_winget_lines $lines
                    }
                    "choco"
                    { $parsed = _pw_parse_choco_lines  $lines
                    }
                    "scoop"
                    { $parsed = _pw_parse_scoop_lines  $lines
                    }
                }
                foreach ($r in $parsed)
                { $results.Add($r)
                }
            }
        } catch
        {
            Write-Debug "Error collecting results for $($t.Key): $_"
        } finally
        {
            $t.PowerShell.Dispose()
        }
    }
    $rsPool.Close()

    if ($results.Count -gt $limit)
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

    switch -Regex ($Command)
    {
        "^(search|-Ss)$"
        {
            if (-not $Query)
            { _pw_color "  [!] Search term missing." Yellow; return
            }
            _pw_color "  > Searching for '$Query'..." Cyan
            $results = @(_pw_search_all $targetManagers $Query $Limit $Timeout)
            _pw_render_results $results $Query

            if (-not $NoInteractive -and $results.Count -gt 0)
            {
                _pw_color ""
                $choice = Read-Host "  Install # (Enter to cancel)"
                if ([string]::IsNullOrWhiteSpace($choice))
                { return
                }
                $idx = 0
                if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $results.Count)
                {
                    _pw_color "  Invalid selection." Red; return
                }
                $pkg = $results[$idx - 1]
                _pw_do_install $pkg
            }
        }

        "^(info|-Si)$"
        {
            if (-not $Query)
            { _pw_color "  [!] Package name missing." Yellow; return
            }
            _pw_do_info $targetManagers $Query
        }

        "^(install|-S)$"
        {
            if (-not $Query)
            { _pw_color "  [!] Package name missing." Yellow; return
            }
            _pw_color "  Looking for candidates for '$Query'..." Cyan
            $results = @(_pw_search_all $targetManagers $Query $Limit $Timeout)

            if ($results.Count -eq 0)
            {
                _pw_color "  No packages found for '$Query'." Yellow
                return
            }

            $pkg = _pw_pick_source $results
            if ($pkg)
            {
                _pw_do_install $pkg
            }
        }
        "^(uninstall|-R)$"
        {
            if (-not $Query)
            { _pw_color "  [!] Package name missing." Yellow; return
            }
            if (-not $Manager)
            {
                _pw_color "  [!] Specify a manager with -Manager (winget|choco|scoop)" Yellow
                return
            }
            _pw_do_uninstall $Query $Manager
        }

        "^(update|upgrade|-Syu)$"
        {
            _pw_handle_update -targetManagers $targetManagers -Query $Query -Manager $Manager
        }

        "^(outdated|-Qu)$"
        {
            _pw_do_outdated $targetManagers
        }

        "^(list|-Q)$"
        {
            _pw_do_list $targetManagers $Query
        }

        "^(export)$"
        {
            _pw_do_export $targetManagers $Query
        }

        "^(import)$"
        {
            if (-not $Query)
            { _pw_color "  [!] Specify the export file path." Yellow; return
            }
            _pw_do_import $targetManagers $Query
        }

        "^(pin|hold)$"
        {
            if (-not $Query)
            {
                _pw_do_pin_list $targetManagers
                return
            }
            if (-not $Manager)
            {
                _pw_color "  [!] Specify a manager with -Manager (winget|choco|scoop)" Yellow
                return
            }
            _pw_do_pin $Query $Manager
        }

        "^(unpin|unhold)$"
        {
            if (-not $Query -or -not $Manager)
            {
                _pw_color "  [!] Requires -Query and -Manager." Yellow; return
            }
            _pw_do_pin $Query $Manager -Unpin
        }

        "^(doctor|check)$"
        {
            _pw_do_doctor $targetManagers
        }

        "^(sync|dupes|dedup)$"
        {
            _pw_do_sync $targetManagers
        }

        "^(status)$"
        {
            _pw_color "  Binary Paths:" Cyan
            foreach ($key in $managers.Keys)
            {
                _pw_color "  * $key " Gray -NoNewline
                _pw_color "-> $($managers[$key])" DarkGray
            }
        }

        "^(version|-V|--version)$"
        {
            _pw_color "  pacwin v0.3.1" Cyan
            _pw_color "  PowerShell $($PSVersionTable.PSVersion)" Gray
            return
        }

        "^(self-update)$"
        {
            _pw_self_update
        }

        "^(help|--help|-h)$"
        {
            _pw_show_help
        }

        "^(version|--version|-v)$"
        {
            _pw_color "  pacwin" White -NoNewline
            _pw_color " v0.3.1" Gray
        }

        Default
        {
            _pw_color "  Unknown command '$Command'." Yellow
            _pw_color "  Type 'pacwin help' for the full command list." Gray
        }
    }
}

#endregion

#region -- Renderer -----------------------------------------

$script:SRC_COLORS = @{
    "winget"     = "Cyan"
    "chocolatey" = "Yellow"
    "scoop"      = "Green"
}

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
        _pw_color ("  {0,-5} {1,-$($nameW-1)} {2,-$($idW-1)} {3,-$($verW-1)} {4}" -f "#", "Name", "ID", "Version", "Source") DarkGray
    } else
    {
        _pw_color ("  {0,-$($nameW-1)} {1,-$($idW-1)} {2,-$($verW-1)} {3}" -f "Name", "ID", "Version", "Source") DarkGray
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
            _pw_color ("  [{0,-2}] " -f $i) DarkGray -NoNewline
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
    _pw_handle_result $mgr $LASTEXITCODE @()
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
        if ($LASTEXITCODE -ne 0)
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

function _pw_do_doctor
{
    param($managers)

    _pw_color "  Running diagnostics..." Cyan
    _pw_sep
    $issues = 0

    # Administrator check
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

    # PowerShell version
    $psv = $PSVersionTable.PSVersion
    _pw_color ("  PS Version   : {0}" -f $psv) $(if ($psv.Major -ge 5)
        { "Green"
        } else
        { "Red"
        })
    if ($psv.Major -lt 5)
    { _pw_color "  [!] PowerShell 5.1+ required." Red; $issues++
    }

    # Manager presence & version
    foreach ($mgr in @("winget","choco","scoop"))
    {
        $exe = _pw_exe $mgr
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

    # Connectivity check
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

    # Scoop buckets stale check
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
            if ($LASTEXITCODE -eq 0)
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
        $raw = scoop list 2>$null
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
    _pw_handle_result $pkg.Manager $LASTEXITCODE $output
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
    _pw_handle_result $mgr $LASTEXITCODE $output
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
    _pw_handle_result $mgr $LASTEXITCODE $output
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
        $out = scoop status 2>$null
        foreach ($line in $out)
        {
            if ($line -match "(\S+)\s+has\s+a\s+new\s+version")
            {
                $allResults.Add([PSCustomObject]@{
                        Name    = $Matches[1]; ID = $Matches[1]
                        Version = "Later"; Source = "scoop"; Manager = "scoop"
                    })
            }
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
        if ($filter)
        { scoop list $filter
        } else
        { scoop list
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

$script:ErrorCodes = @{
    "winget" = @{
        "0"           = "Success"
        "-1978335186" = "Success (Restart required to complete)"
        "-1978335215" = "Network or Source Error (Check connectivity)"
        "-1978334812" = "Installer failed with exit code"
    }
    "choco" = @{
        "0"    = "Success"
        "1641" = "Success (Restart required to complete)"
        "3010" = "Success (Restart required to complete)"
        "1603" = "Fatal error during installation (Try running as Administrator)"
        "-1"   = "General error (Check logs)"
    }
    "scoop" = @{
        "0" = "Success"
        "1" = "Generic failure (Check bucket status or permissions)"
    }
}

function _pw_handle_result
{
    param(
        [string]$manager,
        [int]$exitCode,
        [string[]]$output
    )

    $outputText = $output -join "`n"
    $success = $false
    $msg = ""

    switch ($manager)
    {
        "winget"
        {
            $codeStr = [string]$exitCode
            if ($script:ErrorCodes["winget"].Contains($codeStr))
            {
                $msg = $script:ErrorCodes["winget"][$codeStr]
                if ($exitCode -eq 0 -or $exitCode -eq -1978335186)
                { $success = $true
                }
            } else
            {
                $msg = "Winget Error (Code: $exitCode)."
            }
        }
        "choco"
        {
            $codeStr = [string]$exitCode
            if ($script:ErrorCodes["choco"].Contains($codeStr))
            {
                $msg = $script:ErrorCodes["choco"][$codeStr]
                if ($exitCode -eq 0 -or $exitCode -eq 1641 -or $exitCode -eq 3010)
                { $success = $true
                }
            } else
            {
                $msg = "Chocolatey Error (Code: $exitCode)."
            }
        }
        "scoop"
        {
            if ($outputText -match "installed successfully|already installed")
            {
                $success = $true
            } elseif ($outputText -match "Couldn't find manifest|Access denied")
            {
                $success = $false
                $msg = "Scoop Error: " + ($output | Select-String "Error:" | Select-Object -First 1)
            } else
            {
                $codeStr = [string]$exitCode
                if ($script:ErrorCodes["scoop"].Contains($codeStr))
                {
                    $msg = $script:ErrorCodes["scoop"][$codeStr]
                }
                $success = ($exitCode -eq 0)
            }
        }
    }

    if ($success)
    {
        _pw_color "  [OK] Operation completed successfully. $msg" Green
    } else
    {
        _pw_color "  [FAILURE] The operation could not be completed." Red
        if ($msg)
        { _pw_color "  Detail: $msg" Yellow
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

    _pw_color "  Package available in multiple sources - pick one:" Yellow
    _pw_render_results $arr

    $choice = Read-Host "  Source index (Number, Enter=cancel)"
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
