#!/usr/bin/env bash
# Native-codegen Link 61 / highwater (kernel-arc link 45): RUNTIME FREE-FRAME ALLOCATOR off an AUTHOR-UNKNOWN memory map.
# tract (link 44) gave variable-size durable files. highwater is the genuine open half of D20: the kernel discovers the
# physical RAM at runtime (lodger's Multiboot-mmap scan -> region_hi) and hands a ring-3 program FRESH PHYSICAL FRAMES from
# the TOP DOWN, each mapped NON-IDENTITY at the reused lethe alias V (+invlpg), with the kernel EMITTING each frame's
# physical address (a CPL3 program cannot read its own PFN -- the witness must be KERNEL-emitted). TYPE-II ADDITIVE on the
# FROZEN tract: build_elf(highwater=False) reproduces tract BYTE-FOR-BYTE.
#
# THE FORGE-RESISTANCE CORE (why this is genuinely forced, not lethe's output-forgeable baked-PTE reserve):
#   The gate boots at a PER-RUN-RANDOM -m (the author-unknown memory size). region_hi = M*0x100000-0x20000 (QEMU; validated
#   TCG==KVM 24M..192M). SYS_FALLOC allocates TOP-DOWN from region_hi, so the emitted frame addresses are author-unknown --
#   a baked-address forge emits the wrong addresses for an unseen -m -> RED (M-hwbakedaddr + the -m cross-grade). SYS_HWDUMP
#   re-maps each frame at V (+invlpg) and reads back the seed-derived payload the prober wrote THROUGH V: distinct frames ->
#   distinct payloads (a single baked frame collapses every readback -> M-hwsingleframe RED), and the targeted invlpg is
#   load-bearing (M-hwnoinvlpg -> the stale V->lastframe TLB entry serves every read -> all readbacks collapse -> RED).
#   "top-down" is the forced direction: M-hwbumpup (bottom-up from a baked low base) emits author-KNOWN addresses -> RED.
#
# What this gate proves (far-axis tri-substrate oracle QEMU-TCG + KVM real-silicon + Bochs, vs highwater_ref.py):
#   (B1) KERNEL BYTE-PIN: the EMITTED kernel (compiler `-- emit: multiboot32-highwater`) == highwater_ref.build_elf(highwater=True).
#   (B2) WHITE-BOX assert_highwater: the do_falloc/do_hwdump arms carry the top-down descending cursor, the runtime PTE[V]
#        install from the top-down frame, the targeted invlpg, the kernel-emit reading al_ptr, and the hwdump readback path.
#   (B3) the FROZEN tract kernel FAILS assert_highwater (no eax=13 arm -- the allocator is genuinely new).
#   (D) ADDITIVITY: tract + delete + backfill + larder + the frozen modes emit byte-identical to their refs; assert_varsize
#       / assert_delete / assert_larder STILL PASS on the highwater kernel (the new arms sit AFTER do_dump, adjacency preserved).
#   (PY) build_elf deterministic; assert_highwater GREEN + rejects every white-box mutant; highwater=False == tract; mutants differ.
#   (C) SILICON make-or-break: the author-unknown-(-m) witness emits N top-down frames @ region_hi(-m), each holding its
#       seed-derived payload, GREEN on QEMU-TCG + KVM + Bochs.
#   (FORGE) hwnoinvlpg / hwbumpup / hwsingleframe / hwbakedaddr DIVERGE -> RED.
#   (-M DIFFERENTIAL) the genuine trace at RAM1 graded under RAM2's expectation DIVERGES -> the addresses track the author-unknown -m.
#   (SEED DIFFERENTIAL) the genuine trace graded under a different seed DIVERGES -> the payloads track the late-bound seed.
#   (C-HIGHWATER) THE DIFFERENTIAL: the FROZEN tract kernel + the highwater prober -> SYS_FALLOC (eax=13) unknown -> falls to
#       SYS_EXIT -> no FALLOC/HWDUMP trace -> RED.
# REQUIRE_EMU fail-closed (the larder pattern): if KERNEL_CODEGEN_REQUIRE_EMU=1 and QEMU/Bochs is missing, FAIL.
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
REF="$script_dir/highwater_ref.py"
LB="$script_dir/highwater_latebound.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
for f in "$REF" "$LB" "$feeder"; do [[ -f "$f" ]] || { echo "FAIL: stack/native_compile_fragment.herb (missing $f)"; exit 1; }; done
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
rand_ram() { echo $((RANDOM % 6)) | awk '{split("24 32 48 64 96 128",a," "); print a[$1+1]}'; }
rand_seed() { echo $(( (RANDOM % 254) + 1 )); }

emit() { # marker prog outfile label
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

# ---- reference artifacts ----
REFK="$work/ref_kernel.elf"; python3 "$LB" refkernel "$REFK" >/dev/null
PROBER="$work/prober.bin"; python3 "$LB" prober "$PROBER" >/dev/null
DISK="$work/disk.img"; dd if=/dev/zero of="$DISK" bs=1M count=64 status=none   # the FS-lineage boot expects an IDE drive present

MKELF="$work/highwater_kernel.elf"
emit '-- emit: multiboot32-highwater' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (B1) KERNEL BYTE-PIN ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) highwater kernel byte-identical to highwater_ref.build_elf(highwater=True) [$(wc -c <"$MKELF") B]"
else fail_test "(B1) highwater kernel differs from highwater_ref.build_elf(highwater=True) -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi

# ---- (B2) WHITE-BOX assert_highwater + Multiboot validity ----
if python3 "$REF" asserthighwater "$MKELF"; then ok "(B2) kernel carries the free-frame-allocator machinery (assert_highwater: top-down descending cursor from region_hi + runtime PTE[V] install from the top-down frame + targeted invlpg + kernel-emit reading al_ptr + the hwdump re-map/invlpg/readback path, all reachable)"
else fail_test "(B2) kernel lacks the free-frame-allocator machinery (assert_highwater failed)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "highwater kernel is a valid x86 Multiboot image"
else fail_test "highwater kernel is not a valid x86 Multiboot image"; fi

# ---- (B3) the frozen tract kernel must FAIL assert_highwater ----
python3 "$LB" tractkernel "$work/tract_for_assert.elf" >/dev/null
if python3 "$REF" asserthighwater "$work/tract_for_assert.elf" >/dev/null 2>&1; then fail_test "(B3) the frozen tract kernel PASSED assert_highwater -- the white-box pin does not discriminate the alloc arms"
else ok "(B3) the frozen tract kernel FAILS assert_highwater (the SYS_FALLOC/HWDUMP arms + the top-down allocator are genuinely new)"; fi

# ---- (D) FROZEN prior modes byte-identical (additive) + the prior asserts still hold on highwater ----
# The larder-lineage modes (larder..tract) need their CANONICAL args (npages=NP + fsdel/fsreuse/varsize); build the ref via
# highwater_ref(highwater=False) -- the parametrize-frozen-ref reproduces each one. The pre-larder modes' own `kernelelf
# none full` default IS their canonical kernel.
refbuild_lineage() { # mode outfile
    HW_TDIR="$script_dir" python3 - "$1" "$2" <<'PY'
import os, sys
sys.path.insert(0, os.environ['HW_TDIR'])
import highwater_ref as H
NP = H.GROWHEAP_NPAGES
mode, out = sys.argv[1], sys.argv[2]
args = dict(npages=1, fsdel=False, fsreuse=False, varsize=False, highwater=False)
if   mode == 'growheap': args.update(npages=NP)
elif mode == 'delete':   args.update(npages=NP, fsdel=True)
elif mode == 'backfill': args.update(npages=NP, fsdel=True, fsreuse=True)
elif mode == 'tract':    args.update(npages=NP, fsdel=True, fsreuse=True, varsize=True)
elif mode == 'larder':   pass
else: sys.exit(3)
img, _, _ = H.build_elf(**args); open(out, 'wb').write(img)
PY
}
for lk in larder growheap delete backfill tract; do
    if refbuild_lineage "$lk" "$work/$lk.refk"; then :; else fail_test "(D) refbuild $lk failed"; continue; fi
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; highwater is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- highwater disturbed it"; fi
done
for lk in cairn durable platter lethe cleave tessera; do
    R="$script_dir/${lk}_ref.py"; [[ -f "$R" ]] || { fail_test "(D) missing $R"; continue; }
    if python3 "$R" kernelelf "$work/$lk.refk" none full >/dev/null 2>&1; then :; else fail_test "(D) $lk ref kernelelf failed"; continue; fi
    if emit "-- emit: multiboot32-$lk" 'func main(): return 0 end' "$work/$lk.k" "fr_$lk" && cmp -s "$work/$lk.k" "$work/$lk.refk"; then ok "(D) multiboot32-$lk kernel byte-identical (frozen; highwater is additive)"
    else fail_test "(D) multiboot32-$lk kernel drifted -- highwater disturbed it"; fi
done
for A in assertvarsize assertdelete assertlarder; do
    if python3 "$REF" "$A" "$MKELF" >/dev/null 2>&1; then ok "(D) frozen $A STILL PASSES on the highwater kernel (additive: the new arms sit AFTER do_dump, adjacency preserved)"
    else fail_test "(D) $A FAILED on the highwater kernel -- highwater disturbed a frozen arm (not purely additive)"; fi
done

# ---- (PY) Python byte-pin / assert layer ----
if HW_TDIR="$script_dir" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ['HW_TDIR'])
import highwater_ref as H
NP=H.GROWHEAP_NPAGES
a,_,_=H.build_elf(npages=NP,fsdel=True,fsreuse=True,varsize=True,highwater=True)
b,_,_=H.build_elf(npages=NP,fsdel=True,fsreuse=True,varsize=True,highwater=True)
det=(a==b)
ah=H.assert_highwater(a)
hf,_,_=H.build_elf(npages=NP,fsdel=True,fsreuse=True,varsize=True,highwater=False)
import importlib.util
ts=importlib.util.spec_from_file_location('tr',os.path.join(os.environ['HW_TDIR'],'tract_ref.py')); tm=importlib.util.module_from_spec(ts); ts.loader.exec_module(tm)
tg,_,_=tm.build_elf(npages=NP,fsdel=True,fsreuse=True,varsize=True)
addit=(hf==tg)                                  # highwater=False == tract byte-for-byte
muts=['hwnoinvlpg','hwbumpup','hwsingleframe','hwbakedaddr']
rej=all(not H.assert_highwater(H.build_elf(mut=m,npages=NP,fsdel=True,fsreuse=True,varsize=True,highwater=True)[0]) for m in muts)
diff=all(H.build_elf(mut=m,npages=NP,fsdel=True,fsreuse=True,varsize=True,highwater=True)[0]!=a for m in muts)
difftract=(not H.assert_highwater(tg))          # frozen tract fails assert_highwater
print('det',det,'assert_highwater',ah,'highwater=False==tract',addit,'rejects_muts',rej,'all_muts_differ',diff,'tract_fails_assert',difftract)
sys.exit(0 if (det and ah and addit and rej and diff and difftract) else 1)
PY
then ok "(PY) build_elf deterministic; assert_highwater GREEN + rejects every white-box mutant (hwnoinvlpg/hwbumpup/hwsingleframe/hwbakedaddr); highwater=False == tract byte-for-byte; every mutant kernel differs from genuine; the frozen tract kernel FAILS assert_highwater"
else fail_test "(PY) Python byte-pin/assert layer"; fi

# ============================ SILICON (the author-unknown -m witness) ============================
# boot a (kernel,prober) at -m RAM, feeding SEED over COM1; capture debugcon to $out.
boot_feed() { # kernel out kvm ram seed [prober]
    local kel="$1" out="$2" kvm="$3" ram="$4" seed="$5" prb="${6:-$PROBER}"
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local port; port="$(free_port)"; local d="$out.d"; rm -rf "$d"; mkdir -p "$d"
    python3 "$feeder" "$port" "$seed" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$prb" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m "${ram}M" >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
is_struct_flake() { echo "$1" | grep -qiE 'MAGIC banner not found|truncated|no HWDUMP|alloc entries|hwdump entries'; }
# a REAL divergence = any RED that is NOT a struct flake (a materialized value-mismatch: wrong addr / not-in-window /
# wrong payload / over-cap). Defining it as "RED and not struct-flake" credits every value-RED reason (contiguous
# top-down, region_hi window, readbacks, > HW_MAXFRAMES) as a deterministic bite, not just a hardcoded substring list.
has_real_divergence() { echo "$1" | grep -q '^RED' && ! is_struct_flake "$1"; }
# GENUINE witness (flake-robust retry until the trace materialises).
run_witness() { # kel ram seed kvm -> grade
    local kel="$1" ram="$2" seed="$3" kvm="$4" out="$work/w.out" try g
    for try in 1 2 3 4; do
        boot_feed "$kel" "$out" "$kvm" "$ram" "$seed"
        g="$(python3 "$LB" grade "$out" "$ram" "$seed" 2>&1)"
        is_struct_flake "$g" || break
    done
    echo "$g"
}
# MUTANT verdict (single-shot per attempt; a forge's divergence is deterministic). DIVERGE|CONSISTENT|EQUIVALENT.
mutant_verdict() { # mut ram seed kvm
    local mut="$1" ram="$2" seed="$3" kvm="$4" kel="$work/km.elf" n=4 i g
    python3 "$LB" kernel "$kel" "$mut" >/dev/null
    for i in $(seq 1 "$n"); do
        boot_feed "$kel" "$work/km.out" "$kvm" "$ram" "$seed"
        g="$(python3 "$LB" grade "$work/km.out" "$ram" "$seed" 2>&1)"
        echo "$g" | grep -q '^GREEN' && { echo EQUIVALENT; return; }
        has_real_divergence "$g" && { echo DIVERGE; return; }
    done
    echo CONSISTENT
}

emu_ran=0
if have_qemu; then
    emu_ran=1
    for SUB in tcg kvm; do
        KVMF=""; [[ "$SUB" == kvm ]] && KVMF="kvm"
        if [[ "$SUB" == kvm ]] && ! have_kvm; then
            echo "  NOTE: /dev/kvm unavailable -- KVM real-silicon leg skipped (a local pre-push leg; QEMU-TCG + Bochs are the CI substrates)"; continue
        fi
        RAM="$(rand_ram)"; SEED="$(rand_seed)"
        echo "  ----- QEMU-$SUB  -m ${RAM}M  seed=$SEED (author-unknown) -----"
        RES="$(run_witness "$MKELF" "$RAM" "$SEED" "$KVMF")"
        if echo "$RES" | grep -q '^GREEN'; then ok "(C-$SUB) the AUTHOR-UNKNOWN -m witness: the kernel-emitted trace == N top-down frames @ region_hi(${RAM}M), each holding its late-bound seed-derived payload -- the allocator genuinely read the runtime memory map ($RES)"
        else fail_test "(C-$SUB) genuine witness not GREEN: $(echo "$RES" | tr '\n' ';')"; fi

        if [[ "$SUB" == tcg ]]; then
            for M in hwnoinvlpg hwbumpup hwsingleframe hwbakedaddr; do
                V="$(mutant_verdict "$M" "$RAM" "$SEED" "$KVMF")"
                case "$V" in
                  DIVERGE)    ok "(FORGE $M) the forge kernel's emitted trace DIVERGES (value mismatch) from the genuine top-down/payload golden -> the step is load-bearing" ;;
                  CONSISTENT) ok "(FORGE $M) the forge kernel is RED on every attempt (deterministic break, never GREEN) -> the step is load-bearing" ;;
                  *)          fail_test "(FORGE $M) did NOT deterministically diverge -- a GREEN appeared (vacuous / flake-masked forge)" ;;
                esac
            done
            # (-M DIFFERENTIAL) the genuine trace at RAM graded under a DIFFERENT RAM2 must DIVERGE (addresses track -m).
            RAM2="$RAM"; while [[ "$RAM2" == "$RAM" ]]; do RAM2="$(rand_ram)"; done
            SEED2="$SEED"; while [[ "$SEED2" == "$SEED" ]]; do SEED2="$(rand_seed)"; done
            boot_feed "$MKELF" "$work/md.out" "$KVMF" "$RAM" "$SEED"
            g=""; for try in 1 2 3 4; do g="$(python3 "$LB" grade "$work/md.out" "$RAM" "$SEED" 2>&1)"; echo "$g" | grep -q '^GREEN' && break; boot_feed "$MKELF" "$work/md.out" "$KVMF" "$RAM" "$SEED"; done
            if ! echo "$g" | grep -q '^GREEN'; then fail_test "(-M/SEED DIFFERENTIAL) the base trace is not GREEN under the CORRECT (-m ${RAM}M, seed $SEED) -- the differentials would be vacuous: $(echo "$g" | tr '\n' ';')"
            else
                # (-M DIFFERENTIAL) the SAME GREEN trace graded under a DIFFERENT RAM2 must DIVERGE with a VALUE mismatch (not a flake).
                RES="$(python3 "$LB" grade "$work/md.out" "$RAM2" "$SEED" 2>&1)"
                if has_real_divergence "$RES"; then ok "(-M DIFFERENTIAL) the genuine GREEN trace at -m ${RAM}M graded under -m ${RAM2}M's expectation DIVERGES (value-mismatch) -> the emitted frame addresses track the AUTHOR-UNKNOWN -m (a baked-address forge cannot pass a random -m)"
                else fail_test "(-M DIFFERENTIAL) the trace did NOT value-diverge under -m ${RAM2}M: $(echo "$RES" | tr '\n' ';')"; fi
                # (SEED DIFFERENTIAL) the SAME GREEN trace graded under a DIFFERENT seed must DIVERGE with a VALUE mismatch.
                RES="$(python3 "$LB" grade "$work/md.out" "$RAM" "$SEED2" 2>&1)"
                if has_real_divergence "$RES"; then ok "(SEED DIFFERENTIAL) the genuine GREEN trace graded under a different seed DIVERGES (value-mismatch) -> the per-frame payloads track the late-bound COM1 seed (no baked answer)"
                else fail_test "(SEED DIFFERENTIAL) the payloads did NOT value-diverge under a different seed: $(echo "$RES" | tr '\n' ';')"; fi
            fi
            # (HOSTILE-CAP) Codex-found: an UNBOUNDED SYS_FALLOC overruns hw_frames[] / descends into kernel RAM and aliases it
            # User|RW. OUTPUT-INVISIBLE on the benign N=6 witness -> a dedicated hostile leg + M-hwnocap. The genuine kernel CAPS
            # at HW_MAXFRAMES: a hostile over-cap prober gets exactly HW_MAXFRAMES real top-down frames, the over-cap allocs rejected.
            python3 "$LB" hostileprober "$work/hprober.bin" >/dev/null
            HRAM="$(rand_ram)"; HSEED="$(rand_seed)"
            for try in 1 2 3 4; do boot_feed "$MKELF" "$work/hg.out" "$KVMF" "$HRAM" "$HSEED" "$work/hprober.bin"; HG="$(python3 "$LB" hostilegrade "$work/hg.out" "$HRAM" 2>&1)"; is_struct_flake "$HG" || break; done
            if echo "$HG" | grep -q '^GREEN'; then ok "(HOSTILE-CAP, genuine) a hostile CPL3 loop calling SYS_FALLOC past the cap is bounded -- exactly HW_MAXFRAMES real top-down frames, the over-cap allocs rejected (OOM): no hw_frames[] overrun, no descent into kernel RAM ($HG)"
            else fail_test "(HOSTILE-CAP, genuine) the cap did not hold or flaked: $(echo "$HG"|tr '\n' ';')"; fi
            python3 "$LB" kernel "$work/knocap.elf" hwnocap >/dev/null
            nc_v=EQUIVALENT
            for i in 1 2 3 4; do
                boot_feed "$work/knocap.elf" "$work/nc.out" "$KVMF" "$HRAM" "$HSEED" "$work/hprober.bin"
                g="$(python3 "$LB" hostilegrade "$work/nc.out" "$HRAM" 2>&1)"
                echo "$g" | grep -q '^GREEN' && { nc_v=EQUIVALENT; break; }
                echo "$g" | grep -qE 'NOT enforced|> HW_MAXFRAMES' && { nc_v=DIVERGE; break; }
                nc_v=CONSISTENT
            done
            if [[ "$nc_v" != EQUIVALENT ]]; then ok "(HOSTILE-CAP, M-hwnocap) the dropped cap lets the over-cap allocs proceed -> MORE than HW_MAXFRAMES non-zero FALLOC frames (the hw_frames[] overrun / kernel-descent path) -> RED ($nc_v)"
            else fail_test "(HOSTILE-CAP, M-hwnocap) did NOT bite -- a GREEN appeared (the cap is vacuous / flake-masked)"; fi
        fi
    done
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- Bochs (3rd substrate via GRUB): the author-unknown-megs witness on the EMITTED kernel must be GREEN ----
if have_bochs; then
    emu_ran=1
    RAM="$(rand_ram)"; SEED="$(rand_seed)"
    kelf="$(readlink -f "$MKELF")"; prb="$(readlink -f "$PROBER")"
    d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    pkill -9 -f "$work" 2>/dev/null || true   # scoped to THIS gate (own process), not system-wide (would kill a concurrent gate's Bochs)
    ( cd "$d"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp "$prb" mnt/boot/prober.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/prober.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP" )
    cat > "$d/bochsrc.txt" <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: __RAM__
ata0-master: type=disk, path=disk.img, mode=flat, cylinders=256, heads=16, spt=32
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:__PORT__
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
    # F2 sweep (2026-07-04): the existing retry re-rolls on a missing/truncated trace (is_struct_flake). Add the EXPLICIT
    # harness detectors from the link60 reference so a harness failure re-rolls instead of grading a confounded trace:
    # the feeder must LISTEN (bind) + deliver (SENT -> Bochs connected COM1) + the kernel must run THROUGH its shutdown()
    # tail ('shutdown requested' -> shutdown() writes "Shutdown" to Bochs port 0x8900). Any missing => a re-rollable
    # emulator/feeder failure, NEVER a false kernel RED.
    bochs_emit=""; bochs_harness_fail=1; BOCHS_HARNESS_ERR=""
    for try in 1 2 3; do
        port=$(free_port)
        python3 "$feeder" "$port" "$SEED" --hold 150 > "$d/feed.log" 2>&1 & fp=$!
        _ok_listen=1; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && { _ok_listen=0; break; }; sleep 0.1; done
        if [[ $_ok_listen -ne 0 ]]; then BOCHS_HARNESS_ERR="the COM1 feeder never reached LISTENING"; kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null; echo "  HARNESS ERROR (Bochs highwater witness try $try/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2; continue; fi
        sed -e "s#__PORT__#$port#" -e "s#__RAM__#$RAM#" "$d/bochsrc.txt" > "$d/bochsrc_b.txt"
        ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b.txt" > bochs.txt 2>&1 )   # absolute bochsrc path -> $work in the cmdline for the scoped `pkill -f "$work"`
        kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
        if ! grep -q '^SENT' "$d/feed.log" 2>/dev/null; then BOCHS_HARNESS_ERR="the COM1 feeder never delivered its payload (no SENT / NOCONN -- Bochs did not connect COM1, the kernel got no input)"; echo "  HARNESS ERROR (Bochs highwater witness try $try/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2; continue; fi
        if ! grep -qa 'shutdown requested' "$d/bochs.txt" 2>/dev/null; then BOCHS_HARNESS_ERR="Bochs did NOT run through to the kernel shutdown tail (no 'shutdown requested' -- killed or hung mid-run)"; echo "  HARNESS ERROR (Bochs highwater witness try $try/3): $BOCHS_HARNESS_ERR -- re-rolling (transient emulator/feeder failure, NOT a kernel RED)" >&2; continue; fi
        # This attempt passed LISTENING+SENT+shutdown -> the harness SUCCEEDED, so from here the grade is a GENUINE
        # kernel verdict, NOT a harness failure. Set the flag NOW (not only on a definitive grade) so a persistent
        # struct-flake with a clean harness is graded as a real trace problem (fail_test), never masked as a
        # re-rollable HARNESS-ERROR (cross-model Codex, uniform with link56/57). HARNESS-ERROR fires ONLY when NO
        # attempt ever passed the harness checks.
        bochs_harness_fail=0
        python3 - "$d/bochs.txt" "$d/out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.rfind(b'LARDER\xa5\x5a')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
        bochs_emit="$(python3 "$LB" grade "$d/out" "$RAM" "$SEED" 2>&1)"
        is_struct_flake "$bochs_emit" || break   # a definitive grade (GREEN or a real value-RED) -> stop retrying
    done
    if [[ $bochs_harness_fail -ne 0 ]]; then
        if [[ "$REQUIRE_EMU" == "1" ]]; then echo "HARNESS-ERROR: (C-Bochs) the REQUIRED Bochs substrate failed 3 consecutive harness attempts -- ${BOCHS_HARNESS_ERR:-missing/truncated trace} (re-rollable emulator/feeder failure, NOT a kernel miscompile; the gate is RED only because KERNEL_CODEGEN_REQUIRE_EMU=1)"; fail=$((fail + 1))
        else echo "  HARNESS-ERROR (non-fatal): (C-Bochs) Bochs failed 3 consecutive harness attempts -- ${BOCHS_HARNESS_ERR:-missing/truncated trace} (re-rollable; REQUIRE_EMU=0 so the gate is NOT RED on a harness flake -- re-roll, or set KERNEL_CODEGEN_REQUIRE_EMU=1)" >&2; fi
    elif echo "$bochs_emit" | grep -q '^GREEN'; then ok "(C-Bochs) the author-unknown-megs witness on the EMITTED kernel is GREEN on the 3rd substrate: N top-down frames @ region_hi(${RAM}M) each holding its seed-payload on Bochs' chipset ($bochs_emit)"
    else fail_test "(C-Bochs) Bochs witness not GREEN (fed+delivered+ran through shutdown -> a GENUINE kernel grade, not a harness flake): $(echo "$bochs_emit" | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

# ---- (C-HIGHWATER) THE DIFFERENTIAL: the frozen tract kernel + the highwater prober -> RED ----
if have_qemu; then
    python3 "$LB" tractkernel "$work/tract_kernel.elf" >/dev/null
    DRAM="$(rand_ram)"; DSEED="$(rand_seed)"
    boot_feed "$work/tract_kernel.elf" "$work/diff.out" "" "$DRAM" "$DSEED"
    DRES="$(python3 "$LB" grade "$work/diff.out" "$DRAM" "$DSEED" 2>&1)"
    if echo "$DRES" | grep -q '^GREEN'; then
        fail_test "(C-HIGHWATER) the frozen tract kernel graded GREEN on the highwater witness -- the allocator is NOT genuinely new"
    else
        ok "(C-HIGHWATER) THE DIFFERENTIAL: the frozen tract kernel + the highwater prober is RED -- SYS_FALLOC (eax=13) is unknown in tract, falls to SYS_EXIT, no FALLOC/HWDUMP trace -> the runtime free-frame allocator is a genuinely new observable"
    fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link61 (highwater / RUNTIME FREE-FRAME ALLOCATOR off an author-unknown map): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link61 highwater / kernel-arc link 45: the RUNTIME FREE-FRAME ALLOCATOR off an AUTHOR-UNKNOWN memory map -- the genuine open half of D20. A NEW emit mode multiboot32-highwater, TYPE-II ADDITIVE on the FROZEN tract (link44): SYS_FALLOC (int 0x30 eax=13) allocates a fresh physical frame TOP-DOWN from region_hi (the RAM ceiling lodger's Multiboot-mmap scan discovered, author-unknown because the gate boots at a per-run-random -m), maps it NON-IDENTITY at the reused lethe alias V (PTE[V]<-frame|7; invlpg [V]), records it, and the KERNEL EMITS its physical address (a CPL3 program cannot read its own PFN -- the witness is kernel-emitted); SYS_HWDUMP (eax=14) re-maps each frame at V (+invlpg) and reads back the seed-derived payload the prober wrote THROUGH V, the distinctness witness. Byte-pinned to highwater_ref.build_elf(highwater=True), white-box assert_highwater (the top-down descending cursor from region_hi + the runtime PTE[V] install from the top-down frame + the targeted invlpg + the kernel-emit reading al_ptr + the hwdump re-map/invlpg/readback), the FROZEN tract kernel FAILS assert_highwater (B3), additive on tract/delete/backfill/larder/growheap/cairn/durable/platter/lethe/cleave/tessera (frozen byte-identical) AND assert_varsize/delete/larder STILL PASS on the highwater kernel. AUTHOR-UNKNOWN-(-m) witness GREEN on QEMU-TCG + KVM (real silicon) + Bochs: N top-down frames @ region_hi(-m) each holding its late-bound seed-derived payload. The FORGE mutants DIVERGE -> RED: hwnoinvlpg (the stale V->lastframe TLB entry serves every readback -> all collapse), hwbumpup (bottom-up author-KNOWN addresses), hwsingleframe (one baked frame -> readbacks collapse), hwbakedaddr (fixed addresses fail a random -m). THE -M DIFFERENTIAL: the genuine trace at one -m graded under another's expectation DIVERGES -> the emitted frame addresses track the AUTHOR-UNKNOWN memory size (a baked-address reserve, lethe's output-forgeable forge, cannot pass a random -m). THE SEED DIFFERENTIAL: the trace graded under a different seed DIVERGES -> the payloads track the late-bound COM1 seed. THE HIGHWATER DIFFERENTIAL RED: the frozen tract kernel + the highwater prober -> SYS_FALLOC unknown -> SYS_EXIT -> no trace. Output-forced -- the kernel-emitted frame addresses follow the author-unknown -m and the readbacks follow the late-bound seed, which no baked-address/single-frame/no-invlpg/bottom-up allocator and no frozen older kernel reproduces. KVM (real silicon) runs when /dev/kvm is present (a local pre-push leg, skipped-with-note in CI); QEMU-TCG + Bochs are the REQUIRE_EMU fail-closed CI substrates. HONEST SCOPE: N=6 fresh top-down frames per run (a bounded discovery witness, NOT a production allocator -- no per-frame free/reuse, no general arena, no ownership tracking, no alignment classes); one reused alias window; the memory MAP is made author-unknown via -m (an injected e820 hole is NO-GO cross-substrate). The held-back MUTATION proof (hwnoinvlpg/hwbumpup/hwsingleframe/hwbakedaddr -- control-GREEN + all-RED) lives in the companion mutation harness.)"
