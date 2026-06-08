# internal/helpers/Concurrency.ps1
# Concurrency helpers using RunspacePool for async operations in pacwin

function New-PwTaskPool {
    param(
        [System.Collections.IDictionary]$Scripts,
        [System.Collections.IDictionary]$Managers,
        [string]$Query
    )
    $rsPool = [runspacefactory]::CreateRunspacePool(1, $Scripts.Keys.Count)
    $rsPool.Open()
    $tasks = [System.Collections.Generic.List[Object]]::new()
    foreach ($key in $Scripts.Keys) {
        $ps = [powershell]::Create().AddScript($Scripts[$key]).AddArgument($Managers[$key]).AddArgument($Query)
        $ps.RunspacePool = $rsPool
        $tasks.Add(@{
            Key         = $key
            PowerShell  = $ps
            AsyncResult = $ps.BeginInvoke()
            Finished    = $false
        })
    }
    return [PSCustomObject]@{
        Pool  = $rsPool
        Tasks = $tasks
    }
}

function Wait-PwTaskPool {
    param(
        [object]$PoolContext,
        [int]$TimeoutSeconds
    )
    $tasks = $PoolContext.Tasks
    $spinner = $script:THEME.Layout.Spinner
    $spinIdx = 0
    $startTime = [DateTime]::Now
    $timeoutMs = $TimeoutSeconds * 1000

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
                Write-Host -NoNewline "[" -ForegroundColor $script:THEME.Dim
                Write-Host -NoNewline "v" -ForegroundColor $script:THEME.Success
                Write-Host -NoNewline "] $($t.Key)  " -ForegroundColor $script:THEME.Dim
            } else
            {
                $allFinished = $false
                $char = $spinner[$spinIdx % $spinner.Length]
                Write-Host -NoNewline "[" -ForegroundColor $script:THEME.Dim
                Write-Host -NoNewline "$char" -ForegroundColor $script:THEME.Warning
                Write-Host -NoNewline "] $($t.Key)  " -ForegroundColor $script:THEME.Dim
            }
        }

        if ($allFinished)
        { break
        }

        # Check timeout
        if (([DateTime]::Now - $startTime).TotalMilliseconds -gt $timeoutMs)
        {
            Write-Host "" # New line
            _pw_color "  [!] Search partially timed out ($TimeoutSeconds s). Results may be incomplete." $script:THEME.Dim
            break
        }

        Start-Sleep -Milliseconds 150
        $spinIdx++
    }
    Write-Host "" # End the spinner line
}

function Receive-PwTaskPool {
    param(
        [object]$PoolContext
    )
    $tasks = $PoolContext.Tasks
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($t in $tasks)
    {
        try
        {
            if ($t.AsyncResult.IsCompleted)
            {
                $raw = $t.PowerShell.EndInvoke($t.AsyncResult)
                if ($null -eq $raw) { continue }

                $lines = [System.Collections.Generic.List[string]]::new($raw.Count)
                foreach ($r in $raw)
                {
                    $lines.Add([string]$r)
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
                {
                    $results.Add($r)
                }
            }
        } catch
        {
            Write-Debug "Error collecting results for $($t.Key): $_"
        } finally
        {
            if ($null -ne $t.PowerShell)
            {
                try { $t.PowerShell.Dispose() } catch {}
            }
        }
    }

    if ($null -ne $PoolContext -and $null -ne $PoolContext.Pool)
    {
        try { $PoolContext.Pool.Close() } catch {}
        try { $PoolContext.Pool.Dispose() } catch {}
    }

    return $results
}
