# Herbert maze

A small maze game written in Herbert. Collect all the pale dots to finish,
then restart and play again. The existing `first_steps.herb` example remains
available separately.

From the Herbert repository:

```bash
make maze
./build/maze
```

The default map is `examples/maze.txt`, relative to the current directory. To
open another map, pass its path:

```bash
./build/maze /full/path/to/my-maze.txt
```

Click the window to give it keyboard focus. Use **arrow keys or WASD** to move,
**R** to restart, and **Escape or the close button** to exit. Each move slides
to the next tile; releasing the key lets that tile finish. Moves stay cardinal,
so the character cannot cut diagonally through corners. Opposite directions
cancel on their axis; horizontal input takes priority when both axes are held.
Losing focus clears held keys, with an already-started tile move finishing.

The counter shows dots still to collect. A dot disappears only when the
character reaches its tile. When none remain, the completion panel appears and
movement stops until restart. R restores the original loaded map and counters;
it does not reload the file. Exit and open the program again to load an edit.
R and Escape use queued key presses, so quick taps between animation frames
are retained. Holding R may restart repeatedly if the desktop repeats that key.

## Editing a map

Use an ordinary plain text file with these exact characters:

| Character | Meaning |
| --- | --- |
| `#` | Wall |
| `.` | Dot on a walkable tile |
| Space | Empty walkable tile |
| `P` | The character's starting tile |

For example:

```text
#########
#P..#...#
#.#.#.#.#
#.......#
#########
```

Maps must have equal-length rows, be between 3 and 31 columns wide and between
3 and 19 rows tall, and have walls all around the outside. Include exactly one
`P` and at least one dot. Every dot must be reachable from `P` by horizontal or
vertical movement. Spaces count as cells; tabs, blank lines, comments and other
characters are errors. LF and CRLF line endings work, and the final newline is
optional. Files above 4096 bytes are rejected. Invalid maps print a reason in
the terminal, including a row and column when the error has a location, and
exit before opening a window.

## Implementation and limits

The program is compiled by Herbert's existing self-hosted native compiler. Its
Linux calls, X11 protocol client, lettering, map parser and game rules are our
Herbert source. Linux and the existing X11/XWayland desktop provide operating
system, window, drawing and device services. No foreign language runtime or
third-party graphics library is linked into this program. Build and test tools
are separate; the precise desktop boundary is described in `../lib/README.md`.

`lib/grid_map.herb` provides reusable checked tile-map parsing; the game itself
owns collision, dot collection, counters, restart and presentation. The window
is fixed at 800 by 640 pixels, with 24-pixel tiles. It uses the same desktop
support and limitations as First steps. There are no enemies, sound, mouse
controls, save games or general game engine in this example.

Drawing, movement and restarts reuse buffers allocated at startup. The loaded
map stays unchanged while a second tile buffer tracks collected dots. The
parser's bounded scratch storage remains allocated for this process's lifetime.
This avoids cumulative allocation during play; it does not add general memory
reclamation to Herbert. Updates aim for one frame every 16 milliseconds and
take eight frames per tile; movement slows if the host cannot maintain that
rate. The displayed step counter wraps after 999999.

## Tile-map support API

Concatenate `lib/linux.herb` and `lib/grid_map.herb` before a consumer. Call
`grid_map_parse(bytes, count, max_width, max_height)` once during loading;
`count` is the actual input byte count, and each dimension limit must be 3..255.
The returned tuple is:

```text
(status, width, height, spawn_index, dot_count, cells, error_row, error_column)
```

Status zero means success. `cells` contains exactly `width * height` row-major
ASCII bytes, without line endings; `spawn_index` identifies the `P` byte. Treat
these cells as the original map and copy them if an application needs mutations.
On failure, only status and error coordinates are meaningful. Coordinates are
one-based, or zero when there is no single offending location.
`grid_map_error(status)` returns the corresponding human-readable reason.

The parser validates structure before copying cells and uses a bounded queue
and visited buffer to check dot reachability. It deliberately permits empty
floor regions with no dots that cannot be reached; only collectible
reachability is required. This is a small ASCII tile-map format, not a general
map editor or serialization system.

Direction is sampled at each tile boundary, about every 128 ms during movement.
A direction pressed and released entirely during a committed tile move is not
buffered for the next turn. Hold the next direction through the boundary. Losing
focus or a desktop keyboard grab clears held movement; the current tile move
finishes, and movement resumes when you press a direction again.
