#!/usr/bin/env bash
# Double-clickable launcher for macOS Finder. Keeps the Terminal window open
# so setup progress and any errors stay readable.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
./start-cad.sh
status=$?
if [ $status -ne 0 ]; then
    echo
    echo "LucasCad could not start. Review the error above."
    echo "Press any key to close this window."
    read -r -n 1 -s
fi
exit $status
