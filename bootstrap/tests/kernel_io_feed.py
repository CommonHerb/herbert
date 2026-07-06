#!/usr/bin/env python3
# Far-axis FULL-DUPLEX COM1 substrate for the riposte (link 64, device OUTPUT) gate.
# Python is the TCP SERVER; the emulator (QEMU -chardev socket / Bochs com1
# mode=socket-client) connects as a CLIENT. On connect it SENDS the given bytes
# (possibly none -- an output-only program is fed nothing), then RECV-loops,
# CAPTURING everything the guest transmits until the peer closes (the emulator
# exiting closes the socket -- a deterministic EOF barrier, not a timing guess)
# or the hold expires. kernel_input_feed.py (the frozen link30..63 feeder) is
# send-only; this feeder is its output-capable sibling -- prior gates keep the
# frozen one untouched.
#
# Delivery-vs-receipt honesty (the L39 lesson): SENT means the bytes left THIS
# process; it never proves the guest read them. The gate must therefore grade
# only via guest-side completion barriers (the debugcon frame + the exit code)
# plus the captured stream -- and a COMPLETED run with a wrong stream is a
# kernel/compiler RED, never a harness re-roll.
#
#   usage: kernel_io_feed.py <port> [<byte> ...] --cap <capfile> [--hold S]
#
# Prints LISTENING, then SENT <bytes>, then PEERCLOSED (iff the emulator closed
# the socket) and CAPTURED <hex> -- machine-checkable harness-taxonomy markers.
import socket, sys, time

args = sys.argv[1:]
hold = 45.0
cap = None
rest = []
i = 0
while i < len(args):
    if args[i] == "--hold":
        hold = float(args[i + 1]); i += 2
    elif args[i] == "--cap":
        cap = args[i + 1]; i += 2
    else:
        rest.append(args[i]); i += 1

port = int(rest[0])
payload = bytes(int(x) & 0xFF for x in rest[1:])

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
print("LISTENING", flush=True)
s.settimeout(25.0)
try:
    conn, _ = s.accept()
except socket.timeout:
    print("NOCONN", flush=True)
    sys.exit(2)
conn.sendall(payload)
print("SENT " + " ".join(str(b) for b in payload), flush=True)
conn.settimeout(1.0)
buf = b""
deadline = time.time() + hold
while time.time() < deadline:
    try:
        chunk = conn.recv(4096)
    except socket.timeout:
        continue
    except OSError:
        break
    if chunk == b"":
        print("PEERCLOSED", flush=True)
        break
    buf += chunk
if cap:
    open(cap, "wb").write(buf)
print("CAPTURED " + buf.hex(), flush=True)
try:
    conn.close()
except Exception:
    pass
s.close()
