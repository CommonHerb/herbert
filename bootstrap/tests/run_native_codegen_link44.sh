#!/usr/bin/env bash
# Native-codegen Link 44 / tandem (kernel-arc link 28): THE KERNEL RUNS TWO DISTINCT LOADED PROGRAMS AT ONCE --
# peer-isolated, kernel-scheduled, cooperative. The step from "a sandboxed-payload runner" to "an operating system
# that runs programs." A NEW kernel emit mode `multiboot32-tandem` (mods_count==2; two bump-allocated regions; a
# per-program User/Supervisor PTE-flip at the yield boundary so a hostile peer #PFs; a SYS_YIELD cooperative
# scheduler + a one-cell A->B mailbox) + a NEW module mode `module-tandem` (= module-mmj/mumbani subset + the new
# yield() op, op 52). TYPE-II (new kernel + new module op). Built on the FROZEN holler lineage; PURELY ADDITIVE
# (mmj/mumbani/chiefturbo modules + mumbani/holler kernels byte-identical).
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, + a manual KVM leg, vs tandem_ref.py):
#   (A) MODULE BYTE-PIN: the emitted programs A (producer) and B (consumer) are BYTE-IDENTICAL to
#       tandem_ref.module_A_real()/module_B_real() -- two SEPARATELY-COMPILED, distinct modules.
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted kernel == tandem_ref.build_elf() AND carries the mods_count==2
#       gate + the 2nd-region/2nd-module cells (assert_tandem; a 1-program kernel lacks them).
#   (C) SILICON: the two programs run INTERLEAVED under kernel control -- A reads N held-back random words, ECHOES
#       each (le32(w)) and YIELDs each to B; B receives each via yield, writes le32(3*w) (cross-yield-DERIVED). The
#       debugcon write-frames alternate A,B,A,B (the kernel-scheduled witness; run-A-then-B emits A*,B*). gx vs gy
#       (different held-back streams) differ; gx-as-gy is RED (data-dependent); switch counter >= 2N.
#   (C-PEER) HOSTILE-PEER #PF: a variant A that writes into B's region #PFs (err P|W|U=7, CR2 in B's region, cs
#       RPL3), caught by geeking fault->continue -- the un-fakeable PEER-isolation proof (a single address space
#       cannot produce a CR2-in-peer-window fault). The KVM-load-bearing leg.
#   (D) FROZEN: module-mmj/mumbani/chiefturbo + multiboot32-mumbani/holler kernels still byte-identical (additive).
#   (E) REJECT probes (renamed twins): module-tandem REQUIRES yield() (the cooperative primitive) and bans
#       module_byte()/input_byte(); each rejected program compiles in its proper mode.
# The held-back MUTATION proof (run_native_codegen_link44_mutation.sh) proves each design choice non-vacuous
# (M-singleslot / M-noflip / M-noswap).
set -u
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
REF="$script_dir/tandem_ref.py"
feeder="$script_dir/kernel_input_feed.py"
REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing feeder $feeder)"; exit 1; fi

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

ASRC="$(python3 "$REF" srcA)"; BSRC="$(python3 "$REF" srcB)"

# ---- reference artifacts (the oracle) ----
REFA="$work/ref_A.bin"; python3 "$REF" modA "$REFA"
REFB="$work/ref_B.bin"; python3 "$REF" modB "$REFB"
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK" none full)"
REFH="$work/ref_hostile.bin"; python3 "$REF" modhostile "$REFH"
REFHR="$work/ref_hostile_read.bin"; python3 "$REF" modhostileread "$REFHR"

emit() { # marker prog outfile label -> writes outfile on accept; fail on reject
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}
reject_probe() { # label marker prog
    local label="$1" marker="$2" prog="$3"
    local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%b\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ -f "$cdir/a.out" ]]; then fail_test "reject $label: compiler ACCEPTED an out-of-subset program"; else ok "reject $label (refused: $(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; fi
}
accept_probe() { # label marker prog
    local label="$1" marker="$2" prog="$3"
    local cdir="$work/acc.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%b\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ -f "$cdir/a.out" ]]; then ok "twin $label compiles in its proper mode ($(wc -c <"$cdir/a.out") B) -- tandem-reject is specific"; else fail_test "twin $label should compile in its proper mode but was rejected"; fi
}

AMOD="$work/A.bin"; BMOD="$work/B.bin"; MKELF="$work/tandem_kernel.elf"
emit '-- emit: module-tandem' "$ASRC" "$AMOD" modA || exit 1
emit '-- emit: module-tandem' "$BSRC" "$BMOD" modB || exit 1
emit '-- emit: multiboot32-tandem' 'func main(): return 0 end' "$MKELF" kernel || exit 1

# ---- (A) MODULE BYTE-PINS ----
if cmp -s "$AMOD" "$REFA"; then ok "(A1) program A byte-identical to tandem_ref.module_A_real() [$(wc -c <"$AMOD") B; producer: read+echo+yield]"
else fail_test "(A1) program A differs from module_A_real() -- $(cmp "$AMOD" "$REFA" 2>&1 | head -1)"; fi
if cmp -s "$BMOD" "$REFB"; then ok "(A2) program B byte-identical to tandem_ref.module_B_real() [$(wc -c <"$BMOD") B; consumer: yield+derive+write]"
else fail_test "(A2) program B differs from module_B_real() -- $(cmp "$BMOD" "$REFB" 2>&1 | head -1)"; fi
if cmp -s "$AMOD" "$BMOD"; then fail_test "(A3) A and B are byte-IDENTICAL (not two distinct programs)"; else ok "(A3) A and B are DISTINCT modules (two separately-compiled programs)"; fi

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) tandem kernel byte-identical to tandem_ref.build_elf() [$(wc -c <"$MKELF") B]"
else fail_test "(B1) tandem kernel differs from tandem_ref.build_elf() -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" tandem "$MKELF"; then ok "(B2) kernel carries mods_count==2 + the 2nd-region/2nd-module cells (genuine two-program kernel)"
else fail_test "(B2) kernel lacks the two-program construct (mods==2 / alloc_lo2 / modstart2)"; fi
if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "tandem kernel is a valid x86 Multiboot image"
else fail_test "tandem kernel is not a valid x86 Multiboot image"; fi

# ---- (D) FROZEN prior modes (purely additive) ----
MMJREF="$script_dir/mmj_ref.py"; CTREF="$script_dir/chiefturbo_ref.py"; MUMREF="$script_dir/mumbani_ref.py"; HREF="$script_dir/holler_ref.py"
python3 "$MMJREF" module down "$work/mmj.ref" 2>/dev/null
if emit '-- emit: module-mmj' "$(python3 "$MMJREF" src down)" "$work/mmj.bin" mmjd && cmp -s "$work/mmj.bin" "$work/mmj.ref"; then ok "(D1) module-mmj byte-identical (frozen; shared nc_ouro_* emitter untouched by the yield op)"
else fail_test "(D1) module-mmj drifted -- the yield op disturbed the shared emitter"; fi
python3 "$MUMREF" module "$work/mum.ref" 2>/dev/null
if emit '-- emit: module-mumbani' "$(python3 "$MUMREF" src)" "$work/mum.bin" mumd && cmp -s "$work/mum.bin" "$work/mum.ref"; then ok "(D2) module-mumbani byte-identical (frozen)"
else fail_test "(D2) module-mumbani drifted"; fi
python3 "$CTREF" module "$work/ct.ref" 2>/dev/null
if emit '-- emit: module-chiefturbo' "$(python3 "$CTREF" src)" "$work/ct.bin" ctd && cmp -s "$work/ct.bin" "$work/ct.ref"; then ok "(D3) module-chiefturbo byte-identical (frozen)"
else fail_test "(D3) module-chiefturbo drifted"; fi
python3 "$MUMREF" kernelelf "$work/mumk.ref" >/dev/null 2>&1
if emit '-- emit: multiboot32-mumbani' 'func main(): return module_byte() end' "$work/mumk.bin" mumkd && cmp -s "$work/mumk.bin" "$work/mumk.ref"; then ok "(D4) multiboot32-mumbani kernel byte-identical (frozen)"
else fail_test "(D4) multiboot32-mumbani kernel drifted"; fi

# ---- (E) REJECT probes (renamed twins): module-tandem REQUIRES yield(); bans module_byte()/input_byte() ----
# a no-yield recursive sys_write program -> rejected (ERR 652); valid in module-mmj (which has no yield requirement).
reject_probe noyield '-- emit: module-tandem' 'func down(k): if k == 0: return 0 end  return sys_write(k) + down(k - 1) end\nfunc main(): let n = sys_read()  return down(n) end'
accept_probe noyield_twin '-- emit: module-mmj' 'func down(k): if k == 0: return 0 end  return sys_write(k) + down(k - 1) end\nfunc main(): let n = sys_read()  return down(n) end'
# module_byte()/input_byte() banned (CPL3 sandbox discipline)
reject_probe modbyte '-- emit: module-tandem' 'func main(): let a = yield(0)  return sys_write(module_byte()) end'
reject_probe inputbyte '-- emit: module-tandem' 'func main(): let a = yield(0)  return sys_write(input_byte()) end'

# ============================ SILICON (dual substrate + KVM) ============================
emu_ran=0
qemu_feed() { # kernel modA modB kind out [kvm]
    local kelf="$1" ma="$2" mb="$3" kind="$4" out="$5" kvm="${6:-}"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" $stream --hold 12 > "$d/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    local acc=(); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host) || acc=(-cpu qemu64)
    timeout 120 qemu-system-x86_64 "${acc[@]}" -kernel "$kelf" -initrd "$ma,$mb" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}
qemu_hostile() { # kernel hostileA modB out [kvm]
    local kelf="$1" ha="$2" mb="$3" out="$4" kvm="${5:-}"
    local acc=(); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host) || acc=(-cpu qemu64)
    timeout 60 qemu-system-x86_64 "${acc[@]}" -kernel "$kelf" -initrd "$ha,$mb" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -monitor none -m 64M >/dev/null 2>&1
}

if have_qemu; then
    emu_ran=1
    qemu_feed "$MKELF" "$AMOD" "$BMOD" gx "$work/q.gx"
    if python3 "$REF" grade "$work/q.gx" "$KEND" gx >/dev/null 2>&1; then ok "(C) QEMU: two programs run INTERLEAVED -- A echoes N held-back words, B writes 3*w cross-yield, ABAB order (gx)"
    else fail_test "(C) QEMU gx -> $(python3 "$REF" grade "$work/q.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
    qemu_feed "$MKELF" "$AMOD" "$BMOD" gy "$work/q.gy"
    if python3 "$REF" grade "$work/q.gy" "$KEND" gy >/dev/null 2>&1; then ok "(C) QEMU: a DIFFERENT held-back stream (gy) -- the X!=Y differential"
    else fail_test "(C) QEMU gy -> $(python3 "$REF" grade "$work/q.gy" "$KEND" gy 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" grade "$work/q.gx" "$KEND" gy >/dev/null 2>&1; then fail_test "(C) QEMU gx graded GREEN as gy -- output NOT data-dependent (make-or-break vacuous)"
    else ok "(C) QEMU gx is RED graded as gy (the interleaved output genuinely follows the held-back data)"; fi
    qemu_hostile "$MKELF" "$REFH" "$BMOD" "$work/q.hw"
    if python3 "$REF" gradehostile "$work/q.hw" "$KEND" write >/dev/null 2>&1; then ok "(C-PEER) QEMU: hostile A WRITING B's region #PFs (exact err 7, CR2 in B's window not kernel/A, RPL3) -- integrity isolation"
    else fail_test "(C-PEER) QEMU hostile-write -> $(python3 "$REF" gradehostile "$work/q.hw" "$KEND" write 2>&1 | tr '\n' ';')"; fi
    qemu_hostile "$MKELF" "$REFHR" "$BMOD" "$work/q.hr"
    if python3 "$REF" gradehostile "$work/q.hr" "$KEND" read >/dev/null 2>&1; then ok "(C-PEER) QEMU: hostile A READING B's region #PFs (exact err 5, CR2 in B's window) -- confidentiality isolation (peer A cannot read B)"
    else fail_test "(C-PEER) QEMU hostile-read -> $(python3 "$REF" gradehostile "$work/q.hr" "$KEND" read 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not found"; else echo "  SKIP: qemu-system-x86_64 not found"; fi
fi

# ---- KVM (real silicon): the iret-into-a-different-ring3-frame + PTE-flip leg (chiefturbo iret-DS-null class) ----
if have_kvm; then
    qemu_feed "$MKELF" "$AMOD" "$BMOD" gx "$work/k.gx" kvm
    if python3 "$REF" grade "$work/k.gx" "$KEND" gx >/dev/null 2>&1; then ok "(C-KVM) real silicon: the two-program interleave runs byte-identical on KVM (gx)"
    else fail_test "(C-KVM) KVM gx -> $(python3 "$REF" grade "$work/k.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
    qemu_hostile "$MKELF" "$REFH" "$BMOD" "$work/k.hw" kvm
    if python3 "$REF" gradehostile "$work/k.hw" "$KEND" write >/dev/null 2>&1; then ok "(C-PEER-KVM) real silicon: the hostile-peer WRITE #PF fires on KVM (err 7; the load-bearing isolation leg)"
    else fail_test "(C-PEER-KVM) KVM hostile-write -> $(python3 "$REF" gradehostile "$work/k.hw" "$KEND" write 2>&1 | tr '\n' ';')"; fi
    qemu_hostile "$MKELF" "$REFHR" "$BMOD" "$work/k.hr" kvm
    if python3 "$REF" gradehostile "$work/k.hr" "$KEND" read >/dev/null 2>&1; then ok "(C-PEER-KVM) real silicon: the hostile-peer READ #PF fires on KVM (err 5; iret-to-CPL3 + flip on real silicon)"
    else fail_test "(C-PEER-KVM) KVM hostile-read -> $(python3 "$REF" gradehostile "$work/k.hr" "$KEND" read 2>&1 | tr '\n' ';')"; fi
else
    echo "  NOTE: /dev/kvm not available -- KVM real-silicon leg skipped (run locally with KVM for the iret-DS-null class)"
fi

# ---- Bochs (2nd substrate via GRUB; two `module` lines) ----
bochs_run() { # kind e9out
    local kind="$1"; local e9="$2"
    local ma; ma="$(readlink -f "$AMOD")"; local mb; mb="$(readlink -f "$BMOD")"; local kelf; kelf="$(readlink -f "$MKELF")"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local d="$work/b.$kind.d"; mkdir -p "$d"
    local port; port=$(free_port)
    python3 "$feeder" "$port" $stream --hold 40 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
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
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp "$ma" mnt/boot/a.bin; sudo cp "$mb" mnt/boot/b.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/a.bin\n module /boot/b.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 32
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    python3 - "$d/bochs_out.txt" "$e9" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c')
open(sys.argv[2],'wb').write(d[i:] if i>=0 else b'')
PY
}
if have_bochs; then
    emu_ran=1
    bochs_run gx "$work/b.gx"
    if python3 "$REF" grade "$work/b.gx" "$KEND" gx >/dev/null 2>&1; then ok "(C) Bochs: the two programs run interleaved on the 2nd substrate (gx; GRUB delivers two module lines)"
    else fail_test "(C) Bochs gx -> $(python3 "$REF" grade "$work/b.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required but not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + white-box + reject gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link44 (tandem / TWO DISTINCT LOADED PROGRAMS): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link44 tandem / TWO PROGRAMS)"
