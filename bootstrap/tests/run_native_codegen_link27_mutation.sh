#!/usr/bin/env bash
# Link 27 (rizzing, eleventh kernel-arc link) MUTATION proof -- "prove the shared-memory-tick (async-
# SURVIVAL + synchronization) gate bites." The link27 dual-substrate gate is only meaningful if a WRONG
# compiler would fail it. We mutate the compiler SOURCE at a unique anchor and re-emit a green probe
# through the C-interpreted backend: each mutation must be CAUGHT -- no frame is emitted (timeout /
# triple-fault), or the exact head' / glue-spin / glue-ISR / tick-provenance white-box pin rejects the
# structural change.
#
# The central claim: "the proof byte was emitted only because a MAINLINE task SYNCHRONIZED with the
# asynchronous timer IRQ0 through a SHARED MEMORY word -- the pure-glue ISR bumped `tick` (acknowledging
# the PIC with an EOI and eax-preservingly `iret`-resuming the mainline) while the mainline SPUN on the
# SAME word, surviving N=3 ticks before running the compiled body." Mutations attack exactly that:
#   no_inc          ff05 inc[tick] -> nop nop -> the ISR never bumps the cell -> spin never advances ->
#                   no frame (timeout). The glue-ISR anchor (50 ff 05 ...) breaks -> CAUGHT at the ISR pin.
#   no_eoi          out 0x20,0x20 (e6) -> nop  -> PIC never re-delivers IRQ0 -> stuck below N -> no frame
#                   (timeout). The glue-ISR EOI byte breaks the ISR anchor -> CAUGHT at the ISR pin.
#   no_sti          head sti (fb) -> nop        -> interrupts never enabled -> no IRQ -> spin forever ->
#                   no frame (timeout). The 104-byte head' tail breaks -> CAUGHT at the head' pin.
#   no_iret         ISR iret (cf) -> hlt (f4)   -> mainline never resumes from the first IRQ -> no frame
#                   (timeout). The glue-ISR tail breaks the ISR anchor -> CAUGHT at the ISR pin.
#   jb_retarget     spin jb -10 (72 f6) -> jb +0 (72 00): jb lands on the cmp instead of looping to the
#                   mov, so the spin emits on tick 0 (no survive/repeat). BEHAVIORALLY changes the path,
#                   but the back-edge rel8 (f6) is pinned LITERALLY inside the glue-spin regex (unlike
#                   talkert's body-length-varying rel32), so the spin anchor breaks -> CAUGHT at the spin
#                   pin (the reachability bind is the pinned back-edge itself).
#   wrong_N         spin cmp eax,3 (83 f8 03) -> cmp eax,1 (83 f8 01): emits on tick 1 (same byte),
#                   BEHAVIORALLY INVISIBLE. The N=3 (`03`) is pinned LITERALLY in the glue-spin regex, so
#                   the spin anchor breaks -> CAUGHT at the spin pin ONLY (N is not silicon-witnessable,
#                   the honest analogue of talkert's PIT-divisor pin).
#   wrong_tick_cell ISR inc target (le32 tick_vaddr) -> tick_vaddr+4: the ISR bumps a DIFFERENT word than
#                   the mainline spins on / the head zeroes. The glue-ISR anchor still matches (only the
#                   le32 changed), so PRESENCE pins pass -- caught ONLY by the TICK-CELL PROVENANCE pin
#                   (head==spin==ISR by VALUE), the loader/CPU-redirect meta-class bind. BEHAVIORALLY a
#                   silicon RED too (the spin never sees an advance -> timeout), but the provenance pin
#                   catches it white-box regardless of substrate.
# The underlying SILICON RED for no_inc/no_eoi/no_sti/no_iret/wrong_tick_cell (no advance past the spin ->
# timeout) is independently real on BOTH QEMU and Bochs; assess() catches each at its white-box pin before
# the QEMU leg runs. wrong_N is the only purely-behaviorally-invisible case (same byte on tick 1) and is
# caught ONLY white-box. The async-SURVIVAL + SYNCHRONIZATION property (the kernel cannot reach the byte
# without the ISR genuinely bumping the SAME shared word the mainline spins on, N times) is proven jointly
# by no_inc (no bump => no advance), no_eoi (no re-delivery => no 2nd tick), no_iret (no resume => stuck),
# and wrong_tick_cell (bump the wrong cell => no advance): with N=3 the byte requires 3 real shared-cell
# bumps sustained by EOI + eax-preserving iret-resume.
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
    echo "SKIP: native-codegen link27 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: native-codegen link27 mutation proof (no qemu)"; exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
fail_test() { echo "FAIL: link27-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=88    # the mainline survives N=3 shared-cell ticks then runs the compiled body -> 88 -> frame de 58 ad
# the exact 104-byte head' (only gdtr/esp/idtr/tick le32 vary): GDT-install + PIC remap + PIT program +
# mov dword [tick],0 (c7 05 <le32 tick> 00 00 00 00, the shared-tick zero) + sti
HEAD='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe640c705[0-9a-f]{8}00000000fb'

le32_at() { hx="$1"; o="$2"; echo $((16#${hx:o+6:2}${hx:o+4:2}${hx:o+2:2}${hx:o+0:2})); }

emit_seq=0
# assess(compiler_src) -> "GREEN" or "CAUGHT:<why>"
assess() {
    local comp="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-rizzing\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$comp" < p.herb >/dev/null 2>/dev/null )
    [[ -f "$d/a.out" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$d/a.out" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$d/a.out" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    # (0) the exact 104-byte head' (catches no_sti)
    [[ "${chx:0:208}" =~ $HEAD ]] || { echo "CAUGHT:head"; return; }
    # (1) the glue-spin at byte offset 104 (hex 208), contiguous with the head', AND exactly once
    #     (catches jb_retarget, wrong_N, and the pre-spin-injection forge)
    [[ "${chx:208:22}" =~ ^a1[0-9a-f]{8}83f80372f6fa$ ]] || { echo "CAUGHT:spin-pos"; return; }
    [[ "$(echo "$chx" | grep -oE 'a1[0-9a-f]{8}83f80372f6fa' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:spin"; return; }
    # (2) the glue-ISR exactly once (catches no_inc, no_eoi, no_iret)
    [[ "$(echo "$chx" | grep -oE '50ff05[0-9a-f]{8}b020e62058cf' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:isr"; return; }
    # (3) tick-cell provenance: head == spin == ISR le32 (catches wrong_tick_cell)
    local hpos spos ipos
    hpos=$(echo "$chx" | grep -bo 'c705[0-9a-f]\{8\}00000000' | head -1 | cut -d: -f1)
    spos=208   # the spin is positionally pinned at hex offset 208 (byte 104) by (1) above
    ipos=$(echo "$chx" | grep -bo '50ff05[0-9a-f]\{8\}b020e62058cf' | head -1 | cut -d: -f1)
    if [[ -z "$hpos" || -z "$spos" || -z "$ipos" ]]; then echo "CAUGHT:provenance-anchor"; return; fi
    local ht st it
    ht=$(le32_at "$chx" $((hpos + 4))); st=$(le32_at "$chx" $((spos + 2))); it=$(le32_at "$chx" $((ipos + 6)))
    if ! { [[ "$ht" == "$st" ]] && [[ "$st" == "$it" ]]; }; then echo "CAUGHT:provenance($ht/$st/$it)"; return; fi
    # (4) IDT vec-0x20 gate -> glue-ISR vaddr by value
    local gmid; gmid=$(echo "$chx" | grep -oE '0800008e' | wc -l | tr -d ' ')
    if [[ "$gmid" != 1 ]]; then echo "CAUGHT:gate-mid"; return; fi
    local isr_vaddr mpos lo16 hi16 after lo_v hi_v gate_target
    isr_vaddr=$(( 1048588 + ipos / 2 ))
    mpos=$(echo "$chx" | grep -bo '0800008e' | head -1 | cut -d: -f1)
    lo16="${chx:mpos-4:4}"; hi16="${chx:mpos+8:4}"; after="${chx:mpos+12:4}"
    lo_v=$(( 16#${lo16:2:2}${lo16:0:2} )); hi_v=$(( 16#${hi16:2:2}${hi16:0:2} ))
    gate_target=$(( (hi_v << 16) | lo_v ))
    [[ "$gate_target" -eq "$isr_vaddr" && "$after" == "0701" ]] || { echo "CAUGHT:gate"; return; }
    # (4b) loader/CPU-redirect close: bind the IDTR the head ACTUALLY loads (lidt operand at head' byte
    #   37 = hex 74) to the checked IDT -- limit 0x0107 AND base+0x100 == the checked vec-0x20 gate vaddr.
    local head_idtr idtr_off idtr_limit_hex idtr_base gate_start_vaddr
    head_idtr=$(( 16#${chx:80:2}${chx:78:2}${chx:76:2}${chx:74:2} ))
    idtr_off=$(( (head_idtr - 1048588) * 2 ))
    if [[ "$idtr_off" -lt 0 ]] || [[ $(( idtr_off + 12 )) -gt ${#chx} ]]; then echo "CAUGHT:lidt-range"; return; fi
    idtr_limit_hex="${chx:idtr_off:4}"
    idtr_base=$(( 16#${chx:idtr_off+10:2}${chx:idtr_off+8:2}${chx:idtr_off+6:2}${chx:idtr_off+4:2} ))
    gate_start_vaddr=$(( 1048588 + (mpos - 4) / 2 ))
    { [[ "$idtr_limit_hex" == "0701" ]] && [[ $(( idtr_base + 256 )) -eq "$gate_start_vaddr" ]]; } || { echo "CAUGHT:lidt-redirect"; return; }
    # (5) flat GDT data desc + GDTR limit
    echo "$chx" | grep -q '92cf001700' || { echo "CAUGHT:gdt"; return; }
    # (6) single 0xE9 emit path
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
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated compiler emits golden=$GOLDEN via the shared-memory tick (mainline spins on [tick] the glue-ISR bumps, surviving N=3 async IRQ0s)"; pass=$((pass+1));
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

# assess_image(image_path) -> "GREEN"/"CAUGHT:..." : run the SAME gates on a pre-built (binary-patched
# or hand-forged) image, for forges the source-mutation path cannot express (the emitter's own length
# invariant would reject a source-level spin displacement before the gate ever sees it).
assess_image() {
    local img="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"; rm -rf "$d"; mkdir -p "$d"
    cp "$img" "$d/a.out"
    grub-file --is-x86-multiboot "$d/a.out" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$d/a.out" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "${chx:0:208}" =~ $HEAD ]] || { echo "CAUGHT:head"; return; }
    [[ "${chx:208:22}" =~ ^a1[0-9a-f]{8}83f80372f6fa$ ]] || { echo "CAUGHT:spin-pos"; return; }
    [[ "$(echo "$chx" | grep -oE 'a1[0-9a-f]{8}83f80372f6fa' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:spin"; return; }
    [[ "$(echo "$chx" | grep -oE '50ff05[0-9a-f]{8}b020e62058cf' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:isr"; return; }
    echo "GREEN-gates"   # only the structural pins relevant to the displacement forge; sufficient for the bite
}

# the unmutated control image, for binary-patch forges. Re-interpret the (unmutated) backend source via
# the C bootstrap through a VARIABLE (ctrl_comp) -- the same test-time pattern assess() uses, distinct
# from a Role-2 production HERBERT-compiles-the-backend literal site (which the gaggle switchover-
# completeness grep in run_tests.sh targets; test-time re-interpretation via a variable is exempt).
ctrl_d="$tmp/ctrl.d"; rm -rf "$ctrl_d"; mkdir -p "$ctrl_d"
printf -- '-- emit: multiboot32-rizzing\n%s\n' "$PROBE" > "$ctrl_d/p.herb"
ctrl_comp="$backend"
( cd "$ctrl_d" && "$HERBERT" "$ctrl_comp" < p.herb >/dev/null 2>/dev/null )
CTRL_IMG="$ctrl_d/a.out"

# ============================ SILICON-RED mutations ==========================
# no_inc: ff05 inc dword[tick] -> two nops (255 5 -> 144 144). The ISR never bumps the shared cell, so
# the mainline spin never advances -> NO frame (timeout). Caught at the glue-ISR pin (50ff05... breaks to
# 509090...). Proves the per-tick INC of the shared word is load-bearing.
mutate no_inc \
'    do append(mbuf, 80)
    do append(mbuf, 255)
    do append(mbuf, 5)
    mbuf = nc_append_le32(mbuf, tick_vaddr)' \
'    do append(mbuf, 80)
    do append(mbuf, 144)
    do append(mbuf, 144)
    mbuf = nc_append_le32(mbuf, tick_vaddr)'

# no_eoi: EOI out 0x20,0x20 -> the `out` opcode E6 (230) becomes nop (144) in the glue-ISR. Without the
# EOI the PIC's in-service bit for IRQ0 stays set, so it NEVER re-delivers IRQ0: tick sticks below N=3
# -> NO frame (timeout). Caught at the glue-ISR pin (50ff05...b020e620... -> ...b0209020...). Proves the
# EOI is load-bearing (silicon RED -- no 2nd tick -> timeout -- real on BOTH QEMU and Bochs).
mutate no_eoi \
'    do append(mbuf, 176)
    do append(mbuf, 32)
    do append(mbuf, 230)
    do append(mbuf, 32)
    do append(mbuf, 88)
    do append(mbuf, 207)' \
'    do append(mbuf, 176)
    do append(mbuf, 32)
    do append(mbuf, 144)
    do append(mbuf, 32)
    do append(mbuf, 88)
    do append(mbuf, 207)'

# no_sti: head sti (fb 251) -> nop (144). Interrupts never enabled -> IRQ0 never delivered -> the mainline
# spins on [tick] forever -> NO frame (timeout). Caught at the exact-head' pin (...00000000 fb -> ...00000000
# 90). Proves sti -- the async ENABLER -- is load-bearing for the rizz head.
mutate no_sti \
'    do append(rbuf, 199)
    do append(rbuf, 5)
    rbuf = nc_append_le32(rbuf, tick_vaddr)
    rbuf = nc_append_le32(rbuf, 0)
    do append(rbuf, 251)' \
'    do append(rbuf, 199)
    do append(rbuf, 5)
    rbuf = nc_append_le32(rbuf, tick_vaddr)
    rbuf = nc_append_le32(rbuf, 0)
    do append(rbuf, 144)'

# no_iret: ISR iret (cf 207) -> hlt (f4 244). The handler EOIs then halts forever (IF=0 in the interrupt-
# gate handler), so the mainline NEVER resumes from the first IRQ, no further ticks fire -> NO frame
# (timeout). Caught at the glue-ISR pin (...58cf -> ...58f4). Proves the iret-RESUME is load-bearing.
mutate no_iret \
'    do append(mbuf, 176)
    do append(mbuf, 32)
    do append(mbuf, 230)
    do append(mbuf, 32)
    do append(mbuf, 88)
    do append(mbuf, 207)' \
'    do append(mbuf, 176)
    do append(mbuf, 32)
    do append(mbuf, 230)
    do append(mbuf, 32)
    do append(mbuf, 88)
    do append(mbuf, 244)'

# ============================ WHITEBOX-RED mutations =========================
# idtr_redirect: the head' `lidt [idtr]` operand idtr_vaddr -> gdtr_vaddr (the loader/CPU-redirect meta-
# class). The head' regex WILDCARDS the lidt operand, so pin (0) still passes -- but the CPU now vectors
# IRQ0 through a DIFFERENT IDTR than the harness greps. The loaded "IDTR" at gdtr_vaddr has limit 0x17
# (not 0x0107) and a base != the checked IDT -> CAUGHT at the (4b) lidt-bind. Cross-model Codex built the
# silicon-VALID version (a decoy IDTR -> a trap-gate 0800008f handler that sets [tick]=3 in one IRQ,
# collapsing "survive 3 ticks" while the real 0800008e gate sits dead); this source mutation exercises the
# same bind that closes it. WITHOUT (4b) the unbound lidt operand lets a forge verify a DEAD IDT while
# silicon runs a different interrupt substrate -- rizzing-specific because its emit is the mainline
# fall-through, unlike the prior async links whose emit is the IDT-gated handler.
mutate idtr_redirect \
'    rbuf = nc_append_le32(rbuf, idtr_vaddr)' \
'    rbuf = nc_append_le32(rbuf, gdtr_vaddr)'

# jb_retarget: spin jb -10 (72 f6) -> jb +0 (72 00). The back-edge no longer loops to the mov eax,[tick]
# spin top; jb +0 lands on the next instruction (the cli/fall-through region), so the spin emits without
# genuinely re-reading the cell N times. The back-edge rel8 (f6) is pinned LITERALLY inside the glue-spin
# regex (the reachability bind is the pinned back-edge itself, unlike talkert's body-length-varying
# rel32), so the spin anchor (a1..83f80372f6fa) breaks -> CAUGHT at the spin pin.
mutate jb_retarget \
'    do append(mbuf, 114)
    do append(mbuf, 246)
    do append(mbuf, 250)' \
'    do append(mbuf, 114)
    do append(mbuf, 0)
    do append(mbuf, 250)'

# wrong_N: spin cmp eax,3 (83 f8 03) -> cmp eax,1 (83 f8 01). The mainline emits on tick 1 -- no survive+
# repeat, reducing to an exit-on-first. BEHAVIORALLY INVISIBLE: the frame still appears with the SAME byte
# (88), so silicon does NOT catch it. The N=3 (`03`) is pinned LITERALLY in the glue-spin regex, so the
# spin anchor (a1..83f803..) breaks -> CAUGHT at the spin pin ONLY. This is the honest reason the exact
# count is white-box-pinned -- N is not silicon-witnessable, the analogue of talkert's PIT-divisor pin.
mutate wrong_N \
'    do append(mbuf, 131)
    do append(mbuf, 248)
    do append(mbuf, 3)
    do append(mbuf, 114)
    do append(mbuf, 246)' \
'    do append(mbuf, 131)
    do append(mbuf, 248)
    do append(mbuf, 1)
    do append(mbuf, 114)
    do append(mbuf, 246)'

# wrong_tick_cell: ISR inc target (the le32 tick_vaddr after ff 05) -> tick_vaddr+4. The ISR bumps a
# DIFFERENT word than the head zeroes / the mainline spins on. The glue-ISR PRESENCE anchor still matches
# (only the le32 changed), so the ISR/head pins pass -- caught ONLY by the TICK-CELL PROVENANCE pin
# (head==spin==ISR by VALUE), the loader/CPU-redirect meta-class bind. A forge that spins on one cell while
# the ISR bumps another (the spin would never see an advance) MUST fail here, white-box, on any substrate.
mutate wrong_tick_cell \
'    do append(mbuf, 80)
    do append(mbuf, 255)
    do append(mbuf, 5)
    mbuf = nc_append_le32(mbuf, tick_vaddr)' \
'    do append(mbuf, 80)
    do append(mbuf, 255)
    do append(mbuf, 5)
    mbuf = nc_append_le32(mbuf, tick_vaddr + 4)'

# prespin_inject (BINARY-PATCH forge -- the cross-model Codex find): the rizz head' FALLS THROUGH into
# the spin, so the emit path is the mainline fall-through. A forge that keeps the EXACT head' but injects
# code (e.g. a synchronous emit) between the head' (byte 104) and the spin would, under a free occ()-
# anywhere spin pin, still find the exact spin LATER as dead code and pass. We can't express this at the
# source (the emitter's code-length invariant rejects a displaced spin before the gate runs), so we
# binary-patch the control image: inject 2 nop bytes (90 90) at byte offset 104, pushing the real spin to
# byte 106. The POSITIONAL spin pin (the spin MUST be at byte offset 104, contiguous with the head') MUST
# reject this -- a free occ-anywhere pin would not. Caught at the spin-pos pin.
prespin_img="$tmp/prespin.bin"
if [[ -f "$CTRL_IMG" ]]; then
    python3 - "$CTRL_IMG" "$prespin_img" <<'PY'
import sys
b=bytearray(open(sys.argv[1],"rb").read())
off=4108+104                     # file offset of code byte 104 (the spin's first byte)
b[off:off]=b'\x90\x90'           # inject 2 nops before the spin -> displaces it off offset 104
open(sys.argv[2],"wb").write(bytes(b))
PY
    v=$(assess_image "$prespin_img")
    if [[ "$v" == CAUGHT:* ]]; then echo "PASS mutation prespin_inject: $v"; pass=$((pass+1));
    else fail_test "prespin_inject: pre-spin-injection forge escaped the gate (verdict=$v) -- the positional spin pin does NOT bite"; fi
else
    fail_test "prespin_inject: could not build control image for the binary-patch forge"
fi

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link27-mutation check(s) failed."; exit 1; fi
echo "PASS: link27 mutation proof ($pass checks: control passes head'+spin-pos+isr+provenance+gate+gdt+emit+boot gates; 9 mutations each CAUGHT -- no_inc (ISR never bumps [tick] -> spin never advances), no_eoi (PIC never re-delivers -> stuck below N), no_iret (mainline never resumes) all break the glue-ISR anchor and are caught at the ISR pin (their underlying silicon RED -- no advance past the spin -> timeout -- is real on QEMU+Bochs); no_sti (no IRQ -> spin forever) breaks the 104-byte head' and is caught at the head' pin; jb_retarget (jb -10 -> jb +0: no genuine spin re-read) and wrong_N (cmp 3 -> 1: emits on tick 1, the SAME byte, BEHAVIORALLY INVISIBLE) break the glue-spin anchor (the back-edge rel8 and N are pinned LITERALLY in the regex) and are caught at the spin pin -- the exact count is not silicon-witnessable, like talkert's PIT divisor; wrong_tick_cell (ISR bumps a different word than the mainline spins on) leaves every PRESENCE pin intact and is caught ONLY by the TICK-CELL PROVENANCE value-bind (head==spin==ISR) -- the loader/CPU-redirect meta-class; idtr_redirect (the head' lidt operand pointed at a different IDTR) is caught ONLY by the (4b) lidt-bind requiring the LOADED IDTR's base+0x100 == the checked vec-0x20 gate -- the same meta-class extended to the CPU's ACTUAL interrupt substrate (a cross-model Codex review built the silicon-valid decoy-IDTR + trap-gate forge); prespin_inject (a binary-patched forge that injects code between the exact head' and a now-displaced spin -- the rizz head' falls through, so a free occ-anywhere spin pin would pass a synchronous-emit-then-dead-spin forge) is caught ONLY by the POSITIONAL spin pin requiring the spin at byte offset 104 contiguous with the head' [a cross-model Codex review built this forge]; so the per-tick inc, the EOI, the iret-resume, sti, the back-edge reachability, the exact N, the shared-cell identity, AND the spin's contiguity with the head' are all proven load-bearing or white-box-pinned, and the async-SYNCHRONIZATION property holds: the mainline cannot reach the byte without the ISR genuinely bumping the SAME shared word N times)"
exit 0
