#!/usr/bin/env bash
# MEAS-N -- the black-box threshold MEASUREMENT leg for the long64 buffer link.
#
# NOT a gate. It grades nothing and lands no verdict on the compiler; it returns
# NUMBERS, with the command and substrate that produced each one, so the next
# link's scope stops asserting what it can measure. Chartered by
# BLUESTONE/audits/window-2026-09-01/PACKET-MEAS-N.md.
#
# What it measures, on the CURRENT emitter and the CURRENT head:
#   (1) B_MAX  -- the maximum reliable RECEIVE BURST per substrate: B bytes sent
#       back-to-back into an echo probe, requiring ALL B echoes to match the
#       bytes sent, IN ORDER (counting echoes cannot detect a drop). Geometric
#       ladder, stop at the first rung that is not clean in every repetition.
#   (2) t_boot / t_fill / t_serve -- boot time and per-round-trip time for the
#       one-byte-ack fill and query shapes, from a K-sweep, fit as
#       t(K) = t_boot + K*t_rt, with a HELD-OUT extrapolation check (fit on the
#       low rungs, predict the top rung, require within 10%). Two coefficients.
#       No R^2 anywhere: over this design R^2 >= 0.98 accepts a 35%-wrong
#       exponent, so it cannot decide the question being asked.
#   (3) the sustainable (N,Q) ceiling against the emulator kill / CI step cap.
#
# THE PROBE IS COMPILED BY THE CURRENT EMITTER FROM THE ADMITTED OPS ONLY. The
# multi-function long64 (nc_tap_*) subset admits ops 20/45/53 plus the nc64 set
# (PUSH_INT, LOAD/STORE_LOCAL, ADD, SUB, EQ, NE, BR, BR_IF_FALSE, MUL, RET) --
# `nc_tap_op_allowed`, stack/native_compile_fragment.herb:20166. There is NO
# indexed load/store yet (that IS the next link), so the query answer here is an
# ARITHMETIC function of the assembled index, (idx*7+259)&0xFF, instead of a
# bufget. Consequence, stated once, exactly, and without softening:
#
#   * The FILL barrier of the real forcing program is
#     `output_byte(bufset(base, i, input_byte()))` -- it performs an indexed
#     STORE whose pushed-back value is what gets echoed. This probe's fill does
#     `output_byte(base + input_byte())`. It OMITS the store.
#   * The QUERY barrier OMITS the indexed load `bufget(base, hi*256+lo)`.
#   * At (N=512, Q=64) that is 512 omitted stores and 64 omitted loads, plus the
#     one `bufbase()` in main. NEITHER HALF IS EXACT. An earlier draft of this
#     comment called the fill half "exact"; that was false, and both blind
#     refutation legs caught it.
#   * What IS matched, deliberately: the ARITY. `fill` and `serve` are 3-ary here
#     exactly as in the forcing program, so the per-iteration argument-copy cost
#     is identical -- a tail transition is `24 + 9*nargs` bytes
#     (`nc_tap_tail_len`, :20304-20308), so a 2-ary probe would have understated
#     every barrier by one copied-argument load/store pair. `base` is carried AND
#     used (it is 0, so no answer changes), never a dead parameter.
#   * Also matched: the op-45 read, the op-53 write-then-TEMT-drain, the
#     hi*256+lo index assembly, the tail-call recursion, the frame discipline.
#
# So t_fill and t_serve here are LOWER BOUNDS. The omitted ops are single
# instructions with no device access; the smallest barrier this leg measured is
# 85 us (QEMU-TCG, --quickack) and the largest 46.8 ms (Bochs, default
# transport). Against 46.8 ms the omission is nothing; against 85 us a TCG
# softMMU gather that misses is a real fraction of the barrier. The bound is
# tight on the SLOW transports only, and no report from this leg may say
# otherwise.
#
# ONE image serves every measurement. The counts N and Q are LATE-BOUND (four
# handshake bytes, each echoed before any payload is sent), so the burst ladder,
# both K-sweeps and the full session all run the SAME bytes -- one golden, one
# Bochs disk build, and no rung can be a different program than another.
#
# A11, stated as it actually works: every boot appends its own record
# IMMEDIATELY; the cross-engine comparison happens in --analyze, over the
# records, and IT is what must be read before any number goes into a document.
# The guest-produced CPU-visible value in a record is the debugcon FRAME BYTE.
# `graded_got` beside it is the HOST's own checksum -- identical on every engine
# by construction -- so it is not a cross-engine check and is not counted as one.
# The echo stream is not stored in the TSV: it is compared byte-for-byte IN
# FLIGHT by the feeder, and `ok=1` is the record of that comparison.
#
#   usage: run_meas_n.sh [--substrates "tcg kvm bochs"] [--phases "bare burst shape session"]
#                        [--reps N] [--bochs-reps N] [--shape-reps N]
#                        [--out DIR] [--seed S] [--no-quickack]
#
# --reps is the BURST ladder repetition count (default 10: the largest B that is
# clean 10/10 is B_MAX). --shape-reps is the K-sweep and session count (default
# 3). --bochs-reps replaces --reps on Bochs only, because a Bochs boot is ~50x a
# QEMU boot in wall clock; the substitution is recorded in the summary, never
# silent.
#
# TRANSPORT. TCP_QUICKACK is ON BY DEFAULT (parent ruling, 2026-09-03): the
# answer byte of a query barrier is the only guest->host byte with no host->guest
# byte in front of it, so without it the peer's delayed ACK adds ~41 ms to EVERY
# barrier and a gate would spend its budget measuring the host's ACK policy
# instead of the guest. That is the ADOPTED transport, and the one the link's
# gate inherits. --no-quickack restores the RAW transport -- what the landed
# gates use today -- which is how this leg measures the artefact itself. BOTH are
# measured and BOTH are reported; neither is allowed to stand alone.
#
# Every raw run appends one tab-separated record to $OUT/records.tsv; the summary
# is recomputed from that file, so the analysis can be re-run without re-booting.
set -u

script_dir="$(unset CDPATH; cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(unset CDPATH; cd "$script_dir/../.." && pwd)"
backend="$repo_root/stack/native_compile_fragment.herb"
feeder="$script_dir/kernel_io_feed.py"

if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
# Source the oracle BEFORE probing for any emulator: the QEMU_PREFIX knob lives
# in it, and a probe that runs first sees the unpinned PATH (the delta-findings
# item-1 class, herbert 7a45517).
if ! source "$script_dir/native_codegen_oracle.sh"; then
    echo "FAIL: bootstrap/tests/native_codegen_oracle.sh could not be sourced"; exit 1
fi

SUBSTRATES="tcg kvm bochs"
PHASES="bare burst shape session"
REPS=10
BOCHS_REPS=3
SHAPE_REPS=3
OUT=""
SEED=0
QUICKACK=""          # empty => the feeder's default, which is quickack ON
ANALYZE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --substrates) SUBSTRATES="$2"; shift 2 ;;
        --phases)     PHASES="$2"; shift 2 ;;
        --reps)       REPS="$2"; shift 2 ;;
        --bochs-reps) BOCHS_REPS="$2"; shift 2 ;;
        --shape-reps) SHAPE_REPS="$2"; shift 2 ;;
        --out)        OUT="$2"; shift 2 ;;
        --seed)       SEED="$2"; shift 2 ;;
        --quickack)    QUICKACK="--quickack"; shift ;;      # explicit; already the default
        --no-quickack) QUICKACK="--no-quickack"; shift ;;   # the RAW transport
        --analyze)    ANALYZE="$2"; shift 2 ;;
        *) echo "FAIL: unknown argument '$1'"; exit 1 ;;
    esac
done
if [[ -n "$ANALYZE" ]]; then
    python3 - "$ANALYZE" <<'PY'
import sys, statistics, csv

path = sys.argv[1]
rows = list(csv.DictReader(open(path), delimiter="\t"))
def f(x):
    try: return float(x)
    except (TypeError, ValueError): return None

subs = []
for r in rows:
    if r["substrate"] not in subs: subs.append(r["substrate"])

def total(r):
    a, b = f(r["t_launch"]), f(r["t_exit"])
    return None if a is None or b is None else b - a

def sel(sub, ph, N=None, Q=None):
    out = []
    for r in rows:
        if r["substrate"] != sub or r["phase"] != ph: continue
        if N is not None and int(r["N"]) != N: continue
        if Q is not None and int(r["Q"]) != Q: continue
        out.append(r)
    return out

def fit(pts):
    n = len(pts)
    sk = sum(k for k, _ in pts); st = sum(t for _, t in pts)
    skk = sum(k * k for k, _ in pts); skt = sum(k * t for k, t in pts)
    den = n * skk - sk * sk
    if den == 0: return None, None
    b = (n * skt - sk * st) / den
    return (st - b * sk) / n, b

print("=" * 78)
print("MEAS-N SUMMARY  (records: %s, %d runs)" % (path, len(rows)))
print("=" * 78)

# ---- A11. The ONLY guest-produced value in a record is the debugcon frame byte.
#      graded_got is the HOST's checksum -- identical on every engine by
#      construction -- so it is deliberately NOT part of the cross-engine tuple.
byshape = {}
for r in rows:
    if r["ok"] != "1": continue
    key = (r["phase"], r["N"], r["Q"], r["burst"], r["seed"])
    byshape.setdefault(key, {}).setdefault(r["substrate"], set()).add(r["frame"])
dis = 0; multi = 0
for key, d in sorted(byshape.items()):
    if len(d) < 2: continue
    multi += 1
    vals = set()
    for sub, vs in d.items(): vals |= vs
    if len(vals) != 1:
        dis += 1
        print("A11 DISAGREEMENT %s: %s" % (key, d))
print("A11 cross-engine on the GUEST-PRODUCED frame byte (same image, same seed):")
print("    %d shape(s) observed on >=2 engines, %d disagreement(s)" % (multi, dis))
bad = [r for r in rows if r["ok"] == "1" and r["graded_want"] and
       ("de%sad" % r["graded_want"]) != r["frame"]]
print("A11 guest frame vs the HOST-derived expectation: %d clean run(s) mismatched" % len(bad))
for r in bad[:5]:
    print("   %s %s N=%s Q=%s frame=%s want=de%sad" % (r["substrate"], r["phase"], r["N"], r["Q"], r["frame"], r["graded_want"]))
print("A11 note: the echo stream is not in the TSV; it is compared byte-for-byte")
print("    in flight by the feeder and ok=1 is the record of that comparison.")

coef = {}
for sub in subs:
    print("-" * 78)
    print("SUBSTRATE %s" % sub)
    br = sel(sub, "bare")
    if br:
        ts = [total(r) for r in br if r["ok"] == "1" and total(r) is not None]
        if ts:
            print("  (0) bare boot leg (N=0,Q=0): n=%d median=%.4fs min=%.4fs max=%.4fs"
                  % (len(ts), statistics.median(ts), min(ts), max(ts)))
    # ---- (1) the receive-burst ladder. A clean exhaustion is a FLOOR, not a maximum.
    rs = sel(sub, "burst")
    if rs:
        byB = {}
        for r in rs:
            reps = int(r["burstreps"]) or 1
            byB.setdefault(int(r["N"]) // reps, []).append((r["ok"] == "1", reps))
        bclean = 0; ladder = []; stopped = None
        for B in sorted(byB):
            e = byB[B]
            ladder.append("%d:%s(x%d)" % (B, "clean" if all(o for o, _ in e) else "DIRTY", e[0][1]))
            if all(o for o, _ in e): bclean = B
            else: stopped = B; break
        if stopped is None:
            print("  (1) B_clean >= %d  -- the ladder was EXHAUSTED clean; %d is the highest B tested," % (bclean, bclean))
            print("      not a measured maximum. Ladder: %s" % " ".join(ladder))
        else:
            print("  (1) B_clean = %d, first dirty rung B=%d. Ladder: %s" % (bclean, stopped, " ".join(ladder)))
        print("      Establishes: one host write of B bytes returns B order-exact echoes -- nothing lost.")
        print("      Does NOT establish: that the guest's one-byte RBR ever held two bytes at once")
        print("      (the emulated UART backpressures the socket). Emulator backpressure, not licence.")
    # ---- (2) the two shapes. Canon: fit on K <= top/4, hold out the top rung.
    for ph, label in (("fill", "t_fill"), ("query", "t_serve")):
        rs = [r for r in sel(sub, ph) if r["ok"] == "1" and total(r) is not None]
        if not rs: continue
        byK = {}
        for r in rs:
            K = int(r["N"]) if ph == "fill" else int(r["Q"])
            byK.setdefault(K, []).append(total(r))
        Ks = sorted(byK)
        med = [(K, statistics.median(byK[K])) for K in Ks]
        print("  (2) %s sweep: %s" % (ph, "  ".join("K=%d n=%d med=%.4fs" % (K, len(byK[K]), m) for K, m in med)))
        top = med[-1]
        fitpts = [(K, m) for K, m in med[:-1] if K * 4 <= top[0]]
        if len(fitpts) >= 2:
            a, b = fit(fitpts)
            pred = a + b * top[0]
            err = abs(pred - top[1]) / top[1] if top[1] else float("inf")
            coef[(sub, ph)] = (a, b)
            print("      fit on K<=%d (%d rungs, canon's K<=top/4): t_boot=%.4fs  %s=%.6fs/barrier"
                  % (fitpts[-1][0], len(fitpts), a, label, b))
            print("      HELD-OUT K=%d: predicted %.4fs, measured %.4fs, error %.2f%% -> %s"
                  % (top[0], pred, top[1], err * 100, "within 10%" if err <= 0.10 else "OUTSIDE 10%"))
            # Is the held-out test actually discriminating on this shape, or is it
            # passing because the intercept dominates? Report the share of the
            # held-out prediction the SLOPE contributes; a small share means the
            # test cannot identify the coefficient it exists to validate.
            share = (b * top[0]) / pred if pred else 0.0
            implied = (top[1] - a) / top[0] if top[0] else 0.0
            print("      slope share of the held-out prediction: %.1f%%; coefficient implied by the"
                  % (share * 100))
            print("      held-out point alone: %.6fs (%+.1f%% vs the fit)%s"
                  % (implied, (implied - b) / b * 100 if b else 0.0,
                     "  <-- the test does NOT identify this coefficient" if share < 0.5 else ""))
    # ---- (3) the rung ladder, measured
    print("  (3) rung ladder (whole-run wall clock, emulator launch -> exit):")
    base = None
    for pair in (("512", "64"), ("512", "56"), ("512", "48"), ("376", "76"), ("360", "78")):
        rs = [r for r in sel(sub, "session", N=int(pair[0]), Q=int(pair[1])) if r["ok"] == "1" and total(r) is not None]
        if not rs: continue
        ts = [total(r) for r in rs]
        m = statistics.median(ts)
        if base is None: base = m
        sends = int(pair[0]) + 2 * int(pair[1])
        line = "      N=%s Q=%-3s sends=%-4d n=%d median=%.3fs  (%.3fx the ratified rung)" % (
            pair[0], pair[1], sends, len(ts), m, m / base)
        cf, cq = coef.get((sub, "fill")), coef.get((sub, "query"))
        if cf and cq:
            line += "  [model %.3fs]" % (cf[0] + int(pair[0]) * cf[1] + int(pair[1]) * cq[1])
        print(line)
    allrs = [r for r in rows if r["substrate"] == sub]
    print("  runs=%d  clean=%d  not-clean=%d" % (len(allrs), sum(1 for r in allrs if r["ok"] == "1"),
                                                 sum(1 for r in allrs if r["ok"] != "1")))
    for r in allrs:
        if r["ok"] != "1":
            print("     NOT-CLEAN %s N=%s Q=%s burst=%s rep=%s seed=%s mismatch=%s"
                  % (r["phase"], r["N"], r["Q"], r["burst"], r["rep"], r["seed"], r["mismatch"]))
print("=" * 78)
PY
    exit $?
fi
[[ -n "$OUT" ]] || OUT="$(mktemp -d)"
mkdir -p "$OUT"
REC="$OUT/records.tsv"
[[ -f "$REC" ]] || printf 'substrate\tphase\tN\tQ\tburst\tburstreps\tseed\tquickack\trep\tok\tmismatch\tt_launch\tt_accept\tt_hs\tt_fill_end\tt_query_end\tt_exit\trc\tframe\tgraded_want\tgraded_got\tshutdown\n' > "$REC"

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm()  { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1

# ---------------- the probe: admitted ops only, late-bound N and Q ----------------
# fill/serve are tail self-calls (op-20 immediately followed by op-21, callee
# nparams == caller's), so nc_tap_is_tco lowers them to a jump and the stack is
# constant at every N and Q -- the guard page is never the thing being measured.
probe_src() {
cat <<'HERB'
-- emit: multiboot32-long64
func fill(base, i, n):
    if i == n: return 0 end
    let e = output_byte(base + input_byte())
    return fill(base, i + 1, n)
end
func serve(base, q, acc):
    if q == 0: return acc end
    let hi = input_byte()
    let e1 = output_byte(hi)
    let lo = input_byte()
    let e2 = output_byte(lo)
    let idx = hi * 256 + lo
    let a = output_byte(base + idx * 7 + 259)
    return serve(base, q - 1, acc + a)
end
func main():
    let nh = input_byte()
    let e4 = output_byte(nh)
    let nl = input_byte()
    let e5 = output_byte(nl)
    let qh = input_byte()
    let e6 = output_byte(qh)
    let ql = input_byte()
    let e7 = output_byte(ql)
    let b = 0
    let f = fill(b, 0, nh * 256 + nl)
    return serve(b, qh * 256 + ql, 0) * 4294967296
end
HERB
}

ELF="$OUT/meas_n_probe.elf"
compile_probe() {
    local cdir="$tmp/probe.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    probe_src > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        echo "FAIL: meas-n probe did not compile ($(head -1 "$cdir/err" 2>/dev/null))"; return 1
    fi
    cp "$cdir/a.out" "$ELF"
    echo "MEAS probe_sha256=$(sha256sum "$ELF" | cut -d' ' -f1)"
    echo "MEAS probe_bytes=$(stat -c%s "$ELF")"
    grub-file --is-x86-multiboot "$ELF" >/dev/null 2>&1 \
        || { echo "FAIL: meas-n probe is not x86-multiboot"; return 1; }
    local chx; chx=$(dd if="$ELF" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    echo "$chx" | grep -q '0f05' && { echo "FAIL: meas-n probe contains 0F05 syscall"; return 1; }
    echo "$chx" | grep -q 'cd80' && { echo "FAIL: meas-n probe contains CD80"; return 1; }
    echo "MEAS probe_static=OK (multiboot, no 0F05, no CD80)"
    return 0
}

# host-side oracle for the graded byte: the guest returns serve(...)*2^32, so the
# grading tail's `shr rax,0x20` puts (sum of the FULL op-53 return values) & 0xff
# in al -- the debugcon frame byte and, on QEMU, the isa-debug-exit code.
graded_want() { # N Q seed -> "framebyte_hex rc"
    python3 - "$1" "$2" "$3" <<'PY'
import random, sys
N, Q, seed = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
rng = random.Random(seed)
for _ in range(N): rng.randrange(256)
acc = sum(rng.randrange(65536) * 7 + 259 for _ in range(Q))
g = acc & 0xFF
print("%02x %d" % (g, (((g ^ 0x31) & 0x7F) << 1) | 1))
PY
}

RUN_SEED=0
RUN_BURSTREPS=1
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
feeder_wait() { local log="$1" i; for i in $(seq 1 200); do grep -q LISTENING "$log" && return 0; grep -q NOCONN "$log" && return 1; sleep 0.05; done; return 1; }
fval() { grep -m1 "^$2 " "$1" 2>/dev/null | awk '{print $2}'; }

emit_record() { # substrate phase N Q burst rep W rc frame want_frame shutdown
    local sub="$1" ph="$2" N="$3" Q="$4" bu="$5" rep="$6" W="$7" rc="$8" frame="$9" wantf="${10}" sd="${11}"
    local sline; sline=$(grep -m1 '^SERVE ' "$W/feed.log" 2>/dev/null)
    local ok mm
    ok=$(sed -n 's/.* ok=\([0-9]*\) .*/\1/p' <<<"$sline"); ok="${ok:-0}"
    mm=$(sed -n 's/.* mismatch=\([^ ]*\) .*/\1/p' <<<"$sline"); mm="${mm:-NOSERVE}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sub" "$ph" "$N" "$Q" "$bu" "$RUN_BURSTREPS" "$RUN_SEED" \
        "$(sed -n 's/.* quickack=\([0-9]*\) .*/\1/p' <<<"$sline")" "$rep" "$ok" "$mm" \
        "$(cat "$W/t_launch")" "$(fval "$W/feed.log" T_ACCEPT)" "$(fval "$W/feed.log" T_HS)" \
        "$(fval "$W/feed.log" T_FILL_END)" "$(fval "$W/feed.log" T_QUERY_END)" "$(cat "$W/t_exit")" \
        "$rc" "${frame:-NONE}" "$wantf" "$(sed -n 's/.* graded=\([0-9a-f]*\).*/\1/p' <<<"$sline")" "$sd" >> "$REC"
}

qemu_run() { # phase N Q burst rep kvm
    local ph="$1" N="$2" Q="$3" bu="$4" rep="$5" kvm="${6:-}"
    local sub="tcg"; [[ -n "$kvm" ]] && sub="kvm"
    local W="$tmp/run"; rm -rf "$W"; mkdir -p "$W"
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local port; port=$(free_port)
    local bflag=(); [[ "$bu" == "1" ]] && bflag=(--burst)
    python3 "$feeder" "$port" --serve "$N:$Q" --seed "$RUN_SEED" --burst-reps "$RUN_BURSTREPS" \
        ${bflag[@]+"${bflag[@]}"} $QUICKACK \
        --echo-timeout 60 --cap "$W/cap.bin" > "$W/feed.log" 2>&1 &
    local fp=$!
    feeder_wait "$W/feed.log" || { echo "HARNESS: $sub $ph N=$N Q=$Q rep=$rep -- feeder never LISTENING"; kill "$fp" 2>/dev/null; return 2; }
    date +%s.%N > "$W/t_launch"
    timeout 600 qemu-system-x86_64 -kernel "$ELF" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none "${acc[@]}" -m 64M
    local rc=$?
    date +%s.%N > "$W/t_exit"
    wait "$fp" 2>/dev/null
    local frame; frame=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    local gw; gw=$(graded_want "$N" "$Q" "$RUN_SEED")
    emit_record "$sub" "$ph" "$N" "$Q" "$bu" "$rep" "$W" "$rc" "$frame" "${gw%% *}" "-"
    return 0
}

BOCHS_DISK=""
bochs_build_disk() {
    local W="$tmp/bdisk"; rm -rf "$W"; mkdir -p "$W"
    local t0 t1; t0=$(date +%s.%N)
    ( set -e; cd "$W"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$ELF" mnt/boot/kernel.elf
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP" ) || { echo "HARNESS: bochs disk build failed"; return 1; }
    t1=$(date +%s.%N)
    BOCHS_DISK="$W/disk.img"
    python3 -c "print('MEAS bochs_disk_build_s=%.3f' % ($t1 - $t0))" | tee -a "$META"
    return 0
}

bochs_run() { # phase N Q burst rep kill_s
    local ph="$1" N="$2" Q="$3" bu="$4" rep="$5" kill_s="${6:-300}"
    local W="$tmp/run"; rm -rf "$W"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then echo "HARNESS: bochs BIOS/VGABIOS missing"; return 2; fi
    local port; port=$(free_port)
    local bflag=(); [[ "$bu" == "1" ]] && bflag=(--burst)
    python3 "$feeder" "$port" --serve "$N:$Q" --seed "$RUN_SEED" --burst-reps "$RUN_BURSTREPS" \
        ${bflag[@]+"${bflag[@]}"} $QUICKACK \
        --echo-timeout 120 --cap "$W/cap.bin" > "$W/feed.log" 2>&1 &
    local fp=$!
    feeder_wait "$W/feed.log" || { echo "HARNESS: bochs $ph N=$N Q=$Q rep=$rep -- feeder never LISTENING"; kill "$fp" 2>/dev/null; return 2; }
    ( cd "$W"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=$BOCHS_DISK, mode=flat
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port
port_e9_hack: enabled=1
display_library: x
panic: action=report
log: bochs_log.txt
BX
      date +%s.%N > t_launch
      xvfb-run -a bash -c "yes c | timeout -s KILL $kill_s bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1
      date +%s.%N > t_exit )
    local di; for di in $(seq 1 50); do kill -0 "$fp" 2>/dev/null || break; sleep 0.1; done
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    local sd; sd=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null)
    local frame; frame=$(hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" 2>/dev/null | grep -o 'de..ad' | head -1)
    local gw; gw=$(graded_want "$N" "$Q" "$RUN_SEED")
    # F2/F4 taxonomy: never-LISTENING or never-shutdown is HARNESS, not a number.
    if [[ "${sd:-0}" -lt 1 ]]; then
        echo "HARNESS: bochs $ph N=$N Q=$Q rep=$rep -- boot never reached shutdown (sd=$sd)"
        emit_record bochs "$ph" "$N" "$Q" "$bu" "$rep" "$W" "-" "$frame" "${gw%% *}" "${sd:-0}"
        return 2
    fi
    emit_record bochs "$ph" "$N" "$Q" "$bu" "$rep" "$W" "-" "$frame" "${gw%% *}" "$sd"
    return 0
}

run_one() { # substrate phase N Q burst rep
    # A distinct seed per (phase, N, Q, rep): repeating one payload proves only
    # that ONE payload survives. Deterministic, so any run is reproducible from
    # the seed printed in its record.
    RUN_SEED=$(( (SEED * 1000003 + $6 * 7919 + $3 * 31 + $4 * 17 + ${#2} * 13) % 2147483647 ))
    case "$1" in
        tcg)   qemu_run "$2" "$3" "$4" "$5" "$6" ;;
        kvm)   qemu_run "$2" "$3" "$4" "$5" "$6" kvm ;;
        bochs) bochs_run "$2" "$3" "$4" "$5" "$6" ;;
    esac
}

# ============================ run ============================
compile_probe || exit 1

ACTIVE=""
for s in $SUBSTRATES; do
    case "$s" in
        tcg)   have_qemu  && ACTIVE="$ACTIVE tcg"   || echo "SKIP tcg: no qemu-system-x86_64" ;;
        kvm)   have_kvm   && ACTIVE="$ACTIVE kvm"   || echo "SKIP kvm: /dev/kvm not usable" ;;
        bochs) have_bochs && ACTIVE="$ACTIVE bochs" || echo "SKIP bochs: bochs/parted/grub-install/xvfb-run/sudo -n missing" ;;
    esac
done
# Everything a reader needs to price the numbers goes into a FILE beside the
# records, not only onto a transient stdout: the emulator identities, the disk
# build cost, and the terms that sit OUTSIDE the timed window.
META="$OUT/meta.txt"
{
  echo "MEAS substrates_active=$(echo $ACTIVE | tr ' ' ',')"
  echo "MEAS qemu=$(qemu-system-x86_64 --version 2>/dev/null | head -1)"
  echo "MEAS bochs=$(bochs -q --help 2>&1 | grep -o 'Bochs x86 Emulator [0-9.]*' | head -1)"
  echo "MEAS qemu_path=$(command -v qemu-system-x86_64)"
  echo "MEAS transport=$([[ "$QUICKACK" == "--no-quickack" ]] && echo "RAW (no TCP_QUICKACK -- the artefact)" || echo "ADOPTED (TCP_QUICKACK on, the default)")"
  echo "MEAS probe_sha256=$(sha256sum "$ELF" | cut -d' ' -f1)"
  echo "MEAS timed_window=emulator-launch..emulator-exit ONLY -- probe compile (once per invocation), Bochs disk build, feeder setup, post-exit drain and grading are OUTSIDE it and are recorded separately"
  echo "MEAS leg_start=$(date -Is)"
} | tee -a "$META"   # -a: one block per invocation, so a leg split across
                     # several invocations keeps every block instead of the last

BURST_LADDER="1 2 4 8 16 32 64 128 256 512 1024 2048 4096"
FILL_K="64 128 256 512 1024"
QUERY_K_FAST="64 128 256 512 1024"
QUERY_K_BOCHS="16 32 64 128 256"
# The derivation seat's ladder, EVERY rung (`SCOPE-FINAL.md:126-132`, which
# renumbers `SCOPE-R3.md:118-128` and adds (512,56); the rung VALUES are
# unchanged). The floor is (360,78) at 516 sends -- NOT (512,48). SCOPE-FINAL's
# STOP rule is explicitly two-part: "(a) sends >= 516 with both columns clearing
# 2^-40, and (b) SC10's cost test", and it says outright that "sends are not the
# cost under a two-coefficient model". Part (b) is what this leg answers, so every
# rung is BOOTED rather than interpolated from the fit.
SESSION_PAIRS="512:64 512:56 512:48 376:76 360:78"

for sub in $ACTIVE; do
    reps="$REPS"; [[ "$sub" == "bochs" ]] && reps="$BOCHS_REPS"
    if [[ "$sub" == "bochs" ]]; then bochs_build_disk || continue; fi

    for ph in $PHASES; do
      case "$ph" in
        burst)
            # ONE BOOT PER RUNG: all $reps repetitions of a rung run inside a
            # single boot as $reps successive back-to-back sub-bursts of B bytes
            # (SCOPE-R3.md:323 -- "the ladder is 13 boots per substrate, not up
            # to 260"). Each sub-burst is verified order-exact on its own.
            echo "== $sub burst ladder ($reps repetition(s) per rung, ONE boot per rung) =="
            RUN_BURSTREPS="$reps"
            for B in $BURST_LADDER; do
                clean=1
                run_one "$sub" burst $((B * reps)) 0 1 1 || clean=0
                if [[ "$clean" -eq 1 ]]; then
                    tail -1 "$REC" | awk -F'\t' '$10 != 1 {exit 1}' || clean=0
                fi
                if [[ "$clean" -eq 1 ]]; then
                    echo "MEAS burst.$sub.B=$B ALL_CLEAN over $reps repetition(s) in 1 boot"
                else
                    echo "MEAS burst.$sub.B=$B NOT_CLEAN within $reps repetition(s)"
                fi
                [[ "$clean" -eq 1 ]] || { echo "MEAS burst.$sub.stopped_at=$B"; break; }
            done
            RUN_BURSTREPS=1 ;;
        shape)
            echo "== $sub fill sweep (reps=$SHAPE_REPS) =="
            for K in $FILL_K; do
                for r in $(seq 1 "$SHAPE_REPS"); do run_one "$sub" fill "$K" 0 0 "$r" || break; done
            done
            qk_ladder="$QUERY_K_FAST"
            if [[ "$sub" == "bochs" ]]; then
                qk_ladder="$QUERY_K_BOCHS"
                echo "MEAS query_ladder.bochs=$(echo $qk_ladder | tr ' ' ',') (reduced from $(echo $QUERY_K_FAST | tr ' ' ',') on wall clock; the 4x fit:predict ratio is preserved)"
            fi
            echo "== $sub query sweep (reps=$SHAPE_REPS) =="
            for K in $qk_ladder; do
                for r in $(seq 1 "$SHAPE_REPS"); do run_one "$sub" query 0 "$K" 0 "$r" || break; done
            done ;;
        bare)
            # The per-boot leg cost by itself (N=0, Q=0): handshake only, no fill,
            # no queries. SCOPE-R3 asks for this by name alongside the disk build;
            # it is also what the three boundary probes will cost, since they carry
            # no fill and no queries.
            echo "== $sub bare boot (reps=$SHAPE_REPS) =="
            for r in $(seq 1 "$SHAPE_REPS"); do run_one "$sub" bare 0 0 0 "$r" || break; done ;;
        session)
            echo "== $sub session pairs (reps=$SHAPE_REPS) =="
            for pair in $SESSION_PAIRS; do
                N="${pair%%:*}"; Q="${pair##*:}"
                for r in $(seq 1 "$SHAPE_REPS"); do run_one "$sub" session "$N" "$Q" 0 "$r" || break; done
            done ;;
      esac
    done
done

{ echo "MEAS leg_end=$(date -Is)"; echo "MEAS records=$REC"; } | tee -a "$META"
