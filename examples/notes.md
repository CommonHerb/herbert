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
**Ctrl+Z undoes; Ctrl+Y or Ctrl+Shift+Z redoes.** The last 256 individual byte
edits are retained in fixed storage. Navigation is not an edit. A new edit after
undo drops the redo branch; the oldest edits fall off the bounded history.
History remains available after saving. Undo/redo conservatively marks the
document unsaved, even when it returns to the saved bytes.

**Ctrl+F searches** for up to 64 printable ASCII characters, case-sensitive.
Typing finds the first matching position at/after the cursor. Enter/F3 finds the
next match; Shift+Enter/Shift+F3 finds the previous match. Search wraps at both
ends and includes overlapping matches. Escape leaves search; F3/Shift+F3 then
repeat the last query. F3 without a previous query opens search. The cursor and scrolling show the match location; there
is no selection highlight. Search never changes the document or undo history.

Ctrl+S saves. Escape, Ctrl+Q or the window close button closes a clean document.
With unsaved changes, a visible prompt requires **Y** to close without saving
the original. A confirmed recovery copy is kept; if recovery is incomplete,
the prompt explicitly warns that edits are being discarded. If a save of an
unedited document was unconfirmed, the prompt instead says that saving is
unconfirmed and no recovery copy exists. Escape returns to editing and
Ctrl+S saves. Holding a close key cannot confirm discard.

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
selection, mouse editing, general save-as dialog or multi-file tabs.
Open another file by launching another instance with its path. The visible path
is clipped after 130 bytes; the supplied full path is used for file operations.

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
snapshot of at most 64 KiB; interrupted saves can also leave a temporary file.
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
exit. Synchronous checkpoint writes are bounded to 64 KiB, but the host
filesystem's sync latency is not bounded; slow storage can delay input/display.
This is session recovery, not a replacement for explicitly saving a document.
Idle Notes waits for input, expose, or the next 500 ms cursor blink instead of
presenting the window at 60 Hz.

New documents, rescue copies, and the first recovery checkpoint require Linux
no-replace rename support from the filesystem. If it is unavailable, publication fails without overwriting
an existing name; the editor retains the text and reports the failure.
