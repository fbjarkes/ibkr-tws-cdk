#!/usr/bin/env bash
set -euo pipefail
install -d -o root -g root -m 0700 /var/lib/tws-security /var/log/tws-security
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald.service
journalctl --flush
chmod 0644 /etc/systemd/system/tws-security-monitor.service /etc/systemd/system/tws-security-monitor.timer /etc/systemd/journald.conf.d/90-tws-security.conf /etc/logrotate.d/tws-security /etc/apt/apt.conf.d/90-tws-security
systemctl daemon-reload
systemctl enable --now tws-security-monitor.timer
