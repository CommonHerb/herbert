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
#
# ---------------------------------------------------------------------------
# --serve MODE (MEAS-N, 2026-09-02): the STRICT-ALTERNATION ack loop.
#
#   usage: kernel_io_feed.py <port> --serve <N>:<Q> [--seed S] [--burst]
#          [--burst-reps R] [--no-quickack] [--echo-timeout S] --cap <capfile> [--hold S]
#
# The default (no --serve) path above is UNCHANGED in every respect -- same
# argument shape, same one-shot sendall, same recv(4096) capture loop, same
# printed markers -- so link64 and link64_mutation are behaviour-identical and
# their own gates are the proof. --serve is purely additive.
#
# Why a mode and not a new file: the ack loop needs the same LISTENING/accept/
# capture plumbing this file already owns, and BOOTSTRAP-ALLOWLIST says the list
# "shrinks toward empty" -- a second feeder would grow it for no new mechanism.
#
# The protocol (one byte in flight, so no UART overrun is even expressible):
#   handshake  send nh, recv echo; nl; qh; ql   -- the guest echoes each, which
#              proves it has reached the read loop before any payload is sent.
#   fill  x N  send b_i; recv_exact(1) its echo           (--burst [--burst-reps
#              R]: sendall B = N/R bytes at once and then recv_exact(1) x B,
#              R times inside ONE boot -- the RECEIVE-BURST measurement, NOT a
#              licence to burst in a gate.)
#
# What --burst establishes and what it does NOT: a clean rung proves the host may
# hand the socket B bytes in one write and get B order-exact echoes back, i.e.
# nothing was lost. It does NOT prove the guest's one-byte RBR ever held two
# bytes at once -- the emulated UART backpressures the socket, so delivery may
# have been serialised by the host's own blocking. The number is a floor on
# reliable delivery, an upper bound on nothing, and evidence of emulator
# backpressure rather than of guest robustness.
#   query x Q  send hi; recv echo; send lo; recv echo; recv the answer byte.
#
# recv_exact(1) with a persistent buffer, never recv(4096): framing is by exact
# count and strict alternation, so equal-valued bytes stay positionally
# unambiguous. ANY byte beyond the expected count is a failed measurement.
#
# The draw: ONE random.Random(seed) instantiated ONCE per stream and drawn
# SEQUENTIALLY -- payload bytes first, then query indices. (A generator
# re-seeded inside a comprehension has a single-point image: every payload byte
# and every index identical. That defect was found in a sibling artifact by two
# blind lenses; it is not repeated here.) Image: payload in [0,256)^N drawn
# i.i.d., indices in [0,65536)^Q drawn i.i.d., independent of the payload.
#
# The answer the guest must return is (idx*7+259) & 0xFF with idx = hi*256+lo --
# an ARITHMETIC stand-in for the not-yet-admitted indexed load, so the caller
# must treat t_serve as a LOWER bound (see run_meas_n.sh's honesty note).
#
# Prints, in addition to the default markers: T_LISTEN/T_ACCEPT/T_HS/T_FILL_END/
# T_QUERY_END (absolute epoch seconds, so the caller can subtract its own launch
# stamp) and one SERVE line carrying ok=, mismatch= and the graded checksum.
import socket, sys, time, random

args = sys.argv[1:]
hold = 45.0
cap = None
serve = None
seed = 0
burst = False
burst_reps = 1
# TCP_QUICKACK is ON BY DEFAULT in --serve mode (parent ruling, 2026-09-03).
# Reason, measured not assumed: the query barrier's ANSWER byte is the only
# guest->host byte with no host->guest byte in front of it, so without it the
# peer's delayed ACK adds ~41 ms to EVERY barrier -- 98% of the measured cost on
# QEMU-TCG. A gate built on the raw default would spend its whole budget
# measuring the host's ACK policy instead of the guest. --no-quickack restores
# the raw transport, which is how MEAS-N measures the artefact itself.
# TCP_QUICKACK (host-side) is the chosen mechanism rather than QEMU's
# `-chardev socket,...,nodelay=on` because it works on BOTH emulators: Bochs
# exposes no nodelay knob, so nodelay alone could not be a harness default.
# nodelay=on is a verified independent second mechanism (it removes the same
# stall on QEMU) and is the fallback for a host without TCP_QUICKACK.
quickack = True
echo_timeout = 30.0
rest = []
i = 0
while i < len(args):
    if args[i] == "--hold":
        hold = float(args[i + 1]); i += 2
    elif args[i] == "--cap":
        cap = args[i + 1]; i += 2
    elif args[i] == "--serve":
        serve = args[i + 1]; i += 2
    elif args[i] == "--seed":
        seed = int(args[i + 1]); i += 2
    elif args[i] == "--echo-timeout":
        echo_timeout = float(args[i + 1]); i += 2
    elif args[i] == "--burst":
        burst = True; i += 1
    elif args[i] == "--burst-reps":
        burst_reps = int(args[i + 1]); i += 2
    elif args[i] == "--quickack":
        quickack = True; i += 1          # explicit; already the default
    elif args[i] == "--no-quickack":
        quickack = False; i += 1         # the RAW transport, for measuring the artefact
    else:
        rest.append(args[i]); i += 1

port = int(rest[0])
payload = bytes(int(x) & 0xFF for x in rest[1:])

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
print("LISTENING", flush=True)
t_listen = time.time()
s.settimeout(25.0)
try:
    conn, _ = s.accept()
except socket.timeout:
    print("NOCONN", flush=True)
    sys.exit(2)
t_accept = time.time()

if serve is not None:
    # ---- MEAS-N ack loop. Nothing below this block is reached in this mode, and
    # nothing in this block runs in the default mode.
    _n, _q = serve.split(":")
    N = int(_n); Q = int(_q)
    rng = random.Random(seed)                       # ONE generator, drawn in sequence
    fill_bytes = bytes(rng.randrange(256) for _ in range(N))
    queries = [rng.randrange(65536) for _ in range(Q)]
    conn.settimeout(echo_timeout)
    rxbuf = bytearray()
    # Claiming quickack=1 while the option silently failed would report a
    # configuration the run did not have. Probe it ONCE, loudly, and report what
    # actually applied -- never the flag that was asked for.
    quickack_applied = 0
    if quickack:
        try:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_QUICKACK, 1)
            quickack_applied = 1
        except (OSError, AttributeError) as ex:
            print("QUICKACK_UNAVAILABLE %s" % type(ex).__name__, flush=True)

    def rx1():
        # recv_exact(1) -- never recv(4096); framing is by exact count.
        if quickack_applied:
            # TCP_QUICKACK is one-shot on Linux: it must be re-armed before each recv.
            try:
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_QUICKACK, 1)
            except OSError:
                pass
        c = conn.recv(1)
        if c == b"":
            raise EOFError("peer closed mid-protocol")
        rxbuf.extend(c)
        return c[0]

    ok = 1
    mismatch = "-"
    checksum = 0
    t_hs = t_fill_end = t_query_end = 0.0
    try:
        for tag, v in (("nh", (N >> 8) & 0xFF), ("nl", N & 0xFF),
                       ("qh", (Q >> 8) & 0xFF), ("ql", Q & 0xFF)):
            conn.sendall(bytes([v]))
            if rx1() != v:
                ok = 0; mismatch = "hs_" + tag; break
        t_hs = time.time()
        if ok and burst:
            # B = N / burst_reps bytes sent back-to-back, burst_reps times, ALL
            # INSIDE ONE BOOT -- the ratified ladder shape (10 repetitions of a
            # rung cost one boot, not ten). Each sub-burst is verified
            # order-exact on its own before the next is sent.
            B = N // burst_reps
            for rep in range(burst_reps):
                off = rep * B
                conn.sendall(fill_bytes[off:off + B])
                for j in range(B):
                    if rx1() != fill_bytes[off + j]:
                        ok = 0; mismatch = "burst%d.%d" % (rep, j); break
                if not ok: break
        elif ok:
            for j in range(N):
                conn.sendall(bytes([fill_bytes[j]]))
                if rx1() != fill_bytes[j]:
                    ok = 0; mismatch = "fill.%d" % j; break
        t_fill_end = time.time()
        if ok:
            for j in range(Q):
                idx = queries[j]
                hi = (idx >> 8) & 0xFF; lo = idx & 0xFF
                conn.sendall(bytes([hi]))
                if rx1() != hi:
                    ok = 0; mismatch = "q%d.hi" % j; break
                conn.sendall(bytes([lo]))
                if rx1() != lo:
                    ok = 0; mismatch = "q%d.lo" % j; break
                full = idx * 7 + 259
                if rx1() != (full & 0xFF):
                    ok = 0; mismatch = "q%d.ans" % j; break
                checksum += full
        t_query_end = time.time()
    except (socket.timeout, EOFError, OSError) as ex:
        ok = 0
        mismatch = "%s@%s" % (type(ex).__name__, mismatch)
        now = time.time()
        if t_hs == 0.0: t_hs = now
        if t_fill_end == 0.0: t_fill_end = now
        t_query_end = now
    # Any byte past the expected count invalidates the measurement (it would mean
    # the framing assumption -- exact count + strict alternation -- did not hold).
    extra = 0
    conn.settimeout(0.5)
    try:
        while True:
            c = conn.recv(1)
            if c == b"":
                print("PEERCLOSED", flush=True); break
            rxbuf.extend(c); extra += 1
    except (socket.timeout, OSError):
        pass
    if extra:
        ok = 0; mismatch = "extra=%d@%s" % (extra, mismatch)
    if cap:
        open(cap, "wb").write(bytes(rxbuf))
    print("T_LISTEN %.6f" % t_listen, flush=True)
    print("T_ACCEPT %.6f" % t_accept, flush=True)
    print("T_HS %.6f" % t_hs, flush=True)
    print("T_FILL_END %.6f" % t_fill_end, flush=True)
    print("T_QUERY_END %.6f" % t_query_end, flush=True)
    print("SERVE n=%d q=%d burst=%d burstreps=%d quickack=%d ok=%d mismatch=%s rx=%d extra=%d graded=%02x seed=%d"
          % (N, Q, 1 if burst else 0, burst_reps, quickack_applied, ok, mismatch,
             len(rxbuf), extra, checksum & 0xFF, seed), flush=True)
    print("CAPTURED " + bytes(rxbuf).hex(), flush=True)
    try:
        conn.close()
    except Exception:
        pass
    s.close()
    sys.exit(0 if ok else 3)

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
