#!/usr/bin/env bash
# Native codegen Link 26 (toggler, the TENTH kernel-arc link): the x86-64 BACKEND REUNIFICATION.
# The freestanding image crosses into 64-bit LONG MODE and runs a GENUINELY 64-bit COMPILED body --
# the compiled main() body is lowered through the SAME near-axis 64-bit leaf emitters the Linux-ELF64
# path uses (nc_emit_push_int/add/sub/mul -- REX.W 0x48), AFTER long_entry, so the proof byte =
# HIGH dword of the body's OWN 64-bit result (a multiply whose product exceeds 2^32 -- WRONG under
# 32-bit-width arithmetic). Unlike hoopteeter (multiboot32-long), the proof byte does NOT come from a
# canned 16-byte observable: it flows from NORMAL 64-bit lowering of the source (the anti-ceremony
# guard, now structural). Minimal slice -- straight-line arithmetic {PUSH_INT, ADD, SUB, MUL, RET},
# single main(), no params/locals/branches (64-bit locals/branches widen a later link); with no
# branches there are no body rel32s, so no layout pass (emit the body, then measure).
#
# Image (vaddr V0=0x10000c): [56-byte transition head -> ljmp 0x08:long_entry @ V0+56]
#   [@long_entry (64-bit): mov esp,esp_val (bc imm32 -- in 64-bit mode this ZERO-EXTENDS rsp, the one
#   extra instruction long mode needs because the 32-bit handoff leaves rsp[63:32] UNDEFINED; an
#   omitted/wrong one #PFs outside the low-1-GiB map -> triple-fault)] [the compiled body lowered via
#   the near-axis 64-bit leaves -- ...; pop rax (RET, leaves V in rax)] [shr rax,0x20 -- grading tail:
#   the body's HIGH dword into al] [shared 58-byte epilogue: frame 0xDE<byte>0xAD on 0xE9 +
#   result-dependent isa-debug-exit + Shutdown + cli;hlt] [GDT/GDTR 30][pad to 4 KiB][PML4][PDPT][PD].
# Reuses hoopteeter's transition head / GDT (L=1) / PAE tables and lingo's ehdr/phdr/mbheader + the
# shared epilogue verbatim, so the nine prior emit modes are byte-identical (fixpoint preserved).
#
# Graded, like lingo..hoopteeter, on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs+GRUB vs a
# HOST-derived golden), NOT C. Pays D19's long-mode lowering remainder (a genuinely 64-bit COMPILED
# body, not just the entry transition).
#
# Selected by the anchored first-line directive "-- emit: multiboot32-long64" (a TENTH emit mode; the
# nine prior modes -- multiboot32, -idt, -page, -store, -demand, -timer, -tick, -long, and default
# ELF64 -- are byte-identical, so the native self-host fixpoint gen2==gen1 is preserved).
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; EXACTLY ONE checksum-valid Multiboot header
#     (0x1000/flags0/0xE4524FFE) among all 4-aligned candidates in the first 8 KiB; ZERO syscall
#     escapes (0F05 / CD80 / 0F34) in the code window (bounded by the epilogue terminal faf4ebfd).
#   WHITE-BOX (per probe; the runtime byte alone is forgeable -- a hardcoded mov, a 32-bit-width body,
#   or a compat-mode (L=0) run would also produce a byte -- so prove the STRUCTURE; the proof byte now
#   flows from the VARIABLE lowered body, so the gate proves "the byte IS the genuine 64-bit body's
#   high dword", not exact observable bytes):
#     - THE EXACT 56-BYTE TRANSITION HEAD at code offset 0, EXACTLY ONCE (only gdtr/pml4/long_entry
#       le32 vary): cli; lgdt; CR4=0x20 (PAE); CR3=PML4; EFER.LME; CR0.PG; ljmp 0x08. (Code BEGINS with
#       the head -- e_entry -> the transition; there is no 32-bit body before it.)
#     - THE ljmp TARGET == long_entry == V0+56 (REACHABILITY): the 64-bit region is reached ONLY via
#       the mode-switching far-jmp (a mistargeted/nop'd ljmp falls through in 32-bit -> the body's
#       REX.W bytes decode wrong -> != golden).
#     - mov esp,esp_val (bc imm32) EXACTLY ONCE immediately after the head, with esp_val bound BY VALUE
#       to the derived stack top (load_end + 0x4000) -- the rsp zero-extension, pinned.
#     - THE 64-BIT BODY [code offset 61 .. the grading tail]: PINNED to the EXACT genuine 64-bit
#       lowering of THIS probe's source (the provenance pin -- so the proof byte provably flows from
#       the intended lowered expression, not from a forged/mutated body that reaches a nonzero high
#       dword some other way, e.g. a 64-bit literal or a dead imul), AND a 64-bit instruction WHITELIST
#       {movabs/mov, push, pop, imul, add, sub} with rax/rcx ONLY -- ANY 32-bit GPR (eax/ecx/...) is
#       REJECTED, which pins REX.W on every arithmetic op (drop a 0x48 -> 32-bit-width -> high dword
#       empties -> wrong byte). No I/O, no privileged, no branch/call/indirect/far/ret, no segment
#       write, no memory operand (straight-line register/stack arithmetic only).
#     - THE PROOF-BYTE DATA-FLOW, EXACTLY ONCE: the contiguous run 58 48 c1 e8 20 88 c3 (pop rax [the
#       RET -> body result in rax]; shr rax,0x20 [high dword into al]; mov bl,al [frame it]) -- so the
#       emitted byte IS the lowered body's high dword, with NOTHING between the body result and the
#       frame (closes the hardcode/overwrite forge).
#     - THE GDT 64-bit CODE descriptor 0x00AF9A000000FFFF (L=1) EXACTLY ONCE, NO non-L=1 code
#       descriptor, data descriptor + GDTR.limit=0x17, GDTR base bound to the located GDT.
#     - THE PAE TABLES FULLY BOUND BY VALUE at derived vaddrs (CR3==PML4; PML4[0]==PDPT|3 hi0 +
#       1..511==0; PDPT[0]==PD|3 hi0 + 1..511==0; all 512 PDEs==i*0x200000+0x83 hi0) -- virtual
#       0x10000c maps to physical 0x10000c, no alias.
#     - THE ENTRY+LOAD FRAME so the SCANNED bytes ARE the bytes that RUN: e_entry==0x10000c; e_phoff/
#       phentsize/phnum==52/32/1 (exactly one PT_LOAD) mapping file 0x100c -> vaddr 0x10000c;
#       p_offset/p_vaddr/p_paddr/filesz/memsz pinned.
#     - golden byte = (V >> 32) & 0xff is NONZERO (a dropped/zeroed 64-bit body gives 0x00 -> RED) and
#       the SINGLE emit path (mov dx,0x00E9 = 66 ba e9 00) appears EXACTLY ONCE.
#   RUNTIME (per probe, both substrates): QEMU result-dependent isa-debug-exit + one host-golden e9
#     frame; Bochs one host-golden frame + clean-shutdown evidence.
#   PROBE VECTORS: mul_add + mul_big + mul_add2 + mul_sub (mul/add/sub, distinct nonzero high-dword
#     bytes 0x01/0xE8/0xE9/0xD1, each a product exceeding 2^32 so the byte is 64-bit-only).
#   REJECTS (+ twins): out-of-(64-bit-)subset bodies (div/mod, bitwise, 2-function call, parameterised
#     main) emit NO valid image (ERR 500/501/502). The locals + if/else-branch rejects were RETIRED at
#     native-codegen link29 (trikea / f2), which deliberately WIDENS the multiboot32-long64 subset to
#     admit them; they are now ACCEPTED probes in run_native_codegen_link29.sh.
#
# Honest scope: proves "crosses into 64-bit long mode and runs a COMPILED body whose proof byte is the
# 64-bit-only high dword of the body's own result, as a freestanding Multiboot image under QEMU +
# Bochs+GRUB," NOT real silicon, arbitrary emulator versions, 64-bit locals/branches (a later link),
# or MMIO. The exact transition bytes are pinned WHITE-BOX; what IS silicon-proven (mutation harness):
# dropping the body's REX.W, the mov-esp zero-extension, the grading shr, or the long-mode transition
# each makes the golden byte vanish or change. The dual-substrate + host golden replaces absent C.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L10_BOCHS_PROBES:-mul_add mul_big}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

# toggler proof byte = high dword of the body result V: (V >> 32) & 0xff.
host_proof() { echo $(( ( $1 >> 32 ) & 0xff )); }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

prog_src() { # label -> herbert source (straight-line 64-bit arithmetic; product exceeds 2^32)
    case "$1" in
      mul_add)  echo 'func main(): return 70000 * 70000 + 126 end' ;;
      mul_big)  echo 'func main(): return 1000000 * 1000000 end' ;;
      mul_add2) echo 'func main(): return 1000000 * 1000000 + 5000000000 end' ;;
      mul_sub)  echo 'func main(): return 2000000 * 1000000 - 1 end' ;;
    esac
}
prog_v() { # label -> the body's u64 result V (proof byte = high dword of V)
    case "$1" in
      mul_add)  echo $(( 70000 * 70000 + 126 )) ;;
      mul_big)  echo $(( 1000000 * 1000000 )) ;;
      mul_add2) echo $(( 1000000 * 1000000 + 5000000000 )) ;;
      mul_sub)  echo $(( 2000000 * 1000000 - 1 )) ;;
    esac
}
has_mul() { return 0; }   # every probe contains a multiply
ALL_PROBES="mul_add mul_big mul_add2 mul_sub"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-long64\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }
le32_at() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }
# The EXPECTED genuine 64-bit lowering of each probe's body (the provenance pin -- closes the
# cross-model concern that "REX.W imul present" alone does not prove the byte came from the genuine
# lowering: pin the EXACT lowered bytes the near-axis leaf emitters produce for each probe's source,
# so a forged/mutated body that reaches the high-dword byte some other way is rejected).
le64() { printf '%016x' "$1" | sed -E 's/(..)(..)(..)(..)(..)(..)(..)(..)/\8\7\6\5\4\3\2\1/'; }
pi() { echo "48b8$(le64 "$1")50"; }    # PUSH_INT n -> movabs rax,imm64 (48 B8 imm64); push rax (50)
M_MUL='5958480fafc150'                  # pop rcx; pop rax; REX.W imul rax,rcx; push rax
M_ADD='59584801c850'; M_SUB='59584829c850'; M_RET='58'   # REX.W add/sub rax,rcx; RET -> pop rax
expected_body() { case "$1" in
  mul_add)  echo "$(pi 70000)$(pi 70000)${M_MUL}$(pi 126)${M_ADD}${M_RET}" ;;
  mul_big)  echo "$(pi 1000000)$(pi 1000000)${M_MUL}${M_RET}" ;;
  mul_add2) echo "$(pi 1000000)$(pi 1000000)${M_MUL}$(pi 5000000000)${M_ADD}${M_RET}" ;;
  mul_sub)  echo "$(pi 2000000)$(pi 1000000)${M_MUL}$(pi 1)${M_SUB}${M_RET}" ;;
esac; }

static_gates() { # label elf  (reused from link25 verbatim: MB-header validation + syscall-free)
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx; hx=$(xxd -p "$elf" | tr -d '\n')
    local mb_o mb_valid_count=0 mb_valid_off=-1 mb_valid_flags=-1 mb_valid_csum=0 mb_f mb_c
    for (( mb_o=0; mb_o+12 <= 8192 && mb_o*2+24 <= ${#hx}; mb_o+=4 )); do
        [[ "${hx:$(( mb_o*2 )):8}" == "02b0ad1b" ]] || continue
        mb_f=$(le32_at "$hx" $(( mb_o*2 + 8 ))); mb_c=$(le32_at "$hx" $(( mb_o*2 + 16 )))
        if [[ $(( (16#1BADB002 + mb_f + mb_c) % (1 << 32) )) -eq 0 ]]; then
            mb_valid_count=$(( mb_valid_count + 1 )); mb_valid_off=$mb_o; mb_valid_flags=$mb_f; mb_valid_csum=$mb_c
        fi
    done
    [[ "$mb_valid_count" -eq 1 ]] || { fail_test "$label static: $mb_valid_count checksum-valid Multiboot headers (want 1)"; ok=0; }
    [[ "$mb_valid_off" -eq 4096 && "$mb_valid_flags" -eq 0 && "$mb_valid_csum" -eq $(( 16#E4524FFE )) ]] || { fail_test "$label static: valid MB header not the genuine shape (off=$mb_valid_off flags=$mb_valid_flags csum=$mb_valid_csum)"; ok=0; }
    local code="$tmp/$label.code"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    local term="${chx%%faf4ebfd*}"
    if [[ "$term" == "$chx" ]]; then fail_test "$label static: epilogue terminal absent"; return 1; fi
    local endbytes=$(( ${#term} / 2 + 4 ))
    dd if="$code" of="$code.t" bs=1 count="$endbytes" status=none 2>/dev/null
    local cth; cth=$(xxd -p "$code.t" | tr -d '\n')
    echo "$cth" | grep -q '0f05' && { fail_test "$label static: 0F 05 (syscall) present"; ok=0; }
    echo "$cth" | grep -q 'cd80' && { fail_test "$label static: CD 80 present"; ok=0; }
    echo "$cth" | grep -q '0f34' && { fail_test "$label static: 0F 34 present"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    local vv; vv=$(prog_v "$label")
    local pb; pb=$(host_proof "$vv")
    # (0) golden byte NONZERO: a dropped/zeroed 64-bit body gives high dword 0x00; require nonzero so
    #     "the body ran and produced a >2^32 result" is observable on the byte itself.
    [[ "$pb" -ne 0 ]] || { fail_test "$label whitebox: golden byte is 0x00 (probe V=$vv has zero high dword -- not 64-bit-distinguishing)"; ok=0; }
    # (1) CODE BEGINS with the 56-byte transition head (e_entry -> the transition; no 32-bit body
    #     before it). Exact head, EXACTLY ONCE (only gdtr/pml4/long_entry le32 vary).
    local head='fa0f0115[0-9a-f]{8}b8200000000f22e0b8[0-9a-f]{8}0f22d8b9800000c00f320d000100000f300f20c00d000000800f22c0ea[0-9a-f]{8}0800'
    [[ "${chx:0:8}" == "fa0f0115" ]] || { fail_test "$label whitebox: code does not begin with the transition head (cli;lgdt) -- e_entry is not the transition"; ok=0; }
    [[ "$(occ "$chx" "$head")" == 1 ]] || { fail_test "$label whitebox: exact 56-byte transition head not present exactly once"; ok=0; }
    # (2) GDT 64-bit code descriptor L=1 EXACTLY ONCE, NO non-L=1 code descriptor, data desc + limit.
    [[ "$(occ "$chx" 'ffff0000009aaf00')" == 1 ]] || { fail_test "$label whitebox: 64-bit code descriptor (L=1) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" 'ffff0000009a..00')" == 1 ]] || { fail_test "$label whitebox: a code descriptor with non-L=1 flags exists (compat-mode forge)"; ok=0; }
    [[ "$(occ "$chx" 'ffff00000092af001700')" == 1 ]] || { fail_test "$label whitebox: data descriptor + GDTR limit 0x17 not present exactly once"; ok=0; }
    # derive the emitter layout from the L=1 descriptor position (the GDT null entry is 8 bytes before it)
    local l1_pos gdt_vaddr pml4_vaddr pdpt_vaddr pd_vaddr load_end esp_top
    l1_pos=$(echo "$chx" | grep -bo 'ffff0000009aaf00' | head -1 | cut -d: -f1)
    gdt_vaddr=$(( 1048588 + l1_pos / 2 - 8 ))
    pml4_vaddr=$(( (gdt_vaddr + 30 + 4095) / 4096 * 4096 ))
    pdpt_vaddr=$(( pml4_vaddr + 4096 )); pd_vaddr=$(( pdpt_vaddr + 4096 )); load_end=$(( pd_vaddr + 4096 ))
    esp_top=$(( load_end + 16384 ))
    # (2b) GDTR base bound to the located GDT.
    local gdtr_pos gdtr_base; gdtr_pos=$(echo "$chx" | grep -bo 'ffff00000092af001700' | head -1 | cut -d: -f1)
    gdtr_base=$(le32_at "$chx" $(( gdtr_pos + 20 )))
    [[ "$gdtr_base" -eq "$gdt_vaddr" ]] || { fail_test "$label whitebox: GDTR base ($gdtr_base) != located GDT vaddr ($gdt_vaddr)"; ok=0; }
    # (3) PAE chain bound by value (reused from link25): PD[0]/PD[1] present, PML4/PDPT entry0 + rest 0,
    #     all 512 PDEs == i*0x200000+0x83 hi0 at pd_vaddr -- virtual 0x10000c -> physical 0x10000c.
    [[ "$(occ "$chx" '8300000000000000')" == 1 ]] || { fail_test "$label whitebox: PD[0]=0x83 not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '8300200000000000')" == 1 ]] || { fail_test "$label whitebox: PD[1]=0x200083 not present exactly once"; ok=0; }
    local tbl tname t0want toff thi tlo tbad
    for tbl in pml4 pdpt; do
        if [[ "$tbl" == "pml4" ]]; then toff=$(( (pml4_vaddr - 1048588) * 2 )); t0want=$(( pdpt_vaddr + 3 )); tname="PML4"
        else toff=$(( (pdpt_vaddr - 1048588) * 2 )); t0want=$(( pd_vaddr + 3 )); tname="PDPT"; fi
        local thex="${chx:$toff:8192}" te_i tbad=""
        for (( te_i=0; te_i<512; te_i++ )); do
            tlo=$(le32_at "$thex" $(( te_i * 16 ))); thi="${thex:$(( te_i * 16 + 8 )):8}"
            if [[ "$te_i" -eq 0 ]]; then
                [[ "$tlo" -eq "$t0want" && "$thi" == "00000000" ]] || { tbad="${tname}[0] lo=$tlo hi=$thi"; break; }
            else
                [[ "$tlo" -eq 0 && "$thi" == "00000000" ]] || { tbad="${tname}[$te_i] lo=$tlo hi=$thi"; break; }
            fi
        done
        [[ -z "$tbad" ]] || { fail_test "$label whitebox: $tname not [entry0=next|3, rest 0] [$tbad]"; ok=0; }
    done
    local pd_hex="${chx:$(( (pd_vaddr - 1048588) * 2 )):8192}" pde_i pde_lo pde_hi pde_bad=""
    for (( pde_i=0; pde_i<512; pde_i++ )); do
        pde_lo=$(le32_at "$pd_hex" $(( pde_i * 16 ))); pde_hi="${pd_hex:$(( pde_i * 16 + 8 )):8}"
        if [[ "$pde_lo" -ne $(( pde_i * 2097152 + 131 )) || "$pde_hi" != "00000000" ]]; then pde_bad="PDE[$pde_i] lo=$pde_lo hi=$pde_hi"; break; fi
    done
    [[ -z "$pde_bad" ]] || { fail_test "$label whitebox: leaf PD not the 512-entry low-1-GiB identity map [$pde_bad]"; ok=0; }
    # (4) single emit path.
    [[ "$(occ "$chx" '66bae900')" == 1 ]] || { fail_test "$label whitebox: the 0xE9 frame-emit not present exactly once"; ok=0; }
    # (5) REACHABILITY: ljmp target == long_entry == V0+56; mov esp,esp_val (bc) right after the head,
    #     EXACTLY ONCE, esp_val bound to the derived stack top.
    [[ "$(occ "$chx" '0f22c0ea')" == 1 ]] || { fail_test "$label whitebox: mov-cr0+ljmp anchor (0f22c0ea) not present exactly once"; ok=0; }
    local cr0jmp_pos ljmp_target; cr0jmp_pos=$(echo "$chx" | grep -bo '0f22c0ea' | head -1 | cut -d: -f1)
    ljmp_target=$(le32_at "$chx" $(( cr0jmp_pos + 8 )))
    [[ "$ljmp_target" -eq $(( 1048588 + 56 )) ]] || { fail_test "$label whitebox: ljmp target ($ljmp_target) != long_entry (V0+56 = $(( 1048588 + 56 )))"; ok=0; }
    # the head is exactly 56 bytes, so the mov esp begins at code offset 56 (hex offset 112).
    [[ "${chx:112:2}" == "bc" ]] || { fail_test "$label whitebox: no mov esp,imm32 (bc) at long_entry (offset 56)"; ok=0; }
    local esp_imm; esp_imm=$(le32_at "$chx" 114)
    [[ "$esp_imm" -eq "$esp_top" ]] || { fail_test "$label whitebox: mov esp imm ($esp_imm) != derived stack top ($esp_top) -- rsp not set to the reserved stack"; ok=0; }
    # (6) THE 64-BIT BODY [offset 61 .. the grading tail]. The grading tail (shr rax,0x20 = 48 c1 e8 20)
    #     sits immediately before the epilogue (mov bl,al = 88 c3): the contiguous run 58 48c1e820 88c3
    #     (RET pop rax; shr; frame) pins the proof-byte data-flow EXACTLY ONCE.
    [[ "$(occ "$chx" '5848c1e82088c3')" == 1 ]] || { fail_test "$label whitebox: the body-result data-flow (pop rax; shr rax,0x20; mov bl,al) not present exactly once -- the emitted byte may not be the 64-bit body's high dword"; ok=0; }
    local gt_pos body_start body_end; gt_pos=$(echo "$chx" | grep -bo '48c1e82088c3' | head -1 | cut -d: -f1)
    body_start=$(( 61 )); body_end=$(( gt_pos / 2 ))   # body = [after mov esp .. the grading tail); includes the RET's pop rax (the 58 just before 48c1e820)
    if [[ "$body_end" -le "$body_start" ]]; then fail_test "$label whitebox: empty/invalid body region"; ok=0; fi
    # (6a) PROVENANCE PIN (closes the cross-model concern): the body bytes must be EXACTLY the genuine
    #      64-bit lowering of THIS probe's source, and end precisely at the grading tail. So the proof
    #      byte provably flows from the intended lowered expression (the >2^32 product), not from a
    #      forged/mutated body that reaches a nonzero high dword some other way (a 64-bit literal, a
    #      dead imul, etc.). A wrong body -> mismatch here, even if it boots to the golden byte.
    local want_body; want_body=$(expected_body "$label")
    [[ "${chx:$(( body_start * 2 )):${#want_body}}" == "$want_body" ]] || { fail_test "$label whitebox: body bytes are not the expected genuine 64-bit lowering of the source (provenance) -- got ${chx:$(( body_start * 2 )):60}... want ${want_body:0:60}..."; ok=0; }
    [[ $(( body_start * 2 + ${#want_body} )) -eq "$gt_pos" ]] || { fail_test "$label whitebox: the expected body (${#want_body} hex) does not end exactly at the grading tail ($gt_pos) -- extra/short bytes between body and grading tail"; ok=0; }
    dd if="$code" of="$code.body" bs=1 skip="$body_start" count=$(( body_end - body_start )) status=none 2>/dev/null
    # field 3 (tab-separated) is the mnemonic+operands; NF>=3 drops byte-only continuation lines.
    local bmnem; bmnem=$(objdump -D -b binary -m i386:x86-64 -M intel "$code.body" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
    # WHITELIST: only 64-bit straight-line arithmetic. movabs (mov rax,imm64), push, pop, imul, add, sub.
    local bad; bad=$(echo "$bmnem" | awk '{print $1}' | grep -ivE '^(movabs|mov|push|pop|imul|add|sub)$' | sort -u | tr '\n' ' ')
    [[ -z "${bad// /}" ]] || { fail_test "$label whitebox: body uses non-subset instruction(s) [$bad] -- only 64-bit movabs/push/pop/imul/add/sub allowed"; ok=0; }
    # REX.W pin: the 64-bit body touches ONLY rax/rcx. Any 32-bit GPR operand (eax/ecx/...) means a
    #     REX.W (0x48) was dropped -> 32-bit-width arithmetic -> the high dword empties.
    if echo "$bmnem" | grep -qiE '\b(eax|ebx|ecx|edx|esi|edi|esp|ebp)\b'; then
        fail_test "$label whitebox: body has a 32-bit GPR operand (REX.W dropped) -- arithmetic is not 64-bit-width"; ok=0
    fi
    # no privileged / I/O / control-flow / segment / memory operand in the body (straight-line regs only)
    if echo "$bmnem" | grep -qiE '^(out|in|int|hlt|iret|syscall|sysenter|wrmsr|rdmsr|lgdt|lidt|cli|sti|j[a-z]+|call|ret|loop|jmp|lea|mov[sz]|stos|movs|scas)\b|\[|cr[0-9]|\b(cs|ds|es|ss|fs|gs)\b'; then
        fail_test "$label whitebox: body contains an I/O/privileged/control-flow/memory/segment instruction"; ok=0
    fi
    # the forcing MUL is a REX.W imul (48 0F AF C1) present in the body.
    echo "${chx:$(( body_start*2 )):$(( (body_end-body_start)*2 ))}" | grep -q '480fafc1' || { fail_test "$label whitebox: no REX.W imul (48 0F AF C1) in the body -- the 64-bit multiply is missing"; ok=0; }
    # (7) ENTRY + LOAD FRAME (reused from link25): e_entry==0x10000c; exactly one PT_LOAD mapping file
    #     0x100c -> vaddr 0x10000c; phdr shape + sizes pinned, so the SCANNED bytes are the bytes that RUN.
    local eentry; eentry=$(dd if="$elf" bs=1 skip=24 count=4 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$eentry" == "0c001000" ]] || { fail_test "$label whitebox: e_entry (0x$eentry) != 0x0010000c"; ok=0; }
    local e_phoff e_phentsize e_phnum nload ml_off=-1 ml_vaddr ml_paddr ml_fsz ml_msz i base ptype poff pvaddr ppaddr pfsz pmsz pesz_h pnum_h
    e_phoff=$(le32_at "$(dd if="$elf" bs=1 skip=28 count=4 status=none 2>/dev/null | xxd -p)" 0)
    pesz_h=$(dd if="$elf" bs=1 skip=42 count=2 status=none 2>/dev/null | xxd -p); e_phentsize=$(( 16#${pesz_h:2:2}${pesz_h:0:2} ))
    pnum_h=$(dd if="$elf" bs=1 skip=44 count=2 status=none 2>/dev/null | xxd -p); e_phnum=$(( 16#${pnum_h:2:2}${pnum_h:0:2} ))
    [[ "$e_phoff" -eq 52 && "$e_phentsize" -eq 32 && "$e_phnum" -eq 1 ]] || { fail_test "$label whitebox: phdr table not genuine shape (phoff=$e_phoff entsize=$e_phentsize num=$e_phnum)"; ok=0; }
    nload=0; i=0
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
    [[ "$nload" -eq 1 ]] || { fail_test "$label whitebox: $nload PT_LOAD segments (want 1)"; ok=0; }
    if [[ "$ml_off" -lt 0 ]]; then fail_test "$label whitebox: no PT_LOAD covers file 0x100c"; ok=0
    else
        [[ "$(( ml_vaddr + 4108 - ml_off ))" -eq 1048588 ]] || { fail_test "$label whitebox: PT_LOAD maps file 0x100c to vaddr $(( ml_vaddr + 4108 - ml_off )) != 0x10000c"; ok=0; }
        [[ "$ml_paddr" -eq "$ml_vaddr" ]] || { fail_test "$label whitebox: p_paddr ($ml_paddr) != p_vaddr ($ml_vaddr)"; ok=0; }
        [[ "$ml_fsz" -eq $(( pd_vaddr + 4096 - 1048576 )) ]] || { fail_test "$label whitebox: p_filesz ($ml_fsz) != derived load span ($(( pd_vaddr + 4096 - 1048576 )))"; ok=0; }
        [[ "$ml_msz" -eq $(( ml_fsz + 16384 )) ]] || { fail_test "$label whitebox: p_memsz ($ml_msz) != filesz + 16 KiB ($(( ml_fsz + 16384 )))"; ok=0; }
        [[ "$ml_off" -eq 4096 && "$ml_vaddr" -eq 1048576 ]] || { fail_test "$label whitebox: PT_LOAD base ($ml_off/$ml_vaddr) != 0x1000/0x100000"; ok=0; }
    fi
    [[ "$ok" -eq 1 ]]
}

qemu_run() { # label v elf
    local label="$1" v="$2" elf="$3"
    local p ex ph; p=$(host_proof "$v"); ex=$(host_qemu_exit "$p"); ph=$(printf '%02x' "$p")
    local W="$tmp/$label.q"; mkdir -p "$W"
    printf "\\xde\\x${ph}\\xad" > "$W/golden_frame.bin"
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M
    local rc=$?
    local nframes; nframes=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n' | grep -o "de${ph}ad" | wc -l | tr -d ' ')
    if [[ "$rc" -eq "$ex" ]] && cmp -s "$W/e9.bin" "$W/golden_frame.bin" && [[ "$nframes" -eq 1 ]]; then return 0; fi
    fail_test "$label QEMU: exit=$rc(want $ex) e9=$(xxd -p "$W/e9.bin" 2>/dev/null) want=de${ph}ad nframes=$nframes"; return 1
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
      printf 'set timeout=0\nset default=0\nmenuentry "s" {\n multiboot /boot/kernel.elf\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
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
      xvfb-run -a bash -c "yes c | timeout -s KILL 60 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nframes shutdown
    nframes=$(grep -o "de${ph}ad" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    shutdown=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null)
    if [[ "$nframes" -eq 1 ]] && [[ "$shutdown" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs: frames(de${ph}ad)=$nframes shutdown-evidence=$shutdown"; return 1
}

reject_probe() { # label "<herbert program>"
    local label="$1" prog="$2"
    local cdir="$tmp/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "-- emit: multiboot32-long64\n%b\n" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset body emitted a valid multiboot image"; return 1
    fi
    return 0
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link26 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi

for label in $ALL_PROBES; do
    elf="$tmp/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    whitebox_gates "$label" "$elf" || continue
    if ! have_qemu; then pass=$((pass + 1)); continue; fi
    v=$(prog_v "$label")
    if qemu_run "$label" "$v" "$elf"; then
        bochs_ok=1
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then bochs_run "$label" "$v" "$elf" || bochs_ok=0; fi
        [[ "$bochs_ok" -eq 1 ]] && pass=$((pass + 1))
    fi
done

# NOTE: the `locals` and `branch` reject_probes (+ twins) were RETIRED at native-codegen link29
# (trikea / f2): that link deliberately WIDENS the multiboot32-long64 subset to admit if/else +
# let rbp-frame locals, so those bodies now COMPILE (proven obsolete by the widen, migrated to
# ACCEPTED probes in run_native_codegen_link29.sh with a 64-bit-distinguishing predicate). The
# remaining rejects (div/mod, bitwise, call, mainarg) stay -- they are still out of subset.
reject_probe divmod      'func main(): return 1000000 * 1000000 % 7 end'
reject_probe divmod_twin 'func main(): return 2000000 * 1000000 / 3 end'
reject_probe bitor       'func main(): return 1000000 * 1000000 | 1 end'
reject_probe bitor_twin  'func main(): return 2000000 * 1000000 & 3 end'
reject_probe call        'func h(): return 1000000 end\nfunc main(): return h() * 1000000 end'
reject_probe call_twin   'func g(): return 2000000 end\nfunc main(): return g() * 1000000 end'
reject_probe mainarg     'func main(p): return p * 1000000 end'
reject_probe mainarg_twin 'func main(k): return k * 2000000 end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 8))

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link26 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link26 / toggler / tenth kernel-arc link: the x86-64 BACKEND REUNIFICATION -- the freestanding image crosses into 64-bit long mode and runs a GENUINELY 64-bit COMPILED body lowered through the SAME near-axis 64-bit leaf emitters the Linux-ELF64 path uses, so the proof byte = the HIGH dword of the body's OWN 64-bit result [a product exceeding 2^32, wrong under 32-bit-width arithmetic]; $pass checks: static + white-box [code BEGINS with the exact 56-byte transition head exactly-once; ljmp target == long_entry V0+56; mov esp,esp_val (the rsp zero-extension) bound by value to the derived stack top; the 64-bit BODY bytes PINNED to the EXACT genuine 64-bit lowering of each probe's source (provenance: a forged/mutated body that reaches a nonzero high dword some other way is rejected) AND a {movabs/push/pop/imul/add/sub} whitelist with rax/rcx ONLY -- any 32-bit GPR rejected, pinning REX.W on every arithmetic op -- free of I/O/privileged/branch/call/memory/segment; the proof-byte data-flow 58 48c1e820 88c3 (pop rax; shr rax,0x20; mov bl,al) exactly-once so the byte IS the lowered body's high dword; GDT L=1 exactly-once + no non-L=1 code descriptor + GDTR base bound; the full PAE page-walk bound BY VALUE (CR3==PML4; PML4/PDPT entry0 + rest 0; all 512 PDEs == i*0x200000+0x83 -- virtual 0x10000c -> physical 0x10000c); the ENTRY+LOAD frame bound so the scanned bytes are the bytes that run; golden byte nonzero; single 0xE9 emit], QEMU substrate (4 probes: mul_add/mul_big/mul_add2/mul_sub, distinct nonzero 64-bit high-dword bytes), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 8 out-of-subset rejects with twins (div/bitwise/call/mainarg -> ERR 500/501/502; the locals + if/else-branch rejects were RETIRED at link29 trikea/f2, which widens the 64-bit subset to admit them -> migrated to ACCEPTED probes there); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
