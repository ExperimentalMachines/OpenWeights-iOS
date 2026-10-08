"""Host integrity controls. Synthetic ZIP fixtures are not native execution proof."""
import copy
import hashlib
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


class ArchiveVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / 'fixture.zip'
        self.receipt = self.root / 'receipt.json'
        self.sources = self.root / 'sources.zip'
        self.override = self.root / 'block3.xctestrun'
        self.plan = {
            '__xctestrun_metadata__': {'FormatVersion': 1},
            'BenchmarkTests': {
                'TestHostPath': '__TESTROOT__/Release-iphoneos/Fixture.app',
                'TestBundlePath': '__TESTHOST__/PlugIns/BenchmarkTests.xctest',
                'OnlyTestIdentifiers': ['BenchmarkTests/testStudyBlock', 'BenchmarkTests/testMultiTurnProbeGrading'],
                'MaximumTestExecutionTimeAllowance': 2400,
                'EnvironmentVariables': {'OW_STUDY_SCENARIO': 'S1-stable-facts', 'OW_STUDY_BLOCK': '2',
                                         'OW_STUDY_ATTEMPT': '0', 'OW_STUDY_RUNTIME': 'ExecuTorch Core ML',
                                         'FIXED_SETTING': 'preserved'},
            },
        }
        executable, source = b'synthetic executable fixture', b'synthetic source fixture'
        self.record = {'executables': {'Fixture.app/Fixture': hashlib.sha256(executable).hexdigest()},
                       'sources': {'App/Fixture.swift': hashlib.sha256(source).hexdigest()},
                       'xcode': 'synthetic integrity fixture'}
        self.receipt.write_text(json.dumps(self.record))
        with zipfile.ZipFile(self.archive, 'w') as package:
            package.writestr('Fixture.app/Fixture', executable)
            package.writestr('block2.xctestrun', plistlib.dumps(self.plan))
        with zipfile.ZipFile(self.sources, 'w') as package:
            package.writestr('build-receipt.json', json.dumps(self.record))
            package.writestr('App/Fixture.swift', source)
        self.external = copy.deepcopy(self.plan)
        self.external['BenchmarkTests']['EnvironmentVariables']['OW_STUDY_BLOCK'] = '3'

    def run_verifier(self, external=True):
        command = [sys.executable, str(Path(__file__).with_name('verify_archive.py')), str(self.archive),
                   '--receipt', str(self.receipt), '--sources', str(self.sources), '--suite', 'study',
                   '--scenario', 'S1-stable-facts', '--block', '3' if external else '2',
                   '--runtime', 'ExecuTorch Core ML']
        if external:
            self.override.write_bytes(plistlib.dumps(self.external))
            command += ['--xctestrun-file', str(self.override)]
        return subprocess.run(command, capture_output=True, text=True)

    def assert_binding_rejected(self):
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('changes test hosts, selection, timeouts or non-study settings', result.stderr)

    def test_embedded_plan_preserves_existing_output(self):
        result = self.run_verifier(external=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('separatePlan', json.loads(result.stdout))

    def test_separate_block_plan_records_exact_hash(self):
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['separatePlan']['sha256'],
                         hashlib.sha256(self.override.read_bytes()).hexdigest())

    def test_separate_plan_cannot_replace_test_host(self):
        self.external['BenchmarkTests']['TestHostPath'] = '__TESTROOT__/Different.app'
        self.assert_binding_rejected()

    def test_separate_plan_cannot_replace_test_bundle(self):
        self.external['BenchmarkTests']['TestBundlePath'] = '__TESTHOST__/Other.xctest'
        self.assert_binding_rejected()

    def test_separate_plan_cannot_remove_a_selected_method(self):
        self.external['BenchmarkTests']['OnlyTestIdentifiers'].pop()
        self.assert_binding_rejected()

    def test_separate_plan_cannot_add_a_test_target(self):
        self.external['UnverifiedTests'] = copy.deepcopy(self.external['BenchmarkTests'])
        self.assert_binding_rejected()

    def test_separate_plan_cannot_expand_timeout(self):
        self.external['BenchmarkTests']['MaximumTestExecutionTimeAllowance'] = 9999
        self.assert_binding_rejected()

    def test_separate_plan_cannot_change_other_environment(self):
        self.external['BenchmarkTests']['EnvironmentVariables']['FIXED_SETTING'] = 'changed'
        self.assert_binding_rejected()

    def test_separate_plan_must_match_requested_block(self):
        self.external['BenchmarkTests']['EnvironmentVariables']['OW_STUDY_BLOCK'] = '4'
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('differs from the requested scenario/block/runtime', result.stderr)

    def test_separate_plan_must_match_requested_runtime(self):
        self.external['BenchmarkTests']['EnvironmentVariables']['OW_STUDY_RUNTIME'] = 'ExecuTorch MLX'
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('differs from the requested scenario/block/runtime', result.stderr)

    def test_separate_plan_still_requires_matching_executables(self):
        self.record['executables']['Fixture.app/Fixture'] = '0' * 64
        self.receipt.write_text(json.dumps(self.record))
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Executable does not match build receipt', result.stderr)

    def test_separate_plan_still_requires_matching_sources(self):
        self.record['sources']['App/Fixture.swift'] = '0' * 64
        self.receipt.write_text(json.dumps(self.record))
        with zipfile.ZipFile(self.sources, 'w') as package:
            package.writestr('build-receipt.json', json.dumps(self.record))
            package.writestr('App/Fixture.swift', b'synthetic source fixture')
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Source snapshot hash mismatch', result.stderr)


if __name__ == '__main__':
    unittest.main()
