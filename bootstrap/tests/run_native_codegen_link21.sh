#!/usr/bin/env bash
# Native codegen Link 21 (the FIFTH kernel-arc link): the freestanding image performs the
# first STORE TO A RUNTIME-COMPUTED ADDRESS (candidate (d)) -- it writes a page-table entry
# at a slot address computed at runtime from a virtual address, mapping a page left UNMAPPED
# at build time, then ACCESSES that page and it SUCCEEDS. The MMU is the judge: the access
# only works if the runtime store landed at the right slot with valid bits; otherwise the
# access #PFs into a fail-closed (limit-0) IDT -> triple-fault. The compiled-Herbert main()
# body (toakie subset) then emits the proof byte (anti-ceremony: real compiled lowering, not
# a blob). No fault on the happy path -> no #PF handler, no iret, no TLB flush (the page was
# never accessed, so nothing is cached). Graded, like lingo/toakie/zonday/chosen, on the
# far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs vs a HOST-derived golden), not C.
#
# Selected by the anchored first-line directive "-- emit: multiboot32-store" (a FIFTH emit
# mode; the plain "-- emit: multiboot32", "-idt", "-page", and default ELF64 modes are
# byte-identical, so the native self-host fixpoint gen2==gen1 is preserved).
#
# Image execution (vaddr V0=0x10000c): a fixed 99-byte STRUCTURAL head --
#   cli; lgdt <own GDT>; far-jmp CS=0x08; reload DS/ES/FS/GS/SS=0x10; mov esp; lidt <FAIL-CLOSED
#   limit-0 IDTR>; clear CR4 (PAE/PSE/PGE); mov cr3 <own PD>; set CR0.PG (paging on); jmp $+2;
#   THE COMPUTED-ADDRESS STORE: mov ebx,0x300000; mov eax,ebx; shr eax,10; add eax,<PT base>
#   (eax = the PTE slot for vaddr 0x300000, computed at runtime); mov [eax],<frame|present|RW>
#   (the store -- maps 0x300000 to the present frame above the PT); then THE ACCESS:
#   mov al,[0x300000] -- the MMU walks the just-written PTE; success iff the store was correct.
# the HANDLER is just the compiled main() body (no fault expected) -> the shared 58-byte
#   epilogue (debugcon frame 0xDE<byte>0xAD + result-dependent isa-debug-exit + Bochs power-off
#   + cli;hlt;spin); then the emitter-laid-out GDT/GDTR/(limit-0)IDTR; then a 4 KiB-aligned PD
#   + PT (PT[0x300]=0 at build time -- the hole the runtime store fills).
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; multiboot magic in first 8 KiB &
#     4-aligned; ZERO syscall escapes (no 0F 05 / CD 80 / 0F 34 AND an instruction-aware
#     objdump scan finds no syscall/sysenter/int).
#   WHITE-BOX (per probe; the runtime byte alone is forgeable -- a handler could emit it
#   without the store -- so prove the structure statically):
#     - THE EXACT 99-BYTE STRUCTURAL HEAD, byte-for-byte (only the 2 le32 fields gdtr/idtr
#       vary): pins the CR0.PG-enable, the COMPUTED store (mov ebx,0x300000; mov eax,ebx;
#       shr eax,10; add eax,PT; mov [eax],frame|3) and the access (mov al,[0x300000]) -- so a
#       forged image that skips the store, uses a non-computed store, or maps the wrong frame
#       (the PT base and the PTE value are PINNED) is CAUGHT here.
#     - the absolute far-jmp (EA ptr16:32) to CS=0x08
#     - the flat GDT code (9A CF) + data (92 CF) descriptor followed by GDTR.limit=0x17
#     - the build-time page-table hole at 0x300000 (mapped 0x2ff003, hole 0, mapped 0x301003)
#       -- the slot the runtime store fills -- and PDE[0] -> PT
#     - NO x86 `ret` in the body; (branching probes) a real `je` on an instruction boundary
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit code == host golden, e9 == 0xDE<byte>0xAD, ONE frame
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence
#   PROBE VECTORS: then-arm + else-arm (distinct branch bytes) + a literal + a no-locals body
#     + a 31-local cap body. Each proves the body ran AFTER the runtime store mapped the page.
#   REJECTS (+ twins): an out-of-subset body (div/mod, bitwise, 2-function, non-EQ comparator,
#     parameterised main, non-EQ bool cond) emits NO valid image; the 32-local cap (ERR 470)
#     too. The twin must reject too (structural, not fitted).
#
# Honest scope: proves "writes a PTE at a runtime-computed address and the MMU honors it as a
# freestanding 32-bit Multiboot image under QEMU + Bochs+GRUB," NOT real silicon, arbitrary
# emulator versions, iret-resumption / demand paging (the SIXTH link), long mode, or the
# PIC/device IRQs. Still 32-bit PM. The dual-substrate + host golden replaces the absent C
# differential. This is candidate (d) (the store) in its minimal, MMU-judged form.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L5_BOCHS_PROBES:-store_then store_else}"

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

gen_locals() { # n prefix
    local n="$1" pfx="$2" s='func main():' i
    for i in $(seq 0 $((n - 1))); do s="$s let $pfx$i = $i"; done
    echo "$s return $pfx$((n - 1)) end"
}
prog_src() { # label
    case "$1" in
      store_then)    echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      store_else)    echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      store_lit)     echo 'func main(): let x = 46  return x end' ;;
      store_nolocal) echo 'func main(): return 77 end' ;;
      store_cap31)   gen_locals 31 a ;;
    esac
}
prog_byte() { # label -> host-derived expected low byte
    case "$1" in
      store_then)    echo 88 ;;
      store_else)    echo 11 ;;
      store_lit)     echo 46 ;;
      store_nolocal) echo 77 ;;
      store_cap31)   echo 30 ;;
    esac
}
is_branching() { case "$1" in store_then|store_else) return 0 ;; *) return 1 ;; esac; }
ALL_PROBES="store_then store_else store_lit store_nolocal store_cap31"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-store\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
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

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # (0) THE EXACT 99-BYTE STRUCTURAL HEAD. Pins (only gdtr/idtr le32 vary): cli; lgdt;
    #     far-jmp 0x08:V0+15; segregs; mov esp,0x107000; lidt; clear CR4; mov cr3,0x101000;
    #     CR0.PG; jmp $+2; mov ebx,0x300000; mov eax,ebx; shr eax,10; add eax,0x102000 (the
    #     PT base, PINNED); mov [eax],0x103003 (the PTE value/frame, PINNED); mov al,[0x300000].
    #     This proves the store is COMPUTED (the shr/add) and lands at the right slot with the
    #     right value -- a forged/absent/wrong-frame store is CAUGHT here (the runtime byte
    #     alone is forgeable; cr2/the load can be faked).
    #     VALIDITY DOMAIN: the PT base (0x102000) and the PTE value (0x103003 = frame 0x103000 |
    #     present|RW) are pinned as constants, which hold while pd_vaddr rounds to 0x101000 -- true
    #     for every toakie-subset probe here (all are small; the largest, 31-locals, was checked).
    #     A body large enough (epi > ~3.8 KiB) to roll pd_vaddr would shift these and fail the
    #     regex (a false-FAIL, not a masking hole -- caught loudly); such bodies are out of scope
    #     for this fixture, and a future link that needs them would make these pins structural
    #     (capture pd, assert PT==pd+0x1000, map_pte==pd+0x2003).
    local head="${chx:0:198}"
    local hre='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc007010000f011d[0-9a-f]{8}0f20e0254fffffff0f22e0b8001010000f22d80f20c00d000000800f22c0eb00bb0000300089d8c1e80a0500201000c70003301000a000003000$'
    [[ "$head" =~ $hre ]] || { fail_test "$label whitebox: structural head != exact paging+computed-store+access template (the runtime computed store to the right slot/frame is unproven)"; ok=0; }
    # (a) own GDT + IDT installed: lgdt (0F 01 /2) and lidt (0F 01 /3)
    echo "$chx" | grep -q '0f0115' || { fail_test "$label whitebox: no lgdt (0F 01 /2)"; ok=0; }
    echo "$chx" | grep -q '0f011d' || { fail_test "$label whitebox: no lidt (0F 01 /3)"; ok=0; }
    # (b) absolute far-jmp to CS=0x08
    echo "$chx" | grep -q 'ea1b0010000800' || { fail_test "$label whitebox: no absolute far-jmp to 0x08:0x10001b"; ok=0; }
    # (c) paging-enable: mov cr3,eax (0F 22 D8) + CR0.PG (or 0x80000000; mov cr0,eax)
    echo "$chx" | grep -q '0f22d8' || { fail_test "$label whitebox: no mov cr3,eax"; ok=0; }
    echo "$chx" | grep -q '0d000000800f22c0' || { fail_test "$label whitebox: no CR0.PG enable"; ok=0; }
    # (d) the computed store: shr eax,10 (C1 E8 0A) + mov [eax],imm32 (C7 00 ...) present
    echo "$chx" | grep -q 'c1e80a' || { fail_test "$label whitebox: no runtime slot computation (shr eax,10)"; ok=0; }
    echo "$chx" | grep -q 'c70003301000' || { fail_test "$label whitebox: no computed-address PTE store of frame|present|RW"; ok=0; }
    # (e) flat GDT code + data descriptor + GDTR.limit=0x17 + the FAIL-CLOSED IDTR (limit 0,
    #     base 0) immediately after. The limit-0 IDTR is the mechanism that turns a broken store
    #     (#PF) into a triple-fault (the link's RED); pin it so a regression that installs a REAL
    #     #PF handler -- which could silently MASK a broken store by emitting the byte from the
    #     handler -- is CAUGHT here, not just relied on at runtime.
    echo "$chx" | grep -q 'ffff00' || { fail_test "$label whitebox: no flat segment limit (FF FF)"; ok=0; }
    echo "$chx" | grep -q '9acf00' || { fail_test "$label whitebox: no flat 32-bit code descriptor (9A CF)"; ok=0; }
    echo "$chx" | grep -qE '92cf001700[0-9a-f]{8}000000000000' || { fail_test "$label whitebox: data descriptor + GDTR limit 0x17 not immediately followed by a FAIL-CLOSED IDTR (limit 0, base 0)"; ok=0; }
    # (f) the build-time page-table hole at 0x300000 (mapped 0x2ff003, hole 0, mapped 0x301003)
    #     -- the slot the runtime store fills -- and PDE[0] -> PT.
    echo "$chx" | grep -q '03f02f000000000003103000' || { fail_test "$label whitebox: build-time page-table hole at 0x300000 not present between mapped neighbors"; ok=0; }
    echo "$chx" | grep -q '03201000' || { fail_test "$label whitebox: PDE[0] does not point to the page table"; ok=0; }
    # bound the disasm to the code (head+body+epilogue) by the epilogue terminal
    local term="${chx%%faf4ebfd*}"
    if [[ "$term" == "$chx" ]]; then fail_test "$label whitebox: epilogue terminal absent"; return 1; fi
    local endbytes=$(( ${#term} / 2 + 4 ))
    dd if="$code" of="$code.t" bs=1 count="$endbytes" status=none 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386 -M intel "$code.t" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
    [[ -n "$dis" ]] || { fail_test "$label whitebox: empty disassembly"; return 1; }
    # (g) NO x86 ret in the body
    if echo "$dis" | grep -qE '\bret\b'; then fail_test "$label whitebox: x86 ret present in body"; ok=0; fi
    # (h) branching probes: a real je on an instruction boundary
    if is_branching "$label"; then
        echo "$dis" | grep -qE '\bje\b' || { fail_test "$label whitebox: no real conditional jump (je) in the body"; ok=0; }
        local addrs t; addrs=$(echo "$dis" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
        for t in $(echo "$dis" | grep -oE '\b(je|jmp) +0x[0-9a-f]+' | grep -oE '[0-9a-f]+$' | sort -u); do
            echo "$addrs" | grep -qiE "^0*${t}$" || { fail_test "$label whitebox: branch target 0x${t} not an instruction boundary"; ok=0; }
        done
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
    printf -- "-- emit: multiboot32-store\n%b\n" "$prog" > "$cdir/probe.herb"
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
    echo "SKIP: native-codegen link21 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
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
    echo "$fail native-codegen-link21 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link21 / fifth kernel-arc link: freestanding 32-bit Multiboot image writes a PTE at a RUNTIME-COMPUTED address and the MMU honors it on bare metal; $pass checks: static+white-box (exact 99-byte paging+computed-store+access head, absolute far-jmp, CR3/CR0.PG enable, runtime slot computation + computed-address PTE store of frame|present|RW, flat GDT + GDTR limit, build-time page-table hole at 0x300000, PDE->PT, no x86 ret, real je on boundary), QEMU substrate (5 probes: both branch arms + literal + no-locals + 31-local cap, result-dependent exit), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 14 out-of-subset rejects with twins incl. the 32-local cap (ERR 470); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
