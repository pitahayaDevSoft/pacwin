# internal/commands/export.ps1
# Implementation of export and import commands

function _pw_cmd_export {
    param($Context)
    $targetManagers = $Context.targetManagers
    $Query = $Context.Query

    _pw_do_export $targetManagers $Query
}

function _pw_cmd_import {
    param($Context)
    $targetManagers = $Context.targetManagers
    $Query = $Context.Query

    if (-not $Query) {
        _pw_color "  [!] Specify the export file path." Yellow
        return
    }
    _pw_do_import $targetManagers $Query
}
