
# Python Version Manager by ehzawad@gmail.com
#
# WHAT THIS DOES:
# - Forces explicit Python versions (python3.X) - no default python/python3
# - Blocks pip outside virtual environments
# - Auto-detects venvs and exports VIRTUAL_ENV for subprocesses
# - Temporary version override with 'setpy <version>'
# - Build mode for pip access with 'setpy <version> --build'
#
# LIMITATIONS (Fundamental OS restrictions):
# - Wrapper functions ONLY work in interactive shells where you type commands
# - Subprocesses/sandboxes inherit ENVIRONMENT VARIABLES but NOT shell functions
# - When Claude Code/Codex spawn subshells, they get exported vars (VIRTUAL_ENV, PATH)
#   but NOT the wrapper functions - this is normal Unix behavior
#
# SANDBOXED ENVIRONMENT SUPPORT:
# Auto-detects when helper functions aren't loaded and safely falls back to system commands.
# Bypass triggers: non-interactive shells, CI=1, CODEX_SANDBOX_NETWORK_DISABLED=1
# Manual bypass: export PYTHON_MANAGER_FORCE_BYPASS=1
# Diagnostics: Run 'pydiag'
#
# Global variables
typeset -ga _PYTHON_VERSIONS
typeset -gA _PYTHON_PATHS
typeset -gA _PYTHON_INFO
typeset -g _VENV_PYTHON_VERSION_CACHE=""
typeset -g _LAST_VIRTUAL_ENV=""
typeset -g _PYTHONS_SCANNED=0
typeset -g _PYTHON_OVERRIDE=""
typeset -gi _PYTHON_MANAGER_READY=0
typeset -g _PYTHON_SYMLINK_DIR="$HOME/.local/bin"
typeset -g _PYTHON_SYMLINK_MANAGED=0
typeset -g _PYTHON_BUILD_MODE=0

# Comprehensive Python scanner - lazy loaded
_scan_all_pythons() {
    # Skip if already scanned
    [[ $_PYTHONS_SCANNED -eq 1 ]] && return 0
    
    _PYTHON_VERSIONS=()
    _PYTHON_PATHS=()
    _PYTHON_INFO=()
    
    # All possible Python locations on macOS
    local search_paths=(
        # User installations (preferred)
        "$HOME/.local/bin"
        "$HOME/bin"
        "$HOME/.pythons/*/bin"
        "$HOME/Library/Python/*/bin"
        
        # Homebrew
        "/opt/homebrew/bin"
        "/opt/homebrew/opt/python@*/bin"
        "/usr/local/bin"
        "/usr/local/opt/python@*/bin"
        
        # System Python
        "/usr/bin"
        
        # Custom installations
        "/opt/python*/bin"
        "$HOME/opt/python*/bin"
        "$HOME/opt/python/*/bin"      # For structure like ~/opt/python/3.12.12/bin
        "/opt/python/*/bin"            # For structure like /opt/python/3.12.12/bin
    )
    
    # First pass: find all python executables
    local python_executables=()
    
    for pattern in "${search_paths[@]}"; do
        for dir in ${~pattern}(N/); do
            [[ -d "$dir" ]] || continue
            
            # Find ALL python executables
            for py in "$dir"/python*(N); do
                [[ -x "$py" ]] || continue
                [[ "$py" =~ "python-config" ]] && continue
                [[ "$py" =~ "pythonw" ]] && continue
                
                # Skip managed symlinks in ~/.local/bin (we created these)
                if [[ "${py%/*}" == "$_PYTHON_SYMLINK_DIR" ]] && [[ -L "$py" ]]; then
                    continue
                fi
                
                python_executables+=("$py")
            done
        done
    done
    
    # Second pass: get version info for each executable
    for py in $python_executables; do
        # Try to get version
        local version=""
        local fullver=""
        
        # Method 1: Extract from filename (require dot: python3.12, not python312)
        if [[ "${py:t}" =~ '^python([0-9]+\.[0-9]+)$' ]]; then
            version="${match[1]}"
        fi
        
        # Method 2: Run the executable to get version (with validation)
        if fullver=$("$py" --version 2>&1); then
            # Validate it's actually Python
            if [[ ! "$fullver" =~ ^Python ]]; then
                continue  # Not a Python interpreter
            fi
            if [[ "$fullver" =~ 'Python ([0-9]+)\.([0-9]+)\.?[0-9]*' ]]; then
                local extracted_version="${match[1]}.${match[2]}"
                
                if [[ -z "$version" ]]; then
                    version="$extracted_version"
                fi
                
                # Skip Python 2
                if [[ "${match[1]}" == "2" ]]; then
                    continue
                fi
            fi
        else
            continue
        fi
        
        # If we still don't have a version, try one more method
        if [[ -z "$version" ]] || [[ "$version" == "3" ]]; then
            local pyver=$("$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
            if [[ -n "$pyver" ]] && [[ "$pyver" =~ '^3\.' ]]; then
                version="$pyver"
            fi
        fi
        
        # Skip if we couldn't determine version or if it's Python 2
        [[ -z "$version" ]] && continue
        [[ "$version" =~ '^2' ]] && continue
        
        # Get real path if it's a symlink (macOS-compatible)
        local realpath="$py"
        if [[ -L "$py" ]]; then
            local count=0
            while [[ -L "$realpath" ]] && (( count++ < 50 )); do
                local target=$(readlink "$realpath" 2>/dev/null || echo "$realpath")
                # Handle relative symlinks
                [[ "$target" != /* ]] && target="${realpath:h}/$target"
                realpath="$target"
            done
        fi
        
        # Determine if we should store this Python
        local should_store=0
        
        if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
            # First time seeing this major.minor version
            should_store=1
        else
            # Already have this version, decide which to keep
            
            # Preference 1: Always prefer $HOME/.local/bin
            if [[ "${py%/*}" == "$HOME/.local/bin" ]]; then
                should_store=1
            # Preference 2: Compare patch versions - keep the highest
            elif [[ "$fullver" =~ 'Python ([0-9]+)\.([0-9]+)\.([0-9]+)' ]]; then
                local new_major="${match[1]}"
                local new_minor="${match[2]}"
                local new_patch="${match[3]}"
                
                # Extract stored version
                local stored_info="${_PYTHON_INFO[$version]}"
                if [[ "$stored_info" =~ 'Python ([0-9]+)\.([0-9]+)\.([0-9]+)' ]]; then
                    local stored_major="${match[1]}"
                    local stored_minor="${match[2]}"
                    local stored_patch="${match[3]}"
                    
                    # Compare patch versions numerically
                    if (( new_patch > stored_patch )); then
                        should_store=1
                    fi
                fi
            fi
        fi
        
        # Store this Python if we decided to
        if [[ $should_store -eq 1 ]]; then
            # Only add to array if this is the first time we see this major.minor
            if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
                _PYTHON_VERSIONS+=("$version")
            fi
            _PYTHON_PATHS[$version]="$py"
            _PYTHON_INFO[$version]="$fullver ($realpath)"
        fi
    done
    
    # Sort versions properly (3.9 < 3.10 < 3.11...)
    _PYTHON_VERSIONS=(${(u)_PYTHON_VERSIONS})
    _PYTHON_VERSIONS=($(print -l "${_PYTHON_VERSIONS[@]}" | sort -t. -k1,1n -k2,2n))
    _PYTHONS_SCANNED=1
}

# Check if we're in a virtual environment
_in_virtual_env() {
    # Standard venv/virtualenv
    [[ -n "$VIRTUAL_ENV" ]] && return 0

    # Conda
    [[ -n "$CONDA_DEFAULT_ENV" ]] && return 0

    # Poetry
    [[ -n "$POETRY_ACTIVE" ]] && return 0

    # Pipenv
    [[ -n "$PIPENV_ACTIVE" ]] && return 0

    # Heuristic: Check if python command points to a venv-like structure
    # This helps detect venvs created by sandboxed environments
    # Use type -p to get actual binary path (command -v returns function name if defined)
    local python_path=$(type -p python 2>/dev/null)
    if [[ -n "$python_path" ]] && [[ -x "$python_path" ]]; then
        # Check if python is in a bin/ directory with activate script
        if [[ "$python_path" =~ /bin/python ]]; then
            local venv_dir="${python_path%/bin/python*}"
            # Validate this looks like a venv (has activate script and pyvenv.cfg)
            if [[ -f "$venv_dir/bin/activate" ]] && [[ -f "$venv_dir/pyvenv.cfg" ]]; then
                # Temporarily set VIRTUAL_ENV if not already set
                # This helps the rest of the script work correctly
                if [[ -z "$VIRTUAL_ENV" ]]; then
                    export VIRTUAL_ENV="$venv_dir"
                fi
                return 0
            fi
        fi
    fi

    return 1
}

# Get the Python version used by current venv - with caching
_get_venv_python_version() {
    # Check cache first
    if [[ -n "$VIRTUAL_ENV" ]] && [[ "$VIRTUAL_ENV" == "$_LAST_VIRTUAL_ENV" ]] && [[ -n "$_VENV_PYTHON_VERSION_CACHE" ]]; then
        echo "$_VENV_PYTHON_VERSION_CACHE"
        return 0
    fi
    
    local ver=""
    
    if [[ -n "$VIRTUAL_ENV" ]]; then
        # Method 1: Check pyvenv.cfg (fastest)
        if [[ -f "$VIRTUAL_ENV/pyvenv.cfg" ]]; then
            # Extract only major.minor version (3.12) not full version (3.12.11)
            local full_version=$(grep -E "^version\s*=" "$VIRTUAL_ENV/pyvenv.cfg" 2>/dev/null | sed -E 's/^version\s*=\s*(.*)$/\1/' | tr -d ' ')
            if [[ "$full_version" =~ ^([0-9]+\.[0-9]+) ]]; then
                ver="${match[1]}"
            fi
        fi
        
        # Method 2: Run the venv's python (slower but reliable)
        if [[ -z "$ver" ]] && [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
            ver=$("$VIRTUAL_ENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        fi
        
        # Cache the result
        if [[ -n "$ver" ]]; then
            _LAST_VIRTUAL_ENV="$VIRTUAL_ENV"
            _VENV_PYTHON_VERSION_CACHE="$ver"
            echo "$ver"
            return 0
        fi
    fi
    
    # For conda
    if [[ -n "$CONDA_DEFAULT_ENV" ]] && command -v python >/dev/null 2>&1; then
        ver=$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        if [[ -n "$ver" ]]; then
            echo "$ver"
            return 0
        fi
    fi
    
    return 1
}

# Determine if the manager internals are ready (handles partial loads)
_py_manager_available() {
    [[ ${_PYTHON_MANAGER_READY:-0} -eq 1 ]] || return 1
    typeset -f _in_virtual_env >/dev/null 2>&1 || return 1
    typeset -f _scan_all_pythons >/dev/null 2>&1 || return 1
    return 0
}

# Detect automation contexts where we should not intercept python calls
_py_manager_should_bypass() {
    # Explicit bypass flag
    [[ -n "${PYTHON_MANAGER_FORCE_BYPASS:-}" ]] && return 0

    # CI environments
    [[ -n "${CI:-}" ]] && return 0

    # Non-interactive shells (scripts, subshells, sandboxed execution)
    [[ ! -o interactive ]] && return 0

    # Codex sandbox detection (confirmed real env var)
    [[ -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ]] && return 0

    return 1
}

# Python wrapper
python() {
    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1; then
        # Functions not loaded, just use system python
        command python "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        command python "$@"
        local _py_status=$?
        if (( _py_status == 127 || _py_status == 126 )) && _py_manager_available; then
            _scan_all_pythons
            if (( ${#_PYTHON_VERSIONS} )); then
                local fallback_version="${_PYTHON_VERSIONS[-1]}"
                "${_PYTHON_PATHS[$fallback_version]}" "$@"
                return $?
            fi
        fi
        return $_py_status
    fi

    if ! _py_manager_available; then
        command python "$@"
        return $?
    fi

    # Priority 1: Virtual environment
    if _in_virtual_env; then
        if [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
            "$VIRTUAL_ENV/bin/python" "$@"
        else
            command python "$@"
        fi
        return $?
    fi
    
    # Priority 2: Temporary override
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Validate override still exists
        if ! _validate_python_override; then
            return 1
        fi

        # Check if trying to use pip module (blocked unless build mode)
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
                # Build mode: allow python -m pip
                _scan_all_pythons
                if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
                    echo "[build mode] Running python -m pip with Python ${_PYTHON_OVERRIDE}..." >&2
                    "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
                    return $?
                fi
            else
                echo "Error: python -m pip is blocked outside virtual environments"
                echo ""
                echo "To use pip:"
                echo "   1. Create a virtual environment: python${_PYTHON_OVERRIDE} -m venv [venv-projname]"
                echo "   2. Activate it: source [venv-projname]/bin/activate"
                echo "   3. Then use pip normally"
                echo ""
                echo "This prevents accidental system-wide package installations."
                echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
                return 1
            fi
        fi

        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
            "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
            return $?
        fi
    fi
    
    # Priority 3: System fallback (if explicitly allowed AND override is set)
    if [[ -n "$PYTHON_ALLOW_SYSTEM" ]] && [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Still block pip even with system fallback
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            echo "Error: python -m pip is blocked outside virtual environments"
            echo ""
            echo "To use pip:"
            echo "   1. Create a virtual environment and activate it"
            echo "   2. Then use pip normally"
            echo ""
            echo "This prevents accidental system-wide package installations."
            echo "Note: PYTHON_ALLOW_SYSTEM does NOT affect pip."
            return 1
        fi

        # Use the setpy override for build tools
        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
            "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
            return $?
        fi
    fi
    
    # Default: Show error
    _scan_all_pythons

    echo "Error: No default 'python' command available"
    echo ""

    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "Warning: No Python 3.x installations found!"
        return 1
    fi

    echo "Available Python versions:"
    echo ""

    local sorted_versions=($(print -l "${_PYTHON_VERSIONS[@]}" | sort -t. -k1,1n -k2,2n -r))
    for ver in $sorted_versions; do
        echo "  - python${ver} -> ${_PYTHON_INFO[$ver]}"
    done

    echo ""
    echo "Options:"
    echo "   1. Create venv: python${_PYTHON_VERSIONS[-1]} -m venv [venv-projname] && source [venv-projname]/bin/activate"
    echo "   2. Set temporary default: setpy ${_PYTHON_VERSIONS[-1]}"
    echo "   3. For build tools: setpy <version> && PYTHON_ALLOW_SYSTEM=1 your-build-command"

    return 1
}

# Python3 wrapper
python3() {
    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1; then
        # Functions not loaded, just use system python3
        command python3 "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        command python3 "$@"
        local _py_status=$?
        if (( _py_status == 127 || _py_status == 126 )) && _py_manager_available; then
            _scan_all_pythons
            if (( ${#_PYTHON_VERSIONS} )); then
                local fallback_version="${_PYTHON_VERSIONS[-1]}"
                "${_PYTHON_PATHS[$fallback_version]}" "$@"
                return $?
            fi
        fi
        return $_py_status
    fi

    if ! _py_manager_available; then
        command python3 "$@"
        return $?
    fi

    # Priority 1: Virtual environment
    if _in_virtual_env; then
        if [[ -x "$VIRTUAL_ENV/bin/python3" ]]; then
            "$VIRTUAL_ENV/bin/python3" "$@"
        else
            command python3 "$@"
        fi
        return $?
    fi
    
    # Priority 2: Temporary override
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Validate override still exists
        if ! _validate_python_override; then
            return 1
        fi

        # Check if trying to use pip module (blocked unless build mode)
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
                # Build mode: allow python3 -m pip
                _scan_all_pythons
                if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
                    echo "[build mode] Running python3 -m pip with Python ${_PYTHON_OVERRIDE}..." >&2
                    "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
                    return $?
                fi
            else
                echo "Error: python3 -m pip is blocked outside virtual environments"
                echo ""
                echo "To use pip:"
                echo "   1. Create a virtual environment: python${_PYTHON_OVERRIDE} -m venv [venv-projname]"
                echo "   2. Activate it: source [venv-projname]/bin/activate"
                echo "   3. Then use pip normally"
                echo ""
                echo "This prevents accidental system-wide package installations."
                echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
                return 1
            fi
        fi

        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
            "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
            return $?
        fi
    fi

    # Priority 3: System fallback (if explicitly allowed AND override is set)
    if [[ -n "$PYTHON_ALLOW_SYSTEM" ]] && [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Still block pip even with system fallback
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            echo "Error: python3 -m pip is blocked outside virtual environments"
            echo ""
            echo "To use pip:"
            echo "   1. Create a virtual environment and activate it"
            echo "   2. Then use pip normally"
            echo ""
            echo "This prevents accidental system-wide package installations."
            echo "Note: PYTHON_ALLOW_SYSTEM does NOT affect pip."
            return 1
        fi

        # Use the setpy override for build tools
        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
            "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
            return $?
        fi
    fi
    
    # Default: Show error
    _scan_all_pythons

    echo "Error: No default 'python3' command available"
    echo ""

    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "Warning: No Python 3.x installations found!"
        return 1
    fi

    echo "Available Python versions:"
    echo ""

    local sorted_versions=($(print -l "${_PYTHON_VERSIONS[@]}" | sort -t. -k1,1n -k2,2n -r))
    for ver in $sorted_versions; do
        echo "  - python${ver} -> ${_PYTHON_INFO[$ver]}"
    done

    echo ""
    echo "Options:"
    echo "   1. Create venv: python${_PYTHON_VERSIONS[-1]} -m venv [venv-projname] && source [venv-projname]/bin/activate"
    echo "   2. Set temporary default: setpy ${_PYTHON_VERSIONS[-1]}"
    echo "   3. For build tools: setpy <version> && PYTHON_ALLOW_SYSTEM=1 your-build-command"

    return 1
}

# Pip wrapper - allows override only in build mode
pip() {
    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1 || \
       ! typeset -f _in_virtual_env >/dev/null 2>&1; then
        # Functions not loaded, just use system pip
        command pip "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        command pip "$@"
        return $?
    fi

    if ! _py_manager_available; then
        command pip "$@"
        return $?
    fi

    if _in_virtual_env; then
        if [[ -x "$VIRTUAL_ENV/bin/pip" ]]; then
            "$VIRTUAL_ENV/bin/pip" "$@"
        else
            command pip "$@"
        fi
        return $?
    fi

    # Build mode: allow pip with the override Python
    if [[ $_PYTHON_BUILD_MODE -eq 1 ]] && [[ -n "$_PYTHON_OVERRIDE" ]]; then
        _scan_all_pythons
        local python_path="${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
        if [[ -n "$python_path" ]]; then
            echo "[build mode] Running pip with Python ${_PYTHON_OVERRIDE}..." >&2
            "$python_path" -m pip "$@"
            return $?
        fi
    fi

    echo "Error: pip is not available outside virtual environments"
    echo ""
    echo "To use pip:"
    echo "   1. Create a virtual environment: python3.x -m venv [venv-projname]"
    echo "   2. Activate it: source [venv-projname]/bin/activate"
    echo "   3. Then use pip normally"
    echo ""
    echo "This prevents accidental system-wide package installations."
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo ""
        echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
    fi

    return 1
}

# Pip3 wrapper - allows override only in build mode
pip3() {
    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1 || \
       ! typeset -f _in_virtual_env >/dev/null 2>&1; then
        command pip3 "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        command pip3 "$@"
        return $?
    fi

    if ! _py_manager_available; then
        command pip3 "$@"
        return $?
    fi

    if _in_virtual_env; then
        if [[ -x "$VIRTUAL_ENV/bin/pip3" ]]; then
            "$VIRTUAL_ENV/bin/pip3" "$@"
        else
            command pip3 "$@"
        fi
        return $?
    fi

    # Build mode: allow pip3 with the override Python
    if [[ $_PYTHON_BUILD_MODE -eq 1 ]] && [[ -n "$_PYTHON_OVERRIDE" ]]; then
        _scan_all_pythons
        local python_path="${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
        if [[ -n "$python_path" ]]; then
            echo "[build mode] Running pip3 with Python ${_PYTHON_OVERRIDE}..." >&2
            "$python_path" -m pip "$@"
            return $?
        fi
    fi

    echo "Error: pip3 is not available outside virtual environments"
    echo ""
    echo "To use pip:"
    echo "   1. Create a virtual environment: python3.x -m venv [venv-projname]"
    echo "   2. Activate it: source [venv-projname]/bin/activate"
    echo "   3. Then use pip normally"
    echo ""
    echo "This prevents accidental system-wide package installations."
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo ""
        echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
    fi

    return 1
}

# Set temporary Python default with AI tool support
setpy() {
    if ! _py_manager_available; then
        echo "Warning: Python manager helpers unavailable; cannot change override"
        return 1
    fi

    local version=""
    local build_mode=0

    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                _scan_all_pythons
                local example_ver="${_PYTHON_VERSIONS[-1]:-3.x}"
                echo "Usage: setpy <version> [--build]    Set temporary Python default"
                echo "       setpy clear                  Clear the override"
                echo "       setpy                        Show current status"
                echo ""
                echo "Options:"
                echo "   --build    Also allow pip outside venv (for building modules)"
                echo ""
                echo "Examples:"
                echo "   setpy ${example_ver}             # Set python/python3 to use Python ${example_ver}"
                echo "   setpy ${example_ver} --build     # Same, but also allow pip (for builds)"
                echo "   setpy python${example_ver}       # Also accepts 'python' prefix"
                echo "   setpy clear            # Remove the override and build mode"
                echo ""
                echo "Available versions:"
                for ver in $_PYTHON_VERSIONS; do
                    echo "   ${ver}"
                done
                echo ""
                echo "This sets a temporary default so 'python' and 'python3' work without a venv."
                echo "Also creates ~/.local/bin/python symlink for AI tool compatibility."
                echo ""
                echo "Build mode (--build):"
                echo "   Temporarily allows pip/pip3 outside virtual environments."
                echo "   Use for building modules that require pip install."
                echo "   WARNING: Can pollute system packages - use sparingly!"
                return 0
                ;;
            --build)
                build_mode=1
                ;;
            clear|reset)
                version="clear"
                ;;
            *)
                # It's a version number
                if [[ -z "$version" ]]; then
                    version="$arg"
                fi
                ;;
        esac
    done

    # Handle clear/reset
    if [[ "$version" == "clear" ]]; then
        local had_override=0
        local had_build_mode=0
        
        [[ -n "$_PYTHON_OVERRIDE" ]] && had_override=1
        [[ $_PYTHON_BUILD_MODE -eq 1 ]] && had_build_mode=1
        
        if [[ $had_override -eq 1 ]] || [[ $had_build_mode -eq 1 ]]; then
            if [[ $had_override -eq 1 ]]; then
                echo "Cleared Python override (was ${_PYTHON_OVERRIDE})."
                _PYTHON_OVERRIDE=""
                unset PYTHON PYTHON3
            fi
            
            if [[ $had_build_mode -eq 1 ]]; then
                echo "Cleared build mode (pip is now blocked outside venvs)."
                _PYTHON_BUILD_MODE=0
                unset PIP_REQUIRE_VIRTUALENV
            fi

            # Ask about symlinks
            if [[ $_PYTHON_SYMLINK_MANAGED -eq 1 ]]; then
                echo ""
                echo -n "Remove ~/.local/bin/python symlinks? [y/N] "
                read -r response
                if [[ "$response" =~ ^[Yy]$ ]]; then
                    rm -f "$_PYTHON_SYMLINK_DIR/python" "$_PYTHON_SYMLINK_DIR/python3" 2>/dev/null
                    _PYTHON_SYMLINK_MANAGED=0
                    echo "   Symlinks removed."
                else
                    echo "   Symlinks kept (pointing to previous version)."
                fi
            fi
        else
            echo "No Python override or build mode is set."
        fi
        return 0
    fi

    # No argument - show status and available versions
    if [[ -z "$version" ]]; then
        _scan_all_pythons
        if [[ -n "$_PYTHON_OVERRIDE" ]] || [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
            if [[ -n "$_PYTHON_OVERRIDE" ]]; then
                echo "Current override: Python ${_PYTHON_OVERRIDE}"
                echo "   Binary: ${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
            fi
            if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
                echo "Build mode: ENABLED (pip allowed outside venv)"
            fi
            echo ""
            echo "To clear: setpy clear"
        else
            echo "No Python override is set."
            echo ""
            echo "Usage: setpy <version> [--build]"
            echo ""
            echo "Available versions:"
            for ver in $_PYTHON_VERSIONS; do
                echo "   setpy ${ver}"
            done
            echo ""
            echo "Run 'setpy --help' for more info."
        fi
        return 0
    fi

    # Strip "python" prefix if provided (accept both "3.12" and "python3.12")
    if [[ "$version" =~ ^python([0-9]+\.[0-9]+)$ ]]; then
        version="${match[1]}"
    elif [[ "$version" =~ ^py([0-9]+\.[0-9]+)$ ]]; then
        version="${match[1]}"
    fi

    # Force re-scan to get fresh paths (avoid stale symlinks)
    _PYTHONS_SCANNED=0
    _scan_all_pythons

    # Validate version exists
    if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
        echo "Error: Python ${version} not found on this system"
        echo ""
        echo "Available versions:"
        for ver in $_PYTHON_VERSIONS; do
            echo "  - ${ver}"
        done
        return 1
    fi

    local python_path="${_PYTHON_PATHS[$version]}"

    # Set shell override
    _PYTHON_OVERRIDE="$version"

    # Export for subprocesses (AI tools)
    export PYTHON="$python_path"
    export PYTHON3="$python_path"

    # Handle build mode
    if [[ $build_mode -eq 1 ]]; then
        _PYTHON_BUILD_MODE=1
        # This env var tells pip it's okay to run outside venv (for subprocesses)
        export PIP_REQUIRE_VIRTUALENV=0
    fi

    # Manage symlinks for AI tool PATH compatibility
    _setup_python_symlinks "$python_path"

    echo "Set temporary Python default to ${version}."
    echo ""
    echo "Binary: $python_path"
    echo ""
    echo "AI tool compatibility:"
    echo "   PYTHON=$PYTHON"
    echo "   ~/.local/bin/python -> $python_path"
    
    if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
        echo ""
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│  BUILD MODE ENABLED - pip/pip3 allowed outside venv        │"
        echo "│  WARNING: This can install packages system-wide!           │"
        echo "│  Run 'setpy clear' when done building.                     │"
        echo "└─────────────────────────────────────────────────────────────┘"
    else
        echo ""
        echo "Note: pip remains blocked outside venvs. Use --build to allow."
    fi
    echo ""
    echo "To clear: setpy clear"

    # Warn if in venv
    if _in_virtual_env; then
        echo ""
        echo "Warning: You're in a virtual environment, which takes precedence."
    fi

    # Check PATH
    if [[ ":$PATH:" != *":$_PYTHON_SYMLINK_DIR:"* ]]; then
        echo ""
        echo "Warning: $_PYTHON_SYMLINK_DIR is not in your PATH!"
        echo "   Add to ~/.zshrc: export PATH=\"$_PYTHON_SYMLINK_DIR:\$PATH\""
    fi
}

# Helper to manage symlinks for AI tool compatibility
_setup_python_symlinks() {
    local python_path="$1"

    # Verify target exists
    if [[ ! -x "$python_path" ]]; then
        echo "Error: Target binary does not exist: $python_path"
        return 1
    fi

    # Ensure directory exists
    if [[ ! -d "$_PYTHON_SYMLINK_DIR" ]]; then
        mkdir -p "$_PYTHON_SYMLINK_DIR"
    fi

    # Create/update symlinks
    ln -sf "$python_path" "$_PYTHON_SYMLINK_DIR/python"
    ln -sf "$python_path" "$_PYTHON_SYMLINK_DIR/python3"

    _PYTHON_SYMLINK_MANAGED=1
}

# Validate that the override Python still exists
_validate_python_override() {
    if [[ -z "$_PYTHON_OVERRIDE" ]]; then
        return 0  # No override set
    fi

    # Re-scan to get current state
    _PYTHONS_SCANNED=0
    _scan_all_pythons

    local override_path="${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"

    if [[ -z "$override_path" ]] || [[ ! -x "$override_path" ]]; then
        echo "Error: Python ${_PYTHON_OVERRIDE} is no longer available."
        echo ""
        echo "The previously set version may have been uninstalled."
        echo ""

        if (( ${#_PYTHON_VERSIONS} > 0 )); then
            echo "Available Python versions:"
            for ver in $_PYTHON_VERSIONS; do
                echo "  - ${ver} -> ${_PYTHON_PATHS[$ver]}"
            done
            echo ""
            echo "To fix:"
            echo "  1. setpy clear     (remove stale override)"
            echo "  2. setpy <version> (set a new version)"
        else
            echo "No Python installations found."
            echo "Run: setpy clear"
        fi

        return 1
    fi

    return 0
}

# Python version-specific wrapper function
_python_version_wrapper() {
    local version="$1"
    shift

    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1; then
        # Functions not loaded, just use system python
        command "python${version}" "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        if _py_manager_available; then
            _scan_all_pythons
            if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                "${_PYTHON_PATHS[$version]}" "$@"
                return $?
            fi
        fi
        command "python${version}" "$@"
        return $?
    fi

    if ! _py_manager_available; then
        command "python${version}" "$@"
        return $?
    fi
    
    # If in venv, be more permissive
    if _in_virtual_env; then
        # First, check if the requested python executable exists in the venv
        if [[ -x "$VIRTUAL_ENV/bin/python${version}" ]]; then
            # It exists! Just use it directly
            "$VIRTUAL_ENV/bin/python${version}" "$@"
            return $?
        fi
        
        # If not found, check if this matches the venv's major.minor version
        local venv_version=$(_get_venv_python_version)
        
        # Extract just major.minor from the full version if needed
        if [[ "$venv_version" =~ ^([0-9]+\.[0-9]+) ]]; then
            venv_version="${match[1]}"
        fi
        
        if [[ "$version" == "$venv_version" ]]; then
            # Fall back to the venv's python
            if [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
                "$VIRTUAL_ENV/bin/python" "$@"
                return $?
            fi
        else
            # Only block if it truly doesn't exist and isn't the venv's version
            echo "Error: python${version} is not available in this virtual environment"
            echo ""
            echo "This virtual environment uses Python ${venv_version}"
            echo "   Available: python, python3, python${venv_version}"
            echo ""
            echo "To use a different Python version, deactivate first with: deactivate"
            return 1
        fi
    fi

    # Outside venv: ensure we have scanned for pythons
    _scan_all_pythons

    # Check if trying to use pip module (blocked unless build mode)
    if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
        if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
            # Build mode: allow python3.X -m pip
            if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                echo "[build mode] Running python${version} -m pip..." >&2
                "${_PYTHON_PATHS[$version]}" "$@"
                return $?
            fi
        else
            echo "Error: python${version} -m pip is blocked outside virtual environments"
            echo ""
            echo "To use pip:"
            echo "   1. Create a virtual environment: python${version} -m venv [venv-projname]"
            echo "   2. Activate it: source [venv-projname]/bin/activate"
            echo "   3. Then use pip normally"
            echo ""
            echo "This prevents accidental system-wide package installations."
            echo "Tip: Use 'setpy ${version} --build' to temporarily allow pip."
            return 1
        fi
    fi

    # Check if this version exists
    if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
        echo "Error: python${version} not found on this system"
        return 1
    fi
    
    # Allow all other python usage
    "${_PYTHON_PATHS[$version]}" "$@"
}

# Pip version-specific wrapper
_pip_version_wrapper() {
    local version="$1"
    shift

    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1; then
        # Functions not loaded, just use system pip
        command "pip${version}" "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        if _py_manager_available; then
            _scan_all_pythons
            if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                local pip_path="${_PYTHON_PATHS[$version]%/*}/pip${version}"
                if [[ -x "$pip_path" ]]; then
                    "$pip_path" "$@"
                    return $?
                fi
            fi
        fi
        command "pip${version}" "$@"
        return $?
    fi

    if ! _py_manager_available; then
        command "pip${version}" "$@"
        return $?
    fi
    
    # If in venv, be more permissive
    if _in_virtual_env; then
        # First check if the requested pip executable exists in the venv
        if [[ -x "$VIRTUAL_ENV/bin/pip${version}" ]]; then
            # It exists! Just use it directly
            "$VIRTUAL_ENV/bin/pip${version}" "$@"
            return $?
        fi
        
        # If not found, check if this matches the venv's major.minor version
        local venv_version=$(_get_venv_python_version)
        
        # Extract just major.minor from the full version if needed
        if [[ "$venv_version" =~ ^([0-9]+\.[0-9]+) ]]; then
            venv_version="${match[1]}"
        fi
        
        if [[ "$version" == "$venv_version" ]]; then
            # Fall back to the venv's pip
            if [[ -x "$VIRTUAL_ENV/bin/pip" ]]; then
                "$VIRTUAL_ENV/bin/pip" "$@"
                return $?
            fi
        else
            echo "Error: pip${version} is not available in this virtual environment"
            echo ""
            echo "This virtual environment uses Python ${venv_version}"
            echo "   Available: pip, pip3, pip${venv_version}"
            echo ""
            echo "To use a different Python version, deactivate first with: deactivate"
            return 1
        fi
    fi

    # Build mode: allow pip with the specified version
    if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
            echo "[build mode] Running pip${version} with Python ${version}..." >&2
            "${_PYTHON_PATHS[$version]}" -m pip "$@"
            return $?
        fi
    fi

    # Outside venv: block
    echo "Error: pip${version} is not available outside virtual environments"
    echo ""
    echo "To use pip:"
    echo "   1. Create a virtual environment: python${version} -m venv [venv-projname]"
    echo "   2. Activate it: source [venv-projname]/bin/activate"
    echo "   3. Then use pip normally"
    echo ""
    echo "This prevents accidental system-wide package installations."
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo ""
        echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
    fi
    return 1
}

# Create version functions for a wide range (covers current and future Python versions)
# Note: The wrapper functions handle non-existent versions gracefully with helpful error messages
# This range (3.8-3.25) should cover Python releases for many years to come
for major in 3; do
    for minor in {8..25}; do
        local ver="${major}.${minor}"
        # Validate version format to prevent code injection via eval
        if [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
            eval "
python${ver}() {
    if typeset -f _python_version_wrapper >/dev/null 2>&1; then
        _python_version_wrapper '${ver}' \"\$@\"
    else
        command python${ver} \"\$@\"
    fi
}
"
            eval "
py${ver}() {
    if typeset -f _python_version_wrapper >/dev/null 2>&1; then
        _python_version_wrapper '${ver}' \"\$@\"
    else
        command python${ver} \"\$@\"
    fi
}
"
            eval "
pip${ver}() {
    if typeset -f _pip_version_wrapper >/dev/null 2>&1; then
        _pip_version_wrapper '${ver}' \"\$@\"
    else
        command pip${ver} \"\$@\"
    fi
}
"
        fi
    done
done

# Diagnostic command for debugging sandboxing issues
pydiag() {
    echo "Python Manager Diagnostics:"
    echo ""
    echo "Environment Variables:"
    echo "  PYTHON_MANAGER_FORCE_BYPASS=${PYTHON_MANAGER_FORCE_BYPASS:-<not set>}"
    echo "  CI=${CI:-<not set>}"
    echo "  CODEX_SANDBOX_NETWORK_DISABLED=${CODEX_SANDBOX_NETWORK_DISABLED:-<not set>}"
    echo "  VIRTUAL_ENV=${VIRTUAL_ENV:-<not set>}"
    echo "  SHLVL=$SHLVL"
    echo ""
    echo "Shell Properties:"
    echo "  Interactive: $([[ -o interactive ]] && echo 'yes' || echo 'no')"
    echo "  Login shell: $([[ -o login ]] && echo 'yes' || echo 'no')"
    echo ""
    echo "Function Availability:"
    echo "  _py_manager_available: $(typeset -f _py_manager_available >/dev/null 2>&1 && echo 'loaded' || echo 'missing')"
    echo "  _py_manager_should_bypass: $(typeset -f _py_manager_should_bypass >/dev/null 2>&1 && echo 'loaded' || echo 'missing')"
    echo "  _in_virtual_env: $(typeset -f _in_virtual_env >/dev/null 2>&1 && echo 'loaded' || echo 'missing')"
    echo "  _scan_all_pythons: $(typeset -f _scan_all_pythons >/dev/null 2>&1 && echo 'loaded' || echo 'missing')"
    echo ""
    echo "Manager State:"
    echo "  _PYTHON_MANAGER_READY=${_PYTHON_MANAGER_READY:-0}"
    echo "  _PYTHONS_SCANNED=${_PYTHONS_SCANNED:-0}"
    echo "  _PYTHON_OVERRIDE=${_PYTHON_OVERRIDE:-<not set>}"
    echo "  _PYTHON_BUILD_MODE=${_PYTHON_BUILD_MODE:-0}"
    echo ""

    if typeset -f _py_manager_should_bypass >/dev/null 2>&1; then
        if _py_manager_should_bypass; then
            echo "Bypass Mode: ACTIVE (will use system commands)"
        else
            echo "Bypass Mode: INACTIVE (will use wrapper logic)"
        fi
    else
        echo "Bypass Mode: Cannot determine (function not loaded)"
    fi
    echo ""

    if typeset -f _in_virtual_env >/dev/null 2>&1; then
        if _in_virtual_env; then
            echo "Virtual Environment: DETECTED"
        else
            echo "Virtual Environment: NOT DETECTED"
        fi
    else
        echo "Virtual Environment: Cannot determine (function not loaded)"
    fi
    echo ""

    if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
        echo "Build Mode: ENABLED (pip allowed outside venv)"
    else
        echo "Build Mode: DISABLED (pip blocked outside venv)"
    fi
    echo ""

    echo "Python Commands Available:"
    echo "  python: $(type -p python 2>/dev/null || echo '<function/not found>')"
    echo "  python3: $(type -p python3 2>/dev/null || echo '<function/not found>')"
    echo "  pip: $(type -p pip 2>/dev/null || echo '<function/not found>')"
    echo ""
    echo "  Use 'pywhich python' to see what binary would actually run."
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Subprocess/AI Tool Compatibility (Codex CLI, Claude Code, etc.):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Exported Environment Variables (inherited by subprocesses):"
    echo "  PYTHON=${PYTHON:-<not set>}"
    echo "  PYTHON3=${PYTHON3:-<not set>}"
    echo "  PIP_REQUIRE_VIRTUALENV=${PIP_REQUIRE_VIRTUALENV:-<not set>}"
    echo ""
    
    echo "Symlinks (for PATH-based discovery):"
    if [[ -L "$_PYTHON_SYMLINK_DIR/python" ]]; then
        echo "  $_PYTHON_SYMLINK_DIR/python -> $(readlink "$_PYTHON_SYMLINK_DIR/python")"
    else
        echo "  $_PYTHON_SYMLINK_DIR/python: NOT CREATED"
    fi
    if [[ -L "$_PYTHON_SYMLINK_DIR/python3" ]]; then
        echo "  $_PYTHON_SYMLINK_DIR/python3 -> $(readlink "$_PYTHON_SYMLINK_DIR/python3")"
    else
        echo "  $_PYTHON_SYMLINK_DIR/python3: NOT CREATED"
    fi
    echo ""
    
    echo "PATH check for $_PYTHON_SYMLINK_DIR:"
    if [[ ":$PATH:" == *":$_PYTHON_SYMLINK_DIR:"* ]]; then
        echo "  ✓ $_PYTHON_SYMLINK_DIR is in PATH"
    else
        echo "  ✗ $_PYTHON_SYMLINK_DIR is NOT in PATH"
        echo "    Add to ~/.zshrc: export PATH=\"$_PYTHON_SYMLINK_DIR:\$PATH\""
    fi
    echo ""

    echo "What subprocesses will see:"
    echo "  'python' command: $(command -v python 2>/dev/null || echo 'not found')"
    echo "  'python3' command: $(command -v python3 2>/dev/null || echo 'not found')"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Troubleshooting:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "If Codex CLI/Claude Code can't find Python:"
    echo "   1. Run: setpy <version>  (creates symlinks + exports env vars)"
    echo "   2. Ensure ~/.local/bin is first in PATH"
    echo ""
    echo "If in a sandboxed environment and seeing errors:"
    echo "   1. Set: export PYTHON_MANAGER_FORCE_BYPASS=1"
    echo "   2. Or reload your shell configuration"
    echo "   3. The script should auto-detect sandboxing and bypass safely"
}

# Enhanced pyinfo function
pyinfo() {
    if ! _py_manager_available; then
        echo "Warning: Python manager helpers unavailable; pyinfo cannot run"
        return 1
    fi

    echo "Python Environment Status:"
    echo ""
    
    # Show override if set
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo "Temporary Python Override Active: ${_PYTHON_OVERRIDE}"
        echo "   'python' and 'python3' -> python${_PYTHON_OVERRIDE}"
        echo "   (use 'setpy clear' to remove)"
        echo ""
    fi

    # Check virtual environment status
    if _in_virtual_env; then
        echo "Virtual Environment Active"
        echo ""
        
        local venv_version=$(_get_venv_python_version)
        
        if [[ -n "$VIRTUAL_ENV" ]]; then
            echo "  Type: venv/virtualenv"
            echo "  Path: $VIRTUAL_ENV"
            echo "  Python version: ${venv_version:-unknown}"
        elif [[ -n "$CONDA_DEFAULT_ENV" ]]; then
            echo "  Type: conda"
            echo "  Name: $CONDA_DEFAULT_ENV"
            echo "  Python version: ${venv_version:-unknown}"
        elif [[ -n "$POETRY_ACTIVE" ]]; then
            echo "  Type: poetry"
        elif [[ -n "$PIPENV_ACTIVE" ]]; then
            echo "  Type: pipenv"
        fi
        
        echo ""
        echo "  Available commands in this venv:"
        echo "    python     -> $(pywhich python 2>/dev/null)"
        echo "    python3    -> $(pywhich python3 2>/dev/null)"
        if [[ -n "$venv_version" ]]; then
            echo "    python${venv_version} -> $(pywhich python${venv_version} 2>/dev/null)"
        fi
        echo "    pip        -> $(pywhich pip 2>/dev/null)"
        echo "    pip3       -> $(pywhich pip3 2>/dev/null)"
        if [[ -n "$venv_version" ]]; then
            echo "    pip${venv_version}    -> $(pywhich pip${venv_version} 2>/dev/null)"
        fi
        echo ""
        echo "  Note: Other Python versions are blocked while venv is active."
        echo ""
        echo "────────────────────────────────"
        echo ""
    else
        echo "No Virtual Environment Active"
        echo ""
    fi
    
    _scan_all_pythons
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "No Python 3.x found on system"
    else
        echo "System Python Versions:"
        for ver in $_PYTHON_VERSIONS; do
            echo ""
            echo "  Python $ver:"
            echo "    Path: ${_PYTHON_PATHS[$ver]}"
            echo "    Info: ${_PYTHON_INFO[$ver]}"
            echo "    Usage: python${ver} -m venv <venv-name>"
            if [[ "$ver" == "$_PYTHON_OVERRIDE" ]]; then
                echo "    Status: * Currently set as override"
            fi
        done
        echo ""
        echo "Note: pip is blocked for all system Python versions."
        echo "Always use virtual environments for package management."
    fi
}
# pywhich - Show actual binary paths for python/pip commands
# Usage: pywhich python3.X [pip3.X ...]
pywhich() {
    if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        _scan_all_pythons
        local example_ver="${_PYTHON_VERSIONS[-1]:-3.x}"
        local example_ver2="${_PYTHON_VERSIONS[1]:-3.x}"
        echo "Usage: pywhich <command> [command ...]"
        echo ""
        echo "Shows the actual binary path that would be executed for python/pip commands."
        echo "Unlike 'which', this resolves through the Python manager's logic."
        echo ""
        echo "Examples:"
        echo "   pywhich python${example_ver}     # → /path/to/python${example_ver}"
        echo "   pywhich python         # → shows override or venv python"
        echo "   pywhich pip            # → (blocked outside venv)"
        echo "   pywhich python${example_ver2} pip  # check multiple commands"
        echo ""
        echo "Related commands:"
        echo "   which <cmd>            Enhanced which (uses pywhich for python/pip)"
        echo "   pyinfo                 Show all Python versions and status"
        echo "   setpy <version>        Set temporary Python default"
        return 0
    fi

    if ! _py_manager_available; then
        echo "Warning: Python manager not fully loaded"
        return 1
    fi

    _scan_all_pythons
    local had_error=0

    for cmd in "$@"; do
        local result=""

        case "$cmd" in
            python|python3)
                # Check venv first
                if _in_virtual_env && [[ -x "$VIRTUAL_ENV/bin/$cmd" ]]; then
                    result="$VIRTUAL_ENV/bin/$cmd"
                # Check override
                elif [[ -n "$_PYTHON_OVERRIDE" ]] && [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
                    result="${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
                else
                    result="(blocked - use explicit version or setpy)"
                    had_error=1
                fi
                ;;
            python[0-9].[0-9]*|py[0-9].[0-9]*)
                local version=""
                if [[ "$cmd" =~ ^python([0-9]+\.[0-9]+)$ ]]; then
                    version="${match[1]}"
                elif [[ "$cmd" =~ ^py([0-9]+\.[0-9]+)$ ]]; then
                    version="${match[1]}"
                fi

                if [[ -n "$version" ]]; then
                    # Check venv first
                    if _in_virtual_env; then
                        local venv_version=$(_get_venv_python_version)
                        if [[ "$version" == "$venv_version" ]] && [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
                            result="$VIRTUAL_ENV/bin/python"
                        elif [[ -x "$VIRTUAL_ENV/bin/python${version}" ]]; then
                            result="$VIRTUAL_ENV/bin/python${version}"
                        else
                            result="(not available in venv - venv uses Python $venv_version)"
                            had_error=1
                        fi
                    elif [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                        result="${_PYTHON_PATHS[$version]}"
                    else
                        result="(not found)"
                        had_error=1
                    fi
                fi
                ;;
            pip|pip3)
                if _in_virtual_env && [[ -x "$VIRTUAL_ENV/bin/$cmd" ]]; then
                    result="$VIRTUAL_ENV/bin/$cmd"
                else
                    result="(blocked outside venv)"
                    had_error=1
                fi
                ;;
            pip[0-9].[0-9]*)
                local version=""
                if [[ "$cmd" =~ ^pip([0-9]+\.[0-9]+)$ ]]; then
                    version="${match[1]}"
                fi

                if [[ -n "$version" ]] && _in_virtual_env; then
                    local venv_version=$(_get_venv_python_version)
                    if [[ "$version" == "$venv_version" ]] && [[ -x "$VIRTUAL_ENV/bin/pip" ]]; then
                        result="$VIRTUAL_ENV/bin/pip"
                    elif [[ -x "$VIRTUAL_ENV/bin/pip${version}" ]]; then
                        result="$VIRTUAL_ENV/bin/pip${version}"
                    else
                        result="(not available in venv)"
                        had_error=1
                    fi
                else
                    result="(blocked outside venv)"
                    had_error=1
                fi
                ;;
            *)
                # Not a python/pip command, use real which
                result=$(command which "$cmd" 2>/dev/null)
                if [[ -z "$result" ]]; then
                    result="(not found)"
                    had_error=1
                fi
                ;;
        esac

        if [[ $# -eq 1 ]]; then
            echo "$result"
        else
            echo "$cmd: $result"
        fi
    done

    return $had_error
}

# which - wrapper that uses pywhich for python/pip commands
# Passes through to real which for everything else
which() {
    # Help option
    if [[ "$1" == "--pyhelp" ]]; then
        _scan_all_pythons
        local example_ver="${_PYTHON_VERSIONS[-1]:-3.x}"
        echo "which - enhanced with Python version manager support"
        echo ""
        echo "For python/pip commands, shows the actual binary path:"
        echo "   which python${example_ver}  → /path/to/python${example_ver}"
        echo "   which pip         → (blocked outside venv)"
        echo ""
        echo "For other commands, uses standard 'which' behavior."
        echo ""
        echo "Related commands:"
        echo "   pywhich <cmd>     Show path for python/pip commands"
        echo "   pyinfo            Show all Python versions and status"
        echo "   setpy <version>   Set temporary Python default"
        echo "   pydiag            Debug Python manager issues"
        return 0
    fi

    # If any options are passed (-a, -s, etc.), use real which
    if [[ "$1" == -* ]]; then
        command which "$@"
        return $?
    fi

    # Single argument - check if it's a python/pip command we manage
    if [[ $# -eq 1 ]]; then
        local cmd="$1"
        
        # Exact matches for base commands
        if [[ "$cmd" == "python" || "$cmd" == "python3" || \
              "$cmd" == "pip" || "$cmd" == "pip3" ]]; then
            pywhich "$cmd"
            return $?
        fi
        
        # Version-specific: python3.X, py3.X, pip3.X patterns
        if [[ "$cmd" =~ ^(python|py|pip)[0-9]+\.[0-9]+$ ]]; then
            pywhich "$cmd"
            return $?
        fi
    fi

    # Multiple args or non-python command - use real which
    command which "$@"
}

(( _PYTHON_MANAGER_READY = 1 ))
