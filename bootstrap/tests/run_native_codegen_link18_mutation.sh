#!/usr/bin/env bash
# toakie (Link 18) MUTATION proof -- the "prove the gate bites" forcing function.
#
# The link18 dual-substrate gate is only meaningful if a WRONG compiler would
# fail it. We prove that by mutating the compiler SOURCE at a unique anchor and
# re-emitting a green probe through the C-interpreted backend: each mutation must
# be CAUGHT by at least one gate. Crucially, this exercises BOTH gate kinds and
# names which one fired:
#   - the BLACK-BOX boot differential (the emitted byte changes), and
#   - the WHITE-BOX static gate (real jcc + every branch target on an instruction
#     boundary + a NEGATIVE-displacement frame store/load round-trip).
# Some mutations are behaviorally invisible to the boot differential -- e.g.
# flipping the local displacement sign makes store and load BOTH use [ebp+N], so
# the value still round-trips and the byte is unchanged (the zelph lesson). Those
# are caught only by the white-box gate. A mutation that escaped BOTH would mean
# the gate does not bite. The unmutated control must pass every gate.
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

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
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

# assess(compiler_src) -> echoes "GREEN" (passes every gate, == control) or
# "CAUGHT:<which gate fired>".
assess() {
    local comp="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$comp" < p.herb >/dev/null 2>/dev/null )
    [[ -f "$d/a.out" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$d/a.out" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    whitebox_ok "$d/a.out" || { echo "CAUGHT:whitebox"; return; }
    : > "$d/e9"
    timeout 30 qemu-system-x86_64 -kernel "$d/a.out" -debugcon file:"$d/e9" -display none \
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

# control: unmutated compiler must pass EVERY gate (white-box + boot golden).
ctrl=$(assess "$backend")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated compiler passes all gates (white-box + boot=$GOLDEN)"; pass=$((pass+1));
else echo "FAIL control: unmutated compiler did not pass cleanly: $ctrl"; fail=$((fail+1)); fi

# mutate(name, old, new): old must occur exactly once; the mutant must be CAUGHT.
mutate() {
    local name="$1" old="$2" new="$3"
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
    local v; v=$(assess "$mut")
    if [[ "$v" == CAUGHT:* ]]; then echo "PASS mutation $name: $v"; pass=$((pass+1));
    else fail_test "$name: mutant escaped ALL gates (verdict=$v) -- the gate does NOT bite"; fi
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
# the lowering. The body-length invariant rejects it (no image).
mutate pushint_layout_size \
'    if op == 0:
        return 5
    end
    if op == 3:' \
'    if op == 0:
        return 6
    end
    if op == 3:'

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
echo "PASS: link18 mutation proof ($pass checks: control passes all gates; 6 mutations each CAUGHT -- jcc polarity (boot), EQ polarity (boot), local-disp sign (white-box, behaviorally invisible to boot), layout offset size (length invariant), ALU opcode (boot), branch-target off-by-one (white-box))"
exit 0
