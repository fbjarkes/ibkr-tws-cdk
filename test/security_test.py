import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "provision/files/rootfs/usr/local/sbin/tws-security-monitor.py"
spec = importlib.util.spec_from_file_location("monitor", SCRIPT)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)

class SecurityTests(unittest.TestCase):
    def test_auth_fixtures(self):
        for line in ["Accepted publickey for trader from 100.70.1.2", "++ created session (access granted): username trader", "login successful for user trader"]:
            self.assertEqual(monitor.classify(line), "login_success")
        for line in ["Failed password for trader", "pam_unix(sshd:auth): authentication failure", "AUTHFAIL: user=trader"]:
            self.assertEqual(monitor.classify(line), "login_failure")
        self.assertIsNone(monitor.classify("session closed for user trader"))

    def test_tail_resume_rotation_and_partial_record(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "alerts.json"
            path.write_text('{"rule":{"id":1}}\n')
            records, state = monitor.tail_json(path, {})
            self.assertEqual(records[0]["rule"]["id"], 1)
            self.assertEqual(monitor.tail_json(path, state)[0], [])
            with path.open("a") as stream: stream.write('{"rule":{"id":2}}\n')
            path.rename(path.with_suffix(".json.1"))
            path.write_text('{"rule":{"id":3}}\n{')
            records, state = monitor.tail_json(path, state)
            self.assertEqual([r["rule"]["id"] for r in records], [2, 3])
            self.assertEqual(monitor.tail_json(path, state)[0], [])

    def test_nested_ossec_rotation_and_missing_history(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "alerts.json"
            path.write_text('{"rule":{"id":1}}\n')
            _, state = monitor.tail_json(path, {})
            with path.open("a") as stream: stream.write('{"rule":{"id":2}}\n')
            archived = Path(directory) / "2026" / "Oct" / "ossec-alerts-27.json"
            archived.parent.mkdir(parents=True)
            path.rename(archived)
            path.write_text('{"rule":{"id":3}}\n')
            records, new_state = monitor.tail_json(path, state)
            self.assertEqual([r["rule"]["id"] for r in records], [2, 3])
            self.assertFalse(new_state["gap"])
            archived.unlink()
            _, new_state = monitor.tail_json(path, state)
            self.assertTrue(new_state["gap"])

    def test_journal_checkpoint_prevents_duplicate_auth_alerts(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            output = Path(directory) / "events.jsonl"
            record = json.dumps({"MESSAGE":"Accepted publickey for trader", "__CURSOR":"fixture-cursor"})
            class Result:
                returncode = 0
                stdout = record + "\n"
                def check_returncode(self): pass
            with patch.object(monitor.subprocess, "run", return_value=Result()) as run:
                monitor.collect(state, output)
                self.assertIn("--boot", run.call_args.args[0])
            Result.stdout = ""
            with patch.object(monitor.subprocess, "run", return_value=Result()) as run:
                monitor.collect(state, output)
                self.assertIn("--after-cursor=fixture-cursor", run.call_args.args[0])
            self.assertEqual(len(output.read_text().splitlines()), 1)

class OssecConfigTests(unittest.TestCase):
    def test_local_only_configuration_is_idempotent_and_preserves_rules(self):
        import xml.etree.ElementTree as ET
        config_path = Path(__file__).resolve().parents[1] / "provision/files/configure-ossec.py"
        spec2 = importlib.util.spec_from_file_location("ossec_config", config_path)
        config = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(config)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ossec.conf"
            path.write_text('<ossec_config><rules><include>sshd_rules.xml</include></rules><active-response><command>firewall-drop</command></active-response><remote/><localfile/></ossec_config>')
            config.configure(path)
            first = path.read_text()
            config.configure(path)
            self.assertEqual(first, path.read_text())
            root = ET.parse(path).getroot()
            self.assertEqual(root.findtext("active-response/disabled"), "yes")
            self.assertEqual(root.findtext("global/email_notification"), "no")
            self.assertIsNone(root.find("remote"))
            self.assertEqual(root.findtext("rules/include"), "sshd_rules.xml")
            self.assertEqual(root.findtext("syscheck/auto_ignore"), "no")
            self.assertEqual(root.find("syscheck/directories").get("report_changes"), "no")

if __name__ == "__main__": unittest.main()
