#!/usr/bin/env bash
# zonday (Link 19) MUTATION proof -- the "prove the fault-catch gate bites" forcing
# function. The link19 dual-substrate gate is only meaningful if a WRONG compiler
# would fail it. We prove that by mutating the compiler SOURCE at a unique anchor
# and re-emitting a green probe: each mutation must be CAUGHT (a wrong/absent byte
# under QEMU, or a boot-invisible head change caught by the exact-head white-box gate).
#
# zonday's central claim is "the byte was produced by the CPU vectoring a genuine
# #DE to my installed handler." Every mutation here attacks exactly that path and
# is BLACK-BOX (boot) caught, because catching a hardware fault is inherently
# behavioral -- a broken IDT/gate/selector triple-faults (no byte), and a missing
# or unvalidated fault falls through to the 0xBB sentinel (wrong byte). (The
# white-box structural gates -- lgdt/lidt, the absolute far-jmp, the gate offset ==
# handler vaddr, the flat GDT descriptors, no x86 ret -- are asserted per-probe in
# run_native_codegen_link19.sh.) The unmutated control must emit the golden byte.
#
# SOVEREIGNTY (link 16): this proof is C-FREE. It NO LONGER re-emits through the C
# interpreter. Instead it runs each mutation through a genuine TWO-STAGE seed
# compile (the assay/link18 template): the committed C-free gen-1 seed compiles the
# (mutated) backend into a native gen-1' compiler ELF, and THAT compiler emits the
# probe. This is strictly MORE faithful than the prior C path: it runs the ACTUAL
# mutated compiler and checks the gate catches ITS output, so the proof's meaning
# ("a wrong compiler is caught") survives C's deletion intact. A retireable
# cross-check -- DEFAULT-ON when C is present, opt-OUT via LINK19_MUTATION_NO_C=1 --
# also re-emits each mutation via the C interpreter and asserts the native two-stage
# image is BYTE-IDENTICAL to the C image (substrate faithfulness, while C still
# exists); it retires WITH C at the switchover.
#
# QEMU-only (no losetup/sudo), gated behind KERNEL_CODEGEN_MUTATION=1 (or
# REQUIRE_EMU=1). Each anchor is asserted to occur EXACTLY ONCE, so a drifted
# anchor fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then
    echo "SKIP: native-codegen link19 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: native-codegen link19 mutation proof (no qemu)"; exit 0
fi

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${LINK19_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

pass=0; fail=0
fail_test() { echo "FAIL: link19-mutation ($1)"; fail=$((fail + 1)); }

# A branching handler: x=6*7=42 (==42 true) -> return 88. Exercises the #DE
# trigger, the IDT vector, the faulting-EIP wrapper, and a real compiled branch.
PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=88

emit_seq=0
# assess(compiler) -> "GREEN" (valid image whose boot emits the golden byte) or
# "CAUGHT:<why>". The given native compiler ELF emits the probe; the fault-catch
# path is judged by the emitted byte on QEMU + the exact-head white-box gate.
EMIT_IMG=""
emit_via() {
    local compiler="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-idt\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$compiler" < p.herb >emit.out 2>&1 )
    if [[ -f "$d/a.out" ]]; then EMIT_IMG="$d/a.out"; else EMIT_IMG=""; fi
}
assess() {
    local compiler="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"
    emit_via "$compiler" "$d"
    [[ -n "$EMIT_IMG" ]] && cp "$EMIT_IMG" "$compiler.graded" 2>/dev/null
    [[ -z "$EMIT_IMG" ]] && cp "$d/emit.out" "$compiler.emiterr" 2>/dev/null
    [[ -n "$EMIT_IMG" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$EMIT_IMG" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    # exact-head white-box gate (pins straight-line lidt->div->wrapper; closes the
    # "forge the fault frame" bypass and catches boot-invisible head changes).
    local head; head=$(dd if="$EMIT_IMG" bs=1 skip=4108 count=63 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local hre='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}31d231c9f7f1b0bbe9[0-9a-f]{8}813c243900100075f0$'
    [[ "$head" =~ $hre ]] || { echo "CAUGHT:head"; return; }
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

# seed_compile(backend_src, outpath): the C-free seed compiles a (mutated) backend
# into a native gen-1' compiler ELF. Echoes "" if the backend did not compile.
seed_compile() {
    local src="$1" out="$2" d; d="$(mktemp -d "$tmp/sc.XXXX")"
    ( cd "$d" && "$SEED" < "$src" >/dev/null 2>/dev/null )
    # require a real ELF (magic 7f454c46), not merely a present a.out -- a truncated or
    # partial stage-1 output must not be accepted as a compiler (Codex link16 review).
    if [[ -f "$d/a.out" && "$(head -c4 "$d/a.out" | xxd -p | tr -d '\n')" == "7f454c46" ]]; then
        cp "$d/a.out" "$out"; chmod +x "$out"; echo "$out"; else echo ""; fi
}

# c_emit(backend_src, outdir): the RETIREABLE C path -- the C interpreter runs the
# (mutated) backend to emit the probe. Sets $C_IMG (or "" if no image).
C_IMG=""
c_emit() {
    local src="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-idt\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$src" < p.herb >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then C_IMG="$d/a.out"; else C_IMG=""; fi
}

# control: the unmutated compiler is the SEED itself (the gen-1 fixpoint); it must
# emit the golden byte via the #DE fault path C-FREE.
ctrl=$(assess "$SEED")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated seed compiler emits golden=$GOLDEN via the #DE fault path C-free"; pass=$((pass+1));
else echo "FAIL control: unmutated seed compiler did not pass cleanly: $ctrl"; fail=$((fail+1)); fi
[[ "$XCHECK" == "1" ]] && echo "  (retireable C cross-check ON: each mutation's native two-stage image is asserted byte-identical to the C image)"

# mutate(name, old, new [, expect_no_image_diag]): old must occur exactly once; the
# mutant must be CAUGHT. The C-free seed compiles the mutated backend -> gen1'
# compiler, which emits the probe (two-stage). Optionally cross-checked byte-identical
# to the C image. If expect_no_image_diag is given, a "no-image" verdict is only a
# genuine catch when the mutated compiler emits THAT reject diagnostic (its own
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
    # diagnostic, not an incidental empty image.
    if [[ -n "$expect_no_image_diag" ]]; then
        if [[ "$v" != "CAUGHT:no-image" ]]; then
            fail_test "$name: expected a no-image catch ($expect_no_image_diag) but got $v -- a layout-invariant mutation must refuse to emit"; return
        fi
        # bind the diagnostic to the SAME run assess() graded as no-image (its captured
        # output, saved to $gen1x.emiterr) -- NOT a re-run (Codex link16 review).
        local diag=""; [[ -f "$gen1x.emiterr" ]] && diag="$(cat "$gen1x.emiterr")"
        if [[ "$diag" != *"$expect_no_image_diag"* ]]; then
            fail_test "$name: no-image but NOT the expected reject '$expect_no_image_diag' (got: $(echo "$diag" | tr '\n' ' ')) -- a non-load-bearing empty image"; return
        fi
    elif [[ "$v" == "CAUGHT:no-image" ]]; then
        fail_test "$name: unexpected no-image catch for a mutation that should emit a wrong image"; return
    fi
    # retireable faithfulness: the native two-stage image == the C image, byte-for-byte
    # (or both produce no image). Confirms the C->seed substrate swap is loss-free.
    if [[ "$XCHECK" == "1" ]]; then
        # compare the EXACT image assess() graded (saved as $gen1x.graded), not a re-emit, so a
        # stateful/nondeterministic compiler cannot grade image A then compare a clean image B
        # (Codex link16 review -- bind the assessed artifact itself).
        local nimg=""; [[ -f "$gen1x.graded" ]] && nimg="$gen1x.graded"
        c_emit "$mut" "$tmp/c.$name"; local cimg="$C_IMG"
        if [[ -z "$nimg" && -z "$cimg" ]]; then :   # both no-image -- faithful
        elif [[ -n "$nimg" && -n "$cimg" ]] && cmp -s "$nimg" "$cimg"; then :   # byte-identical -- faithful
        else fail_test "$name: native two-stage image != C image (substrate faithfulness broken: nat=${nimg:-<none>} c=${cimg:-<none>})"; return; fi
    fi
    echo "PASS mutation $name: $v"; pass=$((pass+1))
}

# M1: corrupt the IDTR base (the IDT can no longer be located). The #DE finds no
# valid gate -> #GP during delivery -> double -> triple fault -> no byte.
# (Anchor includes zonday's IDTR limit `7` prefix so it stays unique: chosen's
# multiboot32-page mode also emits `nc_append_le32(buf, idt_vaddr)`, but with limit 119.)
mutate idtr_base \
'    do append(buf, 7)
    do append(buf, 0)
    buf = nc_append_le32(buf, idt_vaddr)' \
'    do append(buf, 7)
    do append(buf, 0)
    buf = nc_append_le32(buf, idt_vaddr + 4096)'

# M2: point the IDT gate offset one byte off the handler (wrapper) vaddr. The CPU
# vectors mid-instruction -> wrong/no byte.
mutate gate_offset_off_by_one \
'    let gate_vaddr = 1048642' \
'    let gate_vaddr = 1048643'

# M3: remove the #DE trigger (div ecx -> two nops). No fault fires, so control
# falls through to the 0xBB SENTINEL -> wrong byte. (Proves the fault genuinely
# fires in the green image, and the sentinel witnesses its absence.)
mutate remove_trigger \
'    do append(buf, 49)
    do append(buf, 201)
    do append(buf, 247)
    do append(buf, 241)
    do append(buf, 176)
    do append(buf, 187)' \
'    do append(buf, 49)
    do append(buf, 201)
    do append(buf, 144)
    do append(buf, 144)
    do append(buf, 176)
    do append(buf, 187)'

# M4: corrupt the gate code selector (0x08 -> 0x18, outside the 3-entry GDT). The
# CPU raises #GP while delivering the #DE -> triple fault -> no byte.
# (Anchor extended through the ghi bytes + zonday's IDTR limit `7, 0` (0x0007) so it stays
# unique: chosen's multiboot32-page mode emits the same gate block but with IDTR limit 119, and
# timer's multiboot32-timer mode emits it with IDTR limit 0x0107 = `7, 1` -- the trailing `0`
# (the limit HIGH byte) distinguishes zonday's single-entry IDT from both.)
mutate bad_gate_selector \
'    do append(buf, glo % 256)
    do append(buf, glo / 256)
    do append(buf, 8)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 142)
    do append(buf, ghi % 256)
    do append(buf, ghi / 256)
    do append(buf, 7)
    do append(buf, 0)' \
'    do append(buf, glo % 256)
    do append(buf, glo / 256)
    do append(buf, 24)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 142)
    do append(buf, ghi % 256)
    do append(buf, ghi / 256)
    do append(buf, 7)
    do append(buf, 0)'

# M5: corrupt the wrapper's faulting-EIP check (expect div EIP+1). A genuine #DE
# pushes the real div EIP, so the check now MISMATCHES -> jne sentinel -> 0xBB.
# This proves the "via the fault path" wrapper guard is load-bearing, not dead code.
# (The head bytes also change, so the exact-head gate catches it first.)
mutate wrapper_eip_check \
'    buf = nc_append_le32(buf, 1048633)' \
'    buf = nc_append_le32(buf, 1048634)'

# M6: flip the sentinel byte (0xBB -> 0x42). BEHAVIORALLY INVISIBLE to the boot
# differential -- correct execution faults and never reaches the sentinel, so the
# golden byte still emits -- and caught ONLY by the exact-head white-box gate. This
# is the boot-invisible case that closes the "byte came via the #DE path" proof gap
# the cross-model pre-land review found.
# (Anchor includes the div's `241`=0xF1 prefix so it stays unique: chosen's
# multiboot32-page head emits the same `mov al,0xBB; jmp` sentinel, but preceded by the
# TOUCH-B address, not the div.)
mutate flip_sentinel \
'    do append(buf, 241)
    do append(buf, 176)
    do append(buf, 187)
    do append(buf, 233)' \
'    do append(buf, 241)
    do append(buf, 176)
    do append(buf, 66)
    do append(buf, 233)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link19-mutation check(s) failed."; exit 1; fi
xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: link19 mutation proof ($pass checks: control emits golden=$GOLDEN via the #DE fault path C-FREE; 6 mutations each CAUGHT via a real two-stage seed compile of the mutated backend -- IDTR base / gate offset / gate selector corruptions are boot-caught (triple-fault or wrong byte); #DE-trigger removal, faulting-EIP-check corruption, and the boot-INVISIBLE sentinel flip are caught by the exact-head template gate, which pins straight-line lidt->div->wrapper flow and closes the forge-the-fault-frame bypass$xc)"
exit 0
