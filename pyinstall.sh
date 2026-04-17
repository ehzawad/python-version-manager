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

# Text fetch for metadata pages. Some python.org endpoints (including the
# Sigstore metadata page) serve gzip-compressed HTML regardless of the
# client's Accept-Encoding; --compressed asks curl to decompress.
_fetch_text() {
    local url="$1" out="$2"
    curl --compressed -fsSL --retry 3 --retry-delay 2 -o "$out" "$url"
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

# Embedded fallback in case the metadata page is unreachable and no cache exists.
# From https://www.python.org/downloads/metadata/sigstore/ — last synced 2026-04-17.
# Covers the series that are currently supported (status bugfix/security per
# PEP release-cycle) plus the two planned future series. EOL series (3.9 and
# earlier) are intentionally omitted — pyinstall status won't surface them,
# and the network path remains as a last resort if one is ever needed.
# Two distinct OIDC issuers in active use:
#   accounts.google.com          — Pablo Galindo, Thomas Wouters (3.10-3.13)
#   github.com/login/oauth       — interactive OAuth for Hugo, Savannah
_sigstore_embedded_fallback() {
    cat <<'FALLBACK'
3.10	pablogsal@python.org	https://accounts.google.com
3.11	pablogsal@python.org	https://accounts.google.com
3.12	thomas@python.org	https://accounts.google.com
3.13	thomas@python.org	https://accounts.google.com
3.14	hugo@python.org	https://github.com/login/oauth
3.15	hugo@python.org	https://github.com/login/oauth
3.16	savannah@python.org	https://github.com/login/oauth
3.17	savannah@python.org	https://github.com/login/oauth
FALLBACK
}

_sigstore_metadata_path() {
    print -- "$_PYINSTALL_CACHE/sigstore-metadata.tsv"
}

# Fetch + parse the python.org Sigstore metadata page. Atomic replace of the
# cache only on successful parse with ≥1 valid row.
_refresh_sigstore_metadata() {
    _mkcache
    local cache
    cache=$(_sigstore_metadata_path)
    local tmp_html="${cache}.html.$$"
    local tmp_tsv="${cache}.tmp.$$"

    if ! _fetch_text "https://www.python.org/downloads/metadata/sigstore/" "$tmp_html"; then
        rm -f "$tmp_html" "$tmp_tsv" 2>/dev/null
        return 1
    fi

    local py
    py=$(_bootstrap_python) || { rm -f "$tmp_html" "$tmp_tsv" 2>/dev/null; return 1; }

    # Parse the first <table> whose first data row has 4+ cells matching
    # (release, pep, manager, issuer). Emit tab-separated rows of
    # "<release>\t<identity-email>\t<issuer-url>". Skip rows with blank PEP.
    "$py" - "$tmp_html" > "$tmp_tsv" <<'PY'
import re, sys
from html.parser import HTMLParser

class TableParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_table = self.in_tr = self.in_cell = False
        self.cell = []
        self.row = []
        self.rows = []
    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self.in_table = True
        elif self.in_table and tag == "tr":
            self.in_tr = True
            self.row = []
        elif self.in_tr and tag in ("td", "th"):
            self.in_cell = True
            self.cell = []
    def handle_data(self, data):
        if self.in_cell:
            self.cell.append(data)
    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.in_cell:
            text = " ".join("".join(self.cell).split())
            self.row.append(text)
            self.in_cell = False
        elif tag == "tr" and self.in_tr:
            if self.row:
                self.rows.append(self.row)
            self.in_tr = False
        elif tag == "table":
            self.in_table = False

doc = open(sys.argv[1], encoding="utf-8").read()
p = TableParser()
p.feed(doc)

release_re = re.compile(r"^\d+\.\d+$")
email_re = re.compile(r"[\w.+-]+@[\w.-]+")
url_re = re.compile(r"https://\S+")

for row in p.rows:
    if len(row) < 4:
        continue
    release = row[0].strip()
    manager = row[2]
    issuer = row[3]
    if not release_re.fullmatch(release):
        continue
    email = email_re.search(manager)
    url = url_re.search(issuer)
    if email and url:
        print(f"{release}\t{email.group(0)}\t{url.group(0)}")
PY

    # Validate: need at least one row with the expected 3-column shape.
    if ! awk -F'\t' 'NF==3 && $1 ~ /^[0-9]+\.[0-9]+$/ { ok=1 } END { exit !ok }' "$tmp_tsv"; then
        rm -f "$tmp_html" "$tmp_tsv" 2>/dev/null
        return 1
    fi

    mv "$tmp_tsv" "$cache"
    rm -f "$tmp_html" 2>/dev/null
    return 0
}

# Resolve the Sigstore identity+issuer for a minor series (e.g. "3.14").
# Prints "<identity>\t<issuer>" on success; returns 1 if minor not found.
# Policy: fresh cache > refresh > stale cache (warn) > embedded fallback (warn) > fail.
_sigstore_identity_for() {
    local minor="$1"
    local cache
    cache=$(_sigstore_metadata_path)
    local age=999999
    [[ -f "$cache" ]] && age=$(( $(date +%s) - $(_file_mtime "$cache") ))

    if [[ ! -f "$cache" ]] || (( age > 86400 )); then
        if _refresh_sigstore_metadata 2>/dev/null; then
            :  # fresh cache, good
        elif [[ -f "$cache" ]]; then
            _warn "Could not refresh Sigstore metadata; using stale cache (${age}s old)"
        else
            _sigstore_embedded_fallback > "$cache" 2>/dev/null || return 1
            _warn "Sigstore metadata fetch failed; using embedded fallback (2026-04-17 snapshot)"
        fi
    fi

    local line
    line=$(awk -F'\t' -v m="$minor" '$1 == m { print; exit }' "$cache")
    [[ -n "$line" ]] || return 1
    local release identity issuer
    IFS=$'\t' read -r release identity issuer <<< "$line"
    print -- "${identity}\t${issuer}"
}

# Ensure the Sigstore helper venv is available with a sigstore CLI >= 3.3 and
# a supporting Python >= 3.10. Idempotent.
_ensure_sigstore_venv() {
    if [[ -x "${_PYINSTALL_SIGSTORE_VENV}/bin/python" ]]; then
        # Quick sanity check: CLI responds to `verify identity --help`
        if "$_PYINSTALL_SIGSTORE_VENV/bin/python" -m sigstore verify identity --help \
                >/dev/null 2>&1; then
            return 0
        fi
        _warn "Existing sigstore venv doesn't respond to 'verify identity'; recreating"
        rm -rf "$_PYINSTALL_SIGSTORE_VENV"
    elif [[ -d "${_PYINSTALL_SIGSTORE_VENV}" ]]; then
        # Directory exists but bin/python is missing or a dangling symlink —
        # typically the bootstrap Python the venv was built against got removed.
        _warn "Existing sigstore venv has a broken interpreter link; recreating"
        rm -rf "$_PYINSTALL_SIGSTORE_VENV"
    fi

    # Sigstore 3.3+ requires Python >= 3.10.
    local cand py=""
    for cand in python3 python3.14 python3.13 python3.12 python3.11 python3.10 /usr/bin/python3; do
        if command -v "$cand" >/dev/null 2>&1 && \
           "$cand" -c 'import sys; assert sys.version_info >= (3, 10)' 2>/dev/null; then
            py=$(command -v "$cand")
            break
        fi
    done
    [[ -n "$py" ]] || { _warn "No Python >= 3.10 available to bootstrap the Sigstore venv"; return 1; }

    _log "Creating Sigstore helper venv at $_PYINSTALL_SIGSTORE_VENV (Python $($py -V | awk '{print $2}')) ..."
    PIP_REQUIRE_VIRTUALENV=0 "$py" -m venv "$_PYINSTALL_SIGSTORE_VENV" \
        || { _warn "venv creation failed"; return 1; }
    "$_PYINSTALL_SIGSTORE_VENV/bin/pip" install --quiet --upgrade pip \
        || { _warn "pip upgrade failed"; return 1; }
    "$_PYINSTALL_SIGSTORE_VENV/bin/pip" install --quiet 'sigstore>=3.3,<5' \
        || { _warn "sigstore install failed"; return 1; }
    "$_PYINSTALL_SIGSTORE_VENV/bin/python" -m sigstore verify identity --help \
        >/dev/null 2>&1 \
        || { _warn "sigstore CLI 'verify identity' not found after install"; return 1; }
    return 0
}

_verify_sigstore() {
    # Strong verification for Python 3.14+. Optional override_identity/override_issuer
    # let the caller supply cert claims for a series not yet in the metadata table.
    local version="$1" tarball="$2"
    local override_identity="${3:-}" override_issuer="${4:-}"
    local mm="${version%.*}"
    local base="https://www.python.org/ftp/python/${version}"
    local bundle="${tarball}.sigstore"

    _log "Fetching Sigstore bundle ..."
    _fetch "${base}/${tarball:t}.sigstore" "$bundle" || {
        _warn "No Sigstore bundle available at $base"
        return 1
    }

    _ensure_sigstore_venv || return 1

    local identity issuer
    if [[ -n "$override_identity" ]] && [[ -n "$override_issuer" ]]; then
        identity="$override_identity"
        issuer="$override_issuer"
        _log "Using caller-supplied identity/issuer overrides"
    else
        local line
        line=$(_sigstore_identity_for "$mm") || {
            _err "No Sigstore identity mapping for Python ${mm}"
            _err "Update the embedded fallback, or pass --sigstore-identity and --sigstore-issuer."
            return 1
        }
        IFS=$'\t' read -r identity issuer <<< "$line"
    fi

    _log "Verifying Sigstore signature:"
    _log "  identity: $identity"
    _log "  issuer:   $issuer"

    if "$_PYINSTALL_SIGSTORE_VENV/bin/python" -m sigstore verify identity \
            --bundle "$bundle" \
            --cert-identity "$identity" \
            --cert-oidc-issuer "$issuer" \
            "$tarball" >&2; then
        _log "Sigstore verification OK"
        return 0
    fi

    _err "Sigstore verification failed for ${tarball:t}"
    _err "Expected from metadata: identity=${identity}, issuer=${issuer}"
    _err "If python.org's metadata has been updated since the embedded fallback"
    _err "was recorded, run: rm $(_sigstore_metadata_path) to force a re-fetch."
    _err "Or supply explicit --sigstore-identity and --sigstore-issuer to match the bundle."
    return 1
}

# Managed GPG home so we don't pollute the user's default keyring. Created on
# demand with mode 700. Cleaned up is out of scope — the keys are small.
_pymanager_gnupg_home() {
    print -- "$_PYINSTALL_CACHE/gnupg"
}

_ensure_gnupg_home() {
    local d
    d=$(_pymanager_gnupg_home)
    [[ -d "$d" ]] && return 0
    mkdir -p "$d" || return 1
    chmod 700 "$d"
}

# Per-minor signer map, sourced from https://www.python.org/downloads/metadata/pgp/.
# Each call prints "<name>\t<email>\t<fingerprint>\t<key_url>".
# Returns 1 if the minor has no mapping — happens for 3.14+ (Sigstore-only)
# and for EOL series we intentionally don't support here.
# Fingerprints are full 40-char SHA-1; short key IDs are insecure for pinning.
_gpg_signer_for() {
    local minor="$1"
    case "$minor" in
        3.12|3.13)
            # Thomas Wouters — key linked from the python.org PGP page via
            # https://github.com/Yhg1s.gpg (the "Yhg1s" moniker is Thomas).
            print -- "Thomas Wouters\tthomas@python.org\t7169605F62C751356D054A26A821E680E5FA6305\thttps://github.com/Yhg1s.gpg"
            ;;
        3.10|3.11)
            # Pablo Galindo Salgado — keybase link from python.org PGP page.
            print -- "Pablo Galindo Salgado\tpablogsal@python.org\tA035C8C19219BA821ECEA86B64E628F8D684696D\thttps://keybase.io/pablogsal/pgp_keys.asc"
            ;;
        *)
            return 1
            ;;
    esac
}

# Import an expected key. Tries the pinned per-signer URL first (direct
# HTTPS, matches what's linked from python.org). Falls back to
# keys.openpgp.org via the keyserver protocol. Either way, asserts the
# expected full fingerprint ends up in the managed keyring.
_ensure_gpg_key() {
    local expected_fpr="$1" key_url="$2"
    local gh
    gh=$(_pymanager_gnupg_home)

    # Fast path: key already present in the managed keyring.
    if gpg --homedir "$gh" --with-colons --fingerprint "$expected_fpr" \
            >/dev/null 2>&1; then
        return 0
    fi

    local tmpkey="${gh}/_fetching.asc.$$"
    if [[ -n "$key_url" ]] && _fetch_text "$key_url" "$tmpkey" 2>/dev/null; then
        if gpg --homedir "$gh" --import "$tmpkey" >/dev/null 2>&1; then
            rm -f "$tmpkey"
            # Verify the imported key matches the expected fingerprint.
            if gpg --homedir "$gh" --with-colons --fingerprint "$expected_fpr" \
                    >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    rm -f "$tmpkey" 2>/dev/null

    # Fallback: keys.openpgp.org keyserver.
    if gpg --homedir "$gh" --keyserver keys.openpgp.org \
            --recv-keys "$expected_fpr" >/dev/null 2>&1; then
        if gpg --homedir "$gh" --with-colons --fingerprint "$expected_fpr" \
                >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

_verify_gpg() {
    # Verification for Python 3.13.x and older. Release-manager fingerprints
    # are pinned per-minor from https://www.python.org/downloads/metadata/pgp/.
    # Returns 0 only when gpg reports VALIDSIG with the expected full fingerprint.
    local version="$1" tarball="$2"
    local mm="${version%.*}"
    command -v gpg >/dev/null 2>&1 || { _warn "gpg not installed"; return 1; }

    local signer_line name email expected_fpr key_url
    if ! signer_line=$(_gpg_signer_for "$mm"); then
        _err "No GPG signer mapping for Python $mm"
        return 1
    fi
    IFS=$'\t' read -r name email expected_fpr key_url <<< "$signer_line"

    local base="https://www.python.org/ftp/python/${version}"
    local sig="${tarball}.asc"
    _log "Fetching OpenPGP signature ..."
    _fetch "${base}/${tarball:t}.asc" "$sig" || {
        _err "No .asc signature published for $version"
        return 1
    }

    _ensure_gnupg_home || { _err "Could not create GPG home"; return 1; }
    local gh
    gh=$(_pymanager_gnupg_home)

    _log "Importing release-manager key ($name)..."
    if ! _ensure_gpg_key "$expected_fpr" "$key_url"; then
        _err "Failed to obtain expected GPG key:"
        _err "  Signer: $name <$email>"
        _err "  Key:    $expected_fpr"
        _err "  Source: $key_url"
        _err "Tried $key_url and keys.openpgp.org; both failed or produced a different fingerprint."
        return 1
    fi

    _log "Verifying OpenPGP signature:"
    _log "  signer: $name <$email>"
    _log "  key:    $expected_fpr"

    # --status-fd 1 emits machine-readable status lines. We assert a
    # VALIDSIG line with the exact expected full fingerprint — a plain exit 0
    # from gpg --verify could pass on a different key that happens to be in
    # the keyring.
    local gpg_status
    gpg_status=$(gpg --homedir "$gh" --status-fd 1 --verify "$sig" "$tarball" 2>&1)
    if [[ "$gpg_status" == *"[GNUPG:] VALIDSIG ${expected_fpr} "* ]] || \
       [[ "$gpg_status" == *"[GNUPG:] VALIDSIG ${expected_fpr}"$'\n'* ]]; then
        _log "GPG verification OK (VALIDSIG $expected_fpr)"
        return 0
    fi

    _err "GPG verification failed for ${tarball:t}"
    _err "Expected VALIDSIG $expected_fpr was not emitted."
    _err "gpg status output:"
    print -u2 -- "$gpg_status" | sed 's/^/  /'
    return 1
}

_verify_tarball() {
    # Choose the right verification path by version. --allow-tls-only
    # (alias: --no-sigstore) forces TLS-only. --sigstore-identity and
    # --sigstore-issuer together override the Sigstore metadata lookup.
    #
    # Policy: both paths fail-closed. A previous version silently fell back
    # to TLS-only on GPG failure, which hid real verification failures.
    local version="$1" tarball="$2" allow_tls_only="$3"
    local override_identity="${4:-}" override_issuer="${5:-}"
    local mm="${version%.*}"
    local minor="${mm#*.}"

    if (( allow_tls_only )); then
        _warn "Skipping cryptographic verification (--allow-tls-only); relying on TLS integrity only for $version"
        return 0
    fi

    if (( minor >= 14 )); then
        _verify_sigstore "$version" "$tarball" "$override_identity" "$override_issuer" && return 0
        _die "Sigstore verification failed for $version; pass --allow-tls-only to bypass at your own risk"
    else
        _verify_gpg "$version" "$tarball" && return 0
        _die "GPG verification failed for $version; pass --allow-tls-only to bypass at your own risk"
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

# Emit one line per dep: "<name>\t<ok|missing>\t<details>". The "details"
# column is informational (brew prefix, package hint, etc.) and may be empty.
_deps_status_macos() {
    if command -v brew >/dev/null 2>&1; then
        print -- "brew\tok\t$(command -v brew)"
    else
        print -- "brew\tmissing\tinstall from https://brew.sh"
        # Without brew, formula checks can't run; report them all as missing.
        local f
        for f in pkg-config openssl@3 xz gdbm tcl-tk mpdecimal zstd; do
            print -- "$f\tmissing\t(brew unavailable)"
        done
        return 0
    fi
    local f prefix
    for f in pkg-config openssl@3 xz gdbm tcl-tk mpdecimal zstd; do
        if prefix=$(brew --prefix "$f" 2>/dev/null); then
            print -- "$f\tok\t$prefix"
        else
            print -- "$f\tmissing\t"
        fi
    done
}

_deps_status_linux() {
    # Header check for system libs; pkg names are the apt hint column.
    local name header pkg
    for row in \
        "openssl:/usr/include/openssl/ssl.h:libssl-dev" \
        "bz2:/usr/include/bzlib.h:libbz2-dev" \
        "sqlite3:/usr/include/sqlite3.h:libsqlite3-dev" \
        "lzma:/usr/include/lzma.h:liblzma-dev" \
        "readline:/usr/include/readline/readline.h:libreadline-dev" \
        "gdbm:/usr/include/gdbm.h:libgdbm-dev" \
        "zlib:/usr/include/zlib.h:zlib1g-dev" \
        "uuid:/usr/include/uuid/uuid.h:uuid-dev" \
        "tcl-tk:/usr/include/tk.h:tk-dev"; do
        name="${row%%:*}"
        pkg="${row##*:}"
        header="${row#*:}"; header="${header%:*}"
        if [[ -f "$header" ]]; then
            print -- "$name\tok\t$header"
        else
            print -- "$name\tmissing\t$pkg"
        fi
    done
    # ffi header lives under arch-specific paths on Debian/Ubuntu.
    local ffi
    for ffi in /usr/include/ffi.h /usr/include/*/ffi.h(N); do
        [[ -f "$ffi" ]] && { print -- "ffi\tok\t$ffi"; return 0; }
    done
    print -- "ffi\tmissing\tlibffi-dev"
}

_deps_status() {
    case "$_PYINSTALL_OS" in
        macos) _deps_status_macos ;;
        linux) _deps_status_linux ;;
        *)     _warn "Unknown OS — skipping dep status"; return 0 ;;
    esac
}

_check_deps() {
    # Returns 0 if all deps are ok, 1 otherwise. Populates globals
    # _PYINSTALL_DEPS_OK and _PYINSTALL_DEPS_MISSING (arrays) so the plan
    # renderer can show per-item status without re-running checks.
    _PYINSTALL_DEPS_OK=()
    _PYINSTALL_DEPS_MISSING=()
    local name state details
    while IFS=$'\t' read -r name state details; do
        [[ -n "$name" ]] || continue
        if [[ "$state" == "ok" ]]; then
            _PYINSTALL_DEPS_OK+=("$name")
        else
            _PYINSTALL_DEPS_MISSING+=("$name")
        fi
    done < <(_deps_status)
    (( ${#_PYINSTALL_DEPS_MISSING} == 0 ))
}
typeset -ga _PYINSTALL_DEPS_OK _PYINSTALL_DEPS_MISSING

# === Configure / Build / Post-checks ===

# Print the exact ./configure flags that will be used, one per line. Policy
# lives here and is the single source of truth for both the plan renderer and
# the actual invocation.
_plan_configure_args() {
    local prefix="$1"
    print -- "--prefix=$prefix"
    print -- "--enable-optimizations"
    print -- "--with-lto"
    case "$_PYINSTALL_OS" in
        macos)
            local openssl_prefix
            openssl_prefix=$(brew --prefix openssl@3 2>/dev/null) \
                || openssl_prefix='<brew --prefix openssl@3 failed>'
            print -- "--with-openssl=$openssl_prefix"
            ;;
    esac
}

# Print the environment variables set during ./configure, one KEY=VALUE per
# line. `env` applies them only to the configure call.
_plan_configure_env() {
    case "$_PYINSTALL_OS" in
        macos)
            local gdbm_prefix
            gdbm_prefix=$(brew --prefix gdbm 2>/dev/null) \
                || gdbm_prefix='<brew --prefix gdbm failed>'
            print -- "GDBM_CFLAGS=-I${gdbm_prefix}/include"
            print -- "GDBM_LIBS=-L${gdbm_prefix}/lib -lgdbm"
            ;;
    esac
}

_run_configure() {
    local prefix="$1"
    local -a args=() envs=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && args+=("$line")
    done < <(_plan_configure_args "$prefix")
    while IFS= read -r line; do
        [[ -n "$line" ]] && envs+=("$line")
    done < <(_plan_configure_env)

    if (( ${#envs} )); then
        env "${envs[@]}" ./configure "${args[@]}" >&2
    else
        ./configure "${args[@]}" >&2
    fi
}

# Module lists used by _post_install_checks and _render_install_plan.
# Required: install fails if any of these can't be imported.
# Optional: install warns but still succeeds.
_PYINSTALL_REQUIRED_MODULES=(ssl hashlib sqlite3 bz2 lzma ctypes _decimal zlib)
_PYINSTALL_OPTIONAL_MODULES=(readline _gdbm uuid tkinter)

_post_install_checks() {
    local version="$1" prefix="$2"
    local mm="${version%.*}"
    local py="$prefix/bin/python${mm}"
    [[ -x "$py" ]] || _die "installed python${mm} not found at $py"

    local got
    got=$("$py" --version 2>&1)
    _log "$got"
    [[ "$got" == "Python ${version}" ]] || _warn "Version string differs: got '$got', expected 'Python ${version}'"

    local mod
    local -a req_ok=() req_missing=() opt_ok=() opt_missing=()
    for mod in $_PYINSTALL_REQUIRED_MODULES; do
        if "$py" -c "import $mod" 2>/dev/null; then
            req_ok+=("$mod")
        else
            req_missing+=("$mod")
        fi
    done
    for mod in $_PYINSTALL_OPTIONAL_MODULES; do
        if "$py" -c "import $mod" 2>/dev/null; then
            opt_ok+=("$mod")
        else
            opt_missing+=("$mod")
        fi
    done

    _log "Required modules OK: ${req_ok[*]}"
    (( ${#opt_ok} ))      && _log "Optional modules OK: ${opt_ok[*]}"
    (( ${#opt_missing} )) && _warn "Optional modules missing: ${opt_missing[*]}"

    if (( ${#req_missing} )); then
        _err "Required modules missing: ${req_missing[*]}"
        _err "Install is incomplete. Check system deps (pyinstall deps) and rebuild with --force."
        return 1
    fi
    return 0
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

# Globals set by _cmd_upgrade so _render_install_plan can show upgrade context.
# Private; reset at the top of _cmd_install.
typeset -g _PYINSTALL_ACTION=""
typeset -g _PYINSTALL_UPGRADE_FROM=""
typeset -g _PYINSTALL_UPGRADE_MINOR=""

# Render the full pre-flight install plan to stderr. Reads the args the caller
# already parsed so the display cannot drift from the actual invocation.
#   _render_install_plan <version> <prefix> <jobs> <allow_tls_only> <force> <keep_build> [<sigstore_identity> <sigstore_issuer>]
_render_install_plan() {
    local version="$1" prefix="$2" jobs="$3" allow_tls_only="$4" force="$5" keep_build="$6"
    local override_identity="${7:-}" override_issuer="${8:-}"
    local mm="${version%.*}"
    local minor="${mm#*.}"
    local base="https://www.python.org/ftp/python/${version}"
    local tarball_name="Python-${version}.tgz"
    local tarball="$_PYINSTALL_DOWNLOADS/$tarball_name"
    local builddir="$_PYINSTALL_BUILD_DIR/Python-$version"

    print -u2 -- ""
    if [[ "$_PYINSTALL_ACTION" == "upgrade" ]] && [[ -n "$_PYINSTALL_UPGRADE_FROM" ]]; then
        print -u2 -- "Install plan: CPython ${version}"
        print -u2 -- "Action: upgrade ${_PYINSTALL_UPGRADE_MINOR} from ${_PYINSTALL_UPGRADE_FROM} to ${version}"
    else
        print -u2 -- "Install plan: CPython ${version}"
        print -u2 -- "Action: fresh install of ${mm} series"
    fi
    print -u2 -- "Platform: $_PYINSTALL_OS $(uname -m)"
    print -u2 -- ""

    # --- Source ---
    print -u2 -- "Source"
    print -u2 -- "  URL:          ${base}/${tarball_name}"
    print -u2 -- "  Cache:        ${tarball}"
    if [[ -f "$tarball" ]]; then
        print -u2 -- "  Cache state:  cached ($(_file_mtime "$tarball" | xargs -I{} date -r {} '+%Y-%m-%d %H:%M' 2>/dev/null || echo downloaded))"
    else
        print -u2 -- "  Cache state:  not downloaded"
    fi
    print -u2 -- ""

    # --- Verification ---
    print -u2 -- "Verification"
    if (( minor >= 14 )); then
        if (( allow_tls_only )); then
            print -u2 -- "  Method:       TLS-only (Sigstore disabled by --allow-tls-only)"
            print -u2 -- "  Identity:     n/a"
        else
            print -u2 -- "  Method:       Sigstore bundle (Python 3.14+)"
            local identity issuer source
            if [[ -n "$override_identity" ]] && [[ -n "$override_issuer" ]]; then
                identity="$override_identity"
                issuer="$override_issuer"
                source="--sigstore-identity / --sigstore-issuer"
            else
                local line
                if line=$(_sigstore_identity_for "$mm" 2>/dev/null); then
                    IFS=$'\t' read -r identity issuer <<< "$line"
                    source="python.org metadata (cached)"
                else
                    identity="UNKNOWN"
                    issuer="UNKNOWN"
                    source="NOT FOUND — pass --sigstore-identity and --sigstore-issuer"
                fi
            fi
            print -u2 -- "  Identity:     $identity"
            print -u2 -- "  Issuer:       $issuer"
            print -u2 -- "  Source:       $source"
            if [[ -x "${_PYINSTALL_SIGSTORE_VENV}/bin/python" ]]; then
                print -u2 -- "  Helper venv:  $_PYINSTALL_SIGSTORE_VENV (exists)"
            else
                print -u2 -- "  Helper venv:  $_PYINSTALL_SIGSTORE_VENV (will be created; installs sigstore>=3.3,<5 from PyPI)"
            fi
        fi
    else
        if (( allow_tls_only )); then
            print -u2 -- "  Method:       TLS-only (--allow-tls-only)"
            print -u2 -- "  Signature:    skipped — no cryptographic release-manager verification"
        elif command -v gpg >/dev/null 2>&1; then
            print -u2 -- "  Method:       OpenPGP (.asc) via gpg"
            local gpg_line gpg_name gpg_email gpg_fpr gpg_url
            if gpg_line=$(_gpg_signer_for "$mm" 2>/dev/null); then
                IFS=$'\t' read -r gpg_name gpg_email gpg_fpr gpg_url <<< "$gpg_line"
                # Pretty-print the fingerprint in 4-char groups (like gpg does).
                local pretty_fpr
                pretty_fpr=$(print -- "$gpg_fpr" | sed -E 's/(.{4})/\1 /g' | sed 's/ $//')
                print -u2 -- "  Signer:       $gpg_name <$gpg_email>"
                print -u2 -- "  Key:          $pretty_fpr"
                print -u2 -- "  Key source:   $gpg_url (falls back to keys.openpgp.org)"
                local gh
                gh=$(_pymanager_gnupg_home)
                if [[ -d "$gh" ]] && gpg --homedir "$gh" --with-colons --fingerprint "$gpg_fpr" >/dev/null 2>&1; then
                    print -u2 -- "  Keyring:      $gh (key present)"
                else
                    print -u2 -- "  Keyring:      $gh (will fetch on verify)"
                fi
                print -u2 -- "  Policy:       fail-closed; pass --allow-tls-only to bypass"
            else
                print -u2 -- "  Signer:       UNKNOWN — no mapping for $mm"
                print -u2 -- "  Policy:       install will fail unless --allow-tls-only is passed"
            fi
        else
            print -u2 -- "  Method:       gpg not installed"
            print -u2 -- "  Policy:       install will fail unless --allow-tls-only is passed"
        fi
    fi
    print -u2 -- ""

    # --- Dependencies ---
    print -u2 -- "Dependencies"
    if (( ${#_PYINSTALL_DEPS_OK} )); then
        print -u2 -- "  ok:           ${_PYINSTALL_DEPS_OK[*]}"
    fi
    if (( ${#_PYINSTALL_DEPS_MISSING} )); then
        print -u2 -- "  MISSING:      ${_PYINSTALL_DEPS_MISSING[*]}"
        print -u2 -- "  Install:      pyinstall deps  (prints the command for your OS)"
    else
        print -u2 -- "  missing:      none"
    fi
    print -u2 -- ""

    # --- Build ---
    print -u2 -- "Build"
    print -u2 -- "  Work dir:     ${builddir}"
    print -u2 -- "  Work cleanup: removed before extract; $(if (( keep_build )); then print -n 'kept after success'; else print -n 'removed after success'; fi); kept on failure"
    local envline
    local env_shown=0
    while IFS= read -r envline; do
        [[ -n "$envline" ]] || continue
        if (( ! env_shown )); then
            print -u2 -- "  Configure env:"
            env_shown=1
        fi
        print -u2 -- "    $envline"
    done < <(_plan_configure_env)
    print -u2 -- "  Configure:"
    local argline
    local -a cfg_args=()
    while IFS= read -r argline; do
        [[ -n "$argline" ]] && cfg_args+=("$argline")
    done < <(_plan_configure_args "$prefix")
    print -u2 -- "    ./configure ${cfg_args[*]}"
    print -u2 -- "  Make:         make -j${jobs} && make altinstall"
    print -u2 -- ""

    # --- Install ---
    print -u2 -- "Install"
    print -u2 -- "  Prefix:       ${prefix}"
    print -u2 -- "  Binary:       ${prefix}/bin/python${mm}"
    if [[ -x "${prefix}/bin/python${mm}" ]]; then
        if (( force )); then
            local backup="${prefix}.old-$(date +%Y%m%d-%H%M%S)"
            print -u2 -- "  Existing:     present; --force will move aside to ${backup}"
        else
            print -u2 -- "  Existing:     PRESENT — install will refuse without --force"
        fi
    else
        print -u2 -- "  Existing:     not present"
    fi
    print -u2 -- "  Change path:  pass --prefix <DIR>, or enter 'e' at the confirmation prompt"
    print -u2 -- ""

    # --- Post-build checks ---
    print -u2 -- "Post-build checks"
    print -u2 -- "  Required:     ${_PYINSTALL_REQUIRED_MODULES[*]}  (install fails on any miss)"
    print -u2 -- "  Optional:     ${_PYINSTALL_OPTIONAL_MODULES[*]}  (warnings only)"
    print -u2 -- ""

    # --- Shell refresh ---
    print -u2 -- "Shell refresh"
    print -u2 -- "  When run via the pyinstall() shell function, pyrefresh is called on success."
    print -u2 -- "  When run as the script directly, run 'pyrefresh' in your interactive shell."
    print -u2 -- ""
}

# True if _cmd_install should refuse because the prefix is already installed
# and --force wasn't given. Prints guidance to stderr.
_install_would_clobber() {
    local prefix="$1" version="$2" force="$3"
    local mm="${version%.*}"
    [[ -x "$prefix/bin/python${mm}" ]] || return 1  # nothing to clobber
    if (( force )); then
        return 1  # --force explicitly opts in
    fi
    _err "CPython ${version} already exists at ${prefix}"
    _err "Pass --force to rebuild (the existing prefix will be moved aside, not overwritten)."
    return 0
}

# Move an existing prefix aside before a --force rebuild. Only auto-renames
# prefixes under the managed root ($_PYINSTALL_PREFIX_ROOT); refuses to touch
# arbitrary prefixes without operator confirmation.
_move_prefix_aside() {
    local prefix="$1"
    [[ -d "$prefix" ]] || return 0
    local stamp backup
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="${prefix}.old-${stamp}"

    if [[ "${prefix:A}" == "${_PYINSTALL_PREFIX_ROOT:A}"/* ]]; then
        _log "Moving existing prefix aside: $prefix -> $backup"
        mv "$prefix" "$backup"
        return 0
    fi

    # Prefix is outside the managed root — require explicit confirmation.
    _err "Refusing to move aside prefix outside ~/opt/python: $prefix"
    _err "Move or remove it manually, then re-run install."
    return 1
}

_cmd_install() {
    local version="" jobs="" prefix=""
    local allow_tls_only=0 keep_build=0 assume_yes=0 dry_run=0 force=0
    local sigstore_identity="" sigstore_issuer=""
    while (( $# )); do
        case "$1" in
            -y|--yes)              assume_yes=1; shift ;;
            -j|--jobs)             jobs="$2"; shift 2 ;;
            --allow-tls-only|--no-sigstore) allow_tls_only=1; shift ;;
            --sigstore-identity)   sigstore_identity="$2"; shift 2 ;;
            --sigstore-issuer)     sigstore_issuer="$2"; shift 2 ;;
            --keep-build)          keep_build=1; shift ;;
            --prefix)              prefix="$2"; shift 2 ;;
            --dry-run)             dry_run=1; shift ;;
            --force)               force=1; shift ;;
            -h|--help)             _cmd_help; return 0 ;;
            -*)                    _die "unknown flag: $1" ;;
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

    if [[ -n "$sigstore_identity" && -z "$sigstore_issuer" ]] || \
       [[ -z "$sigstore_identity" && -n "$sigstore_issuer" ]]; then
        _die "--sigstore-identity and --sigstore-issuer must be passed together"
    fi

    [[ -n "$version" ]] || _die "usage: pyinstall install <X.Y.Z> [flags]"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || _die "invalid version: $version"

    prefix="${prefix:-${_PYINSTALL_PREFIX_ROOT}/${version}}"

    if [[ -z "$jobs" ]]; then
        if [[ "$_PYINSTALL_OS" == "macos" ]]; then
            jobs=$(sysctl -n hw.ncpu)
        else
            jobs=$(nproc 2>/dev/null || echo 4)
        fi
    fi

    # Run dep check so the plan can show per-item status; don't abort yet —
    # the plan tells the user what's missing.
    _check_deps || true

    _render_install_plan "$version" "$prefix" "$jobs" "$allow_tls_only" "$force" "$keep_build" "$sigstore_identity" "$sigstore_issuer"

    if (( dry_run )); then
        # Exit nonzero if the install would fail at preconditions; otherwise 0.
        # Match the preconditions the real install flow enforces.
        if (( ${#_PYINSTALL_DEPS_MISSING} )); then
            _err "dry-run: would fail — missing dependencies"
            return 1
        fi
        if _install_would_clobber "$prefix" "$version" "$force"; then
            _err "dry-run: would fail — prefix exists"
            return 1
        fi
        # Verification preconditions — mirror _verify_tarball's policy.
        if (( ! allow_tls_only )); then
            local dry_mm="${version%.*}"
            local dry_minor="${dry_mm#*.}"
            if (( dry_minor >= 14 )); then
                if [[ -z "$sigstore_identity" ]] || [[ -z "$sigstore_issuer" ]]; then
                    if ! _sigstore_identity_for "$dry_mm" >/dev/null 2>&1; then
                        _err "dry-run: would fail — no Sigstore identity mapping for Python $dry_mm"
                        _err "Pass --sigstore-identity and --sigstore-issuer, or --allow-tls-only to bypass."
                        return 1
                    fi
                fi
            else
                if ! command -v gpg >/dev/null 2>&1; then
                    _err "dry-run: would fail — gpg is not installed and Python $dry_mm requires OpenPGP"
                    _err "Install gpg or pass --allow-tls-only to bypass."
                    return 1
                fi
                if ! _gpg_signer_for "$dry_mm" >/dev/null 2>&1; then
                    _err "dry-run: would fail — no OpenPGP signer mapping for Python $dry_mm"
                    _err "Pass --allow-tls-only to bypass, or install a currently-supported series."
                    return 1
                fi
            fi
        fi
        _log "dry-run: plan is executable"
        return 0
    fi

    if (( ${#_PYINSTALL_DEPS_MISSING} )); then
        _err "Missing dependencies: ${_PYINSTALL_DEPS_MISSING[*]}"
        _err "Run 'pyinstall deps' to see the install command for your OS."
        return 1
    fi

    if _install_would_clobber "$prefix" "$version" "$force"; then
        return 1
    fi

    if (( ! assume_yes )); then
        local ans new_prefix
        while true; do
            print -n -u2 -- "Proceed? [y]es / [N]o / [e]dit install prefix: "
            read -r ans
            case "${ans:l}" in
                y|yes)
                    break
                    ;;
                ""|n|no)
                    _die "aborted"
                    ;;
                e|edit)
                    print -n -u2 -- "New install prefix [${prefix}]: "
                    read -r new_prefix
                    if [[ -n "$new_prefix" ]]; then
                        # Expand ~ manually since `read` doesn't tilde-expand.
                        new_prefix="${new_prefix/#\~/$HOME}"
                        prefix="$new_prefix"
                    fi
                    # Re-check deps (cheap) and re-render the plan with the new prefix so
                    # Existing/Binary lines reflect the change.
                    _check_deps || true
                    _render_install_plan "$version" "$prefix" "$jobs" "$allow_tls_only" "$force" "$keep_build" "$sigstore_identity" "$sigstore_issuer"
                    # After editing, the clobber check needs to re-run against the new prefix.
                    if _install_would_clobber "$prefix" "$version" "$force"; then
                        print -u2 -- "(use --force to rebuild, or [e]dit a different prefix)"
                    fi
                    ;;
                *)
                    print -u2 -- "Please answer y, N, or e."
                    ;;
            esac
        done
    fi

    # Post-edit re-check for clobber (the user may have edited into an existing prefix).
    if _install_would_clobber "$prefix" "$version" "$force"; then
        return 1
    fi

    if (( force )); then
        _move_prefix_aside "$prefix" || return 1
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

    _verify_tarball "$version" "$tarball" "$allow_tls_only" "$sigstore_identity" "$sigstore_issuer"

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

    if ! _post_install_checks "$version" "$prefix"; then
        # Keep the build tree so the user can inspect.
        _warn "Keeping build tree for inspection: $builddir"
        return 1
    fi

    if (( ! keep_build )); then
        _log "Cleaning build tree"
        rm -rf "$builddir"
    fi

    _log "Installed $version at $prefix"
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

    if [[ -n "$current" ]] && [[ "$current" == "$latest" ]]; then
        _log "$minor is already up to date ($current)"
        return 0
    fi

    # Thread context into the plan renderer.
    _PYINSTALL_ACTION="upgrade"
    _PYINSTALL_UPGRADE_MINOR="$minor"
    _PYINSTALL_UPGRADE_FROM="$current"

    _cmd_install "$latest" "$@"
    local rc=$?

    # Reset so subsequent calls don't inherit stale context.
    _PYINSTALL_ACTION=""
    _PYINSTALL_UPGRADE_MINOR=""
    _PYINSTALL_UPGRADE_FROM=""
    return $rc
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
  -y, --yes                     Skip confirmation prompt
  -j, --jobs N                  make -j N (default: detected)
  --dry-run                     Print the install plan and exit without building
  --force                       If the prefix already exists, move it aside and rebuild
  --allow-tls-only              Skip Sigstore/GPG (3.14+ relies on TLS only) — use with caution
  --no-sigstore                 Alias for --allow-tls-only
  --sigstore-identity EMAIL     Override the expected cert-identity (for new series not in metadata)
  --sigstore-issuer URL         Override the expected cert-oidc-issuer (pass with --sigstore-identity)
  --keep-build                  Keep build tree after successful install
  --prefix DIR                  Override install prefix (default: ~/opt/python/<version>)

Note: pyinstall always runs `make altinstall` (versioned names only —
python3.14 etc., never bare python3). The "no default python/python3" design
of this manager depends on managed prefixes containing zero unversioned
interpreter shims; `make install` would defeat strict mode by giving bare
`python3` a real PATH-resolvable target.

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
