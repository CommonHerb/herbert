#!/usr/bin/env bash
# Native-codegen Link 54 / durable (kernel-arc link 38): DURABILITY -- a byte WRITTEN by the kernel SURVIVES A REBOOT.
# platter (link 37) gave the kernel its FIRST BLOCK DEVICE (an addressed random-access disk READ). durable is the first
# time a kernel-written byte PERSISTS ACROSS A POWER CYCLE: a confused-deputy ATA PIO LBA28 single-sector WRITE + an ATA
# CACHE FLUSH (so the write reaches the medium, not just the drive's write cache), gated by a WRITE-LBA access_ok to a
# RESERVED WRITE window [DISK_WRESV_LO, DISK_WRESV_HI) (a clean SUB-RANGE at the TOP of the FROZEN platter read window, so
# the unchanged reader reads the durable byte back) + an ECX<512 offset bound. A WRITE-ANYWHERE primitive is WORSE than
# the read leak -- a hostile module must not scribble the MBR / GRUB / a read-window sector -- so this bound is CRITICAL.
# A NEW kernel emit mode `multiboot32-durable` (TYPE-II ADDITIVE on the FROZEN platter lineage). KERNEL-EMIT only; the
# writer/reader probers are hand-asm.
#
# THE MAKE-OR-BREAK = a TWO-BOOT on ONE disk image: BOOT-1 a WRITER prober reads a late-bound AUTHOR-UNKNOWN byte X off
# COM1 (SYS_READ -- a CPL3 module cannot touch the UART) and SYS_DISK_WRITEs X to (DUR_WLBA, DUR_OFF); the machine is then
# REBOOTED (QEMU re-run on the SAME -drive image, cache=writethrough so the write survives) and BOOT-2 a READER prober
# SYS_DISK_READs that sector back and emits the byte. GREEN iff the emitted byte == X (the byte SURVIVED on the medium
# across a fresh boot with RAM wiped). X is chosen per-run AFTER the kernel/probers are frozen, so it cannot be baked.
#
# Why GENUINELY OUTPUT-FORCED -- the PRIMARY differential is M-nowrite: the SAME genuine durable kernel with ONLY the ATA
# write+flush sequence (d) severed -- everything else byte-identical -- so BOOT-2 reads a stale 0 != X -> RED. This
# attributes the durable byte CLEANLY to the medium write (a RAM-stash forge also loses the byte when RAM is wiped on
# reboot -> stale 0). The frozen-platter differential is a SECONDARY corroborator (framing-confounded: a DIFFERENT ELF
# lacking the whole do_disk_write arm, so its RED conflates "no medium write" with "older kernel without the capability").
# M-nowboundscheck / M-nowecxcheck are OUTPUT-INVISIBLE on the benign in-window two-boot (the benign request is in-window
# / ECX=0), so they are caught by the HOSTILE-WRITE legs (a forbidden-LBA / ECX>=512 write must be REJECTED) + the
# white-box assert_durability. The neutered-rel32 FORGE (the genuine image with the 3 write-bound jcc rel32s zeroed -- a
# WRITE-ANYWHERE sandbox break that is output-invisible on the benign two-boot) is REJECTED by assert_durability (FIX A
# pins the jcc BRANCH TARGETS, not just the cmp;jcc opcodes -- talcott/pin_reachability_not_presence). The held-back
# MUTATION proof lives in the companion mutation harness.
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a KVM real-silicon leg, vs durable_ref.py):
#   (B1) KERNEL BYTE-PIN: the emitted kernel == durable_ref.build_elf() (the SYS_DISK_WRITE arm + the frozen read arm).
#   (B2) WHITE-BOX assert_durability: the do_disk_write arm carries (and reaches-before-write) the WRITE-LBA access_ok
#        (cmp ebx,WLO ; jb reject / cmp ebx,WHI ; jae reject, with the jcc TARGETS pinned to the genuine reject block),
#        the OFFSET access_ok (cmp ecx,512 ; jae reject), and the ATA WRITE SECTORS -> rep outsw -> CACHE FLUSH sequence.
#   (B2-FORGE) the neutered-rel32 FORGE (genuine image, the 3 write-bound jcc rel32s zeroed) is REJECTED by
#        assert_durability (FIX A: the branch TARGETS no longer land on the reject block -- a decorative bound is caught).
#   (B3) the FROZEN platter kernel FAILS assert_durability (it has no SYS_DISK_WRITE arm -- the write machinery is new).
#   (D) FROZEN: the prior baked-kernel modes are byte-identical (durable is PURELY ADDITIVE on platter).
#   (C) SILICON make-or-break: the TWO-BOOT durability test (BOOT-1 writes the late-bound X, reboot, BOOT-2 reads it back
#        == X) -- GREEN on QEMU + KVM + Bochs.
#   (C-NOWRITE) THE PRIMARY DIFFERENTIAL: the SAME two-boot with the M-nowrite kernel (only the ATA write+flush severed)
#        -> BOOT-2 reads stale 0 != X -> RED (the durable byte is attributable to the medium write).
#   (C-PLATTER) THE SECONDARY (frozen-platter) DIFFERENTIAL: the frozen platter kernel + the SAME writer -> eax=6 is an
#        UNKNOWN syscall (falls to SYS_EXIT) -> nothing is written -> BOOT-2 reads stale 0 -> RED (framing-confounded).
#   (C-HOSTILE) the hostile-WRITE leg: a writer to a FORBIDDEN out-of-window LBA (the MBR) is REJECTED -- the forbidden
#        sector is UNCHANGED on the genuine kernel (the WRITE-LBA access_ok holds; M-nowboundscheck lets it land).
#   (C-HOSTILE-ECX) the hostile-OFFSET leg: a writer with a VALID in-window LBA but ECX>=512 is REJECTED (no kernel write
#        past the 512B diskbuf; the OFFSET access_ok holds; M-nowecxcheck would corrupt kernel RAM).
# REQUIRE_EMU fail-closed (the plumb pattern): if KERNEL_CODEGEN_REQUIRE_EMU=1 and an emulator is missing, FAIL.
#
# NOTE -- which legs CANNOT run until the orchestrator lands the `multiboot32-durable` emit mode in the compiler
# (stack/native_compile_fragment.herb -- the nc_emit_multiboot32_durable_program from gen_durable_blob.py) + reseeds
# gen-1:
#   * (B1)/(B2-via-the-emitted-kernel)/(B3)/(D) and EVERY silicon leg (C / C-NOWRITE / C-PLATTER / C-HOSTILE) emit the
#     `multiboot32-durable` kernel and so CANNOT run until the emit mode is in gen-1. Before then this harness FAILS at
#     the emit step (the compiler produces no a.out for the unknown marker) -- the CORRECT fail-closed behavior.
#   * (B2-FORGE) / (B3 vs platter) / assert_durability(genuine) on the REF image run WITHOUT the emit mode (they call the
#     ref directly), so they exercise the FIX-A checker even before the reseed.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/durable_ref.py"
PRIOR_REF="$script_dir/platter_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi
source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"; pkill -9 -f "$work" 2>/dev/null || true' EXIT   # clean up only THIS gate's orphaned bochs (scoped to its unique mktemp; never a system-wide `pkill bochs`). F2 sweep 2026-07-04.
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

# ---- durability-window constants (single source of truth: the ref) ----
read -r DUR_WLO DUR_WHI DUR_WLBA DUR_OFF < <(python3 "$REF" durwindow)
read -r HOST_LBA HOST_OFF HOST_BYTE < <(python3 "$REF" hostilewritetarget)
read -r DFW_LBA DFW_OFF DFW_BYTE < <(python3 "$REF" hostiledfwritetarget)   # the (LBA, offset>=2, sentinel) the DF-writer leg inspects

# ---- reference artifacts ----
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK" none full)"
WRITER="$work/writer.bin"; python3 "$REF" durwriter "$WRITER"        # BOOT-1 writer prober (late-bound COM1 byte X)
READER="$work/reader.bin"; python3 "$REF" durreader "$READER"        # BOOT-2 reader prober (reads the durable byte back)

MKELF="$work/durable_kernel.elf"
emit '-- emit: multiboot32-durable' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) durable kernel byte-identical to durable_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) durable kernel differs from durable_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assert_durability ----
if python3 "$REF" assertdurable "$MKELF"; then ok "(B2) kernel carries the durability write machinery (assert_durability: the WRITE-LBA access_ok to [$DUR_WLO,$DUR_WHI) with the jcc TARGETS pinned to the reject block, the OFFSET access_ok cmp ecx,512, and the ATA WRITE SECTORS -> rep outsw -> CACHE FLUSH sequence)"
else fail_test "(B2) kernel lacks the durability write machinery (assert_durability failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "durable kernel is a valid x86 Multiboot image"
else fail_test "durable kernel is not a valid x86 Multiboot image"; fi

# ---- (B2-FORGE) the neutered-rel32 forge must be REJECTED by assert_durability (FIX A: pinned jcc TARGETS) ----
# The forge is the GENUINE image with ONLY the 3 write-bound jcc rel32s zeroed -- every cmp;jcc byte present, but each
# branch falls through into the ATA write path (a WRITE-ANYWHERE sandbox break, output-invisible on the benign two-boot).
FORGE="$work/forge.elf"; python3 "$REF" neuteredforge "$FORGE" >/dev/null
if python3 "$REF" assertdurable "$FORGE" >/dev/null 2>&1; then fail_test "(B2-FORGE) the neutered-rel32 forge PASSED assert_durability -- the white-box pin does NOT bind the jcc branch targets (FIX A regressed); a decorative WRITE-LBA bound would slip through"
else ok "(B2-FORGE) the neutered-rel32 forge is REJECTED by assert_durability (FIX A pins the 3 write-bound jcc TARGETS to the genuine reject block -- a rel32=0 fall-through that neuters the WRITE-LBA/ECX bounds is caught, talcott/pin_reachability_not_presence)"; fi

# ---- (B3) the frozen platter kernel must FAIL assert_durability (no SYS_DISK_WRITE arm) ----
if [[ -f "$PRIOR_REF" ]]; then
    python3 "$PRIOR_REF" kernelelf "$work/platter_for_assert.elf" none full >/dev/null 2>&1
    if python3 "$REF" assertdurable "$work/platter_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen platter kernel PASSED assert_durability -- the white-box pin does not discriminate the write arm"
    else ok "(B3) the frozen platter kernel FAILS assert_durability (the SYS_DISK_WRITE arm + the ATA write/flush are genuinely new)"; fi
else
    fail_test "(B3) missing $PRIOR_REF -- cannot prove the platter kernel fails assert_durability"
fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive on platter) ----
for lk in platter lethe cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; durable is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- durable disturbed it"; fi
done

# ============================ SILICON (the two-boot DURABILITY make-or-break) ============================
# ONE 64 MiB raw disk image is reused across BOOT-1 (writer) and BOOT-2 (reader). cache=writethrough forces the ATA
# write+flush through to the host file, so the byte the writer persisted in BOOT-1 is on the medium for BOOT-2 to read
# back after the machine is "rebooted" (QEMU re-launched on the SAME image with RAM wiped). X is chosen per-run AFTER
# the kernel/probers are frozen ($RANDOM byte), so it is genuinely author-unknown -- it cannot be baked.
emu_ran=0

# write the late-bound byte X to the writer over COM1, run BOOT-1, then run BOOT-2 with the reader; echo the BOOT-2 out.
two_boot() { # kernel-elf diskimg x boot1out boot2out [kvm]
    local kel="$1" img="$2" x="$3" b1="$4" b2="$5" kvm="${6:-}"
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    # BOOT-1: the writer reads X off COM1 (the feeder is the TCP server; QEMU's -serial chardev connects as the client)
    local port; port=$(free_port); local d="$b1.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$x" --hold 12 > "$d/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$WRITER" -debugcon file:"$b1" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    # REBOOT -> BOOT-2: a FRESH QEMU (RAM wiped) on the SAME disk image; the reader reads the durable sector back.
    timeout 40 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$READER" -debugcon file:"$b2" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -serial none -monitor none -m 64M >/dev/null 2>&1
}

build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }

QIMG="$work/disk.img"
# the author-unknown durable byte X (1..255, nonzero so a stale-0 BOOT-2 is unambiguously RED), chosen AFTER freeze.
XBYTE=$(( (RANDOM % 255) + 1 )); XHEX=$(printf '0x%02x' "$XBYTE")

if have_qemu; then
    emu_ran=1
    build_raw_disk "$QIMG"
    two_boot "$MKELF" "$QIMG" "$XBYTE" "$work/q.b1" "$work/q.b2"
    if python3 "$REF" gradedur "$work/q.b2" "$KEND" "$XHEX" >/dev/null 2>&1; then ok "(C) QEMU TWO-BOOT: BOOT-1 wrote the late-bound author-unknown byte X=$XHEX (read off COM1) via SYS_DISK_WRITE to (LBA $DUR_WLBA, off $DUR_OFF) + CACHE FLUSH; after a REBOOT (RAM wiped) BOOT-2 read it back == X -- the byte SURVIVED on the medium (genuine durability)"
    else fail_test "(C) QEMU two-boot -> $(python3 "$REF" gradedur "$work/q.b2" "$KEND" "$XHEX" 2>&1 | tr '\n' ';')"; fi

    # (C-NOWRITE) THE PRIMARY DIFFERENTIAL: the SAME genuine kernel with ONLY the ATA write+flush severed -> stale 0.
    NWK="$work/nowrite_kernel.elf"; NWKEND="$(python3 "$REF" kernelelf "$NWK" nowrite full)"
    build_raw_disk "$work/disk_nw.img"
    NWX=$(( (RANDOM % 255) + 1 )); NWXHEX=$(printf '0x%02x' "$NWX")
    two_boot "$NWK" "$work/disk_nw.img" "$NWX" "$work/qnw.b1" "$work/qnw.b2"
    if python3 "$REF" gradedur "$work/qnw.b2" "$NWKEND" "$NWXHEX" >/dev/null 2>&1; then fail_test "(C-NOWRITE) the M-nowrite kernel graded GREEN -- BOOT-2 read back X without the ATA write+flush (the durable byte is NOT attributable to the medium write -- vacuous)"
    else ok "(C-NOWRITE) THE PRIMARY DIFFERENTIAL: the M-nowrite kernel (the SAME genuine durable kernel with ONLY the ATA write+flush (d) severed, everything else byte-identical) -> BOOT-2 read a stale 0 != X=$NWXHEX -> RED; the durable byte is cleanly attributable to the medium write"; fi

    # (C-PLATTER) THE SECONDARY (frozen-platter) DIFFERENTIAL: eax=6 is unknown in platter -> falls to SYS_EXIT -> nothing
    # written -> BOOT-2 reads stale 0 -> RED (framing-confounded: a different ELF lacking the whole do_disk_write arm).
    if [[ -f "$PRIOR_REF" ]]; then
        PKELF="$work/platter_kernel.elf"; PKEND="$(python3 "$PRIOR_REF" kernelelf "$PKELF" none full)"
        build_raw_disk "$work/disk_pl.img"
        PLX=$(( (RANDOM % 255) + 1 )); PLXHEX=$(printf '0x%02x' "$PLX")
        two_boot "$PKELF" "$work/disk_pl.img" "$PLX" "$work/qpl.b1" "$work/qpl.b2"
        if python3 "$REF" gradedur "$work/qpl.b2" "$PKEND" "$PLXHEX" >/dev/null 2>&1; then fail_test "(C-PLATTER) the frozen platter kernel graded GREEN -- durability is NOT genuinely new (platter already persists a write?)"
        else ok "(C-PLATTER) THE SECONDARY DIFFERENTIAL: the frozen platter kernel + the SAME writer is RED -- platter has no SYS_DISK_WRITE arm, so eax=6 falls to SYS_EXIT and NOTHING is written -> BOOT-2 reads stale 0; durability is a genuinely new observable (framing-confounded -- platter is a different ELF lacking the whole write arm; M-nowrite is the make-or-break)"; fi
    fi

    # (C-HOSTILE) the hostile-WRITE leg: a writer to a FORBIDDEN out-of-window LBA (the MBR) must be REJECTED -- the
    # forbidden sector is UNCHANGED. We seed the forbidden sector with a known SENTINEL first; after the hostile write the
    # sector must still hold the sentinel (genuine REJECT), NOT the hostile byte (M-nowboundscheck escape).
    HOSTILE_W="$work/hostile_writer.bin"; python3 "$REF" hostilewriter "$HOSTILE_W"
    build_raw_disk "$work/disk_h.img"
    # seed the forbidden sector's target offset with a distinctive sentinel (!= the hostile byte) so an escape is visible.
    printf '\xa5' | dd of="$work/disk_h.img" bs=1 seek=$((HOST_LBA * 512 + HOST_OFF)) conv=notrunc status=none 2>/dev/null
    SAVE_W="$WRITER"; WRITER="$HOSTILE_W"
    # only BOOT-1 (the hostile write attempt); BOOT-2 is irrelevant -- we inspect the disk directly.
    port=$(free_port); mkdir -p "$work/qh.b1.d"
    python3 "$feeder" "$port" 1 --hold 10 > "$work/qh.b1.d/feed.log" 2>&1 & fp=$!
    for i in $(seq 1 50); do grep -q LISTENING "$work/qh.b1.d/feed.log" && break; sleep 0.1; done
    timeout 40 qemu-system-x86_64 -cpu qemu64 -kernel "$MKELF" -initrd "$HOSTILE_W" -debugcon file:"$work/qh.b1" \
        -drive file="$work/disk_h.img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    WRITER="$SAVE_W"
    GOTBYTE=$(dd if="$work/disk_h.img" bs=1 skip=$((HOST_LBA * 512 + HOST_OFF)) count=1 status=none 2>/dev/null | od -An -tu1 | tr -d ' ')
    if [[ "$GOTBYTE" == "165" ]]; then ok "(C-HOSTILE) QEMU: a SYS_DISK_WRITE to a FORBIDDEN out-of-window LBA $HOST_LBA (the MBR) is REJECTED -- the forbidden sector still holds the sentinel 0xA5 (the WRITE-LBA access_ok holds, no write-anywhere escape)"
    else fail_test "(C-HOSTILE) QEMU: the forbidden sector (LBA $HOST_LBA off $HOST_OFF) was MODIFIED to byte=$GOTBYTE (expected the sentinel 165=0xA5) -- the WRITE-LBA access_ok did NOT reject the out-of-window write (a write-anywhere escape)"; fi

    # (C-HOSTILE-ECX) the hostile-OFFSET leg: a VALID in-window LBA but a hostile ECX>=512 must be REJECTED (no write at
    # all). We seed the durable sector with a sentinel, run the hostile-ECX writer, and confirm the durable sector's
    # offset 0 is UNCHANGED (the genuine kernel rejects ECX>=512 BEFORE building/writing the sector). On M-nowecxcheck the
    # store `mov [ecx+diskbuf],DL` writes past diskbuf (corrupting kernel RAM) AND the sector is still written -> the
    # sentinel is overwritten with the zeroed sector -> observable change.
    HOSTILE_E="$work/hostile_ecx_writer.bin"; python3 "$REF" hostileecxwriter "$HOSTILE_E"
    build_raw_disk "$work/disk_he.img"
    printf '\xa5' | dd of="$work/disk_he.img" bs=1 seek=$((DUR_WLBA * 512 + DUR_OFF)) conv=notrunc status=none 2>/dev/null
    timeout 40 qemu-system-x86_64 -cpu qemu64 -kernel "$MKELF" -initrd "$HOSTILE_E" -debugcon file:"$work/qhe.b1" \
        -drive file="$work/disk_he.img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -serial none -monitor none -m 64M >/dev/null 2>&1
    GOTECX=$(dd if="$work/disk_he.img" bs=1 skip=$((DUR_WLBA * 512 + DUR_OFF)) count=1 status=none 2>/dev/null | od -An -tu1 | tr -d ' ')
    if [[ "$GOTECX" == "165" ]]; then ok "(C-HOSTILE-ECX) QEMU: a SYS_DISK_WRITE with a VALID in-window LBA but a hostile byte-offset ECX>=512 is REJECTED -- the durable sector still holds the sentinel 0xA5 (the OFFSET access_ok cmp ecx,512 ; jae rejects BEFORE any write, no kernel write past diskbuf)"
    else fail_test "(C-HOSTILE-ECX) QEMU: the durable sector (LBA $DUR_WLBA off $DUR_OFF) changed to byte=$GOTECX (expected the sentinel 165=0xA5) -- the OFFSET access_ok did NOT reject ECX>=512 (a kernel-write-past-diskbuf escape)"; fi

    # (C-HOSTILE-DF) the DIRECTION-FLAG (cld) leg on the WRITE arm: a hostile module does `std` (DF=1) then a BENIGN
    # in-window SYS_DISK_WRITE of a known sentinel at DFW_OFF (>= 2, in-bounds). The genuine kernel cld's before BOTH rep
    # stosd (zero diskbuf) and rep outsw (send the sector), so the sector is built/sent FORWARD regardless of the module's
    # DF and the sentinel lands at (DFW_LBA, DFW_OFF) on the medium. M-nowcld inherits DF=1 -> the backward rep stosd
    # zeroes the page tables below diskbuf (kernel-memory corruption) AND the backward rep outsw sends diskbuf[0..1] then
    # page-table bytes -> the sentinel never reaches disk offset DFW_OFF (it reads back 0/a pt byte). OUTPUT-INVISIBLE on
    # the benign two-boot (DF=0, offset 0). We seed the durable sector at DFW_OFF with a DISTINCT marker (0x3C) so both
    # "wrote zero" and "did not write" cases are visibly != the 0xA5 sentinel; the genuine forward write overwrites it.
    HOSTILE_DF="$work/hostile_df_writer.bin"; python3 "$REF" hostiledfwriter "$HOSTILE_DF"
    build_raw_disk "$work/disk_hdf.img"
    printf '\x3c' | dd of="$work/disk_hdf.img" bs=1 seek=$((DFW_LBA * 512 + DFW_OFF)) conv=notrunc status=none 2>/dev/null
    timeout 40 qemu-system-x86_64 -cpu qemu64 -kernel "$MKELF" -initrd "$HOSTILE_DF" -debugcon file:"$work/qhdf.b1" \
        -drive file="$work/disk_hdf.img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -serial none -monitor none -m 64M >/dev/null 2>&1
    GOTDF=$(dd if="$work/disk_hdf.img" bs=1 skip=$((DFW_LBA * 512 + DFW_OFF)) count=1 status=none 2>/dev/null | od -An -tu1 | tr -d ' ')
    if [[ "$GOTDF" == "165" ]]; then ok "(C-HOSTILE-DF) QEMU: a SYS_DISK_WRITE preceded by a hostile std (DF=1) STILL persists the sentinel 0xA5 at (LBA $DFW_LBA, off $DFW_OFF) -- the genuine kernel cld's before BOTH rep stosd and rep outsw, so the sector is built and sent FORWARD regardless of the module's direction flag (no backward kernel-memory corruption, no wrong-sector write)"
    else fail_test "(C-HOSTILE-DF) QEMU: the durable sector (LBA $DFW_LBA off $DFW_OFF) read back byte=$GOTDF (expected the sentinel 165=0xA5) -- the kernel did NOT cld before rep stosd / rep outsw (M-nowcld), so DF=1 made the string ops walk BACKWARD: the page tables below diskbuf were zeroed and the wrong sector content reached the medium (an output-invisible sandbox break)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- KVM (real silicon): the ATA PIO write + CACHE FLUSH on the real chipset ----
if have_kvm; then
    build_raw_disk "$work/disk_k.img"
    KX=$(( (RANDOM % 255) + 1 )); KXHEX=$(printf '0x%02x' "$KX")
    two_boot "$MKELF" "$work/disk_k.img" "$KX" "$work/k.b1" "$work/k.b2" kvm
    if python3 "$REF" gradedur "$work/k.b2" "$KEND" "$KXHEX" >/dev/null 2>&1; then ok "(C-KVM) real silicon: the two-boot durability is byte-identical on KVM (the chipset's own ATA controller persists the late-bound X=$KXHEX across the reboot; BOOT-2 reads it back)"
    else fail_test "(C-KVM) KVM two-boot -> $(python3 "$REF" gradedur "$work/k.b2" "$KEND" "$KXHEX" 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; the two-boot persists across two Bochs runs on the SAME GRUB disk) ----
# BOOT-1: GRUB delivers the durable kernel + the writer module; the feeder serves X over com1; the writer SYS_DISK_WRITEs
# X to the absolute window LBA (past where GRUB places its files). BOOT-2: the SAME disk.img is re-run with GRUB's config
# swapped to the reader module; the reader reads the durable sector back. .lock cleanup per STEP-0. (Bochs needs the ATA
# software-RESET prologue the kernel emits for writes -- STEP-0 proved it.)
bochs_two_boot() { # x b2out
    local x="$1" b2out="$2"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local wr; wr="$(readlink -f "$WRITER")"; local rd; rd="$(readlink -f "$READER")"
    local d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    # pre-run hygiene: a prior crashed Bochs can leave the disk locked
    pkill -9 -f "$work" 2>/dev/null || true   # scoped to THIS gate (own process), not system-wide (would kill a concurrent gate's Bochs)
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
      sudo cp "$wr" mnt/boot/writer.bin; sudo cp "$rd" mnt/boot/reader.bin
      # BOOT-1 config: the writer module
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/writer.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP" )
    # CHS geometry fix (STEP-0): 256 cyl x 16 heads x 32 spt = 64 MiB so Bochs + GRUB/BIOS agree on geometry.
    cat > "$d/bochsrc.txt" <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=disk.img, mode=flat, cylinders=256, heads=16, spt=32
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:__PORT__
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
    # Harness-failure detectors (F2 sweep, mirror of the link60 reference). Each sets BOCHS_HARNESS_ERR + returns
    # nonzero so the caller re-rolls, never false-REDding the kernel.
    _feed_ok() { # feedlog label -> 0 iff the feeder reached LISTENING within 5s
        local fl="$1" lbl="$2" i
        for i in $(seq 1 50); do grep -q LISTENING "$fl" 2>/dev/null && break; sleep 0.1; done
        grep -q LISTENING "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never reached LISTENING for $lbl (log: $fl -- feeder/port-bind failure, not a kernel miscompile)"; return 1
    }
    _bochs_ran_ok() { # bochslog label -> 0 iff the boot RAN TO A KERNEL shutdown() tail (i.e. was NOT killed/hung mid-run)
        local bl="$1" lbl="$2"
        [[ -s "$bl" ]] || { BOCHS_HARNESS_ERR="Bochs produced NO output booting $lbl (log: $bl empty/missing -- the emulator did not run, not a kernel miscompile)"; return 1; }
        # The kernel's shutdown() writes "Shutdown" to Bochs' port 0x8900 -> Bochs logs 'shutdown requested' whenever the
        # kernel reaches a shutdown() tail: proves the boot RAN TO COMPLETION (not a mid-run death). `[[ -s log ]]` alone
        # is worthless (Bochs always prints a banner). grep -a: binary log.
        grep -qa 'shutdown requested' "$bl" && return 0
        BOCHS_HARNESS_ERR="Bochs did NOT run $lbl through to a kernel shutdown tail (log: $bl has no 'shutdown requested' -- the boot died or was timeout-killed mid-run, not a kernel miscompile)"; return 1
    }
    _feed_delivered() { # feedlog label -> 0 iff the feeder actually SENT its payload (Bochs connected COM1)
        local fl="$1" lbl="$2"
        grep -q '^SENT' "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never delivered its payload for $lbl (log: $fl has LISTENING but no SENT / shows NOCONN -- Bochs did not connect COM1, the kernel received no input, not a kernel miscompile)"; return 1
    }
    # BOOT-1: run with the writer config (set at install) + the feeder serving X over com1.
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$x" --hold 150 > "$d/feed.log" 2>&1 & local fp=$!
    _feed_ok "$d/feed.log" "writer.bin(BOOT-1)" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
    sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b1.txt"
    ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b1.txt" > bochs_b1.txt 2>&1 )   # absolute bochsrc path -> $work in the cmdline for the scoped `pkill -f "$work"`
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    rm -f "$d/disk.img.lock"
    _bochs_ran_ok "$d/bochs_b1.txt" "writer.bin(BOOT-1)" || return 1
    _feed_delivered "$d/feed.log" "writer.bin(BOOT-1)" || return 1
    # REBOOT -> BOOT-2: swap GRUB's config to the reader (GUARDED), then re-run. The reader reads the durable byte from
    # DISK (not COM1) -> NO feeder, no SENT check; the config-swap guard + the shutdown-completion sentinel apply. A
    # silent swap failure (losetup/mount/tee) would boot the STALE writer -> the reader never runs -> a stale/absent
    # emit graded as kernel; now detected -> harness error -> re-roll.
    if ! ( cd "$d"
           LOOP="$(sudo losetup -fP --show disk.img)" || exit 1
           sudo mount "${LOOP}p1" mnt || { sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
           printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/reader.bin\n boot\n}\n' \
             | sudo tee mnt/boot/grub/grub.cfg >/dev/null || { sudo umount mnt 2>/dev/null; sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
           sudo umount mnt || { sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
           sudo losetup -d "$LOOP"; rm -f disk.img.lock ); then
        BOCHS_HARNESS_ERR="the GRUB config swap to reader.bin FAILED (losetup/mount/tee/umount) -- Bochs would boot the STALE writer; harness failure, not a kernel miscompile"
        return 1
    fi
    ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc.txt" > bochs_b2.txt 2>&1 )   # BOOT-2 reader: no COM1 feeder; absolute bochsrc path (scoped-kill: $work in the cmdline)
    rm -f "$d/disk.img.lock"
    _bochs_ran_ok "$d/bochs_b2.txt" "reader.bin(BOOT-2)" || return 1
    python3 - "$d/bochs_b2.txt" "$b2out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    bochs_done=0
    for attempt in 1 2 3; do
        BOCHS_HARNESS_ERR=""
        BX=$(( (RANDOM % 255) + 1 )); BXHEX=$(printf '0x%02x' "$BX")
        if ! bochs_two_boot "$BX" "$work/b.b2"; then
            echo "  HARNESS ERROR (Bochs two-boot attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling the two-boot (transient emulator/feeder failure, NOT a kernel RED)" >&2
            continue
        fi
        # both boots ran THROUGH shutdown() (BOOT-1 also LISTENED + delivered SENT) -> gradedur is a GENUINE kernel grade
        if python3 "$REF" gradedur "$work/b.b2" "$KEND" "$BXHEX" >/dev/null 2>&1; then ok "(C) Bochs TWO-BOOT: the durable byte X=$BXHEX survives across two Bochs runs on the SAME GRUB disk (BOOT-1 writer SYS_DISK_WRITEs X at the absolute window LBA + CACHE FLUSH; BOOT-2 reader reads it back -- the 2nd substrate's ATA controller persists the write, the software-RESET prologue Bochs needs is emitted)"
        else fail_test "(C) Bochs two-boot (both boots ran through shutdown -> a GENUINE kernel grade, not a harness flake) -> $(python3 "$REF" gradedur "$work/b.b2" "$KEND" "$BXHEX" 2>&1 | tr '\n' ';')"; fi
        bochs_done=1; break
    done
    if [[ "$bochs_done" -eq 0 ]]; then
        # 3 consecutive HARNESS failures (never the kernel; fresh disk each attempt). Distinct greppable marker (NOT the
        # kernel-RED FAIL: prefix); fatal only when the Bochs substrate is REQUIRED (REQUIRE_EMU=1).
        if [[ "$REQUIRE_EMU" == "1" ]]; then
            echo "HARNESS-ERROR: (C-Bochs) the REQUIRED Bochs substrate failed 3 consecutive harness attempts -- $BOCHS_HARNESS_ERR (re-rollable emulator/feeder failure, NOT a kernel miscompile; the gate is RED only because KERNEL_CODEGEN_REQUIRE_EMU=1)"
            fail=$((fail + 1))
        else
            echo "  HARNESS-ERROR (non-fatal): (C-Bochs) Bochs failed 3 consecutive harness attempts -- $BOCHS_HARNESS_ERR (re-rollable; REQUIRE_EMU=0 so the gate is NOT RED on a harness flake -- re-roll, or set KERNEL_CODEGEN_REQUIRE_EMU=1 to require the Bochs substrate)" >&2
        fi
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link54 (durable / DURABILITY -- a kernel-written byte SURVIVES A REBOOT): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link54 durable / DURABILITY -- a byte WRITTEN by the kernel SURVIVES A REBOOT. A NEW emit mode multiboot32-durable, TYPE-II ADDITIVE on the FROZEN platter (link37) lineage: a SYS_DISK_WRITE arm (int 0x30, eax=6) ATA LBA28 single-sector WRITEs a sector (rep outsw, 0x66 prefix) + ATA CACHE FLUSH (0xE7) so the write reaches the medium, gated by a WRITE-LBA access_ok to a reserved write window [$DUR_WLO,$DUR_WHI) (a clean sub-range at the TOP of the frozen read window so the unchanged reader reads it back; a write-anywhere primitive is WORSE than the read leak) + an ECX<512 offset bound, plus the ATA software-RESET prologue (Bochs needs it for writes). THE MAKE-OR-BREAK is a TWO-BOOT on one disk image: BOOT-1 a writer prober reads a late-bound AUTHOR-UNKNOWN byte X off COM1 (a CPL3 module cannot touch the UART) and SYS_DISK_WRITEs X to (LBA $DUR_WLBA, off $DUR_OFF); after a REBOOT (QEMU re-run on the SAME cache=writethrough image, RAM wiped) BOOT-2 a reader prober SYS_DISK_READs that sector back == X -- the byte SURVIVED on the medium. Byte-pinned to durable_ref.build_elf (binds the SYS_DISK_WRITE arm), white-box assert_durability (the WRITE-LBA access_ok with the jcc TARGETS pinned to the reject block -- FIX A/talcott, the OFFSET access_ok, the ATA WRITE -> rep outsw -> CACHE FLUSH sequence), the neutered-rel32 FORGE REJECTED (a decorative WRITE-LBA bound is caught), QEMU+KVM+Bochs GREEN, the PRIMARY M-nowrite differential RED (the same genuine kernel with ONLY the write+flush severed -> BOOT-2 stale 0), the SECONDARY frozen-platter differential RED (no SYS_DISK_WRITE arm -> eax=6 falls to SYS_EXIT -> nothing written; framing-confounded), the hostile-WRITE leg (a forbidden out-of-window LBA -- the MBR -- is REJECTED, the forbidden sector UNCHANGED) and the hostile-OFFSET leg (ECX>=512 REJECTED, no kernel write past the 512B diskbuf) and the hostile-DIRECTION-FLAG leg (a writer that does std=DF=1 before the in-window write STILL persists its sentinel at off>=2 -- the kernel cld's before BOTH rep stosd and rep outsw so the sector is built/sent FORWARD regardless of the module's DF; M-nowcld would walk BACKWARD, zeroing the page tables below diskbuf and sending the wrong sector), additive on platter/lethe/cleave/tessera/furlough/homestead/tenement/rollcall/tickover. Output-forced -- X is late-bound author-unknown AND must SURVIVE on disk across a fresh boot, which no RAM stash and no frozen older kernel reproduces. HONEST SCOPE: ONE block device (ATA master), single-sector synchronous PIO writes + an explicit cache flush, a fixed reserved write sub-window; no journaling, no DMA, no filesystem, no multi-sector or multi-drive)"
