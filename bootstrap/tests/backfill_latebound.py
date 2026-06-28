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
import backfill_ref as C
from backfill_ref import (Asm, le32, FS_NAMELEN, FS_MAXLEN, FS_DIR_LBA, FS_DATA_LO, FS_D, FS_ENTSZ, FS_OFF_LEN, FS_OFF_LBA,
                        SYS_READ, SYS_WRITE, SYS_FS_PUT, SYS_FS_GET, SYS_FS_DEL,
                        parse_head, _wframes, UCODE3, grade_fs, grade_fs_deleted, grade_fs_found)

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


# ---- link42 (DELETE) late-bound probers ----
def module_fs_deleter_latebound():
    """BOOT-2 deleter: read a 16-byte NAME over COM1 (author-unknown, the DECOY name chosen AFTER the BOOT-1 reboot),
       SYS_FS_DEL it (tombstone the matching dir slot's valid:=0 IN PLACE + flush), then SYS_EXIT. The name is late-bound
       so the deletion targets a genuinely author-unknown record, and the deleter emits NOTHING itself -- the deletion is
       OBSERVED only by the BOOT-3 getter (the deleted name no longer resolves; the survivor still does)."""
    m = Asm()
    NAME_OFF = 0
    BUFSZ = 64
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))            # sub esp, BUFSZ   (name buffer at [esp .. esp+15])
    _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)        # read the 16 name bytes over COM1 (the DECOY = the delete-target)
    m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))    # lea ebx,[esp+NAME_OFF]   (name_ptr)
    m.raw(0xB8); m.blob(le32(SYS_FS_DEL))            # mov eax,12 (SYS_FS_DEL)
    m.raw(0xCD,0x30)                                 # int 0x30 -> tombstone the named slot + flush (eax=1 deleted / 0 not-found)
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))            # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


# ---- RAW on-disk directory oracle (host-side ground truth for the tombstone) ----
# Reads the directory sector DIRECTLY off the disk image (independent of SYS_FS_GET-by-name), so it observes the RAW
# {valid, name, len, data_lba} of a slot BY POSITION. This is the definitive tombstone oracle: a genuine DELETE clears the
# matched slot's valid:=0 IN PLACE and changes NOTHING else, so after DEL the slot is {valid==0, name UNCHANGED}. A
# cross-model (Codex) forge that restores valid==1 and CORRUPTS the NAME (so GET-by-name returns found==0) leaves valid==1
# and a changed name here -> caught; a corrupt-LEN/LBA forge leaves valid==1 -> caught; a tombstone-then-untombstone forge
# leaves valid==1 -> caught. A GET-by-name only proves NAME-ABSENCE; this proves the raw VALID bit.
import struct as _struct
def read_dir_slot(img_path, dir_lba, slot):
    with open(img_path, 'rb') as f:
        f.seek(dir_lba * 512); sec = f.read(512)
    base = slot * 28  # FS_ENTSZ
    valid = _struct.unpack('<I', sec[base:base+4])[0]
    length = _struct.unpack('<I', sec[base+4:base+8])[0]
    name = sec[base+8:base+8+FS_NAMELEN]
    lba = _struct.unpack('<I', sec[base+24:base+28])[0]
    return valid, length, name, lba


def module_fs_found_probe_latebound(dstcap=FS_MAXLEN):
    """BOOT-3 FOUND-probe: read a 16-byte name over COM1, SYS_FS_GET it, and emit the 1-byte FOUND flag (eax). found==0
       means the slot's valid==0 (REALLY tombstoned -- the GET scan skips valid!=1); found==1 means the slot is still
       valid (so found==1 with an empty payload is the "absence by corruption" forge -- the record is NOT deleted, GET
       just returns len==0). Grading "deleted" as found==0 makes the absence-by-corruption class OUTPUT-VISIBLE (a
       cross-model Codex leg drove this -- the zero-length GET payload is not sufficient evidence of deletion)."""
    m = Asm()
    NAME_OFF = 0
    DST_OFF = FS_NAMELEN + 16
    BUFSZ = DST_OFF + dstcap
    BUFSZ = (BUFSZ + 15) & ~15
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))            # sub esp, BUFSZ   (query name + dst buffer)
    _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)        # read the 16 name bytes over COM1
    m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))    # lea ebx,[esp+NAME_OFF]  (name_ptr)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))     # lea ecx,[esp+DST_OFF]   (dst_ptr -- GET needs a valid dst)
    m.raw(0xBA); m.blob(le32(dstcap))                # mov edx, dst_cap
    m.raw(0xB8); m.blob(le32(SYS_FS_GET))            # mov eax,8 (SYS_FS_GET)
    m.raw(0xCD,0x30)                                 # int 0x30 -> eax=found, ecx=len
    # emit the FOUND flag (eax) as 1 byte. STORE found into the dst buffer slot (NOT a push -- mirrors the getter's
    # emit-from-[esp+DST_OFF] pattern exactly; an in-region buffer write the SYS_WRITE relay reads back cleanly).
    m.raw(0x89,0x84,0x24); m.blob(le32(DST_OFF))     # mov [esp+DST_OFF], eax  (found dword; low byte = found)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))     # lea ecx,[esp+DST_OFF]   (emit ptr)
    m.raw(0xBA,0x01,0x00,0x00,0x00)                  # mov edx,1
    m.raw(0xB8); m.blob(le32(SYS_WRITE))             # mov eax,2 (SYS_WRITE) -- emit the 1-byte found flag
    m.raw(0xCD,0x30)
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))            # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


def module_fs_deleter_hostile_df():
    """The hostile-DF deleter (the DEL arm's cld leg, the M-fsnocld output witness for DELETE). Reads a VALID 16-byte name
       over COM1, executes `std` (DF=1) IMMEDIATELY before SYS_FS_DEL. The GENUINE kernel cld's before the DEL name-compare
       cmpsb, so the 16-byte compare runs FORWARD regardless of the module's DF -> the correct slot is tombstoned -> BOOT-3
       GET(that name) emits NOTHING (deleted). M-fsnocld inherits DF=1: the repe cmpsb walks BACKWARD off the dir-slot/query
       -> a mis/no-match -> the wrong slot (or no slot) is tombstoned -> the record SURVIVES -> BOOT-3 still resolves it ->
       RED. (Mirrors cairn's hostile-DF getter; the DEL arm has its OWN cld that this leg + assert_delete's cld pin force.)"""
    m = Asm()
    NAME_OFF = 0
    BUFSZ = 64
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))            # sub esp, BUFSZ
    _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)        # read the 16 name bytes over COM1 (VALID, matches the DECOY record)
    m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))    # lea ebx,[esp+NAME_OFF]   (name_ptr)
    m.raw(0xFD)                                      # std  (DF=1 -- hostile direction flag, set right before the DEL)
    m.raw(0xB8); m.blob(le32(SYS_FS_DEL))            # mov eax,12 (SYS_FS_DEL)
    m.raw(0xCD,0x30)                                 # int 0x30 -> GENUINE: kernel cld's, forward compare, right slot ; M-fsnocld: backward, wrong/no slot
    m.raw(0xFC)                                      # cld  (restore DF=0 -- defensive, the deleter does no further string op)
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))            # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


def module_fs_deleter_hostile_namecarry():
    """The hostile-name-CARRY deleter (the DEL arm's access_ok overflow leg, the M-nocarrycheck output witness for DELETE).
       Reads a VALID 16-byte name over COM1 (to keep the stream well-formed) but points name_ptr at 0xFFFFFFF8 -- so
       name_ptr+16 WRAPS. The genuine do_fs_del does `add edx,16 ; jc reject` on the name pointer, so the wrapped name is
       REJECTED -> eax=0 (no out-of-region read), the deleter SURVIVES and emits the 4-byte (found=0) envelope. M-nocarrycheck
       DROPS the carry-check -> the wrap slips `cmp edx,hi ; ja` (the small wrap < hi) and the cld;repe cmpsb reads from
       0xFFFFFFF8 -- an out-of-region kernel read that #PFs -> the deleter FAULTS before emitting (empty). DISCRIMINATOR:
       genuine emits the 4-byte envelope; M-nocarrycheck emits nothing (faulted). (DEL's only pointer is the name_ptr, so the
       name carry IS the discriminating surface -- unlike GET, where the dst carry was.)"""
    m = Asm()
    NAME_OFF = 0
    BUFSZ = 64
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))            # sub esp, BUFSZ
    _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)        # read 16 name bytes over COM1 (well-formed stream; the ptr is overridden)
    m.raw(0xBB); m.blob(le32(0xFFFFFFF8))            # mov ebx, 0xFFFFFFF8  (HOSTILE name_ptr: name_ptr+16 WRAPS)
    m.raw(0xB8); m.blob(le32(SYS_FS_DEL))            # mov eax,12 (SYS_FS_DEL)
    m.raw(0xCD,0x30)                                 # int 0x30 -> GENUINE: carry-check rejects (eax=0); M-nocarry: faults on the cmpsb read
    # emit the (found=eax) envelope so the genuine clean reject is OBSERVABLE (non-empty), while a fault leaves NOTHING.
    m.raw(0x50)                                      # push eax (found)
    m.raw(0x8D,0x8C,0x24); m.blob(le32(0))           # lea ecx,[esp]
    m.raw(0xBA,0x04,0x00,0x00,0x00)                  # mov edx,4
    m.raw(0xB8); m.blob(le32(SYS_WRITE))             # mov eax,2 (SYS_WRITE) -- emit the 4-byte envelope (genuine reject)
    m.raw(0xCD,0x30)
    m.raw(0x83,0xC4,0x04)                            # add esp,4
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))            # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]


# ============================ link43 (BACKFILL) PUT-first-free-slot REUSE forcing harness ============================
# The forcing is a CAPACITY-EXHAUSTION + LOWEST-SCAN 4-boot differential on ONE cache=writethrough disk image:
#   BOOT-1 "filler": PUT FS_D (=8) author-unknown records over COM1 -> the directory is FULL (slots 0..7, sectors
#                    FS_DATA_LO+0..7). On an EMPTY dir, first-free and append-by-count COINCIDE, so the backfill kernel
#                    and the frozen delete kernel reach the SAME state after BOOT-1.
#   BOOT-2 "multi-deleter": SYS_FS_DEL two STRICTLY-INTERIOR records (slots i<j, both != the tail), deleting the LOWER
#                    one FIRST -- so a LIFO "reuse last-deleted" forge diverges from a genuine lowest-valid==0 scan.
#                    Now exactly two slots (i,j) + two data sectors (FS_DATA_LO+i, FS_DATA_LO+j) are free; highest live = 7.
#   BOOT-3 "putter": PUT two NEW author-unknown records. GENUINE first-free: D0->slot i, D1->slot j (lowest-first),
#                    data_lba = FS_DATA_LO+slot, survivors UNTOUCHED. The FROZEN delete kernel (append-by-count): D0->slot
#                    count(valid==1)=6 (a LIVE survivor R6 -> CLOBBERED), D1->slot 6 again (clobbers D0); tail/monotonic
#                    forges -> reject at the D boundary. EVERY non-first-free allocator diverges from the expected state.
#   BOOT-4 "multi-getter" (functional confirm): GET the two NEW records by name across the reboot -> emit their payloads.
#   HOST (PRIMARY, ground truth): reuseok() reads the on-disk directory + data sectors BY POSITION and asserts the FULL
#                    expected FS state (all 8 slots {valid,name,len,data_lba} + all 8 data sectors). This is the link-42
#                    raw-oracle lesson carried forward: it binds REUSE (the new records occupy the freed holes lowest-first,
#                    1:1 data_lba, freed data sectors hold the new payloads) AND survivor-immutability (every survivor's
#                    slot + raw data sector UNCHANGED -- which also excludes a compaction forge that reuses by shifting).
PAYLEN_LO, PAYLEN_HI = 16, 48           # late-bound payload length band (<=255 so the writer's 1-byte len works)

def _rec(tag, seed, idx, paylen_seed):
    """Derive one (name16, payload) for record `idx` under `tag`. Names embed `tag`+idx so they are GLOBALLY DISTINCT
       (full-16 compare matters); payloads are high-entropy + length varied; all late-bound from the host seed."""
    import hashlib
    nh = hashlib.sha256(b'backfill-name|' + tag + b'|' + seed + bytes([idx])).digest()
    # name = tag(1 byte: F/N) + 15 HASH bytes. The idx is folded into the HASH input, NOT placed in a name byte, so the
    # name bytes carry NO slot-index correlation -- a name-keyed reuse forge (reuse the hole with the smallest stored name)
    # then picks a slot UNCORRELATED with the genuine lowest-index hole, so reuseok itself catches it (the cross-model
    # completeness leg found the old `tag+idx+hash` layout let a name-keyed forge match the first-free state via byte-1==idx).
    name = (tag[:1] + nh)[:FS_NAMELEN]                                      # tag + 15 hash bytes -> 16 distinct, index-uncorrelated bytes
    plen = PAYLEN_LO + (hashlib.sha256(b'plen|' + tag + seed + bytes([idx])).digest()[0] % (PAYLEN_HI - PAYLEN_LO))
    pay = b''
    while len(pay) < plen:
        pay += hashlib.sha256(b'backfill-pay|' + tag + b'|' + seed + bytes([idx, len(pay)])).digest()
    return name, pay[:plen]

def make_fill_records(seed, n=FS_D):
    """The FS_D filler records (BOOT-1). Globally distinct names, high-entropy varied-length payloads, all late-bound."""
    return [_rec(b'F', seed, i, seed) for i in range(n)]

NEW_N = 3                               # the number of NEW records PUT in BOOT-3 (== the number of holes punched)

def make_new_records(seed, n=NEW_N):
    """The NEW records (BOOT-3). A DIFFERENT tag so their names differ from every filler record."""
    return [_rec(b'N', seed, i, seed) for i in range(n)]

def del_holes(seed):
    """THREE holes {0, i, j} (slot 0 + two interior i<j in [1, FS_D-2]; the TAIL slot FS_D-1 stays live for the
       tail-append capacity bound), derived late-bound from the seed. Returns (holes_sorted, del_order):
         holes_sorted = [0, i, j]  -- the genuine first-free assignment is lowest-among-ALL: D0->0, D1->i, D2->j.
         del_order    = [i, j, 0]  -- a SCRAMBLED deletion order (neither ascending nor its reverse), so a FIFO free-list
                        (deletion order) AND a LIFO free-list (reverse) BOTH diverge from lowest-first; and including slot
                        0 as a hole kills a scan-from-slot-1 forge. (The cross-model Codex leg drove this strengthening:
                        the earlier 2-interior-hole design was matched by scan-from-1 + a FIFO free-list -- non-first-free
                        allocators that produced the same on-disk bytes. STEP-0 v2 confirms all forges now bite.)"""
    import hashlib
    h = hashlib.sha256(b'backfill-del|' + seed).digest()
    i = 1 + (h[0] % (FS_D - 4))             # 1 .. FS_D-4   (e.g. 1..4)
    j = i + 1 + (h[1] % (FS_D - 2 - i))     # i+1 .. FS_D-2 (e.g. ..6)
    assert 1 <= i < j <= FS_D - 2, (i, j)
    return [0, i, j], [i, j, 0]

def fill_byte_stream(records):
    """COM1 stream for the filler/putter (module_fs_writer_latebound): per record, 16 name + 1 len + len payload."""
    out = bytearray()
    for name, pay in records:
        assert len(name) == FS_NAMELEN and 1 <= len(pay) <= FS_MAXLEN
        out += name; out += bytes([len(pay)]); out += pay
    return bytes(out)

def names_byte_stream(names):
    """COM1 stream for the multi-deleter / multi-getter: just the concatenated 16-byte query names."""
    out = bytearray()
    for nm in names:
        assert len(nm) == FS_NAMELEN
        out += nm
    return bytes(out)

def module_fs_multi_deleter_latebound(ndel=2):
    """BOOT-2: read `ndel` author-unknown 16-byte names over COM1 and SYS_FS_DEL each in turn (lower-index record first).
       Unrolled (Herbert/our asm is straight-line); each DEL persists before the next name is read into the same buffer."""
    m = Asm()
    BUFSZ = 64
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))                 # sub esp, BUFSZ  (16-byte name scratch at [esp..esp+15])
    for _ in range(ndel):
        _read_n_bytes_to(m, 0, FS_NAMELEN)                # read the next 16-byte name over COM1
        m.raw(0x8D,0x9C,0x24); m.blob(le32(0))            # lea ebx,[esp]   (name_ptr)
        m.raw(0xB8); m.blob(le32(SYS_FS_DEL))             # mov eax,12 (SYS_FS_DEL)
        m.raw(0xCD,0x30)                                  # int 0x30 -> tombstone the named slot + flush
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))                 # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def module_fs_multi_reader_latebound(nq=2, dstcap=FS_MAXLEN):
    """BOOT-4: read `nq` author-unknown 16-byte query names over COM1; for each, SYS_FS_GET it and SYS_WRITE the resolved
       payload (concatenated on the wire, in query order). Functional confirmation that the NEW records resolve BY NAME
       across the reboot. Unrolled; the query name + dst buffer share one reservation, reused per query."""
    m = Asm()
    NAME_OFF = 0
    DST_OFF = FS_NAMELEN + 16
    BUFSZ = DST_OFF + dstcap
    BUFSZ = (BUFSZ + 15) & ~15
    m.raw(0x81,0xEC); m.blob(le32(BUFSZ))                 # sub esp, BUFSZ
    for _ in range(nq):
        _read_n_bytes_to(m, NAME_OFF, FS_NAMELEN)         # read the next 16-byte query name
        m.raw(0x8D,0x9C,0x24); m.blob(le32(NAME_OFF))     # lea ebx,[esp+NAME_OFF]  (query name_ptr)
        m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))      # lea ecx,[esp+DST_OFF]   (dst_ptr)
        m.raw(0xBA); m.blob(le32(dstcap))                 # mov edx, dst_cap
        m.raw(0xB8); m.blob(le32(SYS_FS_GET))             # mov eax,8 (SYS_FS_GET)
        m.raw(0xCD,0x30)                                  # int 0x30 -> eax=found, ecx=len
        m.raw(0x89,0xCA)                                  # mov edx,ecx   (len)
        m.raw(0x8D,0x8C,0x24); m.blob(le32(DST_OFF))      # lea ecx,[esp+DST_OFF]   (dst_ptr)
        m.raw(0xB8); m.blob(le32(SYS_WRITE))              # mov eax,2 (SYS_WRITE)
        m.raw(0xCD,0x30)                                  # int 0x30 -> emit this record's payload
    m.raw(0x81,0xC4); m.blob(le32(BUFSZ))                 # add esp, BUFSZ
    m.raw(0xB3,0x00); m.raw(0xB8,0x01,0x00,0x00,0x00); m.raw(0xCD,0x30)   # SYS_EXIT(0)
    m.raw(0xEB,0xFE)
    return m.assemble()[0]

def expected_fs(fillseed, newseed):
    """The host model of the CORRECT first-free final FS state, as a list of FS_D slot dicts {valid,name,len,lba} and a
       dict {lba: 512-byte sector}. fill FS_D (slots 0..FS_D-1) -> delete three holes {0,i,j} -> first-free PUT (lowest
       valid==0 among ALL slots, first) writes D0->0, D1->i, D2->j (the holes are sorted ascending)."""
    fill = make_fill_records(fillseed)
    new = make_new_records(newseed)
    holes, _del_order = del_holes(fillseed)
    slots = [None] * FS_D
    sectors = {}
    for k in range(FS_D):                                  # BOOT-1 fill (first-free == append on an empty dir)
        nm, pay = fill[k]
        slots[k] = {'valid': 1, 'name': nm, 'len': len(pay), 'lba': FS_DATA_LO + k}
        sectors[FS_DATA_LO + k] = pay + b'\x00' * (512 - len(pay))
    for h in holes:                                        # BOOT-2 delete the three holes (tombstone; data sectors left as-is)
        slots[h]['valid'] = 0
    assert sorted([k for k in range(FS_D) if slots[k]['valid'] == 0]) == holes
    # BOOT-3 first-free PUT: lowest valid==0 first. holes is sorted ascending -> D0->holes[0], D1->holes[1], D2->holes[2].
    for (slot, (nm, pay)) in zip(holes, new):
        slots[slot] = {'valid': 1, 'name': nm, 'len': len(pay), 'lba': FS_DATA_LO + slot}
        sectors[FS_DATA_LO + slot] = pay + b'\x00' * (512 - len(pay))
    return slots, sectors, holes, new

def read_data_sector(img_path, lba):
    with open(img_path, 'rb') as f:
        f.seek(lba * 512); return f.read(512)

def reuseok(img, fillseed, newseed):
    """PRIMARY ground-truth oracle: the on-disk directory (FS_D slots) + all FS_D data sectors must EXACTLY match the
       first-free expected state. Binds reuse (new records in the freed holes lowest-first, 1:1 data_lba, freed sectors
       carry the new payloads) AND survivor-immutability (every survivor slot + raw sector byte-unchanged). Returns []
       (GREEN) or a list of mismatches (RED)."""
    slots, sectors, holes, _new = expected_fs(fillseed, newseed)
    errs = []
    for k in range(FS_D):
        v, ln, nm, lb = read_dir_slot(img, FS_DIR_LBA, k)
        e = slots[k]
        tag = ('reused-hole' if k in holes else 'survivor')
        if v != e['valid']: errs.append(f'slot[{k}] ({tag}) valid={v} != {e["valid"]}')
        if nm != e['name']: errs.append(f'slot[{k}] ({tag}) name={nm.hex()} != {e["name"].hex()}')
        if ln != e['len']:  errs.append(f'slot[{k}] ({tag}) len={ln} != {e["len"]}')
        if lb != e['lba']:  errs.append(f'slot[{k}] ({tag}) data_lba={lb} != {e["lba"]} (1:1 invariant / decoupled-sector forge)')
        sec = read_data_sector(img, FS_DATA_LO + k)
        if sec != sectors[FS_DATA_LO + k]:
            errs.append(f'data sector {FS_DATA_LO + k} ({tag}) payload bytes differ (reuse/decoupled/corruption forge)')
    return errs

def fulldirok(img, fillseed, ninthseed):
    """Full-directory reject oracle (the first-free scan's no-free-slot path, otherwise UNEXERCISED by the reuse forcing):
       after BOOT-1 fills all FS_D slots and BOOT-2 PUTs a 9th record into the FULL directory, the first-free scan finds NO
       free slot (ecx reaches FS_D -> jae fs_put_reject) and must REJECT with NO write. Asserts (a) the directory is
       UNDISTURBED -- exactly FS_D live slots, all holding the original fill names, the 9th name ABSENT; and (b) the sector
       ONE PAST the data window (FS_DATA_LO+FS_D == FS_DATA_HI) is ALL-ZERO -- proving the reject did not compute
       fs_lba=FS_DATA_LO+FS_D and write out of the data window (the first-free PUT does NOT bound fs_lba, so in-window-ness
       rests entirely on this slot<FS_D reject). Returns [] (GREEN) or mismatches (RED)."""
    fill = make_fill_records(fillseed)
    ninth = make_new_records(ninthseed, 1)[0]
    fillnames = {n for n, _ in fill}
    errs = []
    live = 0
    for k in range(FS_D):
        v, ln, nm, lb = read_dir_slot(img, FS_DIR_LBA, k)
        if v == 1:
            live += 1
            if nm == ninth[0]: errs.append(f'slot[{k}] holds the 9th record name -- the full-dir PUT was NOT rejected (it overwrote/reused a slot)')
            elif nm not in fillnames: errs.append(f'slot[{k}] holds an unexpected name {nm.hex()} -- the full-dir directory was disturbed')
    if live != FS_D: errs.append(f'{live} live slots != FS_D={FS_D} -- the full directory was disturbed by the rejected PUT')
    over = read_data_sector(img, FS_DATA_LO + FS_D)        # == FS_DATA_HI, one sector PAST the data window
    if over != b'\x00' * 512: errs.append(f'sector {FS_DATA_LO + FS_D} (one past the data window) is NON-ZERO -- the full-dir PUT wrote OUT OF WINDOW (fs_lba=FS_DATA_LO+FS_D)')
    return errs


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'filler':                 # out  (BOOT-1: PUT FS_D author-unknown records -> fill the directory)
        open(sys.argv[2], 'wb').write(module_fs_writer_latebound(nrecords=FS_D)); sys.exit(0)
    elif cmd == 'putter2':              # out  (BOOT-3: PUT NEW_N new author-unknown records into the freed holes)
        open(sys.argv[2], 'wb').write(module_fs_writer_latebound(nrecords=NEW_N)); sys.exit(0)
    elif cmd == 'put1':                 # out  (a single-record putter -- the 9th PUT into a FULL directory, must be rejected)
        open(sys.argv[2], 'wb').write(module_fs_writer_latebound(nrecords=1)); sys.exit(0)
    elif cmd == 'put1stream':           # ninthseedhex -> the single 9th-record putter COM1 stream (decimal bytes)
        recs = make_new_records(bytes.fromhex(sys.argv[2]), 1)
        print(' '.join(str(b) for b in fill_byte_stream(recs))); sys.exit(0)
    elif cmd == 'fulldirok':            # img fillseedhex ninthseedhex  (GREEN iff the full-dir PUT was rejected: dir undisturbed + no out-of-window write)
        errs = fulldirok(sys.argv[2], bytes.fromhex(sys.argv[3]), bytes.fromhex(sys.argv[4]))
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'multideleter':         # out [ndel]  (BOOT-2: SYS_FS_DEL ndel author-unknown names, in the scrambled del-order)
        nd = int(sys.argv[3]) if len(sys.argv) > 3 else NEW_N
        open(sys.argv[2], 'wb').write(module_fs_multi_deleter_latebound(nd)); sys.exit(0)
    elif cmd == 'multigetter':          # out [nq]  (BOOT-4: GET nq author-unknown names -> emit their payloads)
        nq = int(sys.argv[3]) if len(sys.argv) > 3 else 2
        open(sys.argv[2], 'wb').write(module_fs_multi_reader_latebound(nq)); sys.exit(0)
    elif cmd == 'fillstream':           # fillseedhex -> the FS_D-record putter COM1 stream (decimal bytes)
        recs = make_fill_records(bytes.fromhex(sys.argv[2]))
        print(' '.join(str(b) for b in fill_byte_stream(recs))); sys.exit(0)
    elif cmd == 'newstream':            # newseedhex -> the 2-new-record putter COM1 stream (decimal bytes)
        recs = make_new_records(bytes.fromhex(sys.argv[2]))
        print(' '.join(str(b) for b in fill_byte_stream(recs))); sys.exit(0)
    elif cmd == 'delstream':            # fillseedhex -> the DELETE names in the SCRAMBLED del-order ([i,j,0]) COM1 stream
        fseed = bytes.fromhex(sys.argv[2]); fill = make_fill_records(fseed); _holes, order = del_holes(fseed)
        print(' '.join(str(b) for b in names_byte_stream([fill[k][0] for k in order]))); sys.exit(0)
    elif cmd == 'getstream':            # newseedhex -> the NEW_N NEW-record query names COM1 stream (BOOT-4 confirm)
        recs = make_new_records(bytes.fromhex(sys.argv[2]))
        print(' '.join(str(b) for b in names_byte_stream([r[0] for r in recs]))); sys.exit(0)
    elif cmd == 'expectednew':          # newseedhex -> the concatenated NEW payloads (hex) the BOOT-4 multigetter must emit
        recs = make_new_records(bytes.fromhex(sys.argv[2]))
        print(b''.join(r[1] for r in recs).hex()); sys.exit(0)
    elif cmd == 'newrec':               # newseedhex idx -> print: name_hex payload_hex  (one NEW record, for a single-getter functional confirm)
        recs = make_new_records(bytes.fromhex(sys.argv[2])); r = recs[int(sys.argv[3])]
        print(r[0].hex(), r[1].hex()); sys.exit(0)
    elif cmd == 'delidx':               # fillseedhex -> print: holes_sorted | del_order  (the three holes {0,i,j} + the scrambled deletion order)
        holes, order = del_holes(bytes.fromhex(sys.argv[2])); print(' '.join(map(str, holes)), '|', ' '.join(map(str, order))); sys.exit(0)
    elif cmd == 'reuseok':              # img fillseedhex newseedhex  (PRIMARY raw ground-truth oracle: GREEN iff the on-disk FS == first-free expected)
        errs = reuseok(sys.argv[2], bytes.fromhex(sys.argv[3]), bytes.fromhex(sys.argv[4]))
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'deleter':              # out  (BOOT-2 late-bound deleter: read a 16B name over COM1 -> SYS_FS_DEL it)
        open(sys.argv[2], 'wb').write(module_fs_deleter_latebound()); sys.exit(0)
    elif cmd == 'hostiledfdel':         # out  (the hostile-DF deleter: std=DF=1 before SYS_FS_DEL of a VALID name)
        open(sys.argv[2], 'wb').write(module_fs_deleter_hostile_df()); sys.exit(0)
    elif cmd == 'hostilenamecarrydel':  # out  (the hostile-name-carry deleter: name_ptr=0xFFFFFFF8 so name_ptr+16 WRAPS)
        open(sys.argv[2], 'wb').write(module_fs_deleter_hostile_namecarry()); sys.exit(0)
    elif cmd == 'dirslot':              # img lba slot -> print: valid namehex len lba  (raw on-disk dir slot)
        v, ln, nm, lb = read_dir_slot(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        print(v, nm.hex(), ln, lb); sys.exit(0)
    elif cmd == 'tombstoneok':          # img lba delslot delname_hex survslot survname_hex
        # RAW-DIR ground-truth tombstone check: GREEN iff dir[delslot]={valid==0, name==delname (UNCHANGED)} AND
        # dir[survslot]={valid==1, name==survname (UNCHANGED)}. Catches every "absence by corruption" forge structurally.
        img = sys.argv[2]; lba = int(sys.argv[3])
        ds = int(sys.argv[4]); dn = bytes.fromhex(sys.argv[5]); ss = int(sys.argv[6]); sn = bytes.fromhex(sys.argv[7])
        dv, dl, dnm, dlb = read_dir_slot(img, lba, ds)
        sv, sl, snm, slb = read_dir_slot(img, lba, ss)
        errs = []
        if dv != 0:        errs.append(f'deleted slot[{ds}] valid={dv} != 0 (NOT tombstoned -- noop / restored-valid / corrupt-non-valid-field forge)')
        if dnm != dn:      errs.append(f'deleted slot[{ds}] name={dnm.hex()} != {dn.hex()} (the name was CORRUPTED -- a rename forge faking absence, not a tombstone)')
        if sv != 1:        errs.append(f'survivor slot[{ss}] valid={sv} != 1 (the survivor was OVER-DELETED -- wipeall / wrong-slot forge)')
        if snm != sn:      errs.append(f'survivor slot[{ss}] name={snm.hex()} != {sn.hex()} (the survivor was corrupted)')
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'foundprobe':           # out  (BOOT-3 FOUND-probe getter: emits the 1-byte found flag of a name)
        open(sys.argv[2], 'wb').write(module_fs_found_probe_latebound()); sys.exit(0)
    elif cmd == 'gradefound':           # stream kend wantfound(0|1)  (GREEN iff the emitted found byte == want; 0=deleted)
        stream = open(sys.argv[2], 'rb').read(); kend = int(sys.argv[3], 16); want = int(sys.argv[4])
        errs = grade_fs_found(stream, kend, want)
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'gradedeleted':         # stream kend  (GREEN iff the BOOT-3 GET of the DELETED name emitted NOTHING -- WEAK; prefer foundprobe+gradefound)
        stream = open(sys.argv[2], 'rb').read(); kend = int(sys.argv[3], 16)
        errs = grade_fs_deleted(stream, kend)
        if errs:
            print('RED'); [print('  -', e) for e in errs]; sys.exit(1)
        print('GREEN'); sys.exit(0)
    elif cmd == 'putter':                 # out  (BOOT-1 late-bound putter)
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
