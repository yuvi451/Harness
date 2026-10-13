import importlib.util
from pathlib import Path
import unittest
import contextlib
import io
import tempfile
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_privacy',Path(__file__).resolve().parents[2]/'scripts/release_privacy.py')
privacy = importlib.util.module_from_spec(spec); spec.loader.exec_module(privacy)

class ReleasePrivacyTests(unittest.TestCase):
    def test_home_paths_and_credentials_are_detected_without_returning_values(self):
        for value in [b'/' + b'Users/example/project', b'/' + b'home/example/project',
                      b'C:' + bytes([92]) + b'Users' + bytes([92]) + b'Example' + bytes([92]) + b'project',
                      b'sk-' + b'proj-' + b'x'*30, b'-----BEGIN ' + b'PRIVATE KEY-----',
                      b'eyJ' + b'a'*20 + b'.' + b'b'*25 + b'.' + b'c'*25]:
            result = privacy.findings('program',value)
            self.assertTrue(result)
            self.assertNotIn(value.decode(),str(result))

    def test_generic_endpoints_synthetic_fixtures_and_public_certificates_are_allowed(self):
        self.assertEqual(privacy.findings('source.swift',b'https://auth.openai.com dynamic_agent_client synthetic-oauth-token'),[])
        self.assertEqual(privacy.findings('certificate.txt',b'-----BEGIN CERTIFICATE-----'),[])
        for name in ['credentials.p12','identity.p8','.env.production','login.keychain-db']:
            self.assertIn('credential file',privacy.findings(name,b''))

    def test_utf16_paths_and_credentials_are_rejected_in_both_byte_orders(self):
        values = ['/' + 'Users/example/project', 'sk-' + 'proj-' + 'x'*30]
        for value in values:
            for encoding in ['utf-16-le', 'utf-16-be']:
                self.assertTrue(privacy.findings('binary',value.encode(encoding)))

    def test_personal_markers_are_checked_in_content_and_entry_names(self):
        for name, data in [('build/Example Person.log', b''), ('source',b'EXAMPLE PERSON')]:
            self.assertIn('personal identifier',privacy.findings(name,data,private_markers=['Example Person']))

    def test_workspace_owner_is_detected_when_tool_runs_as_a_generic_build_user(self):
        with patch.object(privacy.getpass,'getuser',return_value='root'), \
             patch.object(privacy.Path,'cwd',return_value=Path('/'+'Users/demo-owner/project')):
            self.assertTrue('demo-owner' in privacy.local_private_markers(),'Workspace owner marker missing.')

    def test_local_machine_names_and_additional_provider_keys_are_rejected(self):
        for data in [b'demo-workstation' + b'.local', b'ghp_' + b'x'*36,
                     b'github_pat_' + b'x'*60, b'AKIA' + b'X'*16,
                     b'AIza' + b'x'*35]:
            self.assertTrue(privacy.findings('source',data))

    def test_runtime_git_and_finder_metadata_are_rejected(self):
        for name in ['.git/config','.build/debug/program','.swiftpm/configuration/workspace-state.json',
                     '__MACOSX/._source','.DS_Store','docs/._README.md']:
            self.assertIn('private metadata',privacy.findings(name,b''))
        self.assertEqual(privacy.findings('.gitignore',b''),[])

    def test_diagnostics_never_echo_sensitive_filenames_or_values(self):
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertFalse(privacy.check([('Example Person.txt',b'Example Person')],private_markers=['Example Person']))
        self.assertNotIn('Example Person',output.getvalue())

    def test_zip_comments_and_owner_extra_fields_are_checked(self):
        for metadata in ['archive comment','entry comment','owner field']:
            with tempfile.TemporaryDirectory() as folder:
                archive_path = Path(folder)/'release.zip'
                with zipfile.ZipFile(archive_path,'w') as archive:
                    entry = zipfile.ZipInfo('README.md')
                    if metadata == 'archive comment': archive.comment = b'/' + b'Users/example/project'
                    elif metadata == 'entry comment': entry.comment = b'/' + b'Users/example/project'
                    else: entry.extra = bytes.fromhex('7578010001')
                    archive.writestr(entry,b'public')
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertFalse(privacy.check_archive(archive_path,private_markers=[]))

    def test_clean_archives_and_synthetic_addresses_remain_allowed(self):
        with tempfile.TemporaryDirectory() as folder:
            archive_path = Path(folder)/'release.zip'
            with zipfile.ZipFile(archive_path,'w') as archive:
                archive.writestr('docs/README.md',b'maintainer@example.invalid https://auth.openai.com')
            self.assertTrue(privacy.check_archive(archive_path,private_markers=[]))

    def test_git_metadata_rejects_identity_and_home_paths_without_echoing_them(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess = __import__('subprocess')
            subprocess.run(['git','init','-q',str(root)],check=True)
            (root/'README.md').write_text('public')
            subprocess.run(['git','-C',str(root),'add','.'],check=True)
            subprocess.run(['git','-C',str(root),'-c','user.name=Example Person',
                            '-c','user.email=maintainer@example.invalid','commit','-qm','initial'],check=True)
            with contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertFalse(privacy.check_git_metadata(root,private_markers=['Example Person']))
            self.assertNotIn('Example Person',output.getvalue())
            subprocess.run(['git','-C',str(root),'config','remote.origin.url','/'+'Users/example/source'],check=True)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertFalse(privacy.check_git_metadata(root,private_markers=[]))

if __name__ == '__main__': unittest.main()
