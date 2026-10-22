#!/usr/bin/env bash
set -euo pipefail
umask 022
if [ -n "${1:-}" ] && [ "$1" != --repository-only ]; then
  echo "Usage: $0 [--repository-only]" >&2
  exit 2
fi
. /etc/os-release
[ "$ID" = ubuntu ] && [ "${VERSION_CODENAME:-}" = noble ] || {
  echo 'Tailscale provisioning supports Ubuntu 24.04 (noble).' >&2
  exit 1
}
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
# Official stable apt repository; apt verifies packages using this scoped keyring.
curl --fail --location --retry 3 --connect-timeout 15 --max-time 120   https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o "$temporary/keyring.gpg"
curl --fail --location --retry 3 --connect-timeout 15 --max-time 120   https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o "$temporary/tailscale.list"
[ -s "$temporary/keyring.gpg" ] && [ -s "$temporary/tailscale.list" ]
install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
install -o root -g root -m 0644 "$temporary/keyring.gpg" /usr/share/keyrings/tailscale-archive-keyring.gpg
install -o root -g root -m 0644 "$temporary/tailscale.list" /etc/apt/sources.list.d/tailscale.list
if [ "${1:-}" = --repository-only ]; then exit 0; fi
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y tailscale
systemctl enable --now tailscaled.service
# Enrollment is deliberately interactive; never embed an auth key in this asset.
