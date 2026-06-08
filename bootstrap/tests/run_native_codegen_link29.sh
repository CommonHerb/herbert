#!/usr/bin/env bash
# Native codegen Link 29 (trikea / f2, the THIRTEENTH kernel-arc link): WIDEN the freestanding 64-bit
# (multiboot32-long64 / toggler) subset to accept IF/ELSE control flow + LET rbp-frame LOCALS. The
# toggler (link26) lowered only straight-line 64-bit arithmetic; this link mirrors the PROVEN 32-bit
# toakie control-flow+locals machinery (nc32_layout_loop/nc32_check_branches/...) at 64-bit width:
# locals are 8-byte rbp-frame slots ([rbp - 8*(slot+1)]), branches resolve through a 64-bit layout
# pass (nc64_layout_loop), EQ/NE lower to REX.W cmp + setcc + movzx, and the optional rbp frame
# prologue is mov rbp,rsp (48 89 E5) + sub rsp,8*nlocals (48 83 EC imm8).
#
# THE 64-BIT-DISTINGUISHING FORCING SHAPE: func main(): let x = A*B  if x == C: return D else: return x
# end end, where x = A*B EXCEEDS 2^32 and C shares x's LOW 32 bits but DIFFERS in the HIGH dword. A
# GENUINE 64-bit cmp (48 39 C8) sees x != C and takes the ELSE arm (return x); a 32-bit-truncated cmp
# (39 C8, REX.W dropped) sees the low dwords match and takes the THEN arm -- a DIFFERENT byte. The
# operands are COMPUTED products, not bare literals, so the multiply itself must be 64-bit. The proof
# byte = HIGH dword of the SELECTED arm's 64-bit value (the existing shr rax,0x20; mov bl,al grading +
# de<byte>ad frame, identical to link26). Each golden is host-derived from the known program.
#   - f2_else: x = 1000000*1000000 = 0xE8D4A51000 (hi32 0xE8); C = 0xD4A51000 (= lo32 x, hi32 0).
#             64-bit: x != C -> ELSE -> return x -> byte = 0xE8. 32-bit-trunc: lo32 match -> THEN.
#   - f2_then: y = 2000000*1000000 = 0x1D1A94A2000; C = y exactly. 64-bit: y == C -> THEN -> return
#             D = 0x9A00000042 (a 64-bit literal, hi byte 0x9A) -> byte = 0x9A. A 32-bit-width MUL
#             truncates y (hi 0) != the full-64 literal C -> ELSE -> return truncated y -> byte 0x00.
# Two probes, DIFFERENT arms, DIVERGENT nonzero bytes (0xE8 vs 0x9A).
#
# Also exercises the WIDENED subset directly (migrated from link26's now-obsolete locals/branch
# rejects, which COMPILE under f2): f2_loc (a pure rbp-frame-local body, no branch) and a no-frame
# branch body, plus a NE (!=) probe.
#
# Image (vaddr V0=0x10000c): [56-byte transition head -> ljmp 0x08:long_entry @ V0+56]
#   [@long_entry (64-bit): mov esp,esp_val (bc imm32, rsp zero-extension)] [optional rbp frame:
#   48 89 E5 (mov rbp,rsp) + 48 83 EC XX (sub rsp,8*nlocals)] [the compiled body via nc64_lower_loop:
#   if/else + locals + 64-bit arithmetic; mid-body RET = pop rax; jmp grading-tail, terminal RET =
#   pop rax fall-through] [shr rax,0x20 (grading tail) + mov bl,al] [shared 58-byte epilogue]
#   [GDT/GDTR 30][pad to 4 KiB][PML4][PDPT][PD]. Reuses the toggler head/GDT/PAE/epilogue verbatim, so
#   the prior emit modes are byte-identical and the self-host fixpoint gen2==gen1 is preserved (a
#   straight-line no-locals body compiles byte-identically to the pre-widen toggler -- proven).
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; EXACTLY ONE checksum-valid Multiboot header in
#     the first 8 KiB; ZERO syscall escapes (0F05/CD80/0F34) in the code window (bounded by the
#     epilogue terminal faf4ebfd).
#   ELF P12 (the loader/CPU-redirect close, from link28): e_entry == V0; exactly ONE PT_LOAD mapping
#     file 4096 -> vaddr 0x100000 (so file 4108 <-> vaddr V0 is the unique mapping analyzed).
#   WHITE-BOX (per probe; the runtime byte alone is forgeable -- a movabs of the proof byte, a 32-bit
#   cmp, a dead arm, a swapped-target je would each produce a byte -- so prove the STRUCTURE and bind
#   the artifacts the CPU selects BY VALUE):
#     - THE EXACT 56-BYTE TRANSITION HEAD at code offset 0, EXACTLY ONCE (reachability: ljmp target ==
#       long_entry == V0+56), and mov esp,esp_val (bc) bound by value to the derived stack top.
#     - THE rbp PROLOGUE (locals probes): 48 89 E5 48 83 EC XX (mov rbp,rsp; sub rsp,8*nlocals) right
#       after the mov esp, with XX == 8*nlocals -- pins the genuine frame setup (drop it -> rbp stale).
#     - PROVENANCE: the 64-bit BODY bytes PINNED to the EXACT genuine lowering of THIS probe's source
#       (host-derived) and ending precisely at the grading tail -- so the proof byte provably flows
#       from the intended lowered if/else+locals expression, not a forged body. Binds, BY VALUE: the
#       cmp_setcc (48 39 C8 0F 94 C2 48 0F B6 C2, REX.W on the cmp + the movzx), the br_if_false
#       (58 48 85 C0 0F 84), the load/store local (48 8B 45 / 48 89 45, both REX.W).
#     - REACHABILITY by VALUE: the je (0F 84) rel32 target == the ELSE-arm start; the BR jmp (0xE9)
#       rel32 target == the JOIN (the grading tail). Both arms feed the SINGLE grading tail.
#     - THE PROOF-BYTE DATA-FLOW, EXACTLY ONCE: shr rax,0x20; mov bl,al (48 c1 e8 20 88 c3) -- and NO
#       extra write to bl, NO extra 0xE9-port frame, NO direct movabs of the final proof byte.
#     - WHITELIST (widened): only 64-bit movabs/mov, push, pop, imul, add, sub, cmp, sete, setne,
#       movzx, test, je, jmp + the rbp frame-mov -- forward-only, frame/stack-only, free of
#       I/O/privileged/call/segment/indirect. Any 32-bit GPR (REX.W dropped) is rejected.
#     - THE SINGLE EMIT PATH: the FULL frame anchor 66 ba e9 00 (mov dx,0x00E9) EXACTLY ONCE
#       (disambiguated from the BR jmp 0xE9 by binding the full 4-byte sequence, not the bare e9).
#     - GDT L=1 exactly-once + GDTR base bound; the PAE chain bound by value; the ENTRY+LOAD frame.
#   RUNTIME (per probe, both substrates): QEMU result-dependent isa-debug-exit + one host-golden e9
#     frame; Bochs one host-golden frame + clean-shutdown evidence.
#   PROBE VECTORS: f2_else (ELSE arm, 0xE8) + f2_then (THEN arm, 0x9A) + f2_loc (pure local) + f2_ne
#     (!= branch) -- distinct nonzero bytes, the widened subset exercised.
#   ACCEPTED (migrated from link26's retired locals/branch rejects): the locals + if/else bodies that
#     link26 rejected now COMPILE under f2 (the deliberate widen) -- asserted as valid images here.
#   REJECTS (+ twins): bodies STILL out of subset (div/mod, bitwise, 2-function call, parameterised
#     main, too-many-locals > 15) emit NO valid image.
#
# Honest scope: proves "the freestanding 64-bit image runs a COMPILED body with if/else control flow
# and let rbp-frame locals, whose proof byte is the 64-bit-only high dword of the selected arm's own
# result, under QEMU + Bochs+GRUB," NOT real silicon, arbitrary emulator versions, or > 15 locals /
# nested-function calls. The exact 64-bit lowering is pinned WHITE-BOX; what IS silicon-proven
# (mutation harness run_native_codegen_link29_mutation.sh): dropping a REX.W on the cmp/store/load,
# flipping je<->jne, dropping the prologue, or swapping the arm targets each makes the byte vanish or
# change. The dual-substrate + host golden replaces absent C.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L13_BOCHS_PROBES:-f2_else f2_then}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

# proof byte = high dword (byte 0) of the selected arm's 64-bit value V: (V >> 32) & 0xff.
host_proof() { echo $(( ( $1 >> 32 ) & 0xff )); }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }
le64hex() { printf '%016x' "$1" | sed -E 's/(..)(..)(..)(..)(..)(..)(..)(..)/\8\7\6\5\4\3\2\1/'; }
le32hex() { printf '%08x' $(( $1 & 0xffffffff )) | sed -E 's/(..)(..)(..)(..)/\4\3\2\1/'; }

# ---- the f2 programs + their host-known selected-arm value V (proof byte = hi dword of V) ----
A_ELSE=1000000; B_ELSE=1000000             # x = 1e12 = 0xE8D4A51000
C_ELSE=3567587328                          # = lo32(x) = 0xD4A51000 (hi dword 0)
A_THEN=2000000; B_THEN=1000000             # y = 2e12 = 0x1D1A94A2000
C_THEN=2000000000000                       # == y exactly
D_THEN=661424963650                        # = 0x9A00000042 (then-arm return, hi byte 0x9A)

prog_src() { # label -> herbert source (COMPUTED operands; the forcing shape)
    case "$1" in
      f2_else) echo "func main(): let x = $A_ELSE * $B_ELSE  if x == $C_ELSE: return 88 else: return x end end" ;;
      f2_then) echo "func main(): let y = $A_THEN * $B_THEN  if y == $C_THEN: return $D_THEN else: return y end end" ;;
      # f2_loc: a pure rbp-frame-local body, no branch -- migrates link26's `locals` reject.
      #   z = 70000*70000 = 0x12309CE5400 (hi byte 0x01) -> proof 0x01.
      f2_loc)  echo 'func main(): let z = 70000 * 70000  return z end' ;;
      # f2_ne: the NE (!=) comparator on a 64-bit-distinguishing predicate.
      #   w = 3000000*1000000 = 0x2BA7DEF3000 (hi byte 0xBA); C = lo32(w) = 2112827392 (hi dword 0),
      #   so w != C is TRUE under a genuine 64-bit cmp -> THEN -> return w (byte 0xBA). A 32-bit-trunc
      #   cmp sees lo32(w) != lo32(w) = FALSE -> ELSE -> return 5 -> byte 0x00 (wrong).
      f2_ne)   echo 'func main(): let w = 3000000 * 1000000  if w != 2112827392: return w else: return 5 end end' ;;
    esac
}
prog_v() { # label -> the SELECTED arm's u64 value V (proof byte = hi dword)
    case "$1" in
      f2_else) echo $(( A_ELSE * B_ELSE )) ;;          # ELSE arm returns x
      f2_then) echo "$D_THEN" ;;                       # THEN arm returns D
      f2_loc)  echo $(( 70000 * 70000 )) ;;            # returns z
      f2_ne)   echo $(( 3000000 * 1000000 )) ;;        # w != lo32(w) true -> then -> returns w
    esac
}
has_branch() { case "$1" in f2_loc) return 1 ;; *) return 0 ;; esac; }
has_locals() { return 0; }   # every probe declares at least one let-local
ALL_PROBES="f2_else f2_then f2_loc f2_ne"

# ---- host-side EXACT 64-bit lowering of each probe's body (the provenance reference) -------------
# These mirror nc64_lower_loop EXACTLY (the byte-for-byte leaf encodings). Each is verified to equal
# the compiler's output below; a forged/mutated body that reaches the proof byte some other way fails.
PI() { echo "48b8$(le64hex "$1")50"; }                       # PUSH_INT: movabs rax,imm64; push
DISP8() { printf '%02x' $(( 256 - 8 * ($1 + 1) )); }         # [rbp - 8*(slot+1)] disp8
LOADL() { echo "488b45$(DISP8 "$1")50"; }                    # LOAD_LOCAL: mov rax,[rbp-..]; push
STOREL() { echo "58488945$(DISP8 "$1")"; }                   # STORE_LOCAL: pop; mov [rbp-..],rax
M_MUL='5958480fafc150'                                       # pop rcx; pop rax; REX.W imul; push
M_EQ='59584839c80f94c2480fb6c250'                            # pop;pop; REX.W cmp; sete dl; movzx rax,dl; push
M_NE='59584839c80f95c2480fb6c250'                            # ... setne dl ...
BRIF() { echo "584885c00f84$(le32hex "$1")"; }               # pop; test rax,rax; je rel32
BR()   { echo "e9$(le32hex "$1")"; }                         # jmp rel32
RET_T='58'                                                   # terminal RET: pop rax
RET_M() { echo "58e9$(le32hex "$1")"; }                      # mid RET: pop rax; jmp epi rel32

# For each probe build the body hex + the layout (offsets relative to prefix origin) so we can derive
# the je-target / jmp-target offsets BY VALUE. prefix_len: 12 (every probe has >=1 local).
# We construct each body explicitly with its rel32s, matching nc64_layout_loop / nc64_lower_loop.
expected_body() { # label -> body hex (the full nc64_lower_loop output)
    local pl=12
    case "$1" in
      f2_else)
        # ops: PI A, PI B, MUL, STOREL 0, LOADL 0, PI C, EQ, BRIF else, PI 88, RET_M, LOADL 0, RET_T
        # sizes: 11 11 7 5 5 11 13 10 11 6 5 1 ; offsets from pl=12
        local o_brifend=$(( pl+11+11+7+5+5+11+13+10 ))   # endoff of BRIF
        local o_else=$(( pl+11+11+7+5+5+11+13+10+11+6 )) # start of else-arm LOADL
        local o_retmend=$(( pl+11+11+7+5+5+11+13+10+11+6 ))  # endoff of mid RET
        local epi=$(( pl+11+11+7+5+5+11+13+10+11+6+5+1 ))
        echo "$(PI $A_ELSE)$(PI $B_ELSE)${M_MUL}$(STOREL 0)$(LOADL 0)$(PI $C_ELSE)${M_EQ}$(BRIF $(( o_else - o_brifend )))$(PI 88)$(RET_M $(( epi - o_retmend )))$(LOADL 0)${RET_T}"
        ;;
      f2_then)
        local o_brifend=$(( pl+11+11+7+5+5+11+13+10 ))
        local o_else=$(( pl+11+11+7+5+5+11+13+10+11+6 ))
        local o_retmend=$(( pl+11+11+7+5+5+11+13+10+11+6 ))
        local epi=$(( pl+11+11+7+5+5+11+13+10+11+6+5+1 ))
        echo "$(PI $A_THEN)$(PI $B_THEN)${M_MUL}$(STOREL 0)$(LOADL 0)$(PI $C_THEN)${M_EQ}$(BRIF $(( o_else - o_brifend )))$(PI $D_THEN)$(RET_M $(( epi - o_retmend )))$(LOADL 0)${RET_T}"
        ;;
      f2_ne)
        # w = 3000000*1000000; if w != 854151168: return w else: return 5
        # ops: PI A, PI B, MUL, STOREL 0, LOADL 0, PI C, NE, BRIF else, LOADL 0, RET_M, PI 5, RET_T
        local o_brifend=$(( pl+11+11+7+5+5+11+13+10 ))
        local o_else=$(( pl+11+11+7+5+5+11+13+10+5+6 ))
        local o_retmend=$(( pl+11+11+7+5+5+11+13+10+5+6 ))
        local epi=$(( pl+11+11+7+5+5+11+13+10+5+6+11+1 ))
        echo "$(PI 3000000)$(PI 1000000)${M_MUL}$(STOREL 0)$(LOADL 0)$(PI 2112827392)${M_NE}$(BRIF $(( o_else - o_brifend )))$(LOADL 0)$(RET_M $(( epi - o_retmend )))$(PI 5)${RET_T}"
        ;;
      f2_loc)
        # z = 70000*70000; return z  -> PI A, PI B, MUL, STOREL 0, LOADL 0, RET_T (terminal)
        echo "$(PI 70000)$(PI 70000)${M_MUL}$(STOREL 0)$(LOADL 0)${RET_T}"
        ;;
    esac
}

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-long64\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

static_gates() { # label elf
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx; hx=$(xxd -p "$elf" | tr -d '\n')
    local mb_o mb_valid_count=0 mb_valid_off=-1 mb_valid_flags=-1 mb_valid_csum=0 mb_f mb_c
    for (( mb_o=0; mb_o+12 <= 8192 && mb_o*2+24 <= ${#hx}; mb_o+=4 )); do
        [[ "${hx:$(( mb_o*2 )):8}" == "02b0ad1b" ]] || continue
        mb_f=$(le32_val "$hx" $(( mb_o*2 + 8 ))); mb_c=$(le32_val "$hx" $(( mb_o*2 + 16 )))
        if [[ $(( (16#1BADB002 + mb_f + mb_c) % (1 << 32) )) -eq 0 ]]; then
            mb_valid_count=$(( mb_valid_count + 1 )); mb_valid_off=$mb_o; mb_valid_flags=$mb_f; mb_valid_csum=$mb_c
        fi
    done
    [[ "$mb_valid_count" -eq 1 ]] || { fail_test "$label static: $mb_valid_count checksum-valid Multiboot headers (want 1)"; ok=0; }
    [[ "$mb_valid_off" -eq 4096 && "$mb_valid_flags" -eq 0 && "$mb_valid_csum" -eq $(( 16#E4524FFE )) ]] || { fail_test "$label static: valid MB header not the genuine shape (off=$mb_valid_off flags=$mb_valid_flags csum=$mb_valid_csum)"; ok=0; }
    local code="$work/$label.code"
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

# ELF entry + single-PT_LOAD bind (P12, the loader/CPU-redirect close, from link28).
elf_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local e_entry e_phoff e_phnum p_type p_offset p_vaddr p_flags
    e_entry=$(le32_val "$eh" 48); e_phoff=$(le32_val "$eh" 56); e_phnum=$(( 16#${eh:90:2}${eh:88:2} ))
    [[ "$e_entry" -eq 1048588 ]] || { fail_test "$label elf(P12): e_entry ($e_entry) != 1048588 (V0) -- entry-redirect forge"; ok=0; }
    [[ "$e_phoff" -eq 52 ]] || { fail_test "$label elf(P12): e_phoff ($e_phoff) != 52"; ok=0; }
    [[ "$e_phnum" -eq 1 ]] || { fail_test "$label elf(P12): e_phnum ($e_phnum) != 1 -- a second PT_LOAD could remap the entry"; ok=0; }
    p_type=$(le32_val "$eh" 104); p_offset=$(le32_val "$eh" 112); p_vaddr=$(le32_val "$eh" 120); p_flags=$(le32_val "$eh" 152)
    [[ "$p_type" -eq 1 ]] || { fail_test "$label elf(P12): PT_LOAD type ($p_type) != 1"; ok=0; }
    [[ "$p_offset" -eq 4096 ]] || { fail_test "$label elf(P12): p_offset ($p_offset) != 4096 -- remap forge"; ok=0; }
    [[ "$p_vaddr" -eq 1048576 ]] || { fail_test "$label elf(P12): p_vaddr ($p_vaddr) != 1048576 -- remap forge"; ok=0; }
    [[ "$p_flags" -eq 7 ]] || { fail_test "$label elf(P12): p_flags ($p_flags) != 7"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$work/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    local vv; vv=$(prog_v "$label")
    local pb; pb=$(host_proof "$vv")
    # (0) golden byte NONZERO.
    [[ "$pb" -ne 0 ]] || { fail_test "$label whitebox: golden byte is 0x00 (probe V=$vv has zero high dword -- not 64-bit-distinguishing)"; ok=0; }
    # (1) CODE BEGINS with the 56-byte transition head, exactly once; ljmp target == V0+56.
    local head='fa0f0115[0-9a-f]{8}b8200000000f22e0b8[0-9a-f]{8}0f22d8b9800000c00f320d000100000f300f20c00d000000800f22c0ea[0-9a-f]{8}0800'
    [[ "${chx:0:8}" == "fa0f0115" ]] || { fail_test "$label whitebox: code does not begin with the transition head (cli;lgdt)"; ok=0; }
    [[ "$(occ "$chx" "$head")" == 1 ]] || { fail_test "$label whitebox: exact 56-byte transition head not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '0f22c0ea')" == 1 ]] || { fail_test "$label whitebox: mov-cr0+ljmp anchor (0f22c0ea) not present exactly once"; ok=0; }
    local cr0jmp_pos ljmp_target; cr0jmp_pos=$(echo "$chx" | grep -bo '0f22c0ea' | head -1 | cut -d: -f1)
    ljmp_target=$(le32_val "$chx" $(( cr0jmp_pos + 8 )))
    [[ "$ljmp_target" -eq $(( 1048588 + 56 )) ]] || { fail_test "$label whitebox: ljmp target ($ljmp_target) != long_entry (V0+56)"; ok=0; }
    # (2) mov esp,esp_val (bc) at code offset 56 (hex 112), esp_val bound to derived stack top.
    [[ "${chx:112:2}" == "bc" ]] || { fail_test "$label whitebox: no mov esp,imm32 (bc) at long_entry (offset 56)"; ok=0; }
    # derive the table layout from the GDT L=1 descriptor (the toggler tables verbatim).
    [[ "$(occ "$chx" 'ffff0000009aaf00')" == 1 ]] || { fail_test "$label whitebox: 64-bit code descriptor (L=1) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" 'ffff0000009a..00')" == 1 ]] || { fail_test "$label whitebox: a non-L=1 code descriptor exists (compat-mode forge)"; ok=0; }
    [[ "$(occ "$chx" 'ffff00000092af001700')" == 1 ]] || { fail_test "$label whitebox: data descriptor + GDTR limit 0x17 not present exactly once"; ok=0; }
    local l1_pos gdt_vaddr pml4_vaddr pdpt_vaddr pd_vaddr load_end esp_top
    l1_pos=$(echo "$chx" | grep -bo 'ffff0000009aaf00' | head -1 | cut -d: -f1)
    gdt_vaddr=$(( 1048588 + l1_pos / 2 - 8 ))
    pml4_vaddr=$(( (gdt_vaddr + 30 + 4095) / 4096 * 4096 ))
    pdpt_vaddr=$(( pml4_vaddr + 4096 )); pd_vaddr=$(( pdpt_vaddr + 4096 )); load_end=$(( pd_vaddr + 4096 ))
    esp_top=$(( load_end + 16384 ))
    local esp_imm; esp_imm=$(le32_val "$chx" 114)
    [[ "$esp_imm" -eq "$esp_top" ]] || { fail_test "$label whitebox: mov esp imm ($esp_imm) != derived stack top ($esp_top)"; ok=0; }
    local gdtr_pos gdtr_base; gdtr_pos=$(echo "$chx" | grep -bo 'ffff00000092af001700' | head -1 | cut -d: -f1)
    gdtr_base=$(le32_val "$chx" $(( gdtr_pos + 20 )))
    [[ "$gdtr_base" -eq "$gdt_vaddr" ]] || { fail_test "$label whitebox: GDTR base ($gdtr_base) != located GDT vaddr ($gdt_vaddr)"; ok=0; }
    # (3) PAE chain bound by value (toggler tables).
    [[ "$(occ "$chx" '8300000000000000')" == 1 ]] || { fail_test "$label whitebox: PD[0]=0x83 not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '8300200000000000')" == 1 ]] || { fail_test "$label whitebox: PD[1]=0x200083 not present exactly once"; ok=0; }
    local tbl tname t0want toff thi tlo tbad
    for tbl in pml4 pdpt; do
        if [[ "$tbl" == "pml4" ]]; then toff=$(( (pml4_vaddr - 1048588) * 2 )); t0want=$(( pdpt_vaddr + 3 )); tname="PML4"
        else toff=$(( (pdpt_vaddr - 1048588) * 2 )); t0want=$(( pd_vaddr + 3 )); tname="PDPT"; fi
        local thex="${chx:$toff:8192}" te_i tbad=""
        for (( te_i=0; te_i<512; te_i++ )); do
            tlo=$(le32_val "$thex" $(( te_i * 16 ))); thi="${thex:$(( te_i * 16 + 8 )):8}"
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
        pde_lo=$(le32_val "$pd_hex" $(( pde_i * 16 ))); pde_hi="${pd_hex:$(( pde_i * 16 + 8 )):8}"
        if [[ "$pde_lo" -ne $(( pde_i * 2097152 + 131 )) || "$pde_hi" != "00000000" ]]; then pde_bad="PDE[$pde_i] lo=$pde_lo hi=$pde_hi"; break; fi
    done
    [[ -z "$pde_bad" ]] || { fail_test "$label whitebox: leaf PD not the 512-entry low-1-GiB identity map [$pde_bad]"; ok=0; }
    # (4) SINGLE EMIT PATH: the FULL frame anchor 66bae900 EXACTLY ONCE (disambiguated from BR jmp e9).
    [[ "$(occ "$chx" '66bae900')" == 1 ]] || { fail_test "$label whitebox: the 0xE9 frame-emit (66 ba e9 00) not present exactly once"; ok=0; }
    # (5) PROOF-BYTE DATA-FLOW: shr rax,0x20; mov bl,al (48c1e820 88c3) EXACTLY ONCE, and NO extra
    #     write to bl beyond the epilogue's two legitimate mov al,bl (88d8) reads (88c3 writes bl once).
    [[ "$(occ "$chx" '48c1e82088c3')" == 1 ]] || { fail_test "$label whitebox: shr rax,0x20; mov bl,al not present exactly once -- the proof byte may not be the body's high dword"; ok=0; }
    [[ "$(occ "$chx" '88c3')" == 1 ]] || { fail_test "$label whitebox: more than one write to bl (88c3) -- an extra proof-byte source"; ok=0; }
    # (6) THE rbp PROLOGUE (every probe has a local): 48 89 e5 48 83 ec XX at offset 56 (hex 112+2).
    # mov esp = bc(1) + imm32(4) = 5 bytes = 10 hex starting at code offset 56 (hex 112) -> the rbp
    # prologue (48 89 e5 48 83 ec XX) begins at code offset 61 = hex 122.
    [[ "${chx:122:6}" == "4889e5" ]] || { fail_test "$label whitebox: no mov rbp,rsp (48 89 e5) prologue after mov esp"; ok=0; }
    [[ "${chx:128:6}" == "4883ec" ]] || { fail_test "$label whitebox: no sub rsp,imm8 (48 83 ec) prologue"; ok=0; }
    local sub_imm; sub_imm=$(( 16#${chx:134:2} ))
    # nlocals derived from the probe: every probe uses exactly 1 local slot -> frame 8.
    [[ "$sub_imm" -eq 8 ]] || { fail_test "$label whitebox: sub rsp imm8 ($sub_imm) != 8*nlocals (8) -- frame mis-sized"; ok=0; }
    # (7) PROVENANCE: the body bytes are EXACTLY the host-derived genuine lowering, ending at the tail.
    local body_start=$(( 56 + 12 ))    # head 56 + prefix 12 (mov esp 5 + mov rbp,rsp 3 + sub rsp 4)
    local gt_pos; gt_pos=$(echo "$chx" | grep -bo '48c1e82088c3' | head -1 | cut -d: -f1)
    local body_hexstart=$(( body_start * 2 ))
    local want_body; want_body=$(expected_body "$label")
    [[ "${chx:body_hexstart:${#want_body}}" == "$want_body" ]] || { fail_test "$label whitebox: body bytes != expected genuine 64-bit lowering (provenance) -- got ${chx:body_hexstart:64}... want ${want_body:0:64}..."; ok=0; }
    [[ $(( body_hexstart + ${#want_body} )) -eq "$gt_pos" ]] || { fail_test "$label whitebox: the expected body does not end exactly at the grading tail (gt=$gt_pos) -- extra/short bytes"; ok=0; }
    # (8) REACHABILITY by VALUE for branching probes: je (0f84) target == else-arm start; jmp (e9 in
    #     the body, NOT the frame 66bae900) target == the grading tail (join). Both arms feed the tail.
    if has_branch "$label"; then
        # the body je: 0f84 within the body region. There is exactly one je in these probes.
        local je_count; je_count=$(occ "${chx:body_hexstart:${#want_body}}" '0f84[0-9a-f]{8}')
        [[ "$je_count" == 1 ]] || { fail_test "$label whitebox: body je (0f84 rel32) not present exactly once (got $je_count)"; ok=0; }
        # locate the je inside the body, decode its rel32 target (relative to its own end).
        local body_only="${chx:body_hexstart:${#want_body}}"
        local je_rel_pos; je_rel_pos=$(echo "$body_only" | grep -bo '0f84[0-9a-f]\{8\}' | head -1 | cut -d: -f1)
        local je_byte_off=$(( je_rel_pos / 2 ))                       # byte offset within body of the 0f84
        local je_end=$(( body_start + je_byte_off + 6 ))             # code-offset just past the je (6 bytes)
        local je_rel; je_rel=$(le32_val "$body_only" $(( je_rel_pos + 4 )))
        local je_target=$(( je_end + je_rel ))                        # absolute code offset of the else-arm
        # the body jmp (mid-RET) e9: find an 'e9' rel32 in the body that is NOT part of 66bae9 (frame).
        # In these probes the mid-RET jmp is the ONLY body-level e9. Its target must be the grading tail.
        local jmp_rel_pos; jmp_rel_pos=$(echo "$body_only" | grep -bo '58e9[0-9a-f]\{8\}' | head -1 | cut -d: -f1)
        if [[ -z "$jmp_rel_pos" ]]; then
            fail_test "$label whitebox: no mid-RET jmp (58 e9 rel32) in the body -- one arm does not reach the join"; ok=0
        else
            local jmp_byte_off=$(( jmp_rel_pos / 2 ))
            local jmp_end=$(( body_start + jmp_byte_off + 6 ))        # past 'pop rax; jmp rel32' (1+5)
            local jmp_rel; jmp_rel=$(le32_val "$body_only" $(( jmp_rel_pos + 4 )))   # rel32 hex starts after 58e9
            local jmp_target=$(( jmp_end + jmp_rel ))
            local tail_off=$(( gt_pos / 2 ))                          # code offset of 48c1e820 (the grading tail)
            [[ "$jmp_target" -eq "$tail_off" ]] || { fail_test "$label whitebox: body jmp target ($jmp_target) != grading tail ($tail_off) -- an arm does not feed the single grading tail"; ok=0; }
            # the je target (else-arm) must lie strictly between the then-arm and the grading tail.
            [[ "$je_target" -gt "$je_end" && "$je_target" -lt "$tail_off" ]] || { fail_test "$label whitebox: je target ($je_target) is not a forward in-body else-arm before the tail ($tail_off)"; ok=0; }
        fi
        # NO direct movabs of the final proof byte as a literal anywhere in the body other than via the
        # legitimate movabs of the arm VALUES (already pinned by provenance) -- provenance covers it.
    fi
    # (9) WHITELIST + REX.W: disassemble the body, allow only the widened 64-bit subset, ban 32-bit GPRs.
    local body_byte_len=$(( ${#want_body} / 2 ))
    dd if="$code" of="$code.body" bs=1 skip="$body_start" count="$body_byte_len" status=none 2>/dev/null
    local bdis; bdis=$(objdump -D -b binary -m i386:x86-64 -M intel "$code.body" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
    local bad; bad=$(echo "$bdis" | awk '{print $1}' | grep -ivE '^(movabs|mov|movzx|push|pop|imul|add|sub|cmp|sete|setne|test|je|jmp)$' | sort -u | tr '\n' ' ')
    [[ -z "${bad// /}" ]] || { fail_test "$label whitebox: body uses non-subset instruction(s) [$bad]"; ok=0; }
    # any 32-bit GPR in an ARITHMETIC/compare/frame op means a REX.W was dropped. The frame uses rbp/rsp
    # (legitimately 64-bit), the local mov uses rbp -- allow rbp/rsp; ban eax/ebx/ecx/edx/esi/edi.
    if echo "$bdis" | grep -qiE '\b(eax|ebx|ecx|edx|esi|edi)\b'; then
        fail_test "$label whitebox: body has a 32-bit GPR operand (REX.W dropped) -- arithmetic/compare not 64-bit-width"; ok=0
    fi
    # control transfers in the body must be only direct je/jmp to numeric (in-body) targets.
    local ctl; ctl=$(echo "$bdis" | grep -iE '^(j[a-z]+|call|ret|loop|int|syscall|sysenter|iret)')
    if [[ -n "$ctl" ]] && echo "$ctl" | grep -qvE '^(je|jmp) +0x[0-9a-f]+'; then
        fail_test "$label whitebox: body has a non-direct/forbidden control transfer"; ok=0
    fi
    # the forcing MUL is a REX.W imul (48 0f af c1) present in the body.
    echo "${chx:body_hexstart:${#want_body}}" | grep -q '480fafc1' || { fail_test "$label whitebox: no REX.W imul (48 0f af c1) in the body -- the 64-bit multiply is missing"; ok=0; }
    # the cmp is a REX.W cmp (48 39 c8) -- the 64-bit-distinguishing comparison.
    if has_branch "$label"; then
        echo "${chx:body_hexstart:${#want_body}}" | grep -q '4839c8' || { fail_test "$label whitebox: no REX.W cmp (48 39 c8) in the body -- the comparison is not 64-bit"; ok=0; }
    fi
    # both the STORE and LOAD local carry REX.W (48 89 45 / 48 8b 45).
    echo "${chx:body_hexstart:${#want_body}}" | grep -q '488945' || { fail_test "$label whitebox: no REX.W store-local (48 89 45) -- frame store not 64-bit"; ok=0; }
    echo "${chx:body_hexstart:${#want_body}}" | grep -q '488b45' || { fail_test "$label whitebox: no REX.W load-local (48 8b 45) -- frame load not 64-bit"; ok=0; }
    # (10) ENTRY+LOAD frame: e_entry==0x10000c (the scanned bytes are the bytes that run).
    local eentry; eentry=$(dd if="$elf" bs=1 skip=24 count=4 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$eentry" == "0c001000" ]] || { fail_test "$label whitebox: e_entry (0x$eentry) != 0x0010000c"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

qemu_run() { # label v elf
    local label="$1" v="$2" elf="$3"
    local p ex ph; p=$(host_proof "$v"); ex=$(host_qemu_exit "$p"); ph=$(printf '%02x' "$p")
    local W="$work/$label.q"; mkdir -p "$W"
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
    local W="$work/$label.b"; mkdir -p "$W"
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

accept_probe() { # label "<herbert program>"  -- the WIDENED subset bodies that COMPILE under f2.
    local label="$1" aprog="$2"
    local adir="$work/acc.$label.d"; rm -rf "$adir"; mkdir -p "$adir"
    printf -- "-- emit: multiboot32-long64\n%b\n" "$aprog" > "$adir/probe.herb"
    ( cd "$adir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$adir/a.out" ]] && grub-file --is-x86-multiboot "$adir/a.out" >/dev/null 2>&1; then return 0; fi
    fail_test "accept $label: a widened-subset body did NOT emit a valid multiboot image (the widen regressed)"; return 1
}

reject_probe() { # label "<herbert program>"  -- bodies STILL out of subset.
    local label="$1" rprog="$2"
    local rdir="$work/rej.$label.d"; rm -rf "$rdir"; mkdir -p "$rdir"
    printf -- "-- emit: multiboot32-long64\n%b\n" "$rprog" > "$rdir/probe.herb"
    ( cd "$rdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$rdir/a.out" ]] && grub-file --is-x86-multiboot "$rdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset body emitted a valid multiboot image"; return 1
    fi
    return 0
}

gen_locals() { # n prefix -> a program declaring n locals
    local n="$1" pfx="$2" s='func main():' i
    for i in $(seq 0 $((n - 1))); do s="$s let $pfx$i = $i"; done
    echo "$s return $pfx$((n - 1)) end"
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link29 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi

for label in $ALL_PROBES; do
    elf="$work/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    elf_gates "$label" "$elf" || continue
    whitebox_gates "$label" "$elf" || continue
    if ! have_qemu; then pass=$((pass + 1)); continue; fi
    v=$(prog_v "$label")
    if qemu_run "$label" "$v" "$elf"; then
        bochs_ok=1
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then bochs_run "$label" "$v" "$elf" || bochs_ok=0; fi
        [[ "$bochs_ok" -eq 1 ]] && pass=$((pass + 1))
    fi
done

# ACCEPTED probes (migrated from link26's now-obsolete locals/branch rejects -- they COMPILE under f2).
accept_probe locals      'func main(): let x = 70000  return x * x end'
accept_probe locals_twin 'func main(): let y = 60000  return y * y end'
accept_probe branch      'func main(): if 1000000 * 1000000 == 3567587328: return 7 else: return 1000000 * 1000000 end end'
accept_probe branch_twin 'func main(): if 2000000 * 1000000 == 2840207360: return 5 else: return 2000000 * 1000000 end end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 4))

# REJECTS that STILL hold (div/mod, bitwise, call, mainarg, too-many-locals).
reject_probe divmod      'func main(): return 1000000 * 1000000 % 7 end'
reject_probe divmod_twin 'func main(): return 2000000 * 1000000 / 3 end'
reject_probe bitor       'func main(): return 1000000 * 1000000 | 1 end'
reject_probe bitor_twin  'func main(): return 2000000 * 1000000 & 3 end'
reject_probe call        'func h(): return 1000000 end\nfunc main(): return h() * 1000000 end'
reject_probe call_twin   'func g(): return 2000000 end\nfunc main(): return g() * 1000000 end'
reject_probe mainarg     'func main(p): return p * 1000000 end'
reject_probe mainarg_twin 'func main(k): return k * 2000000 end'
reject_probe maxlocals      "$(gen_locals 16 a)"
reject_probe maxlocals_twin "$(gen_locals 16 z)"
[[ "$fail" -eq 0 ]] && pass=$((pass + 10))

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link29 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link29 / trikea / f2 / thirteenth kernel-arc link: WIDEN the freestanding 64-bit (multiboot32-long64) subset to accept IF/ELSE + LET rbp-frame LOCALS -- mirrors the proven 32-bit toakie control-flow+locals machinery at 64-bit width (8-byte [rbp-8*(slot+1)] slots; nc64_layout_loop branch pass; REX.W cmp+setcc+movzx for EQ/NE); the forcing shape let x=A*B (>2^32) if x==C (C shares x's low 32 bits, differs in the high dword) so a GENUINE 64-bit cmp takes a different arm than a 32-bit-truncated one, proof byte = high dword of the selected arm's 64-bit value; $pass checks: static + ELF-P12 + white-box [56-byte head + ljmp target exactly-once; mov esp bound; the rbp prologue 48 89 e5 48 83 ec XX pinned; the body PROVENANCE-pinned to the exact host-derived 64-bit lowering ending at the grading tail (REX.W cmp 48 39 c8 + sete/setne + movzx + br_if_false 58 48 85 c0 0f 84 + load/store-local 48 8b 45 / 48 89 45, both REX.W); the je rel32 target == else-arm + the BR jmp(0xE9) rel32 target == the join (grading tail) bound BY VALUE so both arms feed the SINGLE grading tail 48c1e820 88c3 exactly-once; widened whitelist {movabs/mov/movzx/push/pop/imul/add/sub/cmp/sete/setne/test/je/jmp + rbp frame-mov} forward-only + frame/stack-only + free of I/O/privileged/call/segment, any 32-bit GPR rejected; the FULL frame anchor 66bae900 exactly-once disambiguated from the BR jmp e9; GDT L=1 + PAE chain + entry frame bound by value], QEMU substrate (4 probes: f2_else 0xE8 + f2_then 0x9A + f2_loc + f2_ne, distinct nonzero high-dword bytes taking different arms), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 4 ACCEPTED widened-subset probes migrated from link26's retired locals/branch rejects, 10 out-of-subset rejects with twins (div/mod/bitwise/call/mainarg/too-many-locals>15 -> ERR 502/504); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
