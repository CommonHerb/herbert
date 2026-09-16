#!/usr/bin/env python3
"""Exercise the Makefile developer build with real seed artifacts and bad envelopes."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
GOOD = b'func main():\n    return 42\nend\n'
OLD = b'previous complete program\x00\xff\n'


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    evidence = Path(tempfile.mkdtemp(prefix='herbert-program-build-'))
    print(f'program-contract evidence: {evidence}', flush=True)
    repo = evidence/'workspace with spaces'; repo.mkdir()
    for directory in ('bootstrap/seed', 'lib'):
        shutil.copytree(ROOT/directory, repo/directory)
    shutil.copyfile(ROOT/'Makefile', repo/'Makefile')
    shutil.copyfile(ROOT/'.gitignore', repo/'.gitignore')
    (repo/'tracked.txt').write_bytes(b'tracked project work\n')
    metadata = evidence/'separate git directory'
    subprocess.run(['git', 'init', '-q', '--separate-git-dir', str(metadata), str(repo)], check=True)
    subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
    seed = evidence/'real-seed'; shutil.copyfile(ROOT/'bootstrap/seed/gen1.seed', seed); seed.chmod(0o700)
    source = evidence/'source with spaces.herb'; source.write_bytes(GOOD)
    output = repo/'build directory'/'my program'; output.parent.mkdir()
    output.write_bytes(OLD)
    rows = []

    def build(name, *, support='', target=output, code=None, env=None):
        if code is not None:
            source.write_bytes(code)
        log = evidence/name; log.mkdir()
        args = ['make', '--no-print-directory', 'program', f'SOURCE={source}', f'SUPPORT={support}']
        if target is not None:
            args.append(f'OUTPUT={target}')
        result = subprocess.run(args, cwd=repo, capture_output=True, timeout=45, env=env)
        (log/'stdout').write_bytes(result.stdout); (log/'stderr').write_bytes(result.stderr)
        (log/'status').write_text(f'{result.returncode}\n')
        captures = [line.removeprefix(b'program build evidence: ').decode()
                    for line in result.stderr.splitlines() if line.startswith(b'program build evidence: ')]
        work = Path(captures[-1]) if captures else None
        rows.append({'case': name, 'status': result.returncode, 'work': str(work) if work else None})
        print(f'program-contract observed {name}: status={result.returncode}', flush=True)
        return result, work

    def preserved(result, target=output, expected=OLD):
        require(result.returncode != 0, 'bad build unexpectedly passed')
        require(target.read_bytes() == expected, 'failed build changed previous output')

    def corrupt_seed(body):
        compiler = repo/'bootstrap/seed/gen1.seed'
        compiler.write_text('#!/bin/sh\n'+body)
        checksum = hashlib.sha256(compiler.read_bytes()).hexdigest()
        (repo/'bootstrap/seed/gen1.seed.sha256').write_text(checksum+'  gen1.seed\n')

    def restore_seed():
        for name in ('gen1.seed', 'gen1.seed.sha256'):
            shutil.copyfile(ROOT/'bootstrap/seed'/name, repo/'bootstrap/seed'/name)

    try:
        result, work = build('clean-paths-with-spaces')
        require(result.returncode == 0, result.stderr.decode())
        require(subprocess.check_output([str(output)], timeout=5) == b'42\n', 'built image did not run')
        require((work/'a.out').read_bytes() == output.read_bytes(), 'retained image differs')
        require((work/'compiler.status').read_text() == '0\n', 'wrong success status capture')
        require((work/'compiler.stdout').read_bytes() == b'0\n', 'wrong success stdout capture')
        require((work/'compiler.stderr').read_bytes() == b'', 'wrong success stderr capture')
        require(work.stat().st_dev == output.parent.stat().st_dev, 'publication crosses filesystems')
        require(not (work/'publish').exists(), 'publication copy was not renamed')
        ignored = subprocess.run(['git', '-C', str(repo), 'check-ignore', '-q', str(work)])
        require(ignored.returncode == 0, 'retained compiler evidence is not Git-ignored')

        original_source = source
        source = evidence/'$(shell printf expanded > SOURCE_EXPANDED).herb'
        source.write_bytes(GOOD)
        literal_output = output.parent/'$(shell printf expanded > OUTPUT_EXPANDED)'
        result, _ = build('literal-make-expressions-in-paths', target=literal_output)
        require(result.returncode == 0, result.stderr.decode())
        require(subprocess.check_output([str(literal_output)], timeout=5) == b'42\n', 'literal path did not publish')
        require(not (repo/'SOURCE_EXPANDED').exists() and not (repo/'OUTPUT_EXPANDED').exists(),
                'filename was evaluated as a Make expression')
        source = original_source
        output.write_bytes(OLD)
        result, _ = build('literal-support-reject', support='$(shell printf expanded > SUPPORT_EXPANDED)')
        preserved(result)
        require(not (repo/'SUPPORT_EXPANDED').exists(), 'support value was evaluated as a Make expression')
        require(b'program: unknown support alias:' in result.stderr, 'wrong literal support rejection reason')

        env = dict(os.environ); env.pop('OUTPUT', None)
        result, _ = build('default-output', target=None, env=env)
        require(result.returncode == 0, result.stderr.decode())
        require(subprocess.check_output([str(repo/'build/program')], timeout=5) == b'42\n', 'default output missing')

        output.write_bytes(OLD)
        library = repo/'lib/linux.herb'
        original_library = library.read_bytes()
        library.write_bytes(original_library.rstrip(b'\n')+b'\n-- comment without final newline')
        result, work = build('support-missing-final-newline', support='linux',
                             code=b'func main():\n    return linux_error(0)\nend')
        require(result.returncode == 0, result.stderr.decode())
        require(subprocess.check_output([str(output)], timeout=5) == b'false\n', 'source swallowed by support comment')
        source_map = (work/'source-map.tsv').read_text().splitlines()
        require(len(source_map) == 3, 'support/source/EOF ranges missing')
        first, last, original_first, _ = source_map[0].split('\t')
        require((int(first), int(last)) == (1, library.read_bytes().count(b'\n')+1), 'support map disagrees with inserted bytes')

        output.write_bytes(OLD)
        result, work = build('mapped-source-rejection', support='linux',
                             code=b'func main():\n    return $\nend')
        preserved(result)
        require((str(source)+':2: unexpected character (ERR 101)').encode() in result.stderr,
                'located user error not mapped to the original file/line')
        require((work/'compiler.status').read_text() == '1\n', 'checked rejection status lost')
        require((work/'compiler.stdout').read_bytes() == b'', 'checked rejection stdout changed')
        require((work/'compiler.stderr').read_bytes().startswith(b'line '), 'raw diagnostic was not preserved')
        require(not (work/'a.out').exists(), 'reject unexpectedly emitted an image')

        for label, code, line in [('newline', b'func main():\n    return 42\n', 3),
                                  ('no-newline', b'func main():\n    return 42', 2)]:
            result, _ = build('mapped-end-of-file-'+label, support='linux', code=code)
            preserved(result)
            require((str(source)+f':{line}: expected end (ERR 203)').encode() in result.stderr,
                    'EOF rejection not mapped to original EOF line')

        library.write_bytes(b'func broken():\n    return $\nend\n')
        result, _ = build('mapped-library-rejection', support='linux', code=GOOD)
        preserved(result)
        require((str(library)+':2: unexpected character (ERR 101)').encode() in result.stderr,
                'located support error not mapped')
        library.write_bytes(original_library)

        result, _ = build('multiple-support-units', support='linux text_buffer',
                          code=b'func main():\n    return text_length(text_buffer(8))\nend\n')
        require(result.returncode == 0, result.stderr.decode())
        require(subprocess.check_output([str(output)], timeout=5) == b'0\n', 'multiple libraries did not compose')
        output.write_bytes(OLD)
        result, work = build('mapped-source-after-multiple-units', support='linux text_buffer',
                             code=b'func main():\n    return $\nend\n')
        preserved(result)
        require((str(source)+':2: unexpected character (ERR 101)').encode() in result.stderr,
                'source error after multiple libraries was not mapped')
        raw_line = original_library.count(b'\n')+(repo/'lib/text_buffer.herb').read_bytes().count(b'\n')+2
        require((work/'compiler.stderr').read_bytes().startswith(f'line {raw_line}:'.encode()),
                'multi-unit raw line was not independently predicted')
        source.write_bytes(GOOD)

        for label, support in [('unknown-alias', 'does_not_exist'), ('alias-path-traversal', '../linux'),
                               ('alias-shell-metacharacter', 'linux;echo')]:
            result, _ = build(label, support=support)
            preserved(result)
            require(b'program: unknown support alias:' in result.stderr, 'wrong alias rejection reason')

        protected = [('source', source, b'output would replace the source'),
                     ('seed', repo/'bootstrap/seed/gen1.seed', b'output would replace the seed'),
                     ('tracked', repo/'tracked.txt', b'output would replace a tracked project file'),
                     ('metadata', metadata/'config', b'output would replace repository metadata'),
                     ('git-pointer', repo/'.git', b'output would replace repository metadata')]
        for label, target, reason in protected:
            original = target.read_bytes()
            result, _ = build('protect-'+label, target=target)
            preserved(result, target, original)
            require(b'program: '+reason in result.stderr, 'wrong protected-output rejection reason')

        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Program contract fixture',
                        '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
                        '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Owned test fixture'], check=True)
        linked = evidence/'linked workspace'
        subprocess.run(['git', '-C', str(repo), '-c', 'core.hooksPath=/dev/null',
                        'worktree', 'add', '-q', '--detach', str(linked)], check=True)
        primary_repo = repo; repo = linked
        linked_git = Path(subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--absolute-git-dir'], text=True).strip())
        require(linked_git != metadata, 'fixture did not separate Git directory from common directory')
        for label, target in [('common', metadata/'config'), ('own', linked_git/'index')]:
            original = target.read_bytes()
            result, work = build('protect-linked-git-'+label, target=target)
            preserved(result, target, original)
            require(work is None and b'program: output would replace repository metadata' in result.stderr,
                    'linked-worktree metadata guard did not fire')
        repo = primary_repo

        unsupported_repo = evidence/'unsupported metadata checkout'
        subprocess.run(['git', 'init', '-q', '--separate-git-dir', str(evidence/'Git metadata\n'),
                        str(unsupported_repo)], check=True)
        metadata_alias = evidence/'metadata directory alias'; metadata_alias.symlink_to(evidence/'Git metadata\n')
        (unsupported_repo/'.git').write_text('gitdir: '+str(metadata_alias)+'\n')
        # A normal pointer name lets Git reach the unsupported canonical name.
        subprocess.run(['git', '-C', str(unsupported_repo), 'rev-parse', '--git-dir'],
                       stdout=subprocess.DEVNULL, check=True)
        shutil.copyfile(repo/'Makefile', unsupported_repo/'Makefile')
        repo = unsupported_repo
        result, work = build('reject-canonical-git-metadata-newline')
        preserved(result)
        require(work is None and b'program: paths containing tabs/newlines are unsupported' in result.stderr,
                'unsupported Git metadata path was truncated or accepted')
        repo = primary_repo

        alias = evidence/'source-alias'; os.link(source, alias)
        result, _ = build('protect-source-hardlink', target=alias)
        preserved(result, alias, GOOD)
        require(b'program: output would replace the source' in result.stderr, 'source alias protection did not fire')
        symlink = evidence/'output-symlink'; symlink.symlink_to(source)
        result, _ = build('protect-output-symlink', target=symlink)
        preserved(result, symlink, GOOD)
        require(symlink.is_symlink(), 'output symlink replaced')

        seed_alias = evidence/'seed-alias'; os.link(repo/'bootstrap/seed/gen1.seed', seed_alias)
        result, _ = build('protect-seed-hardlink', target=seed_alias)
        preserved(result, seed_alias, seed.read_bytes())
        require(b'program: output would replace the seed' in result.stderr, 'seed alias protection did not fire')
        directory = evidence/'directory-output'; directory.mkdir()
        (directory/'sentinel').write_bytes(OLD)
        result, work = build('protect-directory', target=directory)
        require(result.returncode != 0 and work is None, 'directory output reached compilation')
        require(directory.is_dir() and (directory/'sentinel').read_bytes() == OLD, 'destination directory changed')
        require(b'program: output must not be a symlink or directory' in result.stderr, 'directory guard did not fire')

        for label, target in [('newline', str(output)+'\n'), ('tab', str(output)+'\t')]:
            result, _ = build('reject-output-'+label, target=target)
            preserved(result)
            require(not Path(target).exists(), 'unsupported path was created')
            require(b'program: paths containing tabs/newlines are unsupported' in result.stderr, 'recipe did not reject the path')

        original_source = source
        alternate = evidence/'canonical-source.herb'; alternate.write_bytes(GOOD)
        newline_source = evidence/'canonical-source.herb\n'
        newline_source.write_bytes(b'func main():\n    return 88\nend\n')
        source = evidence/'canonical-source-alias'; source.symlink_to(newline_source)
        result, work = build('reject-canonical-source-newline')
        preserved(result)
        require(work is None and b'program: paths containing tabs/newlines are unsupported' in result.stderr,
                'canonical source path was truncated or compiled')
        source = original_source
        newline_parent = evidence/'canonical-output-directory\n'; newline_parent.mkdir()
        output_parent_alias = evidence/'canonical-output-parent-alias'; output_parent_alias.symlink_to(newline_parent)
        canonical_output = newline_parent/'program'; canonical_output.write_bytes(OLD)
        result, work = build('reject-canonical-output-newline', target=output_parent_alias/'program')
        preserved(result, canonical_output)
        require(work is None and b'program: paths containing tabs/newlines are unsupported' in result.stderr,
                'canonical output path was accepted')

        wip = repo/'lib/_program_wip.herb'; wip.write_bytes(b'func program_wip():\n    return 73\nend\n')
        wip_alias = evidence/'untracked-support-alias'; os.link(wip, wip_alias)
        for label, target in [('file', wip), ('hardlink', wip_alias)]:
            result, work = build('protect-untracked-support-'+label, support='_program_wip', target=target,
                                 code=b'func main():\n    return program_wip()\nend\n')
            preserved(result, target, b'func program_wip():\n    return 73\nend\n')
            require(work is None and b'program: output would replace an input source' in result.stderr,
                    'untracked support source reached compilation')
        source.write_bytes(GOOD)

        compiler_call = shlex.quote(str(seed))+'\nrc=$?\n[ "$rc" -eq 0 ] || exit "$rc"\n'
        for label, corruption in [('status', 'exit 7\n'), ('stdout', "printf 'unexpected\\n'\n"),
                                  ('stderr', "printf 'unexpected\\n' >&2\n")]:
            corrupt_seed(compiler_call+corruption)
            result, work = build('bad-compiler-'+label)
            preserved(result)
            require((work/'a.out').read_bytes().startswith(b'\x7fELF'), 'fault must follow a real successful emission')
            require((work/'compiler.status').read_text() == ('7\n' if label == 'status' else '0\n'), 'wrong failure receipt')
        corrupt_seed("printf '0\\n'\n")
        result, work = build('success-without-image')
        preserved(result)
        require((work/'compiler.status').read_text() == '0\n', 'missing-image fixture did not succeed')
        require(not (work/'a.out').exists(), 'missing-image fixture unexpectedly emitted')
        corrupt_seed("printf 'herbert: line 2: internal compiler fault\\n' >&2\nexit 1\n")
        result, work = build('internal-fault-is-not-source-location')
        preserved(result)
        require(b'herbert: line 2: internal compiler fault\n' in result.stderr, 'internal diagnostic was rewritten')
        require((str(source)+':2:').encode() not in result.stderr, 'internal fault mislabeled as source error')
        restore_seed()

        compiler = repo/'bootstrap/seed/gen1.seed'
        compiler.write_bytes(compiler.read_bytes()+b'checksum-drift')
        result, work = build('seed-checksum-mismatch')
        preserved(result)
        require(not (work/'compiler.status').exists(), 'unverified compiler was invoked')
        restore_seed()

        commands = evidence/'publication-fault-bin'; commands.mkdir()
        move = commands/'mv'; move.write_text('#!/bin/sh\nexit 7\n'); move.chmod(0o755)
        env = dict(os.environ, PATH=str(commands)+os.pathsep+os.environ['PATH'])
        result, work = build('publication-command-failure', env=env)
        preserved(result)
        require((work/'compiler.status').read_text() == '0\n', 'failure must occur after successful compilation')
        require((work/'publish').read_bytes() == (work/'a.out').read_bytes(), 'pending publication or retained image lost')

        result, _ = build('final-clean-after-faults', code=GOOD)
        require(result.returncode == 0, result.stderr.decode())
        require(subprocess.check_output([str(output)], timeout=5) == b'42\n', 'restored real compiler did not build')
    except BaseException as error:
        (evidence/'result.json').write_text(json.dumps({'status': 'FAIL', 'error': str(error), 'cases': rows}, indent=2)+'\n')
        raise
    (evidence/'result.json').write_text(json.dumps({'status': 'PASS', 'cases': rows}, indent=2)+'\n')
    print(f'program-contract: {len(rows)} checks passed; retained evidence {evidence}')


if __name__ == '__main__':
    main()
