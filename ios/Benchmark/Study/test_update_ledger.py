import hashlib
import copy
import json
import tempfile
import unittest
from pathlib import Path

from update_ledger import update
from build_cohort import source_cohort


class LedgerDeviceAccountingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.results = Path(self.directory.name)
        self.analysis = {'schemaVersion': 5, 'sources': [], 'gradingVersion': 3}
        self.ledger = {
            'plannedCells': [
                {'deviceCatalogName': name, 'runtime': 'llama.cpp Metal',
                 'scenario': 'S1-stable-facts', 'requiredCompleteIndependentBlocks': 5}
                for name in ['local iPhone 16', 'Firebase iPhone 16 Pro', 'Firebase iPhone SE 3']
            ],
            'unavailableExecutions': [{'device': 'iphonese3', 'matrix': 'historical-failure'}],
        }

    def add_report(self, device, block, *, attempt=0, phase='complete',
                   os='OS A', purpose='repeated-conversation-artifact-study', build_source='a',
                   build_executable='b', cache='prefix'):
        name = f'report-{len(self.analysis["sources"])}.json'
        report = {
            'device': device, 'operatingSystem': os, 'purpose': purpose,
            'contextTokens': 2048, 'maxOutputTokens': 64,
            'completed': True, 'runtimeVersions': {'engine': 'pinned'},
            'study': {'protocolID': 'protocol-v1', 'scenario': 'S1-stable-facts', 'block': block, 'attempt': attempt},
            'rows': [{'engine': 'llama.cpp Metal', 'phase': phase,
                      'artifact': {'id': 'gguf', 'files': [{'file': 'model', 'sha256': 'hash'}]},
                      'samples': [{'cachePolicy': cache}]}],
        }
        (self.results / name).write_text(json.dumps(report))
        path = self.results / name
        proof = {'rawResultsFile': name,
                 'rawResultsSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
                 'buildReceipt': {'sources': {'runner.swift': build_source * 64},
                                  'executables': {'app': build_executable * 64},
                                  'xcode': 'Xcode test', 'sdk': 'test'}}
        path.with_name(path.stem + '-source.json').write_text(json.dumps(proof))
        self.analysis['sources'].append({'file': name, **source_cohort(path, path.read_bytes())})

    def refresh(self):
        return update(self.analysis, self.ledger, self.results)

    def test_se_reports_count_without_attributing_pro_reports(self):
        for block in range(5):
            self.add_report('iPhone14,6', block)
            self.add_report('iPhone17,1', block)
        local, pro, se = self.refresh()['plannedCells']
        self.assertEqual(local['completedPrimaryBlocks'], 0)
        self.assertEqual(pro['completedPrimaryBlocks'], 5)
        self.assertEqual(se['completedPrimaryBlocks'], 5)
        self.assertEqual(se['status'], 'replication-satisfied')
        self.assertTrue(set(pro['observedRawFiles']).isdisjoint(se['observedRawFiles']))

    def test_historical_failure_does_not_define_current_availability(self):
        historical = copy.deepcopy(self.ledger['unavailableExecutions'])
        se = self.refresh()['plannedCells'][2]
        self.assertEqual(se['status'], 'incomplete')
        self.assertEqual(se['completedPrimaryBlocks'], 0)
        self.assertEqual(self.ledger['unavailableExecutions'], historical)

    def test_se_failures_and_retries_are_retained_without_inflating_count(self):
        self.add_report('iPhone14,6', 0, phase='failed')
        self.add_report('iPhone14,6', 0, attempt=1)
        self.add_report('iPhone14,6', 1)
        se = self.refresh()['plannedCells'][2]
        self.assertEqual(len(se['observedRawFiles']), 3)
        self.assertEqual(se['completedPrimaryBlocks'], 1)
        self.assertEqual(se['completeBlockCohorts'][0]['blocks'], [1])

    def test_actual_os_cohorts_remain_separate(self):
        for block in range(3):
            self.add_report('iPhone14,6', block, os='OS A')
        for block in range(3, 5):
            self.add_report('iPhone14,6', block, os='OS B')
        se = self.refresh()['plannedCells'][2]
        self.assertEqual(se['completedPrimaryBlocks'], 3)
        self.assertEqual(len(se['completeBlockCohorts']), 2)
        self.assertEqual(se['status'], 'incomplete')

    def test_compatibility_pilot_is_not_a_primary_study_report(self):
        for block in range(5):
            self.add_report('iPhone14,6', block, purpose='runner-validation-pilot')
        result = self.refresh()
        self.assertEqual(result['records'], [])
        self.assertEqual(result['plannedCells'][2]['completedPrimaryBlocks'], 0)

    def test_source_build_and_cache_cohorts_cannot_inflate_replication(self):
        for block in range(3):
            self.add_report('iPhone14,6', block)
        for block in range(3, 5):
            self.add_report('iPhone14,6', block, build_source='c')
        se = self.refresh()['plannedCells'][2]
        self.assertEqual(se['completedPrimaryBlocks'], 3)
        self.assertEqual(len(se['completeBlockCohorts']), 2)
        self.assertEqual(se['status'], 'incomplete')
        self.add_report('iPhone14,6', 5, cache='reset')
        self.add_report('iPhone14,6', 6, build_executable='d')
        se = self.refresh()['plannedCells'][2]
        self.assertEqual(se['completedPrimaryBlocks'], 3)
        self.assertEqual(len(se['completeBlockCohorts']), 4)

    def test_ledger_rejects_tampered_analysis_build_identity(self):
        self.add_report('iPhone14,6', 0)
        self.analysis['sources'][0]['buildCohortSHA256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'Analysis build cohort differs'):
            self.refresh()

    def test_unknown_catalog_device_is_not_silently_treated_as_pro(self):
        self.ledger['plannedCells'][0]['deviceCatalogName'] = 'unmapped phone'
        with self.assertRaises(KeyError):
            self.refresh()


if __name__ == '__main__':
    unittest.main()
