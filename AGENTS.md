# AI Agent Guidelines (`nikrun/sdk`)

**Nikrun** is a zero-config, user-scope toolchain and developer ecosystem for **Object Pascal / Free Pascal**, split across three core repositories under `https://github.com/nikrun`:

1. **[`nikrun/sdk`](https://github.com/nikrun/sdk)** *(this repository)* — Portable Free Pascal SDK build pipeline, `versions.json`, `sdk-manifest.json` / `sdk-index.json` schemas, and nightly GitHub Releases (`fpc-sdk-latest`).
2. **[`nikrun/cli`](https://github.com/nikrun/cli)** — Standalone `nik` CLI (`src/nik.*.pas`), `nikrun-lsp-protocol` (`lsp-protocol/`), and ecosystem design radar (`docs/design-radar.md`).
3. **[`nikrun/vscode`](https://github.com/nikrun/vscode)** — Official `vscode-nikrun` Visual Studio Code extension.

---

## Core Engineering Rules

- **Terminology & Typography:**
  - **Nikrun** (capitalized prose, no backticks) refers to the overall project and ecosystem.
  - **`nik`** (lowercase in inline code backticks in Markdown; `nik` in terminal output) refers specifically to the CLI tool binary and its commands.
  - Keep technical identifiers (`~/.nikrun`, `--nikrun-home`, `NIKRUN_HOME`, `nikrun-fpc-sdk-*`, `sdk-manifest.json`, `sdk-index.json`, `vscode-nikrun`, `nik.yaml`) in their exact lowercase technical form.
- **Clean-Room Supply Chain:** Bootstrap strictly from official Free Pascal releases/sources (`versions.json`); never depend on unverified third-party compiler binaries.
- **Archive Contract Stability:** Changes to `sdk-manifest.json` or `sdk-index.json` fields must remain backward-compatible with `nik` (`nik.sdk.config.pas` in `nikrun/cli`).
- **Cross-Platform Parity:** Support `win64`, `linux`, and `darwin` (`x86_64` and `aarch64`) cleanly in PowerShell (`pwsh` 7+ on Linux/macOS and Windows PowerShell / `pwsh` on Windows).

---

## Build & Verification Commands

Run commands from the repository root (`pwsh` / Windows PowerShell):

```powershell
# Validate upstream Git source & extracted compiler/version.pas metadata without compiling
.\build.ps1 -Branch main -VerifySourceOnly

# Preview CI branch/target build matrix
.\resolve-matrix.ps1 -Branch main,fixes_3_2 -TargetFilter x86_64-win64 -ForceRebuild

# Smoke-test an existing SDK archive in ./dist or an installed SDK directory
.\test.ps1

# Dry-run sdk-index.json and release-notes.md generation locally
.\publish-release.ps1 -InputDir .\dist -Repository nikrun/sdk -DryRun
```

> **Note:** `.\build.ps1` compiles Free Pascal from source and takes several minutes; only run a full compile when modifying the SDK build/packaging logic itself.
