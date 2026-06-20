#!/usr/bin/env bash
# Native codegen Link 20 ("chosen", the FOURTH kernel-arc link): the freestanding image
# now turns on PAGING and proves a mapping by catching the CPU's own PAGE-FAULT (#PF,
# vector 14) on the unmapped neighbor. It builds an emitter-laid-out page directory +
# page table, identity-maps the low 4 MiB EXCEPT one hole, loads CR3, sets CR0.PG, reads
# a MAPPED page (must not fault), then touches the UNMAPPED neighbor -> genuine #PF -> the
# CPU vectors to a handler the image installed (the REAL compiled Herbert main() body,
# toakie subset) which emits a byte proving it ran via the fault path. Graded, like
# lingo/toakie/zonday, on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs vs a HOST-derived
# golden), not C -- there is no C analogue for catching a bare-metal CPU page-fault.
#
# Selected by the anchored first-line directive "-- emit: multiboot32-page" (a FOURTH emit
# mode; the plain "-- emit: multiboot32", "-- emit: multiboot32-idt", and default ELF64
# modes are byte-identical, so the native self-host fixpoint gen2==gen1 is preserved).
#
# Image execution (vaddr V0=0x10000c): a fixed 118-byte STRUCTURAL head (prologue 92 +
# #PF wrapper 26) --
#   cli; lgdt <own GDT>; far-jmp CS=0x08; reload DS/ES/FS/GS/SS=0x10 (stale bootloader
#   selectors index into the NEW GDT; QEMU vs GRUB differ -> they MUST be refreshed);
#   mov esp; lidt; mov eax,cr4; AND eax,0xFFFFFF4F (clear PAE/PSE/PGE -- Multiboot leaves
#   CR4 UNDEFINED, so a PAE-set substrate would reinterpret the PD as a PDPT; SDM-mandated
#   robustness); mov eax,PD; mov cr3,eax; mov eax,cr0; OR eax,0x80000000; mov cr0,eax
#   (PAGING ON); jmp $+2 (prefetch flush); TOUCH-A [0x2ff000] (mapped, must NOT fault);
#   TOUCH-B [0x300000] (the UNMAPPED neighbor, MUST #PF; faulting EIP == 0x10005b);
#   SENTINEL (mov al,0xBB; jmp epilogue -- reached only if the fault never fires);
#   WRAPPER (the IDT vector-14 gate target): mov eax,cr2; cmp eax,0x300000; jne sentinel;
#   cmp dword [esp],0 (#PF error code: not-present supervisor read == 0); jne sentinel;
#   cmp dword [esp+4],0x10005b (saved EIP == TOUCH-B -- proves WHICH access faulted); jne
#   sentinel -- then falls into:
# the HANDLER (real compiled main() body, no `mov esp`, runs below the #PF frame, does NOT
#   iret) -> the shared 58-byte epilogue (debugcon frame 0xDE<byte>0xAD + result-dependent
#   isa-debug-exit + Bochs power-off + cli;hlt;spin); then the emitter-laid-out
#   GDT/GDTR/IDT(15-entry)/IDTR data tables; then a 4 KiB-aligned page directory + page table.
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; multiboot magic in first 8 KiB &
#     4-aligned; ZERO syscall escapes (no 0F 05 / CD 80 / 0F 34 bytes AND an
#     instruction-aware objdump scan finds no syscall/sysenter/int).
#   WHITE-BOX (per probe; a mis-wired descriptor/vector/page-table is invisible to a
#   black-box diff, AND the runtime byte ALONE is forgeable -- cr2 is ring-0-writable, so an
#   image can fake CR2 + push a fake #PF frame + jump the handler WITHOUT paging and pass the
#   byte-grade (empirically confirmed). So prove the structure statically):
#     - THE EXACT 118-BYTE STRUCTURAL HEAD, byte-for-byte (only the 5 address/displacement
#       le32 fields vary): pins the CR4 clear, the CR0.PG-enable, BOTH touch addresses, and
#       the whole wrapper -- so a forged image that fakes the fault frame is CAUGHT here.
#     - the absolute far-jmp (EA ptr16:32) to CS=0x08
#     - the IDT vector-14 (#PF) gate is exactly offset=0x100068 (the wrapper vaddr) /
#       selector 0x0008 / attr 0x8E (the 8 bytes 68 00 08 00 00 8e 10 00)
#     - the flat GDT code (9A CF) + data (92 CF) descriptors
#     - the page table has EXACTLY ONE hole at the neighbor: mapped 0x2ff003, hole
#       0x00000000, mapped 0x301003 (offset-independent grep) -- and PDE[0] -> PT|0x003
#     - NO x86 `ret` in the handler (Herbert returns fall/jmp into the epilogue)
#     - (branching probes) a real conditional jump `je` whose target lands on an
#       instruction boundary inside the bounded code
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit code == host golden, the e9 capture ==
#       0xDE<byte>0xAD with EXACTLY ONE frame
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence (a handler that
#       emits then triple-faults/hangs cannot pass)
#   PROBE VECTORS: then-arm + else-arm (distinct branch-derived bytes differing in the low
#     7 bits, so the masked isa-debug-exit code also bites) + a literal frame round-trip.
#     Each proves the handler ran COMPILED code via the page-fault.
#   REJECTS (+ renamed/revalued twins): an out-of-subset handler (div/mod, bitwise, a
#     2-function program, a non-EQ comparator, a parameterised main, a non-EQ bool condition)
#     emits NO valid image; the twin must reject too (structural, not fitted).
#
# Honest scope: proves "turns on paging and catches its own #PF on the unmapped neighbor as a
# freestanding 32-bit Multiboot image under QEMU's direct loader and Bochs+GRUB," NOT real
# silicon, arbitrary emulator versions, long mode, the PIC/real device IRQs, iret-resumption,
# or runtime page-table construction (all deferred -- D19's remainder). Tables are
# emitter-laid-out (no store-to-arbitrary-address -> typed-memory candidate (d) stays
# deferred). The dual-substrate + host golden is the far-axis replacement for the absent C
# differential. The CR4 clear is defensive: both tested emulator versions hand off CR4.PAE=0,
# so it is not OBSERVED-forced here, but it is SDM-mandated (CR4 is architecturally undefined
# after Multiboot) and doubles as a boot-invisible mutation for the exact-head gate.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L4_BOCHS_PROBES:-page_then page_else}"

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

# ---- host-derived golden exit code (computed here; never captured) ----------
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

# ---- the chosen forcing programs (handler = compiled main(); host-derived byte) --
# generate a straight-line N-local body: func main(): let <pfx>0=0 ... return <pfx>{N-1} end
gen_locals() { # n prefix
    local n="$1" pfx="$2" s='func main():' i
    for i in $(seq 0 $((n - 1))); do s="$s let $pfx$i = $i"; done
    echo "$s return $pfx$((n - 1)) end"
}
prog_src() { # label
    case "$1" in
      page_then)    echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      page_else)    echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      page_lit)     echo 'func main(): let x = 46  return x end' ;;
      page_nolocal) echo 'func main(): return 77 end' ;;           # nlocals==0: no ebp prologue
      page_cap31)   gen_locals 31 a ;;                              # nlocals==31: max (sub esp,0x7c) -> returns 30
    esac
}
prog_byte() { # label -> host-derived expected low byte (computed independently here)
    case "$1" in
      page_then)    echo 88 ;;   # x=42 (==42 true)  -> return 88
      page_else)    echo 11 ;;   # x=42 (==43 false) -> return 11
      page_lit)     echo 46 ;;   # let x=46 -> return x
      page_nolocal) echo 77 ;;   # return 77 (no locals -> no `sub esp` prologue path)
      page_cap31)   echo 30 ;;   # 31 locals a0..a30 -> return a30 (=30); pins the sub-esp disp8 cap from below
    esac
}
is_branching() { case "$1" in page_then|page_else) return 0 ;; *) return 1 ;; esac; }
# page_nolocal exercises the nlocals==0 (no ebp-prologue) path; page_cap31 exercises the
# max-locals boundary (4*31=124 fits a signed disp8; 4*32=128 would sign-extend negative --
# which is exactly why the emitter caps at 31, ERR 463, exercised by the maxlocals reject).
ALL_PROBES="page_then page_else page_lit page_nolocal page_cap31"

# ---- compile a freestanding -page probe with the NATIVE gen-1 compiler --------
compile_probe() { # label outfile -> 0 on a valid multiboot ELF
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-page\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then
        fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1
    fi
    cp "$cdir/a.out" "$out"; return 0
}

# ---- static escape gate -----------------------------------------------------
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
    # bound the escape scan to the code (head+handler+epilogue) by the epilogue terminal;
    # the data tables / PD / PT after it would mis-disassemble (and contain addr|3 bytes).
    local term="${chx%%faf4ebfd*}"
    if [[ "$term" == "$chx" ]]; then fail_test "$label static: epilogue terminal (cli;hlt;jmp) absent"; return 1; fi
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

# ---- white-box structural gate (the paging / #PF-catch wiring) --------------
whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # (0) THE EXACT 118-BYTE STRUCTURAL HEAD. Pins, byte-for-byte (only the 5 le32 address
    #     fields vary): cli; lgdt; far-jmp 0x08:V0+15; reload DS/ES/FS/GS/SS; mov esp; lidt;
    #     mov eax,cr4; AND eax,0xFFFFFF4F (clear PAE/PSE/PGE); mov eax,PD; mov cr3,eax;
    #     mov eax,cr0; OR eax,0x80000000; mov cr0,eax (PAGING ON); jmp $+2; TOUCH-A
    #     [0x2ff000]; TOUCH-B [0x300000]; sentinel mov al,0xBB; jmp epilogue; WRAPPER:
    #     mov eax,cr2; cmp eax,0x300000; jne sentinel; cmp [esp],0; jne sentinel;
    #     cmp [esp+4],0x10005b; jne sentinel. This proves the touches are reached by
    #     STRAIGHT-LINE flow AFTER paging is genuinely enabled -- a forged image that fakes
    #     CR2 + pushes a fake #PF frame + jumps the wrapper (a byte-present forgery the grep
    #     gates below would miss; cr2 is ring-0-writable) is CAUGHT here.
    local head="${chx:0:236}"
    local hre='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}0f20e0254fffffff0f22e0b8[0-9a-f]{8}0f22d80f20c00d000000800f22c0eb008b0500f02f008b0500003000b0bbe9[0-9a-f]{8}0f20d03d0000300075ef833c240075e9817c24045b00100075df$'
    [[ "$head" =~ $hre ]] || { fail_test "$label whitebox: structural head != exact paging/#PF template (straight-line flow through paging-enable to the unmapped touch unproven)"; ok=0; }
    # (a) own GDT + IDT installed + reloaded: lgdt (0F 01 /2) and lidt (0F 01 /3)
    echo "$chx" | grep -q '0f0115' || { fail_test "$label whitebox: no lgdt (0F 01 /2)"; ok=0; }
    echo "$chx" | grep -q '0f011d' || { fail_test "$label whitebox: no lidt (0F 01 /3)"; ok=0; }
    # (b) the far jump is the ABSOLUTE form (EA ptr16:32) to CS=0x08 (not a rel jmp)
    echo "$chx" | grep -q 'ea1b0010000800' || { fail_test "$label whitebox: no absolute far-jmp to 0x08:0x10001b"; ok=0; }
    # (c) genuine paging-enable: mov cr3,eax (0F 22 D8) AND mov cr0,eax (0F 22 C0) after OR 0x80000000
    echo "$chx" | grep -q '0f22d8' || { fail_test "$label whitebox: no mov cr3,eax (paging base not loaded)"; ok=0; }
    echo "$chx" | grep -q '0d000000800f22c0' || { fail_test "$label whitebox: no CR0.PG enable (or 0x80000000; mov cr0,eax)"; ok=0; }
    # (d) the IDT vector-14 (#PF) gate (offset=0x100068 wrapper / sel 0x0008 / attr 0x8E) is the
    #     LAST entry, immediately followed by IDTR.limit=0x0077 -- pins the gate AND the 15-entry
    #     IDT size together, so a decoy gate elsewhere cannot satisfy this adjacency (Codex caveat).
    echo "$chx" | grep -q '68000800008e10007700' || { fail_test "$label whitebox: IDT #PF gate (offset==wrapper/sel/attr) not immediately followed by IDTR limit 0x77"; ok=0; }
    # (e) the flat GDT: limit FF FF, code (9A CF), and data (92 CF) descriptor immediately followed
    #     by GDTR.limit=0x0017 -- pins the flat 4 GiB segments AND the GDTR together (re-adds the
    #     flat-segment-limit assertion the prior link asserted; do not weaken vs link19).
    echo "$chx" | grep -q 'ffff00' || { fail_test "$label whitebox: no flat segment limit (FF FF)"; ok=0; }
    echo "$chx" | grep -q '9acf00' || { fail_test "$label whitebox: no flat 32-bit code descriptor (9A CF)"; ok=0; }
    echo "$chx" | grep -q '92cf001700' || { fail_test "$label whitebox: data descriptor (92 CF) not immediately followed by GDTR limit 0x17"; ok=0; }
    # (h) the page table has EXACTLY ONE hole at the neighbor B, between mapped neighbors:
    #     ...PT[767]=0x2ff003, PT[768]=0 (B unmapped), PT[769]=0x301003... (offset-independent).
    #     A 'bmapped' mutation that fills the hole (PT[768]=0x300003) breaks this sequence.
    echo "$chx" | grep -q '03f02f000000000003103000' || { fail_test "$label whitebox: page table hole at neighbor B (0x300000) not present between mapped neighbors"; ok=0; }
    #     and PDE[0] -> PT (0x102003 = present+RW)
    echo "$chx" | grep -q '03201000' || { fail_test "$label whitebox: PDE[0] does not point to the page table (present+RW)"; ok=0; }
    # bound the disasm to the code (head+handler+epilogue) by the epilogue terminal
    local term="${chx%%faf4ebfd*}"
    if [[ "$term" == "$chx" ]]; then fail_test "$label whitebox: epilogue terminal absent"; return 1; fi
    local endbytes=$(( ${#term} / 2 + 4 ))
    dd if="$code" of="$code.t" bs=1 count="$endbytes" status=none 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386 -M intel "$code.t" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
    [[ -n "$dis" ]] || { fail_test "$label whitebox: empty disassembly"; return 1; }
    # (f) NO x86 `ret` in the handler -- Herbert returns fall/jmp into the epilogue
    if echo "$dis" | grep -qE '\bret\b'; then fail_test "$label whitebox: x86 ret present in handler (return must reach the shared epilogue)"; ok=0; fi
    # (g) branching probes: a real `je` whose target lands on an instruction boundary
    if is_branching "$label"; then
        echo "$dis" | grep -qE '\bje\b' || { fail_test "$label whitebox: no real conditional jump (je) in the handler"; ok=0; }
        local addrs t; addrs=$(echo "$dis" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
        for t in $(echo "$dis" | grep -oE '\b(je|jmp) +0x[0-9a-f]+' | grep -oE '[0-9a-f]+$' | sort -u); do
            echo "$addrs" | grep -qiE "^0*${t}$" || { fail_test "$label whitebox: branch target 0x${t} not an instruction boundary"; ok=0; }
        done
    fi
    [[ "$ok" -eq 1 ]]
}

# ---- QEMU substrate ---------------------------------------------------------
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

# ---- Bochs substrate (independent codebase, via GRUB on a partitioned HDD) ---
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
      printf 'set timeout=0\nset default=0\nmenuentry "p" {\n multiboot /boot/kernel.elf\n boot\n}\n' \
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

# ---- reject probe: an out-of-subset handler must NOT emit a valid image ------
reject_probe() { # label "<herbert program>"
    local label="$1" prog="$2"
    local cdir="$tmp/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "-- emit: multiboot32-page\n%b\n" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset handler emitted a valid multiboot image"; return 1
    fi
    return 0
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu-system-x86_64 not found)"; exit 1
    fi
    echo "SKIP: native-codegen link20 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
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
    if ! have_qemu; then pass=$((pass + 1)); continue; fi   # statics+whitebox only
    byte=$(prog_byte "$label")
    if qemu_run "$label" "$byte" "$elf"; then
        bochs_ok=1
        if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
            bochs_run "$label" "$byte" "$elf" || bochs_ok=0
        fi
        [[ "$bochs_ok" -eq 1 ]] && pass=$((pass + 1))
    fi
done

# rejects + renamed/revalued twins (rejection must be structural, not fitted). The
# -page handler uses the SAME subset as toakie/zonday, so the boundary is the same.
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
# the max-locals cap (ERR 463): 4*32=128 would emit `sub esp,0x80` -- a NEGATIVE signed disp8,
# so the frame would grow the wrong way -- which is exactly why the emitter caps at 31. The twin
# renames the locals (same count) so the rejection is proven structural (on the count, not names).
reject_probe maxlocals      "$(gen_locals 32 a)"
reject_probe maxlocals_twin "$(gen_locals 32 z)"
[[ "$fail" -eq 0 ]] && pass=$((pass + 14))

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then
    echo "$fail native-codegen-link20 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link20 / chosen: freestanding 32-bit Multiboot image turns on paging and catches the CPU's own #PF on the unmapped neighbor on bare metal; $pass checks: static+white-box (exact 118-byte paging head, absolute far-jmp, CR3/CR0.PG enable, IDT #PF gate offset==wrapper vaddr + IDTR limit, flat GDT descriptors + GDTR limit, single page-table hole at the neighbor between mapped pages, PDE->PT, no x86 ret, real je on boundary), QEMU substrate (5 probes: both branch arms + literal + no-locals + 31-local cap, result-dependent exit), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 14 out-of-subset rejects with twins incl. the 32-local cap (ERR 463); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
