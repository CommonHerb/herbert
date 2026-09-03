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
grade = None          # link66: the GATE's ack loop (see the --grade block below)
witness = False       # A3.1: expect the guest's own accumulator byte, then a guard fault
drain_mode = "eof"    # "eof" (QEMU, -no-reboot) or "quiet" (Bochs, which RESETS on triple fault)
draw = 0              # which of the master seed's two draws this run is
master_seed = None    # A1: handed in by the SUPERVISING driver; never drawn here
query_seed = None     # A SECOND, INDEPENDENT 64-bit value -- see the --grade block
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
drain_timeout = 90.0   # long enough to reach the guest's own EOF; the outer `timeout` binds first
rest = []
i = 0
while i < len(args):
    if args[i] == "--hold":
        hold = float(args[i + 1]); i += 2
    elif args[i] == "--cap":
        cap = args[i + 1]; i += 2
    elif args[i] == "--serve":
        serve = args[i + 1]; i += 2
    elif args[i] == "--grade":
        grade = args[i + 1]; i += 2
    elif args[i] == "--witness":
        witness = True; i += 1
    elif args[i] == "--drain-mode":
        drain_mode = args[i + 1]; i += 2
    elif args[i] == "--draw":
        draw = int(args[i + 1]); i += 2
    elif args[i] == "--master-seed":
        master_seed = int(args[i + 1], 16); i += 2
    elif args[i] == "--query-seed":
        query_seed = int(args[i + 1], 16); i += 2
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

if grade is not None:
    # ---- link66 GRADE MODE: the GATE's one-byte-ack loop.
    #
    # Same strict-alternation plumbing as --serve below, and three deliberate differences,
    # each of which is the reason this mode exists rather than reusing --serve:
    #
    #  1. THE SEED IS NOT DRAWN HERE (A1). It arrives on --master-seed from the supervising
    #     gate driver, which drew it and REMEMBERS it. This process prints back exactly what
    #     it was handed, at one named line, and the driver compares. A harness that ignored
    #     the channel and substituted an internal constant would print a value the driver
    #     never drew -- that is the `seed-echo` leg, and it is why no os.urandom call appears
    #     anywhere in this block.
    #  2. QUERIES ARE DRAWN WITHOUT REPLACEMENT over the FULL index range [0, N). With
    #     replacement, a repeated index is answerable from the survivor's own earlier answer
    #     -- a credit measured at 11.46 bits at (512,64), enough to fail the 2^-40 bar. Drawing
    #     without replacement removes that attack BY CONSTRUCTION rather than pricing it.
    #  3. THE EXPECTED ANSWER IS payload[idx] -- the REAL indexed load. --serve's arithmetic
    #     stand-in (idx*7+259) exists because op 50 was not admitted when it was written; it
    #     is now, so the gate grades storage instead of arithmetic.
    #
    # The generator is the design's own, restated: ONE instance PER STREAM, instantiated
    # OUTSIDE the comprehension, with explicit integer domain tags. A generator constructed
    # inside a comprehension has a single-point image -- every payload byte and every index
    # identical -- which is the defect two blind lenses found in a sibling artifact. The tag
    # (seed<<2)|(d<<1)|kind is injective only for d in {0,1}, which is why d is pinned to the
    # two draws; a re-roll re-draws the MASTER SEED, never d.
    _n, _q = grade.split(":")
    N = int(_n); Q = int(_q)
    if master_seed is None or query_seed is None:
        print("GRADE_NO_SEED", flush=True); sys.exit(4)
    if draw not in (0, 1):
        print("GRADE_BAD_DRAW %d" % draw, flush=True); sys.exit(4)
    if Q > N:
        print("GRADE_Q_EXCEEDS_N", flush=True); sys.exit(4)
    # Q == 0 would make the whole grade vacuous: no query is asked, `ok` stays 1, and a guest
    # that stored nothing passes. A blind refutation leg demonstrated exactly that at (508, 0).
    if Q < 1:
        print("GRADE_Q_TOO_SMALL", flush=True); sys.exit(4)
    # `--hold` bounds the DEFAULT path's accept-and-wait window and is not read anywhere in this
    # block, yet every graded caller used to pass it -- so the bound read as configured when it
    # was not. A review leg named it. Refusing it here is what keeps a caller from believing in
    # a lifetime this mode does not have: the graded bounds are echo_timeout per recv and
    # drain_timeout to EOF, both above, plus the emulator's own kill.
    if "--hold" in args:
        print("GRADE_HOLD_UNSUPPORTED (grade mode is bounded by --echo-timeout and the drain, not by --hold)", flush=True)
        sys.exit(4)
    # ONE named line, carrying BOTH halves, printed VERBATIM as handed in (A1).
    print("LINK66_SEED=%016x%016x (drawn: supervisor)" % (master_seed, query_seed), flush=True)

    # TWO INDEPENDENT SEEDS, and the reason is a refutation leg's, not a preference.
    # The fill phase reveals every payload byte to the guest BEFORE the first query index is
    # sent. With both streams derived from one 64-bit master seed, the payload DETERMINES the
    # query stream: 4096 revealed bits against 64 bits of state, so the whole 512-byte challenge
    # collapses to 8 bytes a guest could hold in one frame. That the inversion costs a 2^64
    # search over `init_by_array` -- roughly fourteen orders of magnitude beyond the 120 s boot
    # budget -- makes it unexploitable TODAY; it does not make the independence claim true, and
    # the design's 2^-64 floor rested on that claim. Two independent draws restore it
    # information-theoretically for the price of one more int.from_bytes.
    def _stream(ms, d, kind):
        return random.Random((ms << 2) | (d << 1) | kind)

    rp = _stream(master_seed, draw, 0)
    rq = _stream(query_seed, draw, 1)
    fill_bytes = bytes(rp.randrange(256) for _ in range(N))
    queries = rq.sample(range(N), Q)

    conn.settimeout(echo_timeout)
    rxbuf = bytearray()
    quickack_applied = 0
    if quickack:
        try:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_QUICKACK, 1)
            quickack_applied = 1
        except (OSError, AttributeError) as ex:
            print("QUICKACK_UNAVAILABLE %s" % type(ex).__name__, flush=True)

    def grx1():
        if quickack_applied:
            try:
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_QUICKACK, 1)
            except OSError:
                pass
        c = conn.recv(1)
        if c == b"":
            raise EOFError("peer closed mid-protocol")
        rxbuf.extend(c)
        return c[0]

    ok = 1; mismatch = "-"; answers = []; wbyte = -1
    try:
        # NO HANDSHAKE. --serve has one because MEAS-N's probe LATE-BINDS N and Q from four
        # echoed count bytes; the link's forcing program does not -- its N and Q are literals
        # in the source (fill(b,0,512) / serve(b,64,0)), so there is nothing to late-bind and
        # four unread bytes would be swallowed as payload, desynchronising the whole stream.
        # A smoke run proved exactly that: mismatch=fill.510, rx=516, qemu timed out. Dropping
        # the handshake is also what makes the design's own counts exact: sends = N + 2Q = 640,
        # receives = N + 3Q = 704.
        if ok:
            for j in range(N):
                conn.sendall(bytes([fill_bytes[j]]))
                if grx1() != fill_bytes[j]:
                    ok = 0; mismatch = "fill.%d" % j; break
        # The shared Bochs F2 harness treats a COMPLETED boot whose feed log has no "^SENT"
        # as FEED-NO-SENT (the feeder never delivered). Emit that witness once the fill phase
        # HAS actually been delivered, so it means exactly what the harness reads it to mean.
        if ok:
            print("SENT grade-fill n=%d" % N, flush=True)
        if ok:
            for j in range(Q):
                idx = queries[j]
                hi = (idx >> 8) & 0xFF; lo = idx & 0xFF
                conn.sendall(bytes([hi]))
                if grx1() != hi:
                    ok = 0; mismatch = "q%d.hi" % j; break
                conn.sendall(bytes([lo]))
                if grx1() != lo:
                    ok = 0; mismatch = "q%d.lo" % j; break
                a = grx1()
                answers.append(a)
                if a != fill_bytes[idx]:
                    ok = 0; mismatch = "q%d.ans idx=%d got=%d want=%d" % (j, idx, a, fill_bytes[idx]); break
        # AMENDMENT A3.1 -- THE GUARD WITNESS. One more byte: the guest's own whole-run
        # accumulator, `sum(answers) & 0xff`, emitted by `output_byte(s)` before the forcing
        # program takes `bufget(b, 262144)` and triple-faults on the guard page. It is the byte
        # the grading tail would have framed, and it is the LAST thing any honest guest emits --
        # a guest whose storage is not the real guarded buffer answers this access instead of
        # faulting, and the gate sees a completion where it requires a fault.
        if ok and witness:
            w = grx1()
            wbyte = w
            want_w = sum(answers) & 0xFF
            if w != want_w:
                ok = 0; mismatch = "witness got=%d want=%d" % (w, want_w)
    except (socket.timeout, EOFError, OSError) as ex:
        ok = 0; mismatch = "%s@%s" % (type(ex).__name__, mismatch)
    # Any byte past the expected count invalidates the grade: the framing assumption is
    # exact count + strict alternation, so an extra byte means the assumption did not hold.
    # Drain to the guest's OWN exit, not to a wall-clock window. A 0.5 s drain made the
    # "any byte beyond the expected count" invariant TIME-bounded: a refutation leg showed a
    # spurious byte at +0.05 s caught (extra=1) and the same byte at +0.80 s missed entirely --
    # i.e. the same emitter defect could go RED on one engine and GREEN on the other. The
    # emulator's exit is a deterministic EOF barrier and the outer `timeout` already bounds it.
    # DRAIN MODE -- a SUBSTRATE difference, stated rather than tuned around.
    #
    # Under QEMU's -no-reboot a triple fault makes the process EXIT, so the socket closes and the
    # guest's own exit is a deterministic EOF barrier. BOCHS RESETS on triple fault: the machine
    # reboots, re-runs the UART init and blocks on its first input_byte(), so EOF NEVER ARRIVES
    # and a 90-second wait for one is both wrong and expensive -- the first A3 smoke reported
    #     ok=0 mismatch=drain_no_eof@- rx=705 expected_rx=705 extra=0 answers=64 witness=204
    # on two byte-perfect Bochs draws.
    #
    # `quiet` therefore drains for a SHORT settle window and does not treat the absence of EOF as
    # a failure -- but it still counts every byte, and `extra` is reported exactly as before. The
    # "no byte beyond the expected count" invariant is NOT weakened: the gate requires `extra=0`
    # on this line, and on Bochs it additionally requires the NO-SHUTDOWN class and zero
    # completion frames. The settle window is 2 s because the fault-reset-reinit cycle on Bochs
    # is sub-second (a boundary probe completes five of them inside its own leg), so the window
    # spans several cycles of anything the guest could emit after the fault.
    #
    # AND THE WINDOW IS TOTAL, NOT PER-RECV. `settimeout` bounds each individual recv, so a guest
    # emitting one byte every 1.9 s would have kept a "2 second" drain alive until the harness
    # killed it -- the window was unbounded above. A refutation leg found that. The deadline below
    # is wall-clock and absolute.
    extra = 0
    quiet = (drain_mode == "quiet")
    deadline = time.time() + (2.0 if quiet else drain_timeout)
    conn.settimeout(2.0 if quiet else drain_timeout)
    try:
        while True:
            if time.time() >= deadline:
                raise socket.timeout()
            conn.settimeout(max(0.01, deadline - time.time()))
            c = conn.recv(1)
            if c == b"":
                print("PEERCLOSED", flush=True); break
            rxbuf.extend(c); extra += 1
    except socket.timeout:
        if drain_mode == "quiet":
            print("DRAIN_QUIET_NO_EOF (expected on a substrate that resets rather than exits)", flush=True)
        else:
            print("DRAIN_TIMEOUT_NO_EOF", flush=True)
            ok = 0; mismatch = "drain_no_eof@%s" % mismatch
    except OSError as ex:
        # A RESET IS NOT AN EOF, and swallowing it re-opened the hole the drain exists to close.
        # A review leg: "after the expected 704 bytes, a reset produces OSError rather than EOF.
        # The feeder retains ok=1 ... An extra byte discarded by the reset is not detected, so
        # 'ANY byte beyond the expected count' remains unsupported." Only `recv() == b""`
        # authenticates the guest's own exit; everything else is a failure to observe it.
        print("DRAIN_ERROR %s" % type(ex).__name__, flush=True)
        ok = 0; mismatch = "drain_%s@%s" % (type(ex).__name__, mismatch)
    if extra:
        ok = 0; mismatch = "extra=%d@%s" % (extra, mismatch)
    if cap:
        open(cap, "wb").write(bytes(rxbuf))
    expected_rx = N + 3 * Q + (1 if witness else 0)   # 704 at (512,64), 705 with the witness
    # `witness=` stays the LAST field: the gate anchors on `witness=([0-9]+)$` precisely because an
    # unanchored glob for `witness=10` also matched `witness=100`..`witness=109`. Anything appended
    # after it silently re-breaks that leg, so the drain annotation goes BEFORE it.
    print("GRADE n=%d q=%d draw=%d quickack=%d ok=%d mismatch=%s rx=%d expected_rx=%d extra=%d answers=%d drain=%s witness=%d"
          % (N, Q, draw, quickack_applied, ok, mismatch, len(rxbuf), expected_rx, extra, len(answers),
             ("quiet-2s-window" if drain_mode == "quiet" else "eof"), wbyte),
          flush=True)
    print("CAPTURED " + bytes(rxbuf).hex(), flush=True)
    try:
        conn.close()
    except Exception:
        pass
    s.close()
    sys.exit(0 if ok else 3)

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
