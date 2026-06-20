#!/usr/bin/env bash
# Native codegen Link 31 (contigo / f1, the FIFTEENTH kernel-arc link): the first
# DATA-DEPENDENT SCHEDULING DECISION. bluefield (link28) preemptively switched between two
# tasks but with a BLIND schedule (cur ^= 1); trukfit (link30) read a late-bound COM1 byte.
# contigo composes both: the freestanding image's mainline reads ONE late-bound byte from
# COM1 into a STATE cell [inq]; the timer-IRQ0 SCHEDULER then LOADS [inq] and takes a
# `cmp [inq],128; jae` to SELECT which of two iret-seeded tasks to dispatch -- so the SCHEDULE
# itself is a function of runtime input (the seed of run-queues / block-wake / priorities).
# Selected by the anchored first-line directive "-- emit: multiboot32-contigo" (a 15th emit
# mode; the 14 prior modes are byte-identical, so the self-host fixpoint gen2==gen1 holds).
# Graded, like lingo..trukfit, on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs vs a
# HOST-derived golden), with trukfit's LATE-BOUND INPUT SUBSTRATE (socket-backed COM1).
#
# WHY THIS IS GENUINELY NEW (not "trukfit with a branch"): input-witnessability alone would be
# satisfied by a monolithic `if input then emitA else emitB`. contigo is new ONLY because the
# white-box gate proves SCHEDULER-MEDIATED selection: (1) input is written to a STATE cell, not
# used to pick directly; (2) the timer-ISR scheduler loads it and takes the cmp;jae; (3) the
# emitted byte comes ONLY from the SELECTED task's context, reached ONLY via the scheduler's
# iret into that task's seed; (4) the mainline and scheduler NEVER emit (0x0E9 frame appears
# exactly twice, one per task body); (5) the ONLY runtime absolute memory store is the head's
# `mov [inq],eax` -- so no code/seed/IDT can be runtime-mutated to do the selection elsewhere
# (the cross-model Codex "head rewrites seedA.eip" forge is closed by this pin).
#
# Image layout (vaddr V0=0x10000c=1048588; file off 4096 = 12-byte mbheader; code at file 4108):
#   [HEAD' 174]   cli; lgdt; ljmp; reload segs; mov esp,esp_top; lidt; UART init (56);
#                 PIC remap + PIT program (52); poll LSR 0x3FD + read RBR 0x3F8 (in al,dx; movzx);
#                 `a3 <inq>` mov[inq],eax; sti; `eb fe` jmp$ idle (NEVER emits, NEVER falls into a task).
#   [TASK A]      [ebp frame?] + compiled toakie body (eax=vA) + the shared 58-byte epilogue.
#   [TASK B]      mov eax,46 (markerB) + the shared 58-byte epilogue.
#   [SCHEDULER 30] EOI; mov eax,[inq]; cmp eax,128; jae pickB; mov esp,seedA; jmp; mov esp,seedB; popa; iret.
#   [TABLES 300]  flat GDT + GDTR + IDT (vec-0x20 gate -> scheduler) + IDTR.
#   [inq 8][seedA 44: 8 zero GP + iret(eip=taskA,cs=8,eflags=0x002)][seedB 44: ...eip=taskB...][guard 16].
# Seed eflags=0x002 (IF=0): one-shot cold dispatch -- the selected task runs uninterrupted to hlt,
# so no re-preemption / double-emit (a TRAP gate 0x8f or eflags IF=1 would risk re-entry; both pinned).
#
# HONEST SCOPE: a CANONICAL-CODEGEN proof for the fixed probes (not general scheduler semantics);
# 32-bit PM (scheduling is orthogonal to bitness; the long64 links stay regression); two tasks, a
# single one-shot data-dependent dispatch (not a multi-quantum run queue); cold-dispatch context
# switch (esp + iret frame; no GP save -- cold tasks have don't-care GP, distinct from bluefield's
# warm save/restore); emulator-graded, emulators unpinned; the input-DELIVERY fact is the
# audited-assertion residue (no independent oracle), minimized by dual-substrate AGREEMENT + the
# host-chosen late-bound value + the value-flow/locus gate. Pays nothing new on the ledger (D18
# port-input core already paid by trukfit; D3 MMIO residue untouched) -- a far-axis CAPABILITY link.
#
# The held-back MUTATION proof (run_native_codegen_link31_mutation.sh) binary-patches a compiled
# probe to prove each load-bearing byte bites (blind-pickA, read-literal, no-input, swap-sense,
# decoy-seed all collapse the differential / no frame; no-EOI, eflags-IF, THRESH are white-box RED).
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L15_BOCHS_PROBES:-co_lit co_then}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
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
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

# ---- the EXACT pinned byte sequences (host-derived; see the empirical pre-build) ----------
UART_HEX='66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003ee'
PICPIT_HEX='b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe640'
READ_HEX='66bafd03eca80174f766baf803ec0fb6c0'   # poll LSR 0x3FD; read RBR 0x3F8; movzx eax,al (17 bytes)
EPILOGUE_HEX='88c366bae900b0deee88d8eeb0adee88d83431247f66baf400ee66ba0089b053eeb068eeb075eeb074eeb064eeb06feeb077eeb06eeefaf4ebfd'
# the exact 174-byte HEAD' (only gdtr/esp/idtr/inq le32 vary).
HEAD_RE="^fa0f0115[0-9a-f]{8}ea1b0010000800""66b81000""8ed88ec08ee08ee88ed0""bc[0-9a-f]{8}""0f011d[0-9a-f]{8}${UART_HEX}${PICPIT_HEX}${READ_HEX}""a3[0-9a-f]{8}""fbebfe"
# the exact 30-byte SCHEDULER (EOI; mov eax,[inq]; cmp eax,128; jae +7; mov esp,seedA; jmp +5;
# mov esp,seedB; popa; iret). The pinned literals VALUE-BIND: EOI=b020e620, THRESH=128 (3d80000000),
# jae+7 (7307 -> lands exactly on the pickB `bc`), eb05, popa+iret (61cf). inq/seedA/seedB vary.
SCHED_RE='b020e620a1[0-9a-f]{8}3d800000007307bc[0-9a-f]{8}eb05bc[0-9a-f]{8}61cf'

# ---- probes: source, host vA (task A's emitted byte), nlocals ------------------------------
MARKERB=46
prog_src() {
    case "$1" in
      co_then)    echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      co_else)    echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      co_lit)     echo 'func main(): return 88 end' ;;
      co_nolocal) echo 'func main(): return 77 end' ;;
      co_cap31)   gen_locals 31 a ;;
    esac
}
gen_locals() { local n="$1" pfx="$2" s='func main():' i; for i in $(seq 0 $((n-1))); do s="$s let $pfx$i = $i"; done; echo "$s return $pfx$((n-1)) end"; }
host_vA() { case "$1" in co_then) echo 88 ;; co_else) echo 11 ;; co_lit) echo 88 ;; co_nolocal) echo 77 ;; co_cap31) echo 30 ;; esac; }
probe_nlocals() { case "$1" in co_then|co_else) echo 1 ;; co_cap31) echo 31 ;; *) echo 0 ;; esac; }
ALL_PROBES="co_then co_else co_lit co_nolocal co_cap31"
X=65    # < 128 -> scheduler dispatches TASK A (emits vA)
Y=200   # >=128 -> scheduler dispatches TASK B (emits markerB=46)

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-contigo\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
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
    # (P0) EXACT 174-byte HEAD' at offset 0 (only gdtr/esp/idtr/inq le32 vary).
    [[ "${chx:0:348}" =~ $HEAD_RE ]] || { fail_test "$label wb(P0): head' != exact 174-byte GDT-install+UART+PIC+PIT+input-read+a3[inq]+sti+jmp\$ template"; ok=0; }
    # (P-sched) the exact 30-byte SCHEDULER present exactly once; locate it -> derive the layout.
    [[ "$(occ "$chx" "$SCHED_RE")" == 1 ]] || { fail_test "$label wb(P-sched): scheduler (EOI; mov eax,[inq]; cmp 128; jae pickB; mov esp,seedA; jmp; mov esp,seedB; popa; iret) not present exactly once"; ok=0; }
    local spos; spos=$(echo "$chx" | grep -boE "$SCHED_RE" | head -1 | cut -d: -f1)
    if [[ -z "$spos" ]]; then fail_test "$label wb: cannot locate scheduler"; return 1; fi
    local off_sched=$(( spos / 2 )); local off_tables=$(( off_sched + 30 )); local off_B=$(( off_sched - 63 ))
    local off_A=174
    [[ "$off_B" -gt "$off_A" ]] || { fail_test "$label wb: derived off_B ($off_B) <= off_A ($off_A)"; return 1; }
    # (P-inq) input -> state -> scheduler VALUE-BIND: head's `a3 <inq>` write addr == scheduler's `a1 <inq>` read addr.
    # head tail = a3(166) imm(167..170) fb(171) eb(172) fe(173); the inq imm is at byte 167 (hexpos 334).
    local inq_head; inq_head=$(le32_val "$chx" 334)
    local inq_sched; inq_sched=$(le32_val "$chx" $(( off_sched*2 + 10 )))
    [[ "$inq_head" -eq "$inq_sched" ]] || { fail_test "$label wb(P-inq): head writes [inq=$inq_head] but scheduler reads [inq=$inq_sched] -- not the same state cell"; ok=0; }
    # the input read appears exactly once in the head (poll LSR + RBR read + movzx, bound contiguous to the a3 store).
    [[ "$(occ "$chx" "${READ_HEX}a3")" == 1 ]] || { fail_test "$label wb(P-inq): the input read (poll+RBR+movzx) bound to mov[inq] not present exactly once"; ok=0; }
    # (P-sched value-binds) the two `bc` immediates == seedA/seedB vaddrs (computed from the layout;
    # each task has a 256-byte stack laid below its seed: inq(8) stackA(256) seedA(44) stackB(256) seedB(44)).
    local off_data=$(( (off_tables + 300 + 3) & ~3 )); local off_seedA=$(( off_data + 8 + 256 )); local off_seedB=$(( off_seedA + 44 + 256 ))
    local seedA_v=$(( 1048588 + off_seedA )); local seedB_v=$(( 1048588 + off_seedB ))
    local bcA; bcA=$(le32_val "$chx" $(( off_sched*2 + 34 )))
    local bcB; bcB=$(le32_val "$chx" $(( off_sched*2 + 48 )))
    [[ "$bcA" -eq "$seedA_v" ]] || { fail_test "$label wb(P-sched): pickA mov esp imm ($bcA) != seedA vaddr ($seedA_v)"; ok=0; }
    [[ "$bcB" -eq "$seedB_v" ]] || { fail_test "$label wb(P-sched): pickB mov esp imm ($bcB) != seedB vaddr ($seedB_v)"; ok=0; }
    # (P-tasks) the 0xE9 frame-emit (66 ba e9 00) occurs EXACTLY TWICE in [0,off_tables) and ZERO in the head and scheduler.
    local span_hex="${chx:0:$(( off_tables * 2 ))}"
    local head_hex="${chx:0:348}"
    local sched_hex="${chx:$(( off_sched*2 )):60}"
    [[ "$(occ "$span_hex" '66bae900')" == 2 ]] || { fail_test "$label wb(P-tasks): 0xE9 frame-emit not present exactly twice in the code span (one per task body)"; ok=0; }
    [[ "$(occ "$head_hex" '66bae900')" == 0 ]] || { fail_test "$label wb(P-tasks): the mainline head EMITS (0xE9) -- emit must come only from a dispatched task"; ok=0; }
    [[ "$(occ "$sched_hex" '66bae900')" == 0 ]] || { fail_test "$label wb(P-tasks): the scheduler EMITS (0xE9) -- emit must come only from a dispatched task"; ok=0; }
    # task A epilogue at off_B-58 and task B = mov eax,46 + epilogue, both the exact 58-byte epilogue.
    [[ "${chx:$(( (off_B-58)*2 )):116}" == "$EPILOGUE_HEX" ]] || { fail_test "$label wb(P-tasks): task A epilogue != the proven 58-byte sequence"; ok=0; }
    [[ "${chx:$(( off_B*2 )):10}" == "b82e000000" ]] || { fail_test "$label wb(P-tasks): task B != mov eax,46 (markerB)"; ok=0; }
    [[ "${chx:$(( off_B*2 + 10 )):116}" == "$EPILOGUE_HEX" ]] || { fail_test "$label wb(P-tasks): task B epilogue != the proven 58-byte sequence"; ok=0; }
    # (P-antimut, cross-model Codex Q1) the ONLY absolute memory STORE in [0,off_tables) is the head's
    # `mov [inq],eax` -- so no reachable code can runtime-mutate a seed/the IDT/code to do the selection
    # outside the scheduler's cmp;jae. Decode the bounded code span and count stores to an absolute
    # image address (operand of the form ",0x10xxxx" with no register base).
    dd if="$code" of="$code.span" bs=1 count="$off_tables" status=none 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386 -M att "$code.span" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
    local absstores; absstores=$(echo "$dis" | grep -cE ',0x10[0-9a-f]{4}$')
    [[ "$absstores" -eq 1 ]] || { fail_test "$label wb(P-antimut): $absstores absolute-address stores in the code span (want exactly 1 = mov [inq],eax) -- a 2nd one could runtime-mutate a seed/code/IDT"; ok=0; }
    # and the task A body region [off_A+ebp, off_B-58) is free of any absolute image-address operand
    # (a genuine toakie body uses only ebp-relative frame slots + immediates -- never 0x10xxxx).
    local body_off=$(( off_A + ebp_prefix )); local body_len=$(( (off_B - 58) - body_off ))
    if [[ "$body_len" -gt 0 ]]; then
        dd if="$code" of="$code.body" bs=1 skip="$body_off" count="$body_len" status=none 2>/dev/null
        local bdis; bdis=$(objdump -D -b binary -m i386 -M att "$code.body" 2>/dev/null | awk -F'\t' 'NF>=3{print $3}')
        echo "$bdis" | grep -qE '0x10[0-9a-f]{4}' && { fail_test "$label wb(P-antimut): task A body references an absolute image address (not a clean toakie lowering)"; ok=0; }
        # (P7) task A body free of I/O + privileged + indirect/call/ret; only direct je/jne/jmp.
        echo "$bdis" | grep -qiE '^(out|outb|in|inb|int|iret|sti|cli|hlt|lgdt|lidt|call|ret|lret|syscall|sysenter|rdtsc|pushf|popf|cpuid)' && { fail_test "$label wb(P7): task A body contains an I/O / privileged / call / ret instruction"; ok=0; }
    fi
    # rbp frame (locals probe): 89 e5 83 ec XX right after the head (offset 174, hexpos 348).
    if [[ "$nlocals" -gt 0 ]]; then
        [[ "${chx:348:8}" == "89e583ec" ]] || { fail_test "$label wb: no rbp frame (89 e5 83 ec) after head for a locals probe"; ok=0; }
        local subimm=$(( 16#${chx:356:2} ))
        [[ "$subimm" -eq $(( 4 * nlocals )) ]] || { fail_test "$label wb: sub esp imm ($subimm) != 4*nlocals"; ok=0; }
    fi
    # (P-reach) head ends in `eb fe` idle (task A NOT fall-through) at offset 172.
    [[ "${chx:344:4}" == "ebfe" ]] || { fail_test "$label wb(P-reach): head does not end in eb fe (jmp\$ idle) -- task A may be fall-through-reachable"; ok=0; }
    # (P-seeds) seedA/seedB each: 8 zero GP dwords + iret[eip==task entry, cs==0x08, eflags==0x002].
    local a_entry=$(( 1048588 + off_A )); local b_entry=$(( 1048588 + off_B ))
    local gpA="${chx:$(( off_seedA*2 )):64}"; local gpB="${chx:$(( off_seedB*2 )):64}"
    [[ "$gpA" =~ ^0{64}$ ]] || { fail_test "$label wb(P-seeds): seedA GP block not 8 zero dwords"; ok=0; }
    [[ "$gpB" =~ ^0{64}$ ]] || { fail_test "$label wb(P-seeds): seedB GP block not 8 zero dwords"; ok=0; }
    local eipA; eipA=$(le32_val "$chx" $(( off_seedA*2 + 64 ))); local csA; csA=$(le32_val "$chx" $(( off_seedA*2 + 72 ))); local efA; efA=$(le32_val "$chx" $(( off_seedA*2 + 80 )))
    local eipB; eipB=$(le32_val "$chx" $(( off_seedB*2 + 64 ))); local csB; csB=$(le32_val "$chx" $(( off_seedB*2 + 72 ))); local efB; efB=$(le32_val "$chx" $(( off_seedB*2 + 80 )))
    [[ "$eipA" -eq "$a_entry" ]] || { fail_test "$label wb(P-seeds): seedA eip ($eipA) != task A entry ($a_entry) -- decoy seed"; ok=0; }
    [[ "$eipB" -eq "$b_entry" ]] || { fail_test "$label wb(P-seeds): seedB eip ($eipB) != task B entry ($b_entry) -- decoy seed"; ok=0; }
    [[ "$csA" -eq 8 && "$csB" -eq 8 ]] || { fail_test "$label wb(P-seeds): seed cs != 0x08 (A=$csA B=$csB)"; ok=0; }
    [[ "$efA" -eq 2 && "$efB" -eq 2 ]] || { fail_test "$label wb(P-seeds): seed eflags != 0x002 IF=0 (A=$efA B=$efB) -- IF=1 risks re-preemption/double-emit"; ok=0; }
    # both task entries point INTO the code region, never into the data region (Codex Q2).
    [[ "$a_entry" -lt $(( 1048588 + off_tables )) && "$eipA" -ge 1048588 ]] || { fail_test "$label wb(P-reach): seedA eip outside the code region"; ok=0; }
    [[ "$b_entry" -lt $(( 1048588 + off_tables )) && "$eipB" -ge 1048588 ]] || { fail_test "$label wb(P-reach): seedB eip outside the code region"; ok=0; }
    # (P-IDT) the vec-0x20 gate (sel 0x08 / attr 0x8E INTERRUPT gate -- not 0x8F trap) targets the scheduler vaddr.
    [[ "$(occ "$chx" '0800008e')" == 1 ]] || { fail_test "$label wb(P-IDT): vec-0x20 gate middle (0800008e = sel 0x08 / attr 0x8E interrupt gate) not present exactly once"; ok=0; }
    local gate_vaddr=$(( 1048588 + off_sched ))
    local mpos; mpos=$(echo "$chx" | grep -bo '0800008e' | head -1 | cut -d: -f1)
    local lo16="${chx:mpos-4:4}" hi16="${chx:mpos+8:4}" after="${chx:mpos+12:4}"
    local gate_target=$(( ( (16#${hi16:2:2}${hi16:0:2}) << 16 ) | (16#${lo16:2:2}${lo16:0:2}) ))
    [[ "$gate_target" -eq "$gate_vaddr" ]] || { fail_test "$label wb(P-IDT): vec-0x20 gate target ($gate_target) != scheduler vaddr ($gate_vaddr) -- decoy gate"; ok=0; }
    [[ "$after" == "0701" ]] || { fail_test "$label wb(P-IDT): IDTR limit 0x0107 (le 0701) does not immediately follow the gate"; ok=0; }
    # loaded-IDTR base -> the checked vec-0x20 gate (rizzing/bluefield P5b: a decoy lidt FAILS). The head's
    # lidt operand (byte 37, hexpos 74) is the ADDRESS of the 6-byte IDTR descriptor; read the BASE FIELD
    # from that descriptor (at +2) and require base+0x100 == the checked gate vaddr.
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
    # decode only the contiguous code (NOT the tables/seeds/inq, which are DATA that mis-decodes).
    local mnem; mnem=$(echo "$dis" | awk '{print $1}' | sort -u)
    local badm; badm=$(echo "$mnem" | grep -ivE '^(mov|movl|movb|movzbl|movzwl|push|pushl|pop|popl|popa|popal|pusha|pushal|add|addl|sub|subl|imul|cmp|cmpl|sete|setne|test|testb|testl|and|andb|andl|xor|xorb|xorl|je|jne|jae|jb|jmp|in|inb|out|outb|cli|sti|hlt|lgdt|lgdtl|lidt|lidtl|ljmp|iret|nop)$' | tr '\n' ' ')
    [[ -z "${badm// /}" ]] || { fail_test "$label wb(M1): code span contains non-whitelisted instruction(s) [$badm]"; ok=0; }
    local forb; forb=$(echo "$dis" | grep -iE '\b(rdtsc|sgdt|sidt|lldt|ltr|lmsw|pushf|popf|int|into|int3|ins|insb|insl|insw|call|lcall|ret|lret|sysenter|syscall|rdmsr|wrmsr|invlpg|invd|wbinvd|cpuid)\b' | head -3 | tr '\n' ';')
    [[ -z "$forb" ]] || { fail_test "$label wb(M1): forbidden instruction in code span [$forb]"; ok=0; }
    # exactly TWO `in (%dx),%al` (poll + RBR, both in the head); ONE iret (scheduler); ONE sti; ONE lgdt; ONE lidt.
    local in_count; in_count=$(echo "$dis" | grep -cE '^(in|inb)\b')
    [[ "$in_count" -eq 2 ]] || { fail_test "$label wb(M1): $in_count 'in' instructions (want exactly 2: poll+RBR)"; ok=0; }
    local in_bad; in_bad=$(echo "$dis" | grep -E '^(in|inb)\b' | grep -ivE 'in +\(%dx\),%al' | tr '\n' ';')
    [[ -z "$in_bad" ]] || { fail_test "$label wb(M1): an 'in' is not 'in (%dx),%al' [$in_bad]"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^iret')" -eq 1 ]] || { fail_test "$label wb(M1): iret count != 1 (the single scheduler iret)"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^sti\b')" -eq 1 ]] || { fail_test "$label wb(M1): sti count != 1"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^(lgdt|lgdtl)\b')" -eq 1 ]] || { fail_test "$label wb(M1): lgdt count != 1"; ok=0; }
    [[ "$(echo "$dis" | grep -cE '^(lidt|lidtl)\b')" -eq 1 ]] || { fail_test "$label wb(M1): lidt count != 1"; ok=0; }
    # (ELF) e_entry bytes that run.
    local eentry; eentry=$(dd if="$elf" bs=1 skip=24 count=4 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$eentry" == "0c001000" ]] || { fail_test "$label wb: e_entry (0x$eentry) != 0x0010000c"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

# ---- substrates with the late-bound socket input feeder ------------------------------------
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
feeder_wait() { local log="$1" i; for i in $(seq 1 80); do grep -q LISTENING "$log" && return 0; grep -q NOCONN "$log" && return 1; sleep 0.1; done; return 1; }

qemu_run_byte() { # label elf byte expected_emit_byte -> 0 if e9==de<eb>ad and exit matches
    local label="$1" elf="$2" byte="$3" eb="$4"
    local ex fh; ex=$(host_qemu_exit "$eb"); fh=$(printf '%02x' "$eb")
    local W="$work/$label.q.$byte"; mkdir -p "$W"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 &
    local fp=$!; feeder_wait "$W/feed.log" || { fail_test "$label QEMU byte=$byte: feeder never LISTENING ($(tr '\n' ' ' < "$W/feed.log"))"; kill "$fp" 2>/dev/null; return 1; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none -cpu qemu64 -m 64M
    local rc=$?; wait "$fp" 2>/dev/null
    local got; got=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    local nframes; nframes=$(echo "$got" | grep -o "de${fh}ad" | wc -l | tr -d ' ')
    if [[ "$rc" -eq "$ex" ]] && [[ "$got" == "de${fh}ad" ]] && [[ "$nframes" -eq 1 ]]; then return 0; fi
    fail_test "$label QEMU byte=$byte: exit=$rc(want $ex) e9=$got want=de${fh}ad nframes=$nframes"; return 1
}

bochs_run_byte() { # label elf byte expected_emit_byte
    local label="$1" elf="$2" byte="$3" eb="$4"
    local fh; fh=$(printf '%02x' "$eb")
    local W="$work/$label.b.$byte"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS missing"; return 1; fi
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
    # launch the feeder just before bochs (avoid the cold-runner accept-timeout flake), tie its
    # lifetime past the bochs boot+read window.
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 30 > "$W/feed.log" 2>&1 &
    local fp=$!; feeder_wait "$W/feed.log" || { fail_test "$label Bochs byte=$byte: feeder never LISTENING ($(tr '\n' ' ' < "$W/feed.log"))"; kill "$fp" 2>/dev/null; return 1; }
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
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nframes shutdown
    nframes=$(grep -o "de${fh}ad" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    shutdown=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null)
    if [[ "$nframes" -eq 1 ]] && [[ "$shutdown" -ge 1 ]]; then return 0; fi
    fail_test "$label Bochs byte=$byte: frames(de${fh}ad)=$nframes shutdown=$shutdown"; return 1
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
    echo "SKIP: native-codegen link31 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
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
    [[ "$vA" -ne "$MARKERB" ]] || { fail_test "$label: vA==markerB -- probe not selection-distinguishing"; continue; }
    sha_before=$(sha256sum "$elf" | cut -d' ' -f1)
    ok=1
    qemu_run_byte "$label" "$elf" "$X" "$vA"      || ok=0   # X -> task A emits vA
    qemu_run_byte "$label" "$elf" "$Y" "$MARKERB" || ok=0   # Y -> task B emits markerB
    if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
        bochs_run_byte "$label" "$elf" "$X" "$vA"      || ok=0
        bochs_run_byte "$label" "$elf" "$Y" "$MARKERB" || ok=0
    fi
    sha_after=$(sha256sum "$elf" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]] || { fail_test "$label: image changed between the X and Y runs (not the same binary)"; ok=0; }
    [[ "$ok" -eq 1 ]] && pass=$((pass + 1))
done

# ---- reject probes (+ twins): the contigo body subset is toakie (no input_byte, no out-of-subset) ----
reject_probe call         '-- emit: multiboot32-contigo'  'func h(): return 2 end\nfunc main(): return h()+1 end'
reject_probe call_twin    '-- emit: multiboot32-contigo'  'func g(): return 4 end\nfunc main(): return g()+9 end'
reject_probe mainarg      '-- emit: multiboot32-contigo'  'func main(p): return p+1 end'
reject_probe mainarg_twin '-- emit: multiboot32-contigo'  'func main(k): return k-1 end'
reject_probe divmod       '-- emit: multiboot32-contigo'  'func main(): let x = 6  return x % 4 end'
reject_probe divmod_twin  '-- emit: multiboot32-contigo'  'func main(): let z = 8  return z / 3 end'
reject_probe bitor        '-- emit: multiboot32-contigo'  'func main(): let x = 6  return x | 1 end'
reject_probe bitor_twin   '-- emit: multiboot32-contigo'  'func main(): let w = 5  return w & 3 end'
reject_probe maxlocals      '-- emit: multiboot32-contigo' "$(gen_locals 32 a)"
reject_probe maxlocals_twin '-- emit: multiboot32-contigo' "$(gen_locals 32 z)"
# the input read is INTRINSIC to the contigo head, NOT body-callable: input_byte() in the body is rejected.
reject_probe in_body      '-- emit: multiboot32-contigo'  'func main(): return input_byte() end'
reject_probe in_body_twin '-- emit: multiboot32-contigo'  'func main(): return input_byte() + 1 end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 12))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link31 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link31 / contigo / f1 / fifteenth kernel-arc link: the first DATA-DEPENDENT SCHEDULING DECISION -- a freestanding 32-bit image reads one late-bound COM1 byte into a state cell [inq], and the timer-IRQ0 SCHEDULER loads [inq] and takes cmp;jae to SELECT which of two iret-seeded tasks to dispatch; the same image fed X=65 dispatches task A (emits vA) and Y=200 dispatches task B (emits 46), so the SCHEDULE is a function of runtime input; $pass checks: static + ELF-P12 + white-box [P0 exact 174-byte head'; P-inq input->state->scheduler value-bind (head mov[inq] addr == scheduler mov eax,[inq] addr); P-sched exact 30-byte scheduler exactly-once + the two mov-esp immediates bound to seedA/seedB by value + THRESH==128; P-tasks 0xE9 frame-emit exactly twice (one per task body) + ZERO in head/scheduler + task B exact + the proven 58-byte epilogue; P-antimut the ONLY absolute store is mov[inq] + task A body free of absolute addresses (the cross-model seed-mutation forge closed); P-reach head ends eb fe (no fall-through) + seed eips bound to the two task entries (decoy seed fails); P-seeds 8 zero GP + cs 0x08 + eflags 0x002 IF=0 (one-shot, no double-emit); P-IDT vec-0x20 gate attr 0x8E interrupt-gate -> scheduler vaddr by value + loaded-IDTR bind; P-GDT flat 9Acf/92cf; M1 BOUNDED whole-code-span disasm whitelist + exactly TWO in (%dx),%al + ONE iret + ONE sti + ONE lgdt + ONE lidt, banning int/call/ret/rdtsc/pushf/popf/cpuid/ins], QEMU substrate (5 probes co_then/co_else/co_lit/co_nolocal/co_cap31, late-bound socket COM1, same image fed X->A and Y->B), Bochs substrate ($BOCHS_PROBES, socket com1, frame + clean shutdown), 12 rejects with twins (call/mainarg/div/mod/bitwise/32-local cap/input_byte-in-body); graded vs host-derived golden on the dual-substrate oracle with a late-bound input substrate -- a CANONICAL-CODEGEN proof for the fixed probes)"
exit 0
