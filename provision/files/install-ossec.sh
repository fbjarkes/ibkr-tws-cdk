#!/usr/bin/env bash
set -euo pipefail
umask 022
manifest=/opt/tws-provision/ossec-release.json
version=$(jq -er .version "$manifest")
url=$(jq -er .url "$manifest")
checksum=$(jq -er .sha256 "$manifest")
signature=$(jq -er .signatureUrl "$manifest")
key_url=$(jq -er .signingKeyUrl "$manifest")
fingerprint=$(jq -er .signingFingerprint "$manifest")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "$url" == "https://github.com/ossec/ossec-hids/archive/refs/tags/$version.tar.gz" ]]
[[ "$signature" == "https://github.com/ossec/ossec-hids/releases/download/$version/ossec-hids-$version.tar.gz.asc" ]]
[[ "$key_url" == https://www.ossec.net/files/OSSEC-ARCHIVE-KEY.asc ]]
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] && [[ "$fingerprint" =~ ^[A-F0-9]{40}$ ]]
marker=/var/lib/tws-security/ossec-version
if [ -x /var/ossec/bin/ossec-analysisd ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$version" ]; then exit 0; fi
if [ -d /var/ossec ]; then
  echo 'Unmanaged/different OSSEC installation found. Review migration explicitly; no automatic overwrite or deletion.' >&2
  exit 1
fi
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
fetch() { curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 "$1" -o "$2"; }
fetch "$url" "$temporary/source.tar.gz"
fetch "$signature" "$temporary/source.asc"
fetch "$key_url" "$temporary/key.asc"
printf '%s  %s\n' "$checksum" "$temporary/source.tar.gz" | sha256sum --check --status
install -d -m 0700 "$temporary/gnupg"
gpg --homedir "$temporary/gnupg" --batch --import "$temporary/key.asc"
gpg --homedir "$temporary/gnupg" --batch --status-fd 1 --verify "$temporary/source.asc" "$temporary/source.tar.gz" > "$temporary/signature.status"
grep -Fq "[GNUPG:] VALIDSIG $fingerprint " "$temporary/signature.status"
tar -xzf "$temporary/source.tar.gz" -C "$temporary"
cd "$temporary/ossec-hids-$version"
cat > etc/preloaded-vars.conf <<'VARS'
USER_LANGUAGE="en"
USER_NO_STOP="y"
USER_INSTALL_TYPE="local"
USER_DIR="/var/ossec"
USER_DELETE_DIR="n"
USER_ENABLE_EMAIL="n"
USER_ENABLE_SYSLOG="n"
USER_ENABLE_ACTIVE_RESPONSE="n"
USER_ENABLE_FIREWALL_RESPONSE="n"
USER_ENABLE_SYSCHECK="y"
USER_ENABLE_ROOTCHECK="y"
VARS
# Keep compilation bounded; use system libraries and enable Linux inotify FIM.
MAKEFLAGS='-j2 USE_INOTIFY=yes PCRE2_SYSTEM=yes USE_SYSTEMD=yes' ./install.sh < /dev/null
[ -x /var/ossec/bin/ossec-analysisd ]
install -d -o root -g root -m 0700 /var/lib/tws-security
printf '%s\n' "$version" > "$marker"
