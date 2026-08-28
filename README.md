# Tk Patch v3

**Map the install tree. Do not glob the OS.**

`rubytk_install.rb` locates Tcl/Tk 8.6 on any distro, then installs the MRI `tk` gem (0.5.1) with the real config/lib/include dirs. It is the successor to `rubytk_patchV2`.

## Why v2 failed

v2 used `Dir.glob` and then **rejected any hit whose path string did not contain `8.6`**.

| Distro | Where `tclConfig.sh` actually lives | v2 |
| --- | --- | --- |
| Debian / Ubuntu | `/usr/lib/x86_64-linux-gnu/tcl8.6/tclConfig.sh` | kept (lucky) |
| Fedora / RHEL | `/usr/lib64/tclConfig.sh` | dropped |
| Arch / Alpine | `/usr/lib/tclConfig.sh` | dropped |
| Homebrew prefix | `/opt/homebrew/opt/tcl-tk/lib/tclConfig.sh` | dropped |
| Windows | `C:/ActiveTcl/lib/tclConfig.sh` (+ `.dll`) | dropped |

Each distro puts Tcl in a different place. That is not a glob problem. It is a classification problem.

## What v3 does

1. **Probe** OS, package manager, Ruby engine. `--tcl-dir=` / `TCLTK_ROOT` always wins.
2. **Snatch the tree** from the package manager as it is (or just was) installed:
   `dpkg -L`, `rpm -ql`, `pacman -Ql`, `apk info -L`, `brew list --verbose`.
3. **`.map` classify** every path. `tclConfig.sh` is a config. `libtcl8.6.so` / `.dylib` / `.dll` is a lib. Version is read from `TCL_VERSION=` inside the file, not from the folder name.
4. If Tcl is missing, install the distro packages, **capture the new file list**, and map again. Walk (`Dir.entries` + `.map`) is the last fallback — there is no `Dir.glob`.
5. Feed those dirs to `gem install tk` as `--with-tclConfig-file=` / `--with-tkConfig-file=` / lib / include flags. Symlinks into `/usr/lib` only if extconf still cannot see the files.

## Usage

```bash
ruby rubytk_install.rb            # locate, install if needed, build the gem
ruby rubytk_install.rb --dry-run  # classify + print flags, write nothing
ruby rubytk_install.rb --tcl-dir=/opt/tcl
```

MRI + Tcl/Tk 8.6 this pass. JRuby is detected and exits 2 — that is the hook for a later backend, not a silent failure. There is no auto-cleanup; a failed run will not `apt-get remove` your Tcl.

## Requirements

- Ruby 2.7+ (MRI). 3.x recommended.
- sudo on Linux only for package install.
- Graphical session optional: `require 'tk'` is the test; the demo window is skipped when `DISPLAY` is unset.

## License

GPL-3.0 (same as the v2 tree).
