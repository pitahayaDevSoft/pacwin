Describe "pacwin Parsers" {
    BeforeAll {
        $psm1 = Join-Path $PSScriptRoot "../pacwin.psm1"
        while (Get-Module pacwin)
        { Remove-Module pacwin -ErrorAction SilentlyContinue
        }
        $content = Get-Content $psm1 -Raw -Encoding UTF8
        New-Module -Name pacwin -ScriptBlock ([ScriptBlock]::Create($content)) -Force | Import-Module -Force
    }

    Context "Column Extractor (_pw_extract_column)" {
        It "Should extract a column within bounds" {
            InModuleScope pacwin {
                $line = "PackageName    ID-123    1.2.3"
                _pw_extract_column $line 0 11 | Should Be "PackageName"
                _pw_extract_column $line 15 6 | Should Be "ID-123"
            }
        }

        It "Should handle out of bounds gracefully" {
            InModuleScope pacwin {
                $line = "Short"
                _pw_extract_column $line 10 5 "N/A" | Should Be "N/A"
            }
        }

        It "Should handle trailing columns with small length" {
            InModuleScope pacwin {
                $line = "Part1  Part2"
                _pw_extract_column $line 7 100 | Should Be "Part2"
            }
        }

        It "Should return fallback for empty or whitespace columns" {
            InModuleScope pacwin {
                $line = "Name          Version"
                _pw_extract_column $line 5 5 "Empty" | Should Be "Empty"
            }
        }
    }

    Context "Winget Parser (_pw_parse_winget_lines)" {
        It "Should parse standard winget table output" {
            InModuleScope pacwin {
                $lines = @(
                    "Name               Id               Version     Source",
                    "------------------------------------------------------",
                    "Google Chrome      Google.Chrome    120.0.0.0   winget",
                    "Mozilla Firefox    Mozilla.Firefox  121.0       winget"
                )
                $res = _pw_parse_winget_lines $lines
                $res.Count | Should Be 2
                $res[0].Name | Should Be "Google Chrome"
                $res[0].ID | Should Be "Google.Chrome"
                $res[0].Version | Should Be "120.0.0.0"
            }
        }

        It "Should parse segmented separator format (Standard)" {
            InModuleScope pacwin {
                $lines = @(
                    "Name                           Id                               Version          Source",
                    "------------------------------------------------------------------------------------------",
                    "Google Chrome                  Google.Chrome                    120.0.6099.130   winget",
                    "Visual Studio Code             Microsoft.VisualStudioCode       1.85.1           winget"
                )
                $results = _pw_parse_winget_lines $lines
                $results.Count | Should Be 2

                $results[0].Name | Should Be "Google Chrome"
                $results[0].ID | Should Be "Google.Chrome"
                $results[0].Version | Should Be "120.0.6099.130"
                $results[0].Source | Should Be "winget"

                $results[1].Name | Should Be "Visual Studio Code"
                $results[1].ID | Should Be "Microsoft.VisualStudioCode"
                $results[1].Version | Should Be "1.85.1"
            }
        }

        It "Should parse single long separator format" {
            InModuleScope pacwin {
                $lines = @(
                    "Name      Id      Version",
                    "-------------------------",
                    "App1      ID1     1.0",
                    "App2      ID2     2.0"
                )
                $results = _pw_parse_winget_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "App1"
                $results[0].ID | Should Be "ID1"
                $results[0].Version | Should Be "1.0"
            }
        }

        It "Should handle no separator (Fallback heuristic)" {
            InModuleScope pacwin {
                $lines = @(
                    "App1    ID1    1.0",
                    "App2    ID2    2.0"
                )
                $results = _pw_parse_winget_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "App1"
                $results[0].ID | Should Be "ID1"
                $results[0].Version | Should Be "1.0"
            }
        }

        It "Should ignore noise lines (Progress bars, headers, etc.)" {
            InModuleScope pacwin {
                $lines = @(
                    "Name                           Id                               Version          Source",
                    "------------------------------------------------------------------------------------------",
                    "  0% [                              ]",
                    "Google Chrome                  Google.Chrome                    120.0.6099.130   winget",
                    " 50% [###########                  ]",
                    "Visual Studio Code             Microsoft.VisualStudioCode       1.85.1           winget",
                    "100% [#############################]"
                )
                $results = _pw_parse_winget_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "Google Chrome"
                $results[1].Name | Should Be "Visual Studio Code"
            }
        }

        It "Should handle missing versions in fallback heuristic" {
            InModuleScope pacwin {
                $lines = @(
                    "AppWithoutVersion    IDOnly"
                )
                $results = _pw_parse_winget_lines $lines
                @($results).Count | Should Be 1
                $results[0].Name | Should Be "AppWithoutVersion"
                $results[0].ID | Should Be "AppWithoutVersion"
                $results[0].Version | Should Be "IDOnly"
            }
        }

        It "Should handle truncated lines gracefully" {
            InModuleScope pacwin {
                $lines = @(
                    "Name      Id      Version",
                    "----------  ------  -------",
                    "Short"
                )
                $results = _pw_parse_winget_lines $lines
                $results.Count | Should Be 0
            }
        }

        It "Handles truncated winget output gracefully" {
            InModuleScope pacwin {
                $lines = @(
                    "Name               Id               Version     Source",
                    "------------------------------------------------------",
                    "Truncated Package  Truncated.P...   1.0.0       winget"
                )
                $res = _pw_parse_winget_lines $lines
                $res.Count | Should Be 1
                $res[0].Name | Should Be "Truncated Package"
                $res[0].ID | Should Be "Truncated.P..."
                $res[0].Version | Should Be "1.0.0"
            }
        }
    }

    Context "Scoop Parser (_pw_parse_scoop_lines)" {
        It "Should return an empty list when no lines are provided" {
            InModuleScope pacwin {
                $results = _pw_parse_scoop_lines @()
                $results.Count | Should Be 0
            }
        }

        It "Should parse modern scoop format: '  name (version) [bucket]'" {
            InModuleScope pacwin {
                $lines = @(
                    "Results from local buckets...",
                    "  7zip (23.01) [main]",
                    "  git (2.42.0.windows.2) [main]"
                )
                $results = _pw_parse_scoop_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "7zip"
                $results[0].Version | Should Be "23.01"
            }
        }
    }

    Context "Chocolatey Parser (_pw_parse_choco_lines)" {
        It "Should parse simple name|version format" {
            InModuleScope pacwin {
                $lines = @(
                    "7zip|23.01.0",
                    "git|2.42.0"
                )
                $results = _pw_parse_choco_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "7zip"
                $results[0].Version | Should Be "23.01.0"
            }
        }

        It "Handles unicode package names in choco" {
            InModuleScope pacwin {
                $lines = @(
                    "ñandú-package|1.2.3-beta",
                    "él-app-unicode|2.0.0"
                )
                $res = _pw_parse_choco_lines $lines
                $res.Count | Should Be 2
                $res[0].Name | Should Be "ñandú-package"
                $res[0].Version | Should Be "1.2.3-beta"
                $res[1].Name | Should Be "él-app-unicode"
                $res[1].Version | Should Be "2.0.0"
            }
        }
    }

    Context "Scoop Outdated Parser (_pw_parse_scoop_outdated_lines)" {
        It "Should parse Scoop classic 'has a new version' format" {
            InModuleScope pacwin {
                $lines = @(
                    "bat has a new version: 0.24.0",
                    "neovim has a new version"
                )
                $results = _pw_parse_scoop_outdated_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "bat"
                $results[0].Version | Should Be "Later"
                $results[1].Name | Should Be "neovim"
            }
        }

        It "Should parse Scoop arrow 'version -> newversion' format" {
            InModuleScope pacwin {
                $lines = @(
                    "  bat (0.23.0 -> 0.24.0)",
                    "  neovim (0.9.4 -> 0.9.5)"
                )
                $results = _pw_parse_scoop_outdated_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "bat"
                $results[0].Version | Should Be "0.24.0"
                $results[1].Name | Should Be "neovim"
                $results[1].Version | Should Be "0.9.5"
            }
        }

        It "Should parse Scoop 'app: old -> new' format" {
            InModuleScope pacwin {
                $lines = @(
                    "bat: 0.23.0 -> 0.24.0",
                    "neovim : 0.9.4 -> 0.9.5"
                )
                $results = _pw_parse_scoop_outdated_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "bat"
                $results[0].Version | Should Be "0.24.0"
                $results[1].Name | Should Be "neovim"
            }
        }

        It "Should parse sfsu outdated tabular format (supports multi-language)" {
            InModuleScope pacwin {
                $lines = @(
                    "Name      Current      Available",
                    "----      -------      ---------",
                    "bat       0.23.0       0.24.0",
                    "neovim    0.9.4        0.9.5"
                )
                $results = _pw_parse_scoop_outdated_lines $lines
                $results.Count | Should Be 2
                $results[0].Name | Should Be "bat"
                $results[0].Version | Should Be "0.24.0"
                $results[1].Name | Should Be "neovim"
                $results[1].Version | Should Be "0.9.5"
            }
        }

        It "Should handle empty inputs or headers gracefully" {
            InModuleScope pacwin {
                $lines = @(
                    "Results from local buckets...",
                    "---",
                    ""
                )
                $results = _pw_parse_scoop_outdated_lines $lines
                $results.Count | Should Be 0
            }
        }

        It "Handles scoop bucket permission errors" {
            InModuleScope pacwin {
                $lines = @(
                    "scoop: Access denied to C:\fake",
                    "Error: Couldn't find manifest for 'fake'"
                )
                $res = _pw_parse_scoop_outdated_lines $lines
                $res.Count | Should Be 0
            }
        }
    }
}
