#!/usr/bin/env bash
# Native codegen Link 35 (nokta / the NINETEENTH kernel-arc link): MEMORY ISOLATION via paging U/S.
# Extends trikonderoga (link 18: ring-3 privileged-op isolation of a build-unknown Multiboot MODULE run at
# CPL3) by turning PAGING ON under the ring boundary: kernel pages are mapped Supervisor (PTE U/S=0), the
# module's code+stack pages User (PTE U/S=1), so a CPL3 plain `mov [kernel_cell],imm` into kernel RAM faults
# #PF (the CPU is the judge) -- closing trikon's honest residue (a CPL3 module could still write kernel RAM).
# Selected by "-- emit: multiboot32-nokta". Graded on the far-axis DUAL-SUBSTRATE oracle (QEMU + Bochs) vs
# the silicon-proven reference (nokta_ref.py), which was also proven byte-identical on KVM real silicon.
#
# WHAT THE GATE PROVES (the make-or-break: the #PF can ONLY be genuine CPU-enforced U/S):
#  (1) WRITE-isolation -- a hostile CPL3 `mov [present,mapped,Supervisor kernel cell], imm` -> #PF errcode
#      EXACTLY 0x07 (P=1,W=1,U=1: a User WRITE to a present Supervisor page; NOT a not-present P=0 scottie
#      miss, NOT trikon's #GP errcode 0), CR2=the exact kernel target, saved CS RPL=3, the write never lands.
#  (2) READ-isolation (confidentiality) -- a hostile CPL3 READ of the same cell -> #PF errcode EXACTLY 0x05
#      (P=1,W=0,U=1): the kernel page is genuinely SUPERVISOR (read AND write blocked), not merely User+RO.
#  (3) PAGE-TABLE tamper closure -- a hostile CPL3 write to the canary's own PTE (inside the PT) -> #PF
#      errcode 0x07, CR2=the PTE: a CPL3 module cannot patch the page tables to escalate (the trikon path).
#  (4) The 19a carry -- a hostile `out 0xE9` STILL #GP(0)s under paging (privileged-op isolation survives).
#  (5) X != Y differential, same sha kernel -- the benign module CARRIES its answer (f(X)=0x5A != f(Y)=0xA7),
#      having first WRITTEN ITS OWN User page (the partition is real in both directions).
#  (6) HONEST ALLOCATION (inherited from lodger, D20) -- host re-derives the bump-allocator policy.
#
# HONEST SCOPE / RESIDUE (audited-assertion, named): memory-isolation covers write/read/page-table-tamper,
# each witnessed at one representative cell but enforced uniformly by construction (every PTE Supervisor, the
# runtime flip touches only the module's 2 pages). Fixed 16 MiB identity map (a >16 MiB module is a SAFE
# deny). In-image page tables => D20 NOT widened. CANONICAL-CODEGEN proof for the fixed probes.
# Emulator-graded (CI versions pinned). The CPU-authored #PF frame is in-band forgeable by a hypothetical
# malicious KERNEL -- closed exactly as lodger/trikon: the EXACT prefix (head+handlers+tables+paging+PD+PT,
# 24564 bytes) + EXACT 58-byte epilogue byte-pin + a no-`out`/no-`int` BODY OUT-SCAN account for every emit
# site, so a kernel != reference is rejected.
#
# The white-box pin is an EXACT byte cmp against nokta_ref.py (= audits/link19-nokta/step0). The held-back
# MUTATION proof (run_native_codegen_link35_mutation.sh) builds reference variants with one design defect
# each and asserts each grades RED, control GREEN.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
REF="$script_dir/nokta_ref.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"

if [[ ! -x "$HERBERT" ]]; then echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at $HERBERT)"; exit 1; fi
if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
if [[ ! -f "$REF" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing nokta_ref.py $REF)"; exit 1; fi

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

# build-unknown modules (host-built). X->0x5A, Y->0xA7 (computed). HOST=hostile out->#GP. HOSW=hostile write
# ->#PF(7). HOSR=hostile read->#PF(5). HOSPT=hostile PT-write->#PF(7,CR2=PTE). FAT=X+4MiB junk.
MODX="$work/mod_x.bin"; MODY="$work/mod_y.bin"; MODH="$work/mod_h.bin"; MODFAT="$work/mod_fat.bin"
MODW="$work/mod_w.bin"; MODR="$work/mod_r.bin"; MODPT="$work/mod_pt.bin"
python3 "$REF" module X "$MODX"; python3 "$REF" module Y "$MODY"
python3 "$REF" module HOST "$MODH"; python3 "$REF" module FAT "$MODFAT"
python3 "$REF" module HOSW "$MODW"; python3 "$REF" module HOSR "$MODR"; python3 "$REF" module HOSPT "$MODPT"
PTADDR="$(python3 "$REF" ptaddr)"
GX=0x5A; GY=0xA7
PREFIX_LEN=24564

prog_src() {
    case "$1" in
      nk_echo)  echo 'func main(): return module_byte() end' ;;
      nk_xform) echo 'func main(): return module_byte() * 3 end' ;;
      nk_local) echo 'func main(): let x = module_byte()  let y = 7  return x + y end' ;;
    esac
}
host_byte() { python3 -c "v=$2
print({'nk_echo':v,'nk_xform':(v*3)&0xFF,'nk_local':(v+7)&0xFF}['$1'])"; }
ALL_PROBES="nk_echo nk_xform nk_local"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$work/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    printf -- '-- emit: multiboot32-nokta\n%s\n' "$(prog_src "$label")" > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

elf_meta() { # elf -> esp_top (decimal) = 0x100000 + p_memsz
    local elf="$1"
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local memsz; memsz=$(le32_val "$eh" 144)
    echo $(( 1048576 + memsz ))
}

static_gates() { # label elf  (multiboot + PAGE_ALIGN|MEMINFO header)
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
    mb_f=$(le32_val "$hx" $(( 4096*2 + 8 )))
    [[ $(( mb_f & 2 )) -eq 2 ]] || { fail_test "$label static: MB header flags ($mb_f) lacks MEMINFO bit"; ok=0; }
    [[ $(( mb_f & 1 )) -eq 1 ]] || { fail_test "$label static: MB header flags ($mb_f) lacks PAGE_ALIGN bit"; ok=0; }
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

whitebox() { # label elf  (EXACT 24564-byte prefix + EXACT 58-byte epilogue + BODY OUT-SCAN vs nokta_ref)
    local label="$1" elf="$2" ok=1
    local esp_top; esp_top=$(elf_meta "$elf")
    local eh; eh=$(dd if="$elf" bs=1 count=84 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local filesz; filesz=$(le32_val "$eh" 136); local code_len=$(( filesz - 12 ))
    local got want
    got=$(dd if="$elf" bs=1 skip=4108 count="$PREFIX_LEN" status=none 2>/dev/null | xxd -p | tr -d '\n')
    want=$(python3 "$REF" prefix "$(printf '%x' "$esp_top")")
    [[ "$got" == "$want" ]] || { fail_test "$label wb(prefix): head+handlers+tables+paging+PD+PT != EXACT ${PREFIX_LEN}-byte nokta_ref (esp_top=0x$(printf '%x' "$esp_top"))"; ok=0; }
    local epigot epiwant
    epigot=$(dd if="$elf" bs=1 skip=$(( 4108 + code_len - 58 )) count=58 status=none 2>/dev/null | xxd -p | tr -d '\n')
    epiwant=$(python3 "$REF" epi)
    [[ "$epigot" == "$epiwant" ]] || { fail_test "$label wb(epi): epilogue != EXACT 58-byte reference (a stray emit site?)"; ok=0; }
    # BODY OUT-SCAN: the region between the pinned prefix and the pinned epilogue must contain NO port-I/O
    # (out: e6/e7/ee/ef) and NO trap/escape (int: cd; syscall/sysenter: 0f05/0f34) opcode -- so "no out in the
    # body" is a gate ASSERTION, not a trust assumption. The fixed-probe bodies (module_byte()+small arith)
    # contain none of these as code OR immediate; a malicious body that smuggled one in would RED here.
    local bodyhex; bodyhex=$(dd if="$elf" bs=1 skip=$(( 4108 + PREFIX_LEN )) count=$(( code_len - PREFIX_LEN - 58 )) status=none 2>/dev/null | xxd -p | tr -d '\n')
    if [[ "$bodyhex" =~ (e6|e7|ee|ef|cd|0f05|0f34) ]]; then
        fail_test "$label wb(body-scan): body contains a forbidden out/int/syscall opcode byte (${BASH_REMATCH[1]})"; ok=0
    fi
    [[ "$ok" -eq 1 ]]
}

qemu_run() { # elf mod mem outfile
    timeout 60 qemu-system-x86_64 -kernel "$1" -initrd "$2" -debugcon file:"$4" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -monitor none -cpu qemu64 -m "$3" >/dev/null 2>&1 || true
}

bochs_run() { # elf mod outfile  -> sets shutdown count in $work/.bsd
    local elf; elf="$(readlink -f "$1")"; local mod; mod="$(readlink -f "$2")"; local outfile="$3"
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
    python3 - "$W/bochs_out.txt" "$outfile" <<'PY'
import sys,re
d=open(sys.argv[1],'rb').read(); i=d.find(b'\x9c'); end=i
if i>=0:
    m=re.search(rb'\xde.\xad', d[i:], re.S)
    g=re.search(rb'\xf0.{4}.{4}.{4}.{4}\xf1', d[i:], re.S)
    p=re.search(rb'\xd0.{4}.{4}.{4}.{4}.{4}\xd1', d[i:], re.S)
    if m: end=max(end, i+m.end())
    if g: end=max(end, i+g.end())
    if p: end=max(end, i+p.end())
open(sys.argv[2],'wb').write(d[i:end] if (i>=0 and end>i) else b'')
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
    echo "SKIP: native-codegen link35 substrate legs (no qemu; authoritative run is the kernel-codegen CI workflow)"; exit 0
fi
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi

for label in $ALL_PROBES; do
    elf="$work/$label.elf"
    compile_probe "$label" "$elf" || continue
    static_gates "$label" "$elf" || continue
    elf_gates "$label" "$elf" || continue
    whitebox "$label" "$elf" || continue
    kend=$(elf_meta "$elf"); kh=$(printf '%x' "$kend")
    bx=$(host_byte "$label" 90); by=$(host_byte "$label" 167)
    [[ "$bx" != "$by" ]] || { fail_test "$label: host bytes X==Y -- probe not module-distinguishing"; continue; }
    sha_before=$(sha256sum "$elf" | cut -d' ' -f1)
    ok=1
    # benign: X at 64M/256M/6G (placement divergence) + Y at 64M + FAT at 64M (wrote its own User page, exit int 0x30)
    qemu_run "$elf" "$MODX" 64M "$work/$label.q64x.bin";  python3 "$REF" grade "$work/$label.q64x.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 64M X: $(python3 "$REF" grade "$work/$label.q64x.bin" "$kh" "$(printf '%x' "$bx")" benign 2>&1 | tr '\n' ' ')"; ok=0; }
    qemu_run "$elf" "$MODX" 256M "$work/$label.q256x.bin"; python3 "$REF" grade "$work/$label.q256x.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 256M X"; ok=0; }
    qemu_run "$elf" "$MODX" 6G "$work/$label.q6gx.bin";    python3 "$REF" grade "$work/$label.q6gx.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 6G X"; ok=0; }
    qemu_run "$elf" "$MODY" 64M "$work/$label.q64y.bin";   python3 "$REF" grade "$work/$label.q64y.bin" "$kh" "$(printf '%x' "$by")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 64M Y"; ok=0; }
    qemu_run "$elf" "$MODFAT" 64M "$work/$label.qfat.bin"; python3 "$REF" grade "$work/$label.qfat.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 || { fail_test "$label QEMU 64M FAT"; ok=0; }
    # isolation probes (kernel-body-independent: the module faults before the body runs) -- run on every probe.
    qemu_run "$elf" "$MODH" 64M "$work/$label.qh.bin";  python3 "$REF" grade "$work/$label.qh.bin" "$kh" 00 hostile     >/dev/null 2>&1 || { fail_test "$label QEMU HOSTILE-out #GP: $(python3 "$REF" grade "$work/$label.qh.bin" "$kh" 00 hostile 2>&1 | tr '\n' ' ')"; ok=0; }
    qemu_run "$elf" "$MODW" 64M "$work/$label.qw.bin";  python3 "$REF" grade "$work/$label.qw.bin" "$kh" 00 pfault      >/dev/null 2>&1 || { fail_test "$label QEMU hostile-WRITE #PF7: $(python3 "$REF" grade "$work/$label.qw.bin" "$kh" 00 pfault 2>&1 | tr '\n' ' ')"; ok=0; }
    qemu_run "$elf" "$MODR" 64M "$work/$label.qr.bin";  python3 "$REF" grade "$work/$label.qr.bin" "$kh" 00 pfault_read >/dev/null 2>&1 || { fail_test "$label QEMU hostile-READ #PF5: $(python3 "$REF" grade "$work/$label.qr.bin" "$kh" 00 pfault_read 2>&1 | tr '\n' ' ')"; ok=0; }
    qemu_run "$elf" "$MODPT" 64M "$work/$label.qpt.bin"; python3 "$REF" grade "$work/$label.qpt.bin" "$kh" 00 pfault_pt "0x$PTADDR" >/dev/null 2>&1 || { fail_test "$label QEMU hostile-PT-write #PF7: $(python3 "$REF" grade "$work/$label.qpt.bin" "$kh" 00 pfault_pt 0x$PTADDR 2>&1 | tr '\n' ' ')"; ok=0; }
    if [[ "$run_bochs" -eq 1 ]]; then
        bochs_run "$elf" "$MODX" "$work/$label.bx.bin"; bsd=$(cat "$work/.bsd" 2>/dev/null || echo 0)
        { python3 "$REF" grade "$work/$label.bx.bin" "$kh" "$(printf '%x' "$bx")" benign >/dev/null 2>&1 && [[ "$bsd" -ge 1 ]]; } || { fail_test "$label Bochs X (shutdown=$bsd): $(python3 "$REF" grade "$work/$label.bx.bin" "$kh" "$(printf '%x' "$bx")" benign 2>&1 | tr '\n' ' ')"; ok=0; }
        bochs_run "$elf" "$MODW" "$work/$label.bw.bin"; bsd=$(cat "$work/.bsd" 2>/dev/null || echo 0)
        { python3 "$REF" grade "$work/$label.bw.bin" "$kh" 00 pfault >/dev/null 2>&1 && [[ "$bsd" -ge 1 ]]; } || { fail_test "$label Bochs hostile-WRITE (shutdown=$bsd): $(python3 "$REF" grade "$work/$label.bw.bin" "$kh" 00 pfault 2>&1 | tr '\n' ' ')"; ok=0; }
        bochs_run "$elf" "$MODR" "$work/$label.br.bin"; bsd=$(cat "$work/.bsd" 2>/dev/null || echo 0)
        { python3 "$REF" grade "$work/$label.br.bin" "$kh" 00 pfault_read >/dev/null 2>&1 && [[ "$bsd" -ge 1 ]]; } || { fail_test "$label Bochs hostile-READ (shutdown=$bsd)"; ok=0; }
    fi
    sha_after=$(sha256sum "$elf" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]] || { fail_test "$label: image changed between runs"; ok=0; }
    [[ "$ok" -eq 1 ]] && pass=$((pass + 1))
done

# ---- reject probes (+ twins): the nokta body subset is straight-line, one module_byte, no calls ----
reject_probe call          '-- emit: multiboot32-nokta'  'func h(): return 2 end\nfunc main(): return h() + module_byte() end'
reject_probe call_twin     '-- emit: multiboot32-nokta'  'func g(): return 4 end\nfunc main(): return g() + module_byte() end'
reject_probe branch        '-- emit: multiboot32-nokta'  'func main(): let x = module_byte()  if x == 5: return 1 else: return 2 end end'
reject_probe branch_twin   '-- emit: multiboot32-nokta'  'func main(): let y = module_byte()  if y == 9: return 3 else: return 4 end end'
reject_probe nomodule      '-- emit: multiboot32-nokta'  'func main(): return 7 end'
reject_probe nomodule_twin '-- emit: multiboot32-nokta'  'func main(): return 9 end'
reject_probe twomodule     '-- emit: multiboot32-nokta'  'func main(): return module_byte() + module_byte() end'
reject_probe twomodule_twin '-- emit: multiboot32-nokta' 'func main(): return module_byte() * module_byte() end'
reject_probe mainarg       '-- emit: multiboot32-nokta'  'func main(p): return p + module_byte() end'
reject_probe mainarg_twin  '-- emit: multiboot32-nokta'  'func main(k): return k - module_byte() end'
[[ "$fail" -eq 0 ]] && pass=$((pass + 10))

echo ""
if [[ "$run_bochs" -eq 0 ]]; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link35 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link35 / nokta / nineteenth kernel-arc link: MEMORY ISOLATION via paging U/S -- the kernel runs the build-unknown module at CPL 3 UNDER PAGING, kernel pages Supervisor + the module's pages User, so a hostile CPL3 write into kernel RAM faults #PF (errcode 7, CR2=target, CS RPL 3, write never lands), a hostile READ faults #PF errcode 5 (confidentiality), a hostile PT-write faults #PF (page-table tamper closure), a hostile out still #GP(0)s (privileged-op isolation survives paging); benign wrote its own User page + exited via int 0x30, f(X)!=f(Y). $pass checks: static MB+PAGE_ALIGN+MEMINFO, ELF-P12, white-box EXACT-${PREFIX_LEN}-byte-prefix + EXACT-58-byte-epilogue + body out-scan vs the silicon+KVM-proven nokta_ref, QEMU substrate (benign X 64M/256M/6G + Y + FAT; hostile #GP/#PF-write/#PF-read/#PF-PT), Bochs substrate (GRUB module; benign + hostile write/read; clean shutdown), 10 rejects with twins; graded vs the host #PF/#GP/exit frame witness + lodger allocator-recompute on the dual-substrate oracle)"
exit 0
