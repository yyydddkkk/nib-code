import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


class Refused(Exception):
    pass


def git(root, *args, data=None, env=None, check=True):
    clean = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    clean.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', LC_ALL='C')
    if env:
        clean.update(env)
    p = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-c',
                        'core.hooksPath=/dev/null', '-C', str(root), *args],
                       input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=clean)
    if check and p.returncode:
        raise Refused(p.stderr.decode('utf-8', 'replace').strip() or 'git failed')
    return p.stdout if check else p


def text(data):
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError:
        raise Refused('race does not support non-UTF-8 paths')


def paths(data):
    return [text(p) for p in data.split(b'\0') if p]


def save_json(path, value):
    temporary = str(path) + '.tmp'
    with open(temporary, 'w') as f:
        json.dump(value, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, path)


def load(home):
    with open(Path(home) / 'owner.json') as f:
        value = json.load(f)
    if value.get('format') != 'nib-race-1' or value.get('home') != str(Path(home).resolve()):
        raise Refused('invalid race ownership metadata')
    return value


def valid_path(name):
    parts = name.split('/')
    if not name or any(p in ('', '.', '..') or p.lower() == '.git' for p in parts):
        raise Refused('unsupported git path: ' + repr(name))


def ancestors(root, name):
    valid_path(name)
    for part in Path(name).parents:
        if str(part) == '.':
            continue
        path = Path(root) / part
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise Refused('race cannot traverse symlink or file ancestor: ' + str(path))


def state(root, name):
    ancestors(root, name)
    path = Path(root) / name
    try:
        s = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(s.st_mode):
        raise Refused('race supports only regular files: ' + str(path))
    with open(path, 'rb') as f:
        data = f.read()
        after = os.fstat(f.fileno())
    if (s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
        raise Refused('file changed while snapshotting: ' + str(path))
    return (stat.S_IMODE(s.st_mode), data)


def tree_files(root, tree):
    out = {}
    for entry in git(root, 'ls-tree', '-r', '-z', tree).split(b'\0'):
        if not entry:
            continue
        info, name = entry.split(b'\t', 1)
        mode, kind, oid = info.split()
        name = text(name)
        valid_path(name)
        if kind != b'blob' or mode not in (b'100644', b'100755'):
            raise Refused('race does not support symlinks or submodules: ' + name)
        out[name] = (mode.decode(), oid.decode())
    return out


def candidates(root):
    out = set(tree_files(root, 'HEAD'))
    for entry in git(root, 'ls-files', '--stage', '-z').split(b'\0'):
        if not entry:
            continue
        info, name = entry.split(b'\t', 1)
        mode, oid, stage = info.split()
        if mode == b'160000' or stage != b'0':
            raise Refused('race does not support submodules or an unmerged parent index')
        out.add(text(name))
    flags = git(root, 'ls-files', '-v', '-z').split(b'\0')
    if any(p.startswith((b'S ', b's ')) for p in flags):
        raise Refused('race does not support sparse checkouts')
    out.update(paths(git(root, 'ls-files', '--others', '--exclude-standard', '-z')))
    return sorted(out)


def snapshot(root, directory, label):
    index = str(Path(directory) / (label + '.index'))
    with contextlib.suppress(FileNotFoundError):
        os.unlink(index)
    env = {'GIT_INDEX_FILE': index}
    git(root, 'read-tree', 'HEAD', env=env)
    zero = b'0' * len(git(root, 'rev-parse', 'HEAD').strip())
    entries = []
    captured = {}
    for name in candidates(root):
        s = state(root, name)
        if s is None:
            entries.append(b'0 ' + zero + b'\t' + name.encode() + b'\0')
            continue
        mode, data = s
        captured[name] = (mode, hashlib.sha256(data).hexdigest())
        oid = git(root, 'hash-object', '-w', '--no-filters', '--stdin', data=data).strip()
        entries.append((b'100755' if mode & 0o111 else b'100644') + b' ' + oid + b'\t' + name.encode() + b'\0')
    git(root, 'update-index', '-z', '--index-info', data=b''.join(entries), env=env)
    tree = text(git(root, 'write-tree', env=env)).strip()
    return tree, captured


def fingerprint(root):
    result = {}
    for name in candidates(root):
        s = state(root, name)
        if s is not None:
            result[name] = (s[0], hashlib.sha256(s[1]).hexdigest())
    return result


def commit(root, tree, parent=None):
    args = ['commit-tree', '--no-gpg-sign', tree]
    if parent:
        args += ['-p', parent]
    env = {k: v for k, v in (('GIT_AUTHOR_NAME', 'nib race'), ('GIT_AUTHOR_EMAIL', 'race@localhost'),
                              ('GIT_COMMITTER_NAME', 'nib race'), ('GIT_COMMITTER_EMAIL', 'race@localhost'))}
    return text(git(root, *args, data=b'nib private race snapshot\n', env=env)).strip()


def clean(home):
    home = Path(home).resolve()
    if not (home / 'owner.json').exists():
        shutil.rmtree(home)
        return
    info = load(home)
    root = info.get('common', info['root'])
    if not Path(root).exists():
        shutil.rmtree(home)
        return
    registered = paths(git(root, 'worktree', 'list', '--porcelain', '-z'))
    for entry in registered:
        if not entry.startswith('worktree '):
            continue
        path = Path(entry[9:])
        if path.parent == home:
            git(root, 'worktree', 'remove', '--force', '--force', str(path))
    shutil.rmtree(home)


def reap(parent, exclude=None):
    for home in Path(parent).glob('race-*'):
        if home == exclude or home.is_symlink() or not home.is_dir():
            continue
        try:
            with open(home / 'owner.lock', 'r+b') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if lock.read() != b'nib-race-1\n':
                    continue
                clean(home)
        except (OSError, ValueError, Refused):
            pass


def create(home, cwd):
    home = Path(home).resolve()
    cwd = Path(cwd).resolve()
    root = Path(text(git(cwd, 'rev-parse', '--show-toplevel')).removesuffix('\n')).resolve()
    if git(root, 'rev-parse', '--is-bare-repository').strip() != b'false':
        raise Refused('race requires a non-bare git repository')
    sparse = git(root, 'config', '--bool', 'core.sparseCheckout', check=False)
    if sparse.stdout.strip() == b'true':
        raise Refused('race does not support sparse checkouts')
    git(root, 'rev-parse', '--verify', 'HEAD')
    common = Path(text(git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir')).removesuffix('\n')).resolve()
    if home.is_relative_to(root) and not home.is_relative_to(common):
        ignored = git(root, 'check-ignore', '-q', str(home), check=False)
        if ignored.returncode != 0:
            raise Refused('NIB_HOME inside the repository must be ignored by git')
    info = dict(format='nib-race-1', home=str(home), root=str(root), common=str(common), cwd=str(cwd), base='')
    save_json(home / 'owner.json', info)
    reap(home.parent, home)
    tree, captured = snapshot(root, home, 'base')
    if fingerprint(root) != captured:
        raise Refused('parent files changed while creating race snapshot')
    info['base'] = commit(root, tree, text(git(root, 'rev-parse', 'HEAD')).strip())
    save_json(home / 'owner.json', info)
    return info


def branch(home, index):
    info = load(home)
    root = info['root']
    path = Path(home) / ('branch-' + str(int(index)))
    if path.exists():
        raise Refused('race branch index already exists')
    git(root, 'worktree', 'add', '--detach', '--no-checkout', str(path), info['base'])
    git(path, 'read-tree', info['base'])
    for name, (mode, oid) in tree_files(root, info['base']).items():
        target = path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(git(root, 'cat-file', 'blob', oid))
        target.chmod(0o755 if mode == '100755' else 0o644)
    (path / Path(info['cwd']).relative_to(root)).mkdir(parents=True, exist_ok=True)
    return {'path': str(path)}


def saved_patch(home, patch):
    directory = Path(home).parent.parent / 'race-patches'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='winner-', suffix='.patch', dir=directory)
    with os.fdopen(fd, 'wb') as f:
        f.write(patch)
    return name


def staged_file(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix='.nib-race-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            os.fchmod(f.fileno(), mode)
            f.flush()
            os.fsync(f.fileno())
        return temporary
    except BaseException:
        os.unlink(temporary)
        raise


def atomic_write(path, data, mode):
    temporary = staged_file(path, data, mode)
    try:
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def transact(root, before, after):
    touched = []
    created_dirs = []
    backups = {}
    complete = False
    try:
        for name, previous in before.items():
            if state(root, name) != previous:
                raise Refused('parent changed during race application: ' + name)
            target = Path(root) / name
            missing = []
            parent = target.parent
            while not parent.exists():
                missing.append(parent)
                parent = parent.parent
            for directory in reversed(missing):
                directory.mkdir()
                created_dirs.append(directory)
            if previous is not None:
                backups[name] = staged_file(target, previous[1], previous[0])
        for name, desired in after.items():
            if state(root, name) != before[name]:
                raise Refused('parent changed during race application: ' + name)
            target = Path(root) / name
            touched.append(name)
            if desired is None:
                target.unlink()
            else:
                atomic_write(target, desired[1], desired[0])
        complete = True
    except BaseException:
        failures = []
        for name in reversed(touched):
            target = Path(root) / name
            try:
                if before[name] is None:
                    with contextlib.suppress(FileNotFoundError):
                        target.unlink()
                else:
                    os.replace(backups[name], target)
                    del backups[name]
            except OSError as e:
                failures.append(str(e))
        if failures:
            recovery = list(backups.values())
            backups.clear()
            raise Refused('rollback requires manual recovery from ' + repr(recovery) + ': ' + '; '.join(failures))
        raise
    finally:
        for temporary in backups.values():
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
        if not complete:
            for directory in reversed(created_dirs):
                with contextlib.suppress(OSError):
                    directory.rmdir()


def encoded(s):
    return None if s is None else base64.b64encode(s[1]).decode()


def merge_tree(root, ours, theirs):
    drivers = git(root, 'config', '--null', '--name-only', '--get-regexp', r'^merge\..*\.driver$', check=False)
    if drivers.returncode not in (0, 1):
        raise Refused('cannot inspect repository merge drivers')
    options = []
    for key in paths(drivers.stdout):
        if any(c in key for c in '=\n\r'):
            raise Refused('unsupported merge driver configuration key')
        options += ['-c', key + '=false']
    return git(root, *options, 'merge-tree', '--write-tree', ours, theirs, check=False)


def apply(home, winner):
    info = load(home)
    root = info['root']
    winner = Path(winner).resolve()
    if winner.parent != Path(home).resolve() or not winner.name.startswith('branch-'):
        raise Refused('winner is not a worktree owned by this race')
    if text(git(winner, 'rev-parse', '--show-toplevel')).removesuffix('\n') != str(winner):
        raise Refused('winner worktree root changed')
    tree, _ = snapshot(winner, home, 'winner')
    patch = git(root, 'diff', '--binary', '--full-index', '--no-ext-diff', '--no-textconv', info['base'], tree, '--')
    if not patch:
        return dict(ok=True, edits=[])
    try:
        common = Path(text(git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir')).removesuffix('\n'))
        with open(common / 'nib-race-apply.lock', 'a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            current, captured = snapshot(root, home, 'current')
            ours = commit(root, current, info['base'])
            theirs = commit(root, tree, info['base'])
            merged = merge_tree(root, ours, theirs)
            if merged.returncode not in (0, 1):
                raise Refused('cannot merge race winner: ' + merged.stderr.decode('utf-8', 'replace'))
            if merged.returncode:
                raise Refused('race winner conflicts with parent changes: ' + merged.stdout.decode('utf-8', 'replace'))
            merged_tree = text(merged.stdout.split(b'\n', 1)[0])
            old_files = tree_files(root, current)
            new_files = tree_files(root, merged_tree)
            names = sorted(n for n in old_files.keys() | new_files.keys() if old_files.get(n) != new_files.get(n))
            before, after = {}, {}
            for name in names:
                previous = state(root, name)
                if name not in old_files and previous is not None:
                    raise Refused('race would overwrite an ignored parent file: ' + name)
                before[name] = previous
                if name in new_files:
                    mode, oid = new_files[name]
                    permissions = previous[0] if previous else 0o644
                    permissions = (permissions | 0o111) if mode == '100755' else (permissions & ~0o111)
                    after[name] = (permissions, git(root, 'cat-file', 'blob', oid))
                else:
                    after[name] = None
            if fingerprint(root) != captured:
                raise Refused('parent files changed while preparing race application')
            edits = [dict(path=str(Path(root) / name), before=encoded(before[name]), after=encoded(after[name])) for name in names]
            transact(root, before, after)
            return dict(ok=True, edits=edits)
    except (OSError, Refused) as e:
        return dict(ok=False, patch=saved_patch(home, patch), error=str(e), edits=[])


def main():
    operation, home, *args = sys.argv[1:]
    try:
        if operation == 'create':
            result = create(home, args[0])
        elif operation == 'branch':
            result = branch(home, args[0])
        elif operation == 'apply':
            result = apply(home, args[0])
        elif operation == 'clean':
            clean(home)
            result = {}
        elif operation == 'reap':
            reap(home)
            result = {}
        else:
            raise Refused('unknown race workspace operation')
        print(json.dumps(result))
    except (OSError, ValueError, Refused) as e:
        print(json.dumps(dict(ok=False, error=str(e))))


if __name__ == '__main__':
    main()
