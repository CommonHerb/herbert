#!/usr/bin/env bash
# Held-back MUTATION proof for native-codegen link53 / platter (the kernel's FIRST BLOCK DEVICE -- an ADDRESSED
# random-access disk READ via SYS_DISK_READ, eax=5). Each mutation perturbs ONE piece of the disk-read machinery in
# platter_ref.build_elf(mut=...) and proves it non-vacuous: the CONTROL kernel grades GREEN (the pointer-chase ==
# disk_chase_expect(chasemap)) on the benign chase AND returns the sentinel 0 for every hostile out-of-window LBA AND
# passes assert_platter; every mutant either grades RED on output OR (the access_ok break) leaks a real disk byte on the
# hostile leg AND fails the white-box assert_platter. Modeled EXACTLY on run_native_codegen_link52_mutation.sh.
#
# The disk substrate (STEP-0, proven): QEMU adds `-drive file=disk.img,format=raw,if=ide,index=0,media=disk` (ATA
# master at 0x1F0). The per-run AUTHOR-UNKNOWN chasemap is dd'd into the reserved window [DISK_RESV_LO,DISK_RESV_HI)
# AFTER the kernel/prober are frozen (a serial COM1 stream cannot reproduce a data-dependent random-access order). For
# the hostile leg the harness ALSO seeds NONZERO bytes at the forbidden LBAs (the MBR/FAT sectors) so a dropped
# access_ok leaks an OBSERVABLE nonzero byte.
#
# Mutations (platter_ref.build_elf(mut=...)):
#   M-fixedlba         the kernel IGNORES the module's EBX and always reads the fixed start sector (LO+START) -> every
#                      hop reads the SAME sector -> the chase collapses (b0==b1==b2==b3) -> RED. The ATA machinery + the
#                      bound checks are intact, so assert_platter stays TRUE -- the read just is not ADDRESSED by the
#                      module. The OUTPUT grade is the discriminator here.
#   M-noread           skip the whole ATA PIO sequence -> the kernel's diskbuf stays ZERO -> the prober emits zeros ->
#                      RED on output AND assert_platter FALSE (the ATA command sequence is gone).
#   M-noboundscheck    drop the LBA access_ok (the two cmp ebx,LO/HI guards) -> the benign window chase still grades
#                      GREEN (OUTPUT-INVISIBLE: the dropped bound is silent for in-window LBAs) -- so the silicon grade
#                      ALONE cannot catch it. Its discriminators are (a) the HOSTILE-LBA leg: a prober that asks for an
#                      OUT-OF-WINDOW LBA (LBA 0 = the MBR, FAT sectors) now gets a real NONZERO disk byte back instead of
#                      the sentinel 0 -> grade_disk_hostile RED (the leak); AND (b) assert_platter FALSE (the bound cmps
#                      are gone). The classic sandbox-break caught by the white-box pin + the hostile output witness.
#   M-noecxcheck       drop the OFFSET access_ok (the `cmp ecx,512 ; jae reject` guarding the [diskbuf+ECX] return) ->
#                      the benign chase still grades GREEN (the prober uses ECX=0 -- OUTPUT-INVISIBLE) -- so the silicon
#                      grade ALONE cannot catch it. Its discriminators are (a) the HOSTILE-ECX leg: a prober with a VALID
#                      in-window LBA but ECX>=512 (mapping to a nonzero kernel byte just past the 512B diskbuf) now gets
#                      that real kernel byte back instead of the sentinel 0 -> grade_disk_hostile_ecx RED (the arbitrary-
#                      kernel-read leak Codex caught); AND (b) assert_platter FALSE (the cmp ecx,512 is gone). The SECOND
#                      untrusted scalar -- mirrors M-noboundscheck for the byte-offset.
#   M-nocld            drop the `cld` before `rep insw` -> the benign chase still grades GREEN (the prober's DF=0 ambiently
#                      -- OUTPUT-INVISIBLE) -- so the silicon grade ALONE cannot catch it. Its discriminators are (a) the
#                      HOSTILE-DF leg: a prober that does `std` (DF=1) before a VALID in-window int 0x30 makes `rep insw`
#                      walk BACKWARD from diskbuf (corrupting kernel memory below it; diskbuf[0] gets the sector's LAST
#                      word) so the returned byte is WRONG -> grade_disk_hostile_df RED; AND (b) assert_platter FALSE (the
#                      cld-before-rep-insw adjacency is gone). The THIRD untrusted bit of state (the DIRECTION FLAG) --
#                      mirrors M-noecxcheck/M-noboundscheck for DF. The GENUINE kernel cld's, so build_elf(none) is
#                      UNCHANGED (M-nocld is a build_elf MUTANT only -- no re-reseed).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/platter_ref.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (mutation proof requires QEMU)"; exit 1; fi
    echo "SKIP: qemu not found (mutation proof needs the silicon gate)"; exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead/timed-out QEMU run trips this -> hard fail at end
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

# ---- disk-window constants (single source of truth: the ref) ----
read -r DISK_LO DISK_HI DISK_KHOPS DISK_START < <(python3 "$REF" diskwindow)
DISK_W=$((DISK_HI - DISK_LO))
DISK_MASK=$((DISK_W - 1))
if (( (DISK_W & DISK_MASK) != 0 )); then echo "FAIL: stack/native_compile_fragment.herb (disk window $DISK_W is not a power of two)"; exit 1; fi

# the per-run AUTHOR-UNKNOWN chasemap + the NONZERO hostile-sector seeding. Writes a random byte for EVERY window index
# AND a nonzero byte at each forbidden hostile LBA (so a dropped access_ok leaks an OBSERVABLE nonzero byte). Prints the
# CLI chasemap arg ("idx:byte,...") on stdout. The kernel/prober are frozen BEFORE this runs -- the bytes are late-bound.
make_disk() { # diskimg seedhint  -> echoes the chasemap arg
    local img="$1" hint="$2"
    dd if=/dev/zero of="$img" bs=1M count=64 status=none
    HOSTILE_LBAS="$(python3 "$REF" hostilelbas)" python3 - "$img" "$DISK_LO" "$DISK_W" "$hint" "$DISK_START" "$DISK_KHOPS" <<'PY'
import sys, os, random
img, lo, w, hint = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
start_idx, khops, mask = int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[3]) - 1
# author-unknown: seed from os.urandom XOR the per-call hint so two calls in one run differ.
rng = random.Random(int.from_bytes(os.urandom(8), 'little') ^ (hash(hint) & 0xFFFFFFFF))
# Reject-and-regenerate DEGENERATE maps (still author-unknown): M-fixedlba pins every hop to the start
# sector -> output [cm[start]]*khops. If the honest chase (idx=start; idx=cm[idx]&mask each hop -- mirrors
# platter_ref.disk_chase_expect) self-loops within the hop count (< khops distinct sectors) or collapses to
# that value, M-fixedlba is output-INVISIBLE and this bite-proof false-REDs (~1/64: cm[start]&mask==start).
for _attempt in range(100000):
    cm = {i: rng.randrange(0, 256) for i in range(w)}
    idx = start_idx; seen = set(); honest = []
    for _ in range(khops):
        seen.add(idx); honest.append(cm[idx] & 0xFF); idx = cm[idx] & mask
    if len(seen) == khops and honest != [cm[start_idx] & 0xFF] * khops:
        break
else:
    sys.exit('FATAL: no non-degenerate chasemap in 100000 tries (window=%d khops=%d)' % (w, khops))
hostile = [int(x) for x in os.environ['HOSTILE_LBAS'].split()]
with open(img, 'r+b') as f:
    for i in range(w):
        f.seek((lo + i) * 512)
        f.write(bytes([cm[i]]))          # byte 0 of sector (lo+i) <- the chase byte
        f.write(b'\x00' * 511)           # zero the rest (deterministic offsets > 0)
    # NONZERO MBR/FAT seeding at the forbidden LBAs: a dropped access_ok leaks one of THESE bytes (observable).
    for lba in hostile:
        if lo <= lba < lo + w:           # never clobber an in-window chase sector
            continue
        f.seek(lba * 512); f.write(bytes([0xDE]))
sys.stderr.write('wrote %d chase sectors at LBA %d + nonzero hostile seeds\n' % (w, lo))
print(','.join('%d:%d' % (i, cm[i]) for i in range(w)))
PY
}

QIMG="$work/disk.img"
CHASEMAP="$(make_disk "$QIMG" map-a 2>/dev/null)" || { echo "FAIL: stack/native_compile_fragment.herb (chasemap generation FATAL -- the degenerate-map guard could not converge; refusing to continue with a degenerate/empty chasemap)"; exit 1; }
# seed the hostile-DF sentinel at (start sector, DF_PROBE_OFF) so the genuine FORWARD read is well-defined and the M-nocld
# BACKWARD read (which leaves diskbuf[offset>=2] zero) is observably wrong. offset 0 stays the chase byte (untouched).
read -r DF_LBA DF_OFF DF_BYTE < <(python3 "$REF" hostiledfprobe)
printf "$(printf '\\x%02x' "$DF_BYTE")" | dd of="$QIMG" bs=1 seek=$((DF_LBA * 512 + DF_OFF)) conv=notrunc status=none 2>/dev/null

PROBER="$work/prober.bin"; python3 "$REF" diskprober "$PROBER"          # the K-hop benign pointer-chase prober
HOSTILE="$work/hostile.bin"; python3 "$REF" hostileprober "$HOSTILE"    # the hostile-LBA prober (must get sentinel 0)
HOSTILE_ECX="$work/hostile_ecx.bin"; python3 "$REF" hostileecxprober "$HOSTILE_ECX"   # the hostile-OFFSET prober (valid LBA + ECX>=512)
HOSTILE_DF="$work/hostile_df.bin"; python3 "$REF" hostiledfprober "$HOSTILE_DF"       # the hostile-DF prober (std + valid LBA)
read -r ECX_PROBE ECX_LEAK < <(python3 "$REF" hostileecxprobe)

qrun() { # kernel-elf out timeout prober
    local kel="$1" out="$2" to="$3" pr="${4:-$PROBER}"
    timeout "$to" qemu-system-x86_64 -cpu qemu64 -kernel "$kel" -initrd "$pr" -debugcon file:"$out" \
        -drive file="$QIMG",format=raw,if=ide,index=0,media=disk \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -serial none -monitor none -m 64M >/dev/null 2>"$out.qerr"
    # fail-closed: a QEMU LAUNCH failure (bad drive/args/OOM/binary) writes to stderr, while a clean run --
    # even a guest fault -- leaves stderr EMPTY. Non-empty stderr is an unambiguous HARNESS failure, NOT a bite.
    # (rc is NOT usable: isa-debug-exit yields arbitrary odd exit codes >124 on legit completions.)
    grep -qvE 'terminating on signal' "$out.qerr" 2>/dev/null && { echo "FAIL: link53 harness failure -- QEMU launch error: $(grep -vE 'terminating on signal' "$out.qerr" | head -1)" >&2; : > "$HVMARK"; }   # only a NON-timeout stderr line is a launch failure; a timeout-kill (hang bite) is left to the grader
}
gg() { python3 "$REF" gradedisk "$1" "$2" "$CHASEMAP" >/dev/null 2>&1; }       # benign chase GREEN?
gh() { python3 "$REF" gradehostile "$1" "$2" >/dev/null 2>&1; }               # hostile-LBA leg GREEN (all sentinel 0)?
ghe() { python3 "$REF" gradehostileecx "$1" "$2" >/dev/null 2>&1; }           # hostile-ECX leg GREEN (sentinel 0)?
ghd() { python3 "$REF" gradehostiledf "$1" "$2" >/dev/null 2>&1; }             # hostile-DF leg GREEN (correct byte despite std)?

# ---- CONTROL: the genuine kernel must be GREEN on the chase AND on the hostile legs AND pass assert_platter ----
CK="$work/ctrl.elf"; CKEND="$(python3 "$REF" kernelelf "$CK" none full)"
qrun "$CK" "$work/c" 40
qrun "$CK" "$work/ch" 40 "$HOSTILE"
qrun "$CK" "$work/che" 40 "$HOSTILE_ECX"
qrun "$CK" "$work/chd" 40 "$HOSTILE_DF"
if gg "$work/c" "$CKEND" && gh "$work/ch" "$CKEND" && ghe "$work/che" "$CKEND" && ghd "$work/chd" "$CKEND" && python3 "$REF" assertplatter "$CK"; then
    ok "control (genuine) GREEN -- the emitted chain == disk_chase_expect(chasemap) (addressed random-access read), every hostile out-of-window LBA returns the sentinel 0 (LBA access_ok holds), the hostile ECX=$ECX_PROBE (>= 512) returns the sentinel 0 (OFFSET access_ok holds), the hostile-DF prober (std before int 0x30) STILL reads the correct disk byte (the kernel cld's before rep insw -> FORWARD read), + assert_platter TRUE"
else
    fail_test "control kernel is NOT clean (chase GREEN + hostile-LBA sentinel-0 + hostile-ECX sentinel-0 + hostile-DF correct-byte + assert_platter) -- the mutation harness does not bite"
fi

# ---- each mutation: RED on the chase output, OR (the access_ok break) leaks on the hostile leg + assert_platter FALSE ----
#   fixedlba        : OUTPUT-graded (RED chase) -- the ATA + bounds stay intact so assert_platter is TRUE.
#   noread          : RED chase (zeros) AND assert_platter FALSE (the ATA sequence is gone).
#   noboundscheck   : the benign chase is GREEN (OUTPUT-INVISIBLE) -- caught by the HOSTILE leg (a nonzero MBR leak ->
#                     grade_disk_hostile RED) AND by assert_platter FALSE (the bound cmps are gone).
muts=( "fixedlba:40:red:ignore EBX, always read LO+START -> every hop reads the SAME sector -> the chase collapses (b0==b1==b2==b3) -> RED; ATA+bounds intact so assert_platter stays TRUE"
       "noread:40:redwhite:skip the ATA PIO sequence -> diskbuf stays 0 -> the prober emits zeros -> RED + assert_platter FALSE"
       "noboundscheck:40:hostile:drop the LBA access_ok -> the benign chase is still GREEN (OUTPUT-INVISIBLE) but the hostile out-of-window read leaks a real nonzero MBR/FAT byte -> grade_disk_hostile RED + assert_platter FALSE"
       "noecxcheck:40:hostileecx:drop the OFFSET access_ok (cmp ecx,512 ; jae) -> the benign chase is still GREEN (the prober uses ECX=0, OUTPUT-INVISIBLE) but the hostile-ECX read (valid LBA + ECX>=512) leaks a nonzero kernel byte past the 512B diskbuf -> grade_disk_hostile_ecx RED + assert_platter FALSE"
       "nocld:40:hostiledf:drop the cld before rep insw -> the benign chase is still GREEN (the prober's DF=0 ambiently AND reads offset 0, OUTPUT-INVISIBLE) but a hostile module that does std (DF=1) before int 0x30 makes rep insw walk BACKWARD from diskbuf (only diskbuf[0..1] written, diskbuf[offset>=2] stays ZERO; kernel memory below diskbuf corrupted) -> the hostile-DF read at offset 2 returns the WRONG byte (zero, not the sentinel) -> grade_disk_hostile_df RED + assert_platter FALSE" )
for spec in "${muts[@]}"; do
    m="${spec%%:*}"; rest="${spec#*:}"; to="${rest%%:*}"; rest2="${rest#*:}"; mode="${rest2%%:*}"; desc="${rest2#*:}"
    MK="$work/$m.elf"; MKEND="$(python3 "$REF" kernelelf "$MK" "$m" full)"
    case "$mode" in
      red)
        # output mutant: must be RED on the benign chase. (assert_platter stays TRUE for fixedlba -- not the discriminator.)
        qrun "$MK" "$work/$m.o" "$to"
        if gg "$work/$m.o" "$MKEND"; then fail_test "M-$m GREEN on the chase (vacuous: $desc)"; else ok "M-$m RED on the chase ($desc)"; fi
        ;;
      redwhite)
        # RED on the chase AND assert_platter FALSE (the ATA sequence is gone).
        qrun "$MK" "$work/$m.o" "$to"
        red=1; gg "$work/$m.o" "$MKEND" && red=0
        wb=1; python3 "$REF" assertplatter "$MK" 2>/dev/null && wb=0
        if [[ "$red" -eq 1 && "$wb" -eq 1 ]]; then ok "M-$m RED on the chase + assert_platter False ($desc)"
        elif [[ "$red" -ne 1 ]]; then fail_test "M-$m GREEN on the chase (vacuous: $desc)"
        else fail_test "M-$m assert_platter TRUE (the ATA sequence survived? $desc)"; fi
        ;;
      hostile)
        # the access_ok break: PROVE the benign chase is GREEN (so the silicon grade alone cannot catch it), then the
        # HOSTILE leg leaks a nonzero disk byte (grade_disk_hostile RED) AND assert_platter FALSE (the white-box witness).
        qrun "$MK" "$work/$m.o" "$to"
        benign_green=0; gg "$work/$m.o" "$MKEND" && benign_green=1
        qrun "$MK" "$work/$m.h" "$to" "$HOSTILE"
        leak=1; gh "$work/$m.h" "$MKEND" && leak=0       # gradehostile RED (exit!=0) == leak detected
        wb=1; python3 "$REF" assertplatter "$MK" 2>/dev/null && wb=0
        if [[ "$leak" -eq 1 && "$wb" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the access_ok break is OUTPUT-INVISIBLE on the benign chase (GREEN) yet the HOSTILE leg LEAKS a nonzero out-of-window disk byte (grade_disk_hostile RED) + assert_platter False ($desc)"
            else
                ok "M-$m hostile-leg LEAK (grade_disk_hostile RED) + assert_platter False (note: this run's benign chase was also RED) ($desc)"
            fi
        elif [[ "$leak" -ne 1 ]]; then
            fail_test "M-$m hostile leg did NOT leak (grade_disk_hostile GREEN -- the access_ok was NOT actually dropped, or the hostile sectors were zero) ($desc)"
        else
            fail_test "M-$m assert_platter TRUE (the bound cmps survived? $desc)"
        fi
        ;;
      hostileecx)
        # the OFFSET access_ok break: PROVE the benign chase is GREEN (the prober uses ECX=0, so the dropped offset bound
        # is OUTPUT-INVISIBLE to the silicon grade), then the HOSTILE-ECX leg (a valid LBA + ECX>=512) leaks a nonzero
        # kernel byte past diskbuf (grade_disk_hostile_ecx RED) AND assert_platter FALSE (the white-box ECX-bound pin).
        qrun "$MK" "$work/$m.o" "$to"
        benign_green=0; gg "$work/$m.o" "$MKEND" && benign_green=1
        qrun "$MK" "$work/$m.he" "$to" "$HOSTILE_ECX"
        leak=1; ghe "$work/$m.he" "$MKEND" && leak=0     # gradehostileecx RED (exit!=0) == leak detected
        wb=1; python3 "$REF" assertplatter "$MK" 2>/dev/null && wb=0
        if [[ "$leak" -eq 1 && "$wb" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the OFFSET access_ok break is OUTPUT-INVISIBLE on the benign chase (GREEN, the prober uses ECX=0) yet the HOSTILE-ECX leg (valid LBA + ECX=$ECX_PROBE >= 512) LEAKS a nonzero kernel byte past diskbuf (grade_disk_hostile_ecx RED) + assert_platter False ($desc)"
            else
                ok "M-$m hostile-ECX leg LEAK (grade_disk_hostile_ecx RED) + assert_platter False (note: this run's benign chase was also RED) ($desc)"
            fi
        elif [[ "$leak" -ne 1 ]]; then
            fail_test "M-$m hostile-ECX leg did NOT leak (grade_disk_hostile_ecx GREEN -- the offset access_ok was NOT actually dropped, or the target byte was zero) ($desc)"
        else
            fail_test "M-$m assert_platter TRUE (the cmp ecx,512 survived? $desc)"
        fi
        ;;
      hostiledf)
        # the cld break (M-nocld): PROVE the benign chase is GREEN (the prober there has DF=0 ambiently, so the dropped
        # cld is OUTPUT-INVISIBLE to the silicon grade), then the HOSTILE-DF leg (a prober that does std (DF=1) before a
        # valid in-window read) gets the WRONG byte back (grade_disk_hostile_df RED -- rep insw walked BACKWARD from
        # diskbuf, corrupting kernel memory below it) AND assert_platter FALSE (the white-box cld-adjacency pin).
        qrun "$MK" "$work/$m.o" "$to"
        benign_green=0; gg "$work/$m.o" "$MKEND" && benign_green=1
        qrun "$MK" "$work/$m.hd" "$to" "$HOSTILE_DF"
        wrong=1; ghd "$work/$m.hd" "$MKEND" && wrong=0    # gradehostiledf RED (exit!=0) == wrong-direction read detected
        wb=1; python3 "$REF" assertplatter "$MK" 2>/dev/null && wb=0
        if [[ "$wrong" -eq 1 && "$wb" -eq 1 ]]; then
            if [[ "$benign_green" -eq 1 ]]; then
                ok "M-$m the cld drop is OUTPUT-INVISIBLE on the benign chase (GREEN, the prober's DF=0) yet the HOSTILE-DF leg (std before int 0x30) reads BACKWARD -> the WRONG disk byte (grade_disk_hostile_df RED; kernel memory below diskbuf corrupted) + assert_platter False ($desc)"
            else
                ok "M-$m hostile-DF leg WRONG-direction read (grade_disk_hostile_df RED) + assert_platter False (note: this run's benign chase was also RED) ($desc)"
            fi
        elif [[ "$wrong" -ne 1 ]]; then
            fail_test "M-$m hostile-DF leg read CORRECTLY (grade_disk_hostile_df GREEN -- the cld was NOT actually dropped, or the sector's first and last words coincide) ($desc)"
        else
            fail_test "M-$m assert_platter TRUE (the cld survived? $desc)"
        fi
        ;;
    esac
done

echo "native-codegen link53 platter MUTATION proof: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
if [[ -e "$HVMARK" ]]; then echo "FAIL: link53 HARNESS FAILURE -- a QEMU run was dead/timed-out (empty output); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link53 platter MUTATION proof -- control GREEN (the emitted chain == disk_chase_expect(chasemap) on a per-run AUTHOR-UNKNOWN chasemap dd'd into the reserved window after freeze; every hostile out-of-window LBA returns the sentinel 0; assert_platter TRUE); M-fixedlba RED on the chase (ignore EBX -> every hop reads the same sector -> the chase collapses -- the read is not ADDRESSED by the module; ATA+bounds intact so assert_platter stays TRUE, the OUTPUT grade is the discriminator); M-noread RED on the chase (the ATA PIO sequence dropped -> diskbuf stays zero -> emits zeros) + assert_platter False; M-noboundscheck the KEY LBA sandbox-break: the LBA access_ok dropped -- OUTPUT-INVISIBLE on the benign window chase (still GREEN, the silicon grade alone CANNOT catch it) -- caught by the HOSTILE-LBA leg (a prober asking for an OUT-OF-WINDOW LBA, LBA 0=the MBR / FAT sectors, now gets a real NONZERO disk byte instead of the sentinel 0 -> grade_disk_hostile RED, the OUTPUT witness of the leak) AND by the white-box assert_platter False (the two cmp ebx,LO/HI bound guards are gone). The hostile sectors are seeded nonzero per-run so the leak is observable. M-noecxcheck the OFFSET sandbox-break (the SECOND untrusted scalar, the info-leak Codex caught): the OFFSET access_ok (cmp ecx,512 ; jae reject) dropped -- OUTPUT-INVISIBLE on the benign chase (still GREEN, the prober uses ECX=0) -- caught by the HOSTILE-ECX leg (a prober with a VALID in-window LBA but ECX>=512 mapping to a nonzero kernel byte just past the 512B diskbuf, now gets that real kernel byte back instead of the sentinel 0 -> grade_disk_hostile_ecx RED, the arbitrary-one-byte-kernel-read leak) AND by the white-box assert_platter False (the cmp ecx,512 is gone). M-nocld the DIRECTION-FLAG sandbox-break (the THIRD untrusted bit of state, the cld completeness item): the cld before rep insw dropped -- OUTPUT-INVISIBLE on the benign chase (still GREEN, the prober's DF=0 ambiently) -- caught by the HOSTILE-DF leg (a prober that does std (DF=1) before a valid in-window int 0x30 makes rep insw walk BACKWARD from diskbuf, corrupting kernel memory below it and giving the WRONG byte -> grade_disk_hostile_df RED) AND by the white-box assert_platter False (the cld-before-rep-insw adjacency is gone). The GENUINE kernel cld's, so build_elf(none) is byte-UNCHANGED -- M-nocld is a build_elf MUTANT variant only, no re-reseed.)"
