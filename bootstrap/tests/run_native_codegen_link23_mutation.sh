#!/usr/bin/env bash
# Link 23 (seventh kernel-arc link) MUTATION proof -- "prove the asynchronous-timer-IRQ gate bites."
# The link23 dual-substrate gate is only meaningful if a WRONG compiler would fail it. We mutate the
# compiler SOURCE at a unique anchor and re-emit a green probe through the C-interpreted backend: each
# mutation must be CAUGHT -- no async IRQ is delivered (no frame / timeout), the IRQ vectors to a
# triple-fault (no frame), or the exact head / gate white-box pin rejects the structural change.
#
# The central claim: "the proof byte was emitted only because a genuine ASYNCHRONOUS timer IRQ0 was
# delivered through a correctly-remapped PIC to the IDT vec-0x20 gate and ran the compiled handler."
# Mutations attack exactly that:
#   M1 sti -> nop          -> interrupts never enabled -> no IRQ        -> no frame (BOOT timeout) + head pin
#   M2 IMR unmask -> mask  -> PIC blocks IRQ0           -> no IRQ        -> no frame (BOOT timeout) + head pin
#   M3 PIC vec base wrong  -> IRQ0 lands at vec 0x28    -> no gate       -> triple-fault (BOOT) + head pin
#   M4 gate misdirected    -> vec 0x20 points mid-handler              -> wrong/crash (BOOT) + gate pin
#   M5 IDTR limit shrunk   -> vec 0x20 out of IDT range -> triple-fault -> gate pin (limit 0x107->0x007)
#   M6 PIT mode 2 -> 0     -> behaviorally invisible (still fires once) -> head pin ONLY (honest residual)
#   M7 head hlt -> nop     -> behaviorally invisible (spin still works) -> head pin ONLY (honest residual)
# M1/M2/M3 change bytes INSIDE the exact-head template, so assess() catches them at the head pin before
# the QEMU leg runs; their underlying SILICON RED (no IRQ delivered -> timeout, or IRQ0 at an unhandled
# vector -> triple-fault, i.e. no frame on the emulator) is independently proven on QEMU by the empirical
# pre-build bite-map recorded in run_native_codegen_link23.sh. M4/M5 are caught by the gate->handler /
# IDTR-limit pin; M6/M7 are behaviorally INVISIBLE on the emulators (the PIT keeps ticking from firmware; a spin loop
# is interruptible too) and are caught ONLY by the exact-head white-box pin -- the honest reason that pin
# exists. The async-only property (no synchronous path to the byte) is proven jointly by M1 (no sti => no
# byte) and the exact-head pin (the mainline ends sti;hlt;jmp-self, with the single 0xE9 emit in the
# handler reached only via the gate).
#
# QEMU-only, gated behind KERNEL_CODEGEN_MUTATION=1 (or REQUIRE_EMU=1). Each anchor is asserted to occur
# EXACTLY ONCE, so a drifted anchor fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then
    echo "SKIP: native-codegen link23 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: native-codegen link23 mutation proof (no qemu)"; exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
fail_test() { echo "FAIL: link23-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=88    # the async handler runs the compiled body -> returns 88 -> frame de 58 ad
# the exact 97-byte head (only gdtr/esp/idtr le32 vary): GDT-install + PIC remap + PIT program + sti + hlt-loop
HEAD='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe640fbf4ebfd'

emit_seq=0
# assess(compiler_src) -> "GREEN" or "CAUGHT:<why>"
assess() {
    local comp="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-timer\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$comp" < p.herb >/dev/null 2>/dev/null )
    [[ -f "$d/a.out" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$d/a.out" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$d/a.out" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "${chx:0:194}" =~ $HEAD ]] || { echo "CAUGHT:head"; return; }
    echo "$chx" | grep -q '6d000800008e10000701' || { echo "CAUGHT:gate"; return; }
    echo "$chx" | grep -q '92cf001700' || { echo "CAUGHT:gdt"; return; }
    [[ "$(echo "$chx" | grep -oE '66bae900' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:emit"; return; }
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

ctrl=$(assess "$backend")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated compiler emits golden=$GOLDEN via the async timer IRQ0 -> compiled handler"; pass=$((pass+1));
else echo "FAIL control: unmutated compiler did not pass cleanly: $ctrl"; fail=$((fail+1)); fi

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

# M1: sti -> nop (251 -> 144) in the head's sti;hlt;jmp-self loop. Interrupts are never enabled, so
# IRQ0 is never delivered and the mainline halts forever -> no frame (QEMU timeout). Also caught by the
# exact-head pin (fb -> 90). Proves sti -- the async ENABLER -- is load-bearing (and, with the head pin,
# that there is no synchronous path to the byte).
mutate sti_to_nop \
'    do append(buf, 251)
    do append(buf, 244)
    do append(buf, 235)
    do append(buf, 253)' \
'    do append(buf, 144)
    do append(buf, 244)
    do append(buf, 235)
    do append(buf, 253)'

# M2: PIC master IMR 0xFE -> 0xFF (mask IRQ0 instead of unmask). The PIC blocks the timer IRQ -> no
# delivery -> no frame (timeout). Caught by the exact-head pin (b0fee621 -> b0ffe621). Proves the
# IRQ0-unmask is load-bearing.
mutate imr_mask_irq0 \
'    buf = nc32_timer_out_imm(buf, 254, 33)' \
'    buf = nc32_timer_out_imm(buf, 255, 33)'

# M3: PIC ICW2 master vector base 0x20 -> 0x28. IRQ0 now lands at vector 0x28, which has a not-present
# IDT gate -> triple-fault (no frame). Caught by the exact-head pin (b020e621 -> b028e621). Proves the
# remap (IRQ0 -> vec 0x20) is load-bearing.
mutate pic_vector_base \
'    buf = nc32_timer_out_imm(buf, 32, 33)' \
'    buf = nc32_timer_out_imm(buf, 40, 33)'

# M4: misdirect the IDT vec-0x20 gate (gate_vaddr -> +16), so the gate points 16 bytes PAST the handler
# entry. On IRQ0 the CPU vectors into the middle of the handler -> wrong execution / crash (no clean
# frame). Caught by the gate pin (the gate no longer reads 6d00...). Proves the gate -> handler binding
# is load-bearing.
mutate gate_misdirected \
'    let gate_vaddr = 1048588 + head_len' \
'    let gate_vaddr = 1048588 + head_len + 16'

# M5: shrink the IDTR limit 0x0107 -> 0x0007 (only vector 0 fits), so vector 0x20 is out of IDT range
# -> triple-fault on IRQ0 (no frame). Caught by the gate pin (the gate is immediately followed by the
# IDTR limit 0701; with 0700 the pin 6d000800008e10000701 fails). Proves the IDTR limit is load-bearing.
mutate idtr_limit \
'    do append(buf, 7)
    do append(buf, 1)
    buf = nc_append_le32(buf, idt_vaddr)' \
'    do append(buf, 7)
    do append(buf, 0)
    buf = nc_append_le32(buf, idt_vaddr)'

# M6: PIT command 0x34 -> 0x30 (mode 2 rate-generator -> mode 0 one-shot). BEHAVIORALLY INVISIBLE on the
# emulators -- mode 0 still fires IRQ0 once (and firmware leaves the PIT ticking regardless: the empirical
# pre-build's `nopit` case showed the frame still appears) -- so silicon does NOT catch it. Caught ONLY by
# the exact-head white-box pin (b034e643 -> b030e643). This is the honest reason the head pin pins the PIT
# program: the divisor/mode are not silicon-mutable.
mutate pit_mode \
'    buf = nc32_timer_out_imm(buf, 52, 67)' \
'    buf = nc32_timer_out_imm(buf, 48, 67)'

# M7: head hlt -> nop (244 -> 144) in the sti;hlt;jmp-self loop. BEHAVIORALLY INVISIBLE -- `sti; nop;
# jmp $-1` is an interruptible spin loop, so IRQ0 still fires and the frame still appears (Codex's
# "hlt vs spin loop may still pass"). Caught ONLY by the exact-head pin (fbf4ebfd -> fb90ebfd). Proves
# the hlt-loop bytes are pinned (a silicon-invisible structural change cannot slip past).
mutate head_hlt_to_nop \
'    do append(buf, 251)
    do append(buf, 244)
    do append(buf, 235)
    do append(buf, 253)' \
'    do append(buf, 251)
    do append(buf, 144)
    do append(buf, 235)
    do append(buf, 253)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link23-mutation check(s) failed."; exit 1; fi
echo "PASS: link23 mutation proof ($pass checks: control passes head+gate+gdt+emit+boot gates; 7 mutations each CAUGHT -- sti->nop, IMR-mask, and a wrong PIC vector base change the exact-head bytes and are caught by the head pin (their underlying silicon RED -- no IRQ -> timeout, or IRQ0 at an unhandled vector -> triple-fault, i.e. no frame -- is proven on QEMU by the empirical pre-build bite-map in run_native_codegen_link23.sh); a misdirected vec-0x20 gate and a shrunk IDTR limit are caught by the gate->handler / IDTR-limit pin; a PIT mode change and a head hlt->nop are BEHAVIORALLY INVISIBLE on the emulators (firmware keeps the PIT ticking; a spin loop is interruptible) and caught ONLY by the exact-head white-box pin -- so the PIC remap, the IRQ0 unmask, the vec-0x20 gate binding, the IDTR limit, and the full async-setup head are all proven load-bearing, and the async-only property holds: no sti => no byte)"
exit 0
