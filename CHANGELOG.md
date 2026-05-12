<!-- markdownlint-disable MD024 -->
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] - Unreleased
Fixed
Scoop Detection: Bypassed `sfsu` PowerShell hooks and other alias wrappers in `_pw_exe` to ensure Scoop is reliably detected when using third-party search optimizers.

## [0.3.0] - 2026-05-12

### Added
- **Comprehensive Winget Parser Tests**: Reached full coverage for multiple table formats, segmented separators, and noise filtering.
- **Search Engine Robustness**: Implemented graceful suppression and reporting of package manager executable failures during concurrent searches.

### Changed
- **Winget Parser Refactor**: Introduced `_pw_extract_column` helper to unify and simplify locale-aware table parsing logic.
- **Update Logic Flattening**: Refactored `_pw_handle_update` using early returns to eliminate deeply nested conditionals and improve maintainability.
- **Performance Optimizations**: Replaced slow `ForEach-Object` pipeline usages with high-performance `foreach` loops and `Generic.List` collections for ~3x speedup.
- **Enhanced Test Environment**: Improved Pester 5 environment isolation by ensuring clean module loading/unloading between test suites.

### Fixed
- **Winget Header Sensitivity**: Parser is now more resilient to non-English headers and varying column widths.
- **Search Error Suppression**: Missing package managers no longer cause the search command to throw unhandled exceptions.

### Security
- **Reinforced Sanitization**: Expanded OWASP-style injection tests for input sanitization in `_pw_sanitize`, including Unicode/Emoji handling and array input validation.

## [0.2.7] - 2026-05-03

### Added

- **Interactive Search by Default**: `pacwin search <query>` now shows a numbered list and prompts for package selection to install (yaourt-style). Use `-NoInteractive` or `-ni` for non-interactive mode.

### Changed

- Search behavior now defaults to interactive mode with numbered package selection.

## [0.2.6] - 2026-04-21

### Added

- **Comprehensive Parser Tests**: Reached full coverage for the winget, chocolatey, and scoop output parsers via Pester.
- **Strict Mode Enforcement**: Activated `Set-StrictMode -Version 2.0` to guarantee high code quality and prevent uninitialized variable usage.
- **Advanced Security Hardening**: Implemented robust path validation (`_pw_validate_path`) and expanded OWASP-style injection tests for input sanitization (`_pw_sanitize`), replacing double quotes with single quotes to block early variable expansion.

### Changed

- **Centralized Error Mapping**: Replaced raw switch statements with a hash map (`$script:ErrorCodes`) for clean, uniform exit-code handling across all package managers.

## [0.2.5] - 2026-04-21

### Fixed

- Character visualization issues in spinners for non-UTF8 terminals (PS 5.1).
- Forced UTF8 console output for better rendering of UI elements.

## [0.2.4] - 2026-04-21

### Fixed

- Hardened `pacwin.psd1` for PowerShell Gallery compatibility (fixed "Cannot index into a null array" error).
- Added `FileList` to module manifest to ensure clean deployments.
- Fixed variable interpolation bug in `self-update` error handler.
- Improved manifest compatibility with older versions of PowerShellGet.

## [0.2.3] - 2026-04-21

### Added

- **Premium Spinner UI**: Real-time progress indicator for parallel searches, showing the status of each manager individually (`[√]`, `[/]`, etc.).
- **Unified Concurrency Engine**: Replaced separate PS5/PS7 search logic with a robust, high-performance RunspacePool implementation for better stability and UI control.
- **Self-Update Command**: Added a built-in mechanism to update `pacwin` automatically from GitHub or via Git.
- **Improved UX**: Visual feedback now prevents the appearance of a "stuck" terminal during long searches, and the help menu has been expanded.

## [0.2.2] - 2026-04-21

### Added

- **Global Search Timeout**: New `-Timeout` parameter to control the maximum wait time for parallel searches.
- **Improved Error Transparency**: Replaced silent error suppression with detailed reporting for manager failures and export operations.

### Changed

- **Language-Agnostic Winget Parser**: Refactored the Winget parser to work across all Windows locales by dynamically detecting column offsets.
- **Centralized Logic**: Unified parsing logic for `sync` and `outdated` commands to ensure consistency and reliability.

## [0.2.1] - 2026-04-17

### Added

- **Pro Header & Dashboard**: Premium ASCII banner with real-time manager presence indicators.
- **Categorized Help UI**: More intuitive, professional, and color-coded help menu.
- **Scripting Support**: New `-NoHeader` switch to suppress banner in non-interactive scripts and pipes.
- **Dynamic Documentation**: High-speed, fluid VHS-recorded demo integration.

### Fixed

- **Winget Parsing Engine**: Robust cleanup of help/usage output that previously polluted search results.
- **Command Completion**: Register-ArgumentCompleter now includes all advanced commands (`hold`, `sync`, `dupes`).
- **Uninstall Precision**: Winget uninstallation now uses `--id` to ensure unique package removal.

## [0.2.0] - 2026-04-14

### Added

- **Feature `pin / hold`**: Freeze packages to prevent accidental updates.
- **Feature `export / import`**: Backup and restore your entire package list to a JSON file.
- **Feature `doctor`**: New environment diagnostic tool to check PS version, managers, and connectivity.
- **Feature `sync`**: Detect cross-manager duplicates (e.g., same app installed via winget and choco).
- **Tab Completion**: Intelligent autocompletion for commands, managers, and installed package IDs.
- **PowerShell 5.1 Robustness**: Full compatibility fixes for legacy PowerShell versions (if-expressions, null-coalescing, and encoding).
- **Admin Privilege Awareness**: Automated warnings when performing system-level actions (especially for Chocolatey) from non-elevated sessions.
- **WhatIf Support**: Standard PowerShell `-WhatIf` support for safe command simulation.

### Changed

- **Documentation Overhaul**: Updated Wiki, README, and Technical Docs with new features and administrator requirements.
- **Refactored `sync` logic**: Improved duplicate detection with name normalization.

### Fixed

- Syntax errors in `pacwin.psm1` preventing loading in PowerShell 5.1.
- Character encoding corruption in UI elements for legacy consoles.
- Scoop output parsing errors for non-string objects.

## [0.1.0] - 2026-04-09

### Added

- **Hybrid Search Engine**: New search core that automatically detects PowerShell version.
  - PowerShell 7+: Uses `ForEach-Object -Parallel` for native threading.
  - PowerShell 5.1: Uses `RunspacePool` for lightweight asynchronous execution.
- **Error Interpretation System**: Logic to parse and report manager-specific exit codes and console output for Winget, Chocolatey, and Scoop.
- **Remote Installer**: Added `get-pacwin.ps1` for automated installation via `curl | powershell`.
- **Technical Documentation**: Comprehensive `DOCUMENTATION.md` detailing architecture and API.

### Changed

- **Internationalization**: Full project refactor to English (Code, Comments, UI).
- **Aesthetic Overhaul**: Replaced extended ASCII box characters with standard ASCII for better indentation and compatibility.
- **Installer Refactor**: Simplified `install.ps1` with automatic profile detection and standard module pathing.
- **README Update**: New production-grade README with status badges and pacman mapping table.

### Fixed

- High CPU usage during searches by replacing `Start-Job` with `Runspaces`.
- Syntax errors and reserved variable warnings ($input renamed to $targetInput).
- Encoding issues in PowerShell 5.1 (all files saved with UTF-8 BOM).

### Security

- Reinforced input sanitization logic in `_pw_sanitize`.

---
