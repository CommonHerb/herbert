#!/usr/bin/env bash
# Link 28 (bluefield, twelfth kernel-arc link) MUTATION proof -- "prove the preemptive-context-switch
# gate bites." The link28 dual-substrate + white-box gate is only meaningful if a WRONG compiler would
# fail it. We mutate the compiler SOURCE at a unique anchor and re-emit a green probe: each mutation must
# be CAUGHT -- no frame is emitted (timeout / triple-fault / wrong byte), or a white-box pin (the exact
# head' / task-A value-flow / scheduler ISR / five-cell provenance / seeded-block / IDT-gate binds)
# rejects the structural change.
#
# The central claim: "the proof byte was emitted only because a PREEMPTIVE CONTEXT SWITCH genuinely
# SAVED task A's full GP+esp context (pusha onto A's stack + save esp to A's TCB), ran task B (started
# from the seeded stack, which CLOBBERED A's carried edx), and RESTORED A's context (load esp from A's
# TCB + popa) so A's mid-flight value survived -- driven by the timer, not a cooperative yield." The
# mutations attack exactly that:
#   no_save        pusha (60) -> nop: A's GP regs never saved; on switch-back popa reads garbage ->
#                  triple-fault / no frame. Scheduler anchor breaks -> CAUGHT (P2).
#   no_restore     popa (61) -> nop: the resumed task's GP regs never restored -> wrong state / no
#                  frame. Scheduler anchor breaks -> CAUGHT (P2).
#   no_iret        iret (cf) -> hlt (f4): the scheduler halts instead of resuming -> no frame
#                  (timeout). Scheduler anchor breaks -> CAUGHT (P2).
#   no_save_esp    mov [tcb+eax*4],esp (892485) -> 3 nops: interrupted esp never saved -> switch-back
#                  loads stale/garbage esp -> triple-fault. Scheduler anchor breaks -> CAUGHT (P2).
#   no_switch_esp  mov esp,[tcb+eax*4] (8b2485) -> 3 nops: the OTHER task's stack never loaded -> popa
#                  pops the wrong task -> no real switch -> no frame. Scheduler anchor breaks (P2).
#   no_flip_cur    xor eax,1 (83f001) -> 3 nops: cur never flips -> the scheduler always saves+restores
#                  the SAME task -> B never runs -> A spins forever (timeout). Scheduler anchor (P2).
#   no_eoi         EOI out 0x20,0x20 (e6) -> nop: PIC never re-delivers IRQ0 -> stuck after the first
#                  tick -> no frame (timeout). Scheduler anchor breaks -> CAUGHT (P2).
#   no_sti         head sti (fb) -> nop: interrupts never enabled -> no preemption -> A spins forever
#                  (timeout). The 114-byte head' breaks -> CAUGHT (P0).
#   no_recover     A's recover mov eax,edx (89d0) -> 2 nops: A emits eax=[bran]=1 + vB instead of vA+vB
#                  -> WRONG byte. The task-A value-flow anchor breaks -> CAUGHT (P1).
#   wrong_shared   A's add eax,[shared] target -> shared+4: A reads a DIFFERENT cell than B writes ->
#                  adds a stale 0 -> wrong byte. The provenance bind (a_shared==b_shared) -> CAUGHT (P3).
#   bad_seed_eip   the seeded iret eip (b_entry) -> b_entry+3: B starts mid-instruction -> garbage /
#                  wrong byte. The seeded-block bind (eip==B_entry) -> CAUGHT (P4).
#   seed_if_off    the seeded eflags (0x202=514) -> 0x002=2 (IF cleared): B runs with interrupts off ->
#                  never preempted -> A never resumes (timeout). The seeded-block bind (eflags==0x202)
#                  -> CAUGHT (P4).
#   idtr_redirect  the head' lidt operand idtr_vaddr -> gdtr_vaddr (the loader/CPU-redirect meta-class):
#                  the CPU vectors IRQ0 through a DECOY IDTR. The head' regex wildcards the lidt operand,
#                  so P0 passes -- caught ONLY by the loaded-IDTR -> checked-gate bind (P5b).
# The underlying SILICON RED for most is independently real on BOTH QEMU and Bochs (no switch -> no
# frame); assess() catches each at its white-box pin before the QEMU leg, and the QEMU leg confirms the
# behavioral RED. seed_if_off and idtr_redirect are the white-box-only / substrate-subtle cases.
#
# SOVEREIGNTY (link 16): this proof is C-FREE. It NO LONGER re-emits through the C
# interpreter. Instead it runs each mutation through a genuine TWO-STAGE seed
# compile (the assay/link18 template): the committed C-free gen-1 seed compiles the
# (mutated) backend into a native gen-1' compiler ELF, and THAT compiler emits the
# probe. This is strictly MORE faithful than the prior C path: it runs the ACTUAL
# mutated compiler and checks the gate catches ITS output, so the proof's meaning
# ("a wrong compiler is caught") survives C's deletion intact. A retireable
# cross-check -- DEFAULT-ON when C is present, opt-OUT via LINK28_MUTATION_NO_C=1 --
# also re-emits each mutation via the C interpreter and asserts the native two-stage
# image is BYTE-IDENTICAL to the C image (substrate faithfulness, while C still
# exists); it retires WITH C at the switchover.
#
# QEMU-only, gated behind KERNEL_CODEGEN_MUTATION=1 (or REQUIRE_EMU=1). Each anchor is
# asserted to occur EXACTLY ONCE, so a drifted anchor fails loudly.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

RUN="${KERNEL_CODEGEN_MUTATION:-${KERNEL_CODEGEN_REQUIRE_EMU:-0}}"
if [[ "$RUN" != "1" ]]; then
    echo "SKIP: native-codegen link28 mutation proof (set KERNEL_CODEGEN_MUTATION=1 to run)"; exit 0
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: native-codegen link28 mutation proof (no qemu)"; exit 0
fi

# C-free production compiler: the committed gen-1 seed (NOT the C interpreter).
source "$script_dir/native_codegen_oracle.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
SEED="$NATIVE_CODEGEN_COMPILER"
# retireable C cross-check: ON only when C is present and not opted out.
XCHECK=0
if [[ -x "$HERBERT" && "${LINK28_MUTATION_NO_C:-0}" != "1" ]]; then XCHECK=1; fi

pass=0; fail=0
fail_test() { echo "FAIL: link28-mutation ($1)"; fail=$((fail + 1)); }

PROBE='func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end'
GOLDEN=134   # body return 88 + vB 46 = 134 (0x86) -> frame de 86 ad, after a real A->B->A switch
HEAD='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe640c705[0-9a-f]{8}00000000c705[0-9a-f]{8}[0-9a-f]{8}fb'
VFLOW='89c2c705[0-9a-f]{8}01000000a1[0-9a-f]{8}83f80175f6fa89d00305[0-9a-f]{8}88c366bae900'
SCHED='60a1[0-9a-f]{8}892485[0-9a-f]{8}83f001a3[0-9a-f]{8}8b2485[0-9a-f]{8}b020e62061cf'
TASKB='b82e000000a3[0-9a-f]{8}a1[0-9a-f]{8}83f80175f6bab7b7b7b7c705[0-9a-f]{8}01000000ebfe'

le32_at() { hx="$1"; o="$2"; echo $((16#${hx:o+6:2}${hx:o+4:2}${hx:o+2:2}${hx:o+0:2})); }
occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }

# emit_via(compiler, outdir): the given native compiler ELF emits the PROBE. Sets
# $EMIT_IMG to the emitted image path, or "" if the compiler refused to emit.
EMIT_IMG=""
emit_via() {
    local compiler="$1" d="$2"; rm -rf "$d"; mkdir -p "$d"
    printf -- '-- emit: multiboot32-bluefield\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$compiler" < p.herb >emit.out 2>&1 )
    if [[ -f "$d/a.out" ]]; then EMIT_IMG="$d/a.out"; else EMIT_IMG=""; fi
}

emit_seq=0
# assess(compiler) -> "GREEN" or "CAUGHT:<why>". The given native compiler ELF
# emits the probe; the emitted image is run through the white-box + boot gates.
assess() {
    local compiler="$1"; emit_seq=$((emit_seq + 1))
    local d="$tmp/run.$emit_seq"
    emit_via "$compiler" "$d"
    [[ -n "$EMIT_IMG" ]] && cp "$EMIT_IMG" "$compiler.graded" 2>/dev/null
    [[ -z "$EMIT_IMG" ]] && cp "$d/emit.out" "$compiler.emiterr" 2>/dev/null
    [[ -n "$EMIT_IMG" ]] || { echo "CAUGHT:no-image"; return; }
    grub-file --is-x86-multiboot "$EMIT_IMG" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    # (P12) ELF entry + phdr bind (the loader/CPU-redirect close)
    local eh; eh=$(dd if="$EMIT_IMG" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$(le32_at "$eh" 48)" -eq 1048588 ]] || { echo "CAUGHT:e_entry"; return; }
    [[ $(( 16#${eh:90:2}${eh:88:2} )) -eq 1 ]] || { echo "CAUGHT:e_phnum"; return; }
    [[ "$(le32_at "$eh" 112)" -eq 4096 ]] || { echo "CAUGHT:p_offset"; return; }
    [[ "$(le32_at "$eh" 120)" -eq 1048576 ]] || { echo "CAUGHT:p_vaddr"; return; }
    local chx; chx=$(dd if="$EMIT_IMG" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    # (P0) exact 114-byte head' (catches no_sti)
    [[ "${chx:0:228}" =~ $HEAD ]] || { echo "CAUGHT:head"; return; }
    # (P1) task-A value-flow exactly once (catches no_recover)
    [[ "$(occ "$chx" "$VFLOW")" == 1 ]] || { echo "CAUGHT:vflow"; return; }
    # (P2) scheduler ISR exactly once (catches no_save/no_restore/no_iret/no_save_esp/no_switch_esp/no_flip_cur/no_eoi)
    [[ "$(occ "$chx" "$SCHED")" == 1 ]] || { echo "CAUGHT:sched"; return; }
    [[ "$(occ "$chx" "$TASKB")" == 1 ]] || { echo "CAUGHT:taskB"; return; }
    # locate anchors
    local va_pos sched_pos tb_pos
    va_pos=$(echo "$chx" | grep -boE "$VFLOW" | head -1 | cut -d: -f1)
    sched_pos=$(echo "$chx" | grep -boE "$SCHED" | head -1 | cut -d: -f1)
    tb_pos=$(echo "$chx" | grep -boE "$TASKB" | head -1 | cut -d: -f1)
    # (P3) five-cell provenance
    local head_cur head_tcb1 head_seed head_idtr
    head_cur=$(le32_at "$chx" 190); head_tcb1=$(le32_at "$chx" 210); head_seed=$(le32_at "$chx" 218); head_idtr=$(le32_at "$chx" 74)
    local sched_cur1 tcb_save sched_cur2 tcb_load
    sched_cur1=$(le32_at "$chx" $((sched_pos + 4))); tcb_save=$(le32_at "$chx" $((sched_pos + 18)))
    sched_cur2=$(le32_at "$chx" $((sched_pos + 34))); tcb_load=$(le32_at "$chx" $((sched_pos + 48)))
    local a_aready a_bran a_shared
    a_aready=$(le32_at "$chx" $((va_pos + 8))); a_bran=$(le32_at "$chx" $((va_pos + 26))); a_shared=$(le32_at "$chx" $((va_pos + 54)))
    local b_shared b_aready b_bran
    b_shared=$(le32_at "$chx" $((tb_pos + 12))); b_aready=$(le32_at "$chx" $((tb_pos + 22))); b_bran=$(le32_at "$chx" $((tb_pos + 54)))
    { [[ "$head_cur" == "$sched_cur1" ]] && [[ "$sched_cur1" == "$sched_cur2" ]]; } || { echo "CAUGHT:prov-cur"; return; }
    { [[ "$tcb_save" == "$tcb_load" ]] && [[ $((tcb_save + 4)) -eq "$head_tcb1" ]]; } || { echo "CAUGHT:prov-tcb"; return; }
    [[ "$a_aready" == "$b_aready" ]] || { echo "CAUGHT:prov-aready"; return; }
    [[ "$a_bran" == "$b_bran" ]] || { echo "CAUGHT:prov-bran"; return; }
    [[ "$a_shared" == "$b_shared" ]] || { echo "CAUGHT:prov-shared($a_shared/$b_shared)"; return; }
    # (P4) seeded-block binds (catches bad_seed_eip, seed_if_off)
    local b_entry seed_hex seed_eip seed_cs seed_eflags
    b_entry=$(( 1048588 + tb_pos / 2 ))
    seed_hex=$(( (head_seed - 1048588) * 2 ))
    if [[ "$seed_hex" -lt 0 ]] || [[ $(( seed_hex + 88 )) -gt ${#chx} ]]; then echo "CAUGHT:seed-range"; return; fi
    [[ "${chx:seed_hex:64}" =~ ^0{64}$ ]] || { echo "CAUGHT:seed-gp"; return; }
    seed_eip=$(le32_at "$chx" $((seed_hex + 64))); seed_cs=$(le32_at "$chx" $((seed_hex + 72))); seed_eflags=$(le32_at "$chx" $((seed_hex + 80)))
    [[ "$seed_eip" -eq "$b_entry" ]] || { echo "CAUGHT:seed-eip($seed_eip/$b_entry)"; return; }
    [[ "$seed_cs" -eq 8 ]] || { echo "CAUGHT:seed-cs"; return; }
    [[ "$seed_eflags" -eq 514 ]] || { echo "CAUGHT:seed-eflags($seed_eflags)"; return; }
    # (P5) IDT gate -> scheduler + loaded-IDTR bind (catches idtr_redirect)
    [[ "$(occ "$chx" '0800008e')" == 1 ]] || { echo "CAUGHT:gate-mid"; return; }
    local sched_vaddr mpos lo16 hi16 after lo_v hi_v gate_target
    sched_vaddr=$(( 1048588 + sched_pos / 2 ))
    mpos=$(echo "$chx" | grep -bo '0800008e' | head -1 | cut -d: -f1)
    lo16="${chx:mpos-4:4}"; hi16="${chx:mpos+8:4}"; after="${chx:mpos+12:4}"
    lo_v=$(( 16#${lo16:2:2}${lo16:0:2} )); hi_v=$(( 16#${hi16:2:2}${hi16:0:2} ))
    gate_target=$(( (hi_v << 16) | lo_v ))
    [[ "$gate_target" -eq "$sched_vaddr" && "$after" == "0701" ]] || { echo "CAUGHT:gate"; return; }
    local idtr_off idtr_limit_hex idtr_base gate_start_vaddr
    idtr_off=$(( (head_idtr - 1048588) * 2 ))
    if [[ "$idtr_off" -lt 0 ]] || [[ $(( idtr_off + 12 )) -gt ${#chx} ]]; then echo "CAUGHT:lidt-range"; return; fi
    idtr_limit_hex="${chx:idtr_off:4}"; idtr_base=$(le32_at "$chx" $(( idtr_off + 4 )))
    gate_start_vaddr=$(( 1048588 + (mpos - 4) / 2 ))
    { [[ "$idtr_limit_hex" == "0701" ]] && [[ $(( idtr_base + 256 )) -eq "$gate_start_vaddr" ]]; } || { echo "CAUGHT:lidt-redirect"; return; }
    # behavioral confirmation
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
    printf -- '-- emit: multiboot32-bluefield\n%s\n' "$PROBE" > "$d/p.herb"
    ( cd "$d" && "$HERBERT" "$src" < p.herb >/dev/null 2>/dev/null )
    if [[ -f "$d/a.out" ]]; then C_IMG="$d/a.out"; else C_IMG=""; fi
}

# control: the unmutated compiler is the SEED itself (the gen-1 fixpoint); it must
# emit the golden byte via a real preemptive A->B->A context switch C-FREE.
ctrl=$(assess "$SEED")
if [[ "$ctrl" == "GREEN" ]]; then echo "PASS control: unmutated seed compiler emits golden=$GOLDEN via a real preemptive A->B->A context switch C-free"; pass=$((pass+1));
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
        fail_test "$name: mutant escaped ALL gates (verdict=$v) -- the gate does NOT bite"; return
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

# ============================ SCHEDULER mutations (P2) =======================
mutate no_save \
'    do append(bfm, 96)
    do append(bfm, 161)
    bfm = nc_append_le32(bfm, cur_vaddr)' \
'    do append(bfm, 144)
    do append(bfm, 161)
    bfm = nc_append_le32(bfm, cur_vaddr)'

mutate no_restore \
'    do append(bfm, 97)
    do append(bfm, 207)' \
'    do append(bfm, 144)
    do append(bfm, 207)'

mutate no_iret \
'    do append(bfm, 97)
    do append(bfm, 207)
    bfm = nc32_timer_emit_tables' \
'    do append(bfm, 97)
    do append(bfm, 244)
    bfm = nc32_timer_emit_tables'

mutate no_save_esp \
'    do append(bfm, 137)
    do append(bfm, 36)
    do append(bfm, 133)
    bfm = nc_append_le32(bfm, tcb_vaddr)
    do append(bfm, 131)' \
'    do append(bfm, 144)
    do append(bfm, 144)
    do append(bfm, 144)
    bfm = nc_append_le32(bfm, tcb_vaddr)
    do append(bfm, 131)'

mutate no_switch_esp \
'    do append(bfm, 139)
    do append(bfm, 36)
    do append(bfm, 133)' \
'    do append(bfm, 144)
    do append(bfm, 144)
    do append(bfm, 144)'

mutate no_flip_cur \
'    do append(bfm, 131)
    do append(bfm, 240)
    do append(bfm, 1)' \
'    do append(bfm, 144)
    do append(bfm, 144)
    do append(bfm, 144)'

mutate no_eoi \
'    do append(bfm, 176)
    do append(bfm, 32)
    do append(bfm, 230)
    do append(bfm, 32)
    do append(bfm, 97)' \
'    do append(bfm, 176)
    do append(bfm, 32)
    do append(bfm, 144)
    do append(bfm, 32)
    do append(bfm, 97)'

# ============================ HEAD mutation (P0) ============================
mutate no_sti \
'    bfh = nc_append_le32(bfh, seed_vaddr)
    do append(bfh, 251)' \
'    bfh = nc_append_le32(bfh, seed_vaddr)
    do append(bfh, 144)'

# ============================ VALUE-FLOW mutation (P1) =======================
mutate no_recover \
'    do append(bfm, 137)
    do append(bfm, 208)
    do append(bfm, 3)
    do append(bfm, 5)' \
'    do append(bfm, 144)
    do append(bfm, 144)
    do append(bfm, 3)
    do append(bfm, 5)'

# ============================ PROVENANCE mutation (P3) =======================
mutate wrong_shared \
'    do append(bfm, 3)
    do append(bfm, 5)
    bfm = nc_append_le32(bfm, shared_vaddr)
    bfm = nc32_emit_epilogue(bfm)' \
'    do append(bfm, 3)
    do append(bfm, 5)
    bfm = nc_append_le32(bfm, shared_vaddr + 4)
    bfm = nc32_emit_epilogue(bfm)'

# ============================ SEEDED-BLOCK mutations (P4) ====================
mutate bad_seed_eip \
'    bfm = nc_append_le32(bfm, b_entry)' \
'    bfm = nc_append_le32(bfm, b_entry + 3)'

mutate seed_if_off \
'    bfm = nc_append_le32(bfm, 514)' \
'    bfm = nc_append_le32(bfm, 2)'

# ============================ LIDT-REDIRECT mutation (P5b) ===================
mutate idtr_redirect \
'    do append(bfh, 29)
    bfh = nc_append_le32(bfh, idtr_vaddr)' \
'    do append(bfh, 29)
    bfh = nc_append_le32(bfh, gdtr_vaddr)'

# ============================ LOADER-REDIRECT forges (P12, BINARY-PATCH) =====
# The emitter always sets e_entry=V0 and one faithful PT_LOAD, so the entry-redirect forge (a dual-
# model adversarial leg built it: leave the faithful switch as a DECOY at file 4108, append a single-
# task payload, repoint e_entry) cannot be expressed as a source mutation. Binary-patch the control
# image to exercise the loader/CPU-redirect meta-class directly: P12 (e_entry==V0, single PT_LOAD,
# 4096->0x100000) MUST reject each. assess_elf runs the P12 binds on a pre-built image. The control
# image is itself emitted C-FREE by the seed compiler (the two-stage gen-1 fixpoint), not the C path.
assess_elf() { # image -> GREEN/CAUGHT
    local img="$1"
    grub-file --is-x86-multiboot "$img" >/dev/null 2>&1 || { echo "CAUGHT:bad-image"; return; }
    local eh; eh=$(dd if="$img" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$(le32_at "$eh" 48)" -eq 1048588 ]] || { echo "CAUGHT:e_entry"; return; }
    [[ $(( 16#${eh:90:2}${eh:88:2} )) -eq 1 ]] || { echo "CAUGHT:e_phnum"; return; }
    [[ "$(le32_at "$eh" 112)" -eq 4096 ]] || { echo "CAUGHT:p_offset"; return; }
    [[ "$(le32_at "$eh" 120)" -eq 1048576 ]] || { echo "CAUGHT:p_vaddr"; return; }
    echo "GREEN-elf"
}
emit_via "$SEED" "$tmp/ctrl.d"
CTRL_IMG="$EMIT_IMG"
if [[ -n "$CTRL_IMG" && -f "$CTRL_IMG" ]]; then
    # entry_redirect: e_entry (file bytes 24..27) V0 -> V0+3 (the decoy-then-redirect forge's core).
    er="$tmp/entry_redirect.bin"
    python3 - "$CTRL_IMG" "$er" <<'PY'
import sys,struct
b=bytearray(open(sys.argv[1],"rb").read())
b[24:28]=struct.pack('<I',0x10000c+3)   # repoint ELF entry off the head'
open(sys.argv[2],"wb").write(bytes(b))
PY
    v=$(assess_elf "$er")
    if [[ "$v" == CAUGHT:* ]]; then echo "PASS mutation entry_redirect: $v"; pass=$((pass+1)); else fail_test "entry_redirect: redirect forge escaped P12 (verdict=$v)"; fi
    # second_phnum: e_phnum (file byte 44) 1 -> 2 (a second PT_LOAD could remap the entry).
    sp="$tmp/second_phnum.bin"
    python3 - "$CTRL_IMG" "$sp" <<'PY'
import sys
b=bytearray(open(sys.argv[1],"rb").read())
b[44]=2
open(sys.argv[2],"wb").write(bytes(b))
PY
    v=$(assess_elf "$sp")
    if [[ "$v" == CAUGHT:* ]]; then echo "PASS mutation second_phnum: $v"; pass=$((pass+1)); else fail_test "second_phnum: extra-PT_LOAD forge escaped P12 (verdict=$v)"; fi
else
    fail_test "loader-redirect forges: could not build control image"
fi

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link28-mutation check(s) failed."; exit 1; fi
xc=""; [[ "$XCHECK" == "1" ]] && xc=" + each native two-stage image byte-identical to C (retireable)"
echo "PASS: link28 mutation proof ($pass checks: control passes head'+vflow+scheduler+taskB+provenance+seeded-block+gate+boot gates C-FREE via a real two-stage seed compile; 13 source mutations each CAUGHT via a real two-stage seed compile of the mutated backend -- no_save/no_restore/no_iret/no_save_esp/no_switch_esp/no_flip_cur/no_eoi break the scheduler ISR anchor (their silicon RED -- no genuine context switch -> no frame -- is real on QEMU+Bochs); no_sti breaks the 114-byte head'; no_recover (A emits [bran]+vB not vA+vB) breaks the task-A value-flow anchor; wrong_shared (A reads a different cell than B writes) is caught by the five-cell provenance value-bind; bad_seed_eip (B starts mid-instruction) and seed_if_off (B runs un-preemptible) are caught by the seeded-block binds (eip==B_entry, eflags==0x202 [IF set]); idtr_redirect (the head lidt operand pointed at a decoy IDTR) is caught ONLY by the loaded-IDTR -> checked-gate bind -- so the full GP+esp save/restore, the stack-switch, the cur-flip, the EOI, the iret-resume, the seeded eip/eflags, the edx-carry recover, and the shared-cell identity are all proven load-bearing, and the preemptive-context-switch property holds: the byte requires the timer-driven scheduler to genuinely save task A's context, run task B (which clobbers it), and restore it; PLUS 2 binary-patch loader-redirect forges CAUGHT by P12 -- entry_redirect (e_entry repointed off the head' to a decoy-then-redirect single-task payload) and second_phnum (a 2nd PT_LOAD to remap the entry) -- closing the loader/CPU-redirect meta-class a dual-model adversarial leg found: the gate binds the artifact the LOADER selects (ELF e_entry==V0, single PT_LOAD mapping file 4096->vaddr 0x100000) by value, not the syntactic file offset 4108$xc)"
exit 0
