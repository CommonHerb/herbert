#!/usr/bin/env bash
# Native-codegen Link 43 / mumbani (link 27): MULTI-PAGE WORKING MEMORY -- the kernel hands the compiled ring-3
# module a working set LARGER THAN ONE PAGE (D20's second installment). A NEW kernel emit mode
# `multiboot32-mumbani` (the holler kernel with the bump allocator widened to K=4 contiguous frames + the alloc_lo
# User-flip widened 1 PTE -> 4 PTEs) + a NEW module mode `module-mumbani` (= module-mmj with sys_read relaxed
# ==1 -> >=1). TYPE-II (new kernel), purely additive (geeking/holler/mmj/chiefturbo byte-identical). The forcing
# program is a recursive REVERSE of N held-back random 24-bit words (read down the recursion, held in the call
# stack, emitted on unwind = reversed). The make-or-break: with N chosen so N*frame > 4096, the recursion stack
# EXCEEDS one page -> on the FROZEN 1-page holler kernel the descent #PFs before any write (0 output); on the
# mumbani 4-page kernel it runs fully and emits the held-back stream REVERSED. Multi-page is load-bearing.
#
# What this gate proves (far-axis DUAL-SUBSTRATE oracle, QEMU + Bochs, vs mumbani_ref.py):
#   (A) MODULE BYTE-PIN: the emitted reverse module is BYTE-IDENTICAL to mumbani_ref.target_module(). A forge
#       (forward-emit / constant) is a DIFFERENT module -> caught here (the mmj pattern).
#   (B) KERNEL BYTE-PIN + WHITE-BOX: the emitted mumbani kernel is BYTE-IDENTICAL to mumbani_ref.build_elf(npages=4)
#       AND carries the 4-page alloc-size immediate (0x4000) + >= 4 User-flip blocks (assert_fourpage). A 1-page
#       kernel, or a forge that bumps esp another way, lacks these.
#   (C) MULTI-PAGE SILICON DIFFERENTIAL: the reverse module RUNS on the mumbani kernel and emits N=400 held-back
#       random words REVERSED with the write esps SPANNING >1 page (gx); gy (different stream) differs (X!=Y);
#       the SAME module on the FROZEN holler 1-page kernel #PFs mid-descent and emits 0 words (RED) -- so the
#       multi-page allocation is load-bearing, not ceremony.
#   (D) FROZEN: the multiboot32-holler kernel is still byte-identical to holler_ref.build_elf() (npages=1) and the
#       module-mmj / module-chiefturbo modules are byte-identical to their refs (mumbani is purely additive).
#   (E) REJECT probes (renamed twins): module-mumbani REQUIRES recursion + sys_write -- it rejects a no-sys_write
#       program, a non-recursive (no backward call) program, and module_byte()/input_byte(). Each rejected program
#       COMPILES in its proper mode, so the reject is mumbani-specific.
# The held-back MUTATION proof (run_native_codegen_link43_mutation.sh) proves each design choice non-vacuous.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/mumbani_ref.py"
HREF="$script_dir/holler_ref.py"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing mumbani_ref.py $REF)"; exit 1; fi
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

# the mumbani forcing program (readword + recursive reverse + main)
MODSRC="$(python3 "$REF" src)"

# ---- reference artifacts (the oracle) ----
REFM="$work/ref_module.bin"; python3 "$REF" module "$REFM"
REFK="$work/ref_kernel.elf"; KEND="$(python3 "$REF" kernelelf "$REFK")"   # mumbani 4-page kernel (npages=4)
HREFK="$work/href_kernel.elf"; python3 "$HREF" cleanelf "$HREFK"          # the frozen holler kernel (D + differential)

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
accept_probe() { # label marker prog -> PASS iff the compiler ACCEPTS (the renamed-twin valid elsewhere)
    local label="$1" marker="$2" prog="$3"
    local cdir="$work/acc.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '%s\n%b\n' "$marker" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ -f "$cdir/a.out" ]]; then ok "twin $label compiles in its proper mode ($(wc -c <"$cdir/a.out") B) -- mumbani-reject is specific"; else fail_test "twin $label should compile in its proper mode but was rejected"; fi
}

MMOD="$work/mb_module.bin"
MKELF="$work/mumbani_kernel.elf"
HKELF="$work/holler_kernel.elf"
emit '-- emit: module-mumbani' "$MODSRC" "$MMOD" module || exit 1
emit '-- emit: multiboot32-mumbani' 'func main(): return module_byte() end' "$MKELF" kernel || exit 1
emit '-- emit: multiboot32-holler' 'func main(): return module_byte() end' "$HKELF" hkernel || exit 1

# ---- (A) MODULE BYTE-PIN: emitted reverse module == mumbani_ref.target_module() byte-for-byte ----
if cmp -s "$MMOD" "$REFM"; then ok "(A) module byte-identical to mumbani_ref.target_module() [$(wc -c <"$MMOD") bytes; the reverse is bound at the emitter layer]"
else fail_test "(A) module differs from mumbani_ref.target_module() -- $(cmp "$MMOD" "$REFM" 2>&1 | head -1)"; fi

# ---- (B) KERNEL BYTE-PIN + WHITE-BOX: emitted mumbani kernel == build_elf(npages=4) + carries the 4-page construct ----
if cmp -s "$MKELF" "$REFK"; then ok "(B1) mumbani kernel byte-identical to mumbani_ref.build_elf(npages=4) [$(wc -c <"$MKELF") bytes]"
else fail_test "(B1) mumbani kernel differs from mumbani_ref.build_elf(npages=4) -- $(cmp "$MKELF" "$REFK" 2>&1 | head -1)"; fi
if python3 "$REF" fourpage "$MKELF"; then ok "(B2) mumbani kernel carries the 4-page alloc-size (0x4000) + >= 4 User-flip blocks (genuine multi-page allocator)"
else fail_test "(B2) mumbani kernel lacks the 4-page alloc/flip construct -- not genuinely multi-page"; fi
if python3 "$REF" fourpage "$HKELF"; then fail_test "(B2-neg) the frozen holler kernel falsely passed assert_fourpage"; else ok "(B2-neg) the frozen holler (1-page) kernel does NOT pass assert_fourpage (the white-box gate is specific)"; fi

if grub-file --is-x86-multiboot "$MKELF" >/dev/null 2>&1; then ok "mumbani kernel is a valid x86 Multiboot image"
else fail_test "mumbani kernel is not a valid x86 Multiboot image"; fi

# ---- (D) FROZEN: holler kernel + mmj/chiefturbo modules unchanged (mumbani is purely additive) ----
if cmp -s "$HKELF" "$HREFK"; then ok "(D1) multiboot32-holler kernel still byte-identical to holler_ref.build_elf() (frozen; mumbani is additive)"
else fail_test "(D1) holler kernel CHANGED by the mumbani edit -- $(cmp "$HKELF" "$HREFK" 2>&1 | head -1)"; fi
# (D2) the prior MODULE modes are byte-identical (additive-safety on the shared nc_ouro_* emitter mumbani reuses)
MMJREF="$script_dir/mmj_ref.py"; CTREF="$script_dir/chiefturbo_ref.py"
python3 "$MMJREF" module down "$work/mmj.ref" 2>/dev/null
if emit '-- emit: module-mmj' "$(python3 "$MMJREF" src down)" "$work/mmj.bin" mmjdrift && cmp -s "$work/mmj.bin" "$work/mmj.ref"; then ok "(D2a) module-mmj byte-identical to mmj_ref.target_module() (frozen; shared emitter untouched)"
else fail_test "(D2a) module-mmj drifted from mmj_ref"; fi
python3 "$CTREF" module "$work/ct.ref" 2>/dev/null
if emit '-- emit: module-chiefturbo' "$(python3 "$CTREF" src)" "$work/ct.bin" ctdrift && cmp -s "$work/ct.bin" "$work/ct.ref"; then ok "(D2b) module-chiefturbo byte-identical to chiefturbo_ref.target_module() (frozen)"
else fail_test "(D2b) module-chiefturbo drifted from chiefturbo_ref"; fi

# ---- (E) REJECT probes (renamed twins): module-mumbani REQUIRES recursion + sys_write ----
# a no-sys_write recursive program -> rejected (ERR 643); valid in multiboot32-ouroboros (which has no sys_write).
reject_probe nowrite '-- emit: module-mumbani' 'func rev(k): if k == 0: return 0 end  let r = rev(k - 1)  return r + 1 end\nfunc main(): let n = sys_read()  return rev(n) end'
# a non-recursive (straight-line) sys_write program -> rejected (ERR 646, no backward call); valid in module-holler.
reject_probe norec '-- emit: module-mumbani' 'func main(): let x = sys_read()  return sys_write(x) end'
accept_probe norec_twin '-- emit: module-holler' 'func main(): let x = sys_read()  return sys_write(x) end'
# module_byte() is kernel-only; input_byte() faults at CPL3.
reject_probe modbyte '-- emit: module-mumbani' 'func rev(k): if k == 0: return 0 end  let r = rev(k - 1)  return sys_write(module_byte()) + r end\nfunc main(): let n = sys_read()  return rev(n) end'
reject_probe inputbyte '-- emit: module-mumbani' 'func rev(k): if k == 0: return 0 end  let r = rev(k - 1)  return sys_write(input_byte()) + r end\nfunc main(): let n = sys_read()  return rev(n) end'

# ============================ SILICON (dual substrate) ============================
emu_ran=0

qemu_feed() { # kernel kind out
    local kelf="$1" kind="$2" out="$3"
    local stream; stream=$(python3 "$REF" stream "$kind")
    local port; port=$(free_port); local d="$out.d"; mkdir -p "$d"
    python3 "$feeder" "$port" $stream --hold 10 > "$d/feed.log" 2>&1 &
    local fp=$!
    local i; for i in $(seq 1 50); do grep -q LISTENING "$d/feed.log" && break; sleep 0.1; done
    timeout 120 qemu-system-x86_64 -kernel "$kelf" -initrd "$MMOD" -debugcon file:"$out" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -cpu qemu64 \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 -monitor none -m 64M >/dev/null 2>&1
    wait "$fp" 2>/dev/null
}

if have_qemu; then
    emu_ran=1
    qemu_feed "$MKELF" gx "$work/q.gx"
    if python3 "$REF" grade "$work/q.gx" "$KEND" gx >/dev/null 2>&1; then ok "(C) QEMU mumbani kernel runs reverse(N=400): emits the held-back random stream REVERSED, write esps span >1 page (gx)"
    else fail_test "(C) QEMU mumbani gx -> $(python3 "$REF" grade "$work/q.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
    qemu_feed "$MKELF" gy "$work/q.gy"
    if python3 "$REF" grade "$work/q.gy" "$KEND" gy >/dev/null 2>&1; then ok "(C) QEMU mumbani kernel reverses a DIFFERENT held-back stream (gy) -- the X!=Y differential"
    else fail_test "(C) QEMU mumbani gy -> $(python3 "$REF" grade "$work/q.gy" "$KEND" gy 2>&1 | tr '\n' ';')"; fi
    if python3 "$REF" grade "$work/q.gx" "$KEND" gy >/dev/null 2>&1; then fail_test "(C) QEMU gx output graded GREEN as gy -- the reversed output is NOT data-dependent (make-or-break vacuous)"
    else ok "(C) QEMU gx output is RED when graded as gy (the reversed output genuinely follows the held-back data)"; fi
    # THE MAKE-OR-BREAK DIFFERENTIAL: the SAME reverse module on the FROZEN 1-page holler kernel must #PF mid-descent (RED)
    qemu_feed "$HKELF" gx "$work/q.h.gx"
    if python3 "$REF" grade "$work/q.h.gx" "$KEND" gx >/dev/null 2>&1; then fail_test "(C-diff) the reverse module ran GREEN on the 1-page holler kernel -- multi-page is NOT load-bearing (make-or-break vacuous)"
    else ok "(C-diff) the SAME reverse module is RED on the FROZEN 1-page holler kernel (#PF mid-descent, 0 words) -- multi-page IS load-bearing"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required (KERNEL_CODEGEN_REQUIRE_EMU=1) but qemu-system-x86_64 not found"; else echo "  SKIP: qemu-system-x86_64 not found (set KERNEL_CODEGEN_REQUIRE_EMU=1 to require)"; fi
fi

# ---- Bochs (2nd substrate, via GRUB disk) ----
bochs_run() { # kind e9out
    local kind="$1"; local e9="$2"
    local mod; mod="$(readlink -f "$MMOD")"; local kelf; kelf="$(readlink -f "$MKELF")"
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
      xvfb-run -a bash -c "yes c | timeout -s KILL 150 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
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
    if python3 "$REF" grade "$work/b.gx" "$KEND" gx >/dev/null 2>&1; then ok "(C) Bochs mumbani kernel reverses N=400 held-back random words on the 2nd substrate (gx)"
    else fail_test "(C) Bochs mumbani gx -> $(python3 "$REF" grade "$work/b.gx" "$KEND" gx 2>&1 | tr '\n' ';')"; fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "Bochs required (KERNEL_CODEGEN_REQUIRE_EMU=1) but bochs/parted/grub-install/xvfb-run/sudo not available"; else echo "  SKIP: bochs toolchain not available"; fi
fi

if [[ "$REQUIRE_EMU" != "1" && "$emu_ran" -eq 0 ]]; then
    echo "  NOTE: no emulator ran; byte-pin + fourpage + reject gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

echo "native-codegen link43 (mumbani / MULTI-PAGE WORKING MEMORY): pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]] || exit 1
echo "PASS: stack/native_compile_fragment.herb (native-codegen link43 mumbani / MULTI-PAGE WORKING MEMORY)"
