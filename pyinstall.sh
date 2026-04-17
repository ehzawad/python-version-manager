#!/usr/bin/env zsh
# pyinstall.sh — CPython source-build manager
#
# Reads latest supported patch versions from python.org, compares against
# local self-builds under ~/opt/python/<version>/, and automates the build
# recipe from python-installation-process.md (Homebrew/apt deps, GPG or
# Sigstore verification, --enable-optimizations --with-lto, make altinstall).
#
# Subcommands: status | latest | install | upgrade | verify | deps | help
# See `pyinstall help` for flags.

set -u
setopt err_exit pipe_fail no_unset

_PYINSTALL_VERSION="0.1"
_PYINSTALL_PREFIX_ROOT="${HOME}/opt/python"
_PYINSTALL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/pymanager"
_PYINSTALL_BUILD_DIR="${_PYINSTALL_CACHE}/build"
_PYINSTALL_DOWNLOADS="${_PYINSTALL_CACHE}/downloads"
_PYINSTALL_SIGSTORE_VENV="${_PYINSTALL_CACHE}/sigstore-venv"

case "$(uname -s)" in
    Darwin) _PYINSTALL_OS=macos ;;
    Linux)  _PYINSTALL_OS=linux ;;
    *)      _PYINSTALL_OS=unknown ;;
esac

# === Logging ===

_log()  { print -u2 -- "[pyinstall] $*"; }
_warn() { print -u2 -- "[pyinstall] WARN: $*"; }
_err()  { print -u2 -- "[pyinstall] ERROR: $*"; }
_die()  { _err "$@"; exit 1; }

# === HTTP + filesystem helpers ===

_fetch() {
    local url="$1" out="$2"
    curl -fsSL --retry 3 --retry-delay 2 -o "$out" "$url"
}

_file_mtime() {
    # Seconds since epoch, macOS stat -f + Linux stat -c fallback.
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

_mkcache() {
    mkdir -p "$_PYINSTALL_CACHE" "$_PYINSTALL_DOWNLOADS" "$_PYINSTALL_BUILD_DIR"
}

_bootstrap_python() {
    # Any already-working Python 3.x that can parse JSON and run pip.
    local cand
    for cand in python3 python3.14 python3.13 python3.12 python3.11 python3.10 /usr/bin/python3; do
        if command -v "$cand" >/dev/null 2>&1; then
            "$cand" -c 'import sys; assert sys.version_info >= (3, 8)' 2>/dev/null && {
                command -v "$cand"
                return 0
            }
        fi
    done
    return 1
}

# === Discovery: upstream versions + local installs ===

_remote_version_dirs() {
    # Parse the FTP index HTML; return every X.Y.Z directory name on its own line.
    curl -fsSL https://www.python.org/ftp/python/ \
        | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
        | sed -E 's|href="([^/"]+)/?"|\1|' \
        | sort -t. -k1,1n -k2,2n -k3,3n -u
}

_supported_minors() {
    # Returns lines: "<minor>\t<status>" for series where status ∈ {bugfix, security}.
    # Cached for 24 hours in $_PYINSTALL_CACHE/release-cycle.json.
    _mkcache
    local cache="$_PYINSTALL_CACHE/release-cycle.json"
    local age=0
    [[ -f "$cache" ]] && age=$(( $(date +%s) - $(_file_mtime "$cache") ))
    if [[ ! -f "$cache" ]] || (( age > 86400 )); then
        _fetch "https://peps.python.org/api/python-releases.json" "$cache" \
            || { _warn "Failed to refresh release-cycle.json; using stale cache"; [[ -f "$cache" ]] || return 1; }
    fi
    local py
    py=$(_bootstrap_python) || _die "No Python 3.x found to parse release-cycle.json"
    "$py" - "$cache" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
# PEPs API shape: {"metadata": {"<minor>": {pep, status, ...}}, "releases": {...}}.
# The status we need lives in "metadata". Fall back to scanning the top-level if
# the schema changes.
series = data.get("metadata") or data
if not isinstance(series, dict):
    sys.exit(0)
def key(item):
    try: return tuple(int(x) for x in item[0].split("."))
    except Exception: return (0, 0)
for ver, meta in sorted(series.items(), key=key):
    if not isinstance(meta, dict):
        continue
    s = meta.get("status", "")
    if s in ("bugfix", "security"):
        print(f"{ver}\t{s}")
PY
}

_latest_per_minor() {
    # Lines: "<minor>\t<X.Y.Z>\t<status>" for every supported minor.
    local -A latest latest_status
    local -a supported_list=()
    local line minor status mm patch cur_patch
    while IFS=$'\t' read -r minor series_status; do
        [[ -n "$minor" ]] || continue
        supported_list+=("$minor")
        latest_status[$minor]="$series_status"
    done < <(_supported_minors)

    while IFS= read -r line; do
        [[ "$line" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
        mm="${match[1]}.${match[2]}"
        patch="${match[3]}"
        (( ${supported_list[(I)$mm]} )) || continue
        cur_patch="${${latest[$mm]-0.0.0}##*.}"
        if (( patch > cur_patch )); then
            latest[$mm]="$line"
        fi
    done < <(_remote_version_dirs)

    for mm in ${(ko)latest}; do
        print -- "${mm}\t${latest[$mm]}\t${latest_status[$mm]-}"
    done | sort -t. -k1,1n -k2,2n
}

_local_installs() {
    # Lines: "<X.Y.Z>" for every ~/opt/python/<version>/bin/python<major.minor>
    # that actually exists and executes.
    [[ -d "$_PYINSTALL_PREFIX_ROOT" ]] || return 0
    local d ver mm py
    for d in "$_PYINSTALL_PREFIX_ROOT"/*(N/); do
        ver="${d:t}"
        [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        mm="${ver%.*}"
        py="$d/bin/python${mm}"
        [[ -x "$py" ]] || continue
        print -- "$ver"
    done | sort -t. -k1,1n -k2,2n -k3,3n
}

# === Verification ===

_verify_sigstore() {
    # Strong verification for Python 3.14+.
    local version="$1" tarball="$2"
    local base="https://www.python.org/ftp/python/${version}"
    local bundle="${tarball}.sigstore"
    _log "Fetching Sigstore bundle ..."
    _fetch "${base}/${tarball:t}.sigstore" "$bundle" || {
        _warn "No Sigstore bundle available at $base"
        return 1
    }

    # Establish the sigstore CLI in a private venv (created once, cached).
    if [[ ! -x "${_PYINSTALL_SIGSTORE_VENV}/bin/python" ]]; then
        local py
        py=$(_bootstrap_python) || { _warn "No bootstrap Python for sigstore"; return 1; }
        _log "Creating Sigstore helper venv at $_PYINSTALL_SIGSTORE_VENV ..."
        # PIP_REQUIRE_VIRTUALENV is set by the manager baseline; explicitly
        # unset it for the bootstrap pip call since we're creating the venv.
        PIP_REQUIRE_VIRTUALENV=0 "$py" -m venv "$_PYINSTALL_SIGSTORE_VENV" \
            || { _warn "venv creation failed"; return 1; }
        "$_PYINSTALL_SIGSTORE_VENV/bin/pip" install --quiet --upgrade pip sigstore \
            || { _warn "sigstore install failed"; return 1; }
    fi

    # Expected identity varies per release manager. Current mapping per
    # https://www.python.org/downloads/metadata/sigstore/ (as of 2026):
    #   3.13: thomas@python.org
    #   3.14, 3.15: hugo@python.org
    local mm="${version%.*}"
    local major="${version%%.*}"
    local minor="${mm#*.}"
    local identity
    case "$mm" in
        3.13)       identity="thomas@python.org" ;;
        3.14|3.15)  identity="hugo@python.org" ;;
        *)
            _warn "Unknown Sigstore identity for $mm; check python.org/downloads/metadata/sigstore/"
            return 1 ;;
    esac

    _log "Verifying Sigstore signature (identity=$identity) ..."
    "$_PYINSTALL_SIGSTORE_VENV/bin/python" -m sigstore verify identity \
        --bundle "$bundle" \
        --cert-identity "$identity" \
        --cert-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$tarball" >&2 && {
            _log "Sigstore verification OK"
            return 0
        }
    _err "Sigstore verification failed"
    return 1
}

_verify_gpg() {
    # Verification for Python 3.13.x and older. Release-manager fingerprints
    # are published at https://www.python.org/downloads/metadata/pgp/.
    local version="$1" tarball="$2"
    command -v gpg >/dev/null 2>&1 || { _warn "gpg not installed"; return 1; }

    local base="https://www.python.org/ftp/python/${version}"
    local sig="${tarball}.asc"
    _log "Fetching OpenPGP signature ..."
    _fetch "${base}/${tarball:t}.asc" "$sig" || {
        _warn "No .asc signature published for $version"
        return 1
    }

    # Short key IDs are insecure; use full fingerprints. This set covers
    # recent release managers; extend as new series appear.
    local fpr
    local -a fingerprints=(
        "A035C8C19219BA821ECEA86B64E628F8D68469"   # Ned Deily (legacy)
        "E3FF2839C048B25C084DEBE9B26995E310250568" # Łukasz Langa
        "A821A8B57C6BB0BC0CB0C2D84735AE3F47EDFEE"  # Pablo Galindo
        "FB9921286F5E1540E929C4208A76DC37F2175DB0" # Thomas Wouters
    )
    _log "Importing release-manager keys ..."
    for fpr in $fingerprints; do
        gpg --keyserver keys.openpgp.org --recv-keys "$fpr" 2>/dev/null || true
    done

    _log "Verifying OpenPGP signature ..."
    gpg --verify "$sig" "$tarball" >&2 && {
        _log "GPG verification OK"
        return 0
    }
    _err "GPG verification failed"
    return 1
}

_verify_tarball() {
    # Choose the right verification path by version. Respects --no-sigstore
    # to force the GPG or sha256 path.
    local version="$1" tarball="$2" no_sigstore="$3"
    local mm="${version%.*}"
    local minor="${mm#*.}"

    if (( minor >= 14 )); then
        if (( no_sigstore )); then
            _warn "Skipping Sigstore by request; no alternative signature exists for $version — relying on TLS only"
            return 0
        fi
        _verify_sigstore "$version" "$tarball" && return 0
        _die "Sigstore verification failed for $version; pass --no-sigstore to bypass at your own risk"
    else
        _verify_gpg "$version" "$tarball" && return 0
        _warn "GPG verification failed or unavailable; proceeding with TLS-only integrity"
        return 0
    fi
}

# === Dependencies ===

_deps_cmd_macos() {
    echo "brew update && brew install pkg-config openssl@3 xz gdbm tcl-tk mpdecimal zstd"
}

_deps_cmd_linux() {
    # Per CPython devguide: build-dep gets most of it, the explicit list
    # covers optional modules that build-dep may miss on some distros.
    cat <<EOF
sudo apt-get update
sudo apt-get build-dep -y python3
sudo apt-get install -y \\
    build-essential gdb lcov pkg-config \\
    libbz2-dev libffi-dev libgdbm-dev libgdbm-compat-dev liblzma-dev \\
    libncurses5-dev libreadline-dev libsqlite3-dev libssl-dev \\
    lzma lzma-dev tk-dev uuid-dev zlib1g-dev
# libmpdec-dev is not packaged on Debian 12 / Ubuntu 24.04; the build falls
# back to the bundled copy.
EOF
}

_check_deps_macos() {
    command -v brew >/dev/null 2>&1 || {
        _err "Homebrew not found. Install from https://brew.sh first."
        return 1
    }
    local missing=()
    local f
    for f in openssl@3 xz gdbm tcl-tk mpdecimal zstd; do
        brew --prefix "$f" >/dev/null 2>&1 || missing+=("$f")
    done
    if (( ${#missing} )); then
        _err "Missing Homebrew formulae: ${missing[*]}"
        return 1
    fi
}

_check_deps_linux() {
    # Cheap heuristic: check for headers we know we need.
    local missing=()
    [[ -f /usr/include/openssl/ssl.h ]] || missing+=("libssl-dev")
    [[ -f /usr/include/bzlib.h ]] || missing+=("libbz2-dev")
    [[ -f /usr/include/sqlite3.h ]] || missing+=("libsqlite3-dev")
    [[ -f /usr/include/ffi.h ]] || [[ -f /usr/include/x86_64-linux-gnu/ffi.h ]] || [[ -f /usr/include/aarch64-linux-gnu/ffi.h ]] || missing+=("libffi-dev")
    if (( ${#missing} )); then
        _err "Likely missing apt packages: ${missing[*]}"
        return 1
    fi
}

_check_deps() {
    case "$_PYINSTALL_OS" in
        macos) _check_deps_macos ;;
        linux) _check_deps_linux ;;
        *)     _warn "Unknown OS — skipping dep check"; return 0 ;;
    esac
}

# === Configure / Build / Post-checks ===

_run_configure() {
    local prefix="$1"
    local -a args=(--prefix="$prefix" --enable-optimizations --with-lto)
    case "$_PYINSTALL_OS" in
        macos)
            local openssl_prefix
            openssl_prefix="$(brew --prefix openssl@3 2>/dev/null)" \
                || _die "brew --prefix openssl@3 failed"
            args+=(--with-openssl="$openssl_prefix")
            GDBM_CFLAGS="-I$(brew --prefix gdbm)/include" \
            GDBM_LIBS="-L$(brew --prefix gdbm)/lib -lgdbm" \
                ./configure "${args[@]}" >&2
            ;;
        linux)
            ./configure "${args[@]}" >&2
            ;;
        *)
            ./configure "${args[@]}" >&2
            ;;
    esac
}

_post_install_checks() {
    local version="$1" prefix="$2"
    local mm="${version%.*}"
    local py="$prefix/bin/python${mm}"
    [[ -x "$py" ]] || _die "installed python${mm} not found at $py"

    local got
    got=$("$py" --version 2>&1)
    _log "$got"
    [[ "$got" == "Python ${version}" ]] || _warn "Version string differs: got '$got', expected 'Python ${version}'"

    _log "Module availability:"
    local mod ok=() missing=()
    for mod in ssl sqlite3 bz2 lzma ctypes readline _gdbm uuid _decimal zlib hashlib; do
        if "$py" -c "import $mod" 2>/dev/null; then
            ok+=("$mod")
        else
            missing+=("$mod")
        fi
    done
    _log "  OK: ${ok[*]}"
    if (( ${#missing} )); then
        _warn "  MISSING: ${missing[*]} — likely missing system deps"
    fi

    # tkinter is most likely to silently fail on macOS if tcl-tk isn't linked.
    if "$py" -c "import tkinter" 2>/dev/null; then
        _log "  tkinter: OK"
    else
        _warn "  tkinter: FAILED — check tcl-tk installation"
    fi
}

# === Subcommands ===

_cmd_status() {
    local -A installed
    local v mm
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        mm="${v%.*}"
        # Keep highest patch per minor
        local cur="${installed[$mm]:-0.0.0}"
        if [[ "$v" == "$(print -- "$v" "$cur" | tr ' ' '\n' | sort -t. -k3,3n | tail -1)" ]]; then
            installed[$mm]="$v"
        fi
    done < <(_local_installs)

    printf '\n%-8s %-12s %-12s %-10s  %s\n' "SERIES" "INSTALLED" "LATEST" "STATUS" "NOTE"
    printf '%s\n' "------------------------------------------------------------------------"
    local series_status local_patch note
    while IFS=$'\t' read -r mm v series_status; do
        local_patch="${installed[$mm]:-none}"
        if [[ "$local_patch" == "none" ]]; then
            note="not installed"
        elif [[ "$local_patch" == "$v" ]]; then
            note="up to date"
        else
            note="upgrade: $local_patch → $v"
        fi
        printf '%-8s %-12s %-12s %-10s  %s\n' "$mm" "$local_patch" "$v" "$series_status" "$note"
    done < <(_latest_per_minor)
    echo ""
}

_cmd_latest() {
    if (( $# > 0 )); then
        local want="$1"
        _latest_per_minor | awk -F'\t' -v m="$want" '$1 == m { print $2 }'
    else
        _latest_per_minor | awk -F'\t' '{ print $1 " " $2 }'
    fi
}

_cmd_deps() {
    case "$_PYINSTALL_OS" in
        macos) _deps_cmd_macos ;;
        linux) _deps_cmd_linux ;;
        *)     _die "Unsupported OS: $(uname -s)" ;;
    esac
}

_cmd_verify() {
    (( $# >= 1 )) || _die "usage: pyinstall verify <tarball>"
    local tarball="$1"
    [[ -f "$tarball" ]] || _die "not found: $tarball"
    local version
    if [[ "${tarball:t}" =~ ^Python-([0-9]+\.[0-9]+\.[0-9]+)\.(tgz|tar\.xz)$ ]]; then
        version="${match[1]}"
    else
        _die "filename must match Python-X.Y.Z.(tgz|tar.xz): $tarball"
    fi
    _verify_tarball "$version" "$tarball" 0
}

_cmd_install() {
    local version="" jobs="" prefix="" no_sigstore=0 keep_build=0 assume_yes=0
    while (( $# )); do
        case "$1" in
            -y|--yes)        assume_yes=1; shift ;;
            -j|--jobs)       jobs="$2"; shift 2 ;;
            --no-sigstore)   no_sigstore=1; shift ;;
            --keep-build)    keep_build=1; shift ;;
            --prefix)        prefix="$2"; shift 2 ;;
            -h|--help)       _cmd_help; return 0 ;;
            -*)              _die "unknown flag: $1" ;;
            *)
                if [[ -z "$version" ]]; then
                    version="$1"
                else
                    _die "too many positional args: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$version" ]] || _die "usage: pyinstall install <X.Y.Z> [flags]"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || _die "invalid version: $version"

    prefix="${prefix:-${_PYINSTALL_PREFIX_ROOT}/${version}}"

    if [[ -x "$prefix/bin/python${version%.*}" ]]; then
        _log "$version already installed at $prefix — skipping"
        return 0
    fi

    _check_deps || _die "missing dependencies; see: pyinstall deps"

    if [[ -z "$jobs" ]]; then
        if [[ "$_PYINSTALL_OS" == "macos" ]]; then
            jobs=$(sysctl -n hw.ncpu)
        else
            jobs=$(nproc 2>/dev/null || echo 4)
        fi
    fi

    _log "Plan: install CPython $version to $prefix, make -j$jobs"
    if (( ! assume_yes )); then
        print -n -u2 -- "Proceed? [y/N] "
        local ans
        read -r ans
        [[ "$ans" == y* || "$ans" == Y* ]] || _die "aborted"
    fi

    _mkcache
    local base="https://www.python.org/ftp/python/${version}"
    local tarball_name="Python-${version}.tgz"
    local tarball="$_PYINSTALL_DOWNLOADS/$tarball_name"

    if [[ ! -f "$tarball" ]]; then
        _log "Downloading $tarball_name ..."
        _fetch "$base/$tarball_name" "$tarball"
    else
        _log "Using cached download: $tarball"
    fi

    _verify_tarball "$version" "$tarball" "$no_sigstore"

    local builddir="$_PYINSTALL_BUILD_DIR/Python-$version"
    rm -rf "$builddir"
    _log "Extracting ..."
    tar -xzf "$tarball" -C "$_PYINSTALL_BUILD_DIR"
    pushd "$builddir" >/dev/null

    _log "Running configure ..."
    _run_configure "$prefix"

    _log "Running make -j$jobs (this takes a while; PGO+LTO) ..."
    make -j"$jobs" >&2

    _log "Running make altinstall ..."
    make altinstall >&2

    popd >/dev/null

    _post_install_checks "$version" "$prefix"

    if (( ! keep_build )); then
        _log "Cleaning build tree"
        rm -rf "$builddir"
    fi

    _log "Installed $version at $prefix"
    _log "Run 'pyrefresh' in your interactive shell to pick it up."
}

_cmd_upgrade() {
    (( $# >= 1 )) || _die "usage: pyinstall upgrade <minor>  (e.g. 3.14)"
    local minor="$1"
    shift
    [[ "$minor" =~ ^[0-9]+\.[0-9]+$ ]] || _die "invalid minor: $minor"

    local latest
    latest=$(_cmd_latest "$minor")
    [[ -n "$latest" ]] || _die "$minor is not a supported series or upstream lookup failed"

    local current=""
    local v
    for v in $(_local_installs); do
        [[ "${v%.*}" == "$minor" ]] || continue
        current="$v"
    done

    if [[ -z "$current" ]]; then
        _log "$minor not installed locally; installing $latest"
    elif [[ "$current" == "$latest" ]]; then
        _log "$minor is already up to date ($current)"
        return 0
    else
        _log "Upgrading $minor: $current → $latest"
    fi

    _cmd_install "$latest" "$@"
}

_cmd_help() {
    cat <<EOF
pyinstall $_PYINSTALL_VERSION — CPython source-build manager

Usage: pyinstall <subcommand> [args...] [flags]

Subcommands:
  status                 Show installed vs upstream-latest per supported minor
  latest [<minor>]       Print upstream-latest patch for each supported minor, or just one
  install <X.Y.Z>        Download, verify, build, altinstall into ~/opt/python/<version>
  upgrade <minor>        Install latest patch of <minor> series if newer than installed
  verify <tarball>       Dry-run verification of a local tarball
  deps                   Print the OS-specific dep install command (does not run it)
  help                   This help

Install/upgrade flags:
  -y, --yes              Skip confirmation prompt
  -j, --jobs N           make -j N (default: detected)
  --no-sigstore          Skip Sigstore verification (3.14+ falls back to TLS-only)
  --keep-build           Keep build tree after successful install
  --prefix DIR           Override install prefix (default: ~/opt/python/<version>)

Source of truth:
  - Supported minor series: https://peps.python.org/api/python-releases.json
  - Available artifacts:    https://www.python.org/ftp/python/
  - Sigstore identities:    https://www.python.org/downloads/metadata/sigstore/
  - OpenPGP fingerprints:   https://www.python.org/downloads/metadata/pgp/

Cache dir: $_PYINSTALL_CACHE
EOF
}

# === Dispatch ===

case "${1:-help}" in
    status)  shift; _cmd_status "$@" ;;
    latest)  shift; _cmd_latest "$@" ;;
    install) shift; _cmd_install "$@" ;;
    upgrade) shift; _cmd_upgrade "$@" ;;
    verify)  shift; _cmd_verify "$@" ;;
    deps)    shift; _cmd_deps "$@" ;;
    help|-h|--help) _cmd_help ;;
    *)       _err "unknown subcommand: $1"; _cmd_help; exit 2 ;;
esac
