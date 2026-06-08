# internal/commands/pin.ps1
# Implementation of pin and unpin (hold/unhold) commands

function _pw_cmd_pin {
    param($Context)
    $targetManagers = $Context.targetManagers
    $Query = $Context.Query
    $Manager = $Context.Manager

    if (-not $Query) {
        _pw_do_pin_list $targetManagers
        return
    }
    if (-not $Manager) {
        _pw_color "  [!] Specify a manager with -Manager (winget|choco|scoop)" Yellow
        return
    }
    _pw_do_pin $Query $Manager
}

function _pw_cmd_unpin {
    param($Context)
    $Query = $Context.Query
    $Manager = $Context.Manager

    if (-not $Query -or -not $Manager) {
        _pw_color "  [!] Requires -Query and -Manager." Yellow
        return
    }
    _pw_do_pin $Query $Manager -Unpin
}
