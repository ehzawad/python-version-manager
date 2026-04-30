# Python Version Manager for macOS/zsh

A lightweight shell-based Python version manager that enforces explicit Python versions and protects against accidental system-wide package installations.

## Features

- **Forces explicit Python versions** — bare `python` and `python3` are **blocked** in a fresh interactive shell. You must either run `setpy <version>` or call an explicit `python3.X`. This is the central invariant of the tool.
- **Prefers your self-builds** — `~/opt/python/<ver>` beats Homebrew/apt at the same major.minor, even when the package manager ships a newer patch
- **Blocks pip outside virtual environments** — enforced both by interactive wrappers and by `PIP_REQUIRE_VIRTUALENV=1` as the manager baseline, so subprocess `pip` calls (Codex CLI, Claude Code, Cursor Agent, sandboxes) refuse too. **This stays in force under every default mode below** — `setpy`, `setpy global`, and `PYMANAGER_AUTO_SETPY=1` never weaken pip safety.
- **Build mode** — temporarily allow pip outside a venv for building modules, `setpy <version> --build`
- **Typo guard** — `set 3.14`, `set py3.13`, `set clear` (all common `setpy` typos) auto-route to `setpy` with a one-line hint
- **Persistent global default (opt-out from strict)** — `setpy global <ver>` pins a Python in `~/.config/pymanager/default-version`; every new shell applies it automatically. `setpy global clear` removes the pin. Precedence: manual in-shell `setpy` > persisted pin > `PYMANAGER_AUTO_SETPY=1` > strict mode.
- **Opt-in drifting-latest** — `export PYMANAGER_AUTO_SETPY=1` (before sourcing) makes every new interactive shell auto-`setpy latest`. Only fires when no persisted pin exists.
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
setpy clear             # drop session override; falls back to the global pin if set, else strict
```

Typo-friendly: `set 3.14`, `set py3.13`, `set clear` are auto-routed to the
right `setpy` command (with a one-line hint), since `set` is a zsh builtin
you almost never actually want when you're thinking about Python versions.

### Set a persistent global default

`setpy` is session-scoped by design. If you want a pinned Python that
survives new terminal windows (without editing `~/.zshrc`), use
`setpy global`:

```bash
setpy global 3.14              # Pin 3.14 — every new shell auto-applies it
setpy global                   # Show the current pin
setpy global clear             # Remove the pin; new shells go back to strict
```

The pin lives in `${XDG_CONFIG_HOME:-$HOME/.config}/pymanager/default-version`
as a single line containing a selector like `3.14` (major.minor). Storing
the selector rather than a resolved path means `pyinstall upgrade 3.14`
transparently moves the pin from `3.14.3` to `3.14.4` — no file edits
needed.

Precedence on each new shell (highest wins):

1. Manual `setpy <version>` you run in that shell
2. Persisted pin (this command)
3. `PYMANAGER_AUTO_SETPY=1` (drifting-latest below) — only fires when no pin exists
4. Strict mode — bare `python`/`python3` blocked

What `setpy global` does **not** do: it does not weaken the pip-outside-venv
block. `PIP_REQUIRE_VIRTUALENV=1` stays in force, wrappers still refuse,
subprocesses still refuse. The pin only changes which interpreter `python`
and `python3` route to — nothing else.

Behavior notes:

- **Missing pin target.** If the pinned version was uninstalled between
  sessions, new shells print `[pymanager] persisted global Python X.Y is
  not installed.` and fall back to strict mode (they do *not* silently
  pick latest — that would violate your explicit pin). Run
  `setpy global clear` or `setpy global <installed-version>` to recover.
- **Invalid pin file.** Same treatment: warn once, stay strict.
- **Already-open shells.** The pin only affects *new* shells. Open tmux
  panes, existing terminals, and ssh sessions that don't re-source
  `pythonmanager.sh` won't update until they do.
- **Manual session override wins.** If you run `setpy 3.13` then
  `setpy global 3.14`, the current shell keeps using 3.13; only new
  shells see 3.14. The pin file is always written regardless.
- **`setpy clear` falls back to the pin.** In a pinned shell you can
  `setpy 3.13` to temporarily switch, then `setpy clear` to return to
  the pin (3.14) — not strict mode. Without a pin, `setpy clear` drops
  to strict as before.
- **Non-interactive shells.** The init auto-apply is gated on
  `[[ -o interactive ]]`. Scripts and non-interactive subshells inherit
  whatever PATH/PYTHON the parent interactive shell already exported.

### Opt-in drifting-latest (auto-setpy)

If you'd rather have the latest detected Python picked automatically in every
new interactive shell — useful when agent tools (Cursor, Claude Code, Codex
CLI) spawn non-interactive subshells and you want them to see your
self-build without running `setpy` each time — add this to `~/.zshrc`
**before** the `source` line:

```bash
export PYMANAGER_AUTO_SETPY=1
source ~/.config/zsh/pythonmanager.sh
```

The default is off — you need to deliberately opt in. Without the flag
(and without a `setpy global` pin), bare `python`/`python3` stay blocked
until you explicitly run `setpy`.

If both `PYMANAGER_AUTO_SETPY=1` and a `setpy global` pin are set, the
pin wins. Explicit version beats implicit latest.

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
| `setpy <version>` | Set temporary Python default (this shell) |
| `setpy <version> --build` | Set default + allow pip |
| `setpy clear` | Clear session override and build mode. Falls back to the `setpy global` pin if one is set; else strict mode. |
| `setpy` | Show current status |
| `setpy global <version>` | Persistent pin — every new shell auto-applies it |
| `setpy global clear` | Remove the persistent pin |
| `setpy global` | Show the current persistent pin |
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

### Shell init order
On each interactive shell init, the manager picks a default Python using this precedence (highest wins):

1. **Session override** — whatever `setpy <version>` the user runs in the shell after init. Takes precedence over everything below for that shell.
2. **Persistent pin** — if `~/.config/pymanager/default-version` exists and contains a valid, installed selector, the manager auto-`setpy`s it (source = `global`). If the file exists but is invalid or names an uninstalled version, the manager warns and stays strict — it does *not* fall through to AUTO_SETPY, because that would silently violate the user's explicit pin.
3. **AUTO_SETPY** — `PYMANAGER_AUTO_SETPY=1` sets the newest installed Python as session default (source = `auto`). Only fires when no pin file exists.
4. **Strict mode** — bare `python`/`python3` stay blocked until the user runs `setpy` explicitly.

Track the active source via `_PYMANAGER_OVERRIDE_SOURCE` (shown in `pydiag`).

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

# Or set a session default
setpy <version>

# Or pin a persistent global default (survives new shells)
setpy global <version>
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
| `PYMANAGER_AUTO_SETPY=1` | Opt-in: auto-`setpy latest` at each interactive shell init. Only fires when no `setpy global` pin exists. (default: off) |
| `PYMANAGER_NO_AUTO_SETPY=1` | Legacy back-compat no-op (auto-setpy is off by default now) |
| `XDG_CONFIG_HOME` | Honored for pin-file location (`$XDG_CONFIG_HOME/pymanager/default-version`; defaults to `~/.config/pymanager/default-version`) |
| `PYTHON` | Exported by setpy for subprocess compatibility |
| `PYTHON3` | Exported by setpy for subprocess compatibility |
| `PIP_REQUIRE_VIRTUALENV=1` | Set by the manager as a baseline; pip refuses installs outside venvs. Unchanged by `setpy global` — persistent default only sets python/python3, never weakens pip safety. |
| `PYMANAGER_BUILD_MODE=1` | Set by `setpy --build`; flips `PIP_REQUIRE_VIRTUALENV` to 0 |
| `PYMANAGER_DEBUG=1` | Enables scanner/debug output on stderr |

## Files

| Path | Purpose |
|------|---------|
| `${XDG_CONFIG_HOME:-$HOME/.config}/pymanager/default-version` | Persistent global pin written by `setpy global <ver>`. One line, selector format (e.g. `3.14`). Mode 0600. Removed by `setpy global clear`. |
| `~/.cache/pymanager/` | `pyinstall` caches: downloads, build tree, managed GPG keyring, Sigstore metadata cache, Sigstore venv. |
| `${TMPDIR:-/tmp}/pymanager.XXXXXXXX/` | Per-shell session wrapper directory; cleaned up on shell exit. |

## Uninstall

```bash
# Remove from ~/.zshrc (delete the source line)
# Then:
rm ~/.config/zsh/pythonmanager.sh ~/.config/zsh/pyinstall.sh

# Wrapper directories clean themselves up on shell exit. Any leftovers
# from a crashed shell can be removed safely with:
rm -rf "${TMPDIR:-/tmp}"pymanager.* 2>/dev/null || true

# Persistent global pin (if you set one):
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/pymanager/default-version"
rmdir "${XDG_CONFIG_HOME:-$HOME/.config}/pymanager" 2>/dev/null || true

# pyinstall caches (downloads, build tree, managed GPG/Sigstore keyrings):
rm -rf ~/.cache/pymanager
```

### usage

## What this repo is doing

I read the repo’s main docs and shell scripts: [README.md](https://github.com/ehzawad/python-version-manager/blob/main/README.md), [pythonmanager.sh](https://github.com/ehzawad/python-version-manager/blob/main/pythonmanager.sh), [pyinstall.sh](https://github.com/ehzawad/python-version-manager/blob/main/pyinstall.sh), and [python-installation-process.md](https://github.com/ehzawad/python-version-manager/blob/main/python-installation-process.md).

The mental model is:

This is a zsh-based Python version manager. In a fresh interactive shell, bare `python` and `python3` are intentionally blocked until you select a version with `setpy`, unless you configure a persistent global default. It also blocks `pip` outside virtual environments by default using wrappers plus `PIP_REQUIRE_VIRTUALENV=1`.

It separates two concerns:

1. `pythonmanager.sh` manages shell-time Python selection: `setpy`, `pyinfo`, `pywhich`, `pyrefresh`, `pydiag`.
2. `pyinstall.sh` manages CPython source builds and upgrades under `~/opt/python/<version>`: `pyinstall status`, `install`, `upgrade`, `latest`, `verify`, `deps`.

## One-time installation

From the repo directory:

```zsh
mkdir -p ~/.config/zsh ~/.local/bin
```

```zsh
cp pythonmanager.sh pyinstall.sh ~/.config/zsh/
```

```zsh
chmod +x ~/.config/zsh/pyinstall.sh
```

Add this to `~/.zshrc`:

```zsh
export PATH="$HOME/.local/bin:$PATH"
source ~/.config/zsh/pythonmanager.sh
```

Reload:

```zsh
source ~/.zshrc
```

Verify:

```zsh
pydiag
```

```zsh
pyinfo
```

## Most important Python version selection commands

### Show detected Python versions

```zsh
pyinfo
```

Shows the selected Python per major/minor version.

```zsh
pyinfo --all
```

Also shows shadowed candidates. This matters because the scanner prefers your self-built Python under `~/opt/python/<version>/bin` over Homebrew or system Python for the same major/minor series.

### Run an explicit Python version without setting a default

```zsh
python3.14 --version
```

```zsh
python3.13 -c "import sys; print(sys.executable)"
```

```zsh
py3.12 script.py
```

This is the safest direct mode. It bypasses the need for a session default.

### Set a temporary Python default for the current shell

```zsh
setpy 3.14
```

After that:

```zsh
python --version
```

```zsh
python3 --version
```

Both route to the selected `3.14` interpreter.

Check current status:

```zsh
setpy
```

Clear the session override:

```zsh
setpy clear
```

Important behavior: if you have a persistent global pin, `setpy clear` falls back to that pin. If no global pin exists, it returns to strict mode where bare `python` and `python3` are blocked.

### Set a persistent global Python default

```zsh
setpy global 3.14
```

This writes a pin to:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/pymanager/default-version
```

Every new interactive shell auto-applies that pin.

Show the current global pin:

```zsh
setpy global
```

Remove the global pin:

```zsh
setpy global clear
```

The key design detail: the pin stores a selector like `3.14`, not a full path. So after upgrading from `3.14.3` to `3.14.4`, the same `setpy global 3.14` pin should resolve to the newer patch automatically after refresh.

### Auto-select latest installed Python in every shell

Put this before sourcing `pythonmanager.sh` in `~/.zshrc`:

```zsh
export PYMANAGER_AUTO_SETPY=1
source ~/.config/zsh/pythonmanager.sh
```

Use this only if you want “drifting latest” behavior. A persistent global pin wins over `PYMANAGER_AUTO_SETPY=1`.

Priority is:

1. Manual `setpy <version>` in the current shell
2. `setpy global <version>` persistent pin
3. `PYMANAGER_AUTO_SETPY=1`
4. Strict mode

## Important update and install commands

### Check installed self-builds versus upstream latest

```zsh
pyinstall status
```

This is the first command I would run before upgrading. It compares your local CPython builds under `~/opt/python/<version>` against python.org’s latest supported patch releases.

### Show latest upstream patch versions

```zsh
pyinstall latest
```

For one minor series:

```zsh
pyinstall latest 3.14
```

### Print dependency install command

```zsh
pyinstall deps
```

This prints the OS-specific dependency command. It does not install the dependencies by itself.

On macOS, the expected dependency family is Homebrew-based. On Linux, the script emits apt-oriented build dependencies.

### Install a specific CPython patch version

```zsh
pyinstall install 3.14.4
```

Safer dry run first:

```zsh
pyinstall install 3.14.4 --dry-run
```

Skip confirmation:

```zsh
pyinstall install 3.14.4 --yes
```

Use explicit parallelism:

```zsh
pyinstall install 3.14.4 --jobs 10
```

Install under a custom prefix:

```zsh
pyinstall install 3.14.4 --prefix "$HOME/opt/python/3.14.4"
```

### Upgrade a minor series to latest patch

```zsh
pyinstall upgrade 3.14
```

Safer dry run:

```zsh
pyinstall upgrade 3.14 --dry-run
```

Skip confirmation:

```zsh
pyinstall upgrade 3.14 --yes
```

Force rebuild over an existing prefix:

```zsh
pyinstall upgrade 3.14 --force
```

Important: `--force` moves the old prefix aside to an `.old-<timestamp>` directory under `~/opt/python`. The scanner deliberately demotes those old backup directories so they do not win version selection.

### Verify a downloaded tarball

```zsh
pyinstall verify Python-3.14.4.tgz
```

The script uses Sigstore for Python `3.14+` and OpenPGP for `3.13` and older, according to the repo docs and `pyinstall.sh`.

### Refresh shell detection after manual install

```zsh
pyrefresh
```

If you invoke `pyinstall` through the shell function from `pythonmanager.sh`, successful install/upgrade should auto-run `pyrefresh`. If you run `./pyinstall.sh` directly, run `pyrefresh` yourself afterward.

## Pip and virtual environment commands

### Recommended workflow

Pick a Python version explicitly:

```zsh
python3.14 -m venv .venv
```

Activate it:

```zsh
source .venv/bin/activate
```

Install packages:

```zsh
pip install requests
```

Confirm:

```zsh
python -c "import sys; print(sys.executable)"
```

Deactivate:

```zsh
deactivate
```

### Temporary build mode

Outside a virtual environment, `pip` is blocked by design. For package build workflows only:

```zsh
setpy 3.14 --build
```

Then:

```zsh
pip install build
```

```zsh
python -m build
```

Clean up:

```zsh
setpy clear
```

Do not use build mode as your normal package-install workflow. Use a venv.

## Diagnostic commands

### Show actual binary resolution

```zsh
pywhich python3.14
```

```zsh
pywhich python
```

```zsh
pywhich pip
```

The repo also wraps `which` for Python/pip-related commands, but `pywhich` is the clearer command.

### Full diagnostics

```zsh
pydiag
```

Useful when Cursor Agent, Claude Code, Codex CLI, or another subprocess sees a different `python3` than your terminal.

### Debug scanner behavior

```zsh
PYMANAGER_DEBUG=1 pyinfo --all
```

### Inspect PATH ordering manually

```zsh
print -rl -- ${(ps.:.)PATH} | nl -ba | head -20
```

```zsh
whence -p python
```

```zsh
whence -p python3
```

## Practical command recipes

### Set Python `3.14` for this terminal only

```zsh
setpy 3.14
```

```zsh
python --version
```

```zsh
python3 --version
```

### Make Python `3.14` the default for all new shells

```zsh
setpy global 3.14
```

Open a new terminal, then:

```zsh
python --version
```

### Upgrade Python `3.14` to latest patch and keep global pin working

```zsh
pyinstall status
```

```zsh
pyinstall upgrade 3.14 --dry-run
```

```zsh
pyinstall upgrade 3.14 --yes
```

```zsh
pyrefresh
```

```zsh
setpy global 3.14
```

The last command is usually only needed if you have not already pinned `3.14`.

### Install exact version, then use it immediately

```zsh
pyinstall install 3.14.4 --dry-run
```

```zsh
pyinstall install 3.14.4 --yes
```

```zsh
pyrefresh
```

```zsh
setpy 3.14
```

```zsh
python --version
```

### Return to strict mode

```zsh
setpy clear
```

If a global pin exists and you want true strict mode:

```zsh
setpy global clear
```

```zsh
setpy clear
```

### Let every new shell pick latest installed Python

Add before sourcing the manager:

```zsh
export PYMANAGER_AUTO_SETPY=1
source ~/.config/zsh/pythonmanager.sh
```

Then reload:

```zsh
source ~/.zshrc
```

## Commands I would personally memorize

```zsh
pyinfo
```

```zsh
pyinfo --all
```

```zsh
setpy 3.14
```

```zsh
setpy clear
```

```zsh
setpy global 3.14
```

```zsh
setpy global clear
```

```zsh
pyinstall status
```

```zsh
pyinstall latest 3.14
```

```zsh
pyinstall upgrade 3.14 --dry-run
```

```zsh
pyinstall upgrade 3.14 --yes
```

```zsh
pyrefresh
```

```zsh
pywhich python3.14
```

```zsh
pydiag
```

## Main caveat

This repo is strict by design. If `python` or `python3` suddenly says no default command is available, that is not a bug. It means the manager is protecting you from accidentally using the wrong interpreter. Use one of these:

```zsh
python3.14 script.py
```

```zsh
setpy 3.14
```

```zsh
setpy global 3.14
```


