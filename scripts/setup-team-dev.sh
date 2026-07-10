#!/usr/bin/env bash

set -euo pipefail

cat >&2 <<'EOF'
error: hosted mobile authentication is not configured for amux.

The inherited cmux Stack project and credentials are intentionally unavailable.
Use the local terminal, tmux, SSH, and agent workflows included with amux. An
Open330-owned authentication setup may be added in a future release.
EOF

exit 1
