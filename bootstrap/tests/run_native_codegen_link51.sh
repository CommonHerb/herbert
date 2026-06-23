#!/usr/bin/env bash
# Native-codegen Link 51 / cleave (kernel-arc link 35): COPY-ON-WRITE -- the first time the kernel COPIES a page on
# demand. tessera (link 34) gave the stack non-identity ALIASING (one frame F at two virtual names). cleave is the
# within-one-execution observable that aliasing makes output-forceable and per-process address spaces (cross-process,
# unobservable on one CPU) do NOT: one ring-3 program maps the SAME shared frame F at a WRITABLE alias VW (F|7) and a
# READ-ONLY alias VR (F|5); it fills F through VW, then stores a marker THROUGH VR -- a write-protection #PF -- and the
# kernel's COW arm allocates a FRESH frame F' from a reserved pool, COPIES F->F' (rep movsd), remaps PTE[VR]<-F'|7
# (PRIVATE + writable), and IRET-resumes the store into the copy. The program then reads back BOTH aliases: VR diverged
# at the written word (its private copy F'), VW is UNCHANGED (the shared F). Built on the FROZEN tessera lineage. A NEW
# kernel emit mode `multiboot32-cleave` (additive). KERNEL-EMIT only; the forcing probe is hand-assembled.
#
# Why GENUINELY OUTPUT-FORCED (not white-box ceremony, unlike per-process CR3): the divergence is observed WITHIN one
# execution -- two names that were the same frame are observably different after the write, with the copy preserving the
# original contents. A "flip VR writable without copying" forge (M-cowshare) makes the store hit the SHARED F, so VW
# reads the marker -> RED ON OUTPUT. (Cross-model Codex ranked COW the strongest next memory link; a 4-leg same-model
# panel + 2 Codex legs converged that per-process-AS is output-forgeable by a single-pd software TLB-swap.)
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a KVM real-silicon leg, vs cleave_ref.py):
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == cleave_ref.build_elf() AND carries the COW machinery
#       (assert_cleave: PTE[VW]<-F|7 writable AND PTE[VR]<-F|5 READ-ONLY (same F -> aliased, F != VW,VR -> non-identity);
#       a `rep movsd` page copy; the copy destination from the cow_next pool, NOT the shared F).
#   (B3) the FROZEN tessera kernel FAILS assert_cleave (it installs both aliases WRITABLE and has no COW arm/copy).
#   (D) FROZEN: the prior baked-kernel modes are byte-identical (cleave is PURELY ADDITIVE).
#   (C) SILICON make-or-break: the prober fills F through VW, COW-stores through VR, and emits SH_N words from VW
#       (== payload: F UNCHANGED) then SH_N from VR (== payload but word COW_IDX == marker: the PRIVATE copy). GREEN
#       requires VW preserved AND VR's copy to hold the ORIGINAL payload except the one written word + a COW witness.
#       SEED-DIFFERENTIAL: a DIFFERENT late-bound seed -> different payload; grading with the default seed is RED.
#   (C-DIFF) THE DIFFERENTIAL: the FROZEN tessera kernel, fed the SAME prober, maps VR WRITABLE (no COW) -> the store
#       hits the shared F -> VW reads the marker -> RED. The copy-on-write is genuinely NEW.
# The held-back MUTATION proof (run_native_codegen_link51_mutation.sh) proves each piece non-vacuous (M-cowshare:
# flip VR writable over the shared F, no private copy -> VW reads the marker; M-nocopy: alloc F' but don't copy ->
# VR garbage; M-noremap: copy but don't remap -> re-fault; M-vrwritable: install VR writable -> no COW; M-videntr:
# VR -> a disjoint frame; M-noinstall: no alias -> the store #PFs terminally).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/cleave_ref.py"
PRIOR_REF="$script_dir/tessera_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
SEED="${CLEAVE_SEED:-90}"        # the held-back seed byte fed late-bound over COM1 (decimal 90 = 0x5A)
SEEDB="${CLEAVE_SEEDB:-77}"      # the seed-differential byte (decimal 77 = 0x4D)
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm() { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

emit() { # marker prog outfile label
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

# ---- reference artifacts ----
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK" none full)"
PROBER="$work/prober.bin"; python3 "$REF" modcowprober "$PROBER"   # K=1, LATE-BOUND seed (SYS_READ over COM1)

MKELF="$work/cleave_kernel.elf"
emit '-- emit: multiboot32-cleave' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) cleave kernel byte-identical to cleave_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) cleave kernel differs from cleave_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" cleave "$MKELF"; then ok "(B2) kernel carries the COW machinery (assert_cleave: PTE[VW]<-F|7 writable + PTE[VR]<-F|5 READ-ONLY -- aliased + non-identity; a rep movsd page copy; the copy dst from the cow_next pool not the shared F)"
else fail_test "(B2) kernel lacks the COW machinery (assert_cleave failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "cleave kernel is a valid x86 Multiboot image"
else fail_test "cleave kernel is not a valid x86 Multiboot image"; fi
# the frozen tessera kernel must FAIL assert_cleave (it maps both aliases WRITABLE and has no COW copy) -- the pin discriminates
python3 "$PRIOR_REF" kernelelf "$work/tess_for_assert.elf" none full >/dev/null 2>&1
if python3 "$REF" cleave "$work/tess_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen tessera kernel PASSED assert_cleave -- the white-box pin does not discriminate copy-on-write"
else ok "(B3) the frozen tessera kernel FAILS assert_cleave (the READ-ONLY alias + the page copy are genuinely new)"; fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive) ----
for lk in tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; cleave is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- cleave disturbed it"; fi
done

# ============================ SILICON (the copy-on-write make-or-break) ============================
emu_ran=0
qemu_run() { # kernel-elf out seed timeout [kvm]
    local kel="$1" out="$2" sd="$3" to="$4" kvm="${5:-}" acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local P; P="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$P" "$sd" --delay 1 --hold 12 > "$work/feed.log" 2>&1 &
    local fp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$work/feed.log" 2>/dev/null && break; sleep 0.05; done
    timeout "$to" qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$PROBER" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$P",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
}
if have_qemu; then
    emu_ran=1
    qemu_run "$MKELF" "$work/q" "$SEED" 40
    if python3 "$REF" gradecleave "$work/q" "$KEND" "$SEED" >/dev/null 2>&1; then ok "(C) QEMU: the prober fills F through VW, stores a marker THROUGH the read-only VR -> the kernel COPIES F->F' and remaps VR private; VR's word diverges to the marker while VW (the shared F) is UNCHANGED and VR's copy preserves the rest of the payload -- copy-on-write"
    else fail_test "(C) QEMU -> $(python3 "$REF" gradecleave "$work/q" "$KEND" "$SEED" 2>&1 | tr '\n' ';')"; fi
    # SEED-DIFFERENTIAL: a different late-bound seed -> different payload; grading with the default seed is RED
    qemu_run "$MKELF" "$work/qb" "$SEEDB" 40
    if python3 "$REF" gradecleave "$work/qb" "$KEND" "$SEEDB" >/dev/null 2>&1; then ok "(C) QEMU seed-B: the COW copy preserves the NEW held-back seed's payload (data-dependence)"
    else fail_test "(C) QEMU seed-B -> $(python3 "$REF" gradecleave "$work/qb" "$KEND" "$SEEDB" 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" gradecleave "$work/qb" "$KEND" "$SEED" >/dev/null 2>&1; then fail_test "(C) QEMU seed-B run graded GREEN with the DEFAULT seed -- the copied payload is NOT data-dependent (vacuous)"
    else ok "(C) QEMU the seed-B run is RED graded with the default seed (the copied page contents follow the late-bound held-back seed)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- THE DIFFERENTIAL (the key forcing proof): the FROZEN tessera kernel maps VR WRITABLE -> NO copy-on-write ----
# tessera installs PTE[VW]<-F|7 and PTE[VR]<-F|7 (both WRITABLE) and has no COW arm. The prober's store THROUGH VR does
# NOT fault -> it lands in the SHARED frame F -> VW reads the marker (the shared frame was corrupted) -> RED. The copy-on-
# write is genuinely new (not incidental to aliasing).
if have_qemu && [[ -f "$PRIOR_REF" ]]; then
    TKELF="$work/tessera_kernel.elf"; TKEND="$(python3 "$PRIOR_REF" kernelelf "$TKELF" none full)"
    qemu_run "$TKELF" "$work/qdiff" "$SEED" 20
    if python3 "$REF" gradecleave "$work/qdiff" "$TKEND" "$SEED" >/dev/null 2>&1; then fail_test "(C-DIFF) the frozen TESSERA kernel graded GREEN -- copy-on-write is NOT genuinely new (tessera already copies on write?)"
    else ok "(C-DIFF) the frozen TESSERA kernel + the SAME prober is RED -- VR is WRITABLE so the store hits the shared frame F (no private copy) -> VW reads the marker; cleave's copy-on-write is a genuinely new observable"; fi
elif [[ ! -f "$PRIOR_REF" ]]; then
    fail_test "(C-DIFF) missing $PRIOR_REF -- cannot run the tessera differential"
fi

# ---- KVM (real silicon): the write-protection #PF + page copy on the real MMU (the iret-DS-null silicon class) ----
if have_kvm; then
    qemu_run "$MKELF" "$work/k" "$SEED" 40 kvm
    if python3 "$REF" gradecleave "$work/k" "$KEND" "$SEED" >/dev/null 2>&1; then ok "(C-KVM) real silicon: the write-protection #PF on the read-only alias + the page copy + the private remap is byte-identical on KVM (the CPU's own MMU traps the CPL3 write to the |5 page and resumes into the copy)"
    else fail_test "(C-KVM) KVM -> $(python3 "$REF" gradecleave "$work/k" "$KEND" "$SEED" 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; 1 module line) ----
bochs_run() { # out seed timeout
    local out="$1" sd="$2" to="$3"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"; local port; port="$(free_port)"
    python3 "$script_dir/kernel_input_feed.py" "$port" "$sd" --delay 2 --hold 40 > "$d/feed.log" 2>&1 &
    local bfp=$!; local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" 2>/dev/null && break; sleep 0.05; done
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf
      sudo cp "$PROBER" mnt/boot/prober.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/prober.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL $to bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    kill "$bfp" 2>/dev/null; wait "$bfp" 2>/dev/null
    python3 - "$d/bochs_out.txt" "$out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    bochs_run "$work/b" "$SEED" 150
    if python3 "$REF" gradecleave "$work/b" "$KEND" "$SEED" >/dev/null 2>&1; then ok "(C) Bochs: copy-on-write is byte-identical on the 2nd substrate (GRUB delivers the prober; the write-protection #PF + page copy + private remap reproduce)"
    else fail_test "(C) Bochs -> $(python3 "$REF" gradecleave "$work/b" "$KEND" "$SEED" 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link51 (cleave / COPY-ON-WRITE): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link51 cleave / COPY-ON-WRITE -- one ring-3 program maps a shared frame F at a WRITABLE alias VW (F|7) and a READ-ONLY alias VR (F|5); a store THROUGH VR traps a write-protection #PF and the kernel COPIES F->F' (rep movsd), remaps PTE[VR]<-F'|7 private, and IRET-resumes the store into the copy, so VR diverges while VW (the shared F) is UNCHANGED; the first time the kernel copies a page on demand. Byte-pinned to cleave_ref.build_elf (binds the read-only alias + the page copy + the private-pool remap, not a permission flip), white-box assert_cleave, QEMU+KVM+Bochs GREEN, seed-differential data-dependent, frozen-tessera differential RED (tessera maps VR writable -> the store corrupts the shared frame), additive on tessera/furlough/homestead/tenement/rollcall/tickover. Output-forced WITHIN one execution -- the within-context observable aliasing makes forceable and per-process CR3 (cross-process, unobservable on one CPU) does not. HONEST SCOPE: ONE shared frame + a fixed-vaddr RO/RW alias pair + a reserved bump pool for copies (no runtime free-frame allocator, no general arena, no per-process address spaces / ELF loader))"
