#!/usr/bin/env bash
# Shared setup for LucasCad on macOS and Linux.
#
# Sourced by start-cad.sh and run-tests.sh. Written for bash 3.2 because that is
# what macOS still ships: no associative arrays, no mapfile, no ${var^^}.

set -euo pipefail

PROJECT_ROOT=${PROJECT_ROOT:-}
if [ -z "$PROJECT_ROOT" ]; then
    echo "bootstrap.sh: PROJECT_ROOT must be set before sourcing" >&2
    exit 1
fi

VENV_DIR="$PROJECT_ROOT/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"
TOOLING_DIR="$PROJECT_ROOT/.tooling"
STAMP_DIR="$PROJECT_ROOT/.tooling/stamps"

# shellcheck disable=SC2034  # consumed by the scripts that source this file
WEB_PORT=${LUCASCAD_WEB_PORT:-4310}
# shellcheck disable=SC2034
API_PORT=${LUCASCAD_API_PORT:-4311}

# cadquery 2.8 declares Requires-Python >=3.11, and cadquery-ocp caps at <3.15.
# macOS ships 3.9 as /usr/bin/python3, so an explicit search matters here.
PYTHON_CANDIDATES="python3.13 python3.12 python3.11 python3 python"
MIN_NODE_MAJOR=22
MIN_NODE_MINOR=13

say()  { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

os_name() {
    case "$(uname -s)" in
        Darwin) echo macos ;;
        Linux)  echo linux ;;
        *)      echo other ;;
    esac
}

# ---------------------------------------------------------------- python -----

python_is_supported() {
    # Usable when 3.11 <= version < 3.15.
    "$1" -c 'import sys; sys.exit(0 if (3, 11) <= sys.version_info < (3, 15) else 1)' \
        >/dev/null 2>&1
}

find_python() {
    if [ -n "${LUCASCAD_PYTHON:-}" ]; then
        python_is_supported "$LUCASCAD_PYTHON" \
            || die "LUCASCAD_PYTHON=$LUCASCAD_PYTHON is not a Python 3.11-3.14 interpreter."
        echo "$LUCASCAD_PYTHON"
        return 0
    fi
    for candidate in $PYTHON_CANDIDATES; do
        resolved=$(command -v "$candidate" 2>/dev/null) || continue
        if python_is_supported "$resolved"; then
            echo "$resolved"
            return 0
        fi
    done
    return 1
}

python_install_hint() {
    if [ "$(os_name)" = macos ]; then
        cat >&2 <<'EOF'
LucasCad needs Python 3.11-3.14 (CadQuery 2.8 requires >= 3.11).
macOS ships Python 3.9 at /usr/bin/python3, which is too old.

Install a supported version, then re-run this script:

    brew install python@3.12

No Homebrew? Get it from https://brew.sh, or install Python from
https://www.python.org/downloads/macos/
EOF
    else
        cat >&2 <<'EOF'
LucasCad needs Python 3.11-3.14 (CadQuery 2.8 requires >= 3.11).

Debian / Ubuntu:
    sudo apt-get update && sudo apt-get install -y python3.12 python3.12-venv

Fedora / RHEL:
    sudo dnf install -y python3.12

Then re-run this script.
EOF
    fi
}

ensure_venv() {
    local python_bin requirements stamp lock
    requirements=${1:-"$PROJECT_ROOT/backend/requirements.txt"}

    if [ ! -x "$VENV_PYTHON" ]; then
        python_bin=$(find_python) || { python_install_hint; die "no supported Python interpreter found"; }
        say "Creating virtualenv with $python_bin ($("$python_bin" -V 2>&1))"
        "$python_bin" -m venv "$VENV_DIR" \
            || die "could not create $VENV_DIR (on Debian/Ubuntu you may need: sudo apt-get install python3-venv)"
    elif ! python_is_supported "$VENV_PYTHON"; then
        warn "$VENV_DIR uses an unsupported Python; rebuilding it"
        rm -rf "$VENV_DIR"
        ensure_venv "$requirements"
        return
    fi

    mkdir -p "$STAMP_DIR"
    stamp="$STAMP_DIR/python-$(basename "$requirements")"
    lock=$(checksum "$requirements")
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$lock" ]; then
        return 0
    fi

    say "Installing Python dependencies from $(basename "$requirements") (first run downloads ~400 MB of Open CASCADE)"
    "$VENV_PYTHON" -m pip install --quiet --upgrade pip \
        || die "pip self-upgrade failed"
    "$VENV_PYTHON" -m pip install --quiet -r "$requirements" \
        || die "installing $requirements failed"
    verify_occ
    printf '%s' "$lock" > "$stamp"
}

verify_occ() {
    # OCP pulls in VTK, which links against libGL. Minimal Linux images and
    # containers often lack it, and the resulting ImportError is inscrutable.
    #
    # Check for a printed marker rather than the exit status: Open CASCADE can
    # crash the interpreter during shutdown after a perfectly good import, so a
    # non-zero exit code does not mean the kernel is broken.
    local detail
    detail=$("$VENV_PYTHON" -c "import cadquery; print('LUCASCAD_KERNEL_OK')" 2>&1 || true)
    case "$detail" in
        *LUCASCAD_KERNEL_OK*) return 0 ;;
    esac
    detail=$(printf '%s\n' "$detail" | tail -3)
    if printf '%s' "$detail" | grep -qi 'libGL\|libEGL\|libX11\|libSM\|libICE\|GLdispatch'; then
        cat >&2 <<EOF

CadQuery imported OpenGL system libraries that are missing on this machine:

$detail

Debian / Ubuntu:
    sudo apt-get install -y libgl1 libglx-mesa0 libxrender1 libxext6 libsm6 libice6

Fedora / RHEL:
    sudo dnf install -y mesa-libGL libXrender libXext libSM libICE

LucasCad renders in your browser, so these are only needed to load the
geometry kernel; no display or GPU is required.
EOF
        die "CadQuery could not be imported"
    fi
    printf '%s\n' "$detail" >&2
    die "CadQuery could not be imported"
}

# ------------------------------------------------------------------ node -----

node_version_ok() {
    "$1" -e "
const [maj, min] = process.versions.node.split('.').map(Number);
process.exit(maj > $MIN_NODE_MAJOR || (maj === $MIN_NODE_MAJOR && min >= $MIN_NODE_MINOR) ? 0 : 1);
" >/dev/null 2>&1
}

node_install_hint() {
    local found
    found=$(command -v node >/dev/null 2>&1 && node --version || echo "not installed")
    cat >&2 <<EOF
LucasCad needs Node >= $MIN_NODE_MAJOR.$MIN_NODE_MINOR.0 (package.json "engines"); found: $found

Install with nvm (works the same on macOS and Linux):
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    exec \$SHELL -l
    nvm install 22

Or with a package manager:
    macOS:          brew install node@22
    Debian/Ubuntu:  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs
EOF
}

ensure_node() {
    command -v node >/dev/null 2>&1 || { node_install_hint; die "node not found"; }
    node_version_ok "$(command -v node)" || { node_install_hint; die "node is too old"; }
}

# ------------------------------------------------------------------ pnpm -----

pinned_pnpm_version() {
    # "packageManager": "pnpm@10.34.5" -> 10.34.5
    node -e 'const s=require("'"$PROJECT_ROOT"'/package.json").packageManager||"";
             process.stdout.write(s.startsWith("pnpm@") ? s.slice(5).split("+")[0] : "")'
}

# Resolve the pnpm pinned in package.json. pnpm reads lockfiles and the
# build-script allowlist differently across majors -- pnpm 12 rejects this
# lockfile's `onlyBuiltDependencies` outright -- so an arbitrary pnpm on PATH is
# not interchangeable. A matching major on PATH is reused; otherwise the pinned
# version is installed under .tooling. `npm install -g` is deliberately avoided
# because it fails with EACCES on the default macOS Node prefix.
ensure_pnpm() {
    if [ -z "${PNPM:-}" ] || [ ! -x "${PNPM:-}" ]; then
        resolve_pnpm
    fi
    publish_pnpm_on_path
}

resolve_pnpm() {
    local want want_major have local_pnpm
    want=$(pinned_pnpm_version)
    [ -n "$want" ] || die 'package.json is missing a "packageManager" pin for pnpm'
    want_major=${want%%.*}

    if command -v pnpm >/dev/null 2>&1; then
        have=$(pnpm --version 2>/dev/null || echo 0)
        if [ "${have%%.*}" = "$want_major" ]; then
            PNPM=$(command -v pnpm)
            return 0
        fi
        warn "pnpm $have is on PATH but this project is pinned to pnpm $want; using a private copy"
    fi

    local_pnpm="$TOOLING_DIR/pnpm-$want/node_modules/.bin/pnpm"
    if [ -x "$local_pnpm" ]; then
        PNPM="$local_pnpm"
        return 0
    fi

    # corepack ships with Node and honours the packageManager pin directly.
    if command -v corepack >/dev/null 2>&1 && corepack prepare "pnpm@$want" --activate >/dev/null 2>&1; then
        if command -v pnpm >/dev/null 2>&1 && [ "$(pnpm --version 2>/dev/null)" = "$want" ]; then
            PNPM=$(command -v pnpm)
            return 0
        fi
    fi

    say "Installing pnpm $want into .tooling (keeps the system Node prefix untouched)"
    mkdir -p "$TOOLING_DIR/pnpm-$want"
    npm install --silent --prefix "$TOOLING_DIR/pnpm-$want" "pnpm@$want" >/dev/null 2>&1 \
        || die "could not install pnpm $want; install it manually from https://pnpm.io/installation"
    [ -x "$local_pnpm" ] || die "pnpm install completed but $local_pnpm is missing"
    PNPM="$local_pnpm"
}

# The "test" script shells out to `pnpm run build`, and pnpm resolves that
# nested call through PATH. A pnpm that is pinned to a private .tooling copy is
# not on PATH, so make it discoverable before running anything that re-enters
# pnpm. Prepended so it also shadows a mismatched system pnpm.
publish_pnpm_on_path() {
    local dir
    dir=$(cd "$(dirname "$PNPM")" && pwd)
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) PATH="$dir:$PATH"; export PATH ;;
    esac
}

ensure_node_modules() {
    local stamp lock
    mkdir -p "$STAMP_DIR"
    stamp="$STAMP_DIR/pnpm-lock"
    lock=$(checksum "$PROJECT_ROOT/pnpm-lock.yaml")

    if [ -d "$PROJECT_ROOT/node_modules" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$lock" ]; then
        return 0
    fi

    say "Installing Node dependencies with pnpm"
    # CI=true stops pnpm from prompting for a TTY when it wants to purge
    # node_modules, which would otherwise hang a double-clicked launcher.
    ( cd "$PROJECT_ROOT" && CI=true "$PNPM" install ) || die "pnpm install failed"
    printf '%s' "$lock" > "$stamp"
}

# ----------------------------------------------------------------- utils -----

checksum() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        # Good enough to detect edits when no hashing tool exists.
        wc -c < "$1" | tr -d ' '
    fi
}

port_in_use() {
    "$VENV_PYTHON" - "$1" <<'PY'
import socket, sys
sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(0)   # in use
finally:
    sock.close()
sys.exit(1)       # free
PY
}

describe_port_user() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}'
    fi
}

require_free_port() {
    local port label owner
    port=$1
    label=$2
    if port_in_use "$port"; then
        owner=$(describe_port_user "$port")
        [ -n "$owner" ] && owner=" It is held by $owner." || owner=""
        die "port $port ($label) is already in use.${owner}
Stop that process, or pick another port:
    LUCASCAD_WEB_PORT=5310 LUCASCAD_API_PORT=5311 ./start-cad.sh"
    fi
}

# The web server binds IPv4 loopback, but "lucascad.localhost" does not resolve
# to IPv4 everywhere: glibc maps *.localhost to ::1 only, so on Linux the pretty
# hostname would be unreachable. Advertise it only where it actually resolves.
ui_host() {
    local name=$1
    if "$VENV_PYTHON" - "$name" <<'PY' 2>/dev/null
import socket, sys
try:
    sys.exit(0 if socket.getaddrinfo(sys.argv[1], None, socket.AF_INET) else 1)
except OSError:
    sys.exit(1)
PY
    then
        printf '%s' "$name"
    else
        printf '127.0.0.1'
    fi
}

open_browser() {
    local url=$1
    case "$(os_name)" in
        macos)
            open "$url" >/dev/null 2>&1 || true
            ;;
        linux)
            # No point launching a browser over SSH or on a headless box.
            if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
                return 0
            fi
            command -v xdg-open >/dev/null 2>&1 && (xdg-open "$url" >/dev/null 2>&1 &) || true
            ;;
    esac
}
