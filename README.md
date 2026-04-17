# Python Version Manager for macOS/zsh

A lightweight shell-based Python version manager that enforces explicit Python versions and protects against accidental system-wide package installations.

## Features

- **Forces explicit Python versions** - No default `python` or `python3` (use `python3.X` explicitly)
- **Blocks pip outside virtual environments** - Prevents polluting system packages
- **Build mode** - Temporarily allow pip for building modules with `setpy <version> --build`
- **AI tool compatibility** - Works with Codex CLI, Claude Code, Cursor via symlinks + env vars
- **Virtual environment detection** - Auto-detects venv, conda, poetry, pipenv

## Installation

### Quick Install

```bash
# Create config directory
mkdir -p ~/.config/zsh ~/.local/bin

# Copy both scripts side by side; pyinstall.sh is auto-discovered by
# pythonmanager.sh via the pyinstall() shell function.
cp pythonmanager.sh pyinstall.sh ~/.config/zsh/
chmod +x ~/.config/zsh/pyinstall.sh

# Add to ~/.zshrc (create if doesn't exist)
echo '# Python Version Manager
export PATH="$HOME/.local/bin:$PATH"
source ~/.config/zsh/pythonmanager.sh' >> ~/.zshrc

# Reload shell
source ~/.zshrc
```

### Verify Installation

```bash
pydiag          # Show diagnostics
pyinfo          # Show available Python versions
```

## Usage

### Basic Commands

```bash
# Use specific Python version (always works)
python3.X --version           # e.g., python3.14, python3.12, python3.9
python3.X -c "print('hello')"
py3.X script.py

# These are BLOCKED by default (no default python)
python --version        # Error: use explicit version
pip install requests    # Error: use virtual environment
```

### Set Temporary Python Default

```bash
setpy <version>         # e.g., setpy 3.14 - sets python/python3
python --version        # Now works with the set version
setpy                   # Show current status
setpy clear             # Remove the override
```

### Build Mode (Allow pip)

For building modules that need pip outside a venv:

```bash
setpy <version> --build # e.g., setpy 3.14 --build
pip install build       # Works! (shows warning)
python -m build         # Build your package
setpy clear             # Clean up when done
```

### Virtual Environments

```bash
# Create and activate (recommended workflow)
python3.X -m venv myproject   # Use your preferred version
source myproject/bin/activate

# Now pip works normally
pip install requests
python -c "import requests; print(requests.__version__)"

# Deactivate when done
deactivate
```

### Query Commands

```bash
pyinfo                  # Show all Python versions and current status
pyinfo --all            # Also show shadowed candidates (e.g. Homebrew's 3.14.4 under your self-built 3.14.3)
pywhich python3.X       # Show actual binary path for a version
which python3.X         # Enhanced which (uses pywhich for python/pip)
pydiag                  # Debug diagnostics (for troubleshooting)
pyrefresh               # Force-rescan Python installations (after manual install)
```

### Managing CPython source builds (pyinstall)

The `pyinstall` helper compares what you have under `~/opt/python/<version>/` against the
current patch releases on python.org, and automates the source-build recipe in
[python-installation-process.md](./python-installation-process.md).

```bash
pyinstall status                 # Diff installed vs upstream-latest per supported minor
pyinstall latest                 # Print upstream-latest patch for every supported minor
pyinstall latest 3.14            # Just one minor
pyinstall deps                   # Print the OS-specific dep install command (does not run it)
pyinstall install 3.14.4         # Download, verify, build, altinstall
pyinstall upgrade 3.14           # Shortcut: install latest patch for the 3.14 series
pyinstall verify <tarball>       # Dry-run verification on an already-downloaded tarball
```

Verification paths:

- **Python 3.14+** — Sigstore (bundle at `Python-X.Y.Z.tgz.sigstore`); the `sigstore` package is installed into a dedicated cached venv at `~/.cache/pymanager/sigstore-venv/` so it never pollutes your system interpreter.
- **Python 3.13 and older** — OpenPGP (`.asc` signature) against release-manager keys from `keys.openpgp.org`.

`pyinstall install` calls `pyrefresh` on success so the new interpreter is visible to the current shell immediately.

## Command Reference

| Command | Description |
|---------|-------------|
| `python3.X` | Run specific Python version (always works) |
| `py3.X` | Alias for python3.X |
| `setpy <version>` | Set temporary Python default |
| `setpy <version> --build` | Set default + allow pip |
| `setpy clear` | Clear override and build mode |
| `setpy` | Show current status |
| `pyinfo` | Show selected Python per major.minor |
| `pyinfo --all` | Also show shadowed candidates |
| `pyrefresh` | Re-scan for newly installed Pythons |
| `pywhich <cmd>` | Show what binary would run |
| `pydiag` | Debug diagnostics |
| `pyinstall status` | Diff installed self-builds vs upstream latest |
| `pyinstall install <X.Y.Z>` | Source-build and install a new CPython |
| `pyinstall upgrade <X.Y>` | Install latest patch of a series |

## How It Works

### Interactive Shells
Shell wrapper functions intercept `python`, `pip`, etc. and route them appropriately.

### Subprocesses (Codex, Claude Code, scripts)
When you run `setpy <version>`:
1. Creates a session-scoped wrapper directory under `$TMPDIR` (e.g. `/var/folders/.../T/pymanager.XXXXXXXX/bin/`) containing `python`, `python3`, `python${version}`, `pip`, `pip3`, `pip${version}` — each is a small shell script that execs the chosen interpreter.
2. Prepends the wrapper directory to `PATH`, followed by the interpreter's real `bin/` directory (so helpers like `python3-config` and installed entry points remain available).
3. Exports `PYTHON` and `PYTHON3` for tools that look at env vars instead of `PATH`.
4. Exports `PIP_REQUIRE_VIRTUALENV=1` so even subprocesses that bypass the wrappers cannot install packages outside a venv. Build mode (`--build`) flips this to `0`.

The wrapper directory is cleaned up automatically on shell exit via a `zshexit` hook. Orphaned directories from crashed shells are pruned opportunistically when the manager is sourced.

### Virtual Environments
When a venv is active, `$VIRTUAL_ENV/bin` is kept ahead of the wrapper directory on `PATH`, so the venv's own `python`/`pip` take precedence automatically.

## Troubleshooting

### "command not found: python"
```bash
# Either use explicit version (run pyinfo to see available)
python3.X --version

# Or set a default
setpy <version>
```

### "pip is not available outside virtual environments"
```bash
# Option 1: Use a virtual environment (recommended)
python3.X -m venv myenv
source myenv/bin/activate
pip install package

# Option 2: Use build mode (temporary)
setpy <version> --build
pip install package
setpy clear
```

### Codex/Claude Code can't find Python
```bash
# Run setpy to create the wrapper directory and export PYTHON/PYTHON3
setpy <version>

# Verify
pydiag | grep -A5 "Subprocess"
```

### Check if ~/.local/bin is in PATH
```bash
echo $PATH | tr ':' '\n' | head -5
# ~/.local/bin should be first or near the top
```

## Configuration

The script auto-detects Python installations in:
- `~/.local/bin`
- `/opt/homebrew/bin` (Homebrew on Apple Silicon)
- `/usr/local/bin` (Homebrew on Intel)
- `/usr/bin` (System Python)
- `~/opt/python/*/bin` (Custom builds)
- `/opt/python/*/bin`

### Scanner preference order

When the same `major.minor` version lives in multiple locations (e.g. your
self-built `~/opt/python/3.14.3/bin/python3.14` **and** a Homebrew-installed
`/opt/homebrew/bin/python3.14` pulled in as a dependency), the scanner picks the
one with the highest priority:

| Priority | Location |
|----------|----------|
| 100 | `~/.local/bin` |
| 90 | `~/opt/python/<version>/bin` (user self-build) |
| 80 | `/opt/python/<version>/bin` (admin self-build) |
| 70 | `~/.pythons/*/bin` |
| 50 | `/opt/homebrew/...`, `/usr/local/opt/python@*/bin` (package manager) |
| 40 | `~/bin`, `~/Library/Python/*/bin`, other |
| 10 | `/usr/bin` (system) |

Within the same priority level, the higher patch version wins as a tiebreaker.
This means a deliberate `make altinstall` under `~/opt/python/` will **not** be
silently shadowed when Homebrew installs Python 3.14 as a formula dependency,
even if Homebrew's patch is newer. Use `pyinstall status` to see when your
self-build is behind upstream, and `pyinfo --all` to see all candidates.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `PYTHON_MANAGER_FORCE_BYPASS=1` | Disable all wrapper logic (falls through to system commands) |
| `PYTHON` | Exported by setpy for subprocess compatibility |
| `PYTHON3` | Exported by setpy for subprocess compatibility |
| `PIP_REQUIRE_VIRTUALENV=1` | Set by the manager as a baseline; pip refuses installs outside venvs |
| `PYMANAGER_BUILD_MODE=1` | Set by `setpy --build`; flips `PIP_REQUIRE_VIRTUALENV` to 0 |
| `PYMANAGER_DEBUG=1` | Enables scanner/debug output on stderr |

## Uninstall

```bash
# Remove from ~/.zshrc (delete the source line)
# Then:
rm ~/.config/zsh/pythonmanager.sh

# Wrapper directories clean themselves up on shell exit. Any leftovers
# from a crashed shell can be removed safely with:
rm -rf "${TMPDIR:-/tmp}"pymanager.* 2>/dev/null || true
```

## License

MIT - Created by ehzawad@gmail.com

