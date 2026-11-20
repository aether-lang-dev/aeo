#!/usr/local/bin/python3
# containment_harness_linux.py — host orchestrator. ssh into the Linux bhyve-VM
# guest, run the naive containment probe, capture its report (over the ssh pipe
# = the container-configured channel), emit REPORT <line> for aeocha. The probe
# is naive: it doesn't confine itself, it discovers the VM boundary by attempts.
#
# The probe travels on the ssh session's stdin (python3 -), so nothing has to be
# staged inside the guest first; a freshly cloned or rebooted guest works.
#
#   AEO_LINUX_GUEST_IP  guest address (default 172.16.0.50, or argv[1])
#   AEO_SSH_KEY         private key for the guest (default ~/.ssh/id_rsa)
#
# Output contract with spec_containment_linux_vm:
#   HARNESS_UNAVAILABLE ...  no guest answers ssh: the spec skips
#   HARNESS_ERR ...          a guest answered but the probe did not report: the
#                            spec FAILS (a broken guest must not read as absent)
#   REPORT <line>            one line of the probe's report
import os, os.path, socket, subprocess, sys

IP = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("AEO_LINUX_GUEST_IP", "172.16.0.50")
KEY = os.environ.get("AEO_SSH_KEY") or os.path.expanduser("~/.ssh/id_rsa")
PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "containment_probe_linux.py")

def answers(ip, port=22, timeout=4):
    try:
        socket.create_connection((ip, port), timeout=timeout).close()
        return True
    except OSError:
        return False

if not answers(IP):
    print("HARNESS_UNAVAILABLE no guest answers ssh at %s:22" % IP); sys.exit(3)

with open(PROBE, "rb") as f:
    r = subprocess.run(["ssh", "-i", KEY, "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
        "ubuntu@" + IP, "python3 -"], stdin=f, capture_output=True)
out = r.stdout.decode(errors="replace")
if r.returncode != 0 or not out:
    err = r.stderr.decode(errors="replace").strip().replace("\n", " | ")
    print("HARNESS_ERR guest %s answered but the probe gave no report (exit %d): %s"
          % (IP, r.returncode, err or "no output")); sys.exit(2)
for line in out.splitlines():
    print("REPORT", line)
