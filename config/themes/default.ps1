# config/themes/default.ps1 (Default Theme - Pitahaya Rebrand)
$themePath = Join-Path $PSScriptRoot "pitahaya.ps1"
if (Test-Path $themePath) {
    . $themePath
} else {
    $script:THEME = @{
        Primary   = "Red"
        Secondary = "Green"
        Success   = "Green"
        Warning   = "Yellow"
        Danger    = "Red"
        Dim       = "DarkGray"
        Version   = "0.6.0"

        Layout = @{
            TitleWidth = 68
            MinWidth   = 80
            Separator  = [string][char]0x2501 * 68
            Spinner    = "|/-\"
            ColWidths  = @{
                Name    = 0.5
                ID      = 0.3
                Version = 0.2
            }
        }
    }
}
