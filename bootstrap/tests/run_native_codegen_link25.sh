#!/usr/bin/env bash
# Native codegen Link 25 (hoopteeter, the NINTH kernel-arc link): the freestanding image crosses
# from 32-bit protected mode into 64-bit LONG MODE and PROVES it. The compiled main() body computes
# a value V in 32-bit, stashes it in esi (a register that SURVIVES the mode transition), then a fixed
# 56-byte transition head (lgdt a GDT with a 64-bit L=1 code descriptor; CR4.PAE; CR3=PML4; EFER.LME
# via wrmsr; CR0.PG -> IA-32e compat; ljmp 0x08:long_entry -> true 64-bit) enters 64-bit mode and a
# 16-byte REX.W observable derives the proof byte = HIGH dword of (V * 0x10001), extracted with a
# REX.W shr-by-32. That byte DISTINGUISHES 64-bit from 32-bit (for a non-degenerate V): in 32-bit/
# compat the REX.W 0x48 decodes as `dec eax` AND `shr r/m32,0x20` masks the count to 0 (a no-op), so
# the identical bytes yield a DIFFERENT byte (silicon-proven in the mutation harness: the L-bit forge
# emits 0xFF, not the golden byte). The gate REJECTS any probe whose 64-bit byte happens to equal its
# 32-bit-compat fallback (the anti-ceremony-degenerate assert, ~line 225: e.g. V=0x80000002). Graded,
# like lingo..talkert, on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs vs a HOST-derived golden),
# NOT C. Pays D19's long-mode-ENTRY half (the full x86-64 backend reunification is deferred to link 10).
#
# Selected by the anchored first-line directive "-- emit: multiboot32-long" (a NINTH emit mode; the
# plain "-- emit: multiboot32", "-idt", "-page", "-store", "-demand", "-timer", "-tick", and default
# ELF64 modes are byte-identical, so the native self-host fixpoint gen2==gen1 is preserved).
#
# Image execution (vaddr V0=0x10000c): [mov esp + ebp-frame(0|5)] [compiled toakie body -- `return V`
#   jumps to epi] [@epi: mov esi,eax (stash V)] [56-byte transition head -> ljmp 0x08:long_entry]
#   [@long_entry: 16-byte 64-bit observable: mov eax,esi (zero-extend V into rax); nop; mov ecx,0x10001;
#   imul rax,rcx; shr rax,32]
#   [shared 58-byte epilogue: frame 0xDE<byte>0xAD on 0xE9 + result-dependent isa-debug-exit on 0xF4
#   + "Shutdown" on 0x8900 + cli;hlt] [GDT/GDTR 30] [pad to 4 KiB] [PML4 4096] [PDPT 4096] [PD 4096
#   identity-mapping the low 1 GiB as 512 2-MiB PAE pages]. The body IS the compiled main() body
#   (anti-ceremony: the proof byte tracks NORMAL compiled lowering, not a canned blob).
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; EXACTLY ONE checksum-valid Multiboot header
#     (magic+flags+checksum==0 mod 2^32) among all 4-aligned candidates in the first 8 KiB, pinned to the
#     genuine shape offset 0x1000 / flags 0 / checksum 0xE4524FFE -- so a decoy magic + a later valid
#     AOUT_KLUDGE header cannot redirect the loader (Codex round-9); ZERO syscall escapes (0F05 / CD80 /
#     0F34) in the body+head+observable+epilogue window (bounded by the epilogue terminal faf4ebfd).
#   WHITE-BOX (per probe; the runtime byte alone is forgeable -- a hardcoded `mov al,X`, a 32-bit `mul`-
#   based high-dword, or a compat-mode (L=0) run of the same bytes would also produce a byte -- so prove
#   the structure):
#     - THE EXACT 56-BYTE TRANSITION HEAD (only gdtr/pml4/long_entry le32 vary), EXACTLY ONCE: cli; lgdt;
#       CR4=0x20 (PAE only); CR3=PML4; EFER.LME (rdmsr; or 0x100; wrmsr); CR0.PG; ljmp sel=0x08. Pins
#       every behaviorally-invisible transition bit (PAE, LME, PG) and the 64-bit code selector at once.
#     - THE EXACT 16-BYTE 64-bit OBSERVABLE, EXACTLY ONCE: 89 f0 (mov eax,esi -- zero-extends esi=V into
#       rax in 64-bit; reading rsi directly would multiply the architecturally-UNDEFINED high 32 bits and
#       corrupt the byte on real silicon -- cross-model Codex catch) 90 (nop) b9 01 00 01 00 (mov ecx,
#       0x10001 -- the multiplier K) 48 0f af c1 (REX.W imul) 48 c1 e8 20 (REX.W shr rax,0x20). The REX.W
#       prefixes and the shr count 0x20 are load-bearing (the compat self-defeat).
#     - THE GDT 64-bit CODE descriptor 0x00AF9A000000FFFF (L=1) EXACTLY ONCE, and the compat twin
#       0x00CF9A000000FFFF (L=0,D=1) ABSENT (occ 0): the single L-bit that distinguishes true 64-bit
#       from compatibility mode. Plus the data descriptor + GDTR.limit=0x17.
#     - THE ljmp TARGET == long_entry (REACHABILITY bind): decode the head's ljmp imm32 and assert it
#       equals the observable's vaddr, so the 64-bit body is reached ONLY via the mode-switching far-jmp
#       (a mistargeted / nop'd ljmp falls through in 32-bit -> the REX.W bytes decode wrong -> != X).
#     - THE PAE TABLES, FULLY BOUND BY VALUE AT THEIR DERIVED VADDRS (not occurrence-counted -- Codex
#       round-8): CR3 == PML4; PML4[0] == PDPT|3 (high dword 0) and PML4[1..511] == 0; PDPT[0] == PD|3
#       (high 0) and PDPT[1..511] == 0; all 512 PDEs == i*0x200000+0x83 (high 0, the low-1-GiB 2-MiB
#       identity map). So the page WALK provably maps virtual 0x10000c -> physical 0x10000c: no PDE alias
#       can divert the first post-CR0.PG fetch to a hidden page. Emitter-laid-out (no runtime store ->
#       typed-memory deferred).
#     - THE ENTRY+LOAD FRAME so the SCANNED bytes ARE the bytes that RUN: e_entry==0x10000c; e_phoff/
#       phentsize/phnum==52/32/1 (exactly one PT_LOAD); that segment's p_offset/p_vaddr/p_paddr/filesz/
#       memsz pinned exactly and it maps file 0x100c -> vaddr 0x10000c (Codex round-7: a relocated/extra
#       phdr or an enlarged segment can hide a redirect/blob).
#     - THE PROLOGUE+BODY [offset 0 .. stash] (scanned from 0 so a prefix-jmp is caught): a 16-mnemonic
#       WHITELIST (mov/movzx/movsx/push/pop/add/sub/imul/cmp/test/sete/setne/je/jne/jmp/nop -- everything
#       else, incl. string/FPU/segment-load/exotic, REJECTED); FREE of I/O + privileged; only DIRECT near
#       je/jne/jmp, STRICTLY FORWARD (no back-edge -- a loop could walk esp into the tables), to in-body
#       boundaries (no far/indirect/call/ret/int); writes ONLY stack memory -- every memory operand is
#       [ebp-0xNN] AND only when the 89e5 ebp-frame is present, esp/ebp/sp/bp written ONLY by the pinned
#       prologue (mov esp,esp_val; [mov ebp,esp; sub esp,imm8<=0x7c]) caught by a GENERIC dest detector, no
#       segment-register write, body < 2048 bytes. (Closes cross-model Codex's runtime-page-table-mutation
#       class and its esp-redirect / loop / no-frame-ebp residuals.)
#       NOTE: the authoritative, current gate list is the final PASS-summary line of this script; this
#       header is orientation. The verification closed the 7 completeness-critic forge classes PLUS a
#       cross-model Codex hunt (10 rounds): a correctness bug (mov rax,rsi read undefined high rsi ->
#       mov eax,esi) and the loader/CPU-redirect meta-class -- runtime page-table mutation, phdr-shape
#       hiding, no-frame [ebp] store, leaf-PDE alias + blob smuggle, and the Multiboot-header decoy.
#     - THE SINGLE EMIT PATH: mov dx,0x00E9 (66 BA E9 00) EXACTLY ONCE (in the epilogue) -- one frame-
#       emit, reached only after the observable computed the high dword in 64-bit.
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit == host golden, e9 == 0xDE<byte>0xAD, ONE frame.
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence.
#   PROBE VECTORS: then-arm + else-arm + literal + no-locals + 31-local cap. Each proves the body ran
#     (V tracked through esi) AND the byte was computed in genuine 64-bit (high dword of V*K).
#   REJECTS (+ twins): out-of-subset bodies (div/mod, bitwise, 2-function, non-EQ comparator,
#     parameterised main, non-EQ bool cond) emit NO valid image; the 32-local cap (ERR 495) too.
#
# Honest scope: proves "crosses into 64-bit long mode and runs a compiled body whose proof byte is a
# 64-bit-distinguishing high dword [per non-degenerate probe], as a freestanding 32-bit Multiboot image under QEMU + Bochs+GRUB," NOT real
# silicon, arbitrary emulator versions, the full x86-64 backend (link 10), or MMIO. The exact PAE/EFER/
# CR transition bytes and the K/shr-count are NOT silicon-witnessable in isolation -- they are pinned
# WHITE-BOX; what IS silicon-proven (mutation harness): dropping LME / PAE / PG / CR3, retargeting the
# ljmp, or clearing the descriptor L-bit each makes the golden byte vanish or change (the L-bit forge
# emits 0xFF on BOTH substrates). The dual-substrate + host golden replaces the absent C differential.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L9_BOCHS_PROBES:-long_then long_else}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1
fi
if [[ ! -f "$backend" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1
fi

source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 \
    && sudo -n true 2>/dev/null; }

# the 64-bit-only observable: proof byte = high dword of (V * 0x10001) = (V*65537 >> 32) & 0xFF
host_proof() { echo $(( ( ($1 * 65537) >> 32 ) & 0xff )); }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }
# the byte the EXACT observable bytes would emit if run in 32-bit/compat (the anti-ceremony fallback):
# mov eax,esi; nop; mov ecx,K; (48=)dec eax; imul eax,ecx; (48=)dec eax; (shr eax,0x20 masked to no-op)
# -> al = ((V-1)*K - 1) & 0xFF. The proof is "64-bit-only" only if this DIFFERS from the golden byte;
# assert it per probe (cross-model Codex: V=0x80000002 would collide -- golden 0x00 == fallback 0x00).
host_fallback32() { echo $(( ( ($1 - 1) * 65537 - 1 ) & 0xff )); }

gen_locals() { # n prefix  (small filler values -- used by the 32-local REJECT)
    local n="$1" pfx="$2" s='func main():' i
    for i in $(seq 0 $((n - 1))); do s="$s let $pfx$i = $i"; done
    echo "$s return $pfx$((n - 1)) end"
}
gen_locals_long() { # n  (31 locals, last = a large V so the high dword is nonzero)
    local n="$1" s='func main():' i
    for i in $(seq 0 $((n - 2))); do s="$s let a$i = $i"; done
    s="$s let a$((n - 1)) = 15728645"
    echo "$s return a$((n - 1)) end"
}

prog_src() { # label
    case "$1" in
      long_then)    echo 'func main(): let x = 6*7  if x == 42: return 12451841 else: return 11206658 end end' ;;
      long_else)    echo 'func main(): let x = 6*7  if x == 43: return 12451841 else: return 11206658 end end' ;;
      long_lit)     echo 'func main(): return 13434883 end' ;;
      long_nolocal) echo 'func main(): return 14418004 end' ;;
      long_cap31)   gen_locals_long 31 ;;
    esac
}
prog_v() { # label -> the body's return value V (the proof byte is the host-derived high dword of V*K)
    case "$1" in
      long_then)    echo 12451841 ;;
      long_else)    echo 11206658 ;;
      long_lit)     echo 13434883 ;;
      long_nolocal) echo 14418004 ;;
      long_cap31)   echo 15728645 ;;
    esac
}
is_branching() { case "$1" in long_then|long_else) return 0 ;; *) return 1 ;; esac; }
ALL_PROBES="long_then long_else long_lit long_nolocal long_cap31"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-long\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1
    fi
    cp "$cdir/a.out" "$out"; return 0
}

# occurrence count of an (extended) regex in a hex string -- asserts a pin is EXACTLY-ONCE.
occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }
# decode a little-endian uint32 from hex string $1 at hex-char offset $2 (8 hex chars).
le32_at() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

static_gates() { # label elf
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx; hx=$(xxd -p "$elf" | tr -d '\n')
    # MULTIBOOT HEADER VALIDATION (Codex round-9): the LOADER (GRUB/QEMU) honors the first CHECKSUM-VALID
    # Multiboot header -- magic + flags + checksum == 0 (mod 2^32) -- NOT the first raw magic. A naive
    # `grep magic | head -1` + flags==0 check is defeated by an earlier INVALID decoy magic with flags 0
    # (which the loader skips because its checksum is wrong) followed by a later VALID AOUT_KLUDGE header
    # that redirects the loader to a hidden 32-bit blob (grub-file still passes -- a valid header exists --
    # and the ELF entry / PT_LOAD / page-table / observable pins all become dead data). So: scan EVERY
    # 4-aligned magic in the first 8 KiB, validate the checksum, require EXACTLY ONE valid header, and pin it
    # to the genuine shape -- offset 0x1000, flags 0, checksum 0xE4524FFE (= -(0x1BADB002) mod 2^32).
    local mb_o mb_valid_count=0 mb_valid_off=-1 mb_valid_flags=-1 mb_valid_csum=0 mb_f mb_c
    for (( mb_o=0; mb_o+12 <= 8192 && mb_o*2+24 <= ${#hx}; mb_o+=4 )); do
        [[ "${hx:$(( mb_o*2 )):8}" == "02b0ad1b" ]] || continue
        mb_f=$(le32_at "$hx" $(( mb_o*2 + 8 ))); mb_c=$(le32_at "$hx" $(( mb_o*2 + 16 )))
        if [[ $(( (16#1BADB002 + mb_f + mb_c) % (1 << 32) )) -eq 0 ]]; then
            mb_valid_count=$(( mb_valid_count + 1 )); mb_valid_off=$mb_o; mb_valid_flags=$mb_f; mb_valid_csum=$mb_c
        fi
    done
    [[ "$mb_valid_count" -eq 1 ]] || { fail_test "$label static: $mb_valid_count checksum-valid Multiboot headers in the first 8 KiB (want exactly 1) -- a 2nd valid header (e.g. AOUT_KLUDGE) redirects the loader to a hidden blob while an invalid decoy passes a first-magic flags check"; ok=0; }
    [[ "$mb_valid_off" -eq 4096 && "$mb_valid_flags" -eq 0 && "$mb_valid_csum" -eq $(( 16#E4524FFE )) ]] || { fail_test "$label static: the valid Multiboot header is not the genuine shape (offset=$mb_valid_off flags=$mb_valid_flags checksum=$mb_valid_csum; want 4096/0/0xE4524FFE) -- AOUT_KLUDGE/address-override or a relocated header can redirect the entry away from the proven ELF path"; ok=0; }
    local code="$tmp/$label.code"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # Bound the escape scan to body+head+observable+epilogue by the epilogue terminal (cli;hlt;jmp$-1 =
    # faf4ebfd). The GDT/GDTR + page tables after it are data.
    local term="${chx%%faf4ebfd*}"
    if [[ "$term" == "$chx" ]]; then fail_test "$label static: epilogue terminal absent"; return 1; fi
    local endbytes=$(( ${#term} / 2 + 4 ))
    dd if="$code" of="$code.t" bs=1 count="$endbytes" status=none 2>/dev/null
    local cth; cth=$(xxd -p "$code.t" | tr -d '\n')
    echo "$cth" | grep -q '0f05' && { fail_test "$label static: 0F 05 (syscall) byte present"; ok=0; }
    echo "$cth" | grep -q 'cd80' && { fail_test "$label static: CD 80 (int 0x80) byte present"; ok=0; }
    echo "$cth" | grep -q '0f34' && { fail_test "$label static: 0F 34 (sysenter) byte present"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # ANTI-CEREMONY: the probe's V must give a 64-bit golden byte that DIFFERS from the byte the same
    # observable bytes emit in 32-bit/compat -- else a compat-mode run forges the golden byte (Codex).
    local vv; vv=$(prog_v "$label")
    [[ "$(host_proof "$vv")" -ne "$(host_fallback32 "$vv")" ]] || { fail_test "$label whitebox: probe V=$vv is anti-ceremony-degenerate -- its 64-bit golden byte equals its 32-bit-compat fallback byte"; ok=0; }
    # (0) THE EXACT 56-BYTE TRANSITION HEAD, EXACTLY ONCE (only gdtr/pml4/long_entry le32 vary). Pins
    #     CR4=0x20 (PAE only), the EFER.LME RMW (or 0x100), CR0.PG, and the ljmp selector 0x08.
    local head='fa0f0115[0-9a-f]{8}b8200000000f22e0b8[0-9a-f]{8}0f22d8b9800000c00f320d000100000f300f20c00d000000800f22c0ea[0-9a-f]{8}0800'
    [[ "$(occ "$chx" "$head")" == 1 ]] || { fail_test "$label whitebox: exact 56-byte transition head (cli;lgdt;CR4.PAE;CR3;EFER.LME;CR0.PG;ljmp 0x08) not present exactly once"; ok=0; }
    # (1) THE EXACT 16-BYTE 64-bit OBSERVABLE, EXACTLY ONCE: mov rax,rsi; mov ecx,0x10001; REX.W imul;
    #     REX.W shr rax,0x20. The REX.W (0x48) and the shr count 0x20 are the compat self-defeat.
    [[ "$(occ "$chx" '89f090b901000100480fafc148c1e820')" == 1 ]] || { fail_test "$label whitebox: exact 16-byte 64-bit observable (mov rax,rsi; mov ecx,0x10001; REX.W imul; REX.W shr 0x20) not present exactly once"; ok=0; }
    # (1b) THE PROOF-BYTE DATA-FLOW, EXACTLY ONCE: the observable + the shared 58-byte epilogue must be
    #      this EXACT contiguous 74-byte run, so the emitted byte IS the observable's REX.W-shr output
    #      (shr rax,0x20; mov bl,al; frame 0xDE<bl>0xAD on 0xE9; result-dependent exit on 0xF4 from bl;
    #      "Shutdown" on 0x8900; cli;hlt). No byte between the observable and the emit can be altered --
    #      closes the completeness-critic's epilogue data-flow forge: keep the genuine 64-bit observable
    #      running but `mov bl,0xBE` (hardcode) / discard al, so the byte is a constant, not the high dword.
    [[ "$(occ "$chx" '89f090b901000100480fafc148c1e82088c366bae900b0deee88d8eeb0adee88d83431247f66baf400ee66ba0089b053eeb068eeb075eeb074eeb064eeb06feeb077eeb06eeefaf4ebfd')" == 1 ]] || { fail_test "$label whitebox: the observable->epilogue proof-byte data-flow (observable; mov bl,al; frame; result-dependent exit; shutdown; cli;hlt) is not the exact contiguous 74-byte sequence -- the emitted byte may be a hardcoded constant, not the 64-bit observable's output"; ok=0; }
    # (2) THE GDT 64-bit CODE descriptor (L=1) EXACTLY ONCE, and NO OTHER code descriptor: any code
    #     descriptor (access 0x9A) with non-L=1 flags (0xCF/0x8F/0x4F/...) is banned BY MASK, not just the
    #     one 0xCF twin -- so an L=0 selector-0x08 descriptor with the L=1 bytes kept as dead data cannot
    #     exist (the completeness-critic's compat-mode forge E). Plus the data descriptor + GDTR.limit=0x17.
    [[ "$(occ "$chx" 'ffff0000009aaf00')" == 1 ]] || { fail_test "$label whitebox: 64-bit code descriptor 0x00AF9A000000FFFF (L=1) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" 'ffff0000009a..00')" == 1 ]] || { fail_test "$label whitebox: a code descriptor (access 0x9A) with non-L=1 flags exists -- the L-bit/compat forge (L=0 selector-0x08 descriptor + dead L=1 bytes)"; ok=0; }
    [[ "$(occ "$chx" 'ffff00000092af001700')" == 1 ]] || { fail_test "$label whitebox: data descriptor + GDTR limit 0x17 not present exactly once"; ok=0; }
    # Locate the GDT (its null entry is 8 bytes before the L=1 descriptor) and derive the whole emitter
    # layout (the page tables are 4 KiB-aligned right after the 30-byte GDT+GDTR), so the gate can bind the
    # CR3 / lgdt / PML4 / PDPT VALUES, not just assert the bytes exist somewhere.
    local l1_pos gdt_vaddr pml4_vaddr pdpt_vaddr pd_vaddr
    l1_pos=$(echo "$chx" | grep -bo 'ffff0000009aaf00' | head -1 | cut -d: -f1)
    gdt_vaddr=$(( 1048588 + l1_pos / 2 - 8 ))
    pml4_vaddr=$(( (gdt_vaddr + 30 + 4095) / 4096 * 4096 ))
    pdpt_vaddr=$(( pml4_vaddr + 4096 ))
    pd_vaddr=$(( pdpt_vaddr + 4096 ))
    # (2b) GDTR base bind: the GDTR (right after the data desc + limit 1700) has base == the located GDT
    #      vaddr, so selector 0x08 (base+8) resolves to the L=1 descriptor -- not a forged GDT elsewhere.
    local gdtr_pos gdtr_base
    gdtr_pos=$(echo "$chx" | grep -bo 'ffff00000092af001700' | head -1 | cut -d: -f1)
    gdtr_base=$(le32_at "$chx" $(( gdtr_pos + 20 )))
    [[ "$gdtr_base" -eq "$gdt_vaddr" ]] || { fail_test "$label whitebox: GDTR base ($gdtr_base) != the located GDT vaddr ($gdt_vaddr) -- selector 0x08 may resolve to a forged descriptor"; ok=0; }
    # (3) THE PAE CHAIN, all present + bound: PD[0]=0x83, PD[1]=0x200083, and -- pinned WHITE-BOX, not
    #     silicon-only -- PML4[0] == PDPT|present|RW and PDPT[0] == PD|present|RW (closes the unpinned-PDPT-
    #     present forge and moves the page-walk chain off the triple-fault-only leg).
    [[ "$(occ "$chx" '8300000000000000')" == 1 ]] || { fail_test "$label whitebox: PD[0]=0x83 (2-MiB identity page at phys 0) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '8300200000000000')" == 1 ]] || { fail_test "$label whitebox: PD[1]=0x200083 (2-4 MiB identity page) not present exactly once"; ok=0; }
    local pml4_e pdpt_e
    # FULLY bind PML4 and PDPT (Codex round-9 secondary): entry 0 == next-level|present|RW with high dword 0
    # (a nonzero high dword would point the walk at a >4 GiB physical table), and entries 1..511 == 0 so
    # there is no alternate top-level path -- the ONLY page-walk root is PML4[0]->PDPT[0]->PD. (Genuine
    # emitter zero-fills 1..511; verified by dumping. Unreachable given the bounded control flow, but pinned
    # so "the chain is bound" is literally exact.)
    local tbl tname t0want toff thi tlo tbad
    for tbl in pml4 pdpt; do
        if [[ "$tbl" == "pml4" ]]; then toff=$(( (pml4_vaddr - 1048588) * 2 )); t0want=$(( pdpt_vaddr + 3 )); tname="PML4"
        else toff=$(( (pdpt_vaddr - 1048588) * 2 )); t0want=$(( pd_vaddr + 3 )); tname="PDPT"; fi
        local thex="${chx:$toff:8192}" te_i tbad=""
        for (( te_i=0; te_i<512; te_i++ )); do
            tlo=$(le32_at "$thex" $(( te_i * 16 ))); thi="${thex:$(( te_i * 16 + 8 )):8}"
            if [[ "$te_i" -eq 0 ]]; then
                [[ "$tlo" -eq "$t0want" && "$thi" == "00000000" ]] || { tbad="${tname}[0] lo=$tlo hi=$thi (want lo=$t0want hi=0)"; break; }
            else
                [[ "$tlo" -eq 0 && "$thi" == "00000000" ]] || { tbad="${tname}[$te_i] lo=$tlo hi=$thi (want 0)"; break; }
            fi
        done
        [[ -z "$tbad" ]] || { fail_test "$label whitebox: $tname is not [entry0=next|3, rest 0] [$tbad] -- an alternate or high-phys table entry could reroute the page walk"; ok=0; }
    done
    # (3b) BIND THE LEAF PD BY ADDRESS (Codex round-8): the occurrence counts above prove PD[0]/PD[1]'s bytes
    #      EXIST somewhere, not that the PD AT pd_vaddr contains them. A forge can patch the real PDE[0] to an
    #      alias (e.g. 0x400083 -> virtual 0x10000c maps to physical 0x40000c) so the first post-CR0.PG fetch
    #      comes from a HIDDEN blob, leaving a dead 0x83 decoy elsewhere to satisfy the count. Pin all 512
    #      PDEs at pd_vaddr to the EXACT low-1-GiB identity map -- PDE[i].lo == i*0x200000+0x83, PDE[i].hi == 0
    #      -- so the page WALK provably maps virtual 0x10000c -> physical 0x10000c (identity): the scanned
    #      bytes ARE the bytes that execute after paging, no alias possible. (The genuine emitter fills all
    #      512 entries; verified by dumping the PD.)
    local pd_hex="${chx:$(( (pd_vaddr - 1048588) * 2 )):8192}"
    local pde_i pde_lo pde_hi pde_bad=""
    for (( pde_i=0; pde_i<512; pde_i++ )); do
        pde_lo=$(le32_at "$pd_hex" $(( pde_i * 16 )))
        pde_hi="${pd_hex:$(( pde_i * 16 + 8 )):8}"
        if [[ "$pde_lo" -ne $(( pde_i * 2097152 + 131 )) || "$pde_hi" != "00000000" ]]; then pde_bad="PDE[$pde_i] lo=$pde_lo hi=$pde_hi (want lo=$(( pde_i * 2097152 + 131 )) hi=0)"; break; fi
    done
    [[ -z "$pde_bad" ]] || { fail_test "$label whitebox: leaf PD at pd_vaddr is not the 512-entry low-1-GiB identity map [$pde_bad] -- a patched real PDE can alias virtual 0x10000c to a hidden blob while a static 0x83 decoy passes the occurrence count (Codex round-8)"; ok=0; }
    # (4) THE SINGLE EMIT PATH: mov dx,0x00E9 (66 ba e9 00) EXACTLY ONCE.
    [[ "$(occ "$chx" '66bae900')" == 1 ]] || { fail_test "$label whitebox: the 0xE9 frame-emit (mov dx,0x00E9) not present exactly once"; ok=0; }
    # (5) THE STASH: mov esi,eax (89 c6) immediately before the head -- the body's V flows to esi which
    #     survives the mode transition into the observable. EXACTLY ONCE (89c6 + the head's cli;lgdt).
    [[ "$(occ "$chx" '89c6fa0f0115')" == 1 ]] || { fail_test "$label whitebox: stash (mov esi,eax) immediately before the transition head not present exactly once"; ok=0; }
    # (6) REACHABILITY / VALUE binds: the ljmp -> the observable; CR3 -> the located PML4; the lgdt operand
    #     -> the located GDTR. Each transition-VALUE operand (a head wildcard) is bound to where the real
    #     structure sits, so a mistargeted ljmp/CR3/lgdt is caught WHITE-BOX (not only on silicon). The
    #     0f22c0ea (mov cr0,eax; ljmp-opcode) anchor is pinned exactly-once so no decoy can re-point it.
    [[ "$(occ "$chx" '0f22c0ea')" == 1 ]] || { fail_test "$label whitebox: the mov-cr0+ljmp anchor (0f22c0ea) not present exactly once -- a decoy could re-point the ljmp decode"; ok=0; }
    local stash_pos cr0jmp_pos obs_pos cr3_pos lgdt_pos
    stash_pos=$(echo "$chx" | grep -bo '89c6fa0f0115' | head -1 | cut -d: -f1)
    cr0jmp_pos=$(echo "$chx" | grep -bo '0f22c0ea' | head -1 | cut -d: -f1)
    obs_pos=$(echo "$chx" | grep -bo '89f090b901000100480fafc148c1e820' | head -1 | cut -d: -f1)
    cr3_pos=$(echo "$chx" | grep -bo '0f22e0b8' | head -1 | cut -d: -f1)
    lgdt_pos=$(echo "$chx" | grep -bo 'fa0f0115' | head -1 | cut -d: -f1)
    if [[ -z "$stash_pos" || -z "$cr0jmp_pos" || -z "$obs_pos" || -z "$cr3_pos" || -z "$lgdt_pos" ]]; then
        fail_test "$label whitebox: cannot locate the reachability-bind anchors"; ok=0
    else
        local obs_vaddr=$(( 1048588 + obs_pos / 2 ))
        local long_entry_vaddr=$(( 1048588 + stash_pos / 2 + 58 ))
        local ljmp_target=$(le32_at "$chx" $(( cr0jmp_pos + 8 )))
        local cr3_val=$(le32_at "$chx" $(( cr3_pos + 8 )))
        local lgdt_op=$(le32_at "$chx" $(( lgdt_pos + 8 )))
        [[ "$ljmp_target" -eq "$obs_vaddr" ]] || { fail_test "$label whitebox: ljmp target ($ljmp_target) != observable vaddr ($obs_vaddr) -- the 64-bit body is not reached via the mode-switch far-jmp"; ok=0; }
        [[ "$obs_vaddr" -eq "$long_entry_vaddr" ]] || { fail_test "$label whitebox: observable vaddr ($obs_vaddr) not 58 bytes after the stash ($long_entry_vaddr)"; ok=0; }
        [[ "$cr3_val" -eq "$pml4_vaddr" ]] || { fail_test "$label whitebox: CR3 ($cr3_val) != the located PML4 vaddr ($pml4_vaddr) -- CR3 not bound to the real page tables"; ok=0; }
        [[ "$lgdt_op" -eq "$(( gdt_vaddr + 24 ))" ]] || { fail_test "$label whitebox: lgdt operand ($lgdt_op) != the located GDTR vaddr ($(( gdt_vaddr + 24 )))"; ok=0; }
    fi
    # (7) ENTRY + PROLOGUE + BODY REACHABILITY -- the gate must prove the proof structure is REACHED from
    #     the entry point, not merely present. (a) e_entry == 0x10000c, read from the ELF header (not
    #     assumed). (b) the code region BEGINS with `mov esp,imm32` (bc ...), the genuine prologue. (c) the
    #     WHOLE region from offset 0 (the prologue) through the stash is disassembled and FREE of I/O +
    #     privileged + far/indirect transfers, every direct near-branch target an instruction boundary <=
    #     the stash. So a prefix `jmp <appended forge blob>` overwriting the prologue -- keeping the genuine
    #     head/observable/epilogue/page-tables as unreached DEAD DATA (all occ==1 greps still match) -- is
    #     REJECTED: the completeness-critic's prefix-jmp / dead-structure forge.
    local eentry; eentry=$(dd if="$elf" bs=1 skip=24 count=4 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$eentry" == "0c001000" ]] || { fail_test "$label whitebox: ELF e_entry (0x$eentry) != 0x0010000c -- execution may not begin at the pinned prologue"; ok=0; }
    [[ "${chx:0:2}" == "bc" ]] || { fail_test "$label whitebox: code does not begin with mov esp,imm32 (bc ...) -- the prologue is overwritten (a diversion to a forge blob)"; ok=0; }
    # PIN the prologue mov esp,imm32 VALUE to the genuine stack top (esp_val = load_end + 0x4000 = pd_vaddr
    # + 0x5000) -- so a forge cannot start with `mov esp,<epilogue/PD>` and push live bytes (Codex round-3:
    # the prologue mov esp was position-allowed but its immediate was unpinned). pd_vaddr is derived above.
    [[ "$(le32_at "$chx" 2)" -eq "$(( pd_vaddr + 20480 ))" ]] || { fail_test "$label whitebox: prologue mov esp,imm32 (0x$(printf '%x' "$(le32_at "$chx" 2)")) != the stack top (0x$(printf '%x' "$(( pd_vaddr + 20480 ))")) -- esp is redirected at entry"; ok=0; }
    # PHDR ENTRY-BIND: the bytes the gate SCANS (from file offset 0x100c) must be the bytes that actually
    # LOAD and RUN at the entry vaddr 0x10000c. The loader (GRUB/QEMU) decides this from the REAL program-
    # header table (e_phoff/e_phentsize/e_phnum) -- so the gate must WALK those, not read hardcoded offsets
    # (a forger relocates the phdr via e_phoff, or adds a 2nd PT_LOAD, to run a hidden blob at the entry
    # while the gate scans dead bytes). Require: exactly one PT_LOAD, and the one covering file 0x100c maps
    # it to vaddr 0x10000c -- so file 0x100c IS the bytes that run at e_entry.
    local e_phoff e_phentsize e_phnum nload ml_off ml_vaddr ml_paddr ml_fsz ml_msz i base ptype poff pvaddr ppaddr pfsz pmsz pesz_h pnum_h
    e_phoff=$(le32_at "$(dd if="$elf" bs=1 skip=28 count=4 status=none 2>/dev/null | xxd -p)" 0)
    pesz_h=$(dd if="$elf" bs=1 skip=42 count=2 status=none 2>/dev/null | xxd -p); e_phentsize=$(( 16#${pesz_h:2:2}${pesz_h:0:2} ))
    pnum_h=$(dd if="$elf" bs=1 skip=44 count=2 status=none 2>/dev/null | xxd -p); e_phnum=$(( 16#${pnum_h:2:2}${pnum_h:0:2} ))
    # The genuine emitter ALWAYS writes exactly ONE program header at the standard offset (e_phoff==52,
    # e_phentsize==32, e_phnum==1 -- verified for every probe shape). Pin that exact shape: it kills the
    # multi-phdr hiding class outright. The walk below caps at 64 entries, so a forge e_phnum=65 with the
    # genuine PT_LOAD at entry 0, PT_NULLs in 1..63 and a HIDDEN 2nd PT_LOAD at entry 64 would be skipped by
    # the walk (nload stays 1) while a real loader maps the hidden segment over 0x10000c (Codex round-7).
    # With exactly one header asserted, there is nowhere to hide a second loadable segment.
    [[ "$e_phoff" -eq 52 && "$e_phentsize" -eq 32 && "$e_phnum" -eq 1 ]] || { fail_test "$label whitebox: ELF program-header table is not the genuine shape (e_phoff=$e_phoff e_phentsize=$e_phentsize e_phnum=$e_phnum; want 52/32/1) -- a relocated or multi-entry phdr can hide a 2nd PT_LOAD past the walk cap and run a blob at the entry while the gate scans dead bytes"; ok=0; }
    nload=0; ml_off=-1; ml_vaddr=-1; ml_paddr=-1; i=0
    while [[ "$i" -lt "$e_phnum" && "$i" -lt 64 ]]; do
        base=$(( e_phoff + i * e_phentsize ))
        ptype=$(le32_at "$(dd if="$elf" bs=1 skip="$base" count=4 status=none 2>/dev/null | xxd -p)" 0)
        if [[ "$ptype" -eq 1 ]]; then
            nload=$(( nload + 1 ))
            poff=$(le32_at "$(dd if="$elf" bs=1 skip=$(( base + 4 )) count=4 status=none 2>/dev/null | xxd -p)" 0)
            pvaddr=$(le32_at "$(dd if="$elf" bs=1 skip=$(( base + 8 )) count=4 status=none 2>/dev/null | xxd -p)" 0)
            ppaddr=$(le32_at "$(dd if="$elf" bs=1 skip=$(( base + 12 )) count=4 status=none 2>/dev/null | xxd -p)" 0)
            pfsz=$(le32_at "$(dd if="$elf" bs=1 skip=$(( base + 16 )) count=4 status=none 2>/dev/null | xxd -p)" 0)
            pmsz=$(le32_at "$(dd if="$elf" bs=1 skip=$(( base + 20 )) count=4 status=none 2>/dev/null | xxd -p)" 0)
            if [[ 4108 -ge "$poff" && 4108 -lt $(( poff + pfsz )) ]]; then ml_off=$poff; ml_vaddr=$pvaddr; ml_paddr=$ppaddr; ml_fsz=$pfsz; ml_msz=$pmsz; fi
        fi
        i=$(( i + 1 ))
    done
    [[ "$nload" -eq 1 ]] || { fail_test "$label whitebox: ELF has $nload PT_LOAD segments (want exactly 1) -- a 2nd loadable segment could redirect the entry"; ok=0; }
    if [[ "$ml_off" -lt 0 ]]; then
        fail_test "$label whitebox: no PT_LOAD covers the scanned file offset 0x100c (the gate is scanning non-loaded bytes)"; ok=0
    else
        [[ "$(( ml_vaddr + 4108 - ml_off ))" -eq 1048588 ]] || { fail_test "$label whitebox: the PT_LOAD maps file 0x100c to vaddr $(( ml_vaddr + 4108 - ml_off )) != 0x10000c (vaddr/e_phoff-shift forge)"; ok=0; }
        # p_paddr == p_vaddr: QEMU's -kernel loader places the segment by p_paddr, GRUB by p_vaddr. A
        # p_paddr != p_vaddr divergence runs DIFFERENT bytes on the two substrates (so the dual-substrate
        # oracle already kills it -- GRUB rejects it), but pin it so the gate also catches it WHITE-BOX in
        # QEMU-only mode rather than relying on the GRUB-rejection accident (the round-6 p_paddr forge).
        [[ "$ml_paddr" -eq "$ml_vaddr" ]] || { fail_test "$label whitebox: PT_LOAD p_paddr ($ml_paddr) != p_vaddr ($ml_vaddr) -- QEMU loads by p_paddr / GRUB by p_vaddr, so the bytes that run diverge between substrates (p_paddr-shift forge)"; ok=0; }
        # PIN the single segment's EXACT size (Codex round-8): p_filesz == the derived load span (pd_vaddr +
        # 4096 - 0x100000 = code+GDT+PML4+PDPT+PD, the last page being the PD) and p_memsz == filesz + the
        # 16 KiB bss stack. An ENLARGED p_filesz loads extra file bytes into physical memory -- a hidden
        # compat-mode blob that an aliased PDE would execute after CR0.PG (the leaf-PD bind below removes the
        # alias; this removes the smuggled bytes -- defense in depth on the same forge).
        [[ "$ml_fsz" -eq $(( pd_vaddr + 4096 - 1048576 )) ]] || { fail_test "$label whitebox: PT_LOAD p_filesz ($ml_fsz) != the derived load span ($(( pd_vaddr + 4096 - 1048576 )) = end of PD) -- an enlarged file segment can smuggle a hidden blob into physical memory"; ok=0; }
        [[ "$ml_msz" -eq $(( ml_fsz + 16384 )) ]] || { fail_test "$label whitebox: PT_LOAD p_memsz ($ml_msz) != p_filesz + 16 KiB bss stack ($(( ml_fsz + 16384 ))) -- a wrong reservation can shift the stack onto live data"; ok=0; }
        # Pin the segment's ABSOLUTE base (Codex round-9 secondary): p_offset==0x1000, p_vaddr==0x100000
        # (== p_paddr, pinned above). The genuine load base is fixed across probe shapes (only the end moves
        # with body size); pinning it removes any residual offset/vaddr ambiguity beyond the relationship.
        [[ "$ml_off" -eq 4096 && "$ml_vaddr" -eq 1048576 ]] || { fail_test "$label whitebox: PT_LOAD p_offset/p_vaddr ($ml_off/$ml_vaddr) != genuine 0x1000/0x100000 -- a shifted segment base"; ok=0; }
    fi
    if [[ -n "$stash_pos" ]]; then
        local body_end=$(( stash_pos / 2 ))
        if [[ "$body_end" -gt 0 ]]; then
            dd if="$code" of="$code.body" bs=1 skip=0 count="$body_end" status=none 2>/dev/null
            local bdis; bdis=$(objdump -D -b binary -m i386 -M intel "$code.body" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
            # INSTRUCTION WHITELIST (the robust closure -- ends the esp/ebp-redirect blacklist whack-a-mole):
            # the genuine toakie lowering uses ONLY these 12 mnemonics. Banning EVERYTHING else rejects
            # string ops (stos/movs/scas), FPU stores, segment loads (lss/les/lds), pusha/popa/enter/leave,
            # 16-bit/exotic forms, in/out/int, far/indirect -- any instruction that could write the page
            # tables/code/epilogue or redirect the stack. (Dangerous USES of allowed mnemonics -- mov esp,
            # mov [abs] -- are still caught by the esp/ebp-write and [ebp-0xNN]-memop checks below.)
            local bad; bad=$(echo "$bdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | awk '{print $1}' | grep -ivE '^(mov|movzx|movsx|push|pop|add|sub|imul|cmp|test|sete|setne|je|jne|jmp|nop)$' | sort -u | tr '\n' ' ')
            [[ -z "${bad// /}" ]] || { fail_test "$label whitebox: body uses non-toakie instruction(s) [$bad] -- only mov/movzx/push/pop/add/sub/imul/cmp/test/sete/je/jmp allowed (closes string-op / FPU / segment-load / exotic-encoding stack-redirect forges)"; ok=0; }
            if echo "$bdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -qiE '^(outs?b?|insb?|out|in|int|into|int3|lgdtd?|lidtd?|lldt|ltr|lmsw|hlt|iretd?|sti|cli|wrmsr|rdmsr|invlpgd?|invd|wbinvd|sysenter|syscall)\b|cr[0-9]|dr[0-9]'; then
                fail_test "$label whitebox: prologue/body contains an I/O / privileged instruction"; ok=0
            fi
            local bctl; bctl=$(echo "$bdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -iE '^(j[a-z]+|call[a-z]*|loop[a-z]*|ret[a-z]*|iret[a-z]*|int[0-9a-z]*|into|syscall|sysenter)\b')
            # Allow ONLY a direct near je/jne/jmp to a bare literal target -- END-ANCHORED ($) so a FAR
            # direct jmp `jmp 0x8:<off>` (opcode EA), which objdump -M intel prints like a near jmp on the
            # SELECTOR, is REJECTED (the far-jmp-skips-the-transition forge).
            if [[ -n "$bctl" ]] && echo "$bctl" | grep -qvE '^(je|jne|jmp) +0x[0-9a-f]+$'; then
                fail_test "$label whitebox: prologue/body has a non-direct/forbidden control transfer (indirect/far/call/int/ret)"; ok=0
            fi
            echo "$bctl" | grep -qiE ':|\bfar\b' && { fail_test "$label whitebox: prologue/body has a FAR control transfer (selector:offset) -- skips the long-mode transition"; ok=0; }
            echo "$bdis" | grep -qiE '\bret\b' && { fail_test "$label whitebox: x86 ret in the prologue/body"; ok=0; }
            # RUNTIME PAGE-TABLE MUTATION (cross-model Codex's 8th class): the page tables are RW and the
            # 32-bit body runs with write capability BEFORE paging -- a body that rewrites a PDE (e.g.
            # `mov [PD], alias|0x83`) makes the post-CR0.PG fetch come from an attacker page (static PD pins
            # still pass; runtime differs). The toakie body's ONLY memory writes are stack-relative (push;
            # pop [ebp-k]). Close every non-stack write avenue:
            #  (a) every explicit memory operand must be [ebp-0xNN] with NN <= 0xff (the local frame -- the
            #      31-local cap uses [ebp-0x4]..[ebp-0x7c]). Ban [esp...] / [ebp+...] / [ebp-bigdisp] /
            #      absolute / ds: / [reg]: a LARGE-displacement stack store reaches the code/epilogue/page-
            #      tables BELOW the stack (Codex's residual: `mov [esp-0x7fa3],0xb3` patches the epilogue's
            #      `mov bl,al` -> `mov bl,imm` at runtime, reviving the hardcode after the static scan).
            local memops; memops=$(echo "$bdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -oE '\[[^]]*\]|[cdefgs]s:0x[0-9a-f]+')
            if [[ -n "$memops" ]] && echo "$memops" | grep -qvE '^\[ebp-0x[0-9a-f]{1,2}\]$'; then
                fail_test "$label whitebox: body has a memory operand other than [ebp-0xNN] (NN<=0xff) -- a non-frame / large-displacement / absolute store can rewrite the code/epilogue/page-tables below the stack"; ok=0
            fi
            #  (a') a [ebp-0xNN] operand is only stack-local when the ebp-FRAME is set up (mov ebp,esp @5 ->
            #      ebp==esp_val). A no-local body has NO frame (bytes 5-6 != 89e5) AND no locals, so it never
            #      references [ebp-x]; a forged no-frame body doing `mov [ebp-0x4],imm32` writes wherever ebp
            #      happened to point at Multiboot handoff (UNDEFINED -- not the stack), an arbitrary store
            #      that can hit the page tables/code/epilogue (Codex round-7). Require the frame for any [ebp].
            if [[ "${chx:10:4}" != "89e5" ]] && echo "$memops" | grep -qiE '^\[ebp[-+]'; then
                fail_test "$label whitebox: body uses an [ebp-...] operand without the mov ebp,esp frame prologue (89 e5) -- ebp is unpinned (undefined at Multiboot handoff), so the access is to an arbitrary address, not the stack"; ok=0
            fi
            #  (b) esp/ebp may be written ONLY inside the prologue (mov esp,imm @0 [+ mov ebp,esp @5;
            #      sub esp,imm8 @7 when there are locals]) -- enforced by instruction OFFSET, not just opcode
            #      pattern (a forge `mov esp,PD` mid-body matches the prologue pattern; only its position
            #      distinguishes it). After the prologue, esp moves only via push/pop.
            local prologue_len=5
            if [[ "${chx:10:4}" == "89e5" ]]; then
                prologue_len=10
                # pin the EXACT ebp-frame: mov ebp,esp (89 e5) + sub esp,imm8 (83 ec NN, NN<=0x7c). Without
                # this, a forge `89 e5 81 ec <imm32>` (sub esp,imm32) at offset 7 passes the offset check and
                # drops esp onto the page tables before a push (Codex round-4).
                [[ "${chx:10:8}" == "89e583ec" && $(( 16#${chx:18:2} )) -le 124 ]] || { fail_test "$label whitebox: ebp-frame is not exactly mov ebp,esp; sub esp,imm8<=0x7c -- a large/imm32 sub esp can redirect the stack"; ok=0; }
            fi
            # esp/ebp/sp/bp may be written ONLY inside the prologue. GENERIC detector: ANY mnemonic whose
            # DESTINATION (first operand) is e?[bs]p -- so imul ebp,eax,1 / movzx bp,... / mov sp,0x3004 /
            # add esp / pop ebp are ALL caught, not an enumerated opcode list (Codex round-5: imul/movzx/
            # movsx esp-writes bypassed the old enumerated detector). Plus xchg with e?[bs]p as the 2nd
            # operand, and the implicit pusha/popa/enter/leave.
            local o; for o in $(echo "$bdis" | grep -iE $'\t[a-z][a-z0-9]* +e?[bs]p\\b|\t[a-z][a-z0-9]* +[^\t,]+,e?[bs]p\\b|\t(pushad?|popad?|enter|leave)\\b' | grep -ivE $'\t(cmp|test|push) +' | sed -E 's/^ *([0-9a-f]+):.*/\1/'); do
                [[ $(( 16#$o )) -lt "$prologue_len" ]] || { fail_test "$label whitebox: esp/ebp/sp/bp written at body offset 0x$o (>= prologue $prologue_len) -- a stack-redirect forge"; ok=0; }
            done
            # SEGMENT-register writes (mov ss,ax / pop ds / pop ss / ...) mutate hidden descriptor state the
            # transition head relies on -- never genuine in the body; ban them outright (Codex round-5).
            echo "$bdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -qiE '^(mov|pop|lds|les|lfs|lgs|lss) +(cs|ds|es|ss|fs|gs)\b' && { fail_test "$label whitebox: body writes a segment register -- mutates hidden state the transition relies on"; ok=0; }
            #  (c) bound the body size: with only push/pop (-/+4) the stack (16 KiB) sits just above the
            #      tables, so a push-run long enough to walk esp into them needs a body far larger than any
            #      genuine toakie probe (the 31-local cap is ~262 bytes).
            [[ "$body_end" -lt 2048 ]] || { fail_test "$label whitebox: body is $body_end bytes (>=2048) -- a push run could walk esp into the low page tables"; ok=0; }
            # REACHABILITY: scanned from offset 0, every direct near-branch target is an instruction boundary
            # <= the stash. A prefix `jmp <forge blob>` (target >> the stash) and a forward jump into the
            # head/observable are both rejected here.
            local baddrs; baddrs=$(echo "$bdis" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
            # Branch targets must be (1) FORWARD/strict, (2) an instruction boundary, (3) <= the stash.
            # FORWARD-ONLY mirrors the compiler's own PASS-B depth gate nc32_check_branches (Codex C1):
            # "every branch must target strictly forward (forbids loops/back-edges structurally)". A
            # backward/self branch (jne .loop) would let a tiny body LOOP a push thousands of times,
            # walking esp DOWN into the page tables despite the <2048-byte body bound -- the linear bound
            # only holds without back-edges (Codex round 6). The genuine toakie lowering never emits one
            # (the compiler rejects t<=i), so forward-only false-rejects nothing real.
            local bl baddr_hex btgt_hex baddr_n btgt_n
            while IFS= read -r bl; do
                [[ -n "$bl" ]] || continue
                baddr_hex=$(echo "$bl" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
                btgt_hex=$(echo "$bl" | grep -oE '0x[0-9a-f]+$' | sed -E 's/^0x//')
                [[ -n "$baddr_hex" && -n "$btgt_hex" ]] || continue
                baddr_n=$(( 16#${baddr_hex} )); btgt_n=$(( 16#${btgt_hex} ))
                [[ "$btgt_n" -gt "$baddr_n" ]] || { fail_test "$label whitebox: backward/self branch at 0x${baddr_hex} -> 0x${btgt_hex} (loop forge: a back-edge can repeat a push and walk esp into the page tables past the <2048-byte bound; genuine lowering is strictly forward)"; ok=0; }
                if [[ "$btgt_n" -ne "$body_end" ]]; then
                    echo "$baddrs" | grep -qiE "^0*${btgt_hex}$" || { fail_test "$label whitebox: branch target 0x${btgt_hex} not an instruction boundary (mid-instruction jump forge)"; ok=0; }
                fi
                [[ "$btgt_n" -le "$body_end" ]] || { fail_test "$label whitebox: branch target 0x${btgt_hex} jumps past the body ($body_end) into the head/observable or an appended forge blob"; ok=0; }
            done < <(echo "$bdis" | grep -iE $'\t(je|jne|jmp) +0x[0-9a-f]+$')
        fi
    fi
    # (8) branching probes must contain a real je (0F 84).
    if is_branching "$label"; then
        echo "$chx" | grep -q '0f84' || { fail_test "$label whitebox: branching probe has no je (0F 84)"; ok=0; }
    fi
    [[ "$ok" -eq 1 ]]
}

qemu_run() { # label v elf
    local label="$1" v="$2" elf="$3"
    local p ex ph; p=$(host_proof "$v"); ex=$(host_qemu_exit "$p"); ph=$(printf '%02x' "$p")
    local W="$tmp/$label.q"; mkdir -p "$W"
    printf "\\xde\\x${ph}\\xad" > "$W/golden_frame.bin"
    timeout 60 qemu-system-x86_64 -kernel "$elf" \
        -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M
    local rc=$?
    local nframes; nframes=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n' | grep -o "de${ph}ad" | wc -l | tr -d ' ')
    if [[ "$rc" -eq "$ex" ]] && cmp -s "$W/e9.bin" "$W/golden_frame.bin" && [[ "$nframes" -eq 1 ]]; then
        return 0
    fi
    fail_test "$label QEMU: exit=$rc(want $ex) e9=$(xxd -p "$W/e9.bin" 2>/dev/null) want=de${ph}ad nframes=$nframes"
    return 1
}

bochs_run() { # label v elf
    local label="$1" v="$2" elf="$3"
    local p ph; p=$(host_proof "$v"); ph=$(printf '%02x' "$p")
    local W="$tmp/$label.b"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS files missing"; return 1; fi
    ( cd "$W"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$elf" mnt/boot/kernel.elf
      printf 'set timeout=0\nset default=0\nmenuentry "s" {\n multiboot /boot/kernel.elf\n boot\n}\n' \
          | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot \
          --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 60 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1
    )
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nframes shutdown
    nframes=$(grep -o "de${ph}ad" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    shutdown=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null)
    if [[ "$nframes" -eq 1 ]] && [[ "$shutdown" -ge 1 ]]; then
        return 0
    fi
    fail_test "$label Bochs: frames(de${ph}ad)=$nframes shutdown-evidence=$shutdown"
    return 1
}

reject_probe() { # label "<herbert program>"
    local label="$1" prog="$2"
    local cdir="$tmp/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "-- emit: multiboot32-long\n%b\n" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset body emitted a valid multiboot image"; return 1
    fi
    return 0
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu-system-x86_64 not found)"; exit 1
    fi
    echo "SKIP: native-codegen link25 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
fi

run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1
fi

for label in $ALL_PROBES; do
    elf="$tmp/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    whitebox_gates "$label" "$elf" || continue
    if ! have_qemu; then pass=$((pass + 1)); continue; fi
    v=$(prog_v "$label")
    if qemu_run "$label" "$v" "$elf"; then
        bochs_ok=1
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
            bochs_run "$label" "$v" "$elf" || bochs_ok=0
        fi
        [[ "$bochs_ok" -eq 1 ]] && pass=$((pass + 1))
    fi
done

reject_probe divmod      'func main(): let x = 6  return x % 4 end'
reject_probe divmod_twin 'func main(): let z = 8  return z / 3 end'
reject_probe bitor       'func main(): let x = 6  return x | 1 end'
reject_probe bitor_twin  'func main(): let w = 5  return w & 3 end'
reject_probe call        'func h(): return 2 end\nfunc main(): return h()+1 end'
reject_probe call_twin   'func g(): return 4 end\nfunc main(): return g()+9 end'
reject_probe lt          'func main(): let x = 6  if x < 5: return 1 else: return 2 end end'
reject_probe lt_twin     'func main(): let q = 9  if q < 2: return 7 else: return 8 end end'
reject_probe mainarg     'func main(p): return p+1 end'
reject_probe mainarg_twin 'func main(k): return k-1 end'
reject_probe boolcond    'func main(): if true: return 1 else: return 2 end end'
reject_probe boolcond_twin 'func main(): if false: return 8 else: return 9 end end'
reject_probe maxlocals      "$(gen_locals 32 a)"
reject_probe maxlocals_twin "$(gen_locals 32 z)"
[[ "$fail" -eq 0 ]] && pass=$((pass + 14))

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then
    echo "$fail native-codegen-link25 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link25 / hoopteeter / ninth kernel-arc link: freestanding 32-bit Multiboot image crosses into 64-bit LONG MODE and emits a proof byte = high dword of (V*0x10001) that is 64-bit-distinguishing for each non-degenerate probe [the gate asserts golden != the 32-bit-compat fallback per probe -- e.g. V=0x80000002 is rejected]; the compiled body computes V in 32-bit, stashes it in esi across the mode switch, and a REX.W observable extracts the high dword in genuine 64-bit; $pass checks: static + white-box (exact 56-byte transition head [CR4.PAE; CR3; EFER.LME; CR0.PG; ljmp 0x08] exactly-once, exact 16-byte REX.W observable exactly-once, the observable->epilogue proof-byte DATA-FLOW pinned as one exact 74-byte run [the emitted byte IS the 64-bit shr output, not a hardcoded constant], GDT 64-bit code descriptor L=1 exactly-once + NO other code descriptor [L=0 banned by mask] + GDTR-base bound to the located GDT [selector 0x08 resolves to L=1], the FULL page-walk bound BY VALUE at derived vaddrs [CR3==PML4; PML4[0]==PDPT|3 hi0 + PML4[1..511]==0; PDPT[0]==PD|3 hi0 + PDPT[1..511]==0; all 512 PDEs==i*0x200000+0x83 hi0 -- so virtual 0x10000c maps to physical 0x10000c, no PDE alias to a hidden page; lgdt==GDTR], ljmp-target == long_entry, the ENTRY+LOAD frame bound so the SCANNED bytes are the bytes that RUN [e_entry==0x10000c, code begins with mov esp, the REAL phdr walked from e_phoff -- exactly one PT_LOAD (e_phoff/phentsize/phnum==52/32/1) mapping file 0x100c->0x10000c, p_offset/p_vaddr/p_paddr/filesz/memsz all pinned exactly, and EXACTLY ONE checksum-valid Multiboot header pinned to 0x1000/flags0/0xE4524FFE], the whole reachable path [prologue+body from offset 0 .. stash] a 16-mnemonic WHITELIST free of I/O+privileged + DIRECT-NEAR STRICTLY-FORWARD control-only [far/indirect/back-edge banned, targets<=stash], stack-only writes [memops only [ebp-0xNN] with the 89e5 frame; esp/ebp/sp/bp written only by the pinned prologue via a generic dest detector; no segment write; body<2048], single 0xE9 emit path, real je on branching probes -- the 7 completeness-critic forge classes PLUS the cross-model Codex loader/CPU-redirect meta-class [runtime page-table mutation, phdr-shape, no-frame [ebp], leaf-PDE alias+blob, Multiboot decoy] all closed across a 10-round hunt), QEMU substrate (5 probes: then + else + literal + no-locals + 31-local cap, result-dependent exit), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 14 out-of-subset rejects with twins incl. the 32-local cap (ERR 495); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
