# internal/helpers/ErrorHandler.ps1
# Centralized error mapping and handling helper for pacwin

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

function _pw_handle_error {
    param(
        [string]$Manager,
        [int]$ExitCode,
        [string]$Message,
        [string[]]$Output
    )

    $outputText = $Output -join "`n"
    $success = $false
    $msg = $Message

    switch ($Manager)
    {
        "winget"
        {
            $codeStr = [string]$ExitCode
            if ($script:ErrorCodes["winget"].Contains($codeStr))
            {
                $msg = $script:ErrorCodes["winget"][$codeStr]
                if ($ExitCode -eq 0 -or $ExitCode -eq -1978335186)
                { $success = $true
                }
            } else
            {
                $msg = if ($Message) { $Message } else { "Winget Error (Code: $ExitCode)." }
            }
        }
        "choco"
        {
            $codeStr = [string]$ExitCode
            if ($script:ErrorCodes["choco"].Contains($codeStr))
            {
                $msg = $script:ErrorCodes["choco"][$codeStr]
                if ($ExitCode -eq 0 -or $ExitCode -eq 1641 -or $ExitCode -eq 3010)
                { $success = $true
                }
            } else
            {
                $msg = if ($Message) { $Message } else { "Chocolatey Error (Code: $ExitCode)." }
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
                $msg = "Scoop Error: " + ($Output | Select-String "Error:" | Select-Object -First 1)
            } else
            {
                $codeStr = [string]$ExitCode
                if ($script:ErrorCodes["scoop"].Contains($codeStr))
                {
                    $msg = $script:ErrorCodes["scoop"][$codeStr]
                }
                $success = ($ExitCode -eq 0)
            }
        }
        default
        {
            $success = ($ExitCode -eq 0)
        }
    }

    return [PSCustomObject]@{
        Manager  = $Manager
        Success  = $success
        Code     = $ExitCode
        Message  = $msg
        Output   = $Output
    }
}
