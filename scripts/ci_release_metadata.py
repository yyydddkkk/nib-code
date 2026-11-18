"""Recognize only a package version edit and its matching release note."""
import argparse
import re
import subprocess
import sys

MANIFEST = b'build.zig.zon'
VERSION_FIELD = re.compile(rb'^    \.version = "([^"\r\n]*)",$', re.MULTILINE)
STABLE_VERSION = rb'(?:0|[1-9][0-9]*)' + rb'\.(?:0|[1-9][0-9]*)' * 2
NOTE_PATH = re.compile(rb'docs/releases/[^/]+\.md')


class InvalidMetadata(ValueError):
    pass


def git(*args):
    return subprocess.check_output(['git', '--no-replace-objects', *args])


def regular_file(commit, path):
    entry = git('ls-tree', commit, '--', path)
    if not entry.startswith(b'100644 blob '):
        return None
    return git('cat-file', 'blob', entry.split()[2])


def validate_note(data, version):
    try:
        lines = data.decode('utf-8').splitlines()
    except UnicodeDecodeError as error:
        raise InvalidMetadata('release note must be UTF-8') from error
    separators = [i for i, line in enumerate(lines) if line == '---']
    if len(separators) != 1:
        raise InvalidMetadata('release note needs English and Chinese sections separated by ---')
    split = separators[0]
    for section, title in ((lines[:split], f'# nib {version}'),
                           (lines[split + 1:], f'# nib {version}（中文）')):
        content = '\n'.join(section).strip().split('\n', 1)
        if content[0] != title or len(content) != 2 or not content[1].strip():
            raise InvalidMetadata(f'release note needs heading {title!r} and a nonempty body')


def metadata_only(base, head):
    changes = set(git('diff', '--name-only', '-z', '--no-renames', '--ignore-submodules=none',
                      base, head, '--').split(b'\0')) - {b''}
    notes = changes - {MANIFEST}
    if MANIFEST not in changes or len(notes) > 1 or any(not NOTE_PATH.fullmatch(p) for p in notes):
        return False

    before, after = (regular_file(commit, MANIFEST) for commit in (base, head))
    if before is None or after is None:
        return False
    old, new = (VERSION_FIELD.findall(data) for data in (before, after))
    if len(old) != 1 or len(new) != 1 or old == new:
        return False
    if VERSION_FIELD.sub(b'', before) != VERSION_FIELD.sub(b'', after):
        return False
    if not re.fullmatch(STABLE_VERSION, new[0]):
        raise InvalidMetadata('package version must be a stable X.Y.Z version without leading zeros')

    path = b'docs/releases/' + new[0] + b'.md'
    if notes != {path}:
        raise InvalidMetadata(f'expected a change to {path.decode()} for the new version')
    previous_note = git('ls-tree', base, '--', path)
    if previous_note and not previous_note.startswith(b'100644 blob '):
        return False
    note = regular_file(head, path)
    if note is None:
        raise InvalidMetadata(f'{path.decode()} must be a regular, non-executable release note')
    validate_note(note, new[0].decode())
    return True


def pr_metadata_only(base, head, merge):
    # Check both the authored PR diff and the integration diff actually tested by CI.
    if git('rev-list', '--parents', '-n', '1', merge).decode().split() != [merge, base, head]:
        return False
    bases = git('merge-base', '--all', base, head).decode().split()
    return len(bases) == 1 and metadata_only(bases[0], head) and metadata_only(base, merge)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base')
    parser.add_argument('head')
    parser.add_argument('merge', nargs='?', help='PR merge commit checked out by CI')
    args = parser.parse_args()
    try:
        base, head = (git('rev-parse', '--verify', '--end-of-options', rev + '^{commit}').decode().strip()
                      for rev in (args.base, args.head))
        if args.merge:
            merge = git('rev-parse', '--verify', '--end-of-options', args.merge + '^{commit}').decode().strip()
            metadata = pr_metadata_only(base, head, merge)
        else:
            metadata = metadata_only(base, head)
    except InvalidMetadata as error:
        parser.exit(1, f'Release metadata: {error}\n')
    except (subprocess.CalledProcessError, OSError, UnicodeError) as error:
        print(f'Release metadata classification unavailable; running full CI: {error}', file=sys.stderr)
        metadata = False
    print('metadata' if metadata else 'full')


if __name__ == '__main__':
    main()
