#!/usr/bin/env python3
"""Replay every series entry in an isolated worktree and compare complete trees."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    archive = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=archive.parent.parent / 'linux')
    parser.add_argument('--method', choices=('apply', 'am'), default='apply')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    manifest = json.loads((archive / 'apply-manifest.json').read_text())
    series = (archive / 'series').read_text().splitlines()
    assert series == [row['patch'] for row in manifest['patches']]
    for row in manifest['patches']:
        assert hashlib.sha256((archive / row['patch']).read_bytes()).hexdigest() == row['sha256']
    env = os.environ.copy()
    for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES'):
        env.pop(key, None)
    env['GIT_CONFIG_NOSYSTEM'] = '1'
    env['GIT_CONFIG_GLOBAL'] = os.devnull
    env['GIT_TERMINAL_PROMPT'] = '0'

    def run(cwd, *command):
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True)
        if result.returncode:
            raise RuntimeError(f'{command!r} failed ({result.returncode}):\n'
                               + result.stdout.decode(errors='replace')
                               + result.stderr.decode(errors='replace'))
        return result.stdout

    def git(cwd, *command):
        return run(cwd, 'git', '-c', 'core.autocrlf=false', '-c', 'core.hooksPath=/dev/null',
                   '-c', 'commit.gpgsign=false', '-c', 'user.name=Platform Series Verification',
                   '-c', 'user.email=verification@localhost', *command)

    source_head = git(source, 'rev-parse', 'HEAD')
    source_status = git(source, 'status', '--porcelain=v1')
    objects = Path(git(source, 'rev-parse', '--path-format=absolute', '--git-path', 'objects').decode().strip())
    records = []
    with tempfile.TemporaryDirectory(prefix='sm8850-series-verification-') as temp:
        work = Path(temp) / 'linux'
        work.mkdir()
        git(work, 'init', '--quiet', '--template=')
        (work / '.git/objects/info/alternates').write_text(str(objects) + '\n')
        shallow = Path(git(source, 'rev-parse', '--path-format=absolute', '--git-path', 'shallow').decode().strip())
        if shallow.exists():
            (work / '.git/shallow').write_bytes(shallow.read_bytes())
        git(work, 'checkout', '--quiet', '--detach', manifest['base_commit'])
        assert git(work, 'write-tree').decode().strip() == manifest['base_tree']
        assert not git(work, 'status', '--porcelain=v1')
        for row in manifest['patches']:
            patch = str(archive / row['patch'])
            if args.method == 'apply':
                git(work, 'apply', '--check', '--index', patch)
                git(work, 'apply', '--index', '--whitespace=nowarn', patch)
            else:
                git(work, 'am', '--no-3way', '--whitespace=nowarn', patch)
            tree = git(work, 'write-tree').decode().strip()
            assert tree == row['expected_tree_after'], (row['number'], tree, row['expected_tree_after'])
            records.append({'number': row['number'], 'patch': row['patch'], 'result': 'passed', 'tree': tree})
            if row['number'] % 10 == 0 or row['number'] == len(series):
                print(f"{args.method}: {row['number']}/{len(series)} patches passed", flush=True)
        git(work, 'diff', '--exit-code')
        assert not git(work, 'ls-files', '--others', '--exclude-standard')
        git(work, 'diff', '--cached', '--exit-code', manifest['target_commit'], '--')
        git(work, 'diff', '--exit-code', manifest['target_commit'], '--')
        final_tree = git(work, 'write-tree').decode().strip()
        assert final_tree == manifest['target_tree']
        changed_files = git(work, 'diff', '--cached', '--name-only', manifest['target_commit'], '--').decode().splitlines()
        if args.method == 'am':
            assert not git(work, 'status', '--porcelain=v1')
            assert int(git(work, 'rev-list', '--count', manifest['base_commit'] + '..HEAD')) == len(series)
            assert git(work, 'rev-parse', 'HEAD^{tree}').decode().strip() == final_tree
    assert git(source, 'rev-parse', 'HEAD') == source_head
    assert git(source, 'status', '--porcelain=v1') == source_status
    report = {'method': args.method, 'base_commit': manifest['base_commit'],
              'target_commit': manifest['target_commit'], 'expected_tree': manifest['target_tree'],
              'actual_tree': final_tree, 'patch_count': len(series), 'patches_passed': len(records),
              'three_way_fallback': False, 'changed_files_vs_target': len(changed_files),
              'worktree_matches_index': True, 'source_head_index_worktree_unchanged': True,
              'patches': records}
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"PASS: {len(series)} patches, tree {final_tree}, 0 changed files versus target.", flush=True)


if __name__ == '__main__':
    main()
