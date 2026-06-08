# internal/commands/system.ps1
# Implementation of status, version, help, and self-update commands

function _pw_cmd_status {
    param($Context)
    $managers = $Context.managers

    _pw_color "  Binary Paths:" Cyan
    foreach ($key in $managers.Keys) {
        _pw_color "  * $key " Gray -NoNewline
        _pw_color "-> $($managers[$key])" DarkGray
    }
}

function _pw_cmd_version {
    param($Context)
    _pw_color "  pacwin" White -NoNewline
    _pw_color " v$($script:THEME.Version)" Gray
    _pw_color "  PowerShell $($PSVersionTable.PSVersion)" Gray
}

function _pw_cmd_self_update {
    param($Context)
    _pw_self_update
}

function _pw_cmd_help {
    param($Context)
    _pw_show_help
}
