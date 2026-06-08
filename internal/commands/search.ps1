# internal/commands/search.ps1
# Implementation of search and info commands

function _pw_cmd_search {
    param($Context)
    $targetManagers = $Context.targetManagers
    $Query = $Context.Query
    $Limit = $Context.Limit
    $Timeout = $Context.Timeout
    $NoInteractive = $Context.NoInteractive

    if (-not $Query) {
        _pw_color "  [!] QUERY_MISSING: Specification required." Yellow
        return
    }
    _pw_color "  > SCANNING_REPOS: '$Query'..." Cyan
    $results = @(_pw_search_all $targetManagers $Query $Limit $Timeout)
    _pw_render_results $results $Query

    if (-not $NoInteractive -and $results.Count -gt 0) {
        _pw_color ""
        _pw_color "  >> ENTRY_INDEX (ENTER TO CANCEL): " Cyan -NoNewline
        $choice = Read-Host
        if ([string]::IsNullOrWhiteSpace($choice)) { return }
        $idx = 0
        if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $results.Count) {
            _pw_color "  [!] SELECTION_INVALID." Red
            return
        }
        $pkg = $results[$idx - 1]
        _pw_do_install $pkg
    }
}

function _pw_cmd_info {
    param($Context)
    $targetManagers = $Context.targetManagers
    $Query = $Context.Query

    if (-not $Query) {
        _pw_color "  [!] Package name missing." Yellow
        return
    }
    _pw_do_info $targetManagers $Query
}
