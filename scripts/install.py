#!/usr/bin/env python3
"""Install one strictly verified bundle without a missing-app update interval."""
from pathlib import Path, PurePosixPath
import ctypes
import os
import subprocess
import sys
import tempfile
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT/'dist/Harness.zip'
DEST = Path.home()/'Applications/Harness.app'

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=120).stdout

def validate_archive(path):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 2000 or sum(item.file_size for item in entries) > 536_870_912:
            raise RuntimeError('Archive exceeds installation limits.')
        names = set()
        for item in entries:
            normalized = PurePosixPath(item.filename)
            parts = normalized.parts
            kind = stat.S_IFMT(item.external_attr >> 16)
            if (not parts or parts[0] != 'Harness' or '..' in parts or '\\' in item.filename
                    or item.orig_filename != item.filename or normalized.as_posix() in names
                    or kind not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise RuntimeError('Unsafe archive entry.')
            names.add(normalized.as_posix())
        if archive.testzip() is not None: raise RuntimeError('Damaged archive.')

def validate(app):
    if app.is_symlink() or not app.is_dir(): raise RuntimeError('Expected a real Harness bundle.')
    bundle = run('/usr/bin/plutil', '-extract', 'CFBundleIdentifier', 'raw', '-o', '-', str(app/'Contents/Info.plist')).strip()
    if bundle != 'org.harness.research': raise RuntimeError('Refusing to replace an unrelated app.')
    run('/usr/bin/codesign', '--verify', '--strict', str(app))
    result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(app)], check=True, capture_output=True, text=True, timeout=10)
    requirement = next((line for line in result.stdout.splitlines() if line.startswith('designated => ')), '')
    if not requirement or 'certificate leaf' not in requirement:
        raise RuntimeError('Expected a certificate-bound signing identity.')
    return requirement

def exchange(first, second):
    # Public macOS renamex_np(RENAME_SWAP), available before our deployment target.
    rename = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(first), os.fsencode(second), 2):
        raise OSError(ctypes.get_errno(), 'Could not atomically exchange app bundles.')

def install_bundle(staged, destination, validate=validate):
    identity = validate(staged)
    exists = destination.exists() or destination.is_symlink()
    if exists:
        if validate(destination) != identity: raise RuntimeError('Signing identity changed; refusing to invalidate saved permissions.')
        exchange(staged, destination)
    else: os.rename(staged, destination)
    try: validate(destination)
    except Exception:
        if exists: exchange(staged, destination)
        else: os.rename(destination, staged)
        raise

def main():
    if SOURCE.is_symlink() or not SOURCE.is_file(): raise RuntimeError('Expected the packaged Harness archive.')
    validate_archive(SOURCE)
    running = subprocess.run(['/usr/bin/pgrep', '-x', 'Harness'], capture_output=True, timeout=10)
    if running.returncode == 0: raise RuntimeError('Quit Harness before installing its update.')
    if running.returncode != 1: raise RuntimeError('Could not verify whether Harness is running.')
    if DEST.parent.is_symlink(): raise RuntimeError('Unsafe installation directory.')
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.harness-install-', suffix='.noindex', dir=DEST.parent) as folder:
        run('/usr/bin/ditto', '-x', '-k', '--norsrc', '--noextattr', '--noqtn', str(SOURCE), folder)
        install_bundle(Path(folder)/'Harness/Harness.app', DEST)
    print('Installed '+str(DEST))

if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('Install failed: '+str(error), file=sys.stderr); sys.exit(1)
