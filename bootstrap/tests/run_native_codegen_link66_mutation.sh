#!/usr/bin/env bash
# Mutation proof for native-codegen link 66 (longbuf): every gate leg that guards RUNTIME-INDEXED
# MEMORY must BITE (go RED) when the capability, its geometry, or its seed channel is broken.
#
# THE GRADING CONVENTION IS THE LANDED ONE, and it is the opposite of the design's first draft.
# `link65_mutation.sh:139` and `link62_mutation.sh:173` call each mutant's TARGETED leg directly and
# reserve the full-image hash for `M-golden` alone. Rows 1, 2, 5, 9, 10 and 15 all MOVE the image, so
# a hash in circuit would fire first and the named discriminator would never run. Here too: every row
# is graded on its own leg with the hash out of circuit; `M-golden` is the only row the hash grades,
# and it carries the landed `base == committed && mutant != committed` control without which a RED is
# not attributable.
#
# THE STATIC LEGS ARE THE GATE'S OWN, EXTRACTED -- NOT A COPY. `run_native_codegen_link66.sh` runs its
# sixteen static legs out of one `<<'PYEOF'` heredoc taking (spec, elf, src) and printing
# `ok|FAIL <leg> :: <detail>` plus a `STATIC-LEGS n ok m FAIL` summary. This file extracts that block
# by its heredoc markers (uniqueness asserted) and runs it against mutant images, so per-leg
# attribution is the gate's own leg names and a leg cannot drift from the gate it grades. The same is
# done for the forcing source, the no-buf-op reject probe, the boundary probe generator and the A1
# seed-channel block: every subject is lifted out of the production gate, never retyped.
#
# ANCHORING (the slice-1 fence, herbert ecf42cb). Every fragment patcher anchors on the ENTITY it
# mutates -- the named function, then the arm inside it -- never on the surrounding table shape. The
# bare arm `if op == 50:\n return 7` occurs TWICE in the fragment (the i386 chiefturbo table carries
# the same shape), so an unscoped anchor is ambiguous TODAY, not merely fragile later; each patcher
# therefore resolves `func <name>(` to a unique definition and patches inside its span.
#
#   ROW  MUTANT              LAYER    CHANGE                                  DISCRIMINATOR (the leg)
#    1   M-decorative        emitter  dead 48 8B 04 CA appended to op 49,     `sites` (+`counts`):
#                                     its size added to nc_tap_op_size, so    a raw window at no
#                                     the length invariants do NOT pre-empt   predicted offset
#    2   M-literal           source   push 4294967296 -> 3389295432, whose    `rawdecode`: a raw hit
#                                     imm64 IS the bytes 48 8B 04 CA; the op  at no instruction
#                                     sequence and every offset are unchanged boundary
#    3   M-recursionstore    source   chain program: one dead get + one dead   black-box floor only
#                                     set, nothing stored, answers constant   (GRADE ok=0 q*.ans)
#    4   M-deadsib           source   the SOLE indexed op sits in a            black-box floor only
#                                     constant-false arm; nothing stored      (shares row 3's leg)
#    5   M-underindex        image    the EDGE probe's baked index rewritten   fault into guard_lo:
#                                     262143 -> 2^64-1 (size-preserving), so  marker, then NO
#                                     the same image now reaches guard_lo     completion -- QEMU AND
#                                                                             BOCHS (A2)
#    6   M-noguardlo         emitter  the lower guard PDE made PRESENT        `pd-guards` (static) +
#                                                                             the -1 probe COMPLETES
#                                                                             -- both engines (A2)
#    7   M-scale4            emitter  SIB scale 8 -> 4 on ops 50 and 51       `rawdecode` (static) +
#                                                                             the 262144 probe ANSWERS
#                                                                             -- both engines (A2)
#    8   M-basebias          emitter  bufbase immediate + 8                   `bufbase-eq`. Its
#                                                                             RUNTIME leg is GREEN BY
#                                                                             DESIGN and is not run
#    9   M-wrongidx          image    serve's `hi * 256` immediate -> 257, so  answer stream
#                                     every query with hi=1 gathers buf[k+1]  mismatches the table
#   10   M-constidx          image    serve's gather SIB CA -> E2 (index      answer stream collapses;
#                                     field = none) -> buf[0] every time      index echoes stay right
#   11   M-memsz             emitter  p_memsz reverted to filesz+16384        `pmemsz`
#   12   M-opsize-49         emitter  nc_tap_op_size(49) 11 -> 12             ERR 610, no a.out
#   13   M-opsize-50         emitter  nc_tap_op_size(50) 7 -> 8               ERR 611, no a.out
#   14   M-opsize-51         emitter  nc_tap_op_size(51) 8 -> 9               ERR 611, no a.out
#   15   M-golden            image    one image byte perturbed                the committed hash, with
#                                                                             the base-matches control
#   16   M-nopredicate       emitter  the two-guard LAYOUT arm forced false   `pd-guards` + `bufbase-eq`
#                                     for a buffer-using program              (static only, by ruling)
#   17   M-noirgate          emitter  the IR `>= 1` op-50/51 gate removed     the no-buf-op probe
#                                                                             COMPILES where it must
#                                                                             be refused (ERR 655)
#   18   M-pops              emitter  the 49/50/51 arms deleted from          ERR 605: the depth walk
#                                     nc_tap_pops AND nc_tap_pushes           mis-verifies
#   19   M-op51noret         emitter  op 51's `52` (push rdx) -> `90` NOP,    the FILL ECHO mismatches
#                                     size-preserving so ERR 611 cannot       (deterministic RED,
#                                     pre-empt the test                       non-deterministic witness)
#   20   M-seedpin-env       harness  the LINK66_SEED refusal removed and     `seed-refusal` must go
#                                     the variable supplied                   RED; and a program with
#                                                                             the answers BAKED from
#                                                                             the attacker's seed then
#                                                                             grades ok=1 (one boot)
#   21   M-seedpin-internal  harness  the feeder ignores the driver's seed    TWO legs: `seed-echo`
#                                     channel and prints an internal constant (bootless) AND
#                                                                             `seed-freshness`
#   22   M-driverpin         driver   the supervising draw pinned to a        `seed-freshness` ONLY --
#                                     constant; the harness prints it         `seed-echo` is GREEN here
#                                     faithfully                              BY DESIGN, and saying so
#                                                                             is the point of the row
#
#   23   M-seedpin-late      harness  the harness prints the DRIVER'S value    the DRIVER'S INDEPENDENT
#                                     VERBATIM and then generates both        DERIVATION. Neither A1 leg
#                                     streams from an internal constant --     sees it: seed-echo is GREEN
#                                     the pin moved AFTER the print, not      (the printed line IS the
#                                     before it                                drawn one) and seed-freshness
#                                                                              is GREEN (two runs print two
#                                                                              different DRAWN values). Only
#                                                                              the gate's second derivation
#                                                                              of the whole receive
#                                                                              transcript catches it.
#                                                                              Row 23 by parent ruling
#                                                                              2026-09-03, after a blind
#                                                                              refutation leg built the
#                                                                              shape and found no chartered
#                                                                              row covering it
#
# ROW 13 IS GRADED ON THE BOUNDARY PROBE, NOT ON THE FORCING PROGRAM, AND THE REASON IS MEASURED.
# A3.1 put `bufget(b, 262144)` -- an op 50 -- into the forcing program's MAIN, and main's block-length
# invariant (ERR 610) is checked BEFORE the callee block's (ERR 611, fragment :21080 vs :21085). So a
# mis-sized op 50 on the forcing program fires 610, not the 611 the design names; measured, both:
#     size50/forcing -> ERR 610      size50/b_edge -> ERR 611
# The boundary probe's main holds only ops 49 and 20, and its callee holds ops 50 and 51, so the
# callee invariant is the one that fires. Rows 12 and 14 keep the forcing program (49 is main-only,
# 51 is callee-only there), so only row 13 moves probe, and it is recorded rather than absorbed.
set -uo pipefail
unset CDPATH
# The two derivations share an interpreter and its startup is attacker-reachable -- the same
# scrub the gate carries, for the same reason (a sitecustomize.py that neuters random.Random
# makes the feeder and the driver's oracle agree on a pinned stream).
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP
export PYTHONNOUSERSITE=1
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || { echo "FAIL: link66-mutation (cannot resolve script_dir)"; exit 1; }
repo_root="$(cd -- "$script_dir/../.." && pwd)" || { echo "FAIL: link66-mutation (cannot resolve repo_root)"; exit 1; }
# shellcheck source=/dev/null
source "$script_dir/native_codegen_oracle.sh" || { echo "FAIL: link66-mutation (cannot source the native-codegen oracle)"; exit 1; }
backend="$repo_root/stack/native_compile_fragment.herb"
spec="$script_dir/longbuf_spec.py"
feeder="$script_dir/kernel_io_feed.py"
gate="$script_dir/run_native_codegen_link66.sh"
goldens_dir="$script_dir/link66_goldens"
for f in "$backend" "$spec" "$feeder" "$gate"; do
    [[ -f "$f" ]] || { echo "FAIL: link66-mutation (missing $f)"; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
fail_test() { echo "FAIL: link66-mutation ($1)"; fail=$((fail + 1)); }
RAN=""
# EVERY SCORE IS NAMED, and the banner is built from THIS LEDGER rather than from a fixed string.
# Both review lenses landed the same BLOCKER independently: on a host with no QEMU the whole
# booting block is skipped, `fail` stays 0, and a fixed banner still asserted that twenty-two
# mutants bit. The file's own comment said not to do that; the code did it anyway.
scored()    { pass=$((pass + 1)); RAN="$RAN $1"; }
row_ran()   { case " $RAN " in *" $1"*) return 0 ;; *) return 1 ;; esac; }
okleg()     { scored "${1%% *}"; echo "  ok   $1"; }

N=512
Q=64
WANT_RX=$(( N + 3 * Q + 1 ))     # 705 at (512,64): the transcript plus A3.1's witness byte
MARKER="41"                      # output_byte(65), the boundary probes' progress barrier
SENTHEX="5a"

QEMU_BIN="${QEMU_PREFIX:+$QEMU_PREFIX/bin/}qemu-system-x86_64"
have_qemu()  { command -v "$QEMU_BIN" >/dev/null 2>&1 || [[ -x "$QEMU_BIN" ]]; }
# THE BOCHS VERSION IS DETECTED, NEVER WRITTEN DOWN. A review leg caught both banners hardcoding
# "Bochs 2.7" while CI pins bochs 2.8 -- so in CI the banner would have named a version that did
# not run, in a suite whose whole doctrine is that a banner states only what executed.
bochs_version() { bochs --help 2>&1 | grep -oE 'Bochs x86 Emulator [0-9][0-9.]*' | head -1 | grep -oE '[0-9][0-9.]*$' || true; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
free_port() { python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
feeder_wait() { local log="$1" i; for i in $(seq 1 80); do grep -q LISTENING "$log" && return 0; grep -q NOCONN "$log" && return 1; sleep 0.1; done; return 1; }
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
boot_legs=1
bochs_ran=0
if ! have_qemu; then
    boot_legs=0
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        echo "FAIL: link66-mutation (KERNEL_CODEGEN_REQUIRE_EMU=1 but no QEMU at ${QEMU_BIN})"; exit 1
    fi
    echo "NOTE: QEMU absent; link66-mutation's booting rows are SKIPPED locally. Authoritative in kernel-codegen CI."
fi

# ---------------------------------------------------------------- lift the gate's own entities
# Each extraction asserts its anchor is UNIQUE. A mutation proof whose subject silently became the
# wrong text is the failure class this whole file exists to catch, so it fails closed on its own
# extraction before it grades anything.
extract_between() { # opener-regex closer-regex outfile why
    local open_re="$1" close_re="$2" out="$3" why="$4" n
    n="$(grep -cE "$open_re" "$gate")"
    [[ "$n" -eq 1 ]] || { echo "FAIL: link66-mutation (extract $why: opener matched $n times, want 1)"; exit 1; }
    awk -v o="$open_re" -v c="$close_re" '$0 ~ o {f=1; next} f && $0 ~ c {exit} f' "$gate" > "$out"
    [[ -s "$out" ]] || { echo "FAIL: link66-mutation (extract $why: empty)"; exit 1; }
}
static_py="$tmp/static_legs.py"
extract_between "<<'PYEOF'$" '^PYEOF$' "$static_py" "the gate's static-leg block"
extract_between '^cat > "\$tmp/forcing.herb" <<.EOS.$' '^EOS$' "$tmp/forcing.herb" "the forcing source"
extract_between '^cat > "\$tmp/nobufop.herb" <<.EOS.$' '^EOS$' "$tmp/nobufop.herb" "the no-buf-op reject probe"
extract_between '^cat > "\$tmp/oneidx.herb" <<.EOS.$' '^EOS$' "$tmp/oneidx.herb" "the one-indexed-op accept probe"
extract_between '^cat > "\$tmp/singlefunc.herb" <<.EOS.$' '^EOS$' "$tmp/singlefunc.herb" "the single-function reject probe"
# The gate's boundary-image decoder and its D26 frame-rule fixtures, lifted whole so the two rows
# that grade them exercise the production text rather than a restatement of it.
for _fn in frame_scan frame_count frame_last frame_verdict grade_bochs_boundary; do
    _n="$(grep -cE "^$_fn\\(\\) " "$gate")"
    [[ "$_n" -eq 1 ]] || { echo "FAIL: link66-mutation (extract the Bochs frame rule: $_fn defined $_n times in the gate, want 1)"; exit 1; }
done
awk '/^frame_scan\(\) \{/{f=1} /^grade_bochs_boundary\(\) \{/{exit} f' "$gate" > "$tmp/frames.sh"
for fn in frame_scan frame_count frame_last frame_verdict; do
    _n="$(grep -cE "^$fn\\(\\) " "$tmp/frames.sh")"
    [[ "$_n" -eq 1 ]] || { echo "FAIL: link66-mutation (the extracted Bochs frame rule defines $fn $_n times, want 1)"; exit 1; }
done
_n="$(grep -cE "^golden_leg\\(\\) \\{" "$gate")"
[[ "$_n" -eq 1 ]] || { echo "FAIL: link66-mutation (extract golden_leg: matched $_n times, want 1)"; exit 1; }
awk '/^golden_leg\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$gate" > "$tmp/golden_leg.sh"
grep -q 'is not exactly 65 bytes' "$tmp/golden_leg.sh" || { echo "FAIL: link66-mutation (extract golden_leg: the 65-byte representation check is missing)"; exit 1; }
# golden_leg reports through the GATE's ok()/bad(). This file grades it on its RETURN VALUE and keeps
# its own ledger, so those two are quiet shims here -- not wired to okleg()/fail_test(), which would
# let an extracted function move this file's counters behind its back.
ok()  { :; }
bad() { :; }
# shellcheck source=/dev/null
source "$tmp/golden_leg.sh" || { echo "FAIL: link66-mutation (cannot source the extracted golden_leg)"; exit 1; }
_n="$(grep -cE "^boundary_static\\(\\) \\{" "$gate")"
[[ "$_n" -eq 1 ]] || { echo "FAIL: link66-mutation (extract boundary_static: matched $_n times, want 1)"; exit 1; }
awk '/^boundary_static\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$gate" > "$tmp/boundary_static.sh"
grep -q 'BOUNDARY-STATIC' "$tmp/boundary_static.sh" || { echo "FAIL: link66-mutation (extract boundary_static: body missing)"; exit 1; }
# The gate's D26 FIXTURES are deliberately NOT extracted: three of them begin with the same `printf
# 'boot noise` line, so no single opener is unique and a uniqueness guard that passed would be lying.
# Row 28 builds the two fixtures that matter itself -- fixtures are data. What IS extracted, and what
# the row actually grades, is the production RULE (frame_verdict, above).
# the boundary generator (SENTINEL + boundary_src) and the A1 seed channel, sourced/run as-is
# Uniqueness FIRST, then extract. A review leg was right that greping the extracted text for what it
# ought to contain is not a uniqueness check: two definitions both extract, and the later shell
# definition silently wins.
for _pair in "^SENTINEL=:the boundary generator's sentinel" "^boundary_src\\(\\) \\{:boundary_src"; do
    _re="${_pair%%:*}"; _why="${_pair#*:}"
    _n="$(grep -cE "$_re" "$gate")"
    [[ "$_n" -eq 1 ]] || { echo "FAIL: link66-mutation (extract $_why: matched $_n times, want 1)"; exit 1; }
done
awk '/^SENTINEL=/{f=1} f{print} f && /^}$/{exit}' "$gate" > "$tmp/boundary_src.sh"
grep -q '^boundary_src() {' "$tmp/boundary_src.sh" || { echo "FAIL: link66-mutation (extract boundary_src: not found)"; exit 1; }
# shellcheck source=/dev/null
source "$tmp/boundary_src.sh" || { echo "FAIL: link66-mutation (cannot source the extracted boundary generator)"; exit 1; }
for _pair in "^# -+ A1: the seed channel\$:the A1 seed-channel opener" "^echo \"LINK66_SEED=:the A1 printed line" "^DRIVER_SEED=:the seed concatenation"; do
    _re="${_pair%%:*}"; _why="${_pair#*:}"
    _n="$(grep -cE "$_re" "$gate")"
    [[ "$_n" -eq 1 ]] || { echo "FAIL: link66-mutation (extract $_why: matched $_n times, want 1)"; exit 1; }
done
awk '/^# -+ A1: the seed channel$/{f=1} f{print} f && /^echo "LINK66_SEED=/{exit}' "$gate" > "$tmp/seedchan.sh"
grep -q 'LINK66_SEED is set' "$tmp/seedchan.sh" || { echo "FAIL: link66-mutation (extract the A1 seed channel: refusal not found)"; exit 1; }
grep -q '^echo "LINK66_SEED=' "$tmp/seedchan.sh" || { echo "FAIL: link66-mutation (extract the A1 seed channel: no printed line)"; exit 1; }

# ---------------------------------------------------------------- compilers, probes, derivation
native_codegen_ensure_compiler "$tmp/gen1" || { echo "FAIL: link66-mutation (cannot acquire the C-free gen-1 compiler)"; exit 1; }

# The fragment patcher. Every mode resolves `func <name>(` to a UNIQUE definition and patches inside
# that function's span, because the bare arms are NOT unique in the fragment: `if op == 50:` +
# `return 7` occurs twice (the i386 chiefturbo table carries the same shape). An unscoped anchor is
# ambiguous today, not merely fragile later -- which is the slice-1 lesson applied before it bites.
cat > "$tmp/frag_patch.py" <<'PPEOF'
import re, sys
mode, srcpath, out = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(srcpath).read()
def span(s, name):
    ms = [m for m in re.finditer(r"^func %s\(" % re.escape(name), s, re.M)]
    assert len(ms) == 1, "%s: %d definitions (anchor is not unique)" % (name, len(ms))
    a = ms[0].start(); b = s.find("\nend\n", a)
    assert b > 0, "%s: unterminated" % name
    return a, b + 5
def infunc(s, name, old, new):
    a, b = span(s, name); body = s[a:b]
    assert body.count(old) == 1, "%s: %d hits for %r inside the function" % (name, body.count(old), old[:48])
    return s[:a] + body.replace(old, new, 1) + s[b:]
def once(s, old, new, why):
    assert s.count(old) == 1, "%s: %d hits" % (why, s.count(old))
    return s.replace(old, new, 1)
GET_SIB = "        do append(obuf, 202)   -- CA  mov rax,[rdx+rcx*8]   (SIB scale bits 11 = x8)\n"
SET_SIB = "        do append(obuf, 200)   -- C8  mov [rax+rcx*8],rdx   (SIB scale bits 11 = x8)\n"
BASE_IMM = "        obuf = nc_append_le64(obuf, buf_2m)\n"
if mode == "decorative":
    src = infunc(src, "nc_tap_lower_body", BASE_IMM + "        do append(obuf, 80)    -- 50  push rax\n",
                 BASE_IMM + "        do append(obuf, 80)    -- 50  push rax\n"
                 + "".join("        do append(obuf, %d)\n" % b for b in (72, 139, 4, 202)))
    src = infunc(src, "nc_tap_op_size", "    if op == 49:\n        return 11\n    end\n",
                 "    if op == 49:\n        return 15\n    end\n")
elif mode == "noguardlo":
    src = infunc(src, "nc_tap_emit_pd_loop",
                 "    elif i * 2097152 == guard_lo_2m:\n        buf = nc_append_le32(buf, 0)\n        buf = nc_append_le32(buf, 0)\n",
                 "    elif i * 2097152 == guard_lo_2m:\n        buf = nc_append_le32(buf, i * 2097152 + 131)\n        buf = nc_append_le32(buf, 0)\n")
elif mode == "scale4":
    src = infunc(src, "nc_tap_lower_body", GET_SIB, "        do append(obuf, 138)   -- 8A  mov rax,[rdx+rcx*4]  (M-scale4)\n")
    src = infunc(src, "nc_tap_lower_body", SET_SIB, "        do append(obuf, 136)   -- 88  mov [rax+rcx*4],rdx  (M-scale4)\n")
elif mode == "basebias":
    src = infunc(src, "nc_tap_lower_body", BASE_IMM, "        obuf = nc_append_le64(obuf, buf_2m + 8)\n")
elif mode == "memsz":
    src = once(src, "        memsz = guard_2m - 1048576\n", "        memsz = filesz + 16384\n", "the buffer-mode p_memsz override")
elif mode in ("opsize49", "opsize50", "opsize51"):
    op, old, new = {"opsize49": (49, 11, 12), "opsize50": (50, 7, 8), "opsize51": (51, 8, 9)}[mode]
    src = infunc(src, "nc_tap_op_size", "    if op == %d:\n        return %d\n    end\n" % (op, old),
                 "    if op == %d:\n        return %d\n    end\n" % (op, new))
elif mode == "nopredicate":
    src = once(src, "    if uses_buf:\n        guard_lo_2m = guard_2m\n", "    if false:\n        guard_lo_2m = guard_2m\n",
               "the two-guard LAYOUT arm")
elif mode == "noirgate":
    src = once(src, "        if nc_tap_idx_ops(funcs, 0, nf, 0) < 1:\n", "        if false:\n", "the IR >= 1 gate")
elif mode == "irgate2":
    # The SAME gate, moved the other way: >= 2 indexed ops. This is the POSITIVE side of the
    # boundary -- a buffer-mode program with EXACTLY ONE indexed op must still compile, and
    # `accept-oneidx` is the only leg that says so.
    src = once(src, "        if nc_tap_idx_ops(funcs, 0, nf, 0) < 1:\n", "        if nc_tap_idx_ops(funcs, 0, nf, 0) < 2:\n", "the IR >= 1 gate (raised to 2)")
elif mode == "singlefunc":
    # Route SINGLE-function programs down the multi-function tap path too, so the device-op
    # multi-function rule stops rejecting them. `reject-singlefunc` is the only leg that sees it.
    src = infunc(src, "nc_emit_multiboot32_long64_program",
                 "    if count(funcs) != 1:\n        return nc_tap_emit_program(funcs, prog.2)\n",
                 "    if true:\n        return nc_tap_emit_program(funcs, prog.2)\n")
elif mode == "pops":
    src = infunc(src, "nc_tap_pops", "    if op == 49:\n        return 0\n    end\n    if op == 50:\n        return 2\n    end\n    if op == 51:\n        return 3\n    end\n", "")
    src = infunc(src, "nc_tap_pushes", "    if op == 49:\n        return 1\n    end\n    if op == 50:\n        return 1\n    end\n    if op == 51:\n        return 1\n    end\n", "")
elif mode == "op51noret":
    src = infunc(src, "nc_tap_lower_body", "        do append(obuf, 82)    -- 52  push rdx\n",
                 "        do append(obuf, 144)   -- 90  NOP (M-op51noret: size-preserving)\n")
else:
    raise SystemExit("unknown fragment mutation %s" % mode)
open(out, "w").write(src)
print("PATCHED %s" % mode)
PPEOF

MUTC=""     # set by mint_mutant
mint_mutant() { # mode -> mints a mutant compiler into $tmp/cc.<mode>, sets MUTC
    local mode="$1"
    # NAMED `frag_<mode>.herb` DELIBERATELY. The slice-1 fence discovers fragment-patching proofs
    # with `grep -l 'frag_' bootstrap/tests/run_native_codegen_link*_mutation.sh`, so a file that
    # spelled its temporaries `frag.<mode>.herb` would be invisible to the sweep that exists to
    # stop an emitter edit breaking it -- the exact failure that made CI run 33736740372 RED.
    local frag="$tmp/frag_$1.herb" md="$tmp/mint.$1"
    MUTC=""
    python3 -I "$tmp/frag_patch.py" "$mode" "$backend" "$frag" > "$tmp/patch.$mode.log" 2>&1 \
        || { fail_test "$mode: the fragment patcher did not apply ($(tail -1 "$tmp/patch.$mode.log"))"; return 1; }
    rm -rf "$md"; mkdir -p "$md"
    ( cd -- "$md" && "$NATIVE_CODEGEN_COMPILER" < "$frag" >mint.out 2>mint.err )
    [[ -f "$md/a.out" ]] || { fail_test "$mode: the mutated fragment did not compile ($(head -1 "$md/mint.out" "$md/mint.err" 2>/dev/null | tr -d '\n'))"; return 1; }
    cp "$md/a.out" "$tmp/cc.$mode"; chmod +x "$tmp/cc.$mode"; MUTC="$tmp/cc.$mode"
    return 0
}

COMPILE_RC=0; COMPILE_MSG=""
compile_with() { # compiler src outdir -> sets COMPILE_RC/COMPILE_MSG, leaves $outdir/a.out on success
    local cc="$1" src="$2" d="$3"
    rm -rf "$d"; mkdir -p "$d"; cp "$src" "$d/probe.herb"
    ( cd -- "$d" && "$cc" < probe.herb >stdout.txt 2>err.txt )
    COMPILE_RC=$?
    COMPILE_MSG="$(head -1 "$d/stdout.txt" "$d/err.txt" 2>/dev/null | grep -v '^==>' | tr -d '\n')"
}
compiled_ok() { [[ "$COMPILE_RC" -eq 0 && -f "$1/a.out" ]]; }
# This toolchain's refusal convention is exit 0 with no image (the gate measured it and says so), so
# a refusal is rc==0 AND no a.out -- which still separates a principled refusal from a CRASH.
refused_ok()   { [[ "$COMPILE_RC" -eq 0 && ! -f "$1/a.out" ]]; }

# the probe sources: the forcing program and the reject probe are the GATE'S OWN (extracted above);
# the three boundary images come from the gate's own generator, sourced above.
boundary_src 262143               > "$tmp/b_edge.herb"
boundary_src 262144               > "$tmp/b_over.herb"
boundary_src 18446744073709551615 > "$tmp/b_under.herb"

compile_with "$NATIVE_CODEGEN_COMPILER" "$tmp/forcing.herb" "$tmp/base.forcing"
compiled_ok "$tmp/base.forcing" || { echo "FAIL: link66-mutation (the base forcing program did not compile: $COMPILE_MSG)"; exit 1; }
for lbl in edge over under; do
    compile_with "$NATIVE_CODEGEN_COMPILER" "$tmp/b_$lbl.herb" "$tmp/base.b_$lbl"
    compiled_ok "$tmp/base.b_$lbl" || { echo "FAIL: link66-mutation (the base boundary-$lbl probe did not compile: $COMPILE_MSG)"; exit 1; }
done

# ---------------------------------------------------------------- the gate's static legs, per image
STATIC_FAILS=""
static_legs() { # label elf src driverseed harnessecho [specpath] -> sets STATIC_FAILS
    local label="$1" elf="$2" src="$3" drv="$4" ech="$5" sp="${6:-$spec}" rc summary total
    STATIC_FAILS=""
    LINK66_DRIVER_SEED="$drv" LINK66_HARNESS_ECHO="$ech" \
        python3 -I "$static_py" "$sp" "$elf" "$src" > "$tmp/st.$label.out" 2>&1
    rc=$?
    summary="$(grep -E '^STATIC-LEGS ' "$tmp/st.$label.out" | tail -1)"
    if [[ "$rc" -ne 0 || -z "$summary" ]]; then
        # A CRASH IS NOT A RED. The block dying leaves no leg verdicts at all, and reading that as
        # "the mutant bit" is exactly the grading-nothing class this file is built against.
        STATIC_FAILS="__CRASH__"
        return 1
    fi
    total=$(( $(awk '{print $2}' <<<"$summary") + $(awk '{print $4}' <<<"$summary") ))
    if [[ "$total" -ne 16 ]]; then
        STATIC_FAILS="__SHORT__($total)"
        return 1
    fi
    STATIC_FAILS="$(awk '/^FAIL /{printf "%s ", $2}' "$tmp/st.$label.out")"
    return 0
}
has_leg() { grep -qE "^FAIL $2( |\$)" "$tmp/st.$1.out"; }

# ---------------------------------------------------------------- the driver's own derivation
# Everything predicted here comes from longbuf_spec's PRODUCTION functions -- the same module the
# gate derives with and the feeder deliberately does not import -- so this file predicts rather
# than re-implements. It also computes each booting mutant's PRECONDITION, because a mutant whose
# bite depends on the draw is vacuous on the draws where it cannot bite, and asserting the
# precondition BEFORE the boot is the difference between a proof and a coin flip.
derive() { # pay qry draw tag -> writes exp.<tag>.bin/.meta/.ans ; nonzero on failure
    python3 -I - "$spec" "$1" "$2" "$3" "$N" "$Q" "$tmp/exp.$4" <<'DEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
pay, qry, d, n, q, base = int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), sys.argv[7]
t, payload, queries = L.expected_transcript(pay, qry, d, n, q, witness=True)
open(base + ".bin", "wb").write(t)
answers = [payload[i] for i in queries]
open(base + ".ans", "w").write("\n".join(str(a) for a in answers) + "\n")
pb = L.expected_proof_byte(pay, qry, d, n, q)
# M-wrongidx's precondition is the SHIFTED ANSWER, not the shifted address. Both review lenses
# caught the first form: `i >= 256` proves an address changed, not that any ANSWER changed -- a draw
# whose every hi==1 query has payload[i+1] == payload[i] grades the row vacuously. `hi1` is kept for
# the record; `wrongidx` is what the leg now asserts.
hi1 = sum(1 for i in queries if i >= 256)
wrongidx = sum(1 for i in queries if 256 <= i < n - 1 and payload[i + 1] != payload[i])
nonzero = sum(1 for a in answers if a != 0)
diff0 = sum(1 for i in queries if payload[i] != payload[0])
open(base + ".meta", "w").write(
    "proof=%02x\nexit=%d\nhi1=%d\nwrongidx=%d\nnonzero=%d\ndiff0=%d\n"
    % (pb, L.qemu_exit_for(pb), hi1, wrongidx, nonzero, diff0))
print("DERIVED proof=%02x hi1=%d wrongidx=%d nonzero=%d diff0=%d" % (pb, hi1, wrongidx, nonzero, diff0))
DEOF
}
meta() { sed -n "s/^$2=//p" "$tmp/exp.$1.meta"; }

# ---------------------------------------------------------------- graded sessions on QEMU-TCG
S_GRADE=""; S_SEED=""; S_E9=""; S_RC=0; S_FRC=0; S_CAP=""; S_QKILL=0
qsession() { # label elf pay qry draw feederpath [drainmode]
    local label="$1" elf="$2" pay="$3" qry="$4" d="$5" fdr="$6" dm="${7:-eof}"
    local W="$tmp/$label.q"; rm -rf "$W"; mkdir -p "$W"
    S_QKILL=0
    local port; port=$(free_port)
    python3 -I "$fdr" "$port" --grade "$N:$Q" --draw "$d" --master-seed "$pay" --query-seed "$qry" \
        --witness --drain-mode "$dm" --cap "$W/cap.bin" > "$W/feed.log" 2>&1 &
    local fp=$!
    if ! feeder_wait "$W/feed.log"; then
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
        S_GRADE="HARNESS-NO-LISTEN"; S_SEED=""; S_E9=""; S_RC=-1; S_FRC=-1; S_CAP="$W/cap.bin"; return 1
    fi
    # QEMU IS STARTED DIRECTLY, NOT UNDER `timeout`, AND THE REASON IS A LEAK THIS FILE CAUSED AND
    # THEN MEASURED. With `timeout 120 qemu ... &`, `$!` is the TIMEOUT wrapper, not QEMU; killing the
    # wrapper after a RED verdict leaves QEMU running with nothing left to time it out, and it spins
    # at ~83% of a core forever. Observed: twenty-four orphaned qemu-system-x86_64 processes, the
    # oldest fifty minutes old, one per RED session across three smoke runs, taking the host's load
    # average from 0.4 to 27 -- on the very host whose quiet is the precondition for grading. So the
    # background job IS QEMU (kill -9 reaches it), and the 120 s ceiling is a separate watchdog that
    # leaves a marker when it fires, so a watchdog kill can never be read as the harness's own.
    "$QEMU_BIN" -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off,logfile="$W/wire.log" \
        -serial chardev:s0 -monitor none -cpu qemu64 -m 64M >/dev/null 2>&1 &
    local qp=$!
    ( sleep 120; kill -9 "$qp" 2>/dev/null && : > "$W/watchdog.fired" ) >/dev/null 2>&1 &
    local wd=$!
    wait "$fp" 2>/dev/null; S_FRC=$?
    S_GRADE="$(grep -E '^GRADE ' "$W/feed.log" | tail -1)"
    # A GUEST THAT FAILS A QUERY IS LEFT BLOCKED ON input_byte() FOREVER, and that is not a fault to
    # be graded -- it is the arithmetic of the protocol. An HONEST guest reaches its guard access and
    # triple-faults, so QEMU exits and the socket's EOF is what ends the feeder's drain; a guest the
    # feeder has already marked ok=0 gets no further bytes and simply waits. Waiting out the 120 s
    # kill for every RED session would cost more than the whole proof and would then report rc=124,
    # which this file's own rule (a kill is not a fault) has to reject. So the harness ends it here,
    # AFTER the verdict has been recorded, and says which of the two happened.
    if [[ "$S_GRADE" == *"ok=1"* ]]; then
        wait "$qp" 2>/dev/null; S_RC=$?
    else
        kill -9 "$qp" 2>/dev/null            # may already be gone; the wait below reports the truth
        wait "$qp" 2>/dev/null; S_RC=$?
        S_QKILL=1
    fi
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    # A WATCHDOG KILL IS A HARNESS FAILURE, not a verdict, and it is distinguishable because the
    # watchdog leaves a marker: without it, `S_RC=137` from a 120 s hang and `S_RC=137` from this
    # harness ending a decided session look identical.
    if [[ -f "$W/watchdog.fired" ]]; then
        S_QKILL=2
    fi
    S_SEED="$(sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' "$W/feed.log" | tail -1)"
    S_E9="$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')"
    S_CAP="$W/cap.bin"
    return 0
}
# The FULL green condition a graded draw must meet -- the gate's own, restated as one predicate so
# the control and the mutants are judged by the same rule: the feeder's verdict, the exact byte
# count, the derived proof byte on the wire, a clean feeder exit, and A3.1's guard fault (no
# completion frame, qemu exit 0 under -no-reboot).
# A COMPLETE, HEALTHY GRADED SESSION -- everything except the driver's own derivation. A review leg
# found `qsession` returning 0 after LISTENING no matter what followed, so `seed-freshness` counted a
# feeder that printed its constant and then DIED TWICE as a successful bite. The freshness rows now
# require this first; it deliberately does NOT compare the capture or the witness to the driver's
# derivation, because row 21's whole point is a harness generating from something else.
session_healthy() { # -> echoes why not
    case "$S_GRADE" in *"ok=1"*"answers=$Q"*) : ;; *) echo "grade not ok=1/answers=$Q: ${S_GRADE:-<no GRADE line>}"; return 1 ;; esac
    case "$S_GRADE" in *"rx=$WANT_RX expected_rx=$WANT_RX extra=0"*) : ;; *) echo "byte count not exactly $WANT_RX: $S_GRADE"; return 1 ;; esac
    [[ "$S_FRC" -eq 0 ]] || { echo "the feeder exited $S_FRC"; return 1; }
    [[ -z "$S_E9" ]] || { echo "a completion frame '$S_E9' was emitted -- the guard access did not fault"; return 1; }
    [[ "$S_QKILL" -eq 2 ]] && { echo "the 120 s watchdog killed qemu -- the guest hung"; return 1; }
    [[ "$S_RC" -eq 0 ]] || { echo "qemu rc=$S_RC, want 0 for a triple fault under -no-reboot"; return 1; }
    return 0
}
session_green() { # label tag -> 0 iff every condition holds; echoes why not
    local label="$1" tag="$2" want_proof why; want_proof="$(meta "$tag" proof)"
    why="$(session_healthy)" || { echo "$why"; return 1; }
    if [[ ! "$S_GRADE" =~ witness=([0-9]+)$ ]] || [[ "${BASH_REMATCH[1]}" -ne $((16#$want_proof)) ]]; then
        echo "witness is not the derived proof byte $((16#$want_proof)): $S_GRADE"; return 1
    fi
    cmp -s "$S_CAP" "$tmp/exp.$tag.bin" || { echo "the capture is not the driver's derived transcript"; return 1; }
    return 0
}

# ---------------------------------------------------------------- bare boundary boots
B_CAP=""; B_E9=""; B_RC=0; B_FRC=0; B_LOG=""
qbare() { # label elf
    local label="$1" elf="$2"
    # Separate statement, deliberately: bash expands every word of a `local` line BEFORE the
    # assignments take effect, and `local` is DYNAMICALLY scoped, so `W="$tmp/$label.q"` on the
    # same line silently reads the CALLER's `label` instead of this one -- which works right up
    # until a caller names its variable something else.
    local W; W="$tmp/$label.q"; rm -rf "$W"; mkdir -p "$W"
    local port; port=$(free_port)
    python3 -I "$feeder" "$port" --cap "$W/cap.bin" --hold 12 > "$W/feed.log" 2>&1 &
    local fp=$!
    if ! feeder_wait "$W/feed.log"; then
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; B_CAP="HARNESS-NO-LISTEN"; B_RC=-1; B_FRC=-1; return 1
    fi
    # `-d int,cpu_reset` is requested here for the same reason the gate requests it: a review leg was
    # right that "marker, rc=0, no frame" accepts ANY post-marker triple fault, not the one the row is
    # named for. TCG traces the exception; the address is then checked, not inferred from an absence.
    timeout 120 "$QEMU_BIN" -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off \
        -serial chardev:s0 -monitor none -cpu qemu64 -m 64M -d int,cpu_reset -D "$W/qemu.log" >/dev/null 2>&1
    B_RC=$?
    wait "$fp" 2>/dev/null; B_FRC=$?
    B_CAP="$(xxd -p "$W/cap.bin" 2>/dev/null | tr -d '\n')"
    B_E9="$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')"
    B_LOG="$W/qemu.log"
    return 0
}
# The gate's own fault-attribution rule, restated on this side of the fence: a PAGE FAULT (v=0e)
# whose CR2 is the DERIVED address, escalating to a #DF. Anything else -- a fault somewhere else, a
# handled fault, a hang -- is not this row's verdict.
fault_at() { # label log want_cr2
    local pf
    if [[ ! -s "$2" ]]; then
        fail_test "$1 fault-attribution (no interrupt trace -- expected with -d int on TCG)"; return 1
    fi
    pf="$(grep -aoE "v=0e [^\n]*CR2=[0-9a-f]{16}" "$2" | grep -oE "CR2=[0-9a-f]{16}" | sort -u)"
    if [[ "$pf" != "CR2=$3" ]]; then
        fail_test "$1 fault-attribution (page-fault CR2 set is '${pf:-<none>}', want exactly 'CR2=$3' -- the fault must be AT the derived guard address, not merely somewhere)"; return 1
    fi
    if ! grep -aq "check_exception old: 0xe new 0xd" "$2"; then
        fail_test "$1 fault-attribution (the #PF did not escalate to a #DF -- a handled or unrelated fault is not this row's verdict)"; return 1
    fi
    echo "    $1 fault-attribution :: #PF v=0e CR2=$3 -> #DF -> triple fault (QEMU-TCG interrupt trace)"
    return 0
}

# ---------------------------------------------------------------- image forges
# Every forge is SIZE-PRESERVING and anchored on the entity it edits, so nothing downstream shifts
# and the named discriminator -- not a wholesale layout mismatch -- is what fires.
cat > "$tmp/forge.py" <<'FGEOF'
import struct, sys
mode, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
raw = bytearray(open(src, "rb").read())
CO = 4108                                  # the code's file offset (longbuf_spec.Image)
p_filesz = struct.unpack("<I", bytes(raw[68:72]))[0]
code = bytes(raw[CO:CO + p_filesz - 12])
def occ(pat, hay=None):
    hay = code if hay is None else hay
    out, i = [], 0
    while True:
        j = hay.find(pat, i)
        if j < 0:
            return out
        out.append(j); i = j + 1
def movabs(v):
    return b"\x48\xb8" + (v & ((1 << 64) - 1)).to_bytes(8, "little") + b"\x50"
if mode == "golden":
    raw[5000] ^= 0xFF                      # one byte, anywhere: only the committed hash grades this
elif mode == "wrongidx":
    # serve's `hi * 256` immediate -> 257. Every query with hi == 1 then gathers buf[k+1].
    hits = occ(movabs(256))
    assert len(hits) == 1, "the 256 immediate occurs %d times (want 1)" % len(hits)
    raw[CO + hits[0]:CO + hits[0] + 11] = movabs(257)
elif mode == "constidx":
    # serve's GATHER SIB CA -> E2: index field 100 with REX.X clear is "no index", so the
    # effective address collapses to [rdx] == buf[0] while both pops, and therefore the operand
    # stack and the index echoes, are untouched. The GUARD access in main is left alone -- it is
    # identified as the op-50 whose eleven-byte PUSH_INT of 262144 immediately precedes it.
    guard = occ(movabs(262144))
    assert len(guard) == 1, "the 262144 immediate occurs %d times (want 1)" % len(guard)
    guard_op50 = guard[0] + 11 + 2          # movabs+push, then `59 5A`, then 48 8B 04 CA
    hits = [h for h in occ(bytes.fromhex("488b04ca")) if h != guard_op50]
    assert len(hits) == 1, "serve's gather is not unique: %s (guard at %d)" % (hits, guard_op50)
    raw[CO + hits[0] + 3] = 0xE2
elif mode == "elfheader":
    # The phdr's p_type, which longbuf_spec.Image.header_ok() asserts is PT_LOAD == 1. Nothing else
    # reads it, so the ONLY leg that can see this is `elf-header` -- which is the point: the leg
    # exists because the location fields the whole analysis rests on were parsed and then ignored.
    struct.pack_into("<I", raw, 52, 2)
elif mode == "underindex":
    # the EDGE probe's baked index 262143 -> 2^64-1, so the SAME image now reaches guard_lo.
    hits = occ(movabs(262143))
    assert len(hits) == 1, "the 262143 immediate occurs %d times (want 1)" % len(hits)
    raw[CO + hits[0]:CO + hits[0] + 11] = movabs((1 << 64) - 1)
else:
    raise SystemExit("unknown forge %s" % mode)
open(dst, "wb").write(bytes(raw))
print("FORGED %s" % mode)
FGEOF
forge() { # mode in out
    python3 -I "$tmp/forge.py" "$1" "$2" "$3" > "$tmp/forge.$1.log" 2>&1 \
        || { fail_test "$1: the image forge did not apply ($(tail -1 "$tmp/forge.$1.log"))"; return 1; }
    [[ -f "$3" ]]
}

# ---------------------------------------------------------------- CONTROL: the base image is clean
# Every static RED below is attributable ONLY because the same battery passes all sixteen legs on the
# unmutated image. Without this control a broken checker reads as twenty-two successful bites.
CTRL_SEED="$(bash "$tmp/seedchan.sh" | sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p')"
[[ "${#CTRL_SEED}" -eq 32 ]] || { echo "FAIL: link66-mutation (the extracted A1 seed channel did not draw)"; exit 1; }
if static_legs base "$tmp/base.forcing/a.out" "$tmp/forcing.herb" "$CTRL_SEED" "$CTRL_SEED" && [[ -z "$STATIC_FAILS" ]]; then
    okleg "control-static (the unmutated forcing image passes all 16 gate static legs -- every RED below is the mutation's)"
else
    fail_test "control-static (the base image does NOT pass the gate's static battery: ${STATIC_FAILS:-<none>}) -- the checker is broken, so no RED below is attributable"
fi

# leg_red: the mutant must FAIL the NAMED leg. Reported with the full FAIL set, because a mutation
# that also trips neighbouring legs is information, not noise -- and because claiming "only this leg
# fired" without printing the set is the kind of unquoted claim this project logs.
leg_red() { # label elf src wantleg note
    local label="$1" elf="$2" src="$3" want="$4" note="$5"
    if ! static_legs "$label" "$elf" "$src" "$CTRL_SEED" "$CTRL_SEED"; then
        fail_test "$label: the static battery did not complete (${STATIC_FAILS}) -- NOT a bite"
        return 1
    fi
    if has_leg "$label" "$want"; then
        echo "$label bit RED on \`$want\`: $(grep -E "^FAIL $want " "$tmp/st.$label.out" | head -1 | cut -c1-160)"
        echo "    ($note; full FAIL set: ${STATIC_FAILS:-<none>})"
        scored "$label"; return 0
    fi
    fail_test "$label: \`$want\` did NOT fire (FAIL set: ${STATIC_FAILS:-<none>})"
    return 1
}

echo "  -- rows graded on the IMAGE or on the emitter's refusal to produce one (no boot) --"

# --- ROW 1: M-decorative -- a dead gather appended to op 49, its size declared, so the image stays
#     well-formed and ERR 610/611 cannot pre-empt the site legs.
if mint_mutant decorative; then
    compile_with "$MUTC" "$tmp/forcing.herb" "$tmp/m.decorative"
    if compiled_ok "$tmp/m.decorative"; then
        if leg_red M-decorative "$tmp/m.decorative/a.out" "$tmp/forcing.herb" sites \
            "the dead 48 8B 04 CA is a raw window at no predicted op-50 offset"; then
            # ASSERTED, not narrated. A review lens was right that `counts`, `sib-exclusivity`,
            # `pushints`, `displacements` and `windows` were firing here as FAIL-set spill while being
            # counted as "covered" -- coverage that nothing checks is not coverage.
            _dec_missing=""
            for _l in counts windows sib-exclusivity pushints displacements; do
                has_leg M-decorative "$_l" || _dec_missing="$_dec_missing $_l"
            done
            if [[ -n "$_dec_missing" ]]; then
                fail_test "M-decorative: these legs did NOT fire and were being counted as covered:$_dec_missing"
            else
                echo "    M-decorative ALSO bit RED on counts, windows, sib-exclusivity, pushints and displacements -- each REQUIRED here, so those five legs are covered by assertion rather than by spill"
            fi
        fi
    else
        fail_test "M-decorative: the probe did not compile under the decorative mutant ($COMPILE_MSG) -- a length invariant pre-empted the site legs, which is what declaring the size exists to prevent"
    fi
fi

# --- ROW 2: M-literal -- a SOURCE mutant that is LAYOUT-PRESERVING by construction. The only change
#     is one PUSH_INT's VALUE: 4294967296 -> 3389295432, whose little-endian imm64 begins with the
#     bytes 48 8B 04 CA. Every op, every offset and every window stays where the spec predicts, so
#     the ONLY thing that can fire is the raw-versus-decode conjunction -- a raw hit at no
#     instruction boundary. (Choosing a value-only edit is deliberate: a mutant that also moved the
#     layout would fire half the battery and prove nothing about `rawdecode` in particular.)
python3 -I - "$tmp/forcing.herb" "$tmp/literal.herb" <<'LEOF'
import sys
src = open(sys.argv[1]).read()
old, new = "return s * 4294967296", "return s * 3389295432"
assert src.count(old) == 1, "the grading-tail multiply is not unique (%d hits)" % src.count(old)
# 3389295432 == 0xCA048B48, so the imm64 is 48 8B 04 CA 00 00 00 00 -- the gather's own bytes.
assert (3389295432).to_bytes(8, "little")[:4] == bytes.fromhex("488b04ca")
open(sys.argv[2], "w").write(src.replace(old, new, 1))
print("SOURCE-MUTATED M-literal")
LEOF
if [[ -s "$tmp/literal.herb" ]]; then
    compile_with "$NATIVE_CODEGEN_COMPILER" "$tmp/literal.herb" "$tmp/m.literal"
    if compiled_ok "$tmp/m.literal"; then
        leg_red M-literal "$tmp/m.literal/a.out" "$tmp/literal.herb" rawdecode \
            "the raw gather pattern now occurs three times where the decode predicts two -- a raw hit inside a movabs immediate, at no instruction boundary"
    else
        fail_test "M-literal: the literal-bearing source did not compile ($COMPILE_MSG)"
    fi
else
    fail_test "M-literal: the source mutation did not apply"
fi

# --- ROW 6 (static half): M-noguardlo -- the lower guard PDE made present.
if mint_mutant noguardlo; then
    compile_with "$MUTC" "$tmp/forcing.herb" "$tmp/m.noguardlo"
    if compiled_ok "$tmp/m.noguardlo"; then
        if leg_red M-noguardlo-static "$tmp/m.noguardlo/a.out" "$tmp/forcing.herb" pd-guards \
            "the page directory now carries ONE non-present entry where the layout requires two"; then
            if has_leg M-noguardlo-static geometry; then
                echo "    M-noguardlo ALSO bit RED on \`geometry\` -- REQUIRED here, so that leg is covered by assertion rather than by spill"
            else
                fail_test "M-noguardlo-static: \`geometry\` did NOT fire and was being counted as covered"
            fi
        fi
    else
        fail_test "M-noguardlo: the forcing program did not compile under the mutant ($COMPILE_MSG)"
    fi
fi

# --- ROW 7 (static half): M-scale4 -- SIB scale 8 -> 4 on both indexed ops.
if mint_mutant scale4; then
    compile_with "$MUTC" "$tmp/forcing.herb" "$tmp/m.scale4"
    if compiled_ok "$tmp/m.scale4"; then
        leg_red M-scale4-static "$tmp/m.scale4/a.out" "$tmp/forcing.herb" rawdecode \
            "the scale-8 gather pattern is GONE (raw 0 against a predicted 2) and the scale-4 sibling is present"
    else
        fail_test "M-scale4: the forcing program did not compile under the mutant ($COMPILE_MSG)"
    fi
fi

# --- ROW 8: M-basebias -- the bufbase immediate biased by +8. ITS RUNTIME LEG IS GREEN BY DESIGN and
#     is deliberately NOT booted: fill and gather share the base, so the buffer round-trips from B+8
#     and every answer is right. The static equality is the only thing that sees it, which is exactly
#     why the design gave `bufbase-eq` a home.
if mint_mutant basebias; then
    compile_with "$MUTC" "$tmp/forcing.herb" "$tmp/m.basebias"
    if compiled_ok "$tmp/m.basebias"; then
        leg_red M-basebias "$tmp/m.basebias/a.out" "$tmp/forcing.herb" bufbase-eq \
            "the decoded movabs immediate is no longer the phdr-derived base. THE 'GREEN BY DESIGN' CLAIM IS NARROWER THAN THE DESIGN'S WORDING, and a review lens was right: it holds for the GRADED DRAW (fill and gather share the base, so the buffer round-trips from B+8 and every answer is correct), but the EDGE boundary probe would go RED under it -- 0x400008 + 8*262143 = 0x600000, the first byte of guard_hi. This file does not boot that probe: the design budgets no boot for row 8 and A2 would require a second engine for a fault-read verdict, so the observation is REPORTED to the parent rather than claimed here"
    else
        fail_test "M-basebias: the forcing program did not compile under the mutant ($COMPILE_MSG)"
    fi
fi

# --- ROW 11: M-memsz -- p_memsz reverted to the landed filesz+16384 under-declaration.
if mint_mutant memsz; then
    compile_with "$MUTC" "$tmp/forcing.herb" "$tmp/m.memsz"
    if compiled_ok "$tmp/m.memsz"; then
        leg_red M-memsz "$tmp/m.memsz/a.out" "$tmp/forcing.herb" pmemsz \
            "the segment no longer DECLARES the page it indexes; the assert is against a guard_hi derived from p_FILEsz, never from p_memsz"
    else
        fail_test "M-memsz: the forcing program did not compile under the mutant ($COMPILE_MSG)"
    fi
fi

# --- ROW 16: M-nopredicate -- the two-guard LAYOUT arm forced false for a buffer-using program.
#     Graded STATICALLY ONLY, by parent ruling 2026-09-03: A2 covers every mutant whose verdict is
#     read off a fault the CPU actually takes, and this row's discriminator is the page-directory
#     IMAGE, which no second engine reads differently.
if mint_mutant nopredicate; then
    compile_with "$MUTC" "$tmp/forcing.herb" "$tmp/m.nopredicate"
    if compiled_ok "$tmp/m.nopredicate"; then
        if leg_red M-nopredicate "$tmp/m.nopredicate/a.out" "$tmp/forcing.herb" pd-guards \
            "the whole two-guard layout is gone: the buffer page is never opened"; then
            # The design's table names TWO discriminators for this row. A review leg found the second
            # one printed as prose in the note and required nowhere, so it was asserted, not checked.
            if has_leg M-nopredicate bufbase-eq; then
                echo "    M-nopredicate ALSO bit RED on its second named discriminator \`bufbase-eq\`: $(grep -E '^FAIL bufbase-eq ' "$tmp/st.M-nopredicate.out" | head -1)"
            else
                fail_test "M-nopredicate: the row's SECOND named discriminator \`bufbase-eq\` did not fire (FAIL set: ${STATIC_FAILS:-<none>})"
            fi
        fi
    else
        fail_test "M-nopredicate: the forcing program did not compile under the mutant ($COMPILE_MSG)"
    fi
fi

# --- ROW 17: M-noirgate -- the IR >= 1 op-50/51 gate removed. The discriminator is not a leg of the
#     static battery at all: it is the gate's `reject-nobufop` leg, which requires the compiler to
#     REFUSE a buffer-mode program that never indexes the page.
compile_with "$NATIVE_CODEGEN_COMPILER" "$tmp/nobufop.herb" "$tmp/base.noirgate"
if refused_ok "$tmp/base.noirgate" && grep -q 'ERR 655' <<<"$COMPILE_MSG"; then
    okleg "control-noirgate (the UNMUTATED compiler refuses the no-buf-op probe: rc=$COMPILE_RC, no a.out, $COMPILE_MSG -- without this, \"the mutant compiled\" would prove nothing about the gate)"
else
    fail_test "control-noirgate (the unmutated compiler did not refuse the no-buf-op probe with ERR 655: rc=$COMPILE_RC a.out=$([[ -f "$tmp/base.noirgate/a.out" ]] && echo yes || echo no) $COMPILE_MSG) -- row 17's RED would not be attributable"
fi
if mint_mutant noirgate; then
    compile_with "$MUTC" "$tmp/nobufop.herb" "$tmp/m.noirgate"
    if compiled_ok "$tmp/m.noirgate"; then
        echo "M-noirgate bit RED on \`reject-nobufop\`: a buffer-mode program with NO indexed op COMPILED (a.out present, rc=$COMPILE_RC) where the unmutated compiler refuses it -- proven above, not assumed"
        scored M-noirgate
    else
        fail_test "M-noirgate: the no-buf-op probe was still refused with the gate removed ($COMPILE_MSG) -- the mutation did not reach the gate it names"
    fi
fi

# --- ROWS 12/13/14: M-opsize-49/50/51 -- one byte of declared size, and the block-length invariant
#     that must fire. Row 13 rides the BOUNDARY probe for the measured reason in this file's header:
#     A3.1 put an op 50 in the forcing program's main, and main's ERR 610 is checked first.
opsize_row() { # label mode probe wantERR why
    local label="$1" mode="$2" probe="$3" want="$4" why="$5"
    mint_mutant "$mode" || return 1
    compile_with "$MUTC" "$probe" "$tmp/m.$mode"
    if compiled_ok "$tmp/m.$mode"; then
        fail_test "$label: the probe COMPILED despite a mis-declared op size -- the length invariant did not fire"
        return 1
    fi
    if grep -q "$want" <<<"$COMPILE_MSG"; then
        echo "$label bit RED on \`$want\`: $COMPILE_MSG ($why; no a.out)"
        scored "$label"; return 0
    fi
    fail_test "$label: no a.out, but the failure was not $want ($COMPILE_MSG)"
    return 1
}
opsize_row M-opsize-49 opsize49 "$tmp/forcing.herb" "ERR 610" "op 49 lives in the forcing program's main, so the MAIN-block invariant is the one that fires"
opsize_row M-opsize-50 opsize50 "$tmp/b_edge.herb" "ERR 611" "graded on the boundary probe, whose main holds no op 50, so the CALLEE-block invariant is the one that fires"
opsize_row M-opsize-51 opsize51 "$tmp/forcing.herb" "ERR 611" "op 51 lives only in the callee \`fill\`, so the CALLEE-block invariant fires on the forcing program itself"

# --- ROW 18: M-pops -- the 49/50/51 arms deleted from BOTH stack-effect tables, so the depth walk
#     tracks the indexed ops as no-ops and mis-verifies.
if mint_mutant pops; then
    compile_with "$MUTC" "$tmp/forcing.herb" "$tmp/m.pops"
    if compiled_ok "$tmp/m.pops"; then
        fail_test "M-pops: the forcing program COMPILED with the indexed ops' stack effects falling through to 0/0"
    elif grep -q 'ERR 605' <<<"$COMPILE_MSG"; then
        echo "M-pops bit RED on \`ERR 605\`: $COMPILE_MSG (the depth walk rejects the body; no a.out)"
        scored M-pops
    else
        fail_test "M-pops: no a.out, but the failure was not ERR 605 ($COMPILE_MSG)"
    fi
fi

# --- ROW 15: M-golden -- one perturbed byte against the committed hash, WITH the landed control.
#     `base == committed` AND `mutant != committed`: without both halves a RED is not attributable
#     (link65_mutation.sh:312 is the precedent this restates).
if forge golden "$tmp/base.forcing/a.out" "$tmp/m_golden.elf"; then
    g_want="$(cat "$goldens_dir/forcing.sha256" 2>/dev/null || echo MISSING)"
    g_base="$(sha256sum "$tmp/base.forcing/a.out" | cut -d' ' -f1)"
    g_mut="$(sha256sum "$tmp/m_golden.elf" | cut -d' ' -f1)"
    if [[ "$g_base" == "$g_want" && "$g_mut" != "$g_want" ]]; then
        echo "M-golden bit RED on the committed hash: base == committed ($g_base) and the one-byte forge != committed ($g_mut)"
        scored M-golden
    else
        fail_test "M-golden: the hash leg is vacuous (base==committed:$([[ "$g_base" == "$g_want" ]] && echo yes || echo NO) forged!=committed:$([[ "$g_mut" != "$g_want" ]] && echo yes || echo NO); committed=$g_want)"
    fi
fi

echo "  -- the A1 seed channel: the driver's own draw, and the harness's echo of it (no boot) --"

# The subject here is the gate's OWN A1 block, lifted out of `run_native_codegen_link66.sh` and run
# standalone. It is the whole of the gate that executes before any compiler or emulator is touched --
# the refusal, the two independent draws, the length and inequality checks, and the one printed line
# -- so grading it standalone grades the production text, not a model of it.
mutate_seedchan() { # mode out
    python3 -I - "$tmp/seedchan.sh" "$1" "$2" <<'SEOF'
import sys
src = open(sys.argv[1]).read(); mode = sys.argv[2]; out = sys.argv[3]
REFUSAL = ('if [[ -n "${LINK66_SEED:-}" ]]; then\n'
           '    echo "FAIL: link66 (LINK66_SEED is set; a graded run takes its seed from the supervising driver)"\n'
           '    exit 1\n'
           'fi\n')
if mode == "seedpin-env":
    assert src.count(REFUSAL) == 1, "the refusal block is not unique (%d hits)" % src.count(REFUSAL)
    src = src.replace(REFUSAL, 'if [[ -n "${LINK66_SEED:-}" ]]; then\n    LINK66_ENV_OVERRIDE="$LINK66_SEED"\nfi\n', 1)
    anchor = 'DRIVER_SEED="${DRIVER_PAY}${DRIVER_QRY}"\n'
    assert src.count(anchor) == 1, "the seed concatenation is not unique"
    src = src.replace(anchor, anchor + 'if [[ -n "${LINK66_ENV_OVERRIDE:-}" ]]; then\n'
                      '    DRIVER_PAY="${LINK66_ENV_OVERRIDE:0:16}"; DRIVER_QRY="${LINK66_ENV_OVERRIDE:16:16}"\n'
                      '    DRIVER_SEED="$LINK66_ENV_OVERRIDE"\nfi\n', 1)
elif mode == "driverpin":
    n, acc = 0, []
    for line in src.splitlines(True):
        if line.startswith("DRIVER_PAY="):
            acc.append('DRIVER_PAY="0123456789abcdef"\n'); n += 1
        elif line.startswith("DRIVER_QRY="):
            acc.append('DRIVER_QRY="fedcba9876543210"\n'); n += 1
        else:
            acc.append(line)
    assert n == 2, "expected exactly two draw sites, found %d" % n
    src = "".join(acc)
else:
    raise SystemExit("unknown seed-channel mutation " + mode)
open(out, "w").write(src)
print("SEED-CHANNEL MUTATED " + mode)
SEOF
}
draw_seed() { # seedchan-path -> echoes the 32-hex seed, empty on refusal
    bash "$1" 2>/dev/null | sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' | head -1
}

# --- CONTROL for row 20: the unmutated channel REFUSES an inherited seed, non-zero, with its line.
ATTACK_SEED="deadbeefdeadbeef0123456789abcdef"
env LINK66_SEED="$ATTACK_SEED" bash "$tmp/seedchan.sh" > "$tmp/refuse.base.out" 2>&1
r_rc=$?
if [[ "$r_rc" -ne 0 ]] && grep -qs 'LINK66_SEED is set' "$tmp/refuse.base.out"; then
    okleg "control-seed-refusal (the unmutated A1 channel refuses an inherited LINK66_SEED: rc=$r_rc, $(head -1 "$tmp/refuse.base.out"))"
else
    fail_test "control-seed-refusal (the unmutated channel did NOT refuse: rc=$r_rc; $(head -1 "$tmp/refuse.base.out")) -- row 20's RED would not be attributable"
fi

# --- ROW 20 (first half): the refusal removed -> the seed becomes attacker-chosen.
if mutate_seedchan seedpin-env "$tmp/seedchan.env.sh" > "$tmp/seedchan.env.log" 2>&1; then
    env LINK66_SEED="$ATTACK_SEED" bash "$tmp/seedchan.env.sh" > "$tmp/refuse.mut.out" 2>&1
    m_rc=$?
    m_seed="$(sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' "$tmp/refuse.mut.out" | head -1)"
    if [[ "$m_rc" -eq 0 && "$m_seed" == "$ATTACK_SEED" ]]; then
        echo "M-seedpin-env bit RED on \`seed-refusal\`: with the refusal removed the channel STARTS (rc=0) and prints the ATTACKER'S value verbatim -- LINK66_SEED=$m_seed. The challenge is no longer drawn; it is supplied."
        scored M-seedpin-env
    else
        fail_test "M-seedpin-env: the refusal-removed channel did not honour the override (rc=$m_rc seed='${m_seed:-<none>}' want '$ATTACK_SEED')"
    fi
else
    fail_test "M-seedpin-env: the seed-channel mutation did not apply ($(tail -1 "$tmp/seedchan.env.log"))"
fi

# --- ROW 22 (its driver): the supervising draw pinned to a constant.
mutate_seedchan driverpin "$tmp/seedchan.pin.sh" > "$tmp/seedchan.pin.log" 2>&1 \
    || fail_test "M-driverpin: the seed-channel mutation did not apply ($(tail -1 "$tmp/seedchan.pin.log"))"

# --- ROW 21 (its harness): the feeder ignores the driver's channel and substitutes a constant.
python3 -I - "$feeder" "$tmp/feed_pinned.py" <<'FEOF'
import sys
src = open(sys.argv[1]).read()
anchor = '    print("LINK66_SEED=%016x%016x (drawn: supervisor)" % (master_seed, query_seed), flush=True)\n'
assert src.count(anchor) == 1, "the feeder's single named seed line is not unique (%d hits)" % src.count(anchor)
# The pin goes BEFORE the print and before rp/rq are built, so the harness prints its constant AND
# generates from it -- the exact shape all three frozen-check verifiers broke the frozen design on.
pin = ("    master_seed = 0x1111111111111111\n"
       "    query_seed = 0x2222222222222222\n")
open(sys.argv[2], "w").write(src.replace(anchor, pin + anchor, 1))
print("HARNESS MUTATED M-seedpin-internal")
FEOF
[[ -s "$tmp/feed_pinned.py" ]] || fail_test "M-seedpin-internal: the harness mutation did not apply"

# --- ROW 23. It began life as an addition raised to the parent rather than slipped in. A blind
#     refutation lens found a seed-channel shape no chartered row covers: a harness that prints the
#     driver's value VERBATIM and then generates its two streams from a constant. `seed-echo` is
#     green against it (the printed line is the drawn one) and `seed-freshness` is green against it
#     (two runs print two different drawn values), so both A1 legs miss it entirely. The only thing
#     that catches it is the gate's INDEPENDENT DERIVATION -- the driver rebuilding the whole
#     705-byte transcript in longbuf_spec and requiring the capture to equal it -- and the gate's own
#     header calls that "THE ANSWER TO THE SHARPEST FINDING THE REVIEW ROUND PRODUCED". Nothing
#     proved it bites. This row does. Raised as an addition and ACCEPTED as row 23 on 2026-09-03;
#     SCOPE-BUILD.md's table and boot accounting carry it now. It costs one QEMU session.
python3 -I - "$feeder" "$tmp/feed_late.py" <<'LEOF'
import sys
src = open(sys.argv[1]).read()
anchor = '    print("LINK66_SEED=%016x%016x (drawn: supervisor)" % (master_seed, query_seed), flush=True)\n'
assert src.count(anchor) == 1, "the feeder's single named seed line is not unique (%d hits)" % src.count(anchor)
# AFTER the print, not before: the line the driver compares is the honest one, and only the
# generation is pinned. That is exactly the shape seed-echo and seed-freshness cannot see.
pin = ("    master_seed = 0x3333333333333333\n"
       "    query_seed = 0x4444444444444444\n")
open(sys.argv[2], "w").write(src.replace(anchor, anchor + pin, 1))
print("HARNESS MUTATED M-seedpin-late (echo faithful, generation pinned)")
LEOF
[[ -s "$tmp/feed_late.py" ]] || fail_test "M-seedpin-late: the harness mutation did not apply"

# --- ROW 21 (first leg): `seed-echo`, in the gate's own static battery, with NO boot.
# The probe below only makes a harness PRINT its line -- it starts the production feeder on its real
# argv channel with a degenerate rung and lets a throwaway peer connect and close, exactly as the
# gate's own bootless probe does. The GRADING is the gate's `seed-echo` leg, run out of the extracted
# static block; this file decides nothing about equality itself.
SE_PAY=""; SE_QRY=""
echo_probe() { # feederpath outfile -> leaves the printed seed in <outfile>.val
    local fdr="$1" out="$2" p; p=$(free_port)
    ( timeout 40 python3 -I "$fdr" "$p" --grade 1:1 --draw 0 --master-seed "$SE_PAY" --query-seed "$SE_QRY" > "$out" 2>&1 ) &
    local hp=$!
    local i; for i in $(seq 1 60); do grep -q LISTENING "$out" 2>/dev/null && break; sleep 0.1; done
    python3 -I -c "import socket,sys;s=socket.create_connection(('127.0.0.1',int(sys.argv[1])),5);s.close()" "$p" 2>/dev/null || true
    wait "$hp" 2>/dev/null
    # Called DIRECTLY, never inside $( ): a backgrounded job plus `wait` does not compose inside a
    # command substitution -- the gate's own leg read an empty file that way. The answer goes to a
    # file and the caller reads it.
    sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' "$out" | head -1 > "$out.val"
}
SE_SEED="$(draw_seed "$tmp/seedchan.sh")"
if [[ "${#SE_SEED}" -ne 32 ]]; then
    fail_test "seed-echo legs: the driver did not draw (got '${SE_SEED}')"
else
    SE_PAY="${SE_SEED:0:16}"; SE_QRY="${SE_SEED:16:16}"
    echo_probe "$feeder" "$tmp/echo.base.log"
    ECHO_BASE="$(cat "$tmp/echo.base.log.val" 2>/dev/null || true)"
    echo_probe "$tmp/feed_pinned.py" "$tmp/echo.mut.log"
    ECHO_MUT="$(cat "$tmp/echo.mut.log.val" 2>/dev/null || true)"
    if [[ "${#ECHO_BASE}" -eq 32 && "$ECHO_BASE" == "$SE_SEED" ]]; then
        if static_legs echobase "$tmp/base.forcing/a.out" "$tmp/forcing.herb" "$SE_SEED" "$ECHO_BASE" && [[ -z "$STATIC_FAILS" ]]; then
            okleg "control-seed-echo (the production harness echoes the value the driver drew: $ECHO_BASE -- so a \`seed-echo\` RED below is the mutation's, not an empty read)"
        else
            fail_test "control-seed-echo (the base battery did not pass with the production echo: ${STATIC_FAILS:-<none>})"
        fi
    else
        fail_test "control-seed-echo (the production harness printed '${ECHO_BASE:-<none>}', not the drawn '$SE_SEED') -- an empty or wrong read would make row 21 bite vacuously"
    fi
    # ROW 22's stated point is a NEGATIVE, and a review lens was right that a negative in prose is
    # not a result: `seed-echo` must be shown ABSENT from the FAIL set against a pinned DRIVER. The
    # pinned channel draws a constant, the UNMUTATED harness echoes it faithfully, and the gate's own
    # leg is therefore green -- which is why `seed-freshness` is the only leg that can see row 22.
    PIN_SEED="$(draw_seed "$tmp/seedchan.pin.sh")"
    if [[ "${#PIN_SEED}" -eq 32 ]]; then
        SE_PAY="${PIN_SEED:0:16}"; SE_QRY="${PIN_SEED:16:16}"
        echo_probe "$feeder" "$tmp/echo.pin.log"
        ECHO_PIN="$(cat "$tmp/echo.pin.log.val" 2>/dev/null || true)"
        if [[ "$ECHO_PIN" == "$PIN_SEED" ]] \
           && static_legs echopin "$tmp/base.forcing/a.out" "$tmp/forcing.herb" "$PIN_SEED" "$ECHO_PIN" \
           && [[ -z "$STATIC_FAILS" ]]; then
            okleg "M-driverpin-seedecho-green (against a PINNED DRIVER the gate's \`seed-echo\` leg is GREEN -- proven, not asserted: the harness printed $ECHO_PIN, the pinned driver drew $PIN_SEED, and the battery's FAIL set is empty. This is why row 22 needs \`seed-freshness\`)"
        else
            fail_test "M-driverpin-seedecho-green (expected an EMPTY FAIL set with the pinned driver echoed faithfully; harness printed '${ECHO_PIN:-<none>}', driver drew '$PIN_SEED', FAIL set: ${STATIC_FAILS:-<none>})"
        fi
        SE_PAY="${SE_SEED:0:16}"; SE_QRY="${SE_SEED:16:16}"
    else
        fail_test "M-driverpin-seedecho-green (the pinned channel did not draw)"
    fi
    if [[ "${#ECHO_MUT}" -eq 32 && "$ECHO_MUT" == "11111111111111112222222222222222" ]]; then
        if static_legs echomut "$tmp/base.forcing/a.out" "$tmp/forcing.herb" "$SE_SEED" "$ECHO_MUT" && has_leg echomut seed-echo; then
            echo "M-seedpin-internal bit RED on \`seed-echo\` (no boot): $(grep -E '^FAIL seed-echo ' "$tmp/st.echomut.out" | head -1)"
            echo "    (the pinned harness printed its internal constant, a value the driver never drew; full FAIL set: ${STATIC_FAILS:-<none>} -- and it is ONLY seed-echo, because the image is untouched)"
            scored M-seedpin-internal
        else
            fail_test "M-seedpin-internal: \`seed-echo\` did NOT fire against a pinned harness (FAIL set: ${STATIC_FAILS:-<none>})"
        fi
    else
        fail_test "M-seedpin-internal: the pinned harness printed '${ECHO_MUT:-<none>}', not its pinned constant -- the mutation did not take, so nothing below it is attributable"
    fi
fi

echo "  -- SLICE 6: the residual legs, closed by ADDING a mutant where one is cheap and discriminating --"
# The parent's rule (2026-09-03): for each gate leg with no mutant, ADD one where it is cheap and
# discriminating, or JUSTIFY in the design's table by NAMING the leg's discriminator and saying why a
# mutant would be redundant. Eight are added here; the justified ones are named in SCOPE-BUILD.md.

# --- ROW 24: M-golden-boundary -- the THREE boundary goldens, which M-golden never touched (it
#     perturbs the forcing image only, so `golden-forcing` was covered and the other three were not).
# Graded through the GATE'S OWN `golden_leg`, extracted above -- a review leg was right that comparing
# digests here is WEAKER than the production leg, which also pins the committed file's EXACT
# REPRESENTATION at 65 bytes (bash command substitution strips trailing newlines, so a malformed
# 66-byte pin would satisfy a digest comparison and be refused by the real leg).
gb_bad=0
for _lbl in edge over under; do
    forge golden "$tmp/base.b_$_lbl/a.out" "$tmp/mgb_$_lbl.elf" || { gb_bad=1; continue; }
    if ! golden_leg "boundary_$_lbl" "$tmp/base.b_$_lbl/a.out" >/dev/null 2>&1; then
        fail_test "M-golden-boundary/$_lbl: the UNMUTATED image fails the gate's own golden_leg -- no RED below it is attributable"; gb_bad=1; continue
    fi
    if golden_leg "boundary_$_lbl" "$tmp/mgb_$_lbl.elf" >/dev/null 2>&1; then
        fail_test "M-golden-boundary/$_lbl: the gate's own golden_leg ACCEPTED a one-byte forge"; gb_bad=1; continue
    fi
    echo "    golden-boundary_$_lbl: the gate's own golden_leg accepts the base image and REFUSES the one-byte forge"
done

if [[ "$gb_bad" -eq 0 ]]; then
    echo "M-golden-boundary bit RED on all three committed boundary hashes, each with its base-matches control"
    scored M-golden-boundary
fi

# --- ROW 25: M-elfheader -- the phdr's p_type, which the whole positional analysis rests on and
#     which `elf-header` exists to assert rather than assume.
if forge elfheader "$tmp/base.forcing/a.out" "$tmp/m_elfheader.elf"; then
    leg_red M-elfheader "$tmp/m_elfheader.elf" "$tmp/forcing.herb" elf-header \
        "p_type is no longer PT_LOAD, so the location fields the analysis rests on are wrong -- and NOTHING else reads p_type, which is why this leg is the only one that can see it"
fi

# --- ROW 26: M-sourceshape -- a bufget whose base is NOT the identifier bound to bufbase(). Graded
#     by calling longbuf_spec's OWN production predicate, because that predicate IS the leg: the
#     subject is the SOURCE, and running the image battery on a re-shaped source would fail other
#     legs for reasons that have nothing to do with A3.3.
python3 -I - "$tmp/forcing.herb" "$tmp/shape.herb" <<'SHEOF'
import sys
src = open(sys.argv[1]).read()
old = "    let g = bufget(b, 262144)\n"
assert src.count(old) == 1, "the guard access is not unique (%d hits)" % src.count(old)
# A DERIVED base: `c` is bufbase()-rooted only through arithmetic, which is exactly the shape A3.3
# forbids -- a booted measurement showed ops 50/51 take their base as a RUNTIME value, so a computed
# base runs real indexed accesses entirely outside the guarded buffer.
open(sys.argv[2], "w").write(src.replace(old, "    let c = b + 0\n    let g = bufget(c, 262144)\n", 1))
print("SOURCE-MUTATED M-sourceshape")
SHEOF
shape_out="$(python3 -I - "$spec" "$tmp/forcing.herb" "$tmp/shape.herb" <<'SPEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
base_ok, base_detail = L.source_base_shape(open(sys.argv[2]).read())
mut_ok, mut_detail = L.source_base_shape(open(sys.argv[3]).read())
print("BASE %s :: %s" % ("ok" if base_ok else "FAIL", base_detail))
print("MUT %s :: %s" % ("ok" if mut_ok else "FAIL", mut_detail))
sys.exit(0 if (base_ok and not mut_ok) else 1)
SPEOF
)"; shape_rc=$?
if [[ "$shape_rc" -eq 0 ]]; then
    echo "M-sourceshape bit RED on \`source-shape\`: $(grep '^MUT' <<<"$shape_out")"
    echo "    (control, same predicate, unmutated source: $(grep '^BASE' <<<"$shape_out"))"
    scored M-sourceshape
else
    fail_test "M-sourceshape: \`source-shape\` did not discriminate a computed base ($shape_out)"
fi

# --- ROW 27: M-parser -- longbuf_spec's parse_positional made to accept ANY length, which is the
#     scan-shaped behaviour LEDGER D26 records the cost of. Graded through the gate's own static
#     battery with the mutated spec, so the legs that fire are the gate's, named.
python3 -I - "$spec" "$tmp/spec_scan.py" <<'PSEOF'
import sys
src = open(sys.argv[1]).read()
old = "    if not isinstance(stream, (bytes, bytearray)) or len(stream) != need:\n"
assert src.count(old) == 1, "the positional length check is not unique (%d hits)" % src.count(old)
# Drop the COUNT rejection: a stream one byte short or one byte long is now "well formed", which is
# precisely what `frame-cardinality` exists to refuse.
# `!=` -> `<`: a stream one byte LONG is now "well formed", which is what `frame-cardinality`
# exists to refuse. Deliberately NOT dropping the check outright -- that made the SHORT fixture raise
# IndexError and killed the whole battery, and a CRASH is not a RED (this file's own rule, and why
# `static_legs` reports __CRASH__ separately from a leg FAIL).
open(sys.argv[2], "w").write(src.replace(old, "    if not isinstance(stream, (bytes, bytearray)) or len(stream) < need:\n", 1))
print("SPEC-MUTATED M-parser")
PSEOF
if [[ -s "$tmp/spec_scan.py" ]]; then
    if static_legs M-parser "$tmp/base.forcing/a.out" "$tmp/forcing.herb" "$CTRL_SEED" "$CTRL_SEED" "$tmp/spec_scan.py" \
       && has_leg M-parser frame-cardinality; then
        echo "M-parser bit RED on \`frame-cardinality\`: $(grep -E '^FAIL frame-cardinality ' "$tmp/st.M-parser.out" | head -1)"
        if has_leg M-parser frame-terminal; then
            fail_test "M-parser: \`frame-terminal\` ALSO fired, so the two parser legs are not discriminated by this mutation"
        else
            echo "    (the parser stopped rejecting by COUNT, which is the D26 scan-shape; \`frame-terminal\` is PROVEN silent here, not merely said to be; full FAIL set: ${STATIC_FAILS:-<none>} -- the IMAGE is untouched)"
            scored M-parser
        fi
    else
        fail_test "M-parser: \`frame-cardinality\` did not fire against a parser that accepts any length (FAIL set: ${STATIC_FAILS:-<none>})"
    fi
else
    fail_test "M-parser: the spec mutation did not apply"
fi

# --- ROW 33: M-parserpos -- the answers read at the WRONG positions. `frame-cardinality` cannot see
#     this (the length is still right); `frame-terminal` is the leg that pins WHERE each answer sits
#     and that the last one is terminal by construction, and it is the only leg that can.
python3 -I - "$spec" "$tmp/spec_pos.py" <<'PPEOF'
import sys
src = open(sys.argv[1]).read()
old = "    answers = [stream[n_echo + 3 * j + 2] for j in range(n_query)]\n"
assert src.count(old) == 1, "the positional answer read is not unique (%d hits)" % src.count(old)
# Off by one WITHIN the triple: the stream length is unchanged, so the cardinality leg stays green
# and only the position pin can fire.
open(sys.argv[2], "w").write(src.replace(old, "    answers = [stream[n_echo + 3 * j + 1] for j in range(n_query)]\n", 1))
print("SPEC-MUTATED M-parserpos")
PPEOF
if [[ -s "$tmp/spec_pos.py" ]]; then
    if static_legs M-parserpos "$tmp/base.forcing/a.out" "$tmp/forcing.herb" "$CTRL_SEED" "$CTRL_SEED" "$tmp/spec_pos.py" \
       && has_leg M-parserpos frame-terminal; then
        echo "M-parserpos bit RED on \`frame-terminal\`: $(grep -E '^FAIL frame-terminal ' "$tmp/st.M-parserpos.out" | head -1)"
        if has_leg M-parserpos frame-cardinality; then
            fail_test "M-parserpos: \`frame-cardinality\` ALSO fired, so the two parser legs are not discriminated by this mutation"
        else
            echo "    (the answers moved one byte inside each triple, so the LENGTH is still right and \`frame-cardinality\` is PROVEN silent -- full FAIL set: ${STATIC_FAILS:-<none>})"
            scored M-parserpos
        fi
    else
        fail_test "M-parserpos: \`frame-terminal\` did not fire against answers read at the wrong offset (FAIL set: ${STATIC_FAILS:-<none>})"
    fi
else
    fail_test "M-parserpos: the spec mutation did not apply"
fi

# --- ROW 34: M-harnesssummary -- the `bochs-harness` leg, which slice 6 first JUSTIFIED as needing no
#     mutant on the grounds that forcing three genuine harness failures would cost three 240 s Bochs
#     timeouts. A cross-family review leg REFUTED that: the leg's discriminator is
#     `f2_harness_summary`'s RETURN VALUE, and the counter it reads can simply be set. No boot at all.
#     The justification is withdrawn and this row replaces it.
python3 -I - "$script_dir/bochs_f2_harness.sh" "$tmp/f2_blind.sh" <<'HSEOF'
import sys
src = open(sys.argv[1]).read()
old = ('f2_harness_summary() {\n'
       '    if [[ "$F2_HARNESS_FAIL" -ne 0 ]]; then\n')
assert src.count(old) == 1, "f2_harness_summary's fail branch is not unique (%d hits)" % src.count(old)
# Exhaustion stops being reported: the summary returns 0 no matter how many legs were unadjudicated,
# which is the fail-OPEN shape the F2 contract exists to forbid.
open(sys.argv[2], "w").write(src.replace(old, 'f2_harness_summary() {\n    if false; then\n', 1))
print("SHARED-HARNESS MUTATED M-harnesssummary")
HSEOF
if [[ -s "$tmp/f2_blind.sh" ]]; then
    hs_base="$( set +u; fail_test() { :; }; source "$script_dir/bochs_f2_harness.sh" >/dev/null 2>&1; F2_HARNESS_FAIL=1; if f2_harness_summary >/dev/null 2>&1; then echo GREEN; else echo RED; fi )"
    hs_mut="$( set +u;  fail_test() { :; }; source "$tmp/f2_blind.sh" >/dev/null 2>&1;                 F2_HARNESS_FAIL=1; if f2_harness_summary >/dev/null 2>&1; then echo GREEN; else echo RED; fi )"
    if [[ "$hs_base" == "RED" && "$hs_mut" == "GREEN" ]]; then
        echo "M-harnesssummary bit RED on \`bochs-harness\`: with one leg recorded as exhausted (F2_HARNESS_FAIL=1) the PRODUCTION summary returns failure, and the mutated one returns SUCCESS -- so the gate would print \`ok bochs-harness\` over an attempted-but-unadjudicated Bochs leg, which is exactly the fail-OPEN shape the F2 contract forbids"
        scored M-harnesssummary
    else
        fail_test "M-harnesssummary: the summary did not discriminate (production=$hs_base mutant=$hs_mut; want RED then GREEN)"
    fi
else
    fail_test "M-harnesssummary: the shared-harness mutation did not apply"
fi

# --- ROW 28: M-frameverdict -- D26 ITSELF, on the Bochs frame rule: bind the FIRST de..ad frame by
#     bare search, which is the landed defect `reject-twoframe` exists to refuse. The gate's OWN
#     fixtures are re-run against the mutated rule.
python3 -I - "$tmp/frames.sh" "$tmp/frames_d26.sh" <<'FVEOF'
import sys
src = open(sys.argv[1]).read()
old = '    [[ "$(frame_last "$1")" == "de${2}ad" ]] || return 1\n'
assert src.count(old) == 1, "frame_verdict's terminal-frame comparison is not unique (%d hits)" % src.count(old)
# THE D26 DEFECT, restored deliberately: grade the FIRST frame instead of the terminal one, and stop
# requiring exactly one. A two-frame stream whose first frame is correct now passes.
new = '    [[ "$(frame_scan "$1" | head -1)" == "de${2}ad" ]] || return 1\n'
src = src.replace(old, new, 1)
old_n = '    local n; n="$(frame_count "$1")"\n    [[ "$n" -eq 1 ]] || return 1\n'
assert src.count(old_n) == 1, "frame_verdict's cardinality check is not unique"
open(sys.argv[2], "w").write(src.replace(old_n, '    local n; n="$(frame_count "$1")"\n', 1))
print("FRAME-RULE MUTATED M-frameverdict")
FVEOF
if [[ -s "$tmp/frames_d26.sh" ]]; then
    tf_out="$(
        set +u
        source "$tmp/frames_d26.sh"
        tmp="$tmp"
        printf 'boot noise\n\xde\x10\xad\ntail\n'                > "$tmp/d26_one.log"
        printf 'boot noise\n\xde\x10\xad\nmore\n\xde\x20\xad\n' > "$tmp/d26_two.log"
        if frame_verdict "$tmp/d26_one.log" 10 && frame_verdict "$tmp/d26_two.log" 10; then
            echo "D26-ACCEPTED-TWOFRAME"
        else
            echo "D26-STILL-REJECTED"
        fi
    )"
    if [[ "$tf_out" == "D26-ACCEPTED-TWOFRAME" ]]; then
        echo "M-frameverdict bit RED on \`reject-twoframe\`: with the rule binding the FIRST frame and dropping the cardinality check, a TWO-frame stream whose first frame is the expected one is ACCEPTED -- which is LEDGER D26's defect exactly, and the leg exists to refuse it"
        scored M-frameverdict
    else
        fail_test "M-frameverdict: the mutated rule still rejected the two-frame stream ($tf_out) -- the mutation did not reach the rule it names"
    fi
else
    fail_test "M-frameverdict: the frame-rule mutation did not apply"
fi

# --- ROW 29: M-irgate2 -- the IR gate raised to >= 2, so a buffer-mode program with EXACTLY ONE
#     indexed op is refused. `accept-oneidx` is the POSITIVE side of that boundary and the only leg
#     that says a one-op program must still compile.
compile_with "$NATIVE_CODEGEN_COMPILER" "$tmp/oneidx.herb" "$tmp/base.oneidx"
if compiled_ok "$tmp/base.oneidx"; then
    okleg "control-oneidx (the UNMUTATED compiler ACCEPTS a buffer-mode program with exactly one indexed op -- without this, \"the mutant refused it\" would prove nothing)"
else
    fail_test "control-oneidx (the unmutated compiler did not accept the one-indexed-op probe: $COMPILE_MSG) -- row 29's RED would not be attributable"
fi
if mint_mutant irgate2; then
    compile_with "$MUTC" "$tmp/oneidx.herb" "$tmp/m.irgate2"
    if compiled_ok "$tmp/m.irgate2"; then
        fail_test "M-irgate2: the one-indexed-op probe still COMPILED with the gate raised to >= 2 -- the mutation did not reach the gate it names"
    elif grep -q 'ERR 655' <<<"$COMPILE_MSG"; then
        echo "M-irgate2 bit RED on \`accept-oneidx\`: a buffer-mode program with EXACTLY ONE indexed op was REFUSED ($COMPILE_MSG) where the gate requires it to compile"
        scored M-irgate2
    else
        fail_test "M-irgate2: no a.out, but the failure was not ERR 655 ($COMPILE_MSG)"
    fi
fi

# --- ROW 30: M-singlefunc -- single-function programs routed down the multi-function tap path, so
#     the device-op multi-function rule stops refusing them.
compile_with "$NATIVE_CODEGEN_COMPILER" "$tmp/singlefunc.herb" "$tmp/base.singlefunc"
if refused_ok "$tmp/base.singlefunc" && grep -qE 'ERR (50[0-9]|6[0-9][0-9])' <<<"$COMPILE_MSG"; then
    okleg "control-singlefunc (the UNMUTATED compiler REFUSES a single-function device-op program with a named diagnostic: $COMPILE_MSG)"
else
    fail_test "control-singlefunc (the unmutated compiler did not refuse the single-function probe with a named diagnostic: rc=$COMPILE_RC $COMPILE_MSG) -- row 30's RED would not be attributable"
fi
if mint_mutant singlefunc; then
    compile_with "$MUTC" "$tmp/singlefunc.herb" "$tmp/m.singlefunc"
    if compiled_ok "$tmp/m.singlefunc"; then
        echo "M-singlefunc bit RED on \`reject-singlefunc\`: a SINGLE-function device-op program COMPILED (a.out present, rc=$COMPILE_RC) where the gate requires a named refusal"
        scored M-singlefunc
    else
        fail_test "M-singlefunc: the single-function probe was still refused ($COMPILE_MSG) -- the mutation did not reach the rule it names"
    fi
fi

# --- ROW 31: M-boundaryimages -- the decode-based boundary leg, graded on the trio with the EDGE
#     slot replaced by the under-index forge. That image carries the WRONG own-immediate and a
#     FOREIGN one, which is exactly the "the compiler lowered both constants the same" collapse the
#     leg was written for. The gate's own decoder runs, extracted, not restated.
# shellcheck source=/dev/null
if source "$tmp/boundary_static.sh" 2>/dev/null && declare -F boundary_static >/dev/null; then
    # The extracted function reads the GATE's own paths ($tmp/b_<lbl>.d/a.out), so those are staged
    # here rather than the function being edited -- editing it would make this a restatement.
    for _lbl in edge over under; do
        mkdir -p "$tmp/b_$_lbl.d"; cp "$tmp/base.b_$_lbl/a.out" "$tmp/b_$_lbl.d/a.out"
    done
    bi_base="$(boundary_static 2>&1)"; bi_base_rc=$?
    # This row runs BEFORE the booting section, so it forges its own copy rather than depending on a
    # file a later block happens to leave behind -- an ordering dependency is how a leg silently
    # stops grading.
    [[ -f "$tmp/m_underindex.elf" ]] || forge underindex "$tmp/base.b_edge/a.out" "$tmp/m_underindex.elf"
    if [[ -f "$tmp/m_underindex.elf" ]]; then
        cp "$tmp/m_underindex.elf" "$tmp/b_edge.d/a.out"
        bi_mut="$(boundary_static 2>&1)"; bi_mut_rc=$?
        cp "$tmp/base.b_edge/a.out" "$tmp/b_edge.d/a.out"
        if [[ "$bi_base_rc" -eq 0 && "$bi_mut_rc" -ne 0 ]]; then
            echo "M-boundaryimages bit RED on \`boundary-images\`: $(sed 's/^BOUNDARY-STATIC //' <<<"$bi_mut" | cut -c1-150)"
            echo "    (control, same decoder, the honest trio: $(sed 's/^BOUNDARY-STATIC //' <<<"$bi_base" | cut -c1-90))"
            scored M-boundaryimages
        else
            fail_test "M-boundaryimages: the decoder did not discriminate (base rc=$bi_base_rc mutant rc=$bi_mut_rc; $bi_mut)"
        fi
    else
        fail_test "M-boundaryimages: the under-index forge is missing, so the trio could not be re-graded"
    fi
else
    fail_test "M-boundaryimages: the gate's boundary decoder could not be sourced"
fi

# ---------------------------------------------------------------- the booting rows
if [[ "$boot_legs" -ne 1 ]]; then
    echo "  NOTE: the thirteen graded sessions and the six bare boundary boots did NOT run on this host."
else
echo "  -- graded sessions on QEMU-TCG (the black-box floor and the seed channel's cross-run half) --"

# The edge/boundary probes' completion values, DERIVED through the spec's own functions rather than
# written down: the probe's main returns the sentinel it read back, so its frame and its
# isa-debug-exit status are predicted the same way a draw's are.
EDGE_DERIV="$(python3 -I - "$spec" "$SENTINEL" <<'EEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
v = int(sys.argv[2]); pb = (v >> 32) & 0xFF
print("%02x %d" % (pb, L.qemu_exit_for(pb)))
EEOF
)" || { echo "FAIL: link66-mutation (cannot derive the boundary probes' completion values)"; exit 1; }
EDGE_PROOF="${EDGE_DERIV%% *}"; EDGE_EXIT="${EDGE_DERIV##* }"
# The LOW guard address the under-index forge must fault at, DERIVED from the very image being
# forged rather than written down: bufget(b,k) addresses buf_2m + 8k, so k = 2^64-1 wraps to
# buf_2m - 8, which the assertion below requires to be inside guard_lo.
CR2_UNDER="$(python3 -I - "$spec" "$tmp/base.b_edge/a.out" <<'GEOF'
import importlib.util, sys
_s = importlib.util.spec_from_file_location("longbuf_spec", sys.argv[1])
L = importlib.util.module_from_spec(_s); _s.loader.exec_module(L)
img = L.Image(sys.argv[2])
under = (img.buf_2m + 8 * ((1 << 64) - 1)) % (1 << 64)
assert img.guard_lo <= under < img.buf_2m, (hex(under), hex(img.guard_lo), hex(img.buf_2m))
print("%016x" % under)
GEOF
)" || { echo "FAIL: link66-mutation (cannot derive the low-guard fault address)"; exit 1; }

run_session() { # label elf feederpath pay qry draw tag [drainmode]
    local label="$1" elf="$2" fdr="$3" pay="$4" qry="$5" d="$6" tag="$7" dm="${8:-eof}"
    if ! derive "$pay" "$qry" "$d" "$tag" > "$tmp/derive.$tag.log" 2>&1; then
        fail_test "$label: the driver could not derive its own expected transcript ($(tail -1 "$tmp/derive.$tag.log"))"; return 1
    fi
    if ! qsession "$label" "$elf" "$pay" "$qry" "$d" "$fdr" "$dm"; then
        fail_test "$label: the feeder never reached LISTENING (HARNESS-ERROR, not a compiler RED)"; return 1
    fi
    echo "    $label :: $S_GRADE"
    echo "    $label LINK66_SEED=$S_SEED (harness) qemu-exit=$S_RC feeder-exit=$S_FRC frame=${S_E9:-EMPTY} derived-proof=$(meta "$tag" proof)"
    return 0
}
# A black-box RED must be the MUTATION's, so three things are required and none of them is "ok=0":
# the feeder exited cleanly, the transcript got as far as the phase named, and the mismatch field is
# the PREDICTED one. A crashed feeder, a dead QEMU or a timeout all produce ok=0 too.
expect_mismatch() { # label wantregex note
    local label="$1" want="$2" note="$3"
    case "$S_GRADE" in
        *"ok=0"*) : ;;
        *) fail_test "$label: the run graded ok=1 -- the mutation did not bite ($S_GRADE)"; return 1 ;;
    esac
    # The feeder's OWN exit status is the verdict's signature, not merely a health check: this mode
    # exits 3 when it graded not-ok (kernel_io_feed.py:424) and 4 on a usage error, 2 on NOCONN, 1 on
    # an unhandled exception. Requiring exactly 3 is what separates "the grader reached a verdict and
    # said RED" from "the grader died and printed nothing useful".
    if [[ "$S_FRC" -ne 3 ]]; then
        fail_test "$label: the feeder exited $S_FRC, want 3 (its graded-not-ok status) -- a RED printed by a process that then died differently is not a verdict"; return 1
    fi
    if [[ "$S_QKILL" -eq 2 ]]; then
        fail_test "$label: the 120 s WATCHDOG killed qemu -- the guest hung rather than reaching a verdict, and a hang is not a mismatch"; return 1
    fi
    if ! grep -qE "mismatch=$want" <<<"$S_GRADE"; then
        fail_test "$label: the mismatch is not the predicted one (want mismatch=$want; got $S_GRADE)"; return 1
    fi
    echo "$label bit RED: $note -- $(grep -oE 'mismatch=[^ ]+( idx=[0-9]+ got=[0-9]+ want=[0-9]+)?' <<<"$S_GRADE" | head -1) (feeder exit 3 = graded not-ok; qemu ended by the harness after the verdict: qkill=$S_QKILL rc=$S_RC)"
    scored "$label"; return 0
}

# --- CONTROL (QEMU): the unmutated image, graded GREEN end to end. Named by the design, and it is
#     what makes every black-box RED below attributable to its mutation rather than to the path.
CQ="$(draw_seed "$tmp/seedchan.sh")"
if [[ "${#CQ}" -ne 32 ]]; then
    fail_test "control-qemu: the driver did not draw"
elif run_session control-qemu "$tmp/base.forcing/a.out" "$feeder" "${CQ:0:16}" "${CQ:16:16}" 0 ctrl; then
    why="$(session_green control-qemu ctrl)"
    if [[ -z "$why" && "$S_SEED" == "$CQ" ]]; then
        echo "control-qemu: base image graded GREEN on QEMU-TCG (answer stream == host table)"
        scored control-qemu
    else
        fail_test "control-qemu (${why:-the harness echoed '$S_SEED', not the drawn '$CQ'}) -- no black-box RED below is attributable"
    fi
fi

# --- CONTROL for `seed-freshness`: two graded sessions of the UNMUTATED pair must print DIFFERENT
#     seeds. One run cannot observe its own freshness, so without this pair rows 21 and 22 are not
#     attributable -- the design's own words, and the slice-0 refutation's finding.
F1="$(draw_seed "$tmp/seedchan.sh")"; F2="$(draw_seed "$tmp/seedchan.sh")"
FS1=""; FS2=""
if run_session freshness-base-1 "$tmp/base.forcing/a.out" "$feeder" "${F1:0:16}" "${F1:16:16}" 0 fb1; then FS1="$S_SEED"; fi
if run_session freshness-base-2 "$tmp/base.forcing/a.out" "$feeder" "${F2:0:16}" "${F2:16:16}" 1 fb2; then FS2="$S_SEED"; fi
if [[ -n "$FS1" && -n "$FS2" && "$FS1" != "$FS2" ]]; then
    echo "seed-freshness: two consecutive graded runs printed different seeds"
    echo "    ($FS1 vs $FS2)"
    scored seed-freshness
else
    fail_test "seed-freshness control (two unmutated graded sessions printed '${FS1:-<none>}' and '${FS2:-<none>}') -- rows 21 and 22 are not attributable without this pair"
fi

# --- ROWS 3 and 4: the two source forgeries the black-box floor is the ONLY thing standing against.
#     Neither is run through the static battery, and the reason is not a shortcut: their op sequences
#     differ from the forcing program's, so the gate's hand-derived sequences would mismatch and the
#     battery would go RED for a reason that has nothing to do with the forgery. The design says
#     "black-box floor only" for exactly these two rows, and this file honours that literally.
cat > "$tmp/m_recursionstore.herb" <<'EOS'
-- emit: multiboot32-long64
func fill(base, i, n):
    if i == n:
        return 0
    end
    let e = output_byte(input_byte())
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
    let a = 0
    let e3 = output_byte(a)
    return serve(base, q - 1, acc + a)
end
func main():
    let b = bufbase()
    let d1 = bufset(b, 0, 7)
    let d2 = bufget(b, 0)
    let f = fill(b, 0, 512)
    let s = serve(b, 64, 0)
    let p = output_byte(s)
    let g = bufget(b, 262144)
    return s * 4294967296
end
EOS
# The sole indexed op sits in an arm the caller can never take, so the image CONTAINS the capability
# and never exercises it. The guard access is deliberately absent here: with the answers wrong the
# run is RED at the first query, long before any guard page is touched, and keeping `bufget(base, k)`
# the program's ONLY indexed op is what makes the row the dead-ARM case rather than row 3's dead-OP.
cat > "$tmp/m_deadsib.herb" <<'EOS'
-- emit: multiboot32-long64
func pick(base, k, z):
    if z == 1:
        return bufget(base, k)
    end
    return 0
end
func fill(base, i, n):
    if i == n:
        return 0
    end
    let e = output_byte(input_byte())
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
    let a = pick(base, hi * 256 + lo, 0)
    let e3 = output_byte(a)
    return serve(base, q - 1, acc + a)
end
func main():
    let b = bufbase()
    let f = fill(b, 0, 512)
    let s = serve(b, 64, 0)
    return output_byte(s)
end
EOS
floor_row() { # label src note
    local label="$1" src="$2" note="$3"
    # A separate statement: every word of a `local` line is expanded BEFORE the assignments run,
    # so `tag="${label//-/_}"` on the same line reads an unset variable under `set -u`.
    local tag; tag="${label//-/_}"
    compile_with "$NATIVE_CODEGEN_COMPILER" "$src" "$tmp/m.$tag"
    if ! compiled_ok "$tmp/m.$tag"; then
        fail_test "$label: the forgery did not compile ($COMPILE_MSG)"; return 1
    fi
    local S; S="$(draw_seed "$tmp/seedchan.sh")"
    [[ "${#S}" -eq 32 ]] || { fail_test "$label: the driver did not draw"; return 1; }
    # `quiet` drain, and it is not a weakening: `eof` waits ninety seconds for an EOF that a
    # blocked guest will never send, and its timeout then PREFIXES the mismatch field
    # (`mismatch=drain_no_eof@q0.ans ...`), hiding the very thing the row is graded on. The
    # `extra=0` invariant is unchanged in either mode -- every byte is still counted.
    run_session "$label" "$tmp/m.$tag/a.out" "$feeder" "${S:0:16}" "${S:16:16}" 0 "$tag" quiet || return 1
    # PRECONDITION, checked before the verdict: a forgery that answers 0 cannot be caught on a draw
    # whose every answer IS 0. Asserting it is the difference between a proof and a coin flip.
    local nz; nz="$(meta "$tag" nonzero)"
    if [[ "$nz" -lt 1 ]]; then
        fail_test "$label: VACUOUS DRAW -- all $Q answers are 0, so answering 0 cannot be distinguished"; return 1
    fi
    expect_mismatch "$label" 'q[0-9]+\.ans' "$note (precondition: $nz of $Q answers are non-zero)"
}
# SAID PRECISELY, because both lenses caught the first wording. These are NOT the design's priced
# chain forgery (R4's peel ladder at 2^-104.45): they answer a literal constant, so their P_forge is
# ~0 and the floor beats them by a mile. What they establish is that the floor BITES a forger the
# static legs cannot see -- not that it bites at the strength the DP charges. And "stores nothing" is
# false of row 3: it executes bufset(b,0,7) and bufget(b,0) whose results are discarded. It stores no
# PAYLOAD, which is the property under test.
floor_row M-recursionstore "$tmp/m_recursionstore.herb" "one dead set and one dead get whose results are discarded, no payload stored, every answer a literal 0 -- caught by the black-box floor and nothing else"
floor_row M-deadsib "$tmp/m_deadsib.herb" "the sole indexed op sits in a constant-false arm, so the capability is present in the image and never executed"

# --- ROW 9: M-wrongidx -- serve's `hi * 256` immediate becomes 257, so every query with hi == 1
#     gathers buf[k+1]. Size-preserving (one imm64 for another), so nothing downstream shifts.
if forge wrongidx "$tmp/base.forcing/a.out" "$tmp/m_wrongidx.elf"; then
    S="$(draw_seed "$tmp/seedchan.sh")"
    if run_session M-wrongidx "$tmp/m_wrongidx.elf" "$feeder" "${S:0:16}" "${S:16:16}" 0 wrongidx quiet; then
        wi="$(meta wrongidx wrongidx)"; hi1="$(meta wrongidx hi1)"
        if [[ "$wi" -lt 1 ]]; then
            fail_test "M-wrongidx: VACUOUS DRAW -- $hi1 of $Q queries have hi == 1 but NONE of them has payload[k+1] != payload[k], so a 256->257 bias changes an address without changing an answer"
        else
            expect_mismatch M-wrongidx 'q[0-9]+\.ans' "the gather is one slot past the query's own index (precondition: $wi of $Q queries have hi == 1 AND a differing next byte; $hi1 have hi == 1 at all)"
        fi
    fi
fi

# --- ROW 10: M-constidx -- the gather's SIB index field set to "none", so the address collapses to
#     [rdx] == buf[0] while BOTH pops, and therefore the operand stack and the index echoes, are
#     untouched. The guard access in main is left alone.
if forge constidx "$tmp/base.forcing/a.out" "$tmp/m_constidx.elf"; then
    S="$(draw_seed "$tmp/seedchan.sh")"
    if run_session M-constidx "$tmp/m_constidx.elf" "$feeder" "${S:0:16}" "${S:16:16}" 0 constidx quiet; then
        d0="$(meta constidx diff0)"
        if [[ "$d0" -lt 1 ]]; then
            fail_test "M-constidx: VACUOUS DRAW -- every queried byte equals payload[0], so a collapse to buf[0] cannot bite"
        else
            expect_mismatch M-constidx 'q[0-9]+\.ans' "the answer stream collapses to payload[0] while the index echoes stay correct (precondition: $d0 of $Q queried bytes differ from payload[0])"
        fi
    fi
fi

# --- ROW 19: M-op51noret -- op 51's `52` (push rdx) replaced by a size-preserving `90`, so ERR 611
#     cannot pre-empt the test. The design's named discriminator is the FILL ECHO: with the push
#     gone the echo reads whatever lies above the emptied operand stack. Deterministic RED,
#     non-deterministic witness -- so the leg requires the phase, never a particular byte.
if mint_mutant op51noret; then
    compile_with "$MUTC" "$tmp/forcing.herb" "$tmp/m.op51noret"
    if compiled_ok "$tmp/m.op51noret"; then
        # Recorded, not claimed as the row's discriminator: the byte-for-byte window pin ALSO sees
        # this one, because op 51's complete window includes its trailing `52`. The design named only
        # the runtime leg; both are true and both are printed.
        if static_legs op51noret "$tmp/m.op51noret/a.out" "$tmp/forcing.herb" "$CTRL_SEED" "$CTRL_SEED" && has_leg op51noret windows; then
            echo "M-op51noret ALSO bit RED statically on \`windows\` (not the row's named discriminator, recorded because it is true): $(grep -E '^FAIL windows ' "$tmp/st.op51noret.out" | head -1 | cut -c1-140)"
            scored M-op51noret-static
        else
            fail_test "M-op51noret: the byte-window pin did not see a size-preserving opcode swap inside op 51's own window (FAIL set: ${STATIC_FAILS:-<none>})"
        fi
        S="$(draw_seed "$tmp/seedchan.sh")"
        if run_session M-op51noret "$tmp/m.op51noret/a.out" "$feeder" "${S:0:16}" "${S:16:16}" 0 op51noret quiet; then
            expect_mismatch M-op51noret 'fill\.[0-9]+' "bufset no longer pushes the stored word back, so the fill echo reads whatever lies above the emptied operand stack"
        fi
    else
        fail_test "M-op51noret: the forcing program did not compile under the mutant ($COMPILE_MSG) -- a length invariant pre-empted the runtime test, which the size-preserving swap exists to avoid"
    fi
fi

# --- ROW 20 (second half): with the seed attacker-chosen, a program that STORES NOTHING grades GREEN.
#     The design says a stored answer table reproduces both draws; the frozen text never supplied a
#     conforming forger, so one is supplied here -- and it is trivial precisely because the seed is
#     known: the attacker knows WHICH 64 indices will be asked, in order, so it needs 64 baked
#     constants and no table lookup at all. It carries a dead bufset (the IR gate) and the guard
#     access (so it faults exactly like an honest guest), and its accumulator is identical, so the
#     derived witness byte matches too. Nothing in the runtime battery can tell it from the real one.
if derive "${ATTACK_SEED:0:16}" "${ATTACK_SEED:16:16}" 0 env > "$tmp/derive.env.log" 2>&1 \
   && python3 -I - "$tmp/exp.env.ans" "$tmp/m_baked.herb" >/dev/null 2>&1 <<'BEOF2'
import sys
ans = [int(x) for x in open(sys.argv[1]).read().split()]
assert len(ans) == 64
L = ["-- emit: multiboot32-long64",
     "func fill(base, i, n):", "    if i == n:", "        return 0", "    end",
     "    let e = output_byte(input_byte())", "    return fill(base, i + 1, n)", "end",
     "func table(j):"]
for j, a in enumerate(ans):
    L += ["    if j == %d:" % j, "        return %d" % a, "    end"]
L += ["    return 0", "end",
      "func serve(base, q, acc, j):", "    if q == 0:", "        return acc", "    end",
      "    let hi = input_byte()", "    let e1 = output_byte(hi)",
      "    let lo = input_byte()", "    let e2 = output_byte(lo)",
      "    let a = table(j)", "    let e3 = output_byte(a)",
      "    return serve(base, q - 1, acc + a, j + 1)", "end",
      "func main():", "    let b = bufbase()", "    let d = bufset(b, 0, 0)",
      "    let f = fill(b, 0, 512)", "    let s = serve(b, 64, 0, 0)",
      "    let p = output_byte(s)", "    let g = bufget(b, 262144)",
      "    return s * 4294967296", "end"]
open(sys.argv[2], "w").write("\n".join(L) + "\n")
BEOF2
then
    compile_with "$NATIVE_CODEGEN_COMPILER" "$tmp/m_baked.herb" "$tmp/m.baked"
    if compiled_ok "$tmp/m.baked"; then
        if run_session M-seedpin-env-baked "$tmp/m.baked/a.out" "$feeder" "${ATTACK_SEED:0:16}" "${ATTACK_SEED:16:16}" 0 env; then
            why="$(session_green M-seedpin-env-baked env)"
            if [[ -z "$why" ]]; then
                echo "M-seedpin-env-baked bit RED on the BLACK-BOX FLOOR: with the seed supplied rather than drawn, a program that stores NO PAYLOAD -- 64 baked constants, one dead bufset and the guard access -- graded GREEN end to end (exact transcript, derived witness byte, guard fault). It is NOT a program without the capability: it executes bufset(b,0,0) and the guard bufget, and both review lenses were right that \"stores nothing\" overstated it. What it stores nothing OF is the payload and the answer table. The refusal is the only thing between an attacker-chosen seed and this."
                scored M-seedpin-env-baked
            else
                fail_test "M-seedpin-env-baked: the baked-answer program did NOT grade green ($why) -- the row's consequence is unproven"
            fi
        fi
    else
        fail_test "M-seedpin-env-baked: the baked-answer program did not compile ($COMPILE_MSG)"
    fi
else
    fail_test "M-seedpin-env-baked: could not derive/emit the baked answer table"
fi

# --- ROW 21 (second leg) and ROW 22: `seed-freshness`, the cross-run half, two graded sessions each.
freshness_row() { # label seedchan feederpath driver-draws-distinctly(0|1) note
    local label="$1" chan="$2" fdr="$3" want_distinct="$4" note="$5" a b why
    local S1 S2
    S1="$(draw_seed "$chan")"; S2="$(draw_seed "$chan")"
    [[ "${#S1}" -eq 32 && "${#S2}" -eq 32 ]] || { fail_test "$label: the driver did not draw twice"; return 1; }
    # PRECONDITION, for the rows whose DRIVER is unmutated: two honest draws must differ, or equal
    # harness echoes would be the driver's doing and not the mutation's. A review leg found this
    # missing; the probability is 2^-128 but an unasserted precondition is an unasserted precondition.
    if [[ "$want_distinct" -eq 1 && "$S1" == "$S2" ]]; then
        fail_test "$label: the two honest driver draws were EQUAL ($S1) -- equal harness echoes would not be attributable to the mutation"; return 1
    fi
    run_session "$label-1" "$tmp/base.forcing/a.out" "$fdr" "${S1:0:16}" "${S1:16:16}" 0 "${label}1" || return 1
    a="$S_SEED"
    # A COMPLETE, HEALTHY SESSION IS REQUIRED BEFORE THE SEEDS ARE COMPARED. A review leg found
    # `qsession` returning 0 after LISTENING no matter what followed, so a harness that printed its
    # constant and then DIED twice was counted as a bite. It is not: the seed line only means
    # something if the session it came from actually graded.
    why="$(session_healthy)" || { fail_test "$label-1: the session did not grade cleanly ($why) -- a seed line from a dead session is not evidence"; return 1; }
    run_session "$label-2" "$tmp/base.forcing/a.out" "$fdr" "${S2:0:16}" "${S2:16:16}" 1 "${label}2" || return 1
    b="$S_SEED"
    why="$(session_healthy)" || { fail_test "$label-2: the session did not grade cleanly ($why) -- a seed line from a dead session is not evidence"; return 1; }
    if [[ -n "$a" && "$a" == "$b" ]]; then
        echo "$label bit RED on \`seed-freshness\`: two independent graded sessions printed EQUAL seed lines ($a == $b). $note"
        scored "$label"; return 0
    fi
    fail_test "$label: the two graded sessions printed '${a:-<none>}' and '${b:-<none>}' -- \`seed-freshness\` did NOT fire"
    return 1
}
freshness_row M-seedpin-internal "$tmp/seedchan.sh" "$tmp/feed_pinned.py" 1 \
    "The driver drew two DIFFERENT fresh seeds (asserted above) and the harness ignored both."
freshness_row M-driverpin "$tmp/seedchan.pin.sh" "$feeder" 0 \
    "The harness is UNMUTATED and echoed faithfully, so \`seed-echo\` is GREEN here -- PROVEN above as M-driverpin-seedecho-green, not asserted. \`seed-freshness\` is the only leg that sees a pinned DRIVER, which is why the parent ordered this row."

# --- THE ADDITION'S OWN BOOT: echo-faithful, generation-pinned. Both A1 legs are GREEN against this
#     harness by construction -- it prints the value it was handed, and two runs print two different
#     handed values -- so if the driver's independent derivation did not bite, nothing would.
LATE_SEED="$(draw_seed "$tmp/seedchan.sh")"
if [[ "${#LATE_SEED}" -ne 32 ]]; then
    fail_test "M-seedpin-late: the driver did not draw"
elif run_session M-seedpin-late "$tmp/base.forcing/a.out" "$tmp/feed_late.py" "${LATE_SEED:0:16}" "${LATE_SEED:16:16}" 0 late; then
    late_why="$(session_healthy)"
    if [[ -n "$late_why" ]]; then
        fail_test "M-seedpin-late: the session did not grade cleanly ($late_why) -- this row needs the mutated harness to report a HEALTHY GREEN, since that is the whole point"
    elif [[ "$S_SEED" != "$LATE_SEED" ]]; then
        fail_test "M-seedpin-late: the harness printed '${S_SEED:-<none>}', not the drawn '$LATE_SEED' -- this row's whole shape is a FAITHFUL echo, so the mutation did not take"
    elif cmp -s "$S_CAP" "$tmp/exp.late.bin"; then
        fail_test "M-seedpin-late: the capture EQUALS the driver's own derivation, so the generation pin did not take"
    else
        echo "M-seedpin-late bit RED on the DRIVER'S INDEPENDENT DERIVATION: the harness echoed the drawn seed VERBATIM ($S_SEED) and reported a clean ok=1 grade, so \`seed-echo\` and \`seed-freshness\` are BOTH green against it -- and the $WANT_RX-byte capture is NOT the transcript the driver derived from the seed it drew. This is the shape the gate's second derivation exists for, and no chartered row covered it."
        scored M-seedpin-late
    fi
fi

echo "  -- bare boundary boots: the three rows whose verdict is read off a RUNTIME fault (A2) --"
# A2 puts rows 5, 6 and 7-runtime on Bochs as well as QEMU, because a fault window is a
# CPU/MMU-visible value and A11.1 requires such a value to be cross-checked on a second engine
# before it is written anywhere. Row 16 is deliberately NOT here: the parent ruled on 2026-09-03
# that its discriminator is the page-directory IMAGE, which no second engine reads differently.
qfault_row() { # label elf want_cr2 note
    local label="$1" elf="$2" want_cr2="$3" note="$4"
    qbare "$label" "$elf" || { fail_test "$label: the feeder never reached LISTENING (HARNESS-ERROR)"; return 1; }
    echo "    $label :: cap=${B_CAP:-EMPTY} e9=${B_E9:-EMPTY} rc=$B_RC feeder-exit=$B_FRC"
    [[ "$B_FRC" -eq 0 ]] || { fail_test "$label: the feeder exited $B_FRC (HARNESS-ERROR, not a kernel verdict)"; return 1; }
    case "$B_CAP" in "$MARKER"*) : ;; *) fail_test "$label: the marker byte was NOT seen -- the probe never ran (cap=${B_CAP:-EMPTY})"; return 1 ;; esac
    # A TIMEOUT IS NOT A FAULT. Under -no-reboot a triple fault makes QEMU EXIT with rc 0 and the
    # isa-debug-exit device never fires; a kill reports 124 and is the signature of a guest that
    # never reached its access at all. Grading the two the same grades the harness's patience.
    if [[ "$B_RC" -ne 0 ]]; then
        fail_test "$label: qemu rc=$B_RC, want 0 for a triple fault under -no-reboot$( [[ "$B_RC" -eq 124 ]] && echo ' -- 124 is the 120 s KILL, not a fault')"; return 1
    fi
    if [[ "${#B_CAP}" -ne 2 || -n "$B_E9" ]]; then
        fail_test "$label: expected marker-then-FAULT (no answer byte, no completion frame); cap=$B_CAP e9=${B_E9:-EMPTY}"; return 1
    fi
    fault_at "$label" "$B_LOG" "$want_cr2" || return 1
    echo "$label bit RED: $note (marker seen, then no answer and no completion frame, at the DERIVED fault address, clean launch)"
    scored "$label"; return 0
}
qanswer_row() { # label elf note
    local label="$1" elf="$2" note="$3"
    qbare "$label" "$elf" || { fail_test "$label: the feeder never reached LISTENING (HARNESS-ERROR)"; return 1; }
    echo "    $label :: cap=${B_CAP:-EMPTY} e9=${B_E9:-EMPTY} rc=$B_RC feeder-exit=$B_FRC (want cap=${MARKER}${SENTHEX} e9=de${EDGE_PROOF}ad rc=$EDGE_EXIT)"
    [[ "$B_FRC" -eq 0 ]] || { fail_test "$label: the feeder exited $B_FRC (HARNESS-ERROR, not a kernel verdict)"; return 1; }
    if [[ "$B_CAP" == "${MARKER}${SENTHEX}" && "$B_E9" == "de${EDGE_PROOF}ad" && "$B_RC" -eq "$EDGE_EXIT" ]]; then
        echo "$label bit RED: $note -- the probe COMPLETED its sentinel round-trip through a slot that must be unmapped, and ran on through its own grading tail"
        scored "$label"; return 0
    fi
    fail_test "$label: the probe did not COMPLETE where the mutation requires it to (cap=${B_CAP:-EMPTY} e9=${B_E9:-EMPTY} rc=$B_RC)"
    return 1
}

# --- ROW 5: M-underindex -- the EDGE image's baked index rewritten 262143 -> 2^64-1.
#
#     WHAT THIS ROW DOES AND DOES NOT PROVE, stated because a blind refutation lens was right that the
#     first version overstated it. PUSH_INT is eleven bytes for every value, so the forged image is
#     BYTE-IDENTICAL to the freshly compiled under-index probe -- asserted below, not assumed -- and
#     "the under probe faults" is something the gate's own boundary-under leg already says on a GREEN
#     run. So this row is NOT a new observation about the guard. What it IS: eleven bytes of one
#     immediate are the whole difference between an image that must COMPLETE its marker-then-SENTINEL
#     round-trip (`boundary-edge-qemu`, `golden-boundary_edge`) and one that must fault, and this row
#     turns those EDGE legs RED -- with the fault pinned to the DERIVED guard_lo address, so it is the
#     named fault and not merely a fault. That is the discrimination `boundary-images` claims
#     statically, made at run time.
if forge underindex "$tmp/base.b_edge/a.out" "$tmp/m_underindex.elf"; then
    if ! cmp -s "$tmp/m_underindex.elf" "$tmp/base.b_under/a.out"; then
        fail_test "M-underindex: the forged image is NOT byte-identical to the compiled under probe -- the forge did something other than substitute the immediate, and the row's claim about eleven bytes is false"
    elif cmp -s "$tmp/m_underindex.elf" "$tmp/base.b_edge/a.out"; then
        fail_test "M-underindex: the forged image is identical to the EDGE probe -- the forge did nothing"
    else
        echo "    M-underindex :: the forged image == the compiled under probe, byte for byte, and differs from the edge probe it was forged from (11 bytes of one immediate)"
        qfault_row M-underindex-qemu "$tmp/m_underindex.elf" "$CR2_UNDER" \
            "the EDGE leg's marker-then-SENTINEL round-trip is VIOLATED: index 2^64-1 addresses buf_2m - 8, inside the LOW guard page, so the store faults before any answer"
    fi
fi
# --- ROW 6 (runtime half): with the low guard PRESENT, the -1 probe completes instead of faulting.
if [[ -x "$tmp/cc.noguardlo" ]]; then
    compile_with "$tmp/cc.noguardlo" "$tmp/b_under.herb" "$tmp/m.nogl_under"
    if compiled_ok "$tmp/m.nogl_under"; then
        qanswer_row M-noguardlo-qemu "$tmp/m.nogl_under/a.out" "the lower guard PDE is present, so index -1 lands in mapped memory"
    else
        fail_test "M-noguardlo-qemu: the under probe did not compile under the mutant ($COMPILE_MSG)"
    fi
fi
# --- ROW 7 (runtime half): at scale 4, index 262144 addresses base + 1 MiB -- inside the buffer.
if [[ -x "$tmp/cc.scale4" ]]; then
    compile_with "$tmp/cc.scale4" "$tmp/b_over.herb" "$tmp/m.s4_over"
    if compiled_ok "$tmp/m.s4_over"; then
        qanswer_row M-scale4-qemu "$tmp/m.s4_over/a.out" "at scale 4 the 262144 probe addresses base + 1 MiB, one page short of the guard it must reach"
    else
        fail_test "M-scale4-qemu: the over probe did not compile under the mutant ($COMPILE_MSG)"
    fi
fi

# ---------------------------------------------------------------- A2's second engine
# Bochs, through the SHARED F2 harness: checked disk build, per-attempt classification, fresh-disk
# re-roll x3 and exhaustion FAILING CLOSED. The frame rule below is the GATE'S OWN, extracted rather
# than copied -- the gate learned the hard way that Bochs's port_e9_hack log is BINARY and that a
# non-byte-aligned matcher invents frames that do not exist.
# The rule itself is extracted in the plumbing near the top, because row 28 grades it long
# before any Bochs leg runs; here it is only sourced.
# shellcheck source=/dev/null
source "$tmp/frames.sh" || { echo "FAIL: link66-mutation (cannot source the extracted frame rule)"; exit 1; }
if [[ ! -f "$script_dir/bochs_f2_harness.sh" ]]; then
    echo "FAIL: link66-mutation (the shared Bochs F2 harness is missing -- A2's second engine cannot be graded)"; exit 1
fi
# shellcheck source=/dev/null
source "$script_dir/bochs_f2_harness.sh" || { echo "FAIL: link66-mutation (cannot source bochs_f2_harness.sh)"; exit 1; }
F2_GATE="link66-mutation"; F2_HARNESS_FAIL=0
if have_bochs && declare -F f2_bochs_feed_attempt >/dev/null; then
    bochs_ran=1
    echo "  -- A2's second engine: the same three rows plus their own named control, on Bochs 2.7 --"
    L66_GRUBCFG="$(printf 'set timeout=0\nset default=0\nmenuentry "l66m" {\n multiboot /boot/kernel.elf\n boot\n}\n')"
    bochs_probe() { # label elf expect(fault|answer)
        local label="$1" elf="$2" expect="$3"
        local W; W="$tmp/$label.b"; rm -rf "$W"; mkdir -p "$W"
        local attempt cls=""
        for attempt in 1 2 3; do
            cls="$(f2_bochs_feed_attempt "--cap $W/cap.bin --hold 20" "$W/feed.log" "$L66_GRUBCFG" 240 64 "$W/out.log" "$elf:boot/kernel.elf")"
            case "$cls" in NO-SHUTDOWN|COMPLETED) break ;; esac
            echo "HARNESS re-roll: link66-mutation $label attempt $attempt = $cls (fresh disk + fresh feeder retry)" >&2
            [[ "$attempt" -eq 3 ]] && f2_harness_error "$label" "$cls"
        done
        local cap; cap=$(xxd -p "$W/cap.bin" 2>/dev/null | tr -d '\n')
        local frames; frames=$(frame_count "$W/out.log")
        echo "    $label :: class=$cls cap=${cap:-EMPTY} frames=$frames"
        case "$cls" in NO-SHUTDOWN|COMPLETED) : ;; *) fail_test "$label (HARNESS class=$cls -- not a kernel verdict; fail-closed)"; return 1 ;; esac
        grep -q "^LISTENING" "$W/feed.log" 2>/dev/null || { fail_test "$label (the feeder never LISTENED -- HARNESS, not a kernel verdict)"; return 1; }
        case "$cap" in "$MARKER"*) : ;; *) fail_test "$label (the marker byte was NOT seen on Bochs; cap=${cap:-EMPTY})"; return 1 ;; esac
        if [[ "$expect" == "fault" ]]; then
            # SUBSTRATE DIFFERENCE, stated rather than tuned around: QEMU runs -no-reboot so a triple
            # fault HALTS and the capture is one marker byte; Bochs RESETS, so the image boots again
            # and emits the marker again until the leg's timeout. The invariant that carries the
            # claim is stronger than a count -- EVERY captured byte is the marker and NOT ONE is an
            # answer -- because a probe that reached its bufget emits a second, different byte.
            local nonmarker; nonmarker=$(printf '%s' "$cap" | sed 's/\(..\)/\1\n/g' | grep -v "^$MARKER\$" | grep -c . || true)
            if [[ "${#cap}" -ge 2 && "$nonmarker" -eq 0 && "$cls" == "NO-SHUTDOWN" ]]; then return 0; fi
            fail_test "$label (expected marker-then-FAULT on Bochs: only marker bytes and NO-SHUTDOWN; cap=$cap nonmarker=$nonmarker class=$cls)"; return 1
        fi
        if [[ "$cls" != "COMPLETED" || "$cap" != "${MARKER}${SENTHEX}" ]]; then
            fail_test "$label (expected the marker-then-SENTINEL round-trip and a COMPLETED boot on Bochs; cap=$cap class=$cls)"; return 1
        fi
        if ! frame_verdict "$W/out.log" "$EDGE_PROOF"; then
            fail_test "$label (the probe must complete through its own tail on Bochs too: frames=$frames want de${EDGE_PROOF}ad x1)"; return 1
        fi
        return 0
    }
    # The design's own named control, and its literal line. Without it a Bochs RED on rows 5, 6 or
    # 7-runtime is not attributable to the mutation rather than to a broken Bochs path.
    if bochs_probe control-bochs "$tmp/base.b_over/a.out" fault; then
        echo "control-bochs: base boundary probe graded GREEN on Bochs (marker seen, no completion frame)"
        scored control-bochs
    fi
    if [[ -f "$tmp/m_underindex.elf" ]] && bochs_probe M-underindex-bochs "$tmp/m_underindex.elf" fault; then
        echo "M-underindex bit RED on Bochs too (A2): the same image faults into guard_lo on a second engine"
        scored M-underindex-bochs
    fi
    if [[ -f "$tmp/m.nogl_under/a.out" ]] && bochs_probe M-noguardlo-bochs "$tmp/m.nogl_under/a.out" answer; then
        echo "M-noguardlo bit RED on Bochs too (A2): with the low guard present the -1 probe COMPLETES on a second engine"
        scored M-noguardlo-bochs
    fi
    if [[ -f "$tmp/m.s4_over/a.out" ]] && bochs_probe M-scale4-bochs "$tmp/m.s4_over/a.out" answer; then
        echo "M-scale4 bit RED on Bochs too (A2): at scale 4 the 262144 probe ANSWERS on a second engine"
        scored M-scale4-bochs
    fi
    # --- ROW 32: M-seedpin-internal-bochs -- A2's own GRADED-SESSION legs, `draw1-bochs` and
    #     `draw2-bochs`, which no chartered row reached. They are NOT the QEMU draw legs on a second
    #     engine sharing one code path: the gate implements `bochs_draw` separately from `qemu_draw`,
    #     with its own class handling, its own seed check, its own capture check and its own witness
    #     check, so a QEMU-side mutant proves nothing about them.
    #
    #     WHAT THIS ROW PROVES, NARROWED after two review lenses landed the same objection: it runs a
    #     REAL Bochs graded session against the pinned harness and shows the seed the harness prints
    #     there is NOT the one the driver drew -- the comparison `bochs_draw` makes at its own seed
    #     check. It does NOT execute `bochs_draw` itself: that function is defined inside the gate's
    #     `have_bochs` block over a closure of the gate's own locals, so it is not extractable the way
    #     `golden_leg`, `frame_verdict`, `boundary_static` and the static battery are, and this row
    #     therefore grades the SAME FACT through its own comparison. Said plainly rather than claimed
    #     away: for the static legs this file grades the gate's OWN code; for the Bochs draw leg it
    #     grades the same discrimination in a restatement.
    #
    #     A wrong-ANSWER mutant was rejected for this leg deliberately, and the reason is Bochs-specific
    #     rather than general: on QEMU this file KILLS the guest once the verdict is recorded, which is
    #     why rows 9 and 10 are cheap. Bochs has no such kill here -- a guest whose answer was rejected
    #     is left blocked on input_byte and the leg runs to its 240 s timeout, three attempts over. A
    #     pinned SEED lets the session complete normally and still go RED.
    if [[ -s "$tmp/feed_pinned.py" ]]; then
        _bs="$(draw_seed "$tmp/seedchan.sh")"
        if [[ "${#_bs}" -ne 32 ]]; then
            fail_test "M-seedpin-internal-bochs: the driver did not draw"
        else
            _W="$tmp/M-seedpin-internal-bochs.b"; rm -rf "$_W"; mkdir -p "$_W"
            _feeder_save="$feeder"; feeder="$tmp/feed_pinned.py"
            _cls=""
            for _attempt in 1 2 3; do
                _cls="$(f2_bochs_feed_attempt "--grade $N:$Q --draw 0 --master-seed ${_bs:0:16} --query-seed ${_bs:16:16} --witness --drain-mode quiet --cap $_W/cap.bin" "$_W/feed.log" "$L66_GRUBCFG" 240 64 "$_W/out.log" "$tmp/base.forcing/a.out:boot/kernel.elf")"
                case "$_cls" in NO-SHUTDOWN|COMPLETED) break ;; esac
                echo "HARNESS re-roll: link66-mutation M-seedpin-internal-bochs attempt $_attempt = $_cls (fresh disk + fresh feeder retry)" >&2
                [[ "$_attempt" -eq 3 ]] && f2_harness_error M-seedpin-internal-bochs "$_cls"
            done
            feeder="$_feeder_save"
            _gl="$(grep -E '^GRADE ' "$_W/feed.log" | tail -1)"
            _sl="$(sed -n 's/^LINK66_SEED=\([0-9a-f]*\).*/\1/p' "$_W/feed.log" | tail -1)"
            echo "    M-seedpin-internal-bochs :: class=$_cls $_gl"
            echo "    M-seedpin-internal-bochs LINK66_SEED=$_sl (harness) driver drew $_bs"
            # NO-SHUTDOWN specifically, and a COMPLETE grade -- a review leg was right that accepting
            # COMPLETED, or scoring without reading the GRADE line at all, lets a feeder that printed
            # its constant and then DIED after LISTENING count as a bite.
            if [[ "$_cls" != "NO-SHUTDOWN" ]]; then
                fail_test "M-seedpin-internal-bochs (class=$_cls, want NO-SHUTDOWN -- the guest must reach the guard access and fault; COMPLETED means it did not, and any other class is a HARNESS failure, not a kernel verdict)"
            elif ! grep -qE 'ok=1' <<<"$_gl" || ! grep -qE "rx=$WANT_RX expected_rx=$WANT_RX extra=0" <<<"$_gl" || ! grep -qE "answers=$Q" <<<"$_gl"; then
                fail_test "M-seedpin-internal-bochs (the Bochs session did not GRADE cleanly, so its seed line is not evidence: ${_gl:-<no GRADE line>})"
            elif ! grep -q "^LISTENING" "$_W/feed.log" 2>/dev/null; then
                fail_test "M-seedpin-internal-bochs (the feeder never LISTENED -- HARNESS, not a kernel verdict)"
            elif [[ "${#_sl}" -ne 32 ]]; then
                fail_test "M-seedpin-internal-bochs (the harness printed no seed line on Bochs: '${_sl:-<none>}') -- an empty read would make this bite vacuously"
            elif [[ "$_sl" == "$_bs" ]]; then
                fail_test "M-seedpin-internal-bochs (the harness echoed the DRAWN seed on Bochs, so the pin did not take)"
            else
                echo "M-seedpin-internal-bochs bit RED on \`draw1-bochs\`'s discrimination: a REAL Bochs graded session (class=NO-SHUTDOWN, ok=1, rx=$WANT_RX, extra=0) printed the harness's internal constant $_sl where the driver drew $_bs -- the comparison bochs_draw makes. STATED EXACTLY: this grades the same FACT through this file's own comparison, because bochs_draw is a closure over the gate's locals and is not extractable; it is NOT the gate's leg body executing"
                scored M-seedpin-internal-bochs
            fi
        fi
    else
        fail_test "M-seedpin-internal-bochs: the pinned harness is missing"
    fi
    if ! declare -F f2_harness_summary >/dev/null; then
        fail_test "bochs-harness (f2_harness_summary is not defined after sourcing -- the shared harness did not load)"
    elif ! f2_harness_summary; then
        fail_test "bochs-harness (Bochs leg(s) exhausted their fresh-disk re-rolls -- attempted-but-unadjudicated legs FAIL CLOSED; NOT a kernel verdict)"
    else
        okleg "bochs-harness"
    fi
elif [[ "$REQUIRE_EMU" == "1" ]]; then
    fail_test "require-bochs (KERNEL_CODEGEN_REQUIRE_EMU=1 but the Bochs/sudo prerequisites are missing -- A2 requires the second engine)"
else
    echo "  NOTE: Bochs prerequisites missing -- A2's second-engine rows skipped locally; CI is the fail-closed enforcer."
fi
fi

# ---------------------------------------------------------------- verdict
echo ""
if [[ "$fail" -ne 0 ]]; then
    echo "$fail link66-mutation sub-test(s) failed."
    exit 1
fi
# THE BANNER IS BUILT FROM THE LEDGER, and this is a fix, not a flourish. Both review lenses landed
# the same BLOCKER independently: the previous banner was a FIXED STRING naming `control-qemu`,
# `control-bochs`, `seed-freshness` and every booting mutant unconditionally, so on a host with no
# QEMU the booting block was skipped, `fail` stayed 0, and the file still asserted that twenty-two
# mutants bit RED -- while its own `$SUBSTRATES` line said Bochs had not run. The comment above the
# old banner said exactly what the code did.
REQUIRED_ROWS="M-decorative M-literal M-recursionstore M-deadsib M-underindex M-noguardlo M-scale4 \
M-basebias M-wrongidx M-constidx M-memsz M-opsize-49 M-opsize-50 M-opsize-51 M-golden M-nopredicate \
M-noirgate M-pops M-op51noret M-seedpin-env M-seedpin-internal M-driverpin"
# Rows 24-31, added in slice 6 to close the per-leg residual the parent ruled on: each covers a
# gate leg that no chartered row reached. Listed separately so the ORIGINAL twenty-two, and then
# row 23, stay auditable as sets.
REQUIRED_RESIDUAL="M-golden-boundary M-elfheader M-sourceshape M-parser M-frameverdict M-irgate2 \
M-singlefunc M-boundaryimages M-parserpos M-harnesssummary M-seedpin-internal-bochs"
REQUIRED_CONTROLS="control-static control-seed-refusal control-seed-echo control-noirgate control-qemu \
control-bochs seed-freshness bochs-harness M-driverpin-seedecho-green M-op51noret-static"
# Row 23, ACCEPTED by parent ruling 2026-09-03 after a blind refutation lens showed no chartered row
# covers its shape. Kept in its own list so the ORIGINAL twenty-two stay auditable as a set.
REQUIRED_ADDED="M-seedpin-late"
MISSING=""
for _r in $REQUIRED_ROWS $REQUIRED_CONTROLS $REQUIRED_ADDED $REQUIRED_RESIDUAL; do row_ran "$_r" || MISSING="$MISSING $_r"; done
SUBSTRATES="static/compile-time only"
if [[ "$boot_legs" -eq 1 ]]; then
    SUBSTRATES="QEMU-TCG"
    if [[ "$bochs_ran" -eq 1 ]]; then SUBSTRATES="$SUBSTRATES + Bochs $(bochs_version) (A2, dual-substrate on every runtime-fault row; version DETECTED -- CI pins 2.8, every local figure is 2.7)"
    else SUBSTRATES="$SUBSTRATES ONLY -- Bochs did NOT run, so A2's second engine is UNOBSERVED on this host"; fi
fi
echo "LEGS THAT RAN AND SCORED ($pass):$RAN"
if [[ -n "$MISSING" ]]; then
    # Fail-closed where it matters: CI sets KERNEL_CODEGEN_REQUIRE_EMU=1 and the substrate guards
    # above already exit non-zero there, so this road exists for a developer host -- and it names
    # what did NOT run instead of claiming it did.
    echo "PARTIAL: link66-mutation ($pass legs on $SUBSTRATES; the following chartered rows/controls did NOT execute on this host and NOTHING is claimed of them:$MISSING)"
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        echo "FAIL: link66-mutation (KERNEL_CODEGEN_REQUIRE_EMU=1 and chartered rows did not execute:$MISSING)"
        exit 1
    fi
    exit 0
fi
echo "PASS: link66-mutation ($pass legs on $SUBSTRATES: controls GREEN -- control-static (the base image passes all 16 gate static legs), control-seed-refusal, control-seed-echo, control-qemu (base image graded GREEN on QEMU-TCG, answer stream == host table), control-bochs (base boundary probe graded GREEN on Bochs, marker seen, no completion frame), seed-freshness (two consecutive graded runs printed different seeds), M-noirgate's base-refuses control and M-golden's base-matches -- and each of the twenty-three chartered mutants bit RED on its OWN targeted leg with the committed hash out of circuit for all but M-golden: M-decorative (sites) + M-literal (rawdecode) + M-recursionstore/M-deadsib (the black-box floor alone; they answer a constant, so they are P_forge~0 forgers and NOT the design's priced chain forgery) + M-underindex (the EDGE leg's marker-then-SENTINEL round-trip is violated by a fault at the derived guard_lo address, QEMU and Bochs) + M-noguardlo (pd-guards; the -1 probe completes, QEMU and Bochs) + M-scale4 (rawdecode; the 262144 probe answers, QEMU and Bochs) + M-basebias (bufbase-eq; its runtime leg ON THE GRADED DRAW is GREEN by design and is not booted) + M-wrongidx/M-constidx (the answer stream) + M-memsz (pmemsz) + M-opsize-49/50/51 (ERR 610/611/611 at compile time) + M-golden (the committed hash with its base-matches control) + M-nopredicate (pd-guards AND bufbase-eq, static only by parent ruling) + M-noirgate (reject-nobufop: the no-buf-op probe compiles where the base compiler refuses it) + M-pops (ERR 605) + M-op51noret (the fill echo, and the byte-window pin too) + M-seedpin-env (seed-refusal, and a program storing no payload then grades GREEN on an attacker-chosen seed) + M-seedpin-internal (seed-echo AND seed-freshness) + M-driverpin (seed-freshness ONLY, with seed-echo PROVEN absent from its FAIL set rather than asserted) + M-seedpin-late (row 23: the harness echoes the DRAWN seed verbatim and generates from a constant, so BOTH A1 legs are green against it and only the driver's own independent derivation of the whole receive transcript catches it); and TEN MORE rows added in slice 6 to close the per-leg residual, each covering a gate leg no chartered row reached: M-golden-boundary (the three boundary hashes M-golden never touched) + M-elfheader (elf-header, the only leg that reads p_type) + M-sourceshape (source-shape, graded by longbuf_spec's own predicate) + M-parser (frame-cardinality) + M-parserpos (frame-terminal) + M-frameverdict (reject-twoframe -- LEDGER D26's own defect, restored deliberately, and the rule ACCEPTS a two-frame stream again) + M-irgate2 (accept-oneidx, the POSITIVE side of the IR boundary) + M-singlefunc (reject-singlefunc) + M-boundaryimages (boundary-images, the constant-collapse the decoder was written for) + M-seedpin-internal-bochs (draw1-bochs -- A2's GRADED-SESSION leg, which bochs_draw implements separately from qemu_draw, so no QEMU-side row covers it). COVERAGE, STATED EXACTLY RATHER THAN ROUNDED: the STATIC legs are graded through the gate's OWN extracted code (its 16-leg battery, golden_leg, boundary_static, frame_verdict), and after rows 24-34 every static leg has a row that REQUIRES it -- counts, windows, sib-exclusivity, pushints and displacements are required inside M-decorative and geometry inside M-noguardlo, rather than being counted from FAIL-set spill. The RUNTIME legs (draw1-qemu, draw2-qemu, draw1-bochs, draw2-bochs, draw1-kvm) are graded by THIS FILE'S session driver, which models the gate's rather than executing it: the booting rows prove the discriminations exist, not that the gate's own leg bodies run them. draw2-qemu, draw2-bochs and draw1-kvm additionally have no row of their own and are JUSTIFIED in SCOPE-BUILD.md as the same functions their draw-1 siblings exercise)"
exit 0
