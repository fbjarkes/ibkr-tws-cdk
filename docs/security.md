# OS Security and Monitoring

This repository includes local-only intrusion detection alternatives. These monitor SSH/RDP authentication and system file integrity with collected data remaining on the disposable root disk. Neither creates remote services, sends notifications, blocks addresses, stops applications, or changes SSH/sudo/network permissions.

**Important:** Review deployment branches before provisioning; changed provisioning can restart EC2. Local logs do not survive desktop recreation, and root compromise can modify them. This is audit-only monitoring, not tamper-proof protection.

## Common behavior

Both alternatives follow this pattern:

- A systemd timer collects SSH and xrdp authentication events every minute into `/var/log/tws-security/events.jsonl` (root-only read). Successful logins are reported regardless of source IP as audit signals, not intrusion proof.
- Persistent journald storage is limited to 100 MiB. A saved cursor resumes collection after normal stop/start; if unavailable, a gap event is logged and collection falls back to retained records from the current boot.
- Logrotate retains 14 rotated aggregate reports. Local logs and file-integrity baselines live on the disposable 20 GiB root disk and do not survive desktop recreation.
- Ubuntu security updates remain enabled. Automatic reboot is disabled. AppArmor utilities are pre-installed; existing profiles remain intact.
- No automatic hardening remediation or active response is enabled.

Verify and test on a fresh desktop before production use:

```bash
sudo systemctl status tws-security-monitor.timer
sudo journalctl -u tws-security-monitor.service -b
sudo tail -n 30 /var/log/tws-security/events.jsonl
sudo python3 /usr/local/sbin/tws-security-monitor.py --event test activation_required 'Manual event test'
```

## OSSEC: Host-based intrusion detection

Branch: `codex/security-ossec`. Deploys OSSEC 4.4.1 locally with file integrity monitoring (FIM), rootcheck, and SSH/PAM authentication correlation. No remote manager, dashboard, agent enrollment, or syslog forwarding is configured. Active response, email, firewall blocking, and detailed file-content diffs are disabled.

### Installation and verification

OSSEC 4.4.1 is compiled from a cryptographically verified GitHub source archive:

- The installer verifies SHA-256 checksum **and** detached GPG signature against OSSEC's published signing fingerprint in an isolated temporary keyring
- Release metadata is pinned in `provision/ossec-release.json`
- Source builds may take several minutes and add compiler/library packages
- Existing unmanaged or different-version installations are rejected (not upgraded silently)

After deployment, activate OSSEC with explicit administrator approval:

```bash
# 1. Validate daemon configurations
sudo /var/ossec/bin/ossec-analysisd -t
sudo /var/ossec/bin/ossec-logcollector -t
sudo /var/ossec/bin/ossec-syscheckd -t

# 2. Check installation status
sudo /var/ossec/bin/ossec-control status

# 3. Review alerts (will be empty until started)
sudo tail -n 30 /var/ossec/logs/alerts/alerts.json

# 4. Create approval marker and start the service
sudo touch /etc/tws-security/ossec-approved
sudo systemctl start ossec.service

# 5. Watch collected events
sudo tail -f /var/log/tws-security/events.jsonl
```

The systemd unit is enabled at boot but gated by the `/etc/tws-security/ossec-approved` marker. Until approval, the login collector runs and reports an `activation_required` event. The service will not start without this marker.

### Monitoring coverage

**File Integrity Monitoring** (syscheck):
- Monitors: `/etc`, `/usr/bin`, `/usr/sbin`, `/usr/local/bin`, `/usr/local/sbin`, trader's SSH keys, and autostart directories
- SHA-256 checksums, ownership, and permissions on all files
- Real-time detection via inotify for immediate alerts on existing-file changes
- Hourly full scans for new files and metadata changes
- Initial scan on startup; subsequent changes can alert near real-time
- `auto_ignore` disabled so repeated changes are reported (not silently accepted after a threshold)
- Excludes `/etc/mtab` and `/etc/resolv.conf` (frequently-changing OS files)

**Rootcheck:**
- Detects OSSEC's standard rootkit indicators

**Authentication Monitoring:**
- SSH and PAM rules from OSSEC correlate login events
- Separate journal collector handles xRDP session formats
- Reports successful/failed authentication by user and source

### Limitations and behavior

- **Not immutable baseline protection:** OSSEC maintains evolving FIM state and reports changes, unlike a frozen approved baseline. Ordinary updates can generate legitimate alerts.
- **Not active response:** Alerts are audit-only; no accounts are disabled, processes stopped, or firewall rules added.
- **Not external monitoring:** Root compromise can modify local logs. This is not tamper-proof intrusion detection.
- **Configuration scope:** Monitors critical OS and configuration paths, not arbitrary project files, caches, or the S3 mount.
- **Data retention:** Syscheck scans hourly. After the initial scan, content changes alert in near real time. New files and permission changes may wait until the next scan.
- **Log rotation:** OSSEC compresses native alert archives. A tmpfiles policy removes dated alert archives after 30 days without touching current links. Monitor 20 GiB root disk usage; time-based retention is not a hard byte cap.

### Validate on a disposable desktop

1. Run unit tests for login event parsing, cursor/rotation behavior, and XML configuration invariants:
   ```bash
   python3 -B -m unittest discover -s test -p 'security_test.py'
   ```

2. Deploy onto a fresh root disk. Validate all daemon configurations and wait for the initial syscheck scan to complete after activation.

3. Create/modify/delete a test file (e.g., `/etc/tws-integrity-test`) and verify both native and aggregate alerts. Observe timing: content changes alert quickly; new files/permissions may wait until the next hourly scan.

4. Test successful and failed SSH/RDP logins. Confirm no firewall, account privilege, or process changes occur.

5. Reboot and stop/start the service. Confirm local OSSEC state persists and collection resumes from the saved journal cursor. Verify an actual SSH login works throughout.

### Switching alternatives or rebuilding

Do not switch between alternatives over an existing installation. To change from AIDE to OSSEC (or vice versa):

1. Keep the data volume (`/srv/tws/home`)
2. Destroy and recreate the desktop and root disk only
3. Deploy the new branch
4. Perform fresh activation and validation

Local OSSEC data lives on the disposable root disk. Recreation requires fresh review and activation.

### References

- [OSSEC installation from source](https://www.ossec.net/docs/docs/manual/installation/install-source.html)
- [Unattended installation variables](https://www.ossec.net/docs/docs/manual/installation/install-source-unattended.html)
- [Syscheck behavior and limitations](https://www.ossec.net/docs/docs/manual/syscheck/index.html)
