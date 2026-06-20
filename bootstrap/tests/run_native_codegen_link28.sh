#!/usr/bin/env bash
# Native codegen Link 28 (bluefield, the TWELFTH kernel-arc link): the freestanding image's first
# PREEMPTIVE CONTEXT SWITCH between two tasks. Reuses talkert/rizzing's 32-bit Multiboot substrate
# (GDT-install, PIC remap, PIT program, the flat tables) but the IRQ0 ISR is no longer pure glue:
# it is a SCHEDULER that saves the interrupted task's full GP+esp context into its per-task TCB slot
# and restores the other task's (pusha; mov [tcb+cur*4],esp; flip cur; mov esp,[tcb+cur*4]; EOI;
# popa; iret). Task B is started "from cold" via a pre-laid 44-byte SEEDED stack block (8 GP dwords
# in popa order + an iret frame eip=B_entry, cs=0x08, eflags=0x202 [IF=1]). The forcing observable is
# count-deterministic (a two-flag aready/bran handshake, NOT wall-time): task A's compiled body
# computes vA, A CARRIES it in edx (a register the toakie/rizzing lowering never writes), sets
# aready, then SPINS on bran; the timer preempts A, the scheduler switches to B; B writes its marker
# vB=46 to [shared], waits on aready, CLOBBERS edx (mov edx,0xB7B7B7B7), sets bran, and spins; the
# timer preempts B, the scheduler restores A's edx=vA, and A recovers (mov eax,edx; add eax,[shared])
# and emits the proof byte = (vA + vB) mod 256 via the shared 58-byte epilogue. The byte is correct
# ONLY if the switch genuinely SAVED A's edx (pusha onto A's stack) across B's clobber and RESTORED
# it (popa) -- a fake/absent switch yields a wrong byte or no frame. Task A's compiled body uses the
# EXISTING control-flow+locals subset UNCHANGED (no widen); task B is hand-emitted glue, so the
# eleven prior emit modes stay byte-identical and the self-host fixpoint gen2==gen1 is preserved.
# Graded, like lingo..rizzing, on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs vs a HOST-derived
# golden), not C.
#
# Selected by the anchored first-line directive "-- emit: multiboot32-bluefield" (a TWELFTH emit
# mode; the eleven prior modes are byte-identical, so gen2==gen1 holds).
#
# Image execution (vaddr V0=0x10000c=1048588): a fixed 114-byte HEAD' -- rizzing's 93-byte prefix
#   (GDT-install; PIC remap; PIT program) ending with `mov dword [cur],0` + `mov dword [tcb+4],seed`
#   (init scheduler state: current task = A, task-B TCB slot pre-points at the seeded stack) + `sti`
#   -- then NO hlt-loop: the mainline FALLS THROUGH into TASK A (the head's esp is A's stack). Task A:
#   [optional ebp frame] + the compiled body (eax=vA) + the A value-flow glue (mov edx,eax [carry];
#   mov dword[aready],1; SPIN mov eax,[bran];cmp eax,1;jne -10;cli; mov eax,edx [recover]; add eax,
#   [shared]) + the shared 58-byte epilogue (frame 0xDE<byte>0xAD on 0xE9, result-dependent isa-debug-
#   exit on 0xF4, "Shutdown" on 0x8900, cli;hlt). Then TASK B glue (reached ONLY via the scheduler's
#   first switch using the seeded stack): mov eax,46; mov [shared],eax; WAIT mov eax,[aready];cmp 1;
#   jne -10; mov edx,0xB7B7B7B7 [clobber]; mov dword[bran],1; jmp $-2 [spin]. Then the SCHEDULER ISR
#   (pusha; mov eax,[cur]; mov [tcb+eax*4],esp; xor eax,1; mov [cur],eax; mov esp,[tcb+eax*4]; EOI;
#   popa; iret). Then the flat GDT/GDTR + IDT (vec-0x20 -> the SCHEDULER) + IDTR (300-byte tables,
#   reused verbatim from talkert) + pad + the data cells (cur,tcb0,tcb1,aready,bran,shared) + a B-stack
#   region + the 44-byte SEEDED block (eip=B_entry,cs=0x08,eflags=0x202) + guard.
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; multiboot magic in first 8 KiB & 4-aligned; ZERO
#     syscall escapes (0F05 / CD80 / 0F34) in the head+taskA-body+epilogue window (bounded by the
#     epilogue terminal faf4ebfd) AND an objdump scan finds no syscall/sysenter/int there.
#   WHITE-BOX (per probe; the runtime byte alone is forgeable -- a single mainline computing vA+vB
#   with a dead scheduler/seed nearby [FORGE-2, the full-ceremony-dead-switch], a restore-without-save,
#   a cooperative int 0x20, a seed pointing somewhere other than B, or a wrong-cell spin would also
#   produce a byte -- so prove the STRUCTURE and bind every cell/artifact the CPU selects by VALUE):
#     (P0) THE EXACT 114-BYTE HEAD' (only gdtr/esp/idtr/cur/tcb1/seed le32 vary): GDT-install + EXACT
#       PIC-remap + EXACT PIT-program + `mov dword[cur],0` + `mov dword[tcb+4],seed` + sti.
#     (P1) TASK-A VALUE-FLOW + EPILOGUE START, exactly once (THE FORGE-2 KILLER): mov edx,eax (89c2,
#       the edx carry) + mov dword[aready],1 + SPIN (a1<bran> 83 f8 01 75 f6 [jne -10, back-edge
#       reachability] fa [cli]) + mov eax,edx (89d0, the recover) + add eax,[shared] (0305<shared>) +
#       the epilogue start (88c366bae900). A `mov eax,imm` body with a live-but-dead switch nearby has
#       none of this contiguous structure.
#     (P2) THE SCHEDULER ISR exactly once: pusha (60) + mov eax,[cur] (a1<cur>) + mov [tcb+eax*4],esp
#       (892485<tcb>) + xor eax,1 (83f001) + mov [cur],eax (a3<cur>) + mov esp,[tcb+eax*4] (8b2485<tcb>)
#       + EOI (b020e620) + popa (61) + iret (cf). The pusha/popa pin the FULL context save/restore; the
#       two 2485<tcb> pin the stack-switch; EOI+iret pin the async survival.
#     (P3) FIVE-CELL PROVENANCE (the loader/CPU-redirect meta-class -- bind by VALUE): cur (head ==
#       sched-read == sched-write), tcb (sched-save == sched-load; head tcb1 == tcb base+4), aready (A
#       writes == B reads), bran (A reads == B writes), shared (A reads == B writes). A forge that
#       spins/saves/signals on different cells than its counterpart FAILS here.
#     (P4) SEEDED-BLOCK value-binds: the head's seeded esp (tcb1 init) points at a block whose iret
#       eip == B_entry (the START of task B's glue, by value), cs == 0x08, eflags == 0x202 (IF=1), and
#       whose 8 GP slots are zero. Binds the artifact the CPU iret's into -- a decoy seed FAILS.
#     (P5) THE IDT vec-0x20 GATE -> the SCHEDULER (bind by value) + the loaded-IDTR -> checked-gate
#       bind (rizzing's 4b): the CPU vectors IRQ0 through the LOADED idtr, so a decoy lidt FAILS.
#     (P6) the flat GDT code (9A CF) + data (92 CF) + GDTR.limit=0x17.
#     (P7) THE TASK-A BODY [after head'/ebp .. value-flow start] IS FREE of I/O + privileged
#       instructions and uses only DIRECT je/jne/jmp to in-body boundaries (closes synchronous-emit +
#       software-int forges).
#     (P8) THE SINGLE EMIT PATH: mov dx,0x00E9 (66 BA E9 00) occurs EXACTLY ONCE.
#     (P9) TASK-B REACHABILITY: task A ends in the epilogue terminal faf4ebfd and task B starts AFTER
#       it -- B is NOT fall-through-reachable from A; it runs ONLY via the seeded iret (P4 binds eip).
#     (P10) B-STACK HEADROOM: seed_vaddr - 44 >= shared_vaddr + 4 (B's interrupt frames cannot scribble
#       the data cells).
#     (P11) branching probes: a real `je` (0F 84) on an instruction boundary.
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit == host golden, e9 == 0xDE<byte>0xAD, ONE frame (after a
#       genuine A->B->A preemptive round trip).
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence.
#   PROBE VECTORS: then-arm + else-arm + literal + no-locals + 31-local cap. Each: byte = (body return
#     + vB=46) mod 256, produced only after a real preemptive switch saved/restored A's edx across B.
#   REJECTS (+ twins): out-of-subset bodies (div/mod, bitwise, 2-function, non-EQ comparator,
#     parameterised main, non-EQ bool cond) emit NO valid image; the 32-local cap (ERR 501) too.
#
# Honest scope: proves "a freestanding 32-bit Multiboot image performs a PREEMPTIVE CONTEXT SWITCH
# between two tasks -- the timer-driven scheduler saves task A's full GP+esp context, runs task B
# (which clobbers A's carried register), and restores A so its mid-flight value survives -- under QEMU
# + Bochs+GRUB," NOT real silicon, arbitrary emulator versions, a FULL architectural switch (no
# segment regs / CR3 / FPU / per-task address space), long mode, or MMIO. Still 32-bit PM, port output
# only (D18 port input deferred). The exact count, the seeded eflags, and the scheduler structure are
# pinned WHITE-BOX (not silicon-witnessable). What IS silicon-proven (mutation harness): the full
# save/restore, the stack-switch, the EOI, the iret-resume, the seeded eip/eflags, and the edx-carry
# are load-bearing -- break any and no frame appears or the byte is wrong. The dual-substrate + host
# golden replaces the absent C differential.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L12_BOCHS_PROBES:-bf_then bf_else}"

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

host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

# decode a 4-byte little-endian word from a hex string at hex-char offset o (8 hex chars)
le32_at() { hx="$1"; o="$2"; echo $((16#${hx:o+6:2}${hx:o+4:2}${hx:o+2:2}${hx:o+0:2})); }

VB=46   # task B's marker, written to [shared]; byte = (body return + VB) mod 256

gen_locals() { # n prefix
    local n="$1" pfx="$2" s='func main():' i
    for i in $(seq 0 $((n - 1))); do s="$s let $pfx$i = $i"; done
    echo "$s return $pfx$((n - 1)) end"
}

prog_src() { # label
    case "$1" in
      bf_then)    echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      bf_else)    echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      bf_lit)     echo 'func main(): return 46 end' ;;
      bf_nolocal) echo 'func main(): return 77 end' ;;
      bf_cap31)   gen_locals 31 a ;;
    esac
}
prog_byte() { # label -> host-derived expected low byte = (body return value + VB) mod 256
    local r
    case "$1" in
      bf_then)    r=88 ;;
      bf_else)    r=11 ;;
      bf_lit)     r=46 ;;
      bf_nolocal) r=77 ;;
      bf_cap31)   r=30 ;;
    esac
    echo $(( (r + VB) % 256 ))
}
is_branching() { case "$1" in bf_then|bf_else) return 0 ;; *) return 1 ;; esac; }
ALL_PROBES="bf_then bf_else bf_lit bf_nolocal bf_cap31"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-bluefield\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1
    fi
    cp "$cdir/a.out" "$out"; return 0
}

static_gates() { # label elf
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx magoff; hx=$(xxd -p "$elf" | tr -d '\n')
    magoff=$(( $(echo "$hx" | grep -bo '02b0ad1b' | head -1 | cut -d: -f1) / 2 ))
    if ! { [[ -n "$magoff" ]] && [[ "$magoff" -lt 8192 ]] && [[ $((magoff % 4)) -eq 0 ]]; }; then
        fail_test "$label static: multiboot magic placement ($magoff)"; ok=0
    fi
    local code="$tmp/$label.code"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # Bound the escape scan to head+taskA-body+epilogue by the epilogue terminal (cli;hlt;jmp$-1 =
    # faf4ebfd). Task B / scheduler / tables after it are pinned white-box, not escape-scanned.
    local term="${chx%%faf4ebfd*}"
    if [[ "$term" == "$chx" ]]; then fail_test "$label static: epilogue terminal absent"; return 1; fi
    local endbytes=$(( ${#term} / 2 + 4 ))
    dd if="$code" of="$code.t" bs=1 count="$endbytes" status=none 2>/dev/null
    local cth; cth=$(xxd -p "$code.t" | tr -d '\n')
    echo "$cth" | grep -q '0f05' && { fail_test "$label static: 0F 05 (syscall) byte present"; ok=0; }
    echo "$cth" | grep -q 'cd80' && { fail_test "$label static: CD 80 (int 0x80) byte present"; ok=0; }
    echo "$cth" | grep -q '0f34' && { fail_test "$label static: 0F 34 (sysenter) byte present"; ok=0; }
    local dis; dis=$(objdump -D -b binary -m i386 -M intel "$code.t" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
    if echo "$dis" | grep -qiE '\b(syscall|sysenter)\b|\bint[ ]+\$?0x'; then
        fail_test "$label static: disasm shows a syscall/sysenter/int instruction"; ok=0
    fi
    [[ "$ok" -eq 1 ]]
}

# occurrence count of an (extended) regex in a hex string -- asserts a pin is EXACTLY-ONCE.
occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }

# the exact 114-byte head' (only gdtr/esp/idtr/cur/tcb1/seed le32 vary)
HEAD='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe640c705[0-9a-f]{8}00000000c705[0-9a-f]{8}[0-9a-f]{8}fb'
# task-A value-flow + epilogue start (THE FORGE-2 KILLER): edx carry; aready; spin(bran,cmp 1,jne -10,cli); recover; add shared; epilogue
VFLOW='89c2c705[0-9a-f]{8}01000000a1[0-9a-f]{8}83f80175f6fa89d00305[0-9a-f]{8}88c366bae900'
# the scheduler ISR (full context save/restore + stack switch + EOI + iret)
SCHED='60a1[0-9a-f]{8}892485[0-9a-f]{8}83f001a3[0-9a-f]{8}8b2485[0-9a-f]{8}b020e62061cf'
# task B glue (marker write; wait on aready; clobber edx; signal bran; spin)
TASKB='b82e000000a3[0-9a-f]{8}a1[0-9a-f]{8}83f80175f6bab7b7b7b7c705[0-9a-f]{8}01000000ebfe'

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # (P0) THE EXACT 114-BYTE HEAD' at offset 0.
    [[ "${chx:0:228}" =~ $HEAD ]] || { fail_test "$label whitebox(P0): head' != exact 114-byte GDT-install+PIC-remap+PIT-program+mov[cur],0+mov[tcb1],seed+sti template"; ok=0; }
    # (P1) TASK-A VALUE-FLOW + EPILOGUE, exactly once (the forge-2 killer).
    [[ "$(occ "$chx" "$VFLOW")" == 1 ]] || { fail_test "$label whitebox(P1): task-A value-flow (edx carry; aready; spin-on-bran [jne -10/cmp 1]; recover; add[shared]; epilogue) not present exactly once -- a mov-eax-imm body with a dead switch would fail here"; ok=0; }
    # (P2) THE SCHEDULER ISR, exactly once.
    [[ "$(occ "$chx" "$SCHED")" == 1 ]] || { fail_test "$label whitebox(P2): scheduler ISR (pusha; mov[tcb+eax*4],esp; flip cur; mov esp,[tcb+eax*4]; EOI; popa; iret) not present exactly once"; ok=0; }
    # (P_taskB) task B glue, exactly once.
    [[ "$(occ "$chx" "$TASKB")" == 1 ]] || { fail_test "$label whitebox: task-B glue (mov[shared],46; wait aready; clobber edx; signal bran; spin) not present exactly once"; ok=0; }
    # locate anchors
    local va_pos sched_pos tb_pos
    va_pos=$(echo "$chx" | grep -boE "$VFLOW" | head -1 | cut -d: -f1)
    sched_pos=$(echo "$chx" | grep -boE "$SCHED" | head -1 | cut -d: -f1)
    tb_pos=$(echo "$chx" | grep -boE "$TASKB" | head -1 | cut -d: -f1)
    if [[ -z "$va_pos" || -z "$sched_pos" || -z "$tb_pos" ]]; then
        fail_test "$label whitebox: cannot locate value-flow / scheduler / task-B anchors"; echo "  [$pass passed before abort]"; return 1
    fi
    # (P3) FIVE-CELL PROVENANCE (bind by VALUE).
    local head_cur head_tcb1 head_seed head_idtr
    head_cur=$(le32_at "$chx" 190)     # head mov[cur],0
    head_tcb1=$(le32_at "$chx" 210)    # head mov[tcb1],seed : the tcb1 SLOT address
    head_seed=$(le32_at "$chx" 218)    # head mov[tcb1],seed : the seeded esp value
    head_idtr=$(le32_at "$chx" 74)     # head lidt operand
    local sched_cur1 tcb_save sched_cur2 tcb_load
    sched_cur1=$(le32_at "$chx" $((sched_pos + 4)))
    tcb_save=$(le32_at "$chx" $((sched_pos + 18)))
    sched_cur2=$(le32_at "$chx" $((sched_pos + 34)))
    tcb_load=$(le32_at "$chx" $((sched_pos + 48)))
    local a_aready a_bran a_shared
    a_aready=$(le32_at "$chx" $((va_pos + 8)))
    a_bran=$(le32_at "$chx" $((va_pos + 26)))
    a_shared=$(le32_at "$chx" $((va_pos + 54)))
    local b_shared b_aready b_bran
    b_shared=$(le32_at "$chx" $((tb_pos + 12)))
    b_aready=$(le32_at "$chx" $((tb_pos + 22)))
    b_bran=$(le32_at "$chx" $((tb_pos + 54)))
    { [[ "$head_cur" == "$sched_cur1" ]] && [[ "$sched_cur1" == "$sched_cur2" ]]; } \
        || { fail_test "$label whitebox(P3-cur): cur cell mismatch (head=$head_cur sched_rd=$sched_cur1 sched_wr=$sched_cur2)"; ok=0; }
    { [[ "$tcb_save" == "$tcb_load" ]] && [[ $((tcb_save + 4)) -eq "$head_tcb1" ]]; } \
        || { fail_test "$label whitebox(P3-tcb): tcb cell mismatch (save=$tcb_save load=$tcb_load head_tcb1=$head_tcb1 want save+4==head_tcb1)"; ok=0; }
    [[ "$a_aready" == "$b_aready" ]] || { fail_test "$label whitebox(P3-aready): A writes $a_aready, B reads $b_aready"; ok=0; }
    [[ "$a_bran" == "$b_bran" ]] || { fail_test "$label whitebox(P3-bran): A spins on $a_bran, B writes $b_bran"; ok=0; }
    [[ "$a_shared" == "$b_shared" ]] || { fail_test "$label whitebox(P3-shared): A reads $a_shared, B writes $b_shared"; ok=0; }
    # (P4) SEEDED-BLOCK value-binds (bind the artifact the CPU iret's into).
    local b_entry seed_off seed_hex seed_eip seed_cs seed_eflags
    b_entry=$(( 1048588 + tb_pos / 2 ))
    seed_off=$(( head_seed - 1048588 ))
    seed_hex=$(( seed_off * 2 ))
    if [[ "$seed_off" -lt 0 ]] || [[ $(( seed_hex + 88 )) -gt ${#chx} ]]; then
        fail_test "$label whitebox(P4): seeded esp (head_seed=$head_seed) points outside the image"; ok=0
    else
        local gp_zero="${chx:seed_hex:64}"
        [[ "$gp_zero" =~ ^0{64}$ ]] || { fail_test "$label whitebox(P4): seeded GP block not 8 zero dwords"; ok=0; }
        seed_eip=$(le32_at "$chx" $((seed_hex + 64)))
        seed_cs=$(le32_at "$chx" $((seed_hex + 72)))
        seed_eflags=$(le32_at "$chx" $((seed_hex + 80)))
        [[ "$seed_eip" -eq "$b_entry" ]] || { fail_test "$label whitebox(P4): seeded eip ($seed_eip) != B_entry ($b_entry) -- decoy seed"; ok=0; }
        [[ "$seed_cs" -eq 8 ]] || { fail_test "$label whitebox(P4): seeded cs ($seed_cs) != 0x08"; ok=0; }
        [[ "$seed_eflags" -eq 514 ]] || { fail_test "$label whitebox(P4): seeded eflags ($seed_eflags) != 0x202 (IF must be set)"; ok=0; }
    fi
    # (P5) IDT vec-0x20 GATE -> the SCHEDULER vaddr (by value) + loaded-IDTR -> checked-gate bind.
    local gmid; gmid="$(occ "$chx" '0800008e')"
    if [[ "$gmid" != 1 ]]; then
        fail_test "$label whitebox(P5): IDT gate middle (sel 0x08 / attr 0x8E = 0800008e) not present exactly once"; ok=0
    else
        local sched_vaddr; sched_vaddr=$(( 1048588 + sched_pos / 2 ))
        local mpos; mpos=$(echo "$chx" | grep -bo '0800008e' | head -1 | cut -d: -f1)
        local lo16="${chx:mpos-4:4}" hi16="${chx:mpos+8:4}" after="${chx:mpos+12:4}"
        local lo_v=$(( 16#${lo16:2:2}${lo16:0:2} ))
        local hi_v=$(( 16#${hi16:2:2}${hi16:0:2} ))
        local gate_target=$(( (hi_v << 16) | lo_v ))
        [[ "$gate_target" -eq "$sched_vaddr" ]] || { fail_test "$label whitebox(P5): IDT vec-0x20 gate target ($gate_target) != scheduler vaddr ($sched_vaddr) -- decoy gate"; ok=0; }
        [[ "$after" == "0701" ]] || { fail_test "$label whitebox(P5): IDTR limit 0x0107 (le 0701) does not immediately follow the gate"; ok=0; }
        local idtr_off=$(( (head_idtr - 1048588) * 2 ))
        if [[ "$idtr_off" -lt 0 ]] || [[ $(( idtr_off + 12 )) -gt ${#chx} ]]; then
            fail_test "$label whitebox(P5b): head' loaded IDTR vaddr ($head_idtr) outside the image -- lidt-redirect forge"; ok=0
        else
            local idtr_limit_hex="${chx:idtr_off:4}"
            local idtr_base; idtr_base=$(le32_at "$chx" $(( idtr_off + 4 )))
            local gate_start_vaddr=$(( 1048588 + (mpos - 4) / 2 ))
            [[ "$idtr_limit_hex" == "0701" ]] || { fail_test "$label whitebox(P5b): loaded IDTR limit ($idtr_limit_hex) != 0701 -- lidt-redirect forge"; ok=0; }
            [[ $(( idtr_base + 256 )) -eq "$gate_start_vaddr" ]] || { fail_test "$label whitebox(P5b): loaded IDTR base ($idtr_base)+0x100 != checked vec-0x20 gate vaddr ($gate_start_vaddr) -- lidt-redirect forge"; ok=0; }
        fi
    fi
    # (P6) flat GDT.
    [[ "$(occ "$chx" '9acf00')" == 1 ]] || { fail_test "$label whitebox(P6): flat 32-bit code descriptor (9A CF) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '92cf001700')" == 1 ]] || { fail_test "$label whitebox(P6): data descriptor + GDTR limit 0x17 not present exactly once"; ok=0; }
    # (P7) TASK-A BODY [after head'/ebp .. value-flow start] free of I/O+privileged + direct-control-only.
    local body_start=114
    if [[ "${chx:228:8}" == "89e583ec" ]]; then body_start=119; fi   # ebp prologue present
    local body_end=$(( va_pos / 2 ))
    if [[ "$body_end" -lt "$body_start" ]]; then
        fail_test "$label whitebox(P7): value-flow precedes the body start"; ok=0
    else
        dd if="$code" of="$code.rb" bs=1 skip="$body_start" count=$(( body_end - body_start + 6 )) status=none 2>/dev/null
        local rdis; rdis=$(objdump -D -b binary -m i386 -M intel "$code.rb" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
        if echo "$rdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -qiE '^(outs?b?|insb?|out|in|int|into|int3|lgdtd?|lidtd?|sgdtd?|sidtd?|lldt|ltr|lmsw|hlt|iretd?|sti|cli|wrmsr|rdmsr|invlpgd?|invd|wbinvd|sysenter|syscall)\b|cr[0-9]|dr[0-9]'; then
            fail_test "$label whitebox(P7): task-A body contains an I/O / privileged instruction"; ok=0
        fi
        local ctl; ctl=$(echo "$rdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -iE '^(j[a-z]+|call[a-z]*|loop[a-z]*|ret[a-z]*|iret[a-z]*|int[0-9a-z]*|into|syscall|sysenter)\b')
        if [[ -n "$ctl" ]] && echo "$ctl" | grep -qvE '^(je|jne|jmp) +0x[0-9a-f]+'; then
            fail_test "$label whitebox(P7): task-A body has a non-direct/forbidden control transfer (indirect/call/far/int/ret)"; ok=0
        fi
        echo "$rdis" | grep -qiE '\bret\b' && { fail_test "$label whitebox(P7): x86 ret in task-A body"; ok=0; }
        # (P7-edx) the carried register edx must NOT appear in task A's BODY PROPER [body_start..body_end)
        # -- the toakie/rizzing lowering uses only eax/ecx/ebp/esp, so any edx mention would mean the carry
        # could be clobbered before A sets it (closes the implicit-edx-contract note; bites a future widen).
        # Disassemble the body ALONE (no +6 trailer, which is the value-flow's legitimate mov edx,eax carry).
        dd if="$code" of="$code.bo" bs=1 skip="$body_start" count=$(( body_end - body_start )) status=none 2>/dev/null
        local bdis; bdis=$(objdump -D -b binary -m i386 -M intel "$code.bo" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
        echo "$bdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -qiE '\b(edx|dx|dl|dh)\b' && { fail_test "$label whitebox(P7-edx): task-A body references edx -- the carried register could be clobbered"; ok=0; }
    fi
    # (P8) THE SINGLE EMIT PATH.
    [[ "$(occ "$chx" '66bae900')" == 1 ]] || { fail_test "$label whitebox(P8): the 0xE9 frame-emit (mov dx,0x00E9) not present exactly once"; ok=0; }
    # (P9) TASK-B REACHABILITY: task A ends in faf4ebfd and task B starts AFTER it (not fall-through).
    local term_pos; term_pos=$(echo "$chx" | grep -bo 'faf4ebfd' | head -1 | cut -d: -f1)
    if [[ -z "$term_pos" ]]; then
        fail_test "$label whitebox(P9): epilogue terminal faf4ebfd absent"; ok=0
    else
        [[ "$tb_pos" -gt "$term_pos" ]] || { fail_test "$label whitebox(P9): task B ($tb_pos) is not after task A's epilogue terminal ($term_pos) -- B may be fall-through-reachable"; ok=0; }
    fi
    # (P10) B-STACK HEADROOM: seed_vaddr - 44 >= shared_vaddr + 4.
    [[ $(( head_seed - 44 )) -ge $(( a_shared + 4 )) ]] || { fail_test "$label whitebox(P10): B-stack headroom (seed-44=$((head_seed-44))) < top data cell+4 ($((a_shared+4))) -- B's frames can scribble the cells"; ok=0; }
    # (P11) branching probes must contain a real je (0F 84).
    if is_branching "$label"; then
        echo "$chx" | grep -q '0f84' || { fail_test "$label whitebox(P11): branching probe has no je (0F 84)"; ok=0; }
    fi
    [[ "$ok" -eq 1 ]]
}

# (P12) ELF ENTRY + PHDR bind -- the loader/CPU-redirect meta-class (cf. hoopteeter). The white-box
# pins read the code at the FIXED file offset 4108 and assume that is what the CPU executes at vaddr
# V0; bind the artifact the LOADER actually selects. A forge can leave a faithful switch as a DECOY at
# 4108, append a single-task payload, extend p_filesz, and repoint e_entry -- passing every byte pin
# and booting green (a dual-model adversarial leg built this). So assert, BY VALUE, that the ELF entry
# is V0 (the head' start), there is exactly ONE PT_LOAD, and it maps file offset 4096 -> vaddr
# 0x100000 (so file 4108 <-> vaddr V0 is the unique mapping the gate analyzed).
elf_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local e_entry e_phoff e_phnum
    e_entry=$(le32_at "$eh" 48)                       # ehdr e_entry @ byte 24
    e_phoff=$(le32_at "$eh" 56)                       # ehdr e_phoff @ byte 28
    e_phnum=$(( 16#${eh:90:2}${eh:88:2} ))           # ehdr e_phnum @ byte 44 (le16)
    [[ "$e_entry" -eq 1048588 ]] || { fail_test "$label elf(P12): e_entry ($e_entry) != 1048588 (V0, head' start) -- entry-redirect forge"; ok=0; }
    [[ "$e_phoff" -eq 52 ]] || { fail_test "$label elf(P12): e_phoff ($e_phoff) != 52"; ok=0; }
    [[ "$e_phnum" -eq 1 ]] || { fail_test "$label elf(P12): e_phnum ($e_phnum) != 1 -- a second PT_LOAD could remap the entry"; ok=0; }
    local p_type p_offset p_vaddr p_flags
    p_type=$(le32_at "$eh" 104)                       # phdr p_type @ file 52
    p_offset=$(le32_at "$eh" 112)                     # phdr p_offset @ file 56
    p_vaddr=$(le32_at "$eh" 120)                      # phdr p_vaddr @ file 60
    p_flags=$(le32_at "$eh" 152)                      # phdr p_flags @ file 76
    [[ "$p_type" -eq 1 ]] || { fail_test "$label elf(P12): PT_LOAD type ($p_type) != 1"; ok=0; }
    [[ "$p_offset" -eq 4096 ]] || { fail_test "$label elf(P12): p_offset ($p_offset) != 4096 -- file/vaddr remap forge"; ok=0; }
    [[ "$p_vaddr" -eq 1048576 ]] || { fail_test "$label elf(P12): p_vaddr ($p_vaddr) != 1048576 -- remap forge"; ok=0; }
    [[ "$p_flags" -eq 7 ]] || { fail_test "$label elf(P12): p_flags ($p_flags) != 7"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

qemu_run() { # label byte elf
    local label="$1" p="$2" elf="$3"
    local ex ph; ex=$(host_qemu_exit "$p"); ph=$(printf '%02x' "$p")
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

bochs_run() { # label byte elf
    local label="$1" p="$2" elf="$3"
    local ph; ph=$(printf '%02x' "$p")
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
megs: 32
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
    printf -- "-- emit: multiboot32-bluefield\n%b\n" "$prog" > "$cdir/probe.herb"
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
    echo "SKIP: native-codegen link28 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
fi

run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1
fi

for label in $ALL_PROBES; do
    elf="$tmp/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    elf_gates "$label" "$elf" || continue
    whitebox_gates "$label" "$elf" || continue
    if ! have_qemu; then pass=$((pass + 1)); continue; fi
    byte=$(prog_byte "$label")
    if qemu_run "$label" "$byte" "$elf"; then
        bochs_ok=1
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
            bochs_run "$label" "$byte" "$elf" || bochs_ok=0
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
    echo "$fail native-codegen-link28 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link28 / bluefield / twelfth kernel-arc link: a freestanding 32-bit Multiboot image performs a PREEMPTIVE CONTEXT SWITCH between two tasks -- the timer-driven SCHEDULER ISR (pusha; save esp->TCB; flip cur; load esp<-TCB; EOI; popa; iret) saves task A's full GP+esp context, runs task B (seeded from a pre-laid stack block; clobbers A's carried edx), and restores A so its mid-flight value survives, then A emits (vA+vB) on bare metal; $pass checks: static + white-box (P0 exact 114-byte head', P1 task-A value-flow [edx carry+spin-on-bran+recover+add shared+epilogue] exactly-once [the forge-2 killer], P2 scheduler ISR exactly-once [full save/restore+stack-switch+EOI+iret], P3 five-cell provenance [cur/tcb/aready/bran/shared bound by value], P4 seeded-block binds [eip==B_entry, cs=0x08, eflags=0x202], P5 IDT vec-0x20->scheduler + loaded-IDTR bind, P6 flat GDT, P7 task-A body free of I/O+privileged + direct-control-only, P8 single 0xE9 emit, P9 task-B reached only via seeded iret, P10 B-stack headroom, P11 real je on boundary, P12 ELF entry==V0 + single PT_LOAD maps 4096->0x100000 [the loader/CPU-redirect close]), QEMU substrate (5 probes: then+else+literal+no-locals+31-local cap, result-dependent exit after a genuine A->B->A round trip), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 14 out-of-subset rejects with twins incl. the 32-local cap (ERR 501); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
