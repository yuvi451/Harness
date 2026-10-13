import importlib.util
import json
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('signing', Path(__file__).resolve().parents[2]/'scripts/signing.py')
signing = importlib.util.module_from_spec(spec); spec.loader.exec_module(signing)

class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(suffix='.noindex')
        self.root = Path(self.temp.name)
        self.login = self.root/'login.keychain-db'; self.login.touch(); self.login.chmod(0o600)
        self.calls = []; self.password = None; self.fail_import = False
        self.signer = signing.Signer(self.root, self.run_tool, self.root)
    def tearDown(self): self.temp.cleanup()
    def run_tool(self, args, **options):
        self.calls.append(args)
        command = args[1]
        output = b'synthetic certificate DER' if options.get('text') is False else ''
        status = 0
        if command == 'find-generic-password':
            if self.password is None: status = 44
            else: output = self.password+'\n'
        elif command == 'create-keychain':
            Path(args[-1]).touch(); Path(args[-1]).chmod(0o600)
        elif command == 'list-keychains' and '-s' not in args:
            output = '"'+str(self.login)+'"\n"'+str(self.signer.keychain)+'"\n"/keep/other.keychain-db"\n'
        elif command == 'req':
            Path(args[args.index('-keyout')+1]).write_text('synthetic private key')
            Path(args[args.index('-out')+1]).write_text('synthetic cert')
        elif command == 'pkcs12': Path(args[args.index('-out')+1]).write_text('synthetic p12')
        elif command == 'import' and self.fail_import: status = 1
        elif command == 'find-certificate': output = '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n'
        elif command == 'add-generic-password': self.password = args[args.index('-w')+1]
        elif command == 'delete-keychain': Path(args[-1]).unlink(missing_ok=True)
        elif command == 'delete-generic-password': self.password = None
        return subprocess.CompletedProcess(args, status, output, 'DO NOT PRINT SECRETS')
    def test_concurrent_setup_cannot_create_a_second_identity(self):
        lock = self.root/'org.harness.research.signing.lock'
        with lock.open('w') as held:
            lock.chmod(0o600)
            fcntl.flock(held,fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(signing.SigningError): self.signer.identity()
        self.assertFalse(any(a[1]=='create-keychain' for a in self.calls))

    def test_timed_out_tool_errors_are_bounded_and_redacted(self):
        def stalled(args, **options):
            raise subprocess.TimeoutExpired(args,120,output='synthetic-private-value')
        signer = signing.Signer(self.root,stalled,self.root)
        with self.assertRaises(signing.SigningError) as failure:
            signer.run('/usr/bin/security','unlock-keychain','-p','synthetic-private-value')
        self.assertNotIn('synthetic-private-value',str(failure.exception))

    def test_bootstrap_reuses_same_certificate_and_never_changes_trust(self):
        first = self.signer.identity(); second = self.signer.identity()
        self.assertEqual(first, second)
        self.assertEqual(sum(a[1]=='create-keychain' for a in self.calls), 1)
        self.assertFalse(any(a[1] in ('add-trusted-cert', 'default-keychain') for a in self.calls))
        search = next(a for a in self.calls if a[1]=='list-keychains' and '-s' in a)
        self.assertEqual(search[search.index('-s')+1:], [str(self.login), '/keep/other.keychain-db'])
        self.assertNotIn(self.password, json.dumps(first))
        self.assertEqual(list(self.root.glob('harness-*')), [])
        self.assertFalse(any('private' in p.name or p.suffix=='.p12' for p in self.root.iterdir()))
    def test_partial_state_refuses_identity_rotation(self):
        self.signer.keychain.touch(); self.signer.keychain.chmod(0o600)
        with self.assertRaises(signing.SigningError): self.signer.identity()
        self.assertFalse(any(a[1]=='create-keychain' for a in self.calls))
        self.assertTrue(self.signer.keychain.exists())
    def test_changed_identity_is_retained_and_rejected(self):
        self.signer.identity()
        self.signer.metadata.write_text(json.dumps({'fingerprint': 'different'}))
        with self.assertRaises(signing.SigningError): self.signer.identity()
        self.assertFalse(any(a[1]=='delete-keychain' for a in self.calls))
        self.assertIsNotNone(self.password)
    def test_failed_bootstrap_cleans_private_files_and_owned_new_keychain(self):
        self.fail_import = True
        with self.assertRaises(signing.SigningError) as error: self.signer.identity()
        self.assertNotIn('DO NOT PRINT SECRETS', str(error.exception))
        self.assertFalse(self.signer.keychain.exists())
        self.assertEqual(list(self.root.glob('harness-*')), [])
    def test_reuse_refuses_symlink_without_unlock(self):
        self.signer.identity()
        target = self.root/'target'; self.signer.metadata.rename(target); self.signer.metadata.symlink_to(target)
        count = len(self.calls)
        with self.assertRaises(signing.SigningError): self.signer.identity()
        self.assertFalse(any(a[1]=='unlock-keychain' for a in self.calls[count:]))

if __name__ == '__main__': unittest.main()
