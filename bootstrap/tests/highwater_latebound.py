#!/usr/bin/env python3
# Companion for run_native_codegen_link61.sh (highwater / kernel-arc link 45). The gate boots the EMITTED highwater kernel
# + the late-bound ring-3 prober at a PER-RUN-RANDOM -m (the author-unknown memory size) feeding the seed over COM1, and
# grades the kernel-emitted trace: N frames allocated TOP-DOWN from region_hi(-m) (a baked-address forge fails for a random
# -m), each holding its seed-derived payload (proving real distinct RAM; a single-frame / no-invlpg forge collapses the
# readbacks). CLI:
#   refkernel <out>            -- highwater_ref.build_elf(highwater=True)
#   tractkernel <out>          -- the FROZEN tract kernel (== build_elf(highwater=False)); the differential
#   kernel <out> <mut|none>    -- a (mutant) highwater kernel, ref-built
#   prober <out>               -- the late-bound ring-3 prober (reads the seed over COM1)
#   stream <seedbyte>          -- the COM1 feed stream (one byte) for kernel_input_feed.py
#   grade <trace> <ram_mb> <seedbyte>  -- GREEN / RED<reason> (struct-flake reasons are retry-safe)
#   expecths <ram_mb>          -- the expected region_hi (diagnostic)
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import highwater_ref as HW
NP = HW.GROWHEAP_NPAGES
MAGIC = bytes([0x4C,0x41,0x52,0x44,0x45,0x52,0xA5,0x5A])
HOSTILE_N = HW.HW_MAXFRAMES + 8   # the hostile over-cap prober's alloc count (> the HW_MAXFRAMES per-boot cap)

def build(mut=None):
    img,_,_ = HW.build_elf(mut=mut, npages=NP, fsdel=True, fsreuse=True, varsize=True, highwater=True)
    return img
def build_tract():
    img,_,_ = HW.build_elf(npages=NP, fsdel=True, fsreuse=True, varsize=True, highwater=False)  # == tract byte-for-byte
    return img

def parse_trace(stream):
    # after MAGIC: (0xF0 + le32 addr)*N allocs ; 0xF1 ; (le32 addr + le32 readback)*N ; 0xF3
    i = stream.rfind(MAGIC)
    if i < 0: return None, 'MAGIC banner not found'
    i += len(MAGIC)
    allocs = []
    while i < len(stream) and stream[i] == HW.HW_AMARK:
        if i+5 > len(stream): return None, 'truncated alloc entry'
        allocs.append(struct.unpack('<I', stream[i+1:i+5])[0]); i += 5
    if i >= len(stream) or stream[i] != HW.HW_DBEGIN:
        return None, 'no HWDUMP begin (truncated; %d allocs)' % len(allocs)
    i += 1
    pairs = []
    while i+8 <= len(stream) and stream[i] != HW.HW_DEND:
        pairs.append((struct.unpack('<I', stream[i:i+4])[0], struct.unpack('<I', stream[i+4:i+8])[0])); i += 8
    if i >= len(stream) or stream[i] != HW.HW_DEND:
        return None, 'no HWDUMP end (truncated; %d pairs)' % len(pairs)
    return {'allocs': allocs, 'pairs': pairs}, 'ok'

MAXRESV = 0x40000   # max BIOS/firmware reservation below the RAM top we tolerate (QEMU reserves 0x20000; Bochs 0x1000).
                    # The substrate-supported -m values are >=8MiB apart, so this 256KiB window cannot collide across -m:
                    # a baked-address forge for one -m lands OUTSIDE every other -m's window -> RED (forge-resistant + substrate-robust).

def hostile_grade(trace_path, ram_mb):
    # The hostile leg: a prober calls SYS_FALLOC HW_MAXFRAMES+8 times. The genuine kernel CAPS at HW_MAXFRAMES (the first
    # HW_MAXFRAMES emit real top-down frames; the rest emit the OOM sentinel 0xF0++0 and do NOT descend/store), so EXACTLY
    # HW_MAXFRAMES non-zero FALLOC addresses appear and HWDUMP dumps HW_MAXFRAMES frames. M-hwnocap emits MORE than
    # HW_MAXFRAMES non-zero addresses (the cap is gone) -> RED (and at higher n would overrun hw_frames[] into kernel RAM).
    data = open(trace_path,'rb').read() if os.path.exists(trace_path) else b''
    t, msg = parse_trace(data)
    if t is None: return 'RED: %s' % msg
    nonzero = [a for a in t['allocs'] if a != 0]
    if len(nonzero) > HW.HW_MAXFRAMES:
        return 'RED: %d non-zero FALLOC frames > HW_MAXFRAMES=%d -- the per-boot cap was NOT enforced (a hostile loop overruns/descends)' % (len(nonzero), HW.HW_MAXFRAMES)
    if len(nonzero) != HW.HW_MAXFRAMES:
        return 'RED: %d non-zero FALLOC frames != HW_MAXFRAMES=%d (truncated?)' % (len(nonzero), HW.HW_MAXFRAMES)
    if len(t['pairs']) != HW.HW_MAXFRAMES:
        return 'RED: HWDUMP dumped %d frames != HW_MAXFRAMES=%d' % (len(t['pairs']), HW.HW_MAXFRAMES)
    # the capped frames must be a contiguous top-down run from a region_hi consistent with -m
    region_hi = (nonzero[0] + 0x1000) & 0xFFFFFFFF; top = ram_mb * 0x100000
    if not (top - MAXRESV < region_hi <= top):
        return 'RED: capped region_hi %s not in window for -m %dM' % (hex(region_hi), ram_mb)
    exp = [(region_hi - (i+1)*0x1000) & 0xFFFFFFFF for i in range(HW.HW_MAXFRAMES)]
    if nonzero != exp:
        return 'RED: capped frames not contiguous top-down'
    return 'GREEN: SYS_FALLOC capped at HW_MAXFRAMES=%d (the over-cap allocs were rejected; no hw_frames[] overrun, no descent into kernel RAM)' % HW.HW_MAXFRAMES

def grade(trace_path, ram_mb, seed):
    data = open(trace_path,'rb').read() if os.path.exists(trace_path) else b''
    t, msg = parse_trace(data)
    if t is None: return 'RED: %s' % msg            # struct flake (retry-safe) -- truncated/missing trace
    allocs, pairs = t['allocs'], t['pairs']
    if len(allocs) != HW.HW_N: return 'RED: %d alloc entries (truncated; expected %d)' % (len(allocs), HW.HW_N)
    if len(pairs) != HW.HW_N: return 'RED: %d hwdump entries (truncated; expected %d)' % (len(pairs), HW.HW_N)
    # Derive region_hi from the emitted top frame, and pin it to the launched -m (catches a baked-address forge + the -m
    # differential: a trace from a DIFFERENT -m falls outside this -m's window). region_hi must be page-aligned and sit in
    # (ram_mb*1MiB - MAXRESV, ram_mb*1MiB] -- the page-aligned ceiling of the author-unknown RAM, minus at most MAXRESV.
    region_hi = (allocs[0] + 0x1000) & 0xFFFFFFFF
    top = ram_mb * 0x100000
    if region_hi & 0xFFF: return 'RED: region_hi %s not page-aligned' % hex(region_hi)
    if not (top - MAXRESV < region_hi <= top):
        return 'RED: region_hi %s not in (%s-0x%x, %s] for -m %dM != expected top-down' % (hex(region_hi), hex(top), MAXRESV, hex(top), ram_mb)
    fr_exp = [(region_hi - (i+1)*0x1000) & 0xFFFFFFFF for i in range(HW.HW_N)]   # contiguous descending from region_hi
    pay_exp = [HW.hw_payload(seed, i) for i in range(HW.HW_N)]
    if allocs != fr_exp:
        return 'RED: alloc addrs %s != contiguous top-down %s' % ([hex(a) for a in allocs], [hex(a) for a in fr_exp])
    if [p[0] for p in pairs] != fr_exp:
        return 'RED: hwdump addrs %s != expected %s' % ([hex(p[0]) for p in pairs], [hex(a) for a in fr_exp])
    if [p[1] for p in pairs] != pay_exp:
        return 'RED: readbacks %s != expected payloads %s' % ([hex(p[1]) for p in pairs], [hex(p) for p in pay_exp])
    return 'GREEN: %d top-down frames @ %s (region_hi=%s, -m %dM), each holds its seed-derived payload' % (HW.HW_N, hex(fr_exp[0]), hex(region_hi), ram_mb)

if __name__ == '__main__':
    cmd = sys.argv[1] if sys.argv[1:] else ''
    if cmd == 'refkernel': open(sys.argv[2],'wb').write(build()); print('ok')
    elif cmd == 'tractkernel': open(sys.argv[2],'wb').write(build_tract()); print('ok')
    elif cmd == 'kernel':
        mut = sys.argv[3] if len(sys.argv) > 3 else 'none'
        open(sys.argv[2],'wb').write(build(None if mut == 'none' else mut)); print('ok')
    elif cmd == 'prober': open(sys.argv[2],'wb').write(HW.module_highwater_prober(seed=None)); print('ok')
    elif cmd == 'hostileprober': open(sys.argv[2],'wb').write(HW.module_highwater_prober(seed=None, n=HOSTILE_N)); print('ok')
    elif cmd == 'hostilegrade': print(hostile_grade(sys.argv[2], int(sys.argv[3])))
    elif cmd == 'stream': print(int(sys.argv[2]) & 0xFF)
    elif cmd == 'grade': print(grade(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]) & 0xFF))
    elif cmd == 'expecths': print('0x%08x' % HW.hw_region_hi_qemu(int(sys.argv[2])))
    else: raise SystemExit('usage: refkernel|tractkernel|kernel|prober|stream|grade|expecths')
