#!/usr/bin/env bash
# Link 22 (sixth kernel-arc link) MUTATION proof -- "prove the iret-resume / demand-paging gate
# bites." The link22 dual-substrate gate is only meaningful if a WRONG compiler would fail it. We
# mutate the compiler SOURCE at a unique anchor and re-emit a green probe through the C-interpreted
# backend: each mutation must be CAUGHT -- the resumed load re-faults / triple-faults (no byte), or
# reads the wrong frame (wrong byte), or the exact handler/hole white-box pin rejects it.
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

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
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
# assess(compiler_src) -> "GREEN" or "CAUGHT:<why>"
assess() {
    local comp="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-demand\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$comp" < p.herb >/dev/null 2>/dev/null )
    [[ -f "$d/a.out" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$d/a.out" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$d/a.out" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
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
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated compiler emits golden=$GOLDEN via the iret-resumed load of the runtime-mapped frame"; pass=$((pass+1));
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
echo "PASS: link22 mutation proof ($pass checks: control passes prologue+glue+handler+gate+hole+seed+boot gates; 9 mutations each CAUGHT -- a not-present PTE and a wrong frame are caught on SILICON (re-fault / wrong byte); a corrupted slot-shift, a removed TLB flush, a removed iret, and a removed add-esp,4 are caught by the exact #PF iret-resume handler pin (their triple-faults are proven on BOTH substrates by the empirical pre-build); a MISDIRECTED IDT gate is caught by the gate->handler cross-check; filling the build-time hole is caught by the hole grep; a corrupted seed mask is caught by the seeded-frame grep -- the runtime page-map, the TLB flush, the error-code drop, the iret-RESUME, the IDT gate binding, and the seed value are all proven load-bearing)"
exit 0
