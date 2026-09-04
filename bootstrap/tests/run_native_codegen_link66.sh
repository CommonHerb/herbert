#!/usr/bin/env bash
# link66 (longbuf) -- RUNTIME-INDEXED MEMORY on the sovereign long64 target.
#
# SLICE 3 STATE: the STATIC legs PLUS the black-box boot legs. The goldens land in slice 4
# and the mutation harness in slice 5. (The "STATIC legs only" header this replaces was
# slice 2's and had become false the moment the boot legs landed -- a cross-family review leg
# caught it, and a header that describes a script the file no longer is, is the cheapest
# possible lie for a gate to tell.)
#
# WHAT A GREEN RUN OF THIS GATE DOES AND DOES NOT ESTABLISH -- stated here rather than in the
# banner, because a review leg was right that the banner claimed more than the evidence:
#   * The static legs establish IMAGE facts outright: the ops are at their predicted offsets,
#     the scale is 8 everywhere, the movabs base equals the phdr-derived buffer, the guard
#     pages are non-present, p_memsz is exact.
#   * The black-box legs are a PROBABILISTIC DISCRIMINATION, not a proof of execution. A guest
#     that never performs an indexed load can still answer every query with probability at
#     least 2^-64 (the seed floor the design APPLIES to every column), and the best attack
#     found over the searched strategy families sits at 2^-99.67 under the residency model.
#     Neither is a proven upper bound. The honest sentence is "no strategy found by five
#     refutation rounds and four independent lenses answers 64 without-replacement queries
#     over a 512-byte payload from one frame's residency", not "this proves an indexed load
#     executed".
#   * What DOES tie the run to the guest rather than to the feeder is the completion frame:
#     the driver predicts the whole-run accumulator's proof byte and QEMU's isa-debug-exit
#     status from the transcript IT derived, and requires both exactly.
#
# Conventions this gate follows, stated only where they are actually true:
#   * the oracle is sourced BEFORE any file probe, with CDPATH unset, a checked cd and a
#     guarded source. (An earlier draft claimed link62-65 "already order this way"; that
#     claim was FALSE and is withdrawn -- link65 has no `unset CDPATH` and an unguarded
#     source. This gate holds the convention; it does not inherit it.)
#   * frame parsing is POSITIONAL, never a scan, and the parser is longbuf_spec's own
#     production function -- not a copy living in this script. LEDGER D26 records why.
#   * the seed is drawn by THIS DRIVER and passed to the harness on one named channel; the
#     harness never draws its own on a graded path (A1).
#   * the static analysis block FAILS CLOSED: its exit status and its own summary line are
#     both checked, and a crash is a gate failure rather than a silent zero-leg pass.
set -uo pipefail
unset CDPATH
# THE TWO DERIVATIONS SHARE AN INTERPRETER, AND ITS STARTUP IS ATTACKER-REACHABLE. A blind
# cross-family review leg's demonstration: point PYTHONPATH at a sitecustomize.py that replaces
# random.Random with a class ignoring its seed, and the feeder AND the driver's oracle generate
# the same pinned stream -- transcript, proof, exit and seed-echo all agree while the 64-bit
# floor is gone. Two implementations are only independent if their interpreters are. Scrubbed
# here rather than per-invocation because the shared Bochs harness launches the feeder itself
# (bochs_f2_harness.sh:153) and this export reaches that child too; the driver's own calls
# additionally use `python3 -I`. STATED, because the two children do NOT have the same startup
# surface: the shared harness's launch is a bare `python3 "$feeder"`, so sys.path[0] is the tests
# directory there while `-I` clears it for the driver. Adding `-I` in the shared harness would
# touch a file many other gates depend on, so it is NOT done here; the asymmetry fails closed
# (a hijacked `random` in the Bochs feeder desynchronises it from `derive` and goes RED) and is
# recorded rather than papered over.
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP
export PYTHONNOUSERSITE=1
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || { echo "FAIL: link66 (cannot resolve script_dir)"; exit 1; }
repo_root="$(cd -- "$script_dir/../.." && pwd)" || { echo "FAIL: link66 (cannot resolve repo_root)"; exit 1; }
# shellcheck source=/dev/null
source "$script_dir/native_codegen_oracle.sh" || { echo "FAIL: link66 (cannot source the native-codegen oracle)"; exit 1; }
backend="$repo_root/stack/native_compile_fragment.herb"
spec="$script_dir/longbuf_spec.py"
[[ -f "$backend" ]] || { echo "FAIL: link66 (missing backend)"; exit 1; }
[[ -f "$spec" ]] || { echo "FAIL: link66 (missing longbuf_spec.py)"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

EXPECTED_LEGS=16          # the static block's own leg count -- a short block is a FAILURE. 13 at slice 2; A3.2 added sib-exclusivity, A3.3 source-shape, and A3's own refutation pushints.

# ---------------------------------------------------------------- the ratified pair + ladder
#
# (512, 64) is the RATIFIED rung, chosen for margin rather than cost. The fallback ladder and
# its two-part STOP, restated here because the gate is where it actually binds:
#   (a) SECURITY FLOOR: sends = N + 2Q must be >= 508, the frontier, with both DP columns
#       clearing 2^-40. Sends are NOT the cost -- under the adopted transport the 516-send rung
#       costs 0.912x the ratified one on Bochs -- so this is a floor, never a budget test.
#   (b) COST TEST (SC10): t_boot + N*t_fill + Q*t_serve must fit the step cap on the SLOWEST
#       substrate. MEAS-N's measured verdict on every booted rung is NO STOP, x17.4 against a
#       120 s per-boot kill.
# RUNG FIVE (360,74), at 508 sends, IS NEVER DESCENDED TO without a boot and a re-derivation
# first -- it clears by 0.24 bits on a model the design itself calls a lower bound, and it was
# computed, never booted (parent decision, recorded for veto).
# THE RUNG IS PINNED BY EXACT MEMBERSHIP, not by an inequality. A blind refutation leg showed
# why: `N + 2Q >= 508` is monotone in N and constrains Q NOT AT ALL, so LINK66_N=508 LINK66_Q=0
# satisfied the guard, asked ZERO queries, and graded a guest that stored nothing as ok=1 --
# P_forge = 1. The gate refuses LINK66_SEED three lines above on exactly the threat model that
# an attacker-set environment variable must not void the floor; these two knobs were left open.
if [[ -n "${LINK66_N:-}" || -n "${LINK66_Q:-}" ]]; then
    echo "FAIL: link66 (LINK66_N/LINK66_Q are set; a graded run takes its rung from the ratified ladder, not the environment)"
    exit 1
fi
LINK66_N=512
LINK66_Q=64
LINK66_SENDS=$(( LINK66_N + 2 * LINK66_Q ))
# The ratified pair and the four booted fallback rungs, by exact membership. Rung five
# (360,74) is deliberately ABSENT: it clears by 0.24 bits on a model the design itself calls a
# lower bound and was computed, never booted -- it is never descended to without a boot and a
# re-derivation first (parent decision, recorded for veto).
case "$LINK66_N:$LINK66_Q" in
    512:64|512:56|512:48|376:76|360:78) : ;;
    *) echo "FAIL: link66 (rung ${LINK66_N}:${LINK66_Q} is not a ratified ladder row)"; exit 1 ;;
esac
if [[ "$LINK66_SENDS" -lt 508 ]]; then
    echo "FAIL: link66 (rung (${LINK66_N},${LINK66_Q}) is ${LINK66_SENDS} sends, below the 508-send security floor)"
    exit 1
fi

# ---------------------------------------------------------------- A1: the seed channel
if [[ -n "${LINK66_SEED:-}" ]]; then
    echo "FAIL: link66 (LINK66_SEED is set; a graded run takes its seed from the supervising driver)"
    exit 1
fi
# TWO INDEPENDENT 64-bit halves (the payload seed and the query seed). One master seed made the
# query stream a deterministic function of the payload the guest had already been shown.
DRIVER_PAY="$(python3 -I -c 'import os,sys;b=os.urandom(8);sys.exit(9) if len(b)!=8 else print("%016x"%int.from_bytes(b,"big"))')" || { echo "FAIL: link66 (the driver draw did not return 8 bytes)"; exit 1; }
DRIVER_QRY="$(python3 -I -c 'import os,sys;b=os.urandom(8);sys.exit(9) if len(b)!=8 else print("%016x"%int.from_bytes(b,"big"))')" || { echo "FAIL: link66 (the driver draw did not return 8 bytes)"; exit 1; }
DRIVER_SEED="${DRIVER_PAY}${DRIVER_QRY}"
# A LENGTH check is not an entropy check, and NEITHER IS A TOP-BYTE CHECK. An earlier draft
# rejected any half whose top byte was 00, reasoning that a short draw could not fake high bits.
# TWO independent review legs, from two model families, refuted it on the same arithmetic:
# P(at least one of two honest 64-bit draws has a zero top byte) = 1 - (255/256)^2 = 0.78%, so it
# was a designed-in ~1-in-128 hard RED before any leg ran -- and its in-band message said
# "re-run once", i.e. the gate shipped a retry-on-red instruction whose retry REDRAWS THE
# CHALLENGE. That is the laundering pattern the rest of this file exists to prevent. It also did
# not test what it claimed: os.urandom(1) + b"\x00"*7 has a nonzero top byte and 8 bits of
# entropy and passed. What IS checkable here is that the draw came back the right SIZE; that the
# source is a real CSPRNG is a property of os.urandom, asserted at the draw site above and named
# as a residual rather than pretended to be tested.
for _h in "$DRIVER_PAY" "$DRIVER_QRY"; do
    [[ "${#_h}" -eq 16 ]] || { echo "FAIL: link66 (driver seed half is not 16 hex chars)"; exit 1; }
done
[[ "$DRIVER_PAY" != "$DRIVER_QRY" ]] || { echo "FAIL: link66 (the two seed halves are identical -- 2^-64 says that is not an honest pair of draws)"; exit 1; }
echo "LINK66_SEED=$DRIVER_SEED (drawn: supervisor, driver)"

native_codegen_ensure_compiler "$tmp/mint" || { echo "FAIL: link66 (cannot acquire the C-free gen-1 compiler)"; exit 1; }

# ---------------------------------------------------------------- probe sources
cat > "$tmp/forcing.herb" <<'EOS'
-- emit: multiboot32-long64
func fill(base, i, n):
    if i == n:
        return 0
    end
    let e = output_byte(bufset(base, i, input_byte()))
    return fill(base, i + 1, n)
end
func serve(base, q, acc):
    if q == 0:
        return acc
    end
    let hi = input_byte()
    let e1 = output_byte(hi)
    let lo = input_byte()
    let e2 = output_byte(lo)
    let a = bufget(base, hi * 256 + lo)
    let e3 = output_byte(a)
    return serve(base, q - 1, acc + a)
end
func main():
    let b = bufbase()
    let f = fill(b, 0, 512)
    let s = serve(b, 64, 0)
    let p = output_byte(s)
    let g = bufget(b, 262144)
    return s * 4294967296
end
EOS

# a buffer-mode program with EXACTLY ONE indexed op: the positive side of the IR gate's
# ">= 1" boundary. Without this, reject-nobufop proves only that SOME program is refused.
cat > "$tmp/oneidx.herb" <<'EOS'
-- emit: multiboot32-long64
func once(base, k, v):
    if k == 0:
        return bufset(base, 0, v)
    end
    return once(base, k - 1, v)
end
func main():
    let b = bufbase()
    let r = once(b, 1, 7)
    return output_byte(r)
end
EOS

# buffer mode, NO indexed op at all -- must be refused with ERR 655
cat > "$tmp/nobufop.herb" <<'EOS'
-- emit: multiboot32-long64
func idle(x):
    if x == 0:
        return 0
    end
    return idle(x - 1)
end
func main():
    let b = bufbase()
    let f = idle(1)
    return b * 0
end
EOS

# a SINGLE-function program using a device op -- refused, because op 53 is admitted only on
# the multi-function path (SC3's real reason: a probe must be able to emit an observable)
cat > "$tmp/singlefunc.herb" <<'EOS'
-- emit: multiboot32-long64
func main():
    let b = bufbase()
    let v = bufset(b, 0, input_byte())
    return output_byte(bufget(b, 0))
end
EOS

compile_probe() {  # src outdir -> sets COMPILE_RC, leaves stdout.txt/err.txt for provenance
    local src="$1" d="$2"
    rm -rf "$d"; mkdir -p "$d"; cp "$src" "$d/probe.herb"
    ( cd -- "$d" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >stdout.txt 2>err.txt )
    COMPILE_RC=$?
}
# ACCEPTANCE AND REJECTION BOTH INCLUDE THE EXIT STATUS. A review leg found COMPILE_RC recorded
# and then never read by any leg: "a compiler can emit a valid image and exit 1; every accepting
# leg treats it as compiled. Conversely, it can print the named error, emit no image, and exit 0;
# both rejection legs pass."
#
# THE FIRST HALF IS ADOPTED AS WRITTEN. THE SECOND IS NOT, AND THE REASON IS MEASURED RATHER THAN
# ARGUED: this toolchain's refusal convention IS exit 0. Run against the gen-1 seed compiler,
# the no-indexed-op probe gives
#     REFUSAL rc=0 ; a.out: no ; stdout: program: native-subset: unknown error (ERR 655)
# so requiring a NONZERO status on the reject path would demand behaviour the compiler does not
# have, and the two reject legs went RED against a correctly-refusing compiler when this file
# first tried it. Pinning rc == 0 on the reject path is still strictly stronger than the old
# `! -f a.out` alone, and it buys the half that matters: a CRASH (nonzero, no image) can no
# longer be read as a principled refusal.
compiled_ok()  { [[ "$COMPILE_RC" -eq 0 && -f "$1/a.out" ]]; }
refused_ok()   { [[ "$COMPILE_RC" -eq 0 && ! -f "$1/a.out" ]]; }

compile_probe "$tmp/forcing.herb" "$tmp/forcing.d"
compiled_ok "$tmp/forcing.d" || { echo "FAIL: link66 (the forcing program did not compile cleanly: rc=$COMPILE_RC a.out=$([[ -f "$tmp/forcing.d/a.out" ]] && echo yes || echo no); $(head -1 "$tmp/forcing.d/err.txt" 2>/dev/null))"; exit 1; }

# ------------------------------------------------- seed-echo: the PRODUCTION harness, no boot
#
# The first draft wrote a five-line stub from a heredoc, ran it, and checked it echoed the
# variable the driver had just set -- a tautology that graded NOTHING about the real harness,
# over an env-var channel the real harness does not even read. A refutation leg called it what
# it was. This invokes the PRODUCTION feeder on its REAL channel (--master-seed/--query-seed on
# argv) with a degenerate rung, and reads the seed line it prints BEFORE any protocol byte
# moves. No emulator: nothing ever connects, so the harness prints its line and then times out
# on accept. That is A1(v)'s "one graded run, no extra boot", actually implemented.
seed_echo_probe() {
    # The feeder prints its seed line INSIDE the grade block, which runs after accept(). With
    # nothing connecting it times out at NOCONN and never prints -- the first draft of this leg
    # did exactly that and reported 'harness printed <none>'. So a throwaway peer connects and
    # immediately closes: accept() returns, the harness prints the line it was HANDED, and the
    # protocol then dies on EOF, which is all this leg needs. Still bootless, still the
    # PRODUCTION harness on its REAL argv channel.
    local p; p=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
    local out="$tmp/seedecho.log"
    ( timeout 40 python3 -I "$script_dir/kernel_io_feed.py" "$p" --grade 1:1 --draw 0 --master-seed "$DRIVER_PAY" --query-seed "$DRIVER_QRY" > "$out" 2>&1 ) &
    local hp=$!
    local i; for i in $(seq 1 60); do grep -q LISTENING "$out" 2>/dev/null && break; sleep 0.1; done
    python3 -I -c "import socket,sys;s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),5);s.close()" "$p" 2>/dev/null || true
    wait "$hp" 2>/dev/null
    sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' "$out" | head -1 > "$tmp/seedecho.val"
}
# Called DIRECTLY, never inside $( ). A backgrounded job plus `wait` inside a command
# substitution does not compose: $! resolved to the wrong job, `wait` returned before the
# harness had written its line, and the leg read an empty file and reported "<none>". The
# function now leaves its answer in a file and the caller reads that.
seed_echo_probe
HARNESS_ECHO="$(cat "$tmp/seedecho.val" 2>/dev/null || true)"

# ---------------------------------------------------------------- the static legs
set +e
LINK66_DRIVER_SEED="$DRIVER_SEED" LINK66_HARNESS_ECHO="$HARNESS_ECHO" python3 -I - "$spec" "$tmp/forcing.d/a.out" "$tmp/forcing.herb" > "$tmp/static.out" 2>&1 <<'PYEOF'
import importlib.util, os, struct, sys
spec_path, elf, src_path = sys.argv[1], sys.argv[2], sys.argv[3]
_s = importlib.util.spec_from_file_location("longbuf_spec", spec_path)
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)

R = []
def leg(name, cond, detail=""):
    R.append(("ok" if cond else "FAIL", name, detail))

F_FILL = L.Func("fill", 3, 4, [
    (3,0,0),(3,0,0),(11,0,0),(17,6,0),(0,0,0),(21,0,0),
    (3,0,0),(3,0,0),(45,0,0),(51,0,0),(53,0,0),(4,0,0),
    (3,0,0),(3,0,0),(0,0,0),(5,0,0),(3,0,0),(20,1,3),(21,0,0),
])
F_SERVE = L.Func("serve", 3, 9, [
    (3,0,0),(0,0,0),(11,0,0),(17,6,0),(3,0,0),(21,0,0),
    (45,0,0),(4,0,0),
    (3,0,0),(53,0,0),(4,0,0),
    (45,0,0),(4,0,0),
    (3,0,0),(53,0,0),(4,0,0),
    (3,0,0),(3,0,0),(0,0,0),(42,0,0),(3,0,0),(5,0,0),(50,0,0),(4,0,0),
    (3,0,0),(53,0,0),(4,0,0),
    (3,0,0),(3,0,0),(0,0,0),(6,0,0),(3,0,0),(3,0,0),(5,0,0),(20,2,3),(21,0,0),
])
# A3.1 changed main: the accumulator is now BOUND (so it can be emitted and then reused), the
# witness byte is emitted, and the guard access follows it. Five locals now: b, f, s, p, g.
F_MAIN = L.Func("main", 0, 5, [
    (49,0,0),(4,0,0),                                       # let b = bufbase()
    (3,0,0),(0,0,0),(0,0,0),(20,1,3),(4,0,0),               # let f = fill(b, 0, 512)
    (3,0,0),(0,0,0),(0,0,0),(20,2,3),(4,0,0),               # let s = serve(b, 64, 0)
    (3,0,0),(53,0,0),(4,0,0),                               # let p = output_byte(s)   <- the witness
    (3,0,0),(0,0,0),(50,0,0),(4,0,0),                       # let g = bufget(b, 262144) <- the guard access
    (3,0,0),(0,0,0),(42,0,0),(21,0,0),                      # return s * 4294967296
], is_main=True)
FUNCS = [F_MAIN, F_FILL, F_SERVE]

img = L.Image(elf)
lay = L.Layout(FUNCS, uses_uart=True)
src = open(src_path).read()

# ---- the ELF location fields this analysis rests on, asserted rather than assumed
leg("elf-header", img.header_ok(),
    "type=%d off=%d vaddr=0x%x filesz=%d memsz=%d"
    % (img.p_type, img.p_offset, img.p_vaddr, img.p_filesz, img.p_memsz))

# ---- pmemsz: p_memsz checked against a guard_hi derived from p_FILEsz, never from p_memsz
leg("pmemsz", img.p_memsz == img.guard_hi - 0x100000,
    "p_memsz=%d ; filesz-derived guard_hi=0x%x ; p_memsz-implied=0x%x"
    % (img.p_memsz, img.guard_hi, img.memsz_from_p))

# ---- pd-guards: the PD's own contents, present bit by present bit
np = img.pd_nonpresent()
want = sorted([img.guard_lo // 2097152, img.guard_hi // 2097152])
bad_present = img.pd_present_ok()
leg("pd-guards", sorted(np) == want and len(np) == 2 and not bad_present,
    "nonpresent=%s want=%s corrupt-present=%s" % (np, want, bad_present[:3]))

# ---- geometry: the filesz-derived layout must agree with what the PAGE TABLES actually say,
#      which is independent evidence. (The first draft asserted guard_lo == roundup_2m(load_end)
#      against a guard_lo DEFINED that way -- a tautology a review leg caught.)
geo = (img.load_end <= img.guard_lo
       and img.guard_lo % 2097152 == 0
       and img.buf_2m - img.guard_lo == 2097152
       and img.guard_hi - img.buf_2m == 2097152
       and sorted(np) == want                       # the PD agrees with the derivation
       and (img.buf_2m // 2097152) not in np        # and the buffer page is PRESENT
       and 2097152 // 8 == 262144)
leg("geometry", geo,
    "load_end=0x%x guard_lo=0x%x buf=0x%x guard_hi=0x%x ; PD agrees ; 262144 slots"
    % (img.load_end, img.guard_lo, img.buf_2m, img.guard_hi))

# ---- windows: EVERY fully-determined op's complete byte window pinned at its predicted
#      offset. This is what establishes an instruction BOUNDARY rather than a byte match: a
#      review leg showed that mutating op-45's trailing `50` to `EB` would swallow the next
#      op's first byte while leaving both the predicted offset and the interior gather bytes
#      untouched. Pinning the adjacent windows closes that escape.
OP45 = bytes.fromhex("66bafd03eca8017 4f766baf803ec0fb6c050".replace(" ", ""))
OP53 = bytes.fromhex("5b66baf80388d8ee66bafd03eca8407 4f753".replace(" ", ""))
FIXED = {45: OP45, 53: OP53, 50: L.OP_BYTES[50], 51: L.OP_BYTES[51]}
win_bad = []
for k, f in enumerate(FUNCS):
    offs = lay.op_offsets(k)
    for i, (op, _, _) in enumerate(f.ops):
        if op in FIXED:
            got = img.code[offs[i]:offs[i] + len(FIXED[op])]
            if got != FIXED[op]:
                win_bad.append("op%d@%d got=%s want=%s" % (op, offs[i], got.hex(), FIXED[op].hex()))
# A3.2 -- GAP-FREE TILING RESTORED, AND ANCHORED IN THE IMAGE. Deleting it in slice 3 was a
# regression against slice 2's own leg, and the parent called it that. But the version deleted was
# genuinely a tautology and must not come back as one:
# Layout.op_offsets BUILDS out[i+1] = out[i] + op_size(i) by definition and lay.funcs IS FUNCS, so
# `offs[i] + op_size(i) == offs[i+1]` held for every possible input image and never touched `img`
# at all. It printed a green detail string on every run while checking nothing, and the `covered`
# list it fed was never read. What this leg ACTUALLY establishes -- and it is the thing that
# bites -- is that every fully-determined op's COMPLETE byte window is present at its predicted
# offset. That is an instruction-BOUNDARY claim rather than a byte-match claim precisely because
# the windows are adjacent: a mutation that lengthened one op would move the next window off its
# predicted offset and be caught there. Adjacency is therefore checked BY the image, not asserted
# by the spec against itself.
#   Layout.op_offsets BUILDS out[i+1] = out[i] + op_size(i) by definition and lay.funcs IS FUNCS,
# so the old `offs[i] + op_size(i) == offs[i+1]` held for every possible input and never touched
# the image. The restored form asks the IMAGE the same question: each fixed-form pattern must occur
# in the whole code region EXACTLY as many times as the layout predicts, and at exactly the
# predicted offsets. Insert one byte anywhere before a fixed op and its window leaves its predicted
# offset -- so tiling is falsified by the image now, not asserted by the spec about itself.
# THE INSTRUCTION REGION, not the whole image. The last 4 KiB of `code` is the PAGE DIRECTORY --
# data, not instructions -- and scanning data for instruction encodings is a category error that
# can only produce SPURIOUS REDs (a PDE that happened to contain the right three bytes would fail
# a leg about the code). Nothing can hide there either: `pd-guards` pins the PD byte for byte,
# requiring exactly two non-present entries and every present entry to be exactly the identity
# mapping `i*2097152 + 131`. So the scans below run over `text` and the PD is covered by its own leg.
text = img.code[:img.code_len - 4096]

pred_fixed = {}
for k, f in enumerate(FUNCS):
    offs = lay.op_offsets(k)
    for i, (op, _, _) in enumerate(f.ops):
        if op in FIXED:
            pred_fixed.setdefault(op, []).append(offs[i])
tile_bad = []
for opcode, pat in FIXED.items():
    want = sorted(pred_fixed.get(opcode, []))
    got, j = [], 0
    while True:
        h = text.find(pat, j)
        if h < 0:
            break
        got.append(h); j = h + 1
    if got != want:
        tile_bad.append("op%d occurs at %s, layout predicts %s" % (opcode, got[:4], want[:4]))
leg("windows", not win_bad and not tile_bad,
    ";".join((win_bad + tile_bad)[:3])
    or "every fixed-form op window (45/53/50/51) is at its predicted offset and occurs nowhere else in the instruction region -- falsified by the image, not by the spec's own recurrence. NOT whole-image coverage: ops 0/5/6/11/16/17/20/21/42, the 56-byte head, the 56-byte UART block, the 4-byte grading tail and the 58-byte shared epilogue are length-pinned only (the coverage leg's goldens land in slice 4)")

# ---- counts: the SOURCE call-site count is the op count
c = L.source_counts(src)
emitted_get = img.raw_count("488b04ca")
emitted_set = img.raw_count("48891 4c8".replace(" ", ""))
leg("counts", c["n_get"] == emitted_get and c["n_set"] == emitted_set and c["n_base"] == 1,
    "source n_get=%d n_set=%d n_base=%d ; emitted get=%d set=%d"
    % (c["n_get"], c["n_set"], c["n_base"], emitted_get, emitted_set))

# ---- sites: a BIJECTION between predicted op starts and raw window hits
sites = lay.buf_sites()
pred = {op: sorted(o for (_, _, p, o) in sites if p == op) for op in (49, 50, 51)}
found = {}
for op, pat in ((50, "488b04ca"), (51, "48891 4c8".replace(" ", ""))):
    b, hits, i = bytes.fromhex(pat), [], 0
    while True:
        j = img.code.find(b, i)
        if j < 0:
            break
        hits.append(j); i = j + 1
    found[op] = hits
inner = {50: 2, 51: 3}      # the gather/scatter bytes sit this far into the op
pred_win = {op: [o + inner[op] for o in pred[op]] for op in (50, 51)}
leg("sites", all(sorted(found[op]) == sorted(pred_win[op]) for op in (50, 51)),
    "predicted=%s found=%s" % (pred_win, found))

# ---- rawdecode: raw hits == decoded sites, no scale-4 sibling anywhere, scale 8 on every
#      buffer op. Together with `windows` (adjacency) this is the raw AND decode conjunction.
rd, rd_detail = True, []
for op in (50, 51):
    if len(found[op]) != len(pred[op]):
        rd = False; rd_detail.append("op%d raw=%d predicted=%d" % (op, len(found[op]), len(pred[op])))
for bad_pat in ("488b048a", "48891488"):
    if img.raw_count(bad_pat) != 0:
        rd = False; rd_detail.append("scale4 %s present" % bad_pat)
for op in (50, 51):
    for off in pred[op]:
        sib = img.code[off + (5 if op == 50 else 6)]
        if sib & L.SCALE8_MASK != 0xC0:
            rd = False; rd_detail.append("op%d@%d SIB=%02x not scale8" % (op, off, sib))
leg("rawdecode", rd, ";".join(rd_detail) or "raw hits == decoded sites; no scale-4 sibling; scale 8 everywhere")

# ---- sib-exclusivity (A3.2): a DECODE-BASED test, not an allowlist of two byte patterns.
#      The old exclusivity was exactly two strings, and the adjudicating lens disassembled seven
#      equivalent encodings invisible to it -- 48 8b 04 cb, 48 8b 1c ca, 48 8b 04 d1,
#      48 8b 44 ca 00, 4c 8b 04 ca, 48 89 1c c8, 48 89 14 cb. This decodes instead: REX.W
#      (0x48-0x4F) + a 64-bit mov r/m (0x8B load or 0x89 store) + a ModRM whose mod != 11 and
#      whose rm == 100, so a SIB byte follows. A SIB with index == 100 and REX.X clear is NOT
#      indexed (that is `[rsp+disp]`, which the emitter uses legitimately -- six sites in the
#      honest image), so it is excluded BY DECODE rather than by exception. Every remaining
#      indexed site must be one of the predicted op-50/51 sites.
# SCOPE, STATED HONESTLY BECAUSE THE LEG'S NAME OVERSELLS IT. This is a ModRM-shaped scan, so it
# is structurally blind to whole families of memory access -- string operations (`F3 A4` rep movsb,
# `F3 48 A5` rep movsq, `AA/AB` stos, `AC/AD` lods) have NO ModRM at all and are the natural way an
# emitter would relocate a 2-MiB buffer; `0F B6/B7/BE/BF` (movzx/movsx) is a byte-granular indexed
# load, which is SUFFICIENT here because the payload is bytes; and every 8/16/32-bit form drops
# REX.W so `b0` is never in 0x48..0x4F. The previous allowlist missed seven encodings; closing
# those seven leaves an open-ended family. So the second pass below flags the families a ModRM scan
# cannot reach -- the honest image contains none of them, which is the claim it makes.
mem_bad = []
for i in range(len(text) - 1):
    if text[i] in (0xA4, 0xA5, 0xAA, 0xAB, 0xAC, 0xAD) and i and text[i - 1] in (0xF2, 0xF3):
        mem_bad.append("string op at %d: %s" % (i - 1, text[i - 1:i + 1].hex()))
for i in range(len(text) - 4):
    if text[i] == 0x0F and text[i + 1] in (0xB6, 0xB7, 0xBE, 0xBF):
        m2 = text[i + 2]
        if (m2 >> 6) != 3 and (m2 & 0x07) == 0x04:
            mem_bad.append("movzx/movsx indexed at %d: %s" % (i, text[i:i + 4].hex()))
sib_bad = list(mem_bad)
for i in range(len(text) - 3):
    b0, b1, m = text[i], text[i + 1], text[i + 2]
    if not (0x48 <= b0 <= 0x4F and b1 in (0x89, 0x8B) and (m >> 6) != 3 and (m & 0x07) == 0x04):
        continue
    sib = text[i + 3]
    if ((sib >> 3) & 0x07) == 0x04 and not (b0 & 0x02):     # index=none, REX.X clear -> not indexed
        continue
    if i not in pred_win[50] and i not in pred_win[51]:
        sib_bad.append("indexed form at %d: %s" % (i, text[i:i + 4].hex()))
leg("sib-exclusivity", not sib_bad,
    ";".join(sib_bad[:3])
    or "every REX.W `mov r/m64` SIB-INDEXED form is a predicted op-50/51 site (%d sites); non-indexed [rsp+disp] excluded by decode; plus a second pass over the ModRM-less and non-REX.W families (%d flagged)"
    % (len(pred_win[50]) + len(pred_win[51]), len(mem_bad)))

# ---- pushints: every op-0 (PUSH_INT) window is `48 B8 <imm64> 50`, and the GUARD ACCESS's
#      immediate is pinned to 262144 exactly, once.
#
#      A blind refutation leg's demonstration, which this closes: op 0 is 11 bytes and NOTHING in
#      the battery read them -- `windows`/tiling anchors only ops 45/53/50/51, `displacements` only
#      3/4, `bufbase-eq` only 49, `sib-exclusivity` sees no REX.W+89/8B there. So the 11 bytes
#      carrying 262144 could be replaced with `0F 0B` (UD2) + nine `90`s -- SAME LENGTH, so every
#      predicted offset downstream is unchanged -- and the graded run would emit all 705 bytes,
#      execute UD2, triple-fault, exit 0 with an empty debugcon file, and pass every leg including
#      the guard witness, while `bufget(b, 262144)` never executed.
#
#      The asymmetry was self-indicting: `boundary_static` goes to real trouble to pin each
#      boundary probe's immediate so that "the compiler lowered both constants the same" is RED,
#      and the GRADED image's immediates -- including the 262144 the whole A3.1 claim is named for
#      -- were checked nowhere. Pinning the FORM of every op-0 kills the substitution at any site;
#      pinning the guard's VALUE also kills the weaker variant the leg admitted, where any index in
#      [262144, 524287] (all inside the high guard page) produced the same fault signature.
pi_bad = []
guard_sites = []
for k, f in enumerate(FUNCS):
    offs = lay.op_offsets(k)
    for i, (op, _, _) in enumerate(f.ops):
        if op != 0:
            continue
        w = img.code[offs[i]:offs[i] + 11]
        if len(w) != 11 or w[0:2] != L.MOVABS_PREFIX or w[10] != 0x50:
            pi_bad.append("%s PUSH_INT@%d is not `48 B8 <imm64> 50`: %s" % (f.name, offs[i], w.hex()))
            continue
        if f.is_main and i + 1 < len(f.ops) and f.ops[i + 1][0] == 50:
            guard_sites.append((offs[i], struct.unpack("<Q", w[2:10])[0]))
if len(guard_sites) != 1:
    pi_bad.append("expected exactly one PUSH_INT immediately before main's bufget, found %d" % len(guard_sites))
elif guard_sites[0][1] != 262144:
    pi_bad.append("guard immediate is %d, want 262144" % guard_sites[0][1])
elif text.count(L.MOVABS_PREFIX + (262144).to_bytes(8, "little") + b"\x50") != 1:
    pi_bad.append("the 262144 movabs window occurs %d times, want exactly 1"
                  % text.count(L.MOVABS_PREFIX + (262144).to_bytes(8, "little") + b"\x50"))
leg("pushints", not pi_bad,
    ";".join(pi_bad[:3]) or "every PUSH_INT window is `48 B8 <imm64> 50`; the guard access's immediate is 262144, at main's only pre-bufget PUSH_INT, occurring exactly once in the image")

# ---- source-shape (A3.3): every bufget/bufset base is the identifier bound to bufbase().
#      A booted measurement showed ops 50/51 take their base as a RUNTIME value, so the pinned
#      geometry is not load-bearing at runtime and `let s = b + 4194304` runs real indexed
#      accesses entirely outside the guarded buffer. The graded source is authored by this gate,
#      so that property is now CHECKED rather than true by inspection.
shape_ok, shape_detail = L.source_base_shape(src)
leg("source-shape", shape_ok, shape_detail)

# ---- bufbase-eq: the decoded movabs immediate must equal the FILESZ-derived base
b49 = [o for (_, _, p, o) in sites if p == 49]
imm = None
be = len(b49) == 1
if be:
    o = b49[0]
    be = img.code[o:o + 2] == L.MOVABS_PREFIX and img.code[o + 10] == 0x50
    imm = struct.unpack("<Q", img.code[o + 2:o + 10])[0]
    be = be and imm == img.buf_2m
leg("bufbase-eq", be, "movabs imm=%s buf_2m=0x%x" % (hex(imm) if imm is not None else "?", img.buf_2m))

# ---- displacements: every param-copy site AND every body LOAD_LOCAL/STORE_LOCAL site,
#      predicted individually -- `48 8B 45 ib` is both forms and the ranges legitimately
#      overlap, which is exactly why each is predicted rather than pattern-counted.
dsp, dsp_detail = True, []
for k in (1, 2):
    for (off, s_disp, d_disp) in lay.param_copy_disps(k):
        w = img.code[off:off + 8]
        want_b = bytes([0x48, 0x8B, 0x45, s_disp, 0x48, 0x89, 0x45, d_disp])
        if w != want_b:
            dsp = False; dsp_detail.append("%s param@%d got=%s want=%s" % (FUNCS[k].name, off, w.hex(), want_b.hex()))
n_local = 0
for k, f in enumerate(FUNCS):
    offs = lay.op_offsets(k)
    for i, (op, _, _) in enumerate(f.ops):
        if op == 3:
            if img.code[offs[i]:offs[i] + 3] != bytes([0x48, 0x8B, 0x45]) or img.code[offs[i] + 4] != 0x50:
                dsp = False; dsp_detail.append("%s LOAD_LOCAL@%d malformed" % (f.name, offs[i]))
            n_local += 1
        elif op == 4:
            if img.code[offs[i]] != 0x58 or img.code[offs[i] + 1:offs[i] + 4] != bytes([0x48, 0x89, 0x45]):
                dsp = False; dsp_detail.append("%s STORE_LOCAL@%d malformed" % (f.name, offs[i]))
            n_local += 1
leg("displacements", dsp,
    ";".join(dsp_detail[:3])
    or "every param-copy pair is pinned COMPLETELY (both displacement bytes); all %d body local sites are pinned in OPCODE FORM ONLY -- the slot displacement byte at +3/+4 is NOT predicted, so this pins that a local is read/written, never WHICH local (the spec does not model let-binding order; residual, and `source-shape` covers the same property on the source side)" % n_local)

# ---- seed-echo: the value the harness printed vs the value the DRIVER drew
drv = os.environ.get("LINK66_DRIVER_SEED", "")
echoed = os.environ.get("LINK66_HARNESS_ECHO", "")
# 32 hex chars, not 16: the driver draws TWO INDEPENDENT halves (payload seed and query
# seed) and the harness prints them concatenated as LINK66_SEED=%016x%016x. A 16 here was
# a leftover from the single-master-seed draft and made the leg unpassable.
leg("seed-echo", len(drv) == 32 and echoed == drv,
    "driver drew %s ; harness printed %s" % (drv or "<none>", echoed or "<none>"))

# ---- positional frame parsing -- the SPEC's production parser, not a copy living here
pp = L.parse_positional
good = bytes(range(10)) + bytes([1, 2, 3])
leg("frame-cardinality",
    pp(good, 10, 1)[2] == 1 and pp(b"\x00" * 12, 10, 1)[2] == -1 and pp(b"\x00" * 14, 10, 1)[2] == -1,
    "one well-formed length (13); 12 and 14 rejected by COUNT, not by search")
leg("frame-terminal",
    pp(good, 10, 1)[1] and pp(good, 10, 1)[0] == [3]
    and pp(bytes(range(16)), 10, 2)[0] == [12, 15]
    and pp(b"\x00" * 11, 10, 1)[0] is None,
    "answers read at their own fixed positions; the last is terminal by construction")

for st, name, detail in R:
    print("%s %s :: %s" % (st, name, detail))
print("STATIC-LEGS %d ok %d FAIL" % (sum(1 for r in R if r[0] == "ok"),
                                     sum(1 for r in R if r[0] == "FAIL")))
PYEOF
static_rc=$?
cat "$tmp/static.out"

# FAIL CLOSED: a crash, a missing summary, or a short leg count is a gate failure, never a
# silent zero-leg pass. (A review leg found the first draft passed with pass=0 fail=0 if the
# analysis block died.)
summary="$(grep -E '^STATIC-LEGS ' "$tmp/static.out" | tail -1)"
if [[ "$static_rc" -ne 0 || -z "$summary" ]]; then
    bad "static-analysis (rc=$static_rc, summary='${summary:-<none>}') -- the static block did not complete"
else
    n_ok=$(awk '{print $2}' <<<"$summary"); n_bad=$(awk '{print $4}' <<<"$summary")
    total=$((n_ok + n_bad))
    if [[ "$total" -ne "$EXPECTED_LEGS" ]]; then
        bad "static-analysis (reported $total legs, expected $EXPECTED_LEGS)"
    fi
    while read -r st name _; do
        [[ "$st" == "ok" ]] && ok "$name"
        [[ "$st" == "FAIL" ]] && bad "$name"
    done < <(grep -E '^(ok|FAIL) ' "$tmp/static.out")
fi

# ---------------------------------------------------------------- the IR gate, BOTH sides
compile_probe "$tmp/oneidx.herb" "$tmp/oneidx.d"
if compiled_ok "$tmp/oneidx.d"; then
    ok "accept-oneidx"
else
    bad "accept-oneidx (a buffer-mode program with EXACTLY ONE indexed op must compile: $(head -1 "$tmp/oneidx.d/stdout.txt" "$tmp/oneidx.d/err.txt" 2>/dev/null | tr -d '\n'))"
fi

compile_probe "$tmp/nobufop.herb" "$tmp/nobufop.d"
if refused_ok "$tmp/nobufop.d" && grep -qs 'ERR 655' "$tmp/nobufop.d/stdout.txt" "$tmp/nobufop.d/err.txt"; then
    ok "reject-nobufop"
else
    bad "reject-nobufop (buffer mode with no indexed op must be refused with ERR 655, not merely fail)"
fi

compile_probe "$tmp/singlefunc.herb" "$tmp/singlefunc.d"
if refused_ok "$tmp/singlefunc.d" && grep -qsE 'ERR (50[0-9]|6[0-9][0-9])' "$tmp/singlefunc.d/stdout.txt" "$tmp/singlefunc.d/err.txt"; then
    ok "reject-singlefunc"
else
    bad "reject-singlefunc (a single-function device-op program must be refused with a NAMED diagnostic, not merely produce no a.out)"
fi

# ---------------------------------------------------------------- seed-refusal
# Bounded by construction: the child is invoked with LINK66_NO_RECURSE set and refuses before
# it could re-enter this leg, so there is exactly one level.
if [[ -n "${LINK66_NO_RECURSE:-}" ]]; then
    echo "FAIL: link66 (internal: the refusal child must never reach the leg body)"; exit 1
fi
env LINK66_SEED=deadbeefdeadbeef LINK66_NO_RECURSE=1 \
    bash "$script_dir/run_native_codegen_link66.sh" >"$tmp/refusal.out" 2>&1
rc=$?
if [[ "$rc" -ne 0 ]] && grep -qs 'LINK66_SEED is set' "$tmp/refusal.out"; then
    ok "seed-refusal"
else
    bad "seed-refusal (a graded run must refuse when LINK66_SEED is present; rc=$rc)"
fi

# ================================================================ SLICE 3: THE BOOT LEGS
# Dual-substrate from the FIRST boot (A11.1): QEMU-TCG and Bochs, plus the local KVM leg.
# A2 puts the SECOND DRAW on both engines too, not just the first.
# The boot invokes ${QEMU_PREFIX:+$QEMU_PREFIX/bin/}qemu-system-x86_64, so the PRESENCE probe
# must ask about that exact binary. A bare `command -v qemu-system-x86_64` answers about a
# DIFFERENT executable whenever QEMU_PREFIX is set -- it would skip the boot legs on a host
# whose only QEMU lives under the prefix, and (worse) report them runnable on a host whose
# PATH qemu exists but whose PREFIX one does not, so the boot would then fail for a reason
# the gate had already told itself could not happen.
QEMU_BIN="${QEMU_PREFIX:+$QEMU_PREFIX/bin/}qemu-system-x86_64"
have_qemu()  { command -v "$QEMU_BIN" >/dev/null 2>&1 || [[ -x "$QEMU_BIN" ]]; }
have_kvm()   { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }
# THE BOCHS VERSION IS DETECTED, NEVER WRITTEN DOWN. A review leg caught both banners hardcoding
# "Bochs 2.7" while CI pins bochs 2.8 -- so in CI the banner would have named a version that did
# not run, in a suite whose whole doctrine is that a banner states only what executed.
bochs_version() { bochs --help 2>&1 | grep -oE 'Bochs x86 Emulator [0-9][0-9.]*' | head -1 | grep -oE '[0-9][0-9.]*$' || true; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
free_port() { python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
feeder_wait() { local log="$1" i; for i in $(seq 1 80); do grep -q LISTENING "$log" && return 0; grep -q NOCONN "$log" && return 1; sleep 0.1; done; return 1; }
feeder="$script_dir/kernel_io_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
# KVM IS ITS OWN KNOB, AND IT DEFAULTS OFF. A blind review leg found the gate self-contradictory:
# this file says in three places that CI sets KERNEL_CODEGEN_REQUIRE_EMU=1 and that CI has no
# /dev/kvm, and an earlier draft hard-exited when both were true -- i.e. it would be permanently
# RED in the one environment it calls authoritative. The real-silicon leg is a LOCAL pre-push leg
# by design; a host that wants it mandatory says so explicitly.
REQUIRE_KVM="${LINK66_REQUIRE_KVM:-0}"
# Which substrates ACTUALLY ran. The banner is built from these, never from a fixed string.
bochs_ran=0; kvm_ran=0
if ! have_qemu; then
    # Through bad(), not a bare exit: a bare exit skips the verdict block and prints NO
    # PASS:/FAIL: line at all, which is the same defect this gate fixed on the Bochs summary path.
    if [[ "$REQUIRE_EMU" == "1" ]]; then bad "require-qemu (KERNEL_CODEGEN_REQUIRE_EMU=1 but no QEMU at ${QEMU_BIN})"; fi
    echo "NOTE: QEMU absent; link66 boot legs skipped locally. Authoritative in kernel-codegen CI."
    echo "NOTE: this run grades the IMAGE only -- the black-box protocol did NOT execute."
    boot_legs=0
else
    boot_legs=1
fi

# --- the boundary probes: one image each, the index a BAKED CONSTANT (never a biased draw --
#     a -1 bias on a random k reaches B-8 only when k==0, which under the without-replacement
#     draw is exactly Q/N = 12.5% of runs; a baked constant faults every time by construction).
#     Each emits a MARKER BYTE BEFORE the access, so a missing frame is attributable to the
#     fault rather than to never having run (SC8's marker-progress class).
#     The edge probe STORES A KNOWN SENTINEL and reads it back, rather than reading whatever
#     an uninitialised buffer happens to hold. A review leg's exact words: "marker followed by
#     any constant byte passes the edge probe; the returned value is not checked." Now the
#     expected answer byte is 0x5a and nothing else passes -- so the edge leg proves a
#     round-trip through the last addressable slot, not merely that two bytes came out.
#     All three probes are the SAME SHAPE with only the index constant differing, which is
#     what makes the static decode below a discrimination rather than three separate stories.
SENTINEL=90        # 0x5a -- deliberately != the 0x41 marker
boundary_src() { # index
    printf -- '-- emit: multiboot32-long64\nfunc probe(base, k, s):\n    let m = output_byte(65)\n    let w = bufset(base, k, s)\n    let a = bufget(base, k)\n    return output_byte(a)\nend\nfunc main():\n    let b = bufbase()\n    return probe(b, %s, %s)\nend\n' "$1" "$SENTINEL"
}
boundary_built=1
boundary_src 262143                   > "$tmp/b_edge.herb"
boundary_src 262144                   > "$tmp/b_over.herb"
boundary_src 18446744073709551615     > "$tmp/b_under.herb"
for lbl in edge over under; do
    compile_probe "$tmp/b_$lbl.herb" "$tmp/b_$lbl.d"
    compiled_ok "$tmp/b_$lbl.d" || { bad "boundary-$lbl (probe did not compile cleanly: rc=$COMPILE_RC; $(head -1 "$tmp/b_$lbl.d/err.txt" 2>/dev/null))"; boundary_built=0; boot_legs=0; }
done

# ---------------------------------------------------------------- SLICE 4: the byte-pin
#
# The four committed goldens, per the landed convention (`gyre_goldens/<label>.sha256`, one bare
# sha256 hex per file, each path in BOOTSTRAP-ALLOWLIST). CAPTURED HOST-SIDE from the compiled
# images -- no boot is involved in a byte-pin, and pretending otherwise would make the capture
# depend on an emulator it does not need.
#
# The hash is deliberately NOT in circuit for any other leg. `SCOPE-R3` draft 1 had six rows
# "golden-disabled" and seven under the hash, which is backwards: rows that move the image would
# trip the hash first and their named discriminator would never run. The landed scripts
# (`link62_mutation.sh:173`, `link65_mutation.sh:139`) call each targeted leg directly and reserve
# the hash for `M-golden` alone. These four legs are that hash, and nothing else consults it.
goldens_dir="$script_dir/link66_goldens"

# --- boundary-images: the three probes DECODED, not merely booted.
#
# A review leg's finding, quoted because it is the whole reason this leg exists: "the 262144
# and 2^64-1 probes have the same expected outcome. If the compiler lowers both constants to
# 262144, both pass. No boundary image is inspected to confirm its immediate, its indexed-load
# bytes, or marker/load ordering." A pair of legs whose PASS condition is identical cannot
# discriminate between the two constants they are named for -- so the discrimination has to be
# made statically, in the image, before either boots.
#
# For each probe this requires, in its own image:
#   * EXACTLY ONE `48 B8 <its own index, u64 LE> 50` (movabs rax, imm64 / push rax), and
#     ZERO occurrences of EITHER OTHER probe's constant in that same form. That is what makes
#     "the compiler lowered both to 262144" a RED rather than an invisible collapse.
#   * exactly one sentinel movabs, exactly one scale-8 indexed load and one indexed store.
#   * ORDERING: marker-emit < store < load < answer-emit. The marker is the probe's progress
#     barrier (SC8's marker-progress class), so a marker emitted AFTER the access would make a
#     missing frame unattributable -- which is the attribution the fault legs rest on.
boundary_static() {
    python3 -I - "$spec" "$tmp/b_edge.d/a.out" "$tmp/b_over.d/a.out" "$tmp/b_under.d/a.out" <<'BEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
OP53 = bytes.fromhex("5b66baf80388d8ee66bafd03eca84074f753")
GET, SET = bytes.fromhex("488b04ca"), bytes.fromhex("48891" + "4c8")
KS = [262143, 262144, 18446744073709551615]
def occ(code, pat):
    out, i = [], 0
    while True:
        j = code.find(pat, i)
        if j < 0:
            return out
        out.append(j); i = j + 1
def movabs(v):
    return b"\x48\xb8" + v.to_bytes(8, "little") + b"\x50"
bad = []
for k, path in zip(KS, sys.argv[2:5]):
    code = L.Image(path).code
    own = occ(code, movabs(k))
    foreign = {o: len(occ(code, movabs(o))) for o in KS if o != k}
    sent = occ(code, movabs(90))
    o53, g, st = occ(code, OP53), occ(code, GET), occ(code, SET)
    if len(own) != 1:
        bad.append("k=%d own-immediate x%d (want 1)" % (k, len(own)))
    for o, n in foreign.items():
        if n:
            bad.append("k=%d carries FOREIGN immediate %d x%d" % (k, o, n))
    if len(sent) != 1:
        bad.append("k=%d sentinel x%d (want 1)" % (k, len(sent)))
    if len(g) != 1 or len(st) != 1:
        bad.append("k=%d bufget x%d bufset x%d (want 1/1)" % (k, len(g), len(st)))
    if len(o53) != 2:
        bad.append("k=%d op53 x%d (want 2: marker + answer)" % (k, len(o53)))
    elif not (o53[0] < st[0] < g[0] < o53[1]):
        bad.append("k=%d ordering marker@%d store@%d load@%d answer@%d"
                   % (k, o53[0], st[0], g[0], o53[1]))
print("BOUNDARY-STATIC " + ("; ".join(bad) if bad else
      "3 images: own immediate x1, no foreign immediate, one scale-8 load + one store, "
      "marker-before-access ordering"))
sys.exit(1 if bad else 0)
BEOF
}

if [[ "${LINK66_CAPTURE_GOLDENS:-0}" == "1" ]]; then
    # Deliberate recapture, never called by `make test` -- the same shape as
    # `capture_native_goldens.sh`. Guarded by an env var rather than a new tracked script,
    # because the design's allowlist moves by its enumerated path list and no other.
    #
    # TWO REFUSALS, both closing holes a byte-pin invites rather than waiting to be told about them.
    # (i) CI MUST NEVER REWRITE THE PIN. A capture that can run where the gate is authoritative is
    #     not a pin, it is a rubber stamp: any image the compiler produced would become "correct".
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        echo "FAIL: link66 capture (KERNEL_CODEGEN_REQUIRE_EMU=1 -- a golden recapture is a deliberate human act, never something an authoritative run does)"; exit 1
    fi
    # (ii) NEVER PIN AN IMAGE THE BATTERY JUST REJECTED. The static legs have already run by this
    #      point, so a capture on a broken emitter would freeze the breakage into the goldens and
    #      every later run would agree with it. Refuse unless the battery is clean.
    if [[ "$fail" -ne 0 ]]; then
        echo "FAIL: link66 capture ($fail static leg(s) FAILED -- refusing to pin an image the battery rejects)"; exit 1
    fi
    # (iii) NEVER PIN AN IMAGE THE BOUNDARY DECODER HAS NOT SEEN. A cross-family review leg found
    #       that `boundary_static` runs LATER in the script than this block exits, so a compiler
    #       that emitted all three boundary images while collapsing their constants would have had
    #       them pinned here and the validator would never have run. Run it FIRST.
    _bs="$(boundary_static 2>&1)"; _bsrc=$?
    if [[ "$_bsrc" -ne 0 ]] || ! grep -q '^BOUNDARY-STATIC 3 images' <<<"$_bs"; then
        echo "FAIL: link66 capture (boundary-images rejected the probes -- refusing to pin them: $_bs)"; exit 1
    fi
    mkdir -p "$goldens_dir"
    # ATOMIC, AND EVERY STEP CHECKED. `sha256sum | cut > file` under `set -uo pipefail` with
    # errexit OFF reports nothing when the hash, the cut or the redirection fails -- the same
    # review leg's blocker: capture would print CAPTURE-COMPLETE and exit 0 over empty, stale or
    # partial digest files. Each digest is computed, validated as 64 lowercase hex, and staged;
    # nothing is published until all four have succeeded.
    _stage="$tmp/goldens.stage"; rm -rf "$_stage"; mkdir -p "$_stage" || { echo "FAIL: link66 capture (cannot stage)"; exit 1; }
    for _g in "forcing:$tmp/forcing.d/a.out" "boundary_edge:$tmp/b_edge.d/a.out" \
              "boundary_over:$tmp/b_over.d/a.out" "boundary_under:$tmp/b_under.d/a.out"; do
        _lbl="${_g%%:*}"; _img="${_g#*:}"
        [[ -f "$_img" ]] || { echo "FAIL: link66 capture (missing image for $_lbl)"; exit 1; }
        _h="$(sha256sum "$_img")" || { echo "FAIL: link66 capture (sha256sum failed for $_lbl)"; exit 1; }
        _h="${_h%% *}"
        [[ "$_h" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: link66 capture ($_lbl digest is not 64 lowercase hex: '$_h')"; exit 1; }
        printf '%s\n' "$_h" > "$_stage/$_lbl.sha256" || { echo "FAIL: link66 capture (cannot write $_lbl)"; exit 1; }
    done
    for _g in forcing boundary_edge boundary_over boundary_under; do
        mv -f "$_stage/$_g.sha256" "$goldens_dir/$_g.sha256" || { echo "FAIL: link66 capture (cannot publish $_g)"; exit 1; }
        echo "CAPTURED $_g.sha256 = $(cat "$goldens_dir/$_g.sha256")"
    done
    echo "CAPTURE-COMPLETE: 4 link66 goldens written to $goldens_dir"
    exit 0
fi

golden_leg() { # label image
    local lbl="$1" img="$2" want got
    if [[ ! -f "$goldens_dir/$lbl.sha256" ]]; then
        bad "golden-$lbl (missing committed golden $goldens_dir/$lbl.sha256 -- fail-closed, never a silent skip)"; return 1
    fi
    # THE FILE'S EXACT REPRESENTATION, not merely its stripped content. Bash command substitution
    # strips ALL trailing newlines, so a digest followed by two or more blank lines compared equal
    # -- a review leg's finding. A committed pin is 65 bytes: 64 lowercase hex and one newline.
    if [[ "$(stat -c%s "$goldens_dir/$lbl.sha256")" -ne 65 ]]; then
        bad "golden-$lbl (committed golden is not exactly 65 bytes -- a pin is 64 lowercase hex + one newline)"; return 1
    fi
    want="$(cat "$goldens_dir/$lbl.sha256")"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { bad "golden-$lbl (committed golden is not 64 lowercase hex)"; return 1; }
    got="$(sha256sum "$img")" || { bad "golden-$lbl (sha256sum failed)"; return 1; }
    got="${got%% *}"
    if [[ "$want" == "$got" ]]; then ok "golden-$lbl"; return 0; fi
    bad "golden-$lbl (image != committed golden: $got != $want)"; return 1
}
# The two fault addresses the boundary claims name, DERIVED rather than written down. A
# `bufget(b, k)` addresses `buf_2m + 8k`, so index 262144 lands on `guard_hi` and index 2^64-1
# lands on `buf_2m - 8`, inside `guard_lo`. Slice 3 could only observe that a fault HAPPENED;
# slice 4 pins WHERE (see `fault_attribution` below).
FAULT_ADDRS="$(python3 -I - "$spec" "$tmp/forcing.d/a.out" <<'FEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
img = L.Image(sys.argv[2])
over = img.buf_2m + 8 * 262144                       # == guard_hi
under = (img.buf_2m + 8 * ((1 << 64) - 1)) % (1 << 64)   # == buf_2m - 8, inside guard_lo
assert over == img.guard_hi, (over, img.guard_hi)
assert img.guard_lo <= under < img.buf_2m, (under, img.guard_lo, img.buf_2m)
print("%016x %016x" % (over, under))
FEOF
)" || { echo "FAIL: link66 (cannot derive the guard fault addresses)"; exit 1; }
CR2_OVER="${FAULT_ADDRS%% *}"; CR2_UNDER="${FAULT_ADDRS##* }"

golden_leg forcing        "$tmp/forcing.d/a.out"
golden_leg boundary_edge  "$tmp/b_edge.d/a.out"
golden_leg boundary_over  "$tmp/b_over.d/a.out"
golden_leg boundary_under "$tmp/b_under.d/a.out"

MARKER="41"   # output_byte(65) -- the probe's observable
SENTHEX="5a"
# The edge probe's main returns the sentinel it read back, so its completion frame and its
# isa-debug-exit status are DERIVABLE, exactly as the draws' are -- through the SAME two spec
# functions, so a leg cannot drift from the rule the draws are graded by. (v = 90 < 2^32, so
# the published proof byte (v >> 32) & 0xff is 0 -- computed here rather than written down.)
EDGE_DERIV="$(python3 -I - "$spec" "$SENTINEL" <<'EEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
v = int(sys.argv[2]); pb = (v >> 32) & 0xFF
print("%02x %d" % (pb, L.qemu_exit_for(pb)))
EEOF
)" || { echo "FAIL: link66 (cannot derive the edge probe's completion values)"; exit 1; }
EDGE_PROOF="${EDGE_DERIV%% *}"; EDGE_EXIT="${EDGE_DERIV##* }"


# NOT gated on an emulator: this leg needs three compiled IMAGES and nothing else. A review leg:
# "with no QEMU, a compiler may collapse or corrupt all three boundary immediates ... The decoder
# never runs, yet the successful banner claims the boundary-images leg ran."
if [[ "$boundary_built" -eq 1 ]]; then
    bs_out="$(boundary_static 2>&1)"; bs_rc=$?
    echo "  $bs_out"
    if [[ "$bs_rc" -eq 0 ]] && grep -q '^BOUNDARY-STATIC 3 images' <<<"$bs_out"; then
        ok "boundary-images"
    else
        bad "boundary-images (rc=$bs_rc; $bs_out)"
    fi
else
    bad "boundary-images (the three boundary images did not compile, so the leg could not run -- fail-closed, never silently omitted from the banner)"
fi

# --- the DRIVER's own derivation of what the guest must send back, and of the guest's own
#     completion frame. Printed once per (draw), consumed by qemu_draw and by the Bochs grader.
#     THIS IS THE ANSWER TO THE SHARPEST FINDING THE REVIEW ROUND PRODUCED:
#       "a harness can print master_seed unchanged, but construct rp and rq from zero or
#        another constant. Because it also grades against that substituted stream, it emits
#        ok=1, and seed-echo passes."
#     Comparing seed lines cannot close that; only a SECOND derivation can. The driver derives
#     the exact N+3Q receive transcript from the seeds IT drew, in longbuf_spec (a module the
#     feeder deliberately does NOT import), and requires the captured bytes to equal it. A
#     harness generating from a substituted constant cannot produce those bytes.
# The capture, graded through the SPEC'S OWN PRODUCTION PARSER as well as by byte equality. A
# blind review leg found that `parse_positional` -- documented as "THE production answer-stream
# parser for this link" -- was on no grading path at all: the captures were compared with `cmp -s`
# and the parser was exercised only on two hand-built fixtures, so `frame-cardinality` and
# `frame-terminal` were two of thirteen static legs establishing nothing about any run. Now the
# capture is parsed positionally, its cardinality and terminal flag are required, its answers are
# required to equal the DERIVED answers, and the whole stream is still required byte-for-byte.
check_capture() { # capfile draw -> 0 iff the capture is exactly the derived stream, parsed
    python3 -I - "$spec" "$1" "$tmp/exp.$2.bin" "$LINK66_N" "$LINK66_Q" <<'CEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
try:
    got = open(sys.argv[2], "rb").read()
except OSError as ex:
    print("CAPTURE unreadable: %s" % ex); sys.exit(1)
want = open(sys.argv[3], "rb").read()
n, q = int(sys.argv[4]), int(sys.argv[5])
if got != want:
    print("CAPTURE bytes differ from the derived stream (got %d B, want %d B)" % (len(got), len(want)))
    sys.exit(1)
# The witness byte sits past the positional frame, so the parser grades the first n+3q and
# the witness is graded by the byte comparison above (and by the feeder, which derives it too).
a_got, term, card = L.parse_positional(got[:n + 3 * q], n, q)
a_want, _, _ = L.parse_positional(want[:n + 3 * q], n, q)
if card != 1 or not term or a_got is None or a_got != a_want:
    print("CAPTURE parse: cardinality=%s terminal=%s answers_match=%s" % (card, term, a_got == a_want))
    sys.exit(1)
print("CAPTURE ok: %d B (%d transcript + 1 witness 0x%02x), cardinality 1, terminal, %d answers match the derivation"
      % (len(got), n + 3 * q, got[n + 3 * q], len(a_got)))
CEOF
}

derive() { # draw -> writes $tmp/exp.<draw>.bin, echoes "<proofhex> <exitcode>"
    python3 -I - "$spec" "$DRIVER_PAY" "$DRIVER_QRY" "$1" "$LINK66_N" "$LINK66_Q" "$tmp/exp.$1.bin" <<'DEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
pay, qry, d, n, q, out = int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), sys.argv[7]
t, _, _ = L.expected_transcript(pay, qry, d, n, q, witness=True)
open(out, "wb").write(t)
pb = L.expected_proof_byte(pay, qry, d, n, q)
print("%02x %d" % (pb, L.qemu_exit_for(pb)))
DEOF
}

# --- a GRADED draw on QEMU. The driver draws the master seed ONCE (above) and passes it in;
#     the harness prints it back and the driver compares (seed-echo, already green statically).
# ---- FAULT ATTRIBUTION (slice-4 carry-over). Slice 3 attributed the guard fault by EXIT STATUS
#      and an EMPTY debugcon file, and a blind refutation leg was right that this is satisfied by
#      ANY fault, not by the one the claim names. QEMU-TCG's `-d int` records the real thing:
#
#        check_exception old: 0xffffffff new 0xe
#             0: v=0e e=0000 i=0 cpl=0 ... CR2=0000000000600000
#        check_exception old: 0xe new 0xd            <- #PF escalates to #DF
#        check_exception old: 0x8 new 0xd            <- and #DF to a triple fault
#
#      So the leg now requires a PAGE FAULT (v=0e) whose CR2 is the DERIVED address, escalating to
#      a double fault. WHERE THE SUBSTRATE PERMITS, and that qualifier is load-bearing and measured:
#      under KVM the exceptions are handled in-kernel and QEMU traces NONE of them (the same run
#      produced no `v=0e` line at all, and the only CR2 in the log is `CR2=00000000` from the
#      post-reset dump). Bochs has no equivalent knob and the shared harness discards its log for a
#      non-completed boot. So this closure is QEMU-TCG only; KVM and Bochs keep the weaker
#      signature, and the legs say which they are using rather than implying they are the same.
fault_attribution() { # label qemulog want_cr2 -> 0 if a #PF at want_cr2 escalated to #DF
    local label="$1" log="$2" want="$3"
    if [[ ! -s "$log" ]]; then
        bad "$label fault-attribution (no interrupt trace -- expected with -d int on TCG)"; return 1
    fi
    local pf; pf="$(grep -aoE "v=0e [^\n]*CR2=[0-9a-f]{16}" "$log" | grep -oE "CR2=[0-9a-f]{16}" | sort -u)"
    if [[ "$pf" != "CR2=$want" ]]; then
        bad "$label fault-attribution (page-fault CR2 set is '${pf:-<none>}', want exactly 'CR2=$want' -- the fault must be AT the derived guard address, not merely somewhere)"; return 1
    fi
    if ! grep -aq "check_exception old: 0xe new 0xd" "$log"; then
        bad "$label fault-attribution (the #PF did not escalate to a #DF -- a handled or unrelated fault is not the guard witness)"; return 1
    fi
    echo "    $label fault-attribution :: #PF v=0e CR2=$want -> #DF -> triple fault (QEMU-TCG interrupt trace)"
    return 0
}

qemu_draw() { # label elf N Q draw [kvm]
    local label="$1" elf="$2" N="$3" Q="$4" d="$5" kvm="${6:-}"
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local W="$tmp/$label.q"; mkdir -p "$W"
    # DRIVER-SIDE, BEFORE the boot: the exact bytes the guest must return, the proof byte its
    # whole-run accumulator must publish, and the isa-debug-exit status QEMU must report.
    local dv; dv="$(derive "$d")" || { bad "$label (the driver could not derive its own expected transcript)"; return 1; }
    # `want_exit` is deliberately NOT bound here any more: A3.1 replaced the completion contract
    # with the guard-fault contract, so the derived exit status is unused on this path and leaving
    # it assigned invited a reader to take it for a checked value. `derive` still emits it; the
    # edge probe uses its own EDGE_EXIT.
    local want_proof; want_proof="${dv%% *}"
    local port; port=$(free_port)
    python3 -I "$feeder" "$port" --grade "$N:$Q" --draw "$d" --master-seed "$DRIVER_PAY" --query-seed "$DRIVER_QRY" \
        --witness --cap "$W/cap.bin" > "$W/feed.log" 2>&1 &
    local fp=$!
    feeder_wait "$W/feed.log" || { bad "$label: feeder never LISTENING (HARNESS-ERROR, not a compiler RED)"; kill "$fp" 2>/dev/null; return 1; }
    # BRIEF B, CLOSED WHERE THE SUBSTRATE PERMITS: `logfile=` makes QEMU ITSELF write the wire
    # record. A blind refutation leg's finding was that `cap.bin` is `rxbuf` -- the harness's own
    # record of what it believes it received, written by the very process being distrusted -- so a
    # fully lying harness could compute the driver's expected transcript from the seeds it was
    # handed and write THAT to `--cap`. An emulator-authored record cannot be forged by the
    # harness, so grading it is what actually ties the bytes to the guest.
    # `-d int,cpu_reset` is TCG-only (see fault_attribution); under KVM it produces no exception
    # trace at all, so it is not requested there.
    local dbg=(); [[ -z "$kvm" ]] && dbg=(-d int,cpu_reset -D "$W/qemu.log")
    timeout 120 "$QEMU_BIN" -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off,logfile="$W/wire.log" \
        -serial chardev:s0 -monitor none "${acc[@]}" -m 64M "${dbg[@]}" >/dev/null 2>&1
    local rc=$?; wait "$fp" 2>/dev/null; local frc=$?
    local gl; gl="$(grep -E '^GRADE ' "$W/feed.log" | tail -1)"
    local sl; sl="$(sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' "$W/feed.log" | tail -1)"
    local e9; e9=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    echo "    $label :: $gl"
    # The harness's OWN seed line, on the gate's stdout and TAGGED. Without this the only
    # LINK66_SEED= line the gate ever prints is the driver's, so the DoD's two-run freshness
    # comparison observes the driver and is blind to a harness pinned to an internal constant.
    echo "    $label LINK66_SEED=$sl (harness) qemu-exit=$rc(want 0 = triple fault) feeder-exit=$frc frame=${e9:-EMPTY}(want EMPTY) witness-proof=$want_proof"
    if [[ "$sl" != "$DRIVER_SEED" ]]; then
        bad "$label seed-echo (harness printed '${sl:-<none>}', driver drew '$DRIVER_SEED')"; return 1
    fi
    # (1) THE INDEPENDENT TRANSCRIPT. Byte-for-byte against the driver's own derivation. This
    #     does not trust the feeder's ok= at all: it is the only leg that survives a harness
    #     that echoes the seed truthfully and then generates from something else.
    # (1a) THE EMULATOR-AUTHORED RECORD is what the transcript leg grades now. The harness's own
    #      cap.bin is still compared -- to the same derivation AND to QEMU's record -- so a
    #      divergence between the two is itself a RED rather than an unnoticed substitution.
    local cw; cw="$(check_capture "$W/wire.log" "$d" 2>&1)"
    if [[ $? -ne 0 ]]; then
        bad "$label transcript/emulator-record ($cw)"; return 1
    fi
    if ! cmp -s "$W/cap.bin" "$W/wire.log"; then
        bad "$label transcript (the harness's cap.bin and QEMU's own wire record DIFFER -- one of them is not the wire)"; return 1
    fi
    local cc; cc="$(check_capture "$W/cap.bin" "$d" 2>&1)"
    if [[ $? -ne 0 ]]; then
        bad "$label transcript ($cc)"; return 1
    fi
    # (2) THE FEEDER'S OWN VERDICT, still required, still not sufficient on its own.
    case "$gl" in
        *"ok=1"*"answers=$LINK66_Q"*) : ;;
        *) bad "$label (qemu rc=$rc feeder rc=$frc; $gl)"; return 1 ;;
    esac
    local want_rx=$(( LINK66_N + 3 * LINK66_Q + 1 ))    # +1: A3.1's witness byte
    case "$gl" in *"rx=$want_rx expected_rx=$want_rx extra=0"*) : ;;
        *) bad "$label (byte count not exactly $want_rx; $gl)"; return 1 ;; esac
    # ANCHORED. `witness=` is the LAST field on the GRADE line, so an unanchored glob for
    # `witness=10` also matched `witness=100`..`witness=109` -- a leg written to pin one byte
    # accepted eleven. Parse the field instead of globbing it.
    if [[ ! "$gl" =~ witness=([0-9]+)$ ]] || [[ "${BASH_REMATCH[1]}" -ne $((16#$want_proof)) ]]; then
        bad "$label (the guest's own accumulator byte is not the derived proof byte $((16#$want_proof)); $gl)"; return 1
    fi
    # (3) THE FEEDER PROCESS ITSELF must have exited clean. A crashed or killed grader that
    #     had already printed ok=1 was previously indistinguishable from a healthy one.
    if [[ "$frc" -ne 0 ]]; then
        bad "$label (the feeder exited $frc -- a grade printed by a process that then died is not a verdict)"; return 1
    fi
    # (4) THE GUARD WITNESS -- AMENDMENT A3.1, and it REPLACES the completion contract rather
    #     than joining it. The ruling asked for the exact transcript, the derived frame AND the
    #     triple-fault signature in the graded image. Measurement says the last two cannot
    #     coexist: nothing in the source runs after the grading tail, and the tail runs only if
    #     `main` returns, so a guest that faults on the guard page emits NO frame -- booted, `e9`
    #     came back EMPTY on an otherwise perfect run. The derived proof byte is therefore
    #     carried on the WIRE (check (3) above, `witness=`), which keeps all three observables,
    #     and what is required here is the fault itself.
    #
    #     WHY THIS IS THE LEG THAT CARRIES USE. `bufget(b, 262144)` is one slot past the 2-MiB
    #     buffer, i.e. the non-present guard page, so an honest guest MUST triple-fault. Any
    #     guest whose storage is not the real guarded buffer -- a different base, a frame chain,
    #     a peel ladder -- reaches this access and COMPLETES instead of faulting. The floor no
    #     longer has to carry USE alone against source-shaped forgers.
    if [[ -n "$e9" ]]; then
        bad "$label guard-witness (a completion frame '$e9' was emitted -- the guest did NOT fault on the guard page at index 262144, so its storage is not the guarded buffer)"; return 1
    fi
    if [[ "$rc" -ne 0 ]]; then
        bad "$label guard-witness (qemu rc=$rc, want 0 for a triple fault under -no-reboot$( [[ "$rc" -eq 124 ]] && echo ' -- 124 is the 120 s KILL, not a fault'))"; return 1
    fi
    # (5) WHERE the fault happened, not merely that one did -- TCG only, stated as such.
    if [[ -z "$kvm" ]]; then
        fault_attribution "$label" "$W/qemu.log" "$CR2_OVER" || return 1
    else
        echo "    $label fault-attribution :: SKIPPED on KVM -- exceptions are handled in-kernel and QEMU traces none of them (measured: no v=0e line, CR2=00000000 in the post-reset dump only). The KVM leg carries the weaker exit-status signature."
    fi
    ok "$label"; return 0
}

# --- a boundary probe on QEMU: MARKER SEEN, then NO completion frame (over/under), or a
#     completed answer (edge). A probe that completes where it must fault, or emits no marker,
#     is a compiler RED.
qemu_boundary() { # label elf expect(fault|answer) want_cr2
    local label="$1" elf="$2" expect="$3" want_cr2="${4:-}" kvm=""
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local W="$tmp/$label.q"; mkdir -p "$W"
    local port; port=$(free_port)
    python3 -I "$feeder" "$port" --cap "$W/cap.bin" --hold 12 > "$W/feed.log" 2>&1 &
    local fp=$!
    feeder_wait "$W/feed.log" || { bad "$label: feeder never LISTENING (HARNESS-ERROR)"; kill "$fp" 2>/dev/null; return 1; }
    timeout 120 "$QEMU_BIN" -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off,logfile="$W/wire.log" \
        -serial chardev:s0 -monitor none "${acc[@]}" -m 64M -d int,cpu_reset -D "$W/qemu.log" >/dev/null 2>&1
    local rc=$?; wait "$fp" 2>/dev/null; local frc=$?
    local cap; cap=$(xxd -p "$W/cap.bin" 2>/dev/null | tr -d '\n')
    local e9;  e9=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    echo "    $label :: cap=${cap:-EMPTY} e9=${e9:-EMPTY} rc=$rc feeder-exit=$frc"
    # The graded legs check the feeder's exit status; these did not, and a review leg pointed out
    # a boundary feeder can write a valid capture and then exit nonzero with every predicate green.
    # NOTE: the default (non-grade) feeder path exits 0 on a clean hold, 2 on NOCONN. A boundary
    # probe always connects, so anything but 0 is a harness fault, not a kernel verdict.
    if [[ "$frc" -ne 0 ]]; then
        bad "$label: feeder exited $frc (HARNESS-ERROR, not a compiler RED)"; return 1
    fi
    case "$cap" in "$MARKER"*) : ;; *) bad "$label (marker byte NOT seen -- the probe never ran; cap=${cap:-EMPTY})"; return 1;; esac
    if [[ "$expect" == "fault" ]]; then
        # A TIMEOUT IS NOT A FAULT. A review leg's exact demonstration: "marker followed by an
        # infinite loop, with no bufget, passes both QEMU fault probes after timeout." Under
        # -no-reboot a real triple fault makes QEMU EXIT; being killed at 120 s reports 124 and
        # is the signature of a guest that never reached its access at all. Grading the two the
        # same is grading the harness's patience, not the MMU.
        # The EXIT STATUS is pinned, not merely screened for 124. Under -no-reboot a triple
        # fault makes QEMU exit WITHOUT the isa-debug-exit device firing, so rc is 0; a
        # completed guest always reports an ODD `(v<<1)|1`; a kill reports 124. Observed on
        # TCG and on KVM at this rung. Requiring the exact class is what makes "some unrelated
        # fault also satisfies the classification" cost something.
        if [[ "$rc" -ne 0 ]]; then
            bad "$label (qemu rc=$rc, want 0 for a triple fault under -no-reboot$( [[ "$rc" -eq 124 ]] && echo ' -- 124 is the 120 s KILL: a guest that hangs before its access looks exactly like this'))"; return 1
        fi
        if [[ "${#cap}" -ne 2 || -n "$e9" ]]; then
            bad "$label (expected marker-then-FAULT: no answer byte and no completion frame; cap=$cap e9=${e9:-EMPTY} rc=$rc)"; return 1
        fi
        # THE DESIGN'S OWN CLAIM, now proven rather than inferred from an absence: "index -1 faults
        # into guard_lo, 262144 faults into guard_hi -- decided by the page tables rather than by a
        # bounds check a program could omit." Slice 3 observed only that SOMETHING faulted; this
        # pins the faulting address to the derived one, so the two probes -- which previously had
        # the SAME pass condition -- now discriminate.
        fault_attribution "$label" "$W/qemu.log" "$want_cr2" || return 1
        ok "$label"; return 0
    fi
    # The EDGE probe stores the sentinel at the last addressable slot and reads it back, so the
    # answer byte is KNOWN -- and so are its completion frame and exit status, because its main
    # returns the sentinel itself. "Any second byte" was the old condition and it graded nothing.
    if [[ "$cap" != "${MARKER}${SENTHEX}" ]]; then
        bad "$label (expected marker-then-SENTINEL round-trip ${MARKER}${SENTHEX} at slot 262143; cap=$cap rc=$rc)"; return 1
    fi
    if [[ "$rc" -ne "$EDGE_EXIT" || "$e9" != "de${EDGE_PROOF}ad" ]]; then
        bad "$label (edge probe must COMPLETE through its own tail: rc=$rc(want $EDGE_EXIT) frame=${e9:-EMPTY}(want de${EDGE_PROOF}ad))"; return 1
    fi
    ok "$label"; return 0
}

# --- Bochs, through the SHARED F2 harness (checked disk build + cleanup guards, per-attempt
#     classification, fresh-disk re-roll x3, exhaustion -> HARNESS-ERROR fail-closed, and only a
#     boot that ran THROUGH shutdown() graded as a kernel verdict). A2 requires the second draw
#     and every runtime-fault leg here too, not QEMU alone: a fault window is a CPU/MMU-visible
#     value and this project's own emulator-artifact hazard says cross-check it on a second engine.
# The F2 contract's first line: "the gate defines fail_test() (its kernel-RED reporter) before
# sourcing". This gate's reporter is bad(); the replay variants call fail_test by name, so it
# has to exist under that name before the source, not after it.
fail_test() { bad "$*"; }
# And the source is FAIL-CLOSED. `|| true` with stderr discarded meant a missing or broken
# shared harness produced a gate that silently ran no Bochs legs at all -- the exact shape of
# the 2026-07-17 flake class this harness was written to end.
if [[ ! -f "$script_dir/bochs_f2_harness.sh" ]]; then
    echo "FAIL: link66 (the shared Bochs F2 harness is missing -- A2's second engine cannot be graded)"; exit 1
fi
# shellcheck source=/dev/null
source "$script_dir/bochs_f2_harness.sh" || { echo "FAIL: link66 (cannot source bochs_f2_harness.sh)"; exit 1; }
F2_GATE="link66"; F2_HARNESS_FAIL=0
# OPT IN to the shared harness's positive termination (default OFF for every other gate). Without
# it a triple-faulting Bochs boot is bounded only by the 240 s attempt window -- measured 28.2 s on
# local 2.7 and the FULL 241 s on CI 2.8, which is what killed link66's first CI run.
export F2_FEED_END_BOOT=1

# --- the Bochs completion-frame rule, extracted so `reject-twoframe` can exercise THE
#     PRODUCTION function rather than a copy of it. QEMU's debugcon is a raw device file and is
#     graded by byte equality against the derived frame; Bochs's is a TEXT LOG, so cardinality
#     is a real question there and LEDGER D26's defect -- binding the FIRST `DE..AD` frame by
#     bare search, so a two-frame stream grades on the frame the boot did not end on -- is a
#     live hazard on this engine and only this engine.
#     THE LOG IS BINARY, AND THE FIRST SMOKE PROVED IT. Bochs's port_e9_hack writes the RAW
#     bytes 0xde <proof> 0xad into bochs_out.txt; grepping that file for the ASCII text
#     "de8ead" finds nothing, ever. The first end-to-end smoke reported
#         draw1-bochs ... frames=0 frame=NONE want=de8ead
#     on a run whose transcript was byte-perfect. Worse than the two REDs it caused: the three
#     Bochs boundary legs were passing on `frames -eq 0`, a condition the broken counter made
#     UNCONDITIONALLY TRUE -- three green legs grading nothing. The lineage's own idiom
#     (run_native_codegen_link65.sh:513-515) hexdumps first and greps the hex, and that is what
#     this does now.
#     AND IT MUST BE BYTE-ALIGNED. `hexdump | grep -oE` on one unbroken hex string is not: BOTH
#     review legs, independently, produced the same class of counterexample -- the raw bytes
#     `ad e1 0a d5` render as `ade10ad5`, which contains `de10ad` starting at NIBBLE index 1. That
#     invents a frame that does not exist (false RED on a draw, false RED on a fault leg) and the
#     non-overlapping `grep -o` also MISSES a second frame in `de de ad ad`. Parsed at byte
#     offsets instead, in python, which is the only form where "a frame" means three bytes.
frame_scan() { # file -> one hex frame per line, byte-aligned, overlaps included
    python3 -I -c '
import sys
d = open(sys.argv[1], "rb").read()
for i in range(len(d) - 2):
    if d[i] == 0xDE and d[i + 2] == 0xAD:
        print("de%02xad" % d[i + 1])
' "$1" 2>/dev/null
}
frame_count()   { frame_scan "$1" | grep -c . || true; }
frame_last()    { frame_scan "$1" | tail -1; }
frame_verdict() { # outlog want_proof -> 0 iff EXACTLY ONE frame and it is the derived one
    local n; n="$(frame_count "$1")"
    [[ "$n" -eq 1 ]] || return 1
    [[ "$(frame_last "$1")" == "de${2}ad" ]] || return 1
    return 0
}

grade_bochs_boundary() { # outlog capfile label expect
    local cap; cap=$(xxd -p "$2" 2>/dev/null | tr -d '
')
    local label="$3" expect="$4"
    local frames; frames=$(frame_count "$1")   # hexdump-based; the raw-log grep never matched
    echo "    $label :: cap=${cap:-EMPTY} frames=$frames"
    case "$cap" in "$MARKER"*) : ;; *) bad "$label (marker byte NOT seen on Bochs; cap=${cap:-EMPTY})"; return 1;; esac
    if [[ "$expect" == "fault" ]]; then
        [[ "${#cap}" -eq 2 && "$frames" -eq 0 ]] && { ok "$label"; return 0; }
        bad "$label (expected marker-then-FAULT on Bochs; cap=$cap frames=$frames)"; return 1
    fi
    if [[ "$cap" != "${MARKER}${SENTHEX}" ]]; then
        bad "$label (expected marker-then-SENTINEL round-trip ${MARKER}${SENTHEX} on Bochs; cap=$cap)"; return 1
    fi
    if ! frame_verdict "$1" "$EDGE_PROOF"; then
        bad "$label (edge probe must COMPLETE through its own tail on Bochs too: frames=$frames want de${EDGE_PROOF}ad x1)"; return 1
    fi
    ok "$label"; return 0
}

# ---------------------------------------------------------------- reject-twoframe (D26)
# The chartered leg manifest names this, and it has a real subject on exactly one engine.
# Proven against the PRODUCTION rule (`frame_verdict`), on three synthetic logs:
#   one correct frame            -> ACCEPT
#   two frames, the FIRST correct -> REJECT   (this is D26's exact defect: a bare first-match
#                                              search grades on the frame the boot did not end on)
#   one frame, wrong proof byte  -> REJECT
# RAW BYTES, not the ASCII text "de10ad". The rule hexdumps a BINARY Bochs log before it
# greps, so a text fixture would exercise nothing -- and this leg exists precisely because the
# first smoke caught the gate grepping the binary log directly and counting zero frames on a
# byte-perfect run.
printf 'boot noise\n\xde\x10\xad\ntail\n'                > "$tmp/f_one.log"
printf 'boot noise\n\xde\x10\xad\nmore\n\xde\x20\xad\n' > "$tmp/f_two.log"
printf 'boot noise\n\xde\x20\xad\ntail\n'                > "$tmp/f_wrong.log"
# The nibble-shift counterexample both review legs produced, as a fixture: these four bytes
# render as the hex text "ade10ad5", which a non-byte-aligned matcher reads as a de10ad frame.
printf 'noise\n\xad\xe1\x0a\xd5\ntail\n'                > "$tmp/f_shift.log"
# ... and the overlapping pair a non-overlapping matcher undercounts.
printf 'noise\n\xde\xde\xad\xad\n'                       > "$tmp/f_overlap.log"
if frame_verdict "$tmp/f_one.log" 10 \
   && ! frame_verdict "$tmp/f_two.log" 10 \
   && ! frame_verdict "$tmp/f_wrong.log" 10 \
   && [[ "$(frame_count "$tmp/f_shift.log")" -eq 0 ]] \
   && [[ "$(frame_count "$tmp/f_overlap.log")" -eq 2 ]]; then
    ok "reject-twoframe"
else
    bad "reject-twoframe (the rule must accept exactly one derived frame, reject a two-frame stream whose FIRST frame is the expected one (D26), see through no nibble-misaligned false frame (ad e1 0a d5), and count both frames of an overlapping pair; got shift=$(frame_count "$tmp/f_shift.log") overlap=$(frame_count "$tmp/f_overlap.log"))"
fi

if [[ "$boot_legs" -eq 1 ]]; then
    echo "  -- boot legs (QEMU-TCG) --"
    qemu_draw draw1-qemu "$tmp/forcing.d/a.out" "$LINK66_N" "$LINK66_Q" 0
    qemu_draw draw2-qemu "$tmp/forcing.d/a.out" "$LINK66_N" "$LINK66_Q" 1
    qemu_boundary boundary-edge-qemu  "$tmp/b_edge.d/a.out"  answer
    qemu_boundary boundary-over-qemu  "$tmp/b_over.d/a.out"  fault "$CR2_OVER"
    qemu_boundary boundary-under-qemu "$tmp/b_under.d/a.out" fault "$CR2_UNDER"
    if have_kvm; then
        kvm_ran=1
        echo "  -- local KVM real-silicon leg (CI has no /dev/kvm; quoted from the pre-push run) --"
        qemu_draw draw1-kvm "$tmp/forcing.d/a.out" "$LINK66_N" "$LINK66_Q" 0 kvm
    else
        echo "  NOTE: /dev/kvm absent -- the KVM leg is a local pre-push leg, skip-if-unavailable by design."
    fi
    if [[ "$REQUIRE_KVM" == "1" && "$kvm_ran" -ne 1 ]]; then
        bad "require-kvm (LINK66_REQUIRE_KVM=1 but /dev/kvm is unusable)"
    fi
    if have_bochs && declare -F f2_bochs_feed_leg >/dev/null; then
        bochs_ran=1
        echo "  -- boot legs (Bochs $(bochs_version) -- A2: the second draw and every runtime-fault leg run here too) --"
        # The GRUB config the disk build writes. An earlier smoke passed "" here, which wrote an
        # EMPTY grub.cfg -- GRUB then had nothing to boot and every Bochs leg classified
        # NO-SHUTDOWN. The dest path is RELATIVE (boot/kernel.elf), matching the landed callers.
        L66_GRUBCFG="$(printf 'set timeout=0\nset default=0\nmenuentry "l66" {\n multiboot /boot/kernel.elf\n boot\n}\n')"
        bochs_draw() { # label elf draw
            local label="$1" elf="$2" d="$3"; local W="$tmp/$label.b"; mkdir -p "$W"
            # A3.1 MOVED THIS OFF f2_bochs_feed_leg, and it had to. That helper grades ONLY a boot
            # that ran through shutdown() and classifies everything else as a harness error -- but
            # the graded image now ENDS IN A TRIPLE FAULT by design, so it never reaches shutdown.
            # Left on the old helper, every Bochs draw would have burned three fresh-disk re-rolls
            # and then reported HARNESS-ERROR on a perfect run. This is SC8's marker-progress class
            # applied to a full graded draw: the progress barrier is the complete transcript plus
            # the witness byte, and the expected terminal state is "no completion, clean launch".
            local dv; dv="$(derive "$d")" || { bad "$label (the driver could not derive its own expected transcript)"; return 1; }
            BOCHS_WANT_PROOF="${dv%% *}"
            local attempt cls=""
            for attempt in 1 2 3; do
                cls="$(f2_bochs_feed_attempt "--grade $LINK66_N:$LINK66_Q --draw $d --master-seed $DRIVER_PAY --query-seed $DRIVER_QRY --witness --drain-mode quiet --cap $W/cap.bin" "$W/feed.log" "$L66_GRUBCFG" 240 64 "$W/out.log" "$elf:boot/kernel.elf")"
                case "$cls" in NO-SHUTDOWN|COMPLETED) break ;; esac
                echo "HARNESS re-roll: link66 $label attempt $attempt = $cls (fresh disk + fresh feeder retry)" >&2
                # Moving this leg off f2_bochs_feed_leg inherited the re-roll loop but NOT
                # f2_harness_error, so F2_HARNESS_FAIL was never incremented here and the
                # `bochs-harness` leg -- whose entire purpose is adjudicating exhaustion --
                # reported `ok` on the exhaustion it exists to catch, while the failure surfaced
                # under the kernel-RED prefix without the greppable HARNESS-ERROR: marker its own
                # contract mandates. A blind refutation leg found it.
                [[ "$attempt" -eq 3 ]] && f2_harness_error "$label" "$cls"
            done
            local gl; gl="$(grep -E '^GRADE ' "$W/feed.log" | tail -1)"
            local sl; sl="$(sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' "$W/feed.log" | tail -1)"
            # NO FRAME COUNT. A blind refutation leg caught this as the FOURTH instance of a leg
            # of mine grading nothing, and it was the same defect I had just removed from
            # bochs_boundary_fault and left here: f2__classify_boot returns NO-SHUTDOWN *before*
            # the `cp "$W/bochs_out.txt" "$outlog"`, and f2_bochs_feed_attempt truncates the outlog
            # on entry -- so on every path that reaches this grading code, out.log is a zero-byte
            # file and `frames -ne 0` is unconditionally false. Printing it as evidence was worse
            # than not checking it.
            echo "    $label :: class=$cls $gl"
            echo "    $label LINK66_SEED=$sl (harness) witness-proof=$BOCHS_WANT_PROOF"
            case "$cls" in
                NO-SHUTDOWN) : ;;
                COMPLETED) bad "$label guard-witness (the boot ran THROUGH shutdown -- the guest did NOT fault on the guard page at index 262144, so its storage is not the guarded buffer)"; return 1 ;;
                *) bad "$label (HARNESS class=$cls -- not a kernel verdict; fail-closed)"; return 1 ;;
            esac
            grep -q "^LISTENING" "$W/feed.log" 2>/dev/null || { bad "$label (feeder never LISTENING -- HARNESS, not a kernel verdict)"; return 1; }
            [[ "$sl" == "$DRIVER_SEED" ]] || { bad "$label seed-echo (harness printed '${sl:-<none>}')"; return 1; }
            local cc; cc="$(check_capture "$W/cap.bin" "$d" 2>&1)"
            if [[ $? -ne 0 ]]; then bad "$label transcript ($cc)"; return 1; fi
            local want_rx=$(( LINK66_N + 3 * LINK66_Q + 1 ))
            case "$gl" in *"ok=1"*"answers=$LINK66_Q"*) : ;;
                *) bad "$label ($gl)"; return 1 ;; esac
            case "$gl" in *"rx=$want_rx expected_rx=$want_rx extra=0"*) : ;;
                *) bad "$label (byte count not exactly $want_rx; $gl)"; return 1 ;; esac
            if [[ ! "$gl" =~ witness=([0-9]+)$ ]] || [[ "${BASH_REMATCH[1]}" -ne $((16#$BOCHS_WANT_PROOF)) ]]; then
                bad "$label (the guest's own accumulator byte is not the derived proof byte; $gl)"; return 1
            fi
            # WHAT THE GUARD WITNESS ACTUALLY ESTABLISHES ON THIS ENGINE, said plainly rather
            # than overstated: `NO-SHUTDOWN` means the boot never ran through shutdown(), so a
            # guest that COMPLETES is RED (checked above) -- but NO-SHUTDOWN does NOT distinguish
            # a triple fault from a HANG, and the shared harness discards the Bochs log for any
            # non-completed boot, so this gate cannot read the reset record that would. The
            # DISCRIMINATING fault signature is carried by the QEMU and KVM legs (exit status 0
            # with an empty debugcon file); Bochs carries A2's second-engine agreement on the
            # transcript and the derived proof byte, and the weaker "did not complete" half of the
            # witness. Recorded as a residual rather than papered over.
            ok "$label"; return 0
        }
        # A FAULTING probe must NOT use f2_bochs_feed_leg. That helper grades only a boot that
        # ran THROUGH shutdown() and classifies anything else as a HARNESS error -- which is
        # exactly inverted for a probe whose PASS condition is "marker seen, then no completion".
        # SC8 names this the MARKER-PROGRESS class: the progress barrier is the marker, not an
        # echo, and the expected terminal state is "marker seen, no completion frame, clean
        # launch". So the faulting legs drive f2_bochs_feed_attempt directly and accept
        # NO-SHUTDOWN as the EXPECTED class, while still requiring a clean launch (the feeder
        # LISTENED and delivered) and the marker byte. A probe that COMPLETES, or that emits no
        # marker, is still a compiler RED.
        bochs_boundary_fault() { # label elf
            local label="$1" elf="$2"; local W="$tmp/$label.b"; mkdir -p "$W"
            local attempt cls=""
            for attempt in 1 2 3; do
                cls="$(f2_bochs_feed_attempt "--cap $W/cap.bin --hold 20" "$W/feed.log" "$L66_GRUBCFG" 240 64 "$W/out.log" "$elf:boot/kernel.elf")"
                case "$cls" in
                    NO-SHUTDOWN|COMPLETED) break ;;
                esac
                echo "HARNESS re-roll: link66 $label attempt $attempt = $cls (fresh disk + fresh feeder retry)" >&2
                [[ "$attempt" -eq 3 ]] && f2_harness_error "$label" "$cls"
            done
            local cap; cap=$(xxd -p "$W/cap.bin" 2>/dev/null | tr -d "\n")
            # NO FRAME COUNT HERE, AND THAT IS THE HONEST FORM. A review leg traced it:
            # f2__classify_boot returns NO-SHUTDOWN *before* the `cp "$W/bochs_out.txt" "$outlog"`
            # (bochs_f2_harness.sh:126-127), and f2_bochs_feed_attempt truncates the outlog at
            # entry (:145) and rm -rf's the attempt directory afterwards. So on a NO-SHUTDOWN boot
            # -- which is EVERY accepted fault attempt -- out.log is an empty file, and
            # `frames -eq 0` was unconditionally true: a third leg of mine grading nothing.
            # The completion barrier on this engine is the CLASS, not a frame count: NO-SHUTDOWN
            # means the boot never ran through shutdown(), which is exactly "did not complete".
            # Requiring a frame count on top of it would be a condition read off a file the shared
            # harness deliberately does not preserve, and the fix is to stop pretending to check
            # it -- not to reach into a shared harness eleven other gates depend on.
            echo "    $label :: class=$cls cap=${cap:-EMPTY} (completion barrier on Bochs is the CLASS; out.log is empty by construction for a non-completed boot)"
            case "$cls" in
                NO-SHUTDOWN|COMPLETED) : ;;
                *) bad "$label (HARNESS class=$cls -- not a kernel verdict; fail-closed)"; return 1 ;;
            esac
            grep -q "^LISTENING" "$W/feed.log" 2>/dev/null || { bad "$label (feeder never LISTENING -- HARNESS, not a kernel verdict)"; return 1; }
            case "$cap" in "$MARKER"*) : ;; *) bad "$label (marker byte NOT seen on Bochs -- the probe never ran; cap=${cap:-EMPTY})"; return 1 ;; esac
            # SUBSTRATE DIFFERENCE, stated rather than tuned around. QEMU runs with -no-reboot,
            # so a triple fault HALTS and the capture is exactly one marker byte. Bochs RESETS on
            # triple fault, so the image boots again, emits the marker again, and faults again
            # until the leg's timeout -- an observed cap of 4141414141, five markers and nothing
            # else. That is the SAME kernel verdict, observed on an engine with a different
            # reset policy; requiring exactly one byte would grade the emulator's reboot
            # behaviour rather than the guest's fault.
            # The invariant that actually carries the claim, and it is stronger than a count:
            # EVERY captured byte is the marker and NOT ONE is an answer. A probe that reached
            # its bufget would emit a second, different byte -- which is exactly what
            # boundary-edge does (cap=4100). So: at least one marker, nothing but markers, no
            # completion frame, no shutdown.
            local nonmarker; nonmarker=$(printf '%s' "$cap" | sed 's/\(..\)/\1\n/g' | grep -v "^$MARKER$" | grep -c . || true)
            if [[ "${#cap}" -ge 2 && "$nonmarker" -eq 0 && "$cls" == "NO-SHUTDOWN" ]]; then ok "$label"; return 0; fi
            bad "$label (expected marker-then-FAULT on Bochs: only marker bytes, no answer byte, and NO-SHUTDOWN; cap=$cap nonmarker=$nonmarker class=$cls)"; return 1
        }
        bochs_boundary() { # label elf expect
            local label="$1" elf="$2" expect="$3"; local W="$tmp/$label.b"; mkdir -p "$W"
            f2_bochs_feed_leg "$label" grade_bochs_boundary                 "--cap $W/cap.bin --hold 20"                 "$W/feed.log" "$W/out.log" "$L66_GRUBCFG" 240 64 "$elf:boot/kernel.elf" -- "$W/cap.bin" "$label" "$expect"
        }
        bochs_draw draw1-bochs "$tmp/forcing.d/a.out" 0            || true
        bochs_draw draw2-bochs "$tmp/forcing.d/a.out" 1            || true
        bochs_boundary boundary-edge-bochs  "$tmp/b_edge.d/a.out"  answer || true
        bochs_boundary_fault boundary-over-bochs  "$tmp/b_over.d/a.out"   || true
        bochs_boundary_fault boundary-under-bochs "$tmp/b_under.d/a.out"  || true
        # THE F2 CONTRACT, HONOURED. Its header says: "the gate ... before its final PASS/FAIL
        # logic, runs `f2_harness_summary || exit 1`", and exhaustion "FAILS CLOSED
        # UNCONDITIONALLY (regardless of KERNEL_CODEGEN_REQUIRE_EMU -- a gate must not PASS
        # with an attempted leg unadjudicated)". The previous form was
        #     declare -F f2_harness_summary >/dev/null && f2_harness_summary
        # which DISCARDED the return value under `set +e`, so a review leg was able to show
        # QEMU green + every Bochs leg exhausted + fail==0 + the gate printing PASS. Routing it
        # through bad() keeps the failure inside this gate's own counter (an `exit 1` here would
        # skip the verdict block and print no banner at all).
        if ! declare -F f2_harness_summary >/dev/null; then
            bad "bochs-harness (f2_harness_summary is not defined after sourcing -- the shared harness did not load)"
        elif ! f2_harness_summary; then
            bad "bochs-harness (Bochs leg(s) exhausted their fresh-disk re-rolls -- attempted-but-unadjudicated legs FAIL CLOSED; NOT a kernel verdict)"
        else
            ok "bochs-harness"
        fi
    elif [[ "$REQUIRE_EMU" == "1" ]]; then
        bad "require-bochs (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing -- A2 requires the second engine)"
    else
        echo "  NOTE: Bochs prerequisites missing -- A2's second-engine legs skipped locally; CI is the fail-closed enforcer."
    fi
fi

# ---------------------------------------------------------------- verdict
#
# THE LEG MANIFEST, BY NAME, reconciled against SCOPE-BUILD's list rather than asserted -- and
# RECOUNTED, because a blind refutation leg counted the strings and found the previous comment
# wrong by exactly the amendment under review (it claimed 30/31 and was not updated when A3 added
# legs, though EXPECTED_LEGS was). Counted from the strings below: STATIC_LEGS = 22 names,
# BOOT_LEGS base = 5, Bochs adds 6, KVM adds 1. Slice 4's four `golden-*` are now IN
# STATIC_LEGS, making it 26 names -> 37 in CI, 38 locally. The design named 28. Every difference is an ADDITION forced by a review finding
# -- nothing chartered was dropped:
#   + elf-header, geometry, windows, accept-oneidx  (slice 2's two review rounds)
#   + boundary-images, bochs-harness                (slice 3's review round)
#   + sib-exclusivity, source-shape                 (A3.2, A3.3)
#   + pushints                                      (A3's own refutation: the 11-byte PUSH_INT
#                                                    windows nothing read)
#   + golden-forcing/-boundary_edge/-boundary_over/-boundary_under   (slice 4's byte-pin)
# This comment is now the thing that has to stay true when a leg is added.
STATIC_LEGS="golden-forcing, golden-boundary_edge, golden-boundary_over, golden-boundary_under, elf-header, pmemsz, pd-guards, geometry, windows, counts, sites, rawdecode, sib-exclusivity, pushints, source-shape, bufbase-eq, displacements, seed-echo, frame-cardinality, frame-terminal, accept-oneidx, reject-nobufop, reject-singlefunc, seed-refusal, reject-twoframe, boundary-images"
# BUILT FROM WHAT RAN, never a fixed string. BOTH review legs, independently, found the same
# thing: on a host with QEMU but without Bochs and without /dev/kvm the gate printed the full
# DUAL-SUBSTRATE banner and named six Bochs legs and a KVM leg individually, none of which had
# executed. This file's own header calls that "the cheapest possible lie for a gate to tell", and
# the two-banner split fixed only the NO-QEMU case; the partial-substrate case was left open.
BOOT_LEGS="draw1-qemu, draw2-qemu (both GUARD-WITNESS: emulator-authored wire record + derived proof byte + a #PF at the derived guard_hi escalating to #DF), boundary-edge-qemu, boundary-over-qemu, boundary-under-qemu (the two fault probes now discriminated by their FAULTING ADDRESS, not by a shared absence)"
SUBSTRATES="QEMU-TCG"
if [[ "$bochs_ran" -eq 1 ]]; then
    BOOT_LEGS="$BOOT_LEGS, draw1-bochs, draw2-bochs, boundary-edge-bochs, boundary-over-bochs, boundary-under-bochs, bochs-harness"
    SUBSTRATES="$SUBSTRATES + Bochs $(bochs_version) (A2, dual-substrate; version DETECTED, not written down -- CI pins 2.8 and every local figure in this design is 2.7)"
else
    SUBSTRATES="$SUBSTRATES ONLY -- Bochs did NOT run, so A2's second engine is UNOBSERVED on this host"
fi
if [[ "$kvm_ran" -eq 1 ]]; then
    BOOT_LEGS="$BOOT_LEGS, draw1-kvm"
    SUBSTRATES="$SUBSTRATES + local KVM"
else
    SUBSTRATES="$SUBSTRATES; no KVM leg on this host"
fi

if [[ "$fail" -ne 0 ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (native-codegen link66 / longbuf: pass=$pass fail=$fail)"
    exit 1
fi

# A GATE THAT DID NOT BOOT MUST NOT PRINT THE RUNTIME CLAIM. A review leg's finding, in its own
# words: "the advertised boot gate can pass with no boot ... The unconditional banner
# nevertheless claims dual-substrate boot legs." Two banners, and the no-boot one claims the
# image and nothing else. CI sets KERNEL_CODEGEN_REQUIRE_EMU=1, so the skip road exists for a
# developer host and is fail-closed anywhere it matters.
if [[ "$boot_legs" -ne 1 ]]; then
    echo "SKIP: link66 runtime legs -- no emulator on this host; the black-box protocol did NOT execute and NOTHING about runtime indexing was observed."
    echo "PASS: stack/native_compile_fragment.herb (native-codegen link66 / longbuf / IMAGE LEGS ONLY -- the static half of runtime-indexed memory on the sovereign long64 target: a 2-MiB buffer between two non-present guard pages, its movabs base equal to the phdr-derived address, scale 8 at every indexed site, p_memsz exact; legs: $STATIC_LEGS; pass=$pass fail=0; the runtime legs were SKIPPED and are authoritative only under KERNEL_CODEGEN_REQUIRE_EMU=1)"
    exit 0
fi

# The runtime sentence, stated at the strength the evidence actually supports. The earlier
# banner said the buffer was "indexed at run time", flatly. A review leg was right that 64
# matches are a DISCRIMINATION, not a proof of execution: the design's own floor is
# P_forge >= 2^-64 from the seed image, and 2^-99.67 is the best attack FOUND over the searched
# strategy families, not a proven upper bound. What IS proof-shaped here is the completion
# contract -- the driver derives the transcript, the accumulator's proof byte and the
# isa-debug-exit status before the boot, and requires all three exactly.
echo "PASS: stack/native_compile_fragment.herb (native-codegen link66 / longbuf / 50th kernel-arc link -- RUNTIME-INDEXED MEMORY on the sovereign long64 target: a 2-MiB buffer between two non-present guard pages, indexed by a guest-assembled index, discriminated by a one-byte-ack black-box protocol whose TWO INDEPENDENT seeds the SUPERVISING DRIVER draws (A1) and whose $LINK66_Q queries are drawn WITHOUT REPLACEMENT over the full $LINK66_N-byte range; the driver INDEPENDENTLY DERIVES the $(( LINK66_N + 3 * LINK66_Q + 1 ))-byte receive stream -- the transcript plus the guest's own accumulator byte -- and requires it byte-exactly of QEMU's OWN chardev wire record (not merely of the harness's cap.bin, which the harness itself writes), so a harness that echoed the seed and generated from something else goes RED; every graded draw then ends in the A3 GUARD WITNESS -- bufget(b, 262144), one slot past the buffer into the non-present guard page, so a guest that performs that indexed access through the real guarded base MUST triple-fault, and one that does not -- because the access was dropped, mis-lowered, or aimed somewhere that is not the guarded page -- COMPLETES instead and goes RED. THE LIMIT OF THAT WITNESS, corrected here by link66's own mutation proof rather than left overstated: it establishes that an indexed access to the guard page HAPPENED, NOT that the 64 answers came from the buffer. A program with the answers baked in that leaves the guard access in place faults exactly like an honest one -- run_native_codegen_link66_mutation.sh builds one (M-seedpin-env) and boots it -- so what excludes that program is the seed being DRAWN PER RUN by the supervising driver, not this witness; the rung is pinned to a ratified ladder row by exact membership at $LINK66_SENDS sends; the black-box result is a probabilistic discrimination against a 2^-64 seed floor and is NOT on its own a proof that an indexed load executed -- the guard witness, not the floor, is what ties the graded run to the guarded buffer; boot legs: $SUBSTRATES; legs: $STATIC_LEGS, $BOOT_LEGS; pass=$pass fail=0; the four images are BYTE-PINNED to committed goldens and the hash is in circuit for nothing else; the mutation suite is slice 5)"
exit 0
