#!/usr/bin/env python3
"""Reuse one local development identity. Never changes certificate trust settings.

Private material ends in a dedicated encrypted Keychain. Only its password is stored
in a precisely named login-Keychain item. Temporary private files are removed.
"""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import secrets
import shlex
import stat
import subprocess
import sys
import tempfile

SERVICE = 'org.harness.research.build-signing'
ACCOUNT = 'Harness Local Development'
CERT_NAME = 'Harness Local Development'

class SigningError(Exception):
    pass

class Signer:
    def __init__(self, directory=None, runner=subprocess.run, temp_root='/private/tmp'):
        self.directory = Path(directory or Path.home() / 'Library/Keychains')
        self.keychain = self.directory / 'org.harness.research.signing.keychain-db'
        self.metadata = self.directory / 'org.harness.research.signing.identity.json'
        self.login = self.directory / 'login.keychain-db'
        self.runner, self.temp_root = runner, temp_root

    def run(self, *args, missing=False, binary=False):
        try:
            result = self.runner(list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=not binary, timeout=120)
        except (subprocess.TimeoutExpired, OSError):
            raise SigningError('Local signing tool did not complete; credential details were suppressed.') from None
        if missing and result.returncode == 44:
            return None
        if result.returncode:
            # CLI error text can contain supplied secrets. Never print it or argv.
            raise SigningError('Local signing setup failed in ' + Path(args[0]).name + '; existing identities were not rotated.')
        return result.stdout

    def check_file(self, path):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
            raise SigningError('Owned signing storage is not a private regular file.')

    def fingerprint(self):
        pem = self.run('/usr/bin/security', 'find-certificate', '-c', CERT_NAME, '-a', '-p', str(self.keychain))
        if pem.count('-----BEGIN CERTIFICATE-----') != 1:
            raise SigningError('Expected exactly one local signing certificate.')
        with tempfile.TemporaryDirectory(prefix='harness-public-cert-', suffix='.noindex', dir=self.temp_root) as folder:
            cert = Path(folder)/'certificate.pem'; cert.write_text(pem)
            self.run('/usr/bin/openssl', 'x509', '-in', str(cert), '-checkend', '86400', '-noout')
            der = self.run('/usr/bin/openssl', 'x509', '-in', str(cert), '-outform', 'der', binary=True)
        return hashlib.sha1(der).hexdigest().upper()

    def identity(self):
        if not self.directory.is_dir() or self.directory.is_symlink():
            raise SigningError('Expected the user Keychains directory.')
        lock_path = self.directory/'org.harness.research.signing.lock'
        try:
            descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, 0o600)
        except OSError:
            raise SigningError('Local signing lock is unavailable.') from None
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                raise SigningError('Unsafe local signing lock.')
            os.fchmod(descriptor, 0o600)
            try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise SigningError('Another local signing setup is active; retry after it finishes.') from None
            return self._identity()
        finally:
            os.close(descriptor)

    def _identity(self):
        password = self.run('/usr/bin/security', 'find-generic-password', '-s', SERVICE, '-a', ACCOUNT, '-w', str(self.login), missing=True)
        present = (self.keychain.exists() or self.keychain.is_symlink(), self.metadata.exists() or self.metadata.is_symlink(), password is not None)
        if any(present) and not all(present):
            raise SigningError('Local signing setup is incomplete. Refusing to generate a replacement identity and invalidate permissions.')
        if all(present):
            self.check_file(self.keychain); self.check_file(self.metadata)
            password = password.rstrip('\n')
            self.run('/usr/bin/security', 'unlock-keychain', '-p', password, str(self.keychain))
            fingerprint = self.fingerprint()
            if json.loads(self.metadata.read_text()).get('fingerprint') != fingerprint:
                raise SigningError('Local signing certificate changed. Refusing silent identity rotation.')
            return {'keychain': str(self.keychain), 'fingerprint': fingerprint}
        if not self.directory.is_dir() or self.directory.is_symlink():
            raise SigningError('Expected the user Keychains directory.')
        if not self.login.is_file() or self.login.is_symlink():
            raise SigningError('Expected the user login Keychain.')
        password = secrets.token_urlsafe(48)
        created_keychain = created_password = False
        try:
            with tempfile.TemporaryDirectory(prefix='harness-signing-', suffix='.noindex', dir=self.temp_root) as folder:
                root = Path(folder); root.chmod(0o700)
                config = root/'certificate.cnf'
                config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN='+CERT_NAME+'\n[ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
                private, cert, p12 = root/'private.key', root/'certificate.pem', root/'identity.p12'
                self.run('/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-x509', '-sha256', '-days', '3650', '-config', str(config), '-keyout', str(private), '-out', str(cert))
                private.chmod(0o600)
                self.run('/usr/bin/openssl', 'pkcs12', '-export', '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1', '-inkey', str(private), '-in', str(cert), '-out', str(p12), '-passout', 'pass:'+password)
                # create-keychain adds its new path to the search list. Remove ONLY
                # this owned addition immediately; retain all other current entries.
                self.run('/usr/bin/security', 'create-keychain', '-p', password, str(self.keychain)); created_keychain = True
                current = shlex.split(self.run('/usr/bin/security', 'list-keychains', '-d', 'user'))
                retained = [entry for entry in current if Path(entry) != self.keychain]
                self.run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *retained)
                self.run('/usr/bin/security', 'unlock-keychain', '-p', password, str(self.keychain))
                self.run('/usr/bin/security', 'import', str(p12), '-k', str(self.keychain), '-P', password, '-T', '/usr/bin/codesign')
                self.run('/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, str(self.keychain))
                self.keychain.chmod(0o600)
                fingerprint = self.fingerprint()
                self.run('/usr/bin/security', 'add-generic-password', '-s', SERVICE, '-a', ACCOUNT, '-w', password, '-T', '/usr/bin/security', str(self.login)); created_password = True
                fd = os.open(self.metadata, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'w') as stream:
                    json.dump({'fingerprint': fingerprint}, stream); stream.flush(); os.fsync(stream.fileno())
                self.check_file(self.keychain); self.check_file(self.metadata)
                return {'keychain': str(self.keychain), 'fingerprint': fingerprint}
        except Exception:
            # Only a newly created setup is rolled back. Reuse failures never delete
            # an established signing key, certificate or password.
            if created_password:
                try: self.run('/usr/bin/security', 'delete-generic-password', '-s', SERVICE, '-a', ACCOUNT, str(self.login))
                except SigningError: pass
            if created_keychain:
                try: self.run('/usr/bin/security', 'delete-keychain', str(self.keychain))
                except SigningError: pass
            if created_keychain and self.metadata.exists() and not self.metadata.is_symlink():
                self.metadata.unlink()
            raise

if __name__ == '__main__':
    try:
        print(json.dumps(Signer().identity()))
    except Exception as error:
        print(str(error) if isinstance(error, SigningError) else 'Local signing setup failed; no credential details were logged.', file=sys.stderr)
        sys.exit(1)
