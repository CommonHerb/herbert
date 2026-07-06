#!/usr/bin/env bash
# Native-codegen Link 55 / cairn (kernel-arc link 39): THE FILESYSTEM GERM -- a PERSISTENT NAMED LOOKUP. durable (link 38)
# gave the kernel DURABILITY (a kernel-written byte survives a reboot, by raw LBA). cairn is the first time a kernel-written
# byte is resolved by NAME across a reboot, not by raw LBA: a tiny on-disk FS (ONE directory sector + D=8 data sectors past
# durable's window) with two new syscall arms -- SYS_FS_PUT (int 0x30 eax=7; EBX=name_ptr(16B), ECX=payload_ptr, EDX=len)
# allocates a data sector BY INSERTION ORDER (data_lba=FS_DATA_LO+nentries, NOT name-derived), writes the payload sector +
# flush, writes the dir entry + flush; SYS_FS_GET (eax=8; EBX=name_ptr(16B query), ECX=dst_ptr, EDX=dst_cap) FIXED-loop
# scans D dir slots for valid && a FULL 16-byte name match, BOUNDS the stored data_lba to [FS_DATA_LO,FS_DATA_HI) BY VALUE
# before the ATA read (the confused-deputy stored-pointer guard -- the NEW security surface: the stored data_lba is an
# attacker-influenced capability), reads that sector, access_ok's dst, copies len bytes. A NEW kernel emit mode
# `multiboot32-cairn` (TYPE-II ADDITIVE on the FROZEN durable lineage). KERNEL-EMIT only; the putter/getter probers are
# hand-asm, LATE-BOUND (names/payloads/query fed over COM1 -- not baked).
#
# THE MAKE-OR-BREAK = a LATE-BOUND TWO-BOOT named-lookup on ONE disk image (cairn_latebound.py builds the probers):
#   BOOT-1 "putter": reads >=2 records over COM1 -- each = 16 name bytes + 1 length byte + len payload bytes via SYS_READ
#     (a CPL3 module cannot touch the UART) -- and SYS_FS_PUTs each. TARGET first, DECOY after (decoy-after-target). The
#     two names SHARE A 15-byte PREFIX and differ ONLY in the LAST byte (so a prefix-only name compare cannot tell them
#     apart -- forces the genuine full 16-byte compare), and the payloads are HIGH-ENTROPY + late-bound (no baked answer).
#   REBOOT (RAM wiped; SAME disk image).
#   BOOT-2 "getter": reads an AUTHOR-UNKNOWN QUERY over COM1 (chosen by the host AFTER the reboot) and SYS_FS_GETs +
#     SYS_WRITEs the resolved payload. RUN THE TWO-QUERY DESIGN: query the TARGET name AND the DECOY name -- each must
#     emit ITS OWN payload. (Querying the DECOY yielding the DECOY's payload, not the first slot's, is what kills
#     M-returnfirst; the per-entry data_lba being honoured is what kills M-fixedlba.)
#   Grade on QEMU-TCG + KVM (real silicon) + Bochs: each query's emitted bytes == the host-computed resolved payload.
#
# Why GENUINELY OUTPUT-FORCED: the resolved payload follows the LATE-BOUND query + late-bound stored records, persisted
# on the medium across a fresh boot (RAM wiped). No baked answer, no RAM stash, and no frozen older kernel (durable has
# no SYS_FS_GET arm) reproduces it. The two-query/decoy-after-target design forces name-RESOLUTION (not a positional rule)
# and the per-entry data_lba; the data_lba BY-VALUE bound is the new confused-deputy guard (a hostile stored data_lba
# would otherwise be an arbitrary-sector read primitive).
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a KVM real-silicon leg, vs cairn_ref.py):
#   (B1) KERNEL BYTE-PIN: the emitted kernel == cairn_ref.build_elf() (the SYS_FS_PUT/GET arms + the frozen durable arms).
#   (B2) WHITE-BOX assert_cairn: the do_fs_get arm carries the data_lba BY-VALUE bound (cmp eax,FS_DATA_LO ; jb / cmp
#        eax,FS_DATA_HI ; jae on the value loaded from [esi+24]) + the FIXED-D dir-scan bound (cmp ecx,FS_D ; jae).
#   (B3) the FROZEN durable kernel FAILS assert_cairn (no FS arms -- the name-resolution machinery is genuinely new).
#   (D) ADDITIVITY: durable + platter + the other frozen modes emit byte-identical to their refs; AND durable's frozen
#       assertdurable PASSES on the cairn kernel (the FS arms sit AFTER do_write, preserving durable's adjacency).
#   (C) SILICON make-or-break: the LATE-BOUND TWO-BOOT two-query named lookup (TARGET->P_T, DECOY->P_D) GREEN on QEMU +
#       KVM + Bochs.
#   (C-PREFIX) THE FULL-16-BYTE-COMPARE leg (closes a cross-model/Codex hole -- the decoy-after-target two-query alone
#       only rules out a PREFIX-only compare, not a LAST-BYTE-only one, since target/decoy differ only in the last byte):
#       a GET of a NEGATIVE-CONTROL name sharing the TARGET's LAST byte but a DIFFERENT 15-byte prefix returns found=0
#       (a last-byte-only forge would wrongly resolve it to P_T). With the decoy query, every one of the 16 bytes matters.
#   (C-SEEDDIFF) SEED-DIFFERENTIAL: a run with a DIFFERENT held-back (names/payloads/query) graded under the FIRST run's
#       expectation -> RED (the output follows the late-bound input, not a baked answer).
#   (C-DURABLE) THE DURABLE DIFFERENTIAL: the FROZEN durable kernel + the cairn getter -> SYS_FS_GET (eax=8) is unknown ->
#       falls to SYS_EXIT -> BOOT-2 exits before emitting -> RED (name resolution is genuinely new).
#   (C-HOSTILE-LBA) a module PUTs (via a CRAFTED host dir) a dir entry naming data_lba OUTSIDE the FS window (=0=the MBR)
#       then GETs -> REJECTED, no leak (the data_lba bound holds).
#   (C-HOSTILE-CARRY) a getter passes a name_ptr near 4 GiB (0xFFFFFFF8) to GET -> REJECTED (the access_ok carry-check
#       holds), no out-of-region access (BOOT-2 emits nothing / found=0).
#   (C-HOSTILE-DF) GAP-2: a getter does `std` (DF=1) before SYS_FS_GET of a VALID name -> the GENUINE kernel cld's before
#       EVERY FS rep (dir/data reads, the name-compare cmpsb, the dst-copy movsb), so it STILL resolves correctly (forward)
#       -> emitted payload == expected -> GREEN. The FS-string-op cld is load-bearing (assert_cairn pins it; M-fsnocld
#       drops it -> the reps walk BACKWARD off diskbuf/dirbuf into the page tables -> wrong resolution / leak).
# REQUIRE_EMU fail-closed (the durable pattern): if KERNEL_CODEGEN_REQUIRE_EMU=1 and an emulator is missing, FAIL.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/cairn_ref.py"
LB="$script_dir/cairn_latebound.py"
DUR_REF="$script_dir/durable_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$LB" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $LB)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi
source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"; pkill -9 -f "$work" 2>/dev/null || true' EXIT   # kill only THIS gate's bochs (scoped to its unique mktemp; a system-wide `pkill bochs` false-REDs a CONCURRENT gate's boot -- the F4 class). F2 sweep 2026-07-04.
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

# ---- FS-window constants (single source of truth: the ref) ----
read -r FS_DIR FS_LO FS_HI FS_D < <(python3 "$REF" fswindow)

# ---- reference artifacts ----
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK" none full)"
PUTTER="$work/putter.bin"; python3 "$LB" putter "$PUTTER"        # BOOT-1 late-bound putter (16B name + len + payload per record)
GETTER="$work/getter.bin"; python3 "$LB" getter "$GETTER"        # BOOT-2 late-bound getter (16B query -> resolved payload)

MKELF="$work/cairn_kernel.elf"
emit '-- emit: multiboot32-cairn' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) cairn kernel byte-identical to cairn_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) cairn kernel differs from cairn_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assert_cairn ----
if python3 "$REF" assertcairn "$MKELF"; then ok "(B2) kernel carries the name-resolution machinery (assert_cairn: the data_lba BY-VALUE bound to [$FS_LO,$FS_HI) on the loaded entry data_lba, and the FIXED-D=$FS_D dir-scan bound)"
else fail_test "(B2) kernel lacks the name-resolution machinery (assert_cairn failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "cairn kernel is a valid x86 Multiboot image"
else fail_test "cairn kernel is not a valid x86 Multiboot image"; fi

# ---- (B3) the frozen durable kernel must FAIL assert_cairn (no FS arms) ----
if [[ -f "$DUR_REF" ]]; then
    python3 "$DUR_REF" kernelelf "$work/durable_for_assert.elf" none full >/dev/null 2>&1
    if python3 "$REF" assertcairn "$work/durable_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen durable kernel PASSED assert_cairn -- the white-box pin does not discriminate the FS arms"
    else ok "(B3) the frozen durable kernel FAILS assert_cairn (the SYS_FS_PUT/GET arms + the data_lba bound are genuinely new)"; fi
else
    fail_test "(B3) missing $DUR_REF -- cannot prove the durable kernel fails assert_cairn"
fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive on durable) + durable's assert still holds on cairn ----
for lk in durable platter lethe cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; cairn is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- cairn disturbed it"; fi
done
# durable's frozen white-box assert must still PASS on the cairn kernel (the FS arms sit AFTER do_write -> durable's
# do_disk_write arm + its adjacency are untouched). This proves cairn did not regress durable's write machinery.
if [[ -f "$DUR_REF" ]]; then
    if python3 "$DUR_REF" assertdurable "$MKELF" >/dev/null 2>&1; then ok "(D) durable's frozen assertdurable PASSES on the cairn kernel (the FS arms are additive AFTER do_write; durable's write machinery + adjacency are preserved)"
    else fail_test "(D) durable's assertdurable FAILED on the cairn kernel -- cairn disturbed the do_disk_write arm (not purely additive)"; fi
fi

# ============================ SILICON (the late-bound two-boot named lookup) ============================
# ONE 64 MiB raw disk image is reused across BOOT-1 (putter) and the two BOOT-2 (getter) runs. cache=writethrough forces
# the ATA write+flush through to the host file, so the records the putter persisted in BOOT-1 are on the medium for the
# getters after a "reboot" (QEMU re-launched on the SAME image with RAM wiped). The seed (-> names/payloads/query) is
# chosen per-run AFTER the kernel/probers are frozen, so the resolved payloads are genuinely author-unknown.
emu_ran=0
build_raw_disk() { dd if=/dev/zero of="$1" bs=1M count=64 status=none; }

# boot the kernel + module, feeding a byte stream over COM1; capture debugcon to $out.
boot_feed() { # kernel mod out kvm stream...
    local kel="$1" mod="$2" out="$3" kvm="$4"; shift 4
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$mod" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}

# boot_feed for a GENUINE getter that MUST emit -- retry up to N times until the debugcon carries a closed UCODE3
# write-frame. The genuine kernel deterministically resolves + emits (or rejects-and-emits an envelope); a rare EMPTY is
# a wall-clock/emulator timing flake (the COM1-serial / debugcon-flush flake class -- the table dumps fine but the final
# SYS_WRITE frame doesn't materialise under host contention). Diagnosed via local repro (~1/22 under load, 0/12 idle; the
# kernel ran -- table present). Retrying is SAFE: it never converts a MUTANT's RED to GREEN, because a mutant emits empty
# for a DETERMINISTIC reason (a #PF on a backward/out-of-region rep) that recurs every attempt -- only the genuine path's
# transient flush flake recovers. Mutant legs do NOT use this (their empty/wrong IS the signal, run once).
boot_feed_emit() { # kernel mod out kvm stream...   (retries the genuine getter until it emits)
    local kel="$1" mod="$2" out="$3" kvm="$4"; shift 4
    local try
    for try in 1 2 3 4; do
        boot_feed "$kel" "$mod" "$out" "$kvm" "$@"
        local e; e="$(python3 "$LB" emitbody "$out" 2>/dev/null)"
        [[ -n "$e" && "$e" != "NO-TABLE" ]] && return 0
    done
    return 0   # fall through after retries; the caller's grade reports the (still-empty) failure honestly
}

# full late-bound two-boot two-query for a given (kernel, seed, kvmflag, label): BOOT-1 putter, then GET TARGET + GET
# DECOY. Sets globals: TWB_TP TWB_DP (the expected payloads), TWB_B2T TWB_B2D (the BOOT-2 debugcon files).
two_boot_two_query() { # kernel-elf seedhex kvmflag label [emit_retry]
    local kel="$1" seed="$2" kvm="$3" lbl="$4" emit_retry="${5:-}"
    DISK="$work/disk_${lbl}.img"; build_raw_disk "$DISK"
    read -r TWB_TN TWB_TP TWB_DN TWB_DP < <(python3 "$LB" records "$seed")
    local putstream qt qd getfn
    putstream="$(python3 "$LB" putstream "$TWB_TN" "$TWB_TP" "$TWB_DN" "$TWB_DP")"
    qt="$(python3 "$LB" querystream "$TWB_TN")"
    qd="$(python3 "$LB" querystream "$TWB_DN")"
    # the GENUINE-pass legs (emit_retry=1) retry the GETs until they emit (flake-robust); the differential legs (durable /
    # seed-run-2) pass emit_retry="" and use a single boot (their expected behavior may legitimately be empty/wrong).
    getfn=boot_feed; [[ "$emit_retry" == "1" ]] && getfn=boot_feed_emit
    boot_feed "$kel" "$PUTTER" "$work/${lbl}.b1" "$kvm" $putstream          # BOOT-1: PUT target then decoy
    TWB_B2T="$work/${lbl}.b2t"; TWB_B2D="$work/${lbl}.b2d"
    "$getfn" "$kel" "$GETTER" "$TWB_B2T" "$kvm" $qt                         # BOOT-2(i): GET target
    "$getfn" "$kel" "$GETTER" "$TWB_B2D" "$kvm" $qd                         # BOOT-2(ii): GET decoy
}

# SAME-INPUT REPLAY DISCRIMINATOR (parley, 2026-07-06 -- verification-honesty; cross-model Codex
# AGREE-WITH-CHANGES, all adopted): the late-bound data is fully derived from $seed ('records $seed')
# and the kernel is byte-pinned (leg B1), so ONE same-seed replay on a fresh disk re-poses the EXACT
# question. A deterministic same-input defect MUST fail again; a one-shot serial transport/capture
# miss (SENT is feeder-side -- guest receipt is unprovable over TCP; a lost BOOT-1 put byte shifts
# framing, so EMPTY *and* WRONG bytes are both transport-reachable here) will not recur. This is
# STRICTER than a fresh-seed re-roll, which rolls new data and can wash out a data-dependent defect.
# Budget: ONE completed replay; a second COMPLETED RED (any signature -- the pair is printed so
# drift is visible) is hard RED. It is NOT a receipt proof and does NOT rule out an intermittent
# same-data race; the labels hedge accordingly.
run_qemu_gate() { # kvmflag label substlabel
    local kvm="$1" lbl="$2" subst="$3"
    local seed; seed="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    local att a1sig="" et ed gt gd
    for att in 1 2; do
        two_boot_two_query "$MKELF" "$seed" "$kvm" "${lbl}.a${att}" 1     # emit_retry=1 (genuine getter must emit)
        et="$(python3 "$LB" emitbody "$TWB_B2T" 2>/dev/null)"
        ed="$(python3 "$LB" emitbody "$TWB_B2D" 2>/dev/null)"
        gt=1; gd=1
        python3 "$LB" gradefs "$TWB_B2T" "$KEND" "$TWB_TP" >/dev/null 2>&1 && gt=0
        python3 "$LB" gradefs "$TWB_B2D" "$KEND" "$TWB_DP" >/dev/null 2>&1 && gd=0
        if [[ "$gt" -eq 0 && "$gd" -eq 0 ]]; then
            local note=""
            [[ "$att" -eq 2 ]] && note=" [FLAKE-DISCRIMINATED: attempt-1 completed RED ($a1sig) did NOT recur under one same-seed replay -- no deterministic same-data RED reproduced; classed a one-shot transport/capture miss, NOT proof against an intermittent same-data race]"
            ok "(C-$subst) late-bound two-boot two-query: BOOT-1 PUT a TARGET + a DECOY (names sharing a 15-byte prefix, differing only in the last byte; high-entropy late-bound payloads read over COM1) then REBOOT; BOOT-2 GET TARGET -> emitted P_T (${#et} hex chars == host-expected), GET DECOY -> emitted P_D (${#ed} hex chars == host-expected) -- name resolution persisted + correct per-name (forces the full 16-byte compare + the per-entry data_lba)$note"
            return 0
        fi
        if [[ "$att" -eq 1 ]]; then
            a1sig="TARGET=$([[ $gt -eq 0 ]] && echo GREEN || echo "RED emitted=${et:-EMPTY}") DECOY=$([[ $gd -eq 0 ]] && echo GREEN || echo "RED emitted=${ed:-EMPTY}")"
            echo "  REPLAY (C-$subst): completed two-boot graded RED ($a1sig) -- running ONE same-seed replay (same-input discriminator: byte-pinned kernel + seed-derived data; recurrence -> deterministic RED, non-recurrence -> transport-class miss)" >&2
        fi
    done
    fail_test "(C-$subst) late-bound two-boot REPRODUCED under same-seed replay -> hard RED: deterministic same-input kernel/substrate failure, not a one-shot transport miss (attempt-1: $a1sig; replay: TARGET grade=$([[ $gt -eq 0 ]] && echo GREEN || echo RED) (emitted=$et want=$TWB_TP) DECOY grade=$([[ $gd -eq 0 ]] && echo GREEN || echo RED) (emitted=$ed want=$TWB_DP))"
    return 1
}

if have_qemu; then
    emu_ran=1
    run_qemu_gate "" qtcg "QEMU"

    # (C-PREFIX) THE FULL-16-BYTE-COMPARE leg (closes a cross-model/Codex hole: the decoy-after-target two-query alone
    # only rules out a PREFIX-only compare; it does NOT force the FULL 16-byte compare -- a kernel keying ONLY on the last
    # byte would still pass it, since the target/decoy differ only in the last byte). We PUT the target + decoy, then GET a
    # NEGATIVE-CONTROL name that shares the TARGET's LAST byte but has a DIFFERENT 15-byte PREFIX. A genuine full-16-byte
    # compare returns found=0 (it matches NO record) -> empty emit; a last-byte-only forge would WRONGLY resolve it to the
    # TARGET's payload. So: the prefix-mismatch GET must be RED against P_T (and emit nothing). Together with the decoy
    # query (rules out prefix-only) this forces EVERY one of the 16 name bytes to matter.
    PXSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    PXDISK="$work/disk_prefix.img"; build_raw_disk "$PXDISK"; DISK="$PXDISK"
    read -r PXTN PXTP PXDN PXDP < <(python3 "$LB" records "$PXSEED")
    PXPUT="$(python3 "$LB" putstream "$PXTN" "$PXTP" "$PXDN" "$PXDP")"
    PXNAME="$(python3 "$LB" prefixmismatch "$PXTN")"            # same last byte as target, different prefix
    PXQ="$(python3 "$LB" querystream "$PXNAME")"
    boot_feed "$MKELF" "$PUTTER" "$work/px.b1" "" $PXPUT
    boot_feed "$MKELF" "$GETTER" "$work/px.b2" "" $PXQ
    PX_EMIT="$(python3 "$LB" emitbody "$work/px.b2" 2>/dev/null)"
    # genuine: found=0 -> empty emit. A last-byte-only forge would emit P_T (the target's payload).
    if python3 "$LB" gradefs "$work/px.b2" "$KEND" "$PXTP" >/dev/null 2>&1; then
        fail_test "(C-PREFIX) a GET of a name sharing the TARGET's LAST byte but a DIFFERENT prefix RESOLVED to the TARGET's payload (emitted=$PX_EMIT) -- the kernel keys ONLY on the last byte / a suffix, NOT the full 16-byte name (a last-byte-only forge slipped through)"
    elif [[ -z "$PX_EMIT" || "$PX_EMIT" == "0000000000000000" ]]; then
        ok "(C-PREFIX) THE FULL-16-BYTE-COMPARE leg: a GET of a NEGATIVE-CONTROL name sharing the TARGET's LAST byte but a DIFFERENT 15-byte PREFIX returns found=0 (ZERO bytes emitted='$PX_EMIT') -- a last-byte-only / suffix-only compare would WRONGLY resolve it to the TARGET's payload, so EVERY one of the 16 name bytes is load-bearing (with the decoy query ruling out a prefix-only compare)"
    else
        # not P_T and not empty -- it resolved to SOMETHING unexpected; flag it (the genuine kernel must return found=0).
        fail_test "(C-PREFIX) the prefix-mismatch GET emitted unexpected bytes (emitted=$PX_EMIT) -- a genuine full-16-byte compare must return found=0 (no match)"
    fi

    # (C-SEEDDIFF) the SEED-DIFFERENTIAL: a SECOND run with a DIFFERENT held-back seed produces DIFFERENT payloads; grading
    # the second run's output under the FIRST run's expected payloads is RED -> the output follows the late-bound input,
    # not a baked answer. (We capture run-1's expected, run a fresh run-2, grade run-2's emit vs run-1's expected.)
    SD1="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    two_boot_two_query "$MKELF" "$SD1" "" sd1            # only SD1's HOST-computed expected payloads are used (not its emit)
    SD1_TP="$TWB_TP"; SD1_DP="$TWB_DP"   # run-1's expected payloads
    SD2="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    two_boot_two_query "$MKELF" "$SD2" "" sd2 1          # emit_retry=1: SD2's emit is graded (must emit; flake-robust)
    SD2_B2T="$TWB_B2T"; SD2_B2D="$TWB_B2D"
    # grade run-2's TARGET emit against run-1's TARGET expected -> must be RED (different held-back payloads)
    if python3 "$LB" gradefs "$SD2_B2T" "$KEND" "$SD1_TP" >/dev/null 2>&1; then
        # they could collide only if the two seeds produced identical payloads -- astronomically unlikely; treat as a fail
        fail_test "(C-SEEDDIFF) run-2's emit graded GREEN against run-1's expected payload -- the output is NOT following the late-bound input (a baked answer?), or the two random seeds collided"
    else
        # and run-2 graded against ITS OWN expected must be GREEN (sanity: the run itself is well-formed)
        if python3 "$LB" gradefs "$SD2_B2T" "$KEND" "$TWB_TP" >/dev/null 2>&1; then
            ok "(C-SEEDDIFF) SEED-DIFFERENTIAL: a fresh run with a DIFFERENT held-back seed emits a DIFFERENT payload -- graded under the FIRST run's expected it is RED (the emitted payload genuinely follows the late-bound COM1 records/query, not a baked constant), yet GREEN under its OWN expected"
        else
            fail_test "(C-SEEDDIFF) run-2 was RED even against its OWN expected payload -- the run is malformed, the differential is vacuous"
        fi
    fi

    # (C-DURABLE) THE DURABLE DIFFERENTIAL: the frozen durable kernel + the cairn putter/getter. SYS_FS_PUT/GET (eax=7/8)
    # are UNKNOWN in durable -> fall to SYS_EXIT. The putter EXITs on its first PUT; the getter EXITs on its GET before any
    # SYS_WRITE -> BOOT-2 emits NOTHING -> RED. Name resolution is genuinely new (durable has only raw-LBA durability).
    if [[ -f "$DUR_REF" ]]; then
        DKELF="$work/durable_kernel.elf"; DKEND="$(python3 "$DUR_REF" kernelelf "$DKELF" none full)"
        DSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
        two_boot_two_query "$DKELF" "$DSEED" "" dur
        DURED="$(python3 "$LB" emitbody "$TWB_B2D" 2>/dev/null)"
        if python3 "$LB" gradefs "$TWB_B2D" "$DKEND" "$TWB_DP" >/dev/null 2>&1; then
            fail_test "(C-DURABLE) the frozen durable kernel graded GREEN -- name resolution is NOT genuinely new (durable already resolves names?)"
        else
            ok "(C-DURABLE) THE DURABLE DIFFERENTIAL: the frozen durable kernel + the cairn getter is RED -- SYS_FS_GET (eax=8) is unknown in durable, falls to SYS_EXIT, BOOT-2 exits before emitting (emitted='${DURED}') -> name resolution is a genuinely new observable (additive on durable, which has only raw-LBA durability)"
        fi
    fi

    # (C-HOSTILE-LBA) the hostile-data_lba leg: craft a hostile directory sector on the HOST disk with a valid entry naming
    # data_lba=0 (the MBR), seed a distinctive sentinel into the MBR, then GET that name. The genuine kernel must REJECT
    # (the data_lba bound) -> found=0, ZERO bytes emitted, no MBR leak. (Reuses the cairn_step0_hostile mechanism.)
    DISK="$work/disk_hlba.img"; build_raw_disk "$DISK"
    printf '\xDE\xAD\xBE\xEF' | dd of="$DISK" bs=1 seek=0 conv=notrunc status=none 2>/dev/null   # seed the MBR
    EVIL_HEX="$(python3 -c "print((b'EVIL'+b'\x00'*12).hex())")"
    python3 - "$DISK" "$FS_DIR" <<'PY'
import sys, struct
img=sys.argv[1]; dir_lba=int(sys.argv[2])
name=b'EVIL'+b'\x00'*12
ent=struct.pack('<II',1,4)+name+struct.pack('<I',0)   # valid=1, len=4, name, data_lba=0 (the MBR!)
assert len(ent)==28
sec=ent+b'\x00'*(512-len(ent))
with open(img,'r+b') as f:
    f.seek(dir_lba*512); f.write(sec)
PY
    EVIL_Q="$(python3 "$LB" querystream "$EVIL_HEX")"
    boot_feed "$MKELF" "$GETTER" "$work/hlba.b2" "" $EVIL_Q
    HLBA_EMIT="$(python3 "$LB" emitbody "$work/hlba.b2" 2>/dev/null)"
    # genuine: found=0 -> the getter SYS_WRITEs len=0 bytes (empty). A LEAK would emit the MBR bytes (DE AD BE EF).
    if [[ -z "$HLBA_EMIT" || "$HLBA_EMIT" == "NO-TABLE" ]]; then
        # empty is the genuine reject (found=0 -> 0-byte write). NO-TABLE would mean a fault (also no leak, but flag it).
        if [[ "$HLBA_EMIT" == "NO-TABLE" ]]; then fail_test "(C-HOSTILE-LBA) the getter faulted (NO-TABLE) on the hostile data_lba=0 entry -- expected a clean reject (found=0, no emit)"
        else ok "(C-HOSTILE-LBA) a GET of a dir entry naming data_lba=0 (the MBR) is REJECTED -- found=0, ZERO bytes emitted, no MBR leak (the data_lba BY-VALUE access_ok holds; the seeded MBR sentinel DE AD BE EF did NOT come back)"; fi
    else
        fail_test "(C-HOSTILE-LBA) the hostile GET LEAKED bytes (emitted=$HLBA_EMIT) -- the data_lba bound did NOT reject an attacker-named out-of-window sector (the seeded MBR sentinel may have leaked)"
    fi

    # (C-HOSTILE-CARRY) the access_ok carry leg: a getter that reads a VALID late-bound query name over COM1 (so it
    # MATCHES a record the putter PUT) but points dst_ptr near 4 GiB (0xFFFFFFF8) -- so dst_ptr+len WRAPS past the region
    # high bound. The genuine do_fs_get does `add edx,ebx ; jc reject` on the dst pointer, so the wrapped dst is REJECTED
    # (found=0, NO out-of-region write); the getter SURVIVES and emits an 8-byte (found,len)=(0,0) envelope. M-nocarrycheck
    # DROPS the carry-check -> the wrapped dst slips `cmp edx,hi ; ja` (the wrap is small < hi) and the kernel `rep movsb`'s
    # into 0xFFFFFFF8 -- an out-of-region kernel WRITE that #PFs -> the getter FAULTS before emitting (empty). DISCRIMINATOR:
    # genuine emits the non-empty envelope; M-nocarrycheck emits NOTHING (faulted). The dst carry is the OUTPUT-discriminating
    # one (a near-4GiB name_ptr just makes the name-compare miss -> found=0 either way, so the dst carry is what bites).
    HCARRY="$work/hostile_carry_getter.bin"; python3 "$LB" hostilecarry "$HCARRY"
    DISK="$work/disk_carry.img"; build_raw_disk "$DISK"
    HCSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    read -r HCTN HCTP HCDN HCDP < <(python3 "$LB" records "$HCSEED")
    HCPUT="$(python3 "$LB" putstream "$HCTN" "$HCTP" "$HCDN" "$HCDP")"
    HCQ="$(python3 "$LB" querystream "$HCTN")"          # query the TARGET (a VALID, matching name)
    boot_feed "$MKELF" "$PUTTER" "$work/carry.b1" "" $HCPUT
    boot_feed_emit "$MKELF" "$HCARRY" "$work/carry.b2" "" $HCQ   # genuine must emit the envelope (flake-robust)
    CARRY_EMIT="$(python3 "$LB" emitbody "$work/carry.b2" 2>/dev/null)"
    if [[ -n "$CARRY_EMIT" && "$CARRY_EMIT" != "NO-TABLE" ]]; then
        ok "(C-HOSTILE-CARRY) a GET of a VALID (matching) name with a dst_ptr near 4 GiB (0xFFFFFFF8, so dst_ptr+len WRAPS) is REJECTED by the access_ok carry-check (add edx,ebx ; jc reject) -- the getter SURVIVES and emits the (found,len)=(0,0) envelope (found=$CARRY_EMIT), no out-of-region kernel write (the carry-check holds; M-nocarrycheck would let the wrap slip the cmp edx,hi and #PF on the rep movsb to 0xFFFFFFF8)"
    elif [[ "$CARRY_EMIT" == "NO-TABLE" ]]; then
        fail_test "(C-HOSTILE-CARRY) the genuine getter FAULTED (NO-TABLE) on the near-4GiB dst_ptr -- expected a clean reject (the getter should survive + emit the found/len envelope)"
    else
        fail_test "(C-HOSTILE-CARRY) the genuine getter emitted NOTHING (it faulted) on the near-4GiB dst_ptr -- expected the carry-check to reject cleanly so the getter survives + emits the envelope"
    fi

    # (C-HOSTILE-DF) the DIRECTION-FLAG (cld) leg on the NEW FS string-ops (GAP-2): a hostile module does `std` (DF=1)
    # IMMEDIATELY before SYS_FS_GET of a VALID (matching) name. The GENUINE kernel cld's before EVERY FS rep (the dir/data
    # sector reads, the 16-byte name-compare cmpsb, the dst-copy movsb), so the transfer is FORWARD regardless of the
    # module's DF and the name resolves correctly -> the emitted payload == the expected payload (GREEN despite the std).
    # This is the OUTPUT witness that the FS clds are load-bearing (paired with assert_cairn's cld-adjacency pin + the
    # M-fsnocld mutant). Without the clds (M-fsnocld) the FS reps walk BACKWARD off diskbuf/dirbuf into the page tables ->
    # wrong resolution / a kernel-memory leak. (Mirrors durable's hostile-DF leg.) An output-invisible confused-deputy op
    # needs an assert-pin + a hostile-DF leg + a mutant, because the byte-pin cannot see a bug its oracle shares.
    HDF="$work/hostile_df_getter.bin"; python3 "$LB" hostiledf "$HDF"
    DFSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    DFDISK="$work/disk_df.img"; build_raw_disk "$DFDISK"; DISK="$DFDISK"
    read -r DFTN DFTP DFDN DFDP < <(python3 "$LB" records "$DFSEED")
    DFPUT="$(python3 "$LB" putstream "$DFTN" "$DFTP" "$DFDN" "$DFDP")"
    DFQ="$(python3 "$LB" querystream "$DFTN")"           # query the TARGET (a VALID, matching name) under DF=1
    boot_feed "$MKELF" "$PUTTER" "$work/df.b1" "" $DFPUT
    boot_feed_emit "$MKELF" "$HDF" "$work/df.b2" "" $DFQ         # genuine must emit P_T (flake-robust)
    DF_EMIT="$(python3 "$LB" emitbody "$work/df.b2" 2>/dev/null)"
    if python3 "$LB" gradefs "$work/df.b2" "$KEND" "$DFTP" >/dev/null 2>&1; then
        ok "(C-HOSTILE-DF) a SYS_FS_GET preceded by a hostile std (DF=1) of a VALID name STILL resolves correctly -- the genuine kernel cld's before EVERY FS rep (the dir/data reads, the 16-byte name-compare cmpsb, the dst-copy movsb), so the name-compare + payload-copy run FORWARD regardless of the module's direction flag and the emitted payload == P_T (${#DF_EMIT} hex chars); M-fsnocld would inherit DF=1 -> the FS reps walk BACKWARD off diskbuf/dirbuf into the page tables -> wrong resolution / a kernel-memory leak"
    else
        fail_test "(C-HOSTILE-DF) the genuine kernel mis-resolved under a hostile std=DF=1 (emitted=$DF_EMIT, want=$DFTP) -- the kernel did NOT cld before its FS reps, so DF=1 made the name-compare/copy walk BACKWARD (this should NEVER happen on the genuine kernel)"
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- KVM (real silicon): the late-bound two-boot named lookup on the real chipset ----
if have_kvm; then
    run_qemu_gate kvm kvm "KVM real silicon"
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped"
fi

# ---- Bochs (2nd substrate via GRUB; the two-boot persists across Bochs runs on the SAME GRUB disk) ----
# BOOT-1: GRUB delivers the cairn kernel + the putter; the feeder serves the put-stream over com1; the putter SYS_FS_PUTs
# two late-bound records. BOOT-2: the SAME disk.img is re-run with GRUB's config swapped to the getter; the feeder serves
# the query; the getter resolves + emits the payload. .lock cleanup per STEP-0. (Bochs needs the ATA software-RESET
# prologue the kernel emits for writes -- the cairn FS writes inherit durable's prologue.)
# HARNESS-vs-KERNEL hardening ported from the link60 reference (F2 sweep 2026-07-04): both Bochs boots must LISTEN +
# deliver (SENT) + swap-GRUB cleanly + run THROUGH the kernel's shutdown() tail, else it is a re-rollable HARNESS
# failure (F5 -- the observed cairn two-boot COM1 flake), never a false kernel RED.
bochs_two_boot_query() { # putstream(space-bytes) querystream(space-bytes) b2out  -> nonzero (sets BOCHS_HARNESS_ERR) on harness failure
    local putstream="$1" qstream="$2" b2out="$3"
    local kelf; kelf="$(readlink -f "$MKELF")"
    local pu; pu="$(readlink -f "$PUTTER")"; local ge; ge="$(readlink -f "$GETTER")"
    local d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
    local BXSHARE; BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    local VGABIOS; VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
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
      sudo cp "$pu" mnt/boot/putter.bin; sudo cp "$ge" mnt/boot/getter.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/putter.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP" )
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
        # kernel reaches a shutdown() tail: proves the boot RAN TO COMPLETION (not a mid-run death). The SENT check + the
        # emitted-payload gradefs carry correctness. `[[ -s log ]]` alone is worthless (Bochs always prints a banner). grep -a: binary log.
        grep -qa 'shutdown requested' "$bl" && return 0
        BOCHS_HARNESS_ERR="Bochs did NOT run $lbl through to a kernel shutdown tail (log: $bl has no 'shutdown requested' -- the boot died or was timeout-killed mid-run, not a kernel miscompile)"; return 1
    }
    _feed_delivered() { # feedlog label -> 0 iff the feeder actually SENT its payload (Bochs connected COM1)
        local fl="$1" lbl="$2"
        grep -q '^SENT' "$fl" 2>/dev/null && return 0
        BOCHS_HARNESS_ERR="the COM1 feeder never delivered its payload for $lbl (log: $fl has LISTENING but no SENT / shows NOCONN -- Bochs did not connect COM1, the kernel received no input, not a kernel miscompile)"; return 1
    }
    # BOOT-1: the putter config (set at install) + the feeder serving the put-stream over com1.
    local port; port=$(free_port)
    python3 "$feeder" "$port" $putstream --hold 150 > "$d/feed1.log" 2>&1 & local fp=$!
    _feed_ok "$d/feed1.log" "putter.bin(BOOT-1)" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
    sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b1.txt"
    ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b1.txt" > bochs_b1.txt 2>&1 )   # absolute bochsrc path -> $work in the cmdline for the scoped `pkill -f "$work"`
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    rm -f "$d/disk.img.lock"
    _bochs_ran_ok "$d/bochs_b1.txt" "putter.bin(BOOT-1)" || return 1
    _feed_delivered "$d/feed1.log" "putter.bin(BOOT-1)" || return 1
    # REBOOT -> BOOT-2: swap GRUB's config to the getter (GUARDED), serve the query over com1, re-run.
    port=$(free_port)
    python3 "$feeder" "$port" $qstream --hold 150 > "$d/feed2.log" 2>&1 & fp=$!
    _feed_ok "$d/feed2.log" "getter.bin(BOOT-2)" || { kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1; }
    # config-swap guard (cross-model Codex): a SILENT losetup/mount/tee failure boots the STALE putter (wrong module) ->
    # the getter never runs -> emits nothing -> a false RED. Detect each step (cleanup preserved) -> harness error -> re-roll.
    if ! ( cd "$d"
           LOOP="$(sudo losetup -fP --show disk.img)" || exit 1
           sudo mount "${LOOP}p1" mnt || { sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
           printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/getter.bin\n boot\n}\n' \
             | sudo tee mnt/boot/grub/grub.cfg >/dev/null || { sudo umount mnt 2>/dev/null; sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
           sudo umount mnt || { sudo losetup -d "$LOOP" 2>/dev/null; exit 1; }
           sudo losetup -d "$LOOP"; rm -f disk.img.lock ); then
        BOCHS_HARNESS_ERR="the GRUB config swap to getter.bin FAILED (losetup/mount/tee/umount) -- Bochs would boot the STALE putter; harness failure, not a kernel miscompile"
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; return 1
    fi
    sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b2.txt"
    ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b2.txt" > bochs_b2.txt 2>&1 )   # absolute bochsrc path (scoped-kill: $work in the cmdline)
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    rm -f "$d/disk.img.lock"
    _bochs_ran_ok "$d/bochs_b2.txt" "getter.bin(BOOT-2)" || return 1
    _feed_delivered "$d/feed2.log" "getter.bin(BOOT-2)" || return 1
    python3 - "$d/bochs_b2.txt" "$b2out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    # COMPLETED-RED runs get ONE SAME-SEED REPLAY (parley -- see run_qemu_gate's doctrine comment):
    # "fed+delivered+ran through shutdown" proves the FEEDER sent and the emulator completed -- it is
    # NOT guest receipt (the emulator drains the socket into the UART model whether or not the guest
    # reads), so a completed zero-emission/wrong-bytes run is AMBIGUOUS between a transport miss and a
    # data-dependent kernel defect. The same-seed replay discriminates: recurrence -> deterministic
    # hard RED; non-recurrence -> transport-class miss, leg GREEN with a hedged marker. Harness-setup
    # failures (never LISTENED / never completed / GRUB-swap failure) do NOT consume the replay budget.
    bochs_done=0
    completed_red=0
    B_A1=""
    for attempt in 1 2 3 4; do
        BOCHS_HARNESS_ERR=""
        if [[ "$completed_red" -eq 0 ]]; then
            BSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
            read -r BTN BTP BDN BDP < <(python3 "$LB" records "$BSEED")
            BPUT="$(python3 "$LB" putstream "$BTN" "$BTP" "$BDN" "$BDP")"
            BQD="$(python3 "$LB" querystream "$BDN")"     # query the DECOY on Bochs (the harder, returnfirst-killing query)
        fi
        if ! bochs_two_boot_query "$BPUT" "$BQD" "$work/b.b2"; then
            echo "  HARNESS ERROR (Bochs two-boot attempt $attempt/4): $BOCHS_HARNESS_ERR -- re-rolling the two-boot (setup/no-completion failure, NOT a kernel grade; does not consume the same-seed replay budget)" >&2
            continue
        fi
        BEMIT="$(python3 "$LB" emitbody "$work/b.b2" 2>/dev/null)"
        if python3 "$LB" gradefs "$work/b.b2" "$KEND" "$BDP" >/dev/null 2>&1; then
            bnote=""
            [[ "$completed_red" -eq 1 ]] && bnote=" [FLAKE-DISCRIMINATED: attempt's completed RED (emitted=${B_A1:-EMPTY}) did NOT recur under one same-seed replay -- no deterministic same-data RED reproduced; classed a one-shot transport/capture miss, NOT proof against an intermittent same-data race]"
            ok "(C-Bochs) late-bound two-boot named lookup survives across two Bochs runs on the SAME GRUB disk: BOOT-1 putter PUT a TARGET + a DECOY (late-bound over com1) + flush; BOOT-2 getter resolved the DECOY name -> emitted P_D (${#BEMIT} hex chars == host-expected) -- the 2nd substrate's ATA controller persists the FS + resolves by name (the software-RESET prologue Bochs needs is inherited from durable)$bnote"
            bochs_done=1; break
        fi
        if [[ "$completed_red" -eq 0 ]]; then
            completed_red=1
            B_A1="${BEMIT:-EMPTY}"
            echo "  REPLAY (C-Bochs): completed two-boot graded RED (emitted=${B_A1} want=$BDP) -- running ONE same-seed replay (same-input discriminator: byte-pinned kernel + seed-derived data; recurrence -> deterministic RED, non-recurrence -> transport-class miss)" >&2
            continue
        fi
        fail_test "(C-Bochs) two-boot DECOY REPRODUCED under same-seed replay -> hard RED: deterministic same-input kernel/substrate failure, not a one-shot transport miss (attempt-1 emitted=${B_A1}; replay -> $(python3 "$LB" gradefs "$work/b.b2" "$KEND" "$BDP" 2>&1 | tr '\n' ';') (emitted=${BEMIT:-EMPTY} want=$BDP))"
        bochs_done=1; break
    done
    if [[ "$bochs_done" -eq 0 ]]; then
        # Exhausted without an adjudicated grade. TWO distinct cases (cross-model Codex diff catch, 2026-07-06):
        if [[ "$completed_red" -eq 1 ]]; then
            # A COMPLETED Bochs RED was observed but its same-seed replay never completed (setup failures ate
            # the remaining attempts). It is UNADJUDICATED -- neither discriminated as a flake nor reproduced.
            # FAIL CLOSED **unconditionally** (independent of REQUIRE_EMU): the pre-parley gate hard-failed ANY
            # completed Bochs RED, and we may NOT clear a completed RED we could not reproduce-or-refute -- that
            # would be exactly the teeth-loss this link exists to prevent. Uses the kernel-RED prefix on purpose.
            fail_test "(C-Bochs) two-boot DECOY completed RED (emitted=${B_A1:-EMPTY} want=$BDP) but its same-seed replay never completed within the attempt budget -- UNADJUDICATED completed RED, FAILED CLOSED (never cleared; a completed RED that cannot be reproduced-or-refuted stays a failure regardless of KERNEL_CODEGEN_REQUIRE_EMU)"
        elif [[ "$REQUIRE_EMU" == "1" ]]; then
            # No completed grade EVER observed -- pure harness/setup failure. Fatal only when Bochs is REQUIRED.
            echo "HARNESS-ERROR: (C-Bochs) the REQUIRED Bochs substrate exhausted its harness attempts -- $BOCHS_HARNESS_ERR (re-rollable emulator/feeder setup failure, NOT an adjudicated kernel grade; the gate is RED because KERNEL_CODEGEN_REQUIRE_EMU=1)."
            fail=$((fail + 1))
        else
            echo "  HARNESS-ERROR (non-fatal): (C-Bochs) Bochs exhausted its harness attempts -- $BOCHS_HARNESS_ERR (re-rollable; REQUIRE_EMU=0 so the gate is NOT RED on a pure harness flake -- re-roll, or set KERNEL_CODEGEN_REQUIRE_EMU=1 to require the Bochs substrate)." >&2
        fi
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link55 (cairn / FILESYSTEM GERM -- a PERSISTENT NAMED LOOKUP): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link55 cairn / FILESYSTEM GERM -- a PERSISTENT NAMED LOOKUP. A NEW emit mode multiboot32-cairn, TYPE-II ADDITIVE on the FROZEN durable (link38) lineage: a tiny on-disk FS (ONE directory sector + D=8 data sectors past durable's window) with two new syscall arms -- SYS_FS_PUT (int 0x30 eax=7; EBX=name_ptr(16B), ECX=payload_ptr, EDX=len) allocates a data sector BY INSERTION ORDER (data_lba=FS_DATA_LO+nentries, NOT name-derived), writes the payload sector + flush, writes the dir entry + flush; SYS_FS_GET (eax=8; EBX=name_ptr(16B query), ECX=dst_ptr, EDX=dst_cap) FIXED-loop scans D dir slots for valid && a FULL 16-byte name match, BOUNDS the stored data_lba to [$FS_LO,$FS_HI) BY VALUE before the ATA read (the confused-deputy stored-pointer guard -- the NEW security surface), reads that sector, access_ok's dst (with a +len/+16 carry-check Codex caught), copies len bytes. THE MAKE-OR-BREAK is a LATE-BOUND TWO-BOOT named lookup: BOOT-1 a putter reads >=2 records over COM1 (each = 16 name bytes + 1 length byte + len payload bytes via SYS_READ -- a CPL3 module cannot touch the UART) and SYS_FS_PUTs each (TARGET first, DECOY after; the two names SHARE A 15-byte PREFIX and differ ONLY in the last byte -- forcing the full 16-byte compare -- and the payloads are high-entropy + late-bound); after a REBOOT (RAM wiped, SAME cache=writethrough image) BOOT-2 a getter reads an author-unknown QUERY over COM1 and SYS_FS_GETs + SYS_WRITEs the resolved payload, RUN TWICE (query the TARGET name AND the DECOY name) -- each emits ITS OWN payload. Byte-pinned to cairn_ref.build_elf (binds the SYS_FS_PUT/GET arms), white-box assert_cairn (the data_lba BY-VALUE bound on the loaded entry data_lba + the FIXED-D dir-scan bound), the frozen durable kernel FAILS assert_cairn (B3), additive on durable/platter/lethe/cleave/tessera/furlough/homestead/tenement/rollcall/tickover AND durable's frozen assertdurable still PASSES on the cairn kernel (the FS arms sit AFTER do_write -- adjacency preserved), QEMU+KVM+Bochs GREEN on the two-query named lookup, the FULL-16-BYTE-COMPARE leg (a negative-control name sharing the TARGET's last byte but a different prefix returns found=0 -- forces every name byte to matter, closing a cross-model/Codex hole that the decoy query alone only rules out a prefix-only compare), the SEED-DIFFERENTIAL RED (a different held-back seed graded under the prior expectation -> the output follows the late-bound input, not a baked answer), THE DURABLE DIFFERENTIAL RED (SYS_FS_GET eax=8 is unknown in durable -> falls to SYS_EXIT -> BOOT-2 exits before emitting), the hostile-data_lba leg (a crafted dir entry naming data_lba=0=the MBR is REJECTED -- found=0, no leak), the hostile-CARRY leg (a near-4GiB dst_ptr so dst+len WRAPS is REJECTED by the access_ok carry-check, no out-of-region access) and the hostile-DF leg (GAP-2: a getter that does std=DF=1 before SYS_FS_GET of a VALID name STILL resolves correctly because the genuine kernel cld's before EVERY FS rep -- the dir/data reads, the name-compare cmpsb, the dst-copy movsb -- so the FS string-ops run FORWARD regardless of the module's direction flag; M-fsnocld drops the FS clds -> backward walk off diskbuf/dirbuf into the page tables -> wrong resolution / leak, caught by this leg + assert_cairn's cld-adjacency pin). Output-forced -- the resolved payload follows the late-bound query + late-bound stored records persisted on the medium across a fresh boot, which no baked answer, RAM stash, or frozen older kernel reproduces. The held-back MUTATION proof (returnfirst/fixedlba/nolbabound/nocarrycheck/fsnocld) lives in the companion mutation harness. HONEST SCOPE: a single directory sector, D=8 fixed slots, one <=512B payload per slot, insertion-order allocation, a full 16-byte name compare; no subdirectories, no free/delete, no name hashing, no multi-sector payloads)"
