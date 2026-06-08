#!/usr/bin/env bash
# Link 26 (toggler, tenth kernel-arc link) MUTATION proof -- "prove the 64-bit-COMPILED-body gate bites."
# The link26 dual-substrate gate is only meaningful if a WRONG compiler would fail it. We mutate the
# compiler SOURCE at a unique anchor and re-emit the canonical probe through the C-interpreted backend:
# each mutation must be CAUGHT -- a white-box pin rejects the structural change, or no/a wrong frame is
# emitted (triple-fault / != golden).
#
# The central claim: "the proof byte appeared only because the image GENUINELY crossed into 64-bit long
# mode and the COMPILED body computed a >2^32 result with REX.W instructions, and that result flowed
# unbroken into the emitted byte." Mutations attack exactly that:
#   M-bodymul  nc_emit_mul REX.W 0x48 -> nop  -> the body's multiply is 32-bit non-widening -> high dword
#              0 -> byte 0x00; AND the body disasm shows a 32-bit GPR -------- body REX.W pin / boot
#   M-shr      grading-tail shr count 0x20 -> 0 -> high dword NOT extracted (no-op) -> low byte --------- data-flow pin
#   M-shrrexw  grading-tail REX.W 0x48 -> nop  -> shr eax (32-bit, count masks 0) -> low byte ----------- data-flow pin
#   M-movesp   mov esp,esp_val (bc) -> mov ebp (bd) -> rsp keeps its UNDEFINED high half -> the body's
#              push addresses outside the low-1-GiB map -> #PF/triple-fault; AND no `bc` at long_entry --- mov-esp pin
#   M-Lbit     GDT code desc L-bit 0xAF->0xCF -> far-jmp lands in COMPATIBILITY mode -> the REX.W body
#              decodes 32-bit -> wrong byte (silicon) ----------------------------------------------------- gdt pin
#   M-lme      EFER.LME or-0x100 -> 0 -> never enters IA-32e -> triple-fault (no frame) ------------------- boot
#   M-pml4     PML4[0] present 3 -> 2 -> first 64-bit fetch hits a not-present PML4E -> #PF -> triple-fault- boot
#   M-hardcode epilogue `mov bl,al` (88 c3) -> `mov bl,0x01` (b3 01) -> the body's high dword is DISCARDED
#              and the framed byte is a constant (BEHAVIORALLY INVISIBLE: 0x01 equals the genuine byte)
#              -- caught ONLY by the body-result -> shr -> frame data-flow pin --------------------------- data-flow pin
#
# QEMU-only, gated behind KERNEL_CODEGEN_MUTATION=1 (or REQUIRE_EMU=1). Each anchor is asserted to occur
# EXACTLY ONCE, so a drifted anchor fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then echo "SKIP: native-codegen link26 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0; fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then echo "SKIP: native-codegen link26 mutation proof (no qemu)"; exit 0; fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
fail_test() { echo "FAIL: link26-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): return 70000 * 70000 + 126 end'   # V=0x12410117E -> proof = high dword = 0x01
GOLDEN=1
HEAD='fa0f0115[0-9a-f]{8}b8200000000f22e0b8[0-9a-f]{8}0f22d8b9800000c00f320d000100000f300f20c00d000000800f22c0ea[0-9a-f]{8}0800'
DATAFLOW='5848c1e82088c3'   # pop rax (RET -> body result); shr rax,0x20 (high dword); mov bl,al (frame)
le32_at() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

emit_seq=0
assess() { # compiler_src -> GREEN | CAUGHT:<why>
    local comp="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-long64\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$comp" < p.herb >/dev/null 2>/dev/null )
    [[ -f "$d/a.out" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$d/a.out" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local chx; chx=$(dd if="$d/a.out" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "${chx:0:8}" == "fa0f0115" ]] || { echo "CAUGHT:no-head-entry"; return; }
    [[ "$(echo "$chx" | grep -oE "$HEAD" | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:head"; return; }
    echo "$chx" | grep -q 'ffff0000009aaf00' || { echo "CAUGHT:gdt-no-L1"; return; }
    [[ "$(echo "$chx" | grep -oE 'ffff0000009a..00' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:gdt-L0-mask"; return; }
    [[ "$(echo "$chx" | grep -oE "$DATAFLOW" | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:dataflow"; return; }
    [[ "${chx:112:2}" == "bc" ]] || { echo "CAUGHT:no-movesp"; return; }
    [[ "$(echo "$chx" | grep -oE '66bae900' | wc -l | tr -d ' ')" == 1 ]] || { echo "CAUGHT:emit"; return; }
    # body REX.W: [offset 61 .. the grading tail] must touch only rax/rcx (no 32-bit GPR).
    local gt_pos body_end; gt_pos=$(echo "$chx" | grep -bo '48c1e82088c3' | head -1 | cut -d: -f1)
    if [[ -n "$gt_pos" ]]; then
        body_end=$(( gt_pos / 2 ))
        dd if="$d/a.out" bs=1 skip=$(( 4108 + 61 )) count=$(( body_end - 61 )) status=none 2>/dev/null > "$d/body"
        if objdump -D -b binary -m i386:x86-64 -M intel "$d/body" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}' | grep -qiE '\b(eax|ebx|ecx|edx|esi|edi|esp|ebp)\b'; then
            echo "CAUGHT:body-32bit"; return
        fi
    fi
    : > "$d/e9"
    timeout 30 qemu-system-x86_64 -kernel "$d/a.out" -debugcon file:"$d/e9" -display none \
        -no-reboot -serial none -monitor none -device isa-debug-exit,iobase=0xf4,iosize=0x04 -cpu qemu64 -m 64M >/dev/null 2>&1
    local hx; hx=$(xxd -p "$d/e9" 2>/dev/null | tr -d '\n')
    if [[ "$hx" =~ ^de([0-9a-f][0-9a-f])ad$ ]]; then
        local b=$((16#${BASH_REMATCH[1]}))
        [[ "$b" == "$GOLDEN" ]] && { echo "GREEN"; return; }
        echo "CAUGHT:boot($b)"; return
    fi
    echo "CAUGHT:boot(noframe:$hx)"
}

ctrl=$(assess "$backend")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated compiler emits golden=$GOLDEN via a genuine 64-bit COMPILED body"; pass=$((pass+1));
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

# M-bodymul: drop REX.W (0x48 -> 0x90 nop) on the SHARED near-axis multiply nc_emit_mul that toggler's
# body reuses. The body multiply becomes 32-bit non-widening -> the product never exceeds 2^32 -> high
# dword 0 -> byte 0x00; the body disasm also shows imul eax,ecx (32-bit GPR). Anchored on nc_emit_mul's
# unique pop-rax;imul;push tail (the observable's imul is preceded by mov ecx, not pop rax).
mutate bodymul \
'    do append(buf, 88)
    do append(buf, 72)
    do append(buf, 15)
    do append(buf, 175)
    do append(buf, 193)
    do append(buf, 80)' \
'    do append(buf, 88)
    do append(buf, 144)
    do append(buf, 15)
    do append(buf, 175)
    do append(buf, 193)
    do append(buf, 80)'

# M-shr: grading-tail shr count 0x20 -> 0 (the 64-bit high-dword extraction becomes a no-op shift). al is
# then the LOW byte of the body result, not the high dword. The shr bytes change (48 c1 e8 00) so the
# data-flow pin 58 48c1e820 88c3 no longer matches. Anchored on toggler's cbuf grading tail.
mutate shr \
'    do append(cbuf, 72)
    do append(cbuf, 193)
    do append(cbuf, 232)
    do append(cbuf, 32)' \
'    do append(cbuf, 72)
    do append(cbuf, 193)
    do append(cbuf, 232)
    do append(cbuf, 0)'

# M-shrrexw: grading-tail REX.W 0x48 -> 0x90 nop. The shr becomes 32-bit (shr eax,0x20, count masks to 0
# -> no-op) -> al is the low byte. The shr bytes change so the data-flow pin no longer matches.
mutate shrrexw \
'    do append(cbuf, 72)
    do append(cbuf, 193)
    do append(cbuf, 232)
    do append(cbuf, 32)' \
'    do append(cbuf, 144)
    do append(cbuf, 193)
    do append(cbuf, 232)
    do append(cbuf, 32)'

# M-movesp: mov esp,esp_val (bc) -> mov ebp,esp_val (bd). esp is then never set, so rsp keeps the
# UNDEFINED high half the 32-bit handoff left; the body's first push addresses outside the low-1-GiB map
# -> #PF -> triple-fault. Also: no `bc` at long_entry -> the mov-esp white-box pin fires.
# Anchor extends through the long64 driver's 64-bit rbp prologue (`if nlocals > 0:` then do-append-72,
# the REX.W mov rbp,rsp) so it pins THIS driver's mov esp EXACTLY: trikea/f2 inserted that prologue
# between the mov esp and the body append (so the old append_str anchor drifted to 0), and the toakie
# driver shares `188 / esp_val / if nlocals>0:` but follows it with do-append-137 (32-bit mov ebp,esp),
# not 72 -- so this stays long64-unique.
mutate movesp \
'    do append(cbuf, 188)
    cbuf = nc_append_le32(cbuf, esp_val)
    if nlocals > 0:
        do append(cbuf, 72)' \
'    do append(cbuf, 189)
    cbuf = nc_append_le32(cbuf, esp_val)
    if nlocals > 0:
        do append(cbuf, 72)'

# M-Lbit: clear the GDT 64-bit code descriptor L-bit (flags 0xAF -> 0xCF) in the SHARED nc32_long_emit_gdt.
# The far-jmp then loads a 32-bit (L=0,D=1) descriptor -> COMPATIBILITY mode; the identical REX.W body
# decodes 32-bit -> wrong byte (silicon). Caught by the GDT L=1 / L0-mask pin.
mutate Lbit \
'    do append(buf, 154)
    do append(buf, 175)
    do append(buf, 0)' \
'    do append(buf, 154)
    do append(buf, 207)
    do append(buf, 0)'

# M-lme: EFER.LME (or eax,0x100 -> or eax,0) in the SHARED transition head. LME never set -> CR0.PG does
# NOT enter IA-32e -> the L=1 ljmp runs 16-bit -> garbage -> triple-fault (no frame).
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

# M-pml4: clear PML4[0] present (pdpt_vaddr + 3 -> + 2) in the SHARED nc32_long_emit_pml4. The first
# 64-bit fetch walks a not-present PML4E -> #PF with no IDT -> triple-fault (no frame).
mutate pml4 \
'    buf = nc_append_le32(buf, pdpt_vaddr + 3)' \
'    buf = nc_append_le32(buf, pdpt_vaddr + 2)'

# M-hardcode: epilogue `mov bl,al` (88 c3 -- take the body's shr output) -> `mov bl,0x01` (b3 01 --
# hardcode the golden byte). The body's high dword is DISCARDED; the framed byte is a constant. The same
# byte 0x01 still boots (BEHAVIORALLY INVISIBLE) -- caught ONLY by the body-result -> shr -> frame
# data-flow pin (58 48c1e820 88c3 no longer matches once 88c3 becomes b301).
mutate hardcode \
'    do append(buf, 136)
    do append(buf, 195)' \
'    do append(buf, 179)
    do append(buf, 1)'

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link26-mutation check(s) failed."; exit 1; fi
echo "PASS: link26 mutation proof ($pass checks: control passes head+entry+gdt(L=1)+L0-mask+data-flow+mov-esp+emit+body-REX.W+boot; 8 mutations each CAUGHT -- M-bodymul (nc_emit_mul REX.W -> nop: the body's multiply is 32-bit non-widening -> high dword 0 -> byte 0x00 + a 32-bit GPR in the body disasm) by the body REX.W pin / boot; M-shr (shr count 0x20->0) and M-shrrexw (shr REX.W -> nop) by the body-result->shr->frame data-flow pin; M-movesp (mov esp -> mov ebp: rsp keeps its undefined high half -> the body's push faults outside the low-1-GiB map) by the mov-esp pin / boot; M-Lbit (GDT L-bit -> compatibility mode -> the REX.W body decodes 32-bit) by the GDT pin / boot; M-lme (drop EFER.LME) and M-pml4 (clear PML4[0] present) -> triple-fault on silicon; M-hardcode (epilogue 'mov bl,al' -> 'mov bl,0x01': the body's high dword is discarded and the framed byte is the constant 0x01 -- BEHAVIORALLY INVISIBLE, the same byte still boots -- caught ONLY by the contiguous body-result->shr->frame data-flow pin) -- so the genuine 64-bit COMPILED body, the REX.W widening multiply, the rsp zero-extension, the high-dword shr, the long-mode transition, and the unbroken body->byte data-flow are all proven load-bearing; the byte cannot appear without a genuine 64-bit-lowered body in true long mode whose own result flows into the emit)"
exit 0
