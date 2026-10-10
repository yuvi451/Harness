#!/usr/bin/env python3
"""Run only while the canonical app is already Ready. No capture or real hotkey."""
import json
from pathlib import Path
import subprocess
import tempfile
APP = Path.home()/'Applications/Harness.app'
AUDIT = Path.home()/'Library/Application Support/harness/audit.jsonl'
def pids(): return subprocess.run(['/usr/bin/pgrep','-x','Harness'],capture_output=True,text=True,check=True).stdout.splitlines()
def launches(): return sum(json.loads(line)['event']=='app_launch' for line in AUDIT.read_text().splitlines())
original=pids()
assert len(original)==1, 'Need exactly one running canonical Harness instance'
process_path=subprocess.run(['/bin/ps','-p',original[0],'-o','comm='],capture_output=True,text=True,check=True).stdout.strip()
assert process_path==str(APP/'Contents/MacOS/Harness'), 'Running instance is not the canonical install'
with tempfile.TemporaryDirectory(prefix='harness-singleton-',suffix='.noindex',dir='/private/tmp') as folder:
    copy=Path(folder)/'Harness.app'
    subprocess.run(['/usr/bin/ditto','--norsrc','--noextattr','--noqtn',str(APP),str(copy)],check=True)
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(copy)],check=True)
    before=launches()
    result=subprocess.run([str(copy/'Contents/MacOS/Harness')],capture_output=True,text=True,timeout=10)
    assert result.returncode==0, 'Second copy did not exit normally'
    assert launches()==before, 'Second copy created an additional session/hotkey registrations'
    assert pids()==original, 'The original single app instance was not preserved'
print('PASS: duplicate bundle exits and reopens the same canonical instance, with no additional session/hotkeys. Temporary copy removed.')
