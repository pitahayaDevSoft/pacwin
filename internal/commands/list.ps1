# internal/commands/list.ps1
# Implementation of list command

function _pw_cmd_list {
    param($Context)
    $targetManagers = $Context.targetManagers
    $Query = $Context.Query

    _pw_do_list $targetManagers $Query
}
