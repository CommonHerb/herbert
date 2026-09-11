#!/usr/bin/env python3
"""Retain exact test outputs before a kernel gate deletes its temporary files.

Only used when KERNEL_EVIDENCE_DIR is set. Disk images/executables are omitted;
all other regular files are copied with a size/hash inventory. Never follow a
symlink or traverse a mount. Repeated attempts get distinct snapshot directories.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile


def capture(source, destination):
    source = Path(source).absolute()
    destination = Path(destination).resolve()
    if not source.exists():
        return
    if source.is_symlink() or not source.is_dir():
        raise ValueError(f'capture source is not a directory: {source}')
    source = source.resolve()
    if source == destination or source in destination.parents:
        raise ValueError('evidence directory must be outside captured tree')
    destination.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc)
    target = Path(tempfile.mkdtemp(prefix=started.strftime('capture-%Y%m%dT%H%M%S.%fZ-'), dir=destination))
    inventory = []
    for base, dirs, names in os.walk(source, followlinks=False):
        dirs[:] = [d for d in dirs if not (Path(base)/d).is_symlink()
                   and not os.path.ismount(Path(base)/d)]
        for name in sorted(names):
            p = Path(base)/name
            if not stat.S_ISREG(p.lstat().st_mode):
                continue
            # Artifacts remain identified in the inventory. Raw emulator files
            # have arbitrary names/extensions and must not be allowlisted away.
            rel = p.relative_to(source)
            omitted = p.suffix in {'.img', '.iso', '.elf', '.seed'} or name in {'a.out', 'gen1-herbert'}
            row = {'path': str(rel), 'size': p.stat().st_size, 'retained': not omitted}
            with p.open('rb') as source_file:
                row['sha256'] = hashlib.file_digest(source_file, 'sha256').hexdigest()
            if not omitted:
                out = target/rel; out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, out)
                with out.open('rb') as copied_file:
                    if hashlib.file_digest(copied_file, 'sha256').hexdigest() != row['sha256']:
                        raise OSError(f'capture changed while copying: {p}')
            inventory.append(row)
    (target/'INVENTORY.json').write_text(json.dumps({'source': str(source), 'gate': destination.name, 'started_utc': started.isoformat(), 'completed_utc': datetime.now(timezone.utc).isoformat(), 'files': inventory}, indent=2)+'\n')


if __name__ == '__main__':
    capture(sys.argv[1], sys.argv[2])
