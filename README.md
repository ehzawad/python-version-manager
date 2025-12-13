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

# Copy the script
cp pythonmanager.sh ~/.config/zsh/

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
pywhich python3.X       # Show actual binary path for a version
which python3.X         # Enhanced which (uses pywhich for python/pip)
pydiag                  # Debug diagnostics (for troubleshooting)
```

## Command Reference

| Command | Description |
|---------|-------------|
| `python3.X` | Run specific Python version (always works) |
| `py3.X` | Alias for python3.X |
| `setpy <version>` | Set temporary Python default |
| `setpy <version> --build` | Set default + allow pip |
| `setpy clear` | Clear override and build mode |
| `setpy` | Show current status |
| `pyinfo` | Show all Python versions |
| `pywhich <cmd>` | Show what binary would run |
| `pydiag` | Debug diagnostics |

## How It Works

### Interactive Shells
Shell wrapper functions intercept `python`, `pip`, etc. and route them appropriately.

### Subprocesses (Codex, Claude Code, scripts)
When you run `setpy <version>`:
1. Creates symlinks at `~/.local/bin/python` and `~/.local/bin/python3`
2. Exports `PYTHON` and `PYTHON3` environment variables
3. Subprocesses find Python via PATH or env vars

### Virtual Environments
When a venv is active, all commands use the venv's Python/pip automatically.

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
# Run setpy to create symlinks (use your preferred version)
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

## Environment Variables

| Variable | Description |
|----------|-------------|
| `PYTHON_MANAGER_FORCE_BYPASS=1` | Disable all wrapper logic |
| `PYTHON_ALLOW_SYSTEM=1` | Allow system python with setpy override |
| `PYTHON` | Exported by setpy for subprocess compatibility |
| `PYTHON3` | Exported by setpy for subprocess compatibility |

## Uninstall

```bash
# Remove from ~/.zshrc (delete the source line)
# Then:
rm ~/.config/zsh/pythonmanager.sh
rm -f ~/.local/bin/python ~/.local/bin/python3  # Remove symlinks
```

## License

MIT - Created by ehzawad@gmail.com

