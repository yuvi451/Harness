import importlib.util
from pathlib import Path
import unittest

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

if __name__ == '__main__': unittest.main()
