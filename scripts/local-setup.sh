#!/usr/bin/env bash
#
# local-setup.sh
# Configure the reverse tunnel, SOCKS5 proxy and sshuttle on this machine only
# (no SSH key upload, no relay server changes).
#
# This is a thin wrapper around install.sh --local-only so that there is a
# single implementation. install.sh must live next to the scripts/ directory.
#
# Usage:
#   ./scripts/local-setup.sh --server user@host [--tunnel-port 2222]
#                            [--socks5-port 1080] [--ssh-port 22]
#                            [--enable-sshuttle] [--only-reverse] [--only-socks5]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/../install.sh"

if [[ ! -f "$INSTALLER" ]]; then
    echo "[local-setup] ERROR: ${INSTALLER} not found." >&2
    echo "[local-setup] Download the full repository or run install.sh directly." >&2
    exit 1
fi

exec bash "$INSTALLER" --local-only "$@"
