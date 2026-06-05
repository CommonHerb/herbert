#!/usr/bin/env bash
# Native codegen Link 27 (rizzing, the ELEVENTH kernel-arc link): the freestanding image's first
# MAINLINE task that SYNCHRONIZES with the timer ISR through a SHARED MEMORY word. Reuses talkert's
# (link24) 32-bit Multiboot substrate -- GDT-install, PIC remap, PIT program, the flat tables -- but
# inverts the tick mechanism: the tick counter moves from esi (a register that survived the async
# interrupts in talkert) to a MEMORY word `tick`. The IRQ0 ISR becomes PURE GLUE -- push eax; inc
# dword [tick]; EOI (out 0x20,0x20); pop eax; iret -- it preserves the interrupted mainline's eax
# (else an IRQ landing between the spin's load of [tick] and the compare corrupts the test; the Bochs
# substrate caught this). The compiled body moves OUT of the handler into the MAINLINE, which SPINS on
# the shared word (mov eax,[tick]; cmp eax,N; jb back-edge) until N=3 ticks have accrued, then `cli`
# and runs the compiled body + the shared 58-byte epilogue. The proof byte = the body's return value
# (anti-ceremony: tracks the body) AND can only appear after the mainline SURVIVES N async ticks bumped
# by the glue ISR through the shared cell (the mainline spin never advances without the ISR's inc, and
# the ISR's inc is dead unless the EOI keeps IRQ0 re-delivering). The IDT vec-0x20 gate points at the
# glue ISR. The compiled body uses the EXISTING control-flow+locals subset UNCHANGED (no widen), so the
# ten prior modes stay byte-identical and the native self-host fixpoint gen2==gen1 is preserved. Graded,
# like lingo/toakie/zonday/chosen/liberi/scottie/talcott/talkert, on the far-axis DUAL-SUBSTRATE oracle
# (QEMU + Bochs vs a HOST-derived golden), not C.
#
# Selected by the anchored first-line directive "-- emit: multiboot32-rizzing" (an ELEVENTH emit mode;
# the plain "-- emit: multiboot32", "-idt", "-page", "-store", "-demand", "-timer", "-tick", and default
# ELF64 modes are byte-identical, so the native self-host fixpoint gen2==gen1 is preserved).
#
# Image execution (vaddr V0=0x10000c=1048588): a fixed 104-byte HEAD' -- talkert's head shape (GDT-
#   install; far-jmp; segment reload; mov esp; lidt; 10 PIC out-imm writes [remap + IRQ0-only IMR]; 3
#   PIT writes [mode 2, divisor 0xFFFF]) but ending with `mov dword [tick],0` (c7 05 <le32 tick> 00 00
#   00 00 -- zero the shared tick word, NOT xor esi,esi) then `sti` -- and NO hlt-loop: the mainline
#   FALLS THROUGH into the GLUE-SPIN (11 B): mov eax,[tick]; cmp eax,3; jb -10 (back-edge to the mov);
#   cli. On IRQ0 the CPU vectors via the IDT vec-0x20 gate to the GLUE-ISR (13 B, after the variable-
#   length body): push eax; inc dword [tick]; mov al,0x20; out 0x20,al; pop eax; iret. After N=3 ticks
#   the spin's jb falls through, cli, then the compiled body + the shared 58-byte epilogue emit (frame
#   0xDE<byte>0xAD on 0xE9, result-dependent isa-debug-exit on 0xF4, "Shutdown" on 0x8900, cli;hlt) and
#   exit. Then the flat GDT/GDTR + 256-zero-prefix IDT (vec-0x20 -> the glue ISR) + IDTR (300-byte
#   tables, reused verbatim from talkert) + pad + the 4-byte tick word.
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; multiboot magic in first 8 KiB & 4-aligned; ZERO
#     syscall escapes (0F05 / CD80 / 0F34) in the head+spin+body+epilogue window (bounded by the
#     epilogue terminal faf4ebfd) AND an objdump scan finds no syscall/sysenter/int there.
#   WHITE-BOX (per probe; the runtime byte alone is forgeable -- a synchronous `out`, a software `int
#   0x20`, a single-tick exit, a spin-on-a-different-cell, or a fall-through would also produce a byte --
#   so prove the structure):
#     - THE EXACT 104-BYTE HEAD' (only gdtr/esp/idtr/tick le32 vary): GDT-install + EXACT PIC-remap +
#       EXACT PIT-program + `mov dword [tick],0` + sti. Pins EVERY behaviorally-invisible element at once
#       (PIC slave + IMR, PIT divisor, the tick-zero, sti) at offset 0.
#     - THE GLUE-SPIN exact-once: mov eax,[tick] (a1+le32) + cmp eax,3 (83 f8 03) + jb -10 (72 f6, the
#       back-edge to the spin top) + cli (fa). The N=3 count is pinned here (white-box, like talkert's
#       PIT divisor -- the exact count is not silicon-witnessable). The jb -10 back-edge is the
#       REACHABILITY bind: it loops to the mov eax,[tick], so the spin genuinely re-reads the shared
#       word each iteration (a jb that lands elsewhere would not spin on the cell).
#     - THE GLUE-ISR exact-once: push eax + inc dword [tick] (ff 05 + le32) + EOI (b0 20 e6 20) + pop eax
#       + iret (cf). The push/pop eax pins the eax-preservation; the EOI + iret pin the async-survival.
#     - TICK-CELL PROVENANCE (the loader/CPU-redirect meta-class -- bind by VALUE): the head's
#       c705<le32>, the spin's a1<le32>, and the ISR's ff05<le32> MUST all be the SAME le32. A forge that
#       spins on a different cell than the ISR bumps (or the head zeroes) FAILS here -- it would never
#       advance, or advance on a stale cell.
#     - THE IDT vec-0x20 GATE -> the GLUE-ISR (bind by value): the gate's offset-lo/offset-hi reassemble
#       to EXACTLY the glue-ISR vaddr (1048588 + isr_code_offset), sel 0x08, attr 0x8E, immediately
#       before IDTR.limit=0x0107 -- a decoy gate / wrong vector / wrong limit fails.
#     - the flat GDT code (9A CF) + data (92 CF) + GDTR.limit=0x17.
#     - THE BODY [spin-cli .. epilogue start] IS FREE of I/O and privileged instructions and uses only
#       DIRECT je/jne/jmp to in-body boundaries (no out/in/int/iret/sti/cli/mov cr, no indirect/far/
#       call/ret) -- closes the synchronous-emit AND software-`int 0x20` (direct + indirect) forges.
#     - THE SINGLE EMIT PATH: mov dx,0x00E9 (66 BA E9 00) occurs EXACTLY ONCE (in the epilogue) -- so
#       there is one frame-emit and it is on the mainline's post-spin path.
#     - branching probes: a real `je` (0F 84) on an instruction boundary.
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit == host golden, e9 == 0xDE<byte>0xAD, ONE frame (after
#       surviving N=3 ticks via the shared-cell spin).
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence.
#   PROBE VECTORS: then-arm + else-arm + literal + no-locals + 31-local cap. Each proves the body ran
#     AND the byte came after the mainline survived the shared-cell tick count.
#   REJECTS (+ twins): out-of-subset bodies (div/mod, bitwise, 2-function, non-EQ comparator,
#     parameterised main, non-EQ bool cond) emit NO valid image; the 32-local cap (ERR 495) too.
#
# Honest scope: proves "a MAINLINE task SYNCHRONIZES with the async timer IRQ through a SHARED MEMORY
# word (the ISR bumps [tick], the mainline spins on it, surviving N=3 ticks via EOI-sustained re-delivery
# + eax-preserving iret-resume) and runs a compiled body as a freestanding 32-bit Multiboot image under
# QEMU + Bochs+GRUB," NOT real silicon, arbitrary emulator versions, long mode, or MMIO. Still 32-bit PM,
# port output only (D18 port input deferred). The PIT divisor, the EXACT count N=3, and the masked/not-
# present table entries are NOT silicon-witnessable -- they are pinned WHITE-BOX by the exact-head' +
# spin + ISR + tables gates. What IS silicon-proven (mutation harness): the EOI, the iret-resume, the
# per-tick inc, and the sti ARE load-bearing -- drop any and no frame appears (the mainline cannot get
# past the spin), so the image genuinely survives+repeats >=1 acknowledged interrupt and synchronizes on
# the shared cell. The dual-substrate + host golden replaces the absent C differential.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L11_BOCHS_PROBES:-rizz_then rizz_else}"

if [[ ! -x "$HERBERT" ]]; then
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

gen_locals() { # n prefix
    local n="$1" pfx="$2" s='func main():' i
    for i in $(seq 0 $((n - 1))); do s="$s let $pfx$i = $i"; done
    echo "$s return $pfx$((n - 1)) end"
}

prog_src() { # label
    case "$1" in
      rizz_then)    echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      rizz_else)    echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      rizz_lit)     echo 'func main(): return 46 end' ;;
      rizz_nolocal) echo 'func main(): return 77 end' ;;
      rizz_cap31)   gen_locals 31 a ;;
    esac
}
prog_byte() { # label -> host-derived expected low byte = the body return value
    case "$1" in
      rizz_then)    echo 88 ;;
      rizz_else)    echo 11 ;;
      rizz_lit)     echo 46 ;;
      rizz_nolocal) echo 77 ;;
      rizz_cap31)   echo 30 ;;
    esac
}
is_branching() { case "$1" in rizz_then|rizz_else) return 0 ;; *) return 1 ;; esac; }
ALL_PROBES="rizz_then rizz_else rizz_lit rizz_nolocal rizz_cap31"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-rizzing\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
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
    # Bound the escape scan to head+spin+body+epilogue by the epilogue terminal (cli;hlt;jmp$-1 =
    # faf4ebfd). The tables after it are data.
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

# occurrence count of an (extended) regex in a hex string -- asserts a pin is EXACTLY-ONCE (a
# presence-grep is forgeable: a decoy/duplicate would pass).
occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # (0) THE EXACT 104-BYTE HEAD' (only gdtr/esp/idtr/tick le32 vary): talkert's head shape -- GDT-
    #     install (cli;lgdt;far-jmp 0x08:V0+15;reload DS/ES/FS/GS/SS;mov esp;lidt) + 10 PIC out-imm
    #     writes (remap + IRQ0-only IMR: 0x20<-11 0xA0<-11 0x21<-20 0xA1<-28 0x21<-04 0xA1<-02 0x21<-01
    #     0xA1<-01 0x21<-FE 0xA1<-FF) + 3 PIT writes (0x43<-34 0x40<-FF 0x40<-FF) -- EXCEPT the tail:
    #     `mov dword [tick],0` (c7 05 <le32 tick> 00 00 00 00 -- zero the SHARED tick word, not xor esi)
    #     then sti (fb). NO hlt-loop: the mainline falls through into the GLUE-SPIN. Pins EVERY
    #     behaviorally-invisible element (the slave PIC, the IMR, the PIT divisor, the tick-zero, sti) at
    #     offset 0. 104 bytes = 208 hex chars; gdtr/esp/idtr/tick le32 are the four variable slots.
    local pro="${chx:0:208}"
    local pre='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe640c705[0-9a-f]{8}00000000fb$'
    [[ "$pro" =~ $pre ]] || { fail_test "$label whitebox: head' != exact 104-byte GDT-install+PIC-remap+PIT-program+mov[tick],0+sti template"; ok=0; }
    # (1) THE GLUE-SPIN, AT EXACTLY OFFSET 104 (CONTIGUOUS WITH THE HEAD') AND EXACTLY ONCE: mov eax,
    #     [tick] (a1 + le32) + cmp eax,3 (83 f8 03) + jb -10 (72 f6, the back-edge to the spin top = the
    #     mov eax,[tick]) + cli (fa). UNLIKE talkert -- whose head is a hlt;jmp$-1 loop so the byte can
    #     ONLY appear via the IDT-gated handler -- the rizz head' FALLS THROUGH into the spin, so the emit
    #     path IS the mainline fall-through. The spin MUST therefore be pinned POSITIONALLY at byte 104
    #     (hex offset 208), immediately after the head', with nothing injectable between them: a free
    #     occ()-anywhere pin would pass a forge that puts `cli` + a SYNCHRONOUS emit right after the head'
    #     and leaves an exact-but-DEAD spin later (the dead-code-spin / pre-spin-injection forge -- a
    #     cross-model Codex review built it). The contiguous pin makes the body-start derivation positional
    #     too, so the I/O-scan below covers every byte from the head' onward. Pins the volatile [tick]
    #     read, the N=3 count (the `03` -- white-box-pinned like talkert's PIT divisor, since the exact
    #     count is not silicon-witnessable), the back-edge REACHABILITY (jb -10 loops to the mov, so the
    #     spin genuinely re-reads the shared cell each iteration), and the cli. Also EXACTLY ONCE.
    [[ "${chx:208:22}" =~ ^a1[0-9a-f]{8}83f80372f6fa$ ]] || { fail_test "$label whitebox: glue-spin (mov eax,[tick]; cmp eax,3; jb -10; cli) not at byte offset 104 immediately after the head' -- a pre-spin synchronous-emit forge could precede a dead decoy spin"; ok=0; }
    [[ "$(occ "$chx" 'a1[0-9a-f]{8}83f80372f6fa')" == 1 ]] || { fail_test "$label whitebox: glue-spin (mov eax,[tick]; cmp eax,3; jb -10; cli) not present exactly once"; ok=0; }
    # (2) THE GLUE-ISR, EXACTLY ONCE: push eax (50) + inc dword [tick] (ff 05 + le32) + EOI (b0 20 e6 20)
    #     + pop eax (58) + iret (cf). Pins the eax-preservation (push/pop around the shared-word inc, so
    #     an IRQ between the spin's load and compare cannot corrupt the test), the per-tick inc, the EOI
    #     (why the PIC re-delivers IRQ0), and the iret-resume -- all exactly once.
    [[ "$(occ "$chx" '50ff05[0-9a-f]{8}b020e62058cf')" == 1 ]] || { fail_test "$label whitebox: glue-ISR (push eax; inc [tick]; EOI; pop eax; iret) not present exactly once"; ok=0; }
    # (3) TICK-CELL PROVENANCE (the loader/CPU-redirect meta-class -- bind by VALUE, not a syntactic
    #     proxy). Extract the le32 from the head's `c705<le32>00000000`, the spin's `a1<le32>`, and the
    #     ISR's `ff05<le32>`. ALL THREE MUST BE EQUAL: the spin reads the SAME memory cell the ISR
    #     increments and the head zeroes. A forge that spins on a different cell than the ISR bumps (it
    #     would never advance), or zeroes a different cell than it spins on, FAILS here.
    local hpos spos ipos head_tick spin_tick isr_tick
    hpos=$(echo "$chx" | grep -bo 'c705[0-9a-f]\{8\}00000000' | head -1 | cut -d: -f1)
    spos=208   # the spin is positionally pinned at hex offset 208 (byte 104) by (1) above
    ipos=$(echo "$chx" | grep -bo '50ff05[0-9a-f]\{8\}b020e62058cf' | head -1 | cut -d: -f1)
    if [[ -z "$hpos" || -z "$spos" || -z "$ipos" ]]; then
        fail_test "$label whitebox: cannot locate one of head-tick / spin-tick / ISR-tick anchors for provenance bind"; ok=0
    else
        head_tick=$(le32_at "$chx" $((hpos + 4)))   # after c705
        spin_tick=$(le32_at "$chx" $((spos + 2)))   # after a1
        isr_tick=$(le32_at "$chx" $((ipos + 6)))    # after 50 ff 05
        if ! { [[ "$head_tick" == "$spin_tick" ]] && [[ "$spin_tick" == "$isr_tick" ]]; }; then
            fail_test "$label whitebox: tick-cell provenance mismatch (head=$head_tick spin=$spin_tick isr=$isr_tick) -- the mainline spins on a different word than the ISR bumps"; ok=0
        fi
    fi
    # (4) THE IDT vec-0x20 GATE -> the GLUE-ISR (bind by value). The glue ISR is AFTER the variable-length
    #     body, so its vaddr is not a fixed offset: locate the ISR (grep -bo) -> code offset -> vaddr =
    #     1048588 + offset. Then decode the vec-0x20 gate: the descriptor middle `0800008e` (sel 0x08,
    #     type 0x00, attr 0x8E -- present, ring0, 32-bit interrupt gate) occurs EXACTLY ONCE; the gate's
    #     offset-lo is the 16 bits immediately BEFORE it, offset-hi the 16 bits immediately AFTER, and the
    #     IDTR limit 0x0107 (le `0701`) follows. Reassemble (hi<<16)|lo and REQUIRE == ISR vaddr -- a
    #     decoy gate / wrong vector / wrong limit fails.
    local gmid; gmid="$(occ "$chx" '0800008e')"
    if [[ -z "$ipos" ]]; then
        : # provenance already failed; skip the value-bind (no ISR offset)
    elif [[ "$gmid" != 1 ]]; then
        fail_test "$label whitebox: IDT gate descriptor middle (sel 0x08 / attr 0x8E = 0800008e) not present exactly once"; ok=0
    else
        local isr_vaddr; isr_vaddr=$(( 1048588 + ipos / 2 ))
        local mpos; mpos=$(echo "$chx" | grep -bo '0800008e' | head -1 | cut -d: -f1)
        local lo16="${chx:mpos-4:4}" hi16="${chx:mpos+8:4}" after="${chx:mpos+12:4}"
        local lo_v=$(( 16#${lo16:2:2}${lo16:0:2} ))
        local hi_v=$(( 16#${hi16:2:2}${hi16:0:2} ))
        local gate_target=$(( (hi_v << 16) | lo_v ))
        [[ "$gate_target" -eq "$isr_vaddr" ]] || { fail_test "$label whitebox: IDT vec-0x20 gate target ($gate_target) != glue-ISR vaddr ($isr_vaddr) -- decoy gate / wrong vector"; ok=0; }
        [[ "$after" == "0701" ]] || { fail_test "$label whitebox: IDTR limit 0x0107 (le 0701) does not immediately follow the gate"; ok=0; }
        # (4b) LOADER/CPU-REDIRECT CLOSE -- bind the IDTR the head ACTUALLY loads to the checked gate.
        #   The head' `lidt [idtr]` operand is a wildcard le32 in pin (0); the CPU vectors IRQ0 via the
        #   LOADED idtr, not the gate the harness greps. A forge can `lidt` a DECOY idtr -> a trap-gate
        #   (0800008f, dodging the 0800008e grep) handler that stores 3 into [tick] in ONE IRQ (collapsing
        #   "survive 3 ticks"), while the real checked gate sits dead. So: decode the IDTR struct at the
        #   loaded vaddr and REQUIRE limit 0x0107 AND base+0x100 == the checked vec-0x20 gate vaddr (the
        #   gate starts 4 hex before '0800008e'). This binds lidt -> loaded-IDTR -> its IDT -> the checked
        #   gate -> the ISR. (Cross-model Codex built this forge; rizzing-specific because its emit is the
        #   mainline fall-through, unlike the prior async links whose emit is the IDT-gated handler.)
        local head_idtr; head_idtr=$(le32_at "$chx" 74)
        local idtr_off=$(( (head_idtr - 1048588) * 2 ))
        if [[ "$idtr_off" -lt 0 ]] || [[ $(( idtr_off + 12 )) -gt ${#chx} ]]; then
            fail_test "$label whitebox: head' loaded IDTR vaddr ($head_idtr) outside the image -- lidt-redirect forge"; ok=0
        else
            local idtr_limit_hex="${chx:idtr_off:4}"
            local idtr_base; idtr_base=$(le32_at "$chx" $(( idtr_off + 4 )))
            local gate_start_vaddr=$(( 1048588 + (mpos - 4) / 2 ))
            [[ "$idtr_limit_hex" == "0701" ]] || { fail_test "$label whitebox: loaded IDTR limit ($idtr_limit_hex) != 0701 (0x0107) -- lidt-redirect forge"; ok=0; }
            [[ $(( idtr_base + 256 )) -eq "$gate_start_vaddr" ]] || { fail_test "$label whitebox: loaded IDTR base ($idtr_base) +0x100 != the checked vec-0x20 gate vaddr ($gate_start_vaddr) -- CPU vectors IRQ0 through a DECOY IDT, not the checked gate (lidt-redirect forge)"; ok=0; }
        fi
    fi
    # (5) the flat GDT: code (9A CF) + data (92 CF) descriptor + GDTR.limit=0x17 -- each exactly once.
    [[ "$(occ "$chx" '9acf00')" == 1 ]] || { fail_test "$label whitebox: flat 32-bit code descriptor (9A CF) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '92cf001700')" == 1 ]] || { fail_test "$label whitebox: data descriptor + GDTR limit 0x17 not present exactly once"; ok=0; }
    # (6) THE BODY [spin-cli .. epilogue start] -- the compiled body lives between the GLUE-SPIN's cli
    #     (the `fa` at the end of the spin match) and the EPILOGUE start (88 c3 66 ba e9 00). Disassemble
    #     and check two ways:
    #   (6a) FREE of I/O + privileged instructions (no out/in/int/into/lgdt/lidt/mov cr/hlt/iret/sti/cli/
    #        wrmsr/...): closes the synchronous-emit AND software-`int 0x20` forge.
    #   (6a-ctl) EVERY control transfer is a DIRECT je/jne/jmp to a LITERAL target (no indirect/far jmp/
    #        call, no ret/loop/int): an indirect/far transfer can vector to a MID-INSTRUCTION hidden
    #        `cd 20` (int 0x20) buried in an immediate -- which (6b)'s literal-target scan cannot see.
    #   (6b) REACHABILITY: NO x86 ret, and every je/jne/jmp target is an instruction BOUNDARY that does
    #        not skip past the epilogue. This closes the "hide cd20 (int 0x20) in a mov immediate and jne
    #        into it MID-INSTRUCTION" synchronous-bounce forge.
    #   Disassemble [body_start .. epilogue+6] so the epilogue start is a decodable, valid branch target;
    #   the addresses are body-relative (0 = body start = the spin's cli + 1).
    local epos; epos=$(echo "$chx" | grep -bo '88c366bae900' | head -1 | cut -d: -f1)
    if [[ -z "$spos" ]]; then
        : # spin anchor already failed; cannot bound the body
    elif [[ -z "$epos" || "$(occ "$chx" '88c366bae900')" != 1 ]]; then
        fail_test "$label whitebox: epilogue start (mov bl,al; mov dx,0x00E9) not present exactly once"; ok=0
    else
        local body_start=$(( (spos + 22) / 2 ))     # spin match is 22 hex chars; cli is its last byte
        local epi_byte=$(( epos / 2 ))
        local epi_rel=$(( epi_byte - body_start ))
        dd if="$code" of="$code.rb" bs=1 skip="$body_start" count=$(( epi_rel + 6 )) status=none 2>/dev/null
        local rdis; rdis=$(objdump -D -b binary -m i386 -M intel "$code.rb" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
        [[ -n "$rdis" ]] || { fail_test "$label whitebox: empty body disassembly"; ok=0; }
        # (6a) no I/O / privileged instruction in the body
        if echo "$rdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -qiE '^(outs?b?|insb?|out|in|int|into|int3|lgdtd?|lidtd?|sgdtd?|sidtd?|lldt|ltr|lmsw|hlt|iretd?|sti|cli|wrmsr|rdmsr|invlpgd?|invd|wbinvd|sysenter|syscall)\b|cr[0-9]|dr[0-9]'; then
            fail_test "$label whitebox: body contains an I/O / privileged instruction (synchronous-emit or software-int forge)"; ok=0
        fi
        # (6a-ctl) EVERY control transfer must be a DIRECT je/jne/jmp to a LITERAL target.
        local ctl; ctl=$(echo "$rdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -iE '^(j[a-z]+|call[a-z]*|loop[a-z]*|ret[a-z]*|iret[a-z]*|int[0-9a-z]*|into|syscall|sysenter)\b')
        if [[ -n "$ctl" ]] && echo "$ctl" | grep -qvE '^(je|jne|jmp) +0x[0-9a-f]+'; then
            fail_test "$label whitebox: body has a non-direct/forbidden control transfer (indirect jmp/call/far/int/ret) -- the indirect-branch-to-hidden-int forge"; ok=0
        fi
        # (6b) no x86 ret; every branch target is an instruction boundary <= the epilogue offset
        echo "$rdis" | grep -qiE '\bret\b' && { fail_test "$label whitebox: x86 ret in body (the body must fall straight into the epilogue)"; ok=0; }
        local raddrs t tn; raddrs=$(echo "$rdis" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
        for t in $(echo "$rdis" | grep -oE '\b(je|jne|jmp) +0x[0-9a-f]+' | grep -oE '[0-9a-f]+$' | sort -u); do
            echo "$raddrs" | grep -qiE "^0*${t}$" || { fail_test "$label whitebox: branch target 0x${t} not an instruction boundary (mid-instruction jump forge)"; ok=0; }
            tn=$(( 16#${t} ))
            [[ "$tn" -le "$epi_rel" ]] || { fail_test "$label whitebox: branch target 0x${t} skips past the epilogue (offset $epi_rel) -- a bypass"; ok=0; }
        done
    fi
    # (7) THE SINGLE EMIT PATH: mov dx,0x00E9 (66 ba e9 00) EXACTLY ONCE -- one frame-emit, on the
    #     mainline's post-spin epilogue (combined with (1)'s spin and (4)'s gate, the byte can only appear
    #     after surviving N=3 shared-cell ticks).
    [[ "$(occ "$chx" '66bae900')" == 1 ]] || { fail_test "$label whitebox: the 0xE9 frame-emit (mov dx,0x00E9) not present exactly once"; ok=0; }
    # (8) branching probes must contain a real je (0F 84) -- a genuine data-dependent branch (its
    #     target-on-boundary is enforced by (6b)).
    if is_branching "$label"; then
        echo "$chx" | grep -q '0f84' || { fail_test "$label whitebox: branching probe has no je (0F 84)"; ok=0; }
    fi
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
    printf -- "-- emit: multiboot32-rizzing\n%b\n" "$prog" > "$cdir/probe.herb"
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
    echo "SKIP: native-codegen link27 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
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
    echo "$fail native-codegen-link27 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link27 / rizzing / eleventh kernel-arc link: a freestanding 32-bit Multiboot MAINLINE task SYNCHRONIZES with the async timer IRQ through a SHARED MEMORY word -- the pure-glue IRQ0 ISR (push eax; inc [tick]; EOI; pop eax; iret) bumps the cell, the mainline SPINS on [tick] surviving N=3 ticks, then cli + the compiled body emit on bare metal; $pass checks: static+white-box (exact 104-byte head' = GDT-install + PIC-remap + PIT-program + mov[tick],0 + sti, glue-spin (a1<le32>83f80372f6fa) exactly-once [volatile [tick] read + cmp N=3 + jb-10 back-edge reachability + cli], glue-ISR (50ff05<le32>b020e62058cf) exactly-once [eax-preserving push/pop + inc + EOI + iret], TICK-CELL PROVENANCE [head/spin/ISR le32 all equal -- spin reads the SAME word the ISR bumps], IDT vec-0x20 gate -> glue-ISR vaddr by VALUE + IDTR limit 0x107, flat GDT, body free of I/O+privileged + direct-control-only [closes the synchronous-emit + software-int forges], single 0xE9 emit path, real je on boundary), QEMU substrate (5 probes: then + else + literal + no-locals + 31-local cap, result-dependent exit after surviving N shared-cell ticks), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 14 out-of-subset rejects with twins incl. the 32-local cap (ERR 495); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
