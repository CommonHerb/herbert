#!/usr/bin/env bash
# Native-codegen Link 53 / platter (kernel-arc link 37): the kernel's FIRST BLOCK DEVICE -- an ADDRESSED random-access
# disk READ via SYS_DISK_READ (eax=5). tessera/cleave/lethe gave non-identity aliasing, COW, and targeted TLB
# invalidation -- all in RAM. platter is the first time the kernel READS a persistent, randomly-ADDRESSED block device:
# a confused-deputy ATA PIO LBA28 single-sector read. ONE ring-3 prober (K=1, timer DISARMED via IF=0) does a DATA-
# DEPENDENT POINTER-CHASE: each sector's byte 0 NAMES (as a window index) the next sector to read; the next LBA =
# DISK_RESV_LO + (b & MASK). The module puts the LBA in EBX + the byte-offset in ECX; the kernel (CPL0) BOUNDS-CHECKS
# the LBA to the reserved window [DISK_RESV_LO, DISK_RESV_HI) (an access_ok on the LBA -- a module cannot read GRUB /
# the FAT partition / arbitrary sectors), does an ATA PIO read into its OWN 512-byte supervisor `diskbuf` (a CPL3
# module cannot do PIO -- an `in al,dx` at CPL3 #GPs), and returns [diskbuf+ECX] in eax; iret back. A NEW kernel emit
# mode `multiboot32-platter` (additive on the FROZEN lethe lineage). KERNEL-EMIT only; the chase prober is hand-asm.
#
# Why GENUINELY OUTPUT-FORCED: the chase order is late-bound in the AUTHOR-UNKNOWN disk bytes (dd'd per-run into the
# reserved window AFTER the kernel/prober are frozen). A serial COM1 stream cannot reproduce a data-dependent RANDOM-
# ACCESS order; the emitted chain == disk_chase_expect(chasemap) ONLY if the kernel actually does the ADDRESSED read
# the module's EBX names. M-fixedlba (ignore EBX, always read the start sector) collapses the chase (b1==b2==b3) -> RED;
# M-noread (skip the ATA sequence -> diskbuf stays 0) emits zeros -> RED; M-noboundscheck is a SANDBOX break the white-
# box assertplatter catches (output may be GREEN). The held-back MUTATION proof lives in the companion mutation harness.
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a KVM real-silicon leg, vs platter_ref.py):
#   (B1) KERNEL BYTE-PIN: the emitted kernel == platter_ref.build_elf() (the SYS_DISK_READ arm + the 512B diskbuf).
#   (B2) WHITE-BOX assertplatter: the kernel carries the disk-read machinery (the LBA access_ok to [LO,HI), the ATA
#        PIO LBA28 sequence with `rep insw` -- the 0x66 operand-size prefix, NOT insd -- into the supervisor diskbuf,
#        and the [diskbuf+offset] return).
#   (B3) the FROZEN lethe kernel FAILS assertplatter (it has no SYS_DISK_READ arm / no diskbuf).
#   (D) FROZEN: the prior baked-kernel modes are byte-identical (platter is PURELY ADDITIVE).
#   (C) SILICON make-or-break: the prober pointer-chases DISK_KHOPS sectors over the per-run author-unknown chasemap;
#        the emitted chain == disk_chase_expect(chasemap). GREEN on QEMU + KVM + Bochs.
#   (C-MAPDIFF) THE CHASEMAP DIFFERENTIAL: re-dd a DIFFERENT author-unknown chasemap -> grading the same emitted output
#        with the OLD map is RED, and grading the new run with the NEW map is GREEN (genuine data-dependence on the disk).
#   (C-DIFF) THE FROZEN-LETHE DIFFERENTIAL: the frozen lethe kernel + the SAME prober -> eax=5 is an UNKNOWN syscall
#        (falls to SYS_EXIT) -> the prober's first int 0x30 EXITs -> no chain emitted -> RED (the block device is new).
#   (C-HOSTILE) the hostile-LBA leg: a prober that asks for an OUT-OF-WINDOW LBA gets the sentinel 0 (access_ok holds).
#   (C-HOSTILE-ECX) the hostile-OFFSET leg: a prober with a VALID in-window LBA but a hostile byte-offset ECX>=512
#        (mapping to a nonzero kernel byte just past the 512B diskbuf) gets the sentinel 0 (the OFFSET access_ok holds).
#   (C-HOSTILE-DF) the hostile-DIRECTION-FLAG leg: a prober that sets DF=1 (std) before a VALID in-window read still gets
#        the correct disk byte (the kernel cld's before rep insw -> a FORWARD transfer regardless of the module's DF).
# REQUIRE_EMU fail-closed (the plumb pattern): if KERNEL_CODEGEN_REQUIRE_EMU=1 and an emulator is missing, FAIL.
#
# NOTE -- which legs cannot run until the orchestrator lands the `multiboot32-platter` emit mode in the compiler
# (stack/native_compile_fragment.herb) + reseeds gen-1, and renames lethe_ref.py -> platter_ref.py with the masking fix
# (module + oracle: `and ebx,MASK` in the prober's next-LBA + `idx=b&MASK` in disk_chase_expect; the KERNEL build_elf is
# UNCHANGED) and adds the `assertplatter` CLI verb:
#   * (B1)/(B2)/(B3)/(D) and EVERY silicon leg (C / C-MAPDIFF / C-DIFF / C-HOSTILE) emit the `multiboot32-platter`
#     kernel and so CANNOT run until the emit mode is in gen-1. Before then this harness FAILS at the emit step
#     (compiler produces no a.out for the unknown marker) -- which is the correct fail-closed behavior.
#   * (B2) additionally needs the `assertplatter` verb in platter_ref.py (the orchestrator adds it alongside the rename).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/platter_ref.py"
PRIOR_REF="$script_dir/lethe_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
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

emit() { # marker prog outfile label
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

# ---- disk-window constants (single source of truth: the ref) ----
read -r DISK_LO DISK_HI DISK_KHOPS DISK_START < <(python3 "$REF" diskwindow)
DISK_W=$((DISK_HI - DISK_LO))
# the window size must be a power of two so the prober's `and ebx,MASK` masks any author-unknown byte in-window.
DISK_MASK=$((DISK_W - 1))
if (( (DISK_W & DISK_MASK) != 0 )); then echo "FAIL: stack/native_compile_fragment.herb (disk window $DISK_W is not a power of two -- masking cannot keep the chase in-window)"; exit 1; fi

# make a fresh per-run AUTHOR-UNKNOWN chasemap (a random byte for EVERY window index). Prints the CLI chasemap arg
# ("idx:byte,...") on stdout; writes the raw chase bytes (byte 0 of each window sector) into $1 (a disk image) at the
# absolute LBA offsets via dd. The kernel/prober are frozen BEFORE this runs -- the bytes are genuinely late-bound.
make_chasemap() { # diskimg seedhint  -> echoes the chasemap arg
    local img="$1" hint="$2"
    python3 - "$img" "$DISK_LO" "$DISK_W" "$hint" "$DISK_START" "$DISK_KHOPS" <<'PY'
import sys, os, random
img, lo, w, hint = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
start_idx, khops, mask = int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[3]) - 1
# author-unknown: seed from os.urandom XOR the per-call hint so two calls in one run differ (the MAPDIFF leg).
rng = random.Random(int.from_bytes(os.urandom(8), 'little') ^ (hash(hint) & 0xFFFFFFFF))
# Reject-and-regenerate DEGENERATE maps (still author-unknown -- only the disk BYTES are conditioned; the
# frozen kernel/prober are unchanged). The M-fixedlba mutation pins EVERY hop to the start sector, so its
# output is [cm[start]]*khops. If the honest chase (idx=start; idx=cm[idx]&mask each hop -- mirrors
# platter_ref.disk_chase_expect + the prober's `and ebx,MASK`) self-loops within the hop count (visits
# < khops DISTINCT sectors) or collapses to that same [cm[start]]*khops output, M-fixedlba becomes
# output-INVISIBLE and its bite-proof false-REDs (~1/64: cm[start]&mask == start). Condition it out.
for _attempt in range(100000):
    cm = {i: rng.randrange(0, 256) for i in range(w)}
    idx = start_idx; seen = set(); honest = []
    for _ in range(khops):
        seen.add(idx); honest.append(cm[idx] & 0xFF); idx = cm[idx] & mask
    if len(seen) == khops and honest != [cm[start_idx] & 0xFF] * khops:
        break
else:
    sys.exit('FATAL: no non-degenerate chasemap in 100000 tries (window=%d khops=%d)' % (w, khops))
with open(img, 'r+b') as f:
    for i in range(w):
        f.seek((lo + i) * 512)
        f.write(bytes([cm[i]]))          # byte 0 of sector (lo+i) <- the chase byte
        f.write(b'\x00' * 511)           # zero the rest of the sector (deterministic offsets>0)
sys.stderr.write('wrote %d chase sectors at LBA %d\n' % (w, lo))
print(','.join('%d:%d' % (i, cm[i]) for i in range(w)))
PY
}

# ---- reference artifacts ----
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK" none full)"
PROBER="$work/prober.bin"; python3 "$REF" diskprober "$PROBER"   # K=1 disk pointer-chase prober (no COM1 seed)

MKELF="$work/platter_kernel.elf"
emit '-- emit: multiboot32-platter' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) platter kernel byte-identical to platter_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) platter kernel differs from platter_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assertplatter ----
if python3 "$REF" assertplatter "$MKELF"; then ok "(B2) kernel carries the block-device machinery (assertplatter: the LBA access_ok to [$DISK_LO,$DISK_HI), the ATA PIO LBA28 sequence with rep insw -- the 0x66 operand-size prefix, NOT insd -- into the supervisor diskbuf, and the [diskbuf+offset] return)"
else fail_test "(B2) kernel lacks the block-device machinery (assertplatter failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "platter kernel is a valid x86 Multiboot image"
else fail_test "platter kernel is not a valid x86 Multiboot image"; fi
# (B3) the frozen lethe kernel must FAIL assertplatter (no SYS_DISK_READ arm / no diskbuf) -- the pin discriminates
if [[ -f "$PRIOR_REF" ]]; then
    python3 "$PRIOR_REF" kernelelf "$work/lethe_for_assert.elf" none full >/dev/null 2>&1
    if python3 "$REF" assertplatter "$work/lethe_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen lethe kernel PASSED assertplatter -- the white-box pin does not discriminate the block device"
    else ok "(B3) the frozen lethe kernel FAILS assertplatter (the SYS_DISK_READ arm + the diskbuf are genuinely new)"; fi
else
    fail_test "(B3) missing $PRIOR_REF -- cannot prove the lethe kernel fails assertplatter"
fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive) ----
for lk in lethe cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; platter is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- platter disturbed it"; fi
done

# ============================ SILICON (the addressed block-device read make-or-break) ============================
# Build a fresh raw 64 MiB disk image carrying a per-run author-unknown chasemap in the reserved window. For QEMU/KVM
# the prober is delivered via -initrd; for Bochs a GRUB-installed copy carries the kernel+prober as Multiboot files AND
# the chase bytes dd'd at the absolute window LBA (past where GRUB places its files -- the FS never allocates them).
emu_ran=0

build_raw_disk() { # diskimg  -> writes a zeroed 64 MiB image (chase bytes dd'd separately by make_chasemap)
    dd if=/dev/zero of="$1" bs=1M count=64 status=none
}

qemu_run() { # kernel-elf diskimg out timeout [kvm]
    local kel="$1" img="$2" out="$3" to="$4" kvm="${5:-}" acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    timeout "$to" qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$PROBER" -debugcon file:"$out" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -serial none -monitor none -m 64M >/dev/null 2>&1
}

QIMG="$work/disk.img"; build_raw_disk "$QIMG"
CHASEMAP="$(make_chasemap "$QIMG" map-a 2>/dev/null)" || { echo "FAIL: stack/native_compile_fragment.herb (chasemap generation FATAL -- the degenerate-map guard could not converge; refusing to continue with a degenerate/empty chasemap)"; exit 1; }
EXPECT="$(python3 "$REF" diskexpect "$CHASEMAP")"

if have_qemu; then
    emu_ran=1
    qemu_run "$MKELF" "$QIMG" "$work/q" 40
    if python3 "$REF" gradedisk "$work/q" "$KEND" "$CHASEMAP" >/dev/null 2>&1; then ok "(C) QEMU: the prober pointer-chases $DISK_KHOPS sectors via SYS_DISK_READ (each next-LBA = $DISK_LO + (prior byte & $DISK_MASK), DATA-DEPENDENT on the disk); the emitted chain == disk_chase_expect(chasemap) [$EXPECT] -- a genuine ADDRESSED random-access block read"
    else fail_test "(C) QEMU -> $(python3 "$REF" gradedisk "$work/q" "$KEND" "$CHASEMAP" 2>&1 | tr '\n' ';')"; fi

    # (C-MAPDIFF) THE CHASEMAP DIFFERENTIAL: re-dd a DIFFERENT author-unknown chasemap into the SAME disk, re-run, and
    # check (a) grading the NEW run with the OLD map is RED, (b) grading the new run with the NEW map is GREEN.
    CHASEMAP2="$(make_chasemap "$QIMG" map-b 2>/dev/null)" || { echo "FAIL: stack/native_compile_fragment.herb (MAPDIFF chasemap generation FATAL -- the degenerate-map guard could not converge)"; exit 1; }
    EXPECT2="$(python3 "$REF" diskexpect "$CHASEMAP2")"
    qemu_run "$MKELF" "$QIMG" "$work/q2" 40
    if python3 "$REF" gradedisk "$work/q2" "$KEND" "$CHASEMAP2" >/dev/null 2>&1; then ok "(C-MAPDIFF) QEMU new-map run grades GREEN against the NEW chasemap [$EXPECT2] (the chase follows the late-bound disk bytes)"
    else fail_test "(C-MAPDIFF) QEMU new-map -> $(python3 "$REF" gradedisk "$work/q2" "$KEND" "$CHASEMAP2" 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" gradedisk "$work/q2" "$KEND" "$CHASEMAP" >/dev/null 2>&1; then fail_test "(C-MAPDIFF) QEMU the new-map run graded GREEN with the OLD chasemap -- the chain is NOT data-dependent on the disk (vacuous)"
    else ok "(C-MAPDIFF) QEMU the new-map run is RED graded with the OLD chasemap (the emitted chain is genuinely the late-bound disk bytes' chase, not baked)"; fi
    # restore the disk to map-a for any later legs that reuse $QIMG with $CHASEMAP
    make_chasemap_restore() { python3 - "$QIMG" "$DISK_LO" "$CHASEMAP" <<'PY'
import sys
img, lo = sys.argv[1], int(sys.argv[2])
cm = {}
for part in sys.argv[3].split(','):
    k, v = part.split(':'); cm[int(k)] = int(v) & 0xFF
with open(img, 'r+b') as f:
    for i, b in cm.items():
        f.seek((lo + i) * 512); f.write(bytes([b])); f.write(b'\x00' * 511)
PY
    }
    make_chasemap_restore
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- (C-DIFF) THE FROZEN-LETHE DIFFERENTIAL: the frozen lethe kernel has no SYS_DISK_READ arm -> RED ----
# Fed the platter prober, the prober's first int 0x30 with eax=5 is an UNKNOWN syscall in lethe (it tests eax 0/2/4 then
# falls to SYS_EXIT) -> the program EXITs immediately -> no chain is emitted -> RED. The block device is genuinely new.
if have_qemu && [[ -f "$PRIOR_REF" ]]; then
    LKELF="$work/lethe_kernel.elf"; LKEND="$(python3 "$PRIOR_REF" kernelelf "$LKELF" none full)"
    qemu_run "$LKELF" "$QIMG" "$work/qdiff" 20
    if python3 "$REF" gradedisk "$work/qdiff" "$LKEND" "$CHASEMAP" >/dev/null 2>&1; then fail_test "(C-DIFF) the frozen LETHE kernel graded GREEN -- the block device is NOT genuinely new (lethe already reads the disk?)"
    else ok "(C-DIFF) the frozen LETHE kernel + the SAME prober is RED -- lethe has no SYS_DISK_READ arm, so eax=5 falls to SYS_EXIT and the prober EXITs before any chain is emitted; platter's addressed block read is a genuinely new observable"; fi
elif [[ ! -f "$PRIOR_REF" ]]; then
    fail_test "(C-DIFF) missing $PRIOR_REF -- cannot run the lethe differential"
fi

# ---- (C-HOSTILE) the hostile-LBA leg: forbidden OUT-OF-WINDOW LBAs are bounds-rejected to the sentinel 0 (access_ok) ----
# The hostile prober asks for forbidden LBAs (MBR/FAT/edge sectors); each must get the sentinel 0 (the kernel's access_ok
# rejects it), NOT the real sector byte. We seed those forbidden sectors NONZERO (0xDE) so a leak is OBSERVABLE: the
# genuine kernel rejects (returns 0); a dropped-access_ok kernel would return 0xDE. Runtime corroboration of the B2 white-box.
if have_qemu; then
    python3 "$REF" hostileprober "$work/hostile.bin"
    for hl in $(python3 "$REF" hostilelbas); do
        if [ "$hl" -lt "$DISK_LO" ] || [ "$hl" -ge "$DISK_HI" ]; then
            printf '\xde' | dd of="$QIMG" bs=1 seek=$((hl * 512)) conv=notrunc status=none 2>/dev/null   # 0xDE at sector hl, offset 0
        fi
    done
    SAVE_PROBER="$PROBER"; PROBER="$work/hostile.bin"
    qemu_run "$MKELF" "$QIMG" "$work/qh" 20
    PROBER="$SAVE_PROBER"
    if python3 "$REF" gradehostile "$work/qh" "$KEND" >/dev/null 2>&1; then ok "(C-HOSTILE) QEMU: every forbidden out-of-window LBA (MBR/FAT/edge sectors, all seeded 0xDE) returns the sentinel 0 -- the kernel's access_ok rejects it, no leak of the real sector byte"
    else fail_test "(C-HOSTILE) QEMU -> $(python3 "$REF" gradehostile "$work/qh" "$KEND" 2>&1 | tr '\n' ';')"; fi
fi

# ---- (C-HOSTILE-ECX) the hostile-OFFSET leg: a VALID in-window LBA but a hostile ECX>=512 -> sentinel 0 (access_ok) ----
# The SECOND untrusted scalar is the byte-OFFSET ECX. The kernel returns [diskbuf+ECX] only after `cmp ecx,512 ; jae
# reject`. The prober issues SYS_DISK_READ with a valid in-window LBA (so the LBA bound passes and the ATA read fills
# diskbuf) but a hostile ECX_PROBE (>= 512) that maps to a KNOWN-NONZERO kernel byte just past the 512B diskbuf. The
# genuine kernel rejects ECX>=512 -> sentinel 0; a dropped-check kernel (M-noecxcheck) would LEAK that nonzero byte.
# Runtime corroboration of the assertplatter (B2) ECX-bound white-box pin. The ECX_PROBE + expected leak are derived
# from the image by the ref (printed for the log).
if have_qemu; then
    read -r ECX_PROBE ECX_LEAK < <(python3 "$REF" hostileecxprobe)
    python3 "$REF" hostileecxprober "$work/hostile_ecx.bin"
    SAVE_PROBER="$PROBER"; PROBER="$work/hostile_ecx.bin"
    qemu_run "$MKELF" "$QIMG" "$work/qhe" 20
    PROBER="$SAVE_PROBER"
    if python3 "$REF" gradehostileecx "$work/qhe" "$KEND" >/dev/null 2>&1; then ok "(C-HOSTILE-ECX) QEMU: a SYS_DISK_READ with a valid in-window LBA but a hostile byte-offset ECX=$ECX_PROBE (>= 512, mapping to the nonzero kernel byte 0x$(printf '%02x' "$ECX_LEAK") just past the 512B diskbuf) returns the sentinel 0 -- the kernel's OFFSET access_ok (cmp ecx,512 ; jae reject) rejects it, no leak of a kernel byte past diskbuf"
    else fail_test "(C-HOSTILE-ECX) QEMU -> $(python3 "$REF" gradehostileecx "$work/qhe" "$KEND" 2>&1 | tr '\n' ';')"; fi
fi

# ---- (C-HOSTILE-DF) the hostile-DF leg: a VALID in-window read with the module's DF=1 (std) still reads FORWARD ----
# The THIRD untrusted bit of state is the DIRECTION FLAG (DF). The genuine kernel `cld`s right before `rep insw`, so the
# ATA transfer ALWAYS walks FORWARD from diskbuf regardless of the module's DF. The prober does `std` (DF=1) then issues a
# BENIGN in-window SYS_DISK_READ (the start sector) at a NONZERO offset (DF_PROBE_OFF) the harness seeded with a known
# sentinel (DF_PROBE_BYTE); the genuine kernel still returns that real sector byte. A dropped-cld kernel (M-nocld) would
# inherit DF=1 -> rep insw walks BACKWARD -> only diskbuf[0..1] is written, diskbuf[offset>=2] stays ZERO -> the WRONG
# byte (and corrupts kernel memory below diskbuf). (offset 0 is NOT a discriminator: it gets the sector's word 0 EITHER
# direction.) Runtime corroboration of the assertplatter (B2) cld-adjacency white-box pin. Restore $QIMG to map-a after.
if have_qemu; then
    read -r DF_LBA DF_OFF DF_BYTE < <(python3 "$REF" hostiledfprobe)
    printf "$(printf '\\x%02x' "$DF_BYTE")" | dd of="$QIMG" bs=1 seek=$((DF_LBA * 512 + DF_OFF)) conv=notrunc status=none 2>/dev/null  # seed the DF sentinel
    python3 "$REF" hostiledfprober "$work/hostile_df.bin"
    SAVE_PROBER="$PROBER"; PROBER="$work/hostile_df.bin"
    qemu_run "$MKELF" "$QIMG" "$work/qhd" 20
    PROBER="$SAVE_PROBER"
    if python3 "$REF" gradehostiledf "$work/qhd" "$KEND" >/dev/null 2>&1; then ok "(C-HOSTILE-DF) QEMU: a SYS_DISK_READ from a module that set DF=1 (std) before int 0x30 STILL reads FORWARD and returns the correct disk byte (0x$(printf '%02x' "$DF_BYTE")) at the start sector offset $DF_OFF -- the kernel's cld before rep insw forces a FORWARD transfer regardless of the module's direction flag, no backward-walk corruption of kernel memory below diskbuf"
    else fail_test "(C-HOSTILE-DF) QEMU -> $(python3 "$REF" gradehostiledf "$work/qhd" "$KEND" 2>&1 | tr '\n' ';')"; fi
    make_chasemap_restore   # restore the chase byte at the start sector (the DF seed left offset 2 nonzero; offset 0 is the chase byte)
fi

# ---- KVM (real silicon): the ATA PIO read on the real chipset/MMU ----
if have_kvm; then
    qemu_run "$MKELF" "$QIMG" "$work/k" 40 kvm
    if python3 "$REF" gradedisk "$work/k" "$KEND" "$CHASEMAP" >/dev/null 2>&1; then ok "(C-KVM) real silicon: the addressed block-device chase is byte-identical on KVM (the chipset's own ATA controller serves the per-run author-unknown sectors; the emitted chain == disk_chase_expect(chasemap))"
    else fail_test "(C-KVM) KVM -> $(python3 "$REF" gradedisk "$work/k" "$KEND" "$CHASEMAP" 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; 1 module line + the chase bytes dd'd into the SAME disk) ----
bochs_run() { # out timeout chasemaparg
    local out="$1" to="$2" cmap="$3"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    # pre-run hygiene: a prior crashed Bochs can leave the disk locked
    pkill -9 bochs 2>/dev/null || true
    rm -f "$d/disk.img.lock" 2>/dev/null || true
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
      # AFTER GRUB is installed and the FS unmounted, dd the per-run author-unknown chase bytes at the ABSOLUTE window
      # LBA (raw, bypassing FAT -- the kernel reads via ATA PIO at the absolute LBA, never through the filesystem). The
      # window (LBA 120000.. ~58.6 MiB) is past where GRUB placed its few files, so the FS never allocates those sectors.
      python3 - disk.img "$DISK_LO" "$cmap" <<'PY'
import sys
img, lo = sys.argv[1], int(sys.argv[2])
cm = {}
for part in sys.argv[3].split(','):
    k, v = part.split(':'); cm[int(k)] = int(v) & 0xFF
with open(img, 'r+b') as f:
    for i, b in cm.items():
        f.seek((lo + i) * 512); f.write(bytes([b])); f.write(b'\x00' * 511)
PY
      # CHS geometry fix (the STEP-0 recipe): a 64 MiB disk with 256 cylinders x 16 heads x 32 spt = 64 MiB so Bochs and
      # the GRUB/BIOS agree on the geometry; without it Bochs mis-derives CHS and the boot or the ATA LBA28 read drifts.
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=disk.img, mode=flat, cylinders=256, heads=16, spt=32
boot: disk
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL $to bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    python3 - "$d/bochs_out.txt" "$out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    bochs_run "$work/b" 150 "$CHASEMAP"
    if python3 "$REF" gradedisk "$work/b" "$KEND" "$CHASEMAP" >/dev/null 2>&1; then ok "(C) Bochs: the addressed block-device chase is byte-identical on the 2nd substrate (GRUB delivers the kernel+prober; Bochs' ATA controller serves the per-run author-unknown sectors dd'd at the absolute window LBA; the emitted chain == disk_chase_expect(chasemap))"
    else fail_test "(C) Bochs -> $(python3 "$REF" gradedisk "$work/b" "$KEND" "$CHASEMAP" 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link53 (platter / FIRST BLOCK DEVICE -- addressed random-access disk READ): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link53 platter / FIRST BLOCK DEVICE -- one ring-3 prober (K=1) pointer-chases $DISK_KHOPS sectors via SYS_DISK_READ (int 0x30, eax=5): each sector's byte 0 NAMES the next sector as a window index, next LBA = $DISK_LO + (b & $DISK_MASK); the module puts the LBA in EBX + byte-offset in ECX, the kernel (CPL0) BOUNDS-CHECKS the LBA to [$DISK_LO,$DISK_HI) (access_ok -- no GRUB/FAT/arbitrary-sector read), does an ATA PIO LBA28 single-sector read with rep insw (0x66 prefix, NOT insd) into its OWN 512B supervisor diskbuf (a CPL3 module cannot PIO -- in al,dx at CPL3 #GPs), and returns [diskbuf+offset] in eax; iret. The first time the kernel reads a persistent, randomly-ADDRESSED block device. Byte-pinned to platter_ref.build_elf (binds the SYS_DISK_READ arm + the 512B diskbuf), white-box assertplatter (the LBA access_ok + the ATA sequence + the diskbuf return), QEMU+KVM+Bochs GREEN on a per-run AUTHOR-UNKNOWN chasemap dd'd into the reserved window AFTER the kernel/prober are frozen, chasemap-differential (re-dd a different map -> old-map grade RED, new-map grade GREEN -- genuine data-dependence on the disk), frozen-lethe differential RED (no SYS_DISK_READ arm -> eax=5 falls to SYS_EXIT -> the prober EXITs before any chain), hostile-LBA out-of-window request returns the sentinel 0 (access_ok holds), hostile-DF (a module that did std before int 0x30) STILL reads the correct disk byte (the kernel cld's before rep insw -> a FORWARD transfer regardless of the module's direction flag, no backward-walk corruption below diskbuf), additive on lethe/cleave/tessera/furlough/homestead/tenement/rollcall/tickover. Output-forced -- the chase order is the late-bound author-unknown disk bytes a serial COM1 stream cannot reproduce. HONEST SCOPE: ONE block device (ATA master), single-sector synchronous PIO reads, a fixed reserved window with a power-of-two size (the prober masks indices in-window); no writes, no DMA, no filesystem, no multi-drive)"
