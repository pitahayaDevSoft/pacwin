# pacwin Tests (PowerShell Pester 3/4/5 Optimized)

param($ModulePath)

Describe "pacwin core logic" {
    BeforeAll {
        Remove-Module pacwin -ErrorAction SilentlyContinue

        if ($null -ne $ModulePath -and (Test-Path $ModulePath))
        {
            $ModuleFile = Get-Item $ModulePath
        } else
        {
            $current = $PSScriptRoot
            $ModuleFile = $null
            for ($i = 0; $i -lt 5; $i++)
            {
                $candidate = Join-Path $current "pacwin.psm1"
                if (Test-Path $candidate)
                {
                    $ModuleFile = Get-Item $candidate
                    break
                }
                $current = Split-Path $current -Parent
                if (-not $current)
                { break
                }
            }
        }

        if ($null -eq $ModuleFile)
        {
            throw "Unable to locate pacwin.psm1. Search started at: $PSScriptRoot"
        }

        $content = Get-Content $ModuleFile.FullName -Raw -Encoding UTF8
        New-Module -Name pacwin -ScriptBlock ([ScriptBlock]::Create($content)) -Force | Import-Module -Force
    }

    BeforeEach {
        # Global mocks to prevent side effects
        Mock -ModuleName pacwin _pw_is_admin { return $true }
        Mock -ModuleName pacwin _pw_detect_managers { return @{ winget = "winget.exe"; choco = "choco.exe" } }
        Mock -ModuleName pacwin _pw_assert_managers { return $true }
        Mock -ModuleName pacwin _pw_color { param($text, $color, $NoNewline) }
        Mock -ModuleName pacwin _pw_header { param($title) }
    }

    Context "Command Mapping" {
        It "Correctly maps shorthand -Ss to search flow" {
            Mock -ModuleName pacwin _pw_search_all { param($mgrs, $q, $l, $t) return @() }
            Mock -ModuleName pacwin _pw_render_results { param($res, $q) }

            { pacwin -Ss "wget" -Manager winget } | Should Not Throw
            Assert-MockCalled _pw_search_all -ModuleName pacwin
        }

        It "Correctly maps shorthand -S to install flow" {
            Mock -ModuleName pacwin _pw_search_all { return @([PSCustomObject]@{ ID="wget"; Manager="winget"; Name="wget" }) }
            Mock -ModuleName pacwin _pw_pick_source { param($candidates) if ($candidates -is [array])
                { return $candidates[0]
                } return $candidates }
            Mock -ModuleName pacwin _pw_do_install { param($pkg) return $true }

            { pacwin -S "wget" -Manager winget } | Should Not Throw
            Assert-MockCalled _pw_do_install -ModuleName pacwin
        }

        It "Correctly maps shorthand -R to uninstall flow" {
            Mock -ModuleName pacwin _pw_do_uninstall { param($name, $mgr) }

            { pacwin -R "wget" -Manager winget } | Should Not Throw
            Assert-MockCalled _pw_do_uninstall -ModuleName pacwin -ParameterFilter { $name -eq "wget" -and $mgr -eq "winget" }
        }

        It "Correctly maps shorthand -Syu to update flow" {
            Mock -ModuleName pacwin _pw_do_update_all { param($mgrs) }

            { pacwin -Syu } | Should Not Throw
            Assert-MockCalled _pw_do_update_all -ModuleName pacwin -Times 1 -Exactly
        }

        It "Can run pacwin doctor without real environment checks" {
            Mock -ModuleName pacwin _pw_do_doctor { param($mgrs) }

            $null = pacwin doctor

            Assert-MockCalled _pw_do_doctor -ModuleName pacwin -Times 1 -Exactly
        }
    }

    Context "WhatIf Support" {
        It "Supports standard PowerShell -WhatIf" {
            Mock -ModuleName pacwin _pw_search_all { return @([PSCustomObject]@{ Name="test"; ID="test"; Version="1.0"; Source="winget"; Manager="winget" }) }
            Mock -ModuleName pacwin _pw_pick_source { param($candidates) return $candidates[0] }
            Mock -ModuleName pacwin _pw_do_install {
                [CmdletBinding(SupportsShouldProcess)]
                param($pkg)
            }

            { pacwin install "testpkg" -WhatIf } | Should Not Throw
        }
    }

    Context "Security & Sanitization" {
        It "Returns empty string for empty or null inputs" {
            InModuleScope pacwin {
                _pw_sanitize "" | Should Be ""
                _pw_sanitize "   " | Should Be ""
                _pw_sanitize $null | Should Be ""
            }
        }

        It "Preserves valid characters (\w, ., -, +)" {
            InModuleScope pacwin {
                _pw_sanitize "google.chrome" | Should Be "google.chrome"
                _pw_sanitize "valid-id+123_abc" | Should Be "valid-id+123_abc"
                _pw_sanitize "v1.2.3-beta+exp" | Should Be "v1.2.3-beta+exp"
            }
        }

        It "Strips out invalid characters (spaces, @, /, ;, etc.)" {
            InModuleScope pacwin {
                _pw_sanitize "google chrome" | Should Be "googlechrome"
                _pw_sanitize "all.valid-chars_@/123" | Should Be "all.valid-chars_123"
                _pw_sanitize 'bad; comando' | Should Be "badcomando"
                _pw_sanitize "'; rm -r /'" | Should Be "rm-r"
                _pw_sanitize '$(whoami)' | Should Be "whoami"
                _pw_sanitize '`Get-Process`' | Should Be "Get-Process"
                _pw_sanitize "google`nchrome" | Should Be "googlechrome"
            }
        }

        It "Handles shell injection characters" {
            InModuleScope pacwin {
                _pw_sanitize "id|command" | Should Be "idcommand"
                _pw_sanitize "id&command" | Should Be "idcommand"
                _pw_sanitize "id<file" | Should Be "idfile"
                _pw_sanitize "id>file" | Should Be "idfile"
            }
        }

        It "Handles Unicode and Emojis" {
            InModuleScope pacwin {
                # \w in .NET regex usually includes Unicode word characters if configured,
                # but our current regex [^\w\.\-\+] might strip them depending on environment.
                # PR #35 expected them to be handled correctly.
                # We inject emoji and ñ via Unicode chars to avoid file codepage issues in PS 5.1
                $emojiStr = "$([char]0xD83D)$([char]0xDCE6)package"
                _pw_sanitize $emojiStr | Should Be "package"
                
                $tildeStr = "$([char]0x00F1)-package"
                _pw_sanitize $tildeStr | Should Be $tildeStr
            }
        }

        It "Handles numeric and array inputs" {
            InModuleScope pacwin {
                _pw_sanitize 123 | Should Be "123"
                $arr = @("google", "chrome")
                _pw_sanitize $arr | Should Be "googlechrome"
            }
        }
    }

    Context "Search Engine Error Handling" {
        It "Gracefully handles package manager failures" {
            # Use InModuleScope to call the internal _pw_search_all
            InModuleScope pacwin {
                # Provide a manager entry that exists in the switch but points to non-existent file
                $res = _pw_search_all @{ "winget" = "non-existent-exe.exe" } "test" 10 5
                $res | Should BeNullOrEmpty
            }
        }
    }
    Context "Command Dispatcher" {
        It "Recognizes new commands like 'hold' or 'sync'" {
            Mock -ModuleName pacwin _pw_do_pin { param($id, $mgr, $Unpin) }
            Mock -ModuleName pacwin _pw_do_sync { param($managers) }

            # Test 'hold' (pin)
            $null = pacwin hold "test" -Manager winget
            Assert-MockCalled _pw_do_pin -ModuleName pacwin -ParameterFilter { $id -eq "test" }

            # Test 'sync'
            $null = pacwin sync
            Assert-MockCalled _pw_do_sync -ModuleName pacwin -Times 1 -Exactly
        }
    }

    Context "Parsers" {
        It "Parses winget table output" {
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
                $res[0].Source | Should Be "winget"
            }
        }

        It "Parses choco limit-output" {
            InModuleScope pacwin {
                $lines = @(
                    "googlechrome|120.0.0.0",
                    "firefox|121.0"
                )
                $res = _pw_parse_choco_lines $lines
                $res.Count | Should Be 2
                $res[0].Name | Should Be "googlechrome"
                $res[0].ID | Should Be "googlechrome"
                $res[0].Version | Should Be "120.0.0.0"
                $res[1].Name | Should Be "firefox"
            }
        }

        It "Parses scoop multi-format output" {
            InModuleScope pacwin {
                $lines = @(
                    "Results from main bucket:",
                    "    bat (0.24.0)",
                    "    neovim (0.9.4)"
                )
                $res = _pw_parse_scoop_lines $lines
                $res.Count | Should Be 2
                $res[0].Name | Should Be "bat"
                $res[0].ID | Should Be "bat"
                $res[0].Version | Should Be "0.24.0"
            }
        }
    }

    Context "String Truncation (_pw_truncate)" {
        It "Should return a padded string when input is null or empty" {
            InModuleScope pacwin {
                $result = _pw_truncate -str $null -max 5
                $result | Should Be "     "
                $result.Length | Should Be 5

                $resultEmpty = _pw_truncate -str "" -max 3
                $resultEmpty | Should Be "   "
                $resultEmpty.Length | Should Be 3
            }
        }

        It "Should return a padded string when input is shorter than max" {
            InModuleScope pacwin {
                $result = _pw_truncate -str "abc" -max 5
                $result | Should Be "abc  "
                $result.Length | Should Be 5
            }
        }

        It "Should return the exact string when input length equals max" {
            InModuleScope pacwin {
                $result = _pw_truncate -str "abcde" -max 5
                $result | Should Be "abcde"
                $result.Length | Should Be 5
            }
        }

        It "Should truncate and append a dot when input is longer than max" {
            InModuleScope pacwin {
                $result = _pw_truncate -str "abcdefg" -max 5
                $result | Should Be "abcd."
                $result.Length | Should Be 5
            }
        }
    }

    Context "Integration Scenarios" {
        It "Handles no managers detected gracefully" {
            Mock -ModuleName pacwin _pw_detect_managers { return @{} }
            Mock -ModuleName pacwin _pw_assert_managers { return $false }
            { pacwin } | Should Not Throw
        }

        It "Handles search timeouts returning partial results" {
            InModuleScope pacwin {
                # Mock a task that completes and one that does not
                $ps1 = New-Object PSObject
                $ps1 | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value { return @("Name  Id  Version", "-----------------", "git   git  2.4.0") }
                $ps1 | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

                $task1 = [PSCustomObject]@{
                    Key = "winget"
                    AsyncResult = [PSCustomObject]@{ IsCompleted = $true }
                    PowerShell = $ps1
                }

                $ps2 = New-Object PSObject
                $ps2 | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

                $task2 = [PSCustomObject]@{
                    Key = "choco"
                    AsyncResult = [PSCustomObject]@{ IsCompleted = $false }
                    PowerShell = $ps2
                }
                
                $poolMock = New-Object PSObject
                $poolMock | Add-Member -MemberType ScriptMethod -Name Close -Value {}
                $poolMock | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}

                $poolCtx = [PSCustomObject]@{
                    Pool = $poolMock
                    Tasks = @($task1, $task2)
                }
                # This simulates a partial timeout collection
                $res = Receive-PwTaskPool -PoolContext $poolCtx
                @($res).Count | Should Be 1
                $res[0].Name | Should Be "git"
            }
        }

        It "Handles empty inputs safely without throwing" {
            { pacwin "" } | Should Not Throw
            { pacwin -Command "" -Query "" } | Should Not Throw
        }

        It "Gracefully reports failure on HTTP 404" {
            Mock -ModuleName pacwin Get-Module { return [PSCustomObject]@{ Path = "C:\fake\pacwin\pacwin.psm1" } }
            Mock -ModuleName pacwin Test-Path { return $false } -ParameterFilter { $Path -like "*\.git" }
            Mock -ModuleName pacwin Invoke-WebRequest { throw "The remote server returned an error: (404) Not Found." }
            
            { _pw_self_update } | Should Not Throw
        }

        It "Performs export and import roundtrip correctly" {
            InModuleScope pacwin {
                function winget {}
                function choco {}
                function scoop {}

                $tempFile = Join-Path $PSScriptRoot "test-export.json"
                try {
                    # Mock winget, choco and scoop commands used in export with ModuleName
                    Mock -ModuleName pacwin winget { return '{"Sources":[{"Packages":[{"PackageIdentifier":"git.git"}]}]}' }
                    Mock -ModuleName pacwin choco { return "node|1.0" }
                    Mock -ModuleName pacwin scoop { return '{"apps":[{"Name":"neovim"}]}' }
                    
                    $mgrs = @{ "winget" = "winget.exe"; "choco" = "choco.exe"; "scoop" = "scoop.exe" }
                    
                    _pw_do_export $mgrs $tempFile
                    
                    Test-Path $tempFile | Should Be $true
                    $content = Get-Content $tempFile -Raw | ConvertFrom-Json
                    $content.packages.Count | Should Be 3
                    
                    # Mock install commands
                    Mock -ModuleName pacwin winget { }
                    Mock -ModuleName pacwin choco { }
                    Mock -ModuleName pacwin scoop { }
                    
                    { _pw_do_import $mgrs $tempFile } | Should Not Throw
                    
                    Assert-MockCalled winget -ModuleName pacwin -Times 2 -Exactly
                    Assert-MockCalled choco -ModuleName pacwin -Times 2 -Exactly
                    Assert-MockCalled scoop -ModuleName pacwin -Times 2 -Exactly
                } finally {
                    if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
                }
            }
        }
    }
}
