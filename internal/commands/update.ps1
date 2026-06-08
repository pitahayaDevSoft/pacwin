# internal/commands/update.ps1
# Implementation of update and outdated commands

function _pw_cmd_update {
    param($Context)
    $targetManagers = $Context.targetManagers
    $Query = $Context.Query
    $Manager = $Context.Manager

    _pw_handle_update -targetManagers $targetManagers -Query $Query -Manager $Manager
}

function _pw_cmd_outdated {
    param($Context)
    $targetManagers = $Context.targetManagers

    _pw_do_outdated $targetManagers
}
