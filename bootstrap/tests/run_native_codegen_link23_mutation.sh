#!/usr/bin/env bash
# Link 23 (seventh kernel-arc link) MUTATION proof -- "prove the asynchronous-timer-IRQ gate bites."
# The link23 dual-substrate gate is only meaningful if a WRONG compiler would fail it. We mutate the
# compiler SOURCE at a unique anchor and re-emit a green probe: each mutation must be CAUGHT -- no async
# IRQ is delivered (no frame / timeout), the IRQ vectors to a triple-fault (no frame), or the exact head /
# gate white-box pin rejects the structural change.
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
# SOVEREIGNTY (link 16): this proof is C-FREE. It NO LONGER re-emits through the C
# interpreter. Instead it runs each mutation through a genuine TWO-STAGE seed
# compile (the assay/link18 template): the committed C-free gen-1 seed compiles the
# (mutated) backend into a native gen-1' compiler ELF, and THAT compiler emits the
# probe. This is strictly MORE faithful than the prior C path: it runs the ACTUAL
# mutated compiler and checks the gate catches ITS output, so the proof's meaning
# ("a wrong compiler is caught") survives C's deletion intact. A retireable
# cross-check -- DEFAULT-ON when C is present, opt-OUT via LINK23_MUTATION_NO_C=1 --
# also re-emits each mutation via the C interpreter and asserts the native two-stage
# image is BYTE-IDENTICAL to the C image (substrate faithfulness, while C still
# exists); it retires WITH C at the switchover.
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

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${LINK23_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

pass=0; fail=0
fail_test() { echo "FAIL: link23-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=88    # the async handler runs the compiled body -> returns 88 -> frame de 58 ad
# the exact 97-byte head (only gdtr/esp/idtr le32 vary): GDT-install + PIC remap + PIT program + sti + hlt-loop
HEAD='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe640fbf4ebfd'

emit_seq=0
# emit_via(compiler, outdir): the given native compiler ELF emits the PROBE. Sets
# $EMIT_IMG to the emitted image path, or "" if the compiler refused to emit.
EMIT_IMG=""
emit_via() {
    local compiler="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-timer\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$compiler" < p.herb >emit.out 2>&1 )
    if [[ -f "$d/a.out" ]]; then EMIT_IMG="$d/a.out"; else EMIT_IMG=""; fi
}
# assess(compiler) -> "GREEN" or "CAUGHT:<why>". The given native compiler ELF emits
# the probe; the async-timer path is judged by the emitted byte on QEMU + the
# exact-head / gate / gdt / emit white-box pins.
assess() {
    local compiler="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"
    emit_via "$compiler" "$d"
    [[ -n "$EMIT_IMG" ]] && cp "$EMIT_IMG" "$compiler.graded" 2>/dev/null
    [[ -z "$EMIT_IMG" ]] && cp "$d/emit.out" "$compiler.emiterr" 2>/dev/null
    [[ -n "$EMIT_IMG" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$EMIT_IMG" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$EMIT_IMG" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "${chx:0:194}" =~ $HEAD ]] || { echo "CAUGHT:head"; return; }
    echo "$chx" | grep -q '6d000800008e10000701' || { echo "CAUGHT:gate"; return; }
    echo "$chx" | grep -q '92cf001700' || { echo "CAUGHT:gdt"; return; }
    [[ "$(echo "$chx" | grep -oE '66bae900' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:emit"; return; }
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
    printf -- '-- emit: multiboot32-timer\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$src" < p.herb >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then C_IMG="$d/a.out"; else C_IMG=""; fi
}

# control: the unmutated compiler is the SEED itself (the gen-1 fixpoint); it must
# emit the golden byte via the async timer IRQ0 -> compiled handler C-FREE.
ctrl=$(assess "$SEED")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated seed compiler emits golden=$GOLDEN via the async timer IRQ0 -> compiled handler C-free"; pass=$((pass+1));
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
xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: link23 mutation proof ($pass checks: control passes head+gate+gdt+emit+boot gates C-FREE; 7 mutations each CAUGHT via a real two-stage seed compile of the mutated backend -- sti->nop, IMR-mask, and a wrong PIC vector base change the exact-head bytes and are caught by the head pin (their underlying silicon RED -- no IRQ -> timeout, or IRQ0 at an unhandled vector -> triple-fault, i.e. no frame -- is proven on QEMU by the empirical pre-build bite-map in run_native_codegen_link23.sh); a misdirected vec-0x20 gate and a shrunk IDTR limit are caught by the gate->handler / IDTR-limit pin; a PIT mode change and a head hlt->nop are BEHAVIORALLY INVISIBLE on the emulators (firmware keeps the PIT ticking; a spin loop is interruptible) and caught ONLY by the exact-head white-box pin -- so the PIC remap, the IRQ0 unmask, the vec-0x20 gate binding, the IDTR limit, and the full async-setup head are all proven load-bearing, and the async-only property holds: no sti => no byte$xc)"
exit 0
