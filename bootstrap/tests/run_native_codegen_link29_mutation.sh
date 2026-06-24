#!/usr/bin/env bash
# Link 29 (trikea / f2, thirteenth kernel-arc link) MUTATION proof -- "prove the widened-64-bit-subset
# gate bites." The link29 dual-substrate + white-box gate is only meaningful if a WRONG lowering would
# fail it. The widen admits if/else + let rbp-frame locals at 64-bit width; the central claim is "the
# proof byte was emitted only because a GENUINE 64-bit if/else + locals body ran -- the comparison was
# 64-bit-WIDTH (REX.W cmp, so it saw the high dword that distinguishes the arms), the frame loads/stores
# were 64-bit, the branch went to the RIGHT arm, and the rbp frame was set up." The mutations attack
# exactly that.
#
# Because the f2 lowering reuses byte sequences that recur across the compiler (the REX.W 0x48, the je
# 0F 84, the frame movs), a clean UNIQUE source anchor is fragile; so each mutation is a BINARY-PATCH on
# the genuine control image (the same technique link28 used for its loader-redirect forges), patched in
# the code window the white-box gate analyzes. Each forge must be CAUGHT -- either a white-box pin
# rejects the structural change (provenance / REX.W / je-target binds) or the patched image boots to a
# WRONG byte / no frame on QEMU. The control (unpatched genuine image) must be GREEN.
#   drop_rexw_cmp    48 39 c8 (REX.W cmp rax,rcx) -> 90 39 c8 (nop; cmp EAX,ECX): the comparison is now
#                    32-bit-WIDTH -> it compares only the low dwords -> for f2_else (C == lo32(x)) the
#                    low dwords MATCH -> the THEN arm is taken -> WRONG byte. CAUGHT: provenance (the
#                    body bytes != the genuine lowering) + the 32-bit-GPR ban + behavioral RED.
#   drop_rexw_store  48 89 45 f8 (mov [rbp-8],rax) -> 90 89 45 f8 (nop; mov [rbp-8],EAX): only the low
#                    dword of x is stored -> the high dword is lost -> the else-arm reload returns a
#                    truncated x -> WRONG byte. CAUGHT: provenance + 32-bit-GPR ban + behavioral RED.
#   drop_rexw_load   48 8b 45 f8 (mov rax,[rbp-8]) -> 90 8b 45 f8 (nop; mov EAX,[rbp-8]): the else-arm
#                    reload zero-extends the low dword -> high dword 0 -> WRONG byte. CAUGHT: provenance
#                    + 32-bit-GPR ban + behavioral RED.
#   flip_je_jne      0F 84 (je, BR_IF_FALSE) -> 0F 85 (jne): the branch condition is inverted -> the
#                    WRONG arm runs -> WRONG byte. CAUGHT: provenance (the body bytes change) + the je
#                    rel32-target reachability bind no longer sees a 0F 84 + behavioral RED.
#   drop_prologue    48 89 e5 (mov rbp,rsp) -> 90 90 90 (3 nops): rbp is left as the bootloader's stale
#                    value -> [rbp-8] store/load scribble/read garbage -> WRONG byte / fault. CAUGHT:
#                    the prologue pin (48 89 e5 right after mov esp) + behavioral RED.
#   swap_arms        rewrite the je rel32 so it targets the THEN arm start instead of the ELSE arm: the
#                    branch reaches the wrong arm -> WRONG byte. CAUGHT: the je-target == else-arm bind
#                    (P8 reachability) + behavioral RED.
#
# QEMU-only, gated behind KERNEL_CODEGEN_MUTATION=1 (or REQUIRE_EMU=1). Each anchor is located EXACTLY
# ONCE in the code window, so a drifted anchor fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then
    echo "SKIP: native-codegen link29 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: native-codegen link29 mutation proof (no qemu)"; exit 0
fi

source "$script_dir/native_codegen_oracle.sh"
mtmp="$(mktemp -d)"; trap 'rm -rf "$mtmp"' EXIT
native_codegen_ensure_compiler "$mtmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: link29-mutation ($1)"; fail=$((fail + 1)); }

# f2_else: a GENUINE 64-bit cmp takes the ELSE arm (x != C since C = lo32(x)) -> return x -> byte 0xE8.
# A 32-bit-width forge takes the THEN arm (return 88 -> high dword 0) -> a DIFFERENT byte.
PROBE='func main(): let x = 1000000 * 1000000  if x == 3567587328: return 88 else: return x end end'
GOLDEN=232   # (1000000*1000000) >> 32 & 0xff = 0xE8 = 232, the genuine 64-bit ELSE-arm proof byte

host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }
le32_val() { local h="$1" o="$2"; echo $(( 16#${h:o+6:2}${h:o+4:2}${h:o+2:2}${h:o+0:2} )); }
occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }

# build the genuine control image
ctrl_d="$mtmp/ctrl.d"; rm -rf "$ctrl_d"; mkdir -p "$ctrl_d"
printf -- '-- emit: multiboot32-long64\n%s\n' "$PROBE" > "$ctrl_d/p.herb"
( cd "$ctrl_d" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>/dev/null )
CTRL_IMG="$ctrl_d/a.out"
if [[ ! -f "$CTRL_IMG" ]]; then echo "FAIL control: could not build control image"; exit 1; fi

# ---- the white-box assessment (a faithful subset of link29's gate: provenance + REX.W + je-target +
#      prologue + behavioral boot). Returns GREEN or CAUGHT:<why>. Operates on an IMAGE file. ----
EXPECT_BODY=""   # the genuine f2_else body hex, computed once from the control image
GT_OFF=0         # grading-tail code-byte offset (genuine)
JE_TARGET=0      # genuine je rel32 target (else-arm code offset)
THEN_OFF=0       # genuine then-arm code offset
PROV_ON=1        # when 0, the provenance pin is DISABLED so a forge must trip its SPECIFIC defense

assess() { # image -> GREEN / CAUGHT:<why>
    local img="$1"
    grub-file --is-x86-multiboot "$img" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$img" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    # (head) the 56-byte transition head exactly once.
    [[ "${chx:0:8}" == "fa0f0115" ]] || { echo "CAUGHT:head"; return; }
    # (prologue) 48 89 e5 48 83 ec right after mov esp (offset 56 -> hex 112; mov esp = 10 hex -> 122).
    [[ "${chx:122:6}" == "4889e5" ]] || { echo "CAUGHT:prologue-rbp"; return; }
    [[ "${chx:128:6}" == "4883ec" ]] || { echo "CAUGHT:prologue-sub"; return; }
    # (single tail) shr rax,0x20; mov bl,al exactly once; one write to bl.
    [[ "$(occ "$chx" '48c1e82088c3')" == 1 ]] || { echo "CAUGHT:tail"; return; }
    [[ "$(occ "$chx" '88c3')" == 1 ]] || { echo "CAUGHT:extra-bl"; return; }
    local gt_pos; gt_pos=$(echo "$chx" | grep -bo '48c1e82088c3' | head -1 | cut -d: -f1)
    local body_start=$(( 56 + 12 )); local body_hexstart=$(( body_start * 2 ))
    local body_only="${chx:body_hexstart:$(( gt_pos - body_hexstart ))}"
    # (provenance) the body must be EXACTLY the genuine lowering (set on the control run). The catch-all:
    # ANY body-byte forge trips it. To prove each SPECIFIC defense ALSO bites, run with PROV_ON=0.
    if [[ -n "$EXPECT_BODY" && "$PROV_ON" -eq 1 ]]; then
        [[ "$body_only" == "$EXPECT_BODY" ]] || { echo "CAUGHT:provenance"; return; }
    fi
    # (32-bit GPR ban) the body must contain NO 32-bit GPR operand (REX.W dropped on cmp/load/store).
    dd if="$img" bs=1 skip=$(( 4108 + body_start )) count=$(( ${#body_only} / 2 )) status=none 2>/dev/null > "$mtmp/body.bin"
    local bdis; bdis=$(objdump -D -b binary -m i386:x86-64 -M intel "$mtmp/body.bin" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
    if echo "$bdis" | grep -qiE '\b(eax|ebx|ecx|edx|esi|edi)\b'; then echo "CAUGHT:rexw-dropped"; return; fi
    # (je reachability) the body je (0f 84) target == the genuine else-arm; one je exactly.
    [[ "$(occ "$body_only" '0f84[0-9a-f]{8}')" == 1 ]] || { echo "CAUGHT:je-count"; return; }
    local je_rel_pos; je_rel_pos=$(echo "$body_only" | grep -bo '0f84[0-9a-f]\{8\}' | head -1 | cut -d: -f1)
    local je_end=$(( body_start + je_rel_pos / 2 + 6 ))
    local je_rel; je_rel=$(le32_val "$body_only" $(( je_rel_pos + 4 )))
    local je_target=$(( je_end + je_rel ))
    if [[ "$JE_TARGET" -ne 0 ]]; then
        [[ "$je_target" -eq "$JE_TARGET" ]] || { echo "CAUGHT:je-target($je_target/$JE_TARGET)"; return; }
    fi
    # behavioral confirmation on QEMU.
    local ph ex; ph=$(printf '%02x' "$GOLDEN"); ex=$(host_qemu_exit "$GOLDEN")
    : > "$mtmp/e9"
    timeout 30 qemu-system-x86_64 -kernel "$img" -debugcon file:"$mtmp/e9" -display none \
        -no-reboot -serial none -monitor none -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -cpu qemu64 -m 64M >/dev/null 2>&1
    local hx; hx=$(xxd -p "$mtmp/e9" 2>/dev/null | tr -d '\n')
    if [[ "$hx" =~ ^de([0-9a-f][0-9a-f])ad$ ]]; then
        local b=$(( 16#${BASH_REMATCH[1]} ))
        [[ "$b" == "$GOLDEN" ]] && { echo "GREEN"; return; }
        echo "CAUGHT:boot($b)"; return
    fi
    echo "CAUGHT:boot(noframe:$hx)"
}

# derive the genuine anchors from the control image (provenance + je-target + then/else offsets)
derive_anchors() {
    local chx; chx=$(dd if="$CTRL_IMG" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local gt_pos; gt_pos=$(echo "$chx" | grep -bo '48c1e82088c3' | head -1 | cut -d: -f1)
    local body_start=$(( 56 + 12 )); local body_hexstart=$(( body_start * 2 ))
    EXPECT_BODY="${chx:body_hexstart:$(( gt_pos - body_hexstart ))}"
    GT_OFF=$(( gt_pos / 2 ))
    local je_rel_pos; je_rel_pos=$(echo "$EXPECT_BODY" | grep -bo '0f84[0-9a-f]\{8\}' | head -1 | cut -d: -f1)
    local je_end=$(( body_start + je_rel_pos / 2 + 6 ))
    local je_rel; je_rel=$(le32_val "$EXPECT_BODY" $(( je_rel_pos + 4 )))
    JE_TARGET=$(( je_end + je_rel ))
    # the then-arm starts right after the je (the next instruction); use the je_end as the then-arm offset.
    THEN_OFF=$je_end
}
derive_anchors

# control
ctrl=$(assess "$CTRL_IMG")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated compiler emits golden=$GOLDEN (0xE8) via a genuine 64-bit if/else+locals body (ELSE arm, x != C)"; pass=$((pass+1));
else echo "FAIL control: unmutated compiler did not pass cleanly: $ctrl"; fail=$((fail+1)); fi

# ---- binary-patch forges (located dynamically; each anchor asserted exactly-once) ----
# patch_at(srcimg, outimg, file_byte_offset, new_hex): overwrite bytes at offset.
patch_at() { python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src,out,off,newhex=sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]
b=bytearray(open(src,"rb").read())
nb=bytes.fromhex(newhex)
b[off:off+len(nb)]=nb
open(out,"wb").write(bytes(b))
PY
}
# find_one(hexpat) -> file byte offset of the unique occurrence in the FULL image, or "" if !=1.
find_one() {
    local pat="$1" full; full=$(xxd -p "$CTRL_IMG" | tr -d '\n')
    local cnt; cnt=$(echo "$full" | grep -oE "$pat" | wc -l | tr -d ' ')
    [[ "$cnt" == 1 ]] || { echo ""; return; }
    echo $(( $(echo "$full" | grep -bo "$pat" | head -1 | cut -d: -f1) / 2 ))
}

run_forge() { # name new_image [specific_catch_substr]
    # Each forge is asserted CAUGHT TWICE: (a) with the full gate (provenance ON -- the catch-all body
    # value-bind), and (b) with provenance OFF, where the forge must trip its SPECIFIC named defense
    # (32-bit-GPR ban / je-target bind / prologue pin) OR a behavioral RED on QEMU. This proves the
    # specific defense bites independently of the catch-all.
    local name="$1" img="$2" want="${3:-}"
    [[ -f "$img" ]] || { fail_test "$name: forge image not produced"; return; }
    PROV_ON=1; local v1; v1=$(assess "$img")
    if [[ "$v1" != CAUGHT:* ]]; then fail_test "$name: forge escaped the FULL gate (verdict=$v1)"; return; fi
    PROV_ON=0; local v2; v2=$(assess "$img"); PROV_ON=1
    if [[ "$v2" != CAUGHT:* ]]; then fail_test "$name: forge escaped the gate with provenance OFF (verdict=$v2) -- only the catch-all caught it"; return; fi
    if [[ -n "$want" ]] && [[ "$v2" != *"$want"* ]]; then
        fail_test "$name: provenance-off catch ($v2) is not the expected specific defense ($want)"; return
    fi
    echo "PASS mutation $name: full=$v1 specific=$v2"; pass=$((pass+1))
}

# drop_rexw_cmp: 48 39 c8 -> 90 39 c8 (the EQ cmp; nop + 32-bit cmp eax,ecx). With provenance OFF the
# disasm shows a 32-bit GPR (cmp eax,ecx) -> the 32-bit-GPR ban (rexw-dropped) bites; else a boot RED.
off=$(find_one '4839c8')
if [[ -z "$off" ]]; then fail_test "drop_rexw_cmp: anchor 4839c8 not unique"; else
    patch_at "$CTRL_IMG" "$mtmp/m_cmp.bin" "$off" '90'; run_forge drop_rexw_cmp "$mtmp/m_cmp.bin" rexw-dropped; fi

# drop_rexw_store: 48 89 45 f8 -> 90 89 45 f8 (nop + 32-bit mov [rbp-8],eax). 32-bit-GPR ban bites.
off=$(find_one '488945f8')
if [[ -z "$off" ]]; then fail_test "drop_rexw_store: anchor 488945f8 not unique"; else
    patch_at "$CTRL_IMG" "$mtmp/m_st.bin" "$off" '90'; run_forge drop_rexw_store "$mtmp/m_st.bin" rexw-dropped; fi

# drop_rexw_load: 48 8b 45 f8 -> 90 8b 45 f8 (nop + 32-bit mov eax,[rbp-8]). 32-bit-GPR ban bites. Two
# load-locals exist; patch the FIRST -- enough to corrupt the data flow.
full=$(xxd -p "$CTRL_IMG" | tr -d '\n')
ldcnt=$(echo "$full" | grep -oE '488b45f8' | wc -l | tr -d ' ')
if [[ "$ldcnt" -lt 1 ]]; then fail_test "drop_rexw_load: no load-local anchor"; else
    off=$(( $(echo "$full" | grep -bo '488b45f8' | head -1 | cut -d: -f1) / 2 ))
    patch_at "$CTRL_IMG" "$mtmp/m_ld.bin" "$off" '90'; run_forge drop_rexw_load "$mtmp/m_ld.bin" rexw-dropped; fi

# flip_je_jne: 0f 84 -> 0f 85 (the body BR_IF_FALSE; located inside the body, unique 0f84 there).
chx=$(dd if="$CTRL_IMG" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
gt_pos=$(echo "$chx" | grep -bo '48c1e82088c3' | head -1 | cut -d: -f1)
body_hexstart=$(( (56 + 12) * 2 ))
body_only="${chx:body_hexstart:$(( gt_pos - body_hexstart ))}"
je_rel_pos=$(echo "$body_only" | grep -bo '0f84[0-9a-f]\{8\}' | head -1 | cut -d: -f1)
je_code_off=$(( (56 + 12) + je_rel_pos / 2 ))           # code offset of the 0f84
je_file_off=$(( 4108 + je_code_off ))                    # file offset of the 0f84
patch_at "$CTRL_IMG" "$mtmp/m_je.bin" "$(( je_file_off + 1 ))" '85'   # 0f -> keep, 84 -> 85 (jne)
run_forge flip_je_jne "$mtmp/m_je.bin" je-count   # the body no longer has a 0f84 je -> je-count bites

# swap_arms: rewrite the je rel32 so it targets the THEN arm start (je_end) instead of the else-arm.
# new rel = THEN_OFF - je_end = 0 (the je falls through to the then-arm). So patch rel32 -> 00000000.
je_rel_file=$(( je_file_off + 2 ))                        # rel32 follows the 0f 84 opcode
patch_at "$CTRL_IMG" "$mtmp/m_swap.bin" "$je_rel_file" '00000000'
run_forge swap_arms "$mtmp/m_swap.bin" je-target   # the je now targets the then-arm -> je-target bind bites

# drop_prologue: 48 89 e5 (mov rbp,rsp) -> 90 90 90 (the prologue right after mov esp; unique).
pro_code_off=61                                          # head 56 + mov esp 5
pro_file_off=$(( 4108 + pro_code_off ))
# confirm the bytes are 4889e5 before patching
prohex="${chx:122:6}"
if [[ "$prohex" != "4889e5" ]]; then fail_test "drop_prologue: prologue bytes ($prohex) not 4889e5 at offset 61"; else
    patch_at "$CTRL_IMG" "$mtmp/m_pro.bin" "$pro_file_off" '909090'; run_forge drop_prologue "$mtmp/m_pro.bin" prologue-rbp; fi

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link29-mutation check(s) failed."; exit 1; fi
echo "PASS: link29 mutation proof ($pass checks: control passes head+prologue+single-tail+provenance+REX.W+je-target+boot gates; 6 binary-patch forges each CAUGHT -- drop_rexw_cmp (48 39 c8 -> 90 39 c8: 32-bit-width comparison sees only the low dwords, which MATCH for f2_else's C=lo32(x), so the wrong arm runs) / drop_rexw_store / drop_rexw_load (the frame store/load loses or zero-extends the high dword -> the else-arm returns a truncated x) are caught by the provenance pin + the 32-bit-GPR ban + a behavioral RED; flip_je_jne (0f84 -> 0f85: the branch condition inverts, the wrong arm runs) is caught by provenance + the je-target reachability bind + behavioral RED; swap_arms (the je rel32 retargeted to the then-arm) is caught by the je-target == else-arm value-bind + behavioral RED; drop_prologue (48 89 e5 -> 90 90 90: rbp left stale, the frame store/load scribble garbage) is caught by the prologue pin + behavioral RED -- so the 64-bit-WIDTH comparison, the 64-bit frame load/store, the correct branch arm, and the rbp frame setup are all proven load-bearing: the proof byte requires a GENUINE 64-bit if/else+locals body, not a 32-bit-truncated or mis-branched one)"
exit 0
