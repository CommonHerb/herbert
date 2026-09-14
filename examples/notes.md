# Herbert Notes

A small plain-text editor written in Herbert. It uses our Linux/X11 support
and bitmap lettering, with Linux and the desktop providing the host services.
The resulting program links no foreign language runtime or graphics library.

```sh
make notes
./build/notes my-notes.txt
```

Without a path it opens `notes.txt` in the current directory. A missing file
starts empty and is created only when you save. An existing file must contain
at most 65,536 bytes: printable ASCII, LF newlines and TAB. Unicode, CRLF,
other control bytes and larger files are refused before editing; their contents
are never silently converted or truncated.

Type to insert text. Arrows move the cursor; Home/End move within a line;
Ctrl+Home/End move to the beginning/end of the document. Page Up/Down move
20 lines. The view scrolls vertically and horizontally to follow the cursor.
Tabs advance to the next four-column stop. Backspace/Delete remove text.
Ctrl+S saves. Escape, Ctrl+Q or the window close button closes a clean document.
With unsaved changes, a visible prompt requires **Y** to discard; Escape
returns to editing and Ctrl+S saves. Holding a close key cannot confirm discard.

**Ctrl+Shift+S saves a rescue copy** in the same directory, named
`herbert-rescue-<process>-<number>.txt`. The footer shows the exact resulting
basename. This works even when another program changed the original and normal
save refuses to overwrite it. Existing rescue files are never overwritten.
The original document stays open with its dirty/conflict state unchanged;
the rescue does not silently switch which file Ctrl+S targets. After a confirmed
rescue, you can close the original, explicitly discard its in-memory edits, and
open the named rescue file. The command also works from the dirty-close prompt.
A rescue is private (0600) and uses the same write/sync/atomic-publication steps.
Failure before publication leaves no rescue file and retains your edits; a
directory-sync failure is reported as a published but unconfirmed copy.

The footer shows cursor position, byte count, unsaved state and save errors.
The buffer is fixed at 64 KiB, allocated on startup and reused through edits
and saves. At capacity, insertion stops with a message; deletion and saving
remain available. This is a deliberate bound, not general runtime reclamation.

Saving writes a new, exclusively created temporary file in the same directory,
syncs its contents and permissions, closes it, then atomically renames it over
the explicitly opened filename and syncs the directory. Pre-publication failure
leaves the previous file intact and retains your edits. A failure after rename
is reported separately as written but not durably confirmed. A missing target
is published with Linux's no-replace rename, so a file created by someone else
while you edit is not overwritten. Ordinary detected external edits are refused.

Final symlinks, directories, devices, FIFOs, multiply hardlinked files and files
owned by another account are refused. Existing ordinary permission bits are
preserved; a new file is private (0600). ACLs, extended attributes, ownership,
special permission bits and hardlink identity are not preserved by replacement.
Use this editor for ordinary notes that do not depend on that metadata.
Parent-directory symlinks are resolved once when opened; subsequent operations
use that opened directory. There is no multi-editor lock: another writer can
race the final conflict check and rename. A crash can leave an owned
`.herbert-save-*.tmp` file beside the document.

Current limits: fixed-size 900x600 window, ASCII keyboard layout support through
the desktop's first two keymap columns, no Unicode/compose/IME, clipboard,
selection, mouse editing, undo, search, general save-as dialog or multi-file tabs.
Open another file by launching another instance with its path. The visible path
is clipped after 130 bytes; the supplied full path is used for file operations.

Unsaved text exists only in this process. A crash, terminated process or lost/
stalled display connection can end the editor without saving it. There is no
autosave or recovery journal; save explicitly with Ctrl+S.

New documents and rescue copies require Linux no-replace rename support from
the filesystem. If it is unavailable, publication fails without overwriting
an existing name; the editor retains the text and reports the failure.
