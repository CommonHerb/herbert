#!/usr/bin/env bash
# zonday (Link 19) MUTATION proof -- the "prove the fault-catch gate bites" forcing
# function. The link19 dual-substrate gate is only meaningful if a WRONG compiler
# would fail it. We prove that by mutating the compiler SOURCE at a unique anchor
# and re-emitting a green probe through the C-interpreted backend: each mutation
# must be CAUGHT (a wrong/absent byte under QEMU).
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
    echo "SKIP: native-codegen link19 mutation proof (no qemu)"; exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
fail_test() { echo "FAIL: link19-mutation ($1)"; fail=$((fail + 1)); }

# A branching handler: x=6*7=42 (==42 true) -> return 88. Exercises the #DE
# trigger, the IDT vector, the faulting-EIP wrapper, and a real compiled branch.
PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=88

emit_seq=0
# assess(compiler_src) -> "GREEN" (valid image whose boot emits the golden byte) or
# "CAUGHT:<why>". The fault-catch path is judged by the emitted byte on QEMU.
assess() {
    local comp="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-idt\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$comp" < p.herb >/dev/null 2>/dev/null )
    [[ -f "$d/a.out" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$d/a.out" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    # exact-head white-box gate (pins straight-line lidt->div->wrapper; closes the
    # "forge the fault frame" bypass and catches boot-invisible head changes).
    local head; head=$(dd if="$d/a.out" bs=1 skip=4108 count=63 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local hre='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}31d231c9f7f1b0bbe9[0-9a-f]{8}813c243900100075f0$'
    [[ "$head" =~ $hre ]] || { echo "CAUGHT:head"; return; }
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

# control: unmutated compiler must emit the golden byte via the fault path.
ctrl=$(assess "$backend")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated compiler emits golden=$GOLDEN via the #DE fault path"; pass=$((pass+1));
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
    else fail_test "$name: mutant escaped the gate (verdict=$v) -- the gate does NOT bite"; fi
}

# M1: corrupt the IDTR base (the IDT can no longer be located). The #DE finds no
# valid gate -> #GP during delivery -> double -> triple fault -> no byte.
mutate idtr_base \
'    buf = nc_append_le32(buf, idt_vaddr)' \
'    buf = nc_append_le32(buf, idt_vaddr + 4096)'

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
mutate bad_gate_selector \
'    do append(buf, glo % 256)
    do append(buf, glo / 256)
    do append(buf, 8)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 142)' \
'    do append(buf, glo % 256)
    do append(buf, glo / 256)
    do append(buf, 24)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 142)'

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
mutate flip_sentinel \
'    do append(buf, 176)
    do append(buf, 187)
    do append(buf, 233)' \
'    do append(buf, 176)
    do append(buf, 66)
    do append(buf, 233)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link19-mutation check(s) failed."; exit 1; fi
echo "PASS: link19 mutation proof ($pass checks: control passes head+boot gates; 6 mutations each CAUGHT -- IDTR base / gate offset / gate selector corruptions are boot-caught (triple-fault or wrong byte); #DE-trigger removal, faulting-EIP-check corruption, and the boot-INVISIBLE sentinel flip are caught by the exact-head template gate, which pins straight-line lidt->div->wrapper flow and closes the forge-the-fault-frame bypass)"
exit 0
