#!/usr/bin/env bash
# Native codegen Link 24 (talkert, the EIGHTH kernel-arc link): the freestanding image SURVIVES and
# REPEATS the asynchronous timer interrupt -- the async-SURVIVAL half talcott (link23, exit-on-first-
# IRQ) deferred. Same boot/PIC/PIT/IDT shape as talcott, but on each PIT timer IRQ0 the handler now
# ACKNOWLEDGES the PIC (non-specific EOI `out 0x20,0x20`) and `iret`-RESUMES the interrupted mainline,
# counting ticks in esi (a register that survives across the interrupts) until the Nth tick (N=3 -> 2
# genuine EOI+iret resume cycles), when it runs the compiled body + the shared epilogue and emits. The
# proof byte = the body's return value (anti-ceremony: tracks the body) AND can only appear after
# surviving N ticks via the async path (the mainline head never emits). Graded, like lingo/toakie/
# zonday/chosen/liberi/scottie/talcott, on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs vs a
# HOST-derived golden), not C. Pays D19's async-SURVIVAL half (EOI + iret-resume + periodicity).
#
# Selected by the anchored first-line directive "-- emit: multiboot32-tick" (an EIGHTH emit mode; the
# plain "-- emit: multiboot32", "-idt", "-page", "-store", "-demand", "-timer", and default ELF64 modes
# are byte-identical, so the native self-host fixpoint gen2==gen1 is preserved).
#
# Image execution (vaddr V0=0x10000c): a fixed 99-byte HEAD -- talcott's 97-byte head (GDT-install;
#   10 PIC `out imm8,al` writes [remap + IRQ0-only IMR]; 3 PIT writes [mode 2, divisor 0xFFFF]) plus
#   `xor esi,esi` (zero the tick counter) before `sti`, then `hlt; jmp $-1` (the mainline NEVER emits).
#   On IRQ0 the CPU vectors via the IDT vec-0x20 gate to V0+99 = the HANDLER:
#     inc esi; cmp esi,3; jb .ack       -- count the tick; if < 3, acknowledge + resume
#     <ebp-frame(0|5) + compiled toakie body + the shared 58-byte epilogue>   -- the esi==3 path: emit
#       (frame 0xDE<byte>0xAD on 0xE9, result-dependent isa-debug-exit on 0xF4, "Shutdown" on 0x8900,
#       cli;hlt) and exit
#     .ack: mov al,0x20; out 0x20,al; iret   -- EOI to the master PIC + async resume (an IRQ frame has
#       NO error code, so NO `add esp,4`, unlike scottie's #PF). Then GDT/GDTR + 33-entry IDT (vec-0x20
#       -> the handler, all else not-present) + IDTR (300-byte tables, reused verbatim from talcott).
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; multiboot magic in first 8 KiB & 4-aligned; ZERO
#     syscall escapes (0F05 / CD80 / 0F34) in the head+handler+epilogue window (bounded by the epilogue
#     terminal faf4ebfd) AND an objdump scan finds no syscall/sysenter/int there.
#   WHITE-BOX (per probe; the runtime byte alone is forgeable -- a synchronous `out`, a software `int
#   0x20`, a single-tick exit, or a fall-through would also produce a byte -- so prove the structure):
#     - THE EXACT 99-BYTE HEAD (only gdtr/esp/idtr le32 vary): GDT-install + EXACT PIC-remap + EXACT
#       PIT-program + `xor esi,esi` + sti + the hlt-loop. Pins EVERY behaviorally-invisible element at
#       once (PIC slave + IMR, PIT divisor, the esi-zero, sti, the hlt-loop).
#     - THE HANDLER PROLOGUE: inc esi (46) + cmp esi,3 (83 FE 03) + jb .ack (0F 82 rel32), EXACTLY ONCE.
#       The N=3 count is pinned here (the exact count is not silicon-witnessable -- white-box, like the
#       PIT divisor).
#     - THE .ack TAIL: mov al,0x20; out 0x20,al; iret (b0 20 e6 20 cf), EXACTLY ONCE -- the EOI +
#       async iret-resume, with the iret immediately after the EOI (closing the wrong-`add esp,4` forge:
#       an IRQ frame has no error code).
#     - THE jb TARGET == .ack: the count-branch jb's rel32 must point EXACTLY at the .ack tail, so the
#       EOI+iret is REACHABLE on the esi<N path -- NOT left as dead code. (Pinning .ack's presence alone
#       is insufficient: a `jb -> body` forge emits the golden byte on tick 1 and never acknowledges/
#       resumes, yet keeps the .ack bytes as an unreachable decoy. Found independently by a same-model
#       completeness critic AND a cross-model Codex review; both built the `jb +0` forge.)
#     - THE IDT vec-0x20 GATE points EXACTLY at the handler (V0+99 = 0x10006f, sel 0x08, attr 0x8E),
#       immediately followed by IDTR.limit=0x0107 -- a decoy gate / wrong vector / wrong limit fails.
#     - the flat GDT code (9A CF) + data (92 CF) + GDTR.limit=0x17.
#     - THE BODY (handler, [V0+109 .. epilogue]) IS FREE of I/O and privileged instructions and uses
#       only DIRECT je/jne/jmp to in-body boundaries (no out/in/int/iret/sti/cli/mov cr, no indirect/
#       far/call/ret) -- closes the synchronous-emit AND software-`int 0x20` (direct + indirect) forges.
#     - THE SINGLE EMIT PATH: mov dx,0x00E9 (66 BA E9 00) occurs EXACTLY ONCE (in the epilogue) -- so
#       there is one frame-emit and it is on the async handler's path.
#     - NO x86 `ret` (C3) in the body; branching probes: a real `je` on an instruction boundary.
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit == host golden, e9 == 0xDE<byte>0xAD, ONE frame (after
#       surviving N=3 ticks).
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence.
#   PROBE VECTORS: then-arm + else-arm + literal + no-locals + 31-local cap. Each proves the body ran
#     AND the byte came via the async IRQ (byte = body return value) after surviving the tick count.
#   REJECTS (+ twins): out-of-subset bodies (div/mod, bitwise, 2-function, non-EQ comparator,
#     parameterised main, non-EQ bool cond) emit NO valid image; the 32-local cap (ERR 489) too.
#
# Honest scope: proves "SURVIVES and REPEATS the asynchronous timer IRQ (EOI + iret-resume + count) and
# runs a compiled handler as a freestanding 32-bit Multiboot image under QEMU + Bochs+GRUB," NOT real
# silicon, arbitrary emulator versions, long mode, or MMIO. Still 32-bit PM, port output only (D18 port
# input deferred). The PIT divisor, the EXACT count N=3, and the masked/not-present table entries are
# NOT silicon-witnessable (firmware also ticks; N=1 emits the same byte on tick 1; masked lines/not-
# present gates are not exercised on the happy path) -- they are pinned WHITE-BOX by the exact-head +
# prologue + exact-tables gates. What IS silicon-proven (mutation harness): the EOI and the iret-resume
# ARE load-bearing -- drop either and no frame appears (the kernel cannot survive past tick 1), so the
# image genuinely survives+repeats >=1 acknowledged interrupt. The dual-substrate + host golden
# replaces the absent C differential.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L8_BOCHS_PROBES:-tick_then tick_else}"

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

gen_locals() { # n prefix
    local n="$1" pfx="$2" s='func main():' i
    for i in $(seq 0 $((n - 1))); do s="$s let $pfx$i = $i"; done
    echo "$s return $pfx$((n - 1)) end"
}

prog_src() { # label
    case "$1" in
      tick_then)    echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      tick_else)    echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      tick_lit)     echo 'func main(): return 46 end' ;;
      tick_nolocal) echo 'func main(): return 77 end' ;;
      tick_cap31)   gen_locals 31 a ;;
    esac
}
prog_byte() { # label -> host-derived expected low byte = the body return value
    case "$1" in
      tick_then)    echo 88 ;;
      tick_else)    echo 11 ;;
      tick_lit)     echo 46 ;;
      tick_nolocal) echo 77 ;;
      tick_cap31)   echo 30 ;;
    esac
}
is_branching() { case "$1" in tick_then|tick_else) return 0 ;; *) return 1 ;; esac; }
ALL_PROBES="tick_then tick_else tick_lit tick_nolocal tick_cap31"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-tick\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
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
    # Bound the escape scan to head+handler+epilogue by the epilogue terminal (cli;hlt;jmp$-1 =
    # faf4ebfd -- distinct from the head's sti;hlt;jmp = fbf4ebfd). The tables after it are data.
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
    # (0) THE EXACT 99-BYTE HEAD (only gdtr/esp/idtr le32 vary): byte-identical to talcott's 97-byte
    #     head -- GDT-install (cli;lgdt;far-jmp 0x08:V0+15;reload DS/ES/FS/GS/SS;mov esp;lidt) + 10 PIC
    #     out-imm writes (remap + IRQ0-only IMR: 0x20<-11 0xA0<-11 0x21<-20 0xA1<-28 0x21<-04 0xA1<-02
    #     0x21<-01 0xA1<-01 0x21<-FE 0xA1<-FF) + 3 PIT writes (0x43<-34 0x40<-FF 0x40<-FF) -- EXCEPT it
    #     inserts `xor esi,esi` (31 F6) before sti: zero the tick counter that lives in esi and SURVIVES
    #     across the async interrupts. Then sti(FB) + hlt-loop(F4 EB FD). Pins EVERY behaviorally-
    #     invisible element (the slave PIC, the IMR, the PIT divisor, the esi-zero, sti, the hlt-loop).
    local pro="${chx:0:198}"
    local pre='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}b011e620b011e6a0b020e621b028e6a1b004e621b002e6a1b001e621b001e6a1b0fee621b0ffe6a1b034e643b0ffe640b0ffe64031f6fbf4ebfd$'
    [[ "$pro" =~ $pre ]] || { fail_test "$label whitebox: head != exact 99-byte GDT-install+PIC-remap+PIT-program+xor-esi+sti+hlt-loop template"; ok=0; }
    # (0b) THE HANDLER PROLOGUE immediately after the head: inc esi (46) + cmp esi,N=3 (83 FE 03) +
    #     jb .ack (0F 82 rel32) -- the periodicity counter. EXACTLY ONCE; the rel32 (skip-the-body-to-
    #     .ack) varies with the body length. The N=3 (the `03`) is pinned here because the exact count is
    #     NOT silicon-witnessable (N=1 would emit the same byte on the first tick -- see the mutation
    #     proof), so it is white-box-pinned, the honest analogue of talcott's PIT-divisor pin.
    [[ "$(occ "$chx" '4683fe030f82[0-9a-f]{8}')" == 1 ]] || { fail_test "$label whitebox: handler prologue (inc esi; cmp esi,3; jb .ack) not present exactly once"; ok=0; }
    # (1) THE IDT vec-0x20 GATE -> the handler at V0+99=0x10006f (offset-lo 006f / sel 0x08 / attr 0x8E
    #     / offset-hi 0010), immediately followed by IDTR.limit=0x0107. The gate target is FIXED (the
    #     handler is always right after the 99-byte head), so a decoy gate / wrong vector / wrong limit
    #     fails. EXACTLY ONCE.
    [[ "$(occ "$chx" '6f000800008e10000701')" == 1 ]] || { fail_test "$label whitebox: IDT vec-0x20 gate -> handler (V0+99, sel 0x08/attr 0x8E) immediately before IDTR limit 0x0107 not present exactly once"; ok=0; }
    # (2) the flat GDT: code (9A CF) + data (92 CF) descriptor + GDTR.limit=0x17 -- each exactly once.
    [[ "$(occ "$chx" '9acf00')" == 1 ]] || { fail_test "$label whitebox: flat 32-bit code descriptor (9A CF) not present exactly once"; ok=0; }
    [[ "$(occ "$chx" '92cf001700')" == 1 ]] || { fail_test "$label whitebox: data descriptor + GDTR limit 0x17 not present exactly once"; ok=0; }
    # (3) THE HANDLER BODY [V0+109 .. epilogue start] (after the 99-byte head + 10-byte prologue) --
    #     disassembled and checked two ways:
    #   (3a) FREE of I/O + privileged instructions (no out/in/int/into/lgdt/lidt/mov cr/hlt/iret/sti/
    #        cli/wrmsr/...): closes the synchronous-emit AND software-`int 0x20` forge.
    #   (3b) REACHABILITY: NO x86 ret, and every je/jne/jmp target is an instruction BOUNDARY that does
    #        not skip past the epilogue. This closes the "hide cd20 (int 0x20) in a mov immediate and
    #        jne into it MID-INSTRUCTION" synchronous-bounce forge -- a mid-instruction target is not
    #        among the linearly-decoded boundaries (the cross-model + completeness-critic catch; this is
    #        link22's branch-target-boundary check, which link24 must keep, not drop).
    #   Disassemble [109 .. epilogue+6] so the epilogue start is a decodable, valid branch target; the
    #   addresses are body-relative (0 = code offset 109 = the body start, just past the gate-target
    #   handler entry + the inc/cmp/jb prologue).
    local epos; epos=$(echo "$chx" | grep -bo '88c366bae900' | head -1 | cut -d: -f1)
    if [[ -z "$epos" || "$(occ "$chx" '88c366bae900')" != 1 ]]; then
        fail_test "$label whitebox: epilogue start (mov bl,al; mov dx,0x00E9) not present exactly once"; ok=0
    else
        local epi_rel=$(( epos / 2 - 109 ))
        dd if="$code" of="$code.rb" bs=1 skip=109 count=$(( epi_rel + 6 )) status=none 2>/dev/null
        local rdis; rdis=$(objdump -D -b binary -m i386 -M intel "$code.rb" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
        [[ -n "$rdis" ]] || { fail_test "$label whitebox: empty handler-body disassembly"; ok=0; }
        # (3a) no I/O / privileged instruction in the body
        if echo "$rdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -qiE '^(outs?b?|insb?|out|in|int|into|int3|lgdtd?|lidtd?|sgdtd?|sidtd?|lldt|ltr|lmsw|hlt|iretd?|sti|cli|wrmsr|rdmsr|invlpgd?|invd|wbinvd|sysenter|syscall)\b|cr[0-9]|dr[0-9]'; then
            fail_test "$label whitebox: handler body contains an I/O / privileged instruction (synchronous-emit or software-int forge)"; ok=0
        fi
        # (3a-ctl) EVERY control transfer in the body must be a DIRECT je/jne/jmp to a LITERAL target
        #   (which (3b) then boundary-checks). Reject calls and INDIRECT / far jmp/call (jmp eax,
        #   jmp [mem], ljmp, call ...) and ret/loop/int: an indirect or far transfer can vector to a
        #   MID-INSTRUCTION hidden `cd 20` (int 0x20) buried in an immediate -- which (3b)'s literal-
        #   target scan cannot see (the completeness-critic's second forge: jmp eax -> cd 20). The
        #   toakie lowering uses ONLY direct je/jmp, so this never rejects a legitimate body.
        local ctl; ctl=$(echo "$rdis" | sed -E 's/^[^\t]*\t[^\t]*\t//' | grep -iE '^(j[a-z]+|call[a-z]*|loop[a-z]*|ret[a-z]*|iret[a-z]*|int[0-9a-z]*|into|syscall|sysenter)\b')
        if [[ -n "$ctl" ]] && echo "$ctl" | grep -qvE '^(je|jne|jmp) +0x[0-9a-f]+'; then
            fail_test "$label whitebox: handler body has a non-direct/forbidden control transfer (indirect jmp/call/far/int/ret) -- the indirect-branch-to-hidden-int forge"; ok=0
        fi
        # (3b) no x86 ret; every branch target is an instruction boundary <= the epilogue offset
        echo "$rdis" | grep -qiE '\bret\b' && { fail_test "$label whitebox: x86 ret in handler body (the body must fall straight into the epilogue)"; ok=0; }
        local raddrs t tn; raddrs=$(echo "$rdis" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
        for t in $(echo "$rdis" | grep -oE '\b(je|jne|jmp) +0x[0-9a-f]+' | grep -oE '[0-9a-f]+$' | sort -u); do
            echo "$raddrs" | grep -qiE "^0*${t}$" || { fail_test "$label whitebox: branch target 0x${t} not an instruction boundary (mid-instruction jump forge)"; ok=0; }
            tn=$(( 16#${t} ))
            [[ "$tn" -le "$epi_rel" ]] || { fail_test "$label whitebox: branch target 0x${t} skips past the epilogue (offset $epi_rel) -- a bypass"; ok=0; }
        done
    fi
    # (4) THE SINGLE EMIT PATH: mov dx,0x00E9 (66 ba e9 00) EXACTLY ONCE -- one frame-emit, on the
    #     async handler's epilogue (combined with (0)'s hlt-loop and (1)'s gate, the byte can only
    #     appear via the asynchronous IRQ0).
    [[ "$(occ "$chx" '66bae900')" == 1 ]] || { fail_test "$label whitebox: the 0xE9 frame-emit (mov dx,0x00E9) not present exactly once"; ok=0; }
    # (5) branching probes must contain a real je (0F 84) -- a genuine data-dependent branch (its
    #     target-on-boundary is enforced by (3b)).
    if is_branching "$label"; then
        echo "$chx" | grep -q '0f84' || { fail_test "$label whitebox: branching probe has no je (0F 84)"; ok=0; }
    fi
    # (6) THE .ack TAIL -- the NEW load-bearing async-SURVIVAL sequence: EOI to the master PIC then iret,
    #     as the EXACT bytes b0 20 e6 20 cf (mov al,0x20; out 0x20,al; iret) -- EXACTLY ONCE. The EOI is
    #     why the PIC re-delivers IRQ0 (silicon-proven in the mutation harness: drop it -> no 2nd tick ->
    #     no frame); the iret resumes the interrupted mainline (silicon-proven: replace with cli;hlt ->
    #     1 tick -> no frame). Pinning the iret (cf) IMMEDIATELY after the out (e6 20) also closes the
    #     wrong-`add esp,4` forge: an IRQ interrupt-gate frame has NO error code (unlike scottie's #PF),
    #     so there is no 83 c4 04 between the EOI and the iret (an inserted one breaks this pin AND
    #     triple-faults on silicon -- both proven in the mutation harness).
    [[ "$(occ "$chx" 'b020e620cf')" == 1 ]] || { fail_test "$label whitebox: the .ack EOI+iret tail (mov al,0x20; out 0x20,al; iret) not present exactly once -- EOI / iret-resume / no-error-code missing or forged"; ok=0; }
    # (7) THE jb TARGET == .ack -- the REACHABILITY bind. Pinning .ack's PRESENCE (6) is NOT enough: a
    #     forge that retargets the count-branch `jb` rel32 to the BODY start emits the byte on the FIRST
    #     tick and leaves the EOI+iret as unreachable DEAD CODE -- it passes (6) and boots to the golden
    #     byte yet NEVER acknowledges/resumes (the completeness-critic + cross-model Codex both built this
    #     `jb +0` forge independently). Decode the prologue jb's rel32 (at code offset 105 = head 99 +
    #     inc 1 + cmp 3 + jb-opcode 2) and assert its target is EXACTLY the .ack offset -- binding the
    #     EOI+iret onto the esi<N path, so the byte cannot appear without genuinely surviving+repeating.
    local rel_hex="${chx:210:8}"
    if [[ "${#rel_hex}" -ne 8 ]]; then
        fail_test "$label whitebox: cannot decode prologue jb rel32 (head/prologue misaligned)"; ok=0
    else
        local jb_rel=$(( 16#${rel_hex:6:2}${rel_hex:4:2}${rel_hex:2:2}${rel_hex:0:2} ))
        local jb_target=$(( 109 + jb_rel ))
        local ack_pos; ack_pos=$(echo "$chx" | grep -bo 'b020e620cf' | head -1 | cut -d: -f1)
        local ack_off=$(( ack_pos / 2 ))
        [[ "$jb_target" -eq "$ack_off" ]] || { fail_test "$label whitebox: prologue jb target ($jb_target) != .ack EOI+iret offset ($ack_off) -- the EOI+iret is unreachable DEAD CODE (count-branch retargeted to the body -> emits on tick 1, never survives/repeats)"; ok=0; }
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
    printf -- "-- emit: multiboot32-tick\n%b\n" "$prog" > "$cdir/probe.herb"
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
    echo "SKIP: native-codegen link24 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
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
    echo "$fail native-codegen-link24 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link24 / talkert / eighth kernel-arc link: freestanding 32-bit Multiboot image SURVIVES and REPEATS the asynchronous timer IRQ -- each IRQ0 the handler EOIs the PIC + iret-resumes the mainline, counting in esi until the Nth (3rd) tick when the compiled body emits on bare metal; $pass checks: static+white-box (exact 99-byte head = GDT-install + PIC-remap + PIT-program + xor-esi + sti + hlt-loop, handler prologue inc-esi/cmp-3/jb exactly-once, .ack EOI+iret tail (b020e620cf) exactly-once [EOI + iret-resume + no-error-code-drop], jb-target == .ack [the EOI+iret is REACHABLE on the esi<N path, not dead-code], IDT vec-0x20 gate -> handler V0+99 + IDTR limit 0x107, flat GDT, body free of I/O+privileged + direct-control-only [closes the synchronous-emit + software-int forges], single 0xE9 emit path, real je on boundary), QEMU substrate (5 probes: then + else + literal + no-locals + 31-local cap, result-dependent exit after N ticks), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 14 out-of-subset rejects with twins incl. the 32-local cap (ERR 489); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
