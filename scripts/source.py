#!/usr/bin/env python3
"""Archive reviewed, committed source without runtime data or the restricted font binary."""
from pathlib import Path
import subprocess
import tempfile
import zipfile
from release_privacy import check

root = Path(__file__).resolve().parents[1]
def git(*args):
    return subprocess.run(['git', *args], cwd=root, check=True, capture_output=True, timeout=30).stdout

if git('status', '--porcelain', '--untracked-files=normal').strip():
    raise SystemExit('Commit reviewed changes before generating a source release.')
paths = [root/p.decode() for p in git('ls-files','-z').split(b'\0') if p]
if not check((p.relative_to(root).as_posix(),p.read_bytes()) for p in paths):
    raise SystemExit('Refusing source release with private content.')
dist = root/'dist'
if dist.is_symlink(): raise SystemExit('Unsafe distribution directory.')
dist.mkdir(exist_ok=True)
destination = dist/'Harness-source.zip'
if destination.is_symlink(): raise SystemExit('Unsafe source archive destination.')
with tempfile.TemporaryDirectory(prefix='harness-source-', suffix='.noindex', dir='/private/tmp') as temporary:
    archive = Path(temporary)/'Harness-source.zip'
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED) as output:
        for path in paths:
            if path.suffix == '.otf': continue
            if path.is_symlink() or not path.is_file(): raise SystemExit('Unexpected source entry.')
            output.write(path, 'Harness-source/'+path.relative_to(root).as_posix())
    destination.write_bytes(archive.read_bytes())
print('Created '+str(destination))
