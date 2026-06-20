#!/usr/bin/env bash
# Native codegen Link 33 (lodger / the SEVENTEENTH kernel-arc link): the PROGRAM-LIFECYCLE GERM.
# The kernel runs ONE program it did NOT bake at build time -- a raw Multiboot MODULE the loader
# (GRUB / QEMU -initrd) delivers. The kernel discovers it at runtime via mbinfo, parses the memory
# map, allocates ONE floored non-overlapping stack page (D20: a bare-metal bump allocator with a
# physical-ownership exclusion set), transfers control to the module's runtime-discovered entry
# indirectly, collects the answer, and halts clean. Selected by the anchored first-line directive
# "-- emit: multiboot32-lodger" (a 17th emit mode; the 16 prior modes are byte-identical, so the
# self-host fixpoint gen2==gen1 holds). Graded, like lingo..cloggard, on the far-axis DUAL-SUBSTRATE
# oracle (QEMU + Bochs), but the late-bound thing is promoted from a socket BYTE (trukfit/contigo/
# cloggard) to a separate PROGRAM: the SAME kernel ELF, fed module X vs module Y, emits f(X) != f(Y).
#
# WHY GENUINELY NEW: across 16 links the kernel only ever ran code it BAKED IN; lodger runs a
# build-unknown artifact. The gate proves:
#  (1) RUNTIME DISCOVERY -- the module is at DIFFERENT physical addresses on QEMU vs Bochs (the
#      e_shoff-class divergence), so no hardcoded entry works on both; the indirect call through the
#      runtime-read mod_start cell is load-bearing (M-modaddr REDs on the substrate that relocates it).
#  (2) HONEST ALLOCATION (D20) -- the kernel parses the mmap and bump-allocates a floored,
#      exclusion-respecting page; the HOST RE-DERIVES the identical policy from the kernel's emitted
#      ownership table and demands EQUALITY (not mere non-overlap), so a trivially-safe or hardcoded
#      allocator REDs (M-noexclude/M-noexclbuf/M-hardcodeaddr).
#  (3) THE MODULE IS A WITNESS -- before returning it emits CA CA <esp@entry+4> <eip> FE FE to 0xE9;
#      the host asserts esp==alloc_hi (the module REALLY ran on the allocated page) and eip==mod_start+10
#      (it REALLY executed from its loader-placed entry) -- making the
#      aliasing/provenance mutations bite DETERMINISTICALLY (M-aliasframe/M-provlit), not by luck.
#  (4) X != Y differential, same sha kernel -- a baked answer is impossible; the module CARRIES it.
#
# HONEST SCOPE / RESIDUE (audited-assertion, named): a CANONICAL-CODEGEN proof for the fixed probes
# (echo / transform / frame-locals); 32-bit flat PM, no paging/ring-3/FS/ELF-parse; ONE module, ONE
# page; emulator-graded, emulators version-pinned in CI. The module-DELIVERY fact + the allocator's
# no-overlap correctness on ARBITRARY layouts have no independent oracle -- minimized by the
# host-recompute equality, the module witness, the cross-substrate placement divergence (QEMU 64M/
# 256M/6G + Bochs 32M), and the build-unknown module defeating a baked answer. A roundup(mod_end)-
# style allocator coincides with the full policy when the module is topmost (the current layouts) --
# the exclusion machinery is proven LOAD-BEARING by M-noexclude AND M-noexclbuf, but exclusion
# correctness on a hostile layout stays an assertion. Pays D20's first honest installment.
#
# The white-box head pin is an EXACT byte cmp against the silicon-proven reference
# (bootstrap/tests/lodger_ref.py = audits/link17-lifecycle/step0); ANY head drift REDs. The held-back
# MUTATION proof (run_native_codegen_link33_mutation.sh) builds reference echo variants with one design
# defect each (the gate pins compiler-output==reference) and asserts each grades RED, control GREEN.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/lodger_ref.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ "${NATIVE_CODEGEN_ORACLE:-golden}" == "c" && ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing lodger_ref.py $REF)"; exit 1; fi

source "$script_dir/native_codegen_oracle.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
native_codegen_ensure_compiler "$work/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
le32_val() { local h="${1:$2:8}"; echo $(( 16#${h:6:2}${h:4:2}${h:2:2}${h:0:2} )); }

# pre-built witness modules (host-built, build-unknown to the kernel): X->0x5A, Y->0xA7 (computed),
# FAT (X + 4MiB junk + deep stack), STACK (deep-stack spray). Same byte-size X/Y, same filename.
MODX="$work/mod_x.bin"; MODY="$work/mod_y.bin"; MODFAT="$work/mod_fat.bin"; MODSTK="$work/mod_stk.bin"
python3 "$REF" module X "$MODX"; python3 "$REF" module Y "$MODY"
python3 "$REF" module FAT "$MODFAT"; python3 "$REF" module STACK "$MODSTK"
GX=0x5A; GY=0xA7   # module-carried answers

# ---- probes: vary the compiled body; module_byte() read exactly once, straight-line --------
prog_src() {
    case "$1" in
      lg_echo)  echo 'func main(): return module_byte() end' ;;
      lg_xform) echo 'func main(): return module_byte() * 3 end' ;;
      lg_local) echo 'func main(): let x = module_byte()  let y = 7  return x + y end' ;;
    esac
}
# host answer byte for a probe given the module value v (mod 256, matching u64 modular-wrap)
host_byte() { python3 -c "v=$2
print({'lg_echo':v,'lg_xform':(v*3)&0xFF,'lg_local':(v+7)&0xFF}['$1'])"; }
ALL_PROBES="lg_echo lg_xform lg_local"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-lodger\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

elf_meta() { # elf -> echoes "esp_top kend" (decimal) from the phdr p_memsz; also P12 sanity
    local elf="$1"
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local memsz; memsz=$(le32_val "$eh" 144)
    echo $(( 1048576 + memsz ))
}

static_gates() { # label elf
    local label="$1" elf="$2" ok=1
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; ok=0; }
    local hx; hx=$(xxd -p "$elf" | tr -d '\n')
    local mb_o mb_valid_count=0 mb_valid_off=-1 mb_f mb_c
    for (( mb_o=0; mb_o+12 <= 8192 && mb_o*2+24 <= ${#hx}; mb_o+=4 )); do
        [[ "${hx:$(( mb_o*2 )):8}" == "02b0ad1b" ]] || continue
        mb_f=$(le32_val "$hx" $(( mb_o*2 + 8 ))); mb_c=$(le32_val "$hx" $(( mb_o*2 + 16 )))
        if [[ $(( (16#1BADB002 + mb_f + mb_c) % (1 << 32) )) -eq 0 ]]; then
            mb_valid_count=$(( mb_valid_count + 1 )); mb_valid_off=$mb_o
        fi
    done
    [[ "$mb_valid_count" -eq 1 ]] || { fail_test "$label static: $mb_valid_count checksum-valid Multiboot headers (want 1)"; ok=0; }
    [[ "$mb_valid_off" -eq 4096 ]] || { fail_test "$label static: valid MB header at off $mb_valid_off (want 4096)"; ok=0; }
    # MEMINFO bit (flags bit1) MUST be set -- lodger requests the memory map.
    mb_f=$(le32_val "$hx" $(( 4096*2 + 8 )))
    [[ $(( mb_f & 2 )) -eq 2 ]] || { fail_test "$label static: MB header flags ($mb_f) lacks MEMINFO bit"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

elf_gates() { # label elf  (P12: e_entry==V0, single PT_LOAD, sizes by value)
    local label="$1" elf="$2" ok=1
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    [[ "$(le32_val "$eh" 48)" -eq 1048588 ]] || { fail_test "$label elf(P12): e_entry != 1048588"; ok=0; }
    [[ "$(le32_val "$eh" 56)" -eq 52 ]] || { fail_test "$label elf(P12): e_phoff != 52"; ok=0; }
    [[ "$(( 16#${eh:90:2}${eh:88:2} ))" -eq 1 ]] || { fail_test "$label elf(P12): e_phnum != 1"; ok=0; }
    [[ "$(le32_val "$eh" 104)" -eq 1 ]] || { fail_test "$label elf(P12): PT_LOAD type != 1"; ok=0; }
    [[ "$(le32_val "$eh" 112)" -eq 4096 ]] || { fail_test "$label elf(P12): p_offset != 4096"; ok=0; }
    [[ "$(le32_val "$eh" 120)" -eq 1048576 ]] || { fail_test "$label elf(P12): p_vaddr != 1048576"; ok=0; }
    [[ "$(le32_val "$eh" 152)" -eq 7 ]] || { fail_test "$label elf(P12): p_flags != 7"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

whitebox_head() { # label elf  (EXACT head + EXACT epilogue == silicon-proven reference)
    local label="$1" elf="$2" ok=1
    local esp_top; esp_top=$(elf_meta "$elf")
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local filesz; filesz=$(le32_val "$eh" 136); local code_len=$(( filesz - 12 ))
    # (P0) EXACT 1493-byte HEAD at code offset 0.
    local got want
    got=$(dd if="$elf" bs=1 skip=4108 count=1493 status=none 2>/dev/null | xxd -p | tr -d '\n')
    want=$(python3 "$REF" head "$(printf '%x' "$esp_top")")
    [[ "$got" == "$want" ]] || { fail_test "$label wb(P0): head != exact 1493-byte lodger reference (esp_top=0x$(printf '%x' "$esp_top"))"; ok=0; }
    # (P-epi) EXACT 58-byte epilogue at code end -- together with the head pin and the straight-line
    # module_byte body subset (which cannot express an 'out'), this pins EVERY 0xE9 emit in the image
    # to the head's ownership-dump sites + the epilogue's DE/AD answer frame. So the kernel CANNOT forge
    # the module's CA/FE witness frame (closes the cross-model 'kernel spoofs 0xE9 witness' finding).
    local epigot epiwant
    epigot=$(dd if="$elf" bs=1 skip=$(( 4108 + code_len - 58 )) count=58 status=none 2>/dev/null | xxd -p | tr -d '\n')
    epiwant=$(python3 "$REF" epi)
    [[ "$epigot" == "$epiwant" ]] || { fail_test "$label wb(P-epi): epilogue != exact 58-byte reference (a stray 0xE9 emit site?)"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

qemu_run() { # elf mod mem outfile
    timeout 60 qemu-system-x86_64 -kernel "$1" -initrd "$2" -debugcon file:"$4" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -monitor none -cpu qemu64 -m "$3" >/dev/null 2>&1 || true
}

bochs_run() { # elf mod outfile  -> sets BOCHS_SHUTDOWN file
    local elf="$1" mod="$2" outfile="$3"
    local W; W="$(mktemp -d)"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then echo "0" > "$work/.bsd"; : > "$outfile"; rm -rf "$W"; return; fi
    ( cd "$W"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$elf" mnt/boot/kernel.elf; sudo cp "$mod" mnt/boot/app.bin
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n module /boot/app.bin\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 32
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 90 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null > "$work/.bsd"
    # extract the binary 0xE9 stream: from the first 0x9C entry tag through the DE??AD answer frame.
    python3 - "$W/bochs_out.txt" "$outfile" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); m=re.search(rb'\xde.\xad', d[i:]) if i>=0 else None
open(sys.argv[2],'wb').write(d[i:i+m.end()] if (i>=0 and m) else b'')
PY
    rm -rf "$W"
}

reject_probe() { # label directive "<body>"
    local label="$1" directive="$2" prog="$3"
    local cdir="$work/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- "%s\n%b\n" "$directive" "$prog" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]] && grub-file --is-x86-multiboot "$cdir/a.out" >/dev/null 2>&1; then
        fail_test "reject $label: out-of-subset program emitted a valid multiboot image"; return 1
    fi
    return 0
}

# ============================ run the gates ==================================
if ! have_qemu; then
    if [[ "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but qemu missing)"; exit 1; fi
    echo "SKIP: native-codegen link33 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi

for label in $ALL_PROBES; do
    elf="$work/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    elf_gates "$label" "$elf" || continue
    whitebox_head "$label" "$elf" || continue
    kend=$(elf_meta "$elf")              # esp_top == kend
    kh=$(printf '%x' "$kend")
    bx=$(host_byte "$label" 90)          # 0x5A
    by=$(host_byte "$label" 167)         # 0xA7
    [[ "$bx" != "$by" ]] || { fail_test "$label: host bytes X==Y -- probe not module-distinguishing"; continue; }
    sha_before=$(sha256sum "$elf" | cut -d' ' -f1)
    ok=1
    # QEMU: X at 64M/256M/6G (placement divergence); Y/FAT/STACK at 64M.
    qemu_run "$elf" "$MODX" 64M "$work/$label.q64x.bin"; python3 "$REF" grade "$work/$label.q64x.bin" "$kh" "$(printf '%x' "$bx")" - 64 >/dev/null 2>&1 || { fail_test "$label QEMU 64M X: $(python3 "$REF" grade "$work/$label.q64x.bin" "$kh" "$(printf '%x' "$bx")" - 64 2>&1 | tr '\n' ' ')"; ok=0; }
    qemu_run "$elf" "$MODX" 256M "$work/$label.q256x.bin"; python3 "$REF" grade "$work/$label.q256x.bin" "$kh" "$(printf '%x' "$bx")" - 256 >/dev/null 2>&1 || { fail_test "$label QEMU 256M X"; ok=0; }
    qemu_run "$elf" "$MODX" 6G "$work/$label.q6gx.bin"; python3 "$REF" grade "$work/$label.q6gx.bin" "$kh" "$(printf '%x' "$bx")" - 6144 >/dev/null 2>&1 || { fail_test "$label QEMU 6G X"; ok=0; }
    qemu_run "$elf" "$MODY" 64M "$work/$label.q64y.bin"; python3 "$REF" grade "$work/$label.q64y.bin" "$kh" "$(printf '%x' "$by")" - 64 >/dev/null 2>&1 || { fail_test "$label QEMU 64M Y"; ok=0; }
    qemu_run "$elf" "$MODFAT" 64M "$work/$label.qfat.bin"; python3 "$REF" grade "$work/$label.qfat.bin" "$kh" "$(printf '%x' "$bx")" - 64 >/dev/null 2>&1 || { fail_test "$label QEMU 64M FAT"; ok=0; }
    qemu_run "$elf" "$MODSTK" 64M "$work/$label.qstk.bin"; python3 "$REF" grade "$work/$label.qstk.bin" "$kh" "$(printf '%x' "$bx")" - 64 >/dev/null 2>&1 || { fail_test "$label QEMU 64M STACK"; ok=0; }
    if [[ "$run_bochs" -eq 1 ]]; then
        bochs_run "$elf" "$MODX" "$work/$label.bx.bin"; bsd=$(cat "$work/.bsd" 2>/dev/null || echo 0)
        { python3 "$REF" grade "$work/$label.bx.bin" "$kh" "$(printf '%x' "$bx")" - >/dev/null 2>&1 && [[ "$bsd" -ge 1 ]]; } || { fail_test "$label Bochs X (shutdown=$bsd): $(python3 "$REF" grade "$work/$label.bx.bin" "$kh" "$(printf '%x' "$bx")" - 2>&1 | tr '\n' ' ')"; ok=0; }
        bochs_run "$elf" "$MODY" "$work/$label.by.bin"; bsd=$(cat "$work/.bsd" 2>/dev/null || echo 0)
        { python3 "$REF" grade "$work/$label.by.bin" "$kh" "$(printf '%x' "$by")" - >/dev/null 2>&1 && [[ "$bsd" -ge 1 ]]; } || { fail_test "$label Bochs Y (shutdown=$bsd)"; ok=0; }
    fi
    sha_after=$(sha256sum "$elf" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]] || { fail_test "$label: image changed between runs"; ok=0; }
    [[ "$ok" -eq 1 ]] && pass=$((pass + 1))
done

# ---- reject probes (+ twins): the lodger subset is straight-line, one module_byte, no calls ----
reject_probe call         '-- emit: multiboot32-lodger'  'func h(): return 2 end\nfunc main(): return h() + module_byte() end'
reject_probe call_twin    '-- emit: multiboot32-lodger'  'func g(): return 4 end\nfunc main(): return g() + module_byte() end'
reject_probe branch       '-- emit: multiboot32-lodger'  'func main(): let x = module_byte()  if x == 5: return 1 else: return 2 end end'
reject_probe branch_twin  '-- emit: multiboot32-lodger'  'func main(): let y = module_byte()  if y == 9: return 3 else: return 4 end end'
reject_probe nomodule     '-- emit: multiboot32-lodger'  'func main(): return 7 end'
reject_probe nomodule_twin '-- emit: multiboot32-lodger' 'func main(): return 9 end'
reject_probe twomodule    '-- emit: multiboot32-lodger'  'func main(): return module_byte() + module_byte() end'
reject_probe twomodule_twin '-- emit: multiboot32-lodger' 'func main(): return module_byte() * module_byte() end'
reject_probe mainarg      '-- emit: multiboot32-lodger'  'func main(p): return p + module_byte() end'
reject_probe mainarg_twin '-- emit: multiboot32-lodger'  'func main(k): return k - module_byte() end'
# module_byte() OUTSIDE the lodger mode must NOT compile to a valid kernel image (input mode + others).
reject_probe modbyte_in_input '-- emit: multiboot32-input'  'func main(): return module_byte() end'
reject_probe modbyte_in_plain '-- emit: multiboot32'        'func main(): return module_byte() end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 12))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link33 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link33 / lodger / seventeenth kernel-arc link: the PROGRAM-LIFECYCLE GERM -- the kernel runs ONE build-unknown Multiboot MODULE: discovers it via mbinfo at runtime, parses the memory map, bump-allocates ONE floored non-overlapping stack page (D20), indirect-calls the runtime-discovered entry, collects the answer, halts clean. SAME kernel ELF fed module X (0x5A) vs Y (0xA7) -> f(X) != f(Y), a baked answer impossible. $pass checks: static MB+MEMINFO, ELF-P12, white-box EXACT-1493-byte-head vs the silicon-proven lodger_ref, QEMU substrate (64M/256M/6G + FAT + deep-STACK modules; host re-derives the bump-allocator policy from the emitted ownership table and demands EQUALITY; the module emits a CA/FE WITNESS frame binding esp==alloc_hi + eip==mod_start+10), Bochs substrate (GRUB module, module at a DIFFERENT physical address -> runtime discovery forced; clean shutdown), 12 rejects with twins (calls/branches/zero-or-two-module_byte/main-arg out of subset; module_byte() outside the lodger mode rejected); graded vs a host-recompute + module-witness on the dual-substrate oracle -- a CANONICAL-CODEGEN proof for the fixed probes; pays D20's first installment)"
exit 0
