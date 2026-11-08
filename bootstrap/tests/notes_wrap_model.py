"""Notes' word wrap, written out again in Python from its rule (examples/notes.md, lib/text_buffer.herb), for the
checks to compare Herbert's answers with. It never reads Herbert's output.

A document is a list of grapheme clusters, each a bytes value, chosen by the checks so that their boundaries are known
without a segmentation of our own. A cluster is one column; a tab runs to the next four-column stop counted from the
row's start (from the line's start for the file's column). A line wider than `width` breaks after the last single-byte
space or tab that fits, the blank staying on the row; a row with no such blank breaks before the first cluster that does
not fit. A blank may start at the width and hang past it, and then ends the row, at a line's end too. An offset where a
line wraps belongs to the lower row; a line's end (its newline, or the text's end) to its last row.
"""
import bisect


def stop(column):
    return (column // 4 + 1) * 4


class Layout:
    def __init__(self, clusters, width):
        self.clusters = [bytes(c) for c in clusters]
        self.text = b''.join(self.clusters)
        self.width = width
        self.starts = []
        at = 0
        for c in self.clusters:
            self.starts.append(at)
            at += len(c)
        self.size = at
        self.at = {s: i for i, s in enumerate(self.starts)}
        self.rows = []          # (start, end, last), in order
        self.index = {}         # row start -> (its index in its line, its line's start, the file column at it)
        i = 0
        while True:
            line_start = self.starts[i] if i < len(self.clusters) else self.size
            k, column = 0, 0
            while True:
                r = self.starts[i] if i < len(self.clusters) else self.size
                self.index[r] = (k, line_start, column)
                end, last, i, column = self.row(i, column)
                self.rows.append((r, end, last))
                k += 1
                if last:
                    break
            if i >= len(self.clusters):
                break
            i += 1              # past the newline
        self.row_starts = [r for r, _, _ in self.rows]

    def offset(self, i):
        return self.starts[i] if i < len(self.clusters) else self.size

    def row(self, i, file):
        """The row from cluster i: (end offset, last, next row's first cluster, file column there)."""
        col, cut = 0, None
        while True:
            if i >= len(self.clusters) or self.clusters[i] == b'\n':
                return self.offset(i), True, i, file
            c = self.clusters[i]
            if c in (b' ', b'\t'):
                e, fe = (stop(col), stop(file)) if c == b'\t' else (col + 1, file + 1)
                if e > self.width:
                    return self.offset(i + 1), False, i + 1, fe
                cut, col, file = (i + 1, fe), e, fe
            else:
                if col >= self.width:
                    if cut is not None:
                        return self.offset(cut[0]), False, cut[0], cut[1]
                    return self.offset(i), False, i, file
                col, file = col + 1, file + 1
            i += 1

    def floor(self, p):
        p = min(p, self.size)
        if p == self.size:
            return p
        return self.starts[bisect.bisect_right(self.starts, p) - 1]

    def next(self, p):
        i = self.at[p]
        return self.offset(i + 1)

    def previous(self, p):
        if p == 0:
            return 0
        return self.floor(p - 1)

    def row_of(self, p):
        """(start, end, last) of the row holding p."""
        p = self.floor(p)
        k = bisect.bisect_right(self.row_starts, p) - 1
        while True:
            r, end, last = self.rows[k]
            if p < end or last:
                return self.rows[k]
            k += 1

    def start(self, p):
        return self.row_of(p)[0]

    def found(self, p):
        """What a lookup leaves: (row start, line number, index in line, line start, file column at the row start)."""
        r = self.start(p)
        k, line_start, column = self.index[r]
        return r, self.text[:line_start].count(b'\n'), k, line_start, column

    def columns(self, p, q, column):
        """The column at q, walking from p (a cluster start) at column, tabs from that column's stops."""
        while p < q:
            c = self.clusters[self.at[p]]
            column = stop(column) if c == b'\t' else column + 1
            p = self.next(p)
        return column

    def file(self, p):
        p = self.floor(p)
        r, line, _, _, column = self.found(p)
        return line, self.columns(r, p, column)

    def last(self, r):
        r, end, last = self.row_of(r)
        return end if last else self.previous(end)

    def position(self, r, column):
        """text_column_position from r (row-relative), then never past the row's last place."""
        p, col = r, 0
        while p < self.size:
            c = self.clusters[self.at[p]]
            if c == b'\n':
                break
            nxt = stop(col) if c == b'\t' else col + 1
            if nxt > column:
                break
            col, p = nxt, self.next(p)
        return min(p, self.last(r))

    def ahead(self, r, n):
        k = self.row_starts.index(self.start(r))
        moved = min(n, len(self.rows) - 1 - k)
        return self.rows[k + moved][0], moved

    def back(self, r, n):
        k = self.row_starts.index(self.start(r))
        return self.rows[max(0, k - n)][0]


def ascii_row_starts(text, width):
    """The row starts of ASCII text without tabs (a str), by the same rule, quickly enough for 4 MiB."""
    starts, x, n = [], 0, len(text)
    while True:
        starts.append(x)
        col, cut = 0, -1
        while True:
            if x >= n or text[x] == '\n':
                end, last = x, True
                break
            if text[x] == ' ':
                if col + 1 > width:
                    end, last = x + 1, False
                    break
                cut, col = x + 1, col + 1
            else:
                if col >= width:
                    end, last = (cut if cut != -1 else x), False
                    break
                col += 1
            x += 1
        if last:
            if end >= n:
                return starts
            x = end + 1
        else:
            x = end
