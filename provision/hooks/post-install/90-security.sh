#!/usr/bin/env bash
set -euo pipefail
bash /opt/tws-provision/files/install-security-common.sh
if [ -e /var/lib/tws-security/aide/baseline.db ] || systemctl is-enabled --quiet tws-aide.timer 2>/dev/null; then
  echo 'AIDE alternative found. Use a fresh desktop root disk when switching IDS alternatives.' >&2
  exit 1
fi
bash /opt/tws-provision/files/install-ossec.sh
python3 /opt/tws-provision/files/configure-ossec.py /var/ossec/etc/ossec.conf
/var/ossec/bin/ossec-analysisd -t
/var/ossec/bin/ossec-logcollector -t
/var/ossec/bin/ossec-syscheckd -t
install -d -o root -g root -m 0755 /etc/tws-security
chmod 0644 /etc/systemd/system/ossec.service
systemctl daemon-reload
systemctl enable ossec.service
# The first baseline requires administrator review, never auto-enroll it.
if [ -e /etc/tws-security/ossec-approved ]; then
  systemctl --no-block restart ossec.service
else
  python3 /usr/local/sbin/tws-security-monitor.py --event ossec activation_required 'Review installation, then create /etc/tws-security/ossec-approved and start ossec.service'
fi
