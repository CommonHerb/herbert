#!/usr/bin/env bash
# Native codegen Link 64 (riposte, the 48th kernel-arc link): the sovereign x86-64 freestanding
# long64 target's FIRST PROGRAM-AUTHORED DEVICE OUTPUT. Adds op 53 (output_byte(v): write v&0xff
# to the COM1 THR 0x3F8, then poll LSR 0x3FD bit 6 (TEMT) until the byte is FULLY ON THE WIRE --
# write-then-drain; 18 self-contained bytes, the dual of op 45) to the taproot/hearken multi-
# function (nc_tap_*) subset. The UART-init predicate widens: nc32_uart_init (56 bytes) is emitted
# ONCE at long_entry iff any function uses op 45 OR op 53 (an op-45-only program keeps the SAME
# block at the SAME offset -> every hearken golden byte-identical; neither op -> byte-identical
# taproot). Until this link the target's ONLY output was the fixed 3-byte epilogue frame on
# debugcon 0xE9 -- an emulator-only device that does NOT exist on the pinned physical target
# (legacy-BIOS x86-64 + real 16550 COM1); op 53 is the first output a PROGRAM authors, on the
# device the real machine actually has, and the output germ of the Closed Loop's byte-stream /
# diag facilities.
#
# WRITE-THEN-DRAIN (STEP-0-forced): Bochs's baud-paced 16550 TX model DROPS back-to-back THR
# writes under a poll-THRE-before-write discipline (2 of 3 bytes lost) and loses the LAST byte
# to shutdown; writing first and then polling TEMT (holding+shift BOTH empty) makes every op-53
# leave the wire drained and the THR free (the invariant that makes the unconditional write
# safe) -- and is the real-16550-correct discipline for the pinned physical COM1.
#
# Forcing (probe ro): func spew(n): if n==0 return 0 end; return output_byte(n*7+259)+spew(n-1) end;
# main returns spew(input_byte())*2^32. The SAME image fed a late-bound b emits a COM1 stream of
# RUNTIME-SET LENGTH b (bytes (7n+259)&0xff, n=b..1) AND a debugcon checksum byte (sum consumes
# output_byte's RETURN VALUE = the FULL argument, 259>255 so high bits are set at every call --
# a pops-without-push / wrong-push lowering cannot hide in the stream; cross-model Codex change).
# A baked table can fake neither the length nor the content of 4 distinct late-bound streams.
# Probe rc: output in a CALLEE reached through a wrapper + a FRAMEFUL main (pins the any-function
# op-53 detection + uart-before-main-frame placement). Probe oo: output-ONLY, no input (pins the
# uart predicate on op 53 alone + TWO op-53 sites + return-value consumption: emitpair(65) returns
# output_byte(65)+output_byte(65*3+130) = 390, graded 0x86, stream 0x41 0x45).
#
# Oracle (no C): (1) full-image GOLDEN HASH per probe; (2) INSTRUCTION-AWARE white-box -- the exact
# 18-byte op-53 window (5b66baf80388d8ee66bafd03eca84074f753) exactly n53 times, the exact op-45
# window exactly n45 times, the exact 56-byte UART block exactly once, and objdump decodes EXACTLY
# 20+n53 'out dx,al' (8 uart + 12 epilogue + n53) and 2*n45+n53 'in al,dx' in the executable
# region (region-aware counts -- the uart block's own outs are part of the expectation, not noise;
# cross-model Codex change); (3) tri-substrate LATE-BOUND runtime: the SAME ro image fed b over a
# full-duplex COM1 socket grades the EXACT captured stream + the debugcon frame + the exit code on
# QEMU-TCG (b in 4,9,251,255 -- 4 distinct bytes incl 0xFF -> 4 distinct self-sized streams, the
# anti-bake differential) + KVM real silicon (b=4,255) + Bochs (b=9); (4) the b=0 EMPTY edge --
# genuine zero-length output distinguished from a capture miss by the de00ad completion frame +
# exit code 99 (the socket EOF barrier: the feeder captures until the emulator exits); (5)
# no-output regression -- hi + hc (hearken sources) and p1 (taproot source) recompile BYTE-
# IDENTICAL to their committed goldens under the widened predicate; (6) non-vacuity + rejects --
# single-function output REJECTED (op 53 admitted ONLY in the multi-func path), default-Linux
# REJECTED (ERR 408 op 53), input-mode REJECTED, arity 0/2 REJECTED (arity-0 inherits the
# sys_write-family reject class: deterministic no-a.out via the compiler's own bounds trap), plus
# compile twins. HARNESS TAXONOMY (the L39 lesson, Codex-narrowed): a COMPLETED run (frame+exit
# observed) with a wrong stream is a compiler RED -- NEVER re-rolled; only never-LISTENING /
# never-completed signatures are harness errors (Bochs: bounded internal re-roll, marked, and
# fail-closed only under KERNEL_CODEGEN_REQUIRE_EMU=1).
#
# Honest scope: ONE byte per op call (no stream-out verb, no flow control, no interrupt-driven
# TX); the TEMT drain is runtime-load-bearing on Bochs (proven: THRE-only loses bytes) but
# runtime-invisible on QEMU (always drained) -- its presence is byte-pinned by the window + the
# in-al-dx count on every substrate; output rate is bounded by the emulated baud on Bochs. NOT
# stream-until-EOF, NOT a file, NOT the single-function path. Adds ZERO baked hex, NO Python ref
# builder.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
backend="$repo_root/stack/native_compile_fragment.herb"
goldens_dir="$script_dir/riposte_goldens"
hearken_goldens="$script_dir/hearken_goldens"
taproot_goldens="$script_dir/taproot_goldens"
feeder="$script_dir/kernel_io_feed.py"

REQUIRE_EMU="${KERNEL_CODEGEN_REQUIRE_EMU:-0}"
DIFF_BYTES="${L64_DIFF_BYTES:-4 9 251 255}"

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

OP53_WINDOW="5b66baf80388d8ee66bafd03eca84074f753"
OP45_WINDOW="66bafd03eca80174f766baf803ec0fb6c050"
UART_BLOCK="66bafb03b003ee66baf903b000ee66bafb03b080ee66baf803b001ee66baf903b000ee66bafb03b003ee66bafa03b000ee66bafc03b003ee"

# --- host oracle: ro/rc stream = (7n+259)&0xff for n=b..1; checksum = sum(7n+259) consumes the
#     FULL return values; graded byte = checksum&0xff; QEMU exit = ((g^0x31)&0x7f)<<1|1.
host_ro() { # byte -> "caphex|e9hex|rc" (caphex empty for b=0)
    python3 - "$1" <<'PY'
import sys
b = int(sys.argv[1])
seq = ''.join('%02x' % ((7*n+259) & 0xff) for n in range(b, 0, -1))
cs = sum(7*n+259 for n in range(1, b+1))
g = cs & 0xff
rc = (((g ^ 0x31) & 0x7f) << 1) | 1
print(f"{seq}|de{g:02x}ad|{rc}")
PY
}
OO_CAP="4145"; OO_E9="de86ad"; OO_RC=111   # emitpair(65): wire 0x41,0x45; sum 65+325=390 -> 0x86

# probe sources
prog_src() { case "$1" in
  ro) printf 'func spew(n):\n    if n == 0: return 0 end\n    return output_byte(n * 7 + 259) + spew(n - 1)\nend\nfunc main(): return spew(input_byte()) * 4294967296 end\n' ;;
  rc) printf 'func put(v): return output_byte(v) end\nfunc spew(n):\n    if n == 0: return 0 end\n    return put(n * 7 + 259) + spew(n - 1)\nend\nfunc main():\n    let x = input_byte()\n    return spew(x) * 4294967296\nend\n' ;;
  oo) printf 'func emitpair(v):\n    return output_byte(v) + output_byte(v * 3 + 130)\nend\nfunc main(): return emitpair(65) * 4294967296 end\n' ;;
  hi) printf 'func tri(n):\n    if n == 0: return 0 end\n    return n + tri(n - 1)\nend\nfunc main(): return tri(input_byte()) * 4294967296 end\n' ;;
  hc) printf 'func read(): return input_byte() end\nfunc tri(n):\n    if n == 0: return 0 end\n    return n + tri(n - 1)\nend\nfunc main():\n    let x = read()\n    return tri(x) * 4294967296\nend\n' ;;
  p1) printf 'func rec(n, acc):\n    if n == 0: return acc end\n    return rec(n - 1, acc + 1073741824)\nend\nfunc main(): return rec(6, 0) end\n' ;;
esac; }
PROBES="ro rc oo"

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

# ---- instruction-aware OUTPUT white-box (region-aware counts -- cross-model Codex change #3):
#      exact op-53 window n53 times, exact op-45 window n45 times, uart block once, objdump
#      'out dx,al' == 20+n53 (8 uart + 12 epilogue + n53) and 'in al,dx' == 2*n45+n53.
output_wb() { # label elf n53 n45
    local label="$1" elf="$2" n53="$3" n45="$4" ok=1
    local chx; chx=$(dd if="$elf" bs=1 skip=4108 status=none 2>/dev/null | xxd -p | tr -d '\n')
    local nw; nw=$(echo "$chx" | grep -o "$OP53_WINDOW" | wc -l | tr -d ' ')
    [[ "$nw" -eq "$n53" ]] || { fail_test "$label wb: op-53 window count=$nw (want $n53)"; ok=0; }
    local n45w; n45w=$(echo "$chx" | grep -o "$OP45_WINDOW" | wc -l | tr -d ' ')
    [[ "$n45w" -eq "$n45" ]] || { fail_test "$label wb: op-45 window count=$n45w (want $n45)"; ok=0; }
    local nuart; nuart=$(echo "$chx" | grep -o "$UART_BLOCK" | wc -l | tr -d ' ')
    [[ "$nuart" -eq 1 ]] || { fail_test "$label wb: 56-byte UART init block count=$nuart (want 1)"; ok=0; }
    local code="$tmp/$label.wb.bin"; dd if="$elf" bs=1 skip=4108 status=none of="$code" 2>/dev/null
    local sig_off; sig_off=$(echo "$chx" | grep -bo 'ffff00000' | head -1 | cut -d: -f1)
    local exec_bytes=$(( ${sig_off:-0} / 2 ))
    [[ "$exec_bytes" -gt 56 ]] || { fail_test "$label wb: cannot locate GDT (exec_bytes=$exec_bytes)"; ok=0; }
    dd if="$code" bs=1 count="$exec_bytes" status=none of="$code.x" 2>/dev/null
    local dis; dis=$(objdump -D -b binary -m i386:x86-64 -M intel "$code.x" 2>/dev/null)
    local nout; nout=$(echo "$dis" | grep -cE '\bout +dx,al\b')
    [[ "$nout" -eq $((20 + n53)) ]] || { fail_test "$label wb: 'out dx,al' decode count=$nout (want $((20 + n53)) = 8 uart + 12 epilogue + $n53 op-53)"; ok=0; }
    local nin; nin=$(echo "$dis" | grep -cE '\bin +al,dx\b')
    [[ "$nin" -eq $((2 * n45 + n53)) ]] || { fail_test "$label wb: 'in al,dx' decode count=$nin (want $((2 * n45 + n53)))"; ok=0; }
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

# ---- full-duplex socket plumbing ----
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
feeder_wait() { local log="$1" i; for i in $(seq 1 80); do grep -q LISTENING "$log" && return 0; grep -q NOCONN "$log" && return 1; sleep 0.1; done; return 1; }

# A COMPLETED run (exit code observed + a well-formed de..ad frame) with a wrong stream/frame is
# a compiler RED -- never re-rolled (Codex change #5). Harness-error is ONLY never-LISTENING.
qemu_run_duplex() { # label elf byte|-(none) want_cap want_e9 want_rc [kvm]
    local label="$1" elf="$2" byte="$3" want_cap="$4" want_e9="$5" want_rc="$6" kvm="${7:-}"
    local acc=(-cpu qemu64); [[ -n "$kvm" ]] && acc=(-enable-kvm -cpu host)
    local W="$tmp/$label.q"; mkdir -p "$W"
    local port; port=$(free_port)
    local feedargs=(); [[ "$byte" != "-" ]] && feedargs=("$byte")
    python3 "$feeder" "$port" ${feedargs[@]+"${feedargs[@]}"} --cap "$W/cap.bin" --hold 45 > "$W/feed.log" 2>&1 &
    local fp=$!
    feeder_wait "$W/feed.log" || { fail_test "$label QEMU$kvm: feeder never LISTENING (harness)"; kill "$fp" 2>/dev/null; return 1; }
    timeout 60 qemu-system-x86_64 -kernel "$elf" -debugcon file:"$W/e9.bin" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none \
        -chardev socket,id=s0,host=127.0.0.1,port="$port",server=off -serial chardev:s0 \
        -monitor none "${acc[@]}" -m 64M
    local rc=$?; wait "$fp" 2>/dev/null
    local got_e9; got_e9=$(xxd -p "$W/e9.bin" 2>/dev/null | tr -d '\n')
    local got_cap; got_cap=$(xxd -p "$W/cap.bin" 2>/dev/null | tr -d '\n')
    if [[ "$rc" -eq "$want_rc" && "$got_e9" == "$want_e9" && "$got_cap" == "$want_cap" ]]; then return 0; fi
    fail_test "$label QEMU$kvm byte=$byte: exit=$rc(want $want_rc) e9=$got_e9(want $want_e9) cap=${got_cap:-EMPTY}(want ${want_cap:-EMPTY})"
    return 1
}

bochs_run_duplex() { # label elf byte want_cap want_e9frame_hex
    local label="$1" elf="$2" byte="$3" want_cap="$4" want_e9="$5"
    local W="$tmp/$label.b"; mkdir -p "$W"
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
    python3 "$feeder" "$port" "$byte" --cap "$W/cap.bin" --hold 60 > "$W/feed.log" 2>&1 &
    local fp=$!
    feeder_wait "$W/feed.log" || { BOCHS_HARNESS_ERR="feeder never LISTENING"; kill "$fp" 2>/dev/null; return 2; }
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
      xvfb-run -a bash -c "yes c | timeout -s KILL 120 bochs -q -f bochsrc.txt" > bochs_out.txt 2>&1 )
    # drain-before-kill (completeness-critic catch): the feeder writes cap.bin only after its recv loop
    # ends (peer-close/hold); killing it first could vaporize a COMPLETED run's capture -> a false RED
    # the taxonomy forbids re-rolling. Bochs has exited here, so the socket is closed -- give the feeder
    # a bounded window to observe PEERCLOSED and flush the capture, THEN reap.
    local di; for di in $(seq 1 50); do kill -0 "$fp" 2>/dev/null || break; sleep 0.1; done
    kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
    local shutdown listened
    shutdown=$(grep -ac 'shutdown requested' "$W/bochs_out.txt" 2>/dev/null)
    listened=$(grep -ac 'SENT' "$W/feed.log" 2>/dev/null)
    if [[ "$listened" -lt 1 || "$shutdown" -lt 1 ]]; then
        BOCHS_HARNESS_ERR="never completed (sent=$listened shutdown=$shutdown) -- emulator/feeder, not a kernel grade"
        return 2
    fi
    # COMPLETED -> a genuine grade from here on (never re-rolled).
    hexdump -ve '1/1 "%02x"' "$W/bochs_out.txt" > "$W/hex.txt" 2>/dev/null
    local nf; nf=$(grep -o "$want_e9" "$W/hex.txt" 2>/dev/null | wc -l | tr -d ' ')
    local got_cap; got_cap=$(xxd -p "$W/cap.bin" 2>/dev/null | tr -d '\n')
    if [[ "$nf" -eq 1 && "$got_cap" == "$want_cap" ]]; then return 0; fi
    fail_test "$label Bochs byte=$byte (COMPLETED run -- a genuine grade, not a harness flake): frames($want_e9)=$nf(want 1) cap=${got_cap:-EMPTY}(want $want_cap)"
    return 1
}

reject_probe() { # label "<full source incl funcs>" [emitline]
    local label="$1" src="$2" emitline="${3:--- emit: multiboot32-long64}"
    local cdir="$tmp/rej.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    { printf -- '%s\n' "$emitline"; printf '%b\n' "$src"; } > "$cdir/r.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < r.herb >/dev/null 2>/dev/null )
    if [[ -f "$cdir/a.out" ]]; then fail_test "$label reject: compiled but should be out-of-subset"; return 1; fi
    pass=$((pass + 1)); return 0
}
accept_twin() { # label "<full source>" [emitline]
    local label="$1" src="$2" emitline="${3:--- emit: multiboot32-long64}"
    local cdir="$tmp/twin.$label.d"; rm -rf "$cdir"; mkdir -p "$cdir"
    { printf -- '%s\n' "$emitline"; printf '%b\n' "$src"; } > "$cdir/t.herb"
    ( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < t.herb >/dev/null 2>/dev/null )
    if [[ ! -f "$cdir/a.out" ]]; then fail_test "$label twin: did NOT compile (reject leg would be vacuous)"; return 1; fi
    pass=$((pass + 1)); return 0
}

# ============================ run ============================
run_bochs=0; have_bochs && run_bochs=1
if [[ "$run_bochs" -eq 0 && "$REQUIRE_EMU" == "1" ]]; then echo "FAIL: stack/native_compile_fragment.herb (KERNEL_CODEGEN_REQUIRE_EMU=1 but Bochs/sudo prerequisites missing)"; exit 1; fi
run_kvm=0; have_kvm && run_kvm=1
if [[ "$run_kvm" -eq 1 ]]; then echo "link64: /dev/kvm present -- KVM real-silicon leg runs on the late-bound duplex witness."
else echo "NOTE: /dev/kvm absent -- KVM leg skipped (skip-if-unavailable by design; kernel_verify.sh is the fail-closed enforcer)."; fi

# probe white-box expectations: label -> n53 n45 backward?
wb_n53() { case "$1" in ro) echo 1;; rc) echo 1;; oo) echo 2;; esac; }
wb_n45() { case "$1" in ro) echo 1;; rc) echo 1;; oo) echo 0;; esac; }

declare -A ELF
for label in $PROBES; do
    elf="$tmp/$label.elf"
    compile_probe "$label" "$elf" || continue
    ELF[$label]="$elf"
    if [[ -f "$goldens_dir/$label.sha256" ]]; then
        want=$(cat "$goldens_dir/$label.sha256"); got=$(sha256sum "$elf" | cut -d' ' -f1)
        if [[ "$want" == "$got" ]]; then pass=$((pass + 1)); else fail_test "$label: image != committed golden ($got != $want)"; fi
    else
        fail_test "$label: missing committed golden $goldens_dir/$label.sha256"
    fi
    static_ok "$label" "$elf" && pass=$((pass + 1))
    output_wb "$label" "$elf" "$(wb_n53 "$label")" "$(wb_n45 "$label")" && pass=$((pass + 1))
    whitebox "$elf" callwhitelist && pass=$((pass + 1)) || fail_test "$label: call whitelist (E8-only) violated"
    whitebox "$elf" guard && pass=$((pass + 1)) || fail_test "$label: guard PD not exactly-one-nonpresent-at-guard-index"
done
for label in ro rc; do
    [[ -n "${ELF[$label]:-}" ]] || continue
    whitebox "${ELF[$label]}" backward && pass=$((pass + 1)) || fail_test "$label: no BACKWARD recursive call to a callee entry"
done

# (5) no-output regression: hearken + taproot sources recompile byte-identical under the widened predicate.
for reg in hi hc p1; do
    elf="$tmp/reg.$reg.elf"
    compile_probe "$reg" "$elf" || continue
    case "$reg" in
      hi|hc) want=$(cat "$hearken_goldens/$reg.sha256") ;;
      p1)    want=$(cat "$taproot_goldens/$reg.sha256") ;;
    esac
    got=$(sha256sum "$elf" | cut -d' ' -f1)
    if [[ "$want" == "$got" ]]; then pass=$((pass + 1)); else fail_test "regression $reg: != committed golden under widened uart predicate ($got != $want)"; fi
done

# (3) tri-substrate late-bound runtime + (4) the b=0 edge
if have_qemu && [[ -n "${ELF[ro]:-}" ]]; then
    for b in $DIFF_BYTES; do
        IFS='|' read -r wcap we9 wrc < <(host_ro "$b")
        qemu_run_duplex "ro.tcg.$b" "${ELF[ro]}" "$b" "$wcap" "$we9" "$wrc" && pass=$((pass + 1))
    done
    IFS='|' read -r wcap we9 wrc < <(host_ro 0)
    qemu_run_duplex "ro.tcg.zero" "${ELF[ro]}" 0 "" "$we9" "$wrc" && pass=$((pass + 1))
    IFS='|' read -r wcap we9 wrc < <(host_ro 9)
    [[ -n "${ELF[rc]:-}" ]] && { qemu_run_duplex "rc.tcg.9" "${ELF[rc]}" 9 "$wcap" "$we9" "$wrc" && pass=$((pass + 1)); }
    [[ -n "${ELF[oo]:-}" ]] && { qemu_run_duplex "oo.tcg" "${ELF[oo]}" - "$OO_CAP" "$OO_E9" "$OO_RC" && pass=$((pass + 1)); }
    if [[ "$run_kvm" -eq 1 ]]; then
        for b in 4 255; do
            IFS='|' read -r wcap we9 wrc < <(host_ro "$b")
            qemu_run_duplex "ro.kvm.$b" "${ELF[ro]}" "$b" "$wcap" "$we9" "$wrc" kvm && pass=$((pass + 1))
        done
        IFS='|' read -r wcap we9 wrc < <(host_ro 9)
        [[ -n "${ELF[rc]:-}" ]] && { qemu_run_duplex "rc.kvm.9" "${ELF[rc]}" 9 "$wcap" "$we9" "$wrc" kvm && pass=$((pass + 1)); }
        [[ -n "${ELF[oo]:-}" ]] && { qemu_run_duplex "oo.kvm" "${ELF[oo]}" - "$OO_CAP" "$OO_E9" "$OO_RC" kvm && pass=$((pass + 1)); }
    fi
else
    if [[ "$REQUIRE_EMU" == "1" ]]; then fail_test "QEMU required but not available"; fi
fi

if [[ "$run_bochs" -eq 1 && -n "${ELF[ro]:-}" ]]; then
    IFS='|' read -r wcap we9 wrc < <(host_ro 9)
    bochs_done=0
    for attempt in 1 2 3; do
        BOCHS_HARNESS_ERR=""
        bochs_run_duplex "ro.bochs.9" "${ELF[ro]}" 9 "$wcap" "$we9"
        rcb=$?
        if [[ "$rcb" -eq 2 ]]; then
            echo "  HARNESS ERROR (Bochs attempt $attempt/3): $BOCHS_HARNESS_ERR -- re-rolling (setup/no-completion only; a completed wrong grade is never re-rolled)" >&2
            continue
        fi
        [[ "$rcb" -eq 0 ]] && pass=$((pass + 1))
        bochs_done=1; break
    done
    if [[ "$bochs_done" -eq 0 ]]; then
        if [[ "$REQUIRE_EMU" == "1" ]]; then
            echo "HARNESS-ERROR: (Bochs) 3 consecutive harness attempts failed -- $BOCHS_HARNESS_ERR (re-rollable emulator/feeder failure, NOT a kernel miscompile; RED only because KERNEL_CODEGEN_REQUIRE_EMU=1)"
            fail=$((fail + 1))
        else
            echo "  HARNESS-ERROR (non-fatal): Bochs failed 3 consecutive harness attempts -- $BOCHS_HARNESS_ERR" >&2
        fi
    fi
fi

# (6) non-vacuity + rejects (+ compile twins so the reject legs cannot be vacuous)
reject_probe out_singlefunc 'func main(): return output_byte(65) * 4294967296 end'
accept_twin  out_singlefunc_twin 'func main(): return 65 * 4294967296 end'
reject_probe out_linuxdefault 'func main(): return output_byte(65) end' ''
reject_probe out_inputmode 'func main(): return output_byte(65) end' '-- emit: multiboot32-input'
reject_probe out_arity0 'func h(): return output_byte() end\nfunc main(): return h() * 4294967296 end'
reject_probe out_arity2 'func h(): return output_byte(1, 2) end\nfunc main(): return h() * 4294967296 end'
accept_twin  out_arity_twin 'func h(): return output_byte(3) end\nfunc main(): return h() * 4294967296 end'
# the NAME-RESERVATION bite-leg (completeness-critic catch): the builtin-name reservation is the ONLY
# thing preventing a user-defined `func output_byte` from silently compiling its call sites to op 53
# (emit_call_expr hijacks the name BEFORE user-call dispatch) -- pin that a program DEFINING the name
# is REJECTED (ERR 429 invalid function table), so deleting the reservation cannot stay green.
reject_probe out_userdef 'func output_byte(v): return v end\nfunc main(): return output_byte(4) * 4294967296 end'

if [[ "$REQUIRE_EMU" != "1" ]] && ! have_qemu; then
    echo "  NOTE: no emulator ran; byte-pin + white-box gates only (set KERNEL_CODEGEN_REQUIRE_EMU=1 for the silicon gate)"
fi

if [[ "$fail" -gt 0 ]]; then
    echo "native-codegen link64 (riposte / DEVICE OUTPUT FROM SOURCE): pass=$pass fail=$fail"
    exit 1
fi
echo "PASS: stack/native_compile_fragment.herb (native-codegen link64 / riposte / 48th kernel-arc link: the sovereign x86-64 long64 target's FIRST PROGRAM-AUTHORED DEVICE OUTPUT -- op 53 (output_byte: COM1 THR write + LSR.TEMT write-then-drain, the dual of op 45) in the taproot/hearken multi-function subset + the UART-init predicate widened to op45-OR-op53; $pass checks: full-image golden hash per probe (ro/rc/oo) + statics + INSTRUCTION-AWARE region-aware output white-box (exact 18-byte op-53 window x n53 + exact op-45 window x n45 + exact 56-byte UART block once + objdump 'out dx,al' == 20+n53 and 'in al,dx' == 2*n45+n53) + E8-only call whitelist + guard-PD white-box + BACKWARD-call value-pin (ro/rc), QEMU-TCG late-bound full-duplex COM1 over 4 distinct bytes incl 0xFF (same image -> 4 distinct SELF-SIZED streams + 4 distinct checksum frames: the anti-bake differential; the checksum consumes output_byte's FULL return value) + the b=0 EMPTY edge (genuine zero-length output vs capture-miss via the de00ad completion frame + exit code) + KVM real-silicon + Bochs duplex witness (write-then-drain proven load-bearing on Bochs's baud-paced TX), no-output regression (hi/hc/p1 byte-identical to hearken/taproot goldens under the widened predicate), non-vacuity (single-function output REJECTED; default-Linux ERR 408; input-mode REJECTED; arity 0/2 REJECTED; a USER-DEFINED func output_byte REJECTED ERR 429 -- the name-reservation that prevents silent op-53 hijack of user call sites is itself pinned) + twins ... no C)"
