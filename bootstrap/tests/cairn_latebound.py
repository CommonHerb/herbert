#!/usr/bin/env python3
# cairn_latebound.py -- LATE-BOUND two-boot named-lookup forcing probers for the cairn (FILESYSTEM CAIRN, kernel-arc
# link 39 / native-codegen link 55) gate. This is an ADDITIVE sidecar to cairn_ref.py: it imports the FROZEN ref
# (its Asm, FS constants, parse_head/_wframes, grade_fs) and adds NOTHING to cairn_ref's genuine kernel logic. The
# baked module_fs_writer/module_fs_reader in cairn_ref.py are STEP-0 smoke probers (names + payloads hardcoded). The
# REAL gate must feed AUTHOR-UNKNOWN names/payloads/query over COM1 AFTER the kernel + probers are frozen, so a baked
# answer cannot stand in. These late-bound probers read every name byte, length byte, and payload byte over COM1 via
# SYS_READ (a CPL3 module cannot touch the UART -- the kernel reads each byte off COM1 and hands it back), so the
# emitted payload follows the late-bound input, not a constant.
#
# THE FORCING SCENARIO (the rigor heart of link 55):
#   BOOT-1 "putter": reads 2 records over COM1. Each record = 16 name bytes + 1 length byte + len payload bytes. For
#     each, it lays name(16)+payload(len) in its OWN in-region stack and SYS_FS_PUTs (EBX=name_ptr, ECX=payload_ptr,
#     EDX=len). The TARGET record is PUT first, the DECOY record PUT after (decoy-after-target). The two names SHARE A
#     15-byte PREFIX and differ ONLY in the last (16th) byte -- so a prefix-only name compare cannot tell them apart
#     (this forces the genuine full 16-byte compare). The payloads are high-entropy + late-bound (no baked answer).
#   REBOOT (RAM wiped, SAME disk image).
#   BOOT-2 "getter": reads an AUTHOR-UNKNOWN 16-byte QUERY over COM1 (chosen by the host AFTER the reboot) and
#     SYS_FS_GETs it, then SYS_WRITEs the resolved payload. The host runs it TWICE (or with two queries): once querying
#     the TARGET name, once the DECOY name. Each must emit ITS OWN payload. Querying the DECOY yielding the DECOY's
#     payload (not the first slot's) is what kills M-returnfirst; the per-entry data_lba being honoured is what kills
#     M-fixedlba.
#
# REGISTER/STACK contract (verified against cairn_ref's do_read/do_fs_put/do_fs_get arms):
#   * SYS_READ (eax=0) returns the byte in eax (movzx eax,bl) and the kernel arm clobbers ecx/edx; only eax is
#     meaningful on return. The prober's ESP/EIP/EFLAGS are restored by iret (the kernel iret's to the same useresp),
#     so ESP is STABLE across int 0x30 as long as the prober itself does not push between reads. We therefore reserve
#     a fixed-size buffer with `sub esp,BUFSZ` ONCE, then store each read byte at `[esp + i]` (esp unchanged between
#     reads) -- a clean, syscall-survivable scratch buffer.
#   * SYS_FS_PUT (eax=7): EBX=name_ptr(16), ECX=payload_ptr, EDX=len. SYS_FS_GET (eax=8): EBX=name_ptr(16 query),
#     ECX=dst_ptr, EDX=dst_cap; returns eax=found, ecx=len. SYS_WRITE (eax=2): ECX=ptr, EDX=len.
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cairn_ref as C
from cairn_ref import Asm, le32, FS_NAMELEN, FS_MAXLEN, SYS_READ, SYS_WRITE, SYS_FS_PUT, SYS_FS_GET, parse_head, _wframes, UCODE3, grade_fs

# the late-bound record count the putter reads (TARGET then DECOY -- decoy after target).
PUT_RECORDS = 2


def _read_n_bytes_to(m, dstoff_from_esp, n):
    # emit code that reads n bytes over COM1 (SYS_READ, one byte per int 0x30) and stores them at [esp + dstoff + i].
    # esp is STABLE across int 0x30 (the prober pushes nothing between reads), so [esp + k] addresses the buffer reliably.
    for i in range(n):
        m.raw(0xB8,0x00,0x00,0x00,0x00)                  # mov eax,0 (SYS_READ)
        m.raw(0xCD,0x30)                                 # int 0x30 -> the late-bound byte in eax (kernel read it off COM1)
        off = dstoff_from_esp + i
        # mov [esp + off], al  -- store the byte. Use the 32-bit-disp SIB form: 88 84 24 <le32(off)>.
        m.raw(0x88,0x84,0x24); m.blob(le32(off))         # mov byte [esp + off], al


def module_fs_writer_latebound(nrecords=PUT_RECORDS, maxpaylen=FS_MAXLEN):
    """BOOT-1 putter: read `nrecords` records over COM1 (each = 16 name bytes + 1 length byte + len payload bytes) and
       SYS_FS_PUT each (TARGET first, DECOY after). The names/payloads/lengths are ALL late-bound -- nothing is baked.
       Stack layout (esp-relative, fixed): [esp .. esp+15] = name(16) ; [esp+16] = (unused len byte slot, we read len
       into a stack slot too) ; [esp+OFF_PAY .. ] = payload. We allocate a generous fixed buffer and re-read it per
       record (the kernel persists each PUT to disk before we reuse the buffer)."""
    m = Asm()
    NAME_OFF = 0
    LEN_OFF = FS_NAMELEN                  # 1 byte slot for the late-bound length
    PAY_OFF = FS_NAMELEN + 4             # payload starts a few bytes after (4-align the length slot)
    BUFSZ = PAY_OFF + maxpaylen
    BUFSZ = (BUFSZ + 15) & ~15           # 16-align the reservation
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))            # sub esp, BUFSZ   (reserve the scratch buffer; esp now -> buffer base)
    for _rec in range(nrecords):
        # read the 16 name bytes into [esp+NAME_OFF .. +15]
        _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)
        # read 1 length byte into [esp+LEN_OFF]
        _read_n_bytes_to(m, LEN_OFF, 1)
        # load len into a register: movzx edx, byte [esp+LEN_OFF]
        m.raw(0x0F,0xB6,0x94,0x24); m.blob(le32(LEN_OFF))    # movzx edx, byte [esp+LEN_OFF]
        # read `len` payload bytes one at a time into [esp+PAY_OFF + i]. We cannot use a runtime loop count at compile
        # time (Herbert/our asm is straight-line), so we unroll up to maxpaylen reads but GUARD each on i < len: if
        # i >= len we still must consume nothing (the host sends exactly len payload bytes). To keep the byte stream
        # EXACTLY len long over COM1 we instead read EXACTLY `len` bytes via a compile-time-bounded, runtime-guarded loop
        # emitted as a forward/back jump. Simplest robust form: a small runtime loop using ecx as the index.
        # ecx = 0 (index)
        m.raw(0x31,0xC9)                              # xor ecx,ecx
        # loop: if ecx >= edx(len) -> done. We emit a manual loop with rel8 jumps.
        # We must preserve edx (len) and ecx (index) across SYS_READ (the kernel's do_read clobbers ecx/edx!). So we
        # stash len in a stack slot and the index in a stack slot, reloading them around each read.
        # Save len at [esp+LEN_OFF] already (it's the byte we read); reload via movzx each iteration. Save index too.
        IDX_OFF = FS_NAMELEN + 1         # 1-byte index slot (payload len <= 512 needs >8 bits -> use a 4-byte slot)
        IDX_OFF = FS_NAMELEN              # reuse via a dword slot? No -- keep distinct. Use a dedicated dword at LEN+0? Cleaner: a fixed dword.
        # Use a dedicated 4-byte index slot just past the payload-region-independent area. Place it at [esp + IDXSLOT].
        IDXSLOT = BUFSZ - 8              # a dword slot near the top of our reservation (well past name/len/payload)
        LENSLOT = BUFSZ - 4              # a dword slot for len
        m.raw(0xC7,0x84,0x24); m.blob(le32(IDXSLOT)); m.blob(le32(0))    # mov dword [esp+IDXSLOT], 0  (index=0)
        m.raw(0x89,0x94,0x24); m.blob(le32(LENSLOT))                     # mov [esp+LENSLOT], edx      (save len)
        # --- payload read loop ---
        loop_items_before = len(m.items)
        # we use forward/backward rel32 jumps via the Asm.j with explicit labels to keep this robust.
        m.lbl('pl_top_%d' % _rec)
        m.raw(0x8B,0x8C,0x24); m.blob(le32(IDXSLOT))                     # mov ecx, [esp+IDXSLOT]  (index)
        m.raw(0x3B,0x8C,0x24); m.blob(le32(LENSLOT))                     # cmp ecx, [esp+LENSLOT]
        m.j(0x83, 'pl_done_%d' % _rec)                                   # jae done (index >= len)
        # read one byte
        m.raw(0xB8,0x00,0x00,0x00,0x00)                                  # mov eax,0 (SYS_READ)
        m.raw(0xCD,0x30)                                                 # int 0x30 -> byte in eax
        # store it at [esp + PAY_OFF + index]. index is in [esp+IDXSLOT]; compute the dest = esp + PAY_OFF + index.
        m.raw(0x8B,0x8C,0x24); m.blob(le32(IDXSLOT))                     # mov ecx, [esp+IDXSLOT]   (reload index)
        # mov [esp + ecx + PAY_OFF], al  -- SIB with base=esp, index=ecx, scale=1, disp32=PAY_OFF: 88 84 0C <le32(PAY_OFF)>
        m.raw(0x88,0x84,0x0C); m.blob(le32(PAY_OFF))                    # mov byte [esp + ecx*1 + PAY_OFF], al
        # index++
        m.raw(0xFF,0x84,0x24); m.blob(le32(IDXSLOT))                    # inc dword [esp+IDXSLOT]
        m.j(None, 'pl_top_%d' % _rec)                                   # jmp loop top
        m.lbl('pl_done_%d' % _rec)
        # now SYS_FS_PUT: EBX = esp+NAME_OFF (name_ptr), ECX = esp+PAY_OFF (payload_ptr), EDX = len.
        m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))                   # lea ebx,[esp+NAME_OFF]   (name_ptr)
        m.raw(0x8D,0x8C,0x24); m.blob(le32(PAY_OFF))                    # lea ecx,[esp+PAY_OFF]    (payload_ptr)
        m.raw(0x8B,0x94,0x24); m.blob(le32(LENSLOT))                    # mov edx,[esp+LENSLOT]    (len)
        m.raw(0xB8); m.blob(le32(SYS_FS_PUT))                           # mov eax,7 (SYS_FS_PUT)
        m.raw(0xCD,0x30)                                                # int 0x30 -> persist (eax=1 stored / 0 rejected)
    # restore the stack + SYS_EXIT
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))            # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


def module_fs_reader_latebound(dstcap=FS_MAXLEN):
    """BOOT-2 getter: read a 16-byte QUERY name over COM1 (author-unknown, chosen AFTER the reboot), SYS_FS_GET it into
       a dst buffer, then SYS_WRITE the `len` resolved bytes. The query is late-bound -> the emitted payload follows
       the query, not a baked answer. Stack layout (esp-relative): [esp .. esp+15] = query name(16) ; [esp+DST_OFF ..]
       = dst buffer(dstcap)."""
    m = Asm()
    NAME_OFF = 0
    DST_OFF = FS_NAMELEN + 16            # leave a small gap; dst buffer past the query name
    BUFSZ = DST_OFF + dstcap
    BUFSZ = (BUFSZ + 15) & ~15
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))            # sub esp, BUFSZ   (reserve; esp -> buffer base)
    # read the 16 query-name bytes into [esp+NAME_OFF .. +15]
    _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)
    # SYS_FS_GET: EBX = name_ptr, ECX = dst_ptr, EDX = dst_cap. returns eax=found, ecx=len.
    m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))    # lea ebx,[esp+NAME_OFF]  (query name_ptr)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))     # lea ecx,[esp+DST_OFF]   (dst_ptr)
    m.raw(0xBA); m.blob(le32(dstcap))                # mov edx, dst_cap
    m.raw(0xB8); m.blob(le32(SYS_FS_GET))            # mov eax,8 (SYS_FS_GET)
    m.raw(0xCD,0x30)                                 # int 0x30 -> eax=found, ecx=len
    # SYS_WRITE the len resolved bytes: ECX = dst_ptr, EDX = len. ecx currently holds len; move it to edx, re-derive dst.
    m.raw(0x89,0xCA)                                 # mov edx,ecx              (edx = len)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))     # lea ecx,[esp+DST_OFF]    (dst_ptr)
    m.raw(0xB8); m.blob(le32(SYS_WRITE))             # mov eax,2 (SYS_WRITE)
    m.raw(0xCD,0x30)                                 # int 0x30 -> emit the resolved payload (len bytes)
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))            # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


def module_fs_getter_hostile_df(dstcap=FS_MAXLEN):
    """The hostile-DF getter (GAP-2: the FS string-op cld leg, the M-fsnocld output witness). It reads a VALID 16-byte
       query name over COM1 (matching a record), executes `std` (DF=1 -- the hostile direction flag) IMMEDIATELY before
       SYS_FS_GET, then `cld` after (to restore DF=0 for its OWN forthcoming SYS_WRITE relay), then SYS_WRITEs the
       resolved payload. The GENUINE kernel cld's before EVERY FS rep (the name-compare cmpsb + the dst-copy movsb), so
       the transfer is FORWARD regardless of the module's DF and the name resolves correctly + the right payload is copied
       -> the emitted payload == the expected payload (GREEN despite the module's std). M-fsnocld DROPS the FS clds, so
       the kernel inherits DF=1: the repe cmpsb walks BACKWARD off the dir-slot/query name (mis-comparison -> wrong/no
       match) and/or the dst-copy rep movsb reads BACKWARD from diskbuf into the page tables below it (a kernel-memory
       LEAK into dst) -> the emitted bytes != the expected payload -> RED. (Mirrors durable's hostile-DF writer leg.)"""
    m = Asm()
    NAME_OFF = 0
    DST_OFF = FS_NAMELEN + 16
    BUFSZ = DST_OFF + dstcap
    BUFSZ = (BUFSZ + 15) & ~15
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))            # sub esp, BUFSZ   (query name + dst buffer)
    _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)        # read the 16 query-name bytes over COM1 (VALID, matches a record)
    m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))    # lea ebx,[esp+NAME_OFF]   (query name_ptr)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))     # lea ecx,[esp+DST_OFF]    (dst_ptr)
    m.raw(0xBA); m.blob(le32(dstcap))                # mov edx, dst_cap
    m.raw(0xFD)                                      # std  (DF=1 -- the hostile direction flag, set right before the GET)
    m.raw(0xB8); m.blob(le32(SYS_FS_GET))            # mov eax,8 (SYS_FS_GET)
    m.raw(0xCD,0x30)                                 # int 0x30 -> GENUINE: kernel cld's, forward, correct ; M-fsnocld: backward, wrong/leak
    m.raw(0xFC)                                      # cld  (restore DF=0 for the prober's OWN SYS_WRITE relay below)
    m.raw(0x89,0xCA)                                 # mov edx,ecx              (edx = len returned)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))     # lea ecx,[esp+DST_OFF]    (dst_ptr)
    m.raw(0xB8); m.blob(le32(SYS_WRITE))             # mov eax,2 (SYS_WRITE)
    m.raw(0xCD,0x30)                                 # int 0x30 -> emit the resolved payload (len bytes)
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))            # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


def module_fs_getter_hostile_dstcarry(dstcap=FS_MAXLEN):
    """The hostile-CARRY getter (the access_ok overflow leg, the M-nocarrycheck output witness). It reads a VALID 16-byte
       query name over COM1 (so it MATCHES a record the putter PUT) but points dst_ptr at 0xFFFFFFF8 -- so dst_ptr+len
       WRAPS past the region high bound. The genuine do_fs_get does `add edx,ebx ; jc reject` on the dst pointer, so the
       wrapped dst is REJECTED -> found=0 (no out-of-region write); the getter SURVIVES and emits an 8-byte (found,len)
       envelope (both 0). M-nocarrycheck DROPS the carry-check, so the wrapped dst slips the `cmp edx,hi ; ja` (the wrap
       is small < hi) and the kernel `rep movsb`'s into 0xFFFFFFF8 -- an out-of-region kernel write that #PFs -> the
       getter FAULTS before emitting (empty). DISCRIMINATOR: genuine emits the 8-byte envelope; M-nocarrycheck emits
       nothing (faulted). The query is late-bound (read over COM1) so it genuinely matches a late-bound record."""
    m = Asm()
    NAME_OFF = 0
    BUFSZ = 64
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))            # sub esp, BUFSZ   (query-name buffer at [esp .. esp+15])
    _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)        # read the 16 query-name bytes over COM1 (VALID, matches a record)
    m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))    # lea ebx,[esp+0]      (valid query name_ptr -- matches)
    m.raw(0xB9); m.blob(le32(0xFFFFFFF8))            # mov ecx, 0xFFFFFFF8  (HOSTILE dst_ptr: dst_ptr+len WRAPS)
    m.raw(0xBA); m.blob(le32(dstcap))                # mov edx, dst_cap
    m.raw(0xB8); m.blob(le32(SYS_FS_GET))            # mov eax,8 (SYS_FS_GET)
    m.raw(0xCD,0x30)                                 # int 0x30 -> GENUINE: dst carry-check rejects (found=0); M-nocarry: faults on rep movsb
    # emit the (found, len) = (eax, ecx) envelope from the stack so the genuine clean-reject is OBSERVABLE (non-empty),
    # while a fault (M-nocarrycheck) leaves NOTHING emitted.
    m.raw(0x50)                                      # push eax (found)
    m.raw(0x51)                                      # push ecx (len)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(0))           # lea ecx,[esp]   (points at the (len,found) dword pair)
    m.raw(0xBA,0x08,0x00,0x00,0x00)                  # mov edx,8       (found + len = 8 bytes)
    m.raw(0xB8); m.blob(le32(SYS_WRITE))             # mov eax,2 (SYS_WRITE) -- emit the 8-byte envelope (genuine reject)
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x08)                            # add esp,8
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))            # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


# ---- host-side helpers for the late-bound records ----
def make_records(seed):
    """Deterministically derive the (target_name, target_payload, decoy_name, decoy_payload) for a given host seed.
       The two names SHARE A 15-byte PREFIX and differ ONLY in the last byte (forces the full 16-byte compare). The
       payloads are high-entropy (derived from the seed) and DIFFERENT lengths so a fixed-length forge can't stand in.
       The seed is chosen per-run by the host AFTER freeze, so nothing here is baked into the kernel/probers."""
    import hashlib
    h = hashlib.sha256(b'cairn-latebound|' + seed).digest()
    # a 15-byte shared prefix from the hash (printable-ish but raw bytes are fine over COM1)
    prefix = h[:15]
    tname = prefix + bytes([h[15]])
    # decoy name = same prefix, last byte differs (guaranteed != tname's last byte)
    dlast = (h[15] ^ 0x5A) & 0xFF
    if dlast == h[15]:
        dlast ^= 0x01
    dname = prefix + bytes([dlast])
    assert tname[:15] == dname[:15] and tname[15] != dname[15], 'names must share a 15-byte prefix, differ in last byte'
    assert len(tname) == 16 and len(dname) == 16
    # high-entropy payloads of DIFFERENT lengths (1..FS_MAXLEN). Use the hash stream, lengths derived from the seed.
    tlen = 24 + (h[16] % 40)             # ~24..63
    dlen = 24 + (h[17] % 40)
    if dlen == tlen:
        dlen += 1
    tpay = hashlib.sha256(b'tpay|' + seed).digest()
    while len(tpay) < tlen:
        tpay += hashlib.sha256(b'tpay|' + seed + bytes([len(tpay)])).digest()
    tpay = tpay[:tlen]
    dpay = hashlib.sha256(b'dpay|' + seed).digest()
    while len(dpay) < dlen:
        dpay += hashlib.sha256(b'dpay|' + seed + bytes([len(dpay)])).digest()
    dpay = dpay[:dlen]
    assert tpay != dpay
    return tname, tpay, dname, dpay


def prefix_mismatch_name(tname):
    """A negative-control query name that shares the TARGET's LAST byte but has a DIFFERENT 15-byte PREFIX. A genuine
       full-16-byte compare returns found=0 for this name (it matches no stored record); a forge that keys ONLY on the
       last byte (or that compares only the last byte / a suffix) would WRONGLY resolve it to the TARGET's payload. This
       closes the cross-model (Codex) hole that the decoy-after-target two-query alone does NOT force the FULL 16-byte
       compare -- it only rules out a prefix-only compare. The prefix-mismatch query rules out a last-byte-only compare,
       so the two together force EVERY one of the 16 bytes to matter."""
    assert len(tname) == 16
    # flip several PREFIX bytes (keep the last byte identical to the target's). Choose flips that cannot accidentally
    # collide with the decoy (the decoy shares the target's 15-byte prefix), so this name differs from BOTH records in
    # the prefix while keeping the target's last byte.
    pre = bytearray(tname[:15])
    pre[0] ^= 0xA5
    pre[7] ^= 0x3C
    pre[14] ^= 0x5A
    name = bytes(pre) + bytes([tname[15]])
    assert name[15] == tname[15] and name[:15] != tname[:15], 'prefix-mismatch must keep the last byte, change the prefix'
    return name


def putter_byte_stream(tname, tpay, dname, dpay):
    """The exact byte stream the COM1 feeder must send to the late-bound putter, in order: for each record
       (TARGET then DECOY): 16 name bytes, 1 length byte, len payload bytes."""
    out = bytearray()
    for name, pay in ((tname, tpay), (dname, dpay)):
        assert len(name) == 16 and 1 <= len(pay) <= FS_MAXLEN
        out += name
        out += bytes([len(pay)])
        out += pay
    return bytes(out)


def query_byte_stream(name16):
    assert len(name16) == 16
    return bytes(name16)


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'putter':                 # out  (BOOT-1 late-bound putter)
        open(sys.argv[2], 'wb').write(module_fs_writer_latebound()); sys.exit(0)
    elif cmd == 'getter':               # out  (BOOT-2 late-bound getter)
        open(sys.argv[2], 'wb').write(module_fs_reader_latebound()); sys.exit(0)
    elif cmd == 'hostilecarry':         # out  (the hostile-CARRY getter: valid query + dst_ptr=0xFFFFFFF8 so dst+len WRAPS)
        open(sys.argv[2], 'wb').write(module_fs_getter_hostile_dstcarry()); sys.exit(0)
    elif cmd == 'hostiledf':            # out  (the hostile-DF getter: std=DF=1 before SYS_FS_GET of a VALID name)
        open(sys.argv[2], 'wb').write(module_fs_getter_hostile_df()); sys.exit(0)
    elif cmd == 'records':              # seedhex -> print: tname_hex tpay_hex dname_hex dpay_hex
        seed = bytes.fromhex(sys.argv[2])
        tn, tp, dn, dp = make_records(seed)
        print(tn.hex(), tp.hex(), dn.hex(), dp.hex()); sys.exit(0)
    elif cmd == 'prefixmismatch':       # tname_hex -> print the prefix-mismatch (same last byte, different prefix) name hex
        print(prefix_mismatch_name(bytes.fromhex(sys.argv[2])).hex()); sys.exit(0)
    elif cmd == 'putstream':            # tname tpay dname dpay (all hex) -> print the putter COM1 byte stream (decimal bytes)
        tn = bytes.fromhex(sys.argv[2]); tp = bytes.fromhex(sys.argv[3])
        dn = bytes.fromhex(sys.argv[4]); dp = bytes.fromhex(sys.argv[5])
        s = putter_byte_stream(tn, tp, dn, dp)
        print(' '.join(str(b) for b in s)); sys.exit(0)
    elif cmd == 'querystream':          # name16hex -> print the query COM1 byte stream (decimal bytes)
        nm = bytes.fromhex(sys.argv[2])
        s = query_byte_stream(nm)
        print(' '.join(str(b) for b in s)); sys.exit(0)
    elif cmd == 'gradefs':              # stream kend wantpayloadhex  (reuse cairn_ref.grade_fs)
        stream = open(sys.argv[2], 'rb').read(); kend = int(sys.argv[3], 16); want = bytes.fromhex(sys.argv[4])
        errs = grade_fs(stream, kend, want)
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'emitbody':             # stream -> print the single emitted UCODE3 write-frame body (hex) for inspection
        stream = open(sys.argv[2], 'rb').read(); r = parse_head(stream)
        if not r:
            print('NO-TABLE'); sys.exit(2)
        wfs = [w for w in _wframes(r['_tail']) if w['closed'] and w['cs'] == UCODE3 and (w['cs'] & 3) == 3]
        print((wfs[0]['body'] if wfs else b'').hex()); sys.exit(0)
    else:
        raise SystemExit('usage: putter|getter|records|putstream|querystream|gradefs|emitbody')
