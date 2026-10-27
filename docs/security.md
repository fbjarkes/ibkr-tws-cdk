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
