# Python Version Manager for macOS/zsh

A lightweight shell-based Python version manager that enforces explicit Python versions and protects against accidental system-wide package installations.

## Features

- **Forces explicit Python versions** — bare `python` and `python3` are **blocked** in a fresh interactive shell. You must either run `setpy <version>` or call an explicit `python3.X`. This is the central invariant of the tool.
- **Prefers your self-builds** — `~/opt/python/<ver>` beats Homebrew/apt at the same major.minor, even when the package manager ships a newer patch
- **Blocks pip outside virtual environments** — enforced both by interactive wrappers and by `PIP_REQUIRE_VIRTUALENV=1` as the manager baseline, so subprocess `pip` calls (Codex CLI, Claude Code, Cursor Agent, sandboxes) refuse too
- **Build mode** — temporarily allow pip outside a venv for building modules, `setpy <version> --build`
- **Typo guard** — `set 3.14`, `set py3.13`, `set clear` (all common `setpy` typos) auto-route to `setpy` with a one-line hint
- **Opt-in ergonomic mode** — `export PYMANAGER_AUTO_SETPY=1` (before sourcing) makes every new interactive shell auto-`setpy latest`, so agents see the self-build on PATH without running `setpy` each time
- **AI-tool compatibility** — when `setpy` is active, a session wrapper directory on PATH routes subprocess `python`/`pip` calls to the chosen interpreter; cleaned up automatically on shell exit via `zshexit`
- **Virtual environment detection** — venv, conda, poetry, pipenv
- **Source-build automation** — `pyinstall status / install / upgrade` diffs your local CPython builds against python.org, handles Sigstore (3.14+) or OpenPGP (≤3.13) verification fail-closed, and runs a PGO+LTO `make altinstall` build

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
# Explicit version always works (this is the default mental model):
python3.14 --version
python3.13 -c "print('hello')"
py3.12 script.py

# Bare python / python3 are BLOCKED in a fresh shell:
python --version              # Error: No default 'python' command available
python3 --version             # Same error, with available-versions hint
pip install requests          # Error: use a virtual environment (or build mode)
```

### Pick a session default

```bash
setpy 3.14              # -> python / python3 now route to 3.14
python --version        # -> Python 3.14.4
setpy                   # show current status
setpy clear             # back to strict (bare python blocked)
```

Typo-friendly: `set 3.14`, `set py3.13`, `set clear` are auto-routed to the
right `setpy` command (with a one-line hint), since `set` is a zsh builtin
you almost never actually want when you're thinking about Python versions.

### Opt-in ergonomic mode (auto-setpy)

If you'd rather have the latest detected Python picked automatically in every
new interactive shell — useful when agent tools (Cursor, Claude Code, Codex
CLI) spawn non-interactive subshells and you want them to see your
self-build without running `setpy` each time — add this to `~/.zshrc`
**before** the `source` line:

```bash
export PYMANAGER_AUTO_SETPY=1
source ~/.config/zsh/pythonmanager.sh
```

The default is off — you need to deliberately opt in. Without the flag,
bare `python`/`python3` stay blocked until you explicitly run `setpy`.

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

Install/upgrade flags:

| Flag | Effect |
|------|--------|
| `-y`, `--yes` | Skip the confirmation prompt |
| `-j`, `--jobs N` | `make -j N` (default: detected core count) |
| `--dry-run` | Print the install plan and exit without downloading or building. Exits nonzero if the real install would fail a precondition (missing deps, clobber without `--force`). |
| `--force` | Rebuild over an existing prefix by moving it aside to `<prefix>.old-<timestamp>`. Refuses to touch prefixes outside `~/opt/python` without manual action. |
| `--prefix DIR` | Override install prefix (default `~/opt/python/<version>`). You can also hit `e` at the confirmation prompt to edit the prefix interactively; the plan re-renders with the new path. |
| `--keep-build` | Keep the build tree after successful install (for inspection) |
| `--allow-tls-only` | Skip Sigstore / OpenPGP; rely on TLS integrity only. Use with caution. |
| `--no-sigstore` | Alias for `--allow-tls-only` |
| `--sigstore-identity EMAIL` | Override the expected Sigstore `--cert-identity`. Use when a new release series hasn't been added to the metadata cache yet. Must be passed with `--sigstore-issuer`. |
| `--sigstore-issuer URL` | Override the expected Sigstore `--cert-oidc-issuer`. Must be passed with `--sigstore-identity`. |

Before any action `pyinstall` prints a plan view you can sanity-check — source URL, verification method and expected identity, dep status per-item, full `./configure` line with env vars, install prefix, the post-build module check list, and what the shell will do afterwards.

Verification paths (both fail-closed — install aborts on verification failure unless `--allow-tls-only` is explicitly passed):

- **Python 3.14+** — Sigstore (`.sigstore` bundle). The expected cert-identity and OIDC issuer are resolved dynamically from [python.org's Sigstore metadata](https://www.python.org/downloads/metadata/sigstore/) (cached for 24h in `~/.cache/pymanager/sigstore-metadata.tsv`). The `sigstore` PyPI package is installed into a dedicated cached venv at `~/.cache/pymanager/sigstore-venv/` (pinned `sigstore>=3.3,<5`, bootstrapped with Python ≥ 3.10) so it never pollutes any system interpreter. If the metadata is unreachable and no cache exists, an embedded fallback table is used; if the fallback also misses your series, pass `--sigstore-identity` + `--sigstore-issuer`.
- **Python 3.13 and older** — OpenPGP (`.asc` signature). Per-minor signer map for currently-supported series: Thomas Wouters for 3.12/3.13, Pablo Galindo for 3.10/3.11. Keys fetched from their pinned per-signer URL first (e.g. `github.com/Yhg1s.gpg`), falling back to `keys.openpgp.org`. Keys are imported into a managed keyring at `~/.cache/pymanager/gnupg` (mode 700) so pyinstall never pollutes your real GPG keyring. Verification uses `gpg --status-fd 1 --verify` and asserts a `VALIDSIG <full-40-char-fingerprint>` line — plain exit 0 is not accepted. EOL series (3.9 and earlier) aren't in the map; pass `--allow-tls-only` if you need to force-install one.

Post-build module checks split into required (`ssl hashlib sqlite3 bz2 lzma ctypes _decimal zlib` — install fails on any miss, build tree is kept for inspection) and optional (`readline _gdbm uuid tkinter` — warn only).

When invoked as the `pyinstall` shell function (sourced via `pythonmanager.sh`), `pyrefresh` runs automatically on success so the current shell sees the new interpreter. When run as the script directly (e.g. `./pyinstall.sh install …`), run `pyrefresh` in your interactive shell afterwards.

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
| `pyinstall latest [<X.Y>]` | Print upstream-latest patch per supported minor |
| `pyinstall install <X.Y.Z> [flags]` | Source-build and install a new CPython (see flag table above) |
| `pyinstall upgrade <X.Y> [flags]` | Install latest patch of a series |
| `pyinstall verify <tarball>` | Dry-run verification of a local tarball |
| `pyinstall deps` | Print OS-specific dep install command (does not run it) |

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

### Codex/Claude Code/Cursor Agent can't find Python

```bash
# Run setpy to create the wrapper directory and export PYTHON/PYTHON3
setpy <version>

# Verify
pydiag | grep -A5 "Subprocess"
```

### `python3` resolves to Homebrew but `python` resolves to your self-build

Symptom (most often in Cursor Agent's subshell):

```zsh
python3 -c "import sys; print(sys.executable)"
# /opt/homebrew/opt/python@3.14/bin/python3.14   ← Homebrew

python -c "import sys; print(sys.executable)"
# /Users/ehz/opt/python/3.14.4/bin/python3.14    ← self-build (via pymanager)
```

Cause: Homebrew's `/opt/homebrew/bin/` ships `python3` (and `python3.14`) but
**no bare `python`**. If the agent's subshell has `/opt/homebrew/bin` ahead of
the pymanager wrapper on `PATH`, `python3` is matched by Homebrew first;
`python` falls through to the wrapper. Claude Code and Codex CLI typically
have the wrapper ahead of Homebrew and see the self-build for both.

The manager's early PATH-repair block auto-corrects this when it detects an
inherited wrapper not at the expected front position. It runs every time
`pythonmanager.sh` is sourced (i.e. every `.zshrc`-loading shell). If you
still see the split:

```zsh
# Diagnostic — avoid `which` here because this project wraps it
print -r -- "cursor=${CURSOR_AGENT:-no}"
print -r -- "_PYMANAGER_PATH_INIT=${_PYMANAGER_PATH_INIT:-unset}"
print -rl -- ${(ps.:.)PATH} | nl -ba | head -20
whence -p python
whence -p python3
```

If PATH shows Homebrew before the `pymanager.*/bin` entry, either the shell
isn't sourcing `.zshrc` (run `zsh -i -c 'echo hi'` to confirm it's interactive)
or the wrapper dir isn't in PATH at all — run `setpy <version>` inside that
shell to recreate it.

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
| 90  | `~/opt/python/<version>/bin` (user self-build) |
| 80  | `/opt/python/<version>/bin` (admin self-build) |
| 70  | `~/.pythons/*/bin` |
| 50  | `/opt/homebrew/...`, `/usr/local/opt/python@*/bin` (package manager) |
| 40  | `~/bin`, `~/Library/Python/*/bin`, other |
| 10  | `/usr/bin` (system) |
| 5   | `~/opt/python/<ver>.old-<timestamp>/bin` (leftover from `pyinstall --force`) |

Within the same priority level, the higher patch version wins as a tiebreaker.
This means a deliberate `make altinstall` under `~/opt/python/` will **not** be
silently shadowed when Homebrew installs Python 3.14 as a formula dependency,
even if Homebrew's patch is newer. Use `pyinstall status` to see when your
self-build is behind upstream, and `pyinfo --all` to see all candidates.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `PYTHON_MANAGER_FORCE_BYPASS=1` | Disable all wrapper logic (falls through to system commands) |
| `PYMANAGER_AUTO_SETPY=1` | Opt-in: auto-`setpy latest` at each interactive shell init (default: off) |
| `PYMANAGER_NO_AUTO_SETPY=1` | Legacy back-compat no-op (auto-setpy is off by default now) |
| `PYTHON` | Exported by setpy for subprocess compatibility |
| `PYTHON3` | Exported by setpy for subprocess compatibility |
| `PIP_REQUIRE_VIRTUALENV=1` | Set by the manager as a baseline; pip refuses installs outside venvs |
| `PYMANAGER_BUILD_MODE=1` | Set by `setpy --build`; flips `PIP_REQUIRE_VIRTUALENV` to 0 |
| `PYMANAGER_DEBUG=1` | Enables scanner/debug output on stderr |

## Uninstall

```bash
# Remove from ~/.zshrc (delete the source line)
# Then:
rm ~/.config/zsh/pythonmanager.sh ~/.config/zsh/pyinstall.sh

# Wrapper directories clean themselves up on shell exit. Any leftovers
# from a crashed shell can be removed safely with:
rm -rf "${TMPDIR:-/tmp}"pymanager.* 2>/dev/null || true

# pyinstall caches (downloads, build tree, managed GPG/Sigstore keyrings):
rm -rf ~/.cache/pymanager
```

## License

MIT - Created by ehzawad@gmail.com

