#!/usr/bin/env python3
"""Reject credential material and developer home paths without printing their values."""
from pathlib import Path
import re
import subprocess
import sys
import zipfile

PATTERNS = {
    'developer home path': rb'/(?:Users|home)/[^/\s\x00]+/|[A-Za-z]:[\\/](?i:Users)[\\/][^\\/\s\x00]+[\\/]',
    'private key': rb'-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----',
    'API key': rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{25,}',
    'JWT credential': rb'eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}',
}
FORBIDDEN = {'.p12', '.pfx', '.p8', '.pem', '.key', '.keychain', '.keychain-db'}

def findings(name, data):
    result = [label for label, pattern in PATTERNS.items() if re.search(pattern, data)]
    path = Path(name)
    if path.suffix.lower() in FORBIDDEN or path.name == '.env' or path.name.startswith('.env.'):
        result.append('credential file')
    return result

def check(entries):
    failed = False
    for name, data in entries:
        for label in findings(name, data):
            # Names originate from repository/own release entries; matched values stay private.
            print(f'Release privacy check: {label} in {name}', file=sys.stderr)
            failed = True
    return not failed

def main():
    if len(sys.argv) > 1:
        for argument in sys.argv[1:]:
            path = Path(argument)
            if path.suffix == '.zip':
                with zipfile.ZipFile(path) as archive:
                    if archive.testzip() is not None: raise SystemExit('Corrupt release archive.')
                    if not check((n, archive.read(n)) for n in archive.namelist() if not n.endswith('/')): return 1
            elif not check([(path.name,path.read_bytes())]): return 1
    else:
        root = Path(__file__).resolve().parents[1]
        paths = subprocess.check_output(['git','ls-files','-z'],cwd=root).split(b'\0')
        if not check((p.decode(),(root/p.decode()).read_bytes()) for p in paths if p): return 1
    print('PASS: no developer home paths or supported credential signatures in checked release content.')
    return 0

if __name__ == '__main__': sys.exit(main())
