#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
HERBERT="${HERBERT:-$repo_root/build/herbert}"
fragment="$repo_root/stack/native_elf_fragment.herb"

if [[ ! -x "$HERBERT" ]]; then
    echo "FAIL: stack/native_elf_fragment.herb (cannot find herbert at $HERBERT)"
    exit 1
fi
if [[ ! -f "$fragment" ]]; then
    echo "FAIL: stack/native_elf_fragment.herb (missing fragment)"
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: stack/native_elf_fragment.herb ($1)"
    exit 1
}

# tollgate: retire C from grading this link. The ELF-emitter fragment used to be
# EXECUTED by the C interpreter (`$HERBERT $fragment`) to produce the a.out under
# test. It is now COMPILED by the C-free gen-1 seed to a native ELF, and that ELF
# is RUN with the same 1-byte stdin -- the fragment runs natively, no C. C is
# preserved as an OPT-IN byte-faithfulness cross-check under NATIVE_CODEGEN_ORACLE=c.
source "$script_dir/native_codegen_oracle.sh"
native_codegen_ensure_compiler "$tmp/native-compiler" || exit 1
frag_native="$tmp/native_elf_fragment.elf"
frag_cdir="$tmp/frag.cdir"; rm -rf "$frag_cdir"; mkdir -p "$frag_cdir"
( cd "$frag_cdir" && "$NATIVE_CODEGEN_COMPILER" <"$fragment" >"$tmp/frag.cc.out" 2>"$tmp/frag.cc.err" )
if [[ ! -f "$frag_cdir/a.out" ]]; then
    fail "seed did not compile native_elf_fragment.herb: $(head -1 "$tmp/frag.cc.out") $(head -1 "$tmp/frag.cc.err")"
fi
cp "$frag_cdir/a.out" "$frag_native"; chmod +x "$frag_native"

write_byte() {
    local hex="$1"
    LC_ALL=C printf '%b' "\\x$hex"
}

emit_aout() {
    local hex="$1"
    local aout="$2"
    local err="$tmp/emit-$hex.err"
    if ! write_byte "$hex" | "$frag_native" >"$aout" 2>"$err"; then
        echo "--- stderr"
        cat "$err"
        fail "emitter exit for param 0x$hex"
    fi
    # Opt-in: the C interpreter must emit a byte-identical a.out.
    if [[ "$NATIVE_CODEGEN_ORACLE" == "c" ]]; then
        local cref="$tmp/emit-$hex.cref"
        if ! write_byte "$hex" | "$HERBERT" "$fragment" >"$cref" 2>/dev/null || ! cmp -s "$aout" "$cref"; then
            fail "C cross-check diverged from native a.out for param 0x$hex"
        fi
    fi
}

assert_readelf() {
    local aout="$1"
    local eh="$tmp/readelf-h.txt"
    local ph="$tmp/readelf-l.txt"
    local sections="$tmp/readelf-S.txt"
    local dynamic="$tmp/readelf-d.txt"
    local relocs="$tmp/readelf-r.txt"
    readelf -h "$aout" >"$eh" || fail "readelf -h failed"
    readelf -l "$aout" >"$ph" || fail "readelf -l failed"
    readelf -S "$aout" >"$sections" || fail "readelf -S failed"
    readelf -d "$aout" >"$dynamic" || fail "readelf -d failed"
    readelf -r "$aout" >"$relocs" || fail "readelf -r failed"

    grep -Fq "Class:                             ELF64" "$eh" || fail "readelf header class"
    grep -Fq "Data:                              2's complement, little endian" "$eh" || fail "readelf header data"
    grep -Fq "Type:                              EXEC (Executable file)" "$eh" || fail "readelf header type"
    grep -Fq "Machine:                           Advanced Micro Devices X86-64" "$eh" || fail "readelf header machine"
    grep -Fq "Entry point address:               0x400078" "$eh" || fail "readelf entry"
    grep -Fq "Start of program headers:          64 (bytes into file)" "$eh" || fail "readelf phoff"
    grep -Fq "Start of section headers:          0 (bytes into file)" "$eh" || fail "readelf shoff"
    grep -Fq "Size of this header:               64 (bytes)" "$eh" || fail "readelf ehsize"
    grep -Fq "Size of program headers:           56 (bytes)" "$eh" || fail "readelf phentsize"
    grep -Fq "Number of program headers:         1" "$eh" || fail "readelf phnum"
    grep -Fq "Size of section headers:           0 (bytes)" "$eh" || fail "readelf shentsize"
    grep -Fq "Number of section headers:         0" "$eh" || fail "readelf shnum"
    grep -Fq "Section header string table index: 0" "$eh" || fail "readelf shstrndx"

    grep -Fq "Elf file type is EXEC (Executable file)" "$ph" || fail "readelf program type"
    grep -Fq "Entry point 0x400078" "$ph" || fail "readelf program entry"
    grep -Fq "There is 1 program header, starting at offset 64" "$ph" || fail "readelf program count"
    [[ "$(grep -c '^[[:space:]]*LOAD[[:space:]]' "$ph")" == "1" ]] || fail "readelf LOAD count"
    grep -Eq '^[[:space:]]*LOAD[[:space:]]+0x0+0[[:space:]]+0x0*400000[[:space:]]+0x0*400000' "$ph" || fail "readelf LOAD address"
    grep -Eq '^[[:space:]]+0x0*1000[[:space:]]+0x0*1000[[:space:]]+R E[[:space:]]+0x1000$' "$ph" || fail "readelf LOAD size/flags"

    grep -Fq "There are no sections in this file." "$sections" || fail "readelf sections"
    grep -Fq "There is no dynamic section in this file." "$dynamic" || fail "readelf dynamic"
    grep -Fq "There are no relocations in this file." "$relocs" || fail "readelf relocs"
}

assert_bytes() {
    local aout="$1"
    perl - "$aout" <<'PERL' || fail "raw byte gate"
use strict;
use warnings;

my ($path) = @ARGV;
open my $fh, '<:raw', $path or die "open $path: $!\n";
local $/;
my $s = <$fh>;

sub bad {
    print STDERR "byte gate: $_[0]\n";
    exit 1;
}

sub first_diff {
    my ($base, $got, $want) = @_;
    my $n = length($got) < length($want) ? length($got) : length($want);
    for my $i (0 .. $n - 1) {
        my $g = ord(substr($got, $i, 1));
        my $w = ord(substr($want, $i, 1));
        return sprintf("offset 0x%04x expected 0x%02x got 0x%02x", $base + $i, $w, $g) if $g != $w;
    }
    return sprintf("length mismatch at offset 0x%04x", $base + $n);
}

my @headers = (
    0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x3e, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x78, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x38, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
);
my @code = (
    0xb8, 0x01, 0x00, 0x00, 0x00,
    0xbf, 0x01, 0x00, 0x00, 0x00,
    0x48, 0xbe, 0x9c, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xba, 0x01, 0x00, 0x00, 0x00,
    0x0f, 0x05,
    0xb8, 0xe7, 0x00, 0x00, 0x00,
    0x31, 0xff,
    0x0f, 0x05,
);

length($s) == 4098 or bad("file size expected 4098 got " . length($s));
my $header = pack('C*', @headers);
my $code = pack('C*', @code);
substr($s, 0x00, 0x78) eq $header
    or bad(first_diff(0x00, substr($s, 0x00, 0x78), $header));
substr($s, 0x78, 0x24) eq $code
    or bad(first_diff(0x78, substr($s, 0x78, 0x24), $code));
ord(substr($s, 0x9c, 1)) == 0x41
    or bad(sprintf("offset 0x009c expected 0x41 got 0x%02x", ord(substr($s, 0x9c, 1))));
substr($s, 0x9d, 0x1000 - 0x9d) eq ("\0" x (0x1000 - 0x9d))
    or bad("non-zero byte in page padding");
substr($s, 0x1000, 2) eq "0\n"
    or bad("trailer expected 30 0a at offset 0x1000");
PERL
}

assert_objdump() {
    local aout="$1"
    local dump="$tmp/objdump.txt"
    objdump -D -b binary -m i386:x86-64 --adjust-vma=0x400000 \
        --start-address=0x400078 --stop-address=0x40009c "$aout" >"$dump" \
        || fail "objdump failed"
    grep -Eq '^[[:space:]]*400078:[[:space:]].*mov[[:space:]]+\$0x1,%eax$' "$dump" || fail "objdump mov eax"
    grep -Eq '^[[:space:]]*40007d:[[:space:]].*mov[[:space:]]+\$0x1,%edi$' "$dump" || fail "objdump mov edi"
    grep -Eq '^[[:space:]]*400082:[[:space:]].*movabs[[:space:]]+\$0x40009c,%rsi$' "$dump" || fail "objdump movabs rsi"
    grep -Eq '^[[:space:]]*40008c:[[:space:]].*mov[[:space:]]+\$0x1,%edx$' "$dump" || fail "objdump mov edx"
    grep -Eq '^[[:space:]]*400091:[[:space:]].*syscall$' "$dump" || fail "objdump write syscall"
    grep -Eq '^[[:space:]]*400093:[[:space:]].*mov[[:space:]]+\$0xe7,%eax$' "$dump" || fail "objdump mov eax exit_group"
    grep -Eq '^[[:space:]]*400098:[[:space:]].*xor[[:space:]]+%edi,%edi$' "$dump" || fail "objdump xor edi"
    grep -Eq '^[[:space:]]*40009a:[[:space:]].*syscall$' "$dump" || fail "objdump exit syscall"
}

for hex in 00 0a 41 80 ff; do
    aout="$tmp/a-$hex.out"
    actual="$tmp/out-$hex.bin"
    expected="$tmp/expected-$hex.bin"

    emit_aout "$hex" "$aout"
    chmod +x "$aout" || fail "chmod for param 0x$hex"
    if ! "$aout" >"$actual"; then
        fail "native execution for param 0x$hex"
    fi
    write_byte "$hex" >"$expected"
    if ! cmp -s "$expected" "$actual"; then
        echo "--- cmp -l expected actual"
        cmp -l "$expected" "$actual" || true
        fail "native stdout mismatch for param 0x$hex"
    fi
done

gate_aout="$tmp/a-41.out"
assert_readelf "$gate_aout"
assert_bytes "$gate_aout"
assert_objdump "$gate_aout"

echo "PASS: stack/native_elf_fragment.herb (native-codegen link1: 5-param differential; readelf/objdump white-box)"
