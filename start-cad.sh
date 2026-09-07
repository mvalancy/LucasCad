#!/usr/bin/env bash
# Start LucasCad on macOS or Linux.
#
#   ./start-cad.sh              set up if needed, then run
#   ./start-cad.sh --setup-only install dependencies and exit
#   ./start-cad.sh --no-open    do not open a browser
#
# Environment overrides: LUCASCAD_PYTHON, LUCASCAD_WEB_PORT, LUCASCAD_API_PORT.

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PROJECT_ROOT
# shellcheck source=scripts/bootstrap.sh
. "$PROJECT_ROOT/scripts/bootstrap.sh"

SETUP_ONLY=0
OPEN_BROWSER=1
for arg in "$@"; do
    case "$arg" in
        --setup-only) SETUP_ONLY=1 ;;
        --no-open)    OPEN_BROWSER=0 ;;
        -h|--help)    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "unknown option: $arg (try --help)" ;;
    esac
done

ensure_node
ensure_venv "$PROJECT_ROOT/backend/requirements.txt"
ensure_pnpm
ensure_node_modules

if [ "$SETUP_ONLY" -eq 1 ]; then
    say "Setup complete. Run ./start-cad.sh to launch LucasCad."
    exit 0
fi

require_free_port "$API_PORT" "geometry service"
require_free_port "$WEB_PORT" "web UI"

# Job control puts each background job in its own process group, so a whole
# server tree can be signalled at once. uvicorn --reload and vinext both spawn
# workers that would otherwise survive and keep the ports bound.
set -m

API_PID=""
WEB_PID=""

stop_tree() {
    local pid=$1
    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    # Give the server a moment to close listeners before forcing it down.
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
        sleep 0.25
        waited=$((waited + 1))
    done
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    trap - EXIT INT TERM
    stop_tree "$WEB_PID"
    stop_tree "$API_PID"
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

say "Starting geometry service on 127.0.0.1:$API_PORT"
(
    cd "$PROJECT_ROOT"
    exec "$VENV_PYTHON" -m uvicorn backend.server:app \
        --host 127.0.0.1 --port "$API_PORT" \
        --reload --reload-dir backend
) &
API_PID=$!

# Importing Open CASCADE takes several seconds on a cold filesystem cache, so
# poll the health endpoint instead of sleeping for a fixed interval.
say "Waiting for the geometry kernel to load"
if ! "$VENV_PYTHON" - "$API_PORT" "$API_PID" <<'PY'
import os, sys, time, urllib.error, urllib.request

port, api_pid = sys.argv[1], int(sys.argv[2])
deadline = time.time() + 90

while time.time() < deadline:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=2) as response:
            if response.status == 200:
                sys.exit(0)
    except (urllib.error.URLError, OSError):
        pass
    try:
        os.kill(api_pid, 0)
    except OSError:
        print("the geometry service exited during startup", file=sys.stderr)
        sys.exit(1)
    time.sleep(0.4)

print("timed out after 90s waiting for /api/health", file=sys.stderr)
sys.exit(1)
PY
then
    die "the geometry service did not come up; see the output above"
fi

URL="http://$(ui_host lucascad.localhost):$WEB_PORT/"
say "LucasCad is ready at $URL"
[ "$OPEN_BROWSER" -eq 1 ] && open_browser "$URL"

(
    cd "$PROJECT_ROOT"
    CI=true exec "$PNPM" exec vinext dev --hostname 127.0.0.1 --port "$WEB_PORT"
) &
WEB_PID=$!

# Exit as soon as either server stops and let the trap tear down the other.
# Polled rather than `wait -n`, which needs bash 4.3; macOS ships bash 3.2.
while kill -0 "$API_PID" 2>/dev/null && kill -0 "$WEB_PID" 2>/dev/null; do
    sleep 1
done

if ! kill -0 "$API_PID" 2>/dev/null; then
    warn "the geometry service stopped; shutting down the web UI"
fi
