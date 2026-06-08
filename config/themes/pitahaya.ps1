# config/themes/pitahaya.ps1 (Tropical UI Theme)
$script:THEME = @{
    Primary   = "Red"      # #FF2400 → ANSI Red
    Secondary = "Green"    # #2E8B57 → ANSI Green
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
            Name    = 0.5  # Porcentaje del ancho disponible
            ID      = 0.3
            Version = 0.2
        }
    }
}
