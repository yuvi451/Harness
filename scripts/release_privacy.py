#!/usr/bin/env python3
"""Reject supported private material without logging matched values or filenames."""
from pathlib import Path, PurePosixPath
import getpass
import os
import re
import socket
import struct
import subprocess
import sys
import zipfile

PATTERNS = {
    'developer home path': rb'/(?:Users|home)/[^/\s\x00]+/|[A-Za-z]:[\\/](?i:Users)[\\/][^\\/\s\x00]+[\\/]',
    'private key': rb'-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',
    'API key': rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{25,}',
    'JWT credential': rb'eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}',
    'local machine name': rb'\b[A-Za-z0-9][A-Za-z0-9_-]{2,}\.local\b',
    'provider credential': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35})\b',
}
FORBIDDEN = {'.p12', '.pfx', '.p8', '.pem', '.key', '.keychain', '.keychain-db'}
PRIVATE_PARTS = {'.git', '.build', '.swiftpm', '__pycache__', '__macosx', '.ds_store'}

def local_private_markers():
    """Discover local identity at runtime; never bake it into a release or fixture."""
    values = [getpass.getuser(), socket.gethostname()]
    # Sandboxed/CI tools can run as a generic user while reading another owner's tree.
    for path in (Path.cwd(), Path(__file__).resolve(), Path.home()):
        parts = path.parts
        for index, part in enumerate(parts[:-1]):
            if part.casefold() in {'users', 'home'}: values.append(parts[index+1])
    try:
        import pwd
        values.append(pwd.getpwuid(os.getuid()).pw_gecos.split(',')[0])
    except (ImportError, KeyError):
        pass
    generic = {'root', 'user', 'runner', 'developer', 'admin', 'administrator', 'build', 'harness'}
    return sorted(set(v for v in values if len(v.strip()) >= 3 and v.casefold() not in generic))

def text_views(data):
    # Mach-O/PE resources and plist strings can contain UTF-16 without a BOM.
    yield data
    for encoding in ('utf-16-le', 'utf-16-be'):
        yield data.decode(encoding, errors='ignore').encode('utf-8')

def findings(name, data, private_markers=()):
    views = tuple(text_views(data)) + (str(name).encode('utf-8'),)
    result = [label for label, pattern in PATTERNS.items()
              if any(re.search(pattern, view) for view in views)]
    markers = [m.casefold() for m in private_markers if m]
    if markers and any(m in view.decode('utf-8', errors='ignore').casefold()
                       for m in markers for view in views):
        result.append('personal identifier')
    path = PurePosixPath(str(name).replace('\\', '/'))
    if path.suffix.lower() in FORBIDDEN or path.name == '.env' or path.name.startswith('.env.'):
        result.append('credential file')
    if any(p.casefold() in PRIVATE_PARTS or p.startswith('._') for p in path.parts):
        result.append('private metadata')
    return result

def check(entries, private_markers=None):
    if private_markers is None: private_markers = local_private_markers()
    failed = False
    for index, (name, data) in enumerate(entries, 1):
        for label in findings(name, data, private_markers):
            # A filename itself can expose an identity, path or credential.
            print(f'Release privacy check: {label} in entry {index}.', file=sys.stderr)
            failed = True
    return not failed

def check_archive(path, private_markers=None):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            print('Release privacy check: corrupt archive.', file=sys.stderr)
            return False
        valid = check([('archive comment',archive.comment)], private_markers)
        for info in archive.infolist():
            valid = check([(info.filename,archive.read(info)),('entry comment',info.comment),
                           ('entry extra field',info.extra)],private_markers) and valid
            offset = 0
            while offset < len(info.extra):
                if len(info.extra)-offset < 4:
                    print('Release privacy check: invalid archive metadata.',file=sys.stderr)
                    return False
                kind, length = struct.unpack_from('<HH',info.extra,offset)
                offset += 4 + length
                if offset > len(info.extra) or kind in {0x000D,0x5855,0x7855,0x7875}:
                    print('Release privacy check: owner or invalid archive metadata.',file=sys.stderr)
                    return False
        return valid

def check_git_metadata(root, private_markers=None):
    """Check all objects, including unreachable history, plus repo config/reflogs."""
    def git(*args):
        return subprocess.check_output(['git',*args],cwd=root,stderr=subprocess.PIPE,timeout=30)
    if Path(git('rev-parse','--show-toplevel').decode().strip()).resolve() != Path(root).resolve():
        print('Release privacy check: unrelated parent repository.',file=sys.stderr)
        return False
    directory = Path(git('rev-parse','--absolute-git-dir').decode().strip())
    files = [directory/'config'] + list((directory/'logs').rglob('*'))
    valid = check((('repository metadata',p.read_bytes()) for p in files if p.is_file()),private_markers)
    objects = git('cat-file','--batch-all-objects','--batch')
    offset = 0
    while offset < len(objects):
        end = objects.index(b'\n',offset)
        _, kind, size = objects[offset:end].split()
        start = end+1; offset = start+int(size)+1
        data = objects[start:offset-1]
        # Trees contain binary object IDs; blob/commit/tag data contains readable content.
        if kind != b'tree': valid = check([('repository object',data)],private_markers) and valid
    return valid

def main():
    if len(sys.argv) > 1:
        for argument in sys.argv[1:]:
            path = Path(argument)
            if path.suffix.lower() == '.zip':
                if not check_archive(path): return 1
            elif not check([(path.name,path.read_bytes())]): return 1
    else:
        root = Path(__file__).resolve().parents[1]
        paths = subprocess.check_output(['git','ls-files','-z'],cwd=root).split(b'\0')
        if not check((p.decode(),(root/p.decode()).read_bytes()) for p in paths if p): return 1
        if not check_git_metadata(root): return 1
    print('PASS: no detected local identities, home paths, credentials or private metadata.')
    return 0

if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.SubprocessError):
        print('Release privacy check failed; file and credential details were suppressed.',file=sys.stderr)
        sys.exit(1)
