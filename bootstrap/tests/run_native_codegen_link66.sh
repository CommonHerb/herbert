#!/usr/bin/env bash
# link66 (longbuf) -- RUNTIME-INDEXED MEMORY on the sovereign long64 target.
#
# SLICE 2 STATE: the STATIC legs only. No emulator is launched by this script yet; the
# black-box draws, the boundary probes and their goldens land in slices 3-4, and the
# mutation harness in slice 5. Every leg below grades the IMAGE or the HARNESS, never a
# boot, and the PASS banner names exactly the legs that ran.
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

EXPECTED_LEGS=13          # the static block's own leg count; a short block is a FAILURE

# ---------------------------------------------------------------- A1: the seed channel
if [[ -n "${LINK66_SEED:-}" ]]; then
    echo "FAIL: link66 (LINK66_SEED is set; a graded run takes its seed from the supervising driver)"
    exit 1
fi
DRIVER_SEED="$(python3 -c 'import os;print("%016x"%int.from_bytes(os.urandom(8),"big"))')"
[[ "${#DRIVER_SEED}" -eq 16 ]] || { echo "FAIL: link66 (the driver could not draw a 64-bit seed)"; exit 1; }
echo "LINK66_SEED=$DRIVER_SEED (drawn: supervisor)"

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
    return serve(b, 64, 0) * 4294967296
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

compile_probe "$tmp/forcing.herb" "$tmp/forcing.d"
[[ -f "$tmp/forcing.d/a.out" ]] || { echo "FAIL: link66 (the forcing program did not compile: $(head -1 "$tmp/forcing.d/err.txt" 2>/dev/null))"; exit 1; }

# ---------------------------------------------------------------- the harness stub (A1)
#
# The thing seed-echo tests. It reads the seed off the named channel and prints it back. A
# harness that ignored the channel and used an internal constant would print a value the
# driver never drew -- which is the whole point, and is why this is a SEPARATE PROCESS with
# its own copy of nothing. (In slice 3 the real harness replaces this stub on the same
# channel; the leg does not change.)
cat > "$tmp/harness_seed.py" <<'EOS'
import os, sys
s = os.environ.get("LINK66_DRIVER_SEED")
if not s:
    sys.exit("harness: no seed on the channel")
print("LINK66_SEED=%s (drawn: supervisor)" % s)
EOS

# ---------------------------------------------------------------- the static legs
HARNESS_LINE="$(LINK66_DRIVER_SEED="$DRIVER_SEED" python3 "$tmp/harness_seed.py" 2>/dev/null)"
HARNESS_ECHO="$(sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' <<<"$HARNESS_LINE")"
set +e
LINK66_DRIVER_SEED="$DRIVER_SEED" LINK66_HARNESS_ECHO="$HARNESS_ECHO" python3 - "$spec" "$tmp/forcing.d/a.out" "$tmp/forcing.herb" > "$tmp/static.out" 2>&1 <<'PYEOF'
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
F_MAIN = L.Func("main", 0, 2, [
    (49,0,0),(4,0,0),
    (3,0,0),(0,0,0),(0,0,0),(20,1,3),(4,0,0),
    (3,0,0),(0,0,0),(0,0,0),(20,2,3),(0,0,0),(42,0,0),(21,0,0),
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
covered = []
for k, f in enumerate(FUNCS):
    offs = lay.op_offsets(k)
    for i, (op, _, _) in enumerate(f.ops):
        sz = f.op_size(i, FUNCS)
        covered.append((offs[i], sz))
        if op in FIXED:
            got = img.code[offs[i]:offs[i] + len(FIXED[op])]
            if got != FIXED[op]:
                win_bad.append("op%d@%d got=%s want=%s" % (op, offs[i], got.hex(), FIXED[op].hex()))
# gap-free: within each function the predicted ops tile contiguously
tile_ok = True
for k, f in enumerate(FUNCS):
    offs = lay.op_offsets(k)
    for i in range(len(offs) - 1):
        if offs[i] + f.op_size(i, FUNCS) != offs[i + 1]:
            tile_ok = False
leg("windows", not win_bad and tile_ok,
    ";".join(win_bad[:3]) or "every fixed-form op window matches at its predicted offset; ops tile gap-free")

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
    ";".join(dsp_detail[:3]) or "every param-copy pair and all %d body local sites match their predicted forms" % n_local)

# ---- seed-echo: the value the harness printed vs the value the DRIVER drew
drv = os.environ.get("LINK66_DRIVER_SEED", "")
echoed = os.environ.get("LINK66_HARNESS_ECHO", "")
leg("seed-echo", len(drv) == 16 and echoed == drv,
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
set -e
set +e
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
if [[ -f "$tmp/oneidx.d/a.out" ]]; then
    ok "accept-oneidx"
else
    bad "accept-oneidx (a buffer-mode program with EXACTLY ONE indexed op must compile: $(head -1 "$tmp/oneidx.d/stdout.txt" "$tmp/oneidx.d/err.txt" 2>/dev/null | tr -d '\n'))"
fi

compile_probe "$tmp/nobufop.herb" "$tmp/nobufop.d"
if [[ ! -f "$tmp/nobufop.d/a.out" ]] && grep -qs 'ERR 655' "$tmp/nobufop.d/stdout.txt" "$tmp/nobufop.d/err.txt"; then
    ok "reject-nobufop"
else
    bad "reject-nobufop (buffer mode with no indexed op must be refused with ERR 655, not merely fail)"
fi

compile_probe "$tmp/singlefunc.herb" "$tmp/singlefunc.d"
if [[ ! -f "$tmp/singlefunc.d/a.out" ]] && grep -qsE 'ERR (50[0-9]|6[0-9][0-9])' "$tmp/singlefunc.d/stdout.txt" "$tmp/singlefunc.d/err.txt"; then
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

# ---------------------------------------------------------------- verdict
if [[ "$fail" -ne 0 ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (native-codegen link66 / longbuf / SLICE 2 static legs: pass=$pass fail=$fail)"
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link66 / longbuf / 50th kernel-arc link, SLICE 2 -- the STATIC legs of RUNTIME-INDEXED MEMORY on the sovereign long64 target; legs: elf-header, pmemsz, pd-guards, geometry, windows, counts, sites, rawdecode, bufbase-eq, displacements, seed-echo, frame-cardinality, frame-terminal, accept-oneidx, reject-nobufop, reject-singlefunc, seed-refusal; pass=$pass fail=0; NO EMULATOR -- the draws, the boundary probes, their goldens and the mutants are slices 3-5)"
exit 0
