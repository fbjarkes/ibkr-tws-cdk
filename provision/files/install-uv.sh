#!/usr/bin/env bash
set -euo pipefail
umask 022
manifest="${1:-/opt/tws-provision/uv-release.json}"
version=$(jq -er '.version' "$manifest")
url=$(jq -er '.url' "$manifest")
checksum=$(jq -er '.sha256' "$manifest")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$url" == "https://github.com/astral-sh/uv/releases/download/$version/uv-x86_64-unknown-linux-gnu.tar.gz" ]]
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]]
if [ -x /usr/local/bin/uv ] && [ -x /usr/local/bin/uvx ] && \
   [[ "$(/usr/local/bin/uv --version)" == "uv $version"* ]]; then exit 0; fi
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 "$url" -o "$temporary/uv.tar.gz"
printf '%s  %s\n' "$checksum" "$temporary/uv.tar.gz" | sha256sum --check --status
tar -xzf "$temporary/uv.tar.gz" -C "$temporary" --strip-components=1 \
  uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx
install -o root -g root -m 0755 "$temporary/uv" /usr/local/bin/uv
install -o root -g root -m 0755 "$temporary/uvx" /usr/local/bin/uvx
/usr/local/bin/uv --version
