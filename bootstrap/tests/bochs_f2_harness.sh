# bochs_f2_harness.sh -- shared F2-hardened Bochs boot harness (discriminator-sweep fleet pass,
# 2026-08-28). Faithful extraction of the link33 pattern (herbert c86a166, Codex-reviewed
# RESOLVED-LAND), factored for the pre-link44 gates whose raw disk builds mis-scored harness
# failures as kernel REDs (the 2026-07-17 CI flake class; live repro on kingdom 2026-08-28:
# a missing grub-pc-bin made grub-install fail silently -> unbootable disk -> frames=0
# shutdown=0 -> a fake kernel RED on an untouched, historically-green gate).
#
# What it guarantees (the F2 doctrine, tranche-1a-endorsed fail-closed form):
#   - every disk-build command is CHECKED, with explicit mount/loop cleanup on every exit path
#     (umount + lazy retry; never rm -rf over a possibly-live mount; no global `losetup -D`);
#   - each boot attempt is CLASSIFIED: DISK-BUILD(step) / NO-OUTPUT / NO-SHUTDOWN / EXTRACT-FAILURE
#     vs COMPLETED (completion witness = the boot ran THROUGH `shutdown requested`);
#   - a harness failure re-rolls on a FRESH disk up to 3 attempts; exhaustion emits a greppable
#     HARNESS-ERROR marker (never the `FAIL:` kernel-RED prefix) and FAILS CLOSED UNCONDITIONALLY
#     (regardless of KERNEL_CODEGEN_REQUIRE_EMU -- a gate must not PASS with an attempted leg
#     unadjudicated);
#   - ONLY a COMPLETED boot is graded as a kernel verdict, by the gate's own grade function.
#
# Contract for a sourcing gate:
#   - the gate defines fail_test() (its kernel-RED reporter) before sourcing;
#   - the gate calls its Bochs legs through f2_bochs_leg and, before its final PASS/FAIL logic,
#     runs `f2_harness_summary || exit 1`;
#   - grading: the grade_fn receives the RAW bochs output log (plus any extra args after `--`),
#     returns 0 for GREEN, nonzero for RED, and prints its own fail_test message on RED.
#
#   f2_bochs_attempt GRUBCFG TIMEOUT_S MEGS OUTLOG SRC:DEST...   (DEST is the in-disk path under mnt/)
#       -> stdout: COMPLETED | DISK-BUILD(step) | NO-OUTPUT | NO-SHUTDOWN | EXTRACT-FAILURE
#          on COMPLETED the raw bochs_out.txt has been copied to OUTLOG
#   f2_bochs_leg LEG_LABEL GRADE_FN OUTLOG GRUBCFG TIMEOUT_S MEGS SRC:DEST... [-- GRADE_ARGS...]
#       -> 0 = graded GREEN; 1 = graded RED (grade_fn reported) or harness-exhausted (marker emitted)
#
#   FEED variants (COM1 socket-feed gates; the gate additionally defines free_port() and $feeder --
#   the kernel_input_feed.py invocation is python3 "$feeder" PORT FEED_ARGS, FEED_ARGS expanded
#   UNQUOTED so multi-byte streams work). The feeder is launched AFTER the disk build, just before
#   the boot (the link31 lesson: a pre-build launch lets the feeder's accept-hold expire during a
#   slow build). Completion additionally witnesses the feeder-side handshake: LISTENING before
#   boot, ^SENT after a shutdown-complete boot (feeder-side delivery; guest RECEIPT stays unproven
#   feeder-side per the parley/attest correction -- a lone completed-RED may still be a capture
#   flake, adjudicated by the gate/FLAKE-LOG, never silently).
#   f2_bochs_feed_attempt FEED_ARGS FEEDLOG GRUBCFG TIMEOUT_S MEGS OUTLOG SRC:DEST...
#       -> stdout: COMPLETED | DISK-BUILD(step) | FEED-NO-LISTEN | NO-OUTPUT | NO-SHUTDOWN |
#          FEED-NO-SENT | EXTRACT-FAILURE
#   f2_bochs_feed_leg LEG_LABEL GRADE_FN FEED_ARGS FEEDLOG OUTLOG GRUBCFG TIMEOUT_S MEGS SRC:DEST... [-- GRADE_ARGS...]
#       -> as f2_bochs_leg (fresh feeder + fresh disk per attempt)
#   f2_harness_summary
#       -> 0 if no leg exhausted; else prints the summary marker and returns 1

F2_HARNESS_FAIL=0
F2_GATE="${F2_GATE:-$(basename "${0:-gate}" .sh)}"

f2_harness_error() { # leg-label last-class
    echo "HARNESS-ERROR: ${F2_GATE} $1 harness exhausted (3 fresh-disk attempts; last=$2) -- an emulator/host harness failure, NOT adjudicated as a kernel verdict; fail-closed"
    F2_HARNESS_FAIL=$((F2_HARNESS_FAIL + 1))
}

f2__bios_find() { # sets F2_BXSHARE F2_VGABIOS; rc 1 if missing
    local bxbios
    bxbios="$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)"
    F2_VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    [[ -n "$bxbios" && -n "$F2_VGABIOS" ]] || return 1
    F2_BXSHARE="$(dirname "$bxbios")"   # dirname of a VERIFIED non-empty path (dirname "" yields ".")
    return 0
}

f2__disk_build_class() { # W grubcfg src:dest...  -> echoes "" on success, else the DISK-BUILD(...) class
    local W="$1" grubcfg="$2"; shift 2
    local step
    step=$(
      cd "$W" || { echo "cd"; exit 1; }
      LOOP=""; MOUNTED=0
      cleanup() { [[ "$MOUNTED" -eq 1 ]] && { sudo umount mnt >/dev/null 2>&1 || sudo umount -l mnt >/dev/null 2>&1; }; [[ -n "$LOOP" ]] && sudo losetup -d "$LOOP" >/dev/null 2>&1; }
      trap cleanup EXIT
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none || { echo "dd"; exit 1; }
      parted -s disk.img mklabel msdos >/dev/null || { echo "parted-mklabel"; exit 1; }
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null || { echo "parted-mkpart"; exit 1; }
      parted -s disk.img set 1 boot on >/dev/null || { echo "parted-setboot"; exit 1; }
      LOOP="$(sudo losetup -fP --show disk.img)" || { LOOP=""; echo "losetup"; exit 1; }
      [[ -n "$LOOP" && -e "${LOOP}p1" ]] || { echo "losetup-part"; exit 1; }
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1 || { echo "mkfs"; exit 1; }
      mkdir -p mnt || { echo "mkdir-mnt"; exit 1; }
      sudo mount "${LOOP}p1" mnt || { echo "mount"; exit 1; }
      MOUNTED=1
      sudo mkdir -p mnt/boot/grub || { echo "mkdir-boot"; exit 1; }
      for spec in "$@"; do
        sudo cp "${spec%%:*}" "mnt/${spec#*:}" || { echo "copy"; exit 1; }
      done
      printf '%s' "$grubcfg" | sudo tee mnt/boot/grub/grub.cfg >/dev/null || { echo "grubcfg"; exit 1; }
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1 || { echo "grub-install"; exit 1; }
      sudo umount mnt || { echo "umount"; exit 1; }
      MOUNTED=0
      sudo losetup -d "$LOOP" || { echo "losetup-detach"; exit 1; }
      LOOP=""
      trap - EXIT
      exit 0
    ) || { # never rm -rf a tree that may still hold a live mount or an attached loop backing file
           if mountpoint -q "$W/mnt" 2>/dev/null; then echo "DISK-BUILD(cleanup-umount-stuck; tempdir $W LEAKED deliberately)"
           elif [[ -n "$(losetup -j "$W/disk.img" 2>/dev/null)" ]]; then echo "DISK-BUILD(cleanup-loop-attached; tempdir $W LEAKED deliberately)"
           else echo "DISK-BUILD(${step:-unknown})"; fi; return 1; }
    return 0
}

f2__boot() { # W timeout_s megs com1line-or-empty
    local W="$1" tmo="$2" megs="$3" com1="$4"
    ( cd "$W"
      { cat <<BX
romimage: file=$F2_BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$F2_VGABIOS
megs: $megs
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
BX
        [[ -n "$com1" ]] && printf '%s\n' "$com1"
        cat <<BX
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      } > bochsrc.txt
      xvfb-run -a bash -c "yes c | timeout -s KILL ${tmo} bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
}

f2__classify_boot() { # W outlog  -> echoes NO-OUTPUT | NO-SHUTDOWN | EXTRACT-FAILURE | COMPLETED
    local W="$1" outlog="$2"
    if [[ ! -s "$W/bochs_out.txt" ]]; then echo "NO-OUTPUT"; return; fi
    local sd; sd=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null); sd="${sd:-0}"
    if [[ "$sd" -lt 1 ]]; then echo "NO-SHUTDOWN"; return; fi
    cp "$W/bochs_out.txt" "$outlog" || { echo "EXTRACT-FAILURE"; return; }
    echo "COMPLETED"
}

f2_bochs_attempt() { # grubcfg timeout_s megs outlog src:dest...
    local grubcfg="$1" tmo="$2" megs="$3" outlog="$4"; shift 4
    : > "$outlog" 2>/dev/null || { echo "DISK-BUILD(log-init)"; return; }   # checked truncate: no stale output can ever be graded
    local W; W="$(mktemp -d)"
    f2__bios_find || { rm -rf "$W"; echo "DISK-BUILD(bios-images-missing)"; return; }
    local bcls
    bcls="$(f2__disk_build_class "$W" "$grubcfg" "$@")" || { [[ "$bcls" == *LEAKED* ]] || rm -rf "$W"; echo "$bcls"; return; }
    f2__boot "$W" "$tmo" "$megs" ""
    local cls; cls="$(f2__classify_boot "$W" "$outlog")"
    rm -rf "$W"; echo "$cls"
}

f2_bochs_feed_attempt() { # feed_args feedlog grubcfg timeout_s megs outlog src:dest...
    local feed_args="$1" feedlog="$2" grubcfg="$3" tmo="$4" megs="$5" outlog="$6"; shift 6
    { : > "$outlog" && : > "$feedlog"; } 2>/dev/null || { echo "DISK-BUILD(log-init)"; return; }   # checked: a stale feed log must never authenticate a dead feeder
    local W; W="$(mktemp -d)"
    f2__bios_find || { rm -rf "$W"; echo "DISK-BUILD(bios-images-missing)"; return; }
    local bcls
    bcls="$(f2__disk_build_class "$W" "$grubcfg" "$@")" || { [[ "$bcls" == *LEAKED* ]] || rm -rf "$W"; echo "$bcls"; return; }
    # feeder AFTER the build, just before the boot (link31's accept-hold lesson)
    local port; port=$(free_port)
    # shellcheck disable=SC2086
    python3 "$feeder" "$port" $feed_args > "$feedlog" 2>&1 &
    local fp=$!
    local i ok=0; for i in $(seq 1 50); do grep -q LISTENING "$feedlog" 2>/dev/null && { ok=1; break; }; sleep 0.1; done
    if [[ "$ok" -ne 1 ]]; then kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; rm -rf "$W"; echo "FEED-NO-LISTEN"; return; fi
    f2__boot "$W" "$tmo" "$megs" "com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port"
    # bounded post-boot grace for the feeder-side SENT (a non-reading guest lets Bochs run the moment the TCP
    # connect completes, possibly before a starved feeder returns from accept()+sendall(); cross-model Codex,
    # tranche 1b): no wait at all on the normal path (SENT is already logged), at most 2s otherwise.
    for i in $(seq 1 20); do grep -q '^SENT' "$feedlog" 2>/dev/null && break; sleep 0.1; done
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    local cls; cls="$(f2__classify_boot "$W" "$outlog")"
    rm -rf "$W"
    if [[ "$cls" == "COMPLETED" ]] && ! grep -q '^SENT' "$feedlog" 2>/dev/null; then echo "FEED-NO-SENT"; return; fi
    echo "$cls"
}

f2_bochs_leg() { # leg-label grade_fn outlog grubcfg timeout_s megs src:dest... [-- grade_args...]
    local leg="$1" gfn="$2" outlog="$3" grubcfg="$4" tmo="$5" megs="$6"; shift 6
    local files=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do files+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    local attempt cls=""
    for attempt in 1 2 3; do
        cls="$(f2_bochs_attempt "$grubcfg" "$tmo" "$megs" "$outlog" "${files[@]}")"
        if [[ "$cls" == "COMPLETED" ]]; then
            "$gfn" "$outlog" "$@"; return $?
        fi
        echo "HARNESS re-roll: ${F2_GATE} $leg attempt $attempt = $cls (fresh disk retry)" >&2
    done
    f2_harness_error "$leg" "$cls"
    return 1
}

f2_bochs_feed_leg() { # leg-label grade_fn feed_args feedlog outlog grubcfg timeout_s megs src:dest... [-- grade_args...]
    local leg="$1" gfn="$2" fargs="$3" feedlog="$4" outlog="$5" grubcfg="$6" tmo="$7" megs="$8"; shift 8
    local files=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do files+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    local attempt cls=""
    for attempt in 1 2 3; do
        cls="$(f2_bochs_feed_attempt "$fargs" "$feedlog" "$grubcfg" "$tmo" "$megs" "$outlog" "${files[@]}")"
        if [[ "$cls" == "COMPLETED" ]]; then
            "$gfn" "$outlog" "$@"; return $?
        fi
        echo "HARNESS re-roll: ${F2_GATE} $leg attempt $attempt = $cls (fresh disk + fresh feeder retry)" >&2
    done
    f2_harness_error "$leg" "$cls"
    return 1
}

f2_harness_summary() {
    if [[ "$F2_HARNESS_FAIL" -ne 0 ]]; then
        echo "HARNESS-ERROR: $F2_HARNESS_FAIL ${F2_GATE} Bochs leg(s) exhausted their fresh-disk re-rolls -- emulator/host harness failure(s), fail-closed (NOT kernel verdicts)"
        return 1
    fi
    return 0
}

# ---- SAME-INPUT REPLAY variants (discriminator-sweep tranche 1b, 2026-08-29: the link37/link39
# Bochs-leg replay item of audits/discriminator-sweep-2026-07-17/CHARTER.md). The SAME harness
# classes + fresh-disk re-rolls as f2_bochs_leg / f2_bochs_feed_leg, PLUS the parley same-input
# replay discriminator (replay_discriminator.sh semantics, ported to the Bochs substrate):
#   - a COMPLETED boot graded RED gets ONE same-input replay on a FRESH disk against the SAME
#     artifact bytes (identity = sha256 of every SRC file, captured PRE-LAUNCH on every attempt;
#     an unhashable artifact refuses to boot and is classed a harness failure); recurrence -> hard
#     RED quoting BOTH signatures + the identity + the Bochs banner; non-recurrence -> GREEN + the
#     hedged FLAKE-DISCRIMINATED marker (NOT proof against an intermittent same-input race and NOT
#     a receipt proof; F4/F7 load-correlated Bochs stalls are exactly what a replay cannot
#     separate -- run quiet);
#   - harness classes never consume the replay budget; the 3rd harness failure exhausts the leg:
#     with a pending completed RED -> UNADJUDICATED, fail_test'd (fail-closed unconditionally);
#     without one -> the HARNESS-ERROR marker (fail-closed via f2_harness_summary);
#   - a replay GREEN may clear a RED ONLY against identical artifact bytes (hash-freeze; a mismatch
#     fail_tests and never clears).
#   GRADE_FN contract for these variants DIFFERS from f2_bochs_leg: it must NOT call fail_test (only
#   the driver adjudicates); it is TRI-STATE -- returns 0 GREEN, 2 for a gate-side extraction/harness
#   failure on the completed log (classed EXTRACT-FAILURE(grade): re-rolled, never a kernel grade, never
#   consumes the replay budget), any other nonzero RED -- and prints its one-line signature (the
#   grader's own output) on stdout; the driver quotes it in the REPLAY announcement (mirroring the QEMU
#   driver) and again, paired with the replay's, at the terminal adjudication.
#   f2_bochs_leg_replay LEG_LABEL GRADE_FN OUTLOG GRUBCFG TIMEOUT_S MEGS SRC:DEST... [-- GRADE_ARGS...]
#   f2_bochs_feed_leg_replay LEG_LABEL GRADE_FN FEED_ARGS FEEDLOG OUTLOG GRUBCFG TIMEOUT_S MEGS SRC:DEST... [-- GRADE_ARGS...]
#       -> 0 = adjudicated GREEN; 1 = hard RED / unadjudicated completed RED / harness-exhausted (reported)

f2__replay_ctx() { # src:dest... -> echoes "sha256=<h1>,<h2>,..." (rc 0) or nothing + rc 1 on an unreadable artifact
    local spec h out=""
    for spec in "$@"; do
        h=$(sha256sum "${spec%%:*}" 2>/dev/null | cut -d' ' -f1)
        [[ -n "$h" ]] || return 1
        out="${out:+$out,}$h"
    done
    echo "sha256=$out"
}

f2__replay_drive() { # mode(plain|feed) leg grade_fn feed_args feedlog outlog grubcfg timeout_s megs src:dest... [-- grade_args...]
    local mode="$1" leg="$2" gfn="$3" fargs="$4" feedlog="$5" outlog="$6" grubcfg="$7" tmo="$8" megs="$9"; shift 9
    local files=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do files+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    local retry="fresh disk retry"; [[ "$mode" == feed ]] && retry="fresh disk + fresh feeder retry"
    local state=idle a1sig="" a1ctx="" hfail=0 attempt=0 cls ctx sig
    while :; do
        attempt=$((attempt + 1))
        if ! ctx="$(f2__replay_ctx "${files[@]}")"; then   # identity PRE-LAUNCH (TOCTOU guard): unhashable -> refuse to boot
            cls="DISK-BUILD(artifact-hash-unobtainable)"
        elif [[ "$mode" == feed ]]; then
            cls="$(f2_bochs_feed_attempt "$fargs" "$feedlog" "$grubcfg" "$tmo" "$megs" "$outlog" "${files[@]}")"
        else
            cls="$(f2_bochs_attempt "$grubcfg" "$tmo" "$megs" "$outlog" "${files[@]}")"
        fi
        if [[ "$cls" == "COMPLETED" ]]; then
            local grc=0
            sig="$("$gfn" "$outlog" "$@" 2>&1)" || grc=$?
            sig="${sig//$'\n'/ }"
            if [[ "$grc" -eq 2 ]]; then   # gate-side extraction failure on a completed log: harness class, not a grade
                cls="EXTRACT-FAILURE(grade: ${sig:-<no detail>})"
            elif [[ "$grc" -eq 0 ]]; then
                if [[ "$state" == replay ]]; then
                    if [[ -z "$ctx" || "$ctx" != "$a1ctx" ]]; then
                        fail_test "$leg replay completed GREEN but the artifact identity does not match attempt-1 (attempt-1 [$a1ctx] vs replay [${ctx:-MISSING}]) -- hash-freeze violated, REFUSING to clear the completed RED (a RED may only be cleared against the SAME bytes; fail closed)"
                        return 1
                    fi
                    echo "  NOTE: $leg [FLAKE-DISCRIMINATED: a completed Bochs RED (${a1sig:-<no signature>}) did NOT recur under one same-input replay on a fresh disk -- no deterministic same-input RED reproduced; classed a one-shot transport/capture miss, NOT proof against an intermittent same-input race]"
                fi
                return 0
            else
            if [[ "$state" == replay ]]; then
                fail_test "$leg REPRODUCED under same-input Bochs replay -> hard RED: deterministic same-input kernel/substrate failure, not a one-shot transport miss (attempt-1: ${a1sig:-<no signature>} [$a1ctx]; replay: ${sig:-<no signature>} [$ctx]; $(grep -a -m1 -o 'Bochs x86 Emulator [0-9.]*' "$outlog" 2>/dev/null || echo 'Bochs banner absent'))"
                return 1
            fi
            state=replay; a1sig="$sig"; a1ctx="$ctx"
            echo "  REPLAY $leg: completed Bochs boot graded RED (${sig:-<no signature>}) -- running ONE same-input replay on a fresh disk (same-input discriminator: byte-pinned artifacts [$ctx] + constant input; recurrence -> deterministic RED, non-recurrence -> transport/capture-class miss)" >&2
            continue
            fi
        fi
        hfail=$((hfail + 1))
        echo "HARNESS re-roll: ${F2_GATE} $leg attempt $attempt = $cls ($retry; NOT a kernel grade, does not consume the replay budget)" >&2
        if [[ "$hfail" -ge 3 ]]; then
            if [[ "$state" == replay ]]; then
                fail_test "$leg completed Bochs RED (${a1sig:-<no signature>}; $a1ctx) but its same-input replay never completed within the harness budget (last: $cls) -- UNADJUDICATED completed RED, FAILED CLOSED (never cleared; a completed RED that cannot be reproduced-or-refuted stays a failure regardless of KERNEL_CODEGEN_REQUIRE_EMU)"
                return 1
            fi
            f2_harness_error "$leg" "$cls"
            return 1
        fi
    done
}

f2_bochs_leg_replay() { # leg-label grade_fn outlog grubcfg timeout_s megs src:dest... [-- grade_args...]
    local leg="$1" gfn="$2" outlog="$3" grubcfg="$4" tmo="$5" megs="$6"; shift 6
    f2__replay_drive plain "$leg" "$gfn" "" "" "$outlog" "$grubcfg" "$tmo" "$megs" "$@"
}

f2_bochs_feed_leg_replay() { # leg-label grade_fn feed_args feedlog outlog grubcfg timeout_s megs src:dest... [-- grade_args...]
    local leg="$1" gfn="$2" fargs="$3" feedlog="$4" outlog="$5" grubcfg="$6" tmo="$7" megs="$8"; shift 8
    f2__replay_drive feed "$leg" "$gfn" "$fargs" "$feedlog" "$outlog" "$grubcfg" "$tmo" "$megs" "$@"
}
