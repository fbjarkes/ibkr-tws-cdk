#!/usr/bin/env python3
"""Local-only auth/IDS event collector. Never blocks logins or sends messages."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess


def classify(message):
    text = message.lower()
    if any(s in text for s in ("accepted publickey", "accepted password", "session opened for user", "login successful", "++ created session", "access granted")):
        return "login_success"
    if any(s in text for s in ("failed password", "failed publickey", "invalid user", "authentication failure", "authentication failed", "login failed", "authfail", "access denied")):
        return "login_failure"
    return None


def emit(path, source, kind, message):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    event = {"time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "source": source, "event": kind, "message": str(message)[:8192]}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as out:
        out.write(json.dumps(event) + "\n")
    print(json.dumps(event), flush=True)


def tail_json(path, previous):
    """Resume by inode/offset; finish an uncompressed rotated file first."""
    path = Path(path)
    if not path.exists():
        return [], previous
    current = path.stat()
    files = []
    gap = False
    old_inode = previous.get("inode")
    if old_inode and old_inode != current.st_ino:
        # OSSEC rotates into year/month subdirectories; also support .1 rotation.
        candidates = list(path.parent.glob(path.name + "*")) + list(path.parent.glob("*/*/*.json"))
        for candidate in candidates:
            if candidate.is_file() and not candidate.name.endswith(".gz") and candidate.stat().st_ino == old_inode:
                files.append((candidate, previous.get("offset", 0)))
                break
        else:
            gap = True
    offset = previous.get("offset", 0) if old_inode == current.st_ino else 0
    if offset > current.st_size:
        gap = True
        offset = 0
    files.append((path, offset))
    events = []
    position = offset
    for filename, start in files:
        with filename.open("rb") as stream:
            stream.seek(start)
            while True:
                before = stream.tell()
                line = stream.readline()
                if not line or not line.endswith(b"\n"):
                    stream.seek(before)
                    break
                try:
                    events.append(json.loads(line))
                except (ValueError, UnicodeDecodeError):
                    pass
            if filename == path:
                position = stream.tell()
    return events, {"inode": current.st_ino, "offset": position, "gap": gap}


def collect(state_dir, output):
    state_dir = Path(state_dir)
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_file = state_dir / "collector.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    command = ["journalctl", "--no-pager", "--output=json", "-u", "ssh.service", "-u", "xrdp.service", "-u", "xrdp-sesman.service"]
    query = ["--after-cursor=" + state["cursor"]] if state.get("cursor") else ["--boot"]
    result = subprocess.run(command + query, capture_output=True, text=True)
    if result.returncode and state.get("cursor"):
        emit(output, "collector", "journal_gap", "Saved journal cursor unavailable; recovering retained records from this boot")
        result = subprocess.run(command + ["--boot"], capture_output=True, text=True)
    result.check_returncode()
    for line in result.stdout.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        message = record.get("MESSAGE", "")
        kind = classify(message) if isinstance(message, str) else None
        if kind:
            emit(output, record.get("_SYSTEMD_UNIT", "auth"), kind, message)
        if record.get("__CURSOR"):
            state["cursor"] = record["__CURSOR"]
    events, state["ossec"] = tail_json("/var/ossec/logs/alerts/alerts.json", state.get("ossec", {}))
    if state["ossec"].get("gap"):
        emit(output, "collector", "ossec_log_gap", "Previous alert file was truncated or no longer retained; resuming available records")
    for event in events:
        rule = event.get("rule", {})
        # Never copy full_log or file-content diffs into the aggregate report.
        emit(output, "ossec", "ids_alert", {"id": rule.get("id"), "level": rule.get("level"), "description": rule.get("description"), "location": event.get("location")})
    temporary = state_file.with_suffix(".tmp")
    temporary.write_text(json.dumps(state), encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, state_file)


if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", default="/var/lib/tws-security")
    parser.add_argument("--output", default="/var/log/tws-security/events.jsonl")
    parser.add_argument("--event", nargs=3, metavar=("SOURCE", "KIND", "MESSAGE"))
    args = parser.parse_args()
    if args.event:
        emit(args.output, *args.event)
    else:
        collect(args.state_dir, args.output)
