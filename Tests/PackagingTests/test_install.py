import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import zipfile
import stat
import os

spec = importlib.util.spec_from_file_location('installer', Path(__file__).resolve().parents[2]/'scripts/install.py')
installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)

class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(suffix='.noindex')
        self.root = Path(self.temp.name)
        self.old, self.new = self.root/'Harness.app', self.root/'staged'
        for bundle, marker in ((self.old, 'old'), (self.new, 'new')):
            bundle.mkdir(); (bundle/'marker').write_text(marker)
    def tearDown(self): self.temp.cleanup()
    def marker(self, bundle): return (bundle/'marker').read_text()
    def test_archive_rejects_escape_duplicate_and_special_entries(self):
        for names in [['Harness/../../escape'], ['/absolute'], ['Harness/a', 'Harness/a'], ['Harness/a', 'Harness/./a'], ['Harness/a', 'Harness//a']]:
            archive = self.root/'invalid.zip'
            with zipfile.ZipFile(archive,'w') as output:
                for name in names: output.writestr(name,b'fixture')
            with self.assertRaises(RuntimeError): installer.validate_archive(archive)
        with zipfile.ZipFile(archive,'w') as output:
            entry = zipfile.ZipInfo('Harness/link'); entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(entry,'../../outside')
        with self.assertRaises(RuntimeError): installer.validate_archive(archive)
    def test_make_check_runs_when_script_has_no_executable_bit(self):
        root = Path(__file__).resolve().parents[2]
        swift = self.root/'swift'
        swift.write_text('#!/bin/sh\nexit 0\n'); swift.chmod(0o755)
        result = subprocess.run(['make','check','SCRATCH='+str(self.root/'build')],cwd=root,
            env={**os.environ,'PATH':str(self.root)+':'+os.environ['PATH']},capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)

    def test_archive_rejects_case_and_unicode_aliases_on_macos(self):
        for names in [['Harness/file', 'Harness/FILE'],
                      ['Harness/café', 'Harness/cafe\u0301']]:
            archive = self.root/'aliased.zip'
            with zipfile.ZipFile(archive,'w') as output:
                for name in names: output.writestr(name,b'fixture')
            with self.assertRaises(RuntimeError): installer.validate_archive(archive)

    def test_real_codesign_requirement_is_read_from_stdout(self):
        requirement = 'designated => identifier "org.harness.research" and certificate leaf = H"fixture"'
        output = subprocess.CompletedProcess([], 0, requirement+'\n', 'Executable=/fixture/Harness\n')
        with patch.object(installer, 'run', return_value='org.harness.research'), patch.object(installer.subprocess, 'run', return_value=output):
            self.assertEqual(installer.validate(self.new), requirement)
    def test_success_atomically_exchanges_existing_bundles(self):
        installer.install_bundle(self.new, self.old, validate=lambda _: 'same identity')
        self.assertEqual(self.marker(self.old), 'new')
        self.assertEqual(self.marker(self.new), 'old')
    def test_identity_change_cannot_replace_canonical_app(self):
        with self.assertRaises(RuntimeError):
            installer.install_bundle(self.new, self.old, validate=lambda path: self.marker(path))
        self.assertEqual(self.marker(self.old), 'old')
    def test_validation_failure_after_exchange_restores_old_app(self):
        def validate(path):
            if path == self.old and self.marker(path) == 'new': raise RuntimeError('invalid new installation')
            return 'same identity'
        with self.assertRaises(RuntimeError): installer.install_bundle(self.new, self.old, validate=validate)
        self.assertEqual(self.marker(self.old), 'old')
        self.assertEqual(self.marker(self.new), 'new')
    def test_fresh_install_and_failed_validation_are_reversible(self):
        destination = self.root/'fresh.app'
        installer.install_bundle(self.new, destination, validate=lambda _: 'identity')
        self.assertEqual(self.marker(destination), 'new')
        def invalid(path):
            if path == self.new: raise RuntimeError('invalid')
            return 'identity'
        with self.assertRaises(RuntimeError): installer.install_bundle(destination, self.new, validate=invalid)
        self.assertEqual(self.marker(destination), 'new')
        self.assertFalse(self.new.exists())

if __name__ == '__main__': unittest.main()
