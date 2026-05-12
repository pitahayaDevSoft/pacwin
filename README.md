# pacwin

<!-- markdownlint-disable MD033 -->

<!-- markdownlint-enable MD033 -->

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/pacwin.svg?color=blue&label=PowerShell%20Gallery)](https://www.powershellgallery.com/packages/pacwin)
[![Downloads](https://img.shields.io/powershellgallery/dt/pacwin.svg?color=blue&label=Downloads)](https://www.powershellgallery.com/packages/pacwin)
![PowerShell](https://img.shields.io/badge/powershell-5.1%20%7C%207%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Windows-blue)

**One CLI. Three managers. Zero excuses for missing `pacman`.**

`pacwin` unifies **winget**, **chocolatey**, and **scoop** behind a single, `pacman`-inspired interface for Windows. If you've ever typed `pacman -Syu` out of pure muscle memory on a PowerShell prompt—and felt the void when it didn't work—this tool was written for you.

![pacwin demo](docs/demo.gif)

---

## The Problem

You know the drill. You grew up on `pacman`, `apt`, or `dnf`. Package management was a solved problem: one tool, one syntax, done. Then corporate IT handed you a Windows laptop.

Now you juggle **three** separate package managers, each with its own quirks:

| Pain Point | winget | chocolatey | scoop |
|:-----------|:-------|:-----------|:------|
| Search syntax | `winget search` | `choco search` | `scoop search` |
| Install syntax | `winget install` | `choco install` | `scoop install` |
| Output format | Column-based, locale-dependent | Pipe-delimited (`\|`) | Bracket-based or columnar |
| Silent failure mode | Cryptic HRESULT codes | Exit code 1 for everything | Bucket not found, no error |
| Requires admin? | Sometimes | Almost always | Never |

Three tools. Three syntaxes. Three failure modes. Zero consistency. That's not package management—that's archaeology.

## The Solution

`pacwin` gives you back what Windows took away: **one command to rule them all.**

```
pacwin -Ss vim        # Search across all managers
pacwin -S neovim      # Install from the best available source
pacwin -Syu           # Update everything
pacwin -R nodejs      # Uninstall cleanly
pacwin -Q             # List all installed packages
```

If you can use `pacman`, you already know `pacwin`. And if your team prefers verbose syntax, that works too—`pacwin search`, `pacwin install`, `pacwin update`. No gatekeeping.

### Why Not Just Use [insert wrapper here]?

- Most wrappers spawn a **new PowerShell process per manager**. That's 3+ seconds of overhead on every search.
- `pacwin` uses a **hybrid concurrency engine**: `RunspacePool` threads on PS 5.1, `ForEach-Object -Parallel` on PS 7+. Same process, shared memory, minimal overhead.
- Exit codes like `3010` (reboot needed) or `0x8A15002E` (no manifest) are **decoded in real time**, not silently swallowed.

---

## Quick Start

### Install from PowerShell Gallery (Recommended)

```powershell
Install-Module -Name pacwin -Scope CurrentUser
```

That's it. No `makepkg`, no `PKGBUILD`, no AUR helper—just one line. (We know. It feels wrong. But it works.)

### Install via curl (One-Liner)

For the `curl | sh` crowd (we see you):

```powershell
curl -sSL https://raw.githubusercontent.com/julesklord/pacwin/main/get-pacwin.ps1 | powershell -Command -
```

### Install from Source

For those who read every line before running anything (respect):

```powershell
git clone https://github.com/julesklord/pacwin.git
cd pacwin
.\install.ps1
```

Restart your terminal. Then:

```powershell
pacwin search vlc
```

**Expected output:**

```text
  #    Name           ID               Version    Source
  -----------------------------------------------------------
  [1 ] vlc            vlc              3.0.21     chocolatey
  [2 ] VideoLAN.VLC   VideoLAN.VLC     3.0.21     winget
```

Multiple sources, one table. Pick your poison.

---

## Command Reference

`pacwin` speaks two dialects: **pacman-style flags** for muscle memory, and **verbose commands** for readability. Both are first-class citizens.

| Task | Verbose | pacman-style |
|:-----|:--------|:-------------|
| **Search** | `pacwin search <query>` | `pacwin -Ss <query>` |
| **Install** | `pacwin install <id>` | `pacwin -S <id>` |
| **Uninstall** | `pacwin uninstall <id>` | `pacwin -R <id>` |
| **Update all** | `pacwin update` | `pacwin -Syu` |
| **List installed** | `pacwin list` | `pacwin -Q` |
| **Check outdated** | `pacwin outdated` | `pacwin -Qu` |
| **Hold / Pin** | `pacwin hold <id>` | `pacwin pin <id>` |
| **Health check** | `pacwin doctor` | `pacwin check` |
| **Deduplicate** | `pacwin sync` | `pacwin dupes` |
| **Self-update** | `pacwin self-update` | `pacwin update-self` |

### Filter by Manager

Don't trust one of the backends? Force a specific source:

```powershell
pacwin search nodejs -Manager scoop    # scoop only
pacwin install git -Manager winget     # winget only
```

### Search Timeout

Some scoop buckets are *glacially* slow. Set a ceiling:

```powershell
pacwin search python -Timeout 45
```

### Scripting & CI/CD

Suppress the banner for automation pipelines:

```powershell
pacwin search terraform -NoHeader
```

Combine with `-WhatIf` for dry runs (native PowerShell `SupportsShouldProcess` integration):

```powershell
pacwin install docker -WhatIf
```

---

## Architecture

The `pacwin` module (~1500 lines, `pacwin.psm1`) is a single PowerShell script module with no build step.

```mermaid
flowchart TD
  subgraph entry["Entry Point"]
    pacwin["pacwin function<br/><code>pacwin.psm1</code>"]
  end

  subgraph validation["Input & Safety"]
    sanitize["_pw_sanitize<br/>regex validation"]
    validate_path["_pw_validate_path<br/>path traversal check"]
    strict["Set-StrictMode<br/>Version 2.0"]
  end

  subgraph dispatch["Command Dispatch"]
    parse_args["_pw_parse_args<br/>flag routing"]
    switch["switch -Regex<br/>command router"]
  end

  subgraph search["Search Engine"]
    search_all["_pw_search_all<br/>concurrency fan-out"]
    runspace["RunspacePool (PS 5.1)<br/>ForEach-Object -Parallel (PS 7+)"]
  end

  subgraph parsers["Output Parsers"]
    parse_winget["_pw_parse_winget_lines<br/>locale-aware columns"]
    parse_choco["_pw_parse_choco_lines<br/>pipe-delimited split"]
    parse_scoop["_pw_parse_scoop_lines<br/>bracket + columnar"]
  end

  subgraph external["External CLIs"]
    winget_cli["winget search"]
    choco_cli["choco search"]
    scoop_cli["scoop search"]
  end

  subgraph operations["Package Operations"]
    install["_pw_do_install"]
    uninstall["_pw_do_uninstall"]
    update["_pw_do_update_single<br/>_pw_do_update_all"]
  end

  subgraph output["Output & Rendering"]
    render["_pw_render_results<br/>ASCII table"]
    color["_pw_color<br/>Green/Yellow/Red"]
    pick["_pw_pick_source<br/>interactive selector"]
  end

  subgraph model["Normalized Model"]
    pscustom["PSCustomObject<br/>Name, ID, Version,<br/>Source, Manager"]
  end

  pacwin --> parse_args
  pacwin --> strict
  parse_args --> switch
  sanitize --> search_all
  switch --> search_all
  switch --> install
  switch --> uninstall
  switch --> update

  search_all --> runspace
  runspace --> parse_winget
  runspace --> parse_choco
  runspace --> parse_scoop

  parse_winget --> winget_cli
  parse_choco --> choco_cli
  parse_scoop --> scoop_cli

  parse_winget --> pscustom
  parse_choco --> pscustom
  parse_scoop --> pscustom

  pscustom --> render
  render --> color
  search_all --> pick

  install --> winget_cli
  install --> choco_cli
  install --> scoop_cli

  classDef blue fill:#dbeafe,stroke:#2563eb,stroke-width:1.5px,color:#172554
  classDef amber fill:#fef3c7,stroke:#d97706,stroke-width:1.5px,color:#78350f
  classDef green fill:#dcfce7,stroke:#16a34a,stroke-width:1.5px,color:#14532d
  classDef gray fill:#f8fafc,stroke:#334155,stroke-width:1.5px,color:#0f172a

  class pacwin,parse_args,switch blue
  class sanitize,validate_path,strict amber
  class search_all,runspace,render,color,pick green
  class parse_winget,parse_choco,parse_scoop,pscustom gray
```

**Key design decisions:**
- **Single file**: No compilation, no dependencies beyond PowerShell 5.1+
- **Same-process concurrency**: Runspaces (PS 5.1) or `ForEach-Object -Parallel` (PS 7+) — no child processes
- **Per-manager parsers**: Each CLI has unique output format (locale-aware winget, pipe-delimited choco, dual-mode scoop)
- **Normalized model**: All parsers emit `[PSCustomObject]` with unary comma wrapping for StrictMode 2.0 compliance

### Concurrency Engine

The core design decision was performance without complexity:

| PowerShell Version | Concurrency Model | Why |
|:-------------------|:-------------------|:----|
| **5.1** | `RunspacePool` (threads) | Avoids `Start-Job` overhead (~3s saved per search) |
| **7+** | `ForEach-Object -Parallel` | Native pipeline parallelism, cleaner syntax |

Both paths execute manager CLI calls concurrently within the **same process**. No child processes, no serialization overhead.

### Parser Architecture

Each manager has a dedicated output parser because, of course, none of them agree on a format:

- **`_pw_parse_winget_lines`** — Heuristic column-boundary detection. Handles locale-dependent headers (Spanish, German, etc.) without hardcoding column names.
- **`_pw_parse_choco_lines`** — Pipe-delimited (`|`) split with whitespace trimming.
- **`_pw_parse_scoop_lines`** — Dual-mode: modern bracket format `name (version) [bucket]` and legacy columnar output.

All parsers return `[System.Collections.Generic.List[PSCustomObject]]` with unary comma wrapping to prevent PowerShell's collection unrolling under `Strict Mode 2.0`.

### Security Model

- **Input sanitization** via `_pw_sanitize`: strict regex validation (`a-zA-Z0-9._\-@/`). Anything else is rejected before it reaches a shell call.
- **Path validation** via `_pw_validate_path`: blocks directory traversal and null-byte injection.
- **`Set-StrictMode -Version 2.0`** enforced module-wide. No uninitialized variables, no silent property access failures.
- **No `Invoke-Expression`**. Ever. All external calls go through direct invocation.

### Internal Naming

All internal functions use the `_pw_` prefix to avoid polluting your global namespace. If you `Get-Command _pw_*` after loading the module, that's by design—they're scoped to the module.

---

## Requirements

| Component | Minimum | Recommended |
|:----------|:--------|:------------|
| **OS** | Windows 10 | Windows 11 |
| **PowerShell** | 5.1 | 7.2+ |
| **Package Managers** | At least one of: `winget`, `choco`, `scoop` | All three in PATH |

Run `pacwin doctor` to verify your environment.

---

## Testing

The test suite uses a **bundled Pester 5.5** module (no global install required):

```powershell
Import-Module ./tests/modules/Pester
Invoke-Pester ./tests
```

Current coverage:

| Suite | Tests | Scope |
|:------|:------|:------|
| `pacwin.Tests.ps1` | 12 | Core logic, security, command dispatch, parsers, string truncation |
| `parsers.Tests.ps1` | 12 | Scoop multi-format, choco pipe-split, edge cases, legacy formats |
| **Total** | **24** | All passing ✅ |

---

## Contributing

1. **Issues**: Use the [GitHub issue tracker](https://github.com/julesklord/pacwin/issues). Bug reports with `pacwin doctor` output are appreciated.
2. **Pull Requests**: Fork, branch, test, PR. Keep the `_pw_` prefix convention. Run the full test suite before submitting.
3. **Code Style**: Single `.psm1` file, `#region` blocks for organization, `Strict Mode 2.0` compliance mandatory.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

Use it, fork it, ship it. Just don't blame us if you start missing `pacman` even *more*.

---

### Metadata

- **Status**: Stable (v0.3.1)
- **Requirements**: Windows PowerShell 5.1 or PS 7.2+
- **Maintainers**: [julesklord](https://github.com/julesklord)
- **Known issues**: Scoop searches can timeout if bucket metadata is stale — run `scoop update` to refresh. Same energy as `pacman -Syy`, different tool.
