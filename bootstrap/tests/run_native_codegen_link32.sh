#!/usr/bin/env bash
# Native codegen Link 32 (cloggard / the SIXTEENTH kernel-arc link): the first DATA-DEPENDENT
# MULTI-QUANTUM scheduler. contigo (link31) made a SINGLE one-shot data-dependent dispatch and
# halted; bluefield (link28) did a SINGLE warm context switch with a BLIND schedule. cloggard
# composes both into a SEQUENCE: a timer-IRQ0 run-queue dispatches K=4 WARM tasks over multiple
# quanta, emitting an ordered TRACE on 0xE9, the schedule being a function of runtime input
# recomputed EACH quantum inside the ISR (next = (inq >> pos) & 1). Selected by the anchored
# first-line directive "-- emit: multiboot32-cloggard" (a 16th emit mode; the 15 prior modes are
# byte-identical, so the self-host fixpoint gen2==gen1 holds). Graded, like lingo..contigo, on the
# far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs vs a HOST-derived golden), with trukfit's LATE-BOUND
# INPUT SUBSTRATE (socket-backed COM1).
#
# WHY GENUINELY NEW (not "contigo with a loop"): the white-box gate proves an ORDERED MULTI-BYTE
# trace whose order is per-quantum input-recomputed across genuinely-WARM quanta:
#  (1) the schedule is a SEQUENCE -- the scheduler recomputes next=(inq>>pos)&1 reading [inq] K
#      times inside vec-0x20 (not a one-shot head precompute);
#  (2) WARM -- the dispatched task RESUMES (its register accumulator survives preemptions via the
#      scheduler's pusha-save to tcb[cur] + restore from the SAME slot); trace-equality alone does
#      NOT witness warmth (cold re-dispatch with per-quantum seeds fakes the increments), so warmth
#      is bound WHITE-BOX by a PROVENANCE pin: the only writes to a tcb slot are the head init and
#      the scheduler's single indexed save; each task's emitted byte dataflows from a warm REGISTER
#      accumulator + a fixed marker (never an indexed memory read);
#  (3) the emit (the framed 0xE9 write) occurs ONLY in a task body (exactly twice, one per task),
#      ZERO in head/scheduler -- reached ONLY via the scheduler's iret;
#  (4) the DONE-FLAG INTERLOCK: the scheduler advances ONLY on [done]==1 (else absorbs the tick),
#      so each grant is bounded to one unit and the K-byte trace is bit-identical on both substrates.
#
# HONEST SCOPE: a CANONICAL-CODEGEN proof for the fixed probes (echo/branch/locals/31-local cap),
# not general scheduler semantics; 32-bit PM; K=4 grants, two tasks; emulator-graded, emulators
# unpinned; the input-DELIVERY fact + schedule correctness are the audited-assertion residue,
# minimized by dual-substrate AGREEMENT + the host-chosen late-bound value + the value-flow/locus/
# provenance gate. Pays nothing new on the ledger (D18 port-input core paid by trukfit; D3 MMIO
# residue untouched) -- a far-axis CAPABILITY link (first multi-quantum data-dependent schedule).
#
# Determinism note (HONEST silicon/white-box split, confirmed by the empirical pre-build): the
# SILICON determinism mechanism is the HLT-park (bounds each grant to <=1 unit) + the slow PIT
# (divisor 0xFFFF) margin (>=1 unit). The DONE-FLAG INTERLOCK is the STRUCTURAL backstop and is
# WHITE-BOX-pinned (silicon-silent with the slow PIT, like contigo's EOI/eflags/THRESH).
#
# The held-back MUTATION proof (run_native_codegen_link32_mutation.sh) binary-patches a compiled
# probe to prove each load-bearing byte bites.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L16_BOCHS_PROBES:-cg_lit cg_then}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

# ---- the EXACT pinned byte templates (host-derived; see the empirical pre-build) -----------
# the exact 224-byte HEAD (only the 11 le32 fields vary: gdtr/esp/idtr/inq + 5 init stores' addr/value).
HEAD_RE='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003eeb011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe64066bafd03eca80174f766baf803ec0fb6c0a3[0-9a-f]{8}c705[0-9a-f]{8}00000000c705[0-9a-f]{8}01000000c705[0-9a-f]{8}02000000c705[0-9a-f]{8}[0-9a-f]{8}c705[0-9a-f]{8}[0-9a-f]{8}fbebfe$'
# the exact 128-byte SCHEDULER. Fixed bytes pin: EOI(b020e620); pusha(60); the DONE-FLAG INTERLOCK
# (85c0 test [done]; 7449 jz absorb); the EXIT gate (83f804 cmp pos,K=4; 7341 jae exit); the IDLE
# skip (83f802 cmp cur,2; 7407 je); the per-quantum BIT-SELECT (d3e8 shr eax,cl; 83e001 and eax,1
# -> next=(inq>>pos)&1); the done=0 advance store value (00000000); the warm save/restore indexed
# moves (892485/8b2485 mov [tcb+eax*4],esp / mov esp,[tcb+eax*4]); two popa;iret (dispatch+absorb);
# the exit block (isa-debug-exit + "Shutdown" + cli;hlt;jmp$). The 10 le32 cell addrs vary.
SCHED_RE='b020e62060a1[0-9a-f]{8}85c07449a1[0-9a-f]{8}83f8047341a1[0-9a-f]{8}83f8027407892485[0-9a-f]{8}8b0d[0-9a-f]{8}a1[0-9a-f]{8}d3e883e001a3[0-9a-f]{8}ff05[0-9a-f]{8}c705[0-9a-f]{8}000000008b2485[0-9a-f]{8}61cf61cf66baf400b000ee66ba0089b053eeb068eeb075eeb074eeb064eeb06feeb077eeb06eeefaf4ebfd'
FRAME_HEX='88c366bae900b0deee88d8eeb0adee'   # the framed 0xE9 emit (al -> "DE al AD")
K=4
MARKERB=176

# ---- probes: vary the compiled body -> vA (the canonical-codegen proof) ---------------------
prog_src() {
    case "$1" in
      cg_then)    echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      cg_else)    echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      cg_lit)     echo 'func main(): return 88 end' ;;
      cg_nolocal) echo 'func main(): return 77 end' ;;
      cg_cap31)   gen_locals 31 a ;;
    esac
}
gen_locals() { local n="$1" pfx="$2" s='func main():' i; for i in $(seq 0 $((n-1))); do s="$s let $pfx$i = $i"; done; echo "$s return $pfx$((n-1)) end"; }
host_vA() { case "$1" in cg_then) echo 88 ;; cg_else) echo 11 ;; cg_lit) echo 88 ;; cg_nolocal) echo 77 ;; cg_cap31) echo 30 ;; esac; }
probe_nlocals() { case "$1" in cg_then|cg_else) echo 1 ;; cg_cap31) echo 31 ;; *) echo 0 ;; esac; }
ALL_PROBES="cg_then cg_else cg_lit cg_nolocal cg_cap31"
# host-side golden trace: schedule = low-K bits of inq; task t emits "DE (base[t]+acc_t) AD".
host_trace() { python3 -c "
inq=$1; vA=$2; K=$3; mB=$MARKERB; base=[vA,mB]; s=[0,0]; out=''
for pos in range(K):
    t=(inq>>pos)&1; s[t]+=1; out+='de%02xad'%((base[t]+s[t])&0xFF)
print(out)"; }
X=10    # 0x0A -> schedule A,B,A,B  (both tasks warm-accumulate; trace = vA+1,mB+1,vA+2,mB+2)
Y=5     # 0x05 -> schedule B,A,B,A  (reversed -- a different ordered sequence)

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-cloggard\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

static_gates() { # label elf
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx; hx=$(xxd -p "$elf" | tr -d '\n')
    local mb_o mb_valid_count=0 mb_valid_off=-1 mb_f mb_c
    for (( mb_o=0; mb_o+12 <= 8192 && mb_o*2+24 <= ${#hx}; mb_o+=4 )); do
        [[ "${hx:$(( mb_o*2 )):8}" == "02b0ad1b" ]] || continue
        mb_f=$(le32_val "$hx" $(( mb_o*2 + 8 ))); mb_c=$(le32_val "$hx" $(( mb_o*2 + 16 )))
        if [[ $(( (16#1BADB002 + mb_f + mb_c) % (1 << 32) )) -eq 0 ]]; then
            mb_valid_count=$(( mb_valid_count + 1 )); mb_valid_off=$mb_o
        fi
    done
    [[ "$mb_valid_count" -eq 1 ]] || { fail_test "$label static: $mb_valid_count checksum-valid Multiboot headers (want 1)"; ok=0; }
    [[ "$mb_valid_off" -eq 4096 ]] || { fail_test "$label static: valid MB header at off $mb_valid_off (want 4096)"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

elf_gates() { # label elf  (P12: e_entry==V0, single PT_LOAD, sizes by value)
    local label="$1" elf="$2" ok=1
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local e_entry e_phoff e_phnum
    e_entry=$(le32_val "$eh" 48); e_phoff=$(le32_val "$eh" 56); e_phnum=$(( 16#${eh:90:2}${eh:88:2} ))
    [[ "$e_entry" -eq 1048588 ]] || { fail_test "$label elf(P12): e_entry ($e_entry) != 1048588 (V0)"; ok=0; }
    [[ "$e_phoff" -eq 52 ]] || { fail_test "$label elf(P12): e_phoff ($e_phoff) != 52"; ok=0; }
    [[ "$e_phnum" -eq 1 ]] || { fail_test "$label elf(P12): e_phnum ($e_phnum) != 1"; ok=0; }
    local p_type p_offset p_vaddr p_flags p_paddr
    p_type=$(le32_val "$eh" 104); p_offset=$(le32_val "$eh" 112); p_vaddr=$(le32_val "$eh" 120); p_flags=$(le32_val "$eh" 152)
    p_paddr=$(le32_val "$eh" 128)
    [[ "$p_type" -eq 1 ]] || { fail_test "$label elf(P12): PT_LOAD type ($p_type) != 1"; ok=0; }
    [[ "$p_offset" -eq 4096 ]] || { fail_test "$label elf(P12): p_offset ($p_offset) != 4096"; ok=0; }
    [[ "$p_vaddr" -eq 1048576 ]] || { fail_test "$label elf(P12): p_vaddr ($p_vaddr) != 1048576"; ok=0; }
    [[ "$p_paddr" -eq 1048576 ]] || { fail_test "$label elf(P12): p_paddr ($p_paddr) != 1048576"; ok=0; }
    [[ "$p_flags" -eq 7 ]] || { fail_test "$label elf(P12): p_flags ($p_flags) != 7"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$work/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    local nlocals; nlocals=$(probe_nlocals "$label")
    local ebp_prefix=0; [[ "$nlocals" -gt 0 ]] && ebp_prefix=5
    # (P0) EXACT 224-byte HEAD at offset 0.
    [[ "${chx:0:448}" =~ $HEAD_RE ]] || { fail_test "$label wb(P0): head != exact 224-byte GDT-install+UART+PIC/PIT+input-read+a3[inq]+init{pos=0,done=1,cur=2,tcb0,tcb1}+sti+jmp\$ template"; ok=0; }
    # (P-sched) the exact 128-byte SCHEDULER present exactly once; locate it -> derive the layout.
    [[ "$(occ "$chx" "$SCHED_RE")" == 1 ]] || { fail_test "$label wb(P-sched): scheduler (EOI; pusha; done-interlock; exit-gate K=$K; idle-skip; bit-select; warm save/restore; 2x popa;iret; exit) not present exactly once"; ok=0; }
    local spos; spos=$(echo "$chx" | grep -boE "$SCHED_RE" | head -1 | cut -d: -f1)
    if [[ -z "$spos" ]]; then fail_test "$label wb: cannot locate scheduler"; return 1; fi
    local off_sched=$(( spos / 2 )); local off_tables=$(( off_sched + 128 )); local off_B=$(( off_sched - 43 ))
    local off_A=224
    [[ "$off_B" -gt "$off_A" ]] || { fail_test "$label wb: derived off_B ($off_B) <= off_A ($off_A)"; return 1; }
    # data layout: 6 cell dwords, then the two 44-byte seeds (cold contexts), then the two 256-byte
    # DEDICATED stacks (each task entry does mov esp,stackX_top -> the warm save is load-bearing).
    local off_after=$(( off_tables + 300 )); local off_data=$(( (off_after + 3) & ~3 ))
    local inq_v=$(( 1048588 + off_data )); local pos_v=$(( inq_v+4 )); local done_v=$(( inq_v+8 )); local cur_v=$(( inq_v+12 )); local tcb0_v=$(( inq_v+16 )); local tcb1_v=$(( inq_v+20 ))
    local off_seedA=$(( off_data+24 )); local off_seedB=$(( off_seedA+44 )); local off_stackA=$(( off_seedB+44 )); local off_stackB=$(( off_stackA+256 ))
    local seedA_v=$(( 1048588 + off_seedA )); local seedB_v=$(( 1048588 + off_seedB ))
    local stackA_top=$(( 1048588 + off_stackA + 256 )); local stackB_top=$(( 1048588 + off_stackB + 256 ))
    local a_entry=$(( 1048588 + off_A )); local b_entry=$(( 1048588 + off_B ))
    # (P-inq/cells) VALUE-BIND: head's init store addrs == scheduler's read/write addrs == computed cells.
    # head: a3[inq]@167, then c705 stores (pos@173, done@183, cur@193, tcb0@203/seedA@207, tcb1@213/seedB@217).
    local h_inq h_pos h_done h_cur h_tcb0 h_seedA h_tcb1 h_seedB
    h_inq=$(le32_val "$chx" 334); h_pos=$(le32_val "$chx" 346); h_done=$(le32_val "$chx" 366); h_cur=$(le32_val "$chx" 386)
    h_tcb0=$(le32_val "$chx" 406); h_seedA=$(le32_val "$chx" 414); h_tcb1=$(le32_val "$chx" 426); h_seedB=$(le32_val "$chx" 434)
    [[ "$h_inq" -eq "$inq_v" && "$h_pos" -eq "$pos_v" && "$h_done" -eq "$done_v" && "$h_cur" -eq "$cur_v" && "$h_tcb0" -eq "$tcb0_v" && "$h_tcb1" -eq "$tcb1_v" ]] || { fail_test "$label wb(P-cells): head init cell addrs != computed cell layout (inq/pos/done/cur/tcb0/tcb1)"; ok=0; }
    [[ "$h_seedA" -eq "$seedA_v" && "$h_seedB" -eq "$seedB_v" ]] || { fail_test "$label wb(P-tcbinit): head inits tcb0/tcb1 to seedA/seedB vaddrs ($h_seedA/$h_seedB vs $seedA_v/$seedB_v)"; ok=0; }
    # scheduler cell addrs (offsets within the 128-byte sched, *2 in hex): done@6, pos@15, cur@25, tcb0@37(save), pos@43, inq@48, cur@58, pos@64, done@70, tcb0@81(restore)
    local s_done s_pos s_cur s_tcbs s_inq s_tcbr
    s_done=$(le32_val "$chx" $(( off_sched*2 + 12 ))); s_pos=$(le32_val "$chx" $(( off_sched*2 + 30 ))); s_cur=$(le32_val "$chx" $(( off_sched*2 + 50 )))
    s_tcbs=$(le32_val "$chx" $(( off_sched*2 + 74 ))); s_inq=$(le32_val "$chx" $(( off_sched*2 + 96 ))); s_tcbr=$(le32_val "$chx" $(( off_sched*2 + 162 )))
    [[ "$s_done" -eq "$done_v" && "$s_pos" -eq "$pos_v" && "$s_cur" -eq "$cur_v" && "$s_inq" -eq "$inq_v" ]] || { fail_test "$label wb(P-sched-cells): scheduler reads cells != head's cells (done/pos/cur/inq)"; ok=0; }
    [[ "$s_tcbs" -eq "$tcb0_v" && "$s_tcbr" -eq "$tcb0_v" ]] || { fail_test "$label wb(P-prov): scheduler save-target ($s_tcbs) / restore-source ($s_tcbr) tcb base != tcb0 ($tcb0_v) -- warm save/restore must use the SAME indexed slot"; ok=0; }
    # (P-tasks) the framed 0xE9 emit occurs EXACTLY TWICE in [0,off_tables) and ZERO in head/scheduler.
    local span_hex="${chx:0:$(( off_tables * 2 ))}"; local head_hex="${chx:0:448}"; local sched_hex="${chx:$(( off_sched*2 )):256}"
    [[ "$(occ "$span_hex" '66bae900')" == 2 ]] || { fail_test "$label wb(P-tasks): framed 0xE9 emit not present exactly twice in the code span (one per task body)"; ok=0; }
    [[ "$(occ "$head_hex" '66bae900')" == 0 ]] || { fail_test "$label wb(P-tasks): the HEAD emits (0xE9) -- emit must come only from a dispatched task"; ok=0; }
    [[ "$(occ "$sched_hex" '66bae900')" == 0 ]] || { fail_test "$label wb(P-tasks): the SCHEDULER emits (0xE9) -- emit must come only from a dispatched task"; ok=0; }
    # (P-stackA) task A entry begins mov esp,stackA_top (dedicated stack; value-bound) -- the warm save is load-bearing.
    [[ "${chx:$(( off_A*2 )):2}" == "bc" && "$(le32_val "$chx" $(( off_A*2 + 2 )))" -eq "$stackA_top" ]] || { fail_test "$label wb(P-stackA): task A does not begin mov esp,stackA_top ($stackA_top)"; ok=0; }
    # task A glue (after mov esp + body): mov edi,eax; xor esi,esi; LOOP{inc esi; mov eax,edi; add eax,esi; FRAME; mov[done],1; hlt; jmp -33}
    # locate the task A glue head exactly at off_B-37
    [[ "${chx:$(( (off_B-37)*2 )):18}" == "89c731f64689f801f0" ]] || { fail_test "$label wb(P-taskA): task A warm-accumulate glue (mov edi,eax;xor esi,esi;inc esi;mov eax,edi;add eax,esi) not at off_B-37"; ok=0; }
    [[ "${chx:$(( (off_B-37)*2 + 18 )):30}" == "$FRAME_HEX" ]] || { fail_test "$label wb(P-taskA): task A framed emit != proven FRAME"; ok=0; }
    [[ "${chx:$(( (off_B-37)*2 + 48 )):4}" == "c705" ]] || { fail_test "$label wb(P-taskA): task A no mov[done] after emit"; ok=0; }
    local ta_done; ta_done=$(le32_val "$chx" $(( (off_B-37)*2 + 52 )))
    [[ "$ta_done" -eq "$done_v" && "${chx:$(( (off_B-37)*2 + 60 )):8}" == "01000000" ]] || { fail_test "$label wb(P-taskA): task A mov[done] addr/value != [done]<-1"; ok=0; }
    [[ "${chx:$(( (off_B-37)*2 + 68 )):4}" == "f4eb" ]] || { fail_test "$label wb(P-taskA): task A park (hlt;jmp) missing"; ok=0; }
    # (P-stackB) task B entry begins mov esp,stackB_top; then xor edi,edi; LOOP{inc edi; mov eax,176; add eax,edi; FRAME; mov[done],1; hlt; jmp -36}
    [[ "${chx:$(( off_B*2 )):2}" == "bc" && "$(le32_val "$chx" $(( off_B*2 + 2 )))" -eq "$stackB_top" ]] || { fail_test "$label wb(P-stackB): task B does not begin mov esp,stackB_top ($stackB_top)"; ok=0; }
    [[ "${chx:$(( (off_B+5)*2 )):8}" == "31ff47b8" ]] || { fail_test "$label wb(P-taskB): task B glue (xor edi,edi;inc edi;mov eax,imm) not at off_B+5"; ok=0; }
    local tb_mark; tb_mark=$(le32_val "$chx" $(( (off_B+5)*2 + 8 )))
    [[ "$tb_mark" -eq "$MARKERB" ]] || { fail_test "$label wb(P-taskB): task B marker imm ($tb_mark) != $MARKERB"; ok=0; }
    [[ "${chx:$(( (off_B+5)*2 + 16 )):4}" == "01f8" ]] || { fail_test "$label wb(P-taskB): task B add eax,edi missing"; ok=0; }
    [[ "${chx:$(( (off_B+5)*2 + 20 )):30}" == "$FRAME_HEX" ]] || { fail_test "$label wb(P-taskB): task B framed emit != proven FRAME"; ok=0; }
    # (P-prov2 / warmth) the task BODIES contain ZERO absolute image-address operands EXCEPT the [done] store
    # (the emitted byte must dataflow from a warm REGISTER accumulator + a fixed marker, never an indexed
    # memory read -- this is the cold-re-dispatch-fakes-warmth forge, closed white-box).
    local taskspan_off=$(( off_A )); local taskspan_len=$(( off_sched - off_A ))
    dd if="$code" of="$code.tasks" bs=1 skip="$taskspan_off" count="$taskspan_len" status=none 2>/dev/null
    local tdis; tdis=$(objdump -D -b binary -m i386 -M att "$code.tasks" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
    local task_abs; task_abs=$(echo "$tdis" | grep -coE '0x10[0-9a-f]{4}')
    # exactly 4 absolute refs in the task span: the two `mov esp,stackX_top` (stack setup) + the two
    # [done] stores (one per task). NO other 0x10xxxx -- the emitted byte must dataflow from a warm
    # REGISTER accumulator + a fixed marker, never an indexed memory read (kills the trace-buffer forge).
    [[ "$task_abs" -eq 4 ]] || { fail_test "$label wb(P-prov): task bodies have $task_abs absolute image-address refs (want exactly 4 = two mov esp,stackX_top + two mov[done]) -- an accumulator/trace read from memory fakes warmth"; ok=0; }
    local allow; allow="$(printf '0x%x|0x%x|0x%x' "$done_v" "$stackA_top" "$stackB_top")"
    local task_abs_bad; task_abs_bad=$(echo "$tdis" | grep -oE '0x10[0-9a-f]{4}' | grep -ivE "^(${allow})$" | head -1)
    [[ -z "$task_abs_bad" ]] || { fail_test "$label wb(P-prov): a task body references an absolute address other than [done]/stackX_top ($task_abs_bad)"; ok=0; }
    # (P7, Codex Q2) the COMPILED toakie BODY (between task A's mov esp + the 37-byte glue) is pure
    # compute -- ZERO I/O / privileged / call / ret. The two FRAMED emits live only in the pinned
    # glue, so this closes "a forge injects an out 0xE9 into the body" (the body can emit nothing).
    local off_body=$(( off_A + 5 + ebp_prefix )); local body_len=$(( (off_B - 37) - off_body ))
    if [[ "$body_len" -gt 0 ]]; then
        dd if="$code" of="$code.body" bs=1 skip="$off_body" count="$body_len" status=none 2>/dev/null
        local bdis; bdis=$(objdump -D -b binary -m i386 -M att "$code.body" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
        echo "$bdis" | grep -qiE '^(out|outb|in|inb|int|iret|sti|cli|hlt|lgdt|lidt|ljmp|call|lcall|ret|lret|syscall|sysenter|rdtsc|pushf|popf|cpuid)' && { fail_test "$label wb(P7): the compiled task A body contains an I/O / privileged / call / ret instruction"; ok=0; }
        echo "$bdis" | grep -qE '0x10[0-9a-f]{4}' && { fail_test "$label wb(P7): the compiled task A body references an absolute image address"; ok=0; }
    fi
    # (P-antimut) the ONLY absolute stores in [0,off_tables) target the whitelisted cells {inq,pos,done,cur,tcb0,tcb1}.
    dd if="$code" of="$code.span" bs=1 count="$off_tables" status=none 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386 -M att "$code.span" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
    local cell_lo=$(( inq_v )); local cell_hi=$(( tcb1_v + 4 ))
    # collect absolute-address store targets (mov ...,0x10xxxx with no register base; and the indexed save).
    local badstore=0 line addr
    while IFS= read -r line; do
        addr=$(echo "$line" | grep -oE '0x10[0-9a-f]{4}$' | head -1)
        [[ -z "$addr" ]] && continue
        local a=$(( addr ))
        if (( a < cell_lo || a >= cell_hi )); then badstore=$(( badstore+1 )); fi
    done < <(echo "$dis" | grep -E '^(mov|movl|movb)[^,]*,0x10[0-9a-f]{4}$')
    [[ "$badstore" -eq 0 ]] || { fail_test "$label wb(P-antimut): $badstore absolute store(s) outside the cell range [inq..tcb1] -- code/seed/IDT runtime-mutation forge"; ok=0; }
    # the indexed warm-save 'mov %esp,0x...(,%eax,4)' must target tcb0 (already value-bound above); ensure
    # there is no SECOND indexed store to a different base.
    local idx_stores; idx_stores=$(echo "$dis" | grep -cE 'mov +%esp,0x10[0-9a-f]{4}\(,%eax,4\)')
    [[ "$idx_stores" -eq 1 ]] || { fail_test "$label wb(P-prov): $idx_stores indexed esp->tcb saves (want exactly 1)"; ok=0; }
    # (P-reach) head ends fbebfe (sti; jmp$ idle -- no fall-through into task A). 224-byte head -> hex 442.
    [[ "${chx:442:6}" == "fbebfe" ]] || { fail_test "$label wb(P-reach): head does not end fb eb fe (sti; jmp\$ idle)"; ok=0; }
    # rbp frame for a locals probe right after task A's mov esp,stackA_top (off_A+5).
    if [[ "$nlocals" -gt 0 ]]; then
        [[ "${chx:$(( (off_A+5)*2 )):8}" == "89e583ec" ]] || { fail_test "$label wb: no rbp frame (89 e5 83 ec) after mov esp for a locals probe"; ok=0; }
        local subimm=$(( 16#${chx:$(( (off_A+5)*2 + 8 )):2} ))
        [[ "$subimm" -eq $(( 4 * nlocals )) ]] || { fail_test "$label wb: sub esp imm ($subimm) != 4*nlocals"; ok=0; }
    fi
    # (P-seeds) seedA/seedB each: 8 zero GP dwords + iret[eip==task entry, cs==0x08, eflags==0x202 IF=1].
    local gpA="${chx:$(( off_seedA*2 )):64}"; local gpB="${chx:$(( off_seedB*2 )):64}"
    [[ "$gpA" =~ ^0{64}$ ]] || { fail_test "$label wb(P-seeds): seedA GP block not 8 zero dwords"; ok=0; }
    [[ "$gpB" =~ ^0{64}$ ]] || { fail_test "$label wb(P-seeds): seedB GP block not 8 zero dwords"; ok=0; }
    local eipA; eipA=$(le32_val "$chx" $(( off_seedA*2 + 64 ))); local csA; csA=$(le32_val "$chx" $(( off_seedA*2 + 72 ))); local efA; efA=$(le32_val "$chx" $(( off_seedA*2 + 80 )))
    local eipB; eipB=$(le32_val "$chx" $(( off_seedB*2 + 64 ))); local csB; csB=$(le32_val "$chx" $(( off_seedB*2 + 72 ))); local efB; efB=$(le32_val "$chx" $(( off_seedB*2 + 80 )))
    [[ "$eipA" -eq "$a_entry" ]] || { fail_test "$label wb(P-seeds): seedA eip ($eipA) != task A entry ($a_entry) -- decoy seed"; ok=0; }
    [[ "$eipB" -eq "$b_entry" ]] || { fail_test "$label wb(P-seeds): seedB eip ($eipB) != task B entry ($b_entry) -- decoy seed"; ok=0; }
    [[ "$csA" -eq 8 && "$csB" -eq 8 ]] || { fail_test "$label wb(P-seeds): seed cs != 0x08 (A=$csA B=$csB)"; ok=0; }
    [[ "$efA" -eq 514 && "$efB" -eq 514 ]] || { fail_test "$label wb(P-seeds): seed eflags != 0x202 IF=1 (A=$efA B=$efB) -- warm tasks must be re-preemptible"; ok=0; }
    # (P-IDT) the vec-0x20 gate (sel 0x08 / attr 0x8E interrupt gate) targets the scheduler vaddr.
    [[ "$(occ "$chx" '0800008e')" == 1 ]] || { fail_test "$label wb(P-IDT): vec-0x20 gate middle (0800008e) not present exactly once"; ok=0; }
    local gate_vaddr=$(( 1048588 + off_sched ))
    local mpos; mpos=$(echo "$chx" | grep -bo '0800008e' | head -1 | cut -d: -f1)
    local lo16="${chx:mpos-4:4}" hi16="${chx:mpos+8:4}" after="${chx:mpos+12:4}"
    local gate_target=$(( ( (16#${hi16:2:2}${hi16:0:2}) << 16 ) | (16#${lo16:2:2}${lo16:0:2}) ))
    [[ "$gate_target" -eq "$gate_vaddr" ]] || { fail_test "$label wb(P-IDT): vec-0x20 gate target ($gate_target) != scheduler vaddr ($gate_vaddr) -- decoy gate"; ok=0; }
    [[ "$after" == "0701" ]] || { fail_test "$label wb(P-IDT): IDTR limit 0x0107 (le 0701) does not immediately follow the gate"; ok=0; }
    local gate_start_vaddr=$(( 1048588 + (mpos - 4) / 2 ))
    local idtr_operand; idtr_operand=$(le32_val "$chx" 74)
    local idtr_off=$(( (idtr_operand - 1048588) * 2 ))
    if [[ "$idtr_off" -lt 0 ]] || [[ $(( idtr_off + 12 )) -gt ${#chx} ]]; then
        fail_test "$label wb(P-IDT): head-loaded IDTR vaddr ($idtr_operand) outside the image -- lidt-redirect forge"; ok=0
    else
        local idtr_limit_hex="${chx:idtr_off:4}"
        local idtr_base; idtr_base=$(le32_val "$chx" $(( idtr_off + 4 )))
        [[ "$idtr_limit_hex" == "0701" ]] || { fail_test "$label wb(P-IDT): loaded IDTR limit ($idtr_limit_hex) != 0701 -- lidt-redirect forge"; ok=0; }
        [[ $(( idtr_base + 256 )) -eq "$gate_start_vaddr" ]] || { fail_test "$label wb(P-IDT): loaded IDTR base ($idtr_base)+0x100 != checked vec-0x20 gate vaddr ($gate_start_vaddr) -- lidt-redirect forge"; ok=0; }
    fi
    # (P-GDT) flat 32-bit code (9A CF) + data (92 CF) + GDTR limit 0x17.
    [[ "$(occ "$chx" '9acf00')" == 1 ]] || { fail_test "$label wb(P-GDT): flat code descriptor (9A CF) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '92cf001700')" == 1 ]] || { fail_test "$label wb(P-GDT): data descriptor + GDTR limit 0x17 not present exactly once"; ok=0; }
    # (M1) BOUNDED whole-code-span scan [0,off_tables): whitelist + exact kernel-instruction counts.
    local mnem; mnem=$(echo "$dis" | awk '{print $1}' | sort -u)
    local badm; badm=$(echo "$mnem" | grep -ivE '^(mov|movl|movb|movzbl|movzwl|push|pushl|pop|popl|popa|popal|pusha|pushal|add|addl|sub|subl|imul|inc|incl|cmp|cmpl|sete|setne|test|testb|testl|and|andb|andl|shr|shrl|xor|xorb|xorl|je|jne|jae|jb|jmp|in|inb|out|outb|cli|sti|hlt|lgdt|lgdtl|lidt|lidtl|ljmp|iret|nop)$' | tr '\n' ' ')
    [[ -z "${badm// /}" ]] || { fail_test "$label wb(M1): code span contains non-whitelisted instruction(s) [$badm]"; ok=0; }
    local forb; forb=$(echo "$dis" | grep -iE '\b(rdtsc|sgdt|sidt|lldt|ltr|lmsw|pushf|popf|int|into|int3|ins|insb|insl|insw|call|lcall|ret|lret|sysenter|syscall|rdmsr|wrmsr|invlpg|invd|wbinvd|cpuid)\b' | head -3 | tr '\n' ';')
    [[ -z "$forb" ]] || { fail_test "$label wb(M1): forbidden instruction in code span [$forb]"; ok=0; }
    # (P-e9prov, Codex Q2/Q4) GLOBAL 0xE9 provenance: the only writes to debugcon 0xE9 are the two task
    # DX-form emits. mov dx,0xE9 (66bae900) is pinned to exactly 2 (P-tasks); ALSO ban any imm-port out
    # to 0xE9 (e6 e9 / e7 e9) in the code span -- so no head/scheduler/body path emits another way.
    echo "$dis" | grep -qiE 'out +%(al|ax|eax),\$0xe9' && { fail_test "$label wb(P-e9prov): an imm-port out to 0xE9 exists outside the two task emit sites"; ok=0; }
    local in_count; in_count=$(echo "$dis" | grep -cE '^(in|inb)\b')
    [[ "$in_count" -eq 2 ]] || { fail_test "$label wb(M1): $in_count 'in' instructions (want exactly 2: poll+RBR)"; ok=0; }
    local in_bad; in_bad=$(echo "$dis" | grep -E '^(in|inb)\b' | grep -ivE 'in +\(%dx\),%al' | tr '\n' ';')
    [[ -z "$in_bad" ]] || { fail_test "$label wb(M1): an 'in' is not 'in (%dx),%al' [$in_bad]"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^iret')" -eq 2 ]] || { fail_test "$label wb(M1): iret count != 2 (dispatch + absorb)"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^pusha')" -eq 1 ]] || { fail_test "$label wb(M1): pusha count != 1 (the scheduler save)"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^sti\b')" -eq 1 ]] || { fail_test "$label wb(M1): sti count != 1"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^(lgdt|lgdtl)\b')" -eq 1 ]] || { fail_test "$label wb(M1): lgdt count != 1"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^(lidt|lidtl)\b')" -eq 1 ]] || { fail_test "$label wb(M1): lidt count != 1"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^hlt')" -eq 3 ]] || { fail_test "$label wb(M1): hlt count != 3 (task A + task B parks + exit)"; ok=0; }
    # (ELF) e_entry bytes that run.
    local eentry; eentry=$(dd if="$elf" bs=1 skip=24 count=4 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$eentry" == "0c001000" ]] || { fail_test "$label wb: e_entry (0x$eentry) != 0x0010000c"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

# ---- substrates with the late-bound socket input feeder ------------------------------------
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
feeder_wait() { local log="$1" i; for i in $(seq 1 80); do grep -q LISTENING "$log" && return 0; grep -q NOCONN "$log" && return 1; sleep 0.1; done; return 1; }

qemu_trace() { # label elf byte -> echoes the captured 0xE9 trace hex (or "")
    local label="$1" elf="$2" byte="$3"
    local W="$work/$label.q.$byte"; mkdir -p "$W"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 &
    local fp=$!; feeder_wait "$W/feed.log" || { fail_test "$label QEMU byte=$byte: feeder never LISTENING ($(tr '\n' ' ' < "$W/feed.log"))"; kill "$fp" 2>/dev/null; echo ""; return; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none -cpu qemu64 -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n'
}

bochs_trace() { # label elf byte -> echoes the captured 0xE9 trace hex (best-effort) + sets BOCHS_SHUTDOWN
    local label="$1" elf="$2" byte="$3"
    local W="$work/$label.b.$byte"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS missing"; echo ""; return; fi
    ( cd "$W"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$elf" mnt/boot/kernel.elf
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP" )
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 30 > "$W/feed.log" 2>&1 &
    local fp=$!; feeder_wait "$W/feed.log" || { fail_test "$label Bochs byte=$byte: feeder never LISTENING"; kill "$fp" 2>/dev/null; echo ""; return; }
    ( cd "$W"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 32
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 90 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    wait "$fp" 2>/dev/null
    # persist the shutdown count to a file (this fn runs in a command-substitution subshell, so a
    # plain variable would not reach the caller).
    grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null > "$work/.bochs_shutdown"
    # extract the contiguous trace run from the e9-hack log (frames "de XX ad" x K).
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" 2>/dev/null | grep -oE "(de[0-9a-f][0-9a-f]ad){$K}" | head -1
}

reject_probe() { # label directive "<body>"
    local label="$1" directive="$2" prog="$3"
    local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "%s\n%b\n" "$directive" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset program emitted a valid multiboot image"; return 1
    fi
    return 0
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link32 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi

for label in $ALL_PROBES; do
    elf="$work/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    elf_gates "$label" "$elf" || continue
    whitebox_gates "$label" "$elf" || continue
    vA=$(host_vA "$label")
    tX=$(host_trace "$X" "$vA" "$K"); tY=$(host_trace "$Y" "$vA" "$K")
    [[ "$tX" != "$tY" ]] || { fail_test "$label: host trace X==Y -- probe not schedule-distinguishing"; continue; }
    sha_before=$(sha256sum "$elf" | cut -d' ' -f1)
    ok=1
    gX=$(qemu_trace "$label" "$elf" "$X"); [[ "$gX" == "$tX" ]] || { fail_test "$label QEMU X=$X: trace=$gX want=$tX"; ok=0; }
    gY=$(qemu_trace "$label" "$elf" "$Y"); [[ "$gY" == "$tY" ]] || { fail_test "$label QEMU Y=$Y: trace=$gY want=$tY"; ok=0; }
    if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
        bX=$(bochs_trace "$label" "$elf" "$X"); bsdX=$(cat "$work/.bochs_shutdown" 2>/dev/null || echo 0)
        [[ "$bX" == "$tX" && "$bsdX" -ge 1 ]] || { fail_test "$label Bochs X=$X: trace=$bX want=$tX shutdown=$bsdX"; ok=0; }
        bY=$(bochs_trace "$label" "$elf" "$Y"); bsdY=$(cat "$work/.bochs_shutdown" 2>/dev/null || echo 0)
        [[ "$bY" == "$tY" && "$bsdY" -ge 1 ]] || { fail_test "$label Bochs Y=$Y: trace=$bY want=$tY shutdown=$bsdY"; ok=0; }
    fi
    sha_after=$(sha256sum "$elf" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]] || { fail_test "$label: image changed between the X and Y runs (not the same binary)"; ok=0; }
    [[ "$ok" -eq 1 ]] && pass=$((pass + 1))
done

# ---- reject probes (+ twins): the cloggard body subset is toakie (no input_byte, no out-of-subset) ----
reject_probe call         '-- emit: multiboot32-cloggard'  'func h(): return 2 end\nfunc main(): return h()+1 end'
reject_probe call_twin    '-- emit: multiboot32-cloggard'  'func g(): return 4 end\nfunc main(): return g()+9 end'
reject_probe mainarg      '-- emit: multiboot32-cloggard'  'func main(p): return p+1 end'
reject_probe mainarg_twin '-- emit: multiboot32-cloggard'  'func main(k): return k-1 end'
reject_probe divmod       '-- emit: multiboot32-cloggard'  'func main(): let x = 6  return x % 4 end'
reject_probe divmod_twin  '-- emit: multiboot32-cloggard'  'func main(): let z = 8  return z / 3 end'
reject_probe bitor        '-- emit: multiboot32-cloggard'  'func main(): let x = 6  return x | 1 end'
reject_probe bitor_twin   '-- emit: multiboot32-cloggard'  'func main(): let w = 5  return w & 3 end'
reject_probe maxlocals      '-- emit: multiboot32-cloggard' "$(gen_locals 32 a)"
reject_probe maxlocals_twin '-- emit: multiboot32-cloggard' "$(gen_locals 32 z)"
reject_probe in_body      '-- emit: multiboot32-cloggard'  'func main(): return input_byte() end'
reject_probe in_body_twin '-- emit: multiboot32-cloggard'  'func main(): return input_byte() + 1 end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 12))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link32 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link32 / cloggard / sixteenth kernel-arc link: the first DATA-DEPENDENT MULTI-QUANTUM scheduler -- a timer-IRQ0 run-queue dispatches K=$K WARM tasks over multiple quanta, emitting an ordered TRACE on 0xE9; the schedule next=(inq>>pos)&1 is recomputed reading [inq] EACH quantum inside vec-0x20, so the same image fed X=0x0A produces schedule A,B,A,B and Y=0x05 produces B,A,B,A -- a DIFFERENT ordered byte sequence; warm accumulation is white-box-bound by the PROVENANCE pin (only writes to a tcb slot are the head init + the scheduler's single indexed save; each task's byte dataflows from a warm REGISTER accumulator + a fixed marker, never an indexed memory read -- closing the cold-re-dispatch-fakes-warmth forge); $pass checks: static + ELF-P12 + white-box [P0 exact 224-byte head; P-sched exact 128-byte scheduler exactly-once w/ the done-flag interlock + exit-gate K=$K + per-quantum bit-select pinned; P-cells head-init/scheduler cell addrs value-bound to the computed layout; P-prov warmth provenance (tcb save==restore slot, task bodies ref only [done]); P-tasks framed emit exactly twice + ZERO in head/scheduler + exact task glue; P-antimut all absolute stores target the cell range; P-reach head ends sti;jmp\$; P-seeds 8 zero GP + cs 0x08 + eflags 0x202 IF=1 + eips bound to the task entries; P-IDT vec-0x20 interrupt-gate -> scheduler + loaded-IDTR bind; P-GDT flat; M1 bounded disasm whitelist + 2 in + 2 iret + 1 pusha + 1 sti + 1 lgdt + 1 lidt + 3 hlt], QEMU substrate (5 probes, late-bound socket COM1, full-trace cmp vs host golden for X and Y), Bochs substrate ($BOCHS_PROBES, socket com1, full-trace + clean shutdown), 12 rejects with twins; graded vs host-derived golden on the dual-substrate oracle -- a CANONICAL-CODEGEN proof for the fixed probes)"
exit 0
