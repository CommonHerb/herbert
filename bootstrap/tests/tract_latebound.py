#!/usr/bin/env python3
# tract (link 44) LATE-BOUND multi-sector forcing prober + host RAW-DISK ground-truth grader.
# The 4-boot forcing (one cache=writethrough disk), all records/names/sizes LATE-BOUND over COM1 (seed chosen AFTER
# freeze, so a baker forge fails):
#   BOOT-1 writer  : PUT 5 records R0..R4 (sizes 2,2,3,2,1 sectors; payloads >512B w/ partial last; random names).
#                    First-fit-by-LBA lays them contiguously: R0[0,2) R1[2,4) R2[4,7) R3[7,9) R4[9,10).
#   BOOT-2 deleter : DEL R1 and R2 (adjacent -> a MERGED 5-sector free gap [2,7)). R0 stays the LOWEST live survivor.
#   BOOT-3 writer  : PUT N0 (4 sectors) -> genuine first-fit lands it in the MERGED gap at sector 2 (4>3 and 4>2
#                    individually, <=5); then N1 (1 sector) -> the SPLIT remainder at sector 6.
#   BOOT-4 getter  : GET R0 (survivor), N0, N1 by name -> SYS_WRITE each -> byte-exact reassembly (functional).
# HOST reuseok (PRIMARY, raw ground truth): reads the on-disk dir + all data sectors BY POSITION and asserts
#   N0.data_lba==LO+2 (first-fit lowest merged gap) + N0 payload byte-exact across its run + N0 last-sector padding==0;
#   N1.data_lba==LO+6 (split remainder); R0 (survivor) data_lba==LO+0 + payload + run UNCHANGED. Binds multi-sector
#   reassembly (trunc/noceil RED), reuse+first-fit-by-LBA (decoupled/bump/bestfit RED), padding (nopadzero RED),
#   survivor-immutability (decoupled clobber RED). varsize=False (frozen backfill) REJECTS the >512 PUT -> RED.
import os, sys, struct, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
for _p in (os.path.dirname(os.path.abspath(__file__)), '/home/gulpin/Desktop/MEWTWO/herbert/bootstrap/tests'):
    if os.path.exists(os.path.join(_p, 'tract_ref.py')): sys.path.insert(0, _p)
from tract_ref import (Asm, le32, FS_NAMELEN, FS_DIR_LBA, FS_DATA_LO, FS_D, FS_ENTSZ, FS_OFF_LEN, FS_OFF_LBA,
                       FS_OFF_VALID, FS_OFF_NAME, TRACT_MAXLEN, TRACT_DATA_HI, TRACT_W, UCODE3, parse_head, _wframes)
SYS_READ=0; SYS_EXIT=1; SYS_WRITE=2; SYS_FS_PUT=7; SYS_FS_GET=8; SYS_FS_DEL=12
SEC=512

# ---------------------------------------------------------------- modules ----
def _read_n_to(m, off, n):
    for i in range(n):
        m.raw(0xB8,0x00,0x00,0x00,0x00)                  # mov eax,0 (SYS_READ)
        m.raw(0xCD,0x30)                                 # int 0x30 -> byte in eax
        m.raw(0x88,0x84,0x24); m.blob(le32(off+i))       # mov [esp+off+i], al

def module_writer_multi(nrecords):
    """PUT nrecords records, each late-bound over COM1: 16 name bytes + 2 length bytes (LE, up to TRACT_MAXLEN) +
       len payload bytes (read via a runtime-counted loop, so >512 works). One generous buffer reused per record (the
       kernel persists each PUT before reuse). Unique per-record loop labels."""
    m=Asm()
    NAME_OFF=0; LEN_OFF=FS_NAMELEN; PAY_OFF=FS_NAMELEN+4
    BUFSZ=PAY_OFF+TRACT_MAXLEN; BUFSZ=(BUFSZ+15)&~15
    IDXSLOT=BUFSZ-8; LENSLOT=BUFSZ-4
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))                 # sub esp,BUFSZ
    for r in range(nrecords):
        _read_n_to(m, NAME_OFF, FS_NAMELEN)
        _read_n_to(m, LEN_OFF, 2)
        m.raw(0x0F,0xB7,0x94,0x24); m.blob(le32(LEN_OFF)) # movzx edx, word [esp+LEN_OFF]
        m.raw(0xC7,0x84,0x24); m.blob(le32(IDXSLOT)); m.blob(le32(0))   # index=0
        m.raw(0x89,0x94,0x24); m.blob(le32(LENSLOT))      # save len
        m.lbl('pl_top_%d'%r)
        m.raw(0x8B,0x8C,0x24); m.blob(le32(IDXSLOT))      # mov ecx,[esp+IDXSLOT]
        m.raw(0x3B,0x8C,0x24); m.blob(le32(LENSLOT))      # cmp ecx,[esp+LENSLOT]
        m.j(0x83, 'pl_done_%d'%r)                          # jae done
        m.raw(0xB8,0x00,0x00,0x00,0x00); m.raw(0xCD,0x30) # SYS_READ -> al
        m.raw(0x8B,0x8C,0x24); m.blob(le32(IDXSLOT))      # reload index
        m.raw(0x88,0x84,0x0C); m.blob(le32(PAY_OFF))      # mov [esp+ecx+PAY_OFF], al
        m.raw(0xFF,0x84,0x24); m.blob(le32(IDXSLOT))      # inc dword [esp+IDXSLOT]
        m.j(None, 'pl_top_%d'%r)
        m.lbl('pl_done_%d'%r)
        m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))     # lea ebx,[esp+NAME_OFF]
        m.raw(0x8D,0x8C,0x24); m.blob(le32(PAY_OFF))      # lea ecx,[esp+PAY_OFF]
        m.raw(0x8B,0x94,0x24); m.blob(le32(LENSLOT))      # mov edx,[esp+LENSLOT]
        m.raw(0xB8); m.blob(le32(SYS_FS_PUT)); m.raw(0xCD,0x30)
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def module_deleter(ndel):
    """DEL ndel records, each name late-bound over COM1."""
    m=Asm(); BUFSZ=64
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))
    for _ in range(ndel):
        _read_n_to(m, 0, FS_NAMELEN)
        m.raw(0x8D,0x9C,0x24); m.blob(le32(0))            # lea ebx,[esp]
        m.raw(0xB8); m.blob(le32(SYS_FS_DEL)); m.raw(0xCD,0x30)
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def module_getter(nq):
    """GET nq names (late-bound over COM1), SYS_WRITE each resolved payload (len bytes). One write-frame per query."""
    m=Asm()
    NAME_OFF=0; DST_OFF=FS_NAMELEN+16
    BUFSZ=DST_OFF+TRACT_MAXLEN; BUFSZ=(BUFSZ+15)&~15
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))
    for _ in range(nq):
        _read_n_to(m, NAME_OFF, FS_NAMELEN)
        m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))     # lea ebx,[esp+NAME_OFF]
        m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))      # lea ecx,[esp+DST_OFF]
        m.raw(0xBA); m.blob(le32(TRACT_MAXLEN))           # mov edx,dst_cap
        m.raw(0xB8); m.blob(le32(SYS_FS_GET)); m.raw(0xCD,0x30)   # -> eax=found, ecx=len
        m.raw(0x89,0xCA)                                  # mov edx,ecx (len)
        m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))      # lea ecx,[esp+DST_OFF]
        m.raw(0xB8); m.blob(le32(SYS_WRITE)); m.raw(0xCD,0x30)
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

# ---------------------------------------------------------------- records ----
SIZES=[2,2,3,2,1]   # R0..R4 sector sizes ; R0=survivor(lowest), R1+R2 deleted(adjacent->merged), R3,R4 survivors
DEL_IDX=[1,2]       # delete R1,R2 (adjacent)
def _entropy(tag, seed, n):
    out=b''
    while len(out)<n: out+=hashlib.sha256(tag+seed+bytes([len(out)&0xFF, (len(out)>>8)&0xFF])).digest()
    return out[:n]
def _len_for(sz, h, i):
    # a partial last sector: len in ((sz-1)*512, sz*512]  -> exercises ceil + padding
    lo=(sz-1)*SEC+1; span=sz*SEC-lo+1
    return lo+(h[i]%span)
def make_records(seed):
    h=hashlib.sha256(b'tract|'+seed).digest()
    used=set(); recs=[]
    for i,sz in enumerate(SIZES):
        while True:
            nm=_entropy(b'name%d|'%i, seed, 16)
            if nm not in used: used.add(nm); break
        ln=_len_for(sz,h,i); pay=_entropy(b'pay%d|'%i, seed, ln)
        recs.append((nm,pay,sz))
    # BOOT-3 new records: N0 size 4 (merged gap), N1 size 1 (split remainder)
    newrecs=[]
    for j,sz in enumerate([4,1]):
        while True:
            nm=_entropy(b'new%d|'%j, seed, 16)
            if nm not in used: used.add(nm); break
        ln=_len_for(sz,h,5+j); pay=_entropy(b'newpay%d|'%j, seed, ln)
        newrecs.append((nm,pay,sz))
    return recs, newrecs

def putter_stream(records):
    out=bytearray()
    for nm,pay,_sz in records:
        assert len(nm)==16 and 1<=len(pay)<=TRACT_MAXLEN
        out+=nm; out+=struct.pack('<H', len(pay)); out+=pay
    return bytes(out)
def name_stream(names):
    out=bytearray()
    for nm in names: assert len(nm)==16; out+=nm
    return bytes(out)

# ---------------------------------------------------------------- raw disk oracle ----
def _read_sec(img, lba):
    with open(img,'rb') as f: f.seek(lba*SEC); return f.read(SEC)
def _dir_entry(img, slot):
    sec=_read_sec(img, FS_DIR_LBA); b=slot*FS_ENTSZ
    valid=struct.unpack('<I',sec[b:b+4])[0]; ln=struct.unpack('<I',sec[b+4:b+8])[0]
    name=sec[b+8:b+8+FS_NAMELEN]; lba=struct.unpack('<I',sec[b+24:b+28])[0]
    return dict(valid=valid,len=ln,name=name,lba=lba)
def _find(img, name):
    for s in range(FS_D):
        e=_dir_entry(img,s)
        if e['valid']==1 and e['name']==name: return e
    return None
def _read_run(img, lba, ln):
    n=(ln+SEC-1)//SEC; return b''.join(_read_sec(img, lba+k) for k in range(n))
def reuseok(img, seed):
    """PRIMARY raw ground-truth: assert the post-BOOT-3 on-disk state == the genuine first-fit-by-LBA expected state."""
    recs,newrecs=make_records(seed); errs=[]
    N0=newrecs[0]; N1=newrecs[1]; R0=recs[0]
    # expected placements (window-local): merged gap at 2, split remainder at 6, survivor R0 at 0
    LO=FS_DATA_LO
    e0=_find(img,N0[0])
    if not e0: errs.append('N0 not found in dir')
    else:
        if e0['lba']!=LO+2: errs.append(f'N0.data_lba={e0["lba"]} != LO+2={LO+2} (first-fit merged-gap reuse FAILED -- bump/bestfit/decoupled)')
        if e0['len']!=len(N0[1]): errs.append(f'N0.len={e0["len"]} != {len(N0[1])}')
        run=_read_run(img,e0['lba'],e0['len'])
        if run[:e0['len']]!=N0[1]: errs.append('N0 payload NOT byte-exact across its run (trunc/noceil/multi-sector bug)')
        pad=run[e0['len']:]
        if pad!=b'\x00'*len(pad): errs.append('N0 last-sector PADDING != 0 (nopadzero leak)')
    e1=_find(img,N1[0])
    if not e1: errs.append('N1 not found in dir')
    elif e1['lba']!=LO+6: errs.append(f'N1.data_lba={e1["lba"]} != LO+6={LO+6} (split-remainder reuse FAILED)')
    elif _read_run(img,e1['lba'],e1['len'])[:e1['len']]!=N1[1]: errs.append('N1 payload not byte-exact')
    eR0=_find(img,R0[0])
    if not eR0: errs.append('R0 (survivor) MISSING -- clobbered (decoupled)')
    else:
        if eR0['lba']!=LO+0: errs.append(f'R0.data_lba={eR0["lba"]} != LO+0 (survivor moved)')
        if _read_run(img,eR0['lba'],eR0['len'])[:eR0['len']]!=R0[1]: errs.append('R0 (survivor) payload CHANGED (decoupled clobber)')
    return errs

# ---- HOSTILE corrupt-entry leg (confused-deputy: the GET trusts the stored data_lba; a crafted dir entry whose run
# straddles the window must be REJECTED -- the GENUINE overflow-safe guard emits NOTHING; M-norunbound reads the
# out-of-window sector and LEAKS a frame). Codex (cross-model) caught the runend overflow; this output-forces the guard. ----
CORRUPT_NAME = b'CORRUPTENTRY!!\x00\x00'   # 16 bytes
assert len(CORRUPT_NAME)==16
def craft_corrupt_dir(img, data_lba, length):
    # write a dir sector with slot0 = {valid=1, len, name=CORRUPT, data_lba} (a HOST-crafted hostile entry), rest zero.
    sec=bytearray(SEC)
    struct.pack_into('<I', sec, 0, 1); struct.pack_into('<I', sec, 4, length)
    sec[8:8+16]=CORRUPT_NAME; struct.pack_into('<I', sec, 24, data_lba & 0xFFFFFFFF)
    with open(img,'r+b') as f: f.seek(FS_DIR_LBA*SEC); f.write(sec)

def emitbody(out_path):
    """Extract the concatenation of all closed ring-3 (UCODE3) write-frame bodies from a debugcon dump (the BOOT-4
       getter's GET+SYS_WRITE relays). Returns the list of frame bodies."""
    try: deb=open(out_path,'rb').read()
    except Exception: return []
    r=parse_head(deb); tail=r['_tail'] if r else deb
    wfs=[w for w in _wframes(tail) if w['closed'] and w['cs']==UCODE3 and (w['cs']&3)==3]
    return [w['body'] for w in wfs]

# ---------------------------------------------------------------- main (CLI for the bash gate) ----
# Streams are emitted as SPACE-SEPARATED DECIMAL byte values (the kernel_input_feed.py interface: feeder <port> b0 b1 ...).
def _emit(b): print(' '.join(str(x) for x in b))
def main():
    import base64
    cmd=sys.argv[1]
    seed=bytes.fromhex(sys.argv[2]) if len(sys.argv)>2 and cmd not in ('module','reuseok','emitbody','gradeforce','gradeone','craftcorrupt','gradecorrupt') else None
    if cmd=='putstream1':        # PUT R0..R4 (BOOT-1)
        _emit(putter_stream(make_records(seed)[0]))
    elif cmd=='delstream':       # DEL R1,R2 (BOOT-2)
        _emit(name_stream([make_records(seed)[0][i][0] for i in DEL_IDX]))
    elif cmd=='putstream3':      # PUT N0,N1 (BOOT-3)
        _emit(putter_stream(make_records(seed)[1]))
    elif cmd=='getstream4':      # GET R0(survivor), N0, N1 (BOOT-4, 3-query getter)
        recs,newrecs=make_records(seed); _emit(name_stream([recs[0][0],newrecs[0][0],newrecs[1][0]]))
    elif cmd=='getname':         # getname <seedhex> <0|1|2> -> the 16-byte name stream for R0/N0/N1 (single-query getter)
        recs,newrecs=make_records(seed); idx=int(sys.argv[3])
        _emit([recs[0][0],newrecs[0][0],newrecs[1][0]][idx])
    elif cmd=='gradeone':        # gradeone <out> <seedhex> <0|1|2> -> exit 0 iff the single-query getter emitted that payload byte-exact
        recs,newrecs=make_records(bytes.fromhex(sys.argv[3])); idx=int(sys.argv[4])
        want=[recs[0][1],newrecs[0][1],newrecs[1][1]][idx]; bodies=emitbody(sys.argv[2])
        if want in bodies: print('ONE-OK'); sys.exit(0)
        print('ONE-ERR: idx=%d want %dB, got frames %s'%(idx,len(want),[len(b) for b in bodies])); sys.exit(1)
    elif cmd=='craftcorrupt':    # craftcorrupt <img>  -> write a HOSTILE dir entry whose run STRADDLES the window (data_lba=HI-1,len=1024 -> runend=HI+1)
        craft_corrupt_dir(sys.argv[2], TRACT_DATA_HI-1, 1024)
    elif cmd=='corruptname':     # the 16-byte CORRUPT query name stream (for the getter)
        _emit(CORRUPT_NAME)
    elif cmd=='gradecorrupt':    # gradecorrupt <out> -> exit 0 iff NO NON-EMPTY ring-3 frame. The genuine getter on a
        # REJECTED GET (found=0 -> len=0) still does SYS_WRITE(dst,0) -> a 0-byte frame; that is the rejection, NOT a leak.
        # A real out-of-window leak (M-norunbound) emits a NON-EMPTY frame (the out-of-window sector bytes).
        nonempty=[b for b in emitbody(sys.argv[2]) if len(b)>0]
        if not nonempty: print('CORRUPT-REJECTED'); sys.exit(0)
        print('CORRUPT-LEAK: %d non-empty frame(s) lens=%s'%(len(nonempty),[len(b) for b in nonempty])); sys.exit(1)
    elif cmd=='counts':          # the (writer,deleter,getter) module record-counts for this scenario
        print(len(SIZES), len(DEL_IDX), len(make_records(seed)[1]), 3)   # writer1=5, del=2, writer3=2(N0,N1), get=3
    elif cmd=='exp':             # exp <seedhex> <R0|N0|N1> -> RAW expected getter payload bytes to stdout
        recs,newrecs=make_records(seed); tag=sys.argv[3]
        m={'R0':recs[0][1],'N0':newrecs[0][1],'N1':newrecs[1][1]}; sys.stdout.buffer.write(m[tag])
    elif cmd=='module':          # module <which> <count> <outfile>
        which=sys.argv[2]; cnt=int(sys.argv[3]); outf=sys.argv[4]
        open(outf,'wb').write({'writer':module_writer_multi,'deleter':module_deleter,'getter':module_getter}[which](cnt))
    elif cmd=='reuseok':         # reuseok <img> <seedhex> -> OK / errors ; exit 0/1
        errs=reuseok(sys.argv[2], bytes.fromhex(sys.argv[3]))
        if errs:
            for e in errs: print('REUSE-ERR:', e)
            sys.exit(1)
        print('REUSE-OK'); sys.exit(0)
    elif cmd=='emitbody':        # emitbody <out> -> base64 of each closed ring-3 write-frame body, one per line
        for b in emitbody(sys.argv[2]): print(base64.b64encode(b).decode())
    elif cmd=='gradeforce':      # gradeforce <out> <seedhex> -> exit 0 iff BOOT-4 emitted [R0,N0,N1] payloads byte-exact
        bodies=emitbody(sys.argv[2]); recs,newrecs=make_records(bytes.fromhex(sys.argv[3]))
        want=[recs[0][1], newrecs[0][1], newrecs[1][1]]   # R0(survivor), N0, N1
        if bodies==want: print('FUNC-OK'); sys.exit(0)
        print('FUNC-ERR: got %d frames lens=%s want lens=%s' % (len(bodies),[len(b) for b in bodies],[len(w) for w in want])); sys.exit(1)
    else:
        print('unknown cmd', cmd); sys.exit(2)

if __name__=='__main__': main()
