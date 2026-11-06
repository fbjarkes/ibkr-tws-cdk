# OS security alternatives

This branch uses local logs only. It does not create AWS services, send notifications, block addresses, stop applications or change SSH/sudo/network permissions. Review before deployment and save work: changed provisioning can stop/start EC2.

## Common behavior

- A systemd timer collects SSH and xrdp authentication events every minute into `/var/log/tws-security/events.jsonl` (root-only), also visible in the service journal. Successful logins are reported regardless of source IP; these are signals for review, not proof of intrusion.
- Persistent journald storage is limited to 100 MiB. A saved cursor resumes collection after normal stop/start; a missing/vacuumed cursor produces a gap event and falls back to retained records from this boot. Abrupt crashes can cause duplicate events. Detection cannot recover logs already deleted before collection.
- Logrotate retains 14 rotated aggregate reports. Local logs/baselines live on the disposable root disk and do not survive recreation. Root compromise can alter these logs; this is not tamper-proof external monitoring.
- Ubuntu security updates remain enabled, with automatic reboot disabled. AppArmor utilities are installed; existing profiles remain intact. No automatic hardening remediation or active response is enabled.
- OSSEC alerts, when present, are summarized without copying full raw events or file-content diffs. SSH/xrdp fixture parsing is tested; validate actual login events after deployment, particularly if log formats change.

```powershell
npm run build
npm test
npx cdk diff TwsDesktop --profile poweruser
npx cdk deploy TwsDesktop --profile poweruser --require-approval never
```

```bash
sudo systemctl status tws-security-monitor.timer
sudo journalctl -u tws-security-monitor.service -b
sudo tail -n 30 /var/log/tws-security/events.jsonl
sudo python3 /usr/local/sbin/tws-security-monitor.py --event manual test 'Local alert pipeline test'
```

No live AWS deployment or workstation installation was performed when authoring these alternatives. For notification delivery later, add a separately scoped transport; no endpoint or credential is embedded here. Test installation and real authentication/integrity events on a disposable instance before using it on the trading desktop.

## Alternative B: OSSEC local mode

Branch: `codex/security-ossec`. OSSEC runs locally on the workstation: no manager VM, dashboard, agent enrollment port or remote syslog listener is added. Native SSH/PAM rules correlate authentication events; the shared collector separately handles SSH/xrdp login messages. Syscheck monitors selected OS/configuration files and trader's SSH/autostart directories. Rootcheck uses OSSEC's local checks. Active response, email, firewall blocking and file-content diffs are disabled.

OSSEC 4.4.1 is built from its pinned GitHub source archive. The installer verifies SHA-256 **and** its detached GPG signature against the full signing fingerprint published by OSSEC, using an isolated temporary keyring. Release metadata lives in `provision/ossec-release.json`. Source builds add compiler/library packages and may take several minutes. Existing unmanaged/different-version installations are refused rather than deleted or silently upgraded; upgrades require explicit migration review.

After deployment, first review the installation and activate it:

```bash
sudo /var/ossec/bin/ossec-analysisd -t
sudo touch /etc/tws-security/ossec-approved
sudo systemctl start ossec.service
sudo /var/ossec/bin/ossec-control status
sudo tail -n 30 /var/ossec/logs/alerts/alerts.json
sudo tail -n 30 /var/log/tws-security/events.jsonl
```

The unit is enabled at boot but gated by that root-owned approval marker. Until activation, the common login collector runs and reports an activation-required event. Local OSSEC data lives under `/var/ossec` on the disposable root disk; recreation needs fresh review/activation. Do not switch alternatives over an existing installation: recreate only the desktop/root disk, retaining the data volume, and deploy the chosen branch.

Syscheck scans at startup and hourly. After its initial scan, existing-file content changes can alert in near real time. New files and ownership/permission changes may wait until a scheduled scan. Unlike AIDE's frozen approved baseline, OSSEC maintains native evolving FIM state; it reports changes rather than waiting for an administrator to accept every new hash. `auto_ignore` is disabled so repeated changes are not silently accepted after a threshold. Ordinary updates can generate legitimate alerts; review them. This behavior is not immutable baseline protection.

Configuration excludes caches, ordinary project files/environments and the S3 mount by monitoring selected paths only. No arbitrary command-execution monitoring or secret-bearing file diffs are enabled. OSSEC rotates/compresses native alert history. A tmpfiles policy ages dated alert archives out after 30 days without touching current top-level log links; the standard cleanup timer is enabled. The aggregate log uses the common logrotate policy. Monitor disk usage on the 20 GiB root disk; time-based retention is not a hard byte cap.

### Validate on a disposable desktop

1. Run `python3 -B -m unittest discover -s test -p 'security_test.py'` for login fixtures, cursor/rotation behavior and XML configuration invariants.
2. Deploy onto a fresh root disk, validate all daemon configurations, activate and wait for the initial syscheck scan to finish.
3. Create/modify/delete a harmless `/etc/tws-integrity-test` file and check native/aggregate alerts. Allow a full hourly scan for new-file/metadata changes.
4. Validate successful/failed SSH and RDP logins; confirm no firewall rule, account privilege or TWS process changes.
5. Reboot and stop/start; confirm local OSSEC state persists and collection resumes. Confirm an actual SSH login works throughout validation.

Authoring validation: the source checksum/GPG signature, complete build/install in an isolated Ubuntu 24.04 filesystem, all three daemon configuration checks, and a native successful-SSH rule test passed. Python fixture and configuration-idempotence tests also passed. Full systemd startup/reboot, real xrdp log formats and live FIM behavior still require the disposable desktop checks above. No workstation/AWS changes were made.

Sources: [OSSEC installation/signing fingerprint](https://www.ossec.net/docs/docs/manual/installation/install-source.html), [unattended installation](https://www.ossec.net/docs/docs/manual/installation/install-source-unattended.html), [syscheck behavior and limitations](https://www.ossec.net/docs/docs/manual/syscheck/index.html).
