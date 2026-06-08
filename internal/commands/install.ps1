# internal/commands/install.ps1
# Implementation of install and uninstall commands

function _pw_cmd_install {
    param($Context)
    $targetManagers = $Context.targetManagers
    $Query = $Context.Query
    $Limit = $Context.Limit
    $Timeout = $Context.Timeout

    if (-not $Query) {
        _pw_color "  [!] Package name missing." Yellow
        return
    }
    _pw_color "  Looking for candidates for '$Query'..." Cyan
    $results = @(_pw_search_all $targetManagers $Query $Limit $Timeout)

    if ($results.Count -eq 0) {
        _pw_color "  No packages found for '$Query'." Yellow
        return
    }

    $pkg = _pw_pick_source $results
    if ($pkg) {
        _pw_do_install $pkg
    }
}

function _pw_cmd_uninstall {
    param($Context)
    $Query = $Context.Query
    $Manager = $Context.Manager

    if (-not $Query) {
        _pw_color "  [!] Package name missing." Yellow
        return
    }
    if (-not $Manager) {
        _pw_color "  [!] Specify a manager with -Manager (winget|choco|scoop)" Yellow
        return
    }
    _pw_do_uninstall $Query $Manager
}
