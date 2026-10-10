#!/usr/bin/env python3
"""Real process/bundle preference checks in UUID test domains only."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile
import uuid
ROOT = Path(__file__).resolve().parents[1]
def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode: raise RuntimeError(result.stderr or 'Probe failed')
    return result.stdout.strip()
with tempfile.TemporaryDirectory(prefix='harness-preferences-', suffix='.noindex', dir='/private/tmp') as folder:
    binary = Path(folder)/'probe'
    run('/usr/bin/xcrun','swiftc','-parse-as-library',str(ROOT/'Sources/HarnessCore/Settings/Settings.swift'),str(ROOT/'Sources/HarnessCore/Settings/SettingsStore.swift'),str(ROOT/'Tests/PreferenceProcessProbe/main.swift'),'-o',str(binary))
    app = Path(folder)/'Probe.app'; bundled = app/'Contents/MacOS/Probe'; bundled.parent.mkdir(parents=True)
    shutil.copyfile(binary,bundled); bundled.chmod(0o755)
    for bundled_writer in (False,True):
        domain='HarnessRestartProbe.'+str(uuid.uuid4())
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':domain,'CFBundleExecutable':'Probe','CFBundlePackageType':'APPL'}))
        try:
            print(run(str(bundled if bundled_writer else binary),'write',domain))
            for reader in (binary,bundled,binary,bundled): print(run(str(reader),'read',domain))
        finally: run(str(binary),'cleanup',domain)
print('PASS: both raw and own-bundle-domain launches share all ordinary preferences across eight independent restarts.')
