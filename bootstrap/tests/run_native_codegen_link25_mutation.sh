#!/usr/bin/env bash
# Link 25 (hoopteeter, ninth kernel-arc link) MUTATION proof -- "prove the long-mode-entry gate bites."
# The link25 dual-substrate gate is only meaningful if a WRONG compiler would fail it. We mutate the
# compiler SOURCE at a unique anchor and re-emit the canonical probe through the C-interpreted backend:
# each mutation must be CAUGHT -- a white-box pin rejects the structural change, or no/ a wrong frame is
# emitted (triple-fault / != golden).
#
# The central claim: "the proof byte appeared only because the image GENUINELY crossed into 64-bit long
# mode and computed the HIGH dword of V*K with REX.W instructions." Mutations attack exactly that:
#   M-Lbit   GDT code desc L-bit 0xAF->0xCF -> far-jmp lands in COMPATIBILITY mode (not 64-bit); the
#            identical REX.W body decodes 32-bit -> emits 0xFF (silicon-proven, both substrates) ----- gdt pin
#   M-lme    EFER.LME or-0x100 -> 0  -> never enters IA-32e -> triple-fault (no frame) -------------- head pin
#   M-pae    CR4 0x20 -> 0           -> PG with LME & !PAE -> #GP -> triple-fault ------------------- head pin
#   M-pg     CR0 0x80000000 -> 0     -> paging never enabled -> not long mode -> garbage/no frame --- head pin
#   M-pml4   PML4[0] present 3 -> 2  -> page walk hits a not-present PML4E -> #PF -> triple-fault ---- boot (no frame)
#   M-ljmp   ljmp target +58 -> +0   -> far-jmp misses long_entry (re-runs the head in 64-bit) ------ ljmp-target pin
#   M-shr    REX.W shr count 0x20->0 -> high dword NOT extracted (no-op shift) -> low byte 0x01 ------ observable pin
#   M-imul   REX.W imul 0x48 -> 0x90 -> 32-bit non-widening multiply -> high dword 0 -> wrong byte --- observable pin
#
# M-Lbit/M-shr/M-imul are BEHAVIORALLY-DETECTABLE (the byte changes) AND structurally pinned; their
# underlying silicon RED is the empirical pre-build bite-map (lbit -> de-FF-ad, compat32 -> de-01-ad,
# nolme/nopae/nopg/badcr3 -> no frame, all RED on BOTH QEMU and Bochs). M-ljmp is caught by the
# reachability pin (the analogue of talkert's jb-target==.ack); M-pml4 is caught on silicon. The exact
# transition bytes and K/shr-count are NOT silicon-witnessable in isolation -- they are white-box-pinned.
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
    echo "SKIP: native-codegen link25 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: native-codegen link25 mutation proof (no qemu)"; exit 0
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
fail_test() { echo "FAIL: link25-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): return 12451841 end'   # V=0xBE0001 -> proof = high dword of V*0x10001 = 0xBE
GOLDEN=190                                  # 0xBE -> frame de be ad
# the exact 56-byte transition head (only gdtr/pml4/long_entry le32 vary):
HEAD='fa0f0115[0-9a-f]{8}b8200000000f22e0b8[0-9a-f]{8}0f22d8b9800000c00f320d000100000f300f20c00d000000800f22c0ea[0-9a-f]{8}0800'
OBS='89f090b901000100480fafc148c1e820'
# the observable + the shared 58-byte epilogue as one EXACT contiguous run (the proof-byte data-flow):
# shr rax,0x20; mov bl,al; frame 0xDE<bl>0xAD on 0xE9; result-dependent exit from bl; "Shutdown"; cli;hlt.
DATAFLOW='89f090b901000100480fafc148c1e82088c366bae900b0deee88d8eeb0adee88d83431247f66baf400ee66ba0089b053eeb068eeb075eeb074eeb064eeb06feeb077eeb06eeefaf4ebfd'
le32_at() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

emit_seq=0
# assess(compiler_src) -> "GREEN" or "CAUGHT:<why>"
assess() {
    local comp="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-long\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$comp" < p.herb >/dev/null 2>/dev/null )
    [[ -f "$d/a.out" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$d/a.out" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$d/a.out" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$(echo "$chx" | grep -oE "$HEAD" | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:head"; return; }
    [[ "$(echo "$chx" | grep -oE "$OBS"  | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:observable"; return; }
    [[ "$(echo "$chx" | grep -oE "$DATAFLOW" | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:dataflow"; return; }
    echo "$chx" | grep -q 'ffff0000009aaf00' || { echo "CAUGHT:gdt-no-L1"; return; }
    [[ "$(echo "$chx" | grep -oE 'ffff0000009a..00' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:gdt-L0-mask"; return; }
    echo "$chx" | grep -q 'ffff00000092af001700' || { echo "CAUGHT:gdt-datadesc"; return; }
    [[ "$(echo "$chx" | grep -oE '66bae900' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:emit"; return; }
    [[ "$(echo "$chx" | grep -oE '0f22c0ea' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:cr0jmp-anchor"; return; }
    # the FULL chain bind (mirrors run_native_codegen_link25.sh): GDTR-base -> GDT, CR3 -> PML4 -> PDPT -> PD,
    # ljmp -> observable, lgdt -> GDTR. A mutation to any transition VALUE (CR3/GDTR/PDPT) is caught here even
    # when it boots (e.g. CR3 -> the adjacent PDPT still boots green; the bind rejects it white-box).
    local l1_pos gdt_vaddr pml4_vaddr pdpt_vaddr pd_vaddr gdtr_pos cr0jmp_pos obs_pos cr3_pos lgdt_pos
    l1_pos=$(echo "$chx" | grep -bo 'ffff0000009aaf00' | head -1 | cut -d: -f1)
    gdt_vaddr=$(( 1048588 + l1_pos / 2 - 8 ))
    pml4_vaddr=$(( (gdt_vaddr + 30 + 4095) / 4096 * 4096 )); pdpt_vaddr=$(( pml4_vaddr + 4096 )); pd_vaddr=$(( pdpt_vaddr + 4096 ))
    gdtr_pos=$(echo "$chx" | grep -bo 'ffff00000092af001700' | head -1 | cut -d: -f1)
    cr0jmp_pos=$(echo "$chx" | grep -bo '0f22c0ea' | head -1 | cut -d: -f1)
    obs_pos=$(echo "$chx" | grep -bo "$OBS" | head -1 | cut -d: -f1)
    cr3_pos=$(echo "$chx" | grep -bo '0f22e0b8' | head -1 | cut -d: -f1)
    lgdt_pos=$(echo "$chx" | grep -bo 'fa0f0115' | head -1 | cut -d: -f1)
    [[ -n "$gdtr_pos" && -n "$cr0jmp_pos" && -n "$obs_pos" && -n "$cr3_pos" && -n "$lgdt_pos" ]] || { echo "CAUGHT:locate"; return; }
    [[ "$(le32_at "$chx" $(( gdtr_pos + 20 )))" -eq "$gdt_vaddr" ]] || { echo "CAUGHT:gdtr-base"; return; }
    [[ "$(le32_at "$chx" $(( (pml4_vaddr - 1048588) * 2 )))" -eq "$(( pdpt_vaddr + 3 ))" ]] || { echo "CAUGHT:pml4"; return; }
    [[ "$(le32_at "$chx" $(( (pdpt_vaddr - 1048588) * 2 )))" -eq "$(( pd_vaddr + 3 ))" ]] || { echo "CAUGHT:pdpt"; return; }
    [[ "$(le32_at "$chx" $(( cr0jmp_pos + 8 )))" -eq "$(( 1048588 + obs_pos / 2 ))" ]] || { echo "CAUGHT:ljmp-target"; return; }
    [[ "$(le32_at "$chx" $(( cr3_pos + 8 )))" -eq "$pml4_vaddr" ]] || { echo "CAUGHT:cr3-bind"; return; }
    [[ "$(le32_at "$chx" $(( lgdt_pos + 8 )))" -eq "$(( gdt_vaddr + 24 ))" ]] || { echo "CAUGHT:lgdt-bind"; return; }
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
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated compiler emits golden=$GOLDEN via a genuine 64-bit long-mode entry"; pass=$((pass+1));
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

# M-Lbit: clear the GDT 64-bit code descriptor L-bit (flags byte 0xAF -> 0xCF). The far-jmp then loads a
# 32-bit (L=0,D=1) descriptor -> COMPATIBILITY mode, NOT 64-bit; the identical REX.W body decodes 32-bit
# and emits 0xFF (silicon-proven both substrates). Caught by the GDT L=1 / compat-twin pin.
mutate Lbit \
'    do append(buf, 154)
    do append(buf, 175)
    do append(buf, 0)' \
'    do append(buf, 154)
    do append(buf, 207)
    do append(buf, 0)'

# M-lme: EFER.LME (or eax,0x100 -> or eax,0). LME never set -> CR0.PG does NOT enter IA-32e -> the ljmp
# to an L=1 descriptor runs as 16-bit -> garbage -> triple-fault (no frame). Caught by the head pin.
mutate lme \
'    do append(buf, 13)
    do append(buf, 0)
    do append(buf, 1)
    do append(buf, 0)
    do append(buf, 0)' \
'    do append(buf, 13)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)'

# M-pae: CR4.PAE (mov eax,0x20 -> mov eax,0). Setting CR0.PG with EFER.LME=1 and CR4.PAE=0 is illegal
# (#GP) -> triple-fault. Caught by the head pin.
mutate pae \
'    do append(buf, 184)
    do append(buf, 32)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)' \
'    do append(buf, 184)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)'

# M-pg: CR0.PG (or eax,0x80000000 -> or eax,0). Paging never enabled -> not IA-32e -> the L=1 ljmp runs
# 16-bit -> garbage/no frame. Anchored through the trailing mov-cr0 + ljmp opcode (unique). Head pin.
mutate pg \
'    do append(buf, 13)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 128)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 192)
    do append(buf, 234)' \
'    do append(buf, 13)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 0)
    do append(buf, 15)
    do append(buf, 34)
    do append(buf, 192)
    do append(buf, 234)'

# M-pml4: clear the PML4[0] present bit (pdpt_vaddr + 3 -> + 2 == RW, not-present). The page-table walk
# hits a not-present PML4E the instant CR0.PG flips -> #PF with no IDT -> triple-fault (no frame). Caught
# on silicon (the proof that CR3/the page tables are load-bearing).
mutate pml4 \
'nc_append_le32(buf, pdpt_vaddr + 3)' \
'nc_append_le32(buf, pdpt_vaddr + 2)'

# M-ljmp: retarget the far-jmp to the stash (v0+epi) instead of long_entry (v0+epi+58). The far-jmp then
# re-executes the transition head in 64-bit (lgdt/mov-cr fault) and never reaches the observable. Caught
# by the ljmp-target == long_entry reachability pin (the analogue of talkert's jb-target==.ack).
mutate ljmp \
'let long_entry_vaddr = v0 + epi + 58' \
'let long_entry_vaddr = v0 + epi + 0'

# M-shr: REX.W shr count 0x20 -> 0 (the 64-bit high-dword extraction becomes a no-op; the count masks to
# 0). al is then the LOW byte of V*K (0x01 for V=0xBE0001) -> de-01-ad, NOT de-be-ad. Caught by the exact
# observable pin (and behaviorally on silicon). The 0x20 count is the compat self-defeat byte.
mutate shr \
'    do append(buf, 72)
    do append(buf, 193)
    do append(buf, 232)
    do append(buf, 32)' \
'    do append(buf, 72)
    do append(buf, 193)
    do append(buf, 232)
    do append(buf, 0)'

# M-imul: REX.W prefix 0x48 -> 0x90 (nop) on the imul. The multiply becomes 32-bit non-widening, so the
# product never exceeds 32 bits, its high dword is 0, and shr yields 0 -> wrong byte. Proves the 64-bit
# WIDENING multiply is load-bearing. Caught by the exact observable pin. Anchored through the unique
# mov ecx,0x10001 prefix (480fafc1 alone also appears in the x86-64 backend's imul).
mutate imul \
'    do append(buf, 185)
    do append(buf, 1)
    do append(buf, 0)
    do append(buf, 1)
    do append(buf, 0)
    do append(buf, 72)
    do append(buf, 15)
    do append(buf, 175)
    do append(buf, 193)' \
'    do append(buf, 185)
    do append(buf, 1)
    do append(buf, 0)
    do append(buf, 1)
    do append(buf, 0)
    do append(buf, 144)
    do append(buf, 15)
    do append(buf, 175)
    do append(buf, 193)'

# M-pdpt: clear the PDPT[0] present bit (pd_vaddr+3 -> +2). The first 64-bit fetch walks
# PML4[0]->PDPT[0]->PD[0]; a not-present PDPT entry -> #PF -> triple-fault (no frame). M-pml4 covers ONLY
# the PML4 level; this is the separate PDPT level. Caught by the new white-box PDPT[0] bind AND on silicon.
mutate pdpt \
'nc_append_le32(buf, pd_vaddr + 3)' \
'nc_append_le32(buf, pd_vaddr + 2)'

# M-cr3val: point CR3 at the adjacent PDPT table (pml4_vaddr -> pml4_vaddr + 4096). The image STILL BOOTS
# GREEN on silicon (the PDPT's first entry chains as a valid PML4E into the identity map), so silicon does
# NOT catch it -- caught ONLY by the new CR3 == pml4_vaddr white-box reachability bind (the analogue of the
# ljmp-target bind; the completeness-critic's near-miss-CR3 forge). Proves CR3 is bound to the real tables.
mutate cr3val \
'nc_append_le32(buf, pml4_vaddr)' \
'nc_append_le32(buf, pml4_vaddr + 4096)'

# M-hardcode: the epilogue data-flow forge (completeness-critic, found re-attacking the hardened gate).
# Replace `mov bl,al` (88 c3 -- take the observable's REX.W-shr output) with `mov bl,0xBE` (b3 be --
# hardcode), in the shared epilogue. The 64-bit observable STILL RUNS, but its output al is discarded and
# the framed byte is a constant. BEHAVIORALLY INVISIBLE for the canonical probe (0xBE happens to equal the
# genuine high dword, so it still boots de-be-ad) -- caught ONLY by the contiguous observable->epilogue
# data-flow pin, the analogue of talkert's behaviorally-invisible count-N pin.
mutate hardcode \
'    do append(buf, 136)
    do append(buf, 195)' \
'    do append(buf, 179)
    do append(buf, 190)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link25-mutation check(s) failed."; exit 1; fi
echo "PASS: link25 mutation proof ($pass checks: control passes head+observable+data-flow+gdt(L=1)+L0-mask+GDTR-base+PML4+PDPT+emit+ljmp-target+CR3+lgdt binds + boot; 11 mutations each CAUGHT -- incl. M-hardcode (epilogue 'mov bl,al'->'mov bl,0xBE': the 64-bit observable runs but its output is discarded and the framed byte is a constant -- BEHAVIORALLY INVISIBLE, the same byte still boots -- caught ONLY by the contiguous observable->epilogue data-flow pin) -- M-Lbit (GDT L-bit 0xAF->0xCF -> compatibility mode, the identical REX.W body emits 0xFF on BOTH substrates) by the GDT pin; M-lme/M-pae/M-pg (drop EFER.LME / CR4.PAE / CR0.PG -> never genuine 64-bit -> triple-fault/garbage on silicon) by the exact-head pin; M-pml4 (clear PML4[0] present) and M-pdpt (clear PDPT[0] present -> first-fetch page-walk #PF) caught WHITE-BOX by the PML4/PDPT present binds; M-cr3val (CR3 -> the adjacent PDPT table: STILL BOOTS GREEN on silicon) caught ONLY by the new CR3==pml4_vaddr white-box reachability bind; M-ljmp (retarget the far-jmp off long_entry) by the ljmp-target==long_entry bind; M-shr (REX.W shr count 0x20->0, the compat self-defeat byte -> de-01-ad) and M-imul (REX.W 0x48->nop -> 32-bit non-widening multiply -> high dword 0) by the exact 16-byte observable pin -- so EFER.LME, CR4.PAE, CR0.PG, the descriptor L-bit, the FULL CR3->PML4->PDPT->PD page-table chain, the GDTR-base->selector-0x08 resolution, the mode-switch far-jmp reachability, the 64-bit shr-32, and the 64-bit widening imul are all proven load-bearing or white-box-bound; the byte cannot appear without a genuine 64-bit long-mode entry. The completeness-critic's body-far-jmp forge [a body ljmp 0x08:<hidden 32-bit blob> that hardcodes the byte and skips the transition] is closed in the forcing harness's body gate, NOT here -- the mutation harness mutates only the honest compiler)"
exit 0
