#!/usr/bin/env bash
# The files that carry a release signature, one per line.
#
# Single source of truth on purpose. The draft this replaced spelled the six
# names out twice inside one workflow, and preflight-check.sh needs the same
# list a third time. Three copies of a list is three chances for it to drift,
# and a name silently dropped from one copy means a file published without a
# signature while everything still reports success.
set -euo pipefail

cat <<'EOF'
install_amneziawg.sh
install_amneziawg_en.sh
manage_amneziawg.sh
manage_amneziawg_en.sh
awg_common.sh
awg_common_en.sh
EOF
