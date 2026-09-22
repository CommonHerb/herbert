# UTF-8 text support

The language's strings and buffers retain their byte-addressed semantics.
These Herbert libraries add explicit decoding, grapheme boundaries and bounded
editing for applications. They do not change the compiler or introduce a foreign
runtime, graphics library, font service or network dependency into emitted programs.

## Encoding and editing

`utf8.herb` implements strict [RFC 3629](https://www.rfc-editor.org/rfc/rfc3629):
valid Unicode scalar values, shortest encoding, no surrogates, and no replacement
decoding. `utf8_decode(bytes, offset, limit)` returns `(scalar, next_offset)`;
an invalid sequence returns `(-EILSEQ, original_offset)`. `utf8_width(scalar)`
returns 1–4 or zero for an invalid scalar. `utf8_store` validates scalar and space
before writing anything; success returns the next offset, failure `-EILSEQ` or
`-EFBIG`. It never allocates.

`utf8_text_allowed` is a separate prose policy: allow TAB/LF and scalar values
outside C0/DEL/C1. Notes additionally accepts uniform CRLF, rejects bare CR and
mixed LF/CRLF, and retains the original style. Format characters, a byte order
mark and noncharacters are retained exactly; unsupported visible forms receive
the font's explicit marker. No normalization, character substitution, byte order
mark or trailing newline is introduced.

`unicode_grapheme.herb` implements default extended grapheme boundaries from
[Unicode 18.0.0, UAX #29 revision49](https://www.unicode.org/reports/tr29/tr29-49.html).
This includes its changed Indic-conjunct rule GB9c, not the older Unicode17 rule.
Grapheme grouping does not promise full script shaping or bidirectional layout.
The library handles controls independently of Notes' narrower prose policy.

`text_buffer` caches boundaries after loads and edits. Positions remain logical
UTF-8 byte offsets. `text_seek` rounds down; `text_next`/`text_previous` move to
adjacent boundaries. Left/Right and deletion treat extended grapheme clusters as
units. Insertion accepts a scalar, and moves to the first boundary at or after
its encoded bytes; insertion can join neighboring clusters. Undo/redo restores
recorded byte spans and cursor positions, including an inserted combining mark
that joined a pre-existing letter.

Each grapheme uses one display column; TAB uses four-column stops. Whole-file
serialization preserves LF/CRLF with a disk-byte capacity bound. Byte-exact,
case-sensitive search requires start and end grapheme boundaries; canonically
equivalent encodings are not implicitly equated. Raw `unicode_grapheme_next` and
`unicode_grapheme_previous` scan from the start to preserve context and are meant
for short inputs such as the 64-byte search query. Use the cached text APIs for
document traversal.

All text, serialization, boundary and history storage is allocated at
construction. History holds up to 256 records and `capacity` inserted/deleted
payload bytes. It evicts complete oldest records to fit; one deletion can hold a
cluster as long as the entire document. No partial cluster is saved in history. A capacity-sized deletion consumes the
whole payload budget and the next accepted edit evicts that deletion record.
New successful edits discard redo, while rejected edits leave it intact. This is
bounded application storage, not general heap reclamation.

## Display and input

`unicode_display.herb` contains original bitmap artwork authored for Herbert.
It preserves the existing ASCII UI renderer and adds 12-by-20-pixel document
cells at scale2. Supported glyphs are printable ASCII, printable Latin-1 excluding
U+00AD, typographic quotes U+2018/U+2019/U+201A/U+201C/U+201D/U+201E, en/em dashes U+2013/U+2014, bullet U+2022,
ellipsis U+2026, euro U+20AC, arrows U+2190–2194, minus U+2212 and comparisons
U+2260/U+2264/U+2265. Exact individual support is checked by
`unicode_display_supported`; ranges here are limited to the named glyphs in
source, not a claim of general block coverage.

The combining marks U+0300, U+0301, U+0302, U+0303, U+0308, U+030A and U+0327
can accompany a Latin ASCII letter: at most one above mark and one cedilla below.
Ring plus cedilla does not fit and is unsupported. Latin-1 precomposed accents
share the decomposed rendering while their original UTF-8 bytes remain distinct.
The document/query font distinguishes a three-pixel hyphen, four-pixel en dash
and five-pixel em dash; the older ASCII UI font retains its own five-pixel hyphen.
SPACE and NBSP deliberately share blank ink. Unsupported clusters are one boxed
marker; Notes labels that limitation when such glyphs are visible. Complex-script
shaping, bidirectional layout and full emoji artwork remain unsupported.

The X11 helper maps Latin-1 and direct Unicode keysyms from its existing two-column
core keymap. Notes also supports Ctrl+Shift+U hexadecimal scalar entry. Legacy
script-specific keysyms, compose/IME and full XKB translation are not implemented.

## Data, provenance and regeneration

Unicode property data and the segmentation test oracle are external standardized
data, distributed under the [retained Unicode license](UNICODE-LICENSE.txt).
The decoder, segmentation algorithm, editor and renderer are Herbert source.
`unicode_tables.herb` is a mechanical merge of the three property files below,
with exact arithmetic for Hangul syllables. Its compact hexadecimal range format
and property bits are documented in its source header.

`tools/generate_unicode_tables.py` is explicitly allowlisted development tooling.
It checks the pinned source hashes and performs no downloads. Place the three
property files and LICENSE.txt together, then run:

```sh
python3 tools/generate_unicode_tables.py --source-dir /path/to/unicode18 --check
```

Omit `--check` to regenerate the asset after deliberate review of any pin changes.
Normal builds and verification need neither this source directory nor a network.
The checked-in `GraphemeBreakTest.txt` is the independent boundary oracle consumed
by `check_utf8_text.py`. The same test checks the generated table against its reviewed SHA256 before
compilation. That is an asset-integrity regression pin, not a fresh derivation
from upstream properties. The generator checks the three property files and
license; the test checks the boundary fixture separately. Original property
inputs and exact generation receipts are retained in the dated implementation
evidence. The permanent font checks exercise declared scalar support and literal
accent, symbol, fallback and scaled pixel geometry without an X server.

| Input | SHA256 |
| --- | --- |
| [GraphemeBreakProperty.txt](https://www.unicode.org/Public/18.0.0/ucd/auxiliary/GraphemeBreakProperty.txt) | `0839dcb79e4ac639ecd538b1abf7c9d22e3f9dd265b7e182d33627aa4d75b45a` |
| [emoji-data.txt](https://www.unicode.org/Public/18.0.0/ucd/emoji/emoji-data.txt) | `80d00f8e616a0ef27fd6b8de3b758c06383b5d917e2977709578e68baf733bf1` |
| [DerivedCoreProperties.txt](https://www.unicode.org/Public/18.0.0/ucd/DerivedCoreProperties.txt) | `09c928886a178fcafd93c29e4bd59073a058e5a100b716d425cb563ab50f68c9` |
| [GraphemeBreakTest.txt](https://www.unicode.org/Public/18.0.0/ucd/auxiliary/GraphemeBreakTest.txt) | `b0cf047ee94485bbdc846de2b902f5f8a815f6b674f9d04223cddadd91c9df31` |
| [LICENSE.txt](https://www.unicode.org/license.txt) | `e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96` |
