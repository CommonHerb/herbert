#!/usr/bin/env bash
# Mutation proof for native-codegen link 62 (taproot): each gate leg must BITE (go RED) when the
# capability it guards is broken. We mutate the EMITTED image (not the compiler) to forge a break the
# gate must catch, and assert the corresponding white-box/runtime leg fails. Proves the link62 gate is
# not vacuous. Mutations (each RED-first):
#   M-noguard   : make the guard PDE PRESENT (identity 2-MiB) -> the guard white-box + runtime fault legs
#                 must fail (overflow would no longer fault -> silent corruption).
#   M-fwdcall   : zero the recursive BACKWARD tail-E9 rel32 (gyre: p1's self-recursion is a TAIL call,
#                 lowered E9 with the exact reclamation window -- the backward_e9 value-pin) -> the
#                 backward tail-E9 pin must fail (recursion provenance gone).
#   M-norecl    : corrupt the reclamation window before the tail E9 (lea rsp,[rbp+8] -> NOPs) -> the
#                 backward_e9 pin must fail (an E9 without its exact reclamation window is NOT a tail).
#   M-farcall   : inject a 0x9A far-call OPCODE into the code window (at the first unmasked push-rax
#                 byte) -> the call-form whitelist (now REAL instruction-boundary decoding) must fail.
#   M-maskhole  : GATE-TEETH B2 -- inject 0x9A at gt+10 (the fixed grading-tail/halt epilogue's `mov
#                 al,0xde` opcode byte), a REAL instruction boundary that the OLD masked-byte-scan
#                 whitelist demonstrably missed: a coincidental 0xE8 byte inside `48 C1 E8 20` (the
#                 grading tail's own shr opcode, not a real call) falsely masked the next 4 bytes, and
#                 the immediate operand of the following `66 BA E9 00` (mov dx,0xE9) supplied a second
#                 coincidental 0xE9 byte whose false mask window shadowed gt+10 from the 0x9A scan --
#                 the masked scanner returned PASS on this exact forge. The repaired REAL-decode
#                 whitelist (B1) must now catch it (RED where the pre-fix scanner passed), proven
#                 against a control-GREEN on the unforged base.
#   M-golden    : perturb one image byte -> the golden-hash pin must fail.
#   M-value     : perturb the graded body so the boot proof byte changes -> the QEMU runtime leg must fail.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
backend="$repo_root/stack/native_compile_fragment.herb"
source "$script_dir/native_codegen_oracle.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
HVMARK="/tmp/.hv_harness_fail.$$"; rm -f "$HVMARK"   # fail-closed marker: a dead/timed-out QEMU run trips this -> hard fail at end
native_codegen_ensure_compiler "$tmp/gen1" || exit 1
pass=0; fail=0
fail_test() { echo "FAIL: link62-mutation ($1)"; fail=$((fail + 1)); }
have_qemu() { command -v qemu-system-x86_64 >/dev/null 2>&1; }
if ! have_qemu; then echo "NOTE: no QEMU; link62-mutation skipped locally (authoritative in CI)."; [[ "${KERNEL_CODEGEN_REQUIRE_EMU:-0}" == "1" ]] && { echo "FAIL: REQUIRE_EMU=1 but no QEMU"; exit 1; }; exit 0; fi

# emit p1 (a recursive probe) as the mutation base
base="$tmp/p1.elf"; cdir="$tmp/p1.d"; mkdir -p "$cdir"
printf -- '-- emit: multiboot32-long64\nfunc rec(n, acc):\n    if n == 0: return acc end\n    return rec(n - 1, acc + 1073741824)\nend\nfunc main(): return rec(6, 0) end\n' > "$cdir/p.herb"
( cd "$cdir" && "$NATIVE_CODEGEN_COMPILER" < p.herb >/dev/null 2>/dev/null )
[[ -f "$cdir/a.out" ]] || { echo "FAIL: link62-mutation (base p1 did not compile)"; exit 1; }
cp "$cdir/a.out" "$base"

WB="$script_dir/../../bootstrap/tests"  # not used; reuse the gate's WB inline
PY="$tmp/wb.py"
cat > "$PY" <<'PYEOF'
import sys,struct,subprocess,re
elf=bytearray(open(sys.argv[1],'rb').read()); mode=sys.argv[2]
filesz=struct.unpack('<I',elf[68:72])[0]; code_off=4108; code=elf[code_off:code_off+filesz-12]
code_len=len(code)
if mode=='guard':
    pd=code[code_len-4096:code_len]; esp=struct.unpack('<I',code[57:61])[0]
    entries=[struct.unpack('<Q',pd[i*8:i*8+8])[0] for i in range(512)]
    npres=[i for i,e in enumerate(entries) if (e&1)==0]; gidx=(esp-0x400000)//0x200000
    ok=(len(npres)==1 and npres[0]==gidx and all(entries[i]==i*0x200000+0x83 for i in range(512) if i not in npres))
    sys.exit(0 if ok else 1)
RECL=bytes.fromhex('4c895d08488d65084c89d5')   # mov [rbp+8],r11; lea rsp,[rbp+8]; mov rbp,r10
if mode=='backward_e9':
    # gyre tail-recursion provenance: backward E9 with the exact reclamation window, landing on 0x55
    found=False
    for i in range(len(code)-5):
        if code[i]==0xE9 and i>=len(RECL) and code[i-len(RECL):i]==RECL:
            rel=struct.unpack('<i',code[i+1:i+5])[0]; tgt=i+5+rel
            if rel<0 and 0<=tgt<len(code) and code[tgt]==0x55: found=True
    sys.exit(0 if found else 1)
if mode=='callwhitelist':
    # GATE-TEETH B1: the SAME real instruction-boundary decoding as the gate (reused verbatim
    # in shape, not the old masked byte-scan) -- see run_native_codegen_link62.sh for the full
    # rationale (a coincidental E8/E9 byte VALUE inside the fixed grading-tail/halt epilogue
    # could shadow a real instruction boundary from the old masked 0x9A scan; real decode has
    # no such false positive/negative).
    if code[56]!=0xBC: sys.exit(2)
    sig=b'\xff\xff\x00\x00\x00\x9a\xaf\x00'; pos=code.find(sig)
    if pos<8: sys.exit(2)
    gdt_start=pos-8
    start=56; end=gdt_start
    open('/tmp/wb62m_cw.bin','wb').write(bytes(code[start:end]))
    out=subprocess.run(['objdump','-D','-b','binary','-m','i386:x86-64','-M','intel',
                        f'--adjust-vma={start}','/tmp/wb62m_cw.bin'],capture_output=True,text=True).stdout
    ins=[]
    for ln in out.splitlines():
        mc=re.match(r'^\s*[0-9a-f]+:\s*((?:[0-9a-f]{2}\s+)+)$',ln)
        if mc:
            if ins: ins[-1]=(ins[-1][0],ins[-1][1]+mc.group(1).split(),ins[-1][2],ins[-1][3])
            continue
        m=re.match(r'\s*([0-9a-f]+):\s*((?:[0-9a-f]{2} )+)\s*(\S+)\s*(.*)$',ln)
        if m: ins.append((int(m.group(1),16),m.group(2).split(),m.group(3),m.group(4).strip()))
    cur=start; has_e8=False
    for (a,byts,mn,rest) in ins:
        if a!=cur: sys.exit(1)
        cur=a+len(byts)
        b0=int(byts[0],16)
        if mn=='(bad)': sys.exit(1)
        if b0==0x9A: sys.exit(1)
        if b0==0xFF and len(byts)>=2 and ((int(byts[1],16)>>3)&7) in (2,3): sys.exit(1)
        if mn in ('call','lcall','callf'):
            if b0!=0xE8: sys.exit(1)
            has_e8=True
        elif mn=='jmp' and b0 not in (0xE9,0xEB): sys.exit(1)
        # B1 (mirrors the gate): E8/E9 must land in [start,end); EB is pinned to the fixed
        # F4-preceded halt-loop (`F4 EB FD`, targeting the hlt) -- the only legitimate EB.
        if b0 in (0xE8,0xE9) and len(byts)>=5:
            rel=struct.unpack('<i',bytes(int(x,16) for x in byts[1:5]))[0]
            if not (start<=a+5+rel<end): sys.exit(1)
        elif b0==0xEB and len(byts)>=2:
            r=int(byts[1],16); rel=r-256 if r>=128 else r
            if not (a>=1 and code[a-1]==0xF4 and a+2+rel==a-1): sys.exit(1)
    if cur!=end: sys.exit(1)
    sys.exit(0 if has_e8 else 1)
# --- mutators (write a forged image to argv[3]) ---
if mode=='mk_noguard':
    pds=code_off+code_len-4096; esp=struct.unpack('<I',code[57:61])[0]; gidx=(esp-0x400000)//0x200000
    struct.pack_into('<Q',elf,pds+gidx*8,gidx*0x200000+0x83)   # make guard PDE present
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_fwdcall':
    # zero the first backward TAIL-E9 rel32 -> target becomes the next instr (no recursion edge)
    for i in range(len(code)-5):
        if code[i]==0xE9 and i>=len(RECL) and code[i-len(RECL):i]==RECL:
            rel=struct.unpack('<i',code[i+1:i+5])[0]
            if rel<0:
                struct.pack_into('<i',elf,code_off+i+1,0); break
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_norecl':
    # NOP the 4-byte `lea rsp,[rbp+8]` inside the reclamation window before the first backward tail E9
    for i in range(len(code)-5):
        if code[i]==0xE9 and i>=len(RECL) and code[i-len(RECL):i]==RECL:
            rel=struct.unpack('<i',code[i+1:i+5])[0]
            if rel<0:
                lea=code_off+i-7            # window layout: [4C895D08][488D6508][4C89D5] E9
                elf[lea:lea+4]=b'\x90\x90\x90\x90'; break
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_farcall':
    # inject 0x9A as an OPCODE: the first UNMASKED push rax (0x50) inside the scanned region
    # [56, gdt) -- an injection into a masked rel32 payload would be invisible by design.
    sig=b'\xff\xff\x00\x00\x00\x9a\xaf\x00'; pos=code.find(sig)
    scan=code[56:pos-8]
    imm=[False]*len(scan)
    for i in range(len(scan)):
        if scan[i] in (0xE8,0xE9) and not imm[i] and i+4<len(scan):
            for j in range(i+1,i+5): imm[j]=True
    for i in range(len(scan)):
        if scan[i]==0x50 and not imm[i]:
            elf[code_off+56+i]=0x9A; break
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='mk_maskhole':
    # GATE-TEETH B2: inject 0x9A at gt+10, a REAL instruction boundary (the opcode byte of the
    # fixed epilogue's `mov al,0xde`) that the OLD masked-byte-scan whitelist demonstrably
    # missed (see the header comment + run_native_codegen_link62.sh's callwhitelist comment for
    # the exact false-mask-cascade mechanism). gt is the grading tail `48 C1 E8 20` that always
    # immediately follows main's body.
    gt=code.find(b'\x48\xc1\xe8\x20',56)
    assert gt>=0, "no grading tail"
    assert code[gt+10]==0xB0, (hex(code[gt+10]), "expected the epilogue's mov al,0xde opcode byte")
    elf[code_off+gt+10]=0x9A
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
if mode=='verify_maskhole':
    # B2: confirm the forge actually injected 0x9A at gt+10 in the file under test, so a failed/
    # inert forge cannot be misread as a genuine RED by the leg below.
    gt=code.find(b'\x48\xc1\xe8\x20',56)
    sys.exit(0 if (gt>=0 and code[gt+10]==0x9A) else 1)
if mode=='mk_value':
    # perturb the first movabs imm64 operand (change the computed result -> different proof byte)
    idx=code.find(b'\x48\xb8')
    if idx>=0: elf[code_off+idx+2]^=0xFF
    open(sys.argv[3],'wb').write(elf); sys.exit(0)
sys.exit(3)
PYEOF

expect_red() { # name  cond(0=leg-passed-BAD)
    if [[ "$1" -ne 0 ]]; then pass=$((pass + 1)); else fail_test "$2 did not bite (leg still passed on the forged image)"; fi
}

# M-noguard: forge guard present -> guard white-box must fail
python3 "$PY" "$base" mk_noguard "$tmp/m_noguard.elf"
python3 "$PY" "$tmp/m_noguard.elf" guard; expect_red $? "M-noguard (guard white-box)"

# control: the un-forged base must PASS the backward tail-E9 pin (so each RED below is
# attributable to its forge, not to a broken checker)
python3 "$PY" "$base" backward_e9
if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail_test "control: base p1 fails the backward tail-E9 pin (checker broken)"; fi

# M-fwdcall: zero the backward tail-E9 rel -> backward tail-E9 value-pin must fail
python3 "$PY" "$base" mk_fwdcall "$tmp/m_fwd.elf"
python3 "$PY" "$tmp/m_fwd.elf" backward_e9; expect_red $? "M-fwdcall (backward tail-E9 pin)"

# M-norecl: NOP the lea rsp,[rbp+8] in the reclamation window -> the E9 is no longer an
# exact tail transition -> backward tail-E9 pin must fail
python3 "$PY" "$base" mk_norecl "$tmp/m_norecl.elf"
python3 "$PY" "$tmp/m_norecl.elf" backward_e9; expect_red $? "M-norecl (reclamation-window pin)"

# M-farcall: inject 0x9A opcode -> instruction-aware call-form whitelist must fail
python3 "$PY" "$base" mk_farcall "$tmp/m_far.elf"
python3 "$PY" "$tmp/m_far.elf" callwhitelist; expect_red $? "M-farcall (call-form whitelist)"

# GATE-TEETH B2: control-GREEN -- the unforged base must PASS the (now real-decode)
# call-form whitelist, so the RED below is attributable to the mk_maskhole forge, not to a
# broken checker.
python3 "$PY" "$base" callwhitelist
if [[ $? -eq 0 ]]; then
    echo "control: base p1 PASSES the real-decode call-form whitelist (checker not broken)"
    pass=$((pass + 1))
else
    fail_test "control: base p1 fails the real-decode call-form whitelist (checker broken)"
fi

# M-maskhole: inject 0x9A at gt+10 -- a REAL instruction boundary the OLD masked-byte-scan
# whitelist demonstrably missed (a coincidental E8/E9 byte VALUE inside the fixed
# grading-tail/halt epilogue false-masked it). The repaired REAL-decode whitelist (B1) must
# now catch it (bite RED where the pre-fix scanner PASSED).
python3 "$PY" "$base" mk_maskhole "$tmp/m_maskhole.elf"
forge_rc=$?
# B2: prove the FORGE itself succeeded and actually injected 0x9A at gt+10 BEFORE interpreting
# the checker's nonzero exit as RED -- otherwise a failed/inert forge (missing file, or the
# internal 0xB0-boundary assert tripping) would make the checker error out and be misread as a
# genuine bite. The RED must be attributable to the injected far-call opcode, not to a broken forge.
if [[ "$forge_rc" -ne 0 || ! -s "$tmp/m_maskhole.elf" ]]; then
    fail_test "M-maskhole forge did not produce a forged image (rc=$forge_rc)"
elif ! python3 "$PY" "$tmp/m_maskhole.elf" verify_maskhole; then
    fail_test "M-maskhole forge is inert (0x9A not present at gt+10 in the forged image)"
else
    python3 "$PY" "$tmp/m_maskhole.elf" callwhitelist
    mh_rc=$?
    if [[ "$mh_rc" -ne 0 ]]; then
        echo "M-maskhole bit RED: 0x9A at the real instruction boundary gt+10 (forge verified to contain it; the masked-scan hole Codex demonstrated) is now caught by the real-decode whitelist"
        pass=$((pass + 1))
    else
        fail_test "M-maskhole (call-form whitelist) did not bite (leg still passed on the verified-forged image)"
    fi
fi

# M-golden: the gate's golden-hash leg must bite (cross-model review: cmp-vs-base was near-vacuous).
# Control: the freshly-emitted base MATCHES the committed p1 golden; forged: a one-byte perturb
# MISMATCHES it -- the exact sha256-vs-committed comparison the gate performs.
goldens_dir="$script_dir/taproot_goldens"
want_g=$(cat "$goldens_dir/p1.sha256" 2>/dev/null || echo MISSING)
got_base=$(sha256sum "$base" | cut -d' ' -f1)
cp "$base" "$tmp/m_gold.elf"; printf '\xff' | dd of="$tmp/m_gold.elf" bs=1 seek=5000 count=1 conv=notrunc status=none 2>/dev/null
got_forged=$(sha256sum "$tmp/m_gold.elf" | cut -d' ' -f1)
if [[ "$got_base" == "$want_g" && "$got_forged" != "$want_g" ]]; then pass=$((pass + 1)); else fail_test "M-golden: golden-hash leg vacuous (base==golden:$([[ "$got_base" == "$want_g" ]] && echo yes || echo NO) forged!=golden:$([[ "$got_forged" != "$want_g" ]] && echo yes || echo NO))"; fi

# runtime CONTROL (fail-closed non-vacuity): the UNFORGED base must boot to the golden proof (rc=97 + de01ad)
# through the SAME QEMU path, so the M-value leg is provably live and a dead/timed-out QEMU cannot masquerade
# as the M-value bite (the fail-open bug: there was NO runtime control, so rc=124/empty scored the bite).
timeout 60 qemu-system-x86_64 -kernel "$base" -debugcon file:"$tmp/cv.bin" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M >/dev/null 2>"$tmp/cv.qerr"
crc=$?; c_e9=$(xxd -p "$tmp/cv.bin" 2>/dev/null | tr -d '\n'); cframes=$(echo "$c_e9" | grep -o 'de01ad' | wc -l | tr -d ' ')
c_clean=1; grep -qvE 'terminating on signal' "$tmp/cv.qerr" 2>/dev/null && c_clean=0   # F1/F3: a NON-timeout stderr line = QEMU launch failure (rc is NOT usable: isa-debug-exit yields odd codes to 255)
if [[ "$c_clean" -eq 1 && "$crc" -eq 97 && "$c_e9" == "de01ad" ]]; then echo "runtime control: unforged base cleanly boots to EXACTLY de01ad/exit97 -- the runtime leg is live/non-vacuous"; pass=$((pass + 1));
else fail_test "runtime control: unforged base did NOT cleanly boot to exactly de01ad/exit97 (rc=$crc e9='${c_e9:-EMPTY}' clean=$c_clean) -- HARNESS failure, the M-value leg cannot be trusted"; fi

# M-value: perturb the graded result -> the boot proof byte changes. Assert the POSITIVE forged outcome (the
# boot COMPLETED with a well-formed de..ad frame that DIVERGES from the golden de01ad/exit97), NOT the mere
# absence of de01ad (which a dead/timed-out QEMU would also satisfy -- the fail-open bug).
python3 "$PY" "$base" mk_value "$tmp/m_val.elf"
timeout 60 qemu-system-x86_64 -kernel "$tmp/m_val.elf" -debugcon file:"$tmp/mv.bin" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot -display none -serial none -monitor none -cpu qemu64 -m 64M >/dev/null 2>"$tmp/mv.qerr"
rc=$?; mv_e9=$(xxd -p "$tmp/mv.bin" 2>/dev/null | tr -d '\n')
mv_clean=1; grep -qvE 'terminating on signal' "$tmp/mv.qerr" 2>/dev/null && mv_clean=0    # F3/F1: a NON-timeout stderr line = QEMU launch failure
# F3: NO bare rc>=124 test -- isa-debug-exit yields odd, result-dependent exit codes up to 255, so rc alone is
# NOT a harness signal (124-vs-legit collides). A genuine M-value bite REQUIRES the e9 stream to be EXACTLY ONE
# well-formed de..ad frame whose byte is NON-golden (!= 01) AND whose isa-debug-exit code matches that byte
# (rc == ((byte^0x31)&0x7f)<<1|1, link62's host_qemu_exit formula) -- a golden frame with an abnormal exit
# (selective emulator death AFTER the frame landed) is a HARNESS failure, NOT the bite; so is a dead/timed-out
# QEMU (no frame) or a launch error (non-timeout stderr).
mv_byte=""; [[ "$mv_e9" =~ ^de([0-9a-f][0-9a-f])ad$ ]] && mv_byte="${BASH_REMATCH[1]}"
if [[ "$mv_clean" -eq 0 ]]; then
    fail_test "M-value: HARNESS failure -- QEMU launch error ($(grep -vE 'terminating on signal' "$tmp/mv.qerr" | head -1)); NOT a bite"
elif [[ -z "$mv_byte" ]]; then
    fail_test "M-value: HARNESS failure -- e9 stream is not exactly one well-formed de..ad frame (rc=$rc e9='${mv_e9:-EMPTY}'; dead/partial/timed-out QEMU); NOT a bite"
elif [[ "$mv_byte" == "01" ]]; then
    fail_test "M-value: forged result still graded as the golden byte de01ad (rc=$rc)"
elif [[ "$rc" -ne $(( (((0x$mv_byte ^ 0x31) & 0x7f) << 1) | 1 )) ]]; then
    fail_test "M-value: HARNESS failure -- divergent frame de${mv_byte}ad but exit code $rc mismatches its frame-derived expected $(( (((0x$mv_byte ^ 0x31) & 0x7f) << 1) | 1 )) (emulator died after the frame?); NOT a bite"
else
    pass=$((pass + 1))   # EXACTLY ONE non-golden frame + frame-coherent exit code -> genuine materialized divergence
fi

echo ""
if [[ "$fail" -ne 0 ]]; then echo "$fail link62-mutation sub-test(s) failed."; exit 1; fi
if [[ -e "$HVMARK" ]]; then echo "FAIL: link62 HARNESS FAILURE -- a QEMU run was dead/timed-out (empty output); fail-closed, NOT a genuine pass"; rm -f "$HVMARK"; exit 1; fi
echo "PASS: link62-mutation ($pass legs: controls GREEN (base p1 passes the backward tail-E9 pin + the real-decode call-form whitelist) + mutations each bit RED: guard white-box, backward tail-E9 pin (M-fwdcall), reclamation-window pin (M-norecl), real-decode call-form whitelist (M-farcall), the masked-scan hole now closed (M-maskhole: 0x9A at a real instruction boundary the old scanner missed), golden hash, runtime value)"
exit 0
