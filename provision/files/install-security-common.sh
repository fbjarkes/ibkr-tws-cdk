#!/usr/bin/env bash
set -euo pipefail
install -d -o root -g root -m 0700 /var/lib/tws-security /var/log/tws-security
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald.service
journalctl --flush
systemctl daemon-reload
systemctl enable --now tws-security-monitor.timer
