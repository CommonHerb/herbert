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
at most 4,194,304 bytes (4 MiB) of valid UTF-8, TAB, and either LF or CRLF newlines.
The original UTF-8 bytes and newline style are preserved when saving, making
rescue copies and checkpointing recovery. Enter inserts a newline in that same
style. A file without newlines (including an empty document) uses LF. No trailing
newline is added and text is never normalized or silently replaced.
Malformed UTF-8, C0/DEL/C1 controls (except TAB and supported newlines), mixed
LF/CRLF endings, bare CR and larger files are refused before editing unchanged.

The original bitmap font displays ASCII, printable Latin-1 letters/symbols,
common typographic quotes, dashes, arrows and mathematical signs. Common Latin
combining accents display like their precomposed forms while keeping their
original bytes. A cluster the font cannot draw appears as one boxed marker;
`Boxed glyphs unavailable` appears in the footer when such a cluster is visible.
This includes unsupported scripts, complex emoji and unsupported accent
combinations. Their bytes remain intact. See [the Unicode guide](../docs/UNICODE.md)
for precise font and character-boundary scope.

Direct Latin-1 and Unicode keysyms from the first two desktop keymap columns
insert their characters. **Ctrl+Shift+U**, up to six hexadecimal digits, then
**Enter or Space** inserts a Unicode scalar (for example `e9` for é or `2014`
for an em dash). Backspace removes a hex digit; Escape cancels without editing.
This also works while searching. Compose/IME and full XKB layouts are not
implemented.

Type to insert text. Left/Right move across whole grapheme clusters; Home/End move within a line;
Ctrl+Home/End move to the beginning/end of the document. Page Up/Down move
20 lines. **Ctrl+G goes to a line:** type its number, then Enter (0 means the
first line; a number past the last line goes to the end of the text; Escape
cancels). The view scrolls vertically and horizontally to follow the cursor,
never past where Ctrl+End stops (the last line at the bottom).
**The scroll wheel** moves the view three lines a notch without moving the
cursor, down as far as Ctrl+End would show; the next key, or the next click in
the text, brings the view back to the cursor before it is handled (the click
lands on the line it was seen on).
Tabs advance to the next four-column stop. Backspace/Delete remove a whole grapheme cluster, so accents and joined emoji
are not split into broken fragments.
**Ctrl+Z undoes; Ctrl+Y or Ctrl+Shift+Z redoes.** History retains up to 256 edits and 8,388,608 bytes of inserted/deleted text in
fixed storage, enough for one replace of a whole document. Large edits can evict older complete history records sooner;
a replace is kept or evicted whole. Navigation is not an edit. A new edit after
undo drops the redo branch; the oldest edits fall off the bounded history.
History remains available after saving. Undo/redo conservatively marks the
document unsaved, even when it returns to the saved bytes.

**Selecting.** Shift with a movement key (arrows, Home/End, Page Up/Down,
Ctrl+Home/End) selects from where the selection started, and Ctrl+A selects
everything. The selection is highlighted. A movement key without Shift drops it,
Left and Right first going to its start or end, and the first Escape drops it
without closing Notes. Typing, Enter, Tab, Unicode entry and Ctrl+V replace the
selection; Backspace and Delete remove it. **Ctrl+X cuts, Ctrl+C copies and Ctrl+V
pastes**; a cut, a paste or a typed replacement is one undo step.

**The mouse.** A left click in the text places the cursor at the nearest
character boundary, dragging selects, and Shift+click extends the selection to
the click; a click that does not drag, or a drag that ends where it began,
selects nothing. Dragging above, below or
beside the text scrolls the view one row or column every 50 ms while the button
is held, so a selection can run past one screen. Opening the Open, Find or Go to
line field, Unicode entry or the close prompt (from Ctrl+Q, Escape or the
window's close button) ends a drag still held, so the cursor and view stay put
under it and after it. Clicks outside the text, and while the Open, Find or Go to line field,
Unicode entry or the close prompt is active, do nothing; so does the wheel
while one of those is up or a drag is held. Keys, clicks and wheel notches are
handled in the order they happened.

**The clipboard is the desktop's.** Ctrl+C and Ctrl+X offer the selection to other
applications, with LF newlines, and Ctrl+V pastes from whichever application
copied last. Pasted text follows the rules for opening a file: valid UTF-8, TAB
and LF or CRLF newlines in any mix, each newline then following the document's
own style when saved. Text with other control characters, a bare CR or invalid
UTF-8 is refused whole, as is text over 65,504 bytes or more than the document
has room for. A copy or cut of more than 65,536 bytes is refused, and the
selection stays. If no application offers text, or the one that does fails to
answer within two seconds, the footer says so and nothing changes. As with any
X11 application, copied text stays available while Notes is running; whether it
outlives Notes depends on the desktop. Ctrl+V also pastes into the Open and Find
fields when the text is one line without tabs that fits; one trailing newline
is dropped, and other text is refused whole.

**Ctrl+F searches** for up to 64 UTF-8 bytes, case-sensitive and byte-exact. Matches must start
and end on grapheme boundaries; canonically equivalent spellings are not
automatically equated.
Typing finds the first matching position at/after the cursor. Enter/F3 finds the
next match; Shift+Enter/Shift+F3 finds the previous match. Search wraps at both
ends and includes overlapping matches. Escape leaves search; F3/Shift+F3 then
repeat the last query. F3 without a previous query opens search. Pressed in the
document, F3 and Shift+F3 first drop any selection, as Ctrl+F does, whether or
not there is a query, so they never select. The cursor and scrolling show the match location, and
while Find is open the match is highlighted. It is not a selection: leaving Find leaves none. Search never changes the
document or undo history.

Ctrl+S saves. Escape, Ctrl+Q or the window close button closes a clean document.
With unsaved changes, a visible prompt requires **Y** to close without saving
the original. A confirmed recovery copy is kept; if recovery is incomplete,
the prompt explicitly warns that edits are being discarded. If a save of an
unedited document was unconfirmed, the prompt instead says that saving is
unconfirmed and no recovery copy exists. Escape returns to editing and
Ctrl+S saves (on a read-only file the prompt names Ctrl+Shift+S, which saves a
copy, instead). Holding a close key cannot confirm discard.

**A read-only file is not saved over.** A file whose owner write permission is
off (0444, 0400 or 0464, say) shows `read-only` beside Saved/UNSAVED in the
status line. Ctrl+S on it writes nothing and says so in the footer. While
`read-only` shows, the sentence shown after an edit, the close prompt and the
line below it (from the moment the prompt opens) name Ctrl+Shift+S, which still
saves a copy beside it, where they would say that Ctrl+S saves or retries;
Ctrl+O's refusal names the copy too, and says that Ctrl+O opens another file
only after Ctrl+S saves. The list of keys on the bottom line, shown when no
prompt is up, still lists Ctrl+S; on a read-only file Ctrl+S refuses as above.
There is no key to override this: to overwrite the file, make it writable and
press Ctrl+S again. A new file, not yet on disk, is never read-only.

Each Ctrl+S reads the file's status again (with one exception, below):
`read-only` follows the permission the file had when it opened until the next
Ctrl+S, and after that the one the last Ctrl+S found, also when that Ctrl+S
found something else wrong with the file (a second hard link, another owner, a
symbolic link, a folder or another kind of file put at its name); a Ctrl+S that
finds the file gone, or cannot read its status at all (its folder cannot be
searched, an input/output error), leaves the mark as it was. A Ctrl+S that finds
something wrong other than a change by another program (the file gone, a second
hard link, another owner, something other than an ordinary file at its name, a
status it could not read) writes nothing and gives that refusal's own sentence
(below), whether or not `read-only` shows. Otherwise, when the mark, as that
Ctrl+S leaves it, shows `read-only`, Ctrl+S refuses as read-only. A file made
read-only while it is open is refused at the next Ctrl+S like one that opened
read-only, and a save after a change of permission keeps the new permission. A
permission changed and changed back counts as a change by another program
(below), at every Ctrl+S until the file is given a different permission (which
is then taken, as above): Notes cannot tell it from another program's edit that
kept the file's size and put its modification time back, so it refuses both,
with the sentence that names permissions (or, while `read-only` shows, as
read-only). So does a permission changed together with the file's size,
modification time, group or identity on disk (another file put at its name),
again as read-only when the permission it found is read-only; a file given a
second hard link or another owner is refused as such files always are (below),
read-only or not.

The limit: another program's edit that keeps the file's size and modification
time and comes with a permission change is not seen. If another program rewrites
the file in place at the same size and puts its modification time back, or
changes only its extended attributes, and the permission changes too (before or
after that edit), the next Ctrl+S takes the new permission: if the owner may
write, that Ctrl+S saves over the other program's work; if not, it refuses as
read-only, and the first Ctrl+S after the file is made writable saves over it.

The exception: when a save was written but the check of the file just written
failed (the footer says "Written; sync/verification failed"; a failed sync alone
is not this case), the next Ctrl+S first checks the file against what that save
wrote and does not read the permission again. A permission changed meanwhile is
then refused as a change by another program, without `read-only`, at every
Ctrl+S until the file has the permission that save gave it again; then Ctrl+S
confirms that save and saves.

**A refused save says why** when the reason is one you can act on: another
program changed the file (or its permissions, as above) since it was opened,
there is no permission to write in its folder (or the file belongs to another
account), or the file was deleted or moved. While `read-only` shows (as that
Ctrl+S leaves the mark), a file deleted or moved, one that belongs to another
account and one whose folder cannot be searched are still said so; a change by
another program, and a folder that can be searched but not written in, are
refused as read-only instead (above). A new file whose folder was removed before
its first save keeps the general sentence and its error number, since it was
never on disk. A rescue refused for want of permission in the folder says so
too. Any other failure keeps the general sentence and its error number, a Ctrl+S
that could not read the file's status for a reason other than permission
included (an input/output error gives 5); none of these refusals replaces the
file. While the close prompt is pending, a refused save or rescue gives its
reason (in short; the general rescue failure's sentence is short already) and
keeps the instruction of the prompt that is up in that prompt's own words
(recovery kept, recovery incomplete so Y discards edits, or a save unconfirmed
with no recovery copy); the line below says the same, then what Ctrl+S does, or
on a read-only file that Ctrl+Shift+S saves a copy. Y and Escape work as before.

**Ctrl+O opens another file** in the same window. The Open field at the bottom
starts with the open document's folder as an absolute path; type a name or edit
the path, then press Enter. Escape cancels, Backspace removes one character and
Ctrl+Shift+U entry works here too. A relative path is resolved from the directory
Notes was started in. If the folder's name is not valid displayable UTF-8, the
field starts empty. A name that does not exist yet opens an empty document,
created when you save, exactly as at launch, and every launch refusal applies.
A refused path leaves the open document, its cursor, history and recovery session
unchanged, and the field stays open so the path can be corrected. With unsaved
changes Ctrl+O refuses and points to Ctrl+S and Ctrl+Shift+S (on a read-only
file, to Ctrl+Shift+S's copy and to the Ctrl+S that must save first): opening
never discards edits. The opened document starts with empty undo history, and its first
edit creates a new recovery session beside it; earlier session copies stay where
they are. Opening allocates nothing: Notes keeps one spare file context from
startup and swaps it with the open one.

**Ctrl+Shift+S saves a rescue copy** in the same directory, named
`herbert-rescue-<process>-<number>.txt`. The footer shows the exact resulting
basename. This works even when another program changed the original and normal
save refuses to overwrite it. Existing rescue files are never overwritten.
The original document stays open with its dirty/conflict state unchanged;
the rescue does not silently switch which file Ctrl+S targets. After a confirmed
rescue, you can close the original, explicitly discard its in-memory edits, and
open the named rescue file. The command also works from the dirty-close prompt. A published rescue leaves
Find and cancels pending hexadecimal entry so its sibling filename is visible;
the last search query remains available with F3.
A rescue is private (0600) and uses the same write/sync/atomic-publication steps.
Failure before publication leaves no rescue file and retains your edits; a
directory-sync failure is reported as a published but unconfirmed copy.

The footer shows cursor position, on-disk byte count, LF/CRLF style, unsaved
state, read-only and save errors. CRLF counts as two on-disk bytes, so inserting a newline
requires two free bytes in a CRLF document.
Text, serialization, grapheme boundaries and history use bounded buffers,
allocated on startup and reused through edits and saves. At capacity, insertion stops with a
message; deletion and saving remain available. This is a deliberate bound, not general runtime reclamation.

Saving writes a new, exclusively created temporary file in the same directory,
syncs its contents and permissions, closes it, then atomically renames it over
the explicitly opened filename and syncs the directory. Pre-publication failure
leaves the previous file intact and retains your edits. A failure after rename
is reported separately as written but not durably confirmed. A missing target
is published with Linux's no-replace rename, so a file created by someone else
while you edit is not overwritten. Ordinary detected external edits are refused.
A change of the file's permission alone, made while it is open, is not an edit:
the next Ctrl+S takes it as it is, together with any change the file's status
does not show; a permission changed and changed back, and one changed after a
save whose check failed, are refused instead (see read-only files above).

Final symlinks, directories, devices, FIFOs, multiply hardlinked files and files
owned by another account are refused. Existing ordinary permission bits, as
they are at the save, are preserved; a new file is private (0600). ACLs, extended attributes, ownership,
special permission bits and hardlink identity are not preserved by replacement.
Use this editor for ordinary notes that do not depend on that metadata.
Parent-directory symlinks are resolved once when opened; subsequent operations
use that opened directory. There is no multi-editor lock: another writer can
race the final conflict check and rename. A crash can leave an owned
`.herbert-save-*.tmp` file beside the document.

Current limits: fixed-size 900x600 window, limited font and keyboard coverage,
no compose/IME, primary selection (middle-click paste), double- or triple-click
selection, scroll bar, horizontal or Shift+wheel scrolling, drag-and-drop,
general save-as dialog, file browser or multi-file tabs. Ctrl+O replaces the open document; to edit two files at
once, launch another instance with the other path. The visible path is clipped
after 130 bytes and the Open field shows a path's last 130 characters; the full
path is used for file operations. Each edit still moves
the text after the cursor, in one block since the block copy, and writes the
whole recovery copy; on the development machine an insertion in the middle of
a 4 MiB document costs under a millisecond and its checkpoint a few. A line
many thousands of characters long is slower to draw.

**Session recovery is automatic after editing.** At the first edit, Notes creates
a private sibling directory named `.herbert-notes-<process>-<number>` (0700).
The window shows its relative path. Each completed input batch writes
`recovery.txt` (0600) there using a new exclusive temporary file, file sync,
atomic publication, and directory sync **before displaying the edited frame**.
The directory holding the session is also synced after the first checkpoint.
Existing session names are skipped, never reused. Editing allocates no new
history, search, or recovery buffers.

After an editor crash or display failure, open that snapshot explicitly:

```sh
./build/notes /path/to/.herbert-notes-12345-1/recovery.txt
```

It opens as a **separate document**. Saving it never automatically restores or
overwrites the original, which may have changed elsewhere. Compare the two and
choose what to keep. A newly edited recovery document gets its own session copy.

**Copies remain after successful save, normal exit, and deliberate discard.**
Remove the named session directory yourself when you no longer need it. There
is no cleanup timer or automatic deletion. Each edited session retains one
snapshot of at most 4 MiB; interrupted saves can also leave a temporary file.
These private files contain your text and continue to use disk space until you
remove them. Clean sessions create no copy.

A failed checkpoint leaves an amber recovery warning in the window; editing,
normal save and manual rescue remain available. A new edit or Ctrl+S retries. If directory creation succeeded but opening or
validating it failed, retries reuse that same candidate; they do not create
a fresh empty directory on every edit. A restrictive umask or filesystem that
cannot supply a private 0700 directory causes a visible recovery refusal.
Pre-publication failure retains the previous snapshot. A sync failure after
publication is explicitly uncertain. Do not rely on recovery while that warning
is present. External changes to the session file are refused using the same
conflict checks as ordinary saves. Directory operations use held descriptors;
renaming a containing directory can therefore leave the displayed path stale.
There is no protection against a malicious writer running as your own account.

Recovery covers completed, acknowledged input batches, not keystrokes still in
flight when a process dies. Close commands also attempt any pending checkpoint before confirmation or
exit. Synchronous checkpoint writes are bounded to 4 MiB, but the host
filesystem's sync latency is not bounded; slow storage can delay input/display.
This is session recovery, not a replacement for explicitly saving a document.
Idle Notes waits for input, expose, or the next 500 ms cursor blink instead of
presenting the window at 60 Hz.

New documents, rescue copies, and the first recovery checkpoint require Linux
no-replace rename support from the filesystem. If it is unavailable, publication fails without overwriting
an existing name; the editor retains the text and reports the failure.
