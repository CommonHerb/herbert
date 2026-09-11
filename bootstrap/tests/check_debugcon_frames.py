#!/usr/bin/env python3
"""Small adversarial battery for binary frame boundaries, not kernel semantics."""
from pathlib import Path
import struct
import unittest
import tempfile
import subprocess
import os
import debugcon_frames as d


def words(*values):
    return struct.pack('<'+'I'*len(values), *values)


def write(body):
    return b'\xd4'+words(len(body), 27, 0x110000, 0x120000)+body+b'\xd5'


class Frames(unittest.TestCase):
    def test_payload_and_headers_are_opaque(self):
        fake = write(b'counterfeit') + b'\xde\x00\xad' + b'\xd0'+words(1,2,3,4,5)+b'\xd1'
        # D4 in the wake byte caused the observed 3.4-billion-byte skip.
        raw = b'\xcc'+words(0,0xd4)+b'\xcd'+write(bytes(range(256))+fake)+b'\xde\x01\xad'
        tail = d.FramedTail(raw, 'cairn', 1)
        self.assertEqual([w['body'] for w in d.write_frames(tail)], [bytes(range(256))+fake])
        self.assertEqual(d.search(tail, 'answer', rb'\xde(.)\xad').group(1), b'\x01')
        self.assertFalse(d.records(tail, 'pf'))

    def test_bad_lengths_terminators_and_trailing_bytes_fail(self):
        genuine = write(b'\xd4\x00\xd5')+b'\xde\x00\xad'
        corruptions = [genuine[:-1], genuine+b'x', genuine+b'\xde\x00\xad',
                       b'\xd4'+words(0xffffffff,27,0,0)+genuine,
                       genuine[:20]+b'x'+genuine[21:]]
        for raw in corruptions:
            with self.subTest(raw=raw):
                with self.assertRaises(d.TraceError): d.FramedTail(raw, 'cairn', 1)
        with self.assertRaises(d.TraceError): d.write_frames(genuine)
        with self.assertRaises(d.TraceError) as error:
            d.FramedTail(b'\xd4'+words(0x1000000,27,0,0), 'cairn', 1)
        self.assertIs(type(error.exception), d.TraceError)

    def test_incomplete_tail_is_not_empty_success(self):
        for raw in (b'', write(b'good value')):
            with self.assertRaises(d.IncompleteTrace): d.FramedTail(raw, 'cairn', 1)
        for raw in (b'LARD', d.BANNER+b'\xe1\0\0', d.BANNER+b'\xf1\0\0',
                    d.BANNER+b'\xe1\xe2'+b'\0'*7):
            with self.assertRaises(d.IncompleteTrace): d.FramedTail(raw,'highwater',1)
        self.assertEqual([w['body'] for w in d.write_frames(d.FramedPrefix(write(b'progress'),'furlough',3))], [b'progress'])
        killed = (b'bash: line 1: 3577180 Broken pipe             yes c\n'
                  b'     3577181 Killed                  | timeout -s KILL 50 bochs -q -f bochsrc.txt\n')
        self.assertEqual(len(d.FramedPrefix(write(b'progress')+killed,'furlough',3).records), 1)
        with self.assertRaises(d.IncompleteTrace): d.FramedTail(write(b'progress')+killed,'furlough',3)
        with self.assertRaises(d.TraceError):
            d.FramedPrefix(write(b'progress')+killed.replace(b'bochs -q',b'other -q'),'furlough',3)
        with self.assertRaises(d.IncompleteTrace):
            d.write_frames(d.FramedTail(b'\x77', 'cairn', 1))

    def test_record_profiles_and_dispatch_shape(self):
        raw = b'\xc2'+words(0,0x1234,0,7)+b'\xc3'+b'\xca'+words(3,4)+b'\xcb'+b'\xde\0\xad'
        tail = d.FramedTail(raw, 'furlough', 2)
        self.assertEqual(d.fields(tail,'commit',('err','cr2','pte_before','pte_after'))[0]['cr2'],0x1234)
        for profile, count in [('tickover',2), ('furlough',1)]:
            with self.assertRaises(d.TraceError): d.FramedTail(raw,profile,count)

    def test_ambiguous_dump_is_error_not_pick(self):
        # Empty heap + 24-byte write, or three heap entries + empty write.
        # Both write interpretations share their D5 and reach the same answer.
        # A nested-looking record must produce ambiguity, never a chosen answer.
        raw=b'\xe1\xe2'+write(b'\0'*6+b'\xe2'+write(b'')[:-1])+b'\xde\0\xad'
        with self.assertRaisesRegex(d.TraceError, 'ambiguous'):
            d.FramedTail(raw,'larder',1)

    def test_bochs_28_pipeline_diagnostic(self):
        import rollcall_ref
        raw=(Path(__file__).parent/'fixtures/rollcall-bochs-2.8.e9').read_bytes()
        result=rollcall_ref.parse_head(raw)
        self.assertEqual([w['body'].hex() for w in d.write_frames(result['_tail'])],
                         ['1f1f2d00']*3+['06481100']*3+['feca0000'])
        with self.assertRaises(d.IncompleteTrace):
            d.FramedTail(write(b'ok')+d._YES_DIAGNOSTIC,'holler',1)
        with self.assertRaises(d.TraceError):
            d.FramedTail(b'\xde\0\xadunrecognized stderr\n','holler',1)

    def test_same_seed_real_bochs_capture(self):
        import cairn_ref
        raw=(Path(__file__).parent/'fixtures/cairn-bochs-ci-seed.e9').read_bytes()
        self.assertEqual(d.extract_bochs(b'Bochs banner\n'+raw), raw)
        with self.assertRaises(d.TraceError): d.extract_bochs(b'\xff'+raw)
        result=cairn_ref.parse_head(raw)
        frames=cairn_ref._wframes(result['_tail'])
        self.assertEqual(len(frames),1)
        self.assertEqual(frames[0]['body'].hex(),
                         'ee9f9abb802b2a9631c2d9e0338c8e03e920ec6b17e04abfd82871223c8a4aeed569761544096d9e0b77e5943e')
        self.assertEqual(d.records(result['_tail'],'answer')[0].raw,b'\xde\0\xad')

    def test_inverted_predicate_cannot_swallow_parser_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); work=root/'work'; work.mkdir()
            marker=work/'parser-errors.txt'
            env=dict(os.environ, KERNEL_PARSE_ERROR_FILE=str(marker), PYTHONPATH=str(Path(__file__).parent))
            caught=subprocess.run(['python3','-c',"from debugcon_frames import TraceError\ntry: raise TraceError('caught')\nexcept TraceError: pass"],env=env,capture_output=True)
            self.assertEqual(caught.returncode,0)
            self.assertFalse(marker.exists())
            code='source "$1" || exit 1; python3 -c "$3" >/dev/null 2>&1 || true; kernel_test_cleanup "$2"; echo BAD'
            result=subprocess.run(['bash','-c',code,'check',str(Path(__file__).parent/'qemu_prefix.sh'),str(work),
                                   "from debugcon_frames import TraceError; raise TraceError('malformed')"],env=env,capture_output=True)
            self.assertEqual(result.returncode,1)
            self.assertNotIn(b'BAD',result.stdout)
            self.assertIn(b'PARSER-ERROR',result.stderr)

    def test_corrupt_get_requires_a_positive_rejection(self):
        import tract_ref
        values=[1 if name=='nprocs' else 0 for name in tract_ref.CELLS]
        head=b'\x9a'+words(0,0,0,0)+words(*values)+b'\x9b'
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'trace'
            for tail, status, leak_status in [(d.BANNER+write(b'')+b'\xde\0\xad',0,1),
                                 (b'',1,1), (b'\xde\0\xad',1,1),
                                 (d.BANNER+write(b'')+write(b'')+b'\xde\0\xad',1,1),
                                 (d.BANNER+write(b'leak')+b'\xde\0\xad',1,0)]:
                path.write_bytes(head+tail)
                result=subprocess.run(['python3',str(Path(__file__).parent/'tract_latebound.py'),
                                       'gradecorrupt',str(path)],capture_output=True)
                self.assertEqual(result.returncode,status,result.stderr)
                result=subprocess.run(['python3',str(Path(__file__).parent/'tract_latebound.py'),
                                       'gradeleak',str(path)],capture_output=True)
                self.assertEqual(result.returncode,leak_status,result.stderr)

    def test_long_stream_without_recursive_parser_stack(self):
        raw=(b'\xcc'+words(0,0xd4)+b'\xcd')*10000+b'\xde\0\xad'
        self.assertEqual(len(d.FramedTail(raw,'cairn',1).records),10001)


if __name__ == '__main__': unittest.main()
