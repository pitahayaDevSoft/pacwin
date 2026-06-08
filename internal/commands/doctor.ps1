# internal/commands/doctor.ps1
# Implementation of doctor and sync commands

function _pw_cmd_doctor {
    param($Context)
    $targetManagers = $Context.targetManagers

    _pw_do_doctor $targetManagers
}

function _pw_cmd_sync {
    param($Context)
    $targetManagers = $Context.targetManagers

    _pw_do_sync $targetManagers
}
