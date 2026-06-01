#!/usr/bin/env bash
# Native codegen Link 22 (the SIXTH kernel-arc link): the freestanding image performs DEMAND
# PAGING / iret-RESUMPTION -- it touches a page left UNMAPPED at build time, takes the CPU's own
# #PF, and a handler MAPS the page at runtime (a computed PTE store sourced from CR2), flushes
# the TLB, drops the #PF error code, and `iret`s -- so the faulting load RE-EXECUTES and now
# SUCCEEDS, reading a build-time-seeded frame. This is the FIRST link whose fault handler RESUMES
# the interrupted instruction (zonday/chosen/liberi all ended cli;hlt or never faulted). The proof
# byte comes from the RESUMED LOAD (seed[V] = V ^ 0x5A), so it can ONLY appear via a genuine
# iret-resume AND it tracks the compiled-Herbert body (anti-ceremony). Graded, like
# lingo/toakie/zonday/chosen/liberi, on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs vs a
# HOST-derived golden), not C.
#
# Selected by the anchored first-line directive "-- emit: multiboot32-demand" (a SIXTH emit mode;
# the plain "-- emit: multiboot32", "-idt", "-page", "-store", and default ELF64 modes are
# byte-identical, so the native self-host fixpoint gen2==gen1 is preserved).
#
# Image execution (vaddr V0=0x10000c): a fixed 73-byte paging-enable PROLOGUE (cli; lgdt; far-jmp
#   CS=0x08; reload DS/ES/FS/GS/SS=0x10; mov esp; lidt <REAL 15-entry IDT with a #PF gate>; clear
#   CR4; mov cr3 <own PD>; set CR0.PG; jmp $+2); then the compiled toakie body (result V in eax);
#   then the GLUE at `epi` -- movzx eax,al; mov al,[eax+0x300000] -- the FAULTING, RESUMED,
#   offset-indexed load (0x300000 is the build-time hole). On #PF the CPU vectors to the HANDLER
#   (push eax; mov eax,cr2; shr eax,10; add eax,PT; mov [eax],frame|3; mov eax,cr3; mov cr3,eax;
#   pop eax; add esp,4; iret) which RESUMES the load -> it reads seed[V] = V^0x5A from the
#   now-mapped frame; the shared 58-byte epilogue frames al as 0xDE<byte>0xAD + a result-dependent
#   isa-debug-exit. Then GDT/GDTR + 15-entry IDT (vec14 -> the handler) + IDTR; PD->PT; PT with the
#   hole at 0x300; the SEEDED FRAME (file-backed). Every return path (terminal RET fall-through AND
#   mid-body `pop eax; jmp epi`) funnels through the glue, so the resume is on the only output path.
#
# Gates (each a real assertion, not a comment):
#   STATIC (per probe): grub-file --is-x86-multiboot; multiboot magic in first 8 KiB & 4-aligned;
#     ZERO syscall escapes in the prologue+body+glue+epilogue (no 0F 05 / CD 80 / 0F 34 AND an
#     objdump scan finds no syscall/sysenter/int). The handler's syscall-freedom is proven by its
#     EXACT byte pin below (its 29 bytes contain no escape).
#   WHITE-BOX (per probe; the runtime byte alone is forgeable -- a handler that emits, or a
#   map-and-jump that skips the resume, would also produce a byte -- so prove the structure):
#     - THE EXACT 73-BYTE PAGING-ENABLE PROLOGUE (only gdtr/esp/idtr/pd le32 vary).
#     - THE GLUE: movzx eax,al; mov al,[eax+0x300000] -- the faulting resumed load on the output path.
#     - THE #PF HANDLER, byte-exact (only pt_base/frame le32 vary): push eax; mov eax,cr2; shr
#       eax,10; add eax,PT; mov [eax],frame|3; mov eax,cr3; mov cr3,eax; pop eax; add esp,4; iret.
#       This pins THE NEW CAPABILITY (the resume): a mutation of the store / flush / add-esp / iret
#       is caught here, AND a forged handler that EMITS the byte (instead of resuming) is excluded.
#     - THE IDT vector-14 (#PF) gate points EXACTLY at the pinned handler (sel 0x08 / attr 0x8E),
#       immediately followed by IDTR.limit=0x77 -- a decoy gate or a gate pointing elsewhere fails.
#     - the flat GDT code (9A CF) + data (92 CF)+GDTR.limit=0x17; the build-time hole at 0x300000
#       (mapped 0x2ff003, hole 0, mapped 0x301003) + PDE[0]->PT; the SEEDED FRAME prefix (i^0x5A).
#     - NO x86 `ret` in the body (iret is the resume); branching probes: a real `je` on a boundary.
#   RUNTIME (per probe, both substrates):
#     - QEMU: result-dependent isa-debug-exit == host golden, e9 == 0xDE<byte>0xAD, ONE frame.
#     - Bochs: exactly one host-golden frame AND clean-shutdown evidence.
#   PROBE VECTORS: then-arm (mid-RET) + else-arm (terminal-RET) + literal + no-locals + 31-local cap.
#     Each proves the body ran AND the faulting load resumed (byte = body-result ^ 0x5A).
#   REJECTS (+ twins): out-of-subset bodies (div/mod, bitwise, 2-function, non-EQ comparator,
#     parameterised main, non-EQ bool cond) emit NO valid image; the 32-local cap (ERR 477) too.
#
# Honest scope: proves "maps a faulting page at runtime and iret-RESUMES the faulting instruction
# as a freestanding 32-bit Multiboot image under QEMU + Bochs+GRUB," NOT real silicon, arbitrary
# emulator versions, asynchronous (PIC/device) interrupts, long mode, or width-correct MMIO. Still
# 32-bit PM. The dual-substrate + host golden replaces the absent C differential.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L6_BOCHS_PROBES:-demand_then demand_else}"

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
      demand_then)    echo 'func main(): let x = 6*7  if x == 42: return 88 else: return 11 end end' ;;
      demand_else)    echo 'func main(): let x = 6*7  if x == 43: return 88 else: return 11 end end' ;;
      demand_lit)     echo 'func main(): let x = 46  return x end' ;;
      demand_nolocal) echo 'func main(): return 77 end' ;;
      demand_cap31)   gen_locals 31 a ;;
    esac
}
prog_byte() { # label -> host-derived expected low byte = (body result) ^ 0x5A
    case "$1" in
      demand_then)    echo $((88 ^ 0x5A)) ;;   # 2
      demand_else)    echo $((11 ^ 0x5A)) ;;   # 81
      demand_lit)     echo $((46 ^ 0x5A)) ;;   # 116
      demand_nolocal) echo $((77 ^ 0x5A)) ;;   # 23
      demand_cap31)   echo $((30 ^ 0x5A)) ;;   # 68
    esac
}
is_branching() { case "$1" in demand_then|demand_else) return 0 ;; *) return 1 ;; esac; }
ALL_PROBES="demand_then demand_else demand_lit demand_nolocal demand_cap31"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-demand\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
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
    # Bound the escape scan to the prologue+body+glue+epilogue by the epilogue terminal; the #PF
    # handler that follows is byte-exact-pinned (whitebox) and contains no escape, and the data
    # tables / PD / PT / frame after it would mis-disassemble (and contain addr|3 + seed bytes).
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

# occurrence count of an (extended) regex in a hex string -- used to assert structural pins are
# EXACTLY-ONCE, not merely present (a presence-grep is forgeable: a decoy/duplicate would pass).
occ() { echo "$1" | grep -oE "$2" | wc -l | tr -d ' '; }

whitebox_gates() { # label elf
    local label="$1" elf="$2" ok=1
    local code="$tmp/$label.wb"
    dd if="$elf" of="$code" bs=1 skip=4108 status=none 2>/dev/null
    local chx; chx=$(xxd -p "$code" | tr -d '\n')
    # (0) THE EXACT 73-BYTE PAGING-ENABLE PROLOGUE (only gdtr/esp/idtr/pd le32 vary): cli; lgdt;
    #     far-jmp 0x08:V0+15; reload DS/ES/FS/GS/SS; mov esp; lidt; mov eax,cr4; AND eax,0xFFFFFF4F
    #     (clear PAE/PSE/PGE); mov eax,PD; mov cr3,eax; mov eax,cr0; OR eax,0x80000000; mov cr0,eax
    #     (PAGING ON); jmp $+2. Identical to liberi/chosen up to here.
    local pro="${chx:0:146}"
    local pre='^fa0f0115[0-9a-f]{8}ea1b001000080066b810008ed88ec08ee08ee88ed0bc[0-9a-f]{8}0f011d[0-9a-f]{8}0f20e0254fffffff0f22e0b8[0-9a-f]{8}0f22d80f20c00d000000800f22c0eb00$'
    [[ "$pro" =~ $pre ]] || { fail_test "$label whitebox: prologue != exact 73-byte paging-enable template"; ok=0; }
    # (1) THE GLUE: movzx eax,al (0F B6 C0); mov al,[eax+0x300000] (8A 80 00 00 30 00) -- the
    #     faulting, resumed, offset-indexed load -- IMMEDIATELY BEFORE the epilogue (88 C3 = mov
    #     bl,al), EXACTLY ONCE. Pinning glue+epilogue contiguously (a positional pin, not just
    #     presence) proves the glue is the instruction the epilogue falls through from -- so the
    #     proof byte (al) is whatever the resumed load produced. Combined with (7)'s reachability
    #     check (no branch SKIPS the glue), this closes the "forge al + jump over the glue" bypass.
    [[ "$(occ "$chx" '0fb6c08a800000300088c3')" == 1 ]] || { fail_test "$label whitebox: faulting resumed-load glue not immediately before the epilogue (mov bl,al) exactly once -- it could be bypassed"; ok=0; }
    # (2) THE #PF HANDLER (THE NEW CAPABILITY -- iret-resume), byte-exact (only pt_base/frame le32
    #     vary): push eax; mov eax,cr2; shr eax,10; add eax,PT; mov [eax],frame|3; mov eax,cr3;
    #     mov cr3,eax; pop eax; add esp,4; iret. Pins the runtime store-from-cr2 + the TLB flush
    #     + the error-code drop + the iret. EXACTLY ONCE (so the gate cross-check below cannot be
    #     fooled by a decoy handler). A mutation of ANY step, or a handler that EMITS the byte
    #     instead of resuming, is CAUGHT here (the runtime byte alone is forgeable).
    # The trailing 0000000000000000 anchors the handler's iret to the GDT null descriptor that
    # immediately follows it (a positional pin -- the handler ends exactly at the tables boundary,
    # so a trailing-byte forge after `iret` cannot match).
    local hre='500f20d0c1e80a05[0-9a-f]{8}c700[0-9a-f]{8}0f20d80f22d85883c404cf0000000000000000'
    [[ "$(occ "$chx" "$hre")" == 1 ]] || { fail_test "$label whitebox: exact #PF iret-resume handler (cr2-computed store + cr3 flush + add esp,4 + iret) not present exactly once, ending at the tables boundary"; ok=0; }
    # (3) the IDT vector-14 (#PF) gate points EXACTLY at the pinned handler (sel 0x08 / attr 0x8E),
    #     immediately followed by IDTR.limit=0x0077. The handler vaddr is derived from WHERE the
    #     pinned handler bytes actually are (asserted unique above + here), so a decoy gate or a
    #     gate pointing elsewhere fails.
    local hpos; hpos=$(echo "$chx" | grep -bo '500f20d0c1e80a05' | head -1 | cut -d: -f1)
    if [[ -z "$hpos" || "$(occ "$chx" '500f20d0c1e80a05')" != 1 ]]; then
        fail_test "$label whitebox: handler-locator bytes not present exactly once (gate cross-check unsafe)"; ok=0
    else
        local hvaddr=$(( 1048588 + hpos / 2 ))
        local glo=$(( hvaddr & 65535 )) ghi=$(( (hvaddr >> 16) & 65535 ))
        local gate; gate=$(printf '%02x%02x0800008e%02x%02x' $((glo & 255)) $((glo >> 8)) $((ghi & 255)) $((ghi >> 8)))
        echo "$chx" | grep -q "${gate}7700" || { fail_test "$label whitebox: IDT #PF gate does not point at the pinned handler (sel 0x08/attr 0x8E) immediately before IDTR limit 0x77"; ok=0; }
    fi
    # (4) the flat GDT: code (9A CF) + data (92 CF) descriptor immediately followed by GDTR.limit=0x17
    echo "$chx" | grep -q '9acf00' || { fail_test "$label whitebox: no flat 32-bit code descriptor (9A CF)"; ok=0; }
    [[ "$(occ "$chx" '92cf001700')" == 1 ]] || { fail_test "$label whitebox: data descriptor + GDTR limit 0x17 not present exactly once"; ok=0; }
    # (5) the build-time page-table hole at 0x300000 (mapped 0x2ff003, hole 0, mapped 0x301003) --
    #     the slot the RUNTIME store fills -- and PDE[0] -> PT (the runtime store maps INTO this PT).
    #     EXACTLY ONCE (so the PT base derived below is unambiguous).
    local holepos; holepos=$(echo "$chx" | grep -bo '03f02f000000000003103000' | head -1 | cut -d: -f1)
    if [[ -z "$holepos" || "$(occ "$chx" '03f02f000000000003103000')" != 1 ]]; then
        fail_test "$label whitebox: build-time page-table hole at 0x300000 not present exactly once between mapped neighbors"; ok=0
    else
        # PT[767] (0x2ff003) is at PT_base + 767*4 = PT_base + 3068; the matched pattern starts there.
        local pt_off=$(( holepos / 2 - 3068 )) pt_vaddr
        pt_vaddr=$(( 1048588 + pt_off ))
        local pde; pde=$(printf '%02x%02x%02x%02x' $(( (pt_vaddr+3) & 255 )) $(( ((pt_vaddr+3) >> 8) & 255 )) $(( (pt_vaddr >> 16) & 255 )) $(( (pt_vaddr >> 24) & 255 )))
        local pde_at=$(( (pt_off - 4096) * 2 ))
        [[ "${chx:$pde_at:8}" == "$pde" ]] || { fail_test "$label whitebox: PDE[0] does not point to the page table (present+RW)"; ok=0; }
    fi
    # (6) the SEEDED FRAME prefix: seed[i] = i ^ 0x5A, so bytes 0..7 = 5A 5B 58 59 5E 5F 5C 5D.
    #     EXACTLY ONCE (the single seeded frame; a duplicate would be a decoy).
    [[ "$(occ "$chx" '5a5b58595e5f5c5d')" == 1 ]] || { fail_test "$label whitebox: seeded frame prefix (i ^ 0x5A) not present exactly once"; ok=0; }
    # (7) REACHABILITY of the faulting load. Bound the disasm to the prologue+body+GLUE (up to the
    #     glue's end), and require: (a) NO x86 `ret` (the resume is via iret, pinned in the handler);
    #     (b) every conditional/unconditional branch target is an instruction boundary AND <= the
    #     GLUE offset -- i.e. NO branch skips the faulting load into the epilogue. With the glue
    #     pinned immediately before the epilogue (check 1), this proves the faulting/resumed load is
    #     executed on EVERY path that reaches the epilogue -- a forged body that computes a byte and
    #     jumps over the glue (Codex's reachability bypass) is CAUGHT here. (Note: a body that instead
    #     FALLS THROUGH the glue has its al overwritten by seed[eax], so it cannot pre-forge the byte;
    #     and the toakie subset has no XOR, so a genuine body cannot compute seed[V]=V^0x5A at all.)
    local glue_off; glue_off=$(echo "$chx" | grep -bo '0fb6c08a8000003000' | head -1 | cut -d: -f1)
    glue_off=$(( glue_off / 2 ))
    dd if="$code" of="$code.t" bs=1 count="$(( glue_off + 9 ))" status=none 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386 -M intel "$code.t" 2>/dev/null | grep -E '^ *[0-9a-f]+:')
    [[ -n "$dis" ]] || { fail_test "$label whitebox: empty disassembly"; return 1; }
    if echo "$dis" | grep -qE '\bret\b'; then fail_test "$label whitebox: x86 ret present in body (resume must be via iret)"; ok=0; fi
    local addrs t tn; addrs=$(echo "$dis" | sed -E 's/^ *([0-9a-f]+):.*/\1/')
    for t in $(echo "$dis" | grep -oE '\b(je|jne|jmp) +0x[0-9a-f]+' | grep -oE '[0-9a-f]+$' | sort -u); do
        echo "$addrs" | grep -qiE "^0*${t}$" || { fail_test "$label whitebox: branch target 0x${t} not an instruction boundary"; ok=0; }
        tn=$(( 16#${t} ))
        [[ "$tn" -le "$glue_off" ]] || { fail_test "$label whitebox: branch target 0x${t} skips past the faulting glue (offset $glue_off) -- a bypass of the resumed load"; ok=0; }
    done
    if is_branching "$label"; then
        echo "$dis" | grep -qE '\bje\b' || { fail_test "$label whitebox: no real conditional jump (je) in the body"; ok=0; }
    fi
    # (8) the BODY (offset 73..glue) is the compiler's toakie lowering -- arithmetic + branches only.
    #     Forbid privileged/control instructions there (lgdt/lidt/sgdt/sidt/lmsw, mov cr*/dr*, wrmsr/
    #     rdmsr, hlt, in/out, invlpg, iret) so a forged body cannot install a second IDT, rewrite
    #     paging, or hand-roll its own fault path to pose as a genuine resume (Codex's body-forge
    #     class). The prologue -- which legitimately has lgdt/lidt/mov-cr -- is excluded by the window.
    if [[ "$glue_off" -gt 73 ]]; then
        dd if="$code" of="$code.body" bs=1 skip=73 count="$(( glue_off - 73 ))" status=none 2>/dev/null
        local bdis; bdis=$(objdump -D -b binary -m i386 -M intel "$code.body" 2>/dev/null \
            | grep -E '^ *[0-9a-f]+:' | sed -E 's/^[^\t]*\t[^\t]*\t//')
        # objdump suffixes the 32-bit descriptor-table/return ops as lgdtd/lidtd/sgdtd/sidtd/iretd.
        if echo "$bdis" | grep -qiE '^(lgdtd?|lidtd?|sgdtd?|sidtd?|lldt|ltr|lmsw|wrmsr|rdmsr|hlt|invlpgd?|invd|wbinvd|iretd?|sysenter|syscall|insb?|outsb?|in|out)\b|cr[0-9]|dr[0-9]'; then
            fail_test "$label whitebox: privileged/control instruction in the body (forged fault path)"; ok=0
        fi
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
    printf -- "-- emit: multiboot32-demand\n%b\n" "$prog" > "$cdir/probe.herb"
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
    echo "SKIP: native-codegen link22 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"
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
    echo "$fail native-codegen-link22 sub-test(s) failed."; exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link22 / sixth kernel-arc link: freestanding 32-bit Multiboot image maps a faulting page at runtime and iret-RESUMES the faulting instruction on bare metal; $pass checks: static+white-box (exact 73-byte paging-enable prologue, faulting resumed-load glue, exact #PF iret-resume handler [cr2-computed store + cr3 flush + add esp,4 + iret], IDT #PF gate -> the pinned handler, flat GDT, build-time page-table hole at 0x300000, PDE->PT, seeded frame i^0x5A, no x86 ret, branch-reachability (no path skips the faulting glue) + body free of privileged/control instructions, real je on boundary), QEMU substrate (5 probes: then[mid-RET] + else[term-RET] + literal + no-locals + 31-local cap, result-dependent exit), Bochs substrate ($BOCHS_PROBES, unique frame + clean shutdown), 14 out-of-subset rejects with twins incl. the 32-local cap (ERR 477); graded vs host-derived golden on the dual-substrate oracle)"
exit 0
