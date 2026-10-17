#!/usr/bin/env bash
set -euo pipefail
while IFS= read -r script; do bash "$script"; done < <(find /opt/tws-provision/hooks/every-boot -maxdepth 1 -type f -name '*.sh' | sort)
