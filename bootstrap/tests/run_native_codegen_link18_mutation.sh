#!/usr/bin/env bash
# toakie (Link 18) MUTATION proof -- the "prove the gate bites" forcing function.
#
# The link18 dual-substrate gate is only meaningful if a WRONG compiler would
# fail it. We prove that by mutating the compiler SOURCE at a unique anchor and
# re-emitting a green probe, then asserting each mutation is CAUGHT by at least
# one gate. This exercises BOTH gate kinds and names which one fired:
#   - the BLACK-BOX boot differential (the emitted byte changes), and
#   - the WHITE-BOX static gate (real jcc + every branch target on an instruction
#     boundary + a NEGATIVE-displacement frame store/load round-trip).
# Some mutations are behaviorally invisible to the boot differential -- e.g.
# flipping the local displacement sign makes store and load BOTH use [ebp+N], so
# the value still round-trips and the byte is unchanged (the zelph lesson). Those
# are caught only by the white-box gate. A mutation that escaped BOTH would mean
# the gate does not bite. The unmutated control must pass every gate.
#
# SOVEREIGNTY (link 15 / assay): this proof is C-FREE. It NO LONGER re-emits
# through the C interpreter. Instead it runs each mutation through a genuine
# TWO-STAGE seed compile: the committed C-free gen-1 seed compiles the (mutated)
# backend into a native gen-1' compiler ELF, and THAT compiler emits the probe.
# This is strictly MORE faithful than the prior C path AND than a binary-patch:
# it runs the ACTUAL mutated compiler and checks the gate catches ITS output, so
# the proof's meaning ("a wrong compiler is caught") survives C's deletion intact
# -- including the "no-image" mutation (M4), where the mutated compiler's own
# body-length invariant refuses to emit, which only a real compile can reproduce.
# A retireable cross-check -- DEFAULT-ON when C is present, opt-OUT via
# LINK18_MUTATION_NO_C=1 -- also re-emits each mutation via the C interpreter
# and asserts the native
# two-stage image is BYTE-IDENTICAL to the C image (substrate faithfulness, while
# C still exists); it retires WITH C at the switchover.
#
# QEMU-only (no losetup/sudo), gated behind KERNEL_CODEGEN_MUTATION=1 (or
# REQUIRE_EMU=1) so it does not slow the default make test. Each anchor is
# asserted to occur EXACTLY ONCE, so a drifted anchor fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then
    echo "SKIP: native-codegen link18 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: native-codegen link18 mutation proof (no qemu)"; exit 0
fi

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${LINK18_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

pass=0; fail=0
fail_test() { echo "FAIL: link18-mutation ($1)"; fail=$((fail + 1)); }

# merge_then exercises EQ, the conditional branch, the BR-to-join, the frame
# store/load round-trip, ADD, and the 2-pass layout -- a wrong anything shifts it.
PROBE='func main(): let x = 6*7  let y = x+1  let r = 0  if y == 43: r = y+3 else: r = y-5 end  return r end'
GOLDEN=46

emit_seq=0
# white-box check on an emitted ELF: returns 0 (pass) / 1 (fail). Bounded to the
# real code (body+epilogue) by the epilogue terminal faf4ebfd (cli;hlt;jmp $-1),
# so a target landing in trailing padding cannot false-pass.
whitebox_ok() { # elf
    local elf="$1" code="$tmp/wb.$emit_seq.code"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    local term="${chx%%faf4ebfd*}"
    [[ "$term" == "$chx" ]] && return 1            # epilogue terminal absent
    local endbytes=$(( ${#term} / 2 + 4 ))
    dd if="$code" of="$code.t" bs=1 count="$endbytes" status=none 2>/dev/null
    # address-colon prefix selector (NOT grep ':\t' -- \t is literal there and
    # matches nothing; verified at toakie that it false-failed every good image).
    local dis; dis=$(objdump -D -b binary -m i386 -M intel "$code.t" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
    [[ -n "$dis" ]] || return 1
    echo "$dis" | grep -qE '\bje\b' || return 1    # (a) a real conditional jump
    local addrs; addrs=$(echo "$dis" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
    local t                                        # (b) every je/jmp target on a boundary
    for t in $(echo "$dis" | grep -oE '\b(je|jmp) +0x[0-9a-f]+' | grep -oE '[0-9a-f]+$' | sort -u); do
        echo "$addrs" | grep -qiE "^0*${t}$" || return 1
    done
    local d                                        # (c) negative-disp store+load round-trip
    for d in fc f8 f4 f0 ec; do
        if echo "$chx" | grep -q "8f45${d}" && echo "$chx" | grep -q "ff75${d}"; then return 0; fi
    done
    return 1
}

# emit_via(compiler, outdir): the given native compiler ELF emits the PROBE. Sets
# $EMIT_IMG to the emitted image path, or "" if the compiler refused to emit.
EMIT_IMG=""
emit_via() {
    local compiler="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$compiler" < p.herb >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then EMIT_IMG="$d/a.out"; else EMIT_IMG=""; fi
}

# seed_compile(backend_src, outpath): the C-free seed compiles a (mutated) backend
# into a native gen-1' compiler ELF. Echoes "" if the backend did not compile.
seed_compile() {
    local src="$1" out="$2" d; d="$(mktemp -d "$tmp/sc.XXXX")"
    ( cd "$d" && "$SEED" < "$src" >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then cp "$d/a.out" "$out"; chmod +x "$out"; echo "$out"; else echo ""; fi
}

# assess(compiler) -> echoes "GREEN" (passes every gate, == control) or
# "CAUGHT:<which gate fired>". The given native compiler ELF emits the probe and
# the emitted image is run through the white-box + boot gates.
assess() {
    local compiler="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"
    emit_via "$compiler" "$d"
    [[ -n "$EMIT_IMG" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$EMIT_IMG" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    whitebox_ok "$EMIT_IMG" || { echo "CAUGHT:whitebox"; return; }
    : > "$d/e9"
    timeout 30 qemu-system-x86_64 -kernel "$EMIT_IMG" -debugcon file:"$d/e9" -display none \
        -no-reboot -serial none -monitor none -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -cpu qemu64 -m 64M >/dev/null 2>&1
    local hx; hx=$(xxd -p "$d/e9" 2>/dev/null | tr -d '\n')
    if [[ "$hx" =~ ^de([0-9a-f][0-9a-f])ad$ ]]; then
        local b=$((16#${BASH_REMATCH[1]}))
        [[ "$b" == "$GOLDEN" ]] && { echo "GREEN"; return; }
        echo "CAUGHT:boot($b)"; return
    fi
    echo "CAUGHT:boot(noframe:$hx)"
}

# control: the unmutated compiler is the SEED itself (the gen-1 fixpoint); it must
# pass EVERY gate (white-box + boot golden) C-FREE.
ctrl=$(assess "$SEED")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated seed compiler passes all gates C-free (white-box + boot=$GOLDEN)"; pass=$((pass+1));
else echo "FAIL control: unmutated seed compiler did not pass cleanly: $ctrl"; fail=$((fail+1)); fi
[[ "$XCHECK" == "1" ]] && echo "  (retireable C cross-check ON: each mutation's native two-stage image is asserted byte-identical to the C image)"

# c_emit(backend_src, outdir): the RETIREABLE C path -- the C interpreter runs the
# (mutated) backend to emit the probe. Sets $C_IMG (or "" if no image).
C_IMG=""
c_emit() {
    local src="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$src" < p.herb >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then C_IMG="$d/a.out"; else C_IMG=""; fi
}

# mutate(name, old, new [, expect_no_image_diag]): old must occur exactly once; the
# mutant must be CAUGHT. The C-free seed compiles the mutated backend -> gen1'
# compiler, which emits the probe (two-stage). Optionally cross-checked byte-identical
# to the C image. If expect_no_image_diag is given (M4), a "no-image" verdict is only
# a genuine catch when the mutated compiler emits THAT reject diagnostic (its own
# layout invariant), NOT any incidental empty image -- closing the no-image catch-all.
mutate() {
    local name="$1" old="$2" new="$3" expect_no_image_diag="${4:-}"
    local n; n=$(python3 - "$backend" "$old" <<'PY'
import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))
PY
)
    if [[ "$n" != "1" ]]; then fail_test "$name: anchor occurs $n times (want 1) -- anchor drifted"; return; fi
    local mut="$tmp/mut.$name.herb"
    python3 - "$backend" "$old" "$new" "$mut" <<'PY'
import sys
open(sys.argv[4],"w").write(open(sys.argv[1]).read().replace(sys.argv[2],sys.argv[3],1))
PY
    # two-stage: seed compiles the mutated backend into a native gen1' compiler.
    local gen1x; gen1x=$(seed_compile "$mut" "$tmp/gen1x.$name")
    if [[ -z "$gen1x" ]]; then fail_test "$name: seed could not compile the mutated backend (two-stage stage-1 failed)"; return; fi
    local v; v=$(assess "$gen1x")
    if [[ "$v" != CAUGHT:* ]]; then
        fail_test "$name: mutant escaped ALL gates (verdict=$v) -- the gate does NOT bite"; return
    fi
    # no-image pin: a "no-image" catch must be the mutated compiler's OWN reject
    # diagnostic (ERR 452 layout invariant), not an incidental empty image.
    if [[ "$v" == "CAUGHT:no-image" && -n "$expect_no_image_diag" ]]; then
        local dd; dd="$(mktemp -d "$tmp/diag.XXXX")"
        printf -- '-- emit: multiboot32\n%s\n' "$PROBE" > "$dd/p.herb"
        local diag; diag="$( cd "$dd" && "$gen1x" < p.herb 2>&1 )"
        if [[ "$diag" != *"$expect_no_image_diag"* ]]; then
            fail_test "$name: no-image but NOT the expected reject '$expect_no_image_diag' (got: $(echo "$diag" | tr '\n' ' ')) -- a non-load-bearing empty image"; return
        fi
    elif [[ "$v" == "CAUGHT:no-image" && -z "$expect_no_image_diag" ]]; then
        fail_test "$name: unexpected no-image catch for a mutation that should emit a wrong image"; return
    fi
    # retireable faithfulness: the native two-stage image == the C image, byte-for-byte
    # (or both produce no image). Confirms the C->seed substrate swap is loss-free.
    if [[ "$XCHECK" == "1" ]]; then
        emit_via "$gen1x" "$tmp/nat.$name"; local nimg="$EMIT_IMG"
        c_emit "$mut" "$tmp/c.$name"; local cimg="$C_IMG"
        if [[ -z "$nimg" && -z "$cimg" ]]; then :   # both no-image (M4) -- faithful
        elif [[ -n "$nimg" && -n "$cimg" ]] && cmp -s "$nimg" "$cimg"; then :   # byte-identical -- faithful
        else fail_test "$name: native two-stage image != C image (substrate faithfulness broken: nat=${nimg:-<none>} c=${cimg:-<none>})"; return; fi
    fi
    echo "PASS mutation $name: $v"; pass=$((pass+1))
}

# M1: jz(0x84/132) -> jnz(0x85/133) in BR_IF_FALSE (branch polarity). Boot-caught.
mutate jz_to_jnz \
'    elif op == 17:
        do append(buf, 88)
        do append(buf, 133)
        do append(buf, 192)
        do append(buf, 15)
        do append(buf, 132)' \
'    elif op == 17:
        do append(buf, 88)
        do append(buf, 133)
        do append(buf, 192)
        do append(buf, 15)
        do append(buf, 133)'

# M2: EQ sete(0x94/148) -> setne(0x95/149) (comparison inverted). Boot-caught.
mutate eq_to_ne \
'    elif op == 11:
        do append(buf, 89)
        do append(buf, 88)
        do append(buf, 57)
        do append(buf, 200)
        do append(buf, 15)
        do append(buf, 148)' \
'    elif op == 11:
        do append(buf, 89)
        do append(buf, 88)
        do append(buf, 57)
        do append(buf, 200)
        do append(buf, 15)
        do append(buf, 149)'

# M3: local displacement sign flip ([ebp-N] -> [ebp+N]). BEHAVIORALLY INVISIBLE to
# the boot differential (store and load both use +N, value round-trips) -- this
# is the zelph-class mutation that ONLY the white-box gate catches.
mutate local_disp_sign \
'    do append(buf, 256 - 4 * (slot + 1))' \
'    do append(buf, 4 * (slot + 1))'

# M4: mis-size PUSH_INT in the layout pass (5 -> 6) so layout offsets desync from
# the lowering. The body-length invariant rejects it (no image). This is the case
# only a real compile reproduces: the mutated compiler's OWN invariant refuses to
# emit -- a binary patch of a good image could never produce it.
mutate pushint_layout_size \
'    if op == 0:
        return 5
    end
    if op == 3:' \
'    if op == 0:
        return 6
    end
    if op == 3:' \
'ERR 452'

# M5: ADD(0x01) -> AND(0x21) (wrong ALU op). Boot-caught (wrong byte).
mutate add_opcode \
'    elif op == 5:
        do append(buf, 89)
        do append(buf, 88)
        do append(buf, 1)
        do append(buf, 200)
        do append(buf, 80)' \
'    elif op == 5:
        do append(buf, 89)
        do append(buf, 88)
        do append(buf, 33)
        do append(buf, 200)
        do append(buf, 80)'

# M6: mis-resolve the BR_IF_FALSE target by +1 (length-preserving). The jcc then
# lands one byte into an instruction -- invisible to the length invariant, caught
# by the white-box target-on-boundary check (the Codex off-by-one demand).
# Anchor includes the 32-bit BR_IF_FALSE prologue bytes (58 85 c0 0f 84: pop;test
# eax,eax;je) so it pins the nc32_lower_loop op-17 site EXACTLY -- trikea/f2's
# nc64_lower_loop op-17 has the identical toff2-endoff block but emits 58 48 85...
# (the REX.W do-append-72 between 88 and 133), so this anchor stays nc32-unique.
mutate brif_target_off_by_one \
'        do append(buf, 88)
        do append(buf, 133)
        do append(buf, 192)
        do append(buf, 15)
        do append(buf, 132)
        let t2 = get(code, i).1
        let toff2 = epi
        if t2 < n:
            toff2 = get(offs, t2)
        end
        buf = nc_append_le32(buf, toff2 - endoff)' \
'        do append(buf, 88)
        do append(buf, 133)
        do append(buf, 192)
        do append(buf, 15)
        do append(buf, 132)
        let t2 = get(code, i).1
        let toff2 = epi
        if t2 < n:
            toff2 = get(offs, t2)
        end
        buf = nc_append_le32(buf, toff2 - endoff + 1)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link18-mutation check(s) failed."; exit 1; fi
xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: link18 mutation proof ($pass checks: control passes all gates C-FREE; 6 mutations each CAUGHT via a real two-stage seed compile of the mutated backend -- jcc polarity (boot), EQ polarity (boot), local-disp sign (white-box, behaviorally invisible to boot), layout offset size (no-image, only a real compile reproduces it), ALU opcode (boot), branch-target off-by-one (white-box)$xc)"
exit 0
