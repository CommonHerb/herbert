#!/usr/bin/env bash
# larder_phaseA_gate.sh -- the Phase-A make-or-break gate for "larder" (kernel-arc link 40 / native-codegen link 56):
# the first general-purpose DYNAMIC HEAP ALLOCATOR. Boots larder_ref.build_elf on QEMU-TCG + KVM (+ Bochs), feeding an
# AUTHOR-UNKNOWN seed-derived alloc/free witness over COM1 (larder_latebound.py), graded against the host FIRST-FIT
# golden. Proves: genuine GREEN on all substrates; every FORGE mutant RED; every CONFUSED-DEPUTY biting mutant RED on
# its hostile leg (robustness legs GREEN); gx/gy seed-differential RED; + the Python byte-pin/assert layer.
set -u
T="$(cd "$(dirname "$0")" && pwd)"
R="$T/larder_latebound.py"
feeder="$T/kernel_input_feed.py"
work="$(mktemp -d)"; trap 'rm -rf "$work"; pkill -9 -f "$work" 2>/dev/null || true' EXIT   # kill only THIS gate's bochs (scoped to its unique mktemp -- the bochs runs under $work/b.d with the absolute bochsrc path in its cmdline; a system-wide `pkill bochs` would false-RED a CONCURRENT gate's boot, the F4 class). (Packet A item 3, 2026-07-05.)
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
bad(){ echo "  FAIL: $1"; fail=$((fail+1)); }
have_qemu(){ command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm(){ [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }
have_bochs(){ command -v bochs >/dev/null && command -v parted >/dev/null && command -v grub-install >/dev/null && command -v xvfb-run >/dev/null && sudo -n true 2>/dev/null; }
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

DRIVER="$work/driver.bin"; python3 "$R" driver "$DRIVER"
DISK="$work/disk.img"; dd if=/dev/zero of="$DISK" bs=1M count=64 status=none

boot_feed(){ # kernel out kvm stream...
    local kel="$1" out="$2" kvm="$3"; shift 3
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local port; port="$(free_port)"; local d; d="$(mktemp -d)"
    python3 "$feeder" "$port" "$@" --hold 16 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 70 qemu-system-x86_64 "${acc[@]}" -kernel "$kel" -initrd "$DRIVER" -debugcon file:"$out" \
        -drive file="$DISK",format=raw,if=ide,index=0,media=disk,cache=writethrough \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null; rm -rf "$d"
}

build_kernel(){ python3 "$R" kernel "$1" "$2" >/dev/null; }   # out mut

# ---------- witness run: kernel-mut, graded against the GENUINE golden for `seed` ----------
run_witness(){ # kmut seed kvm  -> echoes grade result
    local kmut="$1" seed="$2" kvm="$3"
    local kel="$work/kw.elf"; build_kernel "$kel" "$kmut"
    local stream; stream="$(python3 "$R" stream "$seed")"
    local out="$work/w.out"; boot_feed "$kel" "$out" "$kvm" $stream
    python3 "$R" grade "$out" "$seed"
}
# ---------- hostile leg run: kernel-mut, graded against the GENUINE leg golden ----------
run_hostile(){ # kmut seed leg kvm
    local kmut="$1" seed="$2" leg="$3" kvm="$4"
    local kel="$work/kh.elf"; build_kernel "$kel" "$kmut"
    local stream; stream="$(python3 "$R" hostile_stream "$seed" "$leg")"
    local out="$work/h.out"; boot_feed "$kel" "$out" "$kvm" $stream
    python3 "$R" hostile_grade "$out" "$seed" "$leg"
}

echo "===================== Python byte-pin / assert layer ====================="
python3 - <<'PY'
import sys; sys.path.insert(0,'bootstrap/tests')
import larder_ref as L
a,_,_=L.build_elf(); b,_,_=L.build_elf()
det = (a==b)
ac = L.assert_larder(a); acc = L.assert_cairn(a)
muts=['bump','nosplit','nocoalesce','noprevmerge','nonextmerge','nosizewrap','nointeriorfree']
rej = all(not L.assert_larder(L.build_elf(mut=m)[0]) for m in muts)
diff = all(L.build_elf(mut=m)[0]!=a for m in muts+['freenoop'])
print('det',det,'assert_larder',ac,'assert_cairn',acc,'assert_rejects_muts',rej,'all_muts_differ',diff)
sys.exit(0 if (det and ac and acc and rej and diff) else 1)
PY
if [[ $? -eq 0 ]]; then ok "byte-pin: build_elf deterministic; assert_larder GREEN + rejects every white-box mutant; assert_cairn STILL GREEN (additive); every mutant differs"; else bad "Python byte-pin/assert layer"; fi

if have_qemu; then
  for SUB in tcg kvm; do
    KVMF=""; [[ "$SUB" == kvm ]] && KVMF="kvm"
    if [[ "$SUB" == kvm ]] && ! have_kvm; then echo "  NOTE: /dev/kvm unavailable -- KVM leg skipped"; continue; fi
    SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
    echo "===================== QEMU-$SUB  seed=$SEED ====================="
    RES="$(run_witness none "$SEED" "$KVMF")"; echo "$RES" | sed 's/^/    /'
    if echo "$RES" | grep -q '^GREEN'; then ok "($SUB) genuine witness: kernel-emitted trace==golden; split + prev-coalesce + next-coalesce + non-MRU reuse exercised; sentinels intact"; else bad "($SUB) genuine not GREEN"; fi

    if [[ "$SUB" == tcg ]]; then
      echo "--------------------- FORGE mutants (expect RED) ---------------------"
      for M in bump freenoop nosplit nocoalesce noprevmerge nonextmerge; do
        RES="$(run_witness "$M" "$SEED" "$KVMF")"
        if echo "$RES" | grep -q '^RED'; then ok "(forge $M) DIVERGES from the genuine golden -> the allocator step is load-bearing"; else bad "(forge $M) did NOT diverge"; echo "$RES"|sed 's/^/      /'; fi
      done

      echo "--------------------- CONFUSED-DEPUTY hostile legs ---------------------"
      # interior-free: genuine GREEN (interior ptr is a no-op), nointeriorfree RED (frees the containing chunk)
      RES="$(run_hostile none "$SEED" interior "$KVMF")"
      if echo "$RES" | grep -q '^GREEN'; then ok "(interior, genuine) interior-ptr free is a clean no-op -> both chunks survive"; else bad "(interior, genuine) not GREEN"; echo "$RES"|sed 's/^/      /'; fi
      RES="$(run_hostile nointeriorfree "$SEED" interior "$KVMF")"
      if echo "$RES" | grep -q '^RED'; then ok "(interior, M-nointeriorfree) range-match frees the CONTAINING chunk -> the live readback loses it -> RED"; else bad "(interior, M-nointeriorfree) did NOT go RED"; echo "$RES"|sed 's/^/      /'; fi
      # alloc(0): genuine GREEN (reject -> ptr 0), nosizewrap RED (returns a nonzero degenerate-chunk ptr)
      RES="$(run_hostile none "$SEED" alloc0 "$KVMF")"
      if echo "$RES" | grep -q '^GREEN'; then ok "(alloc0, genuine) size==0 rejected -> emits ptr 0, no degenerate chunk"; else bad "(alloc0, genuine) not GREEN"; echo "$RES"|sed 's/^/      /'; fi
      RES="$(run_hostile nosizewrap "$SEED" alloc0 "$KVMF")"
      if echo "$RES" | grep -q '^RED'; then ok "(alloc0, M-nosizewrap) accepts size==0 -> emits a NONZERO ptr to a 0-length chunk -> RED"; else bad "(alloc0, M-nosizewrap) did NOT go RED"; echo "$RES"|sed 's/^/      /'; fi
      # smallalloc: sub-sentinel sizes (2,3) -> genuine GREEN (size<4 floor), nosizewrap RED (accepts -> nonzero ptr to a <4B chunk = the SYS_DUMP cross-boundary edge)
      RES="$(run_hostile none "$SEED" smallalloc "$KVMF")"
      if echo "$RES" | grep -q '^GREEN'; then ok "(smallalloc, genuine) sub-4 sizes rejected (min-alloc = sentinel width) -> emits ptr 0, no sub-sentinel chunk"; else bad "(smallalloc, genuine) not GREEN"; echo "$RES"|sed 's/^/      /'; fi
      RES="$(run_hostile nosizewrap "$SEED" smallalloc "$KVMF")"
      if echo "$RES" | grep -q '^RED'; then ok "(smallalloc, M-nosizewrap) accepts size<4 -> NONZERO ptr to a chunk shorter than the 4-byte readback -> RED (closes the cross-boundary edge)"; else bad "(smallalloc, M-nosizewrap) did NOT go RED"; echo "$RES"|sed 's/^/      /'; fi
      # robustness legs (genuine survives + output-correct; no distinguishing mutant by design -- see report)
      for LEG in allochuge doublefree wildfree; do
        RES="$(run_hostile none "$SEED" "$LEG" "$KVMF")"
        if echo "$RES" | grep -q '^GREEN'; then ok "(robustness $LEG, genuine) allocator survives the malformed request + output is correct"; else bad "(robustness $LEG, genuine) not GREEN"; echo "$RES"|sed 's/^/      /'; fi
      done

      echo "--------------------- gx/gy seed-differential (expect RED) ---------------------"
      GX="$(python3 -c 'import os;print(os.urandom(8).hex())')"; GY="$(python3 -c 'import os;print(os.urandom(8).hex())')"
      kel="$work/kg.elf"; build_kernel "$kel" none
      sx="$(python3 "$R" stream "$GX")"; out="$work/gx.out"; boot_feed "$kel" "$out" "$KVMF" $sx
      RES="$(python3 "$R" grade "$out" "$GY")"     # grade gx's REAL output against gy's golden -> must mismatch
      if echo "$RES" | grep -q '^RED'; then ok "(gx/gy) gx's genuine output graded against gy's golden DIVERGES -> the trace tracks the late-bound seed (no baked answer)"; else bad "(gx/gy) did NOT diverge"; echo "$RES"|sed 's/^/      /'; fi
      # sanity: gx output vs gx golden must be GREEN
      RES="$(python3 "$R" grade "$out" "$GX")"
      if echo "$RES" | grep -q '^GREEN'; then ok "(gx/gy control) gx output vs gx golden GREEN"; else bad "(gx/gy control) gx vs gx not GREEN"; fi
    else
      # KVM: re-confirm the two confused-deputy biting mutants on the physical CPU (KVM has caught iret/segment bugs TCG hid)
      RES="$(run_hostile nointeriorfree "$SEED" interior "$KVMF")"
      if echo "$RES" | grep -q '^RED'; then ok "(KVM, M-nointeriorfree) interior-free corruption RED on the physical CPU"; else bad "(KVM, M-nointeriorfree) not RED"; fi
      RES="$(run_hostile nosizewrap "$SEED" alloc0 "$KVMF")"
      if echo "$RES" | grep -q '^RED'; then ok "(KVM, M-nosizewrap) alloc(0) acceptance RED on the physical CPU"; else bad "(KVM, M-nosizewrap) not RED"; fi
    fi
  done
else
  echo "  SKIP: qemu-system-x86_64 not found"
fi

# ---------- Bochs 3rd substrate: genuine witness GREEN ----------
echo "===================== Bochs (3rd substrate) ====================="
if have_bochs; then
  KELF="$work/kb.elf"; build_kernel "$KELF" none
  SEED="$(python3 -c 'import os;print(os.urandom(8).hex())')"
  STREAM="$(python3 "$R" stream "$SEED")"
  kelf="$(readlink -f "$KELF")"; drv="$(readlink -f "$DRIVER")"
  d="$work/b.d"; rm -rf "$d"; mkdir -p "$d"
  BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
  VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
  pkill -9 -f "$work" 2>/dev/null || true   # scoped to THIS gate's own bochs ($work/b.d in the cmdline), not a system-wide `pkill bochs` (would false-RED a concurrent gate -- F4). (Packet A item 3, 2026-07-05.)
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
  port=$(free_port)
  python3 "$feeder" "$port" $STREAM --hold 150 > "$d/feed.log" 2>&1 & fp=$!
  for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
  sed "s#__PORT__#$port#" "$d/bochsrc.txt" > "$d/bochsrc_b.txt"
  ( cd "$d"; rm -f disk.img.lock; xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f $d/bochsrc_b.txt" > bochs.txt 2>&1 )   # absolute bochsrc path -> $work in the cmdline for the scoped `pkill -f "$work"`
  kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
  python3 - "$d/bochs.txt" "$d/out" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
  echo "  captured debugcon bytes: $(wc -c < "$d/out")"
  RES="$(python3 "$R" grade "$d/out" "$SEED")"; echo "$RES" | sed 's/^/    /'
  if echo "$RES" | grep -q '^GREEN'; then ok "(Bochs) genuine witness GREEN on the 3rd substrate"; else bad "(Bochs) genuine not GREEN"; fi
else
  echo "  SKIP: bochs prerequisites missing"
fi

echo "======================================================================"
echo "larder Phase-A gate: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
