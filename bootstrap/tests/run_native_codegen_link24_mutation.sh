#!/usr/bin/env bash
# Link 24 (talkert, eighth kernel-arc link) MUTATION proof -- "prove the periodic-timer (async-SURVIVAL)
# gate bites." The link24 dual-substrate gate is only meaningful if a WRONG compiler would fail it. We
# mutate the compiler SOURCE at a unique anchor and re-emit a green probe: each mutation must be CAUGHT
# -- no frame is emitted (timeout / triple-fault), or the exact head / prologue / .ack white-box pin
# rejects the structural change.
#
# The central claim: "the proof byte was emitted only because the kernel SURVIVED and REPEATED the
# asynchronous timer IRQ0 -- acknowledging the PIC (EOI) and `iret`-resuming the mainline N-1 times,
# counting in esi, before the Nth tick ran the compiled handler." Mutations attack exactly that:
#   M1 EOI -> nop          -> PIC never re-delivers IRQ0 -> stuck at tick 1 -> no frame (timeout) + ack pin
#   M2 iret -> hlt         -> mainline never resumes      -> 1 tick        -> no frame (timeout) + ack pin
#   M3 +add esp,4 forge    -> wrongly drops a (nonexistent) error code (silicon triple-fault); the 3 extra
#                            bytes also trip gen1's OWN code-length invariant -> no image (pinned ERR 491)
#   M4 inc esi -> nop      -> counter stuck at 0 -> never reaches N         -> no frame (timeout) + prologue pin
#   M5 count N=3 -> 1      -> emits on tick 1 (same byte) BEHAVIORALLY INVISIBLE -> prologue pin ONLY
#   M5b jb rel32 -> 0      -> jb lands on the body: emits on tick 1, EOI+iret become DEAD CODE; the
#                            golden byte STILL appears -> BEHAVIORALLY INVISIBLE -> jb-TARGET pin ONLY
#                            (the headline forge both verification legs built; .ack-presence does NOT catch it)
#   M6 sti -> nop          -> interrupts never enabled -> no IRQ            -> no frame (timeout) + head pin
#   M7 xor esi,esi -> nop  -> counter uninitialised (substrate-variable)   -> head pin ONLY (honest residual)
# M1/M2 change the .ack tail (caught at the .ack pin); M3 trips gen1's code-length invariant (no-image,
# pinned to ERR 491); M4/M5 change the prologue (prologue pin); M6/M7
# change the head (head pin). assess() catches each at its white-box pin before the QEMU leg runs; the
# underlying SILICON RED for M1/M2/M3/M4/M6 (no 2nd tick -> timeout, or a dropped error code ->
# triple-fault, i.e. no frame) is independently proven on BOTH QEMU and Bochs by the empirical pre-build
# bite-map recorded in run_native_codegen_link24.sh (noeoi / noiret / addesp / noinc / nosti all RED on
# both substrates -- and critically, both emulators FAITHFULLY require the EOI, neither re-delivers IRQ0
# leniently). M5 (the exact count N) and M7 (the counter-zero) are NOT silicon-witnessable (N=1 emits the
# same byte on tick 1; an uninitialised esi is substrate-dependent) and are caught ONLY by the white-box
# prologue / head pins -- the honest analogue of talcott's PIT-divisor pin. The async-SURVIVAL property
# (the kernel cannot reach the byte without genuinely surviving+repeating the interrupt) is proven jointly
# by M1 (no EOI => no byte) and M2 (no iret => no byte): with N=3 the byte requires 2 real EOI+iret cycles.
#
# SOVEREIGNTY (link 16): this proof is C-FREE. It NO LONGER re-emits through the C interpreter. Instead
# it runs each mutation through a genuine TWO-STAGE seed compile (the assay/link18 template): the
# committed C-free gen-1 seed compiles the (mutated) backend into a native gen-1' compiler ELF, and THAT
# compiler emits the probe. This is strictly MORE faithful than the prior C path: it runs the ACTUAL
# mutated compiler and checks the gate catches ITS output, so the proof's meaning ("a wrong compiler is
# caught") survives C's deletion intact -- including any "no-image" mutation, where the mutated
# compiler's OWN layout invariant refuses to emit, which only a real compile can reproduce. A retireable
# cross-check -- DEFAULT-ON when C is present, opt-OUT via LINK24_MUTATION_NO_C=1 -- also re-emits each
# mutation via the C interpreter and asserts the native two-stage image is BYTE-IDENTICAL to the C image
# (substrate faithfulness, while C still exists); it retires WITH C at the switchover.
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
    echo "SKIP: native-codegen link24 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: native-codegen link24 mutation proof (no qemu)"; exit 0
fi

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${LINK24_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

pass=0; fail=0
fail_test() { echo "FAIL: link24-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=88    # the async handler runs the compiled body -> returns 88 -> frame de 58 ad
# the exact 99-byte head (only gdtr/esp/idtr le32 vary): GDT-install + PIC remap + PIT program +
# xor esi,esi (31 F6, the tick-counter zero) + sti + hlt-loop
HEAD='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe64031f6fbf4ebfd'

emit_seq=0
# emit_via(compiler, outdir): the given native compiler ELF emits the PROBE. Sets
# $EMIT_IMG to the emitted image path, or "" if the compiler refused to emit.
EMIT_IMG=""
emit_via() {
    local compiler="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-tick\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$compiler" < p.herb >emit.out 2>&1 )
    if [[ -f "$d/a.out" ]]; then EMIT_IMG="$d/a.out"; else EMIT_IMG=""; fi
}
# assess(compiler) -> "GREEN" or "CAUGHT:<why>". The given native compiler ELF emits
# the probe; the emitted image is run through the existing white-box + QEMU boot gates.
assess() {
    local compiler="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"
    emit_via "$compiler" "$d"
    [[ -n "$EMIT_IMG" ]] && cp "$EMIT_IMG" "$compiler.graded" 2>/dev/null
    [[ -z "$EMIT_IMG" ]] && cp "$d/emit.out" "$compiler.emiterr" 2>/dev/null
    [[ -n "$EMIT_IMG" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$EMIT_IMG" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$EMIT_IMG" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "${chx:0:198}" =~ $HEAD ]] || { echo "CAUGHT:head"; return; }
    echo "$chx" | grep -qE '4683fe030f82' || { echo "CAUGHT:prologue"; return; }
    echo "$chx" | grep -q '6f000800008e10000701' || { echo "CAUGHT:gate"; return; }
    echo "$chx" | grep -q '92cf001700' || { echo "CAUGHT:gdt"; return; }
    [[ "$(echo "$chx" | grep -oE '66bae900' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:emit"; return; }
    [[ "$(echo "$chx" | grep -oE 'b020e620cf' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:ack"; return; }
    # the prologue jb must target the .ack EOI+iret (reachability -- the jb-retarget dead-code forge)
    local rel_hex="${chx:210:8}"
    local jb_rel=$(( 16#${rel_hex:6:2}${rel_hex:4:2}${rel_hex:2:2}${rel_hex:0:2} ))
    local ack_pos; ack_pos=$(echo "$chx" | grep -bo 'b020e620cf' | head -1 | cut -d: -f1)
    [[ $(( 109 + jb_rel )) -eq $(( ack_pos / 2 )) ]] || { echo "CAUGHT:jbtarget"; return; }
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
    printf -- '-- emit: multiboot32-tick\n%s\n' "$PROBE" > "$d/p.herb"
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
        fail_test "$name: mutant escaped the gate (verdict=$v) -- the gate does NOT bite"; return
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

# M1: EOI -> nop. Neuter the master-PIC EOI (out 0x20,0x20 -> the `out` opcode E6 becomes nop) in the
# .ack tail. Without the EOI the PIC's in-service bit for IRQ0 stays set, so it NEVER re-delivers IRQ0:
# esi sticks at 1, never reaches N=3 -> NO frame (QEMU timeout). Caught by the .ack pin (b020e620cf ->
# b0209020cf). Proves the EOI is load-bearing (the silicon RED -- no 2nd tick -> timeout -- is the
# `noeoi` case of the empirical pre-build bite-map, RED on BOTH QEMU and Bochs).
mutate eoi_to_nop \
'    do append(cbuf, 176)
    do append(cbuf, 32)
    do append(cbuf, 230)
    do append(cbuf, 32)
    do append(cbuf, 207)' \
'    do append(cbuf, 176)
    do append(cbuf, 32)
    do append(cbuf, 144)
    do append(cbuf, 32)
    do append(cbuf, 207)'

# M2: iret -> hlt. Replace the async-resume iret (CF) with hlt (F4): the handler EOIs then halts forever
# (IF=0 in the interrupt-gate handler), so the mainline NEVER resumes, no 2nd tick fires -> NO frame
# (timeout). Caught by the .ack pin (b020e620cf -> b020e620f4). Proves the iret-RESUME is load-bearing
# (silicon RED -- 1 tick then hang -- is the `noiret` case of the pre-build bite-map).
mutate iret_to_hlt \
'    do append(cbuf, 176)
    do append(cbuf, 32)
    do append(cbuf, 230)
    do append(cbuf, 32)
    do append(cbuf, 207)' \
'    do append(cbuf, 176)
    do append(cbuf, 32)
    do append(cbuf, 230)
    do append(cbuf, 32)
    do append(cbuf, 244)'

# M3: insert a wrong `add esp,4` (83 C4 04) before the iret -- the forge that wrongly drops an error code.
# An IRQ interrupt-gate frame has NO error code (unlike scottie's #PF), so `add esp,4` pops one dword too
# many: iret then reads CS/EFLAGS from the wrong slots -> bogus return -> triple-fault (no frame). The
# silicon RED -- triple-fault, QEMU exit 0 -- is the `addesp` case of the pre-build bite-map. But the
# three extra bytes (83 C4 04) ALSO inflate the .ack tail past the size the layout pass reserved, so the
# mutated gen1' compiler trips its OWN code-length invariant and REFUSES to emit (diagnostic ERR 491).
# This is the assay-M4-class case that ONLY a real two-stage compile reproduces -- a binary patch of a
# good image could never produce it. The no-image pin asserts that exact reject so it stays load-bearing.
mutate add_esp_forge \
'    do append(cbuf, 176)
    do append(cbuf, 32)
    do append(cbuf, 230)
    do append(cbuf, 32)
    do append(cbuf, 207)' \
'    do append(cbuf, 176)
    do append(cbuf, 32)
    do append(cbuf, 230)
    do append(cbuf, 32)
    do append(cbuf, 131)
    do append(cbuf, 196)
    do append(cbuf, 4)
    do append(cbuf, 207)' \
'ERR 491'

# M4: inc esi -> nop. Remove the per-tick counter increment (46 -> 90). esi stays 0 forever, never reaches
# N=3, so the handler always takes the .ack path -> NO frame (timeout). Caught by the prologue pin
# (4683fe030f82 -> 9083fe030f82, the 46 is gone). Proves COUNTING is load-bearing (silicon RED -- never
# emits -> timeout -- is the `noinc` case of the pre-build bite-map).
mutate inc_to_nop \
'    do append(cbuf, 70)
    do append(cbuf, 131)
    do append(cbuf, 254)
    do append(cbuf, 3)' \
'    do append(cbuf, 144)
    do append(cbuf, 131)
    do append(cbuf, 254)
    do append(cbuf, 3)'

# M5: count N=3 -> N=1 (the cmp immediate 03 -> 01). The handler then emits on the FIRST tick -- no
# survive+repeat, reducing to talcott's exit-on-first. BEHAVIORALLY INVISIBLE: the frame still appears
# with the SAME byte (88), so silicon does NOT catch it (the `clobber`/early-count cases of the pre-build
# confirm only count!=enough -> no byte; an early count -> the same byte). Caught ONLY by the prologue
# white-box pin (4683fe030f82 -> 4683fe010f82). This is the honest reason the exact count is white-box-
# pinned -- N is not silicon-witnessable, the analogue of talcott's PIT-divisor pin.
mutate count_n_to_1 \
'    do append(cbuf, 70)
    do append(cbuf, 131)
    do append(cbuf, 254)
    do append(cbuf, 3)' \
'    do append(cbuf, 70)
    do append(cbuf, 131)
    do append(cbuf, 254)
    do append(cbuf, 1)'

# M5b: jb-retarget forge (the completeness-critic + cross-model Codex catch). Set the count-branch jb
# rel32 to 0 so `jb` lands on the BODY start instead of .ack: on the FIRST tick (esi=1<3) it jumps
# straight into the body, emits the golden byte, and exits -- leaving the EOI+iret as unreachable DEAD
# CODE. BEHAVIORALLY INVISIBLE on silicon (the genuine golden byte still appears on tick 1, NO survive/
# repeat, NO EOI, NO iret) -- so QEMU/Bochs do NOT catch it; the .ack PRESENCE pin (b020e620cf still
# present, just dead) does NOT catch it either. Caught ONLY by the jb-TARGET == .ack reachability pin.
# This is the headline forge both verification legs built; it must go RED.
mutate jb_retarget \
'    let jb_rel = epi + 58' \
'    let jb_rel = 0'

# M6: sti -> nop (251 -> 144) in the tick head's xor-esi; sti; hlt; jmp loop. Interrupts are never
# enabled -> IRQ0 never delivered -> mainline halts forever -> NO frame (timeout). Caught by the exact-
# head pin (...31f6 fb... -> ...31f6 90...). Proves sti -- the async ENABLER -- is load-bearing for the
# tick head too (silicon RED -- no IRQ -> timeout -- is the `nosti` case of the pre-build bite-map).
mutate sti_to_nop \
'    do append(hbuf, 49)
    do append(hbuf, 246)
    do append(hbuf, 251)
    do append(hbuf, 244)
    do append(hbuf, 235)
    do append(hbuf, 253)' \
'    do append(hbuf, 49)
    do append(hbuf, 246)
    do append(hbuf, 144)
    do append(hbuf, 244)
    do append(hbuf, 235)
    do append(hbuf, 253)'

# M7: xor esi,esi -> two nops (31 F6 -> 90 90). The tick counter is no longer zeroed before sti, so esi
# holds whatever Multiboot left in it (undefined per the Multiboot spec: only eax/ebx are defined). The
# count behaviour becomes substrate-dependent -- NOT a clean RED -- so this is caught ONLY by the exact-
# head white-box pin (...e640 31f6 fb... -> ...e640 9090 fb...). Proves the counter-zero is pinned (a
# silicon-variable structural change cannot slip past).
mutate xor_esi_to_nop \
'    do append(hbuf, 49)
    do append(hbuf, 246)
    do append(hbuf, 251)
    do append(hbuf, 244)
    do append(hbuf, 235)
    do append(hbuf, 253)' \
'    do append(hbuf, 144)
    do append(hbuf, 144)
    do append(hbuf, 251)
    do append(hbuf, 244)
    do append(hbuf, 235)
    do append(hbuf, 253)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link24-mutation check(s) failed."; exit 1; fi
xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: link24 mutation proof ($pass checks: control emits golden=$GOLDEN via the async timer IRQ0 -> compiled handler C-FREE via the committed gen-1 seed; 8 mutations each CAUGHT via a real two-stage seed compile of the mutated backend -- EOI->nop and iret->hlt change the .ack tail and are caught by the .ack pin; the wrong add-esp,4 forge (which on silicon would wrongly drop a nonexistent error code -> triple-fault, the addesp case of the QEMU+Bochs pre-build bite-map) ALSO inflates the .ack tail past the layout-reserved size, so the mutated gen1' compiler trips its OWN code-length invariant and refuses to emit -> no-image, pinned to its exact ERR 491 reject (the assay-M4-class case only a real two-stage compile reproduces); the silicon RED for EOI/iret -- no 2nd tick -> timeout -- is proven on QEMU+Bochs by the pre-build bite-map (noeoi/noiret RED on BOTH substrates); inc-esi->nop is caught by the prologue pin (counter stuck -> timeout, the noinc pre-build case); count N=3->1 is BEHAVIORALLY INVISIBLE (the same byte still appears on tick 1) and caught ONLY by the prologue white-box pin -- the exact count is not silicon-witnessable, like talcott's PIT divisor; the jb-retarget forge (jb rel32 -> body start: emits the golden byte on tick 1, EOI+iret become unreachable dead code) is ALSO BEHAVIORALLY INVISIBLE and caught ONLY by the jb-TARGET==.ack reachability pin (the headline forge a same-model completeness critic + cross-model Codex both built); sti->nop is caught by the head pin (no IRQ -> timeout); xor-esi->nop is substrate-variable and caught ONLY by the head pin -- so the EOI, the iret-resume, the no-error-code-drop, the per-tick count, the exact N, sti, and the counter-zero are all proven load-bearing or white-box-pinned, and the async-SURVIVAL property holds: drop the EOI or the iret and the kernel cannot survive past tick 1$xc)"
exit 0
