#!/usr/bin/env bash
# Run the LucasCad test suites on macOS or Linux.
#
#   scripts/run-tests.sh            backend + frontend
#   scripts/run-tests.sh backend    pytest only
#   scripts/run-tests.sh frontend   pnpm test only

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PROJECT_ROOT
# shellcheck source=scripts/bootstrap.sh
. "$PROJECT_ROOT/scripts/bootstrap.sh"

TARGET=${1:-all}
case "$TARGET" in
    all|backend|frontend) ;;
    *) die "unknown target: $TARGET (expected all, backend, or frontend)" ;;
esac

if [ "$TARGET" = all ] || [ "$TARGET" = backend ]; then
    ensure_venv "$PROJECT_ROOT/backend/requirements-dev.txt"
    say "Running backend tests"
    ( cd "$PROJECT_ROOT" && "$VENV_PYTHON" -m pytest backend -q )
fi

if [ "$TARGET" = all ] || [ "$TARGET" = frontend ]; then
    ensure_node
    ensure_pnpm
    ensure_node_modules
    say "Running frontend tests"
    ( cd "$PROJECT_ROOT" && CI=true "$PNPM" test )
fi

say "All requested tests passed."
