# Tk_Patch

**Tk_Patch** is a Ruby script that automates the installation and configuration of the Ruby Tk gem (version 0.5.1) for Ruby 2.4+ with Tcl/Tk, ensuring compatibility across Ubuntu, macOS, and Windows. This script dynamically detects the installed Tcl/Tk version, installs compatible dependencies (Tcl/Tk 8.6 if needed), creates necessary symlinks (Linux only), and tests the Tk gem installation with a sample GUI window. It’s a modernized version of the original `Rubytk_patch.rb`, incorporating dynamic Ruby logic inspired by the Rubian project.

Originally developed after 48 hours of research to fix Ruby/Tk compatibility issues post-Ruby 2.4, this updated installer (August 2025) makes setup seamless, saving you from the headaches of manual configuration.

## Features
- **Dynamic Tcl/Tk Version Detection**: Introspects the system’s Tcl/Tk version using `tclsh` and ensures compatibility with the `tk` gem (requires Tcl/Tk 8.6).
- **Cross-Platform Support**: Works on Ubuntu, macOS, and Windows with platform-specific dependency installation and configuration.
- **Automated Dependency Installation**: Installs `tcl8.6-dev`/`tk8.6-dev` (Linux), `tcl-tk@8.6` (macOS via Homebrew), or prompts for ActiveTcl (Windows).
- **Dynamic Symlink Creation**: Creates symlinks for Tcl/Tk libraries on Linux using detected paths.
- **Robust Error Handling**: Checks for RubyGems, `sudo` privileges, and Tcl/Tk files, with clear error messages and logs.
- **Test Script**: Runs a sample Tk GUI to verify successful installation.
- **Logging**: Saves detailed logs to `tk_installer.log` for debugging.

## Requirements
- Ruby 2.4 or later (3.0+ recommended; use `rvm` or `rbenv` for best results).
- Git to clone the repository.
- `sudo` privileges for Linux/macOS (for dependency installation and symlinks).
- Internet access for package installation (Linux/macOS) or ActiveTcl download (Windows).

## Supported Platforms
- **Ubuntu**: Installs `tcl8.6-dev` and `tk8.6-dev`, creates symlinks in `/usr/lib`.
- **macOS**: Uses Homebrew to install `tcl-tk@8.6`.
- **Windows**: Requires ActiveTcl 8.6 installed at `C:\ActiveTcl`.

**Note**: Tcl/Tk 9.0 is **not supported** by the Ruby Tk gem (0.5.1). If detected, the script attempts to install Tcl/Tk 8.6 but may require manual path configuration to avoid conflicts.

## Installation
1. **Clone the Repository**:
   ```bash
   git clone https://github.com/CufeHaco/Tk_Patch
   cd Tk_Patch
