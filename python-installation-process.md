Below is a parameterized recipe that follows the **macOS/Homebrew instructions published in the CPython Developer Guide for Python 3.13 and newer**. It installs CPython under `$HOME/opt/python/<version>`, builds it for Apple-silicon only with PGO + LTO, links against Homebrew's OpenSSL 3 and GDBM, and finishes with `make altinstall` so the system- and Homebrew-provided interpreters remain untouched.

Set `PYVER` (e.g. `3.13.6`, `3.14.3`) once and the rest of the commands pick it up.

---

### 1 · Ensure Xcode command-line tools are present

```bash
xcode-select --install   # no-op if already installed
```

Apple’s CLT provides clang and the standard BSD tool-chain needed for the build; nothing else from full Xcode is required ([Python Developer's Guide][1]).

### 2 · Install the external libraries CPython expects on macOS 13 +

```bash
brew update
brew install pkg-config openssl@3 xz gdbm tcl-tk mpdecimal zstd
```

The devguide lists exactly these formulae for Python 3.13+, noting that macOS lacks headers for OpenSSL and GDBM ([Python Developer's Guide][1]).

### 3 · Fetch and verify the source release

```bash
PYVER=3.14.3   # set this once; used by every step below

cd ~/Downloads
curl -O "https://www.python.org/ftp/python/${PYVER}/Python-${PYVER}.tgz"
```

Then verify. Python 3.14 and newer are signed **only with Sigstore**; `.asc` (OpenPGP) signatures are not published. Python 3.13.x and older still publish both. Pick the path for your version:

#### Python 3.14.x and newer — Sigstore

```bash
curl -O "https://www.python.org/ftp/python/${PYVER}/Python-${PYVER}.tgz.sigstore"

# The `sigstore` CLI is a Python package. Install it into a dedicated venv so
# it never pollutes a system interpreter. Any already-working Python 3.x will
# do as the bootstrap (Homebrew, system, or a previous self-build).
BOOTSTRAP_PY=$(command -v python3 || command -v python3.13 || command -v python3.12)
"$BOOTSTRAP_PY" -m venv ~/.cache/sigstore-venv
~/.cache/sigstore-venv/bin/pip install --quiet sigstore

# Expected signer identity for the 3.14/3.15 series is hugo@python.org via
# GitHub's OIDC issuer. The current mapping is published at
# https://www.python.org/downloads/metadata/sigstore/ — confirm before trusting.
~/.cache/sigstore-venv/bin/python -m sigstore verify identity \
  --bundle "Python-${PYVER}.tgz.sigstore" \
  --cert-identity "hugo@python.org" \
  --cert-oidc-issuer "https://token.actions.githubusercontent.com" \
  "Python-${PYVER}.tgz"
```

#### Python 3.13.x and older — OpenPGP (legacy)

```bash
curl -O "https://www.python.org/ftp/python/${PYVER}/Python-${PYVER}.tgz.asc"
# Release-manager key fingerprint for 3.13.x is Thomas Wouters'; see
# https://www.python.org/downloads/metadata/pgp/ for the current mapping.
gpg --keyserver keys.openpgp.org --recv-keys A035C8C19219BA821ECEA86B64E628F8D68469693D3F93B29109B3CF
gpg --verify "Python-${PYVER}.tgz.asc" "Python-${PYVER}.tgz"
```

#### Then extract

```bash
tar -xzf "Python-${PYVER}.tgz"
cd "Python-${PYVER}"
```

### 4 · Configure for an optimized, arm64-only, non-framework build under `~/opt`

```bash
PREFIX="$HOME/opt/python/${PYVER}"

GDBM_CFLAGS="-I$(brew --prefix gdbm)/include" \
GDBM_LIBS="-L$(brew --prefix gdbm)/lib -lgdbm" \
./configure \
  --prefix="$PREFIX" \
  --enable-optimizations \
  --with-lto \
  --with-openssl="$(brew --prefix openssl@3)"
```

* `--enable-optimizations --with-lto` are the officially recommended flags for a PGO + LTO build ([Python Developer's Guide][3]).
* The GDBM and OpenSSL environment variables follow the Homebrew snippet for Python 3.13+ in the devguide ([Python Developer's Guide][1]).
* Leaving out `--enable-framework` yields a classic Unix tree in `bin/ lib/ include/`.
* The `--build` triple is optional—Autoconf autodetects arm64—but specifying it guarantees no accidental universal wiring.

### 5 · Compile and install without touching `python3`

```bash
make -j 10
make altinstall        # installs python3.13 and pip3.13 under $PREFIX/bin
```

`make altinstall` is the documented safeguard so you never overwrite another interpreter on the machine ([Python documentation][4]).

### 6 · Add the new interpreter to your shell and test

```bash
echo "export PATH=\"\$HOME/opt/python/${PYVER}/bin:\$PATH\"" >> ~/.zshrc
source ~/.zshrc

# Replace ${PYVER%.*} with the major.minor (e.g. 3.14 for 3.14.3)
python${PYVER%.*} -VV          # expect "Python ${PYVER} (main, …)"
python${PYVER%.*} -m ssl       # should import without error → OpenSSL 3.x
python${PYVER%.*} -m tkinter   # opens a blank Tk window if tcl-tk linked
```

---

**Probable failure mode**
If `--with-openssl` is omitted or its path is wrong, `_ssl` fails to build, and anything importing `ssl` or `hashlib` with SHA-256 falls back to Apple’s CommonCrypto, causing missing algorithms or runtime errors. Re-running the same `configure` with the correct `--with-openssl="$(brew --prefix openssl@3)"` flag and `make altinstall` fixes the issue.

This procedure remains entirely within official CPython guidance and uses only vendor-supplied tool-chains and Homebrew formulae for the few libraries macOS lacks by default.

[1]: https://devguide.python.org/contrib/workflows/install-dependencies/ "Install Dependencies"
[2]: https://www.python.org/downloads/release/python-3136/ "Python Release Python 3.13.6 | Python.org"
[3]: https://devguide.python.org/getting-started/setup-building/ "Setup and building"
[4]: https://docs.python.org/3/using/unix.html "2. Using Python on Unix platforms — Python 3.13.6 documentation"
