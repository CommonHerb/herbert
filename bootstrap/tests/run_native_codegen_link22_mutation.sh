#!/usr/bin/env bash
# Link 22 (sixth kernel-arc link) MUTATION proof -- "prove the iret-resume / demand-paging gate
# bites." The link22 dual-substrate gate is only meaningful if a WRONG compiler would fail it. We
# mutate the compiler SOURCE at a unique anchor and re-emit a green probe: each mutation must be
# CAUGHT -- the resumed load re-faults / triple-faults (no byte), or reads the wrong frame (wrong
# byte), or the exact handler/hole white-box pin rejects it.
#
# The central claim: "the proof byte was emitted only because the #PF handler genuinely MAPPED the
# faulting page at runtime, flushed the TLB, dropped the error code, and `iret`-RESUMED the faulting
# instruction, which then read the seeded frame." Mutations attack exactly that:
#   M1 not-present PTE   -> resumed load re-faults forever       -> triple-fault / no frame (BOOT)
#   M2 wrong frame       -> resume reads the wrong page          -> wrong byte (BOOT)
#   M3 wrong slot shift  -> store lands at the wrong PTE slot     -> page unmapped (handler pin)
#   M4 no TLB flush      -> stale not-present walk persists       -> handler pin (silicon: re-fault)
#   M5 no iret (hlt)     -> the faulting instruction never resumes-> handler pin (silicon: no frame)
#   M6 no add esp,4      -> iret loads the error code as EIP       -> handler pin (silicon: 3-fault)
#   M7 build hole filled -> 0x300000 mapped at build, no #PF       -> hole grep + wrong byte (BOOT)
# M1/M2 genuinely exercise the BOOT/silicon leg; M3-M6 are caught by the exact handler pin (and the
# silicon triple-fault for each is proven on BOTH substrates by the empirical pre-build recorded in
# run_native_codegen_link22.sh); M7 by the build-time-hole grep.
#
# SOVEREIGNTY (link 16): this proof is C-FREE. It NO LONGER re-emits through the C interpreter.
# Instead it runs each mutation through a genuine TWO-STAGE seed compile (the assay/link18
# template): the committed C-free gen-1 seed compiles the (mutated) backend into a native gen-1'
# compiler ELF, and THAT compiler emits the probe. This is strictly MORE faithful than the prior C
# path: it runs the ACTUAL mutated compiler and checks the gate catches ITS output, so the proof's
# meaning ("a wrong compiler is caught") survives C's deletion intact. A retireable cross-check --
# DEFAULT-ON when C is present, opt-OUT via LINK22_MUTATION_NO_C=1 -- also re-emits each mutation via
# the C interpreter and asserts the native two-stage image is BYTE-IDENTICAL to the C image
# (substrate faithfulness, while C still exists); it retires WITH C at the switchover.
#
# QEMU-only, gated behind KERNEL_CODEGEN_MUTATION=1 (or REQUIRE_EMU=1). Each anchor is asserted to
# occur EXACTLY ONCE, so a drifted anchor fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then
    echo "SKIP: native-codegen link22 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: native-codegen link22 mutation proof (no qemu)"; exit 0
fi

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${LINK22_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

pass=0; fail=0
fail_test() { echo "FAIL: link22-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=$((88 ^ 0x5A))    # 2 -- the resumed load reads seed[88] = 88 ^ 0x5A
# the exact 73-byte paging-enable prologue (only gdtr/esp/idtr/pd le32 vary)
PRE='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}0f20e0254fffffff0f22e0b8[0-9a-f]{8}0f22d80f20c00d000000800f22c0eb00'
# the exact #PF iret-resume handler (only pt_base/frame_pte le32 vary) -- the NEW capability;
# the trailing 0000000000000000 anchors the iret to the GDT null descriptor right after it.
HRE='500f20d0c1e80a05[0-9a-f]{8}c700[0-9a-f]{8}0f20d80f22d85883c404cf0000000000000000'

emit_seq=0
# emit_via(compiler, outdir): the given native compiler ELF emits the PROBE. Sets $EMIT_IMG to the
# emitted image path, or "" if the compiler refused to emit.
EMIT_IMG=""
emit_via() {
    local compiler="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-demand\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$compiler" < p.herb >emit.out 2>&1 )
    if [[ -f "$d/a.out" ]]; then EMIT_IMG="$d/a.out"; else EMIT_IMG=""; fi
}
# assess(compiler) -> "GREEN" or "CAUGHT:<why>". The given native compiler ELF emits the probe; the
# emitted image is run through the exact white-box pins + the QEMU iret-resume boot byte.
assess() {
    local compiler="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"
    emit_via "$compiler" "$d"
    [[ -n "$EMIT_IMG" ]] && cp "$EMIT_IMG" "$compiler.graded" 2>/dev/null
    [[ -z "$EMIT_IMG" ]] && cp "$d/emit.out" "$compiler.emiterr" 2>/dev/null
    [[ -n "$EMIT_IMG" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$EMIT_IMG" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$EMIT_IMG" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "${chx:0:146}" =~ $PRE ]] || { echo "CAUGHT:prologue"; return; }
    echo "$chx" | grep -q '0fb6c08a8000003000' || { echo "CAUGHT:glue"; return; }
    [[ "$chx" =~ $HRE ]] || { echo "CAUGHT:handler"; return; }
    # the IDT vector-14 gate must point at the pinned handler (sel 0x08 / attr 0x8E) -- derived
    # from where the handler bytes actually are; a misdirected or not-present gate fails here.
    local hpos; hpos=$(echo "$chx" | grep -bo '500f20d0c1e80a05' | head -1 | cut -d: -f1)
    if [[ -n "$hpos" ]]; then
        local hv=$(( 1048588 + hpos/2 )) glo ghi gate
        glo=$(( hv & 65535 )); ghi=$(( (hv>>16) & 65535 ))
        gate=$(printf '%02x%02x0800008e%02x%02x' $((glo&255)) $((glo>>8)) $((ghi&255)) $((ghi>>8)))
        echo "$chx" | grep -q "${gate}7700" || { echo "CAUGHT:gate"; return; }
    fi
    echo "$chx" | grep -q '03f02f000000000003103000' || { echo "CAUGHT:hole"; return; }
    echo "$chx" | grep -q '5a5b58595e5f5c5d' || { echo "CAUGHT:seed"; return; }
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

# seed_compile(backend_src, outpath): the C-free seed compiles a (mutated) backend into a native
# gen-1' compiler ELF. Echoes "" if the backend did not compile.
seed_compile() {
    local src="$1" out="$2" d; d="$(mktemp -d "$tmp/sc.XXXX")"
    ( cd "$d" && "$SEED" < "$src" >/dev/null 2>/dev/null )
    # require a real ELF (magic 7f454c46), not merely a present a.out -- a truncated or
    # partial stage-1 output must not be accepted as a compiler (Codex link16 review).
    if [[ -f "$d/a.out" && "$(head -c4 "$d/a.out" | xxd -p | tr -d '\n')" == "7f454c46" ]]; then
        cp "$d/a.out" "$out"; chmod +x "$out"; echo "$out"; else echo ""; fi
}

# c_emit(backend_src, outdir): the RETIREABLE C path -- the C interpreter runs the (mutated)
# backend to emit the probe. Sets $C_IMG (or "" if no image).
C_IMG=""
c_emit() {
    local src="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-demand\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$src" < p.herb >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then C_IMG="$d/a.out"; else C_IMG=""; fi
}

# control: the unmutated compiler is the SEED itself (the gen-1 fixpoint); it must emit the golden
# byte via the iret-resumed load of the runtime-mapped frame C-FREE.
ctrl=$(assess "$SEED")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated seed compiler emits golden=$GOLDEN via the iret-resumed load of the runtime-mapped frame C-free"; pass=$((pass+1));
else echo "FAIL control: unmutated seed compiler did not pass cleanly: $ctrl"; fail=$((fail+1)); fi
[[ "$XCHECK" == "1" ]] && echo "  (retireable C cross-check ON: each mutation's native two-stage image is asserted byte-identical to the C image)"

# mutate(name, old, new [, expect_no_image_diag]): old must occur exactly once; the mutant must be
# CAUGHT. The C-free seed compiles the mutated backend -> gen1' compiler, which emits the probe
# (two-stage). Optionally cross-checked byte-identical to the C image. If expect_no_image_diag is
# given, a "no-image" verdict is only a genuine catch when the mutated compiler emits THAT reject
# diagnostic (its own layout invariant), NOT any incidental empty image -- closing the no-image
# catch-all.
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
    # no-image pin: a "no-image" catch must be the mutated compiler's OWN reject diagnostic, not an
    # incidental empty image.
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
    # retireable faithfulness: the native two-stage image == the C image, byte-for-byte (or both
    # produce no image). Confirms the C->seed substrate swap is loss-free.
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

# M1: NOT-PRESENT PTE (frame_pte present bit cleared: frame_vaddr+3 -> frame_vaddr+2). The store
# lands, but the MMU sees not-present on the resumed access -> #PF again -> the handler re-maps the
# same not-present PTE -> re-fault loop / triple-fault (no clean frame). Exercises the BOOT leg
# (the handler regex still matches -- frame_pte is wildcarded). Proves the present bit is load-bearing.
mutate pte_not_present \
'    let frame_pte = frame_vaddr + 3' \
'    let frame_pte = frame_vaddr + 2'

# M2: map to the WRONG FRAME (frame_vaddr+3 -> frame_vaddr+4099 = the next present page). The resume
# succeeds but reads a different (zeroed) page -> WRONG byte. Exercises the BOOT leg. Proves the
# store TARGET frame is load-bearing IN the proof byte (unlike liberi, here the frame IS the byte).
mutate wrong_frame \
'    let frame_pte = frame_vaddr + 3' \
'    let frame_pte = frame_vaddr + 4099'

# M3: corrupt the runtime SLOT computation in the handler (shr eax,10 -> shr eax,11), so the store
# lands at the wrong PTE slot; 0x300000 stays unmapped -> resumed access #PFs -> triple-fault.
# Caught by the exact handler pin (c1e80a -> c1e80b). Proves the cr2-computed slot is load-bearing.
mutate wrong_shift \
'    do append(buf, 208)
    do append(buf, 193)
    do append(buf, 232)
    do append(buf, 10)' \
'    do append(buf, 208)
    do append(buf, 193)
    do append(buf, 232)
    do append(buf, 11)'

# M4: remove the TLB FLUSH (the 6-byte mov eax,cr3; mov cr3,eax -> 6 NOPs). On both QEMU and Bochs
# the stale not-present walk persists -> the resumed access re-faults -> triple-fault (empirically
# RED on both substrates, recorded in link22). Caught by the handler pin (the flush bytes
# 0f20d80f22d8 are pinned). Proves the TLB flush is load-bearing (the #PF does NOT auto-invalidate).
mutate no_flush \
'    do append(buf, 15)
    do append(buf, 32)
    do append(buf, 216)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 216)' \
'    do append(buf, 144)
    do append(buf, 144)
    do append(buf, 144)
    do append(buf, 144)
    do append(buf, 144)
    do append(buf, 144)'

# M5: remove the iret (the resume: iret 0xCF -> hlt 0xF4). The handler halts; the faulting load
# never re-executes -> no byte. Caught by the handler pin (the tail 83c404cf -> 83c404f4). Proves
# THE NEW CAPABILITY -- the iret that resumes the faulting instruction -- is load-bearing. (A handler
# that EMITS the byte instead of resuming is likewise excluded: it would not match the exact pin.)
mutate no_iret \
'    do append(buf, 196)
    do append(buf, 4)
    do append(buf, 207)' \
'    do append(buf, 196)
    do append(buf, 4)
    do append(buf, 244)'

# M6: remove the error-code drop (add esp,4 -> add esp,0). iret then pops the #PF error code as the
# return EIP -> triple-fault. Caught by the handler pin (83c404cf -> 83c400cf). Proves the error-code
# drop is load-bearing (iret does NOT pop the #PF error code -- the Codex/SDM critical catch).
mutate no_add_esp \
'    do append(buf, 196)
    do append(buf, 4)
    do append(buf, 207)' \
'    do append(buf, 196)
    do append(buf, 0)
    do append(buf, 207)'

# M7: fill the build-time hole (PT entry 768 -> 769), so 0x300000 is ALREADY mapped at build time --
# no #PF ever fires, the handler/resume is never exercised, and the load reads the identity page
# (zeroes) -> wrong byte. Caught by the build-time hole grep (and the BOOT byte). (Shares
# nc32_page_emit_pt_loop with chosen/liberi; the anchor occurs once.) Proves the fault trigger is
# load-bearing -- the whole link rests on a genuine #PF being taken and resumed.
mutate build_hole_filled \
'    if i == 768:' \
'    if i == 769:'

# M8: MISDIRECT the IDT #PF gate (handler_vaddr -> handler_vaddr+16), so vector 14 points 16 bytes
# PAST the real handler bytes. The handler is still emitted at its true offset, so the gate no
# longer points at it. Caught by the gate->handler cross-check (the gate is derived from where the
# pinned handler ACTUALLY is, and no longer matches), and on silicon the #PF vectors into the middle
# of the tables -> triple-fault. Proves the IDT vector-14 gate -> handler binding is load-bearing.
mutate gate_misdirected \
'    let handler_vaddr = 1048588 + off_handler' \
'    let handler_vaddr = 1048588 + off_handler + 16'

# M9: corrupt the seed MASK (i ^ 0x5A -> i ^ 0x5B), so every seed byte (and thus the resumed
# proof byte seed[V]) is wrong. Caught by the seeded-frame prefix grep (5a5b... -> 5b5a...) AND on
# silicon by the wrong boot byte. Proves the seed VALUE the resumed load reads is load-bearing in
# the proof byte (complementing the wrong-frame mutation, which proves the frame TARGET).
mutate seed_mask \
'    do append(buf, i ^ 90)' \
'    do append(buf, i ^ 91)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link22-mutation check(s) failed."; exit 1; fi
xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: link22 mutation proof ($pass checks: control passes prologue+glue+handler+gate+hole+seed+boot gates C-FREE; 9 mutations each CAUGHT via a real two-stage seed compile of the mutated backend -- a not-present PTE and a wrong frame are caught on SILICON (re-fault / wrong byte); a corrupted slot-shift, a removed TLB flush, a removed iret, and a removed add-esp,4 are caught by the exact #PF iret-resume handler pin (their triple-faults are proven on BOTH substrates by the empirical pre-build); a MISDIRECTED IDT gate is caught by the gate->handler cross-check; filling the build-time hole is caught by the hole grep; a corrupted seed mask is caught by the seeded-frame grep -- the runtime page-map, the TLB flush, the error-code drop, the iret-RESUME, the IDT gate binding, and the seed value are all proven load-bearing$xc)"
exit 0
