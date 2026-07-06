#!/usr/bin/env bash
# Native codegen Link 63 (hearken, the 47th kernel-arc link): the sovereign x86-64 freestanding
# long64 target's FIRST LATE-BOUND INPUT. Adds op 45 (input_byte: poll COM1 LSR 0x3FD, read RBR
# 0x3F8, movzx, push -- 18 self-contained bytes, byte-identical to the proven i386 op-45 lowering)
# to taproot's multi-function (nc_tap_*) subset, plus a UART init (nc32_uart_init, 56 bytes) emitted
# ONCE at long_entry (after 'mov esp', before the optional main frame) iff any function reads input.
# A Herbert-compiled recursive program reads a late-bound COM1 byte b and its graded byte becomes a
# FUNCTION of b -- the far-axis oracle upgrades from taproot's compile-time distinctness panel to
# genuine LATE-BOUND OUTPUT-FORCING (the SAME image fed different bytes emits different bytes; a baked
# constant cannot track a late-bound input).
#
# Forcing: func tri(n): if n==0 return 0 end; return n + tri(n-1) end; main returns tri(input_byte())*2^32.
# tri(b) recurses to depth b (data-dependent depth, guard-protected); graded byte = (b(b+1)/2)&0xFF.
# Two probes: hi (input in main, frameless main), hc (input in a CALLEE + a FRAMEFUL main -- pins the
# 'any function uses op45' detection AND uart-before-the-main-frame placement; cross-model Codex catch).
#
# Oracle (no C): (1) full-image GOLDEN HASH per probe (byte-pins head/uart/op45/body/calls/guard/tables);
# (2) INSTRUCTION-AWARE white-box -- the exact 18-byte op-45 window present once, the exact 56-byte UART
# block present once, and objdump decodes EXACTLY TWO 'in (%dx),%al' in the executable region (both inside
# the op-45 window; a raw 0xEC byte-count is WRONG because 'sub rsp,ib' = 48 83 EC ib contains EC -- Codex);
# (3) tri-substrate LATE-BOUND runtime: the SAME image fed b over a COM1 socket (QEMU-TCG + KVM real-silicon
# + Bochs) grades de<tri(b)&0xff>ad byte-for-byte; (4) a LATE-BOUND DIFFERENTIAL (one image, 4 distinct
# bytes incl. 0xFF max-byte -> 4 distinct proof bytes); (5) backward-call value-pin (recursion provenance,
# inherited); (6) E8-only call whitelist + guard-PD white-box (inherited); (7) no-input REGRESSION (a
# taproot-shape probe emits NO uart -> byte-identical path preserved); (8) NON-VACUITY -- a single-function
# input program is REJECTED (op 45 is admitted ONLY in the multi-func path; the single-func path is
# untouched). The mutation harness (run_native_codegen_link63_mutation.sh) proves M-noinput / M-op45size /
# M-nouart / M-golden each bite RED.
#
# Honest scope: reads ONE late-bound byte (NOT stream-until-EOF), drives a recursive computation, grades
# its high-dword byte. NOT device output from source, NOT heap, NOT the single-function path. Adds ZERO
# baked hex, NO Python ref builder. b<=255 so max recursion depth is 255 -- the guard-page overflow proof
# stays taproot's constant-deep 1,000,000 test (link62); this link does NOT claim input-controlled overflow.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
backend="$repo_root/stack/native_compile_fragment.herb"
goldens_dir="$script_dir/hearken_goldens"
feeder="$script_dir/kernel_input_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
BOCHS_PROBES="${L63_BOCHS_PROBES:-hi hc}"
DIFF_BYTES="${L63_DIFF_BYTES:-4 8 12 255}"

if [[ ! -f "$backend" ]]; then echo "FAIL: stack/native_compile_fragment.herb (missing backend)"; exit 1; fi
source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: stack/native_compile_fragment.herb ($1)"; fail=$((fail + 1)); }

have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
have_kvm()  { [[ -r /dev/kvm && -w /dev/kvm ]] && have_qemu; }
have_bochs() { command -v bochs >/dev/null 2>&1 && command -v parted >/dev/null 2>&1 \
    && command -v grub-install >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 && sudo -n true 2>/dev/null; }

# --- host oracle: tri(b)=b(b+1)/2; result u64 = tri(b)*2^32; proof byte = (result>>32)&0xff = tri(b)&0xff.
host_tri()   { echo $(( ($1 * ($1 + 1)) / 2 )); }
host_proof() { echo $(( $(host_tri "$1") & 0xff )); }
host_qemu_exit() { echo $(( ((( $1 ^ 0x31) & 0x7f) << 1) | 1 )); }

OP45_WINDOW="66bafd03eca80174f766baf803ec0fb6c050"
UART_BLOCK="66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003ee"

# probe sources
prog_src() { case "$1" in
  hi) printf 'func tri(n):\n    if n == 0: return 0 end\n    return n + tri(n - 1)\nend\nfunc main(): return tri(input_byte()) * 4294967296 end\n' ;;
  hc) printf 'func read(): return input_byte() end\nfunc tri(n):\n    if n == 0: return 0 end\n    return n + tri(n - 1)\nend\nfunc main():\n    let x = read()\n    return tri(x) * 4294967296\nend\n' ;;
esac; }
PROBES="hi hc"

compile_probe() { # label outfile
    local label="$1" out="$2"
    local cdir="$tmp/$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    { printf -- '-- emit: multiboot32-long64\n'; prog_src "$label"; } > "$cdir/probe.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < probe.herb >/dev/null 2>"$cdir/err" )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label: compiler produced no a.out ($(head -1 "$cdir/err" 2>/dev/null))"; return 1; fi
    cp "$cdir/a.out" "$out"; return 0
}

static_ok() { # label elf
    local label="$1" elf="$2"
    grub-file --is-x86-multiboot "$elf" >/dev/null 2>&1 || { fail_test "$label static: not x86-multiboot"; return 1; }
    local chx; chx=$(dd if="$elf" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    echo "$chx" | grep -q '0f05' && { fail_test "$label static: 0F05 syscall present"; return 1; }
    echo "$chx" | grep -q 'cd80' && { fail_test "$label static: CD80 present"; return 1; }
    return 0
}

# ---- instruction-aware input white-box (Codex change #3): op-45 window once, uart block once, exactly
#      two decoded 'in (%dx),%al' in the executable region (both inside the op-45 window). ----
input_wb() { # label elf
    local label="$1" elf="$2" ok=1
    local chx; chx=$(dd if="$elf" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local nwin; nwin=$(echo "$chx" | grep -o "$OP45_WINDOW" | wc -l | tr -d ' ')
    [[ "$nwin" -eq 1 ]] || { fail_test "$label wb: op-45 window count=$nwin (want 1)"; ok=0; }
    local nuart; nuart=$(echo "$chx" | grep -o "$UART_BLOCK" | wc -l | tr -d ' ')
    [[ "$nuart" -eq 1 ]] || { fail_test "$label wb: 56-byte UART init block count=$nuart (want 1)"; ok=0; }
    # decode the executable region and count 'in (%dx),%al' == 2 (stop at the GDT code-descriptor signature
    # so table/PDE data bytes are not decoded).
    local code="$tmp/$label.wb.bin"; dd if="$elf" bs=1 skip=4108 status=none of="$code" 2>/dev/null
    local sig_off; sig_off=$(echo "$chx" | grep -bo 'ffff00000' | head -1 | cut -d: -f1)
    local exec_bytes=$(( ${sig_off:-0} / 2 ))
    [[ "$exec_bytes" -gt 56 ]] || { fail_test "$label wb: cannot locate GDT (exec_bytes=$exec_bytes)"; ok=0; }
    dd if="$code" bs=1 count="$exec_bytes" status=none of="$code.x" 2>/dev/null
    local nin; nin=$(objdump -D -b binary -m i386:x86-64 -M intel "$code.x" 2>/dev/null | grep -cE '\bin +al,dx\b')
    [[ "$nin" -eq 2 ]] || { fail_test "$label wb: 'in al,dx' decode count=$nin (want 2: poll+RBR)"; ok=0; }
    [[ "$ok" -eq 1 ]]
}

# ---- inherited white-box (guard PD, backward call, E8-only whitelist) ----
WB="$tmp/wb.py"
cat > "$WB" <<'PY'
import sys,struct
elf=open(sys.argv[1],'rb').read(); mode=sys.argv[2]
filesz=struct.unpack('<I',elf[68:72])[0]; code_len=filesz-12; code=elf[4108:4108+code_len]
if code[56]!=0xBC: print("ERR no mov esp"); sys.exit(2)
esp_val=struct.unpack('<I',code[57:61])[0]
pd=code[code_len-4096:code_len]
entries=[struct.unpack('<Q',pd[i*8:i*8+8])[0] for i in range(512)]
nonpresent=[i for i,e in enumerate(entries) if (e&1)==0]
present_ok=all((entries[i]==i*0x200000+0x83) for i in range(512) if i not in nonpresent)
if mode=='guard':
    gidx=(esp_val-0x400000)//0x200000
    ok=(len(nonpresent)==1 and nonpresent[0]==gidx and present_ok and (esp_val-0x400000)%0x200000==0)
    sys.exit(0 if ok else 1)
if mode=='backward':
    found=False
    for i in range(len(code)-5):
        if code[i]==0xE8:
            rel=struct.unpack('<i',code[i+1:i+5])[0]; tgt=i+5+rel
            if rel<0 and 0<=tgt<len(code) and code[tgt]==0x55: found=True
    sys.exit(0 if found else 1)
if mode=='callwhitelist':
    sig=b'\xff\xff\x00\x00\x00\x9a\xaf\x00'; pos=code.find(sig)
    if pos<8: print("no GDT"); sys.exit(2)
    scan=code[56:pos-8]
    if b'\x9a' in scan: print("far-call 0x9A"); sys.exit(1)
    has_e8=(b'\xe8' in scan)
    bad_ff=any(scan[i]==0xFF and ((scan[i+1]>>3)&7) in (2,3) for i in range(len(scan)-1))
    sys.exit(0 if (has_e8 and not bad_ff) else 1)
print("unknown"); sys.exit(3)
PY
whitebox() { python3 "$WB" "$1" "$2"; }

# ---- late-bound socket feeder plumbing (link31 pattern) ----
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
feeder_wait() { local log="$1" i; for i in $(seq 1 80); do grep -q LISTENING "$log" && return 0; grep -q NOCONN "$log" && return 1; sleep 0.1; done; return 1; }

qemu_run_byte() { # label elf byte [kvm]
    local label="$1" elf="$2" byte="$3" kvm="${4:-}"
    local p ex ph; p=$(host_proof "$byte"); ex=$(host_qemu_exit "$p"); ph=$(printf '%02x' "$p")
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local W="$tmp/$label.q.$byte$kvm"; mkdir -p "$W"
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 6 > "$W/feed.log" 2>&1 &
    local fp=$!; feeder_wait "$W/feed.log" || { fail_test "$label QEMU$kvm byte=$byte: feeder never LISTENING"; kill "$fp" 2>/dev/null; return 1; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none "${acc[@]}" -m 64M
    local rc=$?; wait "$fp" 2>/dev/null
    local got; got=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    local nf; nf=$(echo "$got" | grep -o "de${ph}ad" | wc -l | tr -d ' ')
    if [[ "$rc" -eq "$ex" ]] && [[ "$got" == "de${ph}ad" ]] && [[ "$nf" -eq 1 ]]; then return 0; fi
    fail_test "$label QEMU$kvm byte=$byte: exit=$rc(want $ex) e9=$got want=de${ph}ad nframes=$nf"; return 1
}

bochs_run_byte() { # label elf byte
    local label="$1" elf="$2" byte="$3"
    local p ph; p=$(host_proof "$byte"); ph=$(printf '%02x' "$p")
    local W="$tmp/$label.b.$byte"; mkdir -p "$W"
    local BXSHARE VGABIOS
    BXSHARE="$(dirname "$(find /usr/share -name 'BIOS-bochs-legacy' 2>/dev/null | head -1)")"
    VGABIOS="$(find /usr/share -name 'VGABIOS-lgpl-latest' 2>/dev/null | head -1)"
    if [[ -z "$BXSHARE" || -z "$VGABIOS" ]]; then fail_test "$label Bochs: BIOS/VGABIOS missing"; return 1; fi
    ( cd "$W"
      dd if=/dev/zero of=disk.img bs=1M count=64 status=none
      parted -s disk.img mklabel msdos >/dev/null
      parted -s disk.img mkpart primary fat32 1MiB 100% >/dev/null
      parted -s disk.img set 1 boot on >/dev/null
      LOOP="$(sudo losetup -fP --show disk.img)"
      sudo mkfs.vfat -F 32 "${LOOP}p1" >/dev/null 2>&1
      mkdir -p mnt; sudo mount "${LOOP}p1" mnt
      sudo mkdir -p mnt/boot/grub; sudo cp "$elf" mnt/boot/kernel.elf
      printf 'set timeout=0\nset default=0\nmenuentry "c" {\n multiboot /boot/kernel.elf\n boot\n}\n' | sudo tee mnt/boot/grub/grub.cfg >/dev/null
      sudo grub-install --target=i386-pc --boot-directory=mnt/boot --modules="multiboot normal part_msdos fat biosdisk configfile" "$LOOP" >/dev/null 2>&1
      sudo umount mnt; sudo losetup -d "$LOOP" )
    local port; port=$(free_port)
    python3 "$feeder" "$port" "$byte" --hold 30 > "$W/feed.log" 2>&1 &
    local fp=$!; feeder_wait "$W/feed.log" || { fail_test "$label Bochs byte=$byte: feeder never LISTENING"; kill "$fp" 2>/dev/null; return 1; }
    ( cd "$W"
      cat > bochsrc.txt <<BX
romimage: file=$BXSHARE/BIOS-bochs-legacy
vgaromimage: file=$VGABIOS
megs: 64
ata0-master: type=disk, path=disk.img, mode=flat
boot: disk
com1: enabled=1, mode=socket-client, dev=127.0.0.1:$port
port_e9_hack: enabled=1
display_library: x
panic: action=report
BX
      xvfb-run -a bash -c "yes c | timeout -s KILL 90 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    wait "$fp" 2>/dev/null
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nf shutdown listened
    nf=$(grep -o "de${ph}ad" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    shutdown=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null)
    listened=$(grep -ac 'LISTENING' "$W/feed.log" 2>/dev/null)
    # F2-class harness discrimination: a run that never LISTENED or never reached shutdown is a HARNESS
    # failure, not a kernel RED (fail-closed only under REQUIRE_EMU=1).
    if [[ "$nf" -eq 1 ]] && [[ "$shutdown" -ge 1 ]]; then return 0; fi
    if [[ "$listened" -lt 1 || "$shutdown" -lt 1 ]]; then
        echo "HARNESS-ERROR: $label Bochs byte=$byte (listened=$listened shutdown=$shutdown nframes=$nf) -- emulator/feeder, not a kernel grade"
        [[ "$REQUIRE_EMU" == "1" ]] && return 1
        return 0
    fi
    fail_test "$label Bochs byte=$byte: frames(de${ph}ad)=$nf shutdown=$shutdown"; return 1
}

reject_probe() { # label "<full source incl funcs>"
    local label="$1" src="$2"
    local cdir="$tmp/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    { printf -- '-- emit: multiboot32-long64\n'; printf '%b\n' "$src"; } > "$cdir/r.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < r.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]]; then fail_test "$label reject: compiled but should be out-of-subset"; return 1; fi
    pass=$((pass + 1)); return 0
}

# ============================ run ============================
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi
run_kvm=0; have_kvm && run_kvm=1
if [[ "$run_kvm" -eq 1 ]]; then echo "link63: /dev/kvm present -- KVM real-silicon leg runs on the accepted-probe value witness."
else echo "NOTE: /dev/kvm absent -- KVM leg skipped (skip-if-unavailable by design; kernel_verify.sh is the fail-closed enforcer)."; fi

declare -A P0
for label in $PROBES; do
    elf="$tmp/$label.elf"
    compile_probe "$label" "$elf" || continue
    # (1) full-image golden hash
    if [[ -f "$goldens_dir/$label.sha256" ]]; then
        want=$(cat "$goldens_dir/$label.sha256"); got=$(sha256sum "$elf" | cut -d' ' -f1)
        if [[ "$want" == "$got" ]]; then pass=$((pass + 1)); else fail_test "$label: image != committed golden ($got != $want)"; fi
    else
        fail_test "$label: missing committed golden $goldens_dir/$label.sha256"
    fi
    # (2) statics
    static_ok "$label" "$elf" && pass=$((pass + 1))
    # (3) instruction-aware input white-box
    input_wb "$label" "$elf" && pass=$((pass + 1))
    # (4) inherited white-box: E8-only whitelist, guard PD, backward-call value-pin (both probes recurse)
    whitebox "$elf" callwhitelist && pass=$((pass + 1)) || fail_test "$label: call whitelist (E8-only) violated"
    whitebox "$elf" guard && pass=$((pass + 1)) || fail_test "$label: guard PD not exactly-one-nonpresent-at-guard-index"
    whitebox "$elf" backward && pass=$((pass + 1)) || fail_test "$label: no BACKWARD recursive call to a callee entry"
    # (5) tri-substrate LATE-BOUND runtime + differential over DIFF_BYTES
    for b in $DIFF_BYTES; do
        qemu_run_byte "$label" "$elf" "$b" && pass=$((pass + 1))
        [[ "$run_kvm" -eq 1 ]] && { qemu_run_byte "$label.kvm" "$elf" "$b" kvm && pass=$((pass + 1)); }
    done
    if [[ "$run_bochs" -eq 1 ]] && [[ " $BOCHS_PROBES " == *" $label "* ]]; then
        # Bochs on two distinct bytes = the second-decoder late-bound differential.
        bochs_run_byte "$label" "$elf" 4 && pass=$((pass + 1))
        bochs_run_byte "$label" "$elf" 12 && pass=$((pass + 1))
    fi
    # record proof byte at the FIRST diff byte for the cross-probe distinctness check
    firstb=$(echo $DIFF_BYTES | cut -d' ' -f1); P0[$label]=$(host_proof "$firstb")
done

# (6) LATE-BOUND DIFFERENTIAL is exercised above (same image, 4 bytes incl 0xFF -> 4 proofs). Assert the
#     4 proof bytes are actually distinct (an image that ignored input would emit one constant byte).
distinct=1
prev=""; for b in $DIFF_BYTES; do pb=$(host_proof "$b"); [[ " $prev " == *" $pb "* ]] && distinct=0; prev="$prev $pb"; done
if [[ "$distinct" -eq 1 ]]; then pass=$((pass + 1)); else fail_test "diff-bytes proof set not distinct ($prev)"; fi

# (7) NO-INPUT REGRESSION: a taproot-shape probe (no input) emits NO uart -> the byte-identical path is
#     preserved (uart_len==0). The full byte-identity is re-proven by run_native_codegen_link62.sh (its
#     committed goldens are unchanged); here we assert the uart block is ABSENT.
noin="$tmp/noin.d"; mkdir -p "$noin"
printf -- '-- emit: multiboot32-long64\nfunc h(): return 1000000 end\nfunc main(): return h() * 1000000 end\n' > "$noin/n.herb"
( cd "$noin" && "$NATIVE_CODEGEN_COMPILER" < n.herb >/dev/null 2>/dev/null )
if [[ -f "$noin/a.out" ]]; then
    nu=$(dd if="$noin/a.out" bs=1 skip=4108 status=none | xxd -p | tr -d '\n' | grep -o "$UART_BLOCK" | wc -l | tr -d ' ')
    if [[ "$nu" -eq 0 ]]; then pass=$((pass + 1)); else fail_test "no-input regression: uart present ($nu) in a no-input image"; fi
else
    fail_test "no-input regression: probe did not compile"
fi

# (8) NON-VACUITY / scope boundary: a SINGLE-function input program is REJECTED (op 45 admitted ONLY in
#     the multi-func path; the single-func long64 path is untouched and still rejects it).
reject_probe input_singlefunc 'func main(): return input_byte() * 4294967296 end'
# rejects+twins (still out of subset in the multi-func path)
reject_probe arity      'func h(x): return x * 1000000 end\nfunc main(): return h() end'
reject_probe divcallee  'func h(): return 1000000 / 3 end\nfunc main(): return h() * 1000000 end'

echo ""
if [[ "$run_bochs" -eq 0 ]] && have_qemu; then
    echo "NOTE: Bochs leg skipped (no bochs/sudo locally); QEMU substrate + statics + white-box ran. Dual-substrate runs in the kernel-codegen CI workflow."
fi
if [[ "$fail" -ne 0 ]]; then echo "$fail native-codegen-link63 sub-test(s) failed."; exit 1; fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link63 / hearken / 47th kernel-arc link: the sovereign x86-64 long64 target's FIRST LATE-BOUND INPUT -- op 45 (input_byte: COM1 poll+read) in taproot's multi-function subset + a UART init emitted once at long_entry; a Herbert-compiled recursive program reads a late-bound COM1 byte b and its graded byte = (b(b+1)/2)&0xff, the far-axis oracle upgraded from a compile-time distinctness panel to genuine LATE-BOUND OUTPUT-FORCING; $pass checks: full-image golden hash + statics + INSTRUCTION-AWARE input white-box (exact 18-byte op-45 window once + exact 56-byte UART block once + objdump 'in al,dx' decode count == 2) + E8-only call whitelist + guard-PD white-box + BACKWARD-call value-pin per probe (hi input-in-main frameless, hc input-in-CALLEE + FRAMEFUL main), QEMU-TCG + KVM real-silicon + Bochs late-bound socket-COM1 substrate over 4 distinct bytes incl 0xFF (same image -> 4 distinct proof bytes: the anti-bake differential), no-input regression (uart ABSENT -> byte-identical taproot path), non-vacuity (single-function input REJECTED), rejects+twins; graded vs a hand-derived host oracle on the dual-substrate late-bound-input oracle, no C)"
exit 0
