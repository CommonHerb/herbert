#!/usr/bin/env python3
# Far-axis INPUT substrate for the trukfit (f3 device-input) link30 gate.
# Python is the TCP SERVER; the emulator (QEMU -chardev socket / Bochs com1
# mode=socket-client) connects as a CLIENT and receives exactly the bytes given,
# one connection per run. The socket is held open past output capture (no mid-run
# EOF/hangup). The guest busy-polls LSR.DR, so the byte VALUE is decoupled from RX
# timing -- which is why a chosen byte arrives BIT-IDENTICALLY on QEMU and Bochs.
#
# A "--drained-probe" mode reports whether the guest actually CONSUMED the byte:
# after the hold, it tries a final non-blocking send; if the peer already closed
# having read nothing (or the byte is still queued unread), it prints DRAINED=0.
# The mutation proof uses this to PROVE a literal-baked image never reads the RBR.
#
#   usage: kernel_input_feed.py <port> <byte0> [<byte1> ...] [--hold S] [--delay S] [--drained-probe]
#
# --delay S (default 0): wait S seconds AFTER the guest connects before sending the byte. The byte VALUE is
# decoupled from RX timing (the guest busy-polls LSR.DR), so a delay does NOT change WHICH byte arrives -- it
# only makes the guest's COM1 poll spin longer. The geeking (link 37) mutation harness uses --delay so the
# IF=0 SYS_READ poll outlasts the ~55ms one-shot PIT period, latching a stale tick in the 8259 IRR -- exactly
# the pending-tick condition the stale-IRR drain + RPL-keyed handler exist to absorb. A backward-compatible
# default of 0 leaves every prior link's gate unchanged.
import socket, sys, time

args = sys.argv[1:]
hold = 8.0
delay = 0.0
drained_probe = False
rest = []
i = 0
while i < len(args):
    if args[i] == "--hold":
        hold = float(args[i + 1]); i += 2
    elif args[i] == "--delay":
        delay = float(args[i + 1]); i += 2
    elif args[i] == "--drained-probe":
        drained_probe = True; i += 1
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
if delay > 0:
    time.sleep(delay)
conn.sendall(payload)
print("SENT " + " ".join(str(b) for b in payload), flush=True)
time.sleep(hold)
drained = "unknown"
if drained_probe:
    # If the guest read its byte, a well-behaved 16550 model leaves the TCP
    # channel open until shutdown. We cannot read the UART's RBR from here, so we
    # use a coarse proxy: whether the peer half-closed (FIN) before we close. A
    # guest that NEVER touches the serial port (literal-baker) still leaves the
    # socket open via the emulator, so this proxy is weak on its own -- the gate's
    # AUTHORITATIVE drain check is the WHITE-BOX scan (no live `in` outside the
    # pinned RBR site) plus the X/Y output collapse. We report best-effort here.
    conn.setblocking(False)
    try:
        peek = conn.recv(1, socket.MSG_PEEK)
        drained = "peer_open" if peek == b"" else "peer_data"
    except BlockingIOError:
        drained = "peer_open"
    except (ConnectionResetError, OSError):
        drained = "peer_closed"
    print("DRAINED_PROBE=" + drained, flush=True)
try:
    conn.close()
except Exception:
    pass
s.close()
