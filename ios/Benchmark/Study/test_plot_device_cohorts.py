import copy
import unittest

from plot_device_cohorts import select_cells


class CohortFigureControls(unittest.TestCase):
    def setUp(self):
        # Unit fixtures exercise refusal boundaries, not native performance.
        cell = {'device': 'local', 'operatingSystem': 'local OS', 'engine': 'ExecuTorch Core ML',
                'scenario': 'S1-stable-facts', 'turn': 6, 'workload': 'multi-turn',
                'fullyCompletedReports': 5, 'artifactID': 'coreml',
                'artifactHashes': {'model.pte': 'pinned hash'}, 'runtimeVersions': {'ExecuTorch': '1.5.0'},
                'cachePolicy': 'rebuild-each-turn', 'contextTokens': 2048, 'maxOutputTokens': 64,
                'completeReportMetrics': {m: {'n': 5, 'p25': 1, 'median': 2, 'p75': 3}
                    for m in ['firstCallbackMs', 'streamTokensPerSecond', 'peakFootprintBytes']}}
        cloud = copy.deepcopy(cell)
        cloud.update(device='cloud', operatingSystem='cloud OS')
        self.analysis = {'minimumIndependentBlocksPerCell': 5, 'cells': [cell, cloud]}
        self.cohorts = [('local', 'local OS'), ('cloud', 'cloud OS')]

    def select(self):
        return select_cells(self.analysis, 'ExecuTorch Core ML', 'S1-stable-facts', self.cohorts)

    def test_separate_os_cohorts_preserve_labels_and_counts(self):
        selected = self.select()
        self.assertEqual([(c['device'], c['operatingSystem']) for c in selected], self.cohorts)
        self.assertEqual([c['fullyCompletedReports'] for c in selected], [5, 5])

    def test_four_complete_blocks_refused(self):
        self.analysis['cells'][1]['fullyCompletedReports'] = 4
        with self.assertRaisesRegex(ValueError, '4/5'):
            self.select()

    def test_partial_metric_denominator_refused(self):
        self.analysis['cells'][1]['completeReportMetrics']['firstCallbackMs']['n'] = 4
        with self.assertRaisesRegex(ValueError, 'invalid complete-report metric'):
            self.select()

    def test_duplicate_selection_refused(self):
        self.cohorts.append(self.cohorts[0])
        with self.assertRaisesRegex(ValueError, 'distinct'):
            self.select()

    def test_missing_exact_os_refused(self):
        self.cohorts[1] = ('cloud', 'different OS')
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.select()

    def test_ambiguous_cache_or_artifact_cohort_refused(self):
        duplicate = copy.deepcopy(self.analysis['cells'][1])
        duplicate['cachePolicy'] = 'different cache policy'
        self.analysis['cells'].append(duplicate)
        with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
            self.select()

    def test_differing_artifact_runtime_and_cache_refused(self):
        for key in ['artifactHashes', 'runtimeVersions', 'cachePolicy']:
            with self.subTest(key=key):
                original = self.analysis['cells'][1][key]
                self.analysis['cells'][1][key] = 'different'
                with self.assertRaisesRegex(ValueError, key):
                    self.select()
                self.analysis['cells'][1][key] = original

    def test_nonfinite_or_reversed_intervals_refused(self):
        metric = self.analysis['cells'][1]['completeReportMetrics']['firstCallbackMs']
        for p25, median, p75 in [(1, float('nan'), 3), (3, 2, 1), (0, 2, 3)]:
            with self.subTest(values=(p25, median, p75)):
                metric.update(p25=p25, median=median, p75=p75)
                with self.assertRaisesRegex(ValueError, 'invalid complete-report metric'):
                    self.select()

    def test_schema5_different_build_and_protocol_refused(self):
        self.analysis['schemaVersion'] = 5
        for cell in self.analysis['cells']:
            cell.update(buildCohortSHA256='a' * 64, protocolID='v1')
        self.assertEqual(len(self.select()), 2)
        for key in ['buildCohortSHA256', 'protocolID']:
            with self.subTest(key=key):
                original = self.analysis['cells'][1][key]
                self.analysis['cells'][1][key] = 'different'
                with self.assertRaisesRegex(ValueError, key):
                    self.select()
                self.analysis['cells'][1][key] = original

    def test_different_context_and_protocol_refused(self):
        self.analysis['cells'][1]['contextTokens'] = 4096
        with self.assertRaisesRegex(ValueError, 'Context/output'):
            self.select()
        self.analysis['cells'][1]['contextTokens'] = 2048
        self.analysis['minimumIndependentBlocksPerCell'] = 3
        with self.assertRaisesRegex(ValueError, 'five-block'):
            self.select()


if __name__ == '__main__':
    unittest.main()
