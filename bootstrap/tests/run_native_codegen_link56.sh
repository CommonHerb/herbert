#!/usr/bin/env bash
# Native-codegen Link 56 / larder (kernel-arc link 40): THE FIRST GENERAL-PURPOSE DYNAMIC HEAP ALLOCATOR. cairn (link 39)
# gave the kernel a PERSISTENT NAMED LOOKUP (a byte resolved by NAME across a reboot). larder is the first time the kernel
# hands a ring-3 program GENUINELY DYNAMIC MEMORY: three new syscall arms over the FROZEN cairn lineage -- SYS_ALLOC
# (int 0x30 eax=9; EBX=size) -> ptr in eax (0=OOM/reject); SYS_FREE (eax=10; ECX=ptr) -> 0; SYS_DUMP (eax=11) -> the
# kernel emits the live readback. The allocator is FIRST-FIT over a DEDICATED heap POOL page (carved the lodger way: the
# frozen region bump-scan mints ONE EXTRA page beyond the K proc region pages), split-on-alloc, address-ordered
# coalesce-on-free. The free-list METADATA lives in SUPERVISOR chunk[] cells (do_free NEVER dereferences a module ptr);
# the DATA spans live in proc0's User region (CPL3 r/w) so the module can write a sentinel THROUGH a returned ptr. A NEW
# kernel emit mode `-- emit: multiboot32-larder` (TYPE-II ADDITIVE on the FROZEN cairn lineage: the alloc/free/dump arms
# sit AFTER cairn's FS arms, so assert_cairn STILL PASSES on the larder kernel). KERNEL-EMIT only; the ring-3 DRIVER is a
# GENERIC hand-asm op-interpreter, LATE-BOUND (alloc SIZES + SENTINELS + the op schedule fed over COM1 -- not baked).
#
# THE MAKE-OR-BREAK = a LATE-BOUND, AUTHOR-UNKNOWN alloc/free WITNESS (larder_latebound.py):
#   The seed is chosen by the host AFTER the kernel + driver are frozen; it derives the chunk SIZES (so the whole offset
#   trace is author-unknown) and the SENTINELS (high-entropy). The forcing skeleton (rejection-sampled so the tight pool
#   fills with NO OOM) makes the big late-bound allocs fit ONLY via coalesce: it exercises FIRST-FIT + SPLIT-on-alloc +
#   PREV-coalesce + NEXT-coalesce + a NON-MRU reuse. The driver SYS_ALLOCs each size (the kernel emits the returned ptr,
#   0xE0 + 4 LE bytes), writes the sentinel THROUGH the ptr (forcing REAL backing), SYS_FREEs by remembered ptr, and on
#   SYS_DUMP the kernel walks the live chunks in ADDRESS order emitting (4 ptr bytes + the 4 sentinel bytes it reads back
#   through that ptr) framed 0xE1..0xE2. Graded against the host FIRST-FIT golden on QEMU-TCG + KVM (real silicon) + Bochs.
#
# Why GENUINELY OUTPUT-FORCED: the emitted offset trace follows the LATE-BOUND sizes (author-unknown), and the live
# readback follows the LATE-BOUND sentinels written through the returned pointers. A pure bump-pointer (no reuse), a
# free-noop, a no-split, or a no-coalesce allocator emits a DIFFERENT trace -> RED; a fresh seed (gx/gy) cross-graded is
# RED. The confused-deputy / input-validation surfaces (alloc(0)/size<4 -> a degenerate chunk; an interior-ptr free ->
# the containing chunk) are OUTPUT-INVISIBLE on the benign witness, so they get dedicated hostile legs + a white-box pin.
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle QEMU + Bochs, + a KVM real-silicon leg, vs larder_ref.py):
#   (B1) KERNEL BYTE-PIN: the EMITTED kernel (compiler `-- emit: multiboot32-larder`) == larder_ref.build_elf() (the
#        alloc/free/dump arms + the frozen cairn lineage).
#   (B2) WHITE-BOX assert_larder: the do_alloc / do_free / do_dump arms carry the first-fit search loop, the split-
#        remainder insert (once), the prev+next coalesce deletes (twice), the size reject (cmp ebx,4 / cmp ebx,[pool_size]
#        -> la_oom), the EXACT-base free match, and the kernel-emit path -- all branch-TARGET reachable, ABI reads-only.
#   (B3) the FROZEN cairn kernel FAILS assert_larder (no alloc arms -- the heap allocator is genuinely new).
#   (D) ADDITIVITY: cairn + durable + platter + the other frozen modes emit byte-identical to their refs; AND cairn's
#       frozen assert_cairn STILL PASSES on the larder kernel (the alloc arms sit AFTER the FS arms, adjacency preserved).
#   (PY) the Python byte-pin/assert layer: build_elf deterministic; assert_larder GREEN + rejects every white-box mutant;
#        assert_cairn STILL GREEN (additive); every mutant kernel differs from genuine.
#   (C) SILICON make-or-break: the LATE-BOUND author-unknown alloc/free witness emits the FIRST-FIT golden (split +
#       prev-coalesce + next-coalesce + non-MRU reuse exercised; sentinels intact) GREEN on QEMU-TCG + KVM + Bochs.
#   (FORGE) the output forge mutants (bump / freenoop / nosplit / nocoalesce / noprevmerge / nonextmerge) DIVERGE -> RED.
#   (CONFUSED-DEPUTY) the interior-ptr free is a clean no-op (genuine GREEN) but M-nointeriorfree frees the CONTAINING
#       chunk -> RED; alloc(0) / sub-4 sizes are rejected (genuine GREEN, ptr 0) but M-nosizewrap returns a NONZERO ptr to
#       a degenerate chunk -> RED (smallalloc closes the SYS_DUMP cross-boundary edge); the robustness legs (allochuge /
#       doublefree / wildfree) survive + are output-correct (genuine GREEN).
#   (GX/GY) SEED-DIFFERENTIAL: gx's genuine output graded against gy's golden DIVERGES -> the trace tracks the late-bound
#       seed (no baked answer); gx vs gx is GREEN.
#   (C-LARDER) THE LARDER DIFFERENTIAL: the FROZEN cairn kernel + the larder driver -> SYS_ALLOC (eax=9) is unknown in
#       cairn -> falls to SYS_EXIT -> the driver exits before the kernel emits the LARDER magic banner -> RED (the heap
#       allocator is a genuinely new observable -- no frozen older kernel reproduces it).
# REQUIRE_EMU fail-closed (the cairn/durable pattern): if KERNEL_CODEGEN_REQUIRE_EMU=1 and an emulator is missing, FAIL.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/larder_ref.py"
LB="$script_dir/larder_latebound.py"
CAIRN_REF="$script_dir/cairn_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$LB" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $LB)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi
source "$script_dir/native_codegen_oracle.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"; pkill -9 bochs 2>/dev/null || true' EXIT
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
DRIVER="$work/driver.bin"; python3 "$LB" driver "$DRIVER"        # the GENERIC ring-3 op-interpreter (kernel-agnostic)
DISK="$work/disk.img"; dd if=/dev/zero of="$DISK" bs=1M count=64 status=none   # larder's heap is RAM; a disk is attached so the cairn-lineage boot has an IDE drive

MKELF="$work/larder_kernel.elf"
emit '-- emit: multiboot32-larder' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) larder kernel byte-identical to larder_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) larder kernel differs from larder_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assert_larder + Multiboot validity ----
if python3 "$REF" assertlarder "$MKELF"; then ok "(B2) kernel carries the heap-allocator machinery (assert_larder: first-fit search loop + split-remainder insert once + prev/next coalesce deletes twice + size reject cmp ebx,4 / cmp ebx,[pool_size] -> la_oom + EXACT-base free match + the kernel-emit path, all branch-TARGET reachable, ABI reads-only-ebx/ecx)"
else fail_test "(B2) kernel lacks the heap-allocator machinery (assert_larder failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "larder kernel is a valid x86 Multiboot image"
else fail_test "larder kernel is not a valid x86 Multiboot image"; fi

# ---- (B3) the frozen cairn kernel must FAIL assert_larder (no alloc arms) ----
if [[ -f "$CAIRN_REF" ]]; then
    python3 "$CAIRN_REF" kernelelf "$work/cairn_for_assert.elf" none full >/dev/null 2>&1
    if python3 "$REF" assertlarder "$work/cairn_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen cairn kernel PASSED assert_larder -- the white-box pin does not discriminate the alloc arms"
    else ok "(B3) the frozen cairn kernel FAILS assert_larder (the SYS_ALLOC/FREE/DUMP arms + the first-fit/coalesce machinery are genuinely new)"; fi
else
    fail_test "(B3) missing $CAIRN_REF -- cannot prove the cairn kernel fails assert_larder"
fi

# ---- (D) FROZEN prior baked-kernel modes (purely additive on cairn) + cairn's assert still holds on larder ----
for lk in cairn durable platter lethe cleave tessera furlough homestead tenement rollcall tickover; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R -- cannot prove additivity"; continue; }
    python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; larder is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- larder disturbed it"; fi
done
# cairn's frozen white-box assert must still PASS on the larder kernel (the alloc arms sit AFTER the FS arms -> cairn's
# do_fs_put/get arms + their adjacency are untouched). This proves larder did not regress cairn's FS machinery.
if [[ -f "$CAIRN_REF" ]]; then
    if python3 "$CAIRN_REF" assertcairn "$MKELF" >/dev/null 2>&1; then ok "(D) cairn's frozen assert_cairn PASSES on the larder kernel (the alloc/free/dump arms are additive AFTER the FS arms; cairn's name-resolution machinery + adjacency are preserved)"
    else fail_test "(D) cairn's assert_cairn FAILED on the larder kernel -- larder disturbed the FS arms (not purely additive)"; fi
fi

# ---- (PY) Python byte-pin / assert layer (mirrors larder_phaseA_gate.sh) ----
if LARDER_TDIR="$script_dir" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ['LARDER_TDIR'])
import larder_ref as L
a,_,_ = L.build_elf(); b,_,_ = L.build_elf()
det = (a == b)
ac = L.assert_larder(a); acc = L.assert_cairn(a)
# white-box-REJECTED mutants (assert_larder must say False): the ones that remove a pinned structure.
wb_muts = ['bump','nosplit','nocoalesce','noprevmerge','nonextmerge','nosizewrap','nointeriorfree','bestfit','nomaxchunks']
rej = all(not L.assert_larder(L.build_elf(mut=m)[0]) for m in wb_muts)
# every mutant kernel (incl. the output-only ones that KEEP the pinned structure: freenoop/badsplit/badsplitlen/baddelete) differs.
all_muts = wb_muts + ['freenoop','badsplit','badsplitlen','baddelete']
diff = all(L.build_elf(mut=m)[0] != a for m in all_muts)
# the MAXPROC-boundary invariant: the heap-pool region slot (alloc_lo[MAXPROC]) must not alias the next array + NEXCL covers it.
boundary = (L.arr('alloc_lo')+L.MAXPROC*4 < L.arr('alloc_hi')) and (L.NEXCL >= 9 + 2*L.MAXPROC + (L.MAXPROC+1))
print('det', det, 'assert_larder', ac, 'assert_cairn', acc, 'assert_rejects_muts', rej, 'all_muts_differ', diff, 'maxproc_boundary', boundary)
det = det and boundary
sys.exit(0 if (det and ac and acc and rej and diff) else 1)
PY
then ok "(PY) build_elf deterministic; assert_larder GREEN + rejects every white-box mutant (incl. bestfit + nomaxchunks); assert_cairn STILL GREEN (additive); every mutant kernel (13: incl. badsplit/badsplitlen/baddelete/nomaxchunks) differs from genuine; the MAXPROC-boundary invariant holds (alloc_lo[MAXPROC] does not alias alloc_hi[0]; NEXCL>=34)"
else fail_test "(PY) Python byte-pin/assert layer"; fi

# ============================ SILICON (the late-bound alloc/free witness) ============================
build_kernel() { python3 "$LB" kernel "$1" "$2" >/dev/null; }   # out mut   (ref-built; the compiler only emits genuine)

# boot the kernel + the generic driver, feeding a COM1 op stream; capture debugcon to $out.
boot_feed() { # kernel out kvm stream...
    local kel="$1" out="$2" kvm="$3"; shift 3
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local port; port="$(free_port)"; local d="$out.d"; rm -rf "$d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$DRIVER" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}

# a witness grade is a STRUCTURAL flake (retry-safe) iff its only error is a missing/truncated trace (the COM1-serial /
# debugcon-flush flake class -- the table dumps fine but the final SYS_DUMP frame doesn't materialise under host
# contention). A correctness RED (wrong offset/sentinel) is NOT a flake and stops the retry (reported honestly). Used on
# the GENUINE arms.
is_struct_flake() { echo "$1" | grep -qE 'no parseable kernel cell-dump|MAGIC banner not found|truncated|missing 0xE'; }
# a grade shows a REAL DIVERGENCE iff the grader reports a VALUE mismatch (a wrong/escaping emitted value), not a mere
# missing/truncated trace -- the deterministic-bite signal.
has_real_divergence() { echo "$1" | grep -qE '!= expected|appears MORE THAN ONCE|emitted MORE live chunks'; }
# mutant_verdict: a mutant's RED must be a DETERMINISTIC bite, not a transient structural flake (link-verify rigor). Runs
# a grade-producing command up to N times -> DIVERGE (a value mismatch -> deterministic wrong/escaping trace),
# CONSISTENT (RED on every attempt, never GREEN, never a mismatch -> a deterministic break = reliably no/partial trace),
# or EQUIVALENT (a GREEN appeared -> the mutation is behaviorally vacuous and its RED was a flake -> NOT a bite).
mutant_verdict() { # cmd...  -> echoes DIVERGE|CONSISTENT|EQUIVALENT
    local n=4 i g
    for i in $(seq 1 "$n"); do
        g="$("$@")"
        echo "$g" | grep -q '^GREEN' && { echo EQUIVALENT; return; }
        has_real_divergence "$g" && { echo DIVERGE; return; }
    done
    echo CONSISTENT
}

# GENUINE witness on a given kernel ELF (flake-robust: retry until the trace materialises, then grade once).
run_witness_kel() { # kel seed kvm  -> echoes grade result
    local kel="$1" seed="$2" kvm="$3"
    local stream; stream="$(python3 "$LB" stream "$seed")"
    local out="$work/w.out" try g
    for try in 1 2 3 4; do
        boot_feed "$kel" "$out" "$kvm" $stream
        g="$(python3 "$LB" grade "$out" "$seed" 2>&1)"
        is_struct_flake "$g" || break
    done
    echo "$g"
}
# MUTANT witness (ref-built mutant kernel; SINGLE-SHOT -- a forge's divergence is deterministic).
run_witness_mut() { # kmut seed kvm  -> echoes grade result
    local kmut="$1" seed="$2" kvm="$3"
    local kel="$work/km.elf"; build_kernel "$kel" "$kmut"
    local stream; stream="$(python3 "$LB" stream "$seed")"
    local out="$work/wm.out"; boot_feed "$kel" "$out" "$kvm" $stream
    python3 "$LB" grade "$out" "$seed" 2>&1
}
# hostile / robustness leg. kmut=none -> the GENUINE kernel ($MKELF, flake-robust retry); else a ref-built mutant (single-shot).
run_hostile() { # kmut seed leg kvm  -> echoes hostile_grade result
    local kmut="$1" seed="$2" leg="$3" kvm="$4"
    local kel; if [[ "$kmut" == none ]]; then kel="$MKELF"; else kel="$work/kh.elf"; build_kernel "$kel" "$kmut"; fi
    local stream; stream="$(python3 "$LB" hostile_stream "$seed" "$leg")"
    local out="$work/h.out" try g
    if [[ "$kmut" == none ]]; then
        for try in 1 2 3 4; do
            boot_feed "$kel" "$out" "$kvm" $stream
            g="$(python3 "$LB" hostile_grade "$out" "$seed" "$leg" 2>&1)"
            is_struct_flake "$g" || break
        done
        echo "$g"
    else
        boot_feed "$kel" "$out" "$kvm" $stream
        python3 "$LB" hostile_grade "$out" "$seed" "$leg" 2>&1
    fi
}

emu_ran=0
if have_qemu; then
    emu_ran=1
    for SUB in tcg kvm; do
        KVMF=""; [[ "$SUB" == kvm ]] && KVMF="kvm"
        if [[ "$SUB" == kvm ]] && ! have_kvm; then
            # KVM fail-closed (Codex nit C): under REQUIRE_EMU=1 a missing /dev/kvm must FAIL, not silently skip (the final
            # banner asserts KVM GREEN; the CI runner has /dev/kvm). Otherwise (local, REQUIRE_EMU=0) skip the KVM leg.
            if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "(C-kvm) /dev/kvm unavailable but KERNEL_CODEGEN_REQUIRE_EMU=1 -- the KVM real-silicon leg is mandatory (fail-closed)"; fi
            echo "  NOTE: /dev/kvm unavailable -- KVM real-silicon leg skipped (REQUIRE_EMU=0)"; continue
        fi
        SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
        echo "  ----- QEMU-$SUB  seed=$SEED -----"
        RES="$(run_witness_kel "$MKELF" "$SEED" "$KVMF")"
        if echo "$RES" | grep -q '^GREEN'; then ok "(C-$SUB) the LATE-BOUND author-unknown alloc/free witness on the EMITTED kernel: the kernel-emitted offset trace == the host FIRST-FIT golden (split + prev-coalesce + next-coalesce + non-MRU reuse exercised; the live readback's sentinels -- written THROUGH the returned ptrs -- match)"
        else fail_test "(C-$SUB) genuine witness not GREEN: $(echo "$RES" | tr '\n' ';')"; fi

        if [[ "$SUB" == tcg ]]; then
            # (FORGE) the output forge mutants must DIVERGE from the genuine golden (RED). The rejection-sampled seed makes
            # every forge diverge (larder_latebound._all_forges_diverge); the host golden is the genuine first-fit trace.
            for M in bump freenoop nosplit nocoalesce noprevmerge nonextmerge; do
                V="$(mutant_verdict run_witness_mut "$M" "$SEED" "$KVMF")"   # flake-discriminated: a RED must be a DETERMINISTIC bite
                case "$V" in
                  DIVERGE)    ok "(FORGE $M) the forge kernel's emitted trace DIVERGES (deterministic value mismatch) from the genuine first-fit golden -> the allocator step is load-bearing" ;;
                  CONSISTENT) ok "(FORGE $M) the forge kernel is RED on every attempt (deterministic break -- consistently no/partial trace, never GREEN) -> the allocator step is load-bearing" ;;
                  *)          fail_test "(FORGE $M) did NOT deterministically diverge -- a GREEN appeared across retries (vacuous / flake-masked forge)" ;;
                esac
            done

            # (CONFUSED-DEPUTY) input-validation surfaces, OUTPUT-INVISIBLE on the benign witness -> dedicated hostile legs.
            # interior-ptr free: genuine no-op (both chunks survive) ; M-nointeriorfree range-matches + frees the CONTAINING chunk.
            RES="$(run_hostile none "$SEED" interior "$KVMF")"
            if echo "$RES" | grep -q '^GREEN'; then ok "(interior, genuine) an interior-ptr free (slot+delta) is a clean no-op (exact-base match misses) -> both chunks survive"; else fail_test "(interior, genuine) not GREEN: $(echo "$RES"|tr '\n' ';')"; fi
            V="$(mutant_verdict run_hostile nointeriorfree "$SEED" interior "$KVMF")"
            if [[ "$V" != EQUIVALENT ]]; then ok "(interior, M-nointeriorfree) a range-match frees the CONTAINING chunk on an interior-ptr free -> the live readback loses it -> RED ($V)"; else fail_test "(interior, M-nointeriorfree) did NOT deterministically bite -- a GREEN appeared (vacuous / flake-masked)"; fi
            # alloc(0): genuine reject (ptr 0) ; M-nosizewrap returns a NONZERO ptr to a 0-length chunk.
            RES="$(run_hostile none "$SEED" alloc0 "$KVMF")"
            if echo "$RES" | grep -q '^GREEN'; then ok "(alloc0, genuine) size==0 rejected -> emits ptr 0, no degenerate chunk"; else fail_test "(alloc0, genuine) not GREEN: $(echo "$RES"|tr '\n' ';')"; fi
            V="$(mutant_verdict run_hostile nosizewrap "$SEED" alloc0 "$KVMF")"
            if [[ "$V" != EQUIVALENT ]]; then ok "(alloc0, M-nosizewrap) accepts size==0 -> emits a NONZERO ptr to a 0-length chunk -> RED ($V)"; else fail_test "(alloc0, M-nosizewrap) did NOT deterministically bite -- a GREEN appeared (vacuous / flake-masked)"; fi
            # smallalloc: sub-sentinel sizes (2,3) -> genuine reject (size<4 floor) ; M-nosizewrap returns a ptr to a <4B chunk
            # (the SYS_DUMP cross-boundary readback edge) -- proves the FLOOR specifically, not just size==0.
            RES="$(run_hostile none "$SEED" smallalloc "$KVMF")"
            if echo "$RES" | grep -q '^GREEN'; then ok "(smallalloc, genuine) sub-4 sizes rejected (min-alloc = the 4-byte sentinel width) -> emits ptr 0, no sub-sentinel chunk"; else fail_test "(smallalloc, genuine) not GREEN: $(echo "$RES"|tr '\n' ';')"; fi
            V="$(mutant_verdict run_hostile nosizewrap "$SEED" smallalloc "$KVMF")"
            if [[ "$V" != EQUIVALENT ]]; then ok "(smallalloc, M-nosizewrap) accepts size<4 -> a NONZERO ptr to a chunk shorter than the 4-byte readback -> RED ($V) (closes the SYS_DUMP cross-boundary edge)"; else fail_test "(smallalloc, M-nosizewrap) did NOT deterministically bite -- a GREEN appeared (vacuous / flake-masked)"; fi
            # tablefill: fill the descriptor table to LARDER_MAXCHUNKS then ONE over-cap alloc -> genuine rejects it (chunk-
            # table-full guard, ptr 0) ; M-nomaxchunks proceeds -> emit_larder_split overruns chunk[MAX] past the 16-entry array.
            RES="$(run_hostile none "$SEED" tablefill "$KVMF")"
            if echo "$RES" | grep -q '^GREEN'; then ok "(tablefill, genuine) the over-cap alloc (table at LARDER_MAXCHUNKS) is rejected -> emits ptr 0, no descriptor-array overrun"; else fail_test "(tablefill, genuine) not GREEN: $(echo "$RES"|tr '\n' ';')"; fi
            V="$(mutant_verdict run_hostile nomaxchunks "$SEED" tablefill "$KVMF")"
            if [[ "$V" != EQUIVALENT ]]; then ok "(tablefill, M-nomaxchunks) the dropped table-full guard lets the over-cap alloc proceed -> emit_larder_split overruns chunk[MAX] -> a NONZERO over-cap ptr + corrupted state -> RED ($V)"; else fail_test "(tablefill, M-nomaxchunks) did NOT deterministically bite -- a GREEN appeared (vacuous / flake-masked)"; fi
            # robustness legs: the genuine allocator survives the malformed request + the output is correct (no distinguishing
            # mutant by design -- the metadata is out-of-band so a wild/double/huge request is a clean no-op/OOM).
            for LEG in allochuge doublefree wildfree; do
                RES="$(run_hostile none "$SEED" "$LEG" "$KVMF")"
                if echo "$RES" | grep -q '^GREEN'; then ok "(robustness $LEG, genuine) the allocator survives the malformed request + the output is correct"; else fail_test "(robustness $LEG, genuine) not GREEN: $(echo "$RES"|tr '\n' ';')"; fi
            done

            # (GX/GY) SEED-DIFFERENTIAL: gx's genuine output graded against gy's golden must DIVERGE (the trace tracks the
            # late-bound seed). gx vs gx is the GREEN sanity control.
            GX="$(python3 -c 'import os;print(os.urandom(8).hex())')"; GY="$(python3 -c 'import os;print(os.urandom(8).hex())')"
            sx="$(python3 "$LB" stream "$GX")"; gout="$work/gx.out"
            for try in 1 2 3 4; do boot_feed "$MKELF" "$gout" "$KVMF" $sx; g="$(python3 "$LB" grade "$gout" "$GX" 2>&1)"; is_struct_flake "$g" || break; done
            RES="$(python3 "$LB" grade "$gout" "$GY" 2>&1)"     # gx's REAL output vs gy's golden -> must mismatch
            if echo "$RES" | grep -q '^RED'; then ok "(GX/GY) gx's genuine output graded against gy's golden DIVERGES -> the emitted trace tracks the late-bound seed (no baked answer)"; else fail_test "(GX/GY) gx-vs-gy did NOT diverge (seeds collided?): $(echo "$RES"|tr '\n' ';')"; fi
            RES="$(python3 "$LB" grade "$gout" "$GX" 2>&1)"
            if echo "$RES" | grep -q '^GREEN'; then ok "(GX/GY control) gx output vs gx golden GREEN"; else fail_test "(GX/GY control) gx-vs-gx not GREEN: $(echo "$RES"|tr '\n' ';')"; fi
        else
            # KVM (real silicon): re-confirm the two confused-deputy biting mutants on the physical CPU (KVM has caught
            # iret/segment bugs TCG hid -- e.g. chiefturbo's iret-DS-null). Flake-discriminated deterministic bite.
            V="$(mutant_verdict run_hostile nointeriorfree "$SEED" interior "$KVMF")"
            if [[ "$V" != EQUIVALENT ]]; then ok "(KVM, M-nointeriorfree) interior-free corruption RED on the physical CPU ($V)"; else fail_test "(KVM, M-nointeriorfree) did NOT deterministically bite -- a GREEN appeared (vacuous / flake-masked)"; fi
            V="$(mutant_verdict run_hostile nosizewrap "$SEED" alloc0 "$KVMF")"
            if [[ "$V" != EQUIVALENT ]]; then ok "(KVM, M-nosizewrap) alloc(0) acceptance RED on the physical CPU ($V)"; else fail_test "(KVM, M-nosizewrap) did NOT deterministically bite -- a GREEN appeared (vacuous / flake-masked)"; fi
        fi
    done
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- Bochs (2nd substrate via GRUB): the genuine witness on the EMITTED kernel must be GREEN ----
if have_bochs; then
    emu_ran=1
    KELF="$MKELF"
    SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    STREAM="$(python3 "$LB" stream "$SEED")"
    kelf="$(readlink -f "$KELF")"; drv="$(readlink -f "$DRIVER")"
    d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    pkill -9 bochs 2>/dev/null || true
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp "$drv" mnt/boot/driver.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/driver.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
    bochs_emit=""
    for try in 1 2 3; do
        port=$(free_port)
        python3 "$feeder" "$port" $STREAM --hold 150 > "$d/feed.log" 2>&1 & fp=$!
        for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
        sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b.txt"
        ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f bochsrc_b.txt" > bochs.txt 2>&1 )
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
        python3 - "$d/bochs.txt" "$d/out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
        bochs_emit="$(python3 "$LB" grade "$d/out" "$SEED" 2>&1)"
        is_struct_flake "$bochs_emit" || break
    done
    if echo "$bochs_emit" | grep -q '^GREEN'; then ok "(C-Bochs) the late-bound alloc/free witness on the EMITTED kernel is GREEN on the 2nd substrate: the kernel-emitted trace == the host first-fit golden (split + coalesce + non-MRU reuse) on Bochs' chipset"
    else fail_test "(C-Bochs) Bochs witness not GREEN: $(echo "$bochs_emit" | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

# ---- (C-LARDER) THE LARDER DIFFERENTIAL: the frozen cairn kernel + the larder driver -> RED ----
# SYS_ALLOC/FREE/DUMP (eax=9/10/11) are UNKNOWN in cairn -> fall to SYS_EXIT. The driver SYS_EXITs on its first SYS_ALLOC
# before the kernel ever emits the LARDER magic banner -> the witness has no parseable larder trace -> RED. The heap
# allocator is genuinely new -- no frozen older kernel reproduces it. (Mirrors cairn's durable-differential leg.)
if have_qemu; then
    CKELF="$work/cairn_kernel.elf"; python3 "$CAIRN_REF" kernelelf "$CKELF" none full >/dev/null 2>&1
    DSEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    dstream="$(python3 "$LB" stream "$DSEED")"
    boot_feed "$CKELF" "$work/diff.out" "" $dstream
    DRES="$(python3 "$LB" grade "$work/diff.out" "$DSEED" 2>&1)"
    if echo "$DRES" | grep -q '^GREEN'; then
        fail_test "(C-LARDER) the frozen cairn kernel graded GREEN on the larder witness -- the heap allocator is NOT genuinely new (cairn already allocates?)"
    else
        ok "(C-LARDER) THE LARDER DIFFERENTIAL: the frozen cairn kernel + the larder driver is RED -- SYS_ALLOC (eax=9) is unknown in cairn, falls to SYS_EXIT, the driver exits before the LARDER magic banner is emitted ($(echo "$DRES" | grep -m1 -oE 'no parseable kernel cell-dump|MAGIC banner not found|RED' | head -1)) -> the heap allocator is a genuinely new observable (additive on cairn, which has only a named FS lookup)"
    fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link56 (larder / the first general-purpose DYNAMIC HEAP ALLOCATOR): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link56 larder / the first general-purpose DYNAMIC HEAP ALLOCATOR. A NEW emit mode multiboot32-larder, TYPE-II ADDITIVE on the FROZEN cairn (link39) lineage: three new syscall arms -- SYS_ALLOC (int 0x30 eax=9; EBX=size) -> ptr in eax (0=OOM/reject); SYS_FREE (eax=10; ECX=ptr) -> 0; SYS_DUMP (eax=11) -> the kernel emits the live readback. The allocator is FIRST-FIT over a DEDICATED heap POOL page (carved the lodger way -- the frozen region bump-scan mints ONE EXTRA page beyond the K proc region pages), split-on-alloc, address-ordered coalesce-on-free; the free-list METADATA lives in SUPERVISOR chunk[] cells (do_free never dereferences a module ptr) while the DATA spans live in proc0's User region (CPL3 r/w, so the module writes a sentinel THROUGH a returned ptr). KERNEL-EMIT only; the ring-3 DRIVER is a GENERIC hand-asm op-interpreter, LATE-BOUND (alloc SIZES + SENTINELS + the op schedule fed over COM1 -- a CPL3 module cannot touch the UART -- not baked). THE MAKE-OR-BREAK is a LATE-BOUND author-unknown alloc/free witness: the seed is chosen AFTER freeze and derives the chunk SIZES (so the whole offset trace is author-unknown) + the SENTINELS; the rejection-sampled forcing skeleton fills the tight pool with NO OOM so the big late-bound allocs fit ONLY via coalesce -- it exercises FIRST-FIT + SPLIT-on-alloc + PREV-coalesce + NEXT-coalesce + a NON-MRU reuse; the kernel emits each returned ptr (0xE0) and on SYS_DUMP walks the live chunks in ADDRESS order emitting (ptr + the sentinel read back through that ptr) framed 0xE1..0xE2. Byte-pinned to larder_ref.build_elf (binds the alloc/free/dump arms), white-box assert_larder (the first-fit search loop + the split-remainder insert once + the prev/next coalesce deletes twice + the size reject cmp ebx,4 / cmp ebx,[pool_size] -> la_oom + the EXACT-base free match + the kernel-emit path, all branch-TARGET reachable, ABI reads-only-ebx/ecx), the frozen cairn kernel FAILS assert_larder (B3), additive on cairn/durable/platter/lethe/cleave/tessera/furlough/homestead/tenement/rollcall/tickover AND cairn's frozen assert_cairn still PASSES on the larder kernel (the alloc arms sit AFTER the FS arms -- adjacency preserved), QEMU-TCG+KVM+Bochs GREEN on the witness (split + prev-coalesce + next-coalesce + non-MRU reuse exercised; sentinels intact), the output FORGE mutants (bump / freenoop / nosplit / nocoalesce / noprevmerge / nonextmerge) DIVERGE -> RED, the CONFUSED-DEPUTY legs (an interior-ptr free is a clean no-op -- genuine GREEN -- but M-nointeriorfree frees the CONTAINING chunk -> RED; alloc(0)/sub-4 sizes are rejected -- genuine GREEN, ptr 0 -- but M-nosizewrap returns a NONZERO ptr to a degenerate chunk -> RED, smallalloc closing the SYS_DUMP cross-boundary readback edge) with the robustness legs (allochuge/doublefree/wildfree) surviving + output-correct, the GX/GY SEED-DIFFERENTIAL RED (gx's genuine output graded under gy's golden -> the trace tracks the late-bound seed, not a baked answer), and THE LARDER DIFFERENTIAL RED (the frozen cairn kernel + the larder driver: SYS_ALLOC eax=9 is unknown in cairn -> falls to SYS_EXIT -> the driver exits before the LARDER magic banner is emitted -> no parseable trace). Output-forced -- the emitted offset trace follows the late-bound sizes and the live readback follows the late-bound sentinels written through the returned pointers, which no bump/free-noop/no-split/no-coalesce allocator, no baked answer, and no frozen older kernel reproduces. The CONFUSED-DEPUTY/table-full leg: a table-fill driver allocs to LARDER_MAXCHUNKS then ONE over-cap alloc -- genuine rejects it (chunk-table-full guard, ptr 0, GREEN) but M-nomaxchunks lets emit_larder_split overrun chunk[MAX] -> RED. The MAXPROC-boundary fix: the heap-pool region descriptor lives at alloc_lo[nprocs], so the three region arrays (alloc_lo/alloc_hi/grow_floor) are sized MAXPROC+1 and NEXCL=34 (a Python invariant asserts alloc_lo[MAXPROC] no longer aliases alloc_hi[0]). The held-back MUTATION proof (bump/freenoop/nosplit/nocoalesce/noprevmerge/nonextmerge/nosizewrap/nointeriorfree/bestfit/badsplit/badsplitlen/baddelete/nomaxchunks -- all 13, control-GREEN+all-RED, single shared seed) lives in the companion mutation harness. KVM is fail-closed under KERNEL_CODEGEN_REQUIRE_EMU=1. HONEST SCOPE: a single sub-page heap pool (168 B, tight by design), first-fit + split + address-ordered coalesce, a 4-byte min-alloc floor + a pool-size ceiling, exact-base free; no per-size free-lists/bins, no realloc, no alignment classes, no multi-page heap growth)"
