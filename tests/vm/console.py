#!/usr/bin/env python3
"""Run one shell command on the VM's serial console and print its output.

The stock image has no root password, so the serial console gives a root
shell after Enter. Exits with the command's status.
Usage: console.py SOCKET COMMAND
"""
import re
import socket
import sys
import time

sock_path, command = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.connect(sock_path)
s.settimeout(1)


def read_for(seconds):
    data = b""
    end = time.time() + seconds
    while time.time() < end:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        data += chunk
    return data.decode(errors="replace")


# Wake the console and wait for a shell that answers.
buf = ""
for _ in range(30):
    s.sendall(b"\r\n")
    s.sendall(b"echo __READY__$((20+22))\r\n")
    buf += read_for(2)
    if "__READY__42" in buf:
        break
else:
    sys.exit("no shell on the serial console")

# The console echoes what is typed; the markers are computed so that only the
# command's own output contains them in full.
s.sendall(f"echo __B$((40+2))__; {command}; echo __E$((40+2))__$?\r\n".encode())
out = ""
match = None
end = time.time() + 120
while time.time() < end and not match:
    out += read_for(2)
    match = re.search(r"__B42__\r?\n(.*)__E42__(\d+)", out, re.S)
if not match:
    sys.exit("command did not finish")
print(match.group(1).strip().replace("\r", ""))
sys.exit(int(match.group(2)))
