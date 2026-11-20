#!/usr/local/bin/python3
# capharness_freebsd.py — host orchestrator for the in-bhyve-VM Capsicum
# self-report. ssh into the FreeBSD guest (freebsd_vm), compile the probe with
# the guest's cc, run it; the confined guest process reports over stdout (its
# inherited allowed channel, survives cap_enter), which we capture over the ssh
# pipe. Prints REPORT <line> for the aeocha spec to assert on. The pf on the
# host blocks arbitrary aeonat->host ports, so stdout-over-ssh is the permitted
# channel (sshd:22 is reachable; high ports are not).
#
# The probe source travels on the ssh session's stdin, so nothing has to be
# staged inside the guest first; a freshly booted guest works.
#
#   AEO_FREEBSD_GUEST_IP  guest address (default 172.16.0.52, or argv[1]); the
#                         Linux guest owns .50, so both can run at once
#   AEO_FREEBSD_GUEST_USER  login (default freebsd, the cloud image's user)
#   AEO_SSH_KEY           private key for the guest (default ~/.ssh/id_rsa)
#
# Output contract with spec_capsicum_bhyvevm_selfreport:
#   HARNESS_UNAVAILABLE ...  no guest answers ssh: the spec skips
#   HARNESS_ERR ...          a guest answered but the probe did not report: the
#                            spec FAILS
#   REPORT <line>            one line of the probe's report
import os, os.path, socket, subprocess, sys

IP = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("AEO_FREEBSD_GUEST_IP", "172.16.0.52")
USER = os.environ.get("AEO_FREEBSD_GUEST_USER", "freebsd")
KEY = os.environ.get("AEO_SSH_KEY") or os.path.expanduser("~/.ssh/id_rsa")
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capprobe_freebsd_stdout.c")

def answers(ip, port=22, timeout=4):
    try:
        socket.create_connection((ip, port), timeout=timeout).close()
        return True
    except OSError:
        return False

if not answers(IP):
    print("HARNESS_UNAVAILABLE no guest answers ssh at %s:22" % IP); sys.exit(3)

with open(SRC, "rb") as f:
    r = subprocess.run(["ssh", "-i", KEY, "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", USER + "@" + IP,
        "cat > /tmp/aeo-capprobe.c && cc -o /tmp/aeo-capprobe /tmp/aeo-capprobe.c && /tmp/aeo-capprobe"],
        stdin=f, capture_output=True)
out = r.stdout.decode(errors="replace")
if r.returncode != 0 or not out:
    err = (r.stderr.decode(errors="replace") or out).strip().replace("\n", " | ")
    print("HARNESS_ERR guest %s answered but the probe gave no report (exit %d): %s"
          % (IP, r.returncode, err or "no output")); sys.exit(2)
for line in out.splitlines():
    print("REPORT", line)
