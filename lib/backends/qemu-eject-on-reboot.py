#!/usr/bin/env python3
"""Take the Windows install disc out at Setup's first reboot.

The prompt-free install ISO boots without "Press any key", which also means
nothing stops the firmware from booting it again after Setup's first reboot.
Setup then finds its own half-finished install and asks whether to continue
an "upgrade". Microsoft's answer is to remove the media at that point.

QEMU is started with `-action reboot=shutdown,shutdown=pause`, so the guest's
first reboot pauses the VM instead. This script, connected to QEMU's QMP
socket, then ejects the install disc, restores normal reboot behaviour,
resets and resumes the VM. Every later reboot is an ordinary one. A real
power-off by the guest (reason "guest-shutdown") quits QEMU as usual.

Usage: qemu-eject-on-reboot.py QMP_SOCKET DRIVE_ID MARKER_FILE
"""
import json
import os
import socket
import sys
import time

sock_path, drive, marker = sys.argv[1:4]


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def connect():
    for _ in range(150):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(sock_path)
            return s
        except OSError:
            time.sleep(0.2)
    sys.exit("QMP socket never appeared: " + sock_path)


conn = connect()
stream = conn.makefile("rw", encoding="utf-8")


def send(cmd, **args):
    msg = {"execute": cmd}
    if args:
        msg["arguments"] = args
    stream.write(json.dumps(msg) + "\n")
    stream.flush()
    # Skip events until the matching return/error arrives.
    for line in stream:
        reply = json.loads(line)
        if "return" in reply or "error" in reply:
            if "error" in reply:
                log(f"{cmd}: {reply['error'].get('desc')}")
            return reply


json.loads(stream.readline())          # QMP greeting
send("qmp_capabilities")
log("watching for Setup's first reboot")

for line in stream:
    event = json.loads(line)
    if event.get("event") != "SHUTDOWN":
        continue
    reason = event.get("data", {}).get("reason", "")
    if reason == "guest-reset":
        log("first reboot: ejecting the install disc")
        send("human-monitor-command", **{"command-line": f"eject -f {drive}"})
        send("set-action", reboot="reset", shutdown="poweroff")
        send("system_reset")
        send("cont")
        open(marker, "w").close()
    else:
        log(f"shutdown ({reason}): quitting")
        send("quit")
    break
os._exit(0)
