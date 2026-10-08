import copy
import os
import tempfile
import unittest
from pathlib import Path

from collect_coreml_result import native_directory, require_new_source_proof, retain_snapshot, validate_report


class ResultIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.scenario = {'id': 'S1-stable-facts', 'version': 1, 'system': 'Keep the facts.',
                         'turns': [{'user': f'Turn {i}', 'padding': 'More context. ',
                                    'paddingRepeats': i} for i in range(6)]}
        self.artifact = {'id': 'coreml', 'repo': 'fixture/model', 'revision': 'pinned',
                         'files': [{'file': 'model.pte', 'bytes': 8, 'sha256': 'a' * 64}]}
        self.assets = {'Models/coreml/model.pte': 'a' * 64}
        self.summary = {'result': 'Passed', 'passedTests': 2, 'failedTests': 0,
                        'skippedTests': 0, 'totalTestCount': 2,
                        'devicesAndConfigurations': [{'device': {
                            'modelName': 'iPhone 16 Pro', 'platform': 'iOS',
                            'osVersion': '18.3.2', 'osBuildNumber': '22D82'}}]}
        history = [{'role': 'system', 'content': self.scenario['system']}]
        samples = []
        for i, turn in enumerate(self.scenario['turns']):
            history.append({'role': 'user', 'content': turn['padding'] * i + turn['user']})
            samples.append({'turn': i + 1, 'workload': 'multi-turn',
                            'cachePolicy': 'rebuild-each-turn', 'cachedTokens': 0,
                            'conversationID': 'S1-stable-facts', 'repetition': 3,
                            'messages': copy.deepcopy(history), 'output': f'Reply {i}'})
            history.append({'role': 'assistant', 'content': samples[-1]['output']})
        self.report = {'purpose': 'repeated-conversation-artifact-study', 'completed': True,
                       'study': {'attempt': 0, 'block': 3,
                                 'protocolID': 'openweights-ios-artifact-study-v1',
                                 'runtimeOrder': ['ExecuTorch Core ML'], 'scenario': 'S1-stable-facts'},
                       'device': 'iPhone17,1', 'operatingSystem': 'Version 18.3.2 (Build 22D82)',
                       'lowPowerMode': False, 'contextTokens': 2048, 'maxOutputTokens': 64,
                       'multiTurnWorkload': copy.deepcopy(self.scenario),
                       'acquisitions': [{'artifactID': 'coreml', 'attempt': 0, 'file': 'model.pte',
                                         'outcome': 'bundle-verified', 'receivedFileBytes': 8}],
                       'rows': [{'engine': 'ExecuTorch Core ML', 'phase': 'complete',
                                 'artifact': copy.deepcopy(self.artifact), 'samples': samples}]}

    def validate(self):
        return validate_report(self.report, self.summary, 3, 0, self.scenario,
                               self.artifact, self.assets)

    def test_complete_block_with_exact_history_is_accepted(self):
        self.assertEqual(self.validate(), 'Version 18.3.2 (Build 22D82)')

    def test_wrong_separate_plan_block_is_rejected(self):
        self.report['study']['block'] = 2
        with self.assertRaisesRegex(ValueError, 'Wrong study'):
            self.validate()

    def test_partial_runtime_is_rejected(self):
        self.report['rows'][0]['phase'] = 'failed'
        with self.assertRaisesRegex(ValueError, 'Runtime row'):
            self.validate()

    def test_incomplete_report_is_rejected(self):
        self.report['completed'] = False
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            self.validate()

    def test_omitted_turn_is_rejected(self):
        self.report['rows'][0]['samples'].pop()
        with self.assertRaisesRegex(ValueError, 'six ordered'):
            self.validate()

    def test_reset_replay_cannot_replace_primary_turn(self):
        self.report['rows'][0]['samples'][2]['workload'] = 'multi-turn-replay'
        with self.assertRaisesRegex(ValueError, 'request or cache'):
            self.validate()

    def test_cached_prefix_cannot_be_silently_pooled(self):
        self.report['rows'][0]['samples'][2]['cachedTokens'] = 4
        with self.assertRaisesRegex(ValueError, 'request or cache'):
            self.validate()

    def test_carried_assistant_history_must_match_earlier_output(self):
        self.report['rows'][0]['samples'][1]['messages'][2]['content'] = 'A different reply'
        with self.assertRaisesRegex(ValueError, 'carried assistant'):
            self.validate()

    def test_exact_packaged_padding_must_reach_generation(self):
        self.report['rows'][0]['samples'][1]['messages'][-1]['content'] = 'Turn 1'
        with self.assertRaisesRegex(ValueError, 'Prompt'):
            self.validate()

    def test_artifact_revision_must_match_package(self):
        self.report['rows'][0]['artifact']['revision'] = 'another'
        with self.assertRaisesRegex(ValueError, 'Artifact identity'):
            self.validate()

    def test_build_receipt_model_hash_must_match(self):
        self.assets['Models/coreml/model.pte'] = 'b' * 64
        with self.assertRaisesRegex(ValueError, 'build receipt'):
            self.validate()

    def test_acquisition_byte_count_must_match(self):
        self.report['acquisitions'][0]['receivedFileBytes'] = 7
        with self.assertRaisesRegex(ValueError, 'file size'):
            self.validate()

    def test_duplicate_acquisition_cannot_replace_a_file(self):
        self.report['acquisitions'].append(copy.deepcopy(self.report['acquisitions'][0]))
        with self.assertRaisesRegex(ValueError, 'acquisition event'):
            self.validate()

    def test_raw_os_must_match_native_evidence(self):
        self.report['operatingSystem'] = 'Version 18.3.1 (Build another)'
        with self.assertRaisesRegex(ValueError, 'Raw OS'):
            self.validate()

    def test_skipped_native_method_is_not_complete(self):
        self.summary['skippedTests'] = 1
        with self.assertRaisesRegex(ValueError, 'without skips'):
            self.validate()

    def test_low_power_mode_is_not_silently_pooled(self):
        self.report['lowPowerMode'] = True
        with self.assertRaisesRegex(ValueError, 'Low Power Mode'):
            self.validate()

    def test_correctness_failures_remain_model_observations(self):
        for sample in self.report['rows'][0]['samples']:
            sample['memoryProbePassed'] = False
        self.assertEqual(self.validate(), 'Version 18.3.2 (Build 22D82)')

    def test_existing_source_evidence_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'source.json'
            original = b'{"matrixId":"original-job"}\n'
            path.write_bytes(original)
            with self.assertRaisesRegex(ValueError, 'rather than overwritten'):
                require_new_source_proof(path)
            self.assertEqual(path.read_bytes(), original)

    def test_a_new_source_proof_is_allowed(self):
        with tempfile.TemporaryDirectory() as folder:
            require_new_source_proof(Path(folder) / 'source.json')

    def test_relative_native_path_is_normalized_for_proof(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            child = root / 'Results' / 'native'
            child.mkdir(parents=True)
            relative = Path(os.path.relpath(child, Path.cwd()))
            normalized = native_directory(relative, root)
            self.assertEqual(normalized.relative_to(root), Path('Results/native'))

    def test_native_path_outside_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'benchmark'
            with self.assertRaisesRegex(ValueError, 'inside the benchmark Results'):
                native_directory(Path(folder) / 'outside', root)

    def test_shared_results_symlink_is_supported(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'benchmark'
            shared = Path(folder) / 'shared'
            root.mkdir()
            shared.mkdir()
            (root / 'Results').symlink_to(shared, target_is_directory=True)
            native = root / 'Results' / 'native'
            native.mkdir()
            normalized = native_directory(native, root)
            self.assertEqual(normalized.relative_to((root / 'Results').resolve()), Path('native'))

    def test_snapshot_remains_unchanged_after_live_receipt_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            snapshot = Path(folder) / 'snapshot.json'
            retain_snapshot(snapshot, b'{"state":"FINISHED"}\n')
            changed = b'{"state":"FINISHED","observedLater":true}\n'
            with self.assertRaisesRegex(ValueError, 'snapshot differs'):
                retain_snapshot(snapshot, changed)
            self.assertEqual(snapshot.read_bytes(), b'{"state":"FINISHED"}\n')

    def test_identical_snapshot_can_be_reverified(self):
        with tempfile.TemporaryDirectory() as folder:
            snapshot = Path(folder) / 'snapshot.json'
            retain_snapshot(snapshot, b'proof')
            retain_snapshot(snapshot, b'proof')
            self.assertEqual(snapshot.read_bytes(), b'proof')


if __name__ == '__main__':
    unittest.main()
