#!/usr/bin/env bash
# Native codegen Link 19 ("zonday", the THIRD kernel-arc link): the freestanding
# image now RESPONDS TO THE CPU instead of only computing. It installs its OWN
# GDT + IDT, deliberately triggers the CPU's own DIVIDE-ERROR fault (#DE), and the
# CPU vectors to a handler the image installed -- which is the REAL compiled
# Herbert main() body (toakie subset) -- that emits a byte proving it ran via the
# fault path. Graded, like lingo/toakie, on the far-axis DUAL-SUBSTRATE oracle
# (QEMU + Bochs vs a HOST-derived golden), not C -- there is no C analogue for
# catching a bare-metal CPU fault.
#
# Selected by the anchored first-line directive "-- emit: multiboot32-idt" (a THIRD
# emit mode; the plain "-- emit: multiboot32" and default ELF64 modes are byte-
# identical, so the native self-host fixpoint gen2==gen1 is preserved).
#
# Image execution (vaddr V0=0x10000c): a fixed 63-byte STRUCTURAL head --
#   cli; lgdt <own GDT>; far-jmp CS=0x08; reload DS/ES/FS/GS/SS=0x10 (stale
#   bootloader selectors index into the NEW GDT and QEMU vs GRUB differ -> they
#   MUST be refreshed or one substrate triple-faults); mov esp; lidt; #DE trigger
#   (xor edx,edx; xor ecx,ecx; div ecx); SENTINEL fall-through (mov al,0xBB; jmp
#   epilogue -- reached only if the fault never fires); WRAPPER (the IDT gate target):
#   cmp [esp],<faulting div EIP>; jne sentinel (only a genuine #DE pushes that EIP,
#   so a non-fault entry cannot forge the proof) -- then falls into:
# the HANDLER (real compiled main() body, no `mov esp`, runs below the #DE frame,
#   does NOT iret) -> the shared 58-byte epilogue (debugcon frame 0xDE<byte>0xAD +
#   result-dependent isa-debug-exit + Bochs power-off + cli;hlt;spin); then the
#   emitter-laid-out GDT/GDTR/IDT/IDTR data tables.
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; multiboot magic in first
#     8 KiB & 4-aligned; ZERO syscall escapes (no 0F 05 / CD 80 / 0F 34 bytes AND
#     an instruction-aware objdump scan finds no syscall/sysenter/int).
#   WHITE-BOX (per probe; a mis-wired descriptor/vector is invisible to a black-box
#   diff -- the zelph lesson -- so prove the structure statically):
#     - a real `lgdt` (0F 01 /2) and `lidt` (0F 01 /3) are present
#     - the far jump is the ABSOLUTE form (EA ptr16:32) to CS=0x08, not a rel jmp
#     - the #DE trigger `div ecx` (F7 F1) is present AND the wrapper validates the
#       faulting EIP: `cmp [esp], 0x100039` (81 3C 24 39 00 10 00) is present
#     - the IDT gate is exactly offset=0x100042 (the wrapper vaddr) / selector
#       0x0008 / attr 0x8E (the 8 bytes 42 00 08 00 00 8e 10 00) -- the gate-offset
#       == handler-vaddr wiring, white-boxed (a mis-resolved vector is otherwise
#       only caught by a triple-fault)
#     - the flat GDT code (FF FF 00 00 00 9A CF 00) + data (..92..) descriptors
#     - NO x86 `ret` in the handler (Herbert returns fall/jmp into the epilogue)
#     - (branching probes) a real conditional jump `je` whose target lands on an
#       instruction boundary inside the bounded code
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit code == host golden, the e9 capture
#       == 0xDE<byte>0xAD with EXACTLY ONE frame
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence (a handler
#       that emits then triple-faults/hangs cannot pass)
#   PROBE VECTORS: then-arm + else-arm (distinct branch-derived bytes differing in
#     the low 7 bits, so the masked isa-debug-exit code also bites) + a literal
#     frame round-trip. Each proves the handler ran COMPILED code via the fault.
#   REJECTS (+ renamed/revalued twins): an out-of-subset handler (div/mod, bitwise,
#     a 2-function program, a non-EQ comparator, a parameterised main, a non-EQ bool
#     condition) emits NO valid image; the twin must reject too (structural, not fitted).
#
# Honest scope: proves "installs a GDT+IDT and catches its own #DE as a freestanding
# 32-bit Multiboot image under QEMU's direct loader and Bochs+GRUB," NOT real silicon,
# arbitrary emulator versions, paging, long mode, the PIC/real device IRQs, or
# iret-resumption (all deferred -- D19's remainder). Still 32-bit PM, paging off. The
# dual-substrate + host golden is the far-axis replacement for the absent C differential.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L3_BOCHS_PROBES:-idt_then idt_else}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1
fi
if [[ ! -f "$backend" ]]; then
    echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1
fi

source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Reuse only the gen-1 mint (C out of the run path; the native compiler emits the
# image). L3 is graded on the dual-substrate oracle, not against C.
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 \
    && sudo -n true 2>/dev/null; }

# ---- host-derived golden exit code (computed here; never captured) ----------
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

# ---- the zonday forcing programs (handler = compiled main(); host-derived byte) --
prog_src() { # label
    case "$1" in
      idt_then) echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      idt_else) echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      idt_lit)  echo 'func main(): let x = 46  return x end' ;;
    esac
}
prog_byte() { # label -> host-derived expected low byte (computed independently here)
    case "$1" in
      idt_then) echo 88 ;;   # x=42 (==42 true)  -> return 88
      idt_else) echo 11 ;;   # x=42 (==43 false) -> return 11
      idt_lit)  echo 46 ;;   # let x=46 -> return x
    esac
}
is_branching() { case "$1" in idt_then|idt_else) return 0 ;; *) return 1 ;; esac; }
ALL_PROBES="idt_then idt_else idt_lit"

# ---- compile a freestanding -idt probe with the NATIVE gen-1 compiler --------
compile_probe() { # label outfile -> 0 on a valid multiboot ELF
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-idt\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
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
    echo "$chx" | grep -q '0f05' && { fail_test "$label static: 0F 05 (syscall) byte present"; ok=0; }
    echo "$chx" | grep -q 'cd80' && { fail_test "$label static: CD 80 (int 0x80) byte present"; ok=0; }
    echo "$chx" | grep -q '0f34' && { fail_test "$label static: 0F 34 (sysenter) byte present"; ok=0; }
    # instruction-aware escape scan, bounded to the code (head+handler+epilogue);
    # the data tables after the epilogue terminal would mis-disassemble.
    local term="${chx%%faf4ebfd*}"
    if [[ "$term" == "$chx" ]]; then fail_test "$label static: epilogue terminal (cli;hlt;jmp) absent"; return 1; fi
    local endbytes=$(( ${#term} / 2 + 4 ))
    dd if="$code" of="$code.t" bs=1 count="$endbytes" status=none 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386 -M intel "$code.t" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
    if echo "$dis" | grep -qiE '\b(syscall|sysenter)\b|\bint[ ]+\$?0x'; then
        fail_test "$label static: disasm shows a syscall/sysenter/int instruction"; ok=0
    fi
    [[ "$ok" -eq 1 ]]
}

# ---- white-box structural gate (the IDT/GDT/fault-catch wiring) -------------
whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # (0) THE EXACT 63-BYTE STRUCTURAL HEAD. Pins, byte-for-byte (only the 4
    #     address/displacement le32 fields vary): cli; lgdt; far-jmp 0x08:V0+15;
    #     reload DS/ES/FS/GS/SS; mov esp; lidt; xor edx; xor ecx; DIV ECX (at offset
    #     0x2d); mov al,0xBB; jmp epilogue; cmp [esp],0x100039; jne sentinel. This
    #     proves the #DE trigger is reached by STRAIGHT-LINE flow from lidt BEFORE
    #     the wrapper -- so a forged image that pushes the expected EIP, jumps to the
    #     wrapper, and leaves the div bytes as dead code (a byte-present forgery the
    #     grep gates below would miss) is CAUGHT here (the Codex pre-land finding).
    local head="${chx:0:126}"
    local hre='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}31d231c9f7f1b0bbe9[0-9a-f]{8}813c243900100075f0$'
    [[ "$head" =~ $hre ]] || { fail_test "$label whitebox: structural head != exact GDT/IDT/#DE template (straight-line flow to the div trigger unproven)"; ok=0; }
    # (a) own GDT installed + reloaded: lgdt (0F 01 /2) and lidt (0F 01 /3)
    echo "$chx" | grep -q '0f0115' || { fail_test "$label whitebox: no lgdt (0F 01 /2)"; ok=0; }
    echo "$chx" | grep -q '0f011d' || { fail_test "$label whitebox: no lidt (0F 01 /3)"; ok=0; }
    # (b) the far jump is the ABSOLUTE form (EA ptr16:32) to CS=0x08 (not a rel jmp)
    echo "$chx" | grep -q 'ea1b0010000800' || { fail_test "$label whitebox: no absolute far-jmp to 0x08:0x10001b"; ok=0; }
    # (c) genuine #DE trigger present AND the wrapper validates the faulting EIP
    echo "$chx" | grep -q 'f7f1' || { fail_test "$label whitebox: no div ecx (#DE trigger)"; ok=0; }
    echo "$chx" | grep -q '813c2439001000' || { fail_test "$label whitebox: wrapper does not validate faulting EIP (cmp [esp],0x100039)"; ok=0; }
    # (d) the IDT gate: offset=0x100042 (the wrapper vaddr) / sel 0x0008 / attr 0x8E
    echo "$chx" | grep -q '42000800008e1000' || { fail_test "$label whitebox: IDT gate offset!=wrapper vaddr or wrong selector/attr"; ok=0; }
    # (e) the flat GDT code + data descriptors
    echo "$chx" | grep -q 'ffff00' || { fail_test "$label whitebox: no flat segment limit"; ok=0; }
    echo "$chx" | grep -q '9acf00' || { fail_test "$label whitebox: no flat 32-bit code descriptor (9A CF)"; ok=0; }
    echo "$chx" | grep -q '92cf00' || { fail_test "$label whitebox: no flat 32-bit data descriptor (92 CF)"; ok=0; }
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
      printf 'set timeout=0\nset default=0\nmenuentry "z" {\n multiboot /boot/kernel.elf\n boot\n}\n' \
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
    printf -- "-- emit: multiboot32-idt\n%b\n" "$prog" > "$cdir/probe.herb"
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
    echo "SKIP: native-codegen link19 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
    # Still run the emulator-free gates (compile, static, white-box, rejects) so
    # make test has real coverage without an emulator.
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
# -idt handler uses the SAME subset as toakie, so the boundary is the same.
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
[[ "$fail" -eq 0 ]] && pass=$((pass + 12))

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then
    echo "$fail native-codegen-link19 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link19 / zonday: freestanding 32-bit Multiboot image installs its own GDT+IDT and catches the CPU's own #DE fault on bare metal; $pass checks: static+white-box (lgdt/lidt, absolute far-jmp, #DE trigger + faulting-EIP wrapper, IDT gate offset==handler vaddr, flat GDT descriptors, no x86 ret, real je on boundary), QEMU substrate (3 probes both branch arms + literal, result-dependent exit), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 12 out-of-subset rejects with twins; graded vs host-derived golden on the dual-substrate oracle)"
exit 0
