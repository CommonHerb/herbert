#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link54 / durable (DURABILITY -- a byte WRITTEN by the kernel SURVIVES A
# REBOOT, via SYS_DISK_WRITE eax=6). Each mutation perturbs ONE piece of the durability write machinery in
# durable_ref.build_elf(mut=...) and proves it non-vacuous: the CONTROL kernel grades GREEN (the two-boot reads back the
# late-bound author-unknown X) AND rejects every hostile write AND passes assert_durability; every mutant either grades
# RED on the two-boot output OR (the access_ok breaks) lands a forbidden / out-of-offset write AND fails the white-box
# assert_durability. Modeled EXACTLY on run_native_codegen_link53_mutation.sh.
#
# The disk substrate: ONE 64 MiB raw image, cache=writethrough, reused across BOOT-1 (writer reads X off COM1 via the
# feeder, SYS_DISK_WRITEs it) and BOOT-2 (reader reads it back). X is chosen per-run AFTER freeze. For the hostile legs
# the harness seeds a known SENTINEL at the forbidden sector / the durable sector first so an escape is OBSERVABLE.
#
# Mutations (durable_ref.build_elf(mut=...)):
#   M-nowrite          drop the whole ATA write+flush sequence (d) -> the byte never reaches the medium -> BOOT-2 reads a
#                      stale 0 != X -> RED on the two-boot output AND assert_durability FALSE (the WRITE/rep-outsw/FLUSH
#                      sequence is gone). THE PRIMARY DURABILITY DIFFERENTIAL: the SAME genuine kernel minus only (d).
#   M-nowboundscheck   drop the WRITE-LBA access_ok (the two cmp ebx,WLO/WHI guards) -> the benign two-boot still grades
#                      GREEN (OUTPUT-INVISIBLE: the dropped bound is silent for the in-window durable write) -- so the
#                      two-boot grade ALONE cannot catch it. Its discriminators are (a) the HOSTILE-WRITE leg: a writer to
#                      an OUT-OF-WINDOW LBA (the MBR) now LANDS -- the forbidden sector is MODIFIED (a write-anywhere
#                      escape, strictly WORSE than the read leak); AND (b) assert_durability FALSE (the bound cmps / their
#                      pinned jcc targets are gone).
#   M-nowecxcheck      drop the OFFSET access_ok (the cmp ecx,512 ; jae guarding the diskbuf store) -> the benign two-boot
#                      still grades GREEN (the writer uses ECX=0, OUTPUT-INVISIBLE) -- so the two-boot grade ALONE cannot
#                      catch it. Its discriminators are (a) the HOSTILE-ECX leg: a writer with a VALID in-window LBA but
#                      ECX>=512 now does `mov [ecx+diskbuf],DL` past the 512B diskbuf (an arbitrary kernel write) AND still
#                      writes the sector (overwriting the seeded durable-sector sentinel) -> the durable sector CHANGES;
#                      AND (b) assert_durability FALSE (the cmp ecx,512 is gone).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/durable_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# ---- durability-window constants (single source of truth: the ref) ----
read -r DUR_WLO DUR_WHI DUR_WLBA DUR_OFF < <(python3 "$REF" durwindow)
read -r HOST_LBA HOST_OFF HOST_BYTE < <(python3 "$REF" hostilewritetarget)
read -r DFW_LBA DFW_OFF DFW_BYTE < <(python3 "$REF" hostiledfwritetarget)              # the (LBA, off>=2, sentinel) the DF-writer persists

WRITER="$work/writer.bin"; python3 "$REF" durwriter "$WRITER"                 # BOOT-1 writer (late-bound COM1 byte X)
READER="$work/reader.bin"; python3 "$REF" durreader "$READER"                 # BOOT-2 reader
HOSTILE_W="$work/hostile_writer.bin"; python3 "$REF" hostilewriter "$HOSTILE_W"        # the hostile-LBA writer (must be rejected)
HOSTILE_E="$work/hostile_ecx_writer.bin"; python3 "$REF" hostileecxwriter "$HOSTILE_E" # the hostile-OFFSET writer (must be rejected)
HOSTILE_DF="$work/hostile_df_writer.bin"; python3 "$REF" hostiledfwriter "$HOSTILE_DF" # the hostile-DF writer (std then in-window write; the kernel must cld)

build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }

# BOOT-1 (writer reads X off COM1) -> reboot -> BOOT-2 (reader). Echoes nothing; writes the BOOT-2 debugcon to $4.
two_boot() { # kernel-elf diskimg x boot2out [prober]
    local kel="$1" img="$2" x="$3" b2="$4" pr="${5:-$WRITER}"
    local port; port=$(free_port); local d="$b2.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$x" --hold 12 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 60 qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$pr" -debugcon file:"$b2.b1" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    timeout 40 qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$READER" -debugcon file:"$b2" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -serial none -monitor none -m 64M >/dev/null 2>&1
}
gg() { python3 "$REF" gradedur "$1" "$2" "$3" >/dev/null 2>&1; }              # two-boot GREEN (BOOT-2 == X)?

# run only BOOT-1 with a hostile writer against a sentinel-seeded disk; echoes the byte now at the inspected sector.
hostile_run() { # kernel-elf diskimg prober inspect-lba inspect-off  -> echoes the byte at (inspect-lba,inspect-off)
    local kel="$1" img="$2" pr="$3" ilba="$4" ioff="$5"
    local port; port=$(free_port); local d="$img.hr.d"; mkdir -p "$d"
    python3 "$feeder" "$port" 1 --hold 10 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 40 qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$pr" -debugcon file:"$d/b1" \
        -drive file="$img",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
    dd if="$img" bs=1 skip=$((ilba * 512 + ioff)) count=1 status=none 2>/dev/null | od -An -tu1 | tr -d ' '
}

# ---- CONTROL: the genuine kernel must be GREEN on the two-boot AND reject both hostile writes AND pass assert_durability ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" kernelelf "$CK" none full)"
build_raw_disk "$work/c.img"
CX=$(( (RANDOM % 255) + 1 )); CXHEX=$(printf '0x%02x' "$CX")
two_boot "$CK" "$work/c.img" "$CX" "$work/c.b2"
# hostile-LBA: seed the forbidden sector, run the hostile writer, the sector must still hold the sentinel 0xA5 (165).
build_raw_disk "$work/ch.img"; printf '\xa5' | dd of="$work/ch.img" bs=1 seek=$((HOST_LBA * 512 + HOST_OFF)) conv=notrunc status=none 2>/dev/null
CH_GOT=$(hostile_run "$CK" "$work/ch.img" "$HOSTILE_W" "$HOST_LBA" "$HOST_OFF")
# hostile-ECX: seed the durable sector, run the hostile-ECX writer, the durable sector must still hold the sentinel.
build_raw_disk "$work/che.img"; printf '\xa5' | dd of="$work/che.img" bs=1 seek=$((DUR_WLBA * 512 + DUR_OFF)) conv=notrunc status=none 2>/dev/null
CHE_GOT=$(hostile_run "$CK" "$work/che.img" "$HOSTILE_E" "$DUR_WLBA" "$DUR_OFF")
# hostile-DF: seed the DF sector offset with a DISTINCT marker (0x3C), run the DF writer (std + in-window write of 0xA5
# at off>=2). The genuine kernel cld's before BOTH rep stosd and rep outsw, so the sector is built/sent FORWARD and the
# sentinel 0xA5 (165) lands at (DFW_LBA, DFW_OFF) DESPITE the module's std -> the byte reads back as 165.
build_raw_disk "$work/cdf.img"; printf '\x3c' | dd of="$work/cdf.img" bs=1 seek=$((DFW_LBA * 512 + DFW_OFF)) conv=notrunc status=none 2>/dev/null
CDF_GOT=$(hostile_run "$CK" "$work/cdf.img" "$HOSTILE_DF" "$DFW_LBA" "$DFW_OFF")
if gg "$work/c.b2" "$CKEND" "$CXHEX" && [[ "$CH_GOT" == "165" && "$CHE_GOT" == "165" && "$CDF_GOT" == "165" ]] && python3 "$REF" assertdurable "$CK"; then
    ok "control (genuine) GREEN -- the two-boot reads back the late-bound author-unknown X=$CXHEX (durable across the reboot), the hostile out-of-window LBA write is REJECTED (the forbidden sector still holds the sentinel 0xA5), the hostile ECX>=512 write is REJECTED (the durable sector still holds the sentinel 0xA5), the hostile std(DF=1)+write STILL persists the sentinel 0xA5 at off $DFW_OFF (the kernel cld's so the sector is built/sent FORWARD), + assert_durability TRUE"
else
    fail_test "control kernel is NOT clean (two-boot GREEN=$(gg "$work/c.b2" "$CKEND" "$CXHEX" && echo 1 || echo 0); hostile-LBA sector=$CH_GOT want 165; hostile-ECX sector=$CHE_GOT want 165; hostile-DF sector=$CDF_GOT want 165; assert_durability) -- the mutation harness does not bite"
fi

# ---- each mutation: RED on the two-boot output, OR (the access_ok breaks) a landed forbidden/out-of-offset write + assert_durability FALSE ----
#   nowrite         : two-boot RED (stale 0) AND assert_durability FALSE (the ATA write+flush is gone). THE PRIMARY.
#   nowboundscheck  : the benign two-boot is GREEN (OUTPUT-INVISIBLE) -- caught by the HOSTILE-LBA leg (the forbidden MBR
#                     sector is MODIFIED) AND assert_durability FALSE (the WRITE-LBA bound cmps / jcc targets are gone).
#   nowecxcheck     : the benign two-boot is GREEN (OUTPUT-INVISIBLE, ECX=0) -- caught by the HOSTILE-ECX leg (the durable
#                     sector CHANGES -- a kernel write past diskbuf + the sector still written) AND assert_durability FALSE.
muts=( "nowrite:redwhite:drop the ATA write+flush (d) -> the byte never reaches the medium -> BOOT-2 reads stale 0 != X -> two-boot RED + assert_durability FALSE. THE PRIMARY DURABILITY DIFFERENTIAL (the SAME genuine kernel minus only (d))"
       "nowboundscheck:hostilelba:drop the WRITE-LBA access_ok -> the benign two-boot is still GREEN (OUTPUT-INVISIBLE) but a writer to an OUT-OF-WINDOW LBA (the MBR) now LANDS -> the forbidden sector is MODIFIED (a write-anywhere escape) + assert_durability FALSE"
       "nowecxcheck:hostileecx:drop the OFFSET access_ok (cmp ecx,512 ; jae) -> the benign two-boot is still GREEN (the writer uses ECX=0, OUTPUT-INVISIBLE) but a writer with a VALID LBA + ECX>=512 writes past the 512B diskbuf (arbitrary kernel write) + still writes the sector -> the durable sector CHANGES + assert_durability FALSE"
       "nowcld:hostiledf:drop the two clds (before rep stosd + before rep outsw) -> the benign two-boot is still GREEN (the writer's ambient DF=0 AND it writes at offset 0, OUTPUT-INVISIBLE) but a writer that does std (DF=1) first makes the kernel inherit DF=1 -> the backward rep stosd zeroes the page tables below diskbuf + the backward rep outsw sends the wrong sector content -> the sentinel never lands at off>=2 on the medium (it reads back != 0xA5) + assert_durability FALSE" )
for spec in "${muts[@]}"; do
    m="${spec%%:*}"; rest="${spec#*:}"; mode="${rest%%:*}"; desc="${rest#*:}"
    MK="$work/$m.elf"; MKEND="$(python3 "$REF" kernelelf "$MK" "$m" full)"
    case "$mode" in
      redwhite)
        # the PRIMARY: two-boot RED (stale 0) AND assert_durability FALSE.
        build_raw_disk "$work/$m.img"
        MX=$(( (RANDOM % 255) + 1 )); MXHEX=$(printf '0x%02x' "$MX")
        two_boot "$MK" "$work/$m.img" "$MX" "$work/$m.b2"
        red=1; gg "$work/$m.b2" "$MKEND" "$MXHEX" && red=0
        wb=1; python3 "$REF" assertdurable "$MK" 2>/dev/null && wb=0
        if [[ "$red" -eq 1 && "$wb" -eq 1 ]]; then ok "M-$m two-boot RED (BOOT-2 stale 0 != X=$MXHEX) + assert_durability FALSE ($desc)"
        elif [[ "$red" -ne 1 ]]; then fail_test "M-$m GREEN on the two-boot (vacuous -- the byte survived without the write+flush?: $desc)"
        else fail_test "M-$m assert_durability TRUE (the ATA write sequence survived? $desc)"; fi
        ;;
      hostilelba)
        # the WRITE-LBA access_ok break: PROVE the benign two-boot is GREEN (so the output grade alone cannot catch it),
        # then the HOSTILE-LBA leg LANDS a forbidden write (the MBR sector CHANGES) AND assert_durability FALSE.
        build_raw_disk "$work/$m.img"
        MX=$(( (RANDOM % 255) + 1 )); MXHEX=$(printf '0x%02x' "$MX")
        two_boot "$MK" "$work/$m.img" "$MX" "$work/$m.b2"
        benign_green=0; gg "$work/$m.b2" "$MKEND" "$MXHEX" && benign_green=1
        build_raw_disk "$work/$m.h.img"; printf '\xa5' | dd of="$work/$m.h.img" bs=1 seek=$((HOST_LBA * 512 + HOST_OFF)) conv=notrunc status=none 2>/dev/null
        GOT=$(hostile_run "$MK" "$work/$m.h.img" "$HOSTILE_W" "$HOST_LBA" "$HOST_OFF")
        landed=0; [[ "$GOT" != "165" ]] && landed=1     # the forbidden sector changed from the sentinel -> the write landed
        wb=1; python3 "$REF" assertdurable "$MK" 2>/dev/null && wb=0
        if [[ "$landed" -eq 1 && "$wb" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the WRITE-LBA access_ok break is OUTPUT-INVISIBLE on the benign two-boot (GREEN) yet the HOSTILE-LBA write LANDS -- the forbidden MBR sector changed (sentinel 165 -> $GOT, a write-anywhere escape) + assert_durability FALSE ($desc)"
            else
                ok "M-$m hostile-LBA write LANDED (forbidden sector 165 -> $GOT) + assert_durability FALSE (note: this run's benign two-boot was also RED) ($desc)"
            fi
        elif [[ "$landed" -ne 1 ]]; then
            fail_test "M-$m hostile-LBA write did NOT land (forbidden sector still 165 -- the access_ok was NOT actually dropped) ($desc)"
        else
            fail_test "M-$m assert_durability TRUE (the WRITE-LBA bound cmps / jcc targets survived? $desc)"
        fi
        ;;
      hostileecx)
        # the OFFSET access_ok break: PROVE the benign two-boot is GREEN (the writer uses ECX=0, output-invisible), then
        # the HOSTILE-ECX leg writes past diskbuf + still writes the sector (the seeded durable sector CHANGES) AND
        # assert_durability FALSE.
        build_raw_disk "$work/$m.img"
        MX=$(( (RANDOM % 255) + 1 )); MXHEX=$(printf '0x%02x' "$MX")
        two_boot "$MK" "$work/$m.img" "$MX" "$work/$m.b2"
        benign_green=0; gg "$work/$m.b2" "$MKEND" "$MXHEX" && benign_green=1
        build_raw_disk "$work/$m.he.img"; printf '\xa5' | dd of="$work/$m.he.img" bs=1 seek=$((DUR_WLBA * 512 + DUR_OFF)) conv=notrunc status=none 2>/dev/null
        GOT=$(hostile_run "$MK" "$work/$m.he.img" "$HOSTILE_E" "$DUR_WLBA" "$DUR_OFF")
        changed=0; [[ "$GOT" != "165" ]] && changed=1   # the durable sector changed from the sentinel -> the unbounded write happened
        wb=1; python3 "$REF" assertdurable "$MK" 2>/dev/null && wb=0
        if [[ "$changed" -eq 1 && "$wb" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the OFFSET access_ok break is OUTPUT-INVISIBLE on the benign two-boot (GREEN, the writer uses ECX=0) yet the HOSTILE-ECX write (valid LBA + ECX>=512) writes past diskbuf + still writes the sector -- the durable sector changed (sentinel 165 -> $GOT) + assert_durability FALSE ($desc)"
            else
                ok "M-$m hostile-ECX write CHANGED the durable sector (165 -> $GOT) + assert_durability FALSE (note: this run's benign two-boot was also RED) ($desc)"
            fi
        elif [[ "$changed" -ne 1 ]]; then
            fail_test "M-$m hostile-ECX write did NOT change the durable sector (still 165 -- the offset access_ok was NOT actually dropped) ($desc)"
        else
            fail_test "M-$m assert_durability TRUE (the cmp ecx,512 survived? $desc)"
        fi
        ;;
      hostiledf)
        # the DIRECTION-FLAG (cld) break on the WRITE arm: PROVE the benign two-boot is GREEN (the writer's DF=0 + offset 0,
        # output-invisible), then the HOSTILE-DF leg (std + an in-window write at off>=2) shows the sentinel did NOT land
        # at that disk offset (backward rep stosd/outsw corrupted the build/send) AND assert_durability FALSE.
        build_raw_disk "$work/$m.img"
        MX=$(( (RANDOM % 255) + 1 )); MXHEX=$(printf '0x%02x' "$MX")
        two_boot "$MK" "$work/$m.img" "$MX" "$work/$m.b2"
        benign_green=0; gg "$work/$m.b2" "$MKEND" "$MXHEX" && benign_green=1
        build_raw_disk "$work/$m.df.img"; printf '\x3c' | dd of="$work/$m.df.img" bs=1 seek=$((DFW_LBA * 512 + DFW_OFF)) conv=notrunc status=none 2>/dev/null
        GOT=$(hostile_run "$MK" "$work/$m.df.img" "$HOSTILE_DF" "$DFW_LBA" "$DFW_OFF")
        wrong=0; [[ "$GOT" != "165" ]] && wrong=1        # the sentinel did NOT reach disk off DFW_OFF -> backward string op
        wb=1; python3 "$REF" assertdurable "$MK" 2>/dev/null && wb=0
        if [[ "$wrong" -eq 1 && "$wb" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the dropped clds are OUTPUT-INVISIBLE on the benign two-boot (GREEN, the writer's DF=0 + offset 0) yet the HOSTILE-DF write (std=DF=1 + an in-window write at off $DFW_OFF) leaves disk off $DFW_OFF = $GOT != the sentinel 165 -- DF=1 reached rep stosd/outsw, the string ops walked BACKWARD (page tables below diskbuf zeroed, wrong sector content sent) + assert_durability FALSE ($desc)"
            else
                ok "M-$m hostile-DF write WRONG (disk off $DFW_OFF = $GOT != 165) + assert_durability FALSE (note: this run's benign two-boot was also RED) ($desc)"
            fi
        elif [[ "$wrong" -ne 1 ]]; then
            fail_test "M-$m hostile-DF write STILL landed the sentinel at off $DFW_OFF (got 165 -- the cld was NOT actually dropped / DF did not reach the string op) ($desc)"
        else
            fail_test "M-$m assert_durability TRUE (the cld;rep-stosd / cld;rep-outsw adjacencies survived? $desc)"
        fi
        ;;
    esac
done

echo "native-codegen link54 durable MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link54 durable MUTATION proof -- control GREEN (the two-boot reads back the late-bound author-unknown X persisted across a reboot; every hostile write is REJECTED -- the forbidden out-of-window LBA sector + the durable sector both still hold the seeded sentinel; assert_durability TRUE); M-nowrite the PRIMARY DURABILITY DIFFERENTIAL: the same genuine kernel with ONLY the ATA write+flush (d) severed -> BOOT-2 reads a stale 0 != X -> two-boot RED + assert_durability FALSE (the WRITE/rep-outsw/CACHE-FLUSH sequence is gone); M-nowboundscheck the KEY WRITE-LBA sandbox-break: the WRITE-LBA access_ok dropped -- OUTPUT-INVISIBLE on the benign in-window two-boot (still GREEN, the output grade alone CANNOT catch it) -- caught by the HOSTILE-LBA leg (a writer to an OUT-OF-WINDOW LBA, the MBR, now LANDS -> the forbidden sector is MODIFIED, a write-anywhere escape strictly WORSE than the read leak) AND by the white-box assert_durability FALSE (the cmp ebx,WLO/WHI bound guards / their pinned jcc targets are gone); M-nowecxcheck the OFFSET sandbox-break: the OFFSET access_ok (cmp ecx,512 ; jae) dropped -- OUTPUT-INVISIBLE on the benign two-boot (still GREEN, the writer uses ECX=0) -- caught by the HOSTILE-ECX leg (a writer with a VALID in-window LBA but ECX>=512 does mov [ecx+diskbuf],DL past the 512B diskbuf, an arbitrary kernel write, AND still writes the sector -> the seeded durable sector CHANGES) AND by the white-box assert_durability FALSE (the cmp ecx,512 is gone); M-nowcld the DIRECTION-FLAG sandbox-break: the two clds (before rep stosd + before rep outsw) dropped -- OUTPUT-INVISIBLE on the benign two-boot (still GREEN, the writer's DF=0 + offset 0) -- caught by the HOSTILE-DF leg (a writer that does std=DF=1 then a benign in-window write at off>=2: the kernel inherits DF=1, the backward rep stosd zeroes the page tables below diskbuf AND the backward rep outsw sends the wrong sector content, so the sentinel never lands at that disk offset) AND by the white-box assert_durability FALSE (the FC F3 AB / FC 66 F3 6F cld adjacencies are gone). The hostile sectors are seeded with a known sentinel per-run so an escape is observable.)"
