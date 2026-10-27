#!/usr/bin/env python3
"""Apply local, alert-only OSSEC settings without replacing its rule definitions."""
from pathlib import Path
import os
import sys
import xml.etree.ElementTree as ET


def configure(path):
    tree = ET.parse(path)
    root = tree.getroot()
    def section(name):
        node = root.find(name)
        if node is None: node = ET.SubElement(root, name)
        return node
    def value(parent, name, text):
        for old in list(parent.findall(name)): parent.remove(old)
        ET.SubElement(parent, name).text = text
    global_config = section("global")
    value(global_config, "email_notification", "no")
    value(global_config, "jsonout_output", "yes")
    value(section("alerts"), "log_alert_level", "3")
    for name in ["active-response", "remote", "localfile"]:
        for old in list(root.findall(name)): root.remove(old)
    syscheck = section("syscheck")
    for child in list(syscheck): syscheck.remove(child)
    for name, text in [("frequency", "3600"), ("scan_on_start", "yes"), ("auto_ignore", "no"), ("alert_new_files", "yes")]:
        value(syscheck, name, text)
    ET.SubElement(syscheck, "directories", {"check_all":"yes", "check_sha256sum":"yes", "realtime":"yes", "report_changes":"no"}).text = "/etc,/usr/bin,/usr/sbin,/usr/local/bin,/usr/local/sbin,/home/trader/.ssh,/home/trader/.config/autostart"
    for ignored in ["/etc/mtab", "/etc/resolv.conf"]:
        ET.SubElement(syscheck, "ignore").text = ignored
    ET.SubElement(ET.SubElement(root, "active-response"), "disabled").text = "yes"
    # Native SSH/PAM rule correlation. xrdp log formats are handled explicitly
    # by the shared journal collector, not assumed to match SSH decoders.
    localfile = ET.SubElement(root, "localfile")
    ET.SubElement(localfile, "log_format").text = "syslog"
    ET.SubElement(localfile, "location").text = "/var/log/auth.log"
    temporary = Path(str(path) + ".tws-new")
    ET.indent(tree, space="  ")
    tree.write(temporary, encoding="unicode")
    temporary.chmod(0o640)
    stat = Path(path).stat()
    os.chown(temporary, stat.st_uid, stat.st_gid)
    os.replace(temporary, path)

if __name__ == "__main__": configure(Path(sys.argv[1]))
