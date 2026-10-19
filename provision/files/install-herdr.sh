#!/usr/bin/env bash
set -euo pipefail
manifest=/opt/tws-provision/herdr-release.json
url=$(jq -er '.url' "$manifest")
checksum=$(jq -er '.sha256' "$manifest")
[[ "$url" == https://github.com/herdrdev/herdr/releases/download/*/herdr-linux-x86_64 ]] || exit 1
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || exit 1
install -d -o trader -g trader /home/trader/.local/bin
destination=/home/trader/.local/bin/herdr
if [ -f "$destination" ] && [ "$(sha256sum "$destination" | cut -d' ' -f1)" = "$checksum" ]; then exit 0; fi
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 "$url" -o "$temporary/herdr"
printf '%s  %s\n' "$checksum" "$temporary/herdr" | sha256sum --check --status
install -o trader -g trader -m 0755 "$temporary/herdr" "$destination"
