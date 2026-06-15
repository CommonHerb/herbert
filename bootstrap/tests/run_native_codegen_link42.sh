#!/usr/bin/env bash
# Native-codegen Link 42 / chiefturbo (link 26): RUNTIME-INDEXED MEMORY -- the compiled ring-3 module's first
# register-indexed load/store ([base+index*4], SS-relative) into a runtime-filled buffer on its User page. A new
# emit mode `module-chiefturbo` on the FROZEN holler kernel (TYPE-I, no kernel change). The make-or-break: the
# module fills a buffer with N=40 random 24-bit input WORDS (readword: 3 sys_reads each) via INDEXED STORE, then
# answers N runtime-index queries (read k; sys_write buf[k]) via INDEXED LOAD. N=40 > 31 named slots AND 24-bit
# words cannot pack 2-per-32-bit-slot AND the data is random+held-back -- so reproducing the gather output
# genuinely REQUIRES register-indexed memory (a closed-form/packing/baked forge is defeated). The binding is ALSO
# at the EMITTER layer (byte-pin to chiefturbo_ref.target_module + assert_indexed_load), the ultimate guard.
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, vs chiefturbo_ref.py):
#   (A) BYTE-PIN: the emitted module is BYTE-IDENTICAL to chiefturbo_ref.target_module(). A forge (recompute/
#       pack/bake) is a DIFFERENT module -> caught here. This is the chiefturbo analogue of mmj's union byte-pin.
#   (B) INDEXED (white-box): the emitted module carries an SS-relative SIB register-indexed load/store
#       (assert_indexed_load: 36 8B 04 8A or 36 89 14 88). A non-indexed forge has NONE.
#   (C) RANDOM-ACCESS SILICON: the module RUNS on the frozen holler kernel and gathers EXACTLY data[idx[j]] for
#       a random runtime index sequence; gx vs gy (different index walks) produce DIFFERENT output (X != Y).
#   (D) FROZEN KERNEL: the multiboot32-holler kernel is still byte-identical to holler_ref.build_elf() (TYPE-I).
#   (E) REJECT probes (renamed twins): module-chiefturbo REQUIRES an indexed op -- it rejects a program with no
#       bufget/bufset (a recursion-only mmj program), and rejects module_byte()/input_byte(). Each rejected
#       program COMPILES in its proper mode, so the reject is chiefturbo-specific.
# The held-back MUTATION proof (run_native_codegen_link42_mutation.sh) proves each design choice non-vacuous.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/chiefturbo_ref.py"
HREF="$script_dir/holler_ref.py"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing chiefturbo_ref.py $REF)"; exit 1; fi
if [[ ! -f "$feeder" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing input feeder $feeder)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# the chiefturbo forcing program (readword + fill[indexed store] + gather[indexed load] + main)
MODSRC="$(python3 "$REF" src)"

# ---- reference artifacts (the oracle) ----
REFM="$work/ref_module.bin"; python3 "$REF" module "$REFM"
KEND="$(python3 "$REF" kend)"
HREFK="$work/href_kernel.elf"; python3 "$HREF" cleanelf "$HREFK"   # the frozen holler kernel (D)

emit() { # marker prog outfile label -> writes outfile on accept; fail on reject
    local marker="$1" prog="$2" out="$3" label="$4"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%s\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}
reject_probe() { # label marker prog -> PASS iff the compiler refuses (no a.out)
    local label="$1" marker="$2" prog="$3"
    local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%b\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ -f "$cdir/a.out" ]]; then fail_test "reject $label: compiler ACCEPTED an out-of-subset program"; else ok "reject $label (refused: $(grep -o 'ERR [0-9]*' "$cdir/err" 2>/dev/null | head -1))"; fi
}
accept_probe() { # label marker prog -> PASS iff the compiler ACCEPTS (the renamed-twin: rejected-in-chiefturbo prog is valid elsewhere)
    local label="$1" marker="$2" prog="$3"
    local cdir="$work/acc.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%b\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ -f "$cdir/a.out" ]]; then ok "twin $label compiles in its proper mode ($(wc -c <"$cdir/a.out") B) -- chiefturbo-reject is specific"; else fail_test "twin $label should compile in its proper mode but was rejected"; fi
}

CMOD="$work/ct_module.bin"
KELF="$work/holler_kernel.elf"
emit '-- emit: module-chiefturbo' "$MODSRC" "$CMOD" module || exit 1
emit '-- emit: multiboot32-holler' 'func main(): return module_byte() end' "$KELF" kernel || exit 1

# ---- (A) BYTE-PIN: emitted module == chiefturbo_ref.target_module() byte-for-byte ----
if cmp -s "$CMOD" "$REFM"; then ok "(A) module byte-identical to chiefturbo_ref.target_module() [$(wc -c <"$CMOD") bytes; indexed memory bound at the emitter layer]"
else fail_test "(A) module differs from chiefturbo_ref.target_module() -- $(cmp "$CMOD" "$REFM" 2>&1 | head -1)"; fi

# ---- (B) INDEXED (white-box): the emitted module carries an SS-relative SIB register-indexed load/store ----
if python3 "$REF" indexed "$CMOD"; then ok "(B) emitted module carries an SS-relative SIB register-indexed load/store (genuine runtime-indexed memory; a forge has none)"
else fail_test "(B) emitted module has NO register-indexed load/store -- not genuinely indexed (forge-class)"; fi

# ---- (D) FROZEN KERNEL: the holler kernel is unchanged (chiefturbo is module-only/additive, TYPE-I) ----
if cmp -s "$KELF" "$HREFK"; then ok "(D) multiboot32-holler kernel byte-identical to holler_ref.build_elf() (frozen; chiefturbo is module-only)"
else fail_test "(D) holler kernel CHANGED by the chiefturbo edit -- $(cmp "$KELF" "$HREFK" 2>&1 | head -1)"; fi

if grub-file --is-x86-multiboot "$KELF" >/dev/null 2>&1; then ok "kernel is a valid x86 Multiboot image"
else fail_test "kernel is not a valid x86 Multiboot image"; fi

# ---- (E) REJECT probes (renamed twins): module-chiefturbo REQUIRES an indexed op ----
# a recursion-only program (no bufget/bufset) -> rejected by chiefturbo; valid in module-mmj.
reject_probe noindexed '-- emit: module-chiefturbo' 'func down(k): if k == 0: return 0 end  return sys_write(k) + down(k - 1) end\nfunc main(): let x = sys_read()  return down(x) end'
accept_probe noindexed_twin '-- emit: module-mmj' 'func down(k): if k == 0: return 0 end  return sys_write(k) + down(k - 1) end\nfunc main(): let x = sys_read()  return down(x) end'
# module_byte() is kernel-only; a chiefturbo program using it is rejected.
reject_probe modbyte '-- emit: module-chiefturbo' 'func main(): let base = bufbase()  let v = bufset(base, 0, module_byte())  return bufget(base, 0) end'
# input_byte() faults at CPL3.
reject_probe inputbyte '-- emit: module-chiefturbo' 'func main(): let base = bufbase()  let v = bufset(base, 0, input_byte())  return bufget(base, 0) end'

# ============================ SILICON (dual substrate) ============================
emu_ran=0

qemu_feed() { # kind out
    local kind="$1" out="$2"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" $stream --hold 8 > "$d/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 90 qemu-system-x86_64 -kernel "$KELF" -initrd "$CMOD" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}

if have_qemu; then
    emu_ran=1
    qemu_feed gx "$work/q.gx"
    if python3 "$REF" grade "$work/q.gx" "$KEND" gx >/dev/null 2>&1; then ok "QEMU module gathers N=40 random words by runtime index (gx), all data[idx[j]] correct"
    else fail_test "QEMU chiefturbo gx -> $(python3 "$REF" grade "$work/q.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
    qemu_feed gy "$work/q.gy"
    if python3 "$REF" grade "$work/q.gy" "$KEND" gy >/dev/null 2>&1; then ok "QEMU module gathers by a DIFFERENT runtime index walk (gy) -- the X!=Y random-access differential"
    else fail_test "QEMU chiefturbo gy -> $(python3 "$REF" grade "$work/q.gy" "$KEND" gy 2>&1 | tr '\n' ';')"; fi
    # cross-grade: gx output must NOT grade as gy (the output genuinely follows the runtime indices)
    if python3 "$REF" grade "$work/q.gx" "$KEND" gy >/dev/null 2>&1; then fail_test "QEMU gx output graded GREEN as gy -- gather output is NOT index-dependent (make-or-break vacuous)"
    else ok "QEMU gx output is RED when graded as gy (the gather output is genuinely runtime-index-driven)"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required (KERNEL_CODEGEN_REQUIRE_EMU=1) but qemu-system-x86_64 not found"; else echo "  SKIP: qemu-system-x86_64 not found (set KERNEL_CODEGEN_REQUIRE_EMU=1 to require)"; fi
fi

# ---- Bochs (2nd substrate, via GRUB disk) ----
bochs_run() { # kind e9out
    local kind="$1"; local e9="$2"
    local mod; mod="$(readlink -f "$CMOD")"; local kelf; kelf="$(readlink -f "$KELF")"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local d="$work/b.$kind.d"; mkdir -p "$d"
    local port; port=$(free_port)
    python3 "$feeder" "$port" $stream --hold 40 > "$d/feed.log" 2>&1 & local fp=$!
    local i; for i in $(seq 1 40); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
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
      sudo mkdir -p mnt/boot/grub; sudo cp "$kelf" mnt/boot/kernel.elf; sudo cp "$mod" mnt/boot/app.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/app.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
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
      xvfb-run -a bash -c "yes c | timeout -s KILL 120 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    python3 - "$d/bochs_out.txt" "$e9" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); end=i
if i>=0:
    for pat in (rb'\xde.\xad', rb'\xd4.{16}[\s\S]*?\xd5', rb'\xca.{16}\xcb'):
        m=None
        for mm in re.finditer(pat, d[i:], re.S): m=mm
        if m: end=max(end, i+m.end())
    open(sys.argv[2],'wb').write(d[i:end] if end>i else b'')
else: open(sys.argv[2],'wb').write(b'')
PY
}

if have_bochs; then
    emu_ran=1
    bochs_run gx "$work/b.gx"
    if python3 "$REF" grade "$work/b.gx" "$KEND" gx >/dev/null 2>&1; then ok "Bochs module gathers N=40 random words by runtime index (gx) on the 2nd substrate"
    else fail_test "Bochs chiefturbo gx -> $(python3 "$REF" grade "$work/b.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required (KERNEL_CODEGEN_REQUIRE_EMU=1) but bochs/parted/grub-install/xvfb-run/sudo not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + indexed + reject gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link42 (chiefturbo / RUNTIME-INDEXED MEMORY): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link42 chiefturbo / RUNTIME-INDEXED MEMORY)"
